//! `ls [-a] [-l] [-h] [-d] [-R] [-S] [-r] [-t] [-1] [-F] [FILE...]` — list files and directories.
//!
//! HAND-WRITTEN applet (VISION §16.3): logic transcribed from memcontainers' `programs::ls`,
//! the directory walk and metadata read over the **facade** (`fsutil::list`/`join`) + raw `mc`
//! (`rt::lstat`/`rt::stat`/`rt::readlink`); args + help via **clap**. Hides dotfiles unless `-a`;
//! marks directories with `/` and symlinks with `@`; sorts by name (or size with `-S`, or mtime
//! with `-t`), reversible with `-r`; `-R` recurses; `-l` is the long form (mode + link count +
//! size + mtime + name, and `name -> target` for a symlink); `-h` renders sizes human-readable
//! (1024-based, in `-l`); `-d` lists a directory itself instead of its contents. `-1`/`-F` are
//! accepted.
//!
//! TIER: **read-only**. `ls` only reads (readdir + lstat/stat/readlink) — it never mutates,
//! spawns, or reaches the network — so it belongs at `read-only` (memcontainers over-stamped it
//! `full`; the §16.4 attestation confirms read-only covers every syscall it imports).
//!
//! Deviations from POSIX/GNU ls:
//!   - Help is `--help` only; `-h` means human-readable sizes (as in GNU).
//!   - Long options (`--all`, `--long`, …) are NOT supported.
//!   - There is no owner/group column: the VM has a single subject.
//!   - `-i` (inode numbers) is intentionally unimplemented — the VFS stat ABI carries no inode,
//!     and a fabricated column would be misleading.
//!   - Output is always one-per-line; `-1` is accepted but has no extra effect, and there is no
//!     column/`-C`/`-x` multi-column layout.
//!
//! Exit status: `0` success; `1` a FILE could not be accessed; `2` a clap usage error.
//!
//! Ported from memcontainers' `programs::ls`.

use alloc::format;
use alloc::string::String;
use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

/// Gregorian (year, month, day) from days since 1970-01-01 — Howard Hinnant's branch-free
/// `civil_from_days` (public domain). Transcribed from memcontainers' `cli`.
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

/// Render permission bits as the `ls -l` string (`-rwxr-xr-x` / `drwxr-xr-x` / `lrwxrwxrwx`).
/// Transcribed from memcontainers' `cli::format_mode`.
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

/// Render a timestamp (ms since the Unix epoch) as `YYYY-MM-DD HH:MM` (UTC, long-iso style — no
/// tzdata in the guest). Transcribed from memcontainers' `cli::format_time`.
fn format_time(ms: i64) -> String {
    let ms = if ms < 0 { 0 } else { ms };
    let total_secs = ms / 1000;
    let days = total_secs / 86_400;
    let sod = total_secs % 86_400;
    let (y, m, d) = civil_from_days(days);
    format!("{:04}-{:02}-{:02} {:02}:{:02}", y, m, d, sod / 3600, (sod / 60) % 60)
}

struct Opts {
    all: bool,
    long: bool,
    recursive: bool,
    by_size: bool,
    by_time: bool,
    reverse: bool,
    human: bool,
    dir_only: bool,
}

/// Human-readable byte count (1024-based), GNU `-h` style: a bare number under 1 KiB, else one
/// decimal when the scaled value is < 10 (`1.0K`, `9.8K`), an integer otherwise (`12K`, `1.0M`),
/// each rounded up. Integer math throughout.
fn human(size: u64) -> String {
    if size < 1024 {
        return format!("{size}");
    }
    const SUF: [&str; 6] = ["K", "M", "G", "T", "P", "E"];
    let mut unit = 0usize;
    let mut pow: u128 = 1;
    while unit < 5 && (size as u128) >= pow * 1024 * 1024 {
        pow *= 1024;
        unit += 1;
    }
    // `pow` = 1024^unit; size now in [pow*1024, pow*1024*1024) → scaled in K..
    let scaled_pow = pow * 1024;
    let scaled_int = (size as u128) / scaled_pow;
    let suffix = SUF[unit];
    if scaled_int < 10 {
        let tenths = ((size as u128) * 10).div_ceil(scaled_pow);
        let whole = tenths / 10;
        let frac = tenths % 10;
        if whole >= 10 {
            format!("{whole}{suffix}")
        } else {
            format!("{whole}.{frac}{suffix}")
        }
    } else {
        let whole = (size as u128).div_ceil(scaled_pow);
        format!("{whole}{suffix}")
    }
}

