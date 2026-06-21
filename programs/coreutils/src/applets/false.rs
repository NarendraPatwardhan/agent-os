//! `false` — do nothing, unsuccessfully (exit 1).
//!
//! A POSIX core-set utility: the shell also provides a `false` builtin (which wins when typed at
//! the prompt); this `/bin/false` twin exists for non-shell spawners (`find -exec false`,
//! `xargs`, `env false`). All operands are ignored.
//!
//! Flags (via clap — the help mandate): `--help` prints usage and exits 0; `--version` prints the
//! version and exits 0. Every other argument is ignored.
//!
//! Deviation from GNU: GNU `false` ignores every argument — including `--help`/`--version` — and
//! always exits 1 (it parses nothing). This twin instead recognizes `--help`/`--version`/`-h`
//! (rendered by clap), printing the message and exiting 0; it scans the operands and stops at a
//! `--`, so `false -- --help` still exits 1 silently. With any other arguments it ignores them and
//! exits 1 (no diagnostic), so the net "always fail" behavior is preserved.
//!
//! Exit status: `1` always (a `--help`/`--version` request exits 0 instead).
//!
//! Ported from memcontainers' `programs::false`.

use alloc::vec::Vec;

use clap::Command;

/// The clap command — the single source of `false`'s (minimal) flag surface AND its `--help`.
fn command() -> Command {
    Command::new("false")
        .version("0.1.0")
        .about("Do nothing, unsuccessfully. Exit with a status code indicating failure. Any ARGs are ignored.")
        .override_usage("false [ignored command line arguments]\n       false OPTION")
        .after_help(
            "GNU `false` ignores all arguments (including --help and --version) and always \
             fails. This twin recognizes --help/--version, printing a message and exiting 0; \
             otherwise it ignores its arguments and exits 1.",
        )
}

/// Whether the operands request help (`--help`/`-h`) or version (`--version`), scanning past
/// argv[0] and stopping at `--` (POSIX: `false -- --help` is not a help request). Mirrors
/// memcontainers' `wants_help`, but also catches `--version`.
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

/// `false [ARG]...`. Returns the exit status (1, or 0 for a help/version request).
pub fn uumain(args: impl uucore::Args) -> i32 {
    // GNU `false` never diagnoses on arguments, so do NOT run clap's parser over the operands.
    // Recognize only a help/version request (clap renders it); every other argument is ignored
    // and the status is the fixed 1. Verbatim memcontainers logic, with clap supplying the help.
    let argv: Vec<Vec<u8>> = args.map(|a| a.to_string_lossy().into_owned().into_bytes()).collect();
    match wanted(&argv) {
        Some(true) => {
            let _ = command().print_help();
            0
        }
        Some(false) => {
            print!("{}", command().render_version());
            0
        }
        None => 1,
    }
}
