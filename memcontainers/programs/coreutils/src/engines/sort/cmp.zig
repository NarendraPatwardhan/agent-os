//! Comparison modes for `sort` (DESIGN.md §1): `parse_num`/
//! `human_val`/`version_cmp`/`str_cmp` plus `total_cmp`. Applet-private.

const std = @import("std");
const key_mod = @import("key.zig");
const Key = key_mod.Key;
const Mode = key_mod.Mode;
const isBlank = key_mod.isBlank;

pub const Order = std.math.Order;

pub fn invert(o: Order) Order {
    return switch (o) {
        .lt => .gt,
        .gt => .lt,
        .eq => .eq,
    };
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isPrintable(c: u8) bool {
    return c >= 0x20 and c < 0x7F;
}

fn isAlnum(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn toUpperAscii(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

const Mantissa = struct { value: f64, neg: bool, any: bool, pos: usize };

/// Shared prefix of `-n`/`-g`/`-h`: skip leading blanks, an optional sign, integer
/// digits, and a `.frac` part. Returns the unsigned magnitude, the sign, whether any
/// digit was seen, and the index just past the consumed mantissa (where `-g`'s exponent
/// / `-h`'s suffix begins). Leading blanks are always skipped, independent of the field's
/// own `-b`/`b` (which only controls where the FIELD starts, source: spec, GNU-consistent).
fn parseMantissa(s: []const u8) Mantissa {
    var i: usize = 0;
    while (i < s.len and isBlank(s[i])) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        neg = s[i] == '-';
        i += 1;
    }
    var mant: f64 = 0;
    var any = false;
    while (i < s.len and isDigit(s[i])) : (i += 1) {
        any = true;
        mant = mant * 10 + @as(f64, @floatFromInt(s[i] - '0'));
    }
    if (i < s.len and s[i] == '.') {
        i += 1;
        var scale: f64 = 0.1;
        while (i < s.len and isDigit(s[i])) : (i += 1) {
            any = true;
            mant += @as(f64, @floatFromInt(s[i] - '0')) * scale;
            scale *= 0.1;
        }
    }
    return .{ .value = mant, .neg = neg, .any = any, .pos = i };
}

/// `-n`: leading numeric prefix (no exponent). No digits anywhere -> 0.0.
pub fn parseNum(s: []const u8) f64 {
    const m = parseMantissa(s);
    if (!m.any) return 0.0;
    return if (m.neg) -m.value else m.value;
}

/// `-g`: like `parseNum` but also accepts an `e`/`E` exponent.
pub fn parseGeneral(s: []const u8) f64 {
    const m = parseMantissa(s);
    if (!m.any) return 0.0;
    var exp: f64 = 0;
    const i = m.pos;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var j = i + 1;
        var eneg = false;
        if (j < s.len and (s[j] == '+' or s[j] == '-')) {
            eneg = s[j] == '-';
            j += 1;
        }
        var ev: f64 = 0;
        var any_e = false;
        while (j < s.len and isDigit(s[j])) : (j += 1) {
            any_e = true;
            ev = ev * 10 + @as(f64, @floatFromInt(s[j] - '0'));
        }
        if (any_e) exp = if (eneg) -ev else ev;
    }
    const v = m.value * std.math.pow(f64, 10, exp);
    return if (m.neg) -v else v;
}

/// `-h`: mantissa (no exponent) x 1024^suffix, suffix in K<M<G<T<P<E (uppercase only,
/// per the matrix's own listing).
pub fn parseHuman(s: []const u8) f64 {
    const m = parseMantissa(s);
    if (!m.any) return 0.0;
    const mant = m.value;
    const i = m.pos;
    const neg = m.neg;
    var mult: f64 = 1;
    if (i < s.len) {
        mult = switch (s[i]) {
            'K' => std.math.pow(f64, 1024, 1),
            'M' => std.math.pow(f64, 1024, 2),
            'G' => std.math.pow(f64, 1024, 3),
            'T' => std.math.pow(f64, 1024, 4),
            'P' => std.math.pow(f64, 1024, 5),
            'E' => std.math.pow(f64, 1024, 6),
            else => 1,
        };
    }
    const v = mant * mult;
    return if (neg) -v else v;
}

pub fn numCmp(a: f64, b: f64) Order {
    if (a < b) return .lt;
    if (a > b) return .gt;
    return .eq;
}

/// `-V`: digit runs compared by numeric magnitude (leading zeros stripped; equal
/// magnitude broken by leading-zero count DESCENDING -- `007 < 07 < 7`, matching
/// GNU filevercmp's fractional-part rule), everything else bytewise. Simplified
/// strverscmp -- not bug-for-bug glibc-compatible on adversarial inputs;
/// source: spec (DESIGN.md §2).
pub fn versionCmp(a: []const u8, b: []const u8) Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const ca = a[i];
        const cb = b[j];
        if (isDigit(ca) and isDigit(cb)) {
            const a_start = i;
            while (i < a.len and isDigit(a[i])) i += 1;
            const b_start = j;
            while (j < b.len and isDigit(b[j])) j += 1;
            const a_run = a[a_start..i];
            const b_run = b[b_start..j];
            var az: usize = 0;
            while (az + 1 < a_run.len and a_run[az] == '0') az += 1;
            var bz: usize = 0;
            while (bz + 1 < b_run.len and b_run[bz] == '0') bz += 1;
            const a_val = a_run[az..];
            const b_val = b_run[bz..];
            if (a_val.len != b_val.len) return if (a_val.len < b_val.len) .lt else .gt;
            const c = std.mem.order(u8, a_val, b_val);
            if (c != .eq) return c;
            // equal magnitude: more leading zeros sorts FIRST (GNU filevercmp).
            if (a_run.len != b_run.len) return if (a_run.len > b_run.len) .lt else .gt;
            continue;
        }
        if (ca != cb) return if (ca < cb) .lt else .gt;
        i += 1;
        j += 1;
    }
    if (i < a.len) return .gt;
    if (j < b.len) return .lt;
    return .eq;
}

