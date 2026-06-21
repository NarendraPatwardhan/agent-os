//! `printenv [VARIABLE]...` — print all or part of the environment. With no operands, list every
//! variable as `NAME=value`, sorted by name; with operands, print each named variable's value on
//! its own line (and exit 1 if any is unset). The environment is backed by files under `/env`,
//! so this is a READ-ONLY applet — it opens `/env/<name>` and reads it; it never mutates.
//!
//! Flags: none beyond clap's `--help`. Variable values are read with `crate::textio::read_all`
//! over `rt::open(.., O_READ)`; the directory is enumerated with `crate::fsutil::list`.
//!
//! Deviations from GNU printenv: `-0`/`--null` is NOT implemented (entries are always
//! newline-terminated). A value set via `echo > /env/X` keeps a trailing newline/carriage-return,
//! which is trimmed here (one set via `export` has none).
//!
//! Exit status: `0` success (every requested variable was set, or a full listing); `1` a
//! requested VARIABLE was unset; `2` a usage error (clap).
//!
//! Ported from memcontainers' `programs::printenv`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

/// Read `/env/<name>` into `out`; false if the variable is unset.
fn read_var(name: &str, out: &mut Vec<u8>) -> bool {
    let path = fsutil::join("/env", name);
    match rt::open(&path, rt::O_READ) {
        Ok(fd) => {
            let _ = textio::read_all(fd, out);
            rt::close(fd);
            true
        }
        Err(_) => false,
    }
}

/// Trim trailing newline bytes (a value set via `echo > /env/X` keeps the LF; one set via
/// `export` does not).
fn trim_nl(b: &[u8]) -> &[u8] {
    let mut e = b.len();
    while e > 0 && (b[e - 1] == b'\n' || b[e - 1] == b'\r') {
        e -= 1;
    }
    &b[..e]
}

/// The clap command — the single source of `printenv`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("printenv")
        .about("Print the values of the specified environment VARIABLE(s); with none, print all.")
        .arg(
            Arg::new("VARIABLE")
                .action(ArgAction::Append)
                .num_args(0..)
                .help("environment variables to print (with none, list every variable)"),
        )
}

/// `printenv [VARIABLE]...`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let ops: Vec<&str> = m
        .get_many::<String>("VARIABLE")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();

    if ops.is_empty() {
        let mut names = fsutil::list("/env").unwrap_or_default();
        names.sort();
        for name in names {
            let mut val = Vec::new();
            if read_var(&name, &mut val) {
                textio::out(name.as_bytes());
                textio::out(b"=");
                textio::outln(trim_nl(&val));
            }
        }
        return 0;
    }

    let mut rc = 0;
    for name in &ops {
        let mut val = Vec::new();
        if read_var(name, &mut val) {
            textio::outln(trim_nl(&val));
        } else {
            rc = 1;
        }
    }
    rc
}
