//! TTY — the interactive terminal: ONLCR (the deliberate CRLF) and the cooked line discipline. This
//! is the path the agent's xterm.js terminal sees, distinct from the raw exec pipe (LF; see
//! [`crate::kernel::exec_channel_captures_raw_lf_not_crlf`]). The CRLF here is a chosen behavior, so
//! it is asserted directly.

use crate::boot_posix;

/// WHY: the kernel's terminal layer applies ONLCR — `\n`→`\r\n` — to ALL tool/guest output on the
/// console (kernel io.rs), so a real terminal advances both line and column. GUARANTEES: a tool
/// that emits a single LF appears as CRLF on the console. This is the deliberate behavior memcon-
/// tainers chose after being burned; losing it would break the agent's terminal.
#[test]
fn console_output_is_crlf() {
    let mut s = boot_posix();
    assert_eq!(s.run_for_output("echo hi"), "hi\r\n", "console output must be ONLCR (CRLF)");
}

/// WHY: the cooked line discipline echoes typed characters back to the terminal, terminating the
/// line with CRLF on Enter. GUARANTEES: the typed command is echoed with a trailing `\r\n` — what
/// lets `run_for_output` find the command's response, and what the terminal user sees.
#[test]
fn typed_command_is_echoed_with_crlf() {
    let mut s = boot_posix();
    let response = s.send_line("echo abc");
    assert!(response.contains("echo abc\r\n"), "typed line not echoed with CRLF; got:\n{response:?}");
}

/// WHY: backspace (0x7F) must erase the most recent character from the line buffer BEFORE Enter, and
/// the kernel must emit the redraw sequence "\x08 \x08" so the terminal repaints. GUARANTEES: after
/// typing "echo a", a backspace, then "b" + Enter, the command run is "echo b" (output "b\r\n") and
/// the redraw fired — the line editor edits the buffer, not just the screen.
#[test]
fn backspace_erases_and_redraws() {
    let mut s = boot_posix();
    let m = s.mark();
    s.send_raw(b"echo a");
    s.send_raw(&[0x7F]); // backspace erases 'a'
    s.send_raw(b"b\n"); // 'b' + Enter → the line is "echo b"
    s.drive_until_prompt(m);
    let resp = s.since(m);
    assert!(resp.contains("b\r\n"), "echo of 'b' missing — backspace failed to clear 'a':\n{resp:?}");
    assert!(resp.contains("\x08 \x08"), "expected the backspace redraw sequence:\n{resp:?}");
}
