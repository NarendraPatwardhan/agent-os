//! `nl` -- DESIGN.md §1: facade-streaming (`stream_lines` + `BufOut`).
//! `-b STYLE` (a/t=default/n), `-n FORMAT` (ln/rn=default/rz), `-w NUMBER` width
//! (default 6, must be >0), `-s STRING` separator (default TAB), `-v NUMBER` start
//! (default 1), `-i NUMBER` increment (default 1). The counter continues ACROSS
//! operands. Numbered lines: formatted number + sep. Unnumbered lines: width blanks +
//! sep (GNU-style blank field). Output bare LF. Exit 0/1/2.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "nl",
    .flags = &.{
        cli.valueOpt('b', "body-numbering", "which lines to number (a/t/n)"),
        cli.valueOpt('n', "number-format", "number format (ln/rn/rz)"),
        cli.valueOpt('w', "number-width", "line number field width"),
        cli.valueOpt('s', "number-separator", "separator between number and text"),
        cli.valueOpt('v', "starting-line-number", "starting line number"),
        cli.valueOpt('i', "line-increment", "line number increment"),
    },
    .help = .{
        .summary = "number lines of files",
        .synopsis = &.{"nl [OPTION]... [FILE]..."},
        .description =
        \\Numbers the lines of each FILE and writes them to standard output. -b
        \\selects which lines are numbered: `a` numbers every line, `t` (the
        \\default) numbers only non-empty lines, `n` numbers none. -n selects
        \\the number format: `ln` left-justified, `rn` (the default)
        \\right-justified, `rz` zero-padded. -w sets the number field's width
        \\(default 6); -s sets the separator between the number and the line
        \\(default TAB).
        \\
        \\-v sets the starting number (default 1) and -i the increment (default
        \\1); the counter is NOT reset between FILE operands -- it continues
        \\across all of them.
        ,
        .operands = "FILE...   input files; \"-\" means standard input; with no FILE, reads standard input.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "an invalid -b/-n style, a non-positive -w, or a FILE could not be processed" },
            .{ .code = 2, .when = "usage error" },
        },
        .deviations = &.{
            "No logical page/section model: no `\\:`/`\\:\\:`/`\\:\\:\\:` header-body-footer delimiter syntax, no -p (don't reset numbering on new page), and no -l (blank-line grouping).",
        },
        .examples = &.{
            .{ .cmd = "nl file.txt", .note = "number non-empty lines, TAB-separated" },
            .{ .cmd = "nl -ba -i2 -v10 file.txt", .note = "number every line, starting at 10, incrementing by 2" },
            .{ .cmd = "nl -n rz -w4 file.txt", .note = "zero-padded 4-digit numbers" },
        },
        .see_also = "cat -n (simpler whole-file numbering, no section model).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

const Style = enum { all, nonempty, none };
const NumFmt = enum { ln, rn, rz };

/// Signed decimal, optional leading `+`/`-`. `null` on any non-digit or empty input.
fn parseI64(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var i: usize = 0;
    var neg = false;
    if (s[0] == '+' or s[0] == '-') {
        neg = s[0] == '-';
        i = 1;
    }
    if (i >= s.len) return null;
    var v: i64 = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return if (neg) -v else v;
}

fn parseUsizePositive(s: []const u8) ?usize {
    const v = parseI64(s) orelse return null;
    if (v <= 0) return null;
    return @intCast(v);
}

fn writeRepeated(out: *textio.BufOut, byte: u8, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try out.push(byte);
}

/// Renders `val` as decimal (with sign) into `buf`, returns the written slice.
fn renderNumber(buf: []u8, val: i64) []const u8 {
    var v128: i128 = val;
    var neg = false;
    if (v128 < 0) {
        neg = true;
        v128 = -v128;
    }
    var digits: [20]u8 = undefined;
    var len: usize = 0;
    if (v128 == 0) {
        digits[0] = '0';
        len = 1;
    } else {
        while (v128 != 0) {
            digits[len] = '0' + @as(u8, @intCast(@mod(v128, 10)));
            v128 = @divTrunc(v128, 10);
            len += 1;
        }
    }
    var off: usize = 0;
    if (neg) {
        buf[0] = '-';
        off = 1;
    }
    for (0..len) |k| buf[off + k] = digits[len - 1 - k];
    return buf[0 .. off + len];
}

