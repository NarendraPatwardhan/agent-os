//! `tac [FILE]...` — concatenate and print files in reverse (last line first).
//!
//! Each input's lines are written in reverse order. A single trailing newline is treated as the
//! last line's terminator (not a spurious empty final line). Multiple operands are processed in
//! REVERSE order, each itself reversed — i.e. `tac a b` is `tac b` then `tac a`, which equals
//! reversing the concatenation when files end in a newline (each file is split into lines on its
//! own, like GNU). Output lines are LF-terminated. With no FILE, or when FILE is `-`, read
//! standard input.
//!
//! **Bounded memory.** A seekable file is read END-to-START a block at a time and its lines
//! emitted in reverse, so nothing is slurped. Non-seekable stdin (a pipe) is first spilled
//! verbatim to the private `/scratch` tmpfs (`CAP_SCRATCH`) and then read backward the same way;
//! if `/scratch` is unavailable it falls back to buffering stdin in memory.
//!
//! Deviations from GNU `tac`: no `-b`/`--before`, `-r`/`--regex`, or `-s`/`--separator` — the
//! record separator is always a trailing newline, fixed before each record. A trailing `\r`
//! (CRLF) is stripped from each emitted line; output is always bare LF.
//!
//! Exit status: `0` success; `1` if a FILE could not be opened or read; `2` on a usage error.
//!
//! Ported from memcontainers' `programs::tac`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

/// Reverse `line` (accumulated rightmost-byte-first), strip a trailing `\r`, write it with an LF,
/// and clear it for the next line.
fn emit_line(line: &mut Vec<u8>) {
    line.reverse();
    if line.last() == Some(&b'\r') {
        line.pop();
    }
    let _ = rt::write_all(rt::STDOUT, line);
    let _ = rt::write_all(rt::STDOUT, b"\n");
    line.clear();
}

/// Read the `len`-byte seekable `fd` from the end and emit its lines reversed. A single trailing
/// newline is dropped (it terminates the last line rather than adding an empty one).
fn read_backward(fd: i32, len: u64) -> Result<(), i32> {
    if len == 0 {
        return Ok(());
    }
    // Drop one trailing '\n' so a newline-terminated file does not gain a spurious empty final
    // line.
    let mut l = len;
    rt::lseek(fd, (len - 1) as i64, rt::SEEK_SET)?;
    let mut one = [0u8; 1];
    if rt::read(fd, &mut one)? == 1 && one[0] == b'\n' {
        l = len - 1;
    }

    let mut line: Vec<u8> = Vec::new(); // bytes accumulated rightmost-first
    let mut buf = [0u8; 8192];
    let mut i = l;
    while i > 0 {
        let bstart = i.saturating_sub(buf.len() as u64);
        let want = (i - bstart) as usize;
        rt::lseek(fd, bstart as i64, rt::SEEK_SET)?;
        let mut got = 0usize;
        while got < want {
            let n = rt::read(fd, &mut buf[got..want])?;
            if n == 0 {
                break;
            }
            got += n;
        }
        for k in (0..got).rev() {
            let b = buf[k];
            if b == b'\n' {
                emit_line(&mut line);
            } else {
                line.push(b);
            }
        }
        i = bstart;
    }
    // The first segment (everything before the first '\n') is always a line.
    emit_line(&mut line);
    Ok(())
}

fn tac_fd(fd: i32) -> Result<(), i32> {
    let len = rt::lseek(fd, 0, rt::SEEK_END)?;
    read_backward(fd, len)
}

/// stdin is not seekable, so spill it to `/scratch` and read that backward.
fn tac_stdin() -> Result<(), i32> {
    match spool::SpoolFile::create() {
        Ok(sf) => {
            let mut buf = [0u8; 8192];
            loop {
                let n = rt::read(rt::STDIN, &mut buf)?;
                if n == 0 {
                    break;
                }
                sf.write_all(&buf[..n])?;
            }
            let len = sf.len()?;
            read_backward(sf.fd(), len)
            // `sf` drops here → unlink.
        }
        Err(_) => tac_stdin_inmemory(),
    }
}

/// Fallback when `/scratch` is unavailable: buffer stdin and reverse in memory.
fn tac_stdin_inmemory() -> Result<(), i32> {
    let mut data: Vec<u8> = Vec::new();
    textio::read_all(rt::STDIN, &mut data)?;
    for line in textio::collect_lines(&data).iter().rev() {
        textio::outln(line);
    }
    Ok(())
}

/// The clap command — the single source of `tac`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("tac")
        .about("Write each FILE to standard output, last line first. With no FILE, or when FILE is -, read standard input.")
        .arg(Arg::new("FILE").action(ArgAction::Append).num_args(0..).help("files to reverse (- for standard input)"))
}

/// `tac [FILE]...`. Returns the exit status (0 success; 1 if a FILE could not be opened or read).
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let ops: Vec<&str> = m
        .get_many::<String>("FILE")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();

    let mut rc = 0;

    if ops.is_empty() {
        if tac_stdin().is_err() {
            rc = 1;
        }
        return rc;
    }

    for &op in ops.iter().rev() {
        if op == "-" {
            if tac_stdin().is_err() {
                rc = 1;
            }
            continue;
        }
        match rt::open(op, rt::O_READ) {
            Ok(fd) => {
                let r = tac_fd(fd);
                rt::close(fd);
                if r.is_err() {
                    rc = 1;
                }
            }
            Err(e) => {
                eprintln!("tac: {}: {}", op, rt::strerror(e));
                rc = 1;
            }
        }
    }
    rc
}
