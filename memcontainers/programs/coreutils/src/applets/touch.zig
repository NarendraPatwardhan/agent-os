//! `touch` -- DESIGN.md §1: `-a`/`-m` (neither or both = both),
//! `-c/--no-create`, `-r/--reference FILE`, `-t STAMP` (`[[CC]YY]MMDDhhmm[.ss]`),
//! `-d/--date STRING` (ISO subset `YYYY-MM-DD[ |T HH:MM[:SS]]`). Precedence
//! `-t`/`-d` (whichever is given; `-t` wins if both) over `-r` over now. A missing file
//! is created (`write|create`) unless `-c`, in which case it's silently skipped. Now +
//! both fields -> `sys.utimes(path, null)` (kernel fills); otherwise the untouched
//! member is preserved via `sys.stat`. Bad date -> `touch: <x>: invalid date format`,
//! exit 1; missing operand -> `touch: missing file operand`, exit 1; usage -> exit 2.

const std = @import("std");
const cli = @import("../core/cli.zig");
const fsutil = @import("../core/fsutil.zig");
const sys = @import("../sys/root.zig");
const civil = @import("../core/civil.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "touch",
    .flags = &.{
        cli.flagOpt('a', null, "change only the access time"),
        cli.flagOpt('m', null, "change only the modification time"),
        cli.flagOpt('c', "no-create", "do not create any files"),
        cli.valueOpt('r', "reference", "use this file's times instead of current time"),
        cli.valueOpt('t', null, "use [[CC]YY]MMDDhhmm[.ss] instead of current time"),
        cli.valueOpt('d', "date", "parse STRING and use it instead of current time"),
    },
    .help = .{
        .summary = "change file timestamps",
        .synopsis = &.{"touch [OPTION]... FILE..."},
        .description =
        \\Updates the access and modification times of each FILE to the current time,
        \\creating it (empty) if it does not exist. -a/-m restrict the update to just
        \\the access or modification time (both are updated when neither, or both, are
        \\given); -c suppresses creation of a missing FILE (skipped silently) instead
        \\of touching it.
        \\
        \\The timestamp source, in precedence order, is: -t STAMP or -d/--date STRING
        \\(an explicit time -- if both are given, -t wins), else -r/--reference FILE
        \\(copy that file's atime/mtime), else the current time.
        ,
        .operands = "FILE...  the files to touch (or create).",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "missing operand, an invalid -t/-d date, a -r FILE that cannot be stat'd, or a create/stat/utimes error" },
            .{ .code = 2, .when = "usage error (unrecognized option or missing option value)" },
        },
        .deviations = &.{
            "-t accepts only [[CC]YY]MMDDhhmm[.ss]; -d/--date accepts only the ISO subset YYYY-MM-DD[ |T HH:MM[:SS]]. GNU's much richer free-form date parser (\"next Thursday\", \"+1 day\", relative offsets, etc.) is not supported.",
            "No --time=WORD (selecting which field -a/-m/-d apply to independently) and no -h/--no-dereference.",
        },
        .examples = &.{
            .{ .cmd = "touch newfile.txt", .note = "creates it if missing, else sets both times to now" },
            .{ .cmd = "touch -c -t 202401011200 maybe.txt", .note = "-c skips creation if missing; otherwise sets both times to 2024-01-01 12:00" },
            .{ .cmd = "touch -r ref.txt copy.txt", .note = "copies ref.txt's atime/mtime onto copy.txt" },
        },
        .see_also = "stat (inspect timestamps), date.",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

fn isDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn digitsToU32(s: []const u8) u32 {
    var v: u32 = 0;
    for (s) |c| v = v * 10 + (c - '0');
    return v;
}

/// `[[CC]YY]MMDDhhmm[.ss]` -> epoch ms (UTC). `null` on any malformed input.
fn parseStamp(s: []const u8) ?i64 {
    var main_part = s;
    var ss: u32 = 0;
    if (std.mem.indexOfScalar(u8, s, '.')) |dot| {
        main_part = s[0..dot];
        const secs = s[dot + 1 ..];
        if (secs.len != 2 or !isDigits(secs)) return null;
        ss = digitsToU32(secs);
    }
    if (!isDigits(main_part)) return null;

    var year: i64 = undefined;
    var month: u32 = undefined;
    var day: u32 = undefined;
    var hh: u32 = undefined;
    var mm: u32 = undefined;

    switch (main_part.len) {
        8 => {
            const now_ms = sys.timeRealtimeMs() catch 0;
            year = civil.civilFromDays(@divFloor(now_ms, 86_400_000)).year;
            month = digitsToU32(main_part[0..2]);
            day = digitsToU32(main_part[2..4]);
            hh = digitsToU32(main_part[4..6]);
            mm = digitsToU32(main_part[6..8]);
        },
        10 => {
            const yy = digitsToU32(main_part[0..2]);
            year = if (yy < 69) 2000 + @as(i64, yy) else 1900 + @as(i64, yy);
            month = digitsToU32(main_part[2..4]);
            day = digitsToU32(main_part[4..6]);
            hh = digitsToU32(main_part[6..8]);
            mm = digitsToU32(main_part[8..10]);
        },
        12 => {
            year = digitsToU32(main_part[0..4]);
            month = digitsToU32(main_part[4..6]);
            day = digitsToU32(main_part[6..8]);
            hh = digitsToU32(main_part[8..10]);
            mm = digitsToU32(main_part[10..12]);
        },
        else => return null,
    }
    if (month < 1 or month > 12 or day < 1 or day > 31 or hh > 23 or mm > 59 or ss > 61) return null;
    return civil.epochMsFromCivil(year, month, day, hh, mm, ss);
}

/// `YYYY-MM-DD[ |T HH:MM[:SS]]` -> epoch ms (UTC). `null` on any malformed input.
fn parseIsoDate(s: []const u8) ?i64 {
    if (s.len < 10) return null;
    const date_part = s[0..10];
    if (date_part[4] != '-' or date_part[7] != '-') return null;
    if (!isDigits(date_part[0..4]) or !isDigits(date_part[5..7]) or !isDigits(date_part[8..10])) return null;
    const year: i64 = digitsToU32(date_part[0..4]);
    const month = digitsToU32(date_part[5..7]);
    const day = digitsToU32(date_part[8..10]);
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    var hh: u32 = 0;
    var mm: u32 = 0;
    var ss: u32 = 0;
    if (s.len > 10) {
        const sep = s[10];
        if (sep != ' ' and sep != 'T') return null;
        const rest = s[11..];
        if (rest.len < 5 or rest[2] != ':') return null;
        if (!isDigits(rest[0..2]) or !isDigits(rest[3..5])) return null;
        hh = digitsToU32(rest[0..2]);
        mm = digitsToU32(rest[3..5]);
        if (rest.len > 5) {
            if (rest.len != 8 or rest[5] != ':' or !isDigits(rest[6..8])) return null;
            ss = digitsToU32(rest[6..8]);
        }
    }
    if (hh > 23 or mm > 59 or ss > 61) return null;
    return civil.epochMsFromCivil(year, month, day, hh, mm, ss);
}

const Source = union(enum) {
    now,
    explicit: i64,
    reference: struct { atime_ms: i64, mtime_ms: i64 },
};

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    var touch_a = m.has("a");
    var touch_m = m.has("m");
    if (!touch_a and !touch_m) {
        touch_a = true;
        touch_m = true;
    }
    const no_create = m.has("no-create");

    var source: Source = .now;
    if (m.value("t")) |ts| {
        const ms = parseStamp(ts) orelse {
            ctx.errPrint("touch: {s}: invalid date format\n", .{ts});
            return 1;
        };
        source = .{ .explicit = ms };
    } else if (m.value("date")) |ds| {
        const ms = parseIsoDate(ds) orelse {
            ctx.errPrint("touch: {s}: invalid date format\n", .{ds});
            return 1;
        };
        source = .{ .explicit = ms };
    } else if (m.value("reference")) |rp| {
        const st = sys.stat(rp) catch |e| {
            ctx.errPrint("touch: {s}: {s}\n", .{ rp, sys.strerror(sys.toErrno(e)) });
            return 1;
        };
        source = .{ .reference = .{ .atime_ms = st.atime_ms, .mtime_ms = st.mtime_ms } };
    }

    const files = m.positionalSlice();
    if (files.len == 0) {
        ctx.errPrint("touch: missing file operand\n", .{});
        return 1;
    }

    var rc: u8 = 0;
    for (files) |f| {
        if (!fsutil.exists(f)) {
            if (no_create) continue;
            const fd = sys.open(f, .{ .write = true, .create = true }) catch |e| {
                ctx.errPrint("touch: {s}: {s}\n", .{ f, sys.strerror(sys.toErrno(e)) });
                rc = 1;
                continue;
            };
            sys.close(fd);
        }

        switch (source) {
            .now => {
                if (touch_a and touch_m) {
                    sys.utimes(f, null) catch |e| {
                        ctx.errPrint("touch: {s}: {s}\n", .{ f, sys.strerror(sys.toErrno(e)) });
                        rc = 1;
                    };
                } else {
                    const st = sys.stat(f) catch |e| {
                        ctx.errPrint("touch: {s}: {s}\n", .{ f, sys.strerror(sys.toErrno(e)) });
                        rc = 1;
                        continue;
                    };
                    const now_ms = sys.timeRealtimeMs() catch 0;
                    const at = if (touch_a) now_ms else st.atime_ms;
                    const mt = if (touch_m) now_ms else st.mtime_ms;
                    sys.utimes(f, .{ .atime_ms = at, .mtime_ms = mt }) catch |e| {
                        ctx.errPrint("touch: {s}: {s}\n", .{ f, sys.strerror(sys.toErrno(e)) });
                        rc = 1;
                    };
                }
            },
            .explicit => |ms| {
                var at: i64 = ms;
                var mt: i64 = ms;
                if (!touch_a or !touch_m) {
                    const st = sys.stat(f) catch |e| {
                        ctx.errPrint("touch: {s}: {s}\n", .{ f, sys.strerror(sys.toErrno(e)) });
                        rc = 1;
                        continue;
                    };
                    if (!touch_a) at = st.atime_ms;
                    if (!touch_m) mt = st.mtime_ms;
                }
                sys.utimes(f, .{ .atime_ms = at, .mtime_ms = mt }) catch |e| {
                    ctx.errPrint("touch: {s}: {s}\n", .{ f, sys.strerror(sys.toErrno(e)) });
                    rc = 1;
                };
            },
            .reference => |r| {
                var at: i64 = r.atime_ms;
                var mt: i64 = r.mtime_ms;
                if (!touch_a or !touch_m) {
                    const st = sys.stat(f) catch |e| {
                        ctx.errPrint("touch: {s}: {s}\n", .{ f, sys.strerror(sys.toErrno(e)) });
                        rc = 1;
                        continue;
                    };
                    if (!touch_a) at = st.atime_ms;
                    if (!touch_m) mt = st.mtime_ms;
                }
                sys.utimes(f, .{ .atime_ms = at, .mtime_ms = mt }) catch |e| {
                    ctx.errPrint("touch: {s}: {s}\n", .{ f, sys.strerror(sys.toErrno(e)) });
                    rc = 1;
                };
            },
        }
    }
    return rc;
}
