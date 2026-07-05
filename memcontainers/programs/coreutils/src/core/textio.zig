//! Port of the facade `textio.rs` (DESIGN.md §6): the CRLF-tolerant line model shared
//! by every line-oriented filter. `LineReader` splits on `\n` and strips one trailing
//! `\r`; the final unterminated line is still yielded. This is a spec, not an
//! accident -- keep it byte-exact (DESIGN.md §2, §6 table).

const std = @import("std");
const sys = @import("../sys/root.zig");
const Ctx = @import("../ctx.zig").Ctx;

/// 8 KiB fixed buffer, does not own `fd`. Lines longer than the buffer are split
/// across multiple `next()` calls (bounded-memory tradeoff, DESIGN.md §5.3).
pub const LineReader = struct {
    fd: sys.Fd,
    buf: [8192]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    eof: bool = false,

    pub fn init(fd: sys.Fd) LineReader {
        return .{ .fd = fd };
    }

    fn fill(self: *LineReader) sys.Error!void {
        if (self.start > 0) {
            const remaining = self.end - self.start;
            std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[self.start..self.end]);
            self.start = 0;
            self.end = remaining;
        }
        if (self.end == self.buf.len) return;
        const n = try sys.read(self.fd, self.buf[self.end..]);
        if (n == 0) {
            self.eof = true;
            return;
        }
        self.end += n;
    }

    fn stripCr(line: []const u8) []const u8 {
        if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
        return line;
    }

    /// Next line (trailing `\n` removed, one trailing `\r` stripped), or `null` at EOF.
    pub fn next(self: *LineReader) sys.Error!?[]const u8 {
        while (true) {
            if (self.start < self.end) {
                if (std.mem.indexOfScalar(u8, self.buf[self.start..self.end], '\n')) |rel| {
                    const line_end = self.start + rel;
                    const line = stripCr(self.buf[self.start..line_end]);
                    self.start = line_end + 1;
                    return line;
                }
                // Buffer full with no newline in sight: yield the bounded chunk as-is
                // (pathologically long line -- see struct doc).
                if (self.end - self.start == self.buf.len) {
                    const line = self.buf[self.start..self.end];
                    self.start = self.end;
                    return line;
                }
            }
            if (self.eof) {
                if (self.start < self.end) {
                    const line = stripCr(self.buf[self.start..self.end]);
                    self.start = self.end;
                    return line;
                }
                return null;
            }
            try self.fill();
        }
    }
};

