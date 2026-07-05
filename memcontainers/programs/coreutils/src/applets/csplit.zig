//! `csplit` -- split a file into sections determined by context lines. Faithful port
//! of uutils 0.9.0 `csplit` (src/uu/csplit/{csplit,patterns,split_name,csplit_error}.rs).
//!
//! PATTERN grammar (parsed by `extractPatterns`, matched with `engines/regex.zig`):
//!   - `N`            split up to (not including) line N (1-based).
//!   - `/re/[±OFF]`   split up to the line matching `re`; the split boundary is
//!                    `match_line_index + OFF` (exclusive). `+OFF` keeps OFF extra lines
//!                    (matched line included), `-OFF` moves the boundary earlier.
//!   - `%re%[±OFF]`   like `/re/` but the skipped section is discarded (no file, no count).
//!   - a `{N}` or `{*}` token AFTER a pattern repeats it N more times (total N+1) / forever.
//!
//! Output: one file per section named `<prefix><number>` (prefix `xx`, number `%02d` by
//! default; `-f/-b/-n` customize). Unless `-q/-s`, the byte size of each written section
//! is printed to stdout, one per line, as it is finished -- even the section being written
//! when a later pattern fails (the count is emitted, then the file is deleted on cleanup).
//!
//! Errors exit 1 (`csplit: <message>`). On any splitting error without `-k`, EVERY created
//! section file is deleted (including ones already successfully written). The regex engine
//! is fed one physical line at a time with its trailing `\r\n`/`\n` stripped (csplit never
//! matches across a line boundary), so no multiline/dotall options are needed.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;
const textio = @import("../core/textio.zig");
const fmtnum = @import("../core/fmtnum.zig");
const fmt_min = @import("../core/fmt_min.zig");
const regex = @import("../engines/regex.zig");

const Allocator = std.mem.Allocator;

const help_doc = cli.Help{
    .summary = "split a file into sections determined by context lines",
    .synopsis = &.{"csplit [OPTION]... FILE PATTERN..."},
    .description =
    \\Splits FILE into sections at the boundaries named by one or more
    \\PATTERNs, writing each section to its own file (default name xx00, xx01,
    \\...; -f/-b/-n customize the prefix, sprintf-style suffix format, and
    \\digit count). A PATTERN is a line number N (split just before it),
    \\/RE/[+-OFF] (split at the line matching RE, shifted by OFF), or
    \\%RE%[+-OFF] (like /RE/ but the skipped section is discarded, not
    \\written). Any pattern may be followed by {N} to repeat it N more times,
    \\or {*} to repeat until it stops matching.
    \\
    \\Unless -s/-q, the byte size of each section is printed to standard
    \\output as it is finished. Any splitting error (an out-of-range line
    \\number, a pattern that never matches) is reported and, unless
    \\-k/--keep-files, every section file created so far is deleted before
    \\exiting.
    ,
    .options = &.{
        .{ .flags = "-b, --suffix-format=FORMAT", .desc = "use sprintf-style FORMAT instead of %02d for the suffix" },
        .{ .flags = "-f, --prefix=PREFIX", .desc = "use PREFIX instead of 'xx' for output file names" },
        .{ .flags = "-n, --digits=N", .desc = "use N digits instead of 2 in the default suffix" },
        .{ .flags = "-k, --keep-files", .desc = "keep output files created before an error occurred" },
        .{ .flags = "-s, -q, --quiet, --silent", .desc = "do not print output file sizes" },
        .{ .flags = "-z, --elide-empty-files", .desc = "remove output files that would be empty" },
        .{ .flags = "--suppress-matched", .desc = "do not include the matched line in the output" },
    },
    .operands = "FILE the input file ('-' means standard input). PATTERN... one or more split points, applied in order (see DESCRIPTION).",
    .exit = &.{
        .{ .code = 0, .when = "success" },
        .{ .code = 1, .when = "any error: a bad option, a pattern that never matched, an out-of-range line number, or FILE could not be read (section files are deleted unless -k)" },
    },
    .deviations_from = "GNU coreutils csplit",
    .deviations = &.{
        "A {N repeat token missing its closing '}' (e.g. \"{5\") is still recognized as a repeat count rather than being rejected or treated literally.",
    },
    .examples = &.{
        .{ .cmd = "csplit file.txt 10 20", .note = "sections before line 10, before line 20, and the rest" },
        .{ .cmd = "csplit file.txt '/BEGIN/' '{*}'", .note = "one section per repeated /BEGIN/ match, plus a trailing remainder" },
        .{ .cmd = "csplit -k -s file.txt '/nomatch/'", .note = "keep partial output even though the pattern never matches" },
    },
    .see_also = "split (fixed-size chunking), grep (find the line numbers to split on).",
};

// ============================================================================ errors

