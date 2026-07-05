//! printf formatting engine: pure byte-in/byte-out, no OS.

const std = @import("std");

pub const RenderResult = struct {
    bytes: []u8,
    had_error: bool = false,
};

pub fn render(allocator: std.mem.Allocator, fmt: []const u8, args: []const []const u8) !RenderResult {
    var out = std.ArrayList(u8).empty;
    var ai: usize = 0;
    var err = false;
    while (true) {
        const before = ai;
        const stop = try renderOnce(allocator, fmt, args, &ai, &out, &err);
        if (stop) break;
        if (ai >= args.len or ai == before) break;
    }
    return .{ .bytes = try out.toOwnedSlice(allocator), .had_error = err };
}

fn renderOnce(
    allocator: std.mem.Allocator,
    fmt: []const u8,
    args: []const []const u8,
    ai: *usize,
    out: *std.ArrayList(u8),
    err: *bool,
) !bool {
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c == '\\') {
            const escaped = try escapeAt(allocator, fmt, i, out);
            i = escaped.next;
            if (escaped.stop) return true;
            continue;
        }
        if (c != '%' or i + 1 >= fmt.len) {
            try out.append(allocator, c);
            i += 1;
            continue;
        }

        i += 1;
        if (fmt[i] == '%') {
            try out.append(allocator, '%');
            i += 1;
            continue;
        }

        const spec_start = i;
        var left = false;
        var plus = false;
        var space = false;
        var zero = false;
        var hash = false;
        while (i < fmt.len) : (i += 1) {
            switch (fmt[i]) {
                '-' => left = true,
                '+' => plus = true,
                ' ' => space = true,
                '0' => zero = true,
                '#' => hash = true,
                '\'' => {},
                else => break,
            }
        }

        var width: usize = 0;
        if (i < fmt.len and fmt[i] == '*') {
            i += 1;
            const w = argNum(argAt(args, ai.*), err);
            ai.* += 1;
            if (w < 0) {
                left = true;
                width = @intCast(-w);
            } else {
                width = @intCast(w);
            }
        } else {
            while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) {
                width = width * 10 + (fmt[i] - '0');
            }
        }

        var precision: ?usize = null;
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            if (i < fmt.len and fmt[i] == '*') {
                i += 1;
                const p = argNum(argAt(args, ai.*), err);
                ai.* += 1;
                precision = if (p < 0) null else @as(usize, @intCast(p));
            } else {
                var p: usize = 0;
                while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) {
                    p = p * 10 + (fmt[i] - '0');
                }
                precision = p;
            }
        }

        while (i < fmt.len and isLengthModifier(fmt[i])) : (i += 1) {}
        if (i >= fmt.len) {
            try out.append(allocator, '%');
            try out.appendSlice(allocator, fmt[spec_start..i]);
            break;
        }

        const conv = fmt[i];
        i += 1;
        const arg = argAt(args, ai.*);
        switch (conv) {
            's' => {
                const body = if (precision) |p| arg[0..@min(p, arg.len)] else arg;
                try emitStr(allocator, out, body, width, left);
                ai.* += 1;
            },
            'b' => {
                var decoded = std.ArrayList(u8).empty;
                var j: usize = 0;
                var stop = false;
                while (j < arg.len) {
                    if (arg[j] == '\\') {
                        const escaped = try escapeAt(allocator, arg, j, &decoded);
                        j = escaped.next;
                        if (escaped.stop) {
                            stop = true;
                            break;
                        }
                    } else {
                        try decoded.append(allocator, arg[j]);
                        j += 1;
                    }
                }
                const body = if (precision) |p| decoded.items[0..@min(p, decoded.items.len)] else decoded.items;
                try emitStr(allocator, out, body, width, left);
                ai.* += 1;
                if (stop) return true;
            },
            'c' => {
                const one = arg[0..@min(arg.len, 1)];
                try emitStr(allocator, out, one, width, left);
                ai.* += 1;
            },
            'd', 'i' => {
                const v = argNum(arg, err);
                var digits = std.ArrayList(u8).empty;
                if (!(precision != null and precision.? == 0 and v == 0)) {
                    const mag: u64 = if (v < 0) @intCast(0 -% v) else @intCast(v);
                    try pushRadix(allocator, &digits, mag, 10, false);
                }
                const sign: []const u8 = if (v < 0) "-" else if (plus) "+" else if (space) " " else "";
                try emitNum(allocator, out, sign, digits.items, width, precision, left, zero);
                ai.* += 1;
            },
            'u', 'o', 'x', 'X' => {
                const v: u64 = @bitCast(argNum(arg, err));
                var digits = std.ArrayList(u8).empty;
                const radix: u64 = switch (conv) {
                    'o' => 8,
                    'u' => 10,
                    else => 16,
                };
                if (!(precision != null and precision.? == 0 and v == 0)) {
                    try pushRadix(allocator, &digits, v, radix, conv == 'X');
                }
                var sign = std.ArrayList(u8).empty;
                if (hash and v != 0) {
                    switch (conv) {
                        'o' => if (digits.items.len == 0 or digits.items[0] != '0') try sign.append(allocator, '0'),
                        'x' => try sign.appendSlice(allocator, "0x"),
                        'X' => try sign.appendSlice(allocator, "0X"),
                        else => {},
                    }
                }
                try emitNum(allocator, out, sign.items, digits.items, width, precision, left, zero);
                ai.* += 1;
            },
            else => {
                try out.append(allocator, '%');
                try out.appendSlice(allocator, fmt[spec_start..i]);
            },
        }
    }
    return false;
}

