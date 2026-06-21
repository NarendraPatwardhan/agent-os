//! `cut [OPTION]... [FILE]...` — print selected parts of each line.
//!
//! Exactly one of `-f`/`-c`/`-b` is required: `-f` selects delimiter-separated fields (default
//! delimiter TAB, set with `-d`), `-c`/`-b` select character / byte positions (identical in the C
//! locale). LIST is comma-separated 1-based numbers and ranges: `1,3-5`, `-3` (through 3), `4-`
//! (4 to end). `-s` suppresses lines with no delimiter in `-f` mode (the default prints them
//! whole). `--complement` selects everything NOT in LIST. `--output-delimiter=STR` sets the text
//! between output fields (default: the input delimiter for `-f`, nothing for `-c`/`-b`). `-n` is
//! accepted as a no-op (it never splits a multibyte character). With no FILE, or when FILE is `-`,
//! read standard input.
//!
//! **Streaming, bounded memory.** Lines are read one at a time over the facade's [`LineReader`]
//! (CRLF-tolerant: a trailing `\r` is stripped) and emitted through a chunked [`BufOut`]; peak
//! memory is one line. Output is bare LF.
//!
//! Deviations from GNU `cut`: DELIM and the output delimiter are taken as given but DELIM is a
//! single byte only; `--complement` and `--output-delimiter` are long-only (no short form, as in
//! GNU). No `-z`/`--zero-terminated`. Because lines are CRLF-stripped, a trailing CRLF is
//! normalized to LF on output.
//!
//! Exit status: `0` success; `1` on a usage error or if a FILE could not be opened; `2` on a clap
//! usage error (an unknown flag or a missing option value).
//!
//! Ported from memcontainers' `programs::cut`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;

/// Parse a non-negative decimal index (checked), or `None` on any non-digit / empty input.
fn parse_num(b: &[u8]) -> Option<usize> {
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

/// What went wrong parsing a LIST (for a precise diagnostic).
enum ListErr {
    Invalid,
    Zero,
    Decreasing,
}

/// Parse a LIST into inclusive 1-based `(lo, hi)` ranges (`hi = usize::MAX` = open-ended).
fn parse_list(s: &[u8]) -> Result<Vec<(usize, usize)>, ListErr> {
    let mut v = Vec::new();
    for part in s.split(|&b| b == b',') {
        if part.is_empty() {
            continue;
        }
        match part.iter().position(|&b| b == b'-') {
            Some(dash) => {
                let lo = if dash == 0 {
                    1
                } else {
                    parse_num(&part[..dash]).ok_or(ListErr::Invalid)?
                };
                let hi = if dash == part.len() - 1 {
                    usize::MAX
                } else {
                    parse_num(&part[dash + 1..]).ok_or(ListErr::Invalid)?
                };
                if lo == 0 || hi == 0 {
                    return Err(ListErr::Zero);
                }
                if hi < lo {
                    return Err(ListErr::Decreasing);
                }
                v.push((lo, hi));
            }
            None => {
                let nn = parse_num(part).ok_or(ListErr::Invalid)?;
                if nn == 0 {
                    return Err(ListErr::Zero);
                }
                v.push((nn, nn));
            }
        }
    }
    if v.is_empty() {
        Err(ListErr::Invalid)
    } else {
        Ok(v)
    }
}

fn in_list(list: &[(usize, usize)], idx: usize) -> bool {
    list.iter().any(|&(lo, hi)| idx >= lo && idx <= hi)
}

/// Selection mode: delimiter-separated fields, or character/byte positions.
enum Mode {
    Fields,
    Chars,
}

/// The clap command — the single source of `cut`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("cut")
        .about("Print selected parts of lines from each FILE to standard output. With no FILE, or when FILE is -, read standard input.")
        .arg(Arg::new("bytes").short('b').long("bytes").value_name("LIST").num_args(1).help("select only these bytes"))
        .arg(Arg::new("characters").short('c').long("characters").value_name("LIST").num_args(1).help("select only these characters"))
        .arg(Arg::new("fields").short('f').long("fields").value_name("LIST").num_args(1).help("select only these fields; also print any line that contains no delimiter character, unless -s is specified"))
        .arg(Arg::new("delimiter").short('d').long("delimiter").value_name("DELIM").num_args(1).help("use DELIM instead of TAB for the field delimiter"))
        .arg(Arg::new("only-delimited").short('s').long("only-delimited").action(ArgAction::SetTrue).help("do not print lines not containing delimiters"))
        .arg(Arg::new("no-split-multibyte").short('n').action(ArgAction::SetTrue).help("with -b: do not split multibyte characters (accepted no-op)"))
        .arg(Arg::new("complement").long("complement").action(ArgAction::SetTrue).help("complement the set of selected bytes, characters or fields"))
        .arg(Arg::new("output-delimiter").long("output-delimiter").value_name("STRING").num_args(1).help("use STRING as the output delimiter (default: the input delimiter)"))
        .arg(Arg::new("FILE").action(ArgAction::Append).num_args(0..).help("files to cut (- for standard input)"))
}