/// Every csplit failure mode, carrying the data each message interpolates. Mirrors
/// `CsplitError` + the reported clap/io errors; rendered by `report`.
const CsErr = union(enum) {
    line_out_of_range: []const u8,
    line_out_of_range_rep: Rep,
    match_not_found: []const u8,
    match_not_found_rep: Rep,
    line_number_zero: void,
    line_number_smaller: Smaller,
    invalid_pattern: []const u8,
    invalid_number: []const u8,
    suffix_incorrect: void,
    suffix_too_many: void,
    cannot_open: CannotOpen,
    io: sys.Errno,

    const Rep = struct { pat: []const u8, rep: usize };
    const Smaller = struct { cur: usize, prev: usize };
    const CannotOpen = struct { file: []const u8, errno: sys.Errno };
};

fn report(ctx: *const Ctx, err: CsErr) void {
    switch (err) {
        .line_out_of_range => |p| ctx.errPrint("csplit: '{s}': line number out of range\n", .{p}),
        .line_out_of_range_rep => |r| ctx.errPrint("csplit: '{s}': line number out of range on repetition {d}\n", .{ r.pat, r.rep }),
        .match_not_found => |p| ctx.errPrint("csplit: '{s}': match not found\n", .{p}),
        .match_not_found_rep => |r| ctx.errPrint("csplit: '{s}': match not found on repetition {d}\n", .{ r.pat, r.rep }),
        .line_number_zero => ctx.errPrint("csplit: 0: line number must be greater than zero\n", .{}),
        .line_number_smaller => |s| ctx.errPrint("csplit: line number '{d}' is smaller than preceding line number, {d}\n", .{ s.cur, s.prev }),
        .invalid_pattern => |p| ctx.errPrint("csplit: '{s}': invalid pattern\n", .{p}),
        .invalid_number => |n| ctx.errPrint("csplit: invalid number: '{s}'\n", .{n}),
        .suffix_incorrect => ctx.errPrint("csplit: incorrect conversion specification in suffix\n", .{}),
        .suffix_too_many => ctx.errPrint("csplit: too many % conversion specifications in suffix\n", .{}),
        .cannot_open => |c| ctx.errPrint("csplit: cannot open '{s}' for reading: {s}\n", .{ c.file, sys.strerror(c.errno) }),
        .io => |e| ctx.errPrint("csplit: {s}\n", .{sys.strerror(e)}),
    }
}

// ============================================================================ options + split-name

const Options = struct {
    prefix: []const u8 = "xx",
    /// Literal text of `-b FORMAT` before the single conversion spec.
    fmt_pre: []const u8 = "",
    /// Literal text after the conversion spec.
    fmt_post: []const u8 = "",
    /// The single conversion spec (default `%0<digits>u`).
    spec: fmtnum.Spec,
    /// conv is `d`/`i` (signed emitter) vs `u`/`o`/`x`/`X` (unsigned emitter).
    signed: bool = false,
    keep_files: bool = false,
    quiet: bool = false,
    elide_empty_files: bool = false,
    suppress_matched: bool = false,

    /// Filename of the n-th section: `prefix ++ fmt_pre ++ <formatted n> ++ fmt_post`.
    fn splitName(self: *const Options, gpa: Allocator, n: usize) []const u8 {
        var numbuf: [512]u8 = undefined;
        var sink = fmtnum.FixedSink{ .buf = &numbuf };
        if (self.signed) {
            fmtnum.emitInt(&sink, self.spec, @intCast(n)) catch {};
        } else {
            fmtnum.emitUint(&sink, self.spec, @intCast(n)) catch {};
        }
        const num = sink.slice();
        const total = self.prefix.len + self.fmt_pre.len + num.len + self.fmt_post.len;
        const out = gpa.alloc(u8, total) catch @panic("OOM");
        var o: usize = 0;
        @memcpy(out[o..][0..self.prefix.len], self.prefix);
        o += self.prefix.len;
        @memcpy(out[o..][0..self.fmt_pre.len], self.fmt_pre);
        o += self.fmt_pre.len;
        @memcpy(out[o..][0..num.len], num);
        o += num.len;
        @memcpy(out[o..][0..self.fmt_post.len], self.fmt_post);
        return out;
    }
};

/// Parses `-b FORMAT` into `(fmt_pre, spec, fmt_post, signed)`. Accepts exactly one C
/// conversion of an integer type (`d i u o x X`) with flags from `- 0 #` only (`+`,
/// space, `'` -> incorrect), optional width and `.precision`. `%%` is a literal percent
/// (not a conversion). Zero conversions -> incorrect; two or more valid -> too-many.
const ParsedFmt = struct { pre: []const u8, post: []const u8, spec: fmtnum.Spec, signed: bool };

/// Error set for the pre-open validation (`-b`/`-n`); mapped to `CsErr` by the caller.
const OptError = error{ suffix_incorrect, suffix_too_many, invalid_number };

