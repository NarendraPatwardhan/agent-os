//! Iterative backtracking shell-glob matcher (DESIGN.md §7.2): `*` (any run, incl.
//! empty), `?` (exactly one byte), `[...]` classes with `[!...]`/`[^...]` negation and
//! `a-z` ranges, a malformed (unterminated) `[` degrades to a literal `[`. No
//! recursion: the classic two-pointer "remember the last `*`" algorithm -- on a
//! mismatch, back up to the most recent `*` and advance its claimed run by one byte,
//! rather than recursing per candidate split point. Shared by `find` (`-name`/`-path`
//! and friends) and, later, `tar`/`zip`/`unzip`'s identical `glob_match` copies.
//!
//! No `.`/`/` special-casing here (that's the caller's job: find's `-name` matches
//! against a bare basename, `-path` against the whole operand-relative path, neither
//! of which needs glob.zig to know about path separators).

const std = @import("std");

fn foldLower(b: u8) u8 {
    return if (b >= 'A' and b <= 'Z') b + 32 else b;
}

fn foldEq(a: u8, b: u8, ci: bool) bool {
    if (a == b) return true;
    if (!ci) return false;
    return foldLower(a) == foldLower(b);
}

/// Finds the index of the `]` closing a `[...]` class opened at `open` (the index just
/// after the `[`). Handles a leading `!`/`^` negation and a `]` as the class's very
/// first member (`[]abc]` -- literal `]`). Returns `null` (malformed, no closer) when
/// none is found before the pattern ends.
fn findClassEnd(pattern: []const u8, open: usize) ?usize {
    var i = open;
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) i += 1;
    if (i < pattern.len and pattern[i] == ']') i += 1; // literal ']' as first member
    while (i < pattern.len and pattern[i] != ']') i += 1;
    if (i >= pattern.len) return null;
    return i;
}

/// Does byte `ch` fall in the class spanning `pattern[open..close)` (content only, not
/// including the brackets)? Ranges are `lo-hi`; a `-` that can't start a 3-byte range
/// (at the very end, or right after the optional negation marker with nothing after)
/// is a literal `-`.
fn classMatches(pattern: []const u8, open: usize, close: usize, ch: u8, ci: bool) bool {
    var i = open;
    var negate = false;
    if (i < close and (pattern[i] == '!' or pattern[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    while (i < close) {
        if (i + 2 < close and pattern[i + 1] == '-') {
            const lo = pattern[i];
            const hi = pattern[i + 2];
            if (ci) {
                const cf = foldLower(ch);
                if (cf >= foldLower(lo) and cf <= foldLower(hi)) matched = true;
            } else if (ch >= lo and ch <= hi) {
                matched = true;
            }
            i += 3;
        } else {
            if (foldEq(pattern[i], ch, ci)) matched = true;
            i += 1;
        }
    }
    return if (negate) !matched else matched;
}

/// If the pattern token at `pi` matches `ch`, returns the pattern index just past that
/// token (1 for a literal/`?`, `close+1` for a bracket expression); else `null`. A
/// valid-but-non-matching bracket expression returns `null` too (it must NOT degrade to
/// matching a literal `[`) -- only a genuinely unterminated `[` does that.
fn matchOne(pattern: []const u8, pi: usize, ch: u8, ci: bool) ?usize {
    if (pi >= pattern.len) return null;
    const c = pattern[pi];
    if (c == '?') return pi + 1;
    if (c == '[') {
        if (findClassEnd(pattern, pi + 1)) |close| {
            return if (classMatches(pattern, pi + 1, close, ch, ci)) close + 1 else null;
        }
        return if (foldEq(c, ch, ci)) pi + 1 else null; // malformed '[' -> literal
    }
    return if (foldEq(c, ch, ci)) pi + 1 else null;
}

fn matchImpl(pattern: []const u8, name: []const u8, ci: bool) bool {
    var pi: usize = 0;
    var ni: usize = 0;
    var star_pi: ?usize = null;
    var star_ni: usize = 0;

    while (ni < name.len) {
        if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ni = ni;
            pi += 1;
            continue;
        }
        if (matchOne(pattern, pi, name[ni], ci)) |next_pi| {
            pi = next_pi;
            ni += 1;
            continue;
        }
        if (star_pi) |sp| {
            pi = sp + 1;
            star_ni += 1;
            ni = star_ni;
            continue;
        }
        return false;
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

/// Case-sensitive glob match (`find -name`/`-path`).
pub fn match(pattern: []const u8, name: []const u8) bool {
    return matchImpl(pattern, name, false);
}

/// ASCII case-insensitive glob match (`find -iname`/`-ipath`).
pub fn matchCI(pattern: []const u8, name: []const u8) bool {
    return matchImpl(pattern, name, true);
}
