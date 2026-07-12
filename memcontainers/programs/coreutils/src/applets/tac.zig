//! `tac` -- DESIGN.md §1: operands processed in REVERSE order, each
//! file's lines reversed. Seekable operands are read whole then split/reversed
//! in-memory; stdin (or any non-seekable fd, probed via `sys.lseek`) is spilled to a
//! `SpoolFile` first (in-memory fallback if `/scratch` is unavailable). One trailing
//! `\n` of the file does not create an empty line. Errors `tac: <op>: <strerror>`,
//! exit 1; usage 2.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const spool = @import("../core/spool.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "tac",
    .help = .{
        .summary = "concatenate and print files in reverse",
        .synopsis = &.{"tac [FILE]..."},
        .description =
        \\Writes each FILE to standard output with the order of its lines
        \\reversed (the last line first). FILE operands are themselves also
        \\processed in reverse order, so `tac a b` prints all of b's lines
        \\reversed, then all of a's. With no FILE, reads standard input.
        \\
        \\Seekable files are read and reversed directly in memory; standard
        \\input (or any other non-seekable source) is first spilled to a
        \\temporary spool file so it can still be read back to front.
        ,
        .operands = "FILE...   input files; \"-\" means standard input; with no FILE, reads standard input.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "a FILE could not be opened or read (the remaining operands are still processed)" },
            .{ .code = 2, .when = "usage error" },
        },
        .deviations = &.{
            "No -b/-r/-s (custom record/regex separators) -- tac only reverses whole newline-terminated lines.",
        },
        .examples = &.{
            .{ .cmd = "tac log.txt", .note = "print log.txt with its lines in reverse order" },
            .{ .cmd = "tac a.txt b.txt", .note = "print all of b.txt reversed, then all of a.txt reversed" },
            .{ .cmd = "printf 'x\\ny\\nz' | tac", .note = "prints z, y, x (a missing final newline doesn't add a blank line)" },
        },
        .see_also = "rev (reverses the bytes within each line, not the order of lines).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

fn isSeekable(fd: sys.Fd) bool {
    _ = sys.lseek(fd, 0, .end) catch return false;
    return true;
}

fn spillThenRead(ctx: *Ctx, fd: sys.Fd) sys.Error![]u8 {
    if (spool.SpoolFile.create()) |sf0| {
        var sf = sf0;
        defer sf.deinit();
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try sys.read(fd, &buf);
            if (n == 0) break;
            try sf.writeAll(buf[0..n]);
        }
        try sf.rewind();
        return textio.readAll(ctx.gpa, sf.fd());
    }
    return textio.readAll(ctx.gpa, fd);
}

fn emitReversed(gpa: std.mem.Allocator, out: *textio.BufOut, data: []const u8) !void {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == '\n') {
            lines.append(gpa, data[start..i]) catch return error.ENOMEM;
            start = i + 1;
        }
    }
    if (start < data.len) {
        lines.append(gpa, data[start..]) catch return error.ENOMEM;
    }
    var idx = lines.items.len;
    while (idx > 0) {
        idx -= 1;
        var line = lines.items[idx];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        try out.line(line);
    }
}

fn processOperand(ctx: *Ctx, out: *textio.BufOut, fd: sys.Fd) sys.Error!void {
    var data: []u8 = undefined;
    if (isSeekable(fd)) {
        _ = sys.lseek(fd, 0, .set) catch {};
        data = try textio.readAll(ctx.gpa, fd);
    } else {
        data = try spillThenRead(ctx, fd);
    }
    emitReversed(ctx.gpa, out, data) catch return error.ENOMEM;
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    var files_buf: [256][]const u8 = undefined;
    var n: usize = 0;
    for (m.positionalSlice()) |f| {
        if (n < files_buf.len) {
            files_buf[n] = f;
            n += 1;
        }
    }
    const files = files_buf[0..n];

    var out = textio.BufOut.init(ctx.stdout);
    var rc: u8 = 0;

    if (files.len == 0) {
        processOperand(ctx, &out, ctx.stdin) catch |e| {
            ctx.errPrint("tac: -: {s}\n", .{sys.strerror(sys.toErrno(e))});
            rc = 1;
        };
        out.finish() catch {};
        return rc;
    }

    var idx = files.len;
    while (idx > 0) {
        idx -= 1;
        const file = files[idx];
        const is_stdin = std.mem.eql(u8, file, "-");
        const fd = if (is_stdin) ctx.stdin else sys.open(file, .{ .read = true }) catch |e| {
            ctx.errPrint("tac: {s}: {s}\n", .{ file, sys.strerror(sys.toErrno(e)) });
            rc = 1;
            continue;
        };
        defer if (!is_stdin) sys.close(fd);
        processOperand(ctx, &out, fd) catch |e| {
            ctx.errPrint("tac: {s}: {s}\n", .{ file, sys.strerror(sys.toErrno(e)) });
            rc = 1;
        };
    }
    out.finish() catch {};
    return rc;
}
