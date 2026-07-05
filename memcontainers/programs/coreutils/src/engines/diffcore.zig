//! Line-diff engine for the `diff` applet (DESIGN.md §7.6): Myers O(ND)
//! divide-and-conquer over line slices, yielding a flat list of equal/delete/insert
//! ops, plus the `similar` crate's hunk grouping (`group_diff_ops`) semantics.
//!
//! Normative reference: `reference/crates/similar-2.7.0/src/algorithms/myers.rs`
//! (the divide-and-conquer middle-snake search is a direct port) and
//! `reference/crates/similar-2.7.0/src/common.rs` `group_diff_ops` (verified rule:
//! an interior equal run SPLITS two groups only when its length is `> 2*n`; a run of
//! exactly `2*n` shared context merges the adjacent change clusters into one group;
//! the leading equal run is trimmed to its trailing `n` lines and the trailing equal
//! run to its leading `n` lines).
//!
//! Equality between lines is plain byte equality (`std.mem.eql`); the applet handles
//! `-i`/`-w`/`-B` by diffing preprocessed line arrays. The three output formats
//! (unified/context/normal) live in the applet; this engine only yields ops.
//!
//! Fidelity note: `similar`'s capture pipeline also runs a `Compact` "slider" pass
//! (diffy-style shifting of change clusters through equal runs). We do not port it;
//! instead `normalize` canonicalizes raw Myers output into maximal clusters (adjacent
//! equal runs merged; each maximal non-equal run collapsed to one delete followed by
//! one insert). This only affects the placement of ambiguous equal-cost diffs; the
//! parity goldens are authored from this implementation (source: spec).

const std = @import("std");

pub const Tag = enum { equal, delete, insert };

/// One diff op. `a`/`b` are 0-based start indices into the old/new line arrays.
/// - `.equal`:  `len` lines match starting at `a` in old and `b` in new.
/// - `.delete`: `len` lines of old starting at `a` are removed; `b` is the position
///   in new where the removal happens (nothing consumed on the b side).
/// - `.insert`: `len` lines of new starting at `b` are added; `a` is the position in
///   old where the insertion happens (nothing consumed on the a side).
pub const Op = struct {
    tag: Tag,
    a: usize,
    b: usize,
    len: usize,
};

pub const Error = error{OutOfMemory};

// --------------------------------------------------------------------- Myers core

fn linesEql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn commonPrefixLen(a: []const []const u8, alo: usize, ahi: usize, b: []const []const u8, blo: usize, bhi: usize) usize {
    var i: usize = 0;
    while (alo + i < ahi and blo + i < bhi and linesEql(a[alo + i], b[blo + i])) i += 1;
    return i;
}

fn commonSuffixLen(a: []const []const u8, alo: usize, ahi: usize, b: []const []const u8, blo: usize, bhi: usize) usize {
    var i: usize = 0;
    while (i < ahi - alo and i < bhi - blo and linesEql(a[ahi - 1 - i], b[bhi - 1 - i])) i += 1;
    return i;
}

fn maxD(len1: usize, len2: usize) usize {
    return (len1 + len2 + 1) / 2 + 1;
}

/// `V` from the reference: furthest-reaching x per diagonal k, with an offset so
/// negative k indexes work.
const V = struct {
    v: []usize,
    offset: isize,

    fn get(self: *const V, k: isize) usize {
        return self.v[@intCast(k + self.offset)];
    }
    fn set(self: *V, k: isize, x: usize) void {
        self.v[@intCast(k + self.offset)] = x;
    }
};

const Snake = struct { x: usize, y: usize };

