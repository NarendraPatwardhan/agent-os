//! `time [OPTION]... COMMAND [ARG]...` — run COMMAND and report how long it took. A native mc
//! guest: it spawns the child (`rt::spawn`), waits, and measures wall-clock elapsed via the
//! monotonic clock (`rt::time_monotonic`). The report goes to stderr (or `-o FILE`); the
//! command's own stdout/stderr pass through untouched, and `time` exits with the command's
//! status.
//!
//! This is a `/bin` program, so it can only time *external* commands it spawns — not shell
//! builtins or whole pipelines (there is no `time` shell keyword). The kernel has no
//! per-process CPU/RSS accounting, so `user`/`sys`/CPU%/memory are reported honestly as
//! `0.000`/`?`/`unavailable` — only the real (wall) time is meaningful. Times are formatted with
//! integer arithmetic (millisecond resolution) to keep the guest free of float-formatting code.
//!
//! Flags: `-p`/`--portability` (POSIX one-field-per-line), `-v`/`--verbose` (GNU multi-line),
//! `-o FILE`/`--output=FILE` (write the report to FILE), `-a`/`--append` (append rather than
//! truncate, with `-o`), `-f FORMAT`/`--format=FORMAT` (GNU format string: `%e %E %C %x %U %S %P
//! %M %K %t`). Deviations: spawns external commands only; user/sys/CPU%/memory are not measured;
//! only `time --help`/`-h` as the FIRST token prints help, so `time CMD --help` runs `CMD --help`
//! (clap trailing-var-arg).
//!
//! Exit status: COMMAND's own exit status; `125` if time itself failed (a usage error); `127` if
//! COMMAND could not be run.
//!
//! Ported from memcontainers' `programs::time`.

use alloc::string::String;
use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

/// `real`/`user`/`sys` line for the default (bash-builtin-style) report: `<m>m<s>.<mmm>s`.
fn clock_str(ms: u64) -> String {
    let m = ms / 60_000;
    let rem = ms % 60_000;
    alloc::format!("{}m{}.{:03}s", m, rem / 1000, rem % 1000)
}

/// Seconds with millisecond precision: `<s>.<mmm>` (for `%e` and friends).
fn secs_str(ms: u64) -> String {
    alloc::format!("{}.{:03}", ms / 1000, ms % 1000)
}

/// `[h:]mm:ss.cc` elapsed form (for `%E` / the verbose report).
fn elapsed_hms(ms: u64) -> String {
    let cs = (ms % 1000) / 10;
    let total_s = ms / 1000;
    let h = total_s / 3600;
    let m = (total_s % 3600) / 60;
    let s = total_s % 60;
    if h > 0 {
        alloc::format!("{}:{:02}:{:02}.{:02}", h, m, s, cs)
    } else {
        alloc::format!("{}:{:02}.{:02}", m, s, cs)
    }
}

/// Render a GNU `-f FORMAT` template. Unsupported/unavailable fields render as `0`/`0.000`/`?`
/// rather than fabricated values.
fn render_format(fmt: &[u8], cmd_line: &str, elapsed_ms: u64, status: i32) -> String {
    let mut out = String::new();
    let mut it = fmt.iter().copied().peekable();
    while let Some(c) = it.next() {
        match c {
            b'%' => match it.next() {
                Some(b'e') => out.push_str(&secs_str(elapsed_ms)),
                Some(b'E') => out.push_str(&elapsed_hms(elapsed_ms)),
                Some(b'C') => out.push_str(cmd_line),
                Some(b'x') => out.push_str(&alloc::format!("{status}")),
                Some(b'U') | Some(b'S') => out.push_str("0.000"), // no CPU accounting
                Some(b'P') => out.push('?'),                      // CPU% unavailable
                Some(b'M') | Some(b'K') | Some(b't') => out.push('0'), // RSS unavailable
                Some(b'%') => out.push('%'),
                Some(other) => {
                    out.push('%');
                    out.push(other as char);
                }
                None => out.push('%'),
            },
            b'\\' => match it.next() {
                Some(b'n') => out.push('\n'),
                Some(b't') => out.push('\t'),
                Some(b'\\') => out.push('\\'),
                Some(other) => out.push(other as char),
                None => out.push('\\'),
            },
            other => out.push(other as char),
        }
    }
    out.push('\n');
    out
}

fn render_default(elapsed_ms: u64) -> String {
    alloc::format!(
        "real\t{}\nuser\t{}\nsys\t{}\n",
        clock_str(elapsed_ms),
        clock_str(0),
        clock_str(0),
    )
}

fn render_posix(elapsed_ms: u64) -> String {
    alloc::format!(
        "real {}\nuser {}\nsys {}\n",
        secs_str(elapsed_ms),
        secs_str(0),
        secs_str(0),
    )
}

