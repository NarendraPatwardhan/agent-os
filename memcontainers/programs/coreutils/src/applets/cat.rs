//! `cat [FILE...]` — concatenate files (or stdin) to stdout. The "from programs" representative
//! (VISION §16.3): HAND-WRITTEN logic, args+help via **clap** (reused, not re-rolled), I/O via
//! the **facade** (`BufOut`) over **`//sysroot`** — i.e. mc-direct, the path uutils does not
//! give us. With no display flags it streams verbatim (bytes preserved, no CRLF normalization);
//! the display flags switch to a byte-exact, line-oriented pass that is ALSO streaming (bounded
//! output buffer, one line of carry). Line numbering and squeeze state carry across operands,
//! and the whole operand list is one byte stream (a file with no trailing newline joins the
//! next file's first line, like GNU).

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

/// Open a path for reading, or return its sysroot errno.
fn open_read(path: &str) -> Result<i32, i32> {
    rt::open(path, rt::O_READ)
}

/// Verbatim stream of one fd to stdout. Returns false if stdout closed (stop).
fn cat_fd(fd: i32) -> bool {
    let mut buf = [0u8; 4096];
    loop {
        match rt::read(fd, &mut buf) {
            Ok(0) => return true,
            Ok(n) => {
                if rt::write_all(rt::STDOUT, &buf[..n]).is_err() {
                    return false;
                }
            }
            Err(_) => return false,
        }
    }
}

/// `cat -n`/`-b` line number into the output: 6-wide, right-justified, tab-separated.
fn push_num(o: &mut BufOut, n: u64) {
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
    for _ in tmp[i..].len()..6 {
        o.push(b' ');
    }
    o.extend(&tmp[i..]);
    o.push(b'\t');
}

/// GNU `cat -v` visualization of one byte (never `\t`/`\n`): meta (≥128) prefix `M-`, then `^X`
/// for a control byte, `^?` for DEL, else the byte itself.
fn vis(o: &mut BufOut, b: u8) {
    let mut c = b;
    if c >= 128 {
        o.extend(b"M-");
        c -= 128;
    }
    if c < 32 {
        o.push(b'^');
        o.push(c + 64);
    } else if c == 127 {
        o.extend(b"^?");
    } else {
        o.push(c);
    }
}

/// Streaming, byte-exact transform state, shared across all operands.
struct Cat {
    o: BufOut,
    line: Vec<u8>,
    lineno: u64,
    prev_blank: bool,
    number: bool,
    number_nb: bool,
    squeeze: bool,
    show_ends: bool,
    show_tabs: bool,
    show_nonprint: bool,
}

impl Cat {
    /// Emit the accumulated line (cleared afterwards). `had_nl` is whether it was
    /// newline-terminated; an unterminated final line gets no `$` and no `\n`.
    fn flush_line(&mut self, had_nl: bool) -> Result<(), i32> {
        let blank = self.line.is_empty();
        if self.squeeze && blank && self.prev_blank {
            return Ok(());
        }
        self.prev_blank = blank;

        if self.number_nb {
            if !blank {
                push_num(&mut self.o, self.lineno);
                self.lineno += 1;
            }
        } else if self.number {
            push_num(&mut self.o, self.lineno);
            self.lineno += 1;
        }

        let line = core::mem::take(&mut self.line);
        for &b in &line {
            if b == b'\t' {
                if self.show_tabs {
                    self.o.extend(b"^I");
                } else {
                    self.o.push(b'\t');
                }
            } else if self.show_nonprint {
                vis(&mut self.o, b);
            } else {
                self.o.push(b);
            }
        }
        self.line = line;
        self.line.clear();

        if had_nl {
            if self.show_ends {
                self.o.push(b'$');
            }
            self.o.end_line()?;
        }
        Ok(())
    }

    /// Feed one fd's bytes; the trailing partial line carries to the next fd. Returns false if
    /// stdout closed (stop the whole run).
    fn feed_fd(&mut self, fd: i32) -> bool {
        let mut buf = [0u8; 8192];
        loop {
            match rt::read(fd, &mut buf) {
                Ok(0) => return true,
                Ok(n) => {
                    for &b in &buf[..n] {
                        if b == b'\n' {
                            if self.flush_line(true).is_err() {
                                return false;
                            }
                        } else {
                            self.line.push(b);
                        }
                    }
                }
                Err(_) => return true,
            }
        }
    }

