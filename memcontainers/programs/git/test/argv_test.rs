#[path = "../src/argv.rs"]
mod argv;

fn encode(fun: impl FnOnce(&mut [u8]) -> Result<usize, i32>) -> String {
    let mut out = [0u8; 512];
    let n = fun(&mut out).expect("encode");
    String::from_utf8(out[..n].to_vec()).expect("utf8")
}

#[test]
fn clone_url_and_depth() {
    let body = encode(|out| {
        argv::build_remote_request(
            b"clone",
            &[
                b"git",
                b"clone",
                b"--depth",
                b"1",
                b"https://example.com/r.git",
            ],
            out,
        )
    });
    assert_eq!(
        body,
        r#"{"op":"clone","args":{"url":"https://example.com/r.git","depth":1}}"#
    );
}

#[test]
fn push_requires_qualified_refspec() {
    let body = encode(|out| {
        argv::build_remote_request(
            b"push",
            &[
                b"git",
                b"push",
                b"https://example.com/r.git",
                b"refs/heads/main:refs/heads/main",
            ],
            out,
        )
    });
    assert_eq!(
        body,
        r#"{"op":"push","args":{"url":"https://example.com/r.git","refspecs":["refs/heads/main:refs/heads/main"]}}"#
    );
    let mut out = [0u8; 64];
    assert_eq!(
        argv::build_remote_request(
            b"push",
            &[b"git", b"push", b"https://example.com/r.git", b"main"],
            &mut out
        ),
        Err(2)
    );
}

#[test]
fn local_status_commit_checkout_log_diff() {
    assert_eq!(
        encode(|out| argv::build_local_request(b"status", &[b"git", b"status"], out)),
        r#"{"op":"status","args":{"short":false}}"#
    );
    assert_eq!(
        encode(|out| argv::build_local_request(b"commit", &[b"git", b"commit", b"-m", b"ok"], out)),
        r#"{"op":"commit","args":{"message":"ok"}}"#
    );
    assert_eq!(
        encode(|out| argv::build_local_request(b"checkout", &[b"git", b"checkout", b"topic"], out)),
        r#"{"op":"checkout","args":{"name":"topic"}}"#
    );
    assert_eq!(
        encode(|out| argv::build_local_request(b"log", &[b"git", b"log"], out)),
        r#"{"op":"log","args":{"max_count":32}}"#
    );
    assert_eq!(
        encode(|out| argv::build_local_request(b"diff", &[b"git", b"diff", b"--cached"], out)),
        r#"{"op":"diff","args":{"cached":true}}"#
    );
}
