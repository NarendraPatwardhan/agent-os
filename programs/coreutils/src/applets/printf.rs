//! `printf FORMAT [ARG]...` — format and print data.
//!
//! Supports:
//!   * backslash escapes `\a \b \f \n \r \t \v \\`, octal `\NNN`/`\0NNN`, hex `\xHH`, Unicode
//!     `\uHHHH`/`\UHHHHHHHH`, and `\c` (stop all output);
//!   * conversions `%s %b %c %d %i %u %o %x %X %%` with flags (`- + space 0 #`), a field width,
//!     and a `.precision`, each of which may be `*` (taken from an argument). `%b` interprets
//!     escapes in its argument.
//!
//! Like GNU, FORMAT is reused while arguments remain; missing arguments are treated as empty / 0,
//! and a non-numeric argument to a numeric conversion is a diagnostic (exit 1) while still
//! printing 0. `\n` is a bare LF (the terminal adds CR via ONLCR).
//!
//! Flags (via clap — the help mandate): only `--help`/`--version`. FORMAT and the ARGs are POSIX
//! operands handled by this applet's own logic (clap is NOT run over them), so a leading `%` or a
//! `-`-prefixed ARG passes straight through. clap renders `--help`/`--version`, recognized only
//! as the FIRST argument (like `echo`) — otherwise `--help` is treated as FORMAT literally.
//!
//! Deviations from GNU `printf`: `--help`/`--version` are honored only as the first argument (as
//! above); float conversions (`%f`, `%e`, `%g`, `%a`) are out of this subset and pass through
//! verbatim rather than formatting a number.
//!
//! Exit status: `0` success; `1` if a numeric conversion received a non-numeric argument.
//!
//! Ported from memcontainers' `programs::printf`. **`printf_render` and its helpers below are
//! kept byte-identical with `bi_printf`/`printf_render` in memcontainers' `shcore::exec`** — do
//! not diverge them.

use alloc::vec::Vec;

use clap::Command;

use crate::prelude::*;

// ===== shared with memcontainers' shcore::exec — keep byte-identical =====

fn printf_push_radix(out: &mut Vec<u8>, mut v: u64, radix: u64, upper: bool) {
    const LOWER: &[u8; 16] = b"0123456789abcdef";
    const UPPER: &[u8; 16] = b"0123456789ABCDEF";
    let digits = if upper { UPPER } else { LOWER };
    let mut tmp = [0u8; 64];
    let mut i = tmp.len();
    if v == 0 {
        i -= 1;
        tmp[i] = b'0';
    }
    while v > 0 {
        i -= 1;
        tmp[i] = digits[(v % radix) as usize];
        v /= radix;
    }
    out.extend_from_slice(&tmp[i..]);
}

fn printf_hexval(c: u8) -> Option<u32> {
    match c {
        b'0'..=b'9' => Some((c - b'0') as u32),
        b'a'..=b'f' => Some((c - b'a' + 10) as u32),
        b'A'..=b'F' => Some((c - b'A' + 10) as u32),
        _ => None,
    }
}

fn printf_push_utf8(out: &mut Vec<u8>, cp: u32) {
    if cp < 0x80 {
        out.push(cp as u8);
    } else if cp < 0x800 {
        out.push(0xC0 | (cp >> 6) as u8);
        out.push(0x80 | (cp & 0x3f) as u8);
    } else if cp < 0x10000 {
        out.push(0xE0 | (cp >> 12) as u8);
        out.push(0x80 | ((cp >> 6) & 0x3f) as u8);
        out.push(0x80 | (cp & 0x3f) as u8);
    } else {
        out.push(0xF0 | (cp >> 18) as u8);
        out.push(0x80 | ((cp >> 12) & 0x3f) as u8);
        out.push(0x80 | ((cp >> 6) & 0x3f) as u8);
        out.push(0x80 | (cp & 0x3f) as u8);
    }
}