    /// Flush any unterminated final line + the output buffer.
    fn finish(&mut self) -> Result<(), i32> {
        if !self.line.is_empty() {
            self.flush_line(false)?;
        }
        self.o.finish()
    }
}

/// The clap command — the single source of `cat`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("cat")
        .about("Concatenate FILE(s) to standard output. With no FILE, or when FILE is -, read standard input.")
        .arg(Arg::new("number").short('n').long("number").action(ArgAction::SetTrue).help("number all output lines"))
        .arg(Arg::new("number-nonblank").short('b').long("number-nonblank").action(ArgAction::SetTrue).help("number nonempty output lines (overrides -n)"))
        .arg(Arg::new("squeeze-blank").short('s').long("squeeze-blank").action(ArgAction::SetTrue).help("suppress repeated empty output lines"))
        .arg(Arg::new("show-ends").short('E').long("show-ends").action(ArgAction::SetTrue).help("display $ at end of each line"))
        .arg(Arg::new("show-tabs").short('T').long("show-tabs").action(ArgAction::SetTrue).help("display TAB characters as ^I"))
        .arg(Arg::new("show-nonprinting").short('v').long("show-nonprinting").action(ArgAction::SetTrue).help("use ^ and M- notation, except for LFD and TAB"))
        .arg(Arg::new("show-all").short('A').long("show-all").action(ArgAction::SetTrue).help("equivalent to -vET"))
        .arg(Arg::new("e").short('e').action(ArgAction::SetTrue).help("equivalent to -vE"))
        .arg(Arg::new("t").short('t').action(ArgAction::SetTrue).help("equivalent to -vT"))
        .arg(Arg::new("FILE").action(ArgAction::Append).num_args(1..).help("files to concatenate (- for standard input)"))
}

/// `cat [FILE...]`. Returns the exit status (0 success; 1 if a FILE could not be opened).
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        // clap prints help/usage/version itself; mirror its exit code (0 for --help/--version).
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let all = m.get_flag("show-all");
    let number = m.get_flag("number");
    let number_nb = m.get_flag("number-nonblank");
    let squeeze = m.get_flag("squeeze-blank");
    let show_ends = m.get_flag("show-ends") || m.get_flag("e") || all;
    let show_tabs = m.get_flag("show-tabs") || m.get_flag("t") || all;
    let show_nonprint = m.get_flag("show-nonprinting") || m.get_flag("e") || m.get_flag("t") || all;
    let transform = number || number_nb || squeeze || show_ends || show_tabs || show_nonprint;

    let ops: Vec<&str> = m
        .get_many::<String>("FILE")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();

    // Fast path: no display flags → stream verbatim (preserves bytes/endings).
    if !transform {
        if ops.is_empty() {
            cat_fd(rt::STDIN);
            return 0;
        }
        let mut rc = 0;
        for arg in &ops {
            if *arg == "-" {
                if !cat_fd(rt::STDIN) {
                    break;
                }
                continue;
            }
            match open_read(arg) {
                Ok(fd) => {
                    let ok = cat_fd(fd);
                    rt::close(fd);
                    if !ok {
                        break;
                    }
                }
                Err(e) => {
                    eprintln!("cat: {}: {}", arg, rt::strerror(e));
                    rc = 1;
                }
            }
        }
        return rc;
    }

    // Transform path: byte-exact line-oriented streaming, one byte stream across all operands.
    let mut cat = Cat {
        o: BufOut::new(),
        line: Vec::new(),
        lineno: 1,
        prev_blank: false,
        number,
        number_nb,
        squeeze,
        show_ends,
        show_tabs,
        show_nonprint,
    };
    let mut rc = 0;
    let mut stopped = false;
    if ops.is_empty() {
        cat.feed_fd(rt::STDIN);
    } else {
        for arg in &ops {
            if *arg == "-" {
                if !cat.feed_fd(rt::STDIN) {
                    stopped = true;
                    break;
                }
                continue;
            }
            match open_read(arg) {
                Ok(fd) => {
                    let cont = cat.feed_fd(fd);
                    rt::close(fd);
                    if !cont {
                        stopped = true;
                        break;
                    }
                }
                Err(e) => {
                    eprintln!("cat: {}: {}", arg, rt::strerror(e));
                    rc = 1;
                }
            }
        }
    }
    if !stopped {
        let _ = cat.finish();
    }
    rc
}
