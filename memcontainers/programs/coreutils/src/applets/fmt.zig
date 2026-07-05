//! `fmt` -- docs/analysis/uutils-applets.md: paragraph refill. Ports `uu_fmt`'s
//! `fmt.rs`/`parasplit.rs`/`linebreak.rs` (0.9.0): default = Knuth-Plass "optimal"
//! line breaking (`break_knuth_plass`) with an exact demerits model; `-q`/mail
//! headers use greedy breaking (`break_simple`).
//!
//! WHOLE-FILE BUFFERING (deliberate simplification): `ParagraphStream` needs one
//! line of lookahead (to decide where a paragraph ends), which the reference gets
//! via `Peekable`. Rather than port a lazy peekable line iterator, each FILE operand
//! is read to memory and split into raw lines up front -- paragraph grouping is then
//! plain indexed array-walking. Same observable behavior (fmt is not meant to stream
//! multi-gigabyte input), much simpler control flow.
//!
//! CLI: hand-parsed (not `core/cli.zig`) because of the legacy leading `-WIDTH` form:
//! a `-DIGITS` token is the width ONLY when it is literally `args[1]` (confirmed
//! against the oracle: `fmt file -30` errors "-WIDTH is recognized only when it is
//! the first option", not treated as width); a malformed `-<digit>...<non-digit>`
//! first argument (e.g. `-2x3`) is rejected up front, before any other parsing.
//! `-p`/`-P`/`-w`/`-g`/`-T` take mandatory values (attached or next-token,
//! unconditionally, like ordinary clap value args); `-c -t -m -s -u -q -x -X` cluster
//! as plain flags.
//!
//! DEFAULTS: width 75, goal 70 (a literal hardcoded PAIR, not goal-from-width's 93%
//! formula -- confirmed from source: `DEFAULT_GOAL: usize = 70` is independent of
//! `DEFAULT_WIDTH * 93 / 100 = 69`). Width-only -> `goal = max(1, width*93/100)`
//! (integer division). Goal-only -> `width = max(goal*100/93, goal+3)`, and
//! `goal > 75` errors outright. `MAX_WIDTH = 2500`.
//!
//! BYTE-PARITY STATUS (Knuth-Plass): the demerits model (badness/delta-ratio/short-
//! word/orphan-penalty constants, saturating i64, f32 ratios) is ported line-for-line
//! from `compute_demerits`/`find_kp_breakpoints`/`restart_active_breaks`. One
//! documented risk: Rust's `f32::powi(3)` is implemented as an LLVM intrinsic whose
//! exact multiplication ASSOCIATION (`(x*x)*x` vs `x*(x*x)`) isn't independently
//! verifiable from source alone; this port uses left-to-right `x*x*x`. Verified
//! against the oracle on a broad corpus (default refill, `-w`, `-s`, `-c`, `-t`,
//! `-p`, multi-paragraph, sentence detection, tabs) -- see parity-ledger.md for any
//! residual divergence on adversarial inputs found after that sweep.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

const PROG = "fmt";

const help_doc = cli.Help{
    .summary = "reformat paragraph text",
    .synopsis = &.{"fmt [OPTION]... [FILE]..."},
    .description =
    \\Reflows each FILE's paragraphs to fit a target line width (default
    \\width 75, goal 70) and writes the result to standard output; blank
    \\lines, mail headers (when -m detects one), and non-matching lines are
    \\passed through unfilled. By default, lines are chosen with a
    \\Knuth-Plass "optimal" breaking algorithm that considers a whole
    \\paragraph at once; -q (and detected mail headers) instead use a simple
    \\greedy fill.
    \\
    \\-c (crown margin) preserves each paragraph's first line indentation
    \\and reuses it for the rest of the paragraph; -t (tagged paragraph)
    \\instead treats a differently-indented second line as the start of a
    \\new paragraph. -s (split-only) breaks long lines without rejoining
    \\short ones. -p/-P restrict reflowing to lines that do/don't begin with
    \\a given PREFIX.
    ,
    .options = &.{
        .{ .flags = "-c, --crown-margin", .desc = "preserve the first line's indentation; reuse it for the rest of the paragraph" },
        .{ .flags = "-t, --tagged-paragraph", .desc = "like -c, but a differently-indented second line starts a new paragraph" },
        .{ .flags = "-m, --preserve-headers", .desc = "attempt to detect and pass through mail message headers unfilled" },
        .{ .flags = "-s, --split-only", .desc = "split long lines, but do not join short ones to fill the width" },
        .{ .flags = "-u, --uniform-spacing", .desc = "exactly one space between words, two after a sentence-ending period" },
        .{ .flags = "-p, --prefix=STRING", .desc = "reformat only lines beginning with STRING, reattaching it to the output" },
        .{ .flags = "-P, --skip-prefix=STRING", .desc = "do not reformat lines beginning with STRING" },
        .{ .flags = "-x, --exact-prefix", .desc = "match PREFIX at the exact start of the line, not after leading whitespace" },
        .{ .flags = "-X, --exact-skip-prefix", .desc = "match SKIP-PREFIX at the exact start of the line, not after leading whitespace" },
        .{ .flags = "-w, --width=WIDTH", .desc = "maximum line width (default 75)" },
        .{ .flags = "-g, --goal=GOAL", .desc = "target line width (default 70; derived from WIDTH when only WIDTH is given)" },
        .{ .flags = "-q, --quick", .desc = "break lines with simple greedy fill instead of the optimal algorithm" },
        .{ .flags = "-T, --tab-width=N", .desc = "treat a tab as N columns wide (default 8)" },
    },
    .operands = "FILE...   input files; \"-\" means standard input; with no FILE, reads standard input.",
    .exit = &.{
        .{ .code = 0, .when = "success" },
        .{ .code = 1, .when = "a FILE could not be read, or a usage/option error (invalid width or goal, an unrecognized option, a bad -T value)" },
    },
    .deviations = &.{
        "The legacy `-WIDTH` form (e.g. `fmt -30`) is recognized only as the very first command-line argument; anywhere else it is rejected with a dedicated error instead of being read as a width.",
        "The default GOAL is a fixed 70, not 93% of the default WIDTH (75); GOAL is only derived as WIDTH*93/100 when WIDTH is given explicitly without an accompanying GOAL.",
        "Every codepoint counts as one display column; no East-Asian-wide or combining-mark width table is applied.",
    },
    .examples = &.{
        .{ .cmd = "fmt -w 60 notes.txt", .note = "reflow to a 60-column width" },
        .{ .cmd = "fmt -cw 72 README", .note = "crown-margin mode, each paragraph keeps its own indent" },
        .{ .cmd = "fmt -30 file.txt", .note = "legacy width form (valid only as the very first argument)" },
    },
    .see_also = "fold (blind per-line wrapping, no paragraph reflow).",
};
const MAX_WIDTH: usize = 2500;
const DEFAULT_GOAL: usize = 70;
const DEFAULT_WIDTH: usize = 75;
const GOAL_RATIO: usize = 93;

