//! `dirname` -- docs/analysis/applets-a-f.md: pure string computation, tier_isolated.
//! `-z`/`--zero`. `dir()`: strip trailing '/' (keep single), find last '/': none→".",
//! at index 0→"/", else drop the leaf and collapse the parent's trailing slashes.

const std = @import("std");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "dirname",
    .version = "0.1.0",
    .flags = &.{cli.flagOpt('z', "zero", "end each output line with NUL, not newline")},
    .positionals = .{ .name = "NAME", .min = 1, .max = null },
    .help = .{
        .summary = "strip last component from file name",
        .synopsis = &.{"dirname NAME..."},
        .description =
        \\Prints each NAME with its last '/'-separated component removed. Trailing
        \\slashes are stripped first (a lone "/" is preserved); if no '/' remains
        \\in what's left, the result is ".". Pure string computation; the
        \\filesystem is never touched.
        ,
        .operands = "NAME...   one or more paths.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 2, .when = "usage error: no NAME operand" },
        },
        .examples = &.{
            .{ .cmd = "dirname /usr/bin/", .note = "prints: /usr" },
            .{ .cmd = "dirname stdio.h", .note = "prints: ." },
            .{ .cmd = "dirname /usr/bin//gcc", .note = "prints: /usr/bin" },
        },
        .see_also = "basename (the complementary final component), realpath.",
    },
};

fn dirOf(path: []const u8) []const u8 {
    var s = path;
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    const idx = std.mem.lastIndexOfScalar(u8, s, '/') orelse return ".";
    var parent = s[0..idx];
    while (parent.len > 1 and parent[parent.len - 1] == '/') parent = parent[0 .. parent.len - 1];
    if (parent.len == 0) return "/";
    return parent;
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };
    const sep: []const u8 = if (m.has("zero")) "\x00" else "\n";
    for (m.positionalSlice()) |n| {
        ctx.outWrite(dirOf(n)) catch return 0;
        ctx.outWrite(sep) catch return 0;
    }
    return 0;
}
