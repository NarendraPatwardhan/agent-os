//! The `-d`/`--date` (getdate) parser for `date`. A pragmatic subset of GNU's free-form
//! grammar — the constructs uutils' parse_datetime accepts that real usage exercises:
//! `@EPOCH`, ISO-8601 (`YYYY-MM-DD[THH:MM:SS[.frac]][Z|±HH:MM]`), date-only, time-only,
//! the keywords now/today/yesterday/tomorrow, and relative offsets
//! (`N unit[s] [ago]`, `next/last unit`) applied to a base instant. Parity bound
//! (DESIGN.md §7.8): UTC + fixed offset only — no tzdb, so named zones beyond the fixed
//! abbreviation table resolve to their table offset. Anything outside this subset returns
//! `null` (the applet reports `invalid date`), and the deferrals are ledgered.

const std = @import("std");
const civil = @import("../../core/civil.zig");
const cal = @import("calendar.zig");

pub const Instant = struct { epoch_sec: i64, nanosecond: u32 = 0, offset_sec: i32 = 0 };

const Unit = enum { second, minute, hour, day, week, month, year };

/// Parse `s` relative to `now_sec` (used for relative/time-only forms). Returns null if
/// the string is not in the supported subset.
pub fn parse(s_in: []const u8, now_sec: i64) ?Instant {
    const s = trim(s_in);
    if (s.len == 0) return .{ .epoch_sec = now_sec }; // empty = now (GNU: midnight today, but uutils differs; ledgered)

    // @EPOCH, optionally with a fractional part (@1700000000.123456789).
    if (s[0] == '@') {
        const rest = s[1..];
        if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
            const whole = std.fmt.parseInt(i64, rest[0..dot], 10) catch return null;
            var k: usize = dot + 1;
            const nanos = takeFrac(rest, &k);
            if (k != rest.len) return null; // trailing junk after the fraction
            return .{ .epoch_sec = whole, .nanosecond = nanos };
        }
        const n = std.fmt.parseInt(i64, rest, 10) catch return null;
        return .{ .epoch_sec = n };
    }

    // Pure keywords.
    if (eqIgnoreCase(s, "now")) return .{ .epoch_sec = now_sec };
    if (eqIgnoreCase(s, "today")) return midnight(now_sec, 0);
    if (eqIgnoreCase(s, "yesterday")) return midnight(now_sec, -1);
    if (eqIgnoreCase(s, "tomorrow")) return midnight(now_sec, 1);

    // Absolute ISO date (optionally + time + offset), possibly followed by relative terms.
    if (looksLikeIsoDate(s)) return parseIsoThenRelative(s);

    // Time-only (HH:MM[:SS] [am/pm]) -> today's date at that time.
    if (parseTimeOnly(s, now_sec)) |inst| return inst;

    // Relative-only (e.g. "3 days ago", "next week") applied to now.
    return applyRelativeTerms(s, .{ .epoch_sec = now_sec });
}

