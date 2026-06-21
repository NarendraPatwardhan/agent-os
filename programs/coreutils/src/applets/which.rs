//! `which [-a] NAME...` — for each NAME, print the first `$PATH` directory containing an
//! executable of that name (a NAME containing a `/` is checked as a path as-is, not searched).
//! With `-a` (`--all`), print every match across `$PATH`, not just the first. `$PATH` is read
//! from `/env/PATH`.
//!
//! Flags: `-a`/`--all`.
//!
//! Deviations from GNU/BSD `which`: no `--skip-dot`, `--skip-tilde`, `--read-alias`, or
//! `--tty-only`; it consults neither shell aliases nor functions, only `$PATH`. A "match" is
//! anything that exists at the candidate path — there is no executable-bit test, since the VM
//! has no per-file permission model for the single subject.
//!
//! Exit status: 0 if every NAME was found; 1 if at least one NAME was not found (or had an
//! invalid byte sequence); 2 on a usage error. Reads `/env/PATH` and `stat`s arbitrary
//! absolute candidate paths → tier_readonly.
//!
//! Ported from memcontainers' `programs::which`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

/// Read `/env/PATH` (the per-task search path) into `out`. Missing/unreadable ⇒ empty.
fn read_path(out: &mut Vec<u8>) {
    if let Ok(fd) = rt::open("/env/PATH", rt::O_READ) {
        let _ = textio::read_all(fd, out);
        rt::close(fd);
    }
}

/// The clap command — the single source of `which`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("which")
        .about("Locate a command: print the full path of the executable(s) that would be run.")
        .arg(Arg::new("all").short('a').long("all").action(ArgAction::SetTrue).help("print all matching pathnames of each NAME in $PATH, not just the first"))
        .arg(Arg::new("NAME").action(ArgAction::Append).num_args(1..).help("command name(s) to locate"))
}

/// `which NAME...`. Returns the exit status (0 all found; 1 a NAME was missing; 2 usage error).
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        // clap prints help/usage/version itself; mirror its exit code (0 for --help/--version).
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };
    let all = m.get_flag("all");

    let ops: Vec<&str> = m
        .get_many::<String>("NAME")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();
    if ops.is_empty() {
        eprintln!("which: missing operand");
        return 2;
    }

    let mut path_raw: Vec<u8> = Vec::new();
    read_path(&mut path_raw);
    let path = textio::chomp(&path_raw);

    let mut out = BufOut::new();
    let mut rc = 0;
    for &name_s in &ops {
        let mut found = false;
        if name_s.contains('/') {
            if fsutil::exists(name_s) {
                out.extend(name_s.as_bytes());
                out.push(b'\n');
                found = true;
            }
        } else {
            for dir in path.split(|&b| b == b':').filter(|s| !s.is_empty()) {
                let d = match core::str::from_utf8(dir) {
                    Ok(s) => s,
                    Err(_) => continue,
                };
                let full = fsutil::join(d, name_s);
                if fsutil::exists(&full) {
                    out.extend(full.as_bytes());
                    out.push(b'\n');
                    found = true;
                    if !all {
                        break; // first match only, unless -a
                    }
                }
            }
        }
        if !found {
            rc = 1;
        }
    }
    let _ = out.finish();
    rc
}
