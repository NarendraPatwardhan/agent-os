//! `yes [STRING]...` — repeatedly print a line until the write fails (e.g. the reader of
//! `yes | head` closes).
//!
//! With no operands the repeated line is `y`; with operands it is them joined by single spaces.
//! A bare `\n` terminates the line (the terminal adds CR via ONLCR). All operands are taken
//! literally — `yes -x` repeats the line `-x` — matching GNU.
//!
//! Flags (via clap — the help mandate): `--help` and `--version`. To match GNU `/bin/yes`
//! (which only special-cases a leading `--help`/`--version`), these are honored ONLY as the
//! FIRST operand; `yes foo --help` repeats `foo --help` literally. Because the operands are
//! literal, the STRING list is handled by this applet's own logic, not by clap's parser.
//!
//! Deviations from GNU `yes`: `--help`/`--version` are recognized only as the first operand (as
//! above); there are no other options.
//!
//! Exit status: `0` — reached only when the downstream reader closes (the write fails). While the
//! reader stays open, `yes` never returns.
//!
//! Ported from memcontainers' `programs::yes`.

use alloc::vec::Vec;

use clap::Command;

use sysroot as rt;

/// The clap command — the single source of `yes`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("yes")
        .version("0.1.0")
        .about("Repeatedly output a line with all specified STRING(s), or 'y'.")
        .override_usage("yes [STRING]...")
        .after_help(
            "With no STRING the repeated line is 'y'; with operands it is them joined by single \
             spaces. Output stops when a write fails (e.g. the reader of `yes | head` closes). \
             STRINGs are literal: only a leading --help/--version is special (GNU /bin/yes \
             behavior); `yes foo --help` repeats the line `foo --help`.",
        )
}

/// `yes [STRING]...`. Returns 0 when the downstream reader closes.
pub fn uumain(args: impl uucore::Args) -> i32 {
    // Operands are literal (POSIX/GNU `yes`), so do NOT run clap's parser over them. Honor only a
    // leading --help/--version (matching memcontainers' `wants_help_first`); clap renders both.
    let argv: Vec<Vec<u8>> = args.map(|a| a.to_string_lossy().into_owned().into_bytes()).collect();
    if let Some(first) = argv.get(1) {
        if first.as_slice() == b"--help" || first.as_slice() == b"-h" {
            let _ = command().print_help();
            return 0;
        }
        if first.as_slice() == b"--version" {
            print!("{}", command().render_version());
            return 0;
        }
    }

    // Build the line once: operands joined by spaces (non-empty operands only, matching the
    // memcontainers binary), else "y"; then a bare LF.
    let mut line: Vec<u8> = Vec::new();
    let mut first = true;
    for tok in argv.iter().skip(1).filter(|s| !s.is_empty()) {
        if !first {
            line.push(b' ');
        }
        line.extend_from_slice(tok);
        first = false;
    }
    if first {
        line.push(b'y');
    }
    line.push(b'\n');

    // Repeat until the write fails (the reader closed). Raw stdout write — the hot loop's natural
    // shape and the verbatim ported logic (writing to fd 1 needs no capability).
    while rt::write_all(rt::STDOUT, &line).is_ok() {}
    0
}
