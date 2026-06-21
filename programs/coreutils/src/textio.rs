//! Text I/O for the filter coreutils. One CRLF-tolerant line model underlies two styles
//! (input: a line is the bytes up to `\n`, with the `\n` and any preceding `\r` stripped;
//! output: bare `\n`, the terminal adds CR via ONLCR):
//!
//!   * STREAMING (bounded memory) — [`LineReader`] reads one fd a line at a time over a fixed
//!     buffer; [`stream_lines`] drives it across the usual operand list (stdin for an empty
//!     list or a `-` operand); [`BufOut`] is the matching chunked stdout sink. Peak memory is
//!     one line, independent of input size.
//!   * WHOLE-INPUT — [`read_all`]/[`collect_lines`] hold an entire input at once, for the few
//!     tools that genuinely need every byte.
//!
//! Built on `//sysroot`; uses `alloc`. Ported from memcontainers' `programs::textio`.

use alloc::vec::Vec;

use sysroot as rt;

/// Output is flushed to stdout in chunks of this size (see [`BufOut`]).
const CHUNK: usize = 1 << 14; // 16 KiB

/// Read all of `fd` to EOF, appending to `out`.
pub fn read_all(fd: i32, out: &mut Vec<u8>) -> Result<(), i32> {
    let mut buf = [0u8; 8192];
    loop {
        match rt::read(fd, &mut buf) {
            Ok(0) => return Ok(()),
            Ok(n) => out.extend_from_slice(&buf[..n]),
            Err(e) => return Err(e),
        }
    }
}

/// Strip a single trailing `\r` (the CR of a CRLF pair) from a line slice.
pub fn chomp(line: &[u8]) -> &[u8] {
    match line.last() {
        Some(b'\r') => &line[..line.len() - 1],
        _ => line,
    }
}

/// Collect the lines of `data` (same splitting as [`LineReader`]) into a vector borrowing
/// `data` — for the few tools that must hold all lines at once. A trailing newline does not
/// yield an empty final line; a missing final newline still yields the last partial line.
pub fn collect_lines(data: &[u8]) -> Vec<&[u8]> {
    let mut v = Vec::new();
    let mut start = 0usize;
    for i in 0..data.len() {
        if data[i] == b'\n' {
            v.push(chomp(&data[start..i]));
            start = i + 1;
        }
    }
    if start < data.len() {
        v.push(chomp(&data[start..]));
    }
    v
}

/// Write raw bytes to stdout (best-effort).
pub fn out(s: &[u8]) {
    let _ = rt::write_all(rt::STDOUT, s);
}

/// Write bytes followed by LF to stdout (best-effort).
pub fn outln(s: &[u8]) {
    let _ = rt::write_all(rt::STDOUT, s);
    let _ = rt::write_all(rt::STDOUT, b"\n");
}

/// A forward line reader over `fd` with a fixed read buffer, so input streams a line at a
/// time instead of being slurped. Splits on `\n`; the terminator and any preceding `\r` are
/// stripped (CRLF-tolerant). The final line need not be newline-terminated. Does NOT own `fd`
/// (the caller closes it).
pub struct LineReader {
    fd: i32,
    buf: Vec<u8>,
    start: usize,
    end: usize,
    line: Vec<u8>,
    eof: bool,
}

impl LineReader {
    const CAP: usize = 8192;

    pub fn new(fd: i32) -> LineReader {
        LineReader {
            fd,
            buf: alloc::vec![0u8; Self::CAP],
            start: 0,
            end: 0,
            line: Vec::new(),
            eof: false,
        }
    }

    /// The next line (terminator stripped), or `None` at end of input. The slice borrows
    /// internal state and is valid only until the next call.
    pub fn next_line(&mut self) -> Result<Option<&[u8]>, i32> {
        self.line.clear();
        loop {
            if self.start < self.end {
                if let Some(pos) = self.buf[self.start..self.end].iter().position(|&b| b == b'\n') {
                    let e = self.start + pos;
                    self.line.extend_from_slice(&self.buf[self.start..e]);
                    self.start = e + 1;
                    strip_cr(&mut self.line);
                    return Ok(Some(&self.line));
                }
                // No newline in the buffer: carry the remainder, then refill.
                self.line.extend_from_slice(&self.buf[self.start..self.end]);
                self.start = self.end;
            }
            if self.eof {
                if self.line.is_empty() {
                    return Ok(None);
                }
                strip_cr(&mut self.line);
                return Ok(Some(&self.line));
            }
            self.start = 0;
            self.end = 0;
            let n = rt::read(self.fd, &mut self.buf)?;
            if n == 0 {
                self.eof = true;
            } else {
                self.end = n;
            }
        }
    }
}

