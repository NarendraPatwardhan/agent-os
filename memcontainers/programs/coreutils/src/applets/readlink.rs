//! `readlink [OPTION]... FILE...` — print symlink targets or canonical paths. By default it
//! prints the one-level target of each FILE that is a symlink (a non-symlink yields nothing
//! and a failure status). The canonicalizing modes follow every symlink and collapse `..`,
//! differing only in which components must exist:
//!   * `-f`/`--canonicalize` — every component but the last must exist;
//!   * `-e`/`--canonicalize-existing` — every component must exist;
//!   * `-m`/`--canonicalize-missing` — no component need exist.
//! `-n`/`--no-newline` omits the trailing separator; `-z`/`--zero` uses NUL separators;
//! `-q`/`--quiet` and `-s`/`--silent` suppress error messages (the default here);
//! `-v`/`--verbose` re-enables them.
//!
//! Deviations from GNU: errors are SILENT by default (as if `-q`/`-s` were always on) — pass
//! `-v` to report them; GNU is silent only with `-q`/`-s`. Canonicalization mirrors the
//! kernel's own path walk in user space (no syscall returns the resolved path).
//!
//! Exit status: 0 if every FILE resolved; 1 if any FILE could not be resolved (not a symlink
//! in the default mode, or a missing-required-component / loop in a canonical mode); 2 on a
//! usage error. Reads arbitrary absolute paths via `lstat`/`readlink`/`stat` → tier_readonly.
//!
//! Ported from memcontainers' `programs::readlink`.

use alloc::string::String;
use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::fsutil::{self, Existence};
use crate::prelude::*;
use sysroot as rt;

/// The one-level target of the symlink at `p`, or `None` if it is not a symlink.
fn link_target(p: &str) -> Option<String> {
    match rt::lstat(p) {
        Ok(s) if s.is_symlink => {
            let mut buf = [0u8; 1024];
            let nn = rt::readlink(p, &mut buf).ok()?;
            core::str::from_utf8(&buf[..nn.min(buf.len())])
                .ok()
                .map(String::from)
        }
        _ => None,
    }
}

/// The clap command — the single source of `readlink`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("readlink")
        .about("Print value of a symbolic link or canonical file name.")
        .arg(Arg::new("canonicalize").short('f').long("canonicalize").action(ArgAction::SetTrue).help("canonicalize by following every symlink; all but the last component must exist"))
        .arg(Arg::new("canonicalize-existing").short('e').long("canonicalize-existing").action(ArgAction::SetTrue).help("canonicalize, requiring all components to exist"))
        .arg(Arg::new("canonicalize-missing").short('m').long("canonicalize-missing").action(ArgAction::SetTrue).help("canonicalize, requiring no component to exist"))
        .arg(Arg::new("no-newline").short('n').long("no-newline").action(ArgAction::SetTrue).help("do not output the trailing delimiter"))
        .arg(Arg::new("zero").short('z').long("zero").action(ArgAction::SetTrue).help("end each output line with NUL, not newline"))
        .arg(Arg::new("quiet").short('q').long("quiet").action(ArgAction::SetTrue).help("suppress most error messages (default)"))
        .arg(Arg::new("silent").short('s').long("silent").action(ArgAction::SetTrue).help("suppress most error messages (default)"))
        .arg(Arg::new("verbose").short('v').long("verbose").action(ArgAction::SetTrue).help("report error messages"))
        .arg(Arg::new("FILE").action(ArgAction::Append).num_args(1..).help("symlink(s) or path(s) to resolve"))
}

/// `readlink FILE...`. Returns the exit status (0 success; 1 a FILE failed; 2 usage error).
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        // clap prints help/usage/version itself; mirror its exit code (0 for --help/--version).
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    // `-e` ⇒ all components exist, `-m` ⇒ none, `-f` ⇒ parent — else one-level target.
    let canon = if m.get_flag("canonicalize-existing") {
        Some(Existence::All)
    } else if m.get_flag("canonicalize-missing") {
        Some(Existence::None)
    } else if m.get_flag("canonicalize") {
        Some(Existence::Parent)
    } else {
        None
    };
    let no_newline = m.get_flag("no-newline");
    let zero = m.get_flag("zero");
    // `-q`/`-s` (silent) are the default; `-v` re-enables error messages.
    let verbose = m.get_flag("verbose");
    // One separator written after each result: NUL for `-z`, none for `-n`, else LF (the
    // terminal adds CR via ONLCR).
    let sep: &[u8] = if zero {
        b"\0"
    } else if no_newline {
        b""
    } else {
        b"\n"
    };

    let ops: Vec<&str> = m
        .get_many::<String>("FILE")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();
    if ops.is_empty() {
        eprintln!("readlink: missing operand");
        return 2;
    }

    let mut out = BufOut::new();
    let mut rc = 0;
    for &p in &ops {
        let resolved = match canon {
            Some(mode) => fsutil::canonicalize(p, mode),
            None => link_target(p),
        };
        match resolved {
            Some(s) => {
                out.extend(s.as_bytes());
                out.extend(sep);
            }
            None => {
                if verbose {
                    eprintln!("readlink: {}: cannot resolve", p);
                }
                rc = 1;
            }
        }
    }
    let _ = out.finish();
    rc
}