/// `-f`/`-d`/`-i` on-the-fly filtered comparison: walks both slices skipping
/// characters that fail the dict/ignore-nonprinting filters, case-folding when `-f`.
pub fn strCmpFiltered(a: []const u8, b: []const u8, fold: bool, dict: bool, ignore_nonprinting: bool) Order {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and !passesFilter(a[i], dict, ignore_nonprinting)) i += 1;
        while (j < b.len and !passesFilter(b[j], dict, ignore_nonprinting)) j += 1;
        const ae = i >= a.len;
        const be = j >= b.len;
        if (ae and be) return .eq;
        if (ae) return .lt;
        if (be) return .gt;
        var ca = a[i];
        var cb = b[j];
        if (fold) {
            ca = toUpperAscii(ca);
            cb = toUpperAscii(cb);
        }
        if (ca != cb) return if (ca < cb) .lt else .gt;
        i += 1;
        j += 1;
    }
}

fn passesFilter(c: u8, dict: bool, ignore_nonprinting: bool) bool {
    if (dict and !(isBlank(c) or isAlnum(c))) return false;
    if (ignore_nonprinting and !isPrintable(c)) return false;
    return true;
}

fn keyCmp(k: Key, a_line: []const u8, b_line: []const u8, sep: ?u8) Order {
    const key_mod_extract = key_mod.extractKey;
    const ak = key_mod_extract(a_line, k, sep);
    const bk = key_mod_extract(b_line, k, sep);
    var ord: Order = switch (k.mode) {
        .default => strCmpFiltered(ak, bk, k.fold, k.dict, k.ignore_nonprinting),
        .numeric => numCmp(parseNum(ak), parseNum(bk)),
        .general => numCmp(parseGeneral(ak), parseGeneral(bk)),
        .human => numCmp(parseHuman(ak), parseHuman(bk)),
        .version => versionCmp(ak, bk),
    };
    if (k.reverse) ord = invert(ord);
    return ord;
}

/// All keys equal (ignores the whole-line last-resort) -- used for `-u` dedup and
/// `-c -u` disorder detection, both defined as "KEY equality" per the matrix.
pub fn keysEqual(a_line: []const u8, b_line: []const u8, keys: []const Key, sep: ?u8) bool {
    for (keys) |k| {
        if (keyCmp(k, a_line, b_line, sep) != .eq) return false;
    }
    return true;
}

/// Keys in order, each independently reversible; if all tie and `!stable`, a
/// whole-line bytewise last-resort (itself inheriting `global_reverse`, since it has
/// no per-key letters of its own to override with -- ruling recorded in
/// DESIGN.md §2: this is the SAME "unset letters inherit global" mechanism
/// applied uniformly, not a separate "flip the final result" step).
pub fn totalCmp(a_line: []const u8, b_line: []const u8, keys: []const Key, sep: ?u8, stable: bool, global_reverse: bool) Order {
    for (keys) |k| {
        const c = keyCmp(k, a_line, b_line, sep);
        if (c != .eq) return c;
    }
    if (stable) return .eq;
    var c = std.mem.order(u8, a_line, b_line);
    if (global_reverse) c = invert(c);
    return c;
}