fn render_verbose(cmd_line: &str, elapsed_ms: u64, status: i32) -> String {
    let mut s = String::new();
    s.push_str(&alloc::format!("\tCommand being timed: \"{cmd_line}\"\n"));
    s.push_str("\tUser time (seconds): 0.000\n");
    s.push_str("\tSystem time (seconds): 0.000\n");
    s.push_str("\tPercent of CPU this job got: ?\n");
    s.push_str(&alloc::format!(
        "\tElapsed (wall clock) time (h:mm:ss or m:ss): {}\n",
        elapsed_hms(elapsed_ms)
    ));
    s.push_str("\tMaximum resident set size (kbytes): unavailable\n");
    s.push_str(&alloc::format!("\tExit status: {status}\n"));
    s
}

/// The clap command — the single source of `time`'s flag surface AND its `--help`. COMMAND is a
/// trailing var-arg so the command's own flags pass through untouched.
fn command() -> Command {
    Command::new("time")
        .about("Run COMMAND and report the wall-clock time it took (to stderr, or -o FILE).")
        .override_usage("time [OPTION]... COMMAND [ARG]...")
        .arg(
            Arg::new("portability")
                .short('p')
                .long("portability")
                .visible_alias("posix")
                .action(ArgAction::SetTrue)
                .help("use the POSIX one-field-per-line output format"),
        )
        .arg(
            Arg::new("verbose")
                .short('v')
                .long("verbose")
                .action(ArgAction::SetTrue)
                .help("verbose (GNU-style multi-line) report"),
        )
        .arg(
            Arg::new("output")
                .short('o')
                .long("output")
                .num_args(1)
                .value_name("FILE")
                .help("write the report to FILE instead of stderr"),
        )
        .arg(
            Arg::new("append")
                .short('a')
                .long("append")
                .action(ArgAction::SetTrue)
                .help("append the report to FILE instead of truncating it (with -o)"),
        )
        .arg(
            Arg::new("format")
                .short('f')
                .long("format")
                .num_args(1)
                .value_name("FORMAT")
                .help("GNU format string (%e %E %C %x %U %S %P %M %K %t, etc.)"),
        )
        .arg(
            Arg::new("COMMAND")
                .required(true)
                .action(ArgAction::Append)
                .num_args(1..)
                .value_name("COMMAND")
                // COMMAND is the last positional and captures its own arguments/flags verbatim.
                .trailing_var_arg(true)
                .allow_hyphen_values(true)
                .help("the command to run, followed by its arguments (taken verbatim)"),
        )
}

/// `time [OPTION]... COMMAND [ARG]...`. Returns COMMAND's exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            // GNU/POSIX time exits 125 on its own usage failure; clap returns 0 for help/version.
            return if e.exit_code() == 0 { 0 } else { 125 };
        }
    };

    let posix = m.get_flag("portability");
    let verbose = m.get_flag("verbose");
    let append = m.get_flag("append");
    let out_file = m.get_one::<String>("output");
    let format = m.get_one::<String>("format");

    let cmd: Vec<&str> = m
        .get_many::<String>("COMMAND")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();
    if cmd.is_empty() {
        eprintln!("time: missing command");
        return 125;
    }

    // Spawn the child, inheriting all three stdio fds so its output flows through.
    let mut blob: Vec<u8> = Vec::new();
    for (j, a) in cmd.iter().enumerate() {
        if j > 0 {
            blob.push(0);
        }
        blob.extend_from_slice(a.as_bytes());
    }

    let t0 = rt::time_monotonic().unwrap_or(0);
    let pid = match rt::spawn(&blob, rt::STDIN, rt::STDOUT, rt::STDERR) {
        Ok(p) => p as i32,
        Err(_) => {
            eprintln!("time: cannot run command");
            return 127;
        }
    };
    let status = loop {
        match rt::waitpid(pid) {
            Ok(s) => break s,
            Err(rt::EINTR) => continue,
            Err(_) => break 1,
        }
    };
    let t1 = rt::time_monotonic().unwrap_or(t0);
    let elapsed_ms = (t1 - t0).max(0) as u64;

    // Command line for %C / verbose.
    let mut cmd_line = String::new();
    for (j, a) in cmd.iter().enumerate() {
        if j > 0 {
            cmd_line.push(' ');
        }
        cmd_line.push_str(a);
    }

    let report = if let Some(fmt) = format {
        render_format(fmt.as_bytes(), &cmd_line, elapsed_ms, status)
    } else if verbose {
        render_verbose(&cmd_line, elapsed_ms, status)
    } else if posix {
        render_posix(elapsed_ms)
    } else {
        render_default(elapsed_ms)
    };

    match out_file {
        Some(path) => {
            let flags =
                rt::O_WRITE | rt::O_CREATE | if append { rt::O_APPEND } else { rt::O_TRUNC };
            match rt::open(path, flags) {
                Ok(fd) => {
                    // Write the report through the facade sink, then flush once.
                    let mut o = BufOut::with_fd(fd);
                    o.extend(report.as_bytes());
                    let _ = o.finish();
                    rt::close(fd);
                }
                Err(_) => {
                    eprintln!("time: cannot open output file");
                    let _ = rt::write_all(rt::STDERR, report.as_bytes());
                }
            }
        }
        None => {
            let _ = rt::write_all(rt::STDERR, report.as_bytes());
        }
    }

    status
}