/// A listed entry, with no-follow (lstat) metadata so symlinks show as symlinks.
struct Entry {
    name: String,
    is_dir: bool,
    is_symlink: bool,
    size: u64,
    nlink: u32,
    mode: u16,
    mtime: i64,
    target: String,
}

fn out(s: &str) {
    let _ = rt::write_all(rt::STDOUT, s.as_bytes());
}

/// Gather a path's no-follow metadata (and symlink target) into an `Entry`.
fn entry_of(name: String, path: &str) -> Entry {
    let st = rt::lstat(path).ok();
    let is_dir = st.as_ref().map(|s| s.is_dir).unwrap_or(false);
    let is_symlink = st.as_ref().map(|s| s.is_symlink).unwrap_or(false);
    let size = st.as_ref().map(|s| s.size).unwrap_or(0);
    let nlink = st.as_ref().map(|s| s.nlink).unwrap_or(1);
    let mode = st.as_ref().map(|s| s.mode).unwrap_or(0);
    let mtime = st.as_ref().map(|s| s.mtime).unwrap_or(0);
    let target = if is_symlink {
        let mut buf = [0u8; 1024];
        rt::readlink(path, &mut buf)
            .ok()
            .and_then(|n| core::str::from_utf8(&buf[..n.min(buf.len())]).ok())
            .map(String::from)
            .unwrap_or_default()
    } else {
        String::new()
    };
    Entry {
        name,
        is_dir,
        is_symlink,
        size,
        nlink,
        mode,
        mtime,
        target,
    }
}

fn print_entry(e: &Entry, long: bool, human_size: bool) {
    if long {
        let mode = format_mode(e.mode, e.is_dir, e.is_symlink);
        let time = format_time(e.mtime);
        let size = if human_size {
            human(e.size)
        } else {
            format!("{}", e.size)
        };
        if e.is_symlink {
            out(&format!(
                "{mode} {:>3} {size:>8} {time} {} -> {}\n",
                e.nlink, e.name, e.target
            ));
        } else {
            let slash = if e.is_dir { "/" } else { "" };
            out(&format!(
                "{mode} {:>3} {size:>8} {time} {}{}\n",
                e.nlink, e.name, slash
            ));
        }
    } else {
        let mark = if e.is_dir {
            "/"
        } else if e.is_symlink {
            "@"
        } else {
            ""
        };
        out(&format!("{}{}\n", e.name, mark));
    }
}

fn list_dir(dir: &str, o: &Opts, rc: &mut i32) {
    let names = match fsutil::list(dir) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("ls: {}: {}", dir, rt::strerror(e));
            *rc = 1;
            return;
        }
    };
    let mut entries: Vec<Entry> = Vec::new();
    for name in names {
        if !o.all && name.starts_with('.') {
            continue;
        }
        let path = fsutil::join(dir, &name);
        entries.push(entry_of(name, &path));
    }
    if o.by_time {
        // Newest first (GNU `-t`), ties broken by name.
        entries.sort_by(|a, b| b.mtime.cmp(&a.mtime).then(a.name.cmp(&b.name)));
    } else if o.by_size {
        entries.sort_by(|a, b| b.size.cmp(&a.size).then(a.name.cmp(&b.name)));
    } else {
        entries.sort_by(|a, b| a.name.cmp(&b.name));
    }
    if o.reverse {
        entries.reverse();
    }

    for e in &entries {
        print_entry(e, o.long, o.human);
    }
    if o.recursive {
        for e in &entries {
            if e.is_dir {
                let sub = fsutil::join(dir, &e.name);
                out("\n");
                out(&sub);
                out(":\n");
                list_dir(&sub, o, rc);
            }
        }
    }
}

