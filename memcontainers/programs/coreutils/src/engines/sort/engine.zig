//! External merge-sort machinery for `sort` (docs/analysis/applets-s-z.md): `Batch`
//! (offset/len line index over one data buffer), spill to `spool.Run`, FANIN=16
//! multi-pass reduction, and the final K-way streaming merge. Applet-private.

const std = @import("std");
const sys = @import("../../sys/root.zig");
const spool = @import("../../core/spool.zig");
const textio = @import("../../core/textio.zig");
const cmp = @import("cmp.zig");
const key_mod = @import("key.zig");
const Key = key_mod.Key;

pub const FANIN: usize = 16;

pub const Line = struct { off: usize, len: usize };

/// One data buffer + line offset/len index (DESIGN.md sort matrix). `std.sort.block`
/// (WikiSort-derived, STABLE) is used so ties preserve input order -- required both
/// for `-s` and for GNU's documented "keys then whole-line last-resort" tie order.
pub const Batch = struct {
    data: std.ArrayListUnmanaged(u8) = .empty,
    lines: std.ArrayListUnmanaged(Line) = .empty,

    pub fn lineBytes(self: *const Batch, l: Line) []const u8 {
        return self.data.items[l.off .. l.off + l.len];
    }

    pub fn addLine(self: *Batch, gpa: std.mem.Allocator, bytes: []const u8) !void {
        const off = self.data.items.len;
        try self.data.appendSlice(gpa, bytes);
        try self.lines.append(gpa, .{ .off = off, .len = bytes.len });
    }

    pub fn approxBytes(self: *const Batch) usize {
        return self.data.items.len;
    }

    pub fn isEmpty(self: *const Batch) bool {
        return self.lines.items.len == 0;
    }

    const SortCtx = struct {
        batch: *const Batch,
        keys: []const Key,
        sep: ?u8,
        stable: bool,
        global_reverse: bool,
    };

    fn lessThan(ctx: SortCtx, a: Line, b: Line) bool {
        return cmp.totalCmp(ctx.batch.lineBytes(a), ctx.batch.lineBytes(b), ctx.keys, ctx.sep, ctx.stable, ctx.global_reverse) == .lt;
    }

    pub fn sort(self: *Batch, keys: []const Key, sep: ?u8, stable: bool, global_reverse: bool) void {
        const ctx = SortCtx{ .batch = self, .keys = keys, .sep = sep, .stable = stable, .global_reverse = global_reverse };
        std.sort.block(Line, self.lines.items, ctx, lessThan);
    }
};