fn parseSuffixFormat(gpa: Allocator, fmt: []const u8) OptError!ParsedFmt {
    var pre: std.ArrayListUnmanaged(u8) = .empty;
    var post: std.ArrayListUnmanaged(u8) = .empty;
    var spec: fmtnum.Spec = .{ .conv = 'u' };
    var signed = false;
    var count: usize = 0;

    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%') {
            const dst = if (count == 0) &pre else &post;
            dst.append(gpa, fmt[i]) catch @panic("OOM");
            i += 1;
            continue;
        }
        // fmt[i] == '%'
        if (i + 1 < fmt.len and fmt[i + 1] == '%') {
            const dst = if (count == 0) &pre else &post;
            dst.append(gpa, '%') catch @panic("OOM");
            i += 2;
            continue;
        }
        var j = i + 1;
        var flags: fmtnum.Flags = .{};
        // flag chars: '-' '0' '#' accepted; '+' ' ' '\'' -> incorrect.
        while (j < fmt.len) : (j += 1) {
            switch (fmt[j]) {
                '-' => flags.minus = true,
                '0' => flags.zero = true,
                '#' => flags.hash = true,
                '+', ' ', '\'' => return error.suffix_incorrect,
                else => break,
            }
        }
        // width
        var width: usize = 0;
        while (j < fmt.len and fmt[j] >= '0' and fmt[j] <= '9') : (j += 1) {
            width = width * 10 + (fmt[j] - '0');
        }
        // precision
        var precision: ?usize = null;
        if (j < fmt.len and fmt[j] == '.') {
            j += 1;
            var p: usize = 0;
            while (j < fmt.len and fmt[j] >= '0' and fmt[j] <= '9') : (j += 1) {
                p = p * 10 + (fmt[j] - '0');
            }
            precision = p;
        }
        // conversion char
        if (j >= fmt.len) return error.suffix_incorrect;
        const conv = fmt[j];
        const conv_signed = switch (conv) {
            'd', 'i' => true,
            'u', 'o', 'x', 'X' => false,
            else => return error.suffix_incorrect,
        };
        j += 1;
        count += 1;
        if (count > 1) return error.suffix_too_many;
        signed = conv_signed;
        spec = .{ .flags = flags, .width = width, .precision = precision, .conv = if (conv == 'i') 'd' else conv };
        i = j;
    }
    if (count == 0) return error.suffix_incorrect;
    return .{ .pre = pre.items, .post = post.items, .spec = spec, .signed = signed };
}

/// Builds `Options`, validating `-n DIGITS` and `-b FORMAT`. Runs before the input file
/// is opened (matching `CsplitOptions::new`).
fn buildOptions(
    gpa: Allocator,
    prefix_opt: ?[]const u8,
    format_opt: ?[]const u8,
    digits_opt: ?[]const u8,
    keep: bool,
    quiet: bool,
    elide: bool,
    suppress: bool,
) OptError!Options {
    const digits: usize = if (digits_opt) |d|
        (parseUsize(d) orelse return error.invalid_number)
    else
        2;

    var o = Options{
        .prefix = prefix_opt orelse "xx",
        .spec = .{ .conv = 'u', .width = digits, .flags = .{ .zero = true } },
        .signed = false,
        .keep_files = keep,
        .quiet = quiet,
        .elide_empty_files = elide,
        .suppress_matched = suppress,
    };
    if (format_opt) |f| {
        const pf = try parseSuffixFormat(gpa, f);
        o.fmt_pre = pf.pre;
        o.fmt_post = pf.post;
        o.spec = pf.spec;
        o.signed = pf.signed;
    }
    return o;
}

// ============================================================================ patterns

const Exec = union(enum) { times: usize, always: void };

const Step = struct { max: ?usize, ith: usize };

/// Mirrors `ExecutePatternIter`: `Times(m)` yields ith 1..m; `Always` yields 1,2,... forever.
const ExecIter = struct {
    exec: Exec,
    cur: usize = 0,

    fn next(self: *ExecIter) ?Step {
        switch (self.exec) {
            .times => |m| {
                if (self.cur == m) return null;
                self.cur += 1;
                return .{ .max = m, .ith = self.cur };
            },
            .always => {
                self.cur += 1;
                return .{ .max = null, .ith = self.cur };
            },
        }
    }
};

const Kind = enum { up_to_line, up_to_match, skip_to_match };

