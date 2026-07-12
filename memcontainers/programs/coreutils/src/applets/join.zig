//! `join` -- reference/uutils-coreutils src/uu/join/src/join.rs (~1150 LOC, read in
//! full). Relational equi-join of two files sorted on a key field, merged with a
//! forward-only two-pointer scan; equal-key runs on both sides form a Cartesian
//! product (docs/analysis matrix + rulings below, source: uutils 0.9.0 oracle).
//!
//! Field model (verified against the oracle, not just the doc comments in join.rs):
//!   - default (no `-t`): "whitespace" splitting -- runs of space/tab/newline are field
//!     boundaries; LEADING runs are dropped (no empty first field) but a TRAILING run
//!     produces one real trailing EMPTY field (`"a  "` -> fields `["a", ""]`) because
//!     the underlying scan always pushes a final `(last_end, len)` range unconditionally.
//!     This makes a line ending in whitespace print a doubled separator in default
//!     format -- ruling: replicate verbatim (parity/corpus/join/trailing_ws_field/).
//!   - `-t CHAR` (single byte): plain split on that byte, empty fields between
//!     consecutive delimiters allowed, trailing delimiter also yields an empty field.
//!   - `-t ''` (empty argument): NOT "NUL delimiter" -- it means "no separator, the
//!     whole line is field 0" (`SepSetting::Line` in the oracle). Only reachable via a
//!     unit test (the corpus `cmd` tokenizer has no way to encode a literal empty
//!     argument -- see parity/README convention).
//!   - `-t '\0'` (the two-byte string backslash-zero): NUL byte separator. The oracle
//!     only inspects the FIRST TWO characters of the `-t` value to detect this
//!     escape -- `-t '\0x'` (backslash, zero, then more) is STILL accepted as a NUL
//!     separator, silently ignoring everything after the second character. Ruling:
//!     replicate the quirk (parity/corpus is a two-char case only; the "trailing junk
//!     ignored" quirk is unit-tested).
//!   - `-t` with a single non-ASCII multi-byte UTF-8 codepoint: that whole byte
//!     sequence is the (multi-byte) separator, used verbatim for both splitting and
//!     joining.
//!   - GNU/POSIX default output joins fields with a single space even though the
//!     input separator was a run of blanks (`output_separator()` for whitespace mode
//!     is always `" "`, not the original run).
//!
//! `-o FORMAT`: comma/space/tab-separated `FILENUM.FIELD` tokens or the literal `0`
//! (the join field). `-o auto` (a GNU/uutils extension) means: the join field, then
//! every OTHER field of file 1's FIRST line (in order, by that line's field count),
//! then every other field of file 2's FIRST line -- the field count is fixed from
//! each file's very first physical line, not recomputed per row. Repeating `-o` is a
//! hard error in the oracle (clap forbids repeating a non-Append arg) -- ruling below.
//!
//! `--check-order`/`--nocheck-order` (default: neither): order violations are only
//! ever inspected when a physical line is read via the "checked" path (not the raw
//! initial read, nor `--header`'s post-header re-read). With `--check-order`, ANY
//! decrease in key order is immediately FATAL (prints exactly one
//! "join: FILE:LINE: is not sorted: CONTENT" line, and truncates output at whatever
//! was already flushed -- no final summary line). With the default (neither flag),
//! a decrease only WARNS (once per file, latched), and only once some unpaired line
//! has already been produced during the run (`has_unpaired`); after the whole run, if
//! either side ever warned, prints one final "join: input is not in sorted order" and
//! sets exit code 1 (but output is NOT truncated -- the whole file still gets merged).
//! `--nocheck-order` disables the check entirely (silently accepts any order). If both
//! flags are given, `--check-order` always wins, regardless of argv order (the oracle
//! evaluates `--nocheck-order` first, then unconditionally overwrites with
//! `--check-order` if present).
//!
//! `--header`: BEFORE any key comparison, the first physical line of each file (already
//! read once) is written as a single joined row (Cartesian of the two 1-line "groups",
//! using the SAME `-o`/default format machinery as a real match -- so it is emitted
//! even under `-v`/`print_joined=false`, since header-writing bypasses that flag
//! entirely), then a line is re-read from each file with NO order check (the header
//! itself, and the transition off it, are never order-checked).
//!
//! Cartesian ordering: file1's matching lines are the OUTER loop, file2's the INNER
//! loop (row-major), and the printed join-field text always comes from FILE1's
//! group-representative line (matters under `-i`: `A 1` / `a 2` joins to `A 1 2`, not
//! `a 1 2`).
//!
//! Known divergences from the real oracle (ledgered in DESIGN.md §2, not
//! chased further here): usage-shaped errors that the oracle's clap layer reports with
//! multi-paragraph text (missing/extra positional, unrecognized flag, `-a`/`-v` value
//! outside {1,2}, a repeated `-o`) are reproduced here as a single `join: ...` line at
//! the same exit code, not clap's verbatim formatting.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "join",
    .flags = &.{
        cli.valueOpt('a', null, "also print unpairable lines from file FILENUM"),
        cli.valueOpt('v', null, "like -a FILENUM, but suppress joined output lines"),
        cli.valueOpt('e', null, "replace missing input fields with EMPTY"),
        cli.flagOpt('i', "ignore-case", "ignore differences in case when comparing fields"),
        cli.valueOpt('j', null, "equivalent to '-1 FIELD -2 FIELD'"),
        cli.valueOpt('o', null, "obey FORMAT while constructing output line"),
        cli.valueOpt('t', null, "use CHAR as input and output field separator"),
        cli.valueOpt('1', null, "join on this FIELD of file 1"),
        cli.valueOpt('2', null, "join on this FIELD of file 2"),
        cli.flagOpt(null, "check-order", "check that the input is correctly sorted"),
        cli.flagOpt(null, "nocheck-order", "do not check that the input is correctly sorted"),
        cli.flagOpt(null, "header", "treat the first line in each file as field headers"),
        cli.flagOpt('z', "zero-terminated", "line delimiter is NUL, not newline"),
    },
    .help = .{
        .summary = "join lines of two files on a common field",
        .synopsis = &.{"join [OPTION]... FILE1 FILE2"},
        .description =
        \\join performs a relational equi-join of two files, each already sorted on a key
        \\field, merging them with a single forward-only two-pointer scan (never seeking
        \\backward, never building a full cross-reference table). For every key value that
        \\appears in both files, ALL of file 1's lines with that key are paired with ALL of
        \\file 2's lines with that key -- equal-key runs on both sides form a full Cartesian
        \\product, not a 1:1 zip, so a key shared by 2 lines in file 1 and 3 lines in file 2
        \\produces 6 output lines. Keys present in only one file are dropped unless -a or -v
        \\asks to keep them.
        \\
        \\Because the scan never looks backward, both files must already be sorted on their
        \\join field in the comparison order join itself uses (byte order, or
        \\case-insensitive under -i); out-of-order input is either warned about (the
        \\default) or treated as immediately fatal (--check-order), never silently
        \\re-sorted.
        ,
        .operands =
        \\FILE1 and FILE2 are the two files to join; exactly one of them (never both) may be
        \\"-", meaning standard input. By default each line is split into fields on runs of
        \\space/tab/newline: a run of LEADING whitespace produces no empty first field, but
        \\a run of TRAILING whitespace still produces one real trailing empty field (see
        \\DEVIATIONS), and fields are always rejoined on output with a single space
        \\regardless of how wide the original run was. -t CHAR instead splits on one literal
        \\byte (or a multi-byte UTF-8 sequence, or the backslash-zero escape for NUL -- see
        \\DEVIATIONS), allows empty fields between consecutive delimiters, and that same
        \\CHAR becomes the output separator too. The join field defaults to field 1 of each
        \\file; -1 FIELD and -2 FIELD override it independently for file 1 and file 2, and
        \\-j FIELD sets both at once (an error if it disagrees with an explicit -1 or -2).
        ,
        .exit = &.{
            .{ .code = 0, .when = "the merge completed and no order-check violation was reported" },
            .{ .code = 1, .when = "a usage problem join itself detected (wrong number of FILE operands, an -a/-v value other than 1 or 2, -o given more than once, an invalid -j/-1/-2/-o field number, incompatible -j vs -1/-2, an invalid -t separator, or both operands being '-'), a FILE could not be opened or read, a write error occurred, or an order-check violation was found (--check-order's first violation, or the default check's end-of-run warning) -- see DEVIATIONS" },
            .{ .code = 2, .when = "a bare command-line syntax error caught by the shared argument parser before join's own checks run: an unrecognized option, or an option missing a required value or given one it does not take" },
        },
        .deviations = &.{
            "In default (whitespace) mode, a LEADING run of blanks is dropped (no empty first field) but a TRAILING run still produces one real trailing empty field, so a line like \"a  \" (trailing spaces) yields fields [\"a\", \"\"] and prints a doubled output separator, e.g. \"a  x\" instead of \"a x\".",
            "-t '' (an explicitly empty separator argument) is NOT a NUL delimiter: it selects whole-line mode where the entire line is field 0 and no splitting occurs at all; a true NUL byte separator is spelled -t '\\0', and that escape is detected by inspecting only the FIRST TWO characters of the -t argument, so -t '\\0x' is still silently accepted as a NUL separator with everything past the second character ignored.",
            "-o auto freezes each file's output field count from that file's very first physical line only, not recomputed per row; later lines with more fields are truncated and later lines with fewer are padded with -e's replacement text (empty string by default).",
            "Without --check-order/--nocheck-order, an out-of-order key is only diagnosed once some unpaired line has already been produced (latched per file, at most one warning per file), and processing still runs to completion over the FULL input, ending in one \"join: input is not in sorted order\" message and exit 1; --check-order instead aborts on the very FIRST violation, printing one \"FILE:LINE: is not sorted\" message and truncating output at whatever had already been written, with no final summary line; when both flags are given, --check-order always wins regardless of argv order.",
            "--header writes the two files' first lines as one joined row through the same combine/-o machinery as an ordinary match, so it is printed even under -v (which otherwise suppresses joined output), and neither the header line nor the line read immediately afterward is ever order-checked.",
            "Equal-key runs on both sides are combined as a full Cartesian product with file 1 as the outer loop and file 2 as the inner loop (row-major order), and the join-field text that gets printed always comes from file 1's group-representative line, so under -i a file 1 line \"A 1\" matched against file 2's \"a 2\" prints \"A 1 2\", never \"a 1 2\".",
            "Usage-shaped errors that join itself validates -- the wrong number of FILE operands, an -a/-v value other than 1 or 2, or a repeated -o -- are reported as a single \"join: ...\" line at exit 1 rather than GNU's multi-paragraph usage text; a bare unrecognized option or one missing its required value is instead caught earlier by the shared argument parser and exits 2.",
            "-o FORMAT splits its argument on space, comma, and tab as independent delimiters, so consecutive or leading/trailing delimiters yield empty tokens that must each still parse as a valid field specifier (a leading comma is an error); a field number that overflows a 64-bit size silently becomes a permanently-empty filler column (usize::MAX) instead of an error.",
        },
        .examples = &.{
            .{ .cmd = "join <(printf 'a 1\\na 2\\nb 3\\n') <(printf 'a 10\\na 20\\nb 30\\n')", .note = "key 'a' has 2 lines on each side, so it expands to a 2x2 Cartesian product: 4 lines for 'a', 1 for 'b'" },
            .{ .cmd = "join -a 1 -e MISSING -o 0,1.2,2.2 left.txt right.txt", .note = "keeps left.txt's unmatched lines and fills the missing right-side field with MISSING" },
            .{ .cmd = "join -1 2 -2 1 left.txt right.txt", .note = "joins left.txt's field 2 against right.txt's field 1" },
        },
        .see_also = "sort (produce the sorted input join requires); comm (compare two sorted files line-by-line); paste (concatenate files by position rather than by key).",
    },
    .positionals = .{ .name = "FILE1 FILE2", .min = 0, .max = null },
};

