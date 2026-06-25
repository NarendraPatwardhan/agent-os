//! `tail [OPTION]... [FILE]...` — output the last part of files or standard input.
//!
//! By default prints the last 10 lines of each FILE. `-n N` / `-c N` set the last-N lines /
//! bytes; `-n +N` / `-c +N` instead output starting at line / byte N (1-based) to the end. The
//! obsolete `-N` form is shorthand for `-n N`, and the obsolete bare `+N` form for `-n +N`.
//! `-q` never prints the `==> NAME <==` header, `-v` always does (default: only with multiple
//! files). `-f` follows: after the initial output it polls each regular-file operand for appended
//! data and streams it, reprinting the header when the active file changes (runs until killed;
//! ignored for stdin). With no FILE, or when FILE is `-`, read standard input.
//!
//! **Bounded memory, byte-exact.** The last-N modes stream through a fixed ring sized by the
//! request — an N-byte ring for `-c`, an N-line ring for `-n`, each line kept verbatim WITH its
//! terminator. The `+N` modes skip a prefix then stream the remainder. Peak memory is the
//! requested tail, independent of file size. Bytes are emitted verbatim (no CRLF normalization).
//!
//! Deviations from GNU `tail`: the long options (`--lines`, `--bytes`, `--follow`, `--quiet`,
//! `--verbose`, `--pid`, `--retry`, `--sleep-interval`, `--max-unchanged-stats`) are not
//! implemented; `-f` polls regular files on a fixed 1s interval, never follows stdin, and does
//! not detect truncation/rotation (`-F` is unavailable); no multiplier suffix (`K`/`M`) on the
//! count; no `-z`/`--zero-terminated`.
//!
//! Exit status: `0` success; `1` if a FILE could not be opened or read; `2` on a usage error.
//!
//! Ported from memcontainers' `programs::tail`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use sysroot as rt;

/// Which span of the input to emit.
enum Mode {
    Lines(usize),    // last N lines
    Bytes(usize),    // last N bytes
    FromLine(usize), // +N: from line N
    FromByte(usize), // -c +N: from byte N
}

/// Header policy across the operand list.
#[derive(Clone, Copy, PartialEq)]
enum Header {
    Auto,
    Always,
    Never,
}

/// Parse a non-negative decimal count (checked), or `None` on any non-digit / empty input.
fn parse_usize(b: &[u8]) -> Option<usize> {
    if b.is_empty() {
        return None;
    }
    let mut v = 0usize;
    for &c in b {
        if !c.is_ascii_digit() {
            return None;
        }
        v = v.checked_mul(10)?.checked_add((c - b'0') as usize)?;
    }
    Some(v)
}

/// Resolve a `-n`/`-c` value (with an optional leading `+`) to a mode.
fn mode_from(flag: u8, val: &[u8]) -> Mode {
    let (plus, digits) = match val.first() {
        Some(b'+') => (true, &val[1..]),
        _ => (false, val),
    };
    let v = parse_usize(digits).unwrap_or(0);
    match (flag, plus) {
        (b'n', false) => Mode::Lines(v),
        (b'n', true) => Mode::FromLine(v),
        (b'c', false) => Mode::Bytes(v),
        _ => Mode::FromByte(v),
    }
}

/// Ring buffer of the last `n` bytes (`tail -c N`).
struct ByteTail {
    ring: Vec<u8>,
    n: usize,
    pos: usize,
    full: bool,
}

impl ByteTail {
    fn new(n: usize) -> ByteTail {
        ByteTail {
            ring: alloc::vec![0u8; n],
            n,
            pos: 0,
            full: false,
        }
    }
    fn push(&mut self, mut c: &[u8]) {
        if self.n == 0 {
            return;
        }
        if c.len() >= self.n {
            self.ring.copy_from_slice(&c[c.len() - self.n..]);
            self.pos = 0;
            self.full = true;
            return;
        }
        while !c.is_empty() {
            let take = (self.n - self.pos).min(c.len());
            self.ring[self.pos..self.pos + take].copy_from_slice(&c[..take]);
            self.pos += take;
            if self.pos == self.n {
                self.pos = 0;
                self.full = true;
            }
            c = &c[take..];
        }
    }
    fn emit(&self) {
        if self.full {
            let _ = rt::write_all(rt::STDOUT, &self.ring[self.pos..]);
            let _ = rt::write_all(rt::STDOUT, &self.ring[..self.pos]);
        } else {
            let _ = rt::write_all(rt::STDOUT, &self.ring[..self.pos]);
        }
    }
}