const Pattern = struct {
    kind: Kind,
    n: usize = 0,
    rx: regex.Regex = undefined,
    offset: i32 = 0,
    exec: Exec,
    /// The pattern's Display form, used verbatim in error messages.
    display: []const u8,
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Strict base-10 usize (all digits, non-empty); null on any non-digit or overflow.
fn parseUsize(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var v: usize = 0;
    for (s) |c| {
        if (!isDigit(c)) return null;
        const m = @mulWithOverflow(v, 10);
        if (m[1] != 0) return null;
        const a = @addWithOverflow(m[0], @as(usize, c - '0'));
        if (a[1] != 0) return null;
        v = a[0];
    }
    return v;
}

/// Recognizes a `{N}`/`{*}` repetition token exactly as uutils' regex
/// `^\{(?P<TIMES>[0-9]+)|\*\}$`: a leading `{`+digits => Times(N+1) (highest priority,
/// `}` not required), else a trailing `*}` => Always. Otherwise not a repetition.
fn parseRepeatToken(s: []const u8) ?Exec {
    if (s.len >= 2 and s[0] == '{' and isDigit(s[1])) {
        var j: usize = 1;
        var v: usize = 0;
        while (j < s.len and isDigit(s[j])) : (j += 1) {
            const m = @mulWithOverflow(v, 10);
            if (m[1] != 0) break;
            const a = @addWithOverflow(m[0], @as(usize, s[j] - '0'));
            if (a[1] != 0) break;
            v = a[0];
        }
        return Exec{ .times = v + 1 };
    }
    if (s.len >= 2 and s[s.len - 2] == '*' and s[s.len - 1] == '}') {
        return .always;
    }
    return null;
}

fn validOffset(s: []const u8) bool {
    if (s.len == 0) return true;
    var i: usize = 0;
    if (s[0] == '+' or s[0] == '-') i = 1;
    if (i >= s.len) return false;
    while (i < s.len) : (i += 1) if (!isDigit(s[i])) return false;
    return true;
}

fn parseOffset(s: []const u8) i32 {
    if (s.len == 0) return 0;
    var i: usize = 0;
    var neg = false;
    if (s[0] == '+') {
        i = 1;
    } else if (s[0] == '-') {
        neg = true;
        i = 1;
    }
    var v: i64 = 0;
    while (i < s.len) : (i += 1) v = v * 10 + @as(i64, s[i] - '0');
    if (neg) v = -v;
    return @intCast(v);
}

const MatchStruct = struct { body: []const u8, offset: i32, is_skip: bool };

/// Splits `/body/[±off]` or `%body%[±off]` into its parts, matching uutils'
/// `^(/(?P<UPTO>.+)/|%(?P<SKIPTO>.+)%)(?P<OFFSET>[\+-]?[0-9]+)?$` (greedy `.+`, so the
/// closing delimiter is the rightmost one leaving a valid/empty offset). null if `arg`
/// is not a well-formed match pattern.
fn parseMatchStructure(arg: []const u8) ?MatchStruct {
    const d = arg[0]; // '/' or '%'
    if (arg.len < 3) return null;
    var found: ?usize = null;
    var pp: usize = arg.len - 1;
    while (pp >= 2) : (pp -= 1) {
        if (arg[pp] == d and validOffset(arg[pp + 1 ..])) {
            found = pp;
            break;
        }
    }
    const p = found orelse return null;
    return .{ .body = arg[1..p], .offset = parseOffset(arg[p + 1 ..]), .is_skip = (d == '%') };
}

fn buildLineDisplay(gpa: Allocator, n: usize) []const u8 {
    var buf: [24]u8 = undefined;
    return gpa.dupe(u8, fmt_min.formatBuf(&buf, "{d}", .{n})) catch @panic("OOM");
}

fn buildMatchDisplay(gpa: Allocator, is_skip: bool, body: []const u8, offset: i32) []const u8 {
    const d: u8 = if (is_skip) '%' else '/';
    var list: std.ArrayListUnmanaged(u8) = .empty;
    list.append(gpa, d) catch @panic("OOM");
    list.appendSlice(gpa, body) catch @panic("OOM");
    list.append(gpa, d) catch @panic("OOM");
    if (offset != 0) {
        list.append(gpa, if (offset < 0) '-' else '+') catch @panic("OOM");
        const abs: u32 = @intCast(if (offset < 0) -offset else offset);
        var nb: [16]u8 = undefined;
        list.appendSlice(gpa, fmt_min.formatBuf(&nb, "{d}", .{abs})) catch @panic("OOM");
    }
    return list.items;
}

const ExtractResult = union(enum) { ok: []Pattern, err: CsErr };

/// Parses the raw PATTERN args into `[]Pattern`, compiling each regex with the shared
/// engine. Emits `InvalidPattern` on a malformed/uncompilable pattern.
fn extractPatterns(gpa: Allocator, args: []const []const u8) ExtractResult {
    var list: std.ArrayListUnmanaged(Pattern) = .empty;
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        i += 1;
        // A following `{N}`/`{*}` token sets the repetition count.
        var exec: Exec = .{ .times = 1 };
        if (i < args.len) {
            if (parseRepeatToken(args[i])) |rep| {
                exec = rep;
                i += 1;
            }
        }

        if (arg.len > 0 and (arg[0] == '/' or arg[0] == '%')) {
            const ps = parseMatchStructure(arg) orelse return .{ .err = CsErr{ .invalid_pattern = arg } };
            var diag: regex.Diag = .{};
            const rx = regex.compile(gpa, ps.body, .{}, &diag) catch {
                return .{ .err = CsErr{ .invalid_pattern = arg } };
            };
            list.append(gpa, .{
                .kind = if (ps.is_skip) .skip_to_match else .up_to_match,
                .rx = rx,
                .offset = ps.offset,
                .exec = exec,
                .display = buildMatchDisplay(gpa, ps.is_skip, ps.body, ps.offset),
            }) catch @panic("OOM");
        } else if (parseUsize(arg)) |ln| {
            list.append(gpa, .{
                .kind = .up_to_line,
                .n = ln,
                .exec = exec,
                .display = buildLineDisplay(gpa, ln),
            }) catch @panic("OOM");
        } else {
            return .{ .err = CsErr{ .invalid_pattern = arg } };
        }
    }
    return .{ .ok = list.items };
}

