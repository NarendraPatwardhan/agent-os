//! `seq [-w] [-s SEP] [-f FORMAT] [FIRST [INCREMENT]] LAST` — print an arithmetic sequence.
//!
//! Defaults: `FIRST=1`, `INCREMENT=1`. `-s` sets the separator (default a newline); a trailing
//! newline is always emitted. `-w` pads numbers with leading zeros to equal width. `-f` formats
//! each number with a printf-style float conversion (`%f`/`%e`/`%g`, with flags/width/precision).
//!
//! Integer operands use exact `i64` arithmetic; any non-integer operand (or `-f`) switches to
//! `f64` with the increment applied as `first + i*incr` so rounding error does not accumulate.
//! Without `-f`, the number of fractional digits is derived from the operands (GNU behavior).
//! `-f` and `-w` are mutually exclusive (GNU).
//!
//! Flags (via clap — the help mandate): `-w`/`--equal-width`, `-s`/`--separator`,
//! `-f`/`--format`, plus `--help`/`--version`. Negative operands (`seq -3 3`, `seq 5 -1 1`) are
//! parsed via clap's `allow_negative_numbers`; `--` also ends option parsing.
//!
//! Deviations from GNU `seq`: `-f` conversions are limited to `f`/`e`/`g`. With no `-f`,
//! fractional digits are derived from the operands and exponent operands are not widened the GNU
//! way. (Unlike the memcontainers binary, the long options `--separator`/`--format`/
//! `--equal-width` ARE supported here, via clap.)
//!
//! Exit status: `0` success; `1` if an operand or format string was invalid.
//!
//! Ported from memcontainers' `programs::seq`.

use alloc::string::String;
use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;

/// Print `prog: [ctx: ]msg` to stderr and yield exit code 1 (the non-diverging analogue of
/// memcontainers' `cli::die`, byte-identical wording).
fn die(prog: &str, ctx: Option<&[u8]>, msg: &str) -> i32 {
    match ctx {
        Some(c) => eprintln!("{prog}: {}: {msg}", String::from_utf8_lossy(c)),
        None => eprintln!("{prog}: {msg}"),
    }
    1
}

// ---------- integer path ----------

fn parse_i64(b: &[u8]) -> Option<i64> {
    let (neg, digits): (bool, &[u8]) = match b.first() {
        Some(b'-') => (true, &b[1..]),
        Some(b'+') => (false, &b[1..]),
        _ => (false, b),
    };
    if digits.is_empty() {
        return None;
    }
    let mut v: i64 = 0;
    for &c in digits {
        if !c.is_ascii_digit() {
            return None;
        }
        v = v.checked_mul(10)?.checked_add((c - b'0') as i64)?;
    }
    Some(if neg { -v } else { v })
}

/// Format `v` into `buf`, left-padded with zeros (after any sign) to `width`.
fn fmt_int(buf: &mut Vec<u8>, v: i64, width: usize) {
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
    let body = nd + usize::from(neg);
    if neg {
        buf.push(b'-');
    }
    for _ in body..width {
        buf.push(b'0');
    }
    for k in (0..nd).rev() {
        buf.push(digits[k]);
    }
}

fn int_len(v: i64) -> usize {
    let mut t: Vec<u8> = Vec::new();
    fmt_int(&mut t, v, 0);
    t.len()
}

fn int_path(first: i64, incr: i64, last: i64, sep: &[u8], wide: bool) -> i32 {
    let width = if wide {
        int_len(first).max(int_len(last))
    } else {
        0
    };
    let asc = incr > 0;
    let mut out: Vec<u8> = Vec::new();
    let mut cur = first;
    let mut emitted = false;
    loop {
        if (asc && cur > last) || (!asc && cur < last) {
            break;
        }
        if emitted {
            out.extend_from_slice(sep);
        }
        fmt_int(&mut out, cur, width);
        emitted = true;
        cur = match cur.checked_add(incr) {
            Some(c) => c,
            None => break,
        };
    }
    if emitted {
        out.push(b'\n');
    }
    textio::out(&out);
    0
}

// ---------- float path ----------

fn parse_f64(b: &[u8]) -> Option<f64> {
    core::str::from_utf8(b).ok()?.parse::<f64>().ok()
}

/// Whether an operand should force float mode (`.`, `e`/`E`, `inf`/`nan`, or a value that isn't a
/// plain integer).
fn is_floaty(b: &[u8]) -> bool {
    b.iter()
        .any(|&c| c == b'.' || c == b'e' || c == b'E' || c == b'n' || c == b'N')
}

