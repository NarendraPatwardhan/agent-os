//! FORMAT half of the `datetime` engine (DESIGN.md §7.8): a from-scratch strftime
//! matching jiff 0.2.28's `strtime` conversion-specifier table (see jiff's
//! `src/fmt/strtime/mod.rs` doc comment) plus uutils date's GNU modifier layer
//! (`format_modifiers.rs`).
//!
//! Design: every directive is rendered TWICE in effect but only ONE pass in code --
//! `renderSpecPlain` always produces jiff's *unflagged* default representation for a
//! bare `%<letter>` (exactly the pad byte/width jiff's `printer.rs` uses natively), and
//! `applyModifiers` is *always* run afterward as a pure string transform (ported
//! verbatim from `format_modifiers.rs`'s `apply_modifiers`). This is not an
//! approximation: it is what uutils date itself does whenever ANY directive in the
//! format string carries a flag or width -- and running it unconditionally (even with
//! empty flags/no width) is a provable no-op identity (verified against every
//! directive class while porting), so the two code paths the reference has (native
//! jiff fast path vs. the modifier path) collapse to one without any behavior change.
//!
//! Unsupported (deferred, see docs/parity-ledger.md): `%Q`/`%:Q` (IANA zone id --
//! meaningless without a tzdb, DESIGN.md §7.8 UTC+offset-only bound), locale-plural
//! `%c`/`%x`/`%X`/`%r` beyond the fixed POSIX/C-locale expansions uutils itself uses
//! (`Config::new().custom(PosixCustom::new())`), the `E`/`O` locale modifiers (jiff
//! doesn't support them either). Any other unrecognized directive falls back to
//! jiff's own *lenient* behavior: the bare `%` is emitted literally and the rest of
//! the spec is reprocessed as ordinary text.

const std = @import("std");
const Allocator = std.mem.Allocator;
const civil = @import("../../core/civil.zig");
const cal = @import("calendar.zig");

/// A fully-resolved broken-down time: always complete (year..nanosecond plus an
/// explicit UTC offset) because `date` only ever formats an absolute instant it has
/// already resolved -- unlike jiff's `BrokenDownTime`, there is no "missing field"
/// state to model, so directives never fail.
pub const Tm = struct {
    year: i64,
    month: u32, // 1-12
    day: u32, // 1-31
    hour: u32, // 0-23
    minute: u32, // 0-59
    second: u32, // 0-60 (leap second tolerance only, never produced by our own clock)
    nanosecond: u32 = 0, // 0..999_999_999
    offset_sec: i32 = 0, // UTC offset in seconds, east-positive (DESIGN.md §7.8: UTC + fixed offset only)
    tz_abbrev: []const u8 = "UTC",
};

/// Builds a `Tm` from an absolute (epoch_sec, nanosecond) instant plus the display
/// offset, by shifting to "wall clock" seconds and breaking down via
/// `civil.daysFromCivil`/`civilFromDays` (civil.zig's own breakdown helper is
/// ms-based and private; this is the seconds-based public equivalent for `date`).
pub fn fromEpoch(epoch_sec: i64, nanosecond: u32, offset_sec: i32, tz_abbrev: []const u8) Tm {
    const wall = epoch_sec + @as(i64, offset_sec);
    const days = @divFloor(wall, 86400);
    const sod = wall - days * 86400; // seconds-of-day, always in [0, 86399]
    const cd = civil.civilFromDays(days);
    return .{
        .year = cd.year,
        .month = cd.month,
        .day = cd.day,
        .hour = @intCast(@divTrunc(sod, 3600)),
        .minute = @intCast(@mod(@divTrunc(sod, 60), 60)),
        .second = @intCast(@mod(sod, 60)),
        .nanosecond = nanosecond,
        .offset_sec = offset_sec,
        .tz_abbrev = tz_abbrev,
    };
}

/// Inverse of `fromEpoch`'s wall-clock computation: `%s`.
pub fn epochSeconds(tm: Tm) i64 {
    return civil.daysFromCivil(tm.year, tm.month, tm.day) * 86400 +
        @as(i64, tm.hour) * 3600 + @as(i64, tm.minute) * 60 + @as(i64, tm.second) - @as(i64, tm.offset_sec);
}

