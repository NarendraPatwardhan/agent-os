//! `tr [-c] [-d] [-s] [-t] SET1 [SET2]` — translate, delete, or squeeze bytes of stdin.
//!
//! Translate maps each byte of SET1 to the matching byte of SET2 (the last byte of SET2 repeats
//! if it is shorter, unless `-t` truncates SET1 to SET2's length). `-d` deletes SET1; `-s`
//! squeezes runs of a byte in the last SET to one; `-c` complements SET1. Operates on the raw
//! byte stream (no line model): it reads stdin and writes stdout, a chunk at a time (bounded
//! memory).
//!
//! SET syntax (GNU): byte ranges `a-z`; C escapes `\n \t \r \\ \a \b \f \v` and octal `\NNN`;
//! POSIX classes `[:alpha:]`/`[:digit:]`/`[:space:]`/…; repeat `[c*n]` (n copies, octal if it
//! starts with 0) and `[c*]` (fill SET2 to SET1's length); equivalence `[=c=]` (just `c` in the C
//! locale).
//!
//! Flags (via clap — the help mandate): `-c`/`-C`/`--complement`, `-d`/`--delete`,
//! `-s`/`--squeeze-repeats`, `-t`/`--truncate-set1`, plus `--help`/`--version`. The SET operands
//! may begin with `-` (clap `allow_hyphen_values`), and `--` ends option parsing.
//!
//! Deviations from GNU `tr`: SET1 may not contain a `[c*]` fill (string2 only — GNU also forbids
//! it). No other deviations: the long options GNU offers are all supported here.
//!
//! Exit status: `0` success; `1` if a SET was malformed or no SET operand was given.
//!
//! Ported from memcontainers' `programs::tr`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use sysroot as rt;

/// A SET element before fill resolution: an explicit byte, or a `[c*]` fill that expands (in
/// SET2) to enough copies of `c` to match SET1's length.
#[derive(Clone, Copy)]
enum Tok {
    Byte(u8),
    Fill(u8),
}

/// Read one character at `s[i]`, decoding a C/octal escape; returns (byte, next).
fn read_char(s: &[u8], i: usize) -> (u8, usize) {
    if s[i] != b'\\' || i + 1 >= s.len() {
        return (s[i], i + 1);
    }
    let n = s[i + 1];
    if (b'0'..=b'7').contains(&n) {
        // Up to three octal digits.
        let mut val: u16 = 0;
        let mut j = i + 1;
        let mut count = 0;
        while j < s.len() && count < 3 && (b'0'..=b'7').contains(&s[j]) {
            val = val * 8 + (s[j] - b'0') as u16;
            j += 1;
            count += 1;
        }
        return ((val & 0xff) as u8, j);
    }
    let b = match n {
        b'n' => b'\n',
        b't' => b'\t',
        b'r' => b'\r',
        b'\\' => b'\\',
        b'a' => 7,
        b'b' => 8,
        b'f' => 12,
        b'v' => 11,
        other => other,
    };
    (b, i + 2)
}

/// The byte members of a POSIX `[:name:]` class (C locale), or `None` if unknown.
fn class_bytes(name: &[u8]) -> Option<Vec<u8>> {
    let mut v = Vec::new();
    let push_range = |v: &mut Vec<u8>, lo: u8, hi: u8| {
        for b in lo..=hi {
            v.push(b);
        }
    };
    match name {
        b"alnum" => {
            push_range(&mut v, b'0', b'9');
            push_range(&mut v, b'A', b'Z');
            push_range(&mut v, b'a', b'z');
        }
        b"alpha" => {
            push_range(&mut v, b'A', b'Z');
            push_range(&mut v, b'a', b'z');
        }
        b"digit" => push_range(&mut v, b'0', b'9'),
        b"xdigit" => {
            push_range(&mut v, b'0', b'9');
            push_range(&mut v, b'A', b'F');
            push_range(&mut v, b'a', b'f');
        }
        b"lower" => push_range(&mut v, b'a', b'z'),
        b"upper" => push_range(&mut v, b'A', b'Z'),
        b"space" => v.extend_from_slice(b"\t\n\x0b\x0c\r "),
        b"blank" => v.extend_from_slice(b"\t "),
        b"cntrl" => {
            push_range(&mut v, 0, 31);
            v.push(127);
        }
        b"punct" => {
            // ASCII punctuation (graph minus alnum).
            for b in 33u8..=126 {
                if !b.is_ascii_alphanumeric() {
                    v.push(b);
                }
            }
        }
        b"graph" => push_range(&mut v, 33, 126),
        b"print" => push_range(&mut v, 32, 126),
        _ => return None,
    }
    Some(v)
}

