//! `uniq [OPTION]... [INPUT [OUTPUT]]` — collapse ADJACENT equal lines of INPUT (or stdin),
//! writing to OUTPUT (or stdout).
//!
//! Like GNU `uniq`, comparison is between *adjacent* lines only (so input is usually
//! `sort`ed first); the tool holds only the current group's first line, streaming one line
//! at a time over the facade's [`LineReader`]/[`BufOut`], so peak memory is one line.
//!
//! Selection of which lines print:
//!   * `-d`/`--repeated` — only the first line of each repeated group;
//!   * `-D`/`--all-repeated` — ALL lines of repeated groups (verbatim, in order);
//!   * `-u`/`--unique` — only lines that are not repeated;
//!   * default — one representative of each group.
//! `-c`/`--count` prefixes each printed line with its repeat count, right-justified in 7
//! columns then a space (`-c` with `-D` is rejected, as in GNU). `-i`/`--ignore-case`
//! folds case in the comparison.
//!
//! Comparison key: skip the first `-f N`/`--skip-fields=N` blank-separated fields, then
//! `-s N`/`--skip-chars=N` characters, then compare at most `-w N`/`--check-chars=N`
//! characters of what remains.
//!
//! Operands: the first non-`-` operand is INPUT (`-` or none = stdin); the second is OUTPUT
//! (none = stdout). When OUTPUT is given it is staged through a private `/scratch` spool and
//! copied to the real file only after all input is consumed, so naming the input file as
//! OUTPUT does not truncate data still being read. Declared `read-write` because that OUTPUT
//! operand is a real file write; the tier still denies spawn, network, persistence, and
//! namespace mutation.
//!
//! GNU deviations: `--all-repeated[=METHOD]` is supported only in its bare `-D` form (no
//! `none`/`prepend`/`separate` group-separator METHODs); `--group[=METHOD]` is NOT
//! implemented; `-z`/`--zero-terminated` (NUL line delimiter) is NOT implemented (lines are
//! `\n`-delimited, CRLF-tolerant). Byte-exact otherwise.
//!
//! Exit status: 0 success; 1 if `-c` and `-D` are combined, INPUT/OUTPUT could not be
//! opened, or a write failed.
//!
//! Ported from memcontainers' `programs::uniq`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

fn is_blank(b: u8) -> bool {
    b == b' ' || b == b'\t'
}

/// The comparison key of `line`: skip `skip_fields` blank-separated fields, then
/// `skip_chars` characters, then take at most `width` characters (`None` = all).
fn key(line: &[u8], skip_fields: usize, skip_chars: usize, width: Option<usize>) -> &[u8] {
    let mut i = 0usize;
    for _ in 0..skip_fields {
        while i < line.len() && is_blank(line[i]) {
            i += 1;
        }
        while i < line.len() && !is_blank(line[i]) {
            i += 1;
        }
    }
    i = (i + skip_chars).min(line.len());
    let k = &line[i..];
    match width {
        Some(w) => &k[..w.min(k.len())],
        None => k,
    }
}

fn eq(a: &[u8], b: &[u8], ignore: bool) -> bool {
    if a.len() != b.len() {
        return false;
    }
    if ignore {
        a.iter().zip(b).all(|(x, y)| x.eq_ignore_ascii_case(y))
    } else {
        a == b
    }
}

/// GNU `-c` format: count right-justified in 7 columns, then a space.
fn push_count(o: &mut BufOut, n: u64) {
    let mut tmp = [0u8; 20];
    let mut i = tmp.len();
    let mut v = n;
    if v == 0 {
        i -= 1;
        tmp[i] = b'0';
    }
    while v > 0 {
        i -= 1;
        tmp[i] = b'0' + (v % 10) as u8;
        v /= 10;
    }
    let d = &tmp[i..];
    for _ in d.len()..7 {
        o.push(b' ');
    }
    o.extend(d);
    o.push(b' ');
}

fn copy_fd(src: i32, dst: i32) -> Result<(), i32> {
    let mut buf = [0u8; 8192];
    loop {
        let n = rt::read(src, &mut buf)?;
        if n == 0 {
            return Ok(());
        }
        rt::write_all(dst, &buf[..n])?;
    }
}

/// Open OUTPUT for writing (truncate/create), or report and return the errno.
fn open_output(path: &str) -> Result<i32, i32> {
    rt::open(path, rt::O_WRITE | rt::O_CREATE | rt::O_TRUNC)
}

/// The clap command — the single source of `uniq`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("uniq")
        .about("Filter adjacent matching lines from INPUT (or standard input), writing to OUTPUT (or standard output). With no options, matching lines are merged to the first occurrence.")
        .arg(Arg::new("count").short('c').long("count").action(ArgAction::SetTrue).help("prefix lines by the number of occurrences"))
        .arg(Arg::new("repeated").short('d').long("repeated").action(ArgAction::SetTrue).help("only print duplicate lines, one for each group"))
        .arg(Arg::new("all-repeated").short('D').long("all-repeated").action(ArgAction::SetTrue).help("print all duplicate lines"))
        .arg(Arg::new("unique").short('u').long("unique").action(ArgAction::SetTrue).help("only print unique lines"))
        .arg(Arg::new("ignore-case").short('i').long("ignore-case").action(ArgAction::SetTrue).help("ignore differences in case when comparing"))
        .arg(Arg::new("skip-fields").short('f').long("skip-fields").num_args(1).value_name("N").help("avoid comparing the first N fields"))
        .arg(Arg::new("skip-chars").short('s').long("skip-chars").num_args(1).value_name("N").help("avoid comparing the first N characters"))
        .arg(Arg::new("check-chars").short('w').long("check-chars").num_args(1).value_name("N").help("compare no more than N characters in lines"))
        .arg(Arg::new("INPUT").action(ArgAction::Append).num_args(0..=2).help("INPUT (- or none = standard input) then OUTPUT (none = standard output)"))
}