// ============================================================================ model

const FileNum = enum { one, two };

const Range = struct { start: usize, end: usize };

const LineRec = struct {
    raw: []const u8,
    ranges: []const Range,
};

const SepKind = enum { whitespace, byte, line, multi };

const Separator = struct {
    kind: SepKind,
    byte: u8 = 0,
    multi: []const u8 = &.{},
    out_sep: []const u8 = " ",
};

const SpecTag = enum { key, field };

const FormatSpec = struct {
    tag: SpecTag,
    file_num: FileNum = .one,
    field: usize = 0,
};

const CheckOrder = enum { default, disabled, enabled };

// -------------------------------------------------------------------- field helpers

fn getField(line: LineRec, idx: usize) ?[]const u8 {
    if (idx >= line.ranges.len) return null;
    const r = line.ranges[idx];
    return line.raw[r.start..r.end];
}

fn pushRange(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(Range), start: usize, end: usize) void {
    list.append(gpa, .{ .start = start, .end = end }) catch @panic("OOM");
}

fn fieldRanges(gpa: std.mem.Allocator, sep: Separator, line: []const u8) []const Range {
    var list: std.ArrayListUnmanaged(Range) = .empty;
    switch (sep.kind) {
        .line => {
            pushRange(gpa, &list, 0, line.len);
        },
        .byte => {
            var last_end: usize = 0;
            for (line, 0..) |c, i| {
                if (c == sep.byte) {
                    pushRange(gpa, &list, last_end, i);
                    last_end = i + 1;
                }
            }
            pushRange(gpa, &list, last_end, line.len);
        },
        .multi => {
            var last_end: usize = 0;
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, line, pos, sep.multi)) |idx| {
                pushRange(gpa, &list, last_end, idx);
                last_end = idx + sep.multi.len;
                pos = last_end;
            }
            pushRange(gpa, &list, last_end, line.len);
        },
        .whitespace => {
            var last_end: usize = 0;
            for (line, 0..) |c, i| {
                if (c == ' ' or c == '\t' or c == '\n') {
                    if (i > last_end) pushRange(gpa, &list, last_end, i);
                    last_end = i + 1;
                }
            }
            pushRange(gpa, &list, last_end, line.len);
        },
    }
    return list.toOwnedSlice(gpa) catch @panic("OOM");
}

