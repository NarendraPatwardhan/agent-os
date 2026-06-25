//! `wc [OPTION]... [FILE]...` — count lines, words, characters, bytes, and the longest line.
//!
//! `-l` prints the newline count, `-w` the word count (maximal runs of non-whitespace), `-m` the
//! character count (UTF-8 code points), `-c` the byte count, and `-L` the maximum display width of
//! a line (tabs expand to the next multiple of 8, the terminating newline excluded). With no flag
//! the default columns lines, words, bytes are printed. When several columns are selected they
//! print in the fixed GNU order `l w m c L`. With more than one FILE a final `total` row is
//! appended. With no FILE, or when FILE is `-`, read standard input.
//!
//! **Streaming, byte-exact.** Each fd is counted as bytes arrive over a fixed buffer (no
//! whole-input buffer); peak memory is one read buffer. `-m` counts code points by their leading
//! UTF-8 bytes (any non-continuation byte), independent of locale; `-c` is a raw byte count.
//!
//! Deviations from GNU `wc`: the long options (`--lines`, `--words`, `--chars`, `--bytes`,
//! `--max-line-length`) are not implemented; there is no `--files0-from` and no `--total=`
//! control. Column widths are not padded to a common width (fields are single-space separated).
//!
//! Exit status: `0` success; `1` if a FILE could not be opened or read; `2` on a usage error.
//!
//! Ported from memcontainers' `programs::wc`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use sysroot as rt;

/// The five running counters for one input (and the accumulated total).
#[derive(Default)]
struct Counts {
    lines: u64,
    words: u64,
    chars: u64,
    bytes: u64,
    max_line: u64,
}

/// Count one open fd into `c`, streaming over a fixed buffer. Tracks word state and the current
/// display column across reads so the counts and the longest-line width are exact.
fn count_fd(fd: i32, c: &mut Counts) -> Result<(), i32> {
    let mut buf = [0u8; 4096];
    let mut in_word = false;
    let mut col: u64 = 0;
    loop {
        match rt::read(fd, &mut buf) {
            Ok(0) => break,
            Ok(n) => {
                c.bytes += n as u64;
                for &b in &buf[..n] {
                    // A UTF-8 character starts on any non-continuation byte.
                    if b & 0xC0 != 0x80 {
                        c.chars += 1;
                    }
                    if b == b'\n' {
                        c.lines += 1;
                        if col > c.max_line {
                            c.max_line = col;
                        }
                        col = 0;
                    } else if b == b'\t' {
                        col = col - col % 8 + 8;
                    } else if b == b'\r' {
                        // GNU resets the column on CR but still counts the line at LF.
                        col = 0;
                    } else {
                        col += 1;
                    }
                    if b == b' ' || b == b'\n' || b == b'\t' || b == b'\r'
                        || b == 0x0b /* \v */ || b == 0x0c /* \f */
                    {
                        in_word = false;
                    } else if !in_word {
                        in_word = true;
                        c.words += 1;
                    }
                }
            }
            Err(e) => return Err(e),
        }
    }
    // A final line with no trailing newline still counts toward the longest-line width.
    if col > c.max_line {
        c.max_line = col;
    }
    Ok(())
}

/// Append the decimal of `n` to `o`.
fn push_u64(o: &mut Vec<u8>, n: u64) {
    let mut tmp = [0u8; 20];
    let mut i = tmp.len();
    let mut v = n;
    if v == 0 {
        o.push(b'0');
        return;
    }
    while v > 0 {
        i -= 1;
        tmp[i] = b'0' + (v % 10) as u8;
        v /= 10;
    }
    o.extend_from_slice(&tmp[i..]);
}

/// Which columns to print.
struct Sel {
    l: bool,
    w: bool,
    m: bool,
    c: bool,
    max: bool,
}