/// Parse a clap numeric value (`N`), printing the GNU-style usage error `noun` on a bad
/// value (e.g. "fields to skip", "bytes to skip", "bytes to compare").
fn parse_n(m: &clap::ArgMatches, id: &str, noun: &str) -> Result<Option<usize>, ()> {
    match m.get_one::<String>(id) {
        None => Ok(None),
        Some(s) => match s.parse::<usize>() {
            Ok(v) => Ok(Some(v)),
            Err(_) => {
                eprintln!("uniq: invalid number of {}: '{}'", noun, s);
                Err(())
            }
        },
    }
}

/// `uniq [OPTION]... [INPUT [OUTPUT]]`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        // clap prints help/usage/version itself; mirror its exit code (0 for --help/--version).
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let show_count = m.get_flag("count");
    let only_dup = m.get_flag("repeated");
    let all_dup = m.get_flag("all-repeated");
    let only_uniq = m.get_flag("unique");
    let ignore = m.get_flag("ignore-case");
    let skip_fields = match parse_n(&m, "skip-fields", "fields to skip") {
        Ok(v) => v.unwrap_or(0),
        Err(()) => return 1,
    };
    let skip_chars = match parse_n(&m, "skip-chars", "bytes to skip") {
        Ok(v) => v.unwrap_or(0),
        Err(()) => return 1,
    };
    let width = match parse_n(&m, "check-chars", "bytes to compare") {
        Ok(v) => v,
        Err(()) => return 1,
    };

    if all_dup && show_count {
        eprintln!("uniq: printing all duplicated lines and repeat counts is meaningless");
        return 1;
    }

    // `uniq [INPUT [OUTPUT]]`: the first non-`-` operand is INPUT, the second is OUTPUT.
    let ops: Vec<&str> = m
        .get_many::<String>("INPUT")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();
    let in_ops: Vec<&[u8]> = match ops.first() {
        Some(&f) if f != "-" => alloc::vec![ops[0].as_bytes()],
        _ => Vec::new(),
    };
    let out_path: Option<&str> = ops.get(1).copied();

    let spool = match out_path {
        Some(path) => match spool::SpoolFile::create() {
            Ok(sf) => Some(sf),
            Err(e) => {
                eprintln!("uniq: {}: {}", path, rt::strerror(e));
                return 1;
            }
        },
        None => None,
    };
    let out_fd = spool.as_ref().map_or(rt::STDOUT, |sf| sf.fd());

    let mut o = BufOut::with_fd(out_fd);
    let mut prev: Option<Vec<u8>> = None; // the first line of the current group
    let mut count: u64 = 0;

    let emit_group = |o: &mut BufOut, line: &[u8], count: u64| -> Result<(), i32> {
        // Standard (non -D) emission of one representative line.
        let show = (!only_dup || count >= 2) && (!only_uniq || count <= 1);
        if !show {
            return Ok(());
        }
        if show_count {
            push_count(o, count);
        }
        o.line(line)
    };

    let rc = textio::stream_lines("uniq", &in_ops, |line| {
        if let Some(p) = &prev {
            if eq(
                key(p, skip_fields, skip_chars, width),
                key(line, skip_fields, skip_chars, width),
                ignore,
            ) {
                count += 1;
                if all_dup {
                    if count == 2 {
                        o.line(p)?; // first line of a now-confirmed dup group
                    }
                    o.line(line)?;
                }
                return Ok(());
            }
            // A new distinct group: flush the one that just ended.
            if !all_dup {
                emit_group(&mut o, p, count)?;
            }
        }
        prev = Some(line.to_vec());
        count = 1;
        Ok(())
    });
    // Flush the final group (only the non -D path defers emission).
    if !all_dup {
        if let Some(p) = &prev {
            let _ = emit_group(&mut o, p, count);
        }
    }
    let _ = o.finish();

    if let (Some(path), Some(sf)) = (out_path, spool.as_ref()) {
        let mut final_rc = rc;
        if sf.rewind().is_err() {
            final_rc = 1;
        }
        match open_output(path) {
            Ok(real_fd) => {
                if copy_fd(sf.fd(), real_fd).is_err() {
                    eprintln!("uniq: write error");
                    final_rc = 1;
                }
                rt::close(real_fd);
            }
            Err(e) => {
                eprintln!("uniq: {}: {}", path, rt::strerror(e));
                final_rc = 1;
            }
        }
        return final_rc;
    } else if out_fd != rt::STDOUT {
        rt::close(out_fd);
    }
    rc
}