/// Split `bytes` on `term`, keeping every byte verbatim (no CR stripping -- join
/// preserves bytes exactly). Mirrors io::Split: an empty input yields zero lines; data
/// ending exactly at a terminator does not yield a trailing empty line; an
/// unterminated tail is still a line.
fn splitJoinLines(gpa: std.mem.Allocator, bytes: []const u8, term: u8) []const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var start: usize = 0;
    while (start < bytes.len) {
        if (std.mem.indexOfScalarPos(u8, bytes, start, term)) |t| {
            list.append(gpa, bytes[start..t]) catch @panic("OOM");
            start = t + 1;
        } else {
            list.append(gpa, bytes[start..]) catch @panic("OOM");
            break;
        }
    }
    return list.toOwnedSlice(gpa) catch @panic("OOM");
}

fn buildLineRecs(gpa: std.mem.Allocator, sep: Separator, raw_lines: []const []const u8) []const LineRec {
    var recs = gpa.alloc(LineRec, raw_lines.len) catch @panic("OOM");
    for (raw_lines, 0..) |raw, i| {
        recs[i] = .{ .raw = raw, .ranges = fieldRanges(gpa, sep, raw) };
    }
    return recs;
}

// ------------------------------------------------------------------------ compare

fn compareBytesCI(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[i]);
        if (ca != cb) return if (ca < cb) .lt else .gt;
    }
    return std.math.order(a.len, b.len);
}