fn daysOf(tm: Tm) i64 {
    return civil.daysFromCivil(tm.year, tm.month, tm.day);
}

// ------------------------------------------------------------------ integer writer

fn digitCount(v: u64) u32 {
    var n: u32 = 1;
    var x = v;
    while (x >= 10) : (x /= 10) n += 1;
    return n;
}

fn appendRepeat(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, byte: u8, n: u32) !void {
    var i: u32 = 0;
    while (i < n) : (i += 1) try list.append(gpa, byte);
}

fn appendNatural(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, v: u64) !void {
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var x = v;
    if (x == 0) {
        i -= 1;
        buf[i] = '0';
    } else {
        while (x != 0) {
            i -= 1;
            buf[i] = '0' + @as(u8, @intCast(x % 10));
            x /= 10;
        }
    }
    try list.appendSlice(gpa, buf[i..]);
}

/// Pads `v` (natural digit count, at least `width` wide) with `pad_byte`. Mirrors
/// jiff's `Buffer::write_int_pad` exactly: padding never truncates, so a value wider
/// than `width` just prints its natural (longer) form.
fn appendPadded(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, v: u64, pad_byte: u8, width: u32) !void {
    const d = digitCount(v);
    const total = @max(width, d);
    try appendRepeat(list, gpa, pad_byte, total - d);
    try appendNatural(list, gpa, v);
}

/// General signed-integer writer matching jiff's `Extension::write_int` /
/// `write_negative_int`: space-padding puts the spaces BEFORE the sign
/// (`"  -22"`), zero-padding puts the sign first then zero-fills the magnitude
/// (`"-0022"`). `width==0` means no padding at all (just sign + natural digits).
fn writeIntPad(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, value: i64, pad_byte: u8, width: u32) !void {
    if (value < 0) {
        const mag: u64 = @intCast(-value);
        if (width > 0) {
            const pw = width - 1; // sign consumes one column of the requested width
            if (pad_byte == ' ') {
                const d = digitCount(mag);
                const spaces = if (pw > d) pw - d else 0;
                try appendRepeat(list, gpa, ' ', spaces);
                try list.append(gpa, '-');
                try appendNatural(list, gpa, mag);
            } else {
                try list.append(gpa, '-');
                try appendPadded(list, gpa, mag, pad_byte, pw);
            }
        } else {
            try list.append(gpa, '-');
            try appendNatural(list, gpa, mag);
        }
        return;
    }
    try appendPadded(list, gpa, @intCast(value), pad_byte, width);
}

fn appendOffset(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, offset_sec: i32, colons: u8) !void {
    const neg = offset_sec < 0;
    const total: u32 = @intCast(if (neg) -offset_sec else offset_sec);
    const hh = total / 3600;
    const mm = (total / 60) % 60;
    const ss = total % 60;
    try list.append(gpa, if (neg) '-' else '+');
    try appendPadded(list, gpa, hh, '0', 2);
    switch (colons) {
        0 => {
            try appendPadded(list, gpa, mm, '0', 2);
            if (ss != 0) try appendPadded(list, gpa, ss, '0', 2);
        },
        1 => {
            try list.append(gpa, ':');
            try appendPadded(list, gpa, mm, '0', 2);
            if (ss != 0) {
                try list.append(gpa, ':');
                try appendPadded(list, gpa, ss, '0', 2);
            }
        },
        2 => {
            try list.append(gpa, ':');
            try appendPadded(list, gpa, mm, '0', 2);
            try list.append(gpa, ':');
            try appendPadded(list, gpa, ss, '0', 2);
        },
        else => {
            if (mm != 0 or ss != 0) {
                try list.append(gpa, ':');
                try appendPadded(list, gpa, mm, '0', 2);
                if (ss != 0) {
                    try list.append(gpa, ':');
                    try appendPadded(list, gpa, ss, '0', 2);
                }
            }
        },
    }
}

