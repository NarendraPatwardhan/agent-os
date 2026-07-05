//! Hinnant's `civil_from_days`/`days_from_civil` (http://howardhinnant.github.io/date_algorithms.html),
//! the classic branch-free proleptic-Gregorian <-> day-count conversion, plus the two
//! fixed-format renderers `ls`/`stat` need. UTC only -- no tzdb (DESIGN.md §6 table;
//! that lives in `engines/datetime` for `date` alone, out of scope for M1a).

const std = @import("std");

pub const CivilDate = struct { year: i64, month: u32, day: u32 };

const MS_PER_DAY: i64 = 86_400_000;

/// Days since the epoch (1970-01-01) for the given proleptic-Gregorian date. Negative
/// for dates before the epoch. `month` in `[1,12]`, `day` in `[1, last_day_of_month]`.
pub fn daysFromCivil(year: i64, month: u32, day: u32) i64 {
    var y = year;
    const m: i64 = @intCast(month);
    const d: i64 = @intCast(day);
    y -= if (m <= 2) @as(i64, 1) else 0;
    const era: i64 = @divTrunc(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const doy: i64 = @divTrunc(153 * (m + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) + d - 1; // [0, 365]
    const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// Inverse of `daysFromCivil`.
pub fn civilFromDays(z_in: i64) CivilDate {
    const z = z_in + 719468;
    const era: i64 = @divTrunc(if (z >= 0) z else z - 146096, 146097);
    const doe: i64 = z - era * 146097; // [0, 146096]
    const yoe: i64 = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365); // [0, 399]
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100)); // [0, 365]
    const mp: i64 = @divTrunc(5 * doy + 2, 153); // [0, 11]
    const d: i64 = doy - @divTrunc(153 * mp + 2, 5) + 1; // [1, 31]
    const m: i64 = mp + (if (mp < 10) @as(i64, 3) else -9); // [1, 12]
    const year = y + (if (m <= 2) @as(i64, 1) else 0);
    return .{ .year = year, .month = @intCast(m), .day = @intCast(d) };
}

const Broken = struct { date: CivilDate, hh: u32, mm: u32, ss: u32 };

fn breakDown(ms: i64) Broken {
    const days = @divFloor(ms, MS_PER_DAY);
    const tod = ms - days * MS_PER_DAY; // in [0, MS_PER_DAY)
    const date = civilFromDays(days);
    const hh: u32 = @intCast(@divTrunc(tod, 3_600_000));
    const mm: u32 = @intCast(@mod(@divTrunc(tod, 60_000), 60));
    const ss: u32 = @intCast(@mod(@divTrunc(tod, 1_000), 60));
    return .{ .date = date, .hh = hh, .mm = mm, .ss = ss };
}

/// Writes `value` zero-padded to `width` decimal digits at `buf[off..]`, returns the
/// new offset. Assumes `value` fits in `width` digits (true for the y/m/d/h/m/s ranges
/// this module is used for).
fn writePad(buf: []u8, off: usize, value: u32, width: usize) usize {
    var v = value;
    var i = off + width;
    const stop = off;
    while (i > stop) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    return off + width;
}

/// `YYYY-MM-DD HH:MM`, UTC (ls's long-format timestamp).
pub fn formatYmdHm(buf: []u8, ms: i64) []const u8 {
    const b = breakDown(ms);
    var off: usize = 0;
    off = writePad(buf, off, @intCast(b.date.year), 4);
    buf[off] = '-';
    off += 1;
    off = writePad(buf, off, b.date.month, 2);
    buf[off] = '-';
    off += 1;
    off = writePad(buf, off, b.date.day, 2);
    buf[off] = ' ';
    off += 1;
    off = writePad(buf, off, b.hh, 2);
    buf[off] = ':';
    off += 1;
    off = writePad(buf, off, b.mm, 2);
    return buf[0..off];
}

/// `YYYY-MM-DD HH:MM:SS`, UTC (stat's timestamp).
pub fn formatYmdHms(buf: []u8, ms: i64) []const u8 {
    const b = breakDown(ms);
    var off: usize = 0;
    off = writePad(buf, off, @intCast(b.date.year), 4);
    buf[off] = '-';
    off += 1;
    off = writePad(buf, off, b.date.month, 2);
    buf[off] = '-';
    off += 1;
    off = writePad(buf, off, b.date.day, 2);
    buf[off] = ' ';
    off += 1;
    off = writePad(buf, off, b.hh, 2);
    buf[off] = ':';
    off += 1;
    off = writePad(buf, off, b.mm, 2);
    buf[off] = ':';
    off += 1;
    off = writePad(buf, off, b.ss, 2);
    return buf[0..off];
}

/// Inverse: civil date + time-of-day -> milliseconds since the epoch, UTC.
pub fn epochMsFromCivil(year: i64, month: u32, day: u32, hh: u32, mm: u32, ss: u32) i64 {
    const days = daysFromCivil(year, month, day);
    return days * MS_PER_DAY + @as(i64, hh) * 3_600_000 + @as(i64, mm) * 60_000 + @as(i64, ss) * 1000;
}