fn compareKeys(a: ?[]const u8, b: ?[]const u8, ignore_case: bool) std.math.Order {
    if (a != null and b != null) {
        return if (ignore_case) compareBytesCI(a.?, b.?) else std.mem.order(u8, a.?, b.?);
    }
    if (a != null) return .gt;
    if (b != null) return .lt;
    return .eq;
}

// -------------------------------------------------------------------- field number

const FieldNumResult = union(enum) { ok: usize, invalid };

/// Mirrors the oracle's `parse_field_number`: an all-digit non-empty string. Parses
/// as a natural number; N>0 becomes the 0-based index N-1. A digit string too large
/// for `usize` becomes `usize::MAX` OUTRIGHT (not shifted by one, matching the
/// oracle's overflow branch); `0` or any non-digit content is `.invalid`.
fn parseFieldNumber(s: []const u8) FieldNumResult {
    if (s.len == 0) return .invalid;
    for (s) |c| {
        if (c < '0' or c > '9') return .invalid;
    }
    const max = std.math.maxInt(usize);
    var v: usize = 0;
    var overflowed = false;
    for (s) |c| {
        const d: usize = c - '0';
        if (v > (max - d) / 10) {
            overflowed = true;
            break;
        }
        v = v * 10 + d;
    }
    if (overflowed) return .{ .ok = max };
    if (v == 0) return .invalid;
    return .{ .ok = v - 1 };
}

// --------------------------------------------------------------------- -o parsing

const SpecErrKind = enum { field_specifier, file_number, field_number };
const SpecParseResult = union(enum) { ok: FormatSpec, err: struct { kind: SpecErrKind, text: []const u8 } };

fn parseSpecToken(tok: []const u8) SpecParseResult {
    if (tok.len == 0) return .{ .err = .{ .kind = .file_number, .text = tok } };
    const c0 = tok[0];
    if (c0 == '0') {
        if (tok.len == 1) return .{ .ok = .{ .tag = .key } };
        return .{ .err = .{ .kind = .field_specifier, .text = tok } };
    }
    var fnum: FileNum = undefined;
    if (c0 == '1') {
        fnum = .one;
    } else if (c0 == '2') {
        fnum = .two;
    } else {
        return .{ .err = .{ .kind = .file_number, .text = tok } };
    }
    if (tok.len < 2 or tok[1] != '.') return .{ .err = .{ .kind = .field_specifier, .text = tok } };
    const rest = tok[2..];
    return switch (parseFieldNumber(rest)) {
        .invalid => .{ .err = .{ .kind = .field_number, .text = rest } },
        .ok => |v| .{ .ok = .{ .tag = .field, .file_num = fnum, .field = v } },
    };
}

/// Splits on any of space/comma/tab, individually -- consecutive or leading/trailing
/// delimiters produce empty tokens (matches Rust's `str::split` over a char set,
/// which is NOT the same as a tokenizer that skips empty runs).
fn splitFormat(gpa: std.mem.Allocator, s: []const u8) []const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == ' ' or c == ',' or c == '\t') {
            list.append(gpa, s[start..i]) catch @panic("OOM");
            start = i + 1;
        }
    }
    list.append(gpa, s[start..]) catch @panic("OOM");
    return list.toOwnedSlice(gpa) catch @panic("OOM");
}

// ------------------------------------------------------------------------ quoting

fn isSimpleText(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c <= 0x20 or c == 0x7f) return false;
        if (c == '\'' or c == '"' or c == '\\' or c == '`' or c == '$') return false;
    }
    return true;
}