// ============================================================================ options

const FmtOptions = struct {
    crown: bool = false,
    tagged: bool = false,
    mail: bool = false,
    split_only: bool = false,
    prefix: ?[]const u8 = null,
    xprefix: bool = false,
    anti_prefix: ?[]const u8 = null,
    xanti_prefix: bool = false,
    uniform: bool = false,
    quick: bool = false,
    width: usize = DEFAULT_WIDTH,
    goal: usize = DEFAULT_GOAL,
    tabwidth: usize = 8,
};

// ============================================================================ CLI

const ParseResult = union(enum) { ok: struct { opts: FmtOptions, files: []const []const u8 }, exit: u8 };

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn nextTokenMandatory(argv: []const [:0]const u8, i: *usize) ?[]const u8 {
    if (i.* + 1 >= argv.len) return null;
    i.* += 1;
    return argv[i.*];
}

fn parseArgs(ctx: *Ctx) ParseResult {
    const argv = ctx.args;

    // Pre-check (runs before ANYTHING else, mirroring uumain's own first-arg probe):
    // `-<digit>...<non-digit>` as the VERY first CLI token is a malformed width.
    if (argv.len >= 2) {
        const a0 = argv[1];
        if (a0.len >= 2 and a0[0] == '-' and a0[1] >= '0' and a0[1] <= '9') {
            var malformed = false;
            for (a0[2..]) |c| {
                if (c < '0' or c > '9') {
                    malformed = true;
                    break;
                }
            }
            if (malformed) {
                ctx.errPrint("{s}: invalid width: '{s}'\n", .{ PROG, a0[1..] });
                return .{ .exit = 1 };
            }
        }
    }

    var opts = FmtOptions{};
    var width_val: ?[]const u8 = null;
    var goal_val: ?[]const u8 = null;
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var no_more_flags = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a: []const u8 = argv[i];
        if (no_more_flags) {
            files.append(ctx.gpa, a) catch @panic("OOM");
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            no_more_flags = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--help")) {
            cli.renderHelp(ctx, PROG, help_doc);
            return .{ .exit = 0 };
        }
        if (std.mem.eql(u8, a, "--version")) {
            ctx.outPrint("{s} (nutils) 0.1.0\n", .{PROG});
            return .{ .exit = 0 };
        }
        if (a.len >= 2 and a[0] == '-' and a[1] == '-') {
            const body = a[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const attached: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;
            if (std.mem.eql(u8, name, "crown-margin")) {
                opts.crown = true;
            } else if (std.mem.eql(u8, name, "tagged-paragraph")) {
                opts.tagged = true;
            } else if (std.mem.eql(u8, name, "preserve-headers")) {
                opts.mail = true;
            } else if (std.mem.eql(u8, name, "split-only")) {
                opts.split_only = true;
            } else if (std.mem.eql(u8, name, "uniform-spacing")) {
                opts.uniform = true;
            } else if (std.mem.eql(u8, name, "prefix")) {
                opts.prefix = attached orelse (nextTokenMandatory(argv, &i) orelse return missingValue(ctx, "--prefix"));
            } else if (std.mem.eql(u8, name, "skip-prefix")) {
                opts.anti_prefix = attached orelse (nextTokenMandatory(argv, &i) orelse return missingValue(ctx, "--skip-prefix"));
            } else if (std.mem.eql(u8, name, "exact-prefix")) {
                opts.xprefix = true;
            } else if (std.mem.eql(u8, name, "exact-skip-prefix")) {
                opts.xanti_prefix = true;
            } else if (std.mem.eql(u8, name, "width")) {
                width_val = attached orelse (nextTokenMandatory(argv, &i) orelse return missingValue(ctx, "--width"));
            } else if (std.mem.eql(u8, name, "goal")) {
                goal_val = attached orelse (nextTokenMandatory(argv, &i) orelse return missingValue(ctx, "--goal"));
            } else if (std.mem.eql(u8, name, "quick")) {
                opts.quick = true;
            } else if (std.mem.eql(u8, name, "tab-width")) {
                const v = attached orelse (nextTokenMandatory(argv, &i) orelse return missingValue(ctx, "--tab-width"));
                const n = std.fmt.parseUnsigned(usize, v, 10) catch {
                    ctx.errPrint("{s}: Invalid TABWIDTH specification: {s}\n", .{ PROG, v });
                    return .{ .exit = 1 };
                };
                opts.tabwidth = if (n < 1) 1 else n;
            } else {
                ctx.errPrint("{s}: unrecognized option '--{s}'\n", .{ PROG, name });
                return .{ .exit = 1 };
            }
            continue;
        }
        if (a.len >= 2 and a[0] == '-') {
            if (a[1] >= '0' and a[1] <= '9') {
                // A `-DIGITS` token: legacy WIDTH form, ONLY if it's args[1] itself.
                if (i == 1) {
                    width_val = a[1..];
                    continue;
                }
                ctx.errPrint(
                    "{s}: invalid option -- {c}; -WIDTH is recognized only when it is the first\noption; use -w N instead\nTry '{s} --help' for more information.\n",
                    .{ PROG, a[1], PROG },
                );
                return .{ .exit = 1 };
            }
            var ci: usize = 1;
            while (ci < a.len) {
                const c = a[ci];
                switch (c) {
                    'c' => {
                        opts.crown = true;
                        ci += 1;
                    },
                    't' => {
                        opts.tagged = true;
                        ci += 1;
                    },
                    'm' => {
                        opts.mail = true;
                        ci += 1;
                    },
                    's' => {
                        opts.split_only = true;
                        ci += 1;
                    },
                    'u' => {
                        opts.uniform = true;
                        ci += 1;
                    },
                    'q' => {
                        opts.quick = true;
                        ci += 1;
                    },
                    'x' => {
                        opts.xprefix = true;
                        ci += 1;
                    },
                    'X' => {
                        opts.xanti_prefix = true;
                        ci += 1;
                    },
                    'p' => {
                        const v = if (ci + 1 < a.len) a[ci + 1 ..] else (nextTokenMandatory(argv, &i) orelse return missingValue(ctx, "-p"));
                        opts.prefix = v;
                        ci = a.len;
                    },
                    'P' => {
                        const v = if (ci + 1 < a.len) a[ci + 1 ..] else (nextTokenMandatory(argv, &i) orelse return missingValue(ctx, "-P"));
                        opts.anti_prefix = v;
                        ci = a.len;
                    },
                    'w' => {
                        const v = if (ci + 1 < a.len) a[ci + 1 ..] else (nextTokenMandatory(argv, &i) orelse return missingValue(ctx, "-w"));
                        width_val = v;
                        ci = a.len;
                    },
                    'g' => {
                        const v = if (ci + 1 < a.len) a[ci + 1 ..] else (nextTokenMandatory(argv, &i) orelse return missingValue(ctx, "-g"));
                        goal_val = v;
                        ci = a.len;
                    },
                    'T' => {
                        const v = if (ci + 1 < a.len) a[ci + 1 ..] else (nextTokenMandatory(argv, &i) orelse return missingValue(ctx, "-T"));
                        const n = std.fmt.parseUnsigned(usize, v, 10) catch {
                            ctx.errPrint("{s}: Invalid TABWIDTH specification: {s}\n", .{ PROG, v });
                            return .{ .exit = 1 };
                        };
                        opts.tabwidth = if (n < 1) 1 else n;
                        ci = a.len;
                    },
                    else => {
                        ctx.errPrint("{s}: unrecognized option '-{c}'\n", .{ PROG, c });
                        return .{ .exit = 1 };
                    },
                }
            }
            continue;
        }
        files.append(ctx.gpa, a) catch @panic("OOM");
    }

    const width_opt: ?usize = if (width_val) |v| std.fmt.parseUnsigned(usize, v, 10) catch {
        ctx.errPrint("{s}: invalid width: '{s}'\n", .{ PROG, v });
        return .{ .exit = 1 };
    } else null;
    const goal_opt: ?usize = if (goal_val) |v| std.fmt.parseUnsigned(usize, v, 10) catch {
        ctx.errPrint("{s}: invalid goal: '{s}'\n", .{ PROG, v });
        return .{ .exit = 1 };
    } else null;

    if (width_opt) |w| {
        if (goal_opt) |g| {
            if (g > w) {
                ctx.errPrint("{s}: GOAL cannot be greater than WIDTH.\n", .{PROG});
                return .{ .exit = 1 };
            }
            opts.width = w;
            opts.goal = g;
        } else if (w == 0) {
            opts.width = 0;
            opts.goal = 0;
        } else {
            opts.width = w;
            opts.goal = @max(1, w * GOAL_RATIO / 100);
        }
    } else if (goal_opt) |g| {
        if (g > DEFAULT_WIDTH) {
            ctx.errPrint("{s}: GOAL cannot be greater than WIDTH.\n", .{PROG});
            return .{ .exit = 1 };
        }
        opts.width = @max(g * 100 / GOAL_RATIO, g + 3);
        opts.goal = g;
    } else {
        opts.width = DEFAULT_WIDTH;
        opts.goal = DEFAULT_GOAL;
    }

    if (opts.width > MAX_WIDTH) {
        ctx.errPrint("{s}: invalid width: '{d}': Numerical result out of range\n", .{ PROG, opts.width });
        return .{ .exit = 1 };
    }

    var files_slice = files.toOwnedSlice(ctx.gpa) catch @panic("OOM");
    if (files_slice.len == 0) {
        const one = ctx.gpa.alloc([]const u8, 1) catch @panic("OOM");
        one[0] = "-";
        files_slice = one;
    }

    return .{ .ok = .{ .opts = opts, .files = files_slice } };
}

