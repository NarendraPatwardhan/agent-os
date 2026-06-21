//! `kill [-s SIGNAL | -SIGNAL] PID...` / `kill -l [SPEC]...` — send a signal (default `TERM`)
//! to processes by pid (a negative pid targets a process group). A signal may be given by name
//! (`TERM`, `KILL`, `INT`, …, with or without a `SIG` prefix) or by number. `-l` lists the
//! known signal names, or converts a SPEC (number → name, name → number; an exit-status > 128
//! maps to signal status-128).
//!
//! Flags: `-s SIGNAL`/`--signal SIGNAL`, the bare `-SIGNAL` form (`-9`, `-KILL`, `-HUP`),
//! `-l`/`--list [SPEC]...`, `-L`/`--table` (alias of `-l`).
//!
//! Deviations from GNU/POSIX: the supported signals are limited to HUP INT KILL TERM CHLD CONT
//! TSTP (mirroring the kernel's ABI set). No `%jobspec` operands (use the shell's `kill`
//! builtin for jobs); no `-q` (sigqueue value). The `-SIGNAL` syntax (e.g. `-9`) cannot be
//! modeled by clap's option grammar, so clap supplies only the `--help` text and the
//! documented surface; the signal/pid grammar is parsed by hand (the ported logic), exactly as
//! GNU's own `kill` must.
//!
//! Exit status: 0 on success; 1 on an invalid signal/pid or a process that could not be
//! signalled. Sends signals (`kill` syscall) → tier_full.
//!
//! Ported from memcontainers' `programs::kill`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

/// The supported signals (name without the `SIG` prefix → number). Mirrors the kernel ABI's
/// set; the single source for `sig_num`/`sig_name`/`-l`.
fn signals() -> [(&'static [u8], i32); 7] {
    [
        (b"HUP", rt::SIGHUP),
        (b"INT", rt::SIGINT),
        (b"KILL", rt::SIGKILL),
        (b"TERM", rt::SIGTERM),
        (b"CHLD", rt::SIGCHLD),
        (b"CONT", rt::SIGCONT),
        (b"TSTP", rt::SIGTSTP),
    ]
}

/// Resolve a signal spec (name with optional `SIG` prefix, or a number) to its number.
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
    signals()
        .iter()
        .find(|(n, _)| n.eq_ignore_ascii_case(s))
        .map(|&(_, v)| v)
}

/// The name (no `SIG` prefix) for a signal number, if known.
fn sig_name(num: i32) -> Option<&'static [u8]> {
    signals()
        .iter()
        .find(|(_, v)| *v == num)
        .map(|&(n, _)| n)
}

/// Append `n`'s decimal digits to `out`.
fn push_dec(out: &mut BufOut, n: u32) {
    let mut tmp = [0u8; 12];
    let mut i = tmp.len();
    let mut v = n;
    if v == 0 {
        i -= 1;
        tmp[i] = b'0';
    }
    while v > 0 {
        i -= 1;
        tmp[i] = b'0' + (v % 10) as u8;
        v /= 10;
    }
    out.extend(&tmp[i..]);
}

/// `kill -l [SPEC...]`: with no SPEC, list every known signal name; with SPECs, convert each
/// (number → name, name → number, exit-status > 128 → status-128). Returns the exit status.
fn list_signals(specs: &[&[u8]]) -> i32 {
    let mut out = BufOut::new();
    if specs.is_empty() {
        let mut first = true;
        for (name, _) in signals() {
            if !first {
                out.push(b' ');
            }
            out.extend(name);
            first = false;
        }
        out.push(b'\n');
        let _ = out.finish();
        return 0;
    }
    let mut rc = 0;
    for &spec in specs {
        // A bare number: print the name (mapping an exit status > 128 down).
        if !spec.is_empty() && spec.iter().all(|c| c.is_ascii_digit()) {
            let mut v: i32 = 0;
            for &c in spec {
                v = v.saturating_mul(10).saturating_add((c - b'0') as i32);
            }
            let n = if v > 128 { v - 128 } else { v };
            match sig_name(n) {
                Some(name) => {
                    out.extend(name);
                    out.push(b'\n');
                }
                None => {
                    let _ = out.finish();
                    eprintln!("kill: {}: invalid signal specification", String::from_utf8_lossy(spec));
                    rc = 1;
                }
            }
        } else if let Some(n) = sig_num(spec) {
            // A name: print the number.
            push_dec(&mut out, n.unsigned_abs());
            out.push(b'\n');
        } else {
            let _ = out.finish();
            eprintln!("kill: {}: invalid signal specification", String::from_utf8_lossy(spec));
            rc = 1;
        }
    }
    let _ = out.finish();
    rc
}