fn quote(gpa: std.mem.Allocator, s: []const u8) []const u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    list.append(gpa, '\'') catch @panic("OOM");
    for (s) |c| {
        if (c == '\'') {
            list.appendSlice(gpa, "'\\''") catch @panic("OOM");
        } else {
            list.append(gpa, c) catch @panic("OOM");
        }
    }
    list.append(gpa, '\'') catch @panic("OOM");
    return list.toOwnedSlice(gpa) catch @panic("OOM");
}

fn maybeQuote(gpa: std.mem.Allocator, s: []const u8) []const u8 {
    if (isSimpleText(s)) return s;
    return quote(gpa, s);
}

// -------------------------------------------------------------------------- state

const NextResult = union(enum) { line: ?usize, fatal };

const MergeState = struct {
    lines: []const LineRec,
    pos: usize = 0,
    group_start: usize = 0,
    group_len: usize = 0,
    key: usize,
    file_num: FileNum,
    print_unpaired: bool,
    has_failed: bool = false,
    file_name: []const u8,

    fn hasLine(self: *const MergeState) bool {
        return self.group_len > 0;
    }

    fn currentKey(self: *const MergeState) ?[]const u8 {
        return getField(self.lines[self.group_start], self.key);
    }

    fn reset(self: *MergeState, idx: ?usize) void {
        if (idx) |i| {
            self.group_start = i;
            self.group_len = 1;
        } else {
            self.group_len = 0;
        }
    }

    /// Raw, unchecked read of the next physical line (used for the very first read and
    /// for `--header`'s post-header re-read -- neither is ever order-checked).
    fn rawNext(self: *MergeState) ?usize {
        if (self.pos >= self.lines.len) return null;
        const idx = self.pos;
        self.pos += 1;
        return idx;
    }

    fn init(self: *MergeState) void {
        self.reset(self.rawNext());
    }
};

const Merger = struct {
    ctx: *Ctx,
    ignore_case: bool,
    check_order: CheckOrder,
    unpaired_seen: bool = false,

    fn printNotSorted(self: *Merger, file: []const u8, line_num: usize, content: []const u8) void {
        const q = maybeQuote(self.ctx.gpa, file);
        self.ctx.errPrint("join: {s}:{d}: is not sorted: {s}\n", .{ q, line_num, content });
    }

    /// The order-checked read: advances `m.pos`, and -- unless order-checking is
    /// disabled -- compares the newly read line's key against `m`'s CURRENT group key.
    fn nextLineChecked(self: *Merger, m: *MergeState) NextResult {
        if (m.pos >= m.lines.len) return .{ .line = null };
        const idx = m.pos;
        m.pos += 1;
        if (self.check_order == .disabled) return .{ .line = idx };
        const cur = m.currentKey();
        const nxt = getField(m.lines[idx], m.key);
        const ord = compareKeys(cur, nxt, self.ignore_case);
        if (ord == .gt and (self.check_order == .enabled or (self.unpaired_seen and !m.has_failed))) {
            self.printNotSorted(m.file_name, idx + 1, m.lines[idx].raw);
            if (self.check_order == .enabled) return .fatal;
            m.has_failed = true;
        }
        return .{ .line = idx };
    }

    /// Keeps reading while the key stays equal, growing the (always-contiguous) group;
    /// returns the first line whose key differs (or none at EOF).
    fn extendGroup(self: *Merger, m: *MergeState) NextResult {
        while (true) {
            const r = self.nextLineChecked(m);
            switch (r) {
                .fatal => return .fatal,
                .line => |maybe_idx| {
                    const idx = maybe_idx orelse return .{ .line = null };
                    const cur = m.currentKey();
                    const nk = getField(m.lines[idx], m.key);
                    if (compareKeys(cur, nk, self.ignore_case) == .eq) {
                        m.group_len += 1;
                        continue;
                    }
                    return .{ .line = idx };
                },
            }
        }
    }
};

// ------------------------------------------------------------------------- output

const Repr = struct {
    format: []const FormatSpec,
    empty: []const u8,
    out_sep: []const u8,
    term: u8,
};

fn writeOtherFields(out: *textio.BufOut, line: LineRec, skip_idx: usize, out_sep: []const u8) sys.Error!void {
    for (line.ranges, 0..) |r, idx| {
        if (idx == skip_idx) continue;
        try out.extend(out_sep);
        try out.extend(line.raw[r.start..r.end]);
    }
}

/// Writes a single line (from one state only -- specs referencing the OTHER file
/// number resolve to `null`, filled with `empty`).
fn writeLine(out: *textio.BufOut, m: *const MergeState, idx: usize, repr: Repr) sys.Error!void {
    const line = m.lines[idx];
    if (repr.format.len > 0) {
        for (repr.format, 0..) |fs, si| {
            if (si > 0) try out.extend(repr.out_sep);
            const val: ?[]const u8 = switch (fs.tag) {
                .key => getField(line, m.key),
                .field => if (fs.file_num == m.file_num) getField(line, fs.field) else null,
            };
            try out.extend(val orelse repr.empty);
        }
    } else {
        try out.extend(getField(line, m.key) orelse repr.empty);
        try writeOtherFields(out, line, m.key, repr.out_sep);
    }
    try out.push(repr.term);
}

