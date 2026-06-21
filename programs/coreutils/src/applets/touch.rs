//! `touch [-acm] [-r REF] [-t STAMP] [-d DATETIME] FILE...` — create files and/or update their
//! access/modify times. With no time option the times are set to now; `-r`/`--reference` copies
//! them from a reference file; `-t` takes a POSIX `[[CC]YY]MMDDhhmm[.ss]` stamp; `-d`/`--date`
//! takes a `YYYY-MM-DD[ HH:MM[:SS]]` datetime (also `T` as the date/time separator).
//! `-a`/`-m` restrict the change to atime/mtime (giving neither, or both, sets both); `-c`/
//! `--no-create` skips creating a missing file. Backed by `rt::utimes` over `//sysroot`.
//!
//! Time precedence: `-t`/`-d`, then `-r`, else now. Args+help are via clap; a missing file is
//! created with `rt::open(.., O_WRITE|O_CREATE)`, and the times are read via `rt::stat` /
//! `rt::time_realtime`. The civil-date arithmetic (Howard Hinnant's branch-free
//! `days_from_civil`) is transcribed here so the stamps map to ms-since-epoch.
//!
//! Deviations from GNU touch: `-d` accepts a useful ISO subset only — NOT GNU's full free-form
//! date parser; `--time=atime`/`--time=mtime` keyword forms are NOT implemented (use `-a`/`-m`);
//! `-h`/`--no-dereference` is NOT implemented.
//!
//! Exit status: `0` every file created/updated; `1` a file could not be created or updated, or a
//! date/path was invalid; `2` a usage error (clap).
//!
//! Ported from memcontainers' `programs::touch`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use sysroot as rt;

/// Gregorian (year, month, day) from days since 1970-01-01 — Howard Hinnant's branch-free
/// `civil_from_days` (public domain). Valid for any in-range date.
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

/// Days since 1970-01-01 for a Gregorian (y, m, d) — the inverse of `civil_from_days` (Hinnant's
/// `days_from_civil`).
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let m = m as i64;
    let d = d as i64;
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = y - era * 400; // [0, 399]
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146_097 + doe - 719_468
}

/// Milliseconds since the Unix epoch for a UTC date-time (no validation beyond the calendar
/// arithmetic).
fn epoch_ms(y: i64, mo: u32, d: u32, hh: u32, mi: u32, ss: u32) -> i64 {
    (days_from_civil(y, mo, d) * 86_400 + hh as i64 * 3600 + mi as i64 * 60 + ss as i64) * 1000
}

/// Parse exactly two ASCII digits.
fn two(s: &[u8]) -> Option<u32> {
    if s.len() == 2 && s.iter().all(|b| b.is_ascii_digit()) {
        Some(((s[0] - b'0') * 10 + (s[1] - b'0')) as u32)
    } else {
        None
    }
}

/// Parse a POSIX `-t` stamp: `[[CC]YY]MMDDhhmm[.ss]`. Missing year ⇒ `now_year`.
fn parse_posix(s: &[u8], now_year: i64) -> Option<i64> {
    let (main, ss) = match s.iter().position(|&b| b == b'.') {
        Some(i) => (&s[..i], two(&s[i + 1..])?),
        None => (s, 0),
    };
    let (year, rest) = match main.len() {
        8 => (now_year, main),
        10 => {
            let yy = two(&main[..2])? as i64;
            (if yy >= 69 { 1900 + yy } else { 2000 + yy }, &main[2..])
        }
        12 => {
            let cc = two(&main[..2])? as i64;
            let yy = two(&main[2..4])? as i64;
            (cc * 100 + yy, &main[4..])
        }
        _ => return None,
    };
    if rest.len() != 8 {
        return None;
    }
    let mo = two(&rest[0..2])?;
    let d = two(&rest[2..4])?;
    let hh = two(&rest[4..6])?;
    let mi = two(&rest[6..8])?;
    Some(epoch_ms(year, mo, d, hh, mi, ss))
}

/// Parse a `-d` datetime: `YYYY-MM-DD`, optionally followed by ` ` or `T` and `HH:MM[:SS]`. (A
/// useful ISO subset, not GNU's full free-form parser.)
fn parse_iso(s: &[u8]) -> Option<i64> {
    let s = core::str::from_utf8(s).ok()?;
    let (date, time) = match s.find([' ', 'T']) {
        Some(i) => (&s[..i], Some(&s[i + 1..])),
        None => (s, None),
    };
    let mut dp = date.split('-');
    let y: i64 = dp.next()?.parse().ok()?;
    let mo: u32 = dp.next()?.parse().ok()?;
    let d: u32 = dp.next()?.parse().ok()?;
    if dp.next().is_some() {
        return None;
    }
    let (hh, mi, ss) = match time {
        None => (0, 0, 0),
        Some(t) => {
            let mut tp = t.split(':');
            let hh: u32 = tp.next()?.parse().ok()?;
            let mi: u32 = tp.next()?.parse().ok()?;
            let ss: u32 = tp.next().and_then(|x| x.parse().ok()).unwrap_or(0);
            (hh, mi, ss)
        }
    };
    Some(epoch_ms(y, mo, d, hh, mi, ss))
}

