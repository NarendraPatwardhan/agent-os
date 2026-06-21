//! `xargs [OPTION]... [COMMAND [INITIAL-ARG]...]` — build command lines from standard input and
//! run them. Items are split on whitespace (or NUL with `-0`); batched by `-n N` (max args)
//! and/or `-s BYTES` (max line length); `-I R` replaces `R` in the command with each item (one
//! item per run); `-r` skips an empty input; `-t` traces each command line to stderr before
//! running it; `-E EOF` stops reading at an input item equal to EOF. The default command is
//! `echo`. A native mc guest: each batch runs via `rt::spawn`/`rt::waitpid`.
//!
//! Flags: `-0`/`--null`, `-n N`, `-s BYTES`, `-I R`, `-r`/`--no-run-if-empty`, `-t`/`--verbose`,
//! `-E EOF`. Deviations from GNU `xargs`: `-P` (parallel), `-a`/`--arg-file`, `-d`/`--delimiter`,
//! `-o`, `-x`, `-p` prompting, and `--process-slot-var` are NOT supported (`-p` is treated like
//! `-t` — there is no TTY prompt). `-L N` and `-e EOF` are accepted as approximate aliases of
//! `-n N` and `-E`. The child's stdin is `/dev/null` (the item stream is consumed by xargs).
//! Only `xargs --help`/`-h` as the FIRST token prints help, so `xargs CMD --help` runs
//! `CMD --help` (clap trailing-var-arg). xargs slurps stdin to batch it (bounded by input size,
//! the nature of the algorithm — GNU buffers likewise).
//!
//! Exit status: `0` success; `123` if any command exited with a non-zero status (or could not
//! be waited on); `127` if a command could not be run.
//!
//! Ported from memcontainers' `programs::xargs`.

use alloc::string::String;
use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

/// Parsed option state (mirrors memcontainers' `Opts`).
struct Opts {
    null: bool,
    max_args: Option<usize>,
    max_bytes: Option<usize>,
    replace: Option<Vec<u8>>,
    no_run_if_empty: bool,
    trace: bool,
    eof: Option<Vec<u8>>,
}

/// Parse a `usize` from bytes, defaulting to 0 on garbage (GNU treats a bad count loosely).
fn parse_usize(b: &[u8]) -> usize {
    core::str::from_utf8(b)
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}

/// Replace every occurrence of `from` in `arg` with `to` (the `-I` substitution).
fn replace_all(arg: &[u8], from: &[u8], to: &[u8]) -> Vec<u8> {
    if from.is_empty() {
        return arg.to_vec();
    }
    let mut out = Vec::new();
    let mut i = 0;
    while i < arg.len() {
        if i + from.len() <= arg.len() && &arg[i..i + from.len()] == from {
            out.extend_from_slice(to);
            i += from.len();
        } else {
            out.push(arg[i]);
            i += 1;
        }
    }
    out
}

/// Run one assembled command line: trace it (if `-t`), spawn with the given child stdin, wait,
/// and fold the result into `rc` (123 non-zero status / not-waitable, 127 spawn failure).
fn run_batch(args: &[Vec<u8>], child_in: i32, o: &Opts, rc: &mut i32) {
    if o.trace {
        for (i, a) in args.iter().enumerate() {
            if i > 0 {
                let _ = rt::write_all(rt::STDERR, b" ");
            }
            let _ = rt::write_all(rt::STDERR, a);
        }
        let _ = rt::write_all(rt::STDERR, b"\n");
    }
    let mut blob: Vec<u8> = Vec::new();
    for (i, a) in args.iter().enumerate() {
        if i > 0 {
            blob.push(0);
        }
        blob.extend_from_slice(a);
    }
    match rt::spawn(&blob, child_in, rt::STDOUT, rt::STDERR) {
        Ok(pid) => loop {
            match rt::waitpid(pid as i32) {
                Ok(status) => {
                    if status != 0 {
                        *rc = 123; // xargs: a command exited non-zero
                    }
                    break;
                }
                Err(rt::EINTR) => continue,
                Err(_) => {
                    *rc = 123;
                    break;
                }
            }
        },
        Err(_) => {
            eprintln!("xargs: {}: cannot run command", String::from_utf8_lossy(&args[0]));
            *rc = 127;
        }
    }
}