fn parseIsoThenRelative(s: []const u8) ?Instant {
    // Split off a leading ISO datetime; the remainder (if any) is relative terms.
    var i: usize = 0;
    // date: YYYY-MM-DD
    const year = takeInt(s, &i, 4) orelse return null;
    if (!take(s, &i, '-')) return null;
    const month = takeInt(s, &i, 2) orelse return null;
    if (!take(s, &i, '-')) return null;
    const day = takeInt(s, &i, 2) orelse return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    var hour: i64 = 0;
    var min: i64 = 0;
    var sec: i64 = 0;
    var nanos: u32 = 0;
    var offset: i32 = 0;

    // Optional time, separated by 'T' or space.
    const j = i;
    if (j < s.len and (s[j] == 'T' or s[j] == ' ')) {
        var k = j + 1;
        if (takeInt(s, &k, 2)) |h| {
            if (k < s.len and s[k] == ':') {
                k += 1;
                const m = takeInt(s, &k, 2) orelse return null;
                hour = h;
                min = m;
                if (k < s.len and s[k] == ':') {
                    k += 1;
                    sec = takeInt(s, &k, 2) orelse return null;
                    if (k < s.len and s[k] == '.') {
                        k += 1;
                        nanos = takeFrac(s, &k);
                    }
                }
                // Optional zone: Z or ±HH[:]MM
                if (k < s.len and (s[k] == 'Z' or s[k] == 'z')) {
                    k += 1;
                } else if (k < s.len and (s[k] == '+' or s[k] == '-')) {
                    offset = takeOffset(s, &k) orelse return null;
                }
                i = k;
            }
        }
    }

    const days = civil.daysFromCivil(year, @intCast(month), @intCast(day));
    var epoch: i64 = days * 86400 + hour * 3600 + min * 60 + sec - @as(i64, offset);
    var inst = Instant{ .epoch_sec = epoch, .nanosecond = nanos, .offset_sec = offset };

    // Trailing relative terms (e.g. "2020-01-01 +1 month" / "2020-01-01 3 days").
    const rest = trim(s[i..]);
    if (rest.len != 0) {
        inst = applyRelativeTerms(rest, inst) orelse return null;
    }
    _ = &epoch;
    return inst;
}

/// Applies a sequence of relative terms to `base`. Terms: `[+-]N unit[s]` (optionally
/// `ago`), `next unit`, `last unit`. Whitespace-separated. Returns null on any bad token.
fn applyRelativeTerms(s: []const u8, base: Instant) ?Instant {
    var toks = std.mem.tokenizeAny(u8, s, " \t");
    var y: i64 = 0;
    var mo: i64 = 0;
    var d: i64 = 0;
    var sec: i64 = 0;

    while (toks.next()) |tok0| {
        var tok = tok0;
        var n: i64 = 1;
        if (eqIgnoreCase(tok, "next")) {
            n = 1;
            tok = toks.next() orelse return null;
        } else if (eqIgnoreCase(tok, "last")) {
            n = -1;
            tok = toks.next() orelse return null;
        } else if (parseSignedInt(tok)) |v| {
            n = v;
            tok = toks.next() orelse return null;
        } else return null;

        const unit = parseUnit(tok) orelse return null;
        // Optional trailing "ago" negates.
        const save = toks;
        if (toks.next()) |maybe_ago| {
            if (eqIgnoreCase(maybe_ago, "ago")) {
                n = -n;
            } else {
                toks = save; // put it back
            }
        }

        switch (unit) {
            .second => sec += n,
            .minute => sec += n * 60,
            .hour => sec += n * 3600,
            .day => d += n,
            .week => d += n * 7,
            .month => mo += n,
            .year => y += n,
        }
    }

    // Apply calendar (year/month) parts via civil arithmetic, then the second parts.
    const t = @import("format.zig");
    const tm = t.fromEpoch(base.epoch_sec, base.nanosecond, base.offset_sec, "UTC");
    const sod = @as(i64, @intCast(tm.hour)) * 3600 + @as(i64, @intCast(tm.minute)) * 60 + @as(i64, @intCast(tm.second));
    var day_num: i64 = undefined;
    if (y != 0 or mo != 0) {
        const total_months = @as(i64, @intCast(tm.month)) - 1 + mo + y * 12;
        const ny = tm.year + @divFloor(total_months, 12);
        const nm = @mod(total_months, 12) + 1;
        // GNU/uutils rolls an out-of-range day into the following month rather than
        // clamping (Jan 31 + 1 month -> Mar 2), so keep the original day-of-month and
        // count from the first of the target month.
        day_num = civil.daysFromCivil(ny, @intCast(nm), 1) + (@as(i64, @intCast(tm.day)) - 1);
    } else {
        day_num = @divFloor(t.epochSeconds(tm) - sod, 86400);
    }
    return .{ .epoch_sec = day_num * 86400 + sod + d * 86400 + sec, .nanosecond = base.nanosecond, .offset_sec = base.offset_sec };
}

