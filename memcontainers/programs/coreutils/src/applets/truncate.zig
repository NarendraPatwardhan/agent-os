//! `truncate` -- DESIGN.md §1: `-s/--size SIZE` (required; digits +
//! optional `K/M/G` 1024-based suffix, absolute only -- no `+ - < > / %`), `FILE...`
//! (1+). Each file is opened `write|create` then `sys.ftruncate`d. Missing `-s` or
//! missing FILE operand -> exit 1. No `-c/-o/-r`.

const std = @import("std");
const cli = @import("../core/cli.zig");
const sys = @import("../sys/root.zig");
const sizes = @import("../core/sizes.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "truncate",
    .flags = &.{
        cli.valueOpt('s', "size", "set or adjust the file size to SIZE"),
    },
    .help = .{
        .summary = "shrink or extend the size of files",
        .synopsis = &.{"truncate -s SIZE FILE..."},
        .description =
        \\Sets the size of each FILE to SIZE, growing it with NUL bytes or discarding
        \\data past SIZE as needed. Each FILE is opened -- creating it if it does not
        \\exist -- then resized with ftruncate(2). -s/--size SIZE is required.
        ,
        .operands = "FILE...  one or more files to resize (created if missing).",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "missing -s, missing FILE operand, an invalid SIZE, or an open/ftruncate error" },
            .{ .code = 2, .when = "usage error (unrecognized option or missing option value)" },
        },
        .deviations = &.{
            "SIZE is an absolute value only: digits with an optional K/M/G (1024-based) suffix. GNU's relative forms (+, -, <, >, /, %) are not supported.",
            "No -c/--no-create (a missing FILE is always created), -o/--io-blocks, or -r/--reference=RFILE.",
        },
        .examples = &.{
            .{ .cmd = "truncate -s 0 file.log", .note = "empties the file" },
            .{ .cmd = "truncate -s 1M sparse.img", .note = "grows to exactly 1024*1024 bytes; the gap reads as NUL bytes" },
            .{ .cmd = "truncate -s 10 newfile", .note = "FILE is created if missing (no -c to opt out)" },
        },
        .see_also = "dd (rewrite content), stat (inspect size).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

/// Digits + optional trailing `K`/`M`/`G` (1024-based, uppercase only). No sign, no `b`.
fn parseSize(s: []const u8) ?u64 {
    return sizes.parse(s, .{ .base = 1024, .case_insensitive = false, .allow_b = false });
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    const size_str = m.value("size") orelse {
        ctx.errPrint("truncate: missing -s\n", .{});
        return 1;
    };
    const size = parseSize(size_str) orelse {
        ctx.errPrint("truncate: invalid size: '{s}'\n", .{size_str});
        return 1;
    };

    const files = m.positionalSlice();
    if (files.len == 0) {
        ctx.errPrint("truncate: missing operand\n", .{});
        return 1;
    }

    var rc: u8 = 0;
    for (files) |f| {
        const fd = sys.open(f, .{ .write = true, .create = true }) catch |e| {
            ctx.errPrint("truncate: {s}: {s}\n", .{ f, sys.strerror(sys.toErrno(e)) });
            rc = 1;
            continue;
        };
        defer sys.close(fd);
        sys.ftruncate(fd, size) catch |e| {
            ctx.errPrint("truncate: {s}: {s}\n", .{ f, sys.strerror(sys.toErrno(e)) });
            rc = 1;
        };
    }
    return rc;
}