/// Expand a SET spec into tokens (ranges/classes/escapes/repeats). `in_set2` permits a `[c*]`
/// fill; in SET1 a fill is an error.
fn expand(spec: &[u8], in_set2: bool) -> Result<Vec<Tok>, &'static str> {
    let mut out: Vec<Tok> = Vec::new();
    let mut i = 0usize;
    while i < spec.len() {
        if spec[i] == b'[' && i + 1 < spec.len() {
            // `[:class:]`
            if spec[i + 1] == b':' {
                if let Some(end) = find(spec, i + 2, b":]") {
                    let name = &spec[i + 2..end];
                    let bytes = class_bytes(name).ok_or("invalid character class")?;
                    out.extend(bytes.into_iter().map(Tok::Byte));
                    i = end + 2;
                    continue;
                }
                return Err("missing ']' for character class");
            }
            // `[=c=]` equivalence — in the C locale, just the character itself.
            if spec[i + 1] == b'=' {
                if let Some(end) = find(spec, i + 2, b"=]") {
                    let (c, _) = read_char(spec, i + 2);
                    out.push(Tok::Byte(c));
                    i = end + 2;
                    continue;
                }
                return Err("missing ']' for equivalence class");
            }
            // `[c*n]` / `[c*]` repeat.
            let (c, after_c) = read_char(spec, i + 1);
            if after_c < spec.len() && spec[after_c] == b'*' {
                if let Some(close) = spec[after_c + 1..].iter().position(|&b| b == b']') {
                    let digits = &spec[after_c + 1..after_c + 1 + close];
                    i = after_c + 1 + close + 1;
                    if digits.is_empty() {
                        if !in_set2 {
                            return Err("the [c*] construct may appear in string2 only");
                        }
                        out.push(Tok::Fill(c));
                    } else {
                        let n = parse_repeat(digits).ok_or("invalid repeat count")?;
                        for _ in 0..n {
                            out.push(Tok::Byte(c));
                        }
                    }
                    continue;
                }
            }
            // A bare `[` not starting a construct: literal.
        }
        // A plain char, possibly the low end of a range `lo-hi`.
        let (lo, after_lo) = read_char(spec, i);
        if after_lo < spec.len() && spec[after_lo] == b'-' && after_lo + 1 < spec.len() {
            let (hi, after_hi) = read_char(spec, after_lo + 1);
            if hi < lo {
                return Err("range-endpoints out of order");
            }
            for b in lo..=hi {
                out.push(Tok::Byte(b));
            }
            i = after_hi;
            continue;
        }
        out.push(Tok::Byte(lo));
        i = after_lo;
    }
    Ok(out)
}

/// Find the index of `needle` in `hay[from..]` (absolute), else `None`.
fn find(hay: &[u8], from: usize, needle: &[u8]) -> Option<usize> {
    if from > hay.len() {
        return None;
    }
    hay[from..]
        .windows(needle.len())
        .position(|w| w == needle)
        .map(|p| from + p)
}

/// Parse a repeat count: octal if it has a leading `0`, else decimal.
fn parse_repeat(d: &[u8]) -> Option<usize> {
    let (radix, digits): (usize, &[u8]) = if d.len() > 1 && d[0] == b'0' {
        (8, d)
    } else {
        (10, d)
    };
    let mut v = 0usize;
    for &c in digits {
        let dv = (c.wrapping_sub(b'0')) as usize;
        if dv as u8 >= radix as u8 || !c.is_ascii_digit() {
            return None;
        }
        v = v.checked_mul(radix)?.checked_add(dv)?;
    }
    Some(v)
}

/// Materialize tokens into explicit bytes. A `Fill` (SET2 only) expands to enough copies of its
/// byte to bring SET2 up to `target` (SET1's length).
fn materialize(toks: &[Tok], target: usize) -> Vec<u8> {
    let fixed: usize = toks.iter().filter(|t| matches!(t, Tok::Byte(_))).count();
    let mut out = Vec::new();
    for t in toks {
        match *t {
            Tok::Byte(b) => out.push(b),
            Tok::Fill(b) => {
                for _ in 0..target.saturating_sub(fixed) {
                    out.push(b);
                }
            }
        }
    }
    out
}