/// Fractional digits explicit in a decimal operand (`1.250` → 3); 0 if none or if it uses an
/// exponent (GNU widens precision there differently; we keep the common no-exponent case exact).
fn frac_digits(b: &[u8]) -> usize {
    if b.iter().any(|&c| c == b'e' || c == b'E') {
        return 0;
    }
    match b.iter().position(|&c| c == b'.') {
        Some(p) => b[p + 1..].iter().take_while(|c| c.is_ascii_digit()).count(),
        None => 0,
    }
}

/// The decimal exponent of `v` (floor log10 |v|), via core's `{:e}` formatting so no libm is
/// needed. `0` for a zero value.
fn sci_exp(v: f64) -> i32 {
    if v == 0.0 {
        return 0;
    }
    let s = alloc::format!("{:e}", v);
    match s.as_bytes().iter().position(|&c| c == b'e') {
        Some(p) => s[p + 1..].parse::<i32>().unwrap_or(0),
        None => 0,
    }
}

/// Strip trailing zeros (and a trailing `.`) from a fixed/scientific mantissa, for `%g` without
/// the `#` flag.
fn strip_trailing_zeros(s: &mut String) {
    if s.contains('.') {
        while s.ends_with('0') {
            s.pop();
        }
        if s.ends_with('.') {
            s.pop();
        }
    }
}

/// Render the exponent part C-style: `e`/`E`, sign, at least two digits.
fn c_exponent(out: &mut String, exp: i32, upper: bool) {
    out.push(if upper { 'E' } else { 'e' });
    out.push(if exp < 0 { '-' } else { '+' });
    let mag = exp.unsigned_abs();
    if mag < 10 {
        out.push('0');
    }
    out.push_str(&alloc::format!("{mag}"));
}

/// The numeric body for conversion `conv` at `prec` (sign included), no width pad.
fn render_number(val: f64, conv: u8, prec: usize, plus: bool, space: bool) -> String {
    let upper = conv.is_ascii_uppercase();
    let lc = conv.to_ascii_lowercase();
    let mut s = match lc {
        b'f' => alloc::format!("{:.*}", prec, val),
        b'e' => {
            // Rust `{:.*e}` gives `<mant>e<exp>`; rebuild the exponent C-style.
            let raw = alloc::format!("{:.*e}", prec, val);
            let bytes = raw.as_bytes();
            match bytes.iter().position(|&c| c == b'e') {
                Some(p) => {
                    let mant = core::str::from_utf8(&bytes[..p]).unwrap_or("0");
                    let exp: i32 = core::str::from_utf8(&bytes[p + 1..])
                        .ok()
                        .and_then(|t| t.parse().ok())
                        .unwrap_or(0);
                    let mut out = String::from(mant);
                    c_exponent(&mut out, exp, upper);
                    out
                }
                None => raw,
            }
        }
        b'g' => {
            // C %g: precision = significant digits (>=1); choose %e or %f.
            let p = prec.max(1);
            let exp = sci_exp(val);
            let mut out = if exp < -4 || exp >= p as i32 {
                let raw = alloc::format!("{:.*e}", p - 1, val);
                let bytes = raw.as_bytes();
                let cut = bytes.iter().position(|&c| c == b'e').unwrap_or(bytes.len());
                let mut m = String::from(core::str::from_utf8(&bytes[..cut]).unwrap_or("0"));
                strip_trailing_zeros(&mut m);
                let e: i32 = core::str::from_utf8(&bytes[cut.min(bytes.len())..])
                    .ok()
                    .map(|t| t.trim_start_matches('e'))
                    .and_then(|t| t.parse().ok())
                    .unwrap_or(0);
                c_exponent(&mut m, e, upper);
                m
            } else {
                let fp = (p as i32 - 1 - exp).max(0) as usize;
                let mut m = alloc::format!("{:.*}", fp, val);
                strip_trailing_zeros(&mut m);
                m
            };
            if upper {
                out = out.to_ascii_uppercase();
            }
            out
        }
        _ => alloc::format!("{val}"),
    };
    if upper && lc == b'f' {
        s = s.to_ascii_uppercase(); // INF/NAN
    }
    // Sign flags (Rust already emits `-`).
    if !s.starts_with('-') {
        if plus {
            s.insert(0, '+');
        } else if space {
            s.insert(0, ' ');
        }
    }
    s
}