/// Cartesian product over the two (possibly single-line) groups. The printed
/// join-field text always comes from `s1`'s group-representative line.
fn combine(out: *textio.BufOut, s1: *const MergeState, s2: *const MergeState, repr: Repr) sys.Error!void {
    const key = s1.currentKey();
    var i: usize = s1.group_start;
    while (i < s1.group_start + s1.group_len) : (i += 1) {
        var j: usize = s2.group_start;
        while (j < s2.group_start + s2.group_len) : (j += 1) {
            if (repr.format.len > 0) {
                for (repr.format, 0..) |fs, si| {
                    if (si > 0) try out.extend(repr.out_sep);
                    const val: ?[]const u8 = switch (fs.tag) {
                        .key => key,
                        .field => switch (fs.file_num) {
                            .one => getField(s1.lines[i], fs.field),
                            .two => getField(s2.lines[j], fs.field),
                        },
                    };
                    try out.extend(val orelse repr.empty);
                }
            } else {
                try out.extend(key orelse repr.empty);
                try writeOtherFields(out, s1.lines[i], s1.key, repr.out_sep);
                try writeOtherFields(out, s2.lines[j], s2.key, repr.out_sep);
            }
            try out.push(repr.term);
        }
    }
}

// --------------------------------------------------------------------- -t parsing

const SepParseResult = union(enum) { ok: Separator, non_utf8, multi_char: []const u8 };

/// Mirrors the oracle's `parse_separator`. Only the first two Unicode scalars of a
/// >=2-byte value are ever inspected for the `\0` (NUL) escape -- anything after the
/// second character is silently ignored once that escape matches (`-t '\0x'` is still
/// accepted as a NUL separator; a deliberately-replicated oracle quirk).
fn parseSeparator(value: []const u8) SepParseResult {
    if (value.len == 0) return .{ .ok = .{ .kind = .line, .out_sep = "" } };
    if (value.len == 1) {
        var sepbuf: [1]u8 = .{value[0]};
        return .{ .ok = .{ .kind = .byte, .byte = value[0], .out_sep = &sepbuf } };
    }
    if (!std.unicode.utf8ValidateSlice(value)) return .non_utf8;
    const len0 = std.unicode.utf8ByteSequenceLength(value[0]) catch unreachable;
    if (len0 == value.len) {
        return .{ .ok = .{ .kind = .multi, .multi = value, .out_sep = value } };
    }
    const rest = value[len0..];
    const len1 = std.unicode.utf8ByteSequenceLength(rest[0]) catch unreachable;
    const cp0 = std.unicode.utf8Decode(value[0..len0]) catch unreachable;
    const cp1 = std.unicode.utf8Decode(rest[0..len1]) catch unreachable;
    if (cp0 == '\\' and cp1 == '0') {
        return .{ .ok = .{ .kind = .byte, .byte = 0, .out_sep = "\x00" } };
    }
    return .{ .multi_char = value };
}

// NOTE: parseSeparator's `.byte` branch above returns a slice into a function-local
// array (`sepbuf`) that does not outlive the call -- callers must materialize the
// output separator into gpa-owned memory immediately. See `resolveSeparator` below.
fn resolveSeparator(gpa: std.mem.Allocator, value: []const u8) SepParseResult {
    const r = parseSeparator(value);
    return switch (r) {
        .ok => |sep| blk: {
            if (sep.kind == .byte) {
                const buf = gpa.dupe(u8, &[1]u8{sep.byte}) catch @panic("OOM");
                break :blk .{ .ok = .{ .kind = .byte, .byte = sep.byte, .out_sep = buf } };
            }
            break :blk .{ .ok = sep };
        },
        else => r,
    };
}

// ============================================================================= run