/// Direct port of `find_middle_snake` (myers.rs) without the deadline machinery;
/// with no deadline the search always terminates with a snake.
fn findMiddleSnake(
    a: []const []const u8,
    alo: usize,
    ahi: usize,
    b: []const []const u8,
    blo: usize,
    bhi: usize,
    vf: *V,
    vb: *V,
) Snake {
    const n = ahi - alo;
    const m = bhi - blo;
    const delta = @as(isize, @intCast(n)) - @as(isize, @intCast(m));
    const odd = (delta & 1) == 1;

    vf.set(1, 0);
    vb.set(1, 0);

    const d_max: isize = @intCast(maxD(n, m));
    var d: isize = 0;
    while (d < d_max) : (d += 1) {
        // Forward path
        {
            var k: isize = d;
            while (k >= -d) : (k -= 2) {
                var x = if (k == -d or (k != d and vf.get(k - 1) < vf.get(k + 1)))
                    vf.get(k + 1)
                else
                    vf.get(k - 1) + 1;
                const y: usize = @intCast(@as(isize, @intCast(x)) - k);
                const x0 = x;
                const y0 = y;
                if (x < n and y < m) {
                    x += commonPrefixLen(a, alo + x, ahi, b, blo + y, bhi);
                }
                vf.set(k, x);
                if (odd and @abs(k - delta) <= d - 1) {
                    if (vf.get(k) + vb.get(-(k - delta)) >= n) {
                        return .{ .x = x0 + alo, .y = y0 + blo };
                    }
                }
            }
        }
        // Backward path
        {
            var k: isize = d;
            while (k >= -d) : (k -= 2) {
                var x = if (k == -d or (k != d and vb.get(k - 1) < vb.get(k + 1)))
                    vb.get(k + 1)
                else
                    vb.get(k - 1) + 1;
                var y: usize = @intCast(@as(isize, @intCast(x)) - k);
                if (x < n and y < m) {
                    const advance = commonSuffixLen(a, alo, alo + n - x, b, blo, blo + m - y);
                    x += advance;
                    y += advance;
                }
                vb.set(k, x);
                if (!odd and @abs(k - delta) <= d) {
                    if (vb.get(k) + vf.get(-(k - delta)) >= n) {
                        return .{ .x = alo + n - x, .y = blo + m - y };
                    }
                }
            }
        }
    }
    unreachable; // without a deadline the middle snake is always found
}

fn conquer(
    ops: *std.ArrayListUnmanaged(Op),
    gpa: std.mem.Allocator,
    a: []const []const u8,
    alo_in: usize,
    ahi_in: usize,
    b: []const []const u8,
    blo_in: usize,
    bhi_in: usize,
    vf: *V,
    vb: *V,
) Error!void {
    var alo = alo_in;
    var ahi = ahi_in;
    var blo = blo_in;
    var bhi = bhi_in;

    const prefix = commonPrefixLen(a, alo, ahi, b, blo, bhi);
    if (prefix > 0) {
        try ops.append(gpa, .{ .tag = .equal, .a = alo, .b = blo, .len = prefix });
    }
    alo += prefix;
    blo += prefix;

    const suffix = commonSuffixLen(a, alo, ahi, b, blo, bhi);
    const suffix_a = ahi - suffix;
    const suffix_b = bhi - suffix;
    ahi -= suffix;
    bhi -= suffix;

    if (alo == ahi and blo == bhi) {
        // nothing
    } else if (blo == bhi) {
        try ops.append(gpa, .{ .tag = .delete, .a = alo, .b = blo, .len = ahi - alo });
    } else if (alo == ahi) {
        try ops.append(gpa, .{ .tag = .insert, .a = alo, .b = blo, .len = bhi - blo });
    } else {
        const s = findMiddleSnake(a, alo, ahi, b, blo, bhi, vf, vb);
        try conquer(ops, gpa, a, alo, s.x, b, blo, s.y, vf, vb);
        try conquer(ops, gpa, a, s.x, ahi, b, s.y, bhi, vf, vb);
    }

    if (suffix > 0) {
        try ops.append(gpa, .{ .tag = .equal, .a = suffix_a, .b = suffix_b, .len = suffix });
    }
}