/// The clap command — the single source of `xargs`'s flag surface AND its `--help`. COMMAND +
/// INITIAL-ARGS are trailing var-args so the command's own flags pass through untouched.
fn command() -> Command {
    Command::new("xargs")
        .about("Build and run command lines from items read on standard input (default COMMAND: echo).")
        .override_usage("xargs [OPTION]... [COMMAND [INITIAL-ARG]...]")
        .arg(
            Arg::new("null")
                .short('0')
                .long("null")
                .action(ArgAction::SetTrue)
                .help("items are separated by NUL, not whitespace"),
        )
        .arg(
            Arg::new("max-args")
                .short('n')
                .num_args(1)
                .value_name("N")
                .help("use at most N items per command line"),
        )
        .arg(
            Arg::new("max-chars")
                .short('s')
                .num_args(1)
                .value_name("BYTES")
                .help("limit each command line to at most BYTES bytes"),
        )
        .arg(
            Arg::new("replace")
                .short('I')
                .num_args(1)
                .value_name("R")
                .help("replace R in COMMAND with each item (one item per run; implies -n 1)"),
        )
        .arg(
            Arg::new("no-run-if-empty")
                .short('r')
                .long("no-run-if-empty")
                .action(ArgAction::SetTrue)
                .help("do not run COMMAND if the input is empty"),
        )
        .arg(
            Arg::new("verbose")
                .short('t')
                .long("verbose")
                .action(ArgAction::SetTrue)
                .help("print each command line to stderr before running it"),
        )
        .arg(
            Arg::new("interactive")
                .short('p')
                .long("interactive")
                .action(ArgAction::SetTrue)
                .help("no TTY prompt in this model; treated like -t (trace)"),
        )
        .arg(
            Arg::new("eof")
                .short('E')
                .num_args(1)
                .value_name("EOF")
                .help("stop reading at an input item equal to EOF"),
        )
        .arg(
            Arg::new("eof-e")
                .short('e')
                .num_args(1)
                .value_name("EOF")
                .help("alias of -E"),
        )
        .arg(
            Arg::new("max-lines")
                .short('L')
                .num_args(1)
                .value_name("N")
                .help("approximate alias of -n N (one item per line for single-column input)"),
        )
        .arg(
            Arg::new("COMMAND")
                .action(ArgAction::Append)
                .num_args(0..)
                .value_name("COMMAND")
                // COMMAND + its INITIAL-ARGS are the last positional, captured verbatim
                // (including the command's own flags) once the first word is seen.
                .trailing_var_arg(true)
                .allow_hyphen_values(true)
                .help("the command to run with items appended (default: echo)"),
        )
}

/// `xargs [OPTION]... [COMMAND [INITIAL-ARG]...]`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    // `-L` and `-n` both set max_args; `-I` forces 1; the last on the line wins via fold below.
    let max_args = m
        .get_one::<String>("max-args")
        .or_else(|| m.get_one::<String>("max-lines"))
        .map(|s| parse_usize(s.as_bytes()).max(1));
    let replace = m.get_one::<String>("replace").map(|s| s.as_bytes().to_vec());
    let o = Opts {
        null: m.get_flag("null"),
        // -I implies -n 1; otherwise honor -n / -L.
        max_args: if replace.is_some() { Some(1) } else { max_args },
        max_bytes: m.get_one::<String>("max-chars").map(|s| parse_usize(s.as_bytes())),
        replace,
        no_run_if_empty: m.get_flag("no-run-if-empty"),
        trace: m.get_flag("verbose") || m.get_flag("interactive"),
        eof: m
            .get_one::<String>("eof")
            .or_else(|| m.get_one::<String>("eof-e"))
            .map(|s| s.as_bytes().to_vec()),
    };

    // COMMAND + INITIAL-ARGS; default to `echo`.
    let mut cmd: Vec<Vec<u8>> = m
        .get_many::<String>("COMMAND")
        .map(|v| v.map(|s| s.as_bytes().to_vec()).collect())
        .unwrap_or_default();
    if cmd.is_empty() {
        cmd.push(b"echo".to_vec());
    }

    // Slurp stdin (the items) — xargs must hold all items to batch them.
    let mut input: Vec<u8> = Vec::new();
    let _ = textio::read_all(rt::STDIN, &mut input);

    // Split into items (NUL with -0, else any ASCII whitespace).
    let mut items: Vec<Vec<u8>> = Vec::new();
    if o.null {
        for part in input.split(|&b| b == 0) {
            if !part.is_empty() {
                items.push(part.to_vec());
            }
        }
    } else {
        for part in input.split(|b| matches!(b, b' ' | b'\t' | b'\n' | b'\r' | 0x0b | 0x0c)) {
            if !part.is_empty() {
                items.push(part.to_vec());
            }
        }
    }
    if let Some(eof) = &o.eof {
        if let Some(p) = items.iter().position(|it| it == eof) {
            items.truncate(p);
        }
    }

    if items.is_empty() && o.no_run_if_empty {
        return 0;
    }

    // The child's stdin must NOT be the (drained) item stream — use /dev/null.
    let child_in = rt::open("/dev/null", rt::O_READ).unwrap_or(rt::STDIN);

    let mut rc = 0;
    if let Some(repl) = &o.replace {
        // Replace mode: one item per run, substituting `repl` inside each arg.
        let to_run: &[Vec<u8>] = if items.is_empty() {
            &[Vec::new()][..]
        } else {
            &items
        };
        for item in to_run {
            let mut full: Vec<Vec<u8>> = Vec::with_capacity(cmd.len());
            for c in &cmd {
                full.push(replace_all(c, repl, item));
            }
            run_batch(&full, child_in, &o, &mut rc);
        }
    } else {
        // Batch items by -n / -s onto the end of the command.
        let mut idx = 0;
        let at_least_once = items.is_empty() && !o.no_run_if_empty;
        loop {
            if idx >= items.len() && !at_least_once {
                break;
            }
            let mut full: Vec<Vec<u8>> = cmd.clone();
            let base_bytes: usize = cmd.iter().map(|c| c.len() + 1).sum();
            let mut bytes = base_bytes;
            let mut count = 0;
            while idx < items.len() {
                if let Some(maxn) = o.max_args {
                    if count >= maxn {
                        break;
                    }
                }
                if let Some(maxb) = o.max_bytes {
                    if count > 0 && bytes + items[idx].len() + 1 > maxb {
                        break;
                    }
                }
                bytes += items[idx].len() + 1;
                full.push(items[idx].clone());
                count += 1;
                idx += 1;
            }
            run_batch(&full, child_in, &o, &mut rc);
            if items.is_empty() {
                break; // the single at-least-once run
            }
        }
    }

    rc
}
