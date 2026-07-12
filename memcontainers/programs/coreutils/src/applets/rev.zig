//! `rev` -- DESIGN.md §1: facade-streaming, no real flags. Reverses the
//! **bytes** of each line and re-emits a bare LF (CRLF's trailing `\r` is stripped by
//! `LineReader` and NOT re-inserted). Exit: 0; 1 if a FILE can't open (rest still
//! stream, per `textio.streamLines`).

const std = @import("std");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "rev",
    .help = .{
        .summary = "reverse the bytes of each line",
        .synopsis = &.{"rev [FILE]..."},
        .description =
        \\Reads each FILE (default standard input) and writes each line back
        \\out with its bytes in reverse order, followed by a bare newline. rev
        \\takes no options.
        ,
        .operands = "FILE...   input files; \"-\" means standard input; with no FILE, reads standard input.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "a FILE could not be opened (the remaining files are still processed)" },
            .{ .code = 2, .when = "usage error" },
        },
        .deviations_from = "util-linux rev",
        .deviations = &.{
            "Reverses raw BYTES, not multibyte characters: UTF-8 (or any multibyte) text comes out with its bytes reordered, not its codepoints, unlike locale-aware implementations of rev.",
            "A CRLF line's trailing '\\r' is stripped on read and NOT re-inserted; output always ends in a bare LF.",
        },
        .examples = &.{
            .{ .cmd = "printf 'abc\\n' | rev", .note = "prints: cba" },
            .{ .cmd = "rev file.txt", .note = "reverse every line's bytes" },
        },
        .see_also = "tac (reverses the order of LINES, not the bytes within them).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

fn onLine(out: *textio.BufOut, line: []const u8) anyerror!void {
    var buf: [8192]u8 = undefined;
    const n = line.len;
    if (n <= buf.len) {
        for (line, 0..) |b, i| buf[n - 1 - i] = b;
        try out.line(buf[0..n]);
        return;
    }
    // Defensive fallback: LineReader never returns a chunk longer than its own 8 KiB
    // buffer, so this path is unreachable in practice; reverse byte-by-byte instead of
    // dropping data if that invariant ever changes.
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        try out.push(line[i]);
    }
    try out.endLine();
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };
    var out = textio.BufOut.init(ctx.stdout);
    const rc = textio.streamLines(ctx, "rev", m.positionalSlice(), &out, onLine);
    out.finish() catch {};
    return rc;
}