/// Ring buffer of the last `n` lines (`tail -n N`), each kept with its terminator.
struct LineTail {
    buf: Vec<Vec<u8>>,
    n: usize,
    next: usize,
    carry: Vec<u8>,
}

impl LineTail {
    fn new(n: usize) -> LineTail {
        LineTail {
            buf: Vec::new(),
            n,
            next: 0,
            carry: Vec::new(),
        }
    }
    fn push(&mut self, c: &[u8]) {
        for &b in c {
            self.carry.push(b);
            if b == b'\n' {
                let line = core::mem::take(&mut self.carry);
                self.add(line);
            }
        }
    }
    fn finish(&mut self) {
        if !self.carry.is_empty() {
            let line = core::mem::take(&mut self.carry);
            self.add(line);
        }
    }
    fn add(&mut self, line: Vec<u8>) {
        if self.n == 0 {
            return;
        }
        if self.buf.len() < self.n {
            self.buf.push(line);
        } else {
            self.buf[self.next] = line;
            self.next = (self.next + 1) % self.n;
        }
    }
    fn emit(&self) {
        if self.buf.len() < self.n {
            for l in &self.buf {
                let _ = rt::write_all(rt::STDOUT, l);
            }
        } else {
            for k in 0..self.n {
                let _ = rt::write_all(rt::STDOUT, &self.buf[(self.next + k) % self.n]);
            }
        }
    }
}

/// Stream `fd` through the ring (last-N modes) or skip-then-copy (`+N` modes).
fn tail_stream(fd: i32, mode: &Mode) -> Result<(), i32> {
    let mut buf = [0u8; 8192];
    match mode {
        Mode::Bytes(k) => {
            let mut t = ByteTail::new(*k);
            loop {
                let n = rt::read(fd, &mut buf)?;
                if n == 0 {
                    break;
                }
                t.push(&buf[..n]);
            }
            t.emit();
        }
        Mode::Lines(k) => {
            let mut t = LineTail::new(*k);
            loop {
                let n = rt::read(fd, &mut buf)?;
                if n == 0 {
                    break;
                }
                t.push(&buf[..n]);
            }
            t.finish();
            t.emit();
        }
        Mode::FromByte(start) => {
            let mut skip = start.saturating_sub(1);
            loop {
                let n = rt::read(fd, &mut buf)?;
                if n == 0 {
                    break;
                }
                let mut s = 0;
                if skip > 0 {
                    let drop = skip.min(n);
                    skip -= drop;
                    s = drop;
                }
                if s < n {
                    rt::write_all(rt::STDOUT, &buf[s..n])?;
                }
            }
        }
        Mode::FromLine(start) => {
            let skip_lines = start.saturating_sub(1);
            let mut seen = 0usize;
            let mut started = skip_lines == 0;
            loop {
                let n = rt::read(fd, &mut buf)?;
                if n == 0 {
                    break;
                }
                let mut s = 0;
                if !started {
                    while s < n {
                        let nl = buf[s] == b'\n';
                        s += 1;
                        if nl {
                            seen += 1;
                            if seen == skip_lines {
                                started = true;
                                break;
                            }
                        }
                    }
                }
                if started && s < n {
                    rt::write_all(rt::STDOUT, &buf[s..n])?;
                }
            }
        }
    }
    Ok(())
}

fn print_header(name: &[u8], first: bool) {
    if !first {
        let _ = rt::write_all(rt::STDOUT, b"\n");
    }
    let _ = rt::write_all(rt::STDOUT, b"==> ");
    let _ = rt::write_all(rt::STDOUT, name);
    let _ = rt::write_all(rt::STDOUT, b" <==\n");
}

/// Poll the still-open regular-file operands for appended data and stream it, printing the header
/// when the active file changes (GNU `-f`). Runs until killed.
fn follow_loop(files: &[(Vec<u8>, i32)], headers: bool) -> ! {
    let mut buf = [0u8; 8192];
    let mut active: isize = -1;
    loop {
        for (idx, (name, fd)) in files.iter().enumerate() {
            loop {
                match rt::read(*fd, &mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        if headers && active != idx as isize {
                            print_header(name, false);
                            active = idx as isize;
                        }
                        let _ = rt::write_all(rt::STDOUT, &buf[..n]);
                    }
                    Err(_) => break,
                }
            }
        }
        let _ = rt::sleep_ms(1000);
    }
}

