//! `rm [OPTION]... FILE...` — remove files and (with `-r`/`-R`/`--recursive`) directory trees.
//! `-d`/`--dir` removes an empty directory (like `rmdir`); `-f`/`--force` ignores nonexistent
//! operands, never prompts, and never fails on a missing operand; `-i` prompts before every
//! removal; `-v`/`--verbose` prints `removed FILE`. A non-empty directory without `-r` is an
//! error. Recursion is POST-ORDER (children first), since the kernel `unlink` only removes an
//! already-empty directory.
//!
//! Flags: `-r`/`-R`/`--recursive`, `-d`/`--dir`, `-f`/`--force`, `-i`, `-v`/`--verbose`. Args+help
//! are via clap; removal goes through `crate::fsutil::remove_recursive` (for `-r`) / `rt::unlink`.
//! `-i` reads a y/N answer from stdin (reading an inherited stdin needs no capability).
//!
//! Deviations from GNU rm: `-I` (prompt once for many/recursive), `--interactive=WHEN`,
//! `--one-file-system`, `--no-preserve-root`/`--preserve-root`, and `--`-after-`-f` semantics
//! beyond clap's are NOT implemented; there is no root-preservation guard. `-f` overrides `-i`.
//!
//! Exit status: `0` everything removed (or `-f` with nothing to do); `1` a FILE could not be
//! removed; `2` a usage error (clap).
//!
//! Ported from memcontainers' `programs::rm`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

/// Prompt `rm: action target? ` on stderr and read a reply from stdin (for `-i`). Returns true
/// only if the first non-blank character is `y`/`Y`; EOF or anything else is "no".
fn confirm(action: &str, target: &str) -> bool {
    let _ = rt::write_all(rt::STDERR, b"rm: ");
    let _ = rt::write_all(rt::STDERR, action.as_bytes());
    let _ = rt::write_all(rt::STDERR, b" ");
    let _ = rt::write_all(rt::STDERR, target.as_bytes());
    let _ = rt::write_all(rt::STDERR, b"? ");
    let mut buf = [0u8; 64];
    match rt::read(rt::STDIN, &mut buf) {
        Ok(n) if n > 0 => buf[..n]
            .iter()
            .find(|&&b| b != b' ' && b != b'\t')
            .map(|&b| b == b'y' || b == b'Y')
            .unwrap_or(false),
        _ => false,
    }
}

/// The clap command — the single source of `rm`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("rm")
        .about("Remove (unlink) the FILE(s).")
        .arg(
            Arg::new("recursive")
                .short('r')
                .visible_short_alias('R')
                .long("recursive")
                .action(ArgAction::SetTrue)
                .help("remove directories and their contents recursively"),
        )
        .arg(
            Arg::new("dir")
                .short('d')
                .long("dir")
                .action(ArgAction::SetTrue)
                .help("remove empty directories"),
        )
        .arg(
            Arg::new("force")
                .short('f')
                .long("force")
                .action(ArgAction::SetTrue)
                .help("ignore nonexistent files and arguments, never prompt"),
        )
        .arg(
            Arg::new("interactive")
                .short('i')
                .action(ArgAction::SetTrue)
                .help("prompt before every removal"),
        )
        .arg(
            Arg::new("verbose")
                .short('v')
                .long("verbose")
                .action(ArgAction::SetTrue)
                .help("explain what is being done"),
        )
        .arg(
            Arg::new("FILE")
                .action(ArgAction::Append)
                .num_args(0..)
                .help("the files to remove"),
        )
}

/// `rm [OPTION]... FILE...`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let recursive = m.get_flag("recursive");
    let dir_ok = m.get_flag("dir");
    let force = m.get_flag("force");
    let verbose = m.get_flag("verbose");
    let interactive = m.get_flag("interactive") && !force;
    let ops: Vec<&str> = m
        .get_many::<String>("FILE")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();

    if ops.is_empty() {
        if force {
            return 0; // `rm -f` with no operands is a silent success.
        }
        eprintln!("rm: missing operand");
        return 1;
    }

    let mut rc = 0;
    for path in &ops {
        if !fsutil::exists(path) {
            if !force {
                eprintln!("rm: {}: {}", path, rt::strerror(rt::ENOENT));
                rc = 1;
            }
            continue;
        }
        // A directory needs -r (any contents) or -d (empty). `rt::unlink` itself
        // refuses a non-empty directory, so -d delegates that check to the kernel.
        if fsutil::is_dir(path) && !recursive && !dir_ok {
            eprintln!("rm: {}: is a directory", path);
            rc = 1;
            continue;
        }
        if interactive && !confirm("remove", path) {
            continue;
        }
        let res = if recursive {
            fsutil::remove_recursive(path)
        } else {
            rt::unlink(path)
        };
        match res {
            Ok(()) => {
                if verbose {
                    let _ = rt::write_all(rt::STDOUT, b"removed ");
                    let _ = rt::write_all(rt::STDOUT, path.as_bytes());
                    let _ = rt::write_all(rt::STDOUT, b"\n");
                }
            }
            Err(e) => {
                eprintln!("rm: {}: {}", path, rt::strerror(e));
                rc = 1;
            }
        }
    }
    rc
}
