//! AWK scalar value model -- byte-exact port of awk-rs 0.1.0's `src/value.rs`
//! (reference/crates/awk-rs-0.1.0/src/value.rs). This is the parity ORACLE: every
//! coercion rule here -- including its quirks -- is deliberately replicated, not
//! "fixed", per the awk applet's parity contract.
//!
//! Key quirks inherited from the oracle (see docs/parity-ledger.md for the full
//! writeup):
//!   - A STRING LITERAL that looks numeric (e.g. `"10"`) becomes a `numeric_string`
//!     exactly like a field value would -- awk-rs has no separate "STRNUM" concept
//!     tied to provenance (input vs. literal). `Value.fromStr` is the ONE place any
//!     raw string becomes a Value, called uniformly for literals, fields, split()
//!     results, sub/gsub targets, etc. -- so this conflation happens everywhere,
//!     automatically, by construction.
//!   - Number->string conversion ALWAYS uses the hardcoded `%.6g`-equivalent
//!     algorithm below, regardless of OFMT/CONVFMT's actual value (those variables
//!     are inert storage in the oracle -- see interp.zig).
//!   - NaN sorts/compares as "equal" to anything (Rust's `partial_cmp().unwrap_or
//!     (Equal)`), replicated in `compare`.
//!   - `parse_leading_number`'s whitespace class is the 5-char Rust
//!     `u8::is_ascii_whitespace` set (space/tab/LF/FF/CR, NOT vertical tab); the
//!     numeric-string classifier's `trim()` is modeled on a 6-char set that DOES
//!     include vertical tab -- an inconsistency present in the oracle itself,
//!     replicated faithfully rather than unified.

const std = @import("std");
const fmtnum = @import("../../core/fmtnum.zig");

pub const Value = union(enum) {
    uninitialized,
    number: f64,
    string: []const u8,
    numeric_string: NumStr,

    pub const NumStr = struct { s: []const u8, n: f64 };

    /// `Value.uninitialized` (bare, dot-accessed off the type) resolves to the
    /// union's tag enum, not a union instance -- use this constant (or the
    /// explicit `Value{ .uninitialized = {} }` form) to construct the value.
    pub const UNINIT: Value = .{ .uninitialized = {} };

    /// Value::from_string: classifies `s` as a numeric string (if it parses fully
    /// as a number, ignoring surrounding whitespace) or a plain string. Called for
    /// EVERY raw string that becomes a Value anywhere in the interpreter (literals,
    /// fields, split() parts, sub/gsub/substr/tolower/... results, getline lines,
    /// ARGV/ENVIRON entries) -- see module doc.
    pub fn fromStr(s: []const u8) Value {
        if (parseNumericStringFull(s)) |n| return .{ .numeric_string = .{ .s = s, .n = n } };
        return .{ .string = s };
    }

    pub fn fromNumber(n: f64) Value {
        return .{ .number = n };
    }

    /// Value::is_truthy.
    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .uninitialized => false,
            .number => |n| n != 0.0,
            .string => |s| s.len != 0,
            .numeric_string => |ns| ns.s.len != 0,
        };
    }

    /// Value::to_number.
    pub fn toNumber(self: Value) f64 {
        return switch (self) {
            .uninitialized => 0.0,
            .number => |n| n,
            .string => |s| parseLeadingNumber(s),
            .numeric_string => |ns| ns.n,
        };
    }

    /// Value::to_string_val / Value::as_str -- in the oracle these are two
    /// functions with identical output (one avoids allocation via Cow); we only
    /// need the one behavior. `buf` must be >= 512 bytes for the Number case
    /// (see formatNumberDefault); the String/NumericString/Uninitialized cases
    /// borrow, no buffer needed.
    pub fn toStringVal(self: Value, buf: []u8) []const u8 {
        return switch (self) {
            .uninitialized => "",
            .number => |n| formatNumberDefault(buf, n),
            .string => |s| s,
            .numeric_string => |ns| ns.s,
        };
    }

    /// Allocating counterpart of toStringVal, for call sites that can't offer a
    /// scratch buffer live across the call (e.g. building a Concat result piece by
    /// piece into an ArrayList).
    pub fn toStringValAlloc(self: Value, gpa: std.mem.Allocator) ![]const u8 {
        switch (self) {
            .number => |n| {
                var buf: [512]u8 = undefined;
                return gpa.dupe(u8, formatNumberDefault(&buf, n));
            },
            else => return self.toStringVal(&[0]u8{}),
        }
    }

    /// Value::compares_as_number.
    pub fn comparesAsNumber(self: Value) bool {
        return switch (self) {
            .string => false,
            else => true,
        };
    }
};