/// Canonicalize raw conquer output: merge adjacent equal runs; collapse each maximal
/// run of non-equal ops into (at most) one delete followed by one insert. After this
/// pass, change clusters are always `delete? insert?` between equal runs, which the
/// normal-format emitter walks directly.
fn normalize(gpa: std.mem.Allocator, raw: []const Op) Error![]Op {
    var out: std.ArrayListUnmanaged(Op) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i].tag == .equal) {
            var op = raw[i];
            i += 1;
            while (i < raw.len and raw[i].tag == .equal) : (i += 1) {
                op.len += raw[i].len;
            }
            if (op.len > 0) try out.append(gpa, op);
        } else {
            const a_start = raw[i].a;
            const b_start = raw[i].b;
            var del_len: usize = 0;
            var ins_len: usize = 0;
            while (i < raw.len and raw[i].tag != .equal) : (i += 1) {
                switch (raw[i].tag) {
                    .delete => del_len += raw[i].len,
                    .insert => ins_len += raw[i].len,
                    .equal => unreachable,
                }
            }
            if (del_len > 0) {
                try out.append(gpa, .{ .tag = .delete, .a = a_start, .b = b_start, .len = del_len });
            }
            if (ins_len > 0) {
                try out.append(gpa, .{ .tag = .insert, .a = a_start + del_len, .b = b_start, .len = ins_len });
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Diff two line arrays; returns normalized ops in order. Identical inputs yield a
/// single `.equal` op (or an empty slice when both inputs are empty).
pub fn diffLines(gpa: std.mem.Allocator, a: []const []const u8, b: []const []const u8) Error![]Op {
    const md = maxD(a.len, b.len);
    const vf_buf = try gpa.alloc(usize, 2 * md);
    defer gpa.free(vf_buf);
    const vb_buf = try gpa.alloc(usize, 2 * md);
    defer gpa.free(vb_buf);
    @memset(vf_buf, 0);
    @memset(vb_buf, 0);
    var vf = V{ .v = vf_buf, .offset = @intCast(md) };
    var vb = V{ .v = vb_buf, .offset = @intCast(md) };

    var raw: std.ArrayListUnmanaged(Op) = .empty;
    defer raw.deinit(gpa);
    try conquer(&raw, gpa, a, 0, a.len, b, 0, b.len, &vf, &vb);
    return normalize(gpa, raw.items);
}

/// True if `ops` contains any change (delete/insert).
pub fn hasChanges(ops: []const Op) bool {
    for (ops) |op| if (op.tag != .equal) return true;
    return false;
}

// -------------------------------------------------------------------- hunk grouping

/// Port of `similar`'s `group_diff_ops` (common.rs): given ops and a context radius
/// `n`, produce groups (hunks) each carrying up to `n` context lines on either side.
/// Adjacent change clusters share one group when the equal run between them is
/// `<= 2*n`; a strictly larger run splits (keeping `n` trailing context in the first
/// group and `n` leading context in the next). Identical inputs produce zero groups.
pub fn groupOps(gpa: std.mem.Allocator, ops_in: []const Op, n: usize) Error![][]Op {
    var rv: std.ArrayListUnmanaged([]Op) = .empty;
    if (ops_in.len == 0) return rv.toOwnedSlice(gpa);

    const ops = try gpa.dupe(Op, ops_in);
    defer gpa.free(ops);

    // Trim the leading equal run to its trailing n lines.
    if (ops[0].tag == .equal) {
        const offset = ops[0].len -| n;
        ops[0].a += offset;
        ops[0].b += offset;
        ops[0].len -= offset;
    }
    // Trim the trailing equal run to its leading n lines.
    if (ops[ops.len - 1].tag == .equal) {
        const last = &ops[ops.len - 1];
        last.len -= last.len -| n;
    }

    var pending: std.ArrayListUnmanaged(Op) = .empty;
    for (ops) |op| {
        if (op.tag == .equal and op.len > n * 2) {
            try pending.append(gpa, .{ .tag = .equal, .a = op.a, .b = op.b, .len = n });
            try rv.append(gpa, try pending.toOwnedSlice(gpa));
            pending = .empty;
            const offset = op.len -| n;
            try pending.append(gpa, .{
                .tag = .equal,
                .a = op.a + offset,
                .b = op.b + offset,
                .len = op.len - offset,
            });
            continue;
        }
        try pending.append(gpa, op);
    }

    const keep = switch (pending.items.len) {
        0 => false,
        1 => pending.items[0].tag != .equal,
        else => true,
    };
    if (keep) {
        try rv.append(gpa, try pending.toOwnedSlice(gpa));
    } else {
        pending.deinit(gpa);
    }
    return rv.toOwnedSlice(gpa);
}

pub const Range = struct { start: usize, count: usize };
pub const HunkRanges = struct { a: Range, b: Range };

/// 0-based start + line count covered by a group on each side.
pub fn hunkRanges(group: []const Op) HunkRanges {
    var a_count: usize = 0;
    var b_count: usize = 0;
    for (group) |op| {
        switch (op.tag) {
            .equal => {
                a_count += op.len;
                b_count += op.len;
            },
            .delete => a_count += op.len,
            .insert => b_count += op.len,
        }
    }
    const a_start = if (group.len > 0) group[0].a else 0;
    const b_start = if (group.len > 0) group[0].b else 0;
    return .{
        .a = .{ .start = a_start, .count = a_count },
        .b = .{ .start = b_start, .count = b_count },
    };
}
