use host::{CaptureSink, KernelHostBuilder};
use runfiles::Runfiles;
use serde::Deserialize;
use snapshot_rust::{SNAPSHOT_HEADER_LEN, SNAPSHOT_PAGE_SIZE, SnapshotKind, parse_snapshot};
use std::io::Cursor;

#[derive(Deserialize)]
struct Vector {
    name: String,
    source: Option<String>,
    mutation: String,
    offset: Option<usize>,
    value: Option<u32>,
    length: Option<usize>,
    error: String,
}

fn runfile(path: &str) -> Vec<u8> {
    let r = Runfiles::create().expect("runfiles");
    std::fs::read(r.rlocation(path).expect("runfile path")).expect("read runfile")
}

fn mutate(mut bytes: Vec<u8>, v: &Vector) -> Vec<u8> {
    match v.mutation.as_str() {
        "u32" => bytes[v.offset.unwrap()..v.offset.unwrap() + 4]
            .copy_from_slice(&v.value.unwrap().to_le_bytes()),
        "zero" => bytes[v.offset.unwrap()..v.offset.unwrap() + v.length.unwrap()].fill(0),
        "byte" => bytes[v.offset.unwrap()] = v.value.unwrap() as u8,
        "flip" => bytes[v.offset.unwrap()] ^= 0xff,
        "append" => bytes.push(0),
        "truncate" => {
            bytes.pop();
        }
        other => panic!("unknown mutation {other}"),
    }
    bytes
}

#[test]
fn both_host_families_reject_the_shared_malformed_snapshot_vectors() {
    let kernel = runfile("_main/memcontainers/kernel/rust/kernel.wasm");
    let image = runfile("_main/memcontainers/images/base.tar");
    let vectors: Vec<Vector> = serde_json::from_slice(&runfile(
        "_main/memcontainers/conformance/snapshot_vectors.json",
    ))
    .unwrap();
    let (sink, _) = CaptureSink::new();
    let mut host = KernelHostBuilder::new(kernel.clone())
        .with_base_image(Some(image))
        .with_stdout(Box::new(sink))
        .deterministic()
        .build()
        .unwrap();
    let valid = host.snapshot().unwrap();
    let incremental = host.snapshot_incremental(&valid).unwrap();
    for vector in vectors {
        let is_incremental = vector.source.as_deref() == Some("incremental");
        let bad = mutate(
            if is_incremental {
                incremental.clone()
            } else {
                valid.clone()
            },
            &vector,
        );
        let builder = KernelHostBuilder::new(kernel.clone()).deterministic();
        let result = if is_incremental {
            builder.restore_incremental(&bad, &valid)
        } else {
            builder.restore(&bad)
        };
        let error = result.err().unwrap().to_string();
        assert!(error.contains(&vector.error), "{}: {error}", vector.name);
    }
}

#[test]
fn caller_owned_full_snapshot_is_exact_and_byte_identical() {
    let kernel = runfile("_main/memcontainers/kernel/rust/kernel.wasm");
    let image = runfile("_main/memcontainers/images/base.tar");
    let (sink, _) = CaptureSink::new();
    let mut host = KernelHostBuilder::new(kernel)
        .with_base_image(Some(image))
        .with_stdout(Box::new(sink))
        .deterministic()
        .build()
        .unwrap();

    let owned = host.snapshot().expect("owned snapshot");
    let mut destination = vec![0xa5; host.snapshot_len()];
    host.snapshot_into(&mut destination)
        .expect("snapshot directly into caller destination");
    assert_eq!(destination, owned);

    let mut streamed = Cursor::new(Vec::new());
    let written = host.snapshot_to(&mut streamed).unwrap();
    assert_eq!(written.bytes, owned.len());
    assert_ne!(written.id, [0; 32]);
    assert_eq!(streamed.into_inner(), owned);

    let mut nonempty = Cursor::new(vec![0]);
    assert!(
        host.snapshot_to(&mut nonempty)
            .unwrap_err()
            .to_string()
            .contains("sink must be empty")
    );

    let mut short = vec![0; host.snapshot_len() - 1];
    let error = host.snapshot_into(&mut short).unwrap_err().to_string();
    assert!(error.contains("destination length mismatch"), "{error}");
}

