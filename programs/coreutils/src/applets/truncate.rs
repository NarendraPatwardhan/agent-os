//! `truncate -s SIZE FILE...` — set each file's length to SIZE bytes, growing it with zero bytes
//! or dropping the tail. Missing files are created. SIZE is a non-negative number with an
//! optional `K`/`M`/`G` (1024-based) suffix. Backed by `rt::ftruncate` over `//sysroot`.
//!
//! Flags: `-s`/`--size SIZE` (required). Args+help are via clap; each file is opened with
//! `rt::open(.., O_WRITE|O_CREATE)` then resized with `rt::ftruncate`.
//!
//! Deviations from GNU truncate: SIZE is always the ABSOLUTE length — the relative operators
//! (`+`/`-`/`<`/`>`/`/`/`%`) are NOT implemented; `-c`/`--no-create`, `-o`/`--io-blocks`, and
//! `-r`/`--reference` are NOT implemented; `-s` is required.
//!
//! Exit status: `0` all files resized; `1` a file could not be opened or resized; `2` a usage
//! error — missing `-s`/SIZE, an unparseable SIZE, or a missing FILE operand (clap, plus a
//! parse check).
//!
//! Ported from memcontainers' `programs::truncate`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use sysroot as rt;

/// Parse a SIZE: digits with an optional `K`/`M`/`G` (1024-based) suffix.
fn parse_size(b: &[u8]) -> Option<u64> {
    let (digits, mult): (&[u8], u64) = match b.last() {
        Some(b'K') | Some(b'k') => (&b[..b.len() - 1], 1024),
        Some(b'M') | Some(b'm') => (&b[..b.len() - 1], 1024 * 1024),
        Some(b'G') | Some(b'g') => (&b[..b.len() - 1], 1024 * 1024 * 1024),
        _ => (b, 1),
    };
    if digits.is_empty() {
        return None;
    }
    let mut v: u64 = 0;
    for &c in digits {
        if !c.is_ascii_digit() {
            return None;
        }
        v = v.checked_mul(10)?.checked_add((c - b'0') as u64)?;
    }
    v.checked_mul(mult)
}

/// The clap command — the single source of `truncate`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("truncate")
        .about("Shrink or extend the size of each FILE to the specified size.")
        .arg(
            Arg::new("size")
                .short('s')
                .long("size")
                .num_args(1)
                .value_name("SIZE")
                .help("set or adjust the file size to SIZE bytes (with optional K/M/G suffix)"),
        )
        .arg(
            Arg::new("FILE")
                .action(ArgAction::Append)
                .num_args(0..)
                .help("the files to resize (created if missing)"),
        )
}

/// `truncate -s SIZE FILE...`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let size = match m.get_one::<String>("size").and_then(|s| parse_size(s.as_bytes())) {
        Some(s) => s,
        None => {
            eprintln!("truncate: you must specify a size with -s");
            return 1;
        }
    };
    let ops: Vec<&str> = m
        .get_many::<String>("FILE")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();
    if ops.is_empty() {
        eprintln!("truncate: missing file operand");
        return 1;
    }

    let mut rc = 0;
    for path in &ops {
        match rt::open(path, rt::O_WRITE | rt::O_CREATE) {
            Ok(fd) => {
                if rt::ftruncate(fd, size).is_err() {
                    eprintln!("truncate: {}: could not set size", path);
                    rc = 1;
                }
                rt::close(fd);
            }
            Err(e) => {
                eprintln!("truncate: {}: {}", path, rt::strerror(e));
                rc = 1;
            }
        }
    }
    rc
}
