//! `date` -- print (and parse) dates. Formatting uses engines/datetime (strftime); the
//! `-d`/`--date` free-form parser is engines/datetime/parse. PARITY BOUND (DESIGN.md
//! §7.8): the kernel has no zoneinfo, so nutils `date` operates in UTC + fixed offsets
//! only, matching the reference box's jiff-fallback behavior -- NOT the host's local tz.
//! Goldens are authored with TZ=UTC.
//!
//! Flags: -d/--date STRING, -f/--file FILE, -r/--reference FILE, -u/--utc/--universal,
//! -I/--iso-8601[=SPEC], -R/--rfc-email, --rfc-3339=SPEC, +FORMAT. `-s/--set` parses like
//! -d and prints the result (we cannot set the kernel clock).

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;
const fmt = @import("../engines/datetime/format.zig");
const parse = @import("../engines/datetime/parse.zig");

const DEFAULT_FMT = "%a %b %e %H:%M:%S %Z %Y"; // C-locale default (%X expands to %T)

const help_doc = cli.Help{
    .summary = "print or parse dates and times",
    .synopsis = &.{ "date [OPTION]... [+FORMAT]", "date [OPTION]... -d STRING" },
    .description =
    \\Prints the current date and time, formatted per FORMAT (a '+'-prefixed
    \\strftime-style operand) or a fixed built-in default (`%a %b %e %H:%M:%S %Z
    \\%Y`). With -d/--date, STRING is parsed instead of using the current time;
    \\with -r/--reference, FILE's modification time is used instead.
    \\-I/--iso-8601, -R/--rfc-email, and --rfc-3339 each select a fixed
    \\alternate format and cannot be combined with a +FORMAT operand.
    \\
    \\nutils date runs in UTC with fixed offsets ONLY -- there is no timezone
    \\database. TZ is ignored and -u/--utc is a no-op, because output is always
    \\UTC to begin with; this is a hard platform bound (the underlying kernel carries no
    \\zoneinfo), so times are never converted to a host-local zone. The -d
    \\grammar covers @epoch (with fractional seconds), ISO-8601 dates/times
    \\(optionally with a trailing Z or a ±HH:MM offset), a bare time,
    \\now/today/yesterday/tomorrow, and relative offsets ("N unit[s] [ago]",
    \\"next/last unit") with GNU-style day-rollover (e.g. Jan 31 + 1 month ->
    \\Mar 2).
    \\strftime supports the full standard directive set plus the GNU `-_0^#`
    \\width/case modifiers, `%:z`/`%::z`, and `%N` (nanoseconds).
    ,
    .options = &.{
        .{ .flags = "-d, --date=STRING", .desc = "parse STRING (the getdate grammar above) instead of using the current time" },
        .{ .flags = "-f, --file=FILE", .desc = "parse each non-empty line of FILE like -d and print one result line per line" },
        .{ .flags = "-r, --reference=FILE", .desc = "use FILE's modification time instead of the current time" },
        .{ .flags = "-s, --set=STRING", .desc = "parse STRING like -d and print the result (the system clock is never actually changed)" },
        .{ .flags = "-u, --utc, --universal", .desc = "accepted; a no-op, since output is always UTC to begin with" },
        .{ .flags = "-I, --iso-8601[=SPEC]", .desc = "an ISO-8601 format; SPEC is date (default), hours, minutes, seconds, or ns" },
        .{ .flags = "-R, --rfc-email", .desc = "RFC 5322 format, e.g. \"Fri, 03 Jul 2026 00:00:00 +0000\"" },
        .{ .flags = "--rfc-3339=SPEC", .desc = "RFC 3339 format; SPEC is date, seconds, or ns" },
    },
    .operands = "+FORMAT   an optional strftime-style output format, prefixed with '+'; not combinable with -I/-R/--rfc-3339. With no +FORMAT and none of those flags, the default format above is used.",
    .exit = &.{
        .{ .code = 0, .when = "success" },
        .{ .code = 1, .when = "an invalid option/argument, an unparsable -d/-s/-f date string, or a -r/-f FILE that could not be opened" },
    },
    .deviations_from = "GNU coreutils date",
    .deviations = &.{
        "UTC + fixed-offset ONLY: there is no timezone database. TZ is ignored, and named zones beyond a small fixed abbreviation table cannot be resolved and fail to parse.",
        "-d/--date's grammar has no spelled-month dates (\"Jan 5 2020\"), no bare weekday-name anchoring (\"next Monday\", \"Friday\"), and no military single-letter timezone offsets.",
        "%Z always renders literally as \"UTC\", even when -d resolved a non-zero fixed offset that %z/%:z correctly display -- only the numeric offset, never the zone name, reflects the input.",
        "-s/--set parses its STRING like -d and prints the result, but never actually changes the system clock (there is no way to set kernel time here).",
        "strftime omits %Q/%:Q (IANA zone id -- meaningless without a tzdb) and locale-specific %c/%x/%X/%r beyond their fixed POSIX/C-locale expansions; an unrecognized directive is emitted literally rather than erroring.",
        "-d '' (an empty STRING) parses as \"now\", matching this port's chosen reference (uutils); GNU date's own -d '' means midnight today instead.",
    },
    .examples = &.{
        .{ .cmd = "date '+%Y-%m-%d'", .note = "today's date, UTC" },
        .{ .cmd = "date -d '@0' '+%Y-%m-%dT%H:%M:%SZ'", .note = "the Unix epoch: 1970-01-01T00:00:00Z" },
        .{ .cmd = "date -d '2024-01-01T00:00:00+05:00' '+%z %Z'", .note = "prints \"+0500 UTC\" -- %Z is always literally UTC even though %z reflects the parsed offset" },
    },
    .see_also = "sleep.",
};