/// The clap command — the single source of `tr`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("tr")
        .version("0.1.0")
        .about("Translate, squeeze, and/or delete characters from standard input, writing to standard output.")
        .override_usage("tr [OPTION]... SET1 [SET2]")
        .arg(Arg::new("complement").short('c').visible_short_alias('C').long("complement").action(ArgAction::SetTrue).help("use the complement of SET1"))
        .arg(Arg::new("delete").short('d').long("delete").action(ArgAction::SetTrue).help("delete characters in SET1, do not translate"))
        .arg(Arg::new("squeeze-repeats").short('s').long("squeeze-repeats").action(ArgAction::SetTrue).help("replace each sequence of a repeated character that is listed in the last specified SET, with a single occurrence of that character"))
        .arg(Arg::new("truncate-set1").short('t').long("truncate-set1").action(ArgAction::SetTrue).help("first truncate SET1 to length of SET2"))
        .arg(Arg::new("SET").action(ArgAction::Append).num_args(0..=2).allow_hyphen_values(true).help("SET1 [SET2]: ranges (a-z), C/octal escapes, [:class:], [c*n]/[c*] repeats, [=c=] equivalence"))
        .after_help(
            "Translate maps each byte of SET1 to the matching byte of SET2; the last byte of SET2 \
             repeats if SET2 is shorter (unless -t). Operates on the raw byte stream (no line \
             model). SET syntax: ranges a-z; C escapes \\n \\t \\r \\\\ \\a \\b \\f \\v and octal \
             \\NNN; POSIX classes [:alnum:] [:alpha:] [:blank:] [:cntrl:] [:digit:] [:graph:] \
             [:lower:] [:print:] [:punct:] [:space:] [:upper:] [:xdigit:]; repeat [c*n] (octal if \
             it starts with 0) and [c*] (fill SET2 to SET1's length, string2 only); equivalence \
             [=c=].",
        )
}

/// `tr [OPTION]... SET1 [SET2]`. Returns the exit status (0 success; 1 on a bad/missing SET).
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        // clap prints help/usage/version itself; mirror its exit code (0 for --help/--version).
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let prog = "tr";
    let del = m.get_flag("delete");
    let squeeze = m.get_flag("squeeze-repeats");
    let comp = m.get_flag("complement");
    let truncate = m.get_flag("truncate-set1");

    let ops: Vec<&[u8]> = m
        .get_many::<String>("SET")
        .map(|v| v.map(|s| s.as_bytes()).collect())
        .unwrap_or_default();
    if ops.is_empty() {
        eprintln!("{prog}: missing operand");
        return 1;
    }
    let set1 = match expand(ops[0], false) {
        Ok(t) => materialize(&t, 0),
        Err(e) => {
            eprintln!("{prog}: {e}");
            return 1;
        }
    };
    // SET2 fill (`[c*]`) pads to SET1's length.
    let set2 = match ops.get(1) {
        Some(s) => match expand(s, true) {
            Ok(t) => materialize(&t, set1.len()),
            Err(e) => {
                eprintln!("{prog}: {e}");
                return 1;
            }
        },
        None => Vec::new(),
    };

    let translate = !del && !set2.is_empty();
    // `-t`: truncate SET1 to SET2's length before mapping (GNU `--truncate-set1`).
    let set1_eff: &[u8] = if translate && truncate {
        &set1[..set1.len().min(set2.len())]
    } else {
        &set1
    };

    // Membership of SET1 (after optional complement).
    let mut in1 = [false; 256];
    for &b in set1_eff {
        in1[b as usize] = true;
    }
    if comp {
        for x in in1.iter_mut() {
            *x = !*x;
        }
    }

    // Translation map.
    let mut map = [0u8; 256];
    for (i, mm) in map.iter_mut().enumerate() {
        *mm = i as u8;
    }
    if translate {
        if comp {
            // Every complemented byte maps to the last of SET2.
            let last = *set2.last().unwrap();
            for (b, &flag) in in1.iter().enumerate() {
                if flag {
                    map[b] = last;
                }
            }
        } else {
            for (i, &b) in set1_eff.iter().enumerate() {
                map[b as usize] = set2[i.min(set2.len() - 1)];
            }
        }
    }

    // The squeeze set is the last SET involved: SET2 for translate and for `tr -ds SET1 SET2`,
    // otherwise SET1.
    let mut sq = [false; 256];
    let sqsrc = if translate || (del && !set2.is_empty()) {
        &set2
    } else {
        &set1
    };
    for &b in sqsrc {
        sq[b as usize] = true;
    }
    // `tr -cs SET1`: squeeze the complement of SET1 (only when not translating and not the
    // `-ds SET1 SET2` form).
    if comp && !translate && (!del || set2.is_empty()) {
        for (i, x) in sq.iter_mut().enumerate() {
            *x = !set1.contains(&(i as u8));
        }
    }

    let mut inbuf = [0u8; 8192];
    let mut outbuf: Vec<u8> = Vec::new();
    let mut prev: Option<u8> = None;
    loop {
        match rt::read(rt::STDIN, &mut inbuf) {
            Ok(0) => break,
            Ok(k) => {
                outbuf.clear();
                for &b in &inbuf[..k] {
                    if del && in1[b as usize] {
                        continue;
                    }
                    let t = if translate { map[b as usize] } else { b };
                    if squeeze && sq[t as usize] && prev == Some(t) {
                        continue;
                    }
                    outbuf.push(t);
                    prev = Some(t);
                }
                if rt::write_all(rt::STDOUT, &outbuf).is_err() {
                    break;
                }
            }
            Err(_) => break,
        }
    }
    0
}
