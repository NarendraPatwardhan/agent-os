//! test/[ expression evaluator.

const std = @import("std");
const os = @import("os.zig");

pub const EvalError = union(enum) {
    missing_bracket,
    missing_argument,
    missing_rparen,
    too_many_arguments,
    unknown_unary: []const u8,
    unknown_binary: []const u8,
    integer_expected: []const u8,
};

pub const Result = union(enum) {
    ok: bool,
    err: EvalError,
};

pub const StatFn = *const fn (*anyopaque, []const u8) ?os.FileStat;

pub fn eval(name: []const u8, args: []const []const u8, stat_ptr: *anyopaque, stat_fn: StatFn) Result {
    var end = args.len;
    if (std.mem.eql(u8, name, "[")) {
        if (end == 0 or !std.mem.eql(u8, args[end - 1], "]")) {
            return .{ .err = .missing_bracket };
        }
        end -= 1;
    }
    return evalExpr(args[0..end], stat_ptr, stat_fn);
}

fn evalExpr(args: []const []const u8, stat_ptr: *anyopaque, stat_fn: StatFn) Result {
    if (args.len == 0) return .{ .ok = false };
    if (args.len == 1) return .{ .ok = args[0].len != 0 };

    var i: usize = 0;
    const value = testOr(args, &i, stat_ptr, stat_fn);
    switch (value) {
        .err => return value,
        .ok => |v| {
            if (i != args.len) return .{ .err = .too_many_arguments };
            return .{ .ok = v };
        },
    }
}

fn testOr(args: []const []const u8, i: *usize, stat_ptr: *anyopaque, stat_fn: StatFn) Result {
    var value = testAnd(args, i, stat_ptr, stat_fn);
    while (i.* < args.len and std.mem.eql(u8, args[i.*], "-o")) {
        i.* += 1;
        const rhs = testAnd(args, i, stat_ptr, stat_fn);
        value = boolOr(value, rhs);
    }
    return value;
}

fn testAnd(args: []const []const u8, i: *usize, stat_ptr: *anyopaque, stat_fn: StatFn) Result {
    var value = testFactor(args, i, stat_ptr, stat_fn);
    while (i.* < args.len and std.mem.eql(u8, args[i.*], "-a")) {
        i.* += 1;
        const rhs = testFactor(args, i, stat_ptr, stat_fn);
        value = boolAnd(value, rhs);
    }
    return value;
}

fn testFactor(args: []const []const u8, i: *usize, stat_ptr: *anyopaque, stat_fn: StatFn) Result {
    if (i.* >= args.len) return .{ .err = .missing_argument };
    const tok = args[i.*];
    if (std.mem.eql(u8, tok, "!")) {
        i.* += 1;
        return boolNot(testFactor(args, i, stat_ptr, stat_fn));
    }
    if (std.mem.eql(u8, tok, "(")) {
        i.* += 1;
        const value = testOr(args, i, stat_ptr, stat_fn);
        if (i.* >= args.len or !std.mem.eql(u8, args[i.*], ")")) {
            return .{ .err = .missing_rparen };
        }
        i.* += 1;
        return value;
    }

    const rem = args.len - i.*;
    if (rem >= 3 and isBinop(args[i.* + 1])) {
        const value = testBinary(args[i.*], args[i.* + 1], args[i.* + 2], stat_ptr, stat_fn);
        i.* += 3;
        return value;
    }
    if (rem >= 2 and isUnop(args[i.*])) {
        const value = testUnary(args[i.*], args[i.* + 1], stat_ptr, stat_fn);
        i.* += 2;
        return value;
    }
    i.* += 1;
    return .{ .ok = tok.len != 0 };
}

