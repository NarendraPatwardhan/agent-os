//! Pathname expansion and glob matching.

const std = @import("std");

pub const ListFn = *const fn (*anyopaque, std.mem.Allocator, []const u8) ?[]const []const u8;

pub fn globFull(pattern: []const u8, value: []const u8) bool {
    return globMasked(pattern, allActive, value, &.{});
}

fn allActive(_: usize, _: []const bool) bool {
    return true;
}

pub fn globFullMasked(pattern: []const u8, active: []const bool, value: []const u8) bool {
    return globMasked(pattern, activeAt, value, active);
}

fn globMasked(pattern: []const u8, comptime is_active: fn (usize, []const bool) bool, value: []const u8, active: []const bool) bool {
    var star: ?struct { pi: usize, si: usize } = null;
    var pi: usize = 0;
    var si: usize = 0;

    while (si < value.len) {
        if (pi < pattern.len and is_active(pi, active) and pattern[pi] == '*') {
            pi += 1;
            star = .{ .pi = pi, .si = si };
            continue;
        }
        if (pi < pattern.len and matchesOne(pattern, active, pi, value[si], is_active)) {
            pi += classLen(pattern, active, pi, is_active);
            si += 1;
            continue;
        }
        if (star) |s| {
            pi = s.pi;
            si = s.si + 1;
            star = .{ .pi = s.pi, .si = s.si + 1 };
            continue;
        }
        return false;
    }

    while (pi < pattern.len and is_active(pi, active) and pattern[pi] == '*') {
        pi += 1;
    }
    return pi == pattern.len;
}

fn activeAt(i: usize, active: []const bool) bool {
    return i < active.len and active[i];
}

fn matchesOne(pattern: []const u8, active: []const bool, pi: usize, ch: u8, comptime is_active: fn (usize, []const bool) bool) bool {
    if (!is_active(pi, active)) return pattern[pi] == ch;
    return switch (pattern[pi]) {
        '?' => true,
        '[' => if (parseClass(pattern, pi, ch)) |class| class.matches else ch == '[',
        else => |literal| literal == ch,
    };
}

fn classLen(pattern: []const u8, active: []const bool, pi: usize, comptime is_active: fn (usize, []const bool) bool) usize {
    if (is_active(pi, active) and pattern[pi] == '[') {
        if (parseClass(pattern, pi, 0)) |class| return class.len;
    }
    return 1;
}

const ClassResult = struct {
    matches: bool,
    len: usize,
};

fn parseClass(pattern: []const u8, pi: usize, ch: u8) ?ClassResult {
    std.debug.assert(pattern[pi] == '[');
    var i = pi + 1;
    const negate = i < pattern.len and (pattern[i] == '!' or pattern[i] == '^');
    if (negate) i += 1;

    var matched = false;
    var first = true;
    while (i < pattern.len) {
        if (pattern[i] == ']' and !first) {
            return .{ .matches = matched != negate, .len = i + 1 - pi };
        }
        first = false;
        if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
            if (ch >= pattern[i] and ch <= pattern[i + 2]) matched = true;
            i += 3;
            continue;
        }
        if (pattern[i] == ch) matched = true;
        i += 1;
    }
    return null;
}

pub fn hasMeta(field: []const u8) bool {
    for (field) |ch| {
        if (ch == '*' or ch == '?' or ch == '[') return true;
    }
    return false;
}

fn hasActiveMeta(pattern: []const u8, active: []const bool) bool {
    for (pattern, 0..) |ch, i| {
        if (activeAt(i, active) and (ch == '*' or ch == '?' or ch == '[')) return true;
    }
    return false;
}

const Segment = struct {
    chars: []const u8,
    active: []const bool,
};

const Candidate = struct {
    display: []const u8,
    fs: []const u8,
};

/// Masked pathname expansion. Only bytes with active[i] set are glob
/// metacharacters. If nothing matches, returns the literal field.
pub fn expandGlobMasked(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    active: []const bool,
    cwd: []const u8,
    list_ptr: *anyopaque,
    list_fn: ListFn,
) ![]const []const u8 {
    std.debug.assert(pattern.len == active.len);
    if (!hasActiveMeta(pattern, active)) {
        const out = try allocator.alloc([]const u8, 1);
        out[0] = try allocator.dupe(u8, pattern);
        return out;
    }

    var segments = std.ArrayList(Segment).empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '/') {
            if (i > start) try segments.append(allocator, .{ .chars = pattern[start..i], .active = active[start..i] });
            start = i + 1;
        }
    }
    if (pattern.len > start) try segments.append(allocator, .{ .chars = pattern[start..], .active = active[start..] });

    const absolute = pattern.len > 0 and pattern[0] == '/';
    var bases = std.ArrayList(Candidate).empty;
    try bases.append(allocator, .{
        .display = if (absolute) "/" else "",
        .fs = if (absolute) "/" else cwd,
    });

    for (segments.items) |seg| {
        var next = std.ArrayList(Candidate).empty;
        if (hasActiveMeta(seg.chars, seg.active)) {
            for (bases.items) |base| {
                const entries = list_fn(list_ptr, allocator, base.fs) orelse continue;
                for (entries) |entry| {
                    const pat_dot = seg.chars.len > 0 and seg.chars[0] == '.';
                    if (entry.len > 0 and entry[0] == '.' and !pat_dot) continue;
                    if (globFullMasked(seg.chars, seg.active, entry)) {
                        try next.append(allocator, .{
                            .display = try joinDisplay(allocator, base.display, entry),
                            .fs = try joinSegment(allocator, base.fs, entry),
                        });
                    }
                }
            }
        } else {
            for (bases.items) |base| {
                try next.append(allocator, .{
                    .display = try joinDisplay(allocator, base.display, seg.chars),
                    .fs = try joinSegment(allocator, base.fs, seg.chars),
                });
            }
        }
        bases = next;
    }

    if (bases.items.len == 0) {
        const out = try allocator.alloc([]const u8, 1);
        out[0] = try allocator.dupe(u8, pattern);
        return out;
    }

    var out = std.ArrayList([]const u8).empty;
    for (bases.items) |base| try out.append(allocator, base.display);
    std.mem.sort([]const u8, out.items, {}, stringLess);
    return out.toOwnedSlice(allocator);
}

pub fn expandGlob(
    allocator: std.mem.Allocator,
    field: []const u8,
    cwd: []const u8,
    list_ptr: *anyopaque,
    list_fn: ListFn,
) ![]const []const u8 {
    const active = try allocator.alloc(bool, field.len);
    @memset(active, true);
    return expandGlobMasked(allocator, field, active, cwd, list_ptr, list_fn);
}

fn joinDisplay(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    if (base.len == 0) return allocator.dupe(u8, name);
    if (std.mem.eql(u8, base, "/")) return std.fmt.allocPrint(allocator, "/{s}", .{name});
    if (base[base.len - 1] == '/') return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, name });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name });
}

fn joinSegment(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, base, "/")) return std.fmt.allocPrint(allocator, "/{s}", .{name});
    if (base.len > 0 and base[base.len - 1] == '/') return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, name });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name });
}

fn stringLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
