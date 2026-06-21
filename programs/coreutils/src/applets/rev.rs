//! `rev [FILE]...` — reverse the bytes of each line of each FILE (or stdin) to stdout.
//!
//! Reverses the bytes of every line, one line at a time over the facade's [`LineReader`]
//! (via `textio::stream_lines`) into a chunked [`BufOut`], so peak memory is one line
//! regardless of input size. With no FILE, or when FILE is `-`, reads standard input; the
//! whole operand list is streamed in order. Lines are split on `\n` (CRLF-tolerant: a
//! trailing `\r` is stripped before reversal, matching the facade's line model), and a bare
//! `\n` is re-emitted as the terminator.
//!
//! Flags: only `--help`. (util-linux `rev` has no real options; `-h` is taken as clap's
//! help here.)
//!
//! GNU/util-linux deviations: reverses BYTES, not multibyte/UTF-8 characters; no
//! `-0`/`--zero` (NUL-delimited) option. Because the facade strips a trailing `\r` from CRLF
//! input, a `\r\n`-terminated line loses its `\r` (it is not re-inserted), unlike a strict
//! byte-for-byte reversal of the raw bytes — this matches every other facade-based filter
//! in the box.
//!
//! Exit status: 0 success; 1 if a FILE could not be opened (the remaining inputs still
//! stream, GNU-style).
//!
//! Ported from memcontainers' `programs::rev`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;

/// The clap command — the single source of `rev`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("rev")
        .about("Reverse the bytes of each line of FILE(s) to standard output. With no FILE, or when FILE is -, read standard input.")
        .arg(
            Arg::new("FILE")
                .action(ArgAction::Append)
                .num_args(0..)
                .help("files whose lines to reverse (- for standard input)"),
        )
}

/// `rev [FILE]...`. Returns the exit status (0 success; 1 if a FILE could not be opened).
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        // clap prints help/usage/version itself; mirror its exit code (0 for --help/--version).
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let ops: Vec<&str> = m
        .get_many::<String>("FILE")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();
    // The facade streams over byte-slice operands (stdin for an empty list or a `-`).
    let ops_b: Vec<&[u8]> = ops.iter().map(|s| s.as_bytes()).collect();

    let mut o = BufOut::new();
    let rc = textio::stream_lines("rev", &ops_b, |l| {
        for &b in l.iter().rev() {
            o.push(b);
        }
        o.end_line()
    });
    let _ = o.finish();
    rc
}
