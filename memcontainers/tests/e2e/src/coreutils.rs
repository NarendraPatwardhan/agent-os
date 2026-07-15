//! Coreutils — the guest `/bin` running through the REAL interactive shell on the REAL kernel. Each
//! boots the `posix` image, writes inputs via the control channel, runs a command through the
//! console, and asserts the terminal response. The output is CRLF: a tool emits LF to fd 1, and the
//! terminal's ONLCR (kernel io.rs) adds the CR — exactly what the agent's xterm.js sees. Behavioral
//! tests (mv/cp) run the command on the console, then verify the effect over the control channel.
//!
//! Each line proves the whole pipeline: console → `/bin/sh -c` → `/bin/<tool>` (the wasm32-wasi
//! box CONVERTED to pure-mc, dispatched on argv[0]) → the sysroot/adapter → the kernel.

use crate::boot_posix;

/// WHY: `cat` is the hand-written "from programs" representative (clap + the facade over //sysroot).
/// GUARANTEES: it streams a file back byte-for-byte, ONLCR'd to CRLF on the terminal.
#[test]
fn cat_streams_a_file() {
    let mut s = boot_posix();
    s.host
        .write_file("/tmp/note", b"agent-os e2e\n")
        .expect("write");
    assert_eq!(s.run_for_output("cat /tmp/note"), "agent-os e2e\r\n");
}

/// WHY: `base64` is the uutils representative — the REAL `uu_base64::uumain` over the WASI→mc
/// adapter. GUARANTEES: uutils' exact encoding, proving the converted box executes correctly.
#[test]
fn base64_encodes_via_uutils() {
    let mut s = boot_posix();
    s.host.write_file("/tmp/in", b"hello").expect("write");
    assert_eq!(s.run_for_output("base64 /tmp/in"), "aGVsbG8=\r\n");
}

/// WHY: `grep` is the external-crate representative — ripgrep's engine. GUARANTEES: it selects
/// exactly the matching lines, proving a third-party Rust crate stack runs in a converted box.
#[test]
fn grep_selects_matching_lines() {
    let mut s = boot_posix();
    s.host
        .write_file("/tmp/lines", b"foo\nbar\nbaz\nqux\n")
        .expect("write");
    assert_eq!(s.run_for_output("grep ba /tmp/lines"), "bar\r\nbaz\r\n");
}

/// WHY: `sed` is the VENDORED+patched external tool (uutils sed fetched from crates.io). GUARANTEES:
/// a real `s///` stream-edit, proving a fetched+patched crate converts to pure-mc and runs.
#[test]
fn sed_substitutes_via_vendored_sed() {
    let mut s = boot_posix();
    s.host
        .write_file("/tmp/sed-in", b"hello world\n")
        .expect("write");
    assert_eq!(
        s.run_for_output("sed s/world/agent-os/ /tmp/sed-in"),
        "hello agent-os\r\n"
    );
}

/// WHY: `jq` is the crates.io external tool (the jaq engine). GUARANTEES: a JSON filter selects the
/// value, proving the read-only box runs the jaq stack.
#[test]
fn jq_filters_json() {
    let mut s = boot_posix();
    s.host
        .write_file("/tmp/j.json", b"{\"name\":\"agent-os\",\"n\":42}")
        .expect("write");
    assert_eq!(s.run_for_output("jq .n /tmp/j.json"), "42\r\n");
}

/// WHY: `head` is a hand-written line filter (the streaming facade). GUARANTEES: `-N` selects the
/// first N lines and nothing else.
#[test]
fn head_selects_first_lines() {
    let mut s = boot_posix();
    s.host
        .write_file("/tmp/multi", b"alpha\nbeta\ngamma\n")
        .expect("write");
    assert_eq!(s.run_for_output("head -2 /tmp/multi"), "alpha\r\nbeta\r\n");
}

/// WHY: `gzip` (flate2) is a read-WRITE external tool — it writes/removes files. GUARANTEES: a
/// compress→decompress→cat round-trip recovers the original, proving the box both writes and reads.
#[test]
fn gzip_round_trips() {
    let mut s = boot_posix();
    s.host
        .write_file("/tmp/gz", b"hello flate2 round-trip\n")
        .expect("write");
    s.run_for_output("gzip /tmp/gz"); // → /tmp/gz.gz, removes /tmp/gz (silent)
    s.run_for_output("gzip -d /tmp/gz.gz"); // → /tmp/gz (silent)
    assert_eq!(
        s.run_for_output("cat /tmp/gz"),
        "hello flate2 round-trip\r\n"
    );
}

/// WHY: `mv` mutates the filesystem (the read-write tier). GUARANTEES: the destination gets the
/// source's bytes and the source is gone — verified over the control channel (the fs effect is
/// real, not just terminal output).
#[test]
fn mv_renames_a_file() {
    let mut s = boot_posix();
    s.host.write_file("/tmp/x", b"aaa\n").expect("write /tmp/x");
    s.run_for_output("mv /tmp/x /tmp/y");
    assert_eq!(s.host.read_file("/tmp/y").expect("read /tmp/y"), b"aaa\n");
    assert!(
        s.host.read_file("/tmp/x").is_err(),
        "source must be gone after mv"
    );
}

/// WHY: `cp` copies (read-write) while leaving the source. GUARANTEES: destination and source both
/// hold the bytes after the copy — verified over the control channel.
#[test]
fn cp_copies_a_file() {
    let mut s = boot_posix();
    s.host
        .write_file("/tmp/src", b"copy me\n")
        .expect("write /tmp/src");
    s.run_for_output("cp /tmp/src /tmp/dst");
    assert_eq!(
        s.host.read_file("/tmp/dst").expect("read /tmp/dst"),
        b"copy me\n"
    );
    assert_eq!(
        s.host.read_file("/tmp/src").expect("read /tmp/src"),
        b"copy me\n"
    );
}