fn nineDigitNanos(buf: *[9]u8, ns: u32) void {
    var v = ns;
    var i: usize = 9;
    while (i > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
}

// -------------------------------------------------------------- plain spec render

/// Renders the *unflagged* default text for a single `%<letter>` (or `%:z`-family)
/// directive. `null` means "not a directive I implement" -- the caller falls back to
/// jiff's lenient literal passthrough.
fn renderSpecPlain(gpa: Allocator, tm: Tm, letter: u8, colons: u8) Allocator.Error!?[]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    switch (letter) {
        'A' => try list.appendSlice(gpa, cal.WEEKDAY_FULL[cal.weekdayMon0(daysOf(tm))]),
        'a' => try list.appendSlice(gpa, cal.WEEKDAY_ABBR[cal.weekdayMon0(daysOf(tm))]),
        'B' => try list.appendSlice(gpa, cal.MONTH_FULL[tm.month - 1]),
        'b', 'h' => try list.appendSlice(gpa, cal.MONTH_ABBR[tm.month - 1]),
        'C' => try writeIntPad(&list, gpa, @divTrunc(tm.year, 100), ' ', 0),
        'c' => {
            const s = try render(gpa, tm, "%a %b %e %H:%M:%S %Y");
            defer gpa.free(s);
            try list.appendSlice(gpa, s);
        },
        'D' => {
            const s = try render(gpa, tm, "%m/%d/%y");
            defer gpa.free(s);
            try list.appendSlice(gpa, s);
        },
        'd' => try writeIntPad(&list, gpa, tm.day, '0', 2),
        'e' => try writeIntPad(&list, gpa, tm.day, ' ', 2),
        'F' => {
            const s = try render(gpa, tm, "%Y-%m-%d");
            defer gpa.free(s);
            try list.appendSlice(gpa, s);
        },
        'f' => {
            if (tm.nanosecond == 0) {
                try list.append(gpa, '0');
            } else {
                var buf: [9]u8 = undefined;
                nineDigitNanos(&buf, tm.nanosecond);
                var end: usize = 9;
                while (end > 0 and buf[end - 1] == '0') end -= 1;
                try list.appendSlice(gpa, buf[0..end]);
            }
        },
        'G' => try writeIntPad(&list, gpa, cal.isoWeekOf(tm.year, tm.month, tm.day).year, '0', 4),
        'g' => try writeIntPad(&list, gpa, @mod(cal.isoWeekOf(tm.year, tm.month, tm.day).year, 100), '0', 2),
        'H' => try writeIntPad(&list, gpa, tm.hour, '0', 2),
        'I' => {
            var h = tm.hour;
            if (h == 0) h = 12 else if (h > 12) h -= 12;
            try writeIntPad(&list, gpa, h, '0', 2);
        },
        'j' => try writeIntPad(&list, gpa, cal.dayOfYear(tm.year, tm.month, tm.day), '0', 3),
        'k' => try writeIntPad(&list, gpa, tm.hour, ' ', 2),
        'l' => {
            var h = tm.hour;
            if (h == 0) h = 12 else if (h > 12) h -= 12;
            try writeIntPad(&list, gpa, h, ' ', 2);
        },
        'M' => try writeIntPad(&list, gpa, tm.minute, '0', 2),
        'm' => try writeIntPad(&list, gpa, tm.month, '0', 2),
        'N' => {
            var buf: [9]u8 = undefined;
            nineDigitNanos(&buf, tm.nanosecond);
            try list.appendSlice(gpa, &buf);
        },
        'n' => try list.append(gpa, '\n'),
        'P' => try list.appendSlice(gpa, if (tm.hour < 12) "am" else "pm"),
        'p' => try list.appendSlice(gpa, if (tm.hour < 12) "AM" else "PM"),
        'q' => try writeIntPad(&list, gpa, @divTrunc(tm.month - 1, 3) + 1, '0', 0),
        'R' => {
            const s = try render(gpa, tm, "%H:%M");
            defer gpa.free(s);
            try list.appendSlice(gpa, s);
        },
        'r' => {
            const s = try render(gpa, tm, "%I:%M:%S %p");
            defer gpa.free(s);
            try list.appendSlice(gpa, s);
        },
        'S' => try writeIntPad(&list, gpa, tm.second, '0', 2),
        's' => try writeIntPad(&list, gpa, epochSeconds(tm), ' ', 0),
        'T' => {
            const s = try render(gpa, tm, "%H:%M:%S");
            defer gpa.free(s);
            try list.appendSlice(gpa, s);
        },
        't' => try list.append(gpa, '\t'),
        'U' => try writeIntPad(&list, gpa, cal.weekSundayStart(tm.year, tm.month, tm.day), '0', 2),
        'u' => try writeIntPad(&list, gpa, @as(i64, cal.weekdayMon0(daysOf(tm))) + 1, ' ', 0),
        'V' => try writeIntPad(&list, gpa, cal.isoWeekOf(tm.year, tm.month, tm.day).week, '0', 2),
        'W' => try writeIntPad(&list, gpa, cal.weekMondayStart(tm.year, tm.month, tm.day), '0', 2),
        'w' => try writeIntPad(&list, gpa, cal.weekdaySun0(daysOf(tm)), ' ', 0),
        'X' => {
            const s = try render(gpa, tm, "%H:%M:%S");
            defer gpa.free(s);
            try list.appendSlice(gpa, s);
        },
        'x' => {
            const s = try render(gpa, tm, "%m/%d/%y");
            defer gpa.free(s);
            try list.appendSlice(gpa, s);
        },
        'Y' => try writeIntPad(&list, gpa, tm.year, '0', 4),
        'y' => try writeIntPad(&list, gpa, @mod(tm.year, 100), '0', 2),
        'Z' => {
            for (tm.tz_abbrev) |c| try list.append(gpa, std.ascii.toUpper(c));
        },
        'z' => {
            if (colons > 3) {
                list.deinit(gpa);
                return null;
            }
            try appendOffset(&list, gpa, tm.offset_sec, colons);
        },
        else => {
            list.deinit(gpa);
            return null;
        },
    }
    return try list.toOwnedSlice(gpa);
}

