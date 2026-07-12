//! `jq` -- a JSON query processor (DESIGN.md §1), matching jaq/jq on the
//! common language core (engines/jqlang). CLI: -c compact, -r raw string output, -n null
//! input, FILTER (required), [FILE]... (concatenated, parsed as a stream of JSON values;
//! stdin default). Exit 0 ok, 2 usage/file-open, 3 compile error, 5 runtime/parse error.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;
const textio = @import("../core/textio.zig");
const ev = @import("../engines/jqlang/eval.zig");
const builtins = @import("../engines/jqlang/builtins.zig");
const val = @import("../engines/jqlang/value.zig");
const Value = val.Value;

const help_doc = cli.Help{
    .summary = "command-line JSON processor",
    .synopsis = &.{"jq [-cnr] FILTER [FILE]..."},
    .description =
    \\Reads a stream of JSON values (from FILE(s), concatenated, or standard
    \\input) and runs FILTER against each one, printing every value the filter
    \\emits. FILTER supports identity (.), field/index access (.foo, .foo.bar,
    \\.[i], .[], .[a:b]), pipe (|) and comma (,), arithmetic and comparison
    \\operators, and/or/not, if/elif/else, the // alternative operator, recursive
    \\descent (..), object/array construction (including {(.k): v} dynamic keys
    \\and {$x} shorthand), reduce, `EXPR as $var | BODY` bindings, and roughly 50
    \\builtins (length, keys, values, type, map, select, add, min, max, sort,
    \\sort_by, group_by, unique, unique_by, reverse, flatten, to_entries,
    \\from_entries, floor, ceil, round, sqrt, tostring, tonumber,
    \\ascii_upcase/downcase, startswith, endswith, ltrimstr, rtrimstr, join,
    \\split, contains, has, range, map_values, first, last, any, all, recurse,
    \\and the numbers/strings/objects/... type filters, among others).
    ,
    .options = &.{
        .{ .flags = "-c, --compact-output", .desc = "print each output value on one line, without extra whitespace" },
        .{ .flags = "-r, --raw-output", .desc = "print a string result's raw bytes instead of a quoted JSON string" },
        .{ .flags = "-n, --null-input", .desc = "run FILTER once against null instead of reading any input" },
    },
    .operands = "FILTER is the jq program (required). FILE...   JSON input, concatenated into one stream of values; with none, standard input is read.",
    .exit = &.{
        .{ .code = 0, .when = "success" },
        .{ .code = 2, .when = "usage error (no FILTER, an unrecognized option) or a FILE could not be opened" },
        .{ .code = 3, .when = "FILTER failed to compile" },
        .{ .code = 5, .when = "a JSON parse error in the input, or a runtime error while evaluating FILTER" },
    },
    .deviations_from = "jq 1.7",
    .deviations = &.{
        "No -s/--slurp, -a, -S, -e, --arg/--argjson, --tab/--indent, -j, or -f (no user-defined `def`).",
        "String interpolation (\"\\(expr)\") is not supported; only literal string parts are accepted.",
        "Path expressions and update operators (|=, +=, -=, //=, etc.) are not supported -- only value-producing filters.",
        "try/catch with a handler and the @base64/@csv/@tsv/@html/@uri/@sh/@json format strings are not supported.",
        "A few constructs -- binary-operator operands, object-construction values, array index/slice bounds, and reduce's init/update -- evaluate their sub-expression for a single value (the last one emitted) instead of jq's full Cartesian product over multiple outputs; e.g. `1 + (1,2)` yields one number here, not two.",
        "A runtime error while evaluating FILTER against one input value sets exit 5 but prints no diagnostic (unlike a compile error or a JSON parse error, both of which do); processing continues with the next input value.",
        "Numbers print via a fixed rule -- whole numbers with magnitude < 1e17 print with no decimal point, everything else uses the platform's default float formatting -- which is not guaranteed to byte-match jq's own shortest-round-trip formatter in every edge case.",
    },
    .examples = &.{
        .{ .cmd = "jq '.name' file.json", .note = "pretty-printed, quoted string" },
        .{ .cmd = "jq -r '.items[].id' data.json", .note = "raw (unquoted) ids, one per line" },
        .{ .cmd = "jq -cn '{a: 1, b: [1,2,3]}'", .note = "compact output, no input needed" },
    },
    .see_also = "awk (line/field-oriented processing).",
};

