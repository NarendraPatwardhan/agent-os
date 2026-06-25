//! `stat [-c FMT | --format=FMT | --printf=FMT] FILE...` — display file metadata.
//!
//! HAND-WRITTEN applet (SYSTEMS.md): logic transcribed from memcontainers' `programs::stat`,
//! metadata read via raw `mc` (`rt::lstat`/`rt::readlink`) and emitted through the facade
//! (`textio::out`/`outln`); args + help via **clap**. The default multi-line form shows the
//! name, size, type, hard-link count, the permission bits (octal + symbolic), and the
//! modify/change/access times. A format string selects fields via `%`-directives:
//!   `%n` name · `%N` name (+ `-> target` for a symlink) · `%s` size · `%F` type ·
//!   `%f` raw mode (hex) · `%a` mode (octal) · `%A` mode (symbolic) · `%h` link count ·
//!   `%x %X` access time (human / epoch) · `%y %Y` modify · `%z %Z` change · `%%` a literal `%`.
//!
//! `-c`/`--format` append a newline after each file and take the format literally; `--printf`
//! interprets backslash escapes and adds no trailing newline (GNU).
//!
//! Deviations from GNU stat:
//!   - Owner/group/inode/device directives (`%u %g %U %G %i %d %t %T %o %b`) print `?`: that
//!     data is outside this VM's single-subject, inode-less model — exactly what GNU stat emits
//!     for an unknown field (no fake values). The default report shows no owner/group.
//!   - A symlink reports the link itself (lstat), with its target.
//!   - No `-L`/`--dereference`, `-f`/`--file-system`, `-t`/`--terse`.
//!   - Times render as `YYYY-MM-DD HH:MM:SS` (UTC; no tzdata in the guest), not the
//!     nanosecond/offset-bearing GNU form.
//!
//! Exit status: `0` success; `1` a FILE could not be stat'd; `2` a clap usage error.
//!
//! Ported from memcontainers' `programs::stat`.

use alloc::string::String;
use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

fn push_u64(out: &mut Vec<u8>, n: u64) {
    let mut tmp = [0u8; 20];
    let mut i = tmp.len();
    let mut v = n;
    if v == 0 {
        i -= 1;
        tmp[i] = b'0';
    }
    while v > 0 {
        i -= 1;
        tmp[i] = b'0' + (v % 10) as u8;
        v /= 10;
    }
    out.extend_from_slice(&tmp[i..]);
}

fn push_i64(out: &mut Vec<u8>, v: i64) {
    if v < 0 {
        out.push(b'-');
        push_u64(out, (v as i128).unsigned_abs() as u64);
    } else {
        push_u64(out, v as u64);
    }
}

/// Gregorian (year, month, day) from days since 1970-01-01 — Howard Hinnant's
/// branch-free `civil_from_days` (public domain). Transcribed from memcontainers' `cli`.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = (if z >= 0 { z } else { z - 146_096 }) / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32; // [1, 12]
    (y + i64::from(m <= 2), m, d)
}

/// Render permission bits as the `ls -l` string, e.g. `-rwxr-xr-x` / `drwxr-xr-x` /
/// `lrwxrwxrwx`. Transcribed from memcontainers' `cli::format_mode`.
fn format_mode(mode: u16, is_dir: bool, is_symlink: bool) -> String {
    let t = if is_symlink {
        'l'
    } else if is_dir {
        'd'
    } else {
        '-'
    };
    let bit = |mask: u16, ch: char| if mode & mask != 0 { ch } else { '-' };
    let mut s = String::with_capacity(10);
    s.push(t);
    for (r, w, x) in [
        (0o400, 0o200, 0o100),
        (0o040, 0o020, 0o010),
        (0o004, 0o002, 0o001),
    ] {
        s.push(bit(r, 'r'));
        s.push(bit(w, 'w'));
        s.push(bit(x, 'x'));
    }
    s
}

/// `YYYY-MM-DD HH:MM:SS` (UTC) for ms since the epoch — the `%y`/`%z`/`%x` field.
fn fmt_time_full(ms: i64) -> String {
    let ms = if ms < 0 { 0 } else { ms };
    let secs = ms / 1000;
    let days = secs / 86_400;
    let sod = secs % 86_400;
    let (y, m, d) = civil_from_days(days);
    alloc::format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
        y,
        m,
        d,
        sod / 3600,
        (sod / 60) % 60,
        sod % 60
    )
}

fn type_str(s: &rt::Stat) -> &'static [u8] {
    if s.is_dir {
        b"directory"
    } else if s.is_symlink {
        b"symbolic link"
    } else {
        b"regular file"
    }
}

/// Render one `%`-directive `conv` for `path`/`s` into `out`.
fn directive(out: &mut Vec<u8>, conv: u8, name: &[u8], path: &str, s: &rt::Stat) {
    match conv {
        b'n' => out.extend_from_slice(name),
        b'N' => {
            out.extend_from_slice(name);
            if s.is_symlink {
                let mut buf = [0u8; 1024];
                if let Ok(nn) = rt::readlink(path, &mut buf) {
                    out.extend_from_slice(b" -> ");
                    out.extend_from_slice(&buf[..nn.min(buf.len())]);
                }
            }
        }
        b's' => push_u64(out, s.size),
        b'F' => out.extend_from_slice(type_str(s)),
        b'f' => out.extend_from_slice(alloc::format!("{:x}", s.mode).as_bytes()),
        b'a' => out.extend_from_slice(alloc::format!("{:o}", s.mode & 0o7777).as_bytes()),
        b'A' => out.extend_from_slice(format_mode(s.mode, s.is_dir, s.is_symlink).as_bytes()),
        b'h' => push_u64(out, s.nlink as u64),
        b'x' => out.extend_from_slice(fmt_time_full(s.atime).as_bytes()),
        b'X' => push_i64(out, s.atime / 1000),
        b'y' => out.extend_from_slice(fmt_time_full(s.mtime).as_bytes()),
        b'Y' => push_i64(out, s.mtime / 1000),
        b'z' => out.extend_from_slice(fmt_time_full(s.ctime).as_bytes()),
        b'Z' => push_i64(out, s.ctime / 1000),
        // Outside our model (no owner/inode/device): GNU prints `?` for unknown.
        b'u' | b'g' | b'U' | b'G' | b'i' | b'd' | b't' | b'T' | b'o' | b'b' | b'B' => out.push(b'?'),
        other => {
            out.push(b'%');
            out.push(other);
        }
    }
}