/// Stream the lines of every input operand — stdin for an empty `ops` or a `-` operand — to
/// `f`, one CRLF-stripped line at a time: the bounded-memory counterpart to a slurp +
/// per-line loop. `f` returns `Err` to stop early (e.g. stdout closed). Open/read failures
/// are reported as `prog: name: reason` and set the returned status to 1, but the remaining
/// inputs still stream (GNU behavior).
pub fn stream_lines(prog: &str, ops: &[&[u8]], mut f: impl FnMut(&[u8]) -> Result<(), i32>) -> i32 {
    let mut rc = 0;
    if ops.is_empty() {
        stream_fd(rt::STDIN, &mut f, &mut rc);
        return rc;
    }
    for &arg in ops {
        if arg == b"-" {
            if !stream_fd(rt::STDIN, &mut f, &mut rc) {
                break;
            }
            continue;
        }
        match core::str::from_utf8(arg).ok().map(|p| rt::open(p, rt::O_READ)) {
            Some(Ok(fd)) => {
                let cont = stream_fd(fd, &mut f, &mut rc);
                rt::close(fd);
                if !cont {
                    break;
                }
            }
            Some(Err(e)) => {
                eprintln!("{}: {}: {}", prog, String::from_utf8_lossy(arg), rt::strerror(e));
                rc = 1;
            }
            None => {
                eprintln!("{}: {}: invalid path", prog, String::from_utf8_lossy(arg));
                rc = 1;
            }
        }
    }
    rc
}

/// Stream one fd's lines to `f`. Returns `true` to continue to the next operand, `false` if
/// `f` asked to stop. A read error sets `*rc = 1` and ends this fd only.
fn stream_fd(fd: i32, f: &mut impl FnMut(&[u8]) -> Result<(), i32>, rc: &mut i32) -> bool {
    let mut lr = LineReader::new(fd);
    loop {
        match lr.next_line() {
            Ok(Some(line)) => {
                if f(line).is_err() {
                    return false;
                }
            }
            Ok(None) => return true,
            Err(_) => {
                *rc = 1;
                return true;
            }
        }
    }
}

/// A chunked stdout sink: bytes accumulate and flush automatically once a line pushes the
/// buffer past [`CHUNK`], so a streaming filter holds at most ~one chunk plus the current
/// line. Build a line with [`extend`](BufOut::extend)/[`push`](BufOut::push) then
/// [`end_line`](BufOut::end_line) (or [`line`](BufOut::line) one-shot), and call
/// [`finish`](BufOut::finish) once at the end. `Err` from any method means the downstream
/// closed (broken pipe) — the caller should stop.
pub struct BufOut {
    fd: i32,
    buf: Vec<u8>,
}

impl BufOut {
    /// A sink writing to stdout.
    pub fn new() -> BufOut {
        BufOut::with_fd(rt::STDOUT)
    }

    /// A sink writing to an arbitrary fd (e.g. a tool's OUTPUT-file operand).
    pub fn with_fd(fd: i32) -> BufOut {
        BufOut { fd, buf: Vec::new() }
    }

    /// Append raw bytes to the line under construction (no flush).
    pub fn extend(&mut self, s: &[u8]) {
        self.buf.extend_from_slice(s);
    }

    /// Append one byte to the line under construction (no flush).
    pub fn push(&mut self, b: u8) {
        self.buf.push(b);
    }

    /// Terminate the current line with LF and flush if the buffer is full.
    pub fn end_line(&mut self) -> Result<(), i32> {
        self.buf.push(b'\n');
        self.flush_if_full()
    }

    /// Emit a complete line in one shot (`extend` + `end_line`).
    pub fn line(&mut self, s: &[u8]) -> Result<(), i32> {
        self.buf.extend_from_slice(s);
        self.end_line()
    }

    /// Flush any buffered bytes (call once when done).
    pub fn finish(&mut self) -> Result<(), i32> {
        if !self.buf.is_empty() {
            rt::write_all(self.fd, &self.buf)?;
            self.buf.clear();
        }
        Ok(())
    }

    fn flush_if_full(&mut self) -> Result<(), i32> {
        if self.buf.len() >= CHUNK {
            rt::write_all(self.fd, &self.buf)?;
            self.buf.clear();
        }
        Ok(())
    }
}

impl Default for BufOut {
    fn default() -> Self {
        BufOut::new()
    }
}

/// Strip a single trailing `\r` from a line being assembled.
fn strip_cr(v: &mut Vec<u8>) {
    if v.last() == Some(&b'\r') {
        v.pop();
    }
}