/// 16 KiB chunked stdout sink. A write error means the downstream reader closed the
/// pipe; propagated so streaming callers (cat, yes) can stop quietly.
pub const BufOut = struct {
    fd: sys.Fd,
    buf: [16384]u8 = undefined,
    len: usize = 0,

    pub fn init(fd: sys.Fd) BufOut {
        return .{ .fd = fd };
    }

    fn flush(self: *BufOut) sys.Error!void {
        if (self.len == 0) return;
        try sys.writeAll(self.fd, self.buf[0..self.len]);
        self.len = 0;
    }

    /// Appends bytes, flushing at the chunk threshold; bytes at least as large as the
    /// buffer bypass it and go straight to a single `writeAll`.
    pub fn extend(self: *BufOut, bytes: []const u8) sys.Error!void {
        if (bytes.len >= self.buf.len) {
            try self.flush();
            try sys.writeAll(self.fd, bytes);
            return;
        }
        if (self.len + bytes.len > self.buf.len) try self.flush();
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn push(self: *BufOut, b: u8) sys.Error!void {
        if (self.len == self.buf.len) try self.flush();
        self.buf[self.len] = b;
        self.len += 1;
    }

    pub fn endLine(self: *BufOut) sys.Error!void {
        try self.push('\n');
    }

    pub fn line(self: *BufOut, bytes: []const u8) sys.Error!void {
        try self.extend(bytes);
        try self.endLine();
    }

    pub fn finish(self: *BufOut) sys.Error!void {
        try self.flush();
    }
};

fn streamOne(fd: sys.Fd, context: anytype, comptime callback: fn (@TypeOf(context), []const u8) anyerror!void) bool {
    var lr = LineReader.init(fd);
    while (true) {
        const maybe_line = lr.next() catch return true;
        const l = maybe_line orelse return false;
        callback(context, l) catch return true;
    }
}

/// Operand loop shared by every line filter (DESIGN.md §6 table): empty `ops` or a
/// lone `-` means stdin; an open failure prints `prog: name: strerror` to stderr, sets
/// rc=1, and continues to the next operand; a callback error stops everything (used
/// for "downstream closed").
pub fn streamLines(
    ctx: *Ctx,
    prog: []const u8,
    ops: []const []const u8,
    context: anytype,
    comptime callback: fn (@TypeOf(context), []const u8) anyerror!void,
) u8 {
    var rc: u8 = 0;
    if (ops.len == 0) {
        _ = streamOne(ctx.stdin, context, callback);
        return rc;
    }
    for (ops) |name| {
        const is_stdin = std.mem.eql(u8, name, "-");
        const fd = if (is_stdin) ctx.stdin else sys.open(name, .{ .read = true }) catch |e| {
            ctx.errPrint("{s}: {s}: {s}\n", .{ prog, name, sys.strerror(sys.toErrno(e)) });
            rc = 1;
            continue;
        };
        defer if (!is_stdin) sys.close(fd);
        const stop = streamOne(fd, context, callback);
        if (stop) return rc;
    }
    return rc;
}

/// A read operand resolved by `openOperand`: either a real file (owns `fd`) or stdin.
pub const Operand = struct {
    fd: sys.Fd,
    is_stdin: bool,
    /// Closes the fd unless it is stdin. `defer op.deinit()`.
    pub fn deinit(self: Operand) void {
        if (!self.is_stdin) sys.close(self.fd);
    }
};

/// Resolves a file operand for reading: `-` (or the caller passing `"-"`) means stdin,
/// otherwise `sys.open(name, read)`. On open failure prints `prog: name: strerror` to
/// stderr and returns `null` -- the caller's convention is `orelse { rc = 1; continue; }`.
/// Replaces the ~30 hand-rolled `is_stdin = eql("-")` open loops across the applets.
pub fn openOperand(ctx: *Ctx, prog: []const u8, name: []const u8) ?Operand {
    if (std.mem.eql(u8, name, "-")) return .{ .fd = ctx.stdin, .is_stdin = true };
    const fd = sys.open(name, .{ .read = true }) catch |e| {
        ctx.errPrint("{s}: {s}: {s}\n", .{ prog, name, sys.strerror(sys.toErrno(e)) });
        return null;
    };
    return .{ .fd = fd, .is_stdin = false };
}

/// Opens `path`, reads it fully into `gpa`-owned memory, and closes it. Replaces the
/// ~16 identical local `readAllOut`/`readWholeFile`/`readAllPath` helpers.
pub fn readFileByPath(gpa: std.mem.Allocator, path: []const u8) sys.Error![]u8 {
    const fd = try sys.open(path, .{ .read = true });
    defer sys.close(fd);
    return readAll(gpa, fd);
}

/// Reads `fd` to EOF into `gpa`-owned memory.
pub fn readAll(gpa: std.mem.Allocator, fd: sys.Fd) sys.Error![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try sys.read(fd, &chunk);
        if (n == 0) break;
        list.appendSlice(gpa, chunk[0..n]) catch return error.ENOMEM;
    }
    return list.toOwnedSlice(gpa) catch return error.ENOMEM;
}

/// Reads `fd` to EOF, collecting each `LineReader` line into `gpa`-owned memory.
pub fn collectLines(gpa: std.mem.Allocator, fd: sys.Fd) sys.Error![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var lr = LineReader.init(fd);
    while (try lr.next()) |l| {
        const dup = gpa.dupe(u8, l) catch return error.ENOMEM;
        list.append(gpa, dup) catch return error.ENOMEM;
    }
    return list.toOwnedSlice(gpa) catch return error.ENOMEM;
}

/// Strips one trailing `\n` then one trailing `\r`, matching `LineReader`'s per-line
/// stripping for buffers obtained some other way (e.g. a whole-file `readAll`).
pub fn chomp(s: []const u8) []const u8 {
    var out = s;
    if (out.len > 0 and out[out.len - 1] == '\n') out = out[0 .. out.len - 1];
    if (out.len > 0 and out[out.len - 1] == '\r') out = out[0 .. out.len - 1];
    return out;
}