/// Pad `num` to `width`: right-justified, with spaces or (if `zero` and not `left`) zeros
/// inserted after any sign; `left` left-justifies with spaces.
fn pad(num: &str, width: usize, left: bool, zero: bool) -> String {
    if num.len() >= width {
        return String::from(num);
    }
    let fill = width - num.len();
    let mut out = String::with_capacity(width);
    if left {
        out.push_str(num);
        for _ in 0..fill {
            out.push(' ');
        }
    } else if zero {
        let mut chars = num.chars();
        let first = num.as_bytes().first().copied();
        if matches!(first, Some(b'+') | Some(b'-') | Some(b' ')) {
            out.push(chars.next().unwrap());
        }
        for _ in 0..fill {
            out.push('0');
        }
        out.push_str(chars.as_str());
    } else {
        for _ in 0..fill {
            out.push(' ');
        }
        out.push_str(num);
    }
    out
}

/// Render the whole `-f` format for `val` (literals + escapes + one conversion).
fn render_format(fmt: &[u8], val: f64, out: &mut String) -> Result<bool, &'static str> {
    let mut i = 0;
    let mut used = false;
    while i < fmt.len() {
        match fmt[i] {
            b'%' if i + 1 < fmt.len() && fmt[i + 1] == b'%' => {
                out.push('%');
                i += 2;
            }
            b'%' => {
                i += 1;
                let (mut left, mut zero, mut plus, mut space) = (false, false, false, false);
                while i < fmt.len() {
                    match fmt[i] {
                        b'-' => left = true,
                        b'0' => zero = true,
                        b'+' => plus = true,
                        b' ' => space = true,
                        b'#' => {} // (ignored: matters only for %g trailing zeros)
                        _ => break,
                    }
                    i += 1;
                }
                let mut width = 0usize;
                while i < fmt.len() && fmt[i].is_ascii_digit() {
                    width = width * 10 + (fmt[i] - b'0') as usize;
                    i += 1;
                }
                let mut prec: Option<usize> = None;
                if i < fmt.len() && fmt[i] == b'.' {
                    i += 1;
                    let mut p = 0usize;
                    while i < fmt.len() && fmt[i].is_ascii_digit() {
                        p = p * 10 + (fmt[i] - b'0') as usize;
                        i += 1;
                    }
                    prec = Some(p);
                }
                if i >= fmt.len() {
                    return Err("invalid format string");
                }
                let conv = fmt[i];
                i += 1;
                if !matches!(conv.to_ascii_lowercase(), b'f' | b'e' | b'g') {
                    return Err("format conversion must be f, e, or g");
                }
                let p = prec.unwrap_or(6);
                let num = render_number(val, conv, p, plus, space);
                out.push_str(&pad(&num, width, left, zero));
                used = true;
            }
            b'\\' if i + 1 < fmt.len() => {
                i += 1;
                match fmt[i] {
                    b'n' => out.push('\n'),
                    b't' => out.push('\t'),
                    b'r' => out.push('\r'),
                    b'\\' => out.push('\\'),
                    other => {
                        out.push('\\');
                        out.push(other as char);
                    }
                }
                i += 1;
            }
            c => {
                out.push(c as char);
                i += 1;
            }
        }
    }
    Ok(used)
}

fn float_path(
    prog: &str,
    range: (f64, f64, f64),
    sep: &[u8],
    wide: bool,
    fmt: Option<&[u8]>,
    prec: usize,
) -> i32 {
    let (first, incr, last) = range;
    if incr == 0.0 {
        return die(prog, None, "increment must not be zero");
    }
    // Number of steps, guarded against rounding drift.
    let steps = (last - first) / incr;
    if steps < -1e-9 {
        return 0; // wrong direction → empty
    }
    // `steps + 1e-9 >= 0` here, so a truncating cast equals floor (no std libm).
    let n = (steps + 1e-9) as i64;

    // For -w, the field width is the widest endpoint rendering. The render closure returns an
    // error string if a `-f` format is invalid (reported once, like the memcontainers binary).
    let render = |v: f64| -> Result<String, &'static str> {
        match fmt {
            Some(f) => {
                let mut s = String::new();
                render_format(f, v, &mut s)?;
                Ok(s)
            }
            None => Ok(alloc::format!("{:.*}", prec, v)),
        }
    };
    let width = if wide && fmt.is_none() {
        let a = match render(first) {
            Ok(s) => s.len(),
            Err(e) => return die(prog, None, e),
        };
        let b = match render(last) {
            Ok(s) => s.len(),
            Err(e) => return die(prog, None, e),
        };
        a.max(b)
    } else {
        0
    };

    let mut out: Vec<u8> = Vec::new();
    for i in 0..=n {
        let v = first + (i as f64) * incr;
        if i > 0 {
            out.extend_from_slice(sep);
        }
        let s = match render(v) {
            Ok(s) => s,
            Err(e) => return die(prog, None, e),
        };
        let s = if width > 0 { pad(&s, width, false, true) } else { s };
        out.extend_from_slice(s.as_bytes());
    }
    if n >= 0 {
        out.push(b'\n');
    }
    textio::out(&out);
    0
}