pub fn run(ctx: *Ctx) u8 {
    var date_str: ?[]const u8 = null;
    var file_arg: ?[]const u8 = null;
    var ref_file: ?[]const u8 = null;
    var format_operand: ?[]const u8 = null;
    var format_string: []const u8 = DEFAULT_FMT;
    var have_explicit_format = false;

    var i: usize = 1;
    while (i < ctx.args.len) : (i += 1) {
        const a = ctx.args[i];
        if (std.mem.eql(u8, a, "--help")) {
            cli.renderHelp(ctx, "date", help_doc);
            return 0;
        } else if (std.mem.eql(u8, a, "-u") or std.mem.eql(u8, a, "--utc") or std.mem.eql(u8, a, "--universal")) {
            // Always UTC; accepted as a no-op.
        } else if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--date")) {
            i += 1;
            if (i >= ctx.args.len) return usage(ctx, "option requires an argument -- 'd'");
            date_str = ctx.args[i];
        } else if (std.mem.startsWith(u8, a, "--date=")) {
            date_str = a["--date=".len..];
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--set")) {
            i += 1;
            if (i >= ctx.args.len) return usage(ctx, "option requires an argument -- 's'");
            date_str = ctx.args[i];
        } else if (std.mem.eql(u8, a, "-r") or std.mem.eql(u8, a, "--reference")) {
            i += 1;
            if (i >= ctx.args.len) return usage(ctx, "option requires an argument -- 'r'");
            ref_file = ctx.args[i];
        } else if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--file")) {
            i += 1;
            if (i >= ctx.args.len) return usage(ctx, "option requires an argument -- 'f'");
            file_arg = ctx.args[i];
        } else if (std.mem.eql(u8, a, "-R") or std.mem.eql(u8, a, "--rfc-email")) {
            format_string = "%a, %d %b %Y %H:%M:%S %z";
            have_explicit_format = true;
        } else if (std.mem.eql(u8, a, "-I") or std.mem.eql(u8, a, "--iso-8601")) {
            format_string = "%Y-%m-%d";
            have_explicit_format = true;
        } else if (std.mem.startsWith(u8, a, "-I") or std.mem.startsWith(u8, a, "--iso-8601=")) {
            const spec = if (std.mem.startsWith(u8, a, "--iso-8601=")) a["--iso-8601=".len..] else a[2..];
            format_string = isoSpec(spec) orelse return usage(ctx, "invalid argument for --iso-8601");
            have_explicit_format = true;
        } else if (std.mem.startsWith(u8, a, "--rfc-3339=")) {
            const spec = a["--rfc-3339=".len..];
            format_string = rfc3339Spec(spec) orelse return usage(ctx, "invalid argument for --rfc-3339");
            have_explicit_format = true;
        } else if (a.len > 0 and a[0] == '+') {
            format_operand = a[1..];
        } else if (a.len > 0 and a[0] == '-' and !std.mem.eql(u8, a, "-")) {
            return usage(ctx, "invalid option");
        } else {
            return usage(ctx, "extra operand");
        }
    }

    if (format_operand) |f| {
        if (have_explicit_format) return usage(ctx, "multiple output formats specified");
        format_string = f;
    }

    // -f FILE: one -d per line.
    if (file_arg) |f| {
        return runFile(ctx, f, format_string);
    }

    const now_sec = @divFloor(sys.timeRealtimeMs() catch 0, 1000);

    const inst = resolveInstant(ctx, date_str, ref_file, now_sec) orelse return 1;
    return emit(ctx, inst, format_string);
}