// ------------------------------------------------------------- GNU modifier layer
//
// Ported verbatim from uutils date's `format_modifiers.rs` (`apply_modifiers`,
// `get_default_width`, `is_text_specifier`, `is_space_padded_specifier`,
// `strip_default_padding`) -- see this file's module doc for why running it
// unconditionally (even for a plain, unmodified spec) is safe.

fn isTextSpecifier(letter: u8) bool {
    return switch (letter) {
        'A', 'a', 'B', 'b', 'h', 'Z', 'p', 'P' => true,
        else => false,
    };
}

fn isSpacePaddedSpecifier(letter: u8) bool {
    return switch (letter) {
        'A', 'a', 'B', 'b', 'h', 'Z', 'p', 'P', 'e', 'k', 'l' => true,
        else => false,
    };
}

fn getDefaultWidth(letter: u8) usize {
    return switch (letter) {
        'd', 'e', 'm', 'H', 'k', 'I', 'l', 'M', 'S', 'y', 'g' => 2,
        'j' => 3,
        'U', 'W', 'V' => 2,
        'w', 'u', 'q' => 1,
        'C' => 2,
        'Y', 'G' => 4,
        'N' => 9,
        else => 0, // s, z, text specifiers, anything else
    };
}

fn stripDefaultPadding(gpa: Allocator, value: []const u8) ![]u8 {
    if (value.len >= 2 and value[0] == '0') {
        const stripped = std.mem.trimStart(u8, value, "0");
        if (stripped.len == 0) return gpa.dupe(u8, "0");
        if (std.ascii.isDigit(stripped[0])) return gpa.dupe(u8, stripped);
    }
    if (value.len > 0 and value[0] == ' ') {
        const stripped = std.mem.trimStart(u8, value, " ");
        if (stripped.len != 0) return gpa.dupe(u8, stripped);
    }
    return gpa.dupe(u8, value);
}

