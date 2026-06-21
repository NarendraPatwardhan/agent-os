//! `timeout [OPTION]... DURATION COMMAND [ARG]...` — run COMMAND, but terminate it if it is
//! still running after DURATION. A native mc guest: it spawns the child (`rt::spawn`) and polls
//! (`rt::waitpid_nohang` + the monotonic clock) against a deadline, since the ABI has no
//! blocking-wait-with-timeout. On expiry it sends a signal (default `TERM`); with `-k`/
//! `--kill-after` it escalates to `KILL` after a grace window.
//!
//! DURATION is `N[smhd]` — a bare number is seconds, fractions allowed — the same grammar as
//! `sleep`. `-s`/`--signal` selects the signal (name with optional `SIG` prefix, or a number).
//!
//! Flags: `-s`/`--signal=SIG`, `-k`/`--kill-after=DURATION`, `--preserve-status`,
//! `--foreground`, `-v`/`--verbose`. Deviations from GNU `timeout`: `--foreground` is accepted
//! but a no-op (this model has no separate process groups); termination is a signal followed by
//! a polled reap (no blocking wait-with-timeout exists); only `timeout --help`/`-h` as the
//! FIRST token prints help, so `timeout 5 CMD --help` runs `CMD --help` (clap trailing-var-arg).
//!
//! Exit status: `124` on timeout (unless `--preserve-status`, then COMMAND's status); `125` for
//! timeout's own errors (bad option/duration/signal); `127` if COMMAND could not be run;
//! otherwise COMMAND's own exit status.
//!
//! Ported from memcontainers' `programs::timeout`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use sysroot as rt;

/// How often the deadline poll wakes (ms). Small enough to be responsive, large enough to yield
/// the scheduler between checks.
const POLL_MS: i32 = 10;

/// Resolve a signal spec (name with optional `SIG` prefix, or a number). Kept in sync with
/// `kill`'s `sig_num` and `crates/abi`.
fn sig_num(spec: &[u8]) -> Option<i32> {
    let s = if spec.len() > 3 && spec[..3].eq_ignore_ascii_case(b"SIG") {
        &spec[3..]
    } else {
        spec
    };
    if !s.is_empty() && s.iter().all(|c| c.is_ascii_digit()) {
        let mut v: i32 = 0;
        for &c in s {
            v = v * 10 + (c - b'0') as i32;
        }
        return Some(v);
    }
    let named: &[(&[u8], i32)] = &[
        (b"HUP", rt::SIGHUP),
        (b"INT", rt::SIGINT),
        (b"KILL", rt::SIGKILL),
        (b"TERM", rt::SIGTERM),
        (b"CHLD", rt::SIGCHLD),
        (b"CONT", rt::SIGCONT),
        (b"TSTP", rt::SIGTSTP),
    ];
    named
        .iter()
        .find(|(n, _)| n.eq_ignore_ascii_case(s))
        .map(|&(_, v)| v)
}

/// Parse `NUMBER[smhd]` into milliseconds — same grammar as `sleep`.
fn parse_dur_ms(b: &[u8]) -> Option<u64> {
    let (num, mult) = match b.last() {
        Some(b's') => (&b[..b.len() - 1], 1u64),
        Some(b'm') => (&b[..b.len() - 1], 60),
        Some(b'h') => (&b[..b.len() - 1], 3600),
        Some(b'd') => (&b[..b.len() - 1], 86400),
        _ => (b, 1),
    };
    if num.is_empty() {
        return None;
    }
    let (mut int, mut frac, mut fdig, mut dot) = (0u64, 0u64, 0u32, false);
    for &c in num {
        if c == b'.' {
            if dot {
                return None;
            }
            dot = true;
            continue;
        }
        if !c.is_ascii_digit() {
            return None;
        }
        let d = (c - b'0') as u64;
        if !dot {
            int = int.checked_mul(10)?.checked_add(d)?;
        } else if fdig < 3 {
            frac = frac * 10 + d;
            fdig += 1;
        }
    }
    while fdig < 3 {
        frac *= 10;
        fdig += 1;
    }
    Some((int.checked_mul(1000)?.checked_add(frac)?).checked_mul(mult)?)
}

/// The monotonic clock in ms, or a timeout-own failure (`125`) reported up the stack.
fn now_ms() -> Result<i64, i32> {
    rt::time_monotonic().map_err(|_| 125)
}

/// Blocking reap, retrying through `EINTR`. Returns the child's exit status (or a signal-style
/// 137 if the wait itself fails).
fn reap(pid: i32) -> i32 {
    loop {
        match rt::waitpid(pid) {
            Ok(s) => return s,
            Err(rt::EINTR) => continue,
            Err(_) => return 137,
        }
    }
}

