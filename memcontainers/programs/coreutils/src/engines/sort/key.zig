//! `-k` key grammar + GNU `begfield`/`limfield` field-extraction semantics
//! (docs/analysis/applets-s-z.md `sort` entry). Applet-private -- nothing outside
//! `sort.zig` imports this.
//!
//! Field/char positions are 1-based on the wire (`-k F1[.C1][OPTS],F2[.C2][OPTS]`);
//! internally `field1`/`field2` stay 1-based (0 or missing `field2` = "to end of
//! line"), `char1` defaults to 1, `char2` of 0 (or an omitted `.C2`) means "to end of
//! field2". This mirrors real GNU coreutils' `begfield`/`limfield` (verified against
//! the well-known algorithm): each field-skip iteration is "skip a separator run,
//! then skip the field's content" in blank-mode, or "skip to and past one separator
//! byte" in `-t` mode -- so by DEFAULT (no per-key/global `b`), the blank run
//! *preceding* a field is left attached to that field (part of its comparison key);
//! `-b`/per-key `b` strips it. `-t` mode ignores `b` entirely (matches real GNU:
//! blank-skipping only applies when the separator is the default blank-run model).

const std = @import("std");

pub const Mode = enum { default, numeric, general, human, version };

pub const Key = struct {
    field1: usize = 1,
    char1: usize = 1,
    field2: ?usize = null, // null = to end of line
    char2: usize = 0, // 0 = to end of field2 (only meaningful when field2 != null)
    mode: Mode = .default,
    fold: bool = false,
    dict: bool = false,
    ignore_nonprinting: bool = false,
    blanks: bool = false,
    reverse: bool = false,
    // "has its own X" bits -- unset letters inherit the global flag/mode at resolve time.
    has_mode: bool = false,
    has_fold: bool = false,
    has_dict: bool = false,
    has_ip: bool = false,
    has_blanks: bool = false,
    has_reverse: bool = false,
};

pub fn isBlank(b: u8) bool {
    return b == ' ' or b == '\t';
}

fn applyOptLetter(k: *Key, c: u8) bool {
    switch (c) {
        'n' => {
            k.mode = .numeric;
            k.has_mode = true;
        },
        'g' => {
            k.mode = .general;
            k.has_mode = true;
        },
        'h' => {
            k.mode = .human;
            k.has_mode = true;
        },
        'V' => {
            k.mode = .version;
            k.has_mode = true;
        },
        'M', 'R' => {
            // Month-sort / random-sort: unimplemented, accepted as an explicit
            // "default string compare" mode (does NOT inherit the global mode --
            // the user asked for something specific; source: spec).
            k.mode = .default;
            k.has_mode = true;
        },
        'f' => {
            k.fold = true;
            k.has_fold = true;
        },
        'd' => {
            k.dict = true;
            k.has_dict = true;
        },
        'i' => {
            k.ignore_nonprinting = true;
            k.has_ip = true;
        },
        'b' => {
            k.blanks = true;
            k.has_blanks = true;
        },
        'r' => {
            k.reverse = true;
            k.has_reverse = true;
        },
        else => return false,
    }
    return true;
}

fn parseDigits(s: []const u8, i: *usize) ?usize {
    const start = i.*;
    var v: usize = 0;
    while (i.* < s.len and s[i.*] >= '0' and s[i.*] <= '9') : (i.* += 1) {
        v = v * 10 + (s[i.*] - '0');
    }
    if (i.* == start) return null;
    return v;
}

/// Parses one `-k` argument. Returns `null` on a malformed spec (caller prints the
/// usage error and exits 2).
pub fn parseKeySpec(s: []const u8) ?Key {
    var i: usize = 0;
    var k = Key{};

    const f1 = parseDigits(s, &i) orelse return null;
    if (f1 == 0) return null; // "field number is zero"
    k.field1 = f1;

    if (i < s.len and s[i] == '.') {
        i += 1;
        const c1 = parseDigits(s, &i) orelse return null;
        k.char1 = c1;
    } else {
        k.char1 = 1;
    }
    while (i < s.len and s[i] != ',') : (i += 1) {
        if (!applyOptLetter(&k, s[i])) return null;
    }

    if (i < s.len and s[i] == ',') {
        i += 1;
        const f2 = parseDigits(s, &i) orelse return null;
        if (f2 == 0) return null;
        k.field2 = f2;
        if (i < s.len and s[i] == '.') {
            i += 1;
            const c2 = parseDigits(s, &i) orelse return null;
            k.char2 = c2;
        } else {
            k.char2 = 0;
        }
        while (i < s.len) : (i += 1) {
            if (!applyOptLetter(&k, s[i])) return null;
        }
    }

    if (i != s.len) return null;
    return k;
}