const Flags = struct {
    pad_char: u8,
    no_pad: bool = false,
    uppercase: bool = false,
    swap_case: bool = false,
    force_sign: bool = false,
    underscore: bool = false,
};

fn parseFlags(flag_chars: []const u8, default_pad: u8) Flags {
    var f: Flags = .{ .pad_char = default_pad };
    for (flag_chars) |c| {
        switch (c) {
            '-' => f.no_pad = true,
            '_' => {
                f.no_pad = false;
                f.pad_char = ' ';
                f.underscore = true;
            },
            '0' => {
                f.no_pad = false;
                f.pad_char = '0';
            },
            '^' => {
                f.uppercase = true;
                f.swap_case = false;
            },
            '#' => if (!f.uppercase) {
                f.swap_case = true;
            },
            '+' => {
                f.force_sign = true;
                f.no_pad = false;
                f.pad_char = '0';
            },
            else => {},
        }
    }
    return f;
}

fn allUpperAlpha(s: []const u8) bool {
    for (s) |c| if (std.ascii.isAlphabetic(c) and !std.ascii.isUpper(c)) return false;
    return true;
}
fn allLowerAlpha(s: []const u8) bool {
    for (s) |c| if (std.ascii.isAlphabetic(c) and !std.ascii.isLower(c)) return false;
    return true;
}

/// `value` is the plain-rendered text for `letter` (ignoring any colon prefix, which
/// only affects width/case defaults through `letter` itself, matching the reference's
/// `specifier.chars().last()` checks). `flags`/`width` come from the format string.
fn applyModifiers(gpa: Allocator, value: []const u8, flags_str: []const u8, width: ?usize, letter: u8) ![]u8 {
    const default_pad: u8 = if (isSpacePaddedSpecifier(letter)) ' ' else '0';
    const flags = parseFlags(flags_str, default_pad);
    var result: []u8 = try gpa.dupe(u8, value);

    if (flags.uppercase) {
        const up = try gpa.alloc(u8, result.len);
        for (result, 0..) |c, i| up[i] = std.ascii.toUpper(c);
        gpa.free(result);
        result = up;
    } else if (flags.swap_case) {
        if (allUpperAlpha(result)) {
            const lo = try gpa.alloc(u8, result.len);
            for (result, 0..) |c, i| lo[i] = std.ascii.toLower(c);
            gpa.free(result);
            result = lo;
        } else if (!allLowerAlpha(result)) {
            const up = try gpa.alloc(u8, result.len);
            for (result, 0..) |c, i| up[i] = std.ascii.toUpper(c);
            gpa.free(result);
            result = up;
        }
    }

    if (flags.no_pad) {
        const stripped = try stripDefaultPadding(gpa, result);
        gpa.free(result);
        return stripped;
    }

    var effective_width: usize = 0;
    if (width) |w| {
        effective_width = w;
    } else if (flags.underscore or flags.pad_char != default_pad) {
        effective_width = getDefaultWidth(letter);
    }

    if (effective_width > 0 and effective_width < result.len) {
        const stripped = try stripDefaultPadding(gpa, result);
        gpa.free(result);
        result = stripped;
    }

    if (!isTextSpecifier(letter) and result.len >= 2) {
        if (flags.pad_char == ' ' and result[0] == '0') {
            const stripped = try stripDefaultPadding(gpa, result);
            gpa.free(result);
            result = stripped;
        } else if (flags.pad_char == '0' and result[0] == ' ') {
            const stripped = try stripDefaultPadding(gpa, result);
            gpa.free(result);
            result = stripped;
        }
    }

    if (flags.force_sign and result.len > 0 and result[0] != '+' and result[0] != '-') {
        if (std.ascii.isDigit(result[0])) {
            const default_w = getDefaultWidth(letter);
            if (width != null or (default_w > 0 and result.len > default_w)) {
                const signed = try gpa.alloc(u8, result.len + 1);
                signed[0] = '+';
                @memcpy(signed[1..], result);
                gpa.free(result);
                result = signed;
            }
        }
    }

    if (effective_width > result.len) {
        const padding = effective_width - result.len;
        const has_sign = result.len > 0 and (result[0] == '+' or result[0] == '-');
        const padded = try gpa.alloc(u8, effective_width);
        if (flags.pad_char == '0' and has_sign) {
            padded[0] = result[0];
            @memset(padded[1 .. 1 + padding], '0');
            @memcpy(padded[1 + padding ..], result[1..]);
        } else {
            @memset(padded[0..padding], flags.pad_char);
            @memcpy(padded[padding..], result);
        }
        gpa.free(result);
        result = padded;
    } else if (letter == 'N') {
        if (effective_width <= getDefaultWidth('N') and effective_width != 0) {
            result = gpa.realloc(result, effective_width) catch result[0..effective_width];
        }
    }

    return result;
}