/// The clap command — the single source of `ls`'s flag surface AND its `--help`. `-h` is
/// human-readable sizes (POSIX/GNU), so clap's default `-h`/`--help` is disabled and a long-only
/// `--help` added.
fn command() -> Command {
    Command::new("ls")
        .about("List information about the FILEs (the current directory by default).")
        .override_usage("ls [-alhdRSrt1F] [FILE]...")
        .disable_help_flag(true)
        .after_help(
            "Without -l, directories are marked `/` and symlinks `@`. In -l, a symlink shows as\n\
             `name -> target`. With more than one directory (or with -R), each listing is preceded\n\
             by a `NAME:` header. There is no owner/group column (single subject); -i is\n\
             intentionally unimplemented (no inode in the stat ABI). Output is always one entry\n\
             per line.",
        )
        .arg(Arg::new("help").long("help").action(ArgAction::Help).help("display this help and exit"))
        .arg(Arg::new("all").short('a').action(ArgAction::SetTrue).help("do not hide entries starting with `.`"))
        .arg(Arg::new("long").short('l').action(ArgAction::SetTrue).help("long format: mode, link count, size, mtime, name"))
        .arg(Arg::new("human").short('h').action(ArgAction::SetTrue).help("with -l, print sizes human-readable (1024-based)"))
        .arg(Arg::new("dir").short('d').action(ArgAction::SetTrue).help("list directories themselves, not their contents"))
        .arg(Arg::new("recursive").short('R').action(ArgAction::SetTrue).help("list subdirectories recursively"))
        .arg(Arg::new("by-size").short('S').action(ArgAction::SetTrue).help("sort by file size, largest first"))
        .arg(Arg::new("reverse").short('r').action(ArgAction::SetTrue).help("reverse order while sorting"))
        .arg(Arg::new("by-time").short('t').action(ArgAction::SetTrue).help("sort by modification time, newest first"))
        .arg(Arg::new("one").short('1').action(ArgAction::SetTrue).help("list one entry per line (accepted; always one-per-line)"))
        .arg(Arg::new("classify").short('F').action(ArgAction::SetTrue).help("append an indicator (`/` for dirs, `@` for symlinks)"))
        .arg(Arg::new("FILE").action(ArgAction::Append).num_args(0..).help("files or directories to list (default `.`)"))
}

/// `ls [OPTION]... [FILE]...`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        // clap prints help/usage/version itself; mirror its exit code (0 for --help/--version).
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let o = Opts {
        all: m.get_flag("all"),
        long: m.get_flag("long"),
        recursive: m.get_flag("recursive"),
        by_size: m.get_flag("by-size"),
        by_time: m.get_flag("by-time"),
        reverse: m.get_flag("reverse"),
        human: m.get_flag("human"),
        dir_only: m.get_flag("dir"),
    };

    let mut paths: Vec<&str> = m
        .get_many::<String>("FILE")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();
    if paths.is_empty() {
        paths.push(".");
    }
    paths.sort();
    if o.reverse {
        paths.reverse();
    }

    // `-d`: list each operand itself (a directory is shown as an entry, not descended). No
    // headers, no recursion.
    if o.dir_only {
        let mut rc = 0;
        for &p in &paths {
            match rt::lstat(p) {
                Ok(_) => print_entry(&entry_of(String::from(p), p), o.long, o.human),
                Err(e) => {
                    eprintln!("ls: {}: {}", p, rt::strerror(e));
                    rc = 1;
                }
            }
        }
        return rc;
    }
    // A header precedes each directory listing when there are several listings.
    let multi = paths.len() > 1 || o.recursive;
    let mut rc = 0;

    // POSIX: non-directory operands first, as a group. Existence/type uses lstat (so a dangling
    // symlink still lists, shown as the link itself); whether to descend uses stat (follow), so
    // a symlink to a directory is entered like GNU `ls`.
    for &p in &paths {
        match rt::lstat(p) {
            Err(e) => {
                eprintln!("ls: {}: {}", p, rt::strerror(e));
                rc = 1;
            }
            Ok(_) => {
                let is_dir = rt::stat(p).map(|m| m.is_dir).unwrap_or(false);
                if !is_dir {
                    print_entry(&entry_of(String::from(p), p), o.long, o.human);
                }
            }
        }
    }

    // Then each directory operand (following a symlink-to-directory operand).
    let mut printed_any_dir = false;
    for &p in &paths {
        if !matches!(rt::stat(p), Ok(m) if m.is_dir) {
            continue;
        }
        if multi {
            out(if printed_any_dir { "\n" } else { "" });
            out(p);
            out(":\n");
        }
        printed_any_dir = true;
        list_dir(p, &o, &mut rc);
    }
    rc
}
