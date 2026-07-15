use host::{CaptureSink, KernelHostBuilder};
use runfiles::Runfiles;
use serde::Deserialize;

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