fn missingValue(ctx: *Ctx, opt: []const u8) ParseResult {
    ctx.errPrint("{s}: option '{s}' requires a value\n", .{ PROG, opt });
    return .{ .exit = 1 };
}

// ============================================================================ byte/char helpers

/// GNU fmt's whitespace set is ASCII-only (space/tab/CR/LF/VT/FF) -- deliberately
/// narrower than Unicode whitespace, per `is_fmt_whitespace`.
fn isFmtWs(b: u8) bool {
    return switch (b) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => true,
        else => false,
    };
}

fn isPunctByte(b: u8) bool {
    return b == '!' or b == '.' or b == '?';
}

/// Byte-length of the (possibly multi-byte) UTF-8 sequence starting at `start`,
/// falling back to 1 for invalid/truncated sequences (matches `decode_char`'s
/// fallback exactly). NOTE (documented gap, see module doc): every codepoint is
/// treated as display-width 1 -- no East-Asian-wide/combining-mark table is ported
/// (`unicode-width` crate has no Zig equivalent here); unaffected for ASCII/Latin
/// text, which is what the corpus exercises.
fn charByteLen(bytes: []const u8, start: usize) usize {
    if (start >= bytes.len) return 1;
    const b0 = bytes[start];
    if (b0 < 0x80) return 1;
    const w: usize = if (b0 >= 0xC2 and b0 <= 0xDF)
        2
    else if (b0 >= 0xE0 and b0 <= 0xEF)
        3
    else if (b0 >= 0xF0 and b0 <= 0xF4)
        4
    else
        1;
    if (w == 1 or start + w > bytes.len) return 1;
    var k: usize = 1;
    while (k < w) : (k += 1) {
        if ((bytes[start + k] & 0xC0) != 0x80) return 1;
    }
    return w;
}

// ============================================================================ line reading + paragraph model

const FileLine = struct {
    line: []const u8,
    /// End of the indent (start of visible text); for crown/tagged, only meaningful
    /// from the 2nd line onward.
    indent_end: usize,
    /// End of the PREFIX's OWN indent (spaces before the prefix match).
    prefix_indent_end: usize,
    indent_len: usize,
    prefix_len: usize,
};

const Line = union(enum) {
    format_line: FileLine,
    /// payload: the raw bytes (dumped verbatim) + whether this was a blank-line break
    /// (relevant only for mail-header re-arming).
    no_format_line: struct { bytes: []const u8, is_blank_break: bool },
};

