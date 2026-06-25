//! `env [OPTION]... [NAME=VALUE]... [COMMAND [ARG]...]` — run COMMAND in a modified
//! environment, or (with no COMMAND) print the environment. The environment is the per-task
//! `/env` directory (one file per variable); assignments are written there and inherited by a
//! spawned child (the kernel copies `/env` at spawn).
//!
//! Flags: `-i`/`--ignore-environment` (start empty), `-u NAME`/`--unset=NAME` (remove NAME,
//! repeatable), `-C DIR`/`--chdir=DIR` (change directory before running COMMAND). A leading
//! `NAME=VALUE` operand sets a variable; the first operand without `=` begins COMMAND and
//! everything after it is passed through verbatim (so `env -i prog -x` gives `-x` to `prog`,
//! not to `env`).
//!
//! Deviations from GNU: `-0`/`--null`, `-S`/`--split-string`, `-v`/`--debug`, and the
//! signal/block options are not implemented. Option processing stops at the first operand
//! (clap `trailing_var_arg` + `allow_hyphen_values`), so `env --help` prints help but
//! `env FOO=1 cmd --help` passes `--help` to `cmd` — matching GNU's "options must precede the
//! command" rule. A consequence of `allow_hyphen_values`: an UNKNOWN leading dash-option (e.g.
//! `env -x`) is taken as the start of COMMAND rather than rejected — use `--` to disambiguate.
//!
//! Exit status: success (or COMMAND's status) when COMMAND runs; 0 when only the environment
//! is printed; 1 if COMMAND could not be waited on; 125 on a `-C` chdir failure; 126 if
//! COMMAND was found but could not run; 127 if COMMAND was not found; 2 on a usage error.
//! Spawns a process and mutates `/env` → tier_full.
//!
//! Ported from memcontainers' `programs::env`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

/// Write `name=val` into `/env/<name>` (creating/truncating). Best-effort.
fn set_var(name: &str, val: &str) {
    let p = fsutil::join("/env", name);
    if let Ok(fd) = rt::open(&p, rt::O_WRITE | rt::O_CREATE | rt::O_TRUNC) {
        let _ = rt::write_all(fd, val.as_bytes());
        rt::close(fd);
    }
}

/// Remove every variable from `/env` (the `-i` empty-environment start).
fn clear_env() {
    for name in fsutil::list("/env").unwrap_or_default() {
        let _ = rt::unlink(&fsutil::join("/env", &name));
    }
}

/// Remove a single variable (`-u NAME`).
fn unset_var(name: &str) {
    let _ = rt::unlink(&fsutil::join("/env", name));
}

/// Print the environment as `NAME=VALUE` lines (sorted), trailing whitespace trimmed.
fn list_env() {
    let mut names = fsutil::list("/env").unwrap_or_default();
    names.sort();
    let mut out = BufOut::new();
    for name in names {
        if let Ok(fd) = rt::open(&fsutil::join("/env", &name), rt::O_READ) {
            let mut v: Vec<u8> = Vec::new();
            let _ = textio::read_all(fd, &mut v);
            rt::close(fd);
            let mut e = v.len();
            while e > 0 && (v[e - 1] == b'\n' || v[e - 1] == b'\r') {
                e -= 1;
            }
            out.extend(name.as_bytes());
            out.push(b'=');
            out.extend(&v[..e]);
            if out.end_line().is_err() {
                break;
            }
        }
    }
    let _ = out.finish();
}

/// The clap command — the single source of `env`'s flag surface AND its `--help`. The trailing
/// operand list is captured raw (`trailing_var_arg` + `allow_hyphen_values`) so a dash-option
/// meant for COMMAND is passed through rather than parsed as one of env's own.
fn command() -> Command {
    Command::new("env")
        .about("Set each NAME to VALUE in the environment and run COMMAND. With no COMMAND, print the resulting environment.")
        .arg(Arg::new("ignore-environment").short('i').long("ignore-environment").action(ArgAction::SetTrue).help("start with an empty environment"))
        .arg(Arg::new("unset").short('u').long("unset").action(ArgAction::Append).value_name("NAME").help("remove variable NAME from the environment (repeatable)"))
        .arg(Arg::new("chdir").short('C').long("chdir").num_args(1).value_name("DIR").help("change working directory to DIR before running COMMAND"))
        .arg(
            Arg::new("ARGS")
                .action(ArgAction::Append)
                .num_args(0..)
                .trailing_var_arg(true)
                .allow_hyphen_values(true)
                .help("[NAME=VALUE]... [COMMAND [ARG]...]"),
        )
}

/// `env ...`. Returns the exit status (COMMAND's status, or 0/1/125/126/127/2 — see the doc).
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        // clap prints help/usage/version itself; mirror its exit code (0 for --help/--version).
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    if m.get_flag("ignore-environment") {
        clear_env();
    }
    if let Some(names) = m.get_many::<String>("unset") {
        for name in names {
            unset_var(name);
        }
    }

    let operands: Vec<&str> = m
        .get_many::<String>("ARGS")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();

    // Leading NAME=VALUE operands are assignments; the first operand without `=` begins the
    // command (everything after it is its arguments).
    let mut idx = 0;
    while idx < operands.len() {
        match operands[idx].as_bytes().iter().position(|&b| b == b'=') {
            Some(eq) => {
                set_var(&operands[idx][..eq], &operands[idx][eq + 1..]);
                idx += 1;
            }
            None => break,
        }
    }

    let cmd = &operands[idx..];
    if cmd.is_empty() {
        list_env();
        return 0;
    }

    // `-C DIR`: change directory before spawning (GNU exits 125 on failure).
    if let Some(dir) = m.get_one::<String>("chdir") {
        if let Err(e) = rt::chdir(dir) {
            eprintln!("env: cannot change directory to {}: {}", dir, rt::strerror(e));
            return 125;
        }
    }

    // Spawn the command (the kernel resolves a bare name via $PATH); the child inherits the
    // environment we just set up.
    let mut blob: Vec<u8> = Vec::new();
    for (i, a) in cmd.iter().enumerate() {
        if i > 0 {
            blob.push(0);
        }
        blob.extend_from_slice(a.as_bytes());
    }
    match rt::spawn(&blob, rt::STDIN, rt::STDOUT, rt::STDERR) {
        Ok(pid) => match rt::waitpid(pid as i32) {
            Ok(status) => status,
            Err(_) => 1,
        },
        Err(rt::ENOENT) => {
            eprintln!("env: {}: No such file or directory", cmd[0]);
            127
        }
        Err(e) => {
            eprintln!("env: {}: {}", cmd[0], rt::strerror(e));
            126
        }
    }
}
