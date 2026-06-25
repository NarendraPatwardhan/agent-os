//! I/O sinks and sources for builtin standard streams.
//!
//! Builtins write through a `WriteSink` (stdout/stderr) and read through a
//! `ReadSource` (stdin). The concrete implementations resolve to:
//!
//!   - TerminalSink    → bridge::mc_stdout_write / mc_stderr_write
//!   - FileSink        → Box<dyn FileHandle> for `>` and `>>`
//!   - PipeSink        → *const Pipe for inter-task pipelines
//!   - EmptySource     → immediate EOF (default stdin)
//!   - FileSource      → Box<dyn FileHandle> for `<`
//!   - PipeSource      → *const Pipe for inter-task pipelines
//!
//! PipeSink::write returns `Ok(0)` when the ring buffer is full but not yet
//! closed; the caller (the task runner) reads `block_handle()` to learn which
//! pipe to block on. Symmetrically PipeSource::read returns `Ok(0)` with
//! `is_eof() == false` when the buffer is empty and the write end is still
//! open. Non-pipe sinks/sources never block.

use alloc::boxed::Box;
use alloc::rc::Rc;
use alloc::vec::Vec;
use core::cell::RefCell;

use crate::bridge;
use crate::ipc::Pipe;
use crate::vfs::{FileHandle, FsError};

pub trait WriteSink {
    /// Try to push `buf` into the sink. May write fewer bytes than `buf.len()`
    /// when the sink is full (only meaningful for pipes). Returns `Ok(0)` for
    /// "would block" — the caller checks `block_handle()` to learn the pipe.
    fn write(&mut self, buf: &[u8]) -> Result<usize, FsError>;
    /// Called once when the task closes this sink — e.g. to mark a pipe's
    /// write end closed so readers see EOF.
    fn close(&mut self) {}
    /// `Some(addr)` iff this sink is a pipe and the caller should block on
    /// it. Used to populate `BlockReason::PipeWrite`.
    fn block_handle(&self) -> Option<usize> {
        None
    }
    /// Produce a child-inheritable handle to the *same* destination when a
    /// spawn passes fd 1/2 ("inherit my stdout/stderr"). `None` means "not
    /// directly inheritable" — the caller falls back to the terminal. A pipe
    /// returns a fresh write end (its own refcount); a capture buffer shares
    /// its `Rc`. Without this, a child of a task whose stdout is a capture
    /// buffer (e.g. `cat` under `mc_ctl_exec`'s `/bin/sh -c`) would silently
    /// write to the terminal instead of the captured stream.
    fn inherit_for_child(&self) -> Option<Box<dyn WriteSink>> {
        None
    }
    /// `mc_sys_poll` readiness: would a `write` make progress *without*
    /// blocking? Default `true` (terminals/files always accept); a pipe is
    /// writable iff it has space or its read end is closed (a closed read end
    /// makes `write` return immediately — with an error, but never blocks).
    fn poll_writable(&self) -> bool {
        true
    }
    /// `mc_sys_poll` error condition (`POLLERR`): the peer end is gone. Default
    /// `false`; a pipe sink reports it once the read end is closed.
    fn poll_err(&self) -> bool {
        false
    }
    /// True iff this sink is the controlling terminal (not a pipe, file, or
    /// capture buffer). Backs `mc_sys_isatty`, which `nohup` uses to redirect a
    /// stream to `nohup.out` only when it is a tty.
    fn is_terminal(&self) -> bool {
        false
    }
}

pub trait ReadSource {
    /// Try to fill `buf`. Returns `Ok(0)` for EOF *or* "would block"; the
    /// caller disambiguates via `is_eof()`.
    fn read(&mut self, buf: &mut [u8]) -> Result<usize, FsError>;
    /// True when no more bytes will ever arrive. For a pipe, true iff the
    /// buffer is empty AND the write end is closed.
    fn is_eof(&self) -> bool;
    /// Called once when the task closes this source — for a pipe this
    /// marks the read end closed so the upstream writer's next write
    /// returns broken-pipe and unwedges it.
    fn close(&mut self) {}
    /// `Some(addr)` iff this source is a pipe and the caller should block
    /// on it. Used to populate `BlockReason::PipeRead`.
    fn block_handle(&self) -> Option<usize> {
        None
    }
    /// `mc_sys_poll` readiness: would a `read` return *without* blocking?
    /// Default `true` (files/EOF sources are always readable — a read returns
    /// data or 0); a pipe is readable iff it has buffered data or its write end
    /// is closed (EOF, which a `read` reports immediately as 0).
    fn poll_readable(&self) -> bool {
        true
    }
    /// `mc_sys_poll` hang-up condition (`POLLHUP`): the writer end is gone.
    /// Default `false`; a pipe source reports it once the write end is closed,
    /// and an empty source is always hung up (immediate EOF).
    fn poll_hup(&self) -> bool {
        false
    }
    /// True iff this source is *itself* the controlling terminal. Interactive
    /// stdin is wired as a console pipe, so no source type reports `true` here;
    /// `mc_sys_isatty(0)` instead recognises the terminal by pipe identity
    /// (matching `block_handle()` against `crate::console_pipe_addr()`), so the
    /// live prompt and its children report `isatty(0) == true` while an ordinary
    /// `cat | foo` pipe does not. `nohup` keys off the stdout/stderr checks.
    fn is_terminal(&self) -> bool {
        false
    }
}