/// The source of the new timestamps.
enum Src {
    Now,
    At(i64),
    Ref(i64, i64), // (atime, mtime)
}

/// The clap command — the single source of `touch`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("touch")
        .about("Update the access and modification times of each FILE to the current time.")
        .arg(Arg::new("atime").short('a').action(ArgAction::SetTrue).help("change only the access time"))
        .arg(Arg::new("mtime").short('m').action(ArgAction::SetTrue).help("change only the modification time"))
        .arg(Arg::new("no-create").short('c').long("no-create").action(ArgAction::SetTrue).help("do not create any files"))
        .arg(Arg::new("reference").short('r').long("reference").num_args(1).value_name("FILE").help("use this file's times instead of the current time"))
        .arg(Arg::new("stamp").short('t').num_args(1).value_name("STAMP").help("use [[CC]YY]MMDDhhmm[.ss] instead of the current time"))
        .arg(Arg::new("date").short('d').long("date").num_args(1).value_name("STRING").help("parse STRING (YYYY-MM-DD[ HH:MM[:SS]]) and use it instead of the current time"))
        .arg(Arg::new("FILE").action(ArgAction::Append).num_args(0..).help("the files to create and/or stamp"))
}

/// `touch [OPTION]... FILE...`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let no_create = m.get_flag("no-create");
    let only_a = m.get_flag("atime");
    let only_m = m.get_flag("mtime");
    let set_both = only_a == only_m; // both flags, or neither → set both
    let ops: Vec<&str> = m
        .get_many::<String>("FILE")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();
    if ops.is_empty() {
        eprintln!("touch: missing file operand");
        return 1;
    }

    // Resolve the timestamp source once (precedence: -t/-d, then -r, else now).
    let src = if let Some(t) = m.get_one::<String>("stamp") {
        let now = rt::time_realtime().unwrap_or(0);
        let (yr, _, _) = civil_from_days(now / 1000 / 86_400);
        match parse_posix(t.as_bytes(), yr) {
            Some(ms) => Src::At(ms),
            None => {
                eprintln!("touch: {}: invalid date format", t);
                return 1;
            }
        }
    } else if let Some(d) = m.get_one::<String>("date") {
        match parse_iso(d.as_bytes()) {
            Some(ms) => Src::At(ms),
            None => {
                eprintln!("touch: {}: invalid date format", d);
                return 1;
            }
        }
    } else if let Some(r) = m.get_one::<String>("reference") {
        match rt::stat(r) {
            Ok(s) => Src::Ref(s.atime, s.mtime),
            Err(e) => {
                eprintln!("touch: {}: {}", r, rt::strerror(e));
                return 1;
            }
        }
    } else {
        Src::Now
    };

    let mut rc = 0;
    for path in &ops {
        let existed = rt::stat(path).is_ok();
        if !existed {
            if no_create {
                continue; // -c: do not create a missing file
            }
            match rt::open(path, rt::O_WRITE | rt::O_CREATE) {
                Ok(fd) => rt::close(fd),
                Err(e) => {
                    eprintln!("touch: {}: {}", path, rt::strerror(e));
                    rc = 1;
                    continue;
                }
            }
        }

        // Pick the (atime, mtime) to set, preserving the untouched one under
        // `-a`/`-m`. `Now` with both → a NULL utimes (kernel fills both).
        let cur = rt::stat(path).ok();
        let (src_a, src_m) = match src {
            Src::Now => {
                let now = rt::time_realtime().unwrap_or(0);
                (now, now)
            }
            Src::At(t) => (t, t),
            Src::Ref(a, m) => (a, m),
        };
        let want = if matches!(src, Src::Now) && set_both {
            None // both → now, atomically, no clock read needed
        } else {
            let a = if set_both || only_a {
                src_a
            } else {
                cur.as_ref().map(|s| s.atime).unwrap_or(src_a)
            };
            let mm = if set_both || only_m {
                src_m
            } else {
                cur.as_ref().map(|s| s.mtime).unwrap_or(src_m)
            };
            Some((a, mm))
        };
        if let Err(e) = rt::utimes(path, want) {
            eprintln!("touch: {}: {}", path, rt::strerror(e));
            rc = 1;
        }
    }
    rc
}
