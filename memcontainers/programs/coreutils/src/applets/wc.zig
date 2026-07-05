//! `wc` -- docs/analysis/applets-s-z.md: single-pass streaming counter (4 KiB reads).
//! `-l/--lines -w/--words -m/--chars -c/--bytes -L/--max-line-length`; default = l w c.
//! Print order is ALWAYS l w m c L (only selected fields), space-separated, UNPADDED
//! (a deliberate GNU deviation), filename appended when named. Multi-file `total` row.
//! Errors `wc: {f}: {strerror}` exit 1; usage 2.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "wc",
    .flags = &.{
        cli.flagOpt('l', "lines", "print the newline counts"),
        cli.flagOpt('w', "words", "print the word counts"),
        cli.flagOpt('m', "chars", "print the character counts"),
        cli.flagOpt('c', "bytes", "print the byte counts"),
        cli.flagOpt('L', "max-line-length", "print the maximum display width"),
    },
    .help = .{
        .summary = "print newline, word, and byte counts for files",
        .synopsis = &.{"wc [OPTION]... [FILE]..."},
        .description =
        \\Counts newlines, words, characters, bytes, and/or the longest display
        \\line in each FILE (default standard input) in a single streaming pass,
        \\and prints the selected counts. With no selection flag, prints
        \\newlines, words, and bytes. Selected fields always print in the fixed
        \\order lines, words, chars, bytes, max-line-length -- regardless of the
        \\order the flags were given -- followed by the filename when one was
        \\named.
        \\
        \\With more than one FILE, a final "total" line sums every selected
        \\count across all of them.
        ,
        .operands = "FILE...   input files; \"-\" means standard input; with no FILE, reads standard input.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "a FILE could not be opened or read (errors are reported per file; the remaining files are still processed)" },
            .{ .code = 2, .when = "usage error" },
        },
        .deviations = &.{
            "Counts are printed space-separated and unpadded, not right-justified in GNU's fixed-width columns.",
        },
        .examples = &.{
            .{ .cmd = "wc file.txt", .note = "lines, words, and bytes" },
            .{ .cmd = "wc -l *.txt", .note = "line counts only, with a total row across files" },
            .{ .cmd = "wc -L file.txt", .note = "the longest display line (tabs advance to the next multiple of 8)" },
        },
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

const Sel = struct {
    lines: bool = false,
    words: bool = false,
    chars: bool = false,
    bytes: bool = false,
    max_line: bool = false,

    fn any(s: Sel) bool {
        return s.lines or s.words or s.chars or s.bytes or s.max_line;
    }
};

const Counts = struct {
    lines: u64 = 0,
    words: u64 = 0,
    chars: u64 = 0,
    bytes: u64 = 0,
    max_line: u64 = 0,

    fn add(a: *Counts, b: Counts) void {
        a.lines += b.lines;
        a.words += b.words;
        a.chars += b.chars;
        a.bytes += b.bytes;
        if (b.max_line > a.max_line) a.max_line = b.max_line;
    }
};

fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or (b >= 0x0b and b <= 0x0d);
}

fn countFd(fd: sys.Fd) sys.Error!Counts {
    var c = Counts{};
    var in_word = false;
    var col: u64 = 0;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try sys.read(fd, &buf);
        if (n == 0) break;
        c.bytes += n;
        for (buf[0..n]) |b| {
            if ((b & 0xC0) != 0x80) c.chars += 1;
            if (b == '\n') {
                c.lines += 1;
                if (col > c.max_line) c.max_line = col;
                col = 0;
            } else if (b == '\t') {
                col += 8 - (col % 8);
            } else if (b == '\r') {
                col = 0;
            } else {
                col += 1;
            }
            if (isSpace(b)) {
                in_word = false;
            } else if (!in_word) {
                c.words += 1;
                in_word = true;
            }
        }
    }
    if (col > c.max_line) c.max_line = col;
    return c;
}

fn printCounts(ctx: *Ctx, c: Counts, sel: Sel, name: ?[]const u8) void {
    var first = true;
    if (sel.lines) printNum(ctx, &first, c.lines);
    if (sel.words) printNum(ctx, &first, c.words);
    if (sel.chars) printNum(ctx, &first, c.chars);
    if (sel.bytes) printNum(ctx, &first, c.bytes);
    if (sel.max_line) printNum(ctx, &first, c.max_line);
    if (name) |nm| ctx.outPrint(" {s}", .{nm});
    ctx.outPrint("\n", .{});
}

fn printNum(ctx: *Ctx, first: *bool, v: u64) void {
    if (!first.*) ctx.outPrint(" ", .{});
    ctx.outPrint("{d}", .{v});
    first.* = false;
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    var sel = Sel{
        .lines = m.has("lines"),
        .words = m.has("words"),
        .chars = m.has("chars"),
        .bytes = m.has("bytes"),
        .max_line = m.has("max-line-length"),
    };
    if (!sel.any()) sel = .{ .lines = true, .words = true, .bytes = true };

    var files_buf: [256][]const u8 = undefined;
    var file_count: usize = 0;
    for (m.positionalSlice()) |f| {
        if (file_count < files_buf.len) {
            files_buf[file_count] = f;
            file_count += 1;
        }
    }
    const files = files_buf[0..file_count];

    if (files.len == 0) {
        const c = countFd(ctx.stdin) catch |e| {
            ctx.errPrint("wc: -: {s}\n", .{sys.strerror(sys.toErrno(e))});
            return 1;
        };
        printCounts(ctx, c, sel, null);
        return 0;
    }

    var rc: u8 = 0;
    var total = Counts{};
    var any_ok = false;
    for (files) |file| {
        const is_stdin = std.mem.eql(u8, file, "-");
        const fd = if (is_stdin) ctx.stdin else sys.open(file, .{ .read = true }) catch |e| {
            ctx.errPrint("wc: {s}: {s}\n", .{ file, sys.strerror(sys.toErrno(e)) });
            rc = 1;
            continue;
        };
        defer if (!is_stdin) sys.close(fd);
        const c = countFd(fd) catch |e| {
            ctx.errPrint("wc: {s}: {s}\n", .{ file, sys.strerror(sys.toErrno(e)) });
            rc = 1;
            continue;
        };
        printCounts(ctx, c, sel, file);
        total.add(c);
        any_ok = true;
    }
    if (files.len > 1 and any_ok) {
        printCounts(ctx, total, sel, "total");
    }
    return rc;
}