/// Resolves a key's unset letters against the global order mode/transform flags
/// (GNU: options attached to a key win; letters the key didn't specify fall back to
/// the global flags -- DESIGN ruling recorded in docs/parity-ledger.md).
pub fn resolveAgainstGlobal(k: Key, global_mode: Mode, global_fold: bool, global_dict: bool, global_ip: bool, global_blanks: bool, global_reverse: bool) Key {
    var r = k;
    if (!k.has_mode) r.mode = global_mode;
    if (!k.has_fold) r.fold = global_fold;
    if (!k.has_dict) r.dict = global_dict;
    if (!k.has_ip) r.ignore_nonprinting = global_ip;
    if (!k.has_blanks) r.blanks = global_blanks;
    if (!k.has_reverse) r.reverse = global_reverse;
    return r;
}

/// The implicit single whole-line key used when no `-k` is given at all.
pub fn implicitKey(global_mode: Mode, global_fold: bool, global_dict: bool, global_ip: bool, global_blanks: bool, global_reverse: bool) Key {
    return resolveAgainstGlobal(Key{ .field1 = 1, .char1 = 1, .field2 = null, .char2 = 0 }, global_mode, global_fold, global_dict, global_ip, global_blanks, global_reverse);
}

/// Start offset of field `field` (1-based), `char` (1-based, min 1) chars into it,
/// optionally blank-skipped first (`b`, blank-mode only).
pub fn begField(line: []const u8, field: usize, char: usize, b: bool, sep: ?u8) usize {
    var pos: usize = 0;
    var sword = field - 1;
    while (sword > 0) : (sword -= 1) {
        if (sep) |s| {
            while (pos < line.len and line[pos] != s) pos += 1;
            if (pos < line.len) pos += 1;
        } else {
            while (pos < line.len and isBlank(line[pos])) pos += 1;
            while (pos < line.len and !isBlank(line[pos])) pos += 1;
        }
    }
    if (b and sep == null) {
        while (pos < line.len and isBlank(line[pos])) pos += 1;
    }
    if (char >= 1) {
        pos = @min(pos + (char - 1), line.len);
    }
    return pos;
}

/// End offset (exclusive) of field `field` (1-based); `char == 0` means "to the end
/// of the field" (its natural boundary before the next separator run); `char >= 1`
/// means "up to and including the `char`-th character of the field" (relative to the
/// same blank-skipped start `begField` would compute).
pub fn limField(line: []const u8, field: usize, char: usize, b: bool, sep: ?u8) usize {
    if (char == 0) {
        var pos: usize = 0;
        if (sep) |s| {
            var i: usize = 0;
            while (i < field - 1) : (i += 1) {
                while (pos < line.len and line[pos] != s) pos += 1;
                if (pos < line.len) pos += 1;
            }
            while (pos < line.len and line[pos] != s) pos += 1;
        } else {
            var i: usize = 0;
            while (i < field) : (i += 1) {
                while (pos < line.len and isBlank(line[pos])) pos += 1;
                while (pos < line.len and !isBlank(line[pos])) pos += 1;
            }
        }
        return pos;
    }
    const start = begField(line, field, 1, b, sep);
    return @min(start + char, line.len);
}

/// The key substring per GNU semantics: `[begField(field1,char1,b), end)` where
/// `end` is line-end when `field2` is unset, else `limField(field2,char2,b)`.
pub fn extractKey(line: []const u8, k: Key, sep: ?u8) []const u8 {
    const start = begField(line, k.field1, k.char1, k.blanks, sep);
    const end = if (k.field2) |f2| limField(line, f2, k.char2, k.blanks, sep) else line.len;
    if (end <= start) return line[start..start];
    return line[start..end];
}
