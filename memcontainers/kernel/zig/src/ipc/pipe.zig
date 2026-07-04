//! src/ipc/pipe.zig — pipe ring buffers and reader/writer endpoint semantics (§2.6).
//!
//! Owns: stable ref-counted 64 KiB ring buffers with independent reader/writer ends, backpressure + wakeups, EOF on writer close, and EPIPE/signal on write without readers.
//! Invariants: stable pipe identity independent of scheduler storage moves (§2.6); correct fd-table interaction across spawn/exec/dup/close.
//! Oracle (behavior to match): kernel/rust/src/ipc/pipe.rs.
//! Not here: fd tables (task.zig); block/wake scheduling decisions (scheduler.zig). This file owns the buffer + endpoints; the scheduler owns WHEN a blocked task wakes.
//!
//! Scaffold status: implemented (Phase 4). `write`/`read` are the raw ring-buffer
//! primitives (byte count only, mirroring the oracle's `RingBuffer`); `isReadClosed`/
//! `isWriteClosed`/`isEmpty`/`isFull` are the predicates a future syscall layer composes
//! into EPIPE/SIGPIPE-on-write and EOF-on-read semantics — this file furnishes the state,
//! the decision to raise an errno or a signal belongs to whoever holds the owning `Task`
//! (out of scope here; see task.zig/scheduler.zig). The oracle's `blocked_reader`/
//! `blocked_writer` single-task-slot fields are NOT ported: they are dead code there too
//! (grep confirms no caller outside pipe.rs itself) — the real block/wake mechanism is
//! `BlockReason` + the scheduler's `blocked` map (task.zig/scheduler.zig).

const std = @import("std");

/// 64 KiB ring buffer capacity (matches the Rust oracle's `PIPE_BUFFER_SIZE`).
pub const PIPE_BUFFER_SIZE: usize = 64 * 1024;

/// A pipe: one fixed-capacity ring buffer plus reference-counted reader/writer ends.
///
/// Reference counts (not booleans) because several fds may share one end — e.g. a
/// pipeline stage spawned with an inherited write end. The peer only observes EOF (on
/// read) or a broken pipe (on write) once the LAST holder of the other end releases it
/// (`closeRead`/`closeWrite`). A freshly created pipe starts with zero readers AND zero
/// writers — whoever hands out each `Fd.pipe_read` / `Fd.pipe_write` must call
/// `addReader`/`addWriter` to register that handle, mirroring the oracle's
/// `PipeSource::new`/`PipeSink::new`.
pub const Pipe = struct {
    data: [PIPE_BUFFER_SIZE]u8 = undefined,
    read_pos: usize = 0,
    write_pos: usize = 0,
    readers: usize = 0,
    writers: usize = 0,

    /// Heap-allocate a pipe with a stable address (§2.6) — `BlockReason` and `Fd` carry
    /// raw `*Pipe` pointers into it, so it must never move for its lifetime.
    pub fn create(gpa: std.mem.Allocator) *Pipe {
        const self = gpa.create(Pipe) catch @panic("OOM");
        self.* = .{};
        return self;
    }

    /// Write as many bytes of `buf` as fit before the ring catches up to `read_pos`.
    /// Returns the count actually written — 0 iff the buffer is already full. Does NOT
    /// consult `isReadClosed` (see header: that decision lives with the caller).
    pub fn write(self: *Pipe, buf: []const u8) usize {
        var written: usize = 0;
        for (buf) |byte| {
            const next_write = (self.write_pos + 1) % self.data.len;
            if (next_write == self.read_pos) break; // full
            self.data[self.write_pos] = byte;
            self.write_pos = next_write;
            written += 1;
        }
        return written;
    }

    /// Read up to `buf.len` bytes. Returns the count actually read — 0 iff the buffer is
    /// empty. Does NOT consult `isWriteClosed` (see header: EOF-vs-would-block is the
    /// caller's decision).
    pub fn read(self: *Pipe, buf: []u8) usize {
        var n: usize = 0;
        while (n < buf.len and self.read_pos != self.write_pos) {
            buf[n] = self.data[self.read_pos];
            self.read_pos = (self.read_pos + 1) % self.data.len;
            n += 1;
        }
        return n;
    }

    /// Check if buffer is empty.
    pub fn isEmpty(self: *const Pipe) bool {
        return self.read_pos == self.write_pos;
    }

    /// Check if buffer is full.
    pub fn isFull(self: *const Pipe) bool {
        return (self.write_pos + 1) % self.data.len == self.read_pos;
    }

    /// Register a new holder of the read / write end — a fresh `Fd.pipe_read`/
    /// `Fd.pipe_write` pointing here, including a `dup`'d or child-inherited copy.
    pub fn addReader(self: *Pipe) void {
        self.readers += 1;
    }
    pub fn addWriter(self: *Pipe) void {
        self.writers += 1;
    }

    /// Release one holder's claim on the read / write end. Idempotent (saturating) —
    /// safe even if called more times than `addReader`/`addWriter` ever were.
    pub fn closeRead(self: *Pipe) void {
        self.readers -|= 1;
    }
    pub fn closeWrite(self: *Pipe) void {
        self.writers -|= 1;
    }

    /// True once every holder of the read end has released it — a writer's cue to fail
    /// the write (EPIPE) / raise SIGPIPE instead of blocking forever.
    pub fn isReadClosed(self: *const Pipe) bool {
        return self.readers == 0;
    }

    /// True once every holder of the write end has released it — a reader's cue that an
    /// empty buffer now means EOF, not "block and retry".
    pub fn isWriteClosed(self: *const Pipe) bool {
        return self.writers == 0;
    }
};