const Sink = struct {
    ctx: *Ctx,
    compact: bool,
    raw: bool,
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn emit(ptr: *anyopaque, v: Value) ev.Error!void {
        const self: *Sink = @ptrCast(@alignCast(ptr));
        const g = self.ctx.gpa;
        const rendered = if (self.compact)
            builtins.renderCompact(g, v, self.raw) catch return ev.Error.OutOfMemory
        else if (self.raw and v == .string)
            (g.dupe(u8, v.string) catch return ev.Error.OutOfMemory)
        else
            builtins.renderPretty(g, v) catch return ev.Error.OutOfMemory;
        self.buf.appendSlice(g, rendered) catch return ev.Error.OutOfMemory;
        self.buf.append(g, '\n') catch return ev.Error.OutOfMemory;
        if (self.buf.items.len >= 1 << 15) self.flush();
    }
    fn flush(self: *Sink) void {
        if (self.buf.items.len != 0) {
            sys.writeAll(self.ctx.stdout, self.buf.items) catch {};
            self.buf.clearRetainingCapacity();
        }
    }
};

pub fn run(ctx: *Ctx) u8 {
    var compact = false;
    var raw = false;
    var null_input = false;
    var filter: ?[]const u8 = null;
    var files: std.ArrayListUnmanaged([]const u8) = .empty;

    var i: usize = 1;
    while (i < ctx.args.len) : (i += 1) {
        const a = ctx.args[i];
        if (std.mem.eql(u8, a, "--help")) {
            cli.renderHelp(ctx, "jq", help_doc);
            return 0;
        } else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--compact-output")) {
            compact = true;
        } else if (std.mem.eql(u8, a, "-r") or std.mem.eql(u8, a, "--raw-output")) {
            raw = true;
        } else if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--null-input")) {
            null_input = true;
        } else if (a.len > 1 and a[0] == '-' and !std.mem.eql(u8, a, "-") and !std.mem.startsWith(u8, a, "-cr") and filter != null) {
            ctx.errPrint("jq: Unknown option {s}\n", .{a});
            return 2;
        } else if (a.len > 1 and a[0] == '-' and !std.mem.eql(u8, a, "-") and filter == null and looksLikeFlags(a)) {
            for (a[1..]) |c| switch (c) {
                'c' => compact = true,
                'r' => raw = true,
                'n' => null_input = true,
                else => {
                    ctx.errPrint("jq: Unknown option -{c}\n", .{c});
                    return 2;
                },
            };
        } else if (filter == null) {
            filter = a;
        } else {
            files.append(ctx.gpa, a) catch return 2;
        }
    }

    const flt = filter orelse {
        ctx.errPrint("jq: no filter given\n", .{});
        return 2;
    };

    var interp = ev.compile(ctx.gpa, flt) catch {
        ctx.errPrint("jq: compile error\n", .{});
        return 3;
    };

    var sink = Sink{ .ctx = ctx, .compact = compact, .raw = raw };
    defer sink.flush();

    if (null_input) {
        interp.eval(.null, &sink, Sink.emit) catch return 5;
        return 0;
    }

    // Read all inputs, parse a stream of JSON values.
    var data: std.ArrayListUnmanaged(u8) = .empty;
    if (files.items.len == 0) {
        const d = textio.readAll(ctx.gpa, sys.STDIN) catch return 2;
        data.appendSlice(ctx.gpa, d) catch return 2;
    } else {
        for (files.items) |f| {
            const fd = sys.open(f, .{ .read = true }) catch {
                ctx.errPrint("jq: {s}: No such file or directory\n", .{f});
                return 2;
            };
            const d = textio.readAll(ctx.gpa, fd) catch return 2;
            sys.close(fd);
            data.appendSlice(ctx.gpa, d) catch return 2;
        }
    }

    var p = JsonParser{ .src = data.items, .gpa = ctx.gpa };
    var rc: u8 = 0;
    while (true) {
        p.skipWs();
        if (p.pos >= p.src.len) break;
        const v = p.parseValue() catch {
            ctx.errPrint("jq: parse error\n", .{});
            return 5;
        };
        interp.eval(v, &sink, Sink.emit) catch {
            rc = 5;
        };
    }
    return rc;
}

fn looksLikeFlags(a: []const u8) bool {
    for (a[1..]) |c| if (c != 'c' and c != 'r' and c != 'n') return false;
    return true;
}

// ---------------------------------------------------------------- JSON parser

