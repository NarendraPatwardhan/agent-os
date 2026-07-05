//! The echo rendering logic: pure, no OS.

const std = @import("std");

/// Render an echo invocation. `args` is the words after `echo`; the returned
/// bytes include the trailing newline unless suppressed by `-n` or `\c`.
pub fn render(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var newline = true;
    var escapes = false;
    var start: usize = 0;

    while (start < args.len and isEchoFlag(args[start])) : (start += 1) {
        for (args[start][1..]) |ch| {
            switch (ch) {
                'n' => newline = false,
                'e' => escapes = true,
                'E' => escapes = false,
                else => {},
            }
        }
    }

    var out = std.ArrayList(u8).empty;
    var stopped = false;
    for (args[start..], 0..) |arg, idx| {
        if (idx != 0) try out.append(allocator, ' ');
        if (escapes) {
            const decoded = try unescape(allocator, arg);
            defer allocator.free(decoded.bytes);
            try out.appendSlice(allocator, decoded.bytes);
            if (decoded.stop) {
                stopped = true;
                break;
            }
        } else {
            try out.appendSlice(allocator, arg);
        }
    }

    if (newline and !stopped) try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

fn isEchoFlag(arg: []const u8) bool {
    if (arg.len < 2 or arg[0] != '-') return false;
    for (arg[1..]) |ch| {
        if (ch != 'n' and ch != 'e' and ch != 'E') return false;
    }
    return true;
}

const UnescapeResult = struct {
    bytes: []u8,
    stop: bool,
};

fn unescape(allocator: std.mem.Allocator, s: []const u8) !UnescapeResult {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                'n' => try out.append(allocator, '\n'),
                't' => try out.append(allocator, '\t'),
                'r' => try out.append(allocator, '\r'),
                '\\' => try out.append(allocator, '\\'),
                'a' => try out.append(allocator, 0x07),
                'b' => try out.append(allocator, 0x08),
                'f' => try out.append(allocator, 0x0c),
                'v' => try out.append(allocator, 0x0b),
                '0' => try out.append(allocator, 0),
                'c' => return .{ .bytes = try out.toOwnedSlice(allocator), .stop = true },
                else => |other| {
                    try out.append(allocator, '\\');
                    try out.append(allocator, other);
                },
            }
            i += 2;
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return .{ .bytes = try out.toOwnedSlice(allocator), .stop = false };
}