/// Decode one backslash escape at `s[i]` (where `s[i] == b'\\'`), pushing its byte(s) to `out`.
/// Returns `(next_index, stop)`; `stop` is true for `\c`.
fn printf_escape_at(s: &[u8], i: usize, out: &mut Vec<u8>) -> (usize, bool) {
    if i + 1 >= s.len() {
        out.push(b'\\');
        return (i + 1, false);
    }
    let n = s[i + 1];
    match n {
        b'a' => (i + 2, false_push(out, 7)),
        b'b' => (i + 2, false_push(out, 8)),
        b'f' => (i + 2, false_push(out, 12)),
        b'n' => (i + 2, false_push(out, b'\n')),
        b'r' => (i + 2, false_push(out, b'\r')),
        b't' => (i + 2, false_push(out, b'\t')),
        b'v' => (i + 2, false_push(out, 11)),
        b'\\' => (i + 2, false_push(out, b'\\')),
        b'c' => (i + 2, true),
        b'x' => {
            let mut j = i + 2;
            let mut val = 0u32;
            let mut cnt = 0;
            while j < s.len() && cnt < 2 {
                match printf_hexval(s[j]) {
                    Some(h) => {
                        val = val * 16 + h;
                        j += 1;
                        cnt += 1;
                    }
                    None => break,
                }
            }
            if cnt == 0 {
                out.push(b'\\');
                out.push(b'x');
                (i + 2, false)
            } else {
                out.push((val & 0xff) as u8);
                (j, false)
            }
        }
        b'u' | b'U' => {
            let max = if n == b'u' { 4 } else { 8 };
            let mut j = i + 2;
            let mut val = 0u32;
            let mut cnt = 0;
            while j < s.len() && cnt < max {
                match printf_hexval(s[j]) {
                    Some(h) => {
                        val = val * 16 + h;
                        j += 1;
                        cnt += 1;
                    }
                    None => break,
                }
            }
            if cnt == 0 {
                out.push(b'\\');
                out.push(n);
                (i + 2, false)
            } else {
                printf_push_utf8(out, val);
                (j, false)
            }
        }
        b'0' => {
            // \0NNN — up to three octal digits after the 0.
            let mut j = i + 2;
            let mut val = 0u32;
            let mut cnt = 0;
            while j < s.len() && cnt < 3 && (b'0'..=b'7').contains(&s[j]) {
                val = val * 8 + (s[j] - b'0') as u32;
                j += 1;
                cnt += 1;
            }
            out.push((val & 0xff) as u8);
            (j, false)
        }
        b'1'..=b'7' => {
            // \NNN — this digit plus up to two more octal digits.
            let mut j = i + 1;
            let mut val = 0u32;
            let mut cnt = 0;
            while j < s.len() && cnt < 3 && (b'0'..=b'7').contains(&s[j]) {
                val = val * 8 + (s[j] - b'0') as u32;
                j += 1;
                cnt += 1;
            }
            out.push((val & 0xff) as u8);
            (j, false)
        }
        other => {
            out.push(b'\\');
            out.push(other);
            (i + 2, false)
        }
    }
}

/// Push `b` and return `false` (a helper so escape arms stay one-liners).
fn false_push(out: &mut Vec<u8>, b: u8) -> bool {
    out.push(b);
    false
}

/// Parse the integer value of a numeric argument: a leading `'`/`"` yields the next byte's value
/// (POSIX); otherwise an optionally-signed decimal. Sets `*err` if the argument has no digits or
/// trailing junk (GNU diagnoses but still uses the parsed prefix / 0).
fn printf_arg_num(a: &[u8], err: &mut bool) -> i64 {
    if a.is_empty() {
        return 0;
    }
    if a[0] == b'\'' || a[0] == b'"' {
        return a.get(1).copied().unwrap_or(0) as i64;
    }
    let neg = a[0] == b'-';
    let mut i = if neg || a[0] == b'+' { 1 } else { 0 };
    let start = i;
    let mut v: i64 = 0;
    while i < a.len() && a[i].is_ascii_digit() {
        v = v.saturating_mul(10).saturating_add((a[i] - b'0') as i64);
        i += 1;
    }
    if i == start || i != a.len() {
        *err = true;
    }
    if neg {
        -v
    } else {
        v
    }
}

/// Emit a numeric body (`digits`, preceded by `sign`, which may also be a `0x` prefix) honoring
/// precision (minimum digit count), width, and the `-`/`0` flags.
fn printf_emit_num(
    out: &mut Vec<u8>,
    sign: &[u8],
    digits: &[u8],
    width: usize,
    prec: Option<usize>,
    left: bool,
    zero: bool,
) {
    let mut d: Vec<u8> = Vec::new();
    if let Some(p) = prec {
        if p > digits.len() {
            d.resize(p - digits.len(), b'0');
        }
    }
    d.extend_from_slice(digits);
    let content = sign.len() + d.len();
    let pad = width.saturating_sub(content);
    if left {
        out.extend_from_slice(sign);
        out.extend_from_slice(&d);
        out.resize(out.len() + pad, b' ');
    } else if zero && prec.is_none() {
        out.extend_from_slice(sign);
        out.resize(out.len() + pad, b'0');
        out.extend_from_slice(&d);
    } else {
        out.resize(out.len() + pad, b' ');
        out.extend_from_slice(sign);
        out.extend_from_slice(&d);
    }
}

