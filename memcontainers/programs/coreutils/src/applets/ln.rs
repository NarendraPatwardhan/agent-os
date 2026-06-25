//! `ln [OPTION]... TARGET [LINK]` / `ln [OPTION]... TARGET... DIRECTORY` — create links. By
//! default a HARD link (a second name for the same inode); `-s`/`--symbolic` makes a SYMBOLIC
//! link. `-f`/`--force` removes an existing destination first; `-i`/`--interactive` prompts
//! before removing it; `-n`/`--no-dereference` treats a symlink-to-a-directory destination as a
//! normal file (not a directory to link into); `-v`/`--verbose` prints `'link' -> 'target'`;
//! `-T`/`--no-target-directory` requires exactly two operands (LINK is never a directory);
//! `-t`/`--target-directory=DIR` links each TARGET into DIR; `-r`/`--relative` makes a symlink's
//! stored target relative to the link's directory; `-L`/`--logical` dereferences a symlink TARGET
//! before hard-linking; `-P`/`--physical` (default) hard-links the named node directly.
//!
//! Args+help are via clap; links are created with `rt::symlink`/`rt::link`, with path math from
//! `crate::fsutil` (`basename`/`join`/`lexical_abs`). `-i` reads a y/N answer from stdin.
//!
//! Deviations from GNU ln: `-b`/`--backup` and `-S`/`--suffix` are NOT implemented (an existing
//! destination is only handled via `-f` or `-i`); `-d`/`-F`/`--directory` (hard-link a directory)
//! is NOT implemented.
//!
//! Exit status: `0` every link created; `1` a link could not be created; `2` a usage error
//! (clap) — no operand, `-T` without exactly two operands, or a multi-target final operand that
//! is not a directory.
//!
//! Ported from memcontainers' `programs::ln`.

use alloc::format;
use alloc::string::String;
use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

/// Per-invocation link options.
struct Opts {
    symbolic: bool,
    force: bool,
    interactive: bool,
    no_deref: bool,
    verbose: bool,
    relative: bool,
    logical: bool,
}

/// Prompt `ln: action target? ` on stderr and read a reply from stdin (for `-i`). Returns true
/// only if the first non-blank character is `y`/`Y`; EOF or anything else is "no".
fn confirm(action: &str, target: &str) -> bool {
    let _ = rt::write_all(rt::STDERR, b"ln: ");
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

/// Directory part of a path (everything before the last `/`); `"."` if none.
fn dirname(path: &str) -> &str {
    let t = path.trim_end_matches('/');
    match t.rfind('/') {
        Some(0) => "/",
        Some(i) => &t[..i],
        None => ".",
    }
}

/// Express `target` relative to the directory holding `linkpath` (both absolutized first) — for
/// `ln -r`.
fn relative_link(linkpath: &str, target: &str) -> String {
    let link_abs = fsutil::lexical_abs(linkpath);
    let target_abs = fsutil::lexical_abs(target);
    let from: Vec<&str> = dirname(&link_abs)
        .split('/')
        .filter(|c| !c.is_empty())
        .collect();
    let to: Vec<&str> = target_abs.split('/').filter(|c| !c.is_empty()).collect();
    let mut i = 0;
    while i < from.len() && i < to.len() && from[i] == to[i] {
        i += 1;
    }
    let mut rel = String::new();
    for _ in i..from.len() {
        if !rel.is_empty() {
            rel.push('/');
        }
        rel.push_str("..");
    }
    for c in &to[i..] {
        if !rel.is_empty() {
            rel.push('/');
        }
        rel.push_str(c);
    }
    if rel.is_empty() {
        rel.push('.');
    }
    rel
}

/// Resolve a symlink chain to its ultimate target path (for `ln -L` hard links). Bounded; returns
/// `path` (absolutized) unchanged when it is not a symlink.
fn deref(path: &str) -> String {
    let mut cur = fsutil::lexical_abs(path);
    for _ in 0..40 {
        match rt::lstat(&cur) {
            Ok(s) if s.is_symlink => {
                let mut buf = [0u8; 1024];
                let nn = match rt::readlink(&cur, &mut buf) {
                    Ok(nn) => nn.min(buf.len()),
                    Err(_) => break,
                };
                let tgt = core::str::from_utf8(&buf[..nn]).unwrap_or("");
                cur = if tgt.starts_with('/') {
                    fsutil::lexical_abs(tgt)
                } else {
                    fsutil::lexical_abs(&fsutil::join(dirname(&cur), tgt))
                };
            }
            _ => break,
        }
    }
    cur
}

/// Does `path` denote a directory we should link INTO? Follows symlinks unless `no_deref` (then a
/// symlink — even to a directory — is not a directory here).
fn dest_is_dir(path: &str, no_deref: bool) -> bool {
    if no_deref {
        rt::lstat(path).map(|s| s.is_dir).unwrap_or(false)
    } else {
        rt::stat(path).map(|s| s.is_dir).unwrap_or(false)
    }
}

/// Create one link `linkpath` → `target`; returns 0 on success, 1 on failure.
fn make_link(target: &str, linkpath: &str, o: &Opts) -> i32 {
    // Handle an existing destination (force / interactive).
    if rt::lstat(linkpath).is_ok() {
        if o.interactive {
            if !confirm("replace", linkpath) {
                return 0;
            }
        } else if !o.force {
            eprintln!("ln: {}: File exists", linkpath);
            return 1;
        }
        let _ = rt::unlink(linkpath);
    }

    let result = if o.symbolic {
        let stored = if o.relative {
            relative_link(linkpath, target)
        } else {
            String::from(target)
        };
        rt::symlink(&stored, linkpath)
    } else {
        // Hard link. `-P` (default) links the named node; `-L` first dereferences
        // a symlink target.
        let src = if o.logical {
            deref(target)
        } else {
            String::from(target)
        };
        rt::link(&src, linkpath)
    };

    match result {
        Ok(()) => {
            if o.verbose {
                let _ = rt::write_all(rt::STDOUT, format!("'{linkpath}' -> '{target}'\n").as_bytes());
            }
            0
        }
        Err(e) => {
            eprintln!("ln: {}: {}", linkpath, rt::strerror(e));
            1
        }
    }
}

/// The clap command — the single source of `ln`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("ln")
        .about("Make links between files (a hard link by default; -s for a symbolic link).")
        .arg(Arg::new("symbolic").short('s').long("symbolic").action(ArgAction::SetTrue).help("make symbolic links instead of hard links"))
        .arg(Arg::new("force").short('f').long("force").action(ArgAction::SetTrue).help("remove existing destination files"))
        .arg(Arg::new("interactive").short('i').long("interactive").action(ArgAction::SetTrue).help("prompt whether to remove destinations"))
        .arg(Arg::new("no-dereference").short('n').long("no-dereference").action(ArgAction::SetTrue).help("treat a symlink destination as a normal file"))
        .arg(Arg::new("verbose").short('v').long("verbose").action(ArgAction::SetTrue).help("print the name of each linked file"))
        .arg(Arg::new("no-target-directory").short('T').long("no-target-directory").action(ArgAction::SetTrue).help("treat LINK_NAME as a normal file always (exactly two operands)"))
        .arg(Arg::new("target-directory").short('t').long("target-directory").num_args(1).value_name("DIR").help("link each TARGET into directory DIR"))
        .arg(Arg::new("relative").short('r').long("relative").action(ArgAction::SetTrue).help("with -s, create links relative to link location"))
        .arg(Arg::new("logical").short('L').long("logical").action(ArgAction::SetTrue).help("dereference TARGETs that are symbolic links (hard link)"))
        .arg(Arg::new("physical").short('P').long("physical").action(ArgAction::SetTrue).help("make hard links directly to symbolic links (default)"))
        .arg(Arg::new("PATHS").action(ArgAction::Append).num_args(0..).help("TARGET(s) and an optional LINK_NAME / DIRECTORY"))
}

