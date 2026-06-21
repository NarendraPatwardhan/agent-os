//! `basename NAME [SUFFIX]` / `basename OPTION... NAME...` — strip the directory and an
//! optional trailing suffix from each NAME. In the one-operand form, trailing slashes are
//! stripped, the directory part is removed, then SUFFIX (a second operand, if given) is
//! removed; a suffix is never removed if it equals the whole name (POSIX). With `-a`
//! (`--multiple`) every operand is a NAME; `-s SUF` (`--suffix`) strips SUF from each and
//! implies `-a`. `-z` (`--zero`) terminates each output with NUL instead of a newline.
//!
//! Flags: `-a`/`--multiple`, `-s`/`--suffix=SUFFIX`, `-z`/`--zero`.
//!
//! Deviations from GNU: none of substance — the full GNU flag surface is implemented. Output
//! is byte-exact (the base/suffix logic operates on raw bytes; only operands that are valid
//! UTF-8 reach it, which is every coreutils path). The directory/suffix splitting matches GNU:
//! `/` stays `/`, and a suffix equal to the whole name is preserved.
//!
//! Exit status: 0 on success; 2 on a usage error (missing operand / clap parse error). Pure
//! string computation — no I/O beyond the inherited stdout (tier_isolated).
//!
//! Ported from memcontainers' `programs::basename`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

// Pure string computation: output goes through the facade's `BufOut` (which wraps `mc`
// `write` to fd 1), so no direct `sysroot as rt` calls are needed — `basename` touches no
// files, no clock, no processes.
use crate::prelude::*;

/// Final path component, with trailing slashes removed. `/` stays `/`.
fn base(path: &[u8]) -> &[u8] {
    let mut end = path.len();
    while end > 1 && path[end - 1] == b'/' {
        end -= 1;
    }
    let p = &path[..end];
    if p == b"/" {
        return b"/";
    }
    match p.iter().rposition(|&c| c == b'/') {
        Some(i) => &p[i + 1..],
        None => p,
    }
}

/// Strip `suf` from the end of `name`, unless that would empty it or `suf` is the whole name
/// (POSIX: a suffix is not removed if it equals the operand).
fn strip_suffix<'a>(name: &'a [u8], suf: &[u8]) -> &'a [u8] {
    if !suf.is_empty() && name.len() > suf.len() && name.ends_with(suf) {
        &name[..name.len() - suf.len()]
    } else {
        name
    }
}

/// The clap command — the single source of `basename`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("basename")
        .about("Print NAME with any leading directory components removed. If specified, also remove a trailing SUFFIX.")
        .arg(Arg::new("multiple").short('a').long("multiple").action(ArgAction::SetTrue).help("support multiple arguments and treat each as a NAME"))
        .arg(Arg::new("suffix").short('s').long("suffix").num_args(1).value_name("SUFFIX").help("remove a trailing SUFFIX; implies -a"))
        .arg(Arg::new("zero").short('z').long("zero").action(ArgAction::SetTrue).help("end each output line with NUL, not newline"))
        .arg(Arg::new("NAME").action(ArgAction::Append).num_args(1..).help("path(s) to strip (the last operand is SUFFIX in single-argument mode)"))
}

/// `basename NAME [SUFFIX]`. Returns the exit status (0 success; 2 on a usage error).
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
        eprintln!("basename: missing operand");
        return 2;
    }

    let zero = m.get_flag("zero");
    let suffix_opt = m.get_one::<String>("suffix").map(String::as_str);
    let all = m.get_flag("multiple") || suffix_opt.is_some();
    let term = if zero { b'\0' } else { b'\n' };

    // One BufOut for all operands: a name is extended then terminated (LF or NUL); `finish`
    // flushes once. (basename's outputs are short path components — bounded by definition.)
    let mut o = BufOut::new();
    if all {
        let suf = suffix_opt.map(str::as_bytes).unwrap_or(b"");
        for arg in &ops {
            o.extend(strip_suffix(base(arg.as_bytes()), suf));
            o.push(term);
        }
    } else {
        let name = base(ops[0].as_bytes());
        let suf = ops.get(1).map(|s| s.as_bytes()).unwrap_or(b"");
        o.extend(strip_suffix(name, suf));
        o.push(term);
    }
    let _ = o.finish();
    0
}
