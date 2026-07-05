//! `tee` -- docs/analysis/applets-s-z.md: `-a/--append`, `FILE...` (0+). Opens each FILE
//! `write|create|(append|trunc)`; an open failure prints `tee: {f}: {strerror}`, sets
//! rc=1, but tee CONTINUES with the rest. Reads stdin 8 KiB at a time and `writeAll`s
//! each chunk to stdout AND to every successfully-opened fd, best-effort (write errors
//! on any single fd -- including stdout -- are silently ignored, the loop keeps going
//! until stdin is exhausted). No `-i`, no `-p`.

const std = @import("std");
const cli = @import("../core/cli.zig");
const sys = @import("../sys/root.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "tee",
    .flags = &.{
        cli.flagOpt('a', "append", "append to the given FILEs, do not overwrite"),
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
    .help = .{
        .summary = "copy standard input to standard output and to files",
        .synopsis = &.{"tee [-a] [FILE]..."},
        .description =
        \\Reads standard input in 8 KiB chunks and writes each chunk to standard
        \\output and to every listed FILE, so a pipeline can be observed at an
        \\intermediate stage without losing the data flowing through it. Every FILE is
        \\opened up front (truncating it first, unless -a is given); a FILE that fails
        \\to open is reported and skipped, but tee still copies to standard output and
        \\to the remaining FILEs. Once running, per-write errors on any single
        \\destination -- including standard output -- are silently ignored and do not
        \\stop the copy to the others.
        ,
        .operands = "FILE...   destinations to also write to, in addition to standard output; with no FILE, tee simply relays standard input to standard output.",
        .exit = &.{
            .{ .code = 0, .when = "every listed FILE was opened successfully (write errors during the copy are not reflected in the exit status)" },
            .{ .code = 1, .when = "at least one FILE could not be opened" },
        },
        .deviations = &.{
            "No -i/--ignore-interrupts and no -p/--output-error[=MODE]: signal handling and output-error policy are not implemented; a write error on any destination is always ignored silently and the copy continues.",
        },
        .examples = &.{
            .{ .cmd = "generate_data | tee /tmp/raw.log | analyze", .note = "saves the untouched stream to /tmp/raw.log while still piping it onward" },
            .{ .cmd = "printf 'a\\nb\\n' | tee -a out.txt >/dev/null", .note = "appends \"a\\nb\\n\" to out.txt instead of truncating it" },
        },
        .see_also = "cat (no fan-out), pipe redirection `>`/`>>` (no simultaneous stdout copy).",
    },
};

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };
    const append = m.has("append");
    const files = m.positionalSlice();

    var fds: std.ArrayListUnmanaged(sys.Fd) = .empty;
    var rc: u8 = 0;
    for (files) |f| {
        const open_flags: sys.O = if (append)
            .{ .write = true, .create = true, .append = true }
        else
            .{ .write = true, .create = true, .trunc = true };
        const fd = sys.open(f, open_flags) catch |e| {
            ctx.errPrint("tee: {s}: {s}\n", .{ f, sys.strerror(sys.toErrno(e)) });
            rc = 1;
            continue;
        };
        fds.append(ctx.gpa, fd) catch @panic("OOM");
    }
    defer for (fds.items) |fd| sys.close(fd);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = sys.read(ctx.stdin, &buf) catch break;
        if (n == 0) break;
        const chunk = buf[0..n];
        sys.writeAll(ctx.stdout, chunk) catch {};
        for (fds.items) |fd| sys.writeAll(fd, chunk) catch {};
    }
    return rc;
}