/// Print one row: the selected counters (in `l w m c L` order, space-separated) then the optional
/// name, terminated by LF.
fn print_row(c: &Counts, name: Option<&[u8]>, sel: &Sel) {
    let mut row: Vec<u8> = Vec::new();
    let mut first = true;
    let mut field = |row: &mut Vec<u8>, v: u64| {
        if !first {
            row.push(b' ');
        }
        push_u64(row, v);
        first = false;
    };
    if sel.l {
        field(&mut row, c.lines);
    }
    if sel.w {
        field(&mut row, c.words);
    }
    if sel.m {
        field(&mut row, c.chars);
    }
    if sel.c {
        field(&mut row, c.bytes);
    }
    if sel.max {
        field(&mut row, c.max_line);
    }
    if let Some(nm) = name {
        row.push(b' ');
        row.extend_from_slice(nm);
    }
    row.push(b'\n');
    let _ = rt::write_all(rt::STDOUT, &row);
}

/// The clap command — the single source of `wc`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("wc")
        .about("Print newline, word, and byte counts for each FILE, and a total line if more than one FILE is specified. With no FILE, or when FILE is -, read standard input. A word is a non-zero-length sequence of characters delimited by white space.")
        .arg(Arg::new("lines").short('l').long("lines").action(ArgAction::SetTrue).help("print the newline counts"))
        .arg(Arg::new("words").short('w').long("words").action(ArgAction::SetTrue).help("print the word counts"))
        .arg(Arg::new("chars").short('m').long("chars").action(ArgAction::SetTrue).help("print the character counts"))
        .arg(Arg::new("bytes").short('c').long("bytes").action(ArgAction::SetTrue).help("print the byte counts"))
        .arg(Arg::new("max-line-length").short('L').long("max-line-length").action(ArgAction::SetTrue).help("print the maximum display width"))
        .arg(Arg::new("FILE").action(ArgAction::Append).num_args(0..).help("files to count (- for standard input)"))
}

/// `wc [OPTION]... [FILE]...`. Returns the exit status (0 success; 1 if a FILE could not be opened
/// or read).
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let fl = m.get_flag("lines");
    let fw = m.get_flag("words");
    let fm = m.get_flag("chars");
    let fc = m.get_flag("bytes");
    let f_max = m.get_flag("max-line-length");
    let any_flag = fl || fw || fm || fc || f_max;
    let sel = if any_flag {
        Sel { l: fl, w: fw, m: fm, c: fc, max: f_max }
    } else {
        // Default columns: lines, words, bytes.
        Sel { l: true, w: true, m: false, c: true, max: false }
    };

    let ops: Vec<&str> = m
        .get_many::<String>("FILE")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();

    let mut rc = 0;

    if ops.is_empty() {
        let mut c = Counts::default();
        if count_fd(rt::STDIN, &mut c).is_err() {
            rc = 1;
        }
        print_row(&c, None, &sel);
        return rc;
    }

    let mut total = Counts::default();
    for &arg in &ops {
        if arg == "-" {
            let mut c = Counts::default();
            if count_fd(rt::STDIN, &mut c).is_err() {
                eprintln!("wc: -: {}", rt::strerror(rt::EIO));
                rc = 1;
            } else {
                print_row(&c, Some(b"-"), &sel);
                total.lines += c.lines;
                total.words += c.words;
                total.chars += c.chars;
                total.bytes += c.bytes;
                if c.max_line > total.max_line {
                    total.max_line = c.max_line;
                }
            }
            continue;
        }
        match rt::open(arg, rt::O_READ) {
            Ok(fd) => {
                let mut c = Counts::default();
                if let Err(e) = count_fd(fd, &mut c) {
                    eprintln!("wc: {}: {}", arg, rt::strerror(e));
                    rc = 1;
                } else {
                    print_row(&c, Some(arg.as_bytes()), &sel);
                    total.lines += c.lines;
                    total.words += c.words;
                    total.chars += c.chars;
                    total.bytes += c.bytes;
                    if c.max_line > total.max_line {
                        total.max_line = c.max_line;
                    }
                }
                rt::close(fd);
            }
            Err(e) => {
                eprintln!("wc: {}: {}", arg, rt::strerror(e));
                rc = 1;
            }
        }
    }
    if ops.len() > 1 {
        print_row(&total, Some(b"total"), &sel);
    }
    rc
}
