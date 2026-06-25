//! `fold [OPTION]... [FILE]...` — wrap each input line to a fixed width (default 80).
//!
//! By default WIDTH counts display columns: a TAB advances to the next multiple of 8, a backspace
//! (`0x08`) moves back one, a carriage return resets to 0 (GNU's column model). With `-b`, WIDTH
//! counts bytes instead. With `-s`, a line is broken at the last blank within the width when
//! possible so words stay intact. The obsolete `-WIDTH` form (e.g. `fold -10`) is accepted as
//! `-w WIDTH`. With no FILE, or when FILE is `-`, read standard input.
//!
//! **Streaming, bounded memory.** Lines are read one at a time over the facade's [`LineReader`]
//! (CRLF-tolerant: a trailing `\r` is stripped before wrapping) and emitted through a chunked
//! [`BufOut`]; only the current line/segment is held. Output is bare LF.
//!
//! Deviations from GNU `fold`: the long options (`--bytes`, `--spaces`, `--width`) are not
//! implemented. Because input lines are CRLF-stripped, an embedded `\r`'s column reset still
//! applies (the column model honors `\r`), but the terminating CRLF is normalized to LF.
//!
//! Exit status: `0` success; `1` if a FILE could not be opened; `2` on a usage error (clap).
//!
//! Ported from memcontainers' `programs::fold`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;

/// Parse a non-negative decimal width (checked), or `None` on any non-digit / empty input.
fn parse_usize(b: &[u8]) -> Option<usize> {
    if b.is_empty() {
        return None;
    }
    let mut v = 0usize;
    for &c in b {
        if !c.is_ascii_digit() {
            return None;
        }
        v = v.checked_mul(10)?.checked_add((c - b'0') as usize)?;
    }
    Some(v)
}

/// Column after printing byte `b` starting from `col` (display-column model unless `bytes`, where
/// every byte is one column).
fn advance(col: usize, b: u8, bytes: bool) -> usize {
    if bytes {
        return col + 1;
    }
    match b {
        b'\t' => col - col % 8 + 8, // next multiple of 8
        0x08 => col.saturating_sub(1), // backspace
        b'\r' => 0,
        _ => col + 1,
    }
}

/// Total column width of `seg` from column 0.
fn width_of(seg: &[u8], bytes: bool) -> usize {
    if bytes {
        return seg.len();
    }
    seg.iter().fold(0, |c, &b| advance(c, b, bytes))
}

fn is_blank(b: u8) -> bool {
    b == b' ' || b == b'\t'
}

/// The clap command — the single source of `fold`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("fold")
        .about("Wrap input lines in each FILE, writing to standard output. With no FILE, or when FILE is -, read standard input.")
        .arg(Arg::new("bytes").short('b').long("bytes").action(ArgAction::SetTrue).help("count bytes rather than columns"))
        .arg(Arg::new("spaces").short('s').long("spaces").action(ArgAction::SetTrue).help("break at spaces"))
        .arg(Arg::new("width").short('w').long("width").value_name("WIDTH").num_args(1).help("use WIDTH columns instead of 80"))
        .arg(Arg::new("FILE").action(ArgAction::Append).num_args(0..).help("files to wrap (- for standard input)"))
}

/// `fold [OPTION]... [FILE]...`. Returns the exit status (0 success; 1 if a FILE could not open).
pub fn uumain(args: impl uucore::Args) -> i32 {
    // GNU accepts the obsolete `-WIDTH` (e.g. `fold -10`) as `-w WIDTH`. clap would treat `-10`
    // as an unknown flag, so rewrite a leading bare `-<digits>` operand into `-w <digits>`.
    let argv: Vec<std::ffi::OsString> = args.collect();
    let mut rewritten: Vec<std::ffi::OsString> = Vec::with_capacity(argv.len() + 1);
    for (i, a) in argv.iter().enumerate() {
        if i > 0 {
            if let Some(s) = a.to_str() {
                if let Some(d) = s.strip_prefix('-') {
                    if !d.is_empty() && d.bytes().all(|b| b.is_ascii_digit()) {
                        rewritten.push(std::ffi::OsString::from("-w"));
                        rewritten.push(std::ffi::OsString::from(d));
                        continue;
                    }
                }
            }
        }
        rewritten.push(a.clone());
    }

    let m = match command().try_get_matches_from(rewritten) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let width = m
        .get_one::<String>("width")
        .and_then(|s| parse_usize(s.as_bytes()))
        .filter(|&w| w > 0)
        .unwrap_or(80);
    let at_spaces = m.get_flag("spaces");
    let bytes = m.get_flag("bytes");

    let ops: Vec<&[u8]> = m
        .get_many::<String>("FILE")
        .map(|v| v.map(|s| s.as_bytes()).collect())
        .unwrap_or_default();

    let mut o = BufOut::new();
    let mut seg: Vec<u8> = Vec::new();
    let rc = textio::stream_lines("fold", &ops, |line| {
        seg.clear();
        let mut col = 0usize;
        for &b in line {
            // Break before `b` while it would overflow and the segment isn't empty.
            loop {
                let next = advance(col, b, bytes);
                if next <= width || seg.is_empty() {
                    seg.push(b);
                    col = next;
                    break;
                }
                // Need a break. With -s, split after the last blank in the segment.
                let split = if at_spaces {
                    seg.iter().rposition(|&x| is_blank(x))
                } else {
                    None
                };
                match split {
                    Some(i) => {
                        o.extend(&seg[..=i]);
                        o.end_line()?;
                        // Keep the remainder; recompute its column.
                        seg.drain(..=i);
                        col = width_of(&seg, bytes);
                    }
                    None => {
                        o.extend(&seg);
                        o.end_line()?;
                        seg.clear();
                        col = 0;
                    }
                }
                // Re-evaluate `b` against the now-shorter segment.
            }
        }
        o.extend(&seg);
        o.end_line()
    });
    let _ = o.finish();
    rc
}