/// Splits `data` on `\n`, stripping one trailing `\r` per line (matches
/// `FileLines::next`'s own read_until+trim). The final unterminated segment (if any)
/// is still a line, matching every other line-oriented applet's convention here.
fn splitRawLines(gpa: std.mem.Allocator, data: []const u8) [][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var start: usize = 0;
    while (start < data.len) {
        const nl = std.mem.indexOfScalarPos(u8, data, start, '\n');
        const end = nl orelse data.len;
        var line = data[start..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        out.append(gpa, line) catch @panic("OOM");
        if (nl) |n| {
            start = n + 1;
        } else {
            break;
        }
    }
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}

const PrefixMatch = struct { matched: bool, offset: usize };

fn matchPrefixGeneric(pfx: []const u8, line: []const u8, exact: bool) PrefixMatch {
    if (std.mem.startsWith(u8, line, pfx)) return .{ .matched = true, .offset = 0 };
    if (!exact) {
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            if (std.mem.startsWith(u8, line[i..], pfx)) return .{ .matched = true, .offset = i };
            if (!isFmtWs(line[i])) break;
        }
    }
    return .{ .matched = false, .offset = 0 };
}

fn matchPrefix(opts: FmtOptions, line: []const u8) PrefixMatch {
    const pfx = opts.prefix orelse return .{ .matched = true, .offset = 0 };
    return matchPrefixGeneric(pfx, line, opts.xprefix);
}

fn matchAntiPrefix(opts: FmtOptions, line: []const u8) bool {
    const pfx = opts.anti_prefix orelse return true;
    const r = matchPrefixGeneric(pfx, line, opts.xanti_prefix);
    return !r.matched;
}

/// `compute_indent`: walks `bytes` accumulating display width (tabs round up to the
/// next `tabwidth` stop) until the first non-whitespace byte AT OR AFTER
/// `prefix_end`; also records the display width AT `prefix_end` itself (`prefix_len`).
fn computeIndent(opts: FmtOptions, bytes: []const u8, prefix_end: usize) struct { indent_end: usize, prefix_len: usize, indent_len: usize } {
    var prefix_len: usize = 0;
    var indent_len: usize = 0;
    var idx: usize = 0;
    while (idx < bytes.len) {
        if (idx == prefix_end) prefix_len = indent_len;
        const byte = bytes[idx];
        if (idx >= prefix_end and !isFmtWs(byte)) return .{ .indent_end = idx, .prefix_len = prefix_len, .indent_len = indent_len };
        if (byte == '\t') {
            indent_len = (indent_len / opts.tabwidth + 1) * opts.tabwidth;
            idx += 1;
            continue;
        }
        indent_len += 1; // display width 1 per codepoint (see charByteLen's doc note)
        idx += charByteLen(bytes, idx);
    }
    if (prefix_end >= bytes.len) prefix_len = indent_len;
    return .{ .indent_end = bytes.len, .prefix_len = prefix_len, .indent_len = indent_len };
}

fn classifyLine(opts: FmtOptions, raw: []const u8) Line {
    var all_ws = true;
    for (raw) |b| {
        if (!isFmtWs(b)) {
            all_ws = false;
            break;
        }
    }
    if (all_ws) return .{ .no_format_line = .{ .bytes = &[_]u8{}, .is_blank_break = true } };

    const pm = matchPrefix(opts, raw);
    if (!pm.matched) return .{ .no_format_line = .{ .bytes = raw, .is_blank_break = false } };

    const prefix_len_bytes = pm.offset + if (opts.prefix) |p| p.len else 0;
    var rest_all_ws = true;
    if (prefix_len_bytes <= raw.len) {
        for (raw[prefix_len_bytes..]) |b| {
            if (!isFmtWs(b)) {
                rest_all_ws = false;
                break;
            }
        }
    }
    if (rest_all_ws) return .{ .no_format_line = .{ .bytes = raw, .is_blank_break = false } };

    if (!matchAntiPrefix(opts, raw)) return .{ .no_format_line = .{ .bytes = raw, .is_blank_break = false } };

    const ci = computeIndent(opts, raw, prefix_len_bytes);
    return .{ .format_line = .{
        .line = raw,
        .indent_end = ci.indent_end,
        .prefix_indent_end = pm.offset,
        .indent_len = ci.indent_len,
        .prefix_len = ci.prefix_len,
    } };
}

const Paragraph = struct {
    lines: []const []const u8,
    init_str: []const u8 = &[_]u8{},
    init_len: usize = 0,
    init_end: usize = 0,
    indent_str: []const u8 = &[_]u8{},
    indent_len: usize = 0,
    indent_end: usize = 0,
    mail_header: bool = false,
};

/// Is `line` an RFC822-ish mail header start: `From ` OR printable-ASCII-except-colon
/// then `:`.
fn isMailHeader(fl: FileLine) bool {
    if (fl.indent_end > 0) return false;
    if (std.mem.startsWith(u8, fl.line, "From ")) return true;
    const colon = std.mem.indexOfScalar(u8, fl.line, ':') orelse return false;
    if (colon == 0) return false;
    for (fl.line[0..colon]) |b| {
        if (b < 33 or b > 126 or b == ':') return false;
    }
    return true;
}

