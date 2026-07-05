//! Calendar helpers shared by `format.zig` and `parse.zig`, built entirely on top of
//! `core/civil.zig`'s Hinnant day-count conversion (reused, not modified -- DESIGN.md
//! §7.8). Everything here is proleptic-Gregorian, UTC-agnostic pure math: weekday,
//! ISO-8601 week-date, day-of-year, month-length/leap-year, and the GNU "add N months
//! with end-of-month clamp + shortfall overflow" rule used by relative `+1 month`
//! items. English (C-locale) month/weekday name tables live here too since both
//! engine halves need them.

const std = @import("std");
const civil = @import("../../core/civil.zig");

pub const CivilDate = civil.CivilDate;

pub fn isLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

const DAYS_IN_MONTH = [12]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

/// `month` in `[1,12]`.
pub fn daysInMonth(year: i64, month: u32) u32 {
    if (month == 2 and isLeapYear(year)) return 29;
    return DAYS_IN_MONTH[month - 1];
}

/// Weekday of the given day-count, Monday=0 .. Sunday=6 (`%u`-1 / civil-weekday order).
/// Day 0 (1970-01-01, the Unix epoch) is a Thursday, so `days_since_epoch=0 -> 3`.
pub fn weekdayMon0(days_since_epoch: i64) u3 {
    return @intCast(@mod(days_since_epoch + 3, 7));
}

/// Weekday of the given day-count, Sunday=0 .. Saturday=6 (`%w` order).
pub fn weekdaySun0(days_since_epoch: i64) u3 {
    return @intCast(@mod(days_since_epoch + 4, 7));
}

/// 1-based day-of-year (`%j`), `[1, 365 or 366]`.
pub fn dayOfYear(year: i64, month: u32, day: u32) u32 {
    const first = civil.daysFromCivil(year, 1, 1);
    const this_day = civil.daysFromCivil(year, month, day);
    return @intCast(this_day - first + 1);
}

pub const IsoWeek = struct { year: i64, week: u32 };

/// ISO 8601 week-date (`%G`/`%g`/`%V`): the ISO week-year is the year containing the
/// Thursday of the same (Monday-starting) week; the week number is that Thursday's
/// ordinal day-of-year, divided into 7-day chunks. Standard algorithm.
pub fn isoWeekOf(year: i64, month: u32, day: u32) IsoWeek {
    const days = civil.daysFromCivil(year, month, day);
    const mon0 = weekdayMon0(days); // 0=Mon .. 6=Sun
    const thursday_days = days + (@as(i64, 3) - @as(i64, mon0)); // shift to this week's Thursday
    const iso_year = civil.civilFromDays(thursday_days).year;
    const jan1 = civil.daysFromCivil(iso_year, 1, 1);
    const ordinal = thursday_days - jan1 + 1; // 1-based day-of-year of that Thursday
    const week: u32 = @intCast(@divTrunc(ordinal - 1, 7) + 1);
    return .{ .year = iso_year, .week = week };
}

/// `%U`: week number, week 1 starts on the first Sunday of the year (days before it
/// are week 0).
pub fn weekSundayStart(year: i64, month: u32, day: u32) u32 {
    const doy: i64 = dayOfYear(year, month, day);
    const wsun: i64 = weekdaySun0(civil.daysFromCivil(year, month, day)); // 0=Sun..6=Sat
    return @intCast(@divTrunc(doy + 6 - wsun, 7));
}

/// `%W`: week number, week 1 starts on the first Monday of the year.
pub fn weekMondayStart(year: i64, month: u32, day: u32) u32 {
    const doy: i64 = dayOfYear(year, month, day);
    const wsun: i64 = weekdaySun0(civil.daysFromCivil(year, month, day)); // 0=Sun..6=Sat
    const wmon0 = @mod(wsun + 6, 7); // 0=Mon..6=Sun
    return @intCast(@divTrunc(doy + 6 - wmon0, 7));
}

pub const ClampedDate = struct { year: i64, month: u32, day: u32, shortfall_days: i64 };

/// GNU's relative year/month arithmetic (builder.rs `build()` step 4d comment): add
/// `delta_months` treating day-of-month as fixed; if the target month is too short,
/// clamp to its last day and return the shortfall so the caller can add it back as
/// *days* (overflowing into the next month) -- e.g. Jan 31 + 1 month -> clamp to Feb
/// 29 (2024) -> +2 shortfall days -> Mar 2. Works for `Relative::Years` too (GNU
/// implements years as `delta_months = years*12`).
pub fn addMonthsClamped(year: i64, month: u32, day: u32, delta_months: i64) ClampedDate {
    const total = year * 12 + @as(i64, month - 1) + delta_months;
    const y2 = @divFloor(total, 12);
    const m2: u32 = @intCast(@mod(total, 12) + 1);
    const dim = daysInMonth(y2, m2);
    const d2: u32 = if (day > dim) dim else day;
    return .{ .year = y2, .month = m2, .day = d2, .shortfall_days = @as(i64, day) - @as(i64, d2) };
}

/// Applies `addMonthsClamped` and folds the shortfall back in as whole days, giving
/// the final resolved civil date (matching builder.rs's two-step month/year add).
pub fn addMonths(year: i64, month: u32, day: u32, delta_months: i64) CivilDate {
    const c = addMonthsClamped(year, month, day, delta_months);
    if (c.shortfall_days == 0) return .{ .year = c.year, .month = c.month, .day = c.day };
    const days = civil.daysFromCivil(c.year, c.month, c.day) + c.shortfall_days;
    return civil.civilFromDays(days);
}

// English (C-locale) name tables -- hardcoded per the task (no locale plumbing).
pub const WEEKDAY_FULL = [7][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };
pub const WEEKDAY_ABBR = [7][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
pub const MONTH_FULL = [12][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
pub const MONTH_ABBR = [12][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
