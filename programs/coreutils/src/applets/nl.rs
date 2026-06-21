//! `nl [OPTION]... [FILE]...` — number the lines of files.
//!
//! `-b` selects which body lines are numbered (`t`, the default, numbers only non-empty lines;
//! `a` numbers every line; `n` numbers none). `-n` is the number format (`rn` right-justified
//! without leading zeros = default, `ln` left-justified, `rz` right-justified zero-padded); `-w`
//! the field width (default 6); `-s` the text after the number (default a TAB); `-v` the first
//! line number (default 1); `-i` the increment (default 1). Streams one line at a time and the
//! counter continues across operands. With no FILE, or when FILE is `-`, read standard input.
//!
//! **Streaming, bounded memory.** Lines are read one at a time over the facade's [`LineReader`]
//! (CRLF-tolerant: a trailing `\r` is stripped) and emitted through a chunked [`BufOut`]; peak
//! memory is one line. Output is bare LF.
//!
//! Deviations from GNU `nl`: the long options (`--body-numbering`, `--number-format`,
//! `--number-width`, `--number-separator`, `--starting-line-number`, `--line-increment`) are not
//! implemented. The page/section logic is out of scope — the `\:` delimiters and `-h`/`-f`
//! header/footer styles are not handled; `-b` accepts only `a`/`t`/`n` (no `pBRE` expression).
//! An unsupported `-b`/`-n` style is rejected (exit 1) rather than silently treated as a default.
//!
//! Exit status: `0` success; `1` if a FILE could not be opened or an unsupported style was given;
//! `2` on a usage error (clap).
//!
//! Ported from memcontainers' `programs::nl`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;

/// Number format (`-n`).
#[derive(Clone, Copy, PartialEq)]
enum NumFmt {
    Ln, // left-justified, blank-padded
    Rn, // right-justified, blank-padded (default)
    Rz, // right-justified, zero-padded
}

/// Which body lines to number (`-b`).
#[derive(Clone, Copy, PartialEq)]
enum Body {
    All,      // -b a
    NonEmpty, // -b t (default)
    None,     // -b n
}

/// Parse a signed decimal (`-v`/`-i`/`-w`), or `None` on any non-digit / empty body.
fn parse_i64(b: &[u8]) -> Option<i64> {
    let (neg, d): (bool, &[u8]) = match b.first() {
        Some(b'-') => (true, &b[1..]),
        Some(b'+') => (false, &b[1..]),
        _ => (false, b),
    };
    if d.is_empty() {
        return None;
    }
    let mut v: i64 = 0;
    for &c in d {
        if !c.is_ascii_digit() {
            return None;
        }
        v = v.checked_mul(10)?.checked_add((c - b'0') as i64)?;
    }
    Some(if neg { -v } else { v })
}

/// Render `v` into `o` in the chosen format/width.
fn push_num(o: &mut BufOut, v: i64, width: usize, fmt: NumFmt) {
    let neg = v < 0;
    let mut mag = if neg {
        (v as i128).unsigned_abs()
    } else {
        v as u128
    };
    let mut digits = [0u8; 40];
    let mut nd = 0;
    if mag == 0 {
        digits[0] = b'0';
        nd = 1;
    }
    while mag > 0 {
        digits[nd] = b'0' + (mag % 10) as u8;
        mag /= 10;
        nd += 1;
    }
    let body = nd + usize::from(neg); // sign + digit count
    let pad = width.saturating_sub(body);
    let emit_sign_digits = |o: &mut BufOut| {
        if neg {
            o.push(b'-');
        }
        for k in (0..nd).rev() {
            o.push(digits[k]);
        }
    };
    match fmt {
        NumFmt::Ln => {
            emit_sign_digits(o);
            for _ in 0..pad {
                o.push(b' ');
            }
        }
        NumFmt::Rn => {
            for _ in 0..pad {
                o.push(b' ');
            }
            emit_sign_digits(o);
        }
        NumFmt::Rz => {
            if neg {
                o.push(b'-');
            }
            for _ in 0..pad {
                o.push(b'0');
            }
            for k in (0..nd).rev() {
                o.push(digits[k]);
            }
        }
    }
}