/// `cut [OPTION]... [FILE]...`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let complement = m.get_flag("complement");
    let suppress = m.get_flag("only-delimited");

    // Exactly one of -f / -c / -b.
    let f = m.get_one::<String>("fields").map(String::as_str);
    let cpos = m.get_one::<String>("characters").map(String::as_str);
    let bpos = m.get_one::<String>("bytes").map(String::as_str);
    let (mode, list_src, list_what): (Mode, &str, &str) = match (f, cpos, bpos) {
        (Some(fl), None, None) => (Mode::Fields, fl, "invalid field list"),
        (None, Some(cl), None) => (Mode::Chars, cl, "invalid byte/character list"),
        (None, None, Some(bl)) => (Mode::Chars, bl, "invalid byte/character list"),
        (None, None, None) => {
            eprintln!("cut: you must specify a list of bytes (-b), characters (-c), or fields (-f)");
            return 1;
        }
        _ => {
            eprintln!("cut: only one type of list may be specified");
            return 1;
        }
    };

    let list = match parse_list(list_src.as_bytes()) {
        Ok(l) => l,
        Err(e) => {
            let msg = match e {
                ListErr::Invalid => list_what,
                ListErr::Zero => "fields and positions are numbered from 1",
                ListErr::Decreasing => "invalid decreasing range",
            };
            eprintln!("cut: {}", msg);
            return 1;
        }
    };

    let delim = m
        .get_one::<String>("delimiter")
        .and_then(|d| d.as_bytes().first().copied())
        .unwrap_or(b'\t');
    if m.get_one::<String>("delimiter").is_some() && !matches!(mode, Mode::Fields) {
        eprintln!("cut: an input delimiter may be specified only when operating on fields");
        return 1;
    }
    if suppress && !matches!(mode, Mode::Fields) {
        eprintln!("cut: suppressing non-delimited lines makes sense only when operating on fields");
        return 1;
    }

    // Output delimiter: explicit > input delimiter (for -f) > nothing (for -c/-b).
    let out_delim: Vec<u8> = match m.get_one::<String>("output-delimiter") {
        Some(s) => s.as_bytes().to_vec(),
        None => match mode {
            Mode::Fields => alloc::vec![delim],
            Mode::Chars => Vec::new(),
        },
    };

    let sel = |idx: usize| in_list(&list, idx) != complement;

    let ops: Vec<&[u8]> = m
        .get_many::<String>("FILE")
        .map(|v| v.map(|s| s.as_bytes()).collect())
        .unwrap_or_default();

    let mut o = BufOut::new();
    let rc = textio::stream_lines("cut", &ops, |line| {
        match mode {
            Mode::Chars => {
                // Emit maximal runs of selected positions, separated by out_delim.
                let mut prev = false;
                let mut emitted = false;
                for (i, &b) in line.iter().enumerate() {
                    let s = sel(i + 1);
                    if s {
                        if !prev {
                            if emitted {
                                o.extend(&out_delim);
                            }
                            emitted = true;
                        }
                        o.push(b);
                    }
                    prev = s;
                }
            }
            Mode::Fields => {
                let fields: Vec<&[u8]> = line.split(|&b| b == delim).collect();
                if fields.len() == 1 {
                    // No delimiter on this line.
                    if !suppress {
                        o.extend(line);
                    } else {
                        return Ok(());
                    }
                } else {
                    let mut emitted = false;
                    for (i, f) in fields.iter().enumerate() {
                        if sel(i + 1) {
                            if emitted {
                                o.extend(&out_delim);
                            }
                            o.extend(f);
                            emitted = true;
                        }
                    }
                }
            }
        }
        o.end_line()
    });
    let _ = o.finish();
    rc
}
