//! jq builtin functions. Each is invoked by name from eval.zig's `evalCall`; filter-taking
//! builtins (map, select, sort_by, ...) re-enter the evaluator via the passed `interp`.
//! The common set jaq/jq usage needs; the rest are a documented deferral.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ev = @import("eval.zig");
const val = @import("value.zig");
const Value = val.Value;
const Entry = val.Entry;

const Error = ev.Error;

pub fn call(interp: *ev.Interp, name: []const u8, args: []*ev.Node, input: Value, env: *ev.Env, ctx: *anyopaque, emit: ev.Emit) Error!void {
    const gpa = interp.gpa;
    // zero-arg builtins
    if (args.len == 0) {
        if (eq(name, "length")) return emit(ctx, try lengthOf(input));
        if (eq(name, "utf8bytelength")) { if (input != .string) return error.JqRuntime; return emit(ctx, .{ .number = @floatFromInt(input.string.len) }); }
        if (eq(name, "keys") or eq(name, "keys_unsorted")) return emit(ctx, try keys(gpa, input, eq(name, "keys")));
        // Type filters: emit input iff it has the named type (jq numbers/strings/...).
        if (eq(name, "numbers")) return if (input == .number) emit(ctx, input);
        if (eq(name, "strings")) return if (input == .string) emit(ctx, input);
        if (eq(name, "booleans")) return if (input == .boolean) emit(ctx, input);
        if (eq(name, "nulls")) return if (input == .null) emit(ctx, input);
        if (eq(name, "arrays")) return if (input == .array) emit(ctx, input);
        if (eq(name, "objects")) return if (input == .object) emit(ctx, input);
        if (eq(name, "iterables")) return if (input == .array or input == .object) emit(ctx, input);
        if (eq(name, "scalars")) return if (input != .array and input != .object) emit(ctx, input);
        if (eq(name, "values")) return if (input != .null) emit(ctx, input); // jq: select(. != null)
        if (eq(name, "type")) return emit(ctx, .{ .string = input.typeName() });
        if (eq(name, "not")) return emit(ctx, Value.boolOf(!input.truthy()));
        if (eq(name, "add")) return emit(ctx, try addAll(interp, input));
        if (eq(name, "empty")) return;
        if (eq(name, "min")) return emit(ctx, try minmax(gpa, input, true));
        if (eq(name, "max")) return emit(ctx, try minmax(gpa, input, false));
        if (eq(name, "sort")) return emit(ctx, try sortArr(gpa, input));
        if (eq(name, "unique")) return emit(ctx, try uniqueArr(gpa, input));
        if (eq(name, "reverse")) return emit(ctx, try reverseVal(gpa, input));
        if (eq(name, "flatten")) return emit(ctx, try flatten(gpa, input, 1000000));
        if (eq(name, "to_entries")) return emit(ctx, try toEntries(gpa, input));
        if (eq(name, "from_entries")) return emit(ctx, try fromEntries(gpa, input));
        if (eq(name, "floor")) return emit(ctx, num1(input, floorF));
        if (eq(name, "ceil")) return emit(ctx, num1(input, ceilF));
        if (eq(name, "round")) return emit(ctx, num1(input, roundHalfUp));
        if (eq(name, "fabs")) return emit(ctx, num1(input, absF));
        if (eq(name, "sqrt")) return emit(ctx, num1(input, sqrtF));
        if (eq(name, "tostring")) return emit(ctx, .{ .string = try renderCompact(gpa, input, true) });
        if (eq(name, "tonumber")) return emit(ctx, try toNumber(input));
        if (eq(name, "ascii_downcase")) return emit(ctx, try caseStr(gpa, input, false));
        if (eq(name, "ascii_upcase")) return emit(ctx, try caseStr(gpa, input, true));
        if (eq(name, "first")) return firstLast(input, ctx, emit, true);
        if (eq(name, "last")) return firstLast(input, ctx, emit, false);
        if (eq(name, "recurse")) return interp.recurse(input, ctx, emit);
        if (eq(name, "any")) return emit(ctx, try anyAll(input, true));
        if (eq(name, "all")) return emit(ctx, try anyAll(input, false));
        if (eq(name, "ascii")) return emit(ctx, input);
    }
    // one-arg builtins
    if (args.len == 1) {
        if (eq(name, "map")) return mapFilter(interp, args[0], input, env, ctx, emit);
        if (eq(name, "select")) return selectFilter(interp, args[0], input, env, ctx, emit);
        if (eq(name, "has")) return emit(ctx, try hasKey(interp, args[0], input, env));
        if (eq(name, "contains")) return emit(ctx, Value.boolOf(containsVal(input, try interp.evalOne(args[0], input, env))));
        if (eq(name, "startswith")) return emit(ctx, try affix(interp, args[0], input, env, true));
        if (eq(name, "endswith")) return emit(ctx, try affix(interp, args[0], input, env, false));
        if (eq(name, "ltrimstr")) return emit(ctx, try trimstr(interp, args[0], input, env, true));
        if (eq(name, "rtrimstr")) return emit(ctx, try trimstr(interp, args[0], input, env, false));
        if (eq(name, "join")) return emit(ctx, try joinArr(interp, args[0], input, env));
        if (eq(name, "split")) return emit(ctx, try splitStr(interp, args[0], input, env));
        if (eq(name, "sort_by")) return emit(ctx, try sortBy(interp, args[0], input, env));
        if (eq(name, "group_by")) return emit(ctx, try groupBy(interp, args[0], input, env));
        if (eq(name, "unique_by")) return emit(ctx, try uniqueBy(interp, args[0], input, env));
        if (eq(name, "range")) return rangeFilter(interp, args, input, env, ctx, emit);
        if (eq(name, "error")) return error.JqRuntime;
        if (eq(name, "map_values")) return emit(ctx, try mapValues(interp, args[0], input, env));
    }
    if (eq(name, "range")) return rangeFilter(interp, args, input, env, ctx, emit);
    return error.JqRuntime;
}


fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn lengthOf(v: Value) Error!Value {
    return switch (v) {
        .null => .{ .number = 0 },
        .string => |s| .{ .number = @floatFromInt(s.len) },
        .array => |a| .{ .number = @floatFromInt(a.len) },
        .object => |o| .{ .number = @floatFromInt(o.len) },
        .number => |n| .{ .number = @abs(n) },
        .boolean => error.JqRuntime,
    };
}

fn keys(gpa: Allocator, v: Value, sorted: bool) Error!Value {
    switch (v) {
        .object => |o| {
            var arr = try gpa.alloc(Value, o.len);
            for (o, 0..) |e, i| arr[i] = .{ .string = e.key };
            if (sorted) std.mem.sort(Value, arr, {}, lessString);
            return .{ .array = arr };
        },
        .array => |a| {
            var arr = try gpa.alloc(Value, a.len);
            for (0..a.len) |i| arr[i] = .{ .number = @floatFromInt(i) };
            return .{ .array = arr };
        },
        else => return error.JqRuntime,
    }
}

fn lessString(_: void, a: Value, b: Value) bool {
    return std.mem.order(u8, a.string, b.string) == .lt;
}

fn valuesOf(v: Value, ctx: *anyopaque, emit: ev.Emit) Error!void {
    switch (v) {
        .array => |a| for (a) |x| try emit(ctx, x),
        .object => |o| for (o) |e| try emit(ctx, e.value),
        else => return error.JqRuntime,
    }
}

fn addAll(interp: *ev.Interp, v: Value) Error!Value {
    var acc: Value = .null;
    switch (v) {
        .array => |a| for (a) |x| {
            acc = try interp.addVals(acc, x);
        },
        .object => |o| for (o) |e| {
            acc = try interp.addVals(acc, e.value);
        },
        .null => return .null,
        else => return error.JqRuntime,
    }
    return acc;
}

fn minmax(gpa: Allocator, v: Value, want_min: bool) Error!Value {
    if (v != .array) return error.JqRuntime;
    const a = v.array;
    if (a.len == 0) return .null;
    var best = a[0];
    for (a[1..]) |x| {
        const ord = Value.compare(gpa, x, best);
        if ((want_min and ord == .lt) or (!want_min and ord == .gt)) best = x;
    }
    return best;
}