fn resolveInstant(ctx: *Ctx, date_str: ?[]const u8, ref_file: ?[]const u8, now_sec: i64) ?parse.Instant {
    if (ref_file) |rf| {
        const st = sys.stat(rf) catch {
            ctx.errPrint("date: {s}: No such file or directory\n", .{rf});
            return null;
        };
        return .{ .epoch_sec = @divFloor(st.mtime_ms, 1000), .nanosecond = @intCast(@mod(st.mtime_ms, 1000) * 1_000_000) };
    }
    if (date_str) |ds| {
        return parse.parse(ds, now_sec) orelse {
            ctx.errPrint("date: invalid date '{s}'\n", .{ds});
            return null;
        };
    }
    return .{ .epoch_sec = now_sec };
}

fn emit(ctx: *Ctx, inst: parse.Instant, format_string: []const u8) u8 {
    const tm = fmt.fromEpoch(inst.epoch_sec, inst.nanosecond, inst.offset_sec, "UTC");
    const s = fmt.render(ctx.gpa, tm, format_string) catch return 1;
    ctx.outWrite(s) catch return 1;
    ctx.outWrite("\n") catch return 1;
    return 0;
}

fn runFile(ctx: *Ctx, path: []const u8, format_string: []const u8) u8 {
    const fd = if (std.mem.eql(u8, path, "-")) ctx.stdin else sys.open(path, .{ .read = true }) catch {
        ctx.errPrint("date: {s}: No such file or directory\n", .{path});
        return 1;
    };
    defer if (!std.mem.eql(u8, path, "-")) sys.close(fd);
    const textio = @import("../core/textio.zig");
    const now_sec = @divFloor(sys.timeRealtimeMs() catch 0, 1000);
    const data = textio.readAll(ctx.gpa, fd) catch return 1;
    var rc: u8 = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const inst = parse.parse(line, now_sec) orelse {
            ctx.errPrint("date: invalid date '{s}'\n", .{line});
            rc = 1;
            continue;
        };
        if (emit(ctx, inst, format_string) != 0) return 1;
    }
    return rc;
}

fn isoSpec(spec: []const u8) ?[]const u8 {
    if (spec.len == 0 or std.mem.eql(u8, spec, "date")) return "%Y-%m-%d";
    if (std.mem.eql(u8, spec, "hours")) return "%Y-%m-%dT%H%:z";
    if (std.mem.eql(u8, spec, "minutes")) return "%Y-%m-%dT%H:%M%:z";
    if (std.mem.eql(u8, spec, "seconds")) return "%Y-%m-%dT%H:%M:%S%:z";
    if (std.mem.eql(u8, spec, "ns")) return "%Y-%m-%dT%H:%M:%S,%N%:z";
    return null;
}

fn rfc3339Spec(spec: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, spec, "date")) return "%Y-%m-%d";
    if (std.mem.eql(u8, spec, "seconds")) return "%Y-%m-%d %H:%M:%S%:z";
    if (std.mem.eql(u8, spec, "ns")) return "%Y-%m-%d %H:%M:%S.%N%:z";
    return null;
}

fn usage(ctx: *Ctx, msg: []const u8) u8 {
    ctx.errPrint("date: {s}\n", .{msg});
    return 1;
}
