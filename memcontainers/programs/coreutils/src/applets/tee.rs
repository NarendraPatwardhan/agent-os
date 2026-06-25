//! `tee [-a] [FILE]...` — copy standard input to standard output AND to each FILE.
//!
//! Reads stdin in bounded chunks and writes each chunk verbatim to stdout and to every
//! FILE — byte-exact, no line model, no buffering beyond the read chunk, so peak memory is
//! one chunk regardless of input size. `-a`/`--append` appends to each FILE instead of
//! truncating it (the default truncates/creates). Failing to OPEN one FILE is reported and
//! sets a non-zero exit, but copying to stdout and the remaining files continues (GNU
//! behavior).
//!
//! Flags: `-a`/`--append`, `--help`.
//!
//! GNU deviations: no `-i`/`--ignore-interrupts` (signals are not delivered asynchronously
//! here); no `-p` / `--output-error[=MODE]` write-error mode selection — a write error to a
//! FILE or to stdout is silently best-effort (matching the original port), and only an OPEN
//! failure raises the exit status. Output is not flushed/`fsync`ed per write beyond the
//! kernel's own semantics.
//!
//! Exit status: 0 success; 1 if a FILE could not be opened.
//!
//! Ported from memcontainers' `programs::tee`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use sysroot as rt;

/// The clap command — the single source of `tee`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("tee")
        .about("Copy standard input to each FILE, and also to standard output.")
        .arg(
            Arg::new("append")
                .short('a')
                .long("append")
                .action(ArgAction::SetTrue)
                .help("append to the given FILEs, do not overwrite"),
        )
        .arg(
            Arg::new("FILE")
                .action(ArgAction::Append)
                .num_args(0..)
                .help("files to write standard input to (also written to standard output)"),
        )
}

/// `tee [-a] [FILE]...`. Returns the exit status (0 success; 1 if a FILE could not be opened).
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        // clap prints help/usage/version itself; mirror its exit code (0 for --help/--version).
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let append = m.get_flag("append");
    let ops: Vec<&str> = m
        .get_many::<String>("FILE")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();

    let flags = rt::O_WRITE
        | rt::O_CREATE
        | if append { rt::O_APPEND } else { rt::O_TRUNC };

    let mut fds: Vec<i32> = Vec::new();
    let mut rc = 0;
    for o in &ops {
        match rt::open(o, flags) {
            Ok(fd) => fds.push(fd),
            Err(e) => {
                eprintln!("tee: {}: {}", o, rt::strerror(e));
                rc = 1;
            }
        }
    }

    let mut buf = [0u8; 8192];
    loop {
        match rt::read(rt::STDIN, &mut buf) {
            Ok(0) => break,
            Ok(k) => {
                let _ = rt::write_all(rt::STDOUT, &buf[..k]);
                for &fd in &fds {
                    let _ = rt::write_all(fd, &buf[..k]);
                }
            }
            Err(_) => break,
        }
    }
    for &fd in &fds {
        rt::close(fd);
    }
    rc
}