/// Line numbers must be strictly increasing from 0; equal-to-previous only warns.
fn validateLineNumbers(ctx: *const Ctx, patterns: []const Pattern) ?CsErr {
    var prev: usize = 0;
    for (patterns) |p| {
        if (p.kind != .up_to_line) continue;
        const cur = p.n;
        if (cur == 0) return CsErr.line_number_zero;
        if (prev == cur) {
            ctx.errPrint("csplit: warning: line number '{d}' is the same as preceding line number\n", .{prev});
        } else if (prev > cur) {
            return CsErr{ .line_number_smaller = .{ .cur = cur, .prev = prev } };
        } else {
            prev = cur;
        }
    }
    return null;
}

// ============================================================================ line model

/// Splits raw file bytes into lines, each including its trailing `\n` (the final
/// unterminated line, if any, is kept as-is). Matches `read_until(b'\n')`.
fn splitLines(gpa: Allocator, data: []const u8) []const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    while (i < data.len) {
        if (std.mem.indexOfScalar(u8, data[i..], '\n')) |rel| {
            list.append(gpa, data[i .. i + rel + 1]) catch @panic("OOM");
            i += rel + 1;
        } else {
            list.append(gpa, data[i..]) catch @panic("OOM");
            i = data.len;
        }
    }
    return list.items;
}

/// The regex is matched against the line with its trailing `\r\n`/`\n` removed.
fn stripEol(line: []const u8) []const u8 {
    if (line.len >= 2 and line[line.len - 2] == '\r' and line[line.len - 1] == '\n') return line[0 .. line.len - 2];
    if (line.len >= 1 and line[line.len - 1] == '\n') return line[0 .. line.len - 1];
    return line;
}

// ============================================================================ runner (InputSplitter + SplitWriter)