fn argAt(args: []const []const u8, idx: usize) []const u8 {
    return if (idx < args.len) args[idx] else "";
}

fn isLengthModifier(ch: u8) bool {
    return ch == 'l' or ch == 'h' or ch == 'L' or ch == 'q' or ch == 'j' or ch == 'z' or ch == 't';
}

fn pushRadix(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64, radix: u64, upper: bool) !void {
    const lower = "0123456789abcdef";
    const upper_digits = "0123456789ABCDEF";
    const digits = if (upper) upper_digits else lower;
    var tmp: [64]u8 = undefined;
    var i = tmp.len;
    var v = value;
    if (v == 0) {
        i -= 1;
        tmp[i] = '0';
    }
    while (v > 0) {
        i -= 1;
        tmp[i] = digits[@intCast(v % radix)];
        v /= radix;
    }
    try out.appendSlice(allocator, tmp[i..]);
}

const EscapeResult = struct {
    next: usize,
    stop: bool,
};

pub fn escapeAt(allocator: std.mem.Allocator, s: []const u8, i: usize, out: *std.ArrayList(u8)) !EscapeResult {
    if (i + 1 >= s.len) {
        try out.append(allocator, '\\');
        return .{ .next = i + 1, .stop = false };
    }
    const n = s[i + 1];
    switch (n) {
        'a' => return falsePush(allocator, out, i + 2, 7),
        'b' => return falsePush(allocator, out, i + 2, 8),
        'f' => return falsePush(allocator, out, i + 2, 12),
        'n' => return falsePush(allocator, out, i + 2, '\n'),
        'r' => return falsePush(allocator, out, i + 2, '\r'),
        't' => return falsePush(allocator, out, i + 2, '\t'),
        'v' => return falsePush(allocator, out, i + 2, 11),
        '\\' => return falsePush(allocator, out, i + 2, '\\'),
        'c' => return .{ .next = i + 2, .stop = true },
        'x' => return hexEscape(allocator, s, i, out),
        'u', 'U' => return unicodeEscape(allocator, s, i, out, n == 'u'),
        '0' => return octalEscape(allocator, s, i + 2, 3, out),
        '1'...'7' => return octalEscape(allocator, s, i + 1, 3, out),
        else => |other| {
            try out.append(allocator, '\\');
            try out.append(allocator, other);
            return .{ .next = i + 2, .stop = false };
        },
    }
}

fn falsePush(allocator: std.mem.Allocator, out: *std.ArrayList(u8), next: usize, byte: u8) !EscapeResult {
    try out.append(allocator, byte);
    return .{ .next = next, .stop = false };
}

fn hexEscape(allocator: std.mem.Allocator, s: []const u8, i: usize, out: *std.ArrayList(u8)) !EscapeResult {
    var j = i + 2;
    var value: u32 = 0;
    var count: usize = 0;
    while (j < s.len and count < 2) {
        const h = hexVal(s[j]) orelse break;
        value = value * 16 + h;
        j += 1;
        count += 1;
    }
    if (count == 0) {
        try out.append(allocator, '\\');
        try out.append(allocator, 'x');
        return .{ .next = i + 2, .stop = false };
    }
    try out.append(allocator, @truncate(value));
    return .{ .next = j, .stop = false };
}

