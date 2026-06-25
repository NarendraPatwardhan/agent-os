//! `head [OPTION]... [FILE]...` — output the first part of files or standard input.
//!
//! By default prints the first 10 lines of each FILE; `-n N` sets the line count, `-c N` prints
//! the first N bytes instead, and the obsolete `-N` form is shorthand for `-n N` (e.g. `head -5`).
//! With more than one FILE each is preceded by a `==> NAME <==` header (a blank line separating
//! files after the first). With no FILE, or when FILE is `-`, read standard input.
//!
//! **Streaming, byte-exact.** Each fd streams forward only over a fixed buffer — the line/byte
//! limit is honored as bytes arrive, so peak memory is one read buffer regardless of file size.
//! Bytes are emitted verbatim (no CRLF normalization); a `-c` count is a raw byte count.
//!
//! Deviations from GNU `head`: the long options (`--lines`, `--bytes`, `--quiet`, `--verbose`)
//! and the negative `-n -N` / `-c -N` (all-but-last-N) forms are not implemented; there is no
//! `-q`/`-v` header control and no multiplier suffix (`K`, `M`, …) on the count. `-z`/
//! `--zero-terminated` is not implemented.
//!
//! Exit status: `0` success; `1` if a FILE could not be opened; `2` on a usage error (clap).
//!
//! Ported from memcontainers' `programs::head`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use sysroot as rt;

/// First-N-lines vs first-N-bytes.
enum Mode {
    Lines(usize),
    Bytes(usize),
}

/// Parse a non-negative decimal count, or `None` on any non-digit / empty input.
fn parse_usize(b: &[u8]) -> Option<usize> {
    if b.is_empty() {
        return None;
    }
    let mut v: usize = 0;
    for &c in b {
        if !c.is_ascii_digit() {
            return None;
        }
        v = v.checked_mul(10)?.checked_add((c - b'0') as usize)?;
    }
    Some(v)
}

/// Emit the head of one open fd. Returns false if stdout closed (stop the run).
fn head_fd(fd: i32, mode: &Mode) -> bool {
    let mut buf = [0u8; 4096];
    match *mode {
        Mode::Bytes(limit) => {
            let mut remaining = limit;
            while remaining > 0 {
                let want = remaining.min(buf.len());
                match rt::read(fd, &mut buf[..want]) {
                    Ok(0) => break,
                    Ok(r) => {
                        if rt::write_all(rt::STDOUT, &buf[..r]).is_err() {
                            return false;
                        }
                        remaining -= r;
                    }
                    Err(_) => break,
                }
            }
        }
        Mode::Lines(limit) => {
            if limit == 0 {
                return true;
            }
            let mut seen = 0;
            loop {
                match rt::read(fd, &mut buf) {
                    Ok(0) => break,
                    Ok(r) => {
                        for i in 0..r {
                            if buf[i] == b'\n' {
                                seen += 1;
                                if seen >= limit {
                                    let _ = rt::write_all(rt::STDOUT, &buf[..=i]);
                                    return true;
                                }
                            }
                        }
                        if rt::write_all(rt::STDOUT, &buf[..r]).is_err() {
                            return false;
                        }
                    }
                    Err(_) => break,
                }
            }
        }
    }
    true
}

/// The clap command — the single source of `head`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("head")
        .about("Print the first 10 lines of each FILE to standard output. With more than one FILE, precede each with a header giving the file name. With no FILE, or when FILE is -, read standard input.")
        .arg(Arg::new("bytes").short('c').long("bytes").value_name("N").num_args(1).help("print the first N bytes of each file"))
        .arg(Arg::new("lines").short('n').long("lines").value_name("N").num_args(1).help("print the first N lines instead of the first 10"))
        .arg(Arg::new("FILE").action(ArgAction::Append).num_args(0..).help("files to read (- for standard input)"))
}

/// `head [OPTION]... [FILE]...`. Returns the exit status (0 success; 1 if a FILE could not open).
pub fn uumain(args: impl uucore::Args) -> i32 {
    // GNU accepts the obsolete `-N` (e.g. `head -5`) as `-n N`. clap would treat `-5` as an
    // unknown flag, so rewrite a leading bare `-<digits>` operand into `-n <digits>` first.
    let argv: Vec<std::ffi::OsString> = args.collect();
    let mut rewritten: Vec<std::ffi::OsString> = Vec::with_capacity(argv.len() + 1);
    for (i, a) in argv.iter().enumerate() {
        if i > 0 {
            if let Some(s) = a.to_str() {
                let digits = s.strip_prefix('-');
                if let Some(d) = digits {
                    if !d.is_empty() && d.bytes().all(|b| b.is_ascii_digit()) {
                        rewritten.push(std::ffi::OsString::from("-n"));
                        rewritten.push(std::ffi::OsString::from(d));
                        continue;
                    }
                }
            }
        }
        rewritten.push(a.clone());
    }

    let m = match command().try_get_matches_from(rewritten) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let mode = if let Some(c) = m.get_one::<String>("bytes") {
        Mode::Bytes(parse_usize(c.as_bytes()).unwrap_or(0))
    } else if let Some(n) = m.get_one::<String>("lines") {
        Mode::Lines(parse_usize(n.as_bytes()).unwrap_or(0))
    } else {
        Mode::Lines(10)
    };

    let ops: Vec<&str> = m
        .get_many::<String>("FILE")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();

    if ops.is_empty() {
        head_fd(rt::STDIN, &mode);
        return 0;
    }

    let mut rc = 0;
    let multi = ops.len() > 1;
    for (i, &f) in ops.iter().enumerate() {
        if f == "-" {
            if multi {
                if i > 0 {
                    let _ = rt::write_all(rt::STDOUT, b"\n");
                }
                let _ = rt::write_all(rt::STDOUT, b"==> standard input <==\n");
            }
            if !head_fd(rt::STDIN, &mode) {
                break;
            }
            continue;
        }
        match rt::open(f, rt::O_READ) {
            Ok(fd) => {
                if multi {
                    if i > 0 {
                        let _ = rt::write_all(rt::STDOUT, b"\n");
                    }
                    let _ = rt::write_all(rt::STDOUT, b"==> ");
                    let _ = rt::write_all(rt::STDOUT, f.as_bytes());
                    let _ = rt::write_all(rt::STDOUT, b" <==\n");
                }
                let cont = head_fd(fd, &mode);
                rt::close(fd);
                if !cont {
                    break;
                }
            }
            Err(e) => {
                eprintln!("head: {}: {}", f, rt::strerror(e));
                rc = 1;
            }
        }
    }
    rc
}
