//! `fold` -- DESIGN.md §1: facade-streaming, wraps each input line at a
//! column width. `-b/--bytes` counts bytes not columns; `-s/--spaces` breaks at the
//! last blank; `-w/--width WIDTH` (default 80, 0 falls back to 80). Obsolete `-WIDTH`
//! (e.g. `fold -10`) is pre-rewritten to `-w WIDTH`. Column model: TAB -> next multiple
//! of 8, backspace -> col-1 saturating, `\r` -> 0, else +1 (`-b`: every byte is 1 col).
//! Output bare LF. Exit 0/1/2.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "fold",
    .flags = &.{
        cli.flagOpt('b', "bytes", "count bytes rather than columns"),
        cli.flagOpt('s', "spaces", "break at spaces"),
        cli.valueOpt('w', "width", "use WIDTH columns instead of 80"),
    },
    .help = .{
        .summary = "wrap each input line to fit a width",
        .synopsis = &.{"fold [OPTION]... [FILE]..."},
        .description =
        \\Wraps each line of each FILE to fit within a column width (default
        \\80), writing the result to standard output; long lines are broken
        \\with no other reflowing. -b counts bytes instead of display columns;
        \\-s breaks at the last blank (space or tab) before the width limit
        \\instead of splitting a word.
        \\
        \\Column model: a tab advances to the next multiple of 8; a backspace
        \\moves back one column (saturating at 0); a carriage return resets to
        \\column 0; every other byte advances one column (or, under -b, every
        \\byte counts as one column regardless of its value).
        ,
        .operands = "FILE...   input files; \"-\" means standard input; with no FILE, reads standard input.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "a FILE could not be opened" },
            .{ .code = 2, .when = "usage error" },
        },
        .deviations = &.{
            "-w WIDTH accepts only a plain decimal number; a zero or malformed value silently falls back to the default width (80) instead of GNU's `invalid number of columns` error.",
        },
        .examples = &.{
            .{ .cmd = "fold -w 40 report.txt", .note = "wrap at 40 columns" },
            .{ .cmd = "fold -s -w 20 file.txt", .note = "wrap at 20 columns, breaking at word boundaries" },
            .{ .cmd = "fold -100 file.txt", .note = "obsolete form, equivalent to -w 100" },
        },
        .see_also = "fmt (paragraph-aware reflow, instead of fold's blind per-line wrap).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

/// Decimal-only, non-digit (or empty) => 0 (mirrors head's `parse_usize`); callers fall
/// back to 80 when the result is 0.
fn parseWidth(s: []const u8) usize {
    if (s.len == 0) return 0;
    var v: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return 0;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn isObsoleteForm(a: []const u8) bool {
    if (a.len < 2 or a[0] != '-') return false;
    for (a[1..]) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn rewriteObsolete(gpa: std.mem.Allocator, args: []const [:0]const u8) []const [:0]const u8 {
    if (args.len < 2 or !isObsoleteForm(args[1])) return args;
    var out = gpa.alloc([:0]const u8, args.len + 1) catch @panic("OOM");
    out[0] = args[0];
    out[1] = "-w";
    out[2] = gpa.dupeZ(u8, args[1][1..]) catch @panic("OOM");
    @memcpy(out[3..], args[2..]);
    return out;
}

fn computeCol(b: u8, col: usize, bytes_mode: bool) usize {
    if (bytes_mode) return col + 1;
    return switch (b) {
        '\t' => col + (8 - col % 8),
        0x08 => if (col > 0) col - 1 else 0,
        '\r' => 0,
        else => col + 1,
    };
}

const FoldState = struct {
    out: *textio.BufOut,
    gpa: std.mem.Allocator,
    bytes_mode: bool,
    spaces: bool,
    width: usize,
    seg: std.ArrayListUnmanaged(u8) = .empty,
    tmp: std.ArrayListUnmanaged(u8) = .empty,
    col: usize = 0,
};

fn flushHard(st: *FoldState) !void {
    try st.out.line(st.seg.items);
    st.seg.clearRetainingCapacity();
    st.col = 0;
}

fn flushAtBlank(st: *FoldState) !void {
    var k: ?usize = null;
    var idx: usize = st.seg.items.len;
    while (idx > 0) {
        idx -= 1;
        if (st.seg.items[idx] == ' ' or st.seg.items[idx] == '\t') {
            k = idx;
            break;
        }
    }
    const found = k orelse {
        try flushHard(st);
        return;
    };
    try st.out.line(st.seg.items[0 .. found + 1]);
    st.tmp.clearRetainingCapacity();
    st.tmp.appendSlice(st.gpa, st.seg.items[found + 1 ..]) catch return error.ENOMEM;
    st.seg.clearRetainingCapacity();
    st.col = 0;
    for (st.tmp.items) |c| {
        const nc = computeCol(c, st.col, st.bytes_mode);
        st.seg.append(st.gpa, c) catch return error.ENOMEM;
        st.col = nc;
    }
}

fn onLine(st: *FoldState, line: []const u8) anyerror!void {
    st.seg.clearRetainingCapacity();
    st.col = 0;
    for (line) |b| {
        const newcol = computeCol(b, st.col, st.bytes_mode);
        if (newcol > st.width and st.seg.items.len > 0) {
            if (st.spaces) {
                try flushAtBlank(st);
            } else {
                try flushHard(st);
            }
            const nc2 = computeCol(b, st.col, st.bytes_mode);
            st.seg.append(st.gpa, b) catch return error.ENOMEM;
            st.col = nc2;
        } else {
            st.seg.append(st.gpa, b) catch return error.ENOMEM;
            st.col = newcol;
        }
    }
    try st.out.line(st.seg.items);
}

pub fn run(ctx: *Ctx) u8 {
    const args = rewriteObsolete(ctx.gpa, ctx.args);
    var ctx2 = ctx.*;
    ctx2.args = args;
    const res = cli.parse(&ctx2, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    var width: usize = 80;
    if (m.value("width")) |v| {
        width = parseWidth(v);
        if (width == 0) width = 80;
    }

    var out = textio.BufOut.init(ctx.stdout);
    var st = FoldState{
        .out = &out,
        .gpa = ctx.gpa,
        .bytes_mode = m.has("bytes"),
        .spaces = m.has("spaces"),
        .width = width,
    };
    const rc = textio.streamLines(ctx, "fold", m.positionalSlice(), &st, onLine);
    out.finish() catch {};
    return rc;
}