/// `ln [OPTION]... TARGET [LINK]...`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let o = Opts {
        symbolic: m.get_flag("symbolic"),
        force: m.get_flag("force"),
        interactive: m.get_flag("interactive"),
        no_deref: m.get_flag("no-dereference"),
        verbose: m.get_flag("verbose"),
        relative: m.get_flag("relative"),
        logical: m.get_flag("logical"),
    };
    let no_target_dir = m.get_flag("no-target-directory");
    let target_dir = m.get_one::<String>("target-directory").map(String::as_str);

    let ops: Vec<&str> = m
        .get_many::<String>("PATHS")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();
    if ops.is_empty() {
        eprintln!("ln: missing file operand");
        return 1;
    }

    let mut rc = 0;
    if let Some(dir) = target_dir {
        // `-t DIR`: every operand is a target linked into DIR.
        for &t in &ops {
            let linkpath = fsutil::join(dir, fsutil::basename(t));
            rc |= make_link(t, &linkpath, &o);
        }
    } else if no_target_dir {
        // `-T`: exactly TARGET LINK_NAME (LINK_NAME is never a directory).
        if ops.len() != 2 {
            eprintln!("ln: with -T, exactly two operands are required");
            return 1;
        }
        rc |= make_link(ops[0], ops[1], &o);
    } else if ops.len() == 1 {
        // Single TARGET → link named basename(TARGET) in the cwd.
        let linkpath = String::from(fsutil::basename(ops[0]));
        rc |= make_link(ops[0], &linkpath, &o);
    } else {
        // TARGET... LINK_NAME|DIR.
        let last = ops[ops.len() - 1];
        if dest_is_dir(last, o.no_deref) {
            for &t in &ops[..ops.len() - 1] {
                let linkpath = fsutil::join(last, fsutil::basename(t));
                rc |= make_link(t, &linkpath, &o);
            }
        } else if ops.len() == 2 {
            rc |= make_link(ops[0], ops[1], &o);
        } else {
            eprintln!("ln: {}: is not a directory", last);
            return 1;
        }
    }

    rc
}
