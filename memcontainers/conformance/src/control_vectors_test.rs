use std::collections::BTreeMap;

use ctl_rust::{
    DirEntries, DirEntry, ExecOutcome, ExecRequest, FileStat, RelayEvent, SvcRequest, SvcResponse,
    WireError,
};
use serde_json::Value;

fn runfile(path: &str) -> Vec<u8> {
    let r = runfiles::Runfiles::create().expect("runfiles unavailable");
    let p = r
        .rlocation(path)
        .unwrap_or_else(|| panic!("{path} not found in runfiles"));
    std::fs::read(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()))
}

fn vectors() -> Value {
    serde_json::from_slice(&runfile(
        "_main/memcontainers/conformance/control_vectors.json",
    ))
    .expect("parse control_vectors.json")
}

fn hex_to_bytes(hex: &str) -> Vec<u8> {
    assert_eq!(hex.len() % 2, 0, "hex vector must have an even length");
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).expect("hex byte"))
        .collect()
}

fn positive(message: &str) -> Vec<u8> {
    vectors()["positive"]
        .as_array()
        .expect("positive vectors")
        .iter()
        .find(|case| case["message"].as_str() == Some(message))
        .map(|case| hex_to_bytes(case["hex"].as_str().expect("hex")))
        .unwrap_or_else(|| panic!("missing positive vector for {message}"))
}

fn map(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
        .collect()
}

#[test]
fn rust_control_codecs_match_the_shared_positive_vectors() {
    let exec = ExecRequest {
        cmd: "printf $ALPHA && cat".to_string(),
        cwd: Some("/work".to_string()),
        env: map(&[("ZED", "last"), ("ALPHA", "first")]),
        stdin: Some(b"payload\n\0".to_vec()),
    };
    assert_eq!(exec.encode(), positive("ExecRequest"));
    let decoded = ExecRequest::decode(&positive("ExecRequest")).unwrap();
    assert_eq!(decoded.cmd, exec.cmd);
    assert_eq!(decoded.cwd, exec.cwd);
    assert_eq!(decoded.env, map(&[("ALPHA", "first"), ("ZED", "last")]));
    assert_eq!(decoded.stdin.as_deref(), Some(b"payload\n\0".as_slice()));

    let outcome = ExecOutcome {
        exit_code: 7,
        stdout: b"out\n".to_vec(),
        stderr: b"err\n".to_vec(),
    };
    assert_eq!(outcome.encode(), positive("ExecOutcome"));
    assert_eq!(
        ExecOutcome::decode(&positive("ExecOutcome")).unwrap(),
        outcome
    );

    let stat = FileStat {
        size: 12345,
        is_dir: false,
        is_symlink: true,
        nlink: 2,
        mode: 0o120777,
    };
    assert_eq!(stat.encode(), positive("FileStat"));
    assert_eq!(FileStat::decode(&positive("FileStat")).unwrap(), stat);

    let entries = DirEntries {
        entries: vec![
            DirEntry {
                name: "a.txt".to_string(),
                is_dir: false,
                is_symlink: false,
            },
            DirEntry {
                name: "link".to_string(),
                is_dir: false,
                is_symlink: true,
            },
            DirEntry {
                name: "sub".to_string(),
                is_dir: true,
                is_symlink: false,
            },
        ],
    };
    assert_eq!(entries.encode(), positive("DirEntries"));
    assert_eq!(
        DirEntries::decode(&positive("DirEntries")).unwrap(),
        entries
    );

    let svc_request = SvcRequest {
        service: "kv".to_string(),
        request: b"put\0answer\0forty-two".to_vec(),
    };
    assert_eq!(svc_request.encode(), positive("SvcRequest"));
    assert_eq!(
        SvcRequest::decode(&positive("SvcRequest")).unwrap(),
        svc_request
    );

    let svc_response = SvcResponse {
        status: 0,
        body: b"42".to_vec(),
    };
    assert_eq!(svc_response.encode(), positive("SvcResponse"));
    assert_eq!(
        SvcResponse::decode(&positive("SvcResponse")).unwrap(),
        svc_response
    );

    let relay = RelayEvent {
        kind: "host_call".to_string(),
        handle: 42,
        name: Some("tool.exec".to_string()),
        body: Some(vec![0, 1, 2, 255]),
        args_digest: Some("sha256:0123456789abcdef".to_string()),
        ..Default::default()
    };
    assert_eq!(relay.encode(), positive("RelayEvent"));
    assert_eq!(RelayEvent::decode(&positive("RelayEvent")).unwrap(), relay);
}

#[test]
fn rust_control_codecs_reject_shared_negative_vectors() {
    for case in vectors()["negative"].as_array().expect("negative vectors") {
        let message = case["message"].as_str().expect("message");
        let name = case["name"].as_str().expect("name");
        let bytes = hex_to_bytes(case["hex"].as_str().expect("hex"));
        let want = case["error"].as_str().expect("error");
        let got = match message {
            "ExecRequest" => ExecRequest::decode(&bytes).expect_err("negative vector decoded"),
            other => panic!("unhandled negative vector message {other}"),
        };
        let got_name = match got {
            WireError::WrongMessage => "WrongMessage",
            WireError::UnsupportedVersion => "UnsupportedVersion",
            WireError::Truncated => "Truncated",
            WireError::TrailingBytes => "TrailingBytes",
            WireError::NonCanonicalMap => "NonCanonicalMap",
            WireError::InvalidUtf8 => "InvalidUtf8",
            WireError::InvalidPresence => "InvalidPresence",
        };
        assert_eq!(got_name, want, "{message}:{name}");
    }
}