/// Emit a string body honoring width and the `-` flag (the `0` flag never applies to strings).
fn printf_emit_str(out: &mut Vec<u8>, body: &[u8], width: usize, left: bool) {
    let pad = width.saturating_sub(body.len());
    if left {
        out.extend_from_slice(body);
        out.resize(out.len() + pad, b' ');
    } else {
        out.resize(out.len() + pad, b' ');
        out.extend_from_slice(body);
    }
}

/// Render `fmt` once, consuming arguments from `args` starting at `*ai`. Returns `true` if `\c`
/// was seen (caller stops entirely). `*err` records a numeric conversion error.
fn printf_render(
    fmt: &[u8],
    args: &[&[u8]],
    ai: &mut usize,
    out: &mut Vec<u8>,
    err: &mut bool,
) -> bool {
    let mut i = 0;
    while i < fmt.len() {
        let c = fmt[i];
        if c == b'\\' {
            let (ni, stop) = printf_escape_at(fmt, i, out);
            i = ni;
            if stop {
                return true;
            }
            continue;
        }
        if c != b'%' || i + 1 >= fmt.len() {
            out.push(c);
            i += 1;
            continue;
        }
        // A `%` directive.
        i += 1;
        if fmt[i] == b'%' {
            out.push(b'%');
            i += 1;
            continue;
        }
        let spec_start = i;
        // Flags.
        let (mut left, mut plus, mut space, mut zero, mut hash) = (false, false, false, false, false);
        while i < fmt.len() {
            match fmt[i] {
                b'-' => left = true,
                b'+' => plus = true,
                b' ' => space = true,
                b'0' => zero = true,
                b'#' => hash = true,
                b'\'' => {} // grouping flag: ignored (C locale)
                _ => break,
            }
            i += 1;
        }
        // Width (number or `*`).
        let mut width: usize = 0;
        if i < fmt.len() && fmt[i] == b'*' {
            i += 1;
            let w = printf_arg_num(args.get(*ai).copied().unwrap_or(b""), err);
            *ai += 1;
            if w < 0 {
                left = true;
                width = (-w) as usize;
            } else {
                width = w as usize;
            }
        } else {
            while i < fmt.len() && fmt[i].is_ascii_digit() {
                width = width * 10 + (fmt[i] - b'0') as usize;
                i += 1;
            }
        }
        // Precision (`.` then number or `*`).
        let mut prec: Option<usize> = None;
        if i < fmt.len() && fmt[i] == b'.' {
            i += 1;
            if i < fmt.len() && fmt[i] == b'*' {
                i += 1;
                let p = printf_arg_num(args.get(*ai).copied().unwrap_or(b""), err);
                *ai += 1;
                prec = if p < 0 { None } else { Some(p as usize) };
            } else {
                let mut p = 0usize;
                while i < fmt.len() && fmt[i].is_ascii_digit() {
                    p = p * 10 + (fmt[i] - b'0') as usize;
                    i += 1;
                }
                prec = Some(p);
            }
        }
        // Skip C length modifiers (no effect here).
        while i < fmt.len() && matches!(fmt[i], b'l' | b'h' | b'L' | b'q' | b'j' | b'z' | b't') {
            i += 1;
        }
        if i >= fmt.len() {
            // Trailing incomplete directive: emit verbatim.
            out.push(b'%');
            out.extend_from_slice(&fmt[spec_start..i]);
            break;
        }
        let conv = fmt[i];
        i += 1;
        let arg = args.get(*ai).copied().unwrap_or(b"");
        match conv {
            b's' => {
                let body = match prec {
                    Some(p) => &arg[..p.min(arg.len())],
                    None => arg,
                };
                printf_emit_str(out, body, width, left);
                *ai += 1;
            }
            b'b' => {
                let mut decoded: Vec<u8> = Vec::new();
                let mut j = 0;
                let mut stop = false;
                while j < arg.len() {
                    if arg[j] == b'\\' {
                        let (nj, st) = printf_escape_at(arg, j, &mut decoded);
                        j = nj;
                        if st {
                            stop = true;
                            break;
                        }
                    } else {
                        decoded.push(arg[j]);
                        j += 1;
                    }
                }
                let body = match prec {
                    Some(p) => &decoded[..p.min(decoded.len())],
                    None => &decoded[..],
                };
                printf_emit_str(out, body, width, left);
                *ai += 1;
                if stop {
                    return true;
                }
            }
            b'c' => {
                let one = &arg[..arg.len().min(1)];
                printf_emit_str(out, one, width, left);
                *ai += 1;
            }
            b'd' | b'i' => {
                let v = printf_arg_num(arg, err);
                let mut digits: Vec<u8> = Vec::new();
                if !(prec == Some(0) && v == 0) {
                    let mag = (v as i128).unsigned_abs() as u64;
                    printf_push_radix(&mut digits, mag, 10, false);
                }
                let sign: &[u8] = if v < 0 {
                    b"-"
                } else if plus {
                    b"+"
                } else if space {
                    b" "
                } else {
                    b""
                };
                printf_emit_num(out, sign, &digits, width, prec, left, zero);
                *ai += 1;
            }
            b'u' | b'o' | b'x' | b'X' => {
                let v = printf_arg_num(arg, err) as u64;
                let mut digits: Vec<u8> = Vec::new();
                let radix = match conv {
                    b'o' => 8,
                    b'u' => 10,
                    _ => 16,
                };
                if !(prec == Some(0) && v == 0) {
                    printf_push_radix(&mut digits, v, radix, conv == b'X');
                }
                let mut sign: Vec<u8> = Vec::new();
                if hash && v != 0 {
                    match conv {
                        b'o' => {
                            if digits.first() != Some(&b'0') {
                                sign.push(b'0');
                            }
                        }
                        b'x' => sign.extend_from_slice(b"0x"),
                        b'X' => sign.extend_from_slice(b"0X"),
                        _ => {}
                    }
                }
                printf_emit_num(out, &sign, &digits, width, prec, left, zero);
                *ai += 1;
            }
            _ => {
                // Unknown conversion (e.g. %f): emit verbatim.
                out.push(b'%');
                out.extend_from_slice(&fmt[spec_start..i]);
            }
        }
    }
    false
}