fn sortArr(gpa: Allocator, v: Value) Error!Value {
    if (v != .array) return error.JqRuntime;
    const arr = try gpa.dupe(Value, v.array);
    const C = struct {
        g: Allocator,
        fn less(self: @This(), a: Value, b: Value) bool {
            return Value.compare(self.g, a, b) == .lt;
        }
    };
    std.mem.sort(Value, arr, C{ .g = gpa }, C.less);
    return .{ .array = arr };
}

fn uniqueArr(gpa: Allocator, v: Value) Error!Value {
    const sorted = try sortArr(gpa, v);
    var out: std.ArrayListUnmanaged(Value) = .empty;
    for (sorted.array) |x| {
        if (out.items.len == 0 or !Value.equal(gpa, out.items[out.items.len - 1], x)) {
            try out.append(gpa, x);
        }
    }
    return .{ .array = out.items };
}

fn reverseVal(gpa: Allocator, v: Value) Error!Value {
    switch (v) {
        .array => |a| {
            const arr = try gpa.alloc(Value, a.len);
            for (a, 0..) |x, i| arr[a.len - 1 - i] = x;
            return .{ .array = arr };
        },
        .string => |s| {
            const b = try gpa.alloc(u8, s.len);
            for (s, 0..) |c, i| b[s.len - 1 - i] = c;
            return .{ .string = b };
        },
        else => return error.JqRuntime,
    }
}

fn flatten(gpa: Allocator, v: Value, depth: usize) Error!Value {
    if (v != .array) return error.JqRuntime;
    var out: std.ArrayListUnmanaged(Value) = .empty;
    try flattenInto(gpa, &out, v, depth);
    return .{ .array = out.items };
}
fn flattenInto(gpa: Allocator, out: *std.ArrayListUnmanaged(Value), v: Value, depth: usize) Error!void {
    for (v.array) |x| {
        if (x == .array and depth > 0) {
            try flattenInto(gpa, out, x, depth - 1);
        } else try out.append(gpa, x);
    }
}

fn toEntries(gpa: Allocator, v: Value) Error!Value {
    if (v != .object) return error.JqRuntime;
    var arr = try gpa.alloc(Value, v.object.len);
    for (v.object, 0..) |e, i| {
        var ob = val.ObjBuilder.init(gpa);
        ob.set("key", .{ .string = e.key });
        ob.set("value", e.value);
        arr[i] = .{ .object = ob.finish() };
    }
    return .{ .array = arr };
}

fn fromEntries(gpa: Allocator, v: Value) Error!Value {
    if (v != .array) return error.JqRuntime;
    var ob = val.ObjBuilder.init(gpa);
    for (v.array) |e| {
        if (e != .object) return error.JqRuntime;
        const k = firstOf(e.object, &.{ "key", "k", "name", "Name", "Key", "K" }) orelse Value{ .null = {} };
        const val_ = firstOf(e.object, &.{ "value", "v", "Value", "V" }) orelse Value{ .null = {} };
        const keystr = switch (k) {
            .string => |s| s,
            .number => |n| try std.fmt.allocPrint(gpa, "{d}", .{n}),
            else => return error.JqRuntime,
        };
        ob.set(keystr, val_);
    }
    return .{ .object = ob.finish() };
}
fn firstOf(obj: []const Entry, names: []const []const u8) ?Value {
    for (names) |n| for (obj) |e| if (eq(e.key, n)) return e.value;
    return null;
}

fn num1(v: Value, comptime f: fn (f64) f64) Value {
    return if (v == .number) .{ .number = f(v.number) } else v;
}
fn floorF(x: f64) f64 { return @floor(x); }
fn ceilF(x: f64) f64 { return @ceil(x); }
fn sqrtF(x: f64) f64 { return @sqrt(x); }
fn absF(x: f64) f64 {
    return @abs(x);
}
fn roundHalfUp(x: f64) f64 {
    return std.math.floor(x + 0.5);
}

fn toNumber(v: Value) Error!Value {
    return switch (v) {
        .number => v,
        .string => |s| .{ .number = std.fmt.parseFloat(f64, s) catch return error.JqRuntime },
        else => error.JqRuntime,
    };
}