/// Render a format string for one file. `escapes` interprets `\n` etc (`--printf`).
fn render_format(
    fmt: &[u8],
    name: &[u8],
    path: &str,
    s: &rt::Stat,
    escapes: bool,
    out: &mut Vec<u8>,
) {
    let mut i = 0;
    while i < fmt.len() {
        match fmt[i] {
            b'%' if i + 1 < fmt.len() => {
                directive(out, fmt[i + 1], name, path, s);
                i += 2;
            }
            b'\\' if escapes && i + 1 < fmt.len() => {
                i += 1;
                match fmt[i] {
                    b'n' => out.push(b'\n'),
                    b't' => out.push(b'\t'),
                    b'r' => out.push(b'\r'),
                    b'\\' => out.push(b'\\'),
                    b'"' => out.push(b'"'),
                    other => {
                        out.push(b'\\');
                        out.push(other);
                    }
                }
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
}

/// The default multi-line report.
fn default_report(o: &[u8], path: &str, s: &rt::Stat) {
    let mut line: Vec<u8> = Vec::new();
    line.extend_from_slice(b"  File: ");
    line.extend_from_slice(o);
    if s.is_symlink {
        let mut buf = [0u8; 1024];
        if let Ok(nn) = rt::readlink(path, &mut buf) {
            line.extend_from_slice(b" -> ");
            line.extend_from_slice(&buf[..nn.min(buf.len())]);
        }
    }
    textio::outln(&line);

    line.clear();
    line.extend_from_slice(b"  Size: ");
    push_u64(&mut line, s.size);
    line.extend_from_slice(b"\tLinks: ");
    push_u64(&mut line, s.nlink as u64);
    line.extend_from_slice(b"\tType: ");
    line.extend_from_slice(type_str(s));
    textio::outln(&line);

    line.clear();
    line.extend_from_slice(b"  Mode: ");
    line.extend_from_slice(alloc::format!("{:04o}", s.mode).as_bytes());
    line.extend_from_slice(b"/");
    line.extend_from_slice(format_mode(s.mode, s.is_dir, s.is_symlink).as_bytes());
    textio::outln(&line);

    for (label, t) in [
        (&b"Modify: "[..], s.mtime),
        (&b"Change: "[..], s.ctime),
        (&b"Access: "[..], s.atime),
    ] {
        line.clear();
        line.extend_from_slice(label);
        line.extend_from_slice(fmt_time_full(t).as_bytes());
        textio::outln(&line);
    }
}

/// The clap command — the single source of `stat`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("stat")
        .about("Display file or file system status.")
        .override_usage("stat [-c FMT | --format=FMT | --printf=FMT] FILE...")
        .after_help(
            "Format directives:\n  \
             %n name   %N name (+ `-> target` for a symlink)   %s size   %F type\n  \
             %f raw mode (hex)   %a mode (octal)   %A mode (symbolic)   %h link count\n  \
             %x %X access time (human / epoch)   %y %Y modify   %z %Z change   %% a literal %\n  \
             %u %g %U %G %i %d %t %T %o %b   always print `?` (outside this VM's model)",
        )
        .arg(
            Arg::new("format")
                .short('c')
                .long("format")
                .num_args(1)
                .value_name("FMT")
                .help("use FMT, appending a newline after each file (literal FMT)"),
        )
        .arg(
            Arg::new("printf")
                .long("printf")
                .num_args(1)
                .value_name("FMT")
                .help("use FMT, interpreting backslash escapes, with no trailing newline"),
        )
        .arg(
            Arg::new("FILE")
                .action(ArgAction::Append)
                .num_args(1..)
                .help("files whose metadata to display"),
        )
}

/// `stat [OPTION] FILE...`. Returns the exit status.
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
    if ops.is_empty() {
        eprintln!("stat: missing operand");
        return 2;
    }

    // `--printf` interprets escapes and adds no newline; `-c`/`--format` is
    // literal with a trailing newline.
    let printf = m.get_one::<String>("printf").map(String::as_bytes);
    let format = m.get_one::<String>("format").map(String::as_bytes);
    let (fmt, escapes, newline): (Option<&[u8]>, bool, bool) = match (printf, format) {
        (Some(p), _) => (Some(p), true, false),
        (None, Some(f)) => (Some(f), false, true),
        (None, None) => (None, false, false),
    };

    let mut rc = 0;
    for path in &ops {
        let o = path.as_bytes();
        match rt::lstat(path) {
            Ok(s) => match fmt {
                Some(f) => {
                    let mut out: Vec<u8> = Vec::new();
                    render_format(f, o, path, &s, escapes, &mut out);
                    if newline {
                        out.push(b'\n');
                    }
                    textio::out(&out);
                }
                None => default_report(o, path, &s),
            },
            Err(e) => {
                eprintln!("stat: {}: {}", path, rt::strerror(e));
                rc = 1;
            }
        }
    }
    rc
}