// ===== end shared block =====

/// The clap command — the documented surface AND the `--help`/`--version` source. (FORMAT/ARGs
/// are parsed by this applet's own logic to keep POSIX `printf` semantics; clap is for help.)
fn command() -> Command {
    Command::new("printf")
        .version("0.1.0")
        .about("Print ARGUMENT(s) according to FORMAT, or execute according to OPTION.")
        .override_usage("printf FORMAT [ARGUMENT]...")
        .after_help(
            "FORMAT controls the output as in C printf. Interpreted sequences are:\n  \\\"  \
             double quote        \\\\  backslash\n  \\a  alert (BEL)         \\b  backspace\n  \
             \\c  produce no further output    \\f  form feed\n  \\n  new line            \\r  \
             carriage return\n  \\t  horizontal tab      \\v  vertical tab\n  \\NNN octal value \
             (1-3 digits)   \\0NNN octal value (1-3 digits)\n  \\xHH hex value (1-2 digits)\n  \
             \\uHHHH / \\UHHHHHHHH  Unicode code point\nand all C format specifications ending \
             with one of:\n  %s  string             %b  string with \\ escapes interpreted\n  \
             %c  first character    %d, %i  signed decimal\n  %u  unsigned decimal   %o  \
             unsigned octal\n  %x, %X  unsigned hex   %%  a literal %\nEach accepts the flags \
             `- + space 0 #`, a field width, and a .precision; width and precision may be `*` \
             (taken from an argument). FORMAT is reused while arguments remain. A non-numeric \
             argument to a numeric conversion is diagnosed (exit 1) but still prints 0.\n\
             Deviations: --help/--version are recognized only as the FIRST argument; float \
             conversions (%f/%e/%g/%a) pass through verbatim.",
        )
}

/// `printf FORMAT [ARG]...`. Returns the exit status (0; 1 on a numeric-conversion error).
pub fn uumain(args: impl uucore::Args) -> i32 {
    // POSIX printf: FORMAT and the ARGs are literal operands (a `-`-prefixed ARG or a leading `%`
    // must pass through), so do NOT run clap's parser over them. Honor only a leading
    // --help/--version (matching memcontainers' `wants_help_first`); clap renders both. Interior
    // empty arguments are preserved (`printf '%s' ''`), matching the shell `printf` builtin twin.
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

    if argv.len() < 2 {
        eprintln!("printf: usage: printf FORMAT [ARG...]");
        return 1;
    }
    let fmt: &[u8] = &argv[1];
    let args_slice: Vec<&[u8]> = argv[2..].iter().map(|v| v.as_slice()).collect();

    let mut out: Vec<u8> = Vec::new();
    let mut ai = 0usize;
    let mut err = false;
    loop {
        let before = ai;
        let stop = printf_render(fmt, &args_slice, &mut ai, &mut out, &mut err);
        if stop {
            break;
        }
        // Reuse the format only while it keeps consuming arguments.
        if ai >= args_slice.len() || ai == before {
            break;
        }
    }
    // Emit the fully-rendered output via the facade (one write to stdout, like the source).
    textio::out(&out);
    if err {
        1
    } else {
        0
    }
}
