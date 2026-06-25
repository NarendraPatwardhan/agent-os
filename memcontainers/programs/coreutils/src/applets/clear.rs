//! `clear` — clear the terminal screen and scrollback, then home the cursor.
//!
//! Emits the fixed ANSI sequence `ESC[H ESC[2J ESC[3J`: home the cursor, erase the whole screen,
//! erase the scrollback buffer. A terminal (xterm.js in the web hero, or a real VT on the native
//! host) renders all three. The bytes carry no LF, so the ONLCR layer leaves them untouched.
//! After this exits, the shell prints a fresh prompt at the top of a clean screen. It takes no
//! meaningful operands.
//!
//! Flags (via clap — the help mandate): `--help` prints usage and exits 0; `--version` prints the
//! version and exits 0.
//!
//! Deviations from ncurses `clear`: no `-x` (skip the scrollback erase) and no `-T TERM`; the
//! sequence is fixed, not terminfo-driven. Like the memcontainers binary, any operand other than
//! a leading `--help`/`--version`/`-h` is ignored (the sequence is still emitted) rather than
//! diagnosed.
//!
//! Exit status: `0` success.
//!
//! Ported from memcontainers' `programs::clear`.

use alloc::vec::Vec;

use clap::Command;

use crate::prelude::*;

/// The clap command — the single source of `clear`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("clear")
        .version("0.1.0")
        .about("Clear the terminal screen and scrollback buffer, then home the cursor.")
        .after_help(
            "Emits the fixed ANSI sequence ESC[H ESC[2J ESC[3J. Unlike ncurses clear, there is \
             no -x (skip scrollback erase) or -T TERM option; the sequence is not terminfo-driven.",
        )
}

/// Whether the operands request help (`--help`/`-h`) or version (`--version`), scanning past
/// argv[0] and stopping at `--`. Mirrors memcontainers' `wants_help`, plus `--version`.
fn wanted(argv: &[Vec<u8>]) -> Option<bool> {
    for tok in argv.iter().skip(1) {
        let t = tok.as_slice();
        if t == b"--" {
            break;
        }
        if t == b"--help" || t == b"-h" {
            return Some(true);
        }
        if t == b"--version" {
            return Some(false);
        }
    }
    None
}

/// `clear`. Returns the exit status (0 success).
pub fn uumain(args: impl uucore::Args) -> i32 {
    // memcontainers' `clear` only special-cases a help request and otherwise emits the sequence,
    // ignoring stray operands; mirror that (so do NOT run clap's parser over the operands). clap
    // renders the help/version text.
    let argv: Vec<Vec<u8>> = args.map(|a| a.to_string_lossy().into_owned().into_bytes()).collect();
    match wanted(&argv) {
        Some(true) => {
            let _ = command().print_help();
            return 0;
        }
        Some(false) => {
            print!("{}", command().render_version());
            return 0;
        }
        None => {}
    }
    // Cursor home, erase the whole screen, erase the scrollback. No LF (ONLCR leaves it alone).
    textio::out(b"\x1b[H\x1b[2J\x1b[3J");
    0
}
