//! `mkdir` -- docs/analysis/applets-g-r.md: `fsutil::mkdirP` + `sys.mkdir`/`sys.chmod`.
//! `-p/--parents`, `-m/--mode MODE` (octal only, masked `&0o7777`, applied to the
//! FINAL component only via chmod after creation). No symbolic modes, no `-v`.

const std = @import("std");
const cli = @import("../core/cli.zig");
const fsutil = @import("../core/fsutil.zig");
const sys = @import("../sys/root.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "mkdir",
    .flags = &.{
        cli.flagOpt('p', "parents", "make parent directories as needed"),
        cli.valueOpt('m', "mode", "set the mode of created directories (octal)"),
    },
    .help = .{
        .summary = "create directories",
        .synopsis = &.{"mkdir [OPTION]... DIRECTORY..."},
        .description =
        \\Creates each DIRECTORY. Without -p, a DIRECTORY whose parent does not yet
        \\exist is an error, and an already-existing DIRECTORY is also an error; -p
        \\creates missing parents as needed and silently accepts a DIRECTORY that
        \\already exists. -m MODE sets the permission bits of each DIRECTORY's final
        \\path component via chmod after creation -- with -p, only the last, named
        \\directory gets MODE, not any parents created along the way.
        ,
        .operands = "DIRECTORY...  one or more paths to create.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "missing operand, an invalid -m MODE, or a mkdir/chmod error (including an already-existing DIRECTORY without -p)" },
            .{ .code = 2, .when = "usage error (unrecognized option or missing option value)" },
        },
        .deviations = &.{
            "-m MODE is octal only; symbolic modes (e.g. u+rwx) are not accepted.",
            "No -v/--verbose.",
        },
        .examples = &.{
            .{ .cmd = "mkdir -p a/b/c", .note = "creates missing parents; an existing DIRECTORY is not an error under -p" },
            .{ .cmd = "mkdir -m 0700 private", .note = "MODE applies to the final directory only, not to parents created by -p" },
        },
        .see_also = "rmdir, chmod.",
    },
    .positionals = .{ .name = "DIRECTORY", .min = 0, .max = null },
};

/// Octal-only, masked to `0o7777`. `null` on empty or any non-octal-digit byte.
fn parseOctalMode(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '7') return null;
        v = v * 8 + (c - '0');
    }
    return v & 0o7777;
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };
    const dirs = m.positionalSlice();
    if (dirs.len == 0) {
        ctx.errPrint("mkdir: missing operand\n", .{});
        return 1;
    }

    var mode: ?u32 = null;
    if (m.value("mode")) |spec_str| {
        mode = parseOctalMode(spec_str) orelse {
            ctx.errPrint("mkdir: invalid mode: {s}\n", .{spec_str});
            return 1;
        };
    }
    const parents = m.has("parents");

    var rc: u8 = 0;
    for (dirs) |dir| {
        if (parents) {
            fsutil.mkdirP(dir) catch |e| {
                ctx.errPrint("mkdir: {s}: {s}\n", .{ dir, sys.strerror(sys.toErrno(e)) });
                rc = 1;
                continue;
            };
        } else {
            sys.mkdir(dir) catch |e| {
                ctx.errPrint("mkdir: {s}: {s}\n", .{ dir, sys.strerror(sys.toErrno(e)) });
                rc = 1;
                continue;
            };
        }
        if (mode) |mo| {
            sys.chmod(dir, mo) catch |e| {
                ctx.errPrint("mkdir: {s}: {s}\n", .{ dir, sys.strerror(sys.toErrno(e)) });
                rc = 1;
            };
        }
    }
    return rc;
}
