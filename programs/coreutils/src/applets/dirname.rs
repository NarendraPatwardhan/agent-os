//! `dirname [OPTION] NAME...` — print each NAME with its last `/` component removed (the
//! directory portion). Trailing slashes are ignored; a path with no `/` yields `.`, and
//! `/foo` yields `/`. `-z` (`--zero`) terminates each output with NUL instead of a newline.
//!
//! Flags: `-z`/`--zero`.
//!
//! Deviations from GNU: none — the full GNU surface (just `-z`) is implemented. Output is
//! byte-exact; the directory-splitting matches GNU exactly (a parent's own trailing slashes
//! are also collapsed, so `dirname //a//b//` is `//a`-less of the leaf, i.e. the parent up to
//! its last non-slash run).
//!
//! Exit status: 0 on success; 2 on a usage error (missing operand / clap parse error). Pure
//! string computation — no I/O beyond the inherited stdout (tier_isolated).
//!
//! Ported from memcontainers' `programs::dirname`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

// Pure string computation: output goes through the facade's `BufOut` (which wraps `mc`
// `write` to fd 1); `dirname` touches no files, clock, or processes, so no `rt` calls.
use crate::prelude::*;

/// The directory portion of `path` (its leaf component removed, trailing slashes ignored).
fn dir(path: &[u8]) -> &[u8] {
    let mut end = path.len();
    while end > 1 && path[end - 1] == b'/' {
        end -= 1;
    }
    let p = &path[..end];
    match p.iter().rposition(|&c| c == b'/') {
        None => b".",
        Some(0) => b"/",
        Some(i) => {
            // Drop the component, then any trailing slashes of the parent.
            let mut j = i;
            while j > 1 && p[j - 1] == b'/' {
                j -= 1;
            }
            &p[..j]
        }
    }
}

/// The clap command — the single source of `dirname`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("dirname")
        .about("Output each NAME with its last non-slash component and trailing slashes removed; if NAME contains no /, output '.' (the current directory).")
        .arg(Arg::new("zero").short('z').long("zero").action(ArgAction::SetTrue).help("end each output line with NUL, not newline"))
        .arg(Arg::new("NAME").action(ArgAction::Append).num_args(1..).help("path(s) whose directory portion to print"))
}

/// `dirname NAME...`. Returns the exit status (0 success; 2 on a usage error).
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        // clap prints help/usage/version itself; mirror its exit code (0 for --help/--version).
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let ops: Vec<&str> = m
        .get_many::<String>("NAME")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();
    if ops.is_empty() {
        eprintln!("dirname: missing operand");
        return 2;
    }

    let zero = m.get_flag("zero");
    let mut o = BufOut::new();
    for arg in &ops {
        o.extend(dir(arg.as_bytes()));
        o.push(if zero { b'\0' } else { b'\n' });
    }
    let _ = o.finish();
    0
}
