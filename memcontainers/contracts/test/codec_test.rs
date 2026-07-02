use std::collections::BTreeMap;

use ctl_rust::{ExecRequest, RelayEvent, WireError as ControlWireError};
use llb_rust::{BuildOp, Definition, DigestEdge, LayerRef, NodeDigest, WireError as LlbWireError};

fn map(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
        .collect()
}

fn u8(out: &mut Vec<u8>, value: u8) {
    out.push(value);
}

fn u16(out: &mut Vec<u8>, value: u16) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn u32(out: &mut Vec<u8>, value: u32) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn bytes(out: &mut Vec<u8>, value: &[u8]) {
    u32(out, value.len() as u32);
    out.extend_from_slice(value);
}

fn str_bytes(out: &mut Vec<u8>, value: &str) {
    bytes(out, value.as_bytes());
}

fn non_canonical_exec_request_frame() -> Vec<u8> {
    let mut out = Vec::new();
    u16(&mut out, 1);
    u8(&mut out, 1);
    str_bytes(&mut out, "env");
    u8(&mut out, 0);
    u32(&mut out, 2);
    str_bytes(&mut out, "z");
    str_bytes(&mut out, "last");
    str_bytes(&mut out, "a");
    str_bytes(&mut out, "first");
    u8(&mut out, 0);
    out
}

#[test]
fn control_codecs_are_canonical_and_fail_closed() {
    let unsorted = ExecRequest {
        cmd: "cat".to_string(),
        cwd: Some("/tmp".to_string()),
        env: map(&[("ZED", "z"), ("ALPHA", "a")]),
        stdin: Some(Vec::new()),
    }
    .encode();
    let sorted = ExecRequest {
        cmd: "cat".to_string(),
        cwd: Some("/tmp".to_string()),
        env: map(&[("ALPHA", "a"), ("ZED", "z")]),
        stdin: Some(Vec::new()),
    }
    .encode();
    assert_eq!(unsorted, sorted);

    let exec = ExecRequest::decode(&unsorted).unwrap();
    assert_eq!(exec.cmd, "cat");
    assert_eq!(exec.cwd.as_deref(), Some("/tmp"));
    assert_eq!(exec.env.get("ALPHA").map(String::as_str), Some("a"));
    assert_eq!(exec.env.get("ZED").map(String::as_str), Some("z"));
    assert_eq!(exec.stdin.as_deref(), Some(&[][..]));

    assert_eq!(
        ExecRequest::decode(&[2, 0, 1]),
        Err(ControlWireError::WrongMessage)
    );
    assert_eq!(
        ExecRequest::decode(&[1, 0, 2]),
        Err(ControlWireError::UnsupportedVersion)
    );
    assert_eq!(
        ExecRequest::decode(&unsorted[..unsorted.len() - 1]),
        Err(ControlWireError::Truncated)
    );
    let mut trailing = unsorted.clone();
    trailing.push(0);
    assert_eq!(
        ExecRequest::decode(&trailing),
        Err(ControlWireError::TrailingBytes)
    );
    assert_eq!(
        ExecRequest::decode(&non_canonical_exec_request_frame()),
        Err(ControlWireError::NonCanonicalMap)
    );

    let relay = RelayEvent::decode(
        &RelayEvent {
            kind: "tool_approval".to_string(),
            handle: 7,
            connection: Some("github".to_string()),
            method: Some("POST".to_string()),
            url: Some("https://api.example.test/repos".to_string()),
            origin: Some("https://api.example.test".to_string()),
            ..Default::default()
        }
        .encode(),
    )
    .unwrap();
    assert_eq!(relay.kind, "tool_approval");
    assert_eq!(relay.handle, 7);
    assert_eq!(relay.args_digest, None);

    let host_call = RelayEvent::decode(
        &RelayEvent {
            kind: "host_call".to_string(),
            handle: 8,
            name: Some("empty".to_string()),
            body: Some(Vec::new()),
            ..Default::default()
        }
        .encode(),
    )
    .unwrap();
    assert_eq!(host_call.name.as_deref(), Some("empty"));
    assert_eq!(host_call.body.as_deref(), Some(&[][..]));
}

#[test]
fn llb_codecs_are_canonical_and_fail_closed() {
    let source = BuildOp {
        kind: 0,
        source_ref: Some("base:latest".to_string()),
        ..Default::default()
    };
    let exec = BuildOp {
        kind: 7,
        input: Some(0),
        cmd: Some("printf $VALUE".to_string()),
        cwd: Some("/work".to_string()),
        env: map(&[("ZED", "z"), ("ALPHA", "a")]),
        stdin: Some(Vec::new()),
        deterministic: Some(true),
        tier: Some("read-write".to_string()),
        ..Default::default()
    };
    let definition = Definition {
        version: 1,
        ops: vec![source, exec.clone()],
        root: 1,
    };
    let encoded = definition.encode();
    let decoded = Definition::decode(&encoded).unwrap();
    assert_eq!(decoded.encode(), encoded);
    assert_eq!(decoded.ops[1].cmd.as_deref(), Some("printf $VALUE"));
    assert_eq!(decoded.ops[1].stdin.as_deref(), Some(&[][..]));

    let unsorted_digest = NodeDigest {
        op: exec.clone(),
        edges: vec![
            DigestEdge {
                role: "input".to_string(),
                digest: "sha256:bbbb".to_string(),
            },
            DigestEdge {
                role: "mount".to_string(),
                digest: "sha256:aaaa".to_string(),
            },
        ],
        resolved: map(&[("z", "last"), ("a", "first")]),
        layers: vec![LayerRef {
            digest: "sha256:cccc".to_string(),
            size: 12,
            producer: "node-1".to_string(),
        }],
        kernel_digest: Some("sha256:kernel".to_string()),
    };
    let mut sorted_exec = exec;
    sorted_exec.env = map(&[("ALPHA", "a"), ("ZED", "z")]);
    let sorted_digest = NodeDigest {
        op: sorted_exec,
        resolved: map(&[("a", "first"), ("z", "last")]),
        ..unsorted_digest.clone()
    };
    assert_eq!(unsorted_digest.encode(), sorted_digest.encode());
    let digest = NodeDigest::decode(&unsorted_digest.encode()).unwrap();
    assert_eq!(digest.edges.len(), 2);
    assert_eq!(digest.layers[0].producer, "node-1");

    assert_eq!(
        Definition::decode(&[8, 0, 1]),
        Err(LlbWireError::WrongMessage)
    );
    assert_eq!(
        Definition::decode(&[3, 0, 2]),
        Err(LlbWireError::UnsupportedVersion)
    );
    assert_eq!(
        Definition::decode(&encoded[..encoded.len() - 1]),
        Err(LlbWireError::Truncated)
    );
    let mut trailing = encoded;
    trailing.push(0);
    assert_eq!(
        Definition::decode(&trailing),
        Err(LlbWireError::TrailingBytes)
    );
}