fn caseStr(gpa: Allocator, v: Value, up: bool) Error!Value {
    if (v != .string) return error.JqRuntime;
    const b = try gpa.dupe(u8, v.string);
    for (b) |*c| c.* = if (up) std.ascii.toUpper(c.*) else std.ascii.toLower(c.*);
    return .{ .string = b };
}

fn firstLast(v: Value, ctx: *anyopaque, emit: ev.Emit, first: bool) Error!void {
    if (v != .array) return error.JqRuntime;
    if (v.array.len == 0) return emit(ctx, .null);
    return emit(ctx, if (first) v.array[0] else v.array[v.array.len - 1]);
}

fn anyAll(v: Value, is_any: bool) Error!Value {
    if (v != .array) return error.JqRuntime;
    for (v.array) |x| {
        if (is_any and x.truthy()) return Value.TRUE;
        if (!is_any and !x.truthy()) return Value.FALSE;
    }
    return if (is_any) Value.FALSE else Value.TRUE;
}

// -------- filter-taking builtins --------

fn mapFilter(interp: *ev.Interp, filt: *ev.Node, input: Value, env: *ev.Env, ctx: *anyopaque, emit: ev.Emit) Error!void {
    if (input != .array) return error.JqRuntime;
    var out: std.ArrayListUnmanaged(Value) = .empty;
    const Collect = struct {
        list: *std.ArrayListUnmanaged(Value),
        gpa: Allocator,
        fn f(c: *anyopaque, v: Value) Error!void {
            const s: *@This() = @ptrCast(@alignCast(c));
            try s.list.append(s.gpa, v);
        }
    };
    var col = Collect{ .list = &out, .gpa = interp.gpa };
    for (input.array) |x| try interp.evalNode(filt, x, env, &col, Collect.f);
    try emit(ctx, .{ .array = out.items });
}

fn mapValues(interp: *ev.Interp, filt: *ev.Node, input: Value, env: *ev.Env) Error!Value {
    switch (input) {
        .array => |a| {
            var out: std.ArrayListUnmanaged(Value) = .empty;
            for (a) |x| try out.append(interp.gpa, try interp.evalOne(filt, x, env));
            return .{ .array = out.items };
        },
        .object => |o| {
            var ob = val.ObjBuilder.init(interp.gpa);
            for (o) |e| ob.set(e.key, try interp.evalOne(filt, e.value, env));
            return .{ .object = ob.finish() };
        },
        else => return error.JqRuntime,
    }
}

fn selectFilter(interp: *ev.Interp, filt: *ev.Node, input: Value, env: *ev.Env, ctx: *anyopaque, emit: ev.Emit) Error!void {
    const cond = try interp.evalOne(filt, input, env);
    if (cond.truthy()) try emit(ctx, input);
}

fn hasKey(interp: *ev.Interp, arg: *ev.Node, input: Value, env: *ev.Env) Error!Value {
    const k = try interp.evalOne(arg, input, env);
    switch (input) {
        .object => |o| {
            if (k != .string) return error.JqRuntime;
            for (o) |e| if (eq(e.key, k.string)) return Value.TRUE;
            return Value.FALSE;
        },
        .array => |a| {
            if (k != .number) return error.JqRuntime;
            const i: i64 = @intFromFloat(k.number);
            return Value.boolOf(i >= 0 and i < a.len);
        },
        else => return error.JqRuntime,
    }
}

fn containsVal(a: Value, b: Value) bool {
    if (a == .string and b == .string) return std.mem.indexOf(u8, a.string, b.string) != null;
    return false;
}

fn affix(interp: *ev.Interp, arg: *ev.Node, input: Value, env: *ev.Env, prefix: bool) Error!Value {
    if (input != .string) return error.JqRuntime;
    const p = try interp.evalOne(arg, input, env);
    if (p != .string) return error.JqRuntime;
    return Value.boolOf(if (prefix) std.mem.startsWith(u8, input.string, p.string) else std.mem.endsWith(u8, input.string, p.string));
}

