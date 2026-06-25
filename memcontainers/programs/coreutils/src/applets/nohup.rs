//! `nohup COMMAND [ARG]...` — run COMMAND immune to hangups. `nohup` ignores `SIGHUP` (so the
//! job survives its controlling session ending) and, matching GNU, redirects any of
//! stdout/stderr that is still a terminal to a `nohup.out` file in the current directory
//! (created or appended), so the command keeps producing output after the session is gone. It
//! takes no options of its own — every argument after the program name is part of COMMAND —
//! except `--help`/`-h` recognized ONLY as the first argument (so `nohup cmd --help` runs
//! `cmd --help`, while `nohup --help` prints this help).
//!
//! Deviations from POSIX/GNU `nohup`: help is first-argument-only (clap's trailing-var-arg
//! model: the COMMAND words, including a later `--help`, pass through verbatim); there is no
//! `-p`/`--no-redirect` and no output-file override. The child's stdin is the inherited stdin
//! (a guest's default stdin is already an empty/EOF source, equivalent to GNU's redirect from
//! `/dev/null`). Spawned via `//sysroot` (`rt::spawn`/`rt::waitpid`), so the applet is
//! `tier_full` (SPAWN).
//!
//! Exit status: the command's own status; `125` if `nohup` itself fails (missing operand,
//! could not open `nohup.out`); `127` if COMMAND could not be run.
//!
//! Ported from memcontainers' `programs::nohup`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use sysroot as rt;

/// Open (or create/append) `nohup.out` in the cwd, GNU's redirect target for a tty stream.
fn open_nohup_out() -> Option<i32> {
    rt::open("nohup.out", rt::O_WRITE | rt::O_CREATE | rt::O_APPEND).ok()
}

/// The clap command — the single source of `nohup`'s surface AND its `--help`. `nohup` has no
/// options of its own; COMMAND is a trailing var-arg so its own flags pass through untouched.
fn command() -> Command {
    Command::new("nohup")
        .about("Run COMMAND immune to hangups, with output to a non-tty (nohup.out if stdout is a terminal).")
        .override_usage("nohup COMMAND [ARG]...")
        .arg(
            Arg::new("COMMAND")
                .action(ArgAction::Append)
                .num_args(1..)
                .value_name("COMMAND")
                // The COMMAND and its arguments are taken verbatim: a trailing var-arg captures
                // everything (including the command's own flags) once the first word is seen.
                .trailing_var_arg(true)
                .allow_hyphen_values(true)
                .help("the command to run, followed by its arguments (taken verbatim)"),
        )
}

/// `nohup COMMAND [ARG]...`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        // clap prints help/usage/version itself; mirror its exit code (0 for --help/--version).
        Err(e) => {
            let _ = e.print();
            // GNU nohup exits 125 on its own usage failure; clap returns 0 for help/version.
            return if e.exit_code() == 0 { 0 } else { 125 };
        }
    };

    let cmd: Vec<&str> = m
        .get_many::<String>("COMMAND")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();
    if cmd.is_empty() {
        eprintln!("nohup: missing operand");
        return 125;
    }

    // Immune to hangups (before any I/O — like GNU, established up front).
    let _ = rt::sigdisp(rt::SIGHUP, rt::SIG_IGN);

    // Redirect a terminal stdout/stderr to `nohup.out` (GNU default). A stream the caller
    // already redirected (not a tty) is left untouched.
    let mut out_fd = rt::STDOUT;
    let mut err_fd = rt::STDERR;
    let mut redirect_fd: Option<i32> = None;
    if rt::isatty(rt::STDOUT) {
        match open_nohup_out() {
            Some(fd) => {
                eprintln!("nohup: ignoring input and appending output to 'nohup.out'");
                out_fd = fd;
                redirect_fd = Some(fd);
            }
            None => {
                eprintln!("nohup: failed to open nohup.out");
                return 125;
            }
        }
    }
    if rt::isatty(rt::STDERR) {
        // stderr follows stdout's destination: `nohup.out` if stdout was a tty, otherwise the
        // caller's already-redirected stdout.
        err_fd = redirect_fd.unwrap_or(out_fd);
    }

    // Build the NUL-separated argv blob (argv[0] = the command name).
    let mut blob: Vec<u8> = Vec::new();
    for (i, a) in cmd.iter().enumerate() {
        if i > 0 {
            blob.push(0);
        }
        blob.extend_from_slice(a.as_bytes());
    }

    match rt::spawn(&blob, rt::STDIN, out_fd, err_fd) {
        Ok(pid) => loop {
            match rt::waitpid(pid as i32) {
                Ok(status) => return status,
                Err(rt::EINTR) => continue,
                Err(_) => return 127,
            }
        },
        Err(_) => {
            eprintln!("nohup: {}: command not found", cmd[0]);
            127
        }
    }
}
