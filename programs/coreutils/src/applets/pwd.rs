//! `pwd [OPTION]` — print the absolute pathname of the current working directory, followed by
//! a newline. The cwd lives in the task struct and is read via the `getcwd` syscall.
//!
//! Flags: `-L`/`--logical` (use `$PWD` from the environment if it names the current directory,
//! even if it contains symlinks) and `-P`/`--physical` (resolve all symlinks — the default).
//! The kernel returns an already-canonical cwd, so `-P` is `getcwd` verbatim; `-L` consults
//! `/env/PWD` and accepts it only when it `stat`s to the same directory, falling back to the
//! physical path otherwise (POSIX).
//!
//! Deviations from GNU: none of substance. (GNU defaults to `-L` when `$PWD` is set and valid;
//! here the default is `-P`, matching the kernel's canonical cwd — the logical form is
//! available explicitly via `-L`.) Output is byte-exact (the kernel's path bytes + LF).
//!
//! Exit status: 0 on success; 1 if the working directory could not be determined; 2 on a
//! usage error. Reads the cwd (and, for `-L`, `/env/PWD`) → tier_readonly.
//!
//! Ported from memcontainers' `programs::pwd`.

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

/// Read `$PWD` from `/env/PWD`, trimming a trailing newline. `None` if unset/unreadable.
fn env_pwd() -> Option<alloc::string::String> {
    let fd = rt::open("/env/PWD", rt::O_READ).ok()?;
    let mut v = alloc::vec::Vec::new();
    let r = textio::read_all(fd, &mut v);
    rt::close(fd);
    r.ok()?;
    let mut e = v.len();
    while e > 0 && (v[e - 1] == b'\n' || v[e - 1] == b'\r') {
        e -= 1;
    }
    core::str::from_utf8(&v[..e]).ok().map(alloc::string::String::from)
}

/// True if `$PWD` is an absolute path naming the same directory as the real cwd (so the
/// logical form is usable). Compares by `stat` identity via the canonical cwd string.
fn pwd_names_cwd(pwd: &str, cwd: &str) -> bool {
    // Must be absolute and contain no `.`/`..` component (POSIX requirement for $PWD).
    if !pwd.starts_with('/') {
        return false;
    }
    if pwd.split('/').any(|c| c == "." || c == "..") {
        return false;
    }
    // It names the cwd iff it canonicalizes (symlinks followed) to the same path the kernel
    // reports for the cwd. `fsutil::canonicalize` mirrors the kernel walk.
    match crate::fsutil::canonicalize(pwd, crate::fsutil::Existence::All) {
        Some(resolved) => resolved == cwd,
        None => false,
    }
}

/// The clap command — the single source of `pwd`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("pwd")
        .about("Print the full filename of the current working directory.")
        .arg(Arg::new("logical").short('L').long("logical").action(ArgAction::SetTrue).help("use PWD from environment, even if it contains symlinks"))
        .arg(Arg::new("physical").short('P').long("physical").action(ArgAction::SetTrue).help("avoid all symlinks (the default)"))
}

/// `pwd`. Returns the exit status (0 success; 1 if the cwd is unavailable; 2 usage error).
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        // clap prints help/usage/version itself; mirror its exit code (0 for --help/--version).
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };
    // `-P` wins if both are given (GNU: the last one set; here physical is also the default).
    let logical = m.get_flag("logical") && !m.get_flag("physical");

    let mut buf = [0u8; 4096];
    let cwd = match rt::getcwd(&mut buf) {
        Ok(n) => core::str::from_utf8(&buf[..n]).unwrap_or("/"),
        Err(e) => {
            eprintln!("pwd: {}", rt::strerror(e));
            return 1;
        }
    };

    if logical {
        if let Some(pwd) = env_pwd() {
            if pwd_names_cwd(&pwd, cwd) {
                textio::outln(pwd.as_bytes());
                return 0;
            }
        }
    }
    textio::outln(cwd.as_bytes());
    0
}