fn concatOwned(gpa: std.mem.Allocator, a: []const u8, b: []const u8) []const u8 {
    const out = gpa.alloc(u8, a.len + b.len) catch @panic("OOM");
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

const ParaOrLine = union(enum) { paragraph: Paragraph, no_format: []const u8 };

/// Array-indexed port of `ParagraphStream::next` (see module doc for why: one line
/// of lookahead via a `Peekable` iterator becomes plain indexed walking once every
/// line is pre-classified). `next_mail` is threaded through exactly like the
/// original's `self.next_mail` (true at start of file and after a blank-line break).
fn buildParagraphs(gpa: std.mem.Allocator, opts: FmtOptions, classified: []const Line) []const ParaOrLine {
    var out: std.ArrayListUnmanaged(ParaOrLine) = .empty;
    var idx: usize = 0;
    var next_mail = true;
    while (idx < classified.len) {
        if (classified[idx] == .no_format_line) {
            const nf = classified[idx].no_format_line;
            out.append(gpa, .{ .no_format = nf.bytes }) catch @panic("OOM");
            next_mail = nf.is_blank_break;
            idx += 1;
            continue;
        }

        var init_str: []const u8 = &[_]u8{};
        var init_len: usize = 0;
        var init_end: usize = 0;
        var indent_str: []const u8 = &[_]u8{};
        var indent_len: usize = 0;
        var indent_end: usize = 0;
        var prefix_len: usize = 0;
        var prefix_indent_end: usize = 0;
        var p_lines: std.ArrayListUnmanaged([]const u8) = .empty;
        var in_mail = false;
        var second_done = false;

        while (idx < classified.len and classified[idx] == .format_line) {
            const fl = classified[idx].format_line;
            if (p_lines.items.len == 0) {
                if (opts.mail and next_mail and isMailHeader(fl)) {
                    in_mail = true;
                    indent_str = "  ";
                    indent_len = 2;
                } else {
                    if (opts.crown or opts.tagged) {
                        init_str = fl.line[0..fl.indent_end];
                        init_len = fl.indent_len;
                        init_end = fl.indent_end;
                    } else {
                        second_done = true;
                    }
                    indent_str = fl.line[0..fl.indent_end];
                    indent_len = fl.indent_len;
                    indent_end = fl.indent_end;
                    prefix_len = fl.prefix_len;
                    prefix_indent_end = fl.prefix_indent_end;
                    if (opts.tagged) {
                        indent_str = concatOwned(gpa, indent_str, "    ");
                        indent_len += 4;
                    }
                }
            } else if (in_mail) {
                if (fl.indent_end == 0 or (opts.prefix != null and fl.prefix_indent_end == 0)) break;
            } else if (!second_done) {
                if (prefix_len != fl.prefix_len or prefix_indent_end != fl.prefix_indent_end) break;
                if (opts.tagged and indent_len >= 4 and indent_len - 4 == fl.indent_len and indent_end == fl.indent_end) break;
                indent_str = fl.line[0..fl.indent_end];
                indent_len = fl.indent_len;
                indent_end = fl.indent_end;
                second_done = true;
            } else {
                if (indent_end != fl.indent_end or prefix_indent_end != fl.prefix_indent_end or indent_len != fl.indent_len or prefix_len != fl.prefix_len) break;
            }
            p_lines.append(gpa, fl.line) catch @panic("OOM");
            idx += 1;
            if (opts.split_only) break;
        }

        next_mail = in_mail;
        out.append(gpa, .{ .paragraph = .{
            .lines = p_lines.toOwnedSlice(gpa) catch @panic("OOM"),
            .init_str = init_str,
            .init_len = init_len,
            .init_end = init_end,
            .indent_str = indent_str,
            .indent_len = indent_len,
            .indent_end = indent_end,
            .mail_header = in_mail,
        } }) catch @panic("OOM");
    }
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}

// ============================================================================ word splitting

const WordInfo = struct {
    word: []const u8,
    word_start: usize,
    word_nchars: usize,
    before_tab: ?usize,
    after_tab: usize,
    sentence_start: bool,
    ends_punct: bool,
    new_line: bool,
};

fn countCodepoints(bytes: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        i += charByteLen(bytes, i);
        n += 1;
    }
    return n;
}

const WordSplit = struct {
    opts: FmtOptions,
    bytes: []const u8,
    length: usize,
    position: usize = 0,
    prev_punct: bool = false,

    fn init(opts: FmtOptions, bytes: []const u8) WordSplit {
        var start: usize = 0;
        while (start < bytes.len and isFmtWs(bytes[start])) : (start += 1) {}
        const trimmed = bytes[start..];
        return .{ .opts = opts, .bytes = trimmed, .length = trimmed.len };
    }

    /// Only ASCII whitespace bytes are ever inspected by this scan (a multi-byte
    /// UTF-8 lead byte immediately fails `isFmtWs` and ends the scan) so byte-stepping
    /// (not codepoint-stepping) is exactly what the reference's own
    /// `bytes.iter().enumerate()` does here.
    fn analyzeTabs(self: *const WordSplit, bytes: []const u8) struct { before_tab: ?usize, after_tab: usize, word_start: ?usize } {
        var before_tab: ?usize = null;
        var after_tab: usize = 0;
        var idx: usize = 0;
        while (idx < bytes.len) : (idx += 1) {
            const b = bytes[idx];
            if (!isFmtWs(b)) return .{ .before_tab = before_tab, .after_tab = after_tab, .word_start = idx };
            if (b == '\t') {
                if (before_tab == null) {
                    before_tab = after_tab;
                    after_tab = 0;
                } else {
                    after_tab = (after_tab / self.opts.tabwidth + 1) * self.opts.tabwidth;
                }
            } else {
                after_tab += 1;
            }
        }
        return .{ .before_tab = before_tab, .after_tab = after_tab, .word_start = null };
    }

    fn scanWordEnd(self: *const WordSplit, word_start: usize) struct { end: usize, nchars: usize, last_ascii: ?u8 } {
        var nchars: usize = 0;
        var idx = word_start;
        var last_ascii: ?u8 = null;
        while (idx < self.length) {
            const b0 = self.bytes[idx];
            if (b0 < 0x80) {
                if (isFmtWs(b0)) break;
                nchars += 1;
                last_ascii = b0;
                idx += 1;
            } else {
                idx += charByteLen(self.bytes, idx);
                nchars += 1;
                last_ascii = null;
            }
        }
        return .{ .end = idx, .nchars = nchars, .last_ascii = last_ascii };
    }

    fn next(self: *WordSplit) ?WordInfo {
        if (self.position >= self.length) return null;
        const old_position = self.position;
        const new_line = old_position == 0;

        const at = self.analyzeTabs(self.bytes[old_position..]);
        if (at.word_start == null) {
            self.position = self.length;
            return null;
        }
        const word_start_abs = at.word_start.? + old_position;

        const sw = self.scanWordEnd(word_start_abs);
        self.position = sw.end;

        const word_start_relative_raw = word_start_abs - old_position;
        const is_sentence_start = self.prev_punct and (at.before_tab != null or word_start_relative_raw > 1);
        const ends_punct = if (sw.last_ascii) |c| isPunctByte(c) else false;
        self.prev_punct = ends_punct;

        var word: []const u8 = undefined;
        var word_start_relative: usize = undefined;
        var before_tab: ?usize = null;
        var after_tab: usize = 0;
        if (self.opts.uniform) {
            word = self.bytes[word_start_abs..self.position];
            word_start_relative = 0;
        } else {
            word = self.bytes[old_position..self.position];
            word_start_relative = word_start_relative_raw;
            before_tab = at.before_tab;
            after_tab = at.after_tab;
        }
        return .{
            .word = word,
            .word_start = word_start_relative,
            .word_nchars = sw.nchars,
            .before_tab = before_tab,
            .after_tab = after_tab,
            .sentence_start = is_sentence_start,
            .ends_punct = ends_punct,
            .new_line = new_line,
        };
    }
};

