//! `true` — do nothing, successfully (exit 0).
//!
//! A POSIX core-set utility: the shell also provides a `true` builtin (which wins when typed at
//! the prompt); this `/bin/true` twin exists for non-shell spawners (`find -exec true`, `xargs`,
//! `env true`). All operands are ignored.
//!
//! Flags (via clap — the help mandate): `--help` prints usage and exits 0; `--version` prints the
//! version and exits 0. Every other argument is ignored.
//!
//! Deviation from GNU: GNU `true` ignores every argument — including `--help`/`--version` — and
//! always exits 0 (it parses nothing). This twin instead recognizes `--help`/`--version`/`-h`
//! (rendered by clap), printing the message and exiting 0; it scans the operands and stops at a
//! `--`, so `true -- --help` still exits 0 silently. With any other arguments it ignores them and
//! exits 0 (no diagnostic), so the net "always succeed" behavior is preserved.
//!
//! Exit status: `0` always.
//!
//! Ported from memcontainers' `programs::true`.

use alloc::vec::Vec;

use clap::Command;

/// The clap command — the single source of `true`'s (minimal) flag surface AND its `--help`.
fn command() -> Command {
    Command::new("true")
        .version("0.1.0")
        .about("Do nothing, successfully. Exit with a status code indicating success. Any ARGs are ignored.")
        .override_usage("true [ignored command line arguments]\n       true OPTION")
        .after_help(
            "GNU `true` ignores all arguments (including --help and --version) and always \
             succeeds. This twin recognizes --help/--version, printing a message and exiting 0; \
             otherwise it ignores its arguments and exits 0.",
        )
}

/// Whether the operands request help (`--help`/`-h`) or version (`--version`), scanning past
/// argv[0] and stopping at `--` (POSIX: `true -- --help` is not a help request). Mirrors
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

/// `true [ARG]...`. Returns the exit status (always 0).
pub fn uumain(args: impl uucore::Args) -> i32 {
    // GNU `true` never fails or diagnoses on arguments, so do NOT run clap's parser over the
    // operands. Recognize only a help/version request (clap renders it); every other argument is
    // ignored. This is the verbatim memcontainers logic, with clap supplying the help text.
    let argv: Vec<Vec<u8>> = args.map(|a| a.to_string_lossy().into_owned().into_bytes()).collect();
    match wanted(&argv) {
        Some(true) => {
            let _ = command().print_help();
        }
        Some(false) => {
            print!("{}", command().render_version());
        }
        None => {}
    }
    0
}