/// The clap command — the single source of `nl`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("nl")
        .about("Write each FILE to standard output, with line numbers added. With no FILE, or when FILE is -, read standard input.")
        .arg(Arg::new("body-numbering").short('b').long("body-numbering").value_name("STYLE").num_args(1).help("use STYLE for numbering body lines: a (all), t (nonempty, default), n (none)"))
        .arg(Arg::new("number-format").short('n').long("number-format").value_name("FORMAT").num_args(1).help("insert line numbers according to FORMAT: ln (left), rn (right, default), rz (right, zero-padded)"))
        .arg(Arg::new("number-width").short('w').long("number-width").value_name("NUMBER").num_args(1).help("use NUMBER columns for line numbers (default 6)"))
        .arg(Arg::new("number-separator").short('s').long("number-separator").value_name("STRING").num_args(1).help("add STRING after (possible) line number (default a TAB)"))
        .arg(Arg::new("starting-line-number").short('v').long("starting-line-number").value_name("NUMBER").num_args(1).help("first line number for each section (default 1)"))
        .arg(Arg::new("line-increment").short('i').long("line-increment").value_name("NUMBER").num_args(1).help("line number increment at each line (default 1)"))
        .arg(Arg::new("FILE").action(ArgAction::Append).num_args(0..).help("files to number (- for standard input)"))
}

/// `nl [OPTION]... [FILE]...`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let body = match m.get_one::<String>("body-numbering").map(String::as_str) {
        Some("a") => Body::All,
        Some("n") => Body::None,
        Some("t") | None => Body::NonEmpty,
        Some(other) => {
            // pBRE / other styles are unsupported; reject rather than silently numbering
            // everything (no disguised behavior).
            eprintln!("nl: {}: unsupported body numbering style", other);
            return 1;
        }
    };
    let fmt = match m.get_one::<String>("number-format").map(String::as_str) {
        Some("ln") => NumFmt::Ln,
        Some("rz") => NumFmt::Rz,
        Some("rn") | None => NumFmt::Rn,
        Some(other) => {
            eprintln!("nl: {}: unsupported number format", other);
            return 1;
        }
    };
    let width = m
        .get_one::<String>("number-width")
        .and_then(|s| parse_i64(s.as_bytes()))
        .filter(|&w| w > 0)
        .unwrap_or(6) as usize;
    let sep: Vec<u8> = m
        .get_one::<String>("number-separator")
        .map(|s| s.as_bytes().to_vec())
        .unwrap_or_else(|| b"\t".to_vec());
    let start = m
        .get_one::<String>("starting-line-number")
        .and_then(|s| parse_i64(s.as_bytes()))
        .unwrap_or(1);
    let incr = m
        .get_one::<String>("line-increment")
        .and_then(|s| parse_i64(s.as_bytes()))
        .unwrap_or(1);

    let ops: Vec<&[u8]> = m
        .get_many::<String>("FILE")
        .map(|v| v.map(|s| s.as_bytes()).collect())
        .unwrap_or_default();

    let mut o = BufOut::new();
    let mut num: i64 = start;
    let rc = textio::stream_lines("nl", &ops, |l| {
        let number_it = match body {
            Body::All => true,
            Body::NonEmpty => !l.is_empty(),
            Body::None => false,
        };
        if number_it {
            push_num(&mut o, num, width, fmt);
            o.extend(&sep);
            num = num.wrapping_add(incr);
        } else {
            // Unnumbered line: GNU blanks the number field but keeps the separator.
            for _ in 0..width {
                o.push(b' ');
            }
            o.extend(&sep);
        }
        o.extend(l);
        o.end_line()
    });
    let _ = o.finish();
    rc
}
