//! `echo [-neE] [ARG]...` — print arguments separated by single spaces, followed by a newline.
//!
//! `-n` omits the trailing newline; `-e` enables backslash escapes (`\n \t \r \\ \0 \a \b \f \v`
//! and `\c`); `-E` disables them (the default). Only LEADING `-n`/`-e`/`-E` tokens are flags, per
//! POSIX/XSI `echo` — the first non-flag argument ends flag parsing, so `echo -n -e x -n` prints
//! `x -n`. The trailing newline is a bare LF (the terminal adds CR via ONLCR). With `-e`, `\c`
//! stops all output, including the trailing newline.
//!
//! Flags (via clap — the help mandate): `-n`, `-e`, `-E`, plus `--help`/`--version`. Because
//! `echo`'s operands are POSIX-literal and its flags are leading-only, the ARG list and the
//! leading flags are handled by this applet's own logic; clap supplies the documented surface and
//! renders `--help`/`--version` (recognized only as the FIRST argument, matching GNU /bin/echo —
//! `echo x --help` prints `x --help`).
//!
//! Deviations from GNU `echo`: `--help`/`--version` are honored only as the first argument (as
//! above); combined leading flags are merged (`-ne`); there are no long options for `-n`/`-e`/`-E`.
//!
//! Exit status: `0` always.
//!
//! Ported from memcontainers' `programs::echo`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;

/// The clap command — the documented flag surface AND the `--help`/`--version` source. (Parsing
/// is done by hand below to keep POSIX `echo` operand/flag semantics; this command is for help.)
fn command() -> Command {
    Command::new("echo")
        .version("0.1.0")
        .about("Echo the STRING(s) to standard output.")
        .override_usage("echo [SHORT-OPTION]... [STRING]...")
        .arg(Arg::new("no-newline").short('n').action(ArgAction::SetTrue).help("do not output the trailing newline"))
        .arg(Arg::new("escapes").short('e').action(ArgAction::SetTrue).help("enable interpretation of backslash escapes"))
        .arg(Arg::new("no-escapes").short('E').action(ArgAction::SetTrue).help("disable interpretation of backslash escapes (default)"))
        .arg(Arg::new("STRING").action(ArgAction::Append).num_args(0..).help("strings to print, separated by single spaces"))
        .after_help(
            "Only LEADING -n/-e/-E tokens are flags (POSIX/XSI echo); the first non-flag argument \
             ends flag parsing. The trailing newline is a bare LF. With -e, the following \
             sequences are recognized:\n  \\\\   backslash         \\a   alert (BEL)\n  \\b   \
             backspace         \\c   produce no further output\n  \\f   form feed         \\n   \
             new line\n  \\r   carriage return   \\t   horizontal tab\n  \\v   vertical tab      \
             \\0   null byte\n--help/--version are recognized only as the FIRST argument (GNU \
             /bin/echo behavior).",
        )
}

/// True iff `tok` is a leading echo flag: `-` followed by one or more of `n`/`e`/`E`.
fn is_echo_flag(tok: &[u8]) -> bool {
    tok.len() >= 2 && tok[0] == b'-' && tok[1..].iter().all(|c| matches!(c, b'n' | b'e' | b'E'))
}

/// Append `tok` to `o`, interpreting backslash escapes. Returns true if `\c` was seen (stop all
/// output, suppress the trailing newline). Byte-exact; an unknown escape emits the backslash and
/// the char verbatim.
fn push_escaped(o: &mut BufOut, tok: &[u8]) -> bool {
    let mut i = 0;
    while i < tok.len() {
        if tok[i] == b'\\' && i + 1 < tok.len() {
            let e = tok[i + 1];
            let out: &[u8] = match e {
                b'n' => b"\n",
                b't' => b"\t",
                b'r' => b"\r",
                b'\\' => b"\\",
                b'a' => b"\x07",
                b'b' => b"\x08",
                b'f' => b"\x0c",
                b'v' => b"\x0b",
                b'0' => b"\0",
                b'c' => return true, // \c: stop output now
                _ => {
                    // Unknown escape: emit the backslash + char verbatim.
                    o.extend(&tok[i..i + 2]);
                    i += 2;
                    continue;
                }
            };
            o.extend(out);
            i += 2;
        } else {
            o.push(tok[i]);
            i += 1;
        }
    }
    false
}

/// `echo [-neE] [ARG]...`. Returns the exit status (always 0).
pub fn uumain(args: impl uucore::Args) -> i32 {
    // POSIX echo: operands are literal and flags are leading-only, so do NOT run clap's parser
    // over the operands. Honor only a leading --help/--version (matching memcontainers'
    // `wants_help_first`); clap renders both.
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

    let mut newline = true;
    let mut escapes = false;
    let mut flags_done = false;
    let mut first = true;
    let mut stopped = false;
    let mut o = BufOut::new();

    for tok in argv.iter().skip(1) {
        if !flags_done && is_echo_flag(tok) {
            for &c in &tok[1..] {
                match c {
                    b'n' => newline = false,
                    b'e' => escapes = true,
                    b'E' => escapes = false,
                    _ => {}
                }
            }
            continue;
        }
        flags_done = true;
        if !first {
            o.extend(b" ");
        }
        first = false;
        if escapes {
            if push_escaped(&mut o, tok) {
                stopped = true;
                break;
            }
        } else {
            o.extend(tok);
        }
    }
    if newline && !stopped {
        o.push(b'\n');
    }
    let _ = o.finish();
    0
}