/// The clap command — the single source of `tail`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("tail")
        .about("Print the last 10 lines of each FILE to standard output. With more than one FILE, precede each with a header giving the file name. With no FILE, or when FILE is -, read standard input.")
        .arg(Arg::new("bytes").short('c').long("bytes").value_name("N").num_args(1).help("output the last N bytes; or use -c +N to output starting with byte N"))
        .arg(Arg::new("lines").short('n').long("lines").value_name("N").num_args(1).help("output the last N lines (default 10); or use -n +N to output starting with line N"))
        .arg(Arg::new("follow").short('f').long("follow").action(ArgAction::SetTrue).help("output appended data as the file grows (polls regular files; ignores stdin)"))
        .arg(Arg::new("quiet").short('q').long("quiet").visible_alias("silent").action(ArgAction::SetTrue).help("never print headers giving file names"))
        .arg(Arg::new("verbose").short('v').long("verbose").action(ArgAction::SetTrue).help("always print headers giving file names"))
        .arg(Arg::new("FILE").action(ArgAction::Append).num_args(0..).help("files to read (- for standard input)"))
}

/// `tail [OPTION]... [FILE]...`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    // GNU accepts the obsolete `-N` (last N lines) and bare `+N` (from line N) operand forms.
    // clap cannot model `-N`/`+N`, so capture them in a pre-pass and rewrite into `-n` values,
    // forwarding everything else to clap unchanged.
    let argv: Vec<std::ffi::OsString> = args.collect();
    let mut rewritten: Vec<std::ffi::OsString> = Vec::with_capacity(argv.len());
    let mut obsolete_mode: Option<Mode> = None;
    for (i, a) in argv.iter().enumerate() {
        if i > 0 {
            if let Some(s) = a.to_str() {
                // `-<digits>` → last N lines.
                if let Some(d) = s.strip_prefix('-') {
                    if !d.is_empty() && d.bytes().all(|b| b.is_ascii_digit()) {
                        obsolete_mode = Some(Mode::Lines(parse_usize(d.as_bytes()).unwrap_or(0)));
                        continue;
                    }
                }
                // `+<digits>` → from line N.
                if let Some(d) = s.strip_prefix('+') {
                    if !d.is_empty() && d.bytes().all(|b| b.is_ascii_digit()) {
                        obsolete_mode =
                            Some(Mode::FromLine(parse_usize(d.as_bytes()).unwrap_or(0)));
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
        mode_from(b'c', c.as_bytes())
    } else if let Some(n) = m.get_one::<String>("lines") {
        mode_from(b'n', n.as_bytes())
    } else if let Some(om) = obsolete_mode {
        om
    } else {
        Mode::Lines(10)
    };

    let follow = m.get_flag("follow");
    let header = if m.get_flag("verbose") {
        Header::Always
    } else if m.get_flag("quiet") {
        Header::Never
    } else {
        Header::Auto
    };

    let ops: Vec<&str> = m
        .get_many::<String>("FILE")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();

    if ops.is_empty() {
        let _ = tail_stream(rt::STDIN, &mode);
        return 0; // `-f` on stdin: nothing to poll once it ends.
    }

    // Open every operand up front so `-f` can keep regular files open afterwards.
    let show_headers = match header {
        Header::Always => true,
        Header::Never => false,
        Header::Auto => ops.len() > 1,
    };
    let mut open: Vec<(Vec<u8>, i32)> = Vec::new();
    let mut rc = 0;
    let mut first_header = true;
    for &f in &ops {
        if f == "-" {
            if show_headers {
                print_header(b"standard input", first_header);
                first_header = false;
            }
            if tail_stream(rt::STDIN, &mode).is_err() {
                rc = 1;
            }
            continue;
        }
        match rt::open(f, rt::O_READ) {
            Ok(fd) => {
                if show_headers {
                    print_header(f.as_bytes(), first_header);
                    first_header = false;
                }
                if tail_stream(fd, &mode).is_err() {
                    rc = 1;
                }
                open.push((f.as_bytes().to_vec(), fd));
            }
            Err(e) => {
                eprintln!("tail: {}: {}", f, rt::strerror(e));
                rc = 1;
            }
        }
    }

    if follow && !open.is_empty() {
        // The active-file marker resets, so the first appended data reprints the header; runs
        // until the process is killed.
        follow_loop(&open, show_headers);
    }
    for (_, fd) in &open {
        rt::close(*fd);
    }
    rc
}
