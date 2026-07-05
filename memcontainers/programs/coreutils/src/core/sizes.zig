//! Shared human-size parsing (DESIGN.md §6). Several applets accept a "digits + optional
//! one-letter multiplier suffix" size argument, but with small grammar differences:
//!   - `sort -S`   : k/K m/M g/G (1024^n), a bare `b` = 1, case-insensitive.
//!   - `truncate -s`: K/M/G (1024^n) only, uppercase, no `b`.
//! This module factors the common parser and expresses those differences through
//! `Options`, so the two applets stop carrying near-identical private copies.
//!
//! NOT covered here: `split`'s size grammar. That one is a much larger uucore port
//! (decimal/octal/hex/binary literals + the full IEC KiB.. and SI KB.. unit ladders, in
//! u128) with its own semantics; it stays in `split.zig` rather than being force-fit here.

const std = @import("std");

pub const Options = struct {
    /// Multiplier base for the letter suffixes (1024 for K=KiB, 1000 for K=KB).
    base: u64 = 1024,
    /// Accept a lowercase suffix letter as well as uppercase (`k` == `K`). When false,
    /// only uppercase suffixes are recognized.
    case_insensitive: bool = true,
    /// Accept a bare `b`/`B` suffix meaning x1 (sort's grammar). When false, `b` is invalid.
    allow_b: bool = false,
};

/// Parse `s` as digits followed by an optional single multiplier suffix (k/m/g → base^1..3,
/// or `b` = 1 when `opts.allow_b`). Returns the byte count, or null on any malformed input
/// (empty, non-digit body, unknown/oversized suffix, or overflow).
pub fn parse(s: []const u8, opts: Options) ?u64 {
    if (s.len == 0) return null;

    // Split off an optional trailing single-letter suffix.
    var body = s;
    var mult: u64 = 1;
    const last = s[s.len - 1];
    if (last < '0' or last > '9') {
        mult = suffixMult(last, opts) orelse return null;
        body = s[0 .. s.len - 1];
        if (body.len == 0) return null; // suffix with no digits
    }

    var v: u64 = 0;
    for (body) |c| {
        if (c < '0' or c > '9') return null;
        v = std.math.mul(u64, v, 10) catch return null;
        v = std.math.add(u64, v, c - '0') catch return null;
    }
    return std.math.mul(u64, v, mult) catch null;
}

fn suffixMult(c_in: u8, opts: Options) ?u64 {
    const c = if (opts.case_insensitive) std.ascii.toUpper(c_in) else c_in;
    if (opts.allow_b and c == 'B') return 1;
    return switch (c) {
        'K' => opts.base,
        'M' => opts.base * opts.base,
        'G' => opts.base * opts.base * opts.base,
        else => null,
    };
}
