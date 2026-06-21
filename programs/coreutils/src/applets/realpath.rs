//! `realpath [OPTION]... FILE...` — print the resolved, absolute, canonical form of each
//! FILE: relative paths are resolved against the cwd, `.`/`..`/duplicate-slash components are
//! collapsed, and (by default) symlinks are followed.
//!
//! Existence modes (which path components must exist):
//!   * default — all components but the last must exist (GNU's default, like `readlink -f`);
//!   * `-e`/`--canonicalize-existing` — every component must exist;
//!   * `-m`/`--canonicalize-missing` — no component need exist.
//! `-s`/`--strip`/`--no-symlinks` resolves lexically WITHOUT expanding any symlink (so the
//! result is `lexical_abs`: cwd-anchored, `.`/`..` collapsed, links left intact). `-z`/`--zero`
//! separates outputs with NUL; `-q`/`--quiet` suppresses the per-file error message.
//!
//! Deviations from GNU: `--relative-to`, `--relative-base`, and `-P`/`-L` (logical) are not
//! implemented (a missing relative-base feature, noted here). For symbolic modes the
//! resolution mirrors the kernel's own `open`/`stat` walk in user space, since no syscall
//! hands back the resolved *path*. A symlink loop (or a required-but-missing component) makes
//! that FILE fail.
//!
//! Exit status: 0 if every FILE resolved; 1 if any FILE was invalid, missing a required
//! component, or hit a symlink loop; 2 on a usage error. Reads arbitrary absolute paths via
//! `stat`/`lstat`/`readlink` → tier_readonly (NOT isolated, which would confine the walk to
//! the cwd subtree).
//!
//! Ported from memcontainers' `programs::realpath`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::fsutil::{self, Existence};
use crate::prelude::*;
use sysroot as rt;

/// The clap command — the single source of `realpath`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("realpath")
        .about("Print the resolved absolute file name; all but the last component must exist.")
        .arg(Arg::new("canonicalize-existing").short('e').long("canonicalize-existing").action(ArgAction::SetTrue).help("all components of the path must exist"))
        .arg(Arg::new("canonicalize-missing").short('m').long("canonicalize-missing").action(ArgAction::SetTrue).help("no path components need exist or be a directory"))
        .arg(Arg::new("strip").short('s').long("strip").visible_alias("no-symlinks").action(ArgAction::SetTrue).help("don't expand symlinks (resolve lexically only)"))
        .arg(Arg::new("zero").short('z').long("zero").action(ArgAction::SetTrue).help("end each output line with NUL, not newline"))
        .arg(Arg::new("quiet").short('q').long("quiet").action(ArgAction::SetTrue).help("suppress most error messages"))
        .arg(Arg::new("FILE").action(ArgAction::Append).num_args(1..).help("file name(s) to canonicalize"))
}

/// `realpath FILE...`. Returns the exit status (0 success; 1 a FILE failed; 2 usage error).
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
        eprintln!("realpath: missing operand");
        return 2;
    }

    // Existence mode: -e ⇒ all, -m ⇒ none, default ⇒ parent (GNU's default).
    let existence = if m.get_flag("canonicalize-existing") {
        Existence::All
    } else if m.get_flag("canonicalize-missing") {
        Existence::None
    } else {
        Existence::Parent
    };
    let strip = m.get_flag("strip");
    let zero = m.get_flag("zero");
    let quiet = m.get_flag("quiet");
    let term: &[u8] = if zero { b"\0" } else { b"\n" };

    let mut out = BufOut::new();
    let mut rc = 0;
    for &p in &ops {
        // `-s` resolves purely lexically (no symlink expansion); otherwise canonicalize per
        // the existence mode (mirroring the kernel's own path walk to recover the *path*).
        let resolved = if strip {
            // lexical_abs cannot fail; for `-s -e` GNU still requires existence, but the
            // historical port treats `-s` as the no-symlinks lexical form — documented above.
            Some(fsutil::lexical_abs(p))
        } else {
            fsutil::canonicalize(p, existence)
        };
        match resolved {
            Some(s) => {
                out.extend(s.as_bytes());
                out.extend(term);
            }
            None => {
                if !quiet {
                    // canonicalize returns None for two reasons: a required component is
                    // missing (the common `-e`/default failure) or a symlink loop. Probe the
                    // path so the reported reason is GNU-faithful — ENOENT for the former,
                    // ELOOP for the latter (lstat reports ELOOP if the walk itself loops).
                    let errno = match rt::lstat(p) {
                        Ok(_) => rt::ELOOP,
                        Err(e) => e,
                    };
                    eprintln!("realpath: {}: {}", p, rt::strerror(errno));
                }
                rc = 1;
            }
        }
    }
    let _ = out.finish();
    rc
}