const JsonParser = struct {
    src: []const u8,
    pos: usize = 0,
    gpa: std.mem.Allocator,

    const PErr = error{ Json, OutOfMemory };

    fn skipWs(self: *JsonParser) void {
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                else => return,
            }
        }
    }

    fn parseValue(self: *JsonParser) PErr!Value {
        self.skipWs();
        if (self.pos >= self.src.len) return error.Json;
        const c = self.src[self.pos];
        switch (c) {
            '{' => return self.parseObject(),
            '[' => return self.parseArray(),
            '"' => return .{ .string = try self.parseString() },
            't' => {
                try self.expect("true");
                return Value.TRUE;
            },
            'f' => {
                try self.expect("false");
                return Value.FALSE;
            },
            'n' => {
                try self.expect("null");
                return .null;
            },
            else => return self.parseNumber(),
        }
    }

    fn expect(self: *JsonParser, lit: []const u8) PErr!void {
        if (self.pos + lit.len > self.src.len or !std.mem.eql(u8, self.src[self.pos .. self.pos + lit.len], lit)) return error.Json;
        self.pos += lit.len;
    }

    fn parseNumber(self: *JsonParser) PErr!Value {
        const start = self.pos;
        if (self.pos < self.src.len and (self.src[self.pos] == '-' or self.src[self.pos] == '+')) self.pos += 1;
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                '0'...'9', '.', 'e', 'E', '+', '-' => self.pos += 1,
                else => break,
            }
        }
        if (self.pos == start) return error.Json;
        const n = std.fmt.parseFloat(f64, self.src[start..self.pos]) catch return error.Json;
        return .{ .number = n };
    }

    fn parseString(self: *JsonParser) PErr![]const u8 {
        self.pos += 1; // opening quote
        var out: std.ArrayListUnmanaged(u8) = .empty;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '"') {
                self.pos += 1;
                return out.items;
            }
            if (c == '\\' and self.pos + 1 < self.src.len) {
                self.pos += 1;
                const e = self.src[self.pos];
                switch (e) {
                    'n' => try out.append(self.gpa, '\n'),
                    't' => try out.append(self.gpa, '\t'),
                    'r' => try out.append(self.gpa, '\r'),
                    'b' => try out.append(self.gpa, 0x08),
                    'f' => try out.append(self.gpa, 0x0c),
                    '"' => try out.append(self.gpa, '"'),
                    '\\' => try out.append(self.gpa, '\\'),
                    '/' => try out.append(self.gpa, '/'),
                    'u' => {
                        if (self.pos + 4 >= self.src.len) return error.Json;
                        const cp = std.fmt.parseInt(u21, self.src[self.pos + 1 .. self.pos + 5], 16) catch return error.Json;
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &buf) catch 1;
                        try out.appendSlice(self.gpa, buf[0..len]);
                        self.pos += 4;
                    },
                    else => try out.append(self.gpa, e),
                }
                self.pos += 1;
            } else {
                try out.append(self.gpa, c);
                self.pos += 1;
            }
        }
        return error.Json;
    }

    fn parseArray(self: *JsonParser) PErr!Value {
        self.pos += 1; // [
        var items: std.ArrayListUnmanaged(Value) = .empty;
        self.skipWs();
        if (self.pos < self.src.len and self.src[self.pos] == ']') {
            self.pos += 1;
            return .{ .array = items.items };
        }
        while (true) {
            try items.append(self.gpa, try self.parseValue());
            self.skipWs();
            if (self.pos >= self.src.len) return error.Json;
            if (self.src[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            if (self.src[self.pos] == ']') {
                self.pos += 1;
                break;
            }
            return error.Json;
        }
        return .{ .array = items.items };
    }

    fn parseObject(self: *JsonParser) PErr!Value {
        self.pos += 1; // {
        var ob = val.ObjBuilder.init(self.gpa);
        self.skipWs();
        if (self.pos < self.src.len and self.src[self.pos] == '}') {
            self.pos += 1;
            return .{ .object = ob.finish() };
        }
        while (true) {
            self.skipWs();
            if (self.pos >= self.src.len or self.src[self.pos] != '"') return error.Json;
            const key = try self.parseString();
            self.skipWs();
            if (self.pos >= self.src.len or self.src[self.pos] != ':') return error.Json;
            self.pos += 1;
            const value = try self.parseValue();
            ob.set(key, value);
            self.skipWs();
            if (self.pos >= self.src.len) return error.Json;
            if (self.src[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            if (self.src[self.pos] == '}') {
                self.pos += 1;
                break;
            }
            return error.Json;
        }
        return .{ .object = ob.finish() };
    }
};