fn testUnary(op: []const u8, x: []const u8, stat_ptr: *anyopaque, stat_fn: StatFn) Result {
    if (std.mem.eql(u8, op, "-z")) return .{ .ok = x.len == 0 };
    if (std.mem.eql(u8, op, "-n")) return .{ .ok = x.len != 0 };
    const st = stat_fn(stat_ptr, x);
    if (std.mem.eql(u8, op, "-e")) return .{ .ok = st != null };
    if (std.mem.eql(u8, op, "-f")) return .{ .ok = if (st) |s| !s.is_dir else false };
    if (std.mem.eql(u8, op, "-d")) return .{ .ok = if (st) |s| s.is_dir else false };
    if (std.mem.eql(u8, op, "-s")) return .{ .ok = if (st) |s| s.size > 0 else false };
    if (std.mem.eql(u8, op, "-r")) return .{ .ok = if (st) |s| s.readable() else false };
    if (std.mem.eql(u8, op, "-w")) return .{ .ok = if (st) |s| s.writable() else false };
    if (std.mem.eql(u8, op, "-x")) return .{ .ok = if (st) |s| s.executable() else false };
    return .{ .err = .{ .unknown_unary = op } };
}

fn testBinary(x: []const u8, op: []const u8, y: []const u8, stat_ptr: *anyopaque, stat_fn: StatFn) Result {
    if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) return .{ .ok = std.mem.eql(u8, x, y) };
    if (std.mem.eql(u8, op, "!=")) return .{ .ok = !std.mem.eql(u8, x, y) };
    if (std.mem.eql(u8, op, "-eq")) return intCompare(x, y, .eq);
    if (std.mem.eql(u8, op, "-ne")) return intCompare(x, y, .ne);
    if (std.mem.eql(u8, op, "-lt")) return intCompare(x, y, .lt);
    if (std.mem.eql(u8, op, "-le")) return intCompare(x, y, .le);
    if (std.mem.eql(u8, op, "-gt")) return intCompare(x, y, .gt);
    if (std.mem.eql(u8, op, "-ge")) return intCompare(x, y, .ge);
    if (std.mem.eql(u8, op, "-nt")) {
        const mx = if (stat_fn(stat_ptr, x)) |s| s.mtime else null;
        const my = if (stat_fn(stat_ptr, y)) |s| s.mtime else null;
        return .{ .ok = if (mx) |a| if (my) |b| a > b else true else false };
    }
    if (std.mem.eql(u8, op, "-ot")) {
        const mx = if (stat_fn(stat_ptr, x)) |s| s.mtime else null;
        const my = if (stat_fn(stat_ptr, y)) |s| s.mtime else null;
        return .{ .ok = if (mx) |a| if (my) |b| a < b else false else my != null };
    }
    return .{ .err = .{ .unknown_binary = op } };
}

const Cmp = enum { eq, ne, lt, le, gt, ge };

fn intCompare(x: []const u8, y: []const u8, cmp: Cmp) Result {
    const xv = parseInt(x) orelse return .{ .err = .{ .integer_expected = x } };
    const yv = parseInt(y) orelse return .{ .err = .{ .integer_expected = y } };
    return .{ .ok = switch (cmp) {
        .eq => xv == yv,
        .ne => xv != yv,
        .lt => xv < yv,
        .le => xv <= yv,
        .gt => xv > yv,
        .ge => xv >= yv,
    } };
}

fn parseInt(s: []const u8) ?i64 {
    return std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t\r\n"), 10) catch null;
}

pub fn isBinop(op: []const u8) bool {
    inline for (.{ "=", "==", "!=", "-eq", "-ne", "-lt", "-le", "-gt", "-ge", "-nt", "-ot" }) |candidate| {
        if (std.mem.eql(u8, op, candidate)) return true;
    }
    return false;
}

pub fn isUnop(op: []const u8) bool {
    inline for (.{ "-z", "-n", "-e", "-f", "-d", "-s", "-r", "-w", "-x" }) |candidate| {
        if (std.mem.eql(u8, op, candidate)) return true;
    }
    return false;
}

fn boolNot(r: Result) Result {
    return switch (r) {
        .ok => |v| .{ .ok = !v },
        .err => r,
    };
}

fn boolAnd(a: Result, b: Result) Result {
    return switch (a) {
        .err => a,
        .ok => |av| switch (b) {
            .err => b,
            .ok => |bv| .{ .ok = av and bv },
        },
    };
}

fn boolOr(a: Result, b: Result) Result {
    return switch (a) {
        .err => a,
        .ok => |av| switch (b) {
            .err => b,
            .ok => |bv| .{ .ok = av or bv },
        },
    };
}