/// `ParaWords::create_words`: mail headers split on any whitespace run (uniform
/// 1-space spacing, no tab/sentence tracking); otherwise each PHYSICAL line gets its
/// OWN fresh `WordSplit` (so `prev_punct`/sentence detection resets at every line
/// break -- matches the reference's per-line `flat_map`, not a single paragraph-wide
/// scan).
fn buildParaWords(gpa: std.mem.Allocator, opts: FmtOptions, para: Paragraph) []const WordInfo {
    var words: std.ArrayListUnmanaged(WordInfo) = .empty;
    if (para.mail_header) {
        for (para.lines) |line| {
            var i: usize = 0;
            while (i < line.len) {
                while (i < line.len and isFmtWs(line[i])) : (i += 1) {}
                const start = i;
                while (i < line.len and !isFmtWs(line[i])) : (i += 1) {}
                if (i > start) {
                    const seg = line[start..i];
                    words.append(gpa, .{
                        .word = seg,
                        .word_start = 0,
                        .word_nchars = countCodepoints(seg),
                        .before_tab = null,
                        .after_tab = 0,
                        .sentence_start = false,
                        .ends_punct = false,
                        .new_line = false,
                    }) catch @panic("OOM");
                }
            }
        }
    } else {
        if (para.lines.len > 0) {
            const cut = if (opts.crown or opts.tagged) para.init_end else para.indent_end;
            const first = para.lines[0];
            var ws0 = WordSplit.init(opts, first[@min(cut, first.len)..]);
            while (ws0.next()) |w| words.append(gpa, w) catch @panic("OOM");
        }
        if (para.lines.len > 1) {
            for (para.lines[1..]) |line| {
                var ws = WordSplit.init(opts, line[@min(para.indent_end, line.len)..]);
                while (ws.next()) |w| words.append(gpa, w) catch @panic("OOM");
            }
        }
    }
    return words.toOwnedSlice(gpa) catch @panic("OOM");
}

// ============================================================================ line breaking (linebreak.rs)

const BAD_MULT: f32 = 200.0;
const DR_MULT: f32 = 600.0;
const DL_MULT: f32 = 10.0;
const ORPHAN_BREAK_PENALTY: i64 = 250_000_000;

const BreakCtx = struct {
    opts: FmtOptions,
    init_len: usize,
    indent: []const u8,
    indent_len: usize,
    uniform: bool,
};

fn computeWidth(ctx: BreakCtx, w: WordInfo, posn: usize, fresh: bool) usize {
    if (fresh) return 0;
    const post = w.after_tab;
    if (w.before_tab) |pre| {
        return post + ((pre + posn) / ctx.opts.tabwidth + 1) * ctx.opts.tabwidth - posn;
    }
    return post;
}

fn computeSlen(uniform: bool, newline: bool, start: bool, punct: bool) usize {
    if (uniform or newline) {
        return if (start or (newline and punct)) 2 else 1;
    }
    return 0;
}

fn sliceIfFresh(fresh: bool, word: []const u8, start: usize, uniform: bool, newline: bool, sstart: bool, punct: bool) struct { slen: usize, word: []const u8 } {
    if (fresh) return .{ .slen = 0, .word = word[start..] };
    return .{ .slen = computeSlen(uniform, newline, sstart, punct), .word = word };
}

fn writeNewline(out: *textio.BufOut, indent: []const u8) void {
    out.push('\n') catch {};
    out.extend(indent) catch {};
}

fn writeWithSpaces(out: *textio.BufOut, word: []const u8, slen: usize) void {
    if (slen == 2) {
        out.extend("  ") catch {};
    } else if (slen == 1) {
        out.push(' ') catch {};
    }
    out.extend(word) catch {};
}

/// `break_simple`: greedy fill (used for `-q` and mail headers).
fn breakSimple(out: *textio.BufOut, words: []const WordInfo, ctx: BreakCtx) void {
    var l = ctx.init_len;
    var prev_punct = false;
    for (words) |w| {
        const wlen = w.word_nchars + computeWidth(ctx, w, l, false);
        const slen = computeSlen(ctx.uniform, w.new_line, w.sentence_start, prev_punct);
        if (l + wlen + slen > ctx.opts.width) {
            writeNewline(out, ctx.indent);
            writeWithSpaces(out, w.word[w.word_start..], 0);
            l = ctx.indent_len + w.word_nchars;
        } else {
            writeWithSpaces(out, w.word, slen);
            l = l + wlen + slen;
        }
        prev_punct = w.ends_punct;
    }
    out.push('\n') catch {};
}

fn isWordSentenceFinal(current: WordInfo, next: ?WordInfo) bool {
    const n = next orelse return true;
    return n.sentence_start or (n.new_line and current.ends_punct);
}

fn isNextWordSentenceFinal(words: []const WordInfo, i: usize) bool {
    if (i >= words.len) return false;
    const next2: ?WordInfo = if (i + 1 < words.len) words[i + 1] else null;
    return isWordSentenceFinal(words[i], next2);
}

/// Rust's `f32::powi(3)` (an LLVM intrinsic) is approximated as left-to-right
/// `x*x*x` -- see the module doc's byte-parity note.
fn powi3(x: f32) f32 {
    return x * x * x;
}

fn f32ToI64Sat(x: f32) i64 {
    if (std.math.isNan(x)) return 0;
    const max_f: f32 = 9223372036854775807.0;
    const min_f: f32 = -9223372036854775808.0;
    if (x >= max_f) return std.math.maxInt(i64);
    if (x <= min_f) return std.math.minInt(i64);
    return @intFromFloat(x);
}

fn computeDemerits(delta_len: isize, stretch: usize, wlen: usize, prev_rat: f32) struct { demerits: i64, ratio: f32 } {
    const ratio: f32 = if (delta_len == 0) 0.0 else @as(f32, @floatFromInt(delta_len)) / @as(f32, @floatFromInt(stretch));
    const bad_linelen: i64 = f32ToI64Sat(BAD_MULT * @abs(powi3(ratio)));
    const bad_wordlen: i64 = if (wlen >= stretch) 0 else blk: {
        const num: f32 = @floatFromInt(stretch - wlen);
        const den: f32 = @floatFromInt(stretch - 1);
        break :blk f32ToI64Sat(DL_MULT * @abs(powi3(num / den)));
    };
    const bad_delta_r: i64 = if (std.math.isNan(prev_rat)) 0 else blk: {
        const d = (ratio - prev_rat) / 2.0;
        break :blk f32ToI64Sat(DR_MULT * @abs(powi3(d)));
    };
    const base: i64 = ((@as(i64, 1) +| bad_linelen) +| bad_wordlen) +| bad_delta_r;
    return .{ .demerits = base *| base, .ratio = ratio };
}

const LineBreakNode = struct {
    prev: usize,
    linebreak: ?usize, // index into `words`
    break_before: bool,
    demerits: i64,
    prev_rat: f32,
    length: usize,
    fresh: bool,
};

