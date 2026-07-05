//! `basename` -- docs/analysis/applets-a-f.md: pure string computation, tier_isolated.
//! `-a`/`--multiple` (every operand is a NAME), `-s`/`--suffix=SUFFIX` (implies -a),
//! `-z`/`--zero`. Single-arg mode: positional[0] is NAME, positional[1] (if present)
//! is an ad-hoc SUFFIX (classic two-operand `basename NAME SUFFIX` form). Byte-exact.

const std = @import("std");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "basename",
    .version = "0.1.0",
    .flags = &.{
        cli.flagOpt('a', "multiple", "support multiple arguments and treat each as a NAME"),
        cli.valueOpt('s', "suffix", "remove a trailing SUFFIX; implies -a"),
        cli.flagOpt('z', "zero", "end each output line with NUL, not newline"),
    },
    .positionals = .{ .name = "NAME", .min = 1, .max = null },
    .help = .{
        .summary = "strip directory and suffix from file names",
        .synopsis = &.{
            "basename NAME [SUFFIX]",
            "basename OPTION... NAME...",
        },
        .description =
        \\Prints NAME with any leading directory components removed, i.e. the final
        \\'/'-separated component. In the default two-operand form, a second operand
        \\is a literal SUFFIX stripped from the result if it is a proper, non-empty
        \\suffix (never stripped if it equals the whole name). -a/--multiple
        \\(implied by -s) instead treats every operand as a NAME. Pure string
        \\computation; the filesystem is never touched.
        ,
        .operands = "NAME...   one or more paths. In the default (non -a/-s) form, at most two operands are accepted: NAME and an optional literal SUFFIX.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "the default (non -a/-s) form was given more than two operands" },
            .{ .code = 2, .when = "usage error: no NAME operand" },
        },
        .examples = &.{
            .{ .cmd = "basename /usr/bin/sort", .note = "prints: sort" },
            .{ .cmd = "basename include/stdio.h .h", .note = "prints: stdio" },
            .{ .cmd = "basename -a -s .txt a.txt b.txt", .note = "prints: a, then b" },
        },
        .see_also = "dirname (the complementary directory portion), realpath.",
    },
};

/// Strip trailing '/' (keep a single '/'), take the component after the last '/'.
fn baseOf(path: []const u8) []const u8 {
    if (path.len == 0) return "";
    var s = path;
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (std.mem.eql(u8, s, "/")) return "/";
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |idx| return s[idx + 1 ..];
    return s;
}

/// Remove suffix only if non-empty, strictly shorter than the name, and a proper
/// suffix (POSIX: never strip when suffix == whole name).
fn stripSuffix(name: []const u8, suf: []const u8) []const u8 {
    if (suf.len == 0) return name;
    if (name.len > suf.len and std.mem.endsWith(u8, name, suf)) return name[0 .. name.len - suf.len];
    return name;
}

fn emitOne(ctx: *Ctx, name: []const u8, suf: []const u8, zero: bool) void {
    const result = stripSuffix(baseOf(name), suf);
    ctx.outWrite(result) catch return;
    ctx.outWrite(if (zero) "\x00" else "\n") catch return;
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };
    const suffix = m.value("suffix");
    const multiple = m.has("multiple") or suffix != null;
    const zero = m.has("zero");
    const names = m.positionalSlice();

    if (multiple) {
        for (names) |n| emitOne(ctx, n, suffix orelse "", zero);
        return 0;
    }

    if (names.len > 2) {
        ctx.errPrint("basename: extra operand '{s}'\n", .{names[2]});
        return 1;
    }
    const suf = if (names.len > 1) names[1] else "";
    emitOne(ctx, names[0], suf, zero);
    return 0;
}