/// Fuses `InputSplitter` (a line iterator with a push-back/sliding buffer for offsets and
/// matched-line hand-off) and `SplitWriter` (per-section files + byte-count reporting).
const Runner = struct {
    ctx: *Ctx,
    gpa: Allocator,
    opts: *const Options,

    // input side
    lines: []const []const u8,
    pos: usize = 0,
    buf: std.ArrayListUnmanaged(Item) = .empty,
    bufsize: usize = 1,
    rewind: bool = false,

    // writer side
    counter: usize = 0,
    cur_fd: ?sys.Fd = null,
    cur_name: ?[]const u8 = null,
    size: usize = 0,
    dev_null: bool = false,

    const Item = struct { idx: usize, line: []const u8 };

    // --- input splitter ---

    fn next(self: *Runner) ?Item {
        if (self.rewind) {
            if (self.buf.items.len > 0) return self.buf.orderedRemove(0);
            self.rewind = false;
        }
        if (self.pos < self.lines.len) {
            const it = Item{ .idx = self.pos, .line = self.lines[self.pos] };
            self.pos += 1;
            return it;
        }
        return null;
    }

    fn rewindBuffer(self: *Runner) void {
        self.rewind = true;
    }

    fn setSize(self: *Runner, n: usize) void {
        self.bufsize = n;
    }

    fn bufferLen(self: *const Runner) usize {
        return self.buf.items.len;
    }

    fn addLineToBuffer(self: *Runner, idx: usize, line: []const u8) ?[]const u8 {
        if (self.rewind) {
            self.buf.insert(self.gpa, 0, .{ .idx = idx, .line = line }) catch @panic("OOM");
            return null;
        } else if (self.buf.items.len >= self.bufsize) {
            const head = self.buf.orderedRemove(0);
            self.buf.append(self.gpa, .{ .idx = idx, .line = line }) catch @panic("OOM");
            return head.line;
        } else {
            self.buf.append(self.gpa, .{ .idx = idx, .line = line }) catch @panic("OOM");
            return null;
        }
    }

    fn drainBuffer(self: *Runner) []const []const u8 {
        const out = self.gpa.alloc([]const u8, self.buf.items.len) catch @panic("OOM");
        for (self.buf.items, 0..) |it, k| out[k] = it.line;
        self.buf.clearRetainingCapacity();
        return out;
    }

    fn shrinkBufferToSize(self: *Runner) []const []const u8 {
        const shrink = if (self.buf.items.len > self.bufsize) self.buf.items.len - self.bufsize else 0;
        const out = self.gpa.alloc([]const u8, shrink) catch @panic("OOM");
        for (0..shrink) |k| out[k] = self.buf.items[k].line;
        const rest = self.buf.items.len - shrink;
        std.mem.copyForwards(Item, self.buf.items[0..rest], self.buf.items[shrink..]);
        self.buf.items.len = rest;
        return out;
    }

    // --- split writer ---

    fn newWriter(self: *Runner) ?CsErr {
        if (self.cur_fd) |fd| {
            sys.close(fd);
            self.cur_fd = null;
        }
        const name = self.opts.splitName(self.gpa, self.counter);
        const fd = sys.open(name, .{ .write = true, .create = true, .trunc = true }) catch |e| {
            return CsErr{ .io = sys.toErrno(e) };
        };
        self.cur_fd = fd;
        self.cur_name = name;
        self.counter += 1;
        self.size = 0;
        self.dev_null = false;
        return null;
    }

    fn asDevNull(self: *Runner) void {
        self.dev_null = true;
    }

    fn writeln(self: *Runner, line: []const u8) ?CsErr {
        if (self.dev_null) return null;
        if (self.cur_fd) |fd| {
            sys.writeAll(fd, line) catch |e| return CsErr{ .io = sys.toErrno(e) };
            self.size += line.len;
        }
        return null;
    }

    fn finishSplit(self: *Runner) void {
        if (self.dev_null) return;
        if (self.opts.elide_empty_files and self.size == 0) {
            if (self.cur_name) |nm| sys.unlink(nm) catch {};
            self.counter -= 1;
        } else if (!self.opts.quiet) {
            self.ctx.outPrint("{d}\n", .{self.size});
        }
    }

    fn deleteAllSplits(self: *Runner) void {
        var i: usize = 0;
        while (i < self.counter) : (i += 1) {
            const name = self.opts.splitName(self.gpa, i);
            sys.unlink(name) catch {};
        }
    }

    fn closeCurrent(self: *Runner) void {
        if (self.cur_fd) |fd| {
            sys.close(fd);
            self.cur_fd = null;
        }
    }

    // --- core algorithms ---

    /// Write up to (not including) line number `n`; boundary line is pushed back (or
    /// dropped under `--suppress-matched`). LineOutOfRange if `n` exceeds the input.
    fn doToLine(self: *Runner, pas: []const u8, n: usize) ?CsErr {
        self.rewindBuffer();
        self.setSize(1);
        var ret: ?CsErr = CsErr{ .line_out_of_range = pas };
        while (self.next()) |item| {
            const ln = item.idx;
            if (n < ln + 1) {
                _ = self.addLineToBuffer(ln, item.line);
                ret = null;
                break;
            } else if (n == ln + 1) {
                if (!self.opts.suppress_matched) _ = self.addLineToBuffer(ln, item.line);
                ret = null;
                break;
            } else {
                if (self.writeln(item.line)) |e| return e;
            }
        }
        self.finishSplit();
        return ret;
    }

    /// Write/skip up to the line matching `rx`, extended (`+off`) or reduced (`-off`) by
    /// the offset. See module doc for the exact boundary semantics.
    fn doToMatch(self: *Runner, pas: []const u8, rx: *regex.Regex, offset_in: i32) ?CsErr {
        var offset = offset_in;
        if (offset >= 0) {
            for (self.drainBuffer()) |line| if (self.writeln(line)) |e| return e;
            self.setSize(1);
            while (self.next()) |item| {
                const stripped = stripEol(item.line);
                if (rx.isMatch(stripped)) {
                    var next_suppress = false;
                    if (!self.opts.suppress_matched and offset == 0) {
                        _ = self.addLineToBuffer(item.idx, item.line);
                    } else if (!self.opts.suppress_matched) {
                        if (self.writeln(item.line)) |e| return e;
                    } else if (offset >= 1) {
                        next_suppress = true;
                        if (self.writeln(item.line)) |e| return e;
                    }
                    offset -= 1;
                    while (offset > 0) {
                        if (self.next()) |it2| {
                            if (self.writeln(it2.line)) |e| return e;
                        } else {
                            self.finishSplit();
                            return CsErr{ .line_out_of_range = pas };
                        }
                        offset -= 1;
                    }
                    self.finishSplit();
                    if (next_suppress) _ = self.next();
                    return null;
                }
                if (self.writeln(item.line)) |e| return e;
            }
        } else {
            const k: usize = @intCast(-offset);
            self.setSize(k);
            while (self.next()) |item| {
                const stripped = stripEol(item.line);
                if (rx.isMatch(stripped)) {
                    for (self.shrinkBufferToSize()) |line| if (self.writeln(line)) |e| return e;
                    if (self.opts.suppress_matched) {
                        _ = self.addLineToBuffer(item.idx, item.line);
                    } else {
                        self.setSize(k + 1);
                        _ = self.addLineToBuffer(item.idx, item.line);
                    }
                    self.finishSplit();
                    if (self.bufferLen() < k) return CsErr{ .line_out_of_range = pas };
                    return null;
                }
                if (self.addLineToBuffer(item.idx, item.line)) |evicted| {
                    if (self.writeln(evicted)) |e| return e;
                }
            }
            for (self.drainBuffer()) |line| if (self.writeln(line)) |e| return e;
        }
        self.finishSplit();
        return CsErr{ .match_not_found = pas };
    }

    /// Walk the pattern list, applying each (with its repetition count) in turn.
    fn doCsplit(self: *Runner, patterns: []Pattern) ?CsErr {
        for (patterns) |*pat| {
            const pas = pat.display;
            switch (pat.kind) {
                .up_to_line => {
                    var up_to = pat.n;
                    var it = ExecIter{ .exec = pat.exec };
                    while (it.next()) |step| {
                        if (self.newWriter()) |e| return e;
                        if (self.doToLine(pas, up_to)) |e| {
                            switch (e) {
                                .line_out_of_range => {
                                    if (step.ith != 1) return CsErr{ .line_out_of_range_rep = .{ .pat = pas, .rep = step.ith - 1 } };
                                    return e;
                                },
                                else => return e,
                            }
                        }
                        up_to += pat.n;
                    }
                },
                .up_to_match, .skip_to_match => {
                    const is_skip = pat.kind == .skip_to_match;
                    var it = ExecIter{ .exec = pat.exec };
                    while (it.next()) |step| {
                        if (is_skip) self.asDevNull() else if (self.newWriter()) |e| return e;
                        if (self.doToMatch(pas, &pat.rx, pat.offset)) |e| {
                            switch (e) {
                                .match_not_found => {
                                    if (step.max == null) return null; // Always + no match: stop cleanly
                                    if (step.max.? != 1 and step.ith != 1)
                                        return CsErr{ .match_not_found_rep = .{ .pat = pas, .rep = step.ith - 1 } };
                                    return e;
                                },
                                else => return e,
                            }
                        }
                    }
                },
            }
        }
        return null;
    }

    /// Top-level orchestration: run the patterns, then emit any remaining input as a
    /// final section, then delete everything on error unless `-k`.
    fn csplit(self: *Runner, patterns: []Pattern, all_up_to_line: bool) ?CsErr {
        var ret = self.doCsplit(patterns);
        if (ret == null) {
            self.rewindBuffer();
            if (self.next()) |first| {
                if (self.newWriter()) |e| {
                    ret = e;
                } else if (self.writeln(first.line)) |e| {
                    ret = e;
                } else {
                    while (self.next()) |it| {
                        if (self.writeln(it.line)) |e| {
                            ret = e;
                            break;
                        }
                    }
                    if (ret == null) self.finishSplit();
                }
            } else if (all_up_to_line and self.opts.suppress_matched) {
                if (self.newWriter()) |e| {
                    ret = e;
                } else {
                    self.finishSplit();
                }
            }
        }
        if (ret != null and !self.opts.keep_files) self.deleteAllSplits();
        self.closeCurrent();
        return ret;
    }
};