/// compare_values: numeric compare iff BOTH sides "compare as number"; otherwise a
/// byte compare of each side's string form. NaN compares Equal to anything (Rust's
/// `partial_cmp(..).unwrap_or(Equal)`).
pub fn compare(l: Value, r: Value) std.math.Order {
    if (l.comparesAsNumber() and r.comparesAsNumber()) {
        const a = l.toNumber();
        const b = r.toNumber();
        if (std.math.isNan(a) or std.math.isNan(b)) return .eq;
        if (a < b) return .lt;
        if (a > b) return .gt;
        return .eq;
    }
    var lbuf: [512]u8 = undefined;
    var rbuf: [512]u8 = undefined;
    return std.mem.order(u8, l.toStringVal(&lbuf), r.toStringVal(&rbuf));
}

/// Rust's `u8::is_ascii_whitespace`: space, tab, LF, FF, CR (NOT vertical tab).
fn isRustAsciiWs(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == 0x0C or b == '\r';
}

/// The broader class used to model Rust's (Unicode-aware) `str::trim()` as used by
/// `parse_numeric_string`, restricted to ASCII: adds vertical tab (0x0B) versus
/// `isRustAsciiWs` above -- see module doc on the oracle's own inconsistency.
fn isTrimWs(b: u8) bool {
    return isRustAsciiWs(b) or b == 0x0B;
}

fn trimWs(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and isTrimWs(s[start])) start += 1;
    while (end > start and isTrimWs(s[end - 1])) end -= 1;
    return s[start..end];
}

/// parse_leading_number: lenient prefix scan (whitespace, optional sign, digits,
/// optional `.digits`, optional exponent with its own optional sign) -- garbage
/// after a valid prefix is silently ignored; no digits at all -> 0.0.
pub fn parseLeadingNumber(s: []const u8) f64 {
    var i: usize = 0;
    while (i < s.len and isRustAsciiWs(s[i])) i += 1;
    if (i >= s.len) return 0.0;
    const start = i;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    var has_digits = false;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) has_digits = true;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) has_digits = true;
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        const exp_start = i;
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        if (i < s.len and std.ascii.isDigit(s[i])) {
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        } else {
            i = exp_start; // invalid exponent: back up, exponent text is not consumed
        }
    }
    if (!has_digits) return 0.0;
    return std.fmt.parseFloat(f64, s[start..i]) catch 0.0;
}

/// parse_numeric_string: `s.trim()`'s content must be ENTIRELY a number (optional
/// sign, digits/one-dot/one-exponent) to qualify; returns the parsed value, or
/// `null` if `s` (trimmed) isn't a pure number. The char-class scan mirrors the
/// oracle's own (slightly loose -- see module doc) pre-filter; final acceptance
/// always goes through a strict float parse.
fn parseNumericStringFull(s: []const u8) ?f64 {
    const trimmed = trimWs(s);
    if (trimmed.len == 0) return null;

    var all_digits = true;
    for (trimmed) |b| {
        if (!std.ascii.isDigit(b)) {
            all_digits = false;
            break;
        }
    }
    if (all_digits) return std.fmt.parseFloat(f64, trimmed) catch null;

    const check = if (trimmed[0] == '-' or trimmed[0] == '+') trimmed[1..] else trimmed;
    var has_dot = false;
    var has_e = false;
    for (check, 0..) |b, i| {
        switch (b) {
            '0'...'9' => {},
            '.' => {
                if (has_dot or has_e) return null;
                has_dot = true;
            },
            'e', 'E' => {
                if (has_e or i == 0) return null;
                has_e = true;
            },
            '+', '-' => {
                if (!has_e) return null;
            },
            else => return null,
        }
    }
    return std.fmt.parseFloat(f64, trimmed) catch null;
}

/// format_number(n, "%.6g") -- the ONLY format string ever used by the oracle (see
/// module doc): NaN -> "nan", +-Inf -> "inf"/"-inf"; a whole number with
/// |n| < 1e15 prints with no fractional part; otherwise render fixed to 6 decimal
/// places (correctly rounded, via fmtnum's decimal engine) and strip trailing
/// fraction zeros (and a bare trailing '.' if the whole fraction was zeros).
/// `buf` must be >= 512 bytes (covers f64's <=309 integer digits plus slack).
pub fn formatNumberDefault(buf: []u8, n: f64) []const u8 {
    if (std.math.isNan(n)) return "nan";
    if (std.math.isInf(n)) return if (n > 0) "inf" else "-inf";

    if (@trunc(n) == n and @abs(n) < 1e15) {
        const asI: i64 = @intFromFloat(n);
        return std.fmt.bufPrint(buf, "{d}", .{asI}) catch unreachable;
    }

    const rendered = fmtnum.renderFloat(buf, .{ .conv = 'f', .precision = 6 }, n) catch blk: {
        // Buffer too small (astronomically large n): fall back to scientific,
        // which fmtnum guarantees fits any f64 in <=512 bytes; never hit in
        // practice since `buf` is sized generously by every call site.
        break :blk fmtnum.renderFloat(buf, .{ .conv = 'e', .precision = 6 }, n) catch "0";
    };
    if (std.mem.indexOfScalar(u8, rendered, '.') == null) return rendered;
    var end = rendered.len;
    while (end > 0 and rendered[end - 1] == '0') end -= 1;
    if (end > 0 and rendered[end - 1] == '.') end -= 1;
    return rendered[0..end];
}