fn readOperand(ctx: *Ctx, path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "-")) {
        return textio.readAll(ctx.gpa, ctx.stdin) catch |e| {
            ctx.errPrint("join: -: {s}\n", .{sys.strerror(sys.toErrno(e))});
            return null;
        };
    }
    const fd = sys.open(path, .{ .read = true }) catch |e| {
        ctx.errPrint("join: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
        return null;
    };
    defer sys.close(fd);
    return textio.readAll(ctx.gpa, fd) catch |e| {
        ctx.errPrint("join: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
        return null;
    };
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };
    const gpa = ctx.gpa;

    // ---- clap-parity checks (checked before any business-logic validation, mirroring
    // the oracle's clap stage running before uumain's own parsing) ----
    const pos = m.positionalSlice();
    if (pos.len != 2) {
        ctx.errPrint("join: exactly two file operands are required\n", .{});
        return 1;
    }

    var unpaired1 = false;
    var unpaired2 = false;
    var print_joined = true;
    if (m.values("v").len > 0) print_joined = false;
    for (m.values("v")) |v| {
        if (std.mem.eql(u8, v, "1")) {
            unpaired1 = true;
        } else if (std.mem.eql(u8, v, "2")) {
            unpaired2 = true;
        } else {
            ctx.errPrint("join: invalid file number: '{s}'\n", .{v});
            return 1;
        }
    }
    for (m.values("a")) |v| {
        if (std.mem.eql(u8, v, "1")) {
            unpaired1 = true;
        } else if (std.mem.eql(u8, v, "2")) {
            unpaired2 = true;
        } else {
            ctx.errPrint("join: invalid file number: '{s}'\n", .{v});
            return 1;
        }
    }

    if (m.values("o").len > 1) {
        ctx.errPrint("join: the argument '-o <FORMAT>' cannot be used multiple times\n", .{});
        return 1;
    }

    // ---- parse_settings()-order business logic ----
    var keys_opt: ?usize = null;
    if (m.value("j")) |v| {
        keys_opt = switch (parseFieldNumber(v)) {
            .ok => |n| n,
            .invalid => {
                ctx.errPrint("join: invalid field number: {s}\n", .{quote(gpa, v)});
                return 1;
            },
        };
    }
    var key1_opt: ?usize = null;
    if (m.value("1")) |v| {
        key1_opt = switch (parseFieldNumber(v)) {
            .ok => |n| n,
            .invalid => {
                ctx.errPrint("join: invalid field number: {s}\n", .{quote(gpa, v)});
                return 1;
            },
        };
    }
    var key2_opt: ?usize = null;
    if (m.value("2")) |v| {
        key2_opt = switch (parseFieldNumber(v)) {
            .ok => |n| n,
            .invalid => {
                ctx.errPrint("join: invalid field number: {s}\n", .{quote(gpa, v)});
                return 1;
            },
        };
    }

    const key1 = blk: {
        if (keys_opt != null and key1_opt != null and keys_opt.? != key1_opt.?) {
            ctx.errPrint("join: incompatible join fields {d}, {d}\n", .{ keys_opt.? + 1, key1_opt.? + 1 });
            return 1;
        }
        if (keys_opt) |k| break :blk k;
        if (key1_opt) |k| break :blk k;
        break :blk 0;
    };
    const key2 = blk: {
        if (keys_opt != null and key2_opt != null and keys_opt.? != key2_opt.?) {
            ctx.errPrint("join: incompatible join fields {d}, {d}\n", .{ keys_opt.? + 1, key2_opt.? + 1 });
            return 1;
        }
        if (keys_opt) |k| break :blk k;
        if (key2_opt) |k| break :blk k;
        break :blk 0;
    };

    var sep: Separator = .{ .kind = .whitespace, .out_sep = " " };
    if (m.value("t")) |tv| {
        switch (resolveSeparator(gpa, tv)) {
            .ok => |s| sep = s,
            .non_utf8 => {
                ctx.errPrint("join: non-UTF-8 multi-byte tab\n", .{});
                return 1;
            },
            .multi_char => |v| {
                ctx.errPrint("join: multi-character tab {s}\n", .{v});
                return 1;
            },
        }
    }

    var autoformat = false;
    var format: []const FormatSpec = &.{};
    if (m.value("o")) |ov| {
        if (std.mem.eql(u8, ov, "auto")) {
            autoformat = true;
        } else {
            const tokens = splitFormat(gpa, ov);
            var list: std.ArrayListUnmanaged(FormatSpec) = .empty;
            for (tokens) |tok| {
                switch (parseSpecToken(tok)) {
                    .ok => |fs| list.append(gpa, fs) catch @panic("OOM"),
                    .err => |e| {
                        const q = quote(gpa, e.text);
                        switch (e.kind) {
                            .field_specifier => ctx.errPrint("join: invalid field specifier: {s}\n", .{q}),
                            .file_number => ctx.errPrint("join: invalid file number in field spec: {s}\n", .{q}),
                            .field_number => ctx.errPrint("join: invalid field number: {s}\n", .{q}),
                        }
                        return 1;
                    },
                }
            }
            format = list.items;
        }
    }

    const empty: []const u8 = m.value("e") orelse "";
    var check_order: CheckOrder = .default;
    if (m.has("nocheck-order")) check_order = .disabled;
    if (m.has("check-order")) check_order = .enabled;
    const headers = m.has("header");
    const term: u8 = if (m.has("zero-terminated")) 0 else '\n';
    const ignore_case = m.has("ignore-case");

    const file1_name = pos[0];
    const file2_name = pos[1];
    if (std.mem.eql(u8, file1_name, "-") and std.mem.eql(u8, file2_name, "-")) {
        ctx.errPrint("join: both files cannot be standard input\n", .{});
        return 1;
    }

    const bytes1 = readOperand(ctx, file1_name) orelse return 1;
    const raw1 = splitJoinLines(gpa, bytes1, term);
    const recs1 = buildLineRecs(gpa, sep, raw1);
    const bytes2 = readOperand(ctx, file2_name) orelse return 1;
    const raw2 = splitJoinLines(gpa, bytes2, term);
    const recs2 = buildLineRecs(gpa, sep, raw2);

    var state1 = MergeState{ .lines = recs1, .key = key1, .file_num = .one, .print_unpaired = unpaired1, .file_name = file1_name };
    var state2 = MergeState{ .lines = recs2, .key = key2, .file_num = .two, .print_unpaired = unpaired2, .file_name = file2_name };
    state1.init();
    state2.init();

    if (autoformat) {
        var list: std.ArrayListUnmanaged(FormatSpec) = .empty;
        list.append(gpa, .{ .tag = .key }) catch @panic("OOM");
        if (state1.hasLine()) {
            const n = state1.lines[state1.group_start].ranges.len;
            for (0..n) |i| {
                if (i != state1.key) list.append(gpa, .{ .tag = .field, .file_num = .one, .field = i }) catch @panic("OOM");
            }
        }
        if (state2.hasLine()) {
            const n = state2.lines[state2.group_start].ranges.len;
            for (0..n) |i| {
                if (i != state2.key) list.append(gpa, .{ .tag = .field, .file_num = .two, .field = i }) catch @panic("OOM");
            }
        }
        format = list.items;
    }

    const repr = Repr{ .format = format, .empty = empty, .out_sep = sep.out_sep, .term = term };
    var out = textio.BufOut.init(ctx.stdout);
    var merger = Merger{ .ctx = ctx, .ignore_case = ignore_case, .check_order = check_order };

    if (headers) {
        (if (state1.hasLine()) blk: {
            if (state2.hasLine()) break :blk combine(&out, &state1, &state2, repr);
            break :blk writeLine(&out, &state1, state1.group_start, repr);
        } else if (state2.hasLine())
            writeLine(&out, &state2, state2.group_start, repr)
        else {}) catch {
            out.finish() catch {};
            return 1;
        };
        state1.reset(state1.rawNext());
        state2.reset(state2.rawNext());
    }

    while (state1.hasLine() and state2.hasLine()) {
        const ord = compareKeys(state1.currentKey(), state2.currentKey(), ignore_case);
        switch (ord) {
            .lt => {
                if (state1.print_unpaired) {
                    writeLine(&out, &state1, state1.group_start, repr) catch {
                        out.finish() catch {};
                        return 1;
                    };
                }
                const r = merger.nextLineChecked(&state1);
                switch (r) {
                    .fatal => {
                        out.finish() catch {};
                        return 1;
                    },
                    .line => |idx| state1.reset(idx),
                }
                merger.unpaired_seen = true;
            },
            .gt => {
                if (state2.print_unpaired) {
                    writeLine(&out, &state2, state2.group_start, repr) catch {
                        out.finish() catch {};
                        return 1;
                    };
                }
                const r = merger.nextLineChecked(&state2);
                switch (r) {
                    .fatal => {
                        out.finish() catch {};
                        return 1;
                    },
                    .line => |idx| state2.reset(idx),
                }
                merger.unpaired_seen = true;
            },
            .eq => {
                const r1 = merger.extendGroup(&state1);
                if (r1 == .fatal) {
                    out.finish() catch {};
                    return 1;
                }
                const r2 = merger.extendGroup(&state2);
                if (r2 == .fatal) {
                    out.finish() catch {};
                    return 1;
                }
                if (print_joined) {
                    combine(&out, &state1, &state2, repr) catch {
                        out.finish() catch {};
                        return 1;
                    };
                }
                state1.reset(r1.line);
                state2.reset(r2.line);
            },
        }
    }

    inline for (.{ &state1, &state2 }) |st| {
        if (st.hasLine()) {
            if (st.print_unpaired) {
                writeLine(&out, st, st.group_start, repr) catch {
                    out.finish() catch {};
                    return 1;
                };
            }
            while (true) {
                const r = merger.nextLineChecked(st);
                switch (r) {
                    .fatal => {
                        out.finish() catch {};
                        return 1;
                    },
                    .line => |maybe_idx| {
                        const idx = maybe_idx orelse break;
                        if (st.print_unpaired) {
                            writeLine(&out, st, idx, repr) catch {
                                out.finish() catch {};
                                return 1;
                            };
                        }
                        st.reset(idx);
                    },
                }
            }
        }
    }

    out.finish() catch {};

    if (state1.has_failed or state2.has_failed) {
        ctx.errPrint("join: input is not in sorted order\n", .{});
        return 1;
    }
    return 0;
}