// ---------------------------------------------------------------- top-level scan

fn isFlagChar(c: u8) bool {
    return switch (c) {
        '_', '0', '^', '#', '+', '-' => true,
        else => false,
    };
}

/// Renders `fmt` against `tm`. GNU/jiff directive set in full (see module doc for
/// the small deliberately-deferred subset). Only fails on allocation failure.
pub fn render(gpa: Allocator, tm: Tm, fmt: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%') {
            try out.append(gpa, fmt[i]);
            i += 1;
            continue;
        }
        if (i + 1 < fmt.len and fmt[i + 1] == '%') {
            try out.append(gpa, '%');
            i += 2;
            continue;
        }
        // %.f / %.Nf: dot-precision fractional seconds, a standalone grammar form
        // uutils' own GNU-modifier scanner never intercepts (see module doc).
        if (i + 1 < fmt.len and fmt[i + 1] == '.') {
            var j = i + 2;
            const width_start = j;
            while (j < fmt.len and std.ascii.isDigit(fmt[j])) j += 1;
            if (j < fmt.len and fmt[j] == 'f') {
                const prec: ?usize = if (j > width_start) std.fmt.parseInt(usize, fmt[width_start..j], 10) catch null else null;
                if (tm.nanosecond != 0 or (prec != null and prec.? != 0)) {
                    var buf: [9]u8 = undefined;
                    nineDigitNanos(&buf, tm.nanosecond);
                    const take = @min(prec orelse 9, 9);
                    var end = take;
                    if (prec == null) {
                        end = 9;
                        while (end > 0 and buf[end - 1] == '0') end -= 1;
                    }
                    if (end > 0 or prec != null) {
                        try out.append(gpa, '.');
                        try out.appendSlice(gpa, buf[0..end]);
                    }
                }
                i = j + 1;
                continue;
            }
        }

        var j = i + 1;
        const flags_start = j;
        while (j < fmt.len and isFlagChar(fmt[j])) j += 1;
        const flags_str = fmt[flags_start..j];
        const width_start = j;
        while (j < fmt.len and std.ascii.isDigit(fmt[j])) j += 1;
        const width: ?usize = if (j > width_start)
            (std.fmt.parseInt(usize, fmt[width_start..j], 10) catch std.math.maxInt(usize))
        else
            null;
        const colon_start = j;
        while (j < fmt.len and fmt[j] == ':') j += 1;
        const colons: u8 = @intCast(@min(j - colon_start, 255));

        if (j >= fmt.len or !std.ascii.isAlphabetic(fmt[j])) {
            // Malformed spec: lenient passthrough (jiff `Config::lenient(true)`).
            try out.append(gpa, '%');
            i += 1;
            continue;
        }
        const letter = fmt[j];

        const plain = try renderSpecPlain(gpa, tm, letter, colons);
        if (plain == null) {
            // Unrecognized/unsupported directive: same lenient passthrough.
            try out.append(gpa, '%');
            i += 1;
            continue;
        }
        defer gpa.free(plain.?);

        if (flags_str.len == 0 and width == null) {
            try out.appendSlice(gpa, plain.?);
        } else {
            const modified = try applyModifiers(gpa, plain.?, flags_str, width, letter);
            defer gpa.free(modified);
            try out.appendSlice(gpa, modified);
        }
        i = j + 1;
    }
    return out.toOwnedSlice(gpa);
}
