//! `tree [-a] [-d] [-f] [-L LEVEL] [--noreport] [DIR...]` — print the directory hierarchy.
//!
//! HAND-WRITTEN applet (SYSTEMS.md): logic transcribed from memcontainers' `programs::tree`,
//! the directory walk runs over the **facade** (`fsutil::list`/`join`/`is_dir`) and emits through
//! `textio::out`/`outln`; args + help via **clap**. Prints the hierarchy under each DIR (default
//! `.`) with the usual `├──`/`└──` connectors (UTF-8, byte-exact), then a `N directories, M files`
//! summary. `-a` shows hidden entries (default hides dotfiles, GNU behavior); `-d` lists
//! directories only; `-f` prints each entry's full path; `-L` limits the descent depth;
//! `--noreport` omits the summary. Multiple roots each print their own tree, then one combined
//! summary.
//!
//! Deviations from tree(1):
//!   - Only `-a`, `-d`, `-f`, `-L`, and `--noreport` are implemented (no `-P`/`-I` patterns,
//!     `-C` color, `-p`/`-s`/`-h` size or permission columns, `-J`/`-X` output formats, etc.).
//!   - There is no owner/group information (single-subject VM).
//!
//! Exit status: `0` success; `1` a DIR could not be opened or is not a directory; `2` a clap
//! usage error.
//!
//! Ported from memcontainers' `programs::tree`.

use alloc::format;
use alloc::string::String;
use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

struct Opts {
    all: bool,
    dirs_only: bool,
    full: bool,
    max_level: Option<usize>,
}

/// Walk `dir` whose entries sit at `level` (root children are level 1).
fn walk(dir: &str, prefix: &str, level: usize, o: &Opts, dirs: &mut u64, files: &mut u64) {
    if let Some(max) = o.max_level {
        if level > max {
            return;
        }
    }
    let mut names = match fsutil::list(dir) {
        Ok(v) => v,
        Err(_) => return,
    };
    if !o.all {
        names.retain(|n| !n.starts_with('.'));
    }
    if o.dirs_only {
        names.retain(|n| fsutil::is_dir(&fsutil::join(dir, n)));
    }
    names.sort();
    let count = names.len();
    for (i, name) in names.iter().enumerate() {
        let last = i + 1 == count;
        textio::out(prefix.as_bytes());
        textio::out(if last {
            b"\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 "
        } else {
            b"\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 "
        });
        let full = fsutil::join(dir, name);
        // `-f` prints the path; otherwise just the basename.
        textio::outln(if o.full { full.as_bytes() } else { name.as_bytes() });
        if fsutil::is_dir(&full) {
            *dirs += 1;
            let child = format!("{prefix}{}", if last { "    " } else { "\u{2502}   " });
            walk(&full, &child, level + 1, o, dirs, files);
        } else {
            *files += 1;
        }
    }
}

/// The clap command — the single source of `tree`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("tree")
        .about("List the contents of directories in a tree-like format.")
        .override_usage("tree [-a] [-d] [-f] [-L LEVEL] [--noreport] [DIR]...")
        .after_help(
            "Each DIR (default `.`) prints its own tree with the usual ├── / └── connectors; with\n\
             multiple roots a single combined summary follows them all. Only -a, -d, -f, -L, and\n\
             --noreport are implemented (no -P/-I patterns, -C color, size/permission columns, or\n\
             alternate output formats).",
        )
        .arg(
            Arg::new("all")
                .short('a')
                .action(ArgAction::SetTrue)
                .help("show hidden entries (default hides dotfiles, like GNU)"),
        )
        .arg(
            Arg::new("dirs-only")
                .short('d')
                .action(ArgAction::SetTrue)
                .help("list directories only"),
        )
        .arg(
            Arg::new("full")
                .short('f')
                .action(ArgAction::SetTrue)
                .help("print the full path of each entry, not just its name"),
        )
        .arg(
            Arg::new("level")
                .short('L')
                .num_args(1)
                .value_name("LEVEL")
                .help("descend at most LEVEL directories deep"),
        )
        .arg(
            Arg::new("noreport")
                .long("noreport")
                .action(ArgAction::SetTrue)
                .help("omit the trailing `N directories, M files` summary"),
        )
        .arg(
            Arg::new("DIR")
                .action(ArgAction::Append)
                .num_args(0..)
                .help("directories to display (default the current directory)"),
        )
}

/// `tree [OPTION]... [DIR]...`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        // clap prints help/usage/version itself; mirror its exit code (0 for --help/--version).
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    // `-L` accepts only a positive integer; a non-numeric or zero value disables the limit
    // (matching the memcontainers source, which filtered to `> 0`).
    let max_level = m
        .get_one::<String>("level")
        .and_then(|s| s.parse::<usize>().ok())
        .filter(|&v| v > 0);
    let o = Opts {
        all: m.get_flag("all"),
        dirs_only: m.get_flag("dirs-only"),
        full: m.get_flag("full"),
        max_level,
    };
    let noreport = m.get_flag("noreport");

    let mut roots: Vec<&str> = m
        .get_many::<String>("DIR")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();
    if roots.is_empty() {
        roots.push(".");
    }

    let (mut dirs, mut files) = (0u64, 0u64);
    let mut rc = 0;
    for root in &roots {
        match rt::stat(root) {
            Ok(s) if s.is_dir => {}
            Ok(_) => {
                eprintln!("tree: {}: Not a directory", root);
                rc = 1;
                continue;
            }
            Err(e) => {
                eprintln!("tree: {}: {}", root, rt::strerror(e));
                rc = 1;
                continue;
            }
        }
        textio::outln(root.as_bytes());
        walk(root, "", 1, &o, &mut dirs, &mut files);
    }

    if !noreport {
        let summary = if o.dirs_only {
            format!("\n{dirs} director{}", if dirs == 1 { "y" } else { "ies" })
        } else {
            format!(
                "\n{dirs} director{}, {files} file{}",
                if dirs == 1 { "y" } else { "ies" },
                if files == 1 { "" } else { "s" }
            )
        };
        textio::outln(summary.as_bytes());
    }
    rc
}
