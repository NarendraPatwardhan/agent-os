//! Builtin programs as cooperative state machines.
//!
//! Each builtin is a `Box<dyn Builtin>` owned by a Task. The pipeline runner
//! calls `step()` repeatedly; a single step does bounded work (read a chunk
//! from a source, write a chunk to a sink, generate at most a few KiB of
//! output) and returns one of:
//!
//!   - Exit(i32)         → the builtin is done.
//!   - BlockedOnStdin    → stdin returned 0 bytes but is not yet EOF.
//!   - BlockedOnStdout   → stdout sink reported full (pipe with no room).
//!
//! The runner parks the task on the appropriate `BlockReason` when it sees
//! a Blocked* result, and the scheduler's `check_unblocked` wakes it once
//! the underlying pipe state changes. The state machine model is what makes
//! `cat /dev/zero | head -n 1` safe — cat writes 4 KiB at a time and exits
//! as soon as head closes the pipe's read end, instead of buffering /dev/zero
//! to OOM.

use alloc::boxed::Box;
use alloc::string::String;
use alloc::vec::Vec;

use crate::io::{ReadSource, WriteSink};
use crate::task::{BlockReason, Scheduler, TaskId};
use crate::vfs::{FsError, Namespace};

pub mod fs;
pub mod text;

pub use fs::umount_factory;
pub use text::tail_factory;

/// What a builtin's `step` reports back to the runner.
#[derive(Debug)]
pub enum BuiltinStep {
    /// The builtin has produced all its output and exited.
    Exit(i32),
    /// The builtin wants to read more stdin but the source returned 0
    /// bytes without being EOF. The runner parks the task on
    /// `BlockReason::PipeRead`.
    BlockedOnStdin,
    /// The builtin wants to write more output but stdout returned 0
    /// bytes accepted. The runner parks the task on
    /// `BlockReason::PipeWrite`.
    BlockedOnStdout,
    /// The builtin made no progress this step and wants to be re-stepped
    /// next tick — e.g. a network builtin waiting on a host capability
    /// whose response is not ready yet. The runner re-readies the task
    /// (it is not parked on a pipe). One poll per tick, bounded.
    Pending,
    /// Park the task on an explicit block reason. Used by user-space guests
    /// to block on an arbitrary pipe fd or on `waitpid` — the runner calls
    /// `block_task(pid, reason)` directly.
    BlockedOn(BlockReason),
}

/// Per-step context handed to a builtin. Owned by the Task; the runner
/// constructs it from the task's fd table on every step.
pub struct BuiltinCtx<'a> {
    /// This task's (per-process) namespace.
    pub ns: &'a Namespace,
    /// The shared ROOT namespace. Privileged shell builtins (`umount`) manage
    /// the shared mount table here, so the effect persists; ordinary commands
    /// and guests use the per-process `ns`.
    pub root_ns: &'a Namespace,
    pub cwd: &'a mut String,
    pub stdin: &'a mut dyn ReadSource,
    pub stdout: &'a mut dyn WriteSink,
    pub stderr: &'a mut dyn WriteSink,
    /// The scheduler and this task's id — used by user-space guests to spawn
    /// children, allocate pipes, and wait. Ordinary builtins ignore them.
    pub sched: &'a Scheduler,
    pub pid: TaskId,
}

/// A running builtin program. Steps are cooperative — bounded work per
/// call, no internal loops that can hang the scheduler.
pub trait Builtin {
    fn step(&mut self, ctx: &mut BuiltinCtx<'_>) -> BuiltinStep;
}

pub type BuiltinFactory = fn(args: Vec<String>) -> Box<dyn Builtin>;

// ---------- Shared helpers ----------

pub(crate) fn fs_error_str(e: FsError) -> &'static str {
    match e {
        FsError::NotFound => "No such file or directory",
        FsError::AlreadyExists => "File exists",
        FsError::NotDir => "Not a directory",
        FsError::IsDir => "Is a directory",
        FsError::PermissionDenied => "Permission denied",
        FsError::AccessDenied => "Permission denied",
        FsError::InvalidPath => "Invalid path",
        FsError::NotEmpty => "Directory not empty",
        FsError::IoError => "I/O error",
        FsError::BadFileDescriptor => "Bad file descriptor",
        FsError::NotImplemented => "Not implemented",
        FsError::CrossDevice => "Invalid cross-device link",
        FsError::Loop => "Too many levels of symbolic links",
        FsError::WouldBlock => "Resource temporarily unavailable",
        FsError::MessageTooBig => "Message too long",
    }
}

/// Pending bytes buffered for a sink. Builtins keep at most one of these
/// for stdout and one for stderr; each step flushes pending bytes before
/// generating more.
pub(crate) struct OutBuf {
    bytes: Vec<u8>,
    offset: usize,
}

impl OutBuf {
    pub fn new() -> Self {
        Self {
            bytes: Vec::new(),
            offset: 0,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.offset >= self.bytes.len()
    }

    pub fn queue(&mut self, b: &[u8]) {
        // Compact when we've drained everything.
        if self.is_empty() {
            self.bytes.clear();
            self.offset = 0;
        }
        self.bytes.extend_from_slice(b);
    }

    /// Try to push as many pending bytes as possible into `sink`. Returns
    /// `Ok(true)` once the buffer is empty, `Ok(false)` if `sink` reported
    /// full mid-flush, `Err(e)` on a hard write error (e.g. broken pipe).
    pub fn flush(&mut self, sink: &mut dyn WriteSink) -> Result<bool, FsError> {
        while self.offset < self.bytes.len() {
            match sink.write(&self.bytes[self.offset..])? {
                0 => return Ok(false),
                n => self.offset += n,
            }
        }
        self.bytes.clear();
        self.offset = 0;
        Ok(true)
    }
}

/// Append `s` to a pending stderr buffer.
pub(crate) fn push_str(buf: &mut OutBuf, s: &str) {
    buf.queue(s.as_bytes());
}

/// Trivial builtins shared by init.rs.
pub fn true_factory(_args: Vec<String>) -> Box<dyn Builtin> {
    Box::new(ConstExit(0))
}

pub fn false_factory(_args: Vec<String>) -> Box<dyn Builtin> {
    Box::new(ConstExit(1))
}

struct ConstExit(i32);

impl Builtin for ConstExit {
    fn step(&mut self, _ctx: &mut BuiltinCtx<'_>) -> BuiltinStep {
        BuiltinStep::Exit(self.0)
    }
}
