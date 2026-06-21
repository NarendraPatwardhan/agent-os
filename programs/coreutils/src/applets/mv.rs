//! `mv [OPTION]... SOURCE... DEST` — move/rename files. Implements the POSIX userspace
//! conventions: rename when DEST is a new name, move INTO an existing directory (appending the
//! basename), multiple sources into a directory, overwrite, and a COPY+REMOVE fallback when the
//! rename crosses mounts (`EXDEV`). The kernel `rename` provides the atomic same-mount primitive
//! (overwrite + directory rename). `-f`/`--force` does not prompt (and overrides `-i`/`-n`);
//! `-i`/`--interactive` prompts before overwriting; `-n`/`--no-clobber` never overwrites;
//! `-v`/`--verbose` prints `SOURCE -> DEST`.
//!
//! Flags: `-f`/`--force`, `-i`/`--interactive`, `-n`/`--no-clobber`, `-v`/`--verbose`. Args+help
//! are via clap; the move uses `rt::rename`, falling back to `crate::fsutil`
//! (`copy_recursive`/`preserve_meta`/`remove_recursive`) on `EXDEV`. `-i` reads a y/N answer
//! from stdin.
//!
//! Deviations from GNU mv: `-t`/`--target-directory`, `-T`/`--no-target-directory`, `-u`/
//! `--update`, `-b`/`--backup`, and `--strip-trailing-slashes` are NOT implemented.
//!
//! Exit status: `0` every source moved; `1` a source could not be moved; `2` a usage error
//! (clap) — missing SOURCE, missing DEST, or several sources with a non-directory DEST.
//!
//! Ported from memcontainers' `programs::mv`.

use alloc::string::String;
use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

/// Prompt `mv: action target? ` on stderr and read a reply from stdin (for `-i`). Returns true
/// only if the first non-blank character is `y`/`Y`; EOF or anything else is "no".
fn confirm(action: &str, target: &str) -> bool {
    let _ = rt::write_all(rt::STDERR, b"mv: ");
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

/// `src -> dst` line on stdout (for `-v`).
fn verbose_line(src: &str, dst: &str) {
    let _ = rt::write_all(rt::STDOUT, src.as_bytes());
    let _ = rt::write_all(rt::STDOUT, b" -> ");
    let _ = rt::write_all(rt::STDOUT, dst.as_bytes());
    let _ = rt::write_all(rt::STDOUT, b"\n");
}

/// The clap command — the single source of `mv`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("mv")
        .about("Rename SOURCE to DEST, or move SOURCE(s) to an existing DIRECTORY.")
        .arg(
            Arg::new("force")
                .short('f')
                .long("force")
                .action(ArgAction::SetTrue)
                .help("do not prompt before overwriting (overrides -i and -n)"),
        )
        .arg(
            Arg::new("interactive")
                .short('i')
                .long("interactive")
                .action(ArgAction::SetTrue)
                .help("prompt before overwriting an existing file"),
        )
        .arg(
            Arg::new("no-clobber")
                .short('n')
                .long("no-clobber")
                .action(ArgAction::SetTrue)
                .help("do not overwrite an existing file"),
        )
        .arg(
            Arg::new("verbose")
                .short('v')
                .long("verbose")
                .action(ArgAction::SetTrue)
                .help("explain what is being done (SOURCE -> DEST)"),
        )
        .arg(
            Arg::new("PATHS")
                .action(ArgAction::Append)
                .num_args(0..)
                .help("the source(s) followed by the destination"),
        )
}

/// `mv [OPTION]... SOURCE... DEST`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let paths: Vec<&str> = m
        .get_many::<String>("PATHS")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();
    if paths.is_empty() {
        eprintln!("mv: missing file operand");
        return 1;
    }
    if paths.len() < 2 {
        eprintln!("mv: {}: missing destination file operand", paths[0]);
        return 1;
    }

    let force = m.get_flag("force");
    let no_clobber = m.get_flag("no-clobber") && !force;
    let verbose = m.get_flag("verbose");
    let interactive = m.get_flag("interactive") && !force && !no_clobber;

    let (sources, dest_slot) = paths.split_at(paths.len() - 1);
    let dest = dest_slot[0];
    let dest_is_dir = fsutil::is_dir(dest);
    if sources.len() > 1 && !dest_is_dir {
        eprintln!("mv: {}: not a directory", dest);
        return 1;
    }

    let mut rc = 0;
    for &src in sources {
        let dst = if dest_is_dir {
            fsutil::join(dest, fsutil::basename(src))
        } else {
            String::from(dest)
        };
        if no_clobber && fsutil::exists(&dst) {
            continue;
        }
        if interactive && fsutil::exists(&dst) && !confirm("overwrite", &dst) {
            continue;
        }
        let moved = match rt::rename(src, &dst) {
            Ok(()) => true,
            // Cross-mount move: copy the subtree then remove the source. A move
            // preserves metadata, so carry mode + times across the copy (a
            // same-mount rename keeps them for free — the inode moves).
            Err(rt::EXDEV) => {
                if let Err(e) = fsutil::copy_recursive(src, &dst) {
                    eprintln!("mv: {}: {}", src, rt::strerror(e));
                    rc = 1;
                    continue;
                }
                fsutil::preserve_meta(src, &dst, true);
                match fsutil::remove_recursive(src) {
                    Ok(()) => true,
                    Err(e) => {
                        eprintln!("mv: {}: {}", src, rt::strerror(e));
                        rc = 1;
                        false
                    }
                }
            }
            Err(e) => {
                eprintln!("mv: {}: {}", src, rt::strerror(e));
                rc = 1;
                false
            }
        };
        if moved && verbose {
            verbose_line(src, &dst);
        }
    }
    rc
}
