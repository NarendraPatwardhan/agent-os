//! `rmdir [OPTION]... DIRECTORY...` — remove empty directories. `-p`/`--parents` additionally
//! removes each now-empty parent directory in turn after the named one is removed. Refuses to
//! remove a non-directory (reports `Not a directory`); a non-empty directory reports the
//! kernel's `Directory not empty`. Output is byte-exact and there is none on success.
//!
//! Flags: `-p`/`--parents` (remove now-empty parents). Args+help are via clap; the directory
//! removal goes through `//sysroot` (`rt::unlink`, which removes an empty directory) and
//! `crate::fsutil::is_dir`.
//!
//! Deviations from GNU rmdir: `--ignore-fail-on-non-empty` and `-v`/`--verbose` are NOT
//! implemented (a non-empty directory always reports an error; nothing is printed on success).
//!
//! Exit status: `0` all directories removed; `1` a DIRECTORY could not be removed (missing, a
//! non-directory, non-empty, or a permission failure); `2` a usage error (clap).
//!
//! Ported from memcontainers' `programs::rmdir`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

/// Parent directory of a path (`/a/b` → `/a`, `a` → ``, `/a` → `/`).
fn parent(p: &str) -> &str {
    let t = p.trim_end_matches('/');
    match t.rfind('/') {
        Some(0) => "/",
        Some(i) => &t[..i],
        None => "",
    }
}

/// The clap command — the single source of `rmdir`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("rmdir")
        .about("Remove the DIRECTORY(ies), if they are empty.")
        .arg(
            Arg::new("parents")
                .short('p')
                .long("parents")
                .action(ArgAction::SetTrue)
                .help("remove DIRECTORY and its now-empty ancestors"),
        )
        .arg(
            Arg::new("DIRECTORY")
                .action(ArgAction::Append)
                .num_args(0..)
                .help("the empty directories to remove"),
        )
}

/// `rmdir [OPTION]... DIRECTORY...`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let parents = m.get_flag("parents");
    let ops: Vec<&str> = m
        .get_many::<String>("DIRECTORY")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();
    if ops.is_empty() {
        eprintln!("rmdir: missing operand");
        return 1;
    }

    let mut rc = 0;
    for path in &ops {
        if !fsutil::is_dir(path) {
            eprintln!("rmdir: {}: Not a directory", path);
            rc = 1;
            continue;
        }
        if let Err(e) = rt::unlink(path) {
            eprintln!("rmdir: {}: {}", path, rt::strerror(e));
            rc = 1;
            continue;
        }
        if parents {
            let mut p = parent(path);
            while !p.is_empty() && p != "/" && p != "." {
                if !fsutil::is_dir(p) || rt::unlink(p).is_err() {
                    break;
                }
                p = parent(p);
            }
        }
    }
    rc
}