fn formatField(out: *textio.BufOut, width: usize, fmt: NumFmt, val: i64) !void {
    var numbuf: [24]u8 = undefined;
    const s = renderNumber(&numbuf, val);
    if (s.len >= width) {
        try out.extend(s);
        return;
    }
    const pad = width - s.len;
    switch (fmt) {
        .ln => {
            try out.extend(s);
            try writeRepeated(out, ' ', pad);
        },
        .rn => {
            try writeRepeated(out, ' ', pad);
            try out.extend(s);
        },
        .rz => {
            if (s.len > 0 and s[0] == '-') {
                try out.push('-');
                try writeRepeated(out, '0', pad);
                try out.extend(s[1..]);
            } else {
                try writeRepeated(out, '0', pad);
                try out.extend(s);
            }
        },
    }
}

const NlState = struct {
    out: *textio.BufOut,
    style: Style,
    fmt: NumFmt,
    width: usize,
    sep: []const u8,
    incr: i64,
    counter: i64,
};

fn onLine(st: *NlState, line: []const u8) anyerror!void {
    const numbered = switch (st.style) {
        .all => true,
        .nonempty => line.len != 0,
        .none => false,
    };
    if (numbered) {
        try formatField(st.out, st.width, st.fmt, st.counter);
        st.counter += st.incr;
    } else {
        try writeRepeated(st.out, ' ', st.width);
    }
    try st.out.extend(st.sep);
    try st.out.line(line);
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    var style: Style = .nonempty;
    if (m.value("body-numbering")) |v| {
        if (std.mem.eql(u8, v, "a")) {
            style = .all;
        } else if (std.mem.eql(u8, v, "t")) {
            style = .nonempty;
        } else if (std.mem.eql(u8, v, "n")) {
            style = .none;
        } else {
            ctx.errPrint("nl: invalid body numbering style: '{s}'\n", .{v});
            return 1;
        }
    }

    var fmt: NumFmt = .rn;
    if (m.value("number-format")) |v| {
        if (std.mem.eql(u8, v, "ln")) {
            fmt = .ln;
        } else if (std.mem.eql(u8, v, "rn")) {
            fmt = .rn;
        } else if (std.mem.eql(u8, v, "rz")) {
            fmt = .rz;
        } else {
            ctx.errPrint("nl: invalid line numbering format: '{s}'\n", .{v});
            return 1;
        }
    }

    var width: usize = 6;
    if (m.value("number-width")) |v| {
        width = parseUsizePositive(v) orelse {
            ctx.errPrint("nl: invalid line number field width: '{s}'\n", .{v});
            return 1;
        };
    }

    var sep: []const u8 = "\t";
    if (m.value("number-separator")) |v| sep = v;

    var start: i64 = 1;
    if (m.value("starting-line-number")) |v| {
        start = parseI64(v) orelse {
            ctx.errPrint("nl: invalid starting line number: '{s}'\n", .{v});
            return 1;
        };
    }

    var incr: i64 = 1;
    if (m.value("line-increment")) |v| {
        incr = parseI64(v) orelse {
            ctx.errPrint("nl: invalid line increment: '{s}'\n", .{v});
            return 1;
        };
    }

    var out = textio.BufOut.init(ctx.stdout);
    var st = NlState{ .out = &out, .style = style, .fmt = fmt, .width = width, .sep = sep, .incr = incr, .counter = start };
    const rc = textio.streamLines(ctx, "nl", m.positionalSlice(), &st, onLine);
    out.finish() catch {};
    return rc;
}