// ------ Terminal (ONLCR) ------

/// Write `buf` to the host terminal (stdout), translating `\n` -> `\r\n` (POSIX
/// `ONLCR`). All TOOL/GUEST output emits plain LF internally; the CR is added here
/// — and ONLY here — so files and pipes (which never pass through this path) stay
/// pure LF. Stateless and allocation-free: emit each `\n`-free run, then `\r\n`.
///
/// Every tool/guest terminal write routes through this: guest fd 1/2 (via
/// `TerminalSink`) and `/dev/cons`. The kernel's OWN terminal *chrome* — boot
/// banners (`init.rs`) and the line-discipline keystroke echo + rescue prompt
/// (`lib.rs`) — writes CRLF directly to the host instead; it is the terminal
/// layer itself, not LF tool output, so it sits below ONLCR by design.
pub fn term_write_stdout(buf: &[u8]) {
    term_write(buf, false);
}

/// Like [`term_write_stdout`] but for stderr.
pub fn term_write_stderr(buf: &[u8]) {
    term_write(buf, true);
}

fn term_write(buf: &[u8], stderr: bool) {
    fn emit(b: &[u8], stderr: bool) {
        if b.is_empty() {
            return;
        }
        unsafe {
            if stderr {
                bridge::mc_stderr_write(b.as_ptr(), b.len());
            } else {
                bridge::mc_stdout_write(b.as_ptr(), b.len());
            }
        }
    }
    let mut start = 0;
    for i in 0..buf.len() {
        if buf[i] == b'\n' {
            emit(&buf[start..i], stderr);
            emit(b"\r\n", stderr);
            start = i + 1;
        }
    }
    emit(&buf[start..], stderr);
}

#[derive(Clone, Copy)]
pub enum TerminalSink {
    Stdout,
    Stderr,
}

impl WriteSink for TerminalSink {
    fn write(&mut self, buf: &[u8]) -> Result<usize, FsError> {
        match self {
            TerminalSink::Stdout => term_write_stdout(buf),
            TerminalSink::Stderr => term_write_stderr(buf),
        }
        Ok(buf.len())
    }
    fn is_terminal(&self) -> bool {
        true
    }
}

// ------ Capture ------

/// A `WriteSink` that accumulates bytes into a shared buffer. The host
/// control channel (`mc_ctl_exec`) backs a command's tail stdout and every
/// command's stderr with one of these instead of the terminal, then reads
/// the accumulated bytes once the job completes. The buffer is `Rc`-shared so
/// the same logical stream can back several tasks (a pipeline's stderr) while
/// the control job retains a handle to read it. Single-threaded cooperative
/// discipline (or the BKL on the threaded build) makes the `RefCell` sound.
pub struct CaptureSink(pub Rc<RefCell<Vec<u8>>>);

