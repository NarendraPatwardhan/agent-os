//! `sleep` -- DESIGN.md §1: `DURATION...` (1+, summed). Each operand is
//! `[digits][.frac][s|m|h|d]` (default unit `s`); the fractional part is truncated to
//! millisecond resolution. Missing operand -> `sleep: missing operand`, exit 2. Invalid
//! operand -> `sleep: invalid time interval '<x>'`, exit 1. Sleeps in `i32`-max chunks
//! via `sys.sleepMs`.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "pause for a specified amount of time",
    .synopsis = &.{"sleep DURATION..."},
    .description =
    \\Waits for the sum of all DURATION operands, then exits successfully. Each
    \\DURATION is a non-negative number, optionally with a fractional part and a
    \\unit suffix -- s (seconds, the default), m (minutes), h (hours), or d (days).
    \\The fractional part is truncated (not rounded) to millisecond resolution.
    ,
    .options_note = "sleep takes no options besides --help/-h, honored only as the first argument.",
    .operands = "DURATION...   one or more time spans to wait, summed; each is [digits][.digits][s|m|h|d].",
    .exit = &.{
        .{ .code = 0, .when = "the full duration elapsed (including a total of 0)" },
        .{ .code = 1, .when = "a DURATION was not a valid time interval, or the summed total overflowed" },
        .{ .code = 2, .when = "no DURATION operand was given" },
    },
    .deviations_from = "GNU coreutils sleep",
    .deviations = &.{
        "\"inf\"/\"infinity\" are not recognized as an unbounded duration (GNU sleep waits forever on those); nutils reports them as an invalid time interval.",
        "Fractional seconds below 1ms are truncated rather than rounded (e.g. 0.0009s sleeps 0ms).",
    },
    .examples = &.{
        .{ .cmd = "sleep 1.5", .note = "waits 1500ms" },
        .{ .cmd = "sleep 2m 30s", .note = "waits 2 minutes 30 seconds (operands are summed)" },
    },
};

fn isHelp(a: []const u8) bool {
    return std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h");
}

/// Parses one DURATION operand into a millisecond count. `null` on any malformed input
/// or checked-arithmetic overflow.
fn parseMs(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var body = s;
    var unit_ms: u64 = 1000; // seconds, default
    const last = body[body.len - 1];
    if (last == 's' or last == 'm' or last == 'h' or last == 'd') {
        unit_ms = switch (last) {
            's' => 1000,
            'm' => 60_000,
            'h' => 3_600_000,
            'd' => 86_400_000,
            else => unreachable,
        };
        body = body[0 .. body.len - 1];
    }
    if (body.len == 0) return null;

    const dot = std.mem.indexOfScalar(u8, body, '.');
    const int_str = if (dot) |d| body[0..d] else body;
    const frac_str = if (dot) |d| body[d + 1 ..] else "";
    if (dot != null and frac_str.len == 0 and int_str.len == 0) return null; // lone "."
    if (int_str.len == 0 and frac_str.len == 0) return null;

    for (int_str) |c| if (c < '0' or c > '9') return null;
    for (frac_str) |c| if (c < '0' or c > '9') return null;

    var int_val: u64 = 0;
    for (int_str) |c| {
        int_val = std.math.mul(u64, int_val, 10) catch return null;
        int_val = std.math.add(u64, int_val, c - '0') catch return null;
    }

    // Fractional value, truncated to ms: frac_numerator * unit_ms / 10^frac_len.
    var frac_num: u64 = 0;
    var scale: u64 = 1;
    for (frac_str) |c| {
        frac_num = std.math.mul(u64, frac_num, 10) catch return null;
        frac_num = std.math.add(u64, frac_num, c - '0') catch return null;
        scale = std.math.mul(u64, scale, 10) catch return null;
    }

    const whole_ms = std.math.mul(u64, int_val, unit_ms) catch return null;
    const frac_scaled = std.math.mul(u64, frac_num, unit_ms) catch return null;
    const frac_ms = frac_scaled / scale;
    return std.math.add(u64, whole_ms, frac_ms) catch null;
}

pub fn run(ctx: *Ctx) u8 {
    const args = ctx.args[1..];
    if (args.len >= 1 and isHelp(args[0])) {
        cli.renderHelp(ctx, "sleep", help_doc);
        return 0;
    }
    if (args.len == 0) {
        ctx.errPrint("sleep: missing operand\n", .{});
        return 2;
    }

    var total: u64 = 0;
    for (args) |a| {
        const ms = parseMs(a) orelse {
            ctx.errPrint("sleep: invalid time interval '{s}'\n", .{a});
            return 1;
        };
        total = std.math.add(u64, total, ms) catch {
            ctx.errPrint("sleep: invalid time interval '{s}'\n", .{a});
            return 1;
        };
    }

    const max_chunk: u64 = @intCast(std.math.maxInt(i32));
    while (total > 0) {
        const chunk = @min(total, max_chunk);
        sys.sleepMs(@intCast(chunk));
        total -= chunk;
    }
    return 0;
}