/// Parse a pid operand (an optional leading `-` for a process group).
fn parse_pid(b: &[u8]) -> Option<i32> {
    let (neg, d) = if b.first() == Some(&b'-') {
        (true, &b[1..])
    } else {
        (false, b)
    };
    if d.is_empty() || !d.iter().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let mut v: i32 = 0;
    for &c in d {
        v = v.checked_mul(10)?.checked_add((c - b'0') as i32)?;
    }
    Some(if neg { -v } else { v })
}

/// The clap command — the source of `kill`'s `--help` and documented flag surface. (The
/// `-SIGNAL` / pid grammar is parsed by hand below; clap cannot model `-9`.)
fn command() -> Command {
    Command::new("kill")
        .about("Send a signal to processes by PID (default TERM). A negative PID targets a process group.")
        .arg(Arg::new("signal").short('s').long("signal").num_args(1).value_name("SIGNAL").help("send SIGNAL (name or number) instead of the default TERM"))
        .arg(Arg::new("list").short('l').long("list").action(ArgAction::SetTrue).help("list signal names, or convert SPEC (number<->name)"))
        .arg(Arg::new("table").short('L').long("table").action(ArgAction::SetTrue).help("alias of -l: list/convert signal names"))
        .arg(Arg::new("ARGS").action(ArgAction::Append).num_args(0..).help("-SIGNAL selector and PID(s), or SPEC(s) with -l"))
}

/// `kill ...`. Returns the exit status (0 success; 1 an invalid signal/pid or failed signal).
pub fn uumain(args: impl uucore::Args) -> i32 {
    // Collect argv so the nonstandard `-SIGNAL` grammar can be parsed by hand (clap cannot
    // model `-9`). `Args` is `Iterator<Item = OsString>`; signals and pids are ASCII, so the
    // lossy String reduction loses nothing. `--help`/`-h` is served by clap (the help source)
    // before any custom parsing.
    let raw: Vec<String> = args.map(|a| a.to_string_lossy().into_owned()).collect();
    let parts: Vec<&[u8]> = raw.iter().map(|s| s.as_bytes()).collect();

    // Help: a long `--help` or bare `-h` anywhere in the operands (before `--`).
    for &t in parts.iter().skip(1) {
        if t == b"--" {
            break;
        }
        if t == b"--help" || t == b"-h" {
            let mut cmd = command();
            let _ = cmd.print_help();
            println!();
            return 0;
        }
    }

    // Drop argv[0] and any empty tokens for the positional grammar (matching the original).
    let toks: Vec<&[u8]> = parts
        .iter()
        .skip(1)
        .copied()
        .filter(|s| !s.is_empty())
        .collect();

    // `-l`/`-L`/`--list`: list or convert signals (everything after it is a SPEC).
    if toks
        .first()
        .map(|t| *t == b"-l" || *t == b"-L" || *t == b"--list")
        .unwrap_or(false)
    {
        return list_signals(&toks[1.min(toks.len())..]);
    }

    let mut sig = rt::SIGTERM;
    let mut i = 0usize;
    // Optional leading signal selector: `-s SIGNAL`, `--signal SIGNAL`, or a bare `-SIGNAL`.
    while i < toks.len() {
        let t = toks[i];
        if t == b"-s" || t == b"--signal" {
            i += 1;
            match toks.get(i).and_then(|s| sig_num(s)) {
                Some(s) => sig = s,
                None => {
                    eprintln!("kill: invalid signal");
                    return 1;
                }
            }
            i += 1;
            break;
        }
        if t == b"--" {
            i += 1;
            break;
        }
        if t.len() > 1 && t[0] == b'-' {
            match sig_num(&t[1..]) {
                Some(s) => {
                    sig = s;
                    i += 1;
                    continue;
                }
                None => {
                    eprintln!("kill: invalid signal");
                    return 1;
                }
            }
        }
        break;
    }

    let pids = &toks[i.min(toks.len())..];
    if pids.is_empty() {
        eprintln!("kill: usage: kill [-s SIGNAL | -SIGNAL] PID...");
        return 1;
    }

    let mut rc = 0;
    for &p in pids {
        match parse_pid(p) {
            Some(pid) => {
                if rt::kill(pid, sig).is_err() {
                    eprintln!("kill: {}: no such process", String::from_utf8_lossy(p));
                    rc = 1;
                }
            }
            None => {
                eprintln!("kill: {}: arguments must be process or job IDs", String::from_utf8_lossy(p));
                rc = 1;
            }
        }
    }
    rc
}