impl WriteSink for CaptureSink {
    fn write(&mut self, buf: &[u8]) -> Result<usize, FsError> {
        self.0.borrow_mut().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn inherit_for_child(&self) -> Option<Box<dyn WriteSink>> {
        // Share the same buffer so a spawned child's stdout/stderr lands in
        // the captured stream the control job will read.
        Some(Box::new(CaptureSink(self.0.clone())))
    }
}

// SAFETY: like the other sinks, only ever touched under the kernel's
// single-threaded cooperative discipline / the BKL. The `Rc` is never shared
// across threads.
unsafe impl Send for CaptureSink {}
unsafe impl Sync for CaptureSink {}

// ------ Empty ------

pub struct EmptySource;

impl ReadSource for EmptySource {
    fn read(&mut self, _buf: &mut [u8]) -> Result<usize, FsError> {
        Ok(0)
    }
    fn is_eof(&self) -> bool {
        true
    }
    fn poll_hup(&self) -> bool {
        true // immediate EOF — the (nonexistent) writer is gone
    }
}

// ------ File ------

pub struct FileSink(pub Box<dyn FileHandle>);

impl WriteSink for FileSink {
    fn write(&mut self, buf: &[u8]) -> Result<usize, FsError> {
        self.0.write(buf)
    }
}

pub struct FileSource(pub Box<dyn FileHandle>);

impl ReadSource for FileSource {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize, FsError> {
        self.0.read(buf)
    }
    fn is_eof(&self) -> bool {
        // The runner stops calling `read` once it observes 0; a file with
        // bytes left always returns >0. Treat 0 as EOF unconditionally.
        true
    }
}

// ------ Pipe ------
//
// SAFETY: a `Pipe` lives inside `Scheduler.pipes: Vec<Box<Pipe>>`; the Box
// gives it a stable heap address. The scheduler never drops a pipe while
// any task still references it (see `Scheduler::reap_dead_pipes`). The raw
// pointer the sink holds is therefore valid for the task's lifetime.

pub struct PipeSink {
    pub pipe: *const Pipe,
    closed: bool,
}

impl PipeSink {
    pub fn new(pipe: &Pipe) -> Self {
        pipe.add_writer();
        Self {
            pipe: pipe as *const Pipe,
            closed: false,
        }
    }
    fn pipe(&self) -> &Pipe {
        unsafe { &*self.pipe }
    }
}

impl Drop for PipeSink {
    fn drop(&mut self) {
        // Release the write-end reference exactly once (close() is idempotent).
        self.close();
    }
}

impl WriteSink for PipeSink {
    fn write(&mut self, buf: &[u8]) -> Result<usize, FsError> {
        let p = self.pipe();
        if p.is_read_closed() {
            // Writer should treat this as a broken pipe; surface as an
            // error so the builtin's exit code reflects it.
            return Err(FsError::IoError);
        }
        Ok(p.buffer.write(buf))
    }
    fn close(&mut self) {
        if !self.closed {
            self.closed = true;
            self.pipe().close_write();
        }
    }
    fn block_handle(&self) -> Option<usize> {
        Some(self.pipe as usize)
    }
    fn inherit_for_child(&self) -> Option<Box<dyn WriteSink>> {
        // A fresh write end on the same pipe (its own refcount via `new`).
        Some(Box::new(PipeSink::new(self.pipe())))
    }
    fn poll_writable(&self) -> bool {
        let p = self.pipe();
        !p.buffer.is_full() || p.is_read_closed()
    }
    fn poll_err(&self) -> bool {
        self.pipe().is_read_closed()
    }
}

pub struct PipeSource {
    pub pipe: *const Pipe,
    closed: bool,
}

impl PipeSource {
    pub fn new(pipe: &Pipe) -> Self {
        pipe.add_reader();
        Self {
            pipe: pipe as *const Pipe,
            closed: false,
        }
    }
    fn pipe(&self) -> &Pipe {
        unsafe { &*self.pipe }
    }
}

impl Drop for PipeSource {
    fn drop(&mut self) {
        // Release the read-end reference exactly once (close() is idempotent).
        self.close();
    }
}

impl ReadSource for PipeSource {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize, FsError> {
        Ok(self.pipe().buffer.read(buf))
    }
    fn is_eof(&self) -> bool {
        let p = self.pipe();
        p.buffer.is_empty() && p.is_write_closed()
    }
    fn close(&mut self) {
        if !self.closed {
            self.closed = true;
            self.pipe().close_read();
        }
    }
    fn block_handle(&self) -> Option<usize> {
        Some(self.pipe as usize)
    }
    fn poll_readable(&self) -> bool {
        let p = self.pipe();
        !p.buffer.is_empty() || p.is_write_closed()
    }
    fn poll_hup(&self) -> bool {
        self.pipe().is_write_closed()
    }
}

// SAFETY: a `Pipe` inside the scheduler outlives every task that references
// it; the kernel is single-threaded in cooperative mode (the only mode
// supported before threading was introduced). Pipes are not aliased mutably
// from multiple places at the same time.
unsafe impl Send for PipeSink {}
unsafe impl Sync for PipeSink {}
unsafe impl Send for PipeSource {}
unsafe impl Sync for PipeSource {}