#[test]
fn incremental_tracks_small_writes_restores_exactly_and_survives_failure() {
    let kernel = runfile("_main/memcontainers/kernel/rust/kernel.wasm");
    let image = runfile("_main/memcontainers/images/base.tar");
    let (sink, _) = CaptureSink::new();
    let mut host = KernelHostBuilder::new(kernel.clone())
        .with_base_image(Some(image))
        .with_stdout(Box::new(sink))
        .deterministic()
        .build()
        .unwrap();

    let base = host.snapshot().expect("full baseline");
    let payload: Vec<u8> = (0..4096).map(|i| (i * 31) as u8).collect();
    host.write_file("/tmp/tracked", &payload)
        .expect("write a 4-KiB file");

    let mut short = vec![0; host.snapshot_len() - 1];
    assert!(host.snapshot_into(&mut short).is_err());

    let delta = host
        .snapshot_incremental(&base)
        .expect("incremental snapshot");
    let view = parse_snapshot(&delta).expect("parse incremental");
    assert_eq!(view.kind, SnapshotKind::Incremental);
    assert!(view.changed_pages > 0);
    assert!(view.changed_pages < view.memory_len / SNAPSHOT_PAGE_SIZE);
    assert!(delta.len() < SNAPSHOT_HEADER_LEN + view.memory_len);

    let mut restored = KernelHostBuilder::new(kernel.clone())
        .deterministic()
        .restore_incremental(&delta, &base)
        .expect("restore incremental");
    assert_eq!(restored.read_file("/tmp/tracked").unwrap(), payload);

    restored
        .write_file("/tmp/after-restore", b"second generation")
        .unwrap();
    let second_generation = restored.snapshot_incremental(&base).unwrap();
    let mut restored_again = KernelHostBuilder::new(kernel.clone())
        .deterministic()
        .restore_incremental(&second_generation, &base)
        .unwrap();
    assert_eq!(
        restored_again.read_file("/tmp/after-restore").unwrap(),
        b"second generation"
    );

    let replacement = vec![0xa7; 4096];
    host.write_file("/tmp/tracked", &replacement).unwrap();
    let mut bad_base = base.clone();
    bad_base[SNAPSHOT_HEADER_LEN] ^= 1;
    assert!(host.snapshot_incremental(&bad_base).is_err());
    let after_failure = host.snapshot_incremental(&base).unwrap();
    let mut restored = KernelHostBuilder::new(kernel)
        .deterministic()
        .restore_incremental(&after_failure, &base)
        .unwrap();
    assert_eq!(restored.read_file("/tmp/tracked").unwrap(), replacement);
}

#[test]
fn incremental_handles_memory_growth() {
    let kernel = runfile("_main/memcontainers/kernel/rust/kernel.wasm");
    let image = runfile("_main/memcontainers/images/base.tar");
    let (sink, _) = CaptureSink::new();
    let mut host = KernelHostBuilder::new(kernel.clone())
        .with_base_image(Some(image))
        .with_stdout(Box::new(sink))
        .deterministic()
        .build()
        .unwrap();
    let base = host.snapshot().unwrap();
    let base_len = parse_snapshot(&base).unwrap().memory_len;
    let payload = vec![0x5c; base_len];
    host.write_file("/tmp/growth", &payload).unwrap();
    let delta = host.snapshot_incremental(&base).unwrap();
    assert!(parse_snapshot(&delta).unwrap().memory_len > base_len);
    let mut restored = KernelHostBuilder::new(kernel)
        .deterministic()
        .restore_incremental(&delta, &base)
        .unwrap();
    assert_eq!(restored.read_file("/tmp/growth").unwrap(), payload);
}