/// The clap command — the single source of `timeout`'s flag surface AND its `--help`. COMMAND is
/// a trailing var-arg so the command's own flags pass through; DURATION precedes it.
fn command() -> Command {
    Command::new("timeout")
        .about("Run COMMAND, terminating it if it is still running after DURATION.")
        .override_usage("timeout [OPTION]... DURATION COMMAND [ARG]...")
        .arg(
            Arg::new("signal")
                .short('s')
                .long("signal")
                .num_args(1)
                .value_name("SIG")
                .help("signal to send on timeout (name or number; default TERM)"),
        )
        .arg(
            Arg::new("kill-after")
                .short('k')
                .long("kill-after")
                .num_args(1)
                .value_name("DURATION")
                .help("also send KILL if still running this long after the first signal"),
        )
        .arg(
            Arg::new("preserve-status")
                .long("preserve-status")
                .action(ArgAction::SetTrue)
                .help("exit with the same status as COMMAND, even when it times out"),
        )
        .arg(
            Arg::new("foreground")
                .long("foreground")
                .action(ArgAction::SetTrue)
                .help("accepted for compatibility; a no-op (no separate process groups)"),
        )
        .arg(
            Arg::new("verbose")
                .short('v')
                .long("verbose")
                .action(ArgAction::SetTrue)
                .help("diagnose to stderr any signal sent upon timeout"),
        )
        .arg(
            Arg::new("DURATION")
                .required(true)
                .value_name("DURATION")
                .help("time limit as N[smhd] (bare number is seconds; fractions allowed)"),
        )
        .arg(
            Arg::new("COMMAND")
                .action(ArgAction::Append)
                .num_args(1..)
                .value_name("COMMAND")
                // COMMAND is the last positional, so it captures everything after DURATION
                // verbatim (including the command's own flags).
                .trailing_var_arg(true)
                .allow_hyphen_values(true)
                .help("the command to run, followed by its arguments (taken verbatim)"),
        )
}

/// `timeout [OPTION]... DURATION COMMAND [ARG]...`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            // GNU timeout exits 125 on its own usage failure; clap returns 0 for help/version.
            return if e.exit_code() == 0 { 0 } else { 125 };
        }
    };

    let preserve = m.get_flag("preserve-status");
    let verbose = m.get_flag("verbose");

    let sig = match m.get_one::<String>("signal") {
        Some(s) => match sig_num(s.as_bytes()) {
            Some(v) => v,
            None => {
                eprintln!("timeout: invalid signal");
                return 125;
            }
        },
        None => rt::SIGTERM,
    };
    let kill_after: Option<u64> = match m.get_one::<String>("kill-after") {
        Some(s) => match parse_dur_ms(s.as_bytes()) {
            Some(v) => Some(v),
            None => {
                eprintln!("timeout: invalid duration");
                return 125;
            }
        },
        None => None,
    };

    let dur = match m.get_one::<String>("DURATION").map(|d| parse_dur_ms(d.as_bytes())) {
        Some(Some(d)) => d,
        Some(None) => {
            eprintln!("timeout: invalid time interval");
            return 125;
        }
        None => {
            eprintln!("timeout: missing duration");
            return 125;
        }
    };

    let cmd: Vec<&str> = m
        .get_many::<String>("COMMAND")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();
    if cmd.is_empty() {
        eprintln!("timeout: missing command");
        return 125;
    }

    // Spawn the child (inherits all three stdio fds).
    let mut blob: Vec<u8> = Vec::new();
    for (j, a) in cmd.iter().enumerate() {
        if j > 0 {
            blob.push(0);
        }
        blob.extend_from_slice(a.as_bytes());
    }
    let pid = match rt::spawn(&blob, rt::STDIN, rt::STDOUT, rt::STDERR) {
        Ok(p) => p as i32,
        Err(_) => {
            eprintln!("timeout: cannot run command");
            return 127;
        }
    };

    // Poll-wait against the deadline.
    let start = match now_ms() {
        Ok(t) => t,
        Err(c) => {
            eprintln!("timeout: monotonic clock unavailable");
            return c;
        }
    };
    let deadline = start + dur as i64;
    loop {
        match rt::waitpid_nohang(pid) {
            Ok(Some((status, _))) => return status, // finished in time
            Ok(None) => {}                           // still running
            Err(rt::EINTR) => continue,
            Err(_) => return 125,
        }
        match now_ms() {
            Ok(t) if t >= deadline => break,
            Ok(_) => {}
            Err(c) => {
                eprintln!("timeout: monotonic clock unavailable");
                return c;
            }
        }
        let _ = rt::sleep_ms(POLL_MS);
    }

    // Timed out: send the signal, optionally escalate to KILL.
    let _ = rt::kill(pid, sig);
    if verbose {
        eprintln!("timeout: sending signal to command");
    }
    let status = if let Some(ka) = kill_after {
        let kd = match now_ms() {
            Ok(t) => t + ka as i64,
            Err(c) => {
                eprintln!("timeout: monotonic clock unavailable");
                return c;
            }
        };
        loop {
            match rt::waitpid_nohang(pid) {
                Ok(Some((st, _))) => break st,
                Ok(None) => {
                    match now_ms() {
                        Ok(t) if t >= kd => {
                            let _ = rt::kill(pid, rt::SIGKILL);
                            break reap(pid);
                        }
                        Ok(_) => {}
                        Err(c) => {
                            eprintln!("timeout: monotonic clock unavailable");
                            return c;
                        }
                    }
                    let _ = rt::sleep_ms(POLL_MS);
                }
                Err(rt::EINTR) => continue,
                Err(_) => break 137,
            }
        }
    } else {
        reap(pid)
    };

    if preserve {
        status
    } else {
        124
    }
}
