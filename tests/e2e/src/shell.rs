//! Shell — `/bin/sh` control flow on the real kernel, driven through the console. Pipes,
//! redirection, sequencing, conditionals, command substitution, and variables — the constructs the
//! agent actually types. Each asserts the terminal response (CRLF) or, for redirection, the file
//! effect over the control channel.

use crate::boot_posix;

/// WHY: a pipe wires one guest's stdout to the next's stdin through the kernel's pipe primitive.
/// GUARANTEES: `a | b` routes bytes between two converted boxes, not just runs them serially.
#[test]
fn pipe_routes_output_between_commands() {
    let mut s = boot_posix();
    s.host.write_file("/tmp/lines", b"foo\nbar\nbaz\n").expect("write");
    assert_eq!(s.run_for_output("cat /tmp/lines | grep bar"), "bar\r\n");
}

/// WHY: `>` redirection points a guest's fd 1 at a file (a PIPE/file, not the terminal), so the
/// bytes land pure-LF. GUARANTEES: the redirected output is in the file verbatim (LF), and nothing
/// echoes to the terminal.
#[test]
fn redirect_writes_to_file() {
    let mut s = boot_posix();
    assert_eq!(s.run_for_output("echo hello > /tmp/r"), "");
    assert_eq!(s.host.read_file("/tmp/r").expect("read /tmp/r"), b"hello\n");
}

/// WHY: `;` sequences commands in order. GUARANTEES: both run, left-to-right, their outputs in order.
#[test]
fn semicolon_sequences_commands() {
    let mut s = boot_posix();
    assert_eq!(s.run_for_output("echo one; echo two"), "one\r\ntwo\r\n");
}

/// WHY: `&&` runs the right side only on the left's success. GUARANTEES: success chains (the second
/// runs) — the exit-status wiring through the shell is correct.
#[test]
fn and_runs_second_on_success() {
    let mut s = boot_posix();
    assert_eq!(s.run_for_output("true && echo yes"), "yes\r\n");
}

/// WHY: `||` runs the right side only on the left's failure. GUARANTEES: a failing command's
/// nonzero status triggers the fallback.
#[test]
fn or_runs_fallback_on_failure() {
    let mut s = boot_posix();
    assert_eq!(s.run_for_output("false || echo fallback"), "fallback\r\n");
}

/// WHY: `$(...)` command substitution runs a subshell and splices its stdout into the parent
/// command line. GUARANTEES: the inner command's output becomes the outer argument.
#[test]
fn command_substitution_splices_output() {
    let mut s = boot_posix();
    assert_eq!(s.run_for_output("echo $(echo nested)"), "nested\r\n");
}

/// WHY: variable assignment + `$VAR` expansion is the most basic shell state. GUARANTEES: an
/// assigned value expands in a later command on the same line.
#[test]
fn variable_assigns_and_expands() {
    let mut s = boot_posix();
    assert_eq!(s.run_for_output("X=hi; echo $X"), "hi\r\n");
}
