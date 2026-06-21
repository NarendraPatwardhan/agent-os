//! `chmod [-R] MODE FILE...` — change file mode (permission) bits. `MODE` is either OCTAL
//! (`755`, `0644`) or SYMBOLIC: one or more comma-separated clauses `[ugoa]*[+-=][rwx]*` (e.g.
//! `u+x`, `go-w`, `a=r`, `+x`). Octal is absolute; symbolic is applied relative to the current
//! bits. `-R`/`--recursive` recurses into directories (post-order over the tree). Single subject,
//! so only the owner triad is ever ENFORCED, but all three triads are stored and settable.
//! Backed by `rt::chmod` over `//sysroot`.
//!
//! Args+help: because a symbolic MODE can itself begin with `-` (e.g. `chmod -x f`), the operand
//! list is parsed with clap's `allow_hyphen_values` (only `-R`/`--recursive`/`--help` are real
//! options); the first remaining token is the MODE, the rest are files. The MODE is validated up
//! front so a bad spec fails before any file is touched. The mode math is transcribed from
//! memcontainers; recursion walks via `crate::fsutil::list` / `join`.
//!
//! Deviations from GNU chmod: `--reference`, `-c`/`--changes`, `-v`/`--verbose`, `-f`/`--silent`,
//! and `--preserve-root` are NOT implemented (`--recursive` is accepted as a synonym for `-R`).
//! The setuid/setgid/sticky bits and the `X`, `s`, `t` symbolic perms are NOT supported.
//!
//! Exit status: `0` every file changed; `1` an invalid mode, or a file could not be changed; `2`
//! a usage error (clap), including a missing operand.
//!
//! Ported from memcontainers' `programs::chmod`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

/// Parse an octal mode string (`"755"`, `"0644"`) into permission bits, or `None` if it is not
/// all octal digits.
fn parse_octal_mode(s: &[u8]) -> Option<u16> {
    if s.is_empty() || !s.iter().all(|b| (b'0'..=b'7').contains(b)) {
        return None;
    }
    let mut m: u16 = 0;
    for &b in s {
        m = m.checked_mul(8)?.checked_add((b - b'0') as u16)?;
    }
    Some(m & 0o7777)
}

/// Apply one symbolic clause (`[ugoa]*[+-=][rwx]*`) to `mode`.
fn apply_symbolic(mut mode: u16, clause: &[u8]) -> Option<u16> {
    let mut i = 0;
    let mut who: u16 = 0;
    while i < clause.len() {
        who |= match clause[i] {
            b'u' => 0o700,
            b'g' => 0o070,
            b'o' => 0o007,
            b'a' => 0o777,
            _ => break,
        };
        i += 1;
    }
    if who == 0 {
        who = 0o777; // no `who` given → all
    }
    let op = *clause.get(i)?;
    i += 1;
    let mut perm: u16 = 0;
    while i < clause.len() {
        perm |= match clause[i] {
            b'r' => 0o444,
            b'w' => 0o222,
            b'x' => 0o111,
            _ => return None,
        };
        i += 1;
    }
    let bits = perm & who;
    match op {
        b'+' => mode |= bits,
        b'-' => mode &= !bits,
        b'=' => mode = (mode & !who) | bits,
        _ => return None,
    }
    Some(mode)
}

/// Resolve a MODE spec against a file's current `mode` — octal is absolute, symbolic is relative
/// (comma-separated clauses applied in order).
fn resolve_mode(spec: &[u8], current: u16) -> Option<u16> {
    if let Some(oct) = parse_octal_mode(spec) {
        return Some(oct);
    }
    let mut mode = current;
    for clause in spec.split(|&b| b == b',') {
        mode = apply_symbolic(mode, clause)?;
    }
    Some(mode)
}

/// Apply `spec` to `path` (and, when `recursive` and `path` is a directory, its descendants).
fn do_chmod(path: &str, spec: &[u8], recursive: bool, rc: &mut i32) {
    let st = match rt::stat(path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("chmod: {}: {}", path, rt::strerror(e));
            *rc = 1;
            return;
        }
    };
    match resolve_mode(spec, st.mode) {
        Some(md) => {
            if let Err(e) = rt::chmod(path, md) {
                eprintln!("chmod: {}: {}", path, rt::strerror(e));
                *rc = 1;
            }
        }
        None => {
            eprintln!("chmod: invalid mode: {}", String::from_utf8_lossy(spec));
            *rc = 1;
            return;
        }
    }
    if recursive && st.is_dir {
        if let Ok(names) = fsutil::list(path) {
            for name in names {
                let child = fsutil::join(path, &name);
                do_chmod(&child, spec, recursive, rc);
            }
        }
    }
}

/// The clap command — the single source of `chmod`'s flag surface AND its `--help`. The operands
/// allow a leading `-` (a symbolic MODE like `-x`), so only `-R`/`--recursive` is a real option.
fn command() -> Command {
    Command::new("chmod")
        .about("Change the mode (permission bits) of each FILE to MODE (octal or symbolic).")
        .arg(
            Arg::new("recursive")
                .short('R')
                .long("recursive")
                .action(ArgAction::SetTrue)
                .help("change files and directories recursively"),
        )
        .arg(
            Arg::new("ARGS")
                .action(ArgAction::Append)
                .num_args(0..)
                .trailing_var_arg(true)
                .allow_hyphen_values(true)
                .help("the MODE (octal or symbolic) followed by the FILE(s)"),
        )
}

/// `chmod [-R] MODE FILE...`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let recursive = m.get_flag("recursive");
    let rest: Vec<&str> = m
        .get_many::<String>("ARGS")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();

    let spec = match rest.first() {
        Some(s) => s.as_bytes(),
        None => {
            eprintln!("chmod: missing operand");
            return 1;
        }
    };
    let files = &rest[1..];
    if files.is_empty() {
        eprintln!("chmod: missing operand after '{}'", String::from_utf8_lossy(spec));
        return 1;
    }
    // Validate the spec up front (against a dummy mode) so a bad MODE fails
    // before any file is touched.
    if resolve_mode(spec, 0o644).is_none() {
        eprintln!("chmod: invalid mode: {}", String::from_utf8_lossy(spec));
        return 1;
    }

    let mut rc = 0;
    for path in files {
        do_chmod(path, spec, recursive, &mut rc);
    }
    rc
}