/// The clap command — the single source of `seq`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("seq")
        .version("0.1.0")
        .about("Print numbers from FIRST to LAST, in steps of INCREMENT.")
        .override_usage("seq [OPTION]... LAST\n       seq [OPTION]... FIRST LAST\n       seq [OPTION]... FIRST INCREMENT LAST")
        .allow_negative_numbers(true)
        .arg(Arg::new("equal-width").short('w').long("equal-width").action(ArgAction::SetTrue).help("equalize width by padding with leading zeroes"))
        .arg(Arg::new("separator").short('s').long("separator").num_args(1).value_name("STRING").help("use STRING to separate numbers (default: \\n)"))
        .arg(Arg::new("format").short('f').long("format").num_args(1).value_name("FORMAT").help("use printf style floating-point FORMAT (%f/%e/%g)"))
        .arg(Arg::new("OPERAND").action(ArgAction::Append).num_args(0..=3).help("FIRST, INCREMENT, LAST (FIRST and INCREMENT default to 1)"))
        .after_help(
            "Prints FIRST, FIRST+INCREMENT, ... up to LAST. FIRST and INCREMENT default to 1. A \
             trailing newline is always emitted. -f accepts %f/%e/%g with flags, width, and \
             precision; -f and -w are mutually exclusive. Integer operands use exact i64 \
             arithmetic; any non-integer operand (or -f) switches to f64 computed as \
             `first + i*incr` to avoid drift. With no -f, fractional digits are derived from the \
             operands.",
        )
}

/// `seq [OPTION]... [FIRST [INCREMENT]] LAST`. Returns the exit status (0 success; 1 on a bad
/// operand or format).
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        // clap prints help/usage/version itself; mirror its exit code (0 for --help/--version).
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };
    let prog = "seq";

    let wide = m.get_flag("equal-width");
    let sep_owned: Option<Vec<u8>> = m.get_one::<String>("separator").map(|s| s.as_bytes().to_vec());
    let fmt: Option<Vec<u8>> = m.get_one::<String>("format").map(|s| s.as_bytes().to_vec());
    let nums: Vec<&[u8]> = m
        .get_many::<String>("OPERAND")
        .map(|v| v.map(|s| s.as_bytes()).collect())
        .unwrap_or_default();

    if fmt.is_some() && wide {
        return die(
            prog,
            None,
            "format string may not be specified when printing equal-width strings",
        );
    }

    let sep_b: &[u8] = match &sep_owned {
        Some(s) => s,
        None => b"\n",
    };
    let float_mode = fmt.is_some() || nums.iter().any(|t| is_floaty(t));

    if !float_mode {
        let mut parsed: Vec<i64> = Vec::with_capacity(nums.len());
        for t in &nums {
            match parse_i64(t) {
                Some(v) => parsed.push(v),
                None => return die(prog, Some(t), "invalid argument"),
            }
        }
        let (first, incr, last) = match parsed.len() {
            1 => (1, 1, parsed[0]),
            2 => (parsed[0], 1, parsed[1]),
            3 => (parsed[0], parsed[1], parsed[2]),
            _ => return die(prog, None, "usage: seq [-w] [-s sep] [first [incr]] last"),
        };
        if incr == 0 {
            return die(prog, None, "increment must not be zero");
        }
        return int_path(first, incr, last, sep_b, wide);
    }

    let mut parsed: Vec<f64> = Vec::with_capacity(nums.len());
    for t in &nums {
        match parse_f64(t) {
            Some(v) => parsed.push(v),
            None => return die(prog, Some(t), "invalid floating point argument"),
        }
    }
    let (first, incr, last) = match parsed.len() {
        1 => (1.0, 1.0, parsed[0]),
        2 => (parsed[0], 1.0, parsed[1]),
        3 => (parsed[0], parsed[1], parsed[2]),
        _ => return die(prog, None, "usage: seq [-w] [-s sep] [-f fmt] [first [incr]] last"),
    };
    // Derived precision (no -f): the max fractional digits among the operands.
    let prec = nums.iter().map(|t| frac_digits(t)).max().unwrap_or(0);

    float_path(prog, (first, incr, last), sep_b, wide, fmt.as_deref(), prec)
}
