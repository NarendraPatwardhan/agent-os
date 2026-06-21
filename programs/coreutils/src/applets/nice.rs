//! `nice [-n ADJUST] [COMMAND [ARG]...]` — run COMMAND with adjusted scheduling niceness
//! (default +10), or, with no COMMAND, print the current niceness. Accepts `-n N`,
//! `--adjustment=N`, and the legacy bare `-N` form (a signed-integer option). Higher niceness
//! means lower priority; the value is inherited by the spawned child.
//!
//! Flags: `-n N`/`--adjustment=N`, the legacy `-N`.
//!
//! Deviations from GNU: only `nice --help`/`nice -h` as the FIRST argument prints help (a
//! `--help` after the COMMAND is passed through to it). Like GNU, `nice`'s own option parsing
//! stops at the first operand, so a dash-option meant for COMMAND is passed through verbatim.
//! The legacy `-N` form cannot be modeled by clap (it looks like an unknown flag), so the
//! option grammar is parsed by hand while clap supplies the `--help` text.
//!
//! Exit status: success (or COMMAND's status) when COMMAND runs; 0 when the niceness is
//! printed; 1 if COMMAND could not be waited on; 125 on a bad adjustment / nice failure; 126 if
//! COMMAND was found but could not run; 127 if COMMAND was not found. Adjusts scheduling and
//! spawns a process → tier_full.
//!
//! Ported from memcontainers' `programs::nice`.

use alloc::vec::Vec;

use clap::{Arg, Command};

use sysroot as rt;

/// Parse a signed decimal integer, or `None`.
fn parse_int(b: &[u8]) -> Option<i32> {
    core::str::from_utf8(b).ok()?.parse::<i32>().ok()
}

/// The clap command — the source of `nice`'s `--help` and documented flag surface. (The legacy
/// `-N` form and the command pass-through are parsed by hand below.)
fn command() -> Command {
    Command::new("nice")
        .about("Run COMMAND with an adjusted niceness, which affects process scheduling. With no COMMAND, print the current niceness. Niceness values range from -20 (most favorable) to 19 (least favorable).")
        .arg(Arg::new("adjustment").short('n').long("adjustment").num_args(1).value_name("N").help("add integer N to the niceness (default 10)"))
        .arg(Arg::new("COMMAND").num_args(0..).help("the program to run (with its arguments) at the adjusted niceness"))
}

/// `nice ...`. Returns the exit status (COMMAND's status, or 0/1/125/126/127 — see the doc).
pub fn uumain(args: impl uucore::Args) -> i32 {
    // Collect argv; the legacy `-N` grammar is parsed by hand (clap cannot model it). `Args` is
    // `Iterator<Item = OsString>`; the lossy String reduction is fine (options are ASCII,
    // command words are UTF-8 paths).
    let raw: Vec<String> = args.map(|a| a.to_string_lossy().into_owned()).collect();
    let toks: Vec<&[u8]> = raw.iter().map(|s| s.as_bytes()).collect();

    // Help only as the FIRST argument (so `nice cmd --help` gives `--help` to cmd).
    if toks
        .get(1)
        .map(|t| *t == b"--help" || *t == b"-h")
        .unwrap_or(false)
    {
        let mut cmd = command();
        let _ = cmd.print_help();
        println!();
        return 0;
    }

    // Parse nice's own options, stopping at the first operand. `-n N`/`-nN`, `--adjustment=N`/
    // `--adjustment N`, and the legacy bare `-N` are all accepted.
    let mut inc: Option<i32> = None;
    let mut i = 1usize; // skip argv[0]
    while i < toks.len() {
        let t = toks[i];
        if t == b"--" {
            i += 1;
            break;
        } else if t == b"-n" {
            i += 1;
            match toks.get(i).and_then(|v| parse_int(v)) {
                Some(v) => inc = Some(v),
                None => {
                    eprintln!("nice: invalid adjustment");
                    return 125;
                }
            }
            i += 1;
        } else if let Some(rest) = t.strip_prefix(b"-n") {
            match parse_int(rest) {
                Some(v) => inc = Some(v),
                None => {
                    eprintln!("nice: invalid adjustment '{}'", String::from_utf8_lossy(rest));
                    return 125;
                }
            }
            i += 1;
        } else if let Some(rest) = t.strip_prefix(b"--adjustment=") {
            match parse_int(rest) {
                Some(v) => inc = Some(v),
                None => {
                    eprintln!("nice: invalid adjustment '{}'", String::from_utf8_lossy(rest));
                    return 125;
                }
            }
            i += 1;
        } else if t == b"--adjustment" {
            i += 1;
            match toks.get(i).and_then(|v| parse_int(v)) {
                Some(v) => inc = Some(v),
                None => {
                    eprintln!("nice: invalid adjustment");
                    return 125;
                }
            }
            i += 1;
        } else if t.len() > 1 && t[0] == b'-' && t != b"-" {
            // Legacy bare `-N` (nice has no other short flags, so any `-<int>` is the value).
            match parse_int(&t[1..]) {
                Some(v) => {
                    inc = Some(v);
                    i += 1;
                }
                None => {
                    eprintln!("nice: invalid option '{}'", String::from_utf8_lossy(t));
                    return 125;
                }
            }
        } else {
            break; // first operand (the command)
        }
    }

    let ops = &toks[i.min(toks.len())..];
    if ops.is_empty() {
        // No command: report the current niceness (adjust by 0 to read it back).
        match rt::nice(0) {
            Ok(v) => println!("{v}"),
            Err(e) => eprintln!("nice: {}", rt::strerror(e)),
        }
        return 0;
    }

    // Adjust our own niceness (default +10); the spawned child inherits it.
    if rt::nice(inc.unwrap_or(10)).is_err() {
        eprintln!("nice: cannot set niceness");
    }

    let mut blob: Vec<u8> = Vec::new();
    for (j, &a) in ops.iter().enumerate() {
        if j > 0 {
            blob.push(0);
        }
        blob.extend_from_slice(a);
    }
    match rt::spawn(&blob, rt::STDIN, rt::STDOUT, rt::STDERR) {
        Ok(pid) => match rt::waitpid(pid as i32) {
            Ok(status) => status,
            Err(_) => 1,
        },
        Err(rt::ENOENT) => {
            eprintln!("nice: {}: No such file or directory", String::from_utf8_lossy(ops[0]));
            127
        }
        Err(e) => {
            eprintln!("nice: {}: {}", String::from_utf8_lossy(ops[0]), rt::strerror(e));
            126
        }
    }
}