fn trimstr(interp: *ev.Interp, arg: *ev.Node, input: Value, env: *ev.Env, left: bool) Error!Value {
    if (input != .string) return input;
    const p = try interp.evalOne(arg, input, env);
    if (p != .string) return input;
    if (left and std.mem.startsWith(u8, input.string, p.string)) return .{ .string = input.string[p.string.len..] };
    if (!left and std.mem.endsWith(u8, input.string, p.string)) return .{ .string = input.string[0 .. input.string.len - p.string.len] };
    return input;
}

fn joinArr(interp: *ev.Interp, arg: *ev.Node, input: Value, env: *ev.Env) Error!Value {
    if (input != .array) return error.JqRuntime;
    const sepv = try interp.evalOne(arg, input, env);
    const sep = if (sepv == .string) sepv.string else "";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (input.array, 0..) |x, i| {
        if (i != 0) try out.appendSlice(interp.gpa, sep);
        switch (x) {
            .string => |s| try out.appendSlice(interp.gpa, s),
            .number => |n| try out.appendSlice(interp.gpa, try std.fmt.allocPrint(interp.gpa, "{d}", .{n})),
            .null => {},
            .boolean => |b| try out.appendSlice(interp.gpa, if (b) "true" else "false"),
            else => return error.JqRuntime,
        }
    }
    return .{ .string = out.items };
}

fn splitStr(interp: *ev.Interp, arg: *ev.Node, input: Value, env: *ev.Env) Error!Value {
    if (input != .string) return error.JqRuntime;
    const sepv = try interp.evalOne(arg, input, env);
    if (sepv != .string) return error.JqRuntime;
    var out: std.ArrayListUnmanaged(Value) = .empty;
    if (sepv.string.len == 0) {
        for (input.string) |c| try out.append(interp.gpa, .{ .string = try interp.gpa.dupe(u8, &[_]u8{c}) });
    } else {
        var it = std.mem.splitSequence(u8, input.string, sepv.string);
        while (it.next()) |piece| try out.append(interp.gpa, .{ .string = piece });
    }
    return .{ .array = out.items };
}

fn sortBy(interp: *ev.Interp, filt: *ev.Node, input: Value, env: *ev.Env) Error!Value {
    if (input != .array) return error.JqRuntime;
    const Pair = struct { key: Value, v: Value };
    var pairs = try interp.gpa.alloc(Pair, input.array.len);
    for (input.array, 0..) |x, i| pairs[i] = .{ .key = try interp.evalOne(filt, x, env), .v = x };
    const C = struct {
        g: Allocator,
        fn less(self: @This(), a: Pair, b: Pair) bool {
            return Value.compare(self.g, a.key, b.key) == .lt;
        }
    };
    std.mem.sort(Pair, pairs, C{ .g = interp.gpa }, C.less);
    var arr = try interp.gpa.alloc(Value, pairs.len);
    for (pairs, 0..) |p, i| arr[i] = p.v;
    return .{ .array = arr };
}

fn uniqueBy(interp: *ev.Interp, filt: *ev.Node, input: Value, env: *ev.Env) Error!Value {
    const sorted = try sortBy(interp, filt, input, env);
    var out: std.ArrayListUnmanaged(Value) = .empty;
    var last_key: ?Value = null;
    for (sorted.array) |x| {
        const k = try interp.evalOne(filt, x, env);
        if (last_key == null or !Value.equal(interp.gpa, last_key.?, k)) {
            try out.append(interp.gpa, x);
            last_key = k;
        }
    }
    return .{ .array = out.items };
}

fn groupBy(interp: *ev.Interp, filt: *ev.Node, input: Value, env: *ev.Env) Error!Value {
    const sorted = try sortBy(interp, filt, input, env);
    var groups: std.ArrayListUnmanaged(Value) = .empty;
    var cur: std.ArrayListUnmanaged(Value) = .empty;
    var last_key: ?Value = null;
    for (sorted.array) |x| {
        const k = try interp.evalOne(filt, x, env);
        if (last_key != null and !Value.equal(interp.gpa, last_key.?, k)) {
            try groups.append(interp.gpa, .{ .array = cur.items });
            cur = .empty;
        }
        try cur.append(interp.gpa, x);
        last_key = k;
    }
    if (cur.items.len != 0) try groups.append(interp.gpa, .{ .array = cur.items });
    return .{ .array = groups.items };
}

