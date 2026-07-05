//! `/scratch` spill (DESIGN.md §6, facade `spool.rs`, 112 LOC): bounded-memory spill
//! to a per-task private tmpfs. `SpoolFile.create()` failing means "no scratch
//! capability" -- callers (sort, tac, uniq; not yet ported in M1a) fall back to an
//! in-memory strategy instead of treating it as fatal.

const std = @import("std");
const sys = @import("../sys/root.zig");
const textio = @import("textio.zig");
const fmt_min = @import("fmt_min.zig");

var seq_counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// A self-unlinking spill file at `/scratch/sp.<pid>.<seq>`.
pub const SpoolFile = struct {
    handle: sys.Fd,
    path_buf: [64]u8 = undefined,
    path_len: usize = 0,

    /// `null` means no scratch capability (creation failed) -- callers must fall back.
    pub fn create() ?SpoolFile {
        const pid = sys.getpid();
        const seq = seq_counter.fetchAdd(1, .monotonic);
        var buf: [64]u8 = undefined;
        const path = fmt_min.formatBuf(&buf, "/scratch/sp.{d}.{d}", .{ pid, seq });
        const opened = sys.open(path, .{ .read = true, .write = true, .create = true, .trunc = true }) catch return null;
        var sf = SpoolFile{ .handle = opened };
        @memcpy(sf.path_buf[0..path.len], path);
        sf.path_len = path.len;
        return sf;
    }

    pub fn pathSlice(self: *const SpoolFile) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn fd(self: *const SpoolFile) sys.Fd {
        return self.handle;
    }

    pub fn writeAll(self: *SpoolFile, bytes: []const u8) sys.Error!void {
        return sys.writeAll(self.handle, bytes);
    }

    /// Seeks back to the start (arms the file for reading after a fill phase).
    pub fn rewind(self: *SpoolFile) sys.Error!void {
        _ = try sys.lseek(self.handle, 0, .set);
    }

    /// Seeks to the end and returns the resulting offset (the file's current length).
    /// Side effect: moves the file position to the end, same as the Rust original.
    pub fn len(self: *SpoolFile) sys.Error!u64 {
        return sys.lseek(self.handle, 0, .end);
    }

    /// Closes the fd and unlinks the spill file (best-effort).
    pub fn deinit(self: *SpoolFile) void {
        sys.close(self.handle);
        sys.unlink(self.pathSlice()) catch {};
    }
};

/// Write-once-then-stream: fill via `writeAll`, `rewindForRead` arms a `LineReader`
/// over the same fd, then `nextLine` streams lines back out.
pub const Run = struct {
    spool: SpoolFile,
    reader: ?textio.LineReader = null,

    pub fn init(spool: SpoolFile) Run {
        return .{ .spool = spool };
    }

    pub fn writeAll(self: *Run, bytes: []const u8) sys.Error!void {
        return self.spool.writeAll(bytes);
    }

    pub fn rewindForRead(self: *Run) sys.Error!void {
        try self.spool.rewind();
        self.reader = textio.LineReader.init(self.spool.fd());
    }

    pub fn nextLine(self: *Run) sys.Error!?[]const u8 {
        if (self.reader == null) return error.EINVAL;
        return self.reader.?.next();
    }

    pub fn deinit(self: *Run) void {
        self.spool.deinit();
    }
};