fn restartActiveBreaks(ctx: BreakCtx, active: LineBreakNode, act_idx: usize, w: WordInfo, slen: usize, min: usize) LineBreakNode {
    var break_before: bool = undefined;
    var line_length: usize = undefined;
    if (active.fresh) {
        break_before = false;
        line_length = ctx.indent_len;
    } else {
        const wlen = w.word_nchars + computeWidth(ctx, w, active.length, active.fresh);
        const underlen: isize = @as(isize, @intCast(min)) - @as(isize, @intCast(active.length));
        const overlen: isize = @as(isize, @intCast(wlen + slen + active.length)) - @as(isize, @intCast(ctx.opts.width));
        if (overlen > underlen) {
            break_before = true;
            line_length = ctx.indent_len + w.word_nchars;
        } else {
            break_before = false;
            line_length = ctx.indent_len;
        }
    }
    return .{
        .prev = act_idx,
        .linebreak = null, // set by caller (needs the word's index, not the value)
        .break_before = break_before,
        .demerits = 0,
        .prev_rat = if (break_before) 1.0 else -1.0,
        .length = line_length,
        .fresh = !break_before,
    };
}

/// Ports `find_kp_breakpoints` + `build_best_path`. Returns breakpoints in FORWARD
/// order (word index + break-before flag) -- reversed from the reference's own
/// (parent-pointer-chased) order, since this port renders via random array access
/// rather than a cooperatively-advanced shared iterator (see module doc).
const Breakpoint = struct { word_idx: usize, break_before: bool };

fn findKpBreakpoints(gpa: std.mem.Allocator, words: []const WordInfo, ctx: BreakCtx) []const Breakpoint {
    var nodes: std.ArrayListUnmanaged(LineBreakNode) = .empty;
    nodes.append(gpa, .{ .prev = 0, .linebreak = null, .break_before = false, .demerits = 0, .prev_rat = std.math.nan(f32), .length = ctx.init_len, .fresh = false }) catch @panic("OOM");

    var active_breaks: std.ArrayListUnmanaged(usize) = .empty;
    active_breaks.append(gpa, 0) catch @panic("OOM");
    var next_active: std.ArrayListUnmanaged(usize) = .empty;

    const stretch = ctx.opts.width - ctx.opts.goal;
    const minlength: usize = if (ctx.opts.goal <= 10) 1 else @max(ctx.opts.goal, stretch + 1) - stretch;

    var is_sentence_start = false;
    for (words, 0..) |w, wi| {
        // `is_next_word_sentence_final` in the reference peeks starting from the word
        // AFTER the current one (`wi+1`), not the current word itself.
        const next_word_sentence_final = isNextWordSentenceFinal(words, wi + 1);
        const is_last_word = wi + 1 >= words.len;
        const is_sentence_end = if (is_last_word) true else (words[wi + 1].sentence_start or (words[wi + 1].new_line and w.ends_punct));

        const slen = computeSlen(ctx.uniform, w.new_line, is_sentence_start, false);

        var best_active_demerits: i64 = std.math.maxInt(i64);
        var ld_idx: usize = 0;
        var best_break_before: ?LineBreakNode = null;
        var best_break_after: ?LineBreakNode = null;
        next_active.clearRetainingCapacity();

        for (active_breaks.items) |ai| {
            const active = nodes.items[ai];
            if (active.demerits < best_active_demerits) {
                best_active_demerits = active.demerits;
                ld_idx = ai;
            }

            if (!active.fresh and active.length >= minlength) {
                const cd = computeDemerits(@as(isize, @intCast(ctx.opts.goal)) - @as(isize, @intCast(active.length)), stretch, w.word_nchars, active.prev_rat);
                var nd = cd.demerits;
                if (is_sentence_end) nd = nd +| ORPHAN_BREAK_PENALTY;
                const total = active.demerits +| nd;
                if (best_break_before == null or total < best_break_before.?.demerits) {
                    best_break_before = .{ .prev = ai, .linebreak = wi, .break_before = true, .demerits = total, .prev_rat = cd.ratio, .length = ctx.indent_len + w.word_nchars, .fresh = false };
                }
            }

            const tlen = w.word_nchars + computeWidth(ctx, w, active.length, active.fresh) + slen + active.length;
            if (tlen <= ctx.opts.width) {
                next_active.append(gpa, ai) catch @panic("OOM");
                nodes.items[ai].fresh = false;
                nodes.items[ai].length = tlen;

                if (tlen >= minlength) {
                    var nd: i64 = undefined;
                    var ratio: f32 = undefined;
                    if (is_last_word) {
                        nd = 0;
                        ratio = 0.0;
                    } else {
                        const cd = computeDemerits(@as(isize, @intCast(ctx.opts.goal)) - @as(isize, @intCast(tlen)), stretch, w.word_nchars, active.prev_rat);
                        nd = cd.demerits;
                        ratio = cd.ratio;
                    }
                    if (!is_last_word and next_word_sentence_final) nd = nd +| ORPHAN_BREAK_PENALTY;
                    const total = active.demerits +| nd;
                    if (best_break_after == null or total < best_break_after.?.demerits) {
                        best_break_after = .{ .prev = ai, .linebreak = wi, .break_before = false, .demerits = total, .prev_rat = ratio, .length = ctx.indent_len, .fresh = true };
                    }
                }
            }
        }

        if (best_break_before) |lb| {
            next_active.append(gpa, nodes.items.len) catch @panic("OOM");
            nodes.append(gpa, lb) catch @panic("OOM");
        }
        if (best_break_after) |lb| {
            next_active.append(gpa, nodes.items.len) catch @panic("OOM");
            nodes.append(gpa, lb) catch @panic("OOM");
        }

        if (next_active.items.len == 0) {
            var restarted = restartActiveBreaks(ctx, nodes.items[ld_idx], ld_idx, w, slen, minlength);
            restarted.linebreak = wi;
            next_active.append(gpa, nodes.items.len) catch @panic("OOM");
            nodes.append(gpa, restarted) catch @panic("OOM");
        }

        std.mem.swap(std.ArrayListUnmanaged(usize), &active_breaks, &next_active);
        is_sentence_start = is_sentence_end;
    }

    // build_best_path: pick the active node with the fewest demerits, then chase
    // `.prev` pointers back to the root, collecting (word_idx, break_before).
    var out: std.ArrayListUnmanaged(Breakpoint) = .empty;
    if (active_breaks.items.len == 0) return out.toOwnedSlice(gpa) catch @panic("OOM");
    var best_idx = active_breaks.items[0];
    var best_demerits = nodes.items[best_idx].demerits;
    for (active_breaks.items[1..]) |ai| {
        if (nodes.items[ai].demerits < best_demerits) {
            best_demerits = nodes.items[ai].demerits;
            best_idx = ai;
        }
    }
    var rev: std.ArrayListUnmanaged(Breakpoint) = .empty;
    while (true) {
        const node = nodes.items[best_idx];
        const lb = node.linebreak orelse break;
        rev.append(gpa, .{ .word_idx = lb, .break_before = node.break_before }) catch @panic("OOM");
        best_idx = node.prev;
    }
    var i: usize = rev.items.len;
    while (i > 0) {
        i -= 1;
        out.append(gpa, rev.items[i]) catch @panic("OOM");
    }
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}