fn rangeFilter(interp: *ev.Interp, args: []*ev.Node, input: Value, env: *ev.Env, ctx: *anyopaque, emit: ev.Emit) Error!void {
    var lo: f64 = 0;
    var hi: f64 = 0;
    var step: f64 = 1;
    if (args.len == 1) {
        hi = (try interp.evalOne(args[0], input, env)).number;
    } else if (args.len >= 2) {
        lo = (try interp.evalOne(args[0], input, env)).number;
        hi = (try interp.evalOne(args[1], input, env)).number;
        if (args.len >= 3) step = (try interp.evalOne(args[2], input, env)).number;
    }
    if (step == 0) return;
    var x = lo;
    while ((step > 0 and x < hi) or (step < 0 and x > hi)) : (x += step) try emit(ctx, .{ .number = x });
}

/// Compact JSON rendering of a value into a freshly-allocated buffer. `raw_string` emits a
/// bare string without quotes (for tostring/`-r`).
pub fn renderCompact(gpa: Allocator, v: Value, raw_string: bool) Error![]const u8 {
    if (raw_string and v == .string) return gpa.dupe(u8, v.string);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try renderInto(gpa, &out, v, false, 0);
    return out.items;
}

pub fn renderPretty(gpa: Allocator, v: Value) Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try renderInto(gpa, &out, v, true, 0);
    return out.items;
}

fn renderInto(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), v: Value, pretty: bool, indent: usize) Error!void {
    switch (v) {
        .null => try out.appendSlice(gpa, "null"),
        .boolean => |b| try out.appendSlice(gpa, if (b) "true" else "false"),
        .number => |n| try renderNumber(gpa, out, n),
        .string => |s| try renderString(gpa, out, s),
        .array => |a| {
            if (a.len == 0) {
                try out.appendSlice(gpa, "[]");
                return;
            }
            try out.append(gpa, '[');
            for (a, 0..) |x, i| {
                if (i != 0) try out.append(gpa, ',');
                if (pretty) try newlineIndent(gpa, out, indent + 1);
                try renderInto(gpa, out, x, pretty, indent + 1);
            }
            if (pretty) try newlineIndent(gpa, out, indent);
            try out.append(gpa, ']');
        },
        .object => |o| {
            if (o.len == 0) {
                try out.appendSlice(gpa, "{}");
                return;
            }
            try out.append(gpa, '{');
            for (o, 0..) |e, i| {
                if (i != 0) try out.append(gpa, ',');
                if (pretty) try newlineIndent(gpa, out, indent + 1);
                try renderString(gpa, out, e.key);
                try out.append(gpa, ':');
                if (pretty) try out.append(gpa, ' ');
                try renderInto(gpa, out, e.value, pretty, indent + 1);
            }
            if (pretty) try newlineIndent(gpa, out, indent);
            try out.append(gpa, '}');
        },
    }
}

fn newlineIndent(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), indent: usize) Error!void {
    try out.append(gpa, '\n');
    var i: usize = 0;
    while (i < indent) : (i += 1) try out.appendSlice(gpa, "  ");
}

fn renderNumber(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), n: f64) Error!void {
    if (n == @floor(n) and std.math.isFinite(n) and @abs(n) < 1e17) {
        try out.appendSlice(gpa, try std.fmt.allocPrint(gpa, "{d}", .{@as(i64, @intFromFloat(n))}));
    } else {
        try out.appendSlice(gpa, try std.fmt.allocPrint(gpa, "{d}", .{n}));
    }
}

fn renderString(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) Error!void {
    try out.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            0x08 => try out.appendSlice(gpa, "\\b"),
            0x0c => try out.appendSlice(gpa, "\\f"),
            0...7, 0x0b, 0x0e...0x1f => try out.appendSlice(gpa, try std.fmt.allocPrint(gpa, "\\u{x:0>4}", .{c})),
            else => try out.append(gpa, c),
        }
    }
    try out.append(gpa, '"');
}