fn parseTimeOnly(s: []const u8, now_sec: i64) ?Instant {
    var i: usize = 0;
    const h = takeInt(s, &i, 2) orelse return null;
    if (i >= s.len or s[i] != ':') return null;
    i += 1;
    const m = takeInt(s, &i, 2) orelse return null;
    var sec: i64 = 0;
    if (i < s.len and s[i] == ':') {
        i += 1;
        sec = takeInt(s, &i, 2) orelse return null;
    }
    var hour = h;
    const rest = trim(s[i..]);
    if (eqIgnoreCase(rest, "pm")) {
        if (hour < 12) hour += 12;
    } else if (eqIgnoreCase(rest, "am")) {
        if (hour == 12) hour = 0;
    } else if (rest.len != 0) return null;
    const base = midnight(now_sec, 0) orelse return null;
    return .{ .epoch_sec = base.epoch_sec + hour * 3600 + m * 60 + sec };
}

// ------------------------------------------------------------------ helpers

fn midnight(now_sec: i64, day_delta: i64) ?Instant {
    const days = @divFloor(now_sec, 86400) + day_delta;
    return .{ .epoch_sec = days * 86400 };
}

fn looksLikeIsoDate(s: []const u8) bool {
    // 4 digits, dash, then more digits — enough to disambiguate from time-only.
    if (s.len < 8) return false;
    var i: usize = 0;
    while (i < 4) : (i += 1) if (!isDigit(s[i])) return false;
    return s[4] == '-';
}

fn parseUnit(tok: []const u8) ?Unit {
    const t = trimSuffix(tok, "s"); // allow plural
    if (eqIgnoreCase(t, "sec") or eqIgnoreCase(t, "second")) return .second;
    if (eqIgnoreCase(t, "min") or eqIgnoreCase(t, "minute")) return .minute;
    if (eqIgnoreCase(t, "hour")) return .hour;
    if (eqIgnoreCase(t, "day")) return .day;
    if (eqIgnoreCase(t, "week")) return .week;
    if (eqIgnoreCase(t, "month")) return .month;
    if (eqIgnoreCase(t, "year")) return .year;
    return null;
}

fn parseSignedInt(tok: []const u8) ?i64 {
    return std.fmt.parseInt(i64, tok, 10) catch null;
}

fn takeInt(s: []const u8, i: *usize, max_digits: usize) ?i64 {
    const start = i.*;
    var v: i64 = 0;
    var count: usize = 0;
    while (i.* < s.len and isDigit(s[i.*]) and count < max_digits) : (i.* += 1) {
        v = v * 10 + (s[i.*] - '0');
        count += 1;
    }
    if (i.* == start) return null;
    return v;
}

fn takeFrac(s: []const u8, i: *usize) u32 {
    var scale: u32 = 100_000_000;
    var nanos: u32 = 0;
    while (i.* < s.len and isDigit(s[i.*])) : (i.* += 1) {
        nanos += @as(u32, s[i.*] - '0') * scale;
        scale /= 10;
    }
    return nanos;
}

fn takeOffset(s: []const u8, i: *usize) ?i32 {
    const sign: i32 = if (s[i.*] == '-') -1 else 1;
    i.* += 1;
    const h = takeInt(s, i, 2) orelse return null;
    var m: i64 = 0;
    if (i.* < s.len and s[i.*] == ':') i.* += 1;
    if (i.* < s.len and isDigit(s[i.*])) m = takeInt(s, i, 2) orelse 0;
    return sign * @as(i32, @intCast(h * 3600 + m * 60));
}

fn take(s: []const u8, i: *usize, c: u8) bool {
    if (i.* < s.len and s[i.*] == c) {
        i.* += 1;
        return true;
    }
    return false;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\n\r");
}

fn trimSuffix(s: []const u8, suf: []const u8) []const u8 {
    if (std.mem.endsWith(u8, s, suf)) return s[0 .. s.len - suf.len];
    return s;
}
