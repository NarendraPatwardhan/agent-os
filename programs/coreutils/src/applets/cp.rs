//! `cp [OPTION]... SRC... DST` — copy files and directory trees. Supports the directory-
//! destination convention (`cp f… DIR` copies each into DIR), multiple sources, and recursive
//! copy. `-r`/`-R`/`--recursive` copies directories; `-a`/`--archive` is `-R -p` plus symlink
//! preservation (a link is recreated, not dereferenced); `-p`/`--preserve` additionally preserves
//! mtime/atime (the source's mode bits are ALWAYS copied, even without `-p`, per POSIX); `-n`/
//! `--no-clobber` never overwrites; `-i`/`--interactive` asks before overwriting; `-f`/`--force`
//! force-removes an undeletable destination and retries; `-v`/`--verbose` prints each
//! `src -> dst`. Contents stream in bounded chunks via `crate::fsutil`.
//!
//! Flag precedence: `-f` overrides `-n`, and both override `-i`. Args+help are via clap; the copy
//! engine is `crate::fsutil` (`copy_file`/`copy_recursive`/`copy_tree`/`preserve_meta`) over
//! `//sysroot`. `-i` reads a y/N answer from stdin.
//!
//! Deviations from GNU cp: `--backup`, `-u`/`--update`, `-l`/`--link`, `-s`/`--symbolic-link`,
//! `--reflink`, `--sparse`, and `-t`/`-T` target-directory control are NOT implemented; `-p`
//! preserves times + mode only (no owner/group/xattrs — the VM is single-subject); `--preserve`
//! takes no value (it is `-p`, not `--preserve=ATTR_LIST`).
//!
//! Exit status: `0` every source copied; `1` a source could not be read or a destination written;
//! `2` a usage error (clap) — missing SRC, missing DST, or several sources with a non-directory
//! DST.
//!
//! Ported from memcontainers' `programs::cp`.

use alloc::string::String;
use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

/// Prompt `cp: action target? ` on stderr and read a reply from stdin (for `-i`). Returns true
/// only if the first non-blank character is `y`/`Y`; EOF or anything else is "no".
fn confirm(action: &str, target: &str) -> bool {
    let _ = rt::write_all(rt::STDERR, b"cp: ");
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

/// The clap command — the single source of `cp`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("cp")
        .about("Copy SOURCE to DEST, or multiple SOURCE(s) to a DIRECTORY.")
        .arg(
            Arg::new("recursive")
                .short('r')
                .visible_short_alias('R')
                .long("recursive")
                .action(ArgAction::SetTrue)
                .help("copy directories recursively"),
        )
        .arg(
            Arg::new("archive")
                .short('a')
                .long("archive")
                .action(ArgAction::SetTrue)
                .help("same as -R -p, and recreate symlinks instead of following them"),
        )
        .arg(
            Arg::new("preserve")
                .short('p')
                .long("preserve")
                .action(ArgAction::SetTrue)
                .help("preserve modification/access times (mode is always preserved)"),
        )
        .arg(
            Arg::new("no-clobber")
                .short('n')
                .long("no-clobber")
                .action(ArgAction::SetTrue)
                .help("do not overwrite an existing file"),
        )
        .arg(
            Arg::new("interactive")
                .short('i')
                .long("interactive")
                .action(ArgAction::SetTrue)
                .help("prompt before overwriting an existing file"),
        )
        .arg(
            Arg::new("force")
                .short('f')
                .long("force")
                .action(ArgAction::SetTrue)
                .help("remove an undeletable destination and retry the copy"),
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

/// `cp [OPTION]... SRC... DST`. Returns the exit status.
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
        eprintln!("cp: missing file operand");
        return 1;
    }
    if paths.len() < 2 {
        eprintln!("cp: {}: missing destination file operand", paths[0]);
        return 1;
    }

    let archive = m.get_flag("archive"); // -a = -R -p + preserve symlinks
    let recursive = m.get_flag("recursive") || archive;
    let verbose = m.get_flag("verbose");
    let force = m.get_flag("force");
    let no_clobber = m.get_flag("no-clobber") && !force; // -f overrides -n
    let interactive = m.get_flag("interactive") && !no_clobber && !force; // -n/-f take precedence
    let preserve = m.get_flag("preserve") || archive; // copy mode + mtime/atime onto each destination

    let (sources, dest_slot) = paths.split_at(paths.len() - 1);
    let dest = dest_slot[0];
    let dest_is_dir = fsutil::is_dir(dest);
    if sources.len() > 1 && !dest_is_dir {
        eprintln!("cp: {}: not a directory", dest);
        return 1;
    }

    let mut rc = 0;
    for &src in sources {
        let dst = if dest_is_dir {
            fsutil::join(dest, fsutil::basename(src))
        } else {
            String::from(dest)
        };
        if fsutil::exists(&dst) {
            if no_clobber {
                continue;
            }
            if interactive && !confirm("overwrite", &dst) {
                continue;
            }
        }
        let res = if archive {
            // `-a`: symlink-aware recursive copy (links recreated, not followed).
            if fsutil::is_dir(src) && fsutil::same_or_descendant(src, &dst) {
                eprintln!("cp: {}: cannot copy a directory into itself", src);
                rc = 1;
                continue;
            }
            fsutil::copy_tree(src, &dst, false)
        } else if fsutil::is_dir(src) {
            if !recursive {
                eprintln!("cp: {}: is a directory (use -r)", src);
                rc = 1;
                continue;
            }
            if fsutil::same_or_descendant(src, &dst) {
                eprintln!("cp: {}: cannot copy a directory into itself", src);
                rc = 1;
                continue;
            }
            fsutil::copy_recursive(src, &dst)
        } else if !fsutil::exists(src) {
            Err(rt::ENOENT)
        } else {
            // `-f`: if the destination can't be written, remove it and retry.
            match fsutil::copy_file(src, &dst) {
                Err(e) if force => {
                    let _ = rt::unlink(&dst);
                    fsutil::copy_file(src, &dst).map_err(|_| e)
                }
                other => other,
            }
        };
        match res {
            Ok(()) => {
                // `cp` copies the source's mode bits always; `-p` adds the times.
                fsutil::preserve_meta(src, &dst, preserve);
                if verbose {
                    verbose_line(src, &dst);
                }
            }
            Err(e) => {
                eprintln!("cp: {}: {}", src, rt::strerror(e));
                rc = 1;
            }
        }
    }
    rc
}