/// Renders the words using the breakpoints from `findKpBreakpoints`, via direct
/// array indexing (see module doc: this port has random access to `words`, unlike
/// the reference's single forward iterator shared between the search and render
/// passes, so no `ptr::eq` tracking is needed -- otherwise the exact per-word state
/// transitions of `break_knuth_plass`'s render loop are preserved verbatim).
fn renderKnuthPlass(out: *textio.BufOut, words: []const WordInfo, breakpoints: []const Breakpoint, ctx: BreakCtx) void {
    var word_i: usize = 0;
    var prev_punct = false;
    var fresh = false;
    for (breakpoints) |bp| {
        if (fresh) writeNewline(out, ctx.indent);
        while (word_i < words.len) {
            const w = words[word_i];
            const sw = sliceIfFresh(fresh, w.word, w.word_start, ctx.uniform, w.new_line, w.sentence_start, prev_punct);
            fresh = false;
            prev_punct = w.ends_punct;
            const is_bp_word = word_i == bp.word_idx;
            word_i += 1;
            if (is_bp_word) {
                if (bp.break_before) {
                    writeNewline(out, ctx.indent);
                    writeWithSpaces(out, w.word[w.word_start..], 0);
                } else {
                    writeWithSpaces(out, sw.word, sw.slen);
                    fresh = true;
                }
                break;
            }
            writeWithSpaces(out, sw.word, sw.slen);
        }
    }
    while (word_i < words.len) : (word_i += 1) {
        const w = words[word_i];
        if (fresh) writeNewline(out, ctx.indent);
        const sw = sliceIfFresh(fresh, w.word, w.word_start, ctx.uniform, w.new_line, w.sentence_start, prev_punct);
        prev_punct = w.ends_punct;
        fresh = false;
        writeWithSpaces(out, sw.word, sw.slen);
    }
    out.push('\n') catch {};
}

fn breakKnuthPlass(gpa: std.mem.Allocator, out: *textio.BufOut, words: []const WordInfo, ctx: BreakCtx) void {
    const bps = findKpBreakpoints(gpa, words, ctx);
    renderKnuthPlass(out, words, bps, ctx);
}

/// `break_lines`: writes the paragraph's init/indent, the first word, then dispatches
/// to the simple or Knuth-Plass breaker for the rest.
fn breakLines(gpa: std.mem.Allocator, out: *textio.BufOut, para: Paragraph, opts: FmtOptions) void {
    const words = buildParaWords(gpa, opts, para);
    if (words.len == 0) {
        out.push('\n') catch {};
        return;
    }
    const first = words[0];
    var init_len = first.word_nchars;
    if (opts.crown or opts.tagged) {
        out.extend(para.init_str) catch {};
        init_len += para.init_len;
    } else if (!para.mail_header) {
        out.extend(para.indent_str) catch {};
        init_len += para.indent_len;
    }
    out.extend(first.word) catch {};

    const uniform = para.mail_header or opts.uniform;
    const ctx = BreakCtx{ .opts = opts, .init_len = init_len, .indent = para.indent_str, .indent_len = para.indent_len, .uniform = uniform };

    const rest = words[1..];
    if (opts.quick or para.mail_header) {
        breakSimple(out, rest, ctx);
    } else {
        breakKnuthPlass(gpa, out, rest, ctx);
    }
}

// ============================================================================ driver

/// `process_file`: reads one FILE (or stdin) whole, splits+classifies its lines,
/// walks the resulting paragraphs, and either dumps a `NoFormatLine` verbatim (plus
/// one `\n`, matching the reference appending a newline after the raw bytes it
/// read -- the terminator the line itself lost when it was split off) or reflows a
/// real paragraph.
fn processFile(gpa: std.mem.Allocator, ctx: *Ctx, out: *textio.BufOut, file_name: []const u8, opts: FmtOptions) u8 {
    const is_stdin = std.mem.eql(u8, file_name, "-");
    const fd = if (is_stdin) ctx.stdin else sys.open(file_name, .{ .read = true }) catch |e| {
        ctx.errPrint("{s}: cannot open '{s}' for reading: {s}\n", .{ PROG, file_name, sys.strerror(sys.toErrno(e)) });
        return 1;
    };
    defer if (!is_stdin) sys.close(fd);

    if (!is_stdin) {
        const st = sys.stat(file_name) catch null;
        if (st) |s| {
            if (s.is_dir) {
                ctx.errPrint("{s}: read error\n", .{PROG});
                return 1;
            }
        }
    }

    const data = textio.readAll(gpa, fd) catch {
        ctx.errPrint("{s}: failed to write output\n", .{PROG});
        return 1;
    };
    const raw_lines = splitRawLines(gpa, data);
    const classified = gpa.alloc(Line, raw_lines.len) catch @panic("OOM");
    for (raw_lines, 0..) |rl, idx| classified[idx] = classifyLine(opts, rl);

    const paragraphs = buildParagraphs(gpa, opts, classified);
    for (paragraphs) |pl| {
        switch (pl) {
            .no_format => |bytes| {
                out.extend(bytes) catch {};
                out.push('\n') catch {};
            },
            .paragraph => |para| breakLines(gpa, out, para, opts),
        }
    }
    return 0;
}

pub fn run(ctx: *Ctx) u8 {
    const res = parseArgs(ctx);
    const parsed = switch (res) {
        .exit => |c| return c,
        .ok => |p| p,
    };

    var out = textio.BufOut.init(ctx.stdout);
    var rc: u8 = 0;
    for (parsed.files) |f| {
        const r = processFile(ctx.gpa, ctx, &out, f, parsed.opts);
        if (r != 0) rc = r;
    }
    out.finish() catch {};
    return rc;
}