fn unicodeEscape(allocator: std.mem.Allocator, s: []const u8, i: usize, out: *std.ArrayList(u8), small: bool) !EscapeResult {
    const max: usize = if (small) 4 else 8;
    var j = i + 2;
    var value: u32 = 0;
    var count: usize = 0;
    while (j < s.len and count < max) {
        const h = hexVal(s[j]) orelse break;
        value = value * 16 + h;
        j += 1;
        count += 1;
    }
    if (count == 0) {
        try out.append(allocator, '\\');
        try out.append(allocator, if (small) 'u' else 'U');
        return .{ .next = i + 2, .stop = false };
    }
    try pushUtf8(allocator, out, value);
    return .{ .next = j, .stop = false };
}

fn octalEscape(allocator: std.mem.Allocator, s: []const u8, start: usize, max: usize, out: *std.ArrayList(u8)) !EscapeResult {
    var j = start;
    var value: u32 = 0;
    var count: usize = 0;
    while (j < s.len and count < max and s[j] >= '0' and s[j] <= '7') {
        value = value * 8 + (s[j] - '0');
        j += 1;
        count += 1;
    }
    try out.append(allocator, @truncate(value));
    return .{ .next = j, .stop = false };
}

fn hexVal(ch: u8) ?u32 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

fn pushUtf8(allocator: std.mem.Allocator, out: *std.ArrayList(u8), cp: u32) !void {
    if (cp < 0x80) {
        try out.append(allocator, @intCast(cp));
    } else if (cp < 0x800) {
        try out.append(allocator, @intCast(0xC0 | (cp >> 6)));
        try out.append(allocator, @intCast(0x80 | (cp & 0x3f)));
    } else if (cp < 0x10000) {
        try out.append(allocator, @intCast(0xE0 | (cp >> 12)));
        try out.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3f)));
        try out.append(allocator, @intCast(0x80 | (cp & 0x3f)));
    } else {
        try out.append(allocator, @intCast(0xF0 | (cp >> 18)));
        try out.append(allocator, @intCast(0x80 | ((cp >> 12) & 0x3f)));
        try out.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3f)));
        try out.append(allocator, @intCast(0x80 | (cp & 0x3f)));
    }
}

fn argNum(arg: []const u8, err: *bool) i64 {
    if (arg.len == 0) return 0;
    if (arg[0] == '\'' or arg[0] == '"') {
        return if (arg.len > 1) arg[1] else 0;
    }
    const neg = arg[0] == '-';
    var i: usize = if (neg or arg[0] == '+') 1 else 0;
    const start = i;
    var value: i64 = 0;
    while (i < arg.len and std.ascii.isDigit(arg[i])) : (i += 1) {
        value = std.math.add(i64, std.math.mul(i64, value, 10) catch std.math.maxInt(i64), arg[i] - '0') catch std.math.maxInt(i64);
    }
    if (i == start or i != arg.len) err.* = true;
    return if (neg) -value else value;
}

fn emitNum(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    sign: []const u8,
    digits: []const u8,
    width: usize,
    precision: ?usize,
    left: bool,
    zero: bool,
) !void {
    var body = std.ArrayList(u8).empty;
    if (precision) |p| {
        if (p > digits.len) {
            try body.appendNTimes(allocator, '0', p - digits.len);
        }
    }
    try body.appendSlice(allocator, digits);
    const content = sign.len + body.items.len;
    const pad = width -| content;
    if (left) {
        try out.appendSlice(allocator, sign);
        try out.appendSlice(allocator, body.items);
        try out.appendNTimes(allocator, ' ', pad);
    } else if (zero and precision == null) {
        try out.appendSlice(allocator, sign);
        try out.appendNTimes(allocator, '0', pad);
        try out.appendSlice(allocator, body.items);
    } else {
        try out.appendNTimes(allocator, ' ', pad);
        try out.appendSlice(allocator, sign);
        try out.appendSlice(allocator, body.items);
    }
}

fn emitStr(allocator: std.mem.Allocator, out: *std.ArrayList(u8), body: []const u8, width: usize, left: bool) !void {
    const pad = width -| body.len;
    if (left) {
        try out.appendSlice(allocator, body);
        try out.appendNTimes(allocator, ' ', pad);
    } else {
        try out.appendNTimes(allocator, ' ', pad);
        try out.appendSlice(allocator, body);
    }
}