// ============================================================================ CLI + run

const version_str = "csplit (nutils) 0.9.0\n";

fn clapError(ctx: *const Ctx, comptime msg: []const u8) u8 {
    ctx.errPrint("csplit: {s}\n", .{msg});
    return 1;
}

pub fn run(ctx: *Ctx) u8 {
    const gpa = ctx.gpa;
    const args = ctx.args;

    var prefix_opt: ?[]const u8 = null;
    var format_opt: ?[]const u8 = null;
    var digits_opt: ?[]const u8 = null;
    var keep = false;
    var quiet = false;
    var elide = false;
    var suppress = false;

    var positionals: std.ArrayListUnmanaged([]const u8) = .empty;
    var no_more_flags = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (no_more_flags) {
            positionals.append(gpa, a) catch @panic("OOM");
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            no_more_flags = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--help")) {
            cli.renderHelp(ctx, "csplit", help_doc);
            return 0;
        }
        if (std.mem.eql(u8, a, "--version")) {
            ctx.outPrint("{s}", .{version_str});
            return 0;
        }
        // long options
        if (a.len >= 2 and a[0] == '-' and a[1] == '-') {
            const body = a[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const attached: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;

            const NeedVal = enum { none, prefix, format, digits };
            var need: NeedVal = .none;
            if (std.mem.eql(u8, name, "suffix-format")) {
                need = .format;
            } else if (std.mem.eql(u8, name, "prefix")) {
                need = .prefix;
            } else if (std.mem.eql(u8, name, "digits")) {
                need = .digits;
            } else if (std.mem.eql(u8, name, "keep-files")) {
                if (attached != null) return clapError(ctx, "option '--keep-files' takes no value");
                keep = true;
            } else if (std.mem.eql(u8, name, "suppress-matched")) {
                if (attached != null) return clapError(ctx, "option '--suppress-matched' takes no value");
                suppress = true;
            } else if (std.mem.eql(u8, name, "quiet") or std.mem.eql(u8, name, "silent")) {
                if (attached != null) return clapError(ctx, "option takes no value");
                quiet = true;
            } else if (std.mem.eql(u8, name, "elide-empty-files")) {
                if (attached != null) return clapError(ctx, "option '--elide-empty-files' takes no value");
                elide = true;
            } else {
                return clapError(ctx, "unrecognized option");
            }
            if (need != .none) {
                var v: []const u8 = undefined;
                if (attached) |att| {
                    v = att;
                } else {
                    i += 1;
                    if (i >= args.len) return clapError(ctx, "option requires a value");
                    v = args[i];
                }
                switch (need) {
                    .prefix => prefix_opt = v,
                    .format => format_opt = v,
                    .digits => digits_opt = v,
                    .none => unreachable,
                }
            }
            continue;
        }
        // short option cluster (but a bare "-" is the stdin FILE operand)
        if (a.len >= 2 and a[0] == '-') {
            var ci: usize = 1;
            while (ci < a.len) {
                const c = a[ci];
                switch (c) {
                    'k' => {
                        keep = true;
                        ci += 1;
                    },
                    's', 'q' => {
                        quiet = true;
                        ci += 1;
                    },
                    'z' => {
                        elide = true;
                        ci += 1;
                    },
                    'b', 'f', 'n' => {
                        var v: []const u8 = undefined;
                        if (ci + 1 < a.len) {
                            v = a[ci + 1 ..];
                        } else {
                            i += 1;
                            if (i >= args.len) return clapError(ctx, "option requires a value");
                            v = args[i];
                        }
                        switch (c) {
                            'b' => format_opt = v,
                            'f' => prefix_opt = v,
                            'n' => digits_opt = v,
                            else => unreachable,
                        }
                        ci = a.len;
                    },
                    else => return clapError(ctx, "unrecognized option"),
                }
            }
            continue;
        }
        positionals.append(gpa, a) catch @panic("OOM");
    }

    // clap requires FILE + at least one PATTERN.
    if (positionals.items.len < 2) {
        return clapError(ctx, "missing operand");
    }
    const file = positionals.items[0];
    const pattern_args = positionals.items[1..];

    // Build options (validates -n/-b) before opening the file.
    const opts = buildOptions(gpa, prefix_opt, format_opt, digits_opt, keep, quiet, elide, suppress) catch |e| switch (e) {
        error.suffix_incorrect => {
            report(ctx, .suffix_incorrect);
            return 1;
        },
        error.suffix_too_many => {
            report(ctx, .suffix_too_many);
            return 1;
        },
        error.invalid_number => {
            // reconstruct the offending value for the message
            report(ctx, CsErr{ .invalid_number = digits_opt.? });
            return 1;
        },
    };

    // Read the whole input.
    const is_stdin = std.mem.eql(u8, file, "-");
    const data: []const u8 = blk: {
        if (is_stdin) {
            break :blk textio.readAll(gpa, ctx.stdin) catch |e| {
                report(ctx, CsErr{ .io = sys.toErrno(e) });
                return 1;
            };
        }
        const fd = sys.open(file, .{ .read = true }) catch |e| {
            report(ctx, CsErr{ .cannot_open = .{ .file = file, .errno = sys.toErrno(e) } });
            return 1;
        };
        defer sys.close(fd);
        break :blk textio.readAll(gpa, fd) catch |e| {
            report(ctx, CsErr{ .io = sys.toErrno(e) });
            return 1;
        };
    };

    // Parse and validate patterns (after the file is opened, matching uutils).
    const patterns = switch (extractPatterns(gpa, pattern_args)) {
        .ok => |p| p,
        .err => |e| {
            report(ctx, e);
            return 1;
        },
    };
    if (validateLineNumbers(ctx, patterns)) |e| {
        report(ctx, e);
        return 1;
    }

    var all_up_to_line = true;
    for (patterns) |p| {
        if (p.kind != .up_to_line) {
            all_up_to_line = false;
            break;
        }
    }

    const lines = splitLines(gpa, data);
    var runner = Runner{ .ctx = ctx, .gpa = gpa, .opts = &opts, .lines = lines };
    if (runner.csplit(patterns, all_up_to_line)) |e| {
        report(ctx, e);
        return 1;
    }
    return 0;
}
