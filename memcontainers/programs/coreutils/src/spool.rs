//! Bounded-memory spill support for the text filters that cannot stream — `sort` (external
//! merge-sort) and `tac` (reverse). A guest's own linear memory is tightly capped, so a tool
//! that must hold more than fits spills the overflow to its PRIVATE `/scratch` tmpfs: a
//! per-task mount the kernel grants to any task holding `CAP_SCRATCH` (the `read-only` tier
//! and up) WITHOUT granting write-anywhere `CAP_FS_WRITE`. The bytes still live in kernel RAM
//! (scratch is a tmpfs), but they leave the guest's own capped heap, so peak guest memory
//! tracks the working set rather than the input size.
//!
//!   * [`SpoolFile`] — a uniquely-named scratch file that unlinks itself on drop.
//!   * [`Run`] — a write-once-then-read sorted run (a `SpoolFile` a tool fills, rewinds, and
//!     streams back during a merge), built on [`crate::textio::LineReader`].
//!
//! Built on `//sysroot`; uses `alloc`. Ported from memcontainers' `programs::spool` (§16.2).

use alloc::string::String;
use core::sync::atomic::{AtomicU32, Ordering};

use crate::textio::LineReader;
use sysroot as rt;

/// The per-task private scratch mount (kernel `spawn`; `CAP_SCRATCH`-gated).
pub const SCRATCH_DIR: &str = "/scratch";

/// Distinguishes spool files opened within one process. (Guests are single-threaded, but a
/// tool holds many runs at once during a merge.)
static SEQ: AtomicU32 = AtomicU32::new(0);

/// A scratch-backed temporary file: created empty under [`SCRATCH_DIR`], CLOSED and UNLINKED
/// when dropped, so a spilling tool never leaks files even on an early return. The handle is
/// read+write and seekable. [`create`](SpoolFile::create) returns `Err` if the task lacks
/// `CAP_SCRATCH` (no writable `/scratch`), letting the caller fall back to an in-memory path.
pub struct SpoolFile {
    path: String,
    fd: i32,
}

impl SpoolFile {
    /// Create a fresh, empty, read+write scratch file with a process-unique name.
    pub fn create() -> Result<SpoolFile, i32> {
        let seq = SEQ.fetch_add(1, Ordering::Relaxed);
        let path = alloc::format!("{SCRATCH_DIR}/sp.{}.{}", rt::getpid(), seq);
        let fd = rt::open(&path, rt::O_READ | rt::O_WRITE | rt::O_CREATE | rt::O_TRUNC)?;
        Ok(SpoolFile { path, fd })
    }

    /// The underlying descriptor (valid until this handle drops).
    pub fn fd(&self) -> i32 {
        self.fd
    }

    /// Write all of `buf` at the current offset.
    pub fn write_all(&self, buf: &[u8]) -> Result<(), i32> {
        rt::write_all(self.fd, buf)
    }

    /// Seek back to offset 0 (to read after writing).
    pub fn rewind(&self) -> Result<(), i32> {
        rt::lseek(self.fd, 0, rt::SEEK_SET).map(|_| ())
    }

    /// The file's current length in bytes (leaves the offset at end-of-file).
    pub fn len(&self) -> Result<u64, i32> {
        rt::lseek(self.fd, 0, rt::SEEK_END)
    }
}

impl Drop for SpoolFile {
    fn drop(&mut self) {
        rt::close(self.fd);
        let _ = rt::unlink(&self.path);
    }
}

/// A sorted run for an external merge-sort: a [`SpoolFile`] a tool fills with already-sorted,
/// LF-terminated lines, then [`rewind_for_read`](Run::rewind_for_read) and streams back
/// through [`next_line`](Run::next_line) during the merge. Dropping it unlinks the scratch
/// file, so partial or abandoned runs clean up automatically.
pub struct Run {
    file: SpoolFile,
    reader: Option<LineReader>,
}

impl Run {
    /// Create an empty run.
    pub fn create() -> Result<Run, i32> {
        Ok(Run {
            file: SpoolFile::create()?,
            reader: None,
        })
    }

    /// Append already-formatted (LF-terminated) bytes during the fill phase.
    pub fn write_all(&self, buf: &[u8]) -> Result<(), i32> {
        self.file.write_all(buf)
    }

    /// Rewind to the start and arm the line reader for the merge phase.
    pub fn rewind_for_read(&mut self) -> Result<(), i32> {
        self.file.rewind()?;
        self.reader = Some(LineReader::new(self.file.fd()));
        Ok(())
    }

    /// The next line of the run, or `None` at its end. Call only after
    /// [`rewind_for_read`](Run::rewind_for_read).
    pub fn next_line(&mut self) -> Result<Option<&[u8]>, i32> {
        match self.reader.as_mut() {
            Some(r) => r.next_line(),
            None => Ok(None),
        }
    }
}