/// Splits `buf` the same way `textio.LineReader` would (trailing `\n` removed, one
/// trailing `\r` stripped, final unterminated chunk still yielded), appending each
/// line into `batch` UNSORTED (used for merge-mode's in-memory spool fallback, where
/// input is already sorted and must not be reordered).
pub fn fillBatchFromBytes(gpa: std.mem.Allocator, batch: *Batch, buf: []const u8) !void {
    var start: usize = 0;
    while (start < buf.len) {
        const rel = std.mem.indexOfScalar(u8, buf[start..], '\n');
        var line_end: usize = undefined;
        var next_start: usize = undefined;
        if (rel) |r| {
            line_end = start + r;
            next_start = line_end + 1;
        } else {
            line_end = buf.len;
            next_start = buf.len;
        }
        var line = buf[start..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        try batch.addLine(gpa, line);
        start = next_start;
    }
}

/// A single sorted-run source, either an on-disk spool run, an in-memory batch
/// (already sorted), or a plain streaming reader over a pre-sorted file (merge mode).
pub const MemCursor = struct {
    batch: *const Batch,
    idx: usize = 0,

    fn next(self: *MemCursor) ?[]const u8 {
        if (self.idx >= self.batch.lines.items.len) return null;
        const l = self.batch.lines.items[self.idx];
        self.idx += 1;
        return self.batch.lineBytes(l);
    }
};

pub const Source = union(enum) {
    run: *spool.Run,
    mem: *MemCursor,
    reader: *textio.LineReader,

    pub fn next(self: Source) sys.Error!?[]const u8 {
        return switch (self) {
            .run => |r| r.nextLine(),
            .mem => |m| m.next(),
            .reader => |r| r.next(),
        };
    }
};

/// Sorts `batch` in place and spills it to a fresh `/scratch` run. Returns `null` if
/// `/scratch` is unavailable (caller falls back to keeping data in memory) OR a
/// write failure occurs mid-spill (the partially-written spool file is cleaned up).
pub fn spillBatch(batch: *Batch, keys: []const Key, sep: ?u8, stable: bool, global_reverse: bool) ?spool.Run {
    const sf = spool.SpoolFile.create() orelse return null;
    batch.sort(keys, sep, stable, global_reverse);
    var run = spool.Run.init(sf);
    for (batch.lines.items) |l| {
        const bytes = batch.lineBytes(l);
        run.writeAll(bytes) catch {
            run.deinit();
            return null;
        };
        run.writeAll("\n") catch {
            run.deinit();
            return null;
        };
    }
    return run;
}

fn pickMin(current: []const ?[]const u8, keys: []const Key, sep: ?u8, stable: bool, global_reverse: bool) ?usize {
    var best: ?usize = null;
    for (current, 0..) |c, i| {
        if (c == null) continue;
        if (best == null) {
            best = i;
            continue;
        }
        if (cmp.totalCmp(current[best.?].?, c.?, keys, sep, stable, global_reverse) == .gt) best = i;
    }
    return best;
}

/// Errors reduceRuns can surface: allocation, or a scratch read/write failure that would
/// otherwise silently corrupt (truncate) the merge.
pub const ReduceError = std.mem.Allocator.Error || sys.Error;

/// Multi-pass FANIN=16 reduction of on-disk runs down to <= FANIN runs, ready for a
/// single final K-way merge. No dedup here -- `-u` only applies at the true final
/// merge, which sees the fully-ordered stream exactly once. A scratch read/write failure
/// aborts with an error rather than emitting a partially-merged run (a read error is NOT
/// treated as EOF, which would drop the tail of a run).
pub fn reduceRuns(gpa: std.mem.Allocator, runs_in: []spool.Run, keys: []const Key, sep: ?u8, stable: bool, global_reverse: bool) ReduceError![]spool.Run {
    var runs: std.ArrayListUnmanaged(spool.Run) = .empty;
    try runs.appendSlice(gpa, runs_in);

    while (runs.items.len > FANIN) {
        var next_runs: std.ArrayListUnmanaged(spool.Run) = .empty;
        var i: usize = 0;
        while (i < runs.items.len) {
            const end = @min(i + FANIN, runs.items.len);
            const group = runs.items[i..end];
            for (group) |*r| try r.rewindForRead();
            const current = try gpa.alloc(?[]const u8, group.len);
            for (group, 0..) |*r, gi| current[gi] = try r.nextLine();

            const sf = spool.SpoolFile.create();
            if (sf == null) {
                // Scratch exhausted mid-reduction: give up further reduction for this
                // group (rare; final merge just gets a wider fan-in than FANIN).
                try next_runs.appendSlice(gpa, group);
                i = end;
                continue;
            }
            var merged = spool.Run.init(sf.?);
            while (true) {
                const bi = pickMin(current, keys, sep, stable, global_reverse) orelse break;
                try merged.writeAll(current[bi].?);
                try merged.writeAll("\n");
                current[bi] = try group[bi].nextLine();
            }
            for (group) |*r| r.deinit();
            try next_runs.append(gpa, merged);
            i = end;
        }
        runs = next_runs;
    }
    return runs.items;
}

pub const OutSink = struct {
    out: textio.BufOut,

    pub fn init(fd: sys.Fd) OutSink {
        return .{ .out = textio.BufOut.init(fd) };
    }

    pub fn line(self: *OutSink, bytes: []const u8) sys.Error!void {
        try self.out.extend(bytes);
        try self.out.push('\n');
    }

    pub fn finish(self: *OutSink) sys.Error!void {
        try self.out.finish();
    }
};

/// The final K-way streaming merge (16 KiB chunked `OutSink`, per-source rewound and
/// ready to read): repeatedly picks the minimum among the sources' current lines
/// (ties -> lowest source index, giving cross-run stability), optionally dedups by
/// KEY equality (`-u`) against the last EMITTED line.
pub fn mergeToSink(gpa: std.mem.Allocator, sink: *OutSink, sources: []const Source, keys: []const Key, sep: ?u8, stable: bool, global_reverse: bool, unique: bool) !void {
    const current = try gpa.alloc(?[]const u8, sources.len);
    for (sources, 0..) |s, i| current[i] = try s.next();
    var last: ?[]u8 = null;
    while (true) {
        const bi = pickMin(current, keys, sep, stable, global_reverse) orelse break;
        const line_bytes = current[bi].?;
        var emit = true;
        if (unique) {
            if (last) |lp| {
                if (cmp.keysEqual(lp, line_bytes, keys, sep)) emit = false;
            }
        }
        if (emit) {
            try sink.line(line_bytes);
            if (unique) last = try gpa.dupe(u8, line_bytes);
        }
        current[bi] = try sources[bi].next();
    }
}
