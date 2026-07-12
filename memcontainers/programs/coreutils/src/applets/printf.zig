//! `printf` -- DESIGN.md §1: hand-parsed byte-exact engine (clap only
//! for leading `--help`/`--version`). Escapes `\a \b \f \n \r \t \v \\` (NOT `\e`),
//! `\c` stop-everything, octal `\NNN` (<=3 digits; in `%b` arguments `\0` + <=3 more
//! digits, GNU-lenient `\NNN` also accepted there), hex `\xHH` (1-2 digits), Unicode
//! `\uHHHH`/`\UHHHHHHHH` -> UTF-8. Conversions `%s %b %c %d %i %u %o %x %X %%` with
//! flags `- + space 0 #` (`'` accepted+ignored), width and `.precision` (both `*`
//! from args); C length modifiers `l h L q j z t` skipped silently. UNKNOWN
//! conversions (including `%f %e %g %a`!) are emitted VERBATIM -- the matrix
//! documents this deviation from GNU, which formats floats. FORMAT is reused while
//! args remain, but a pass that consumes no argument ends the loop (GNU rule; we do
//! not print GNU's "ignoring excess arguments" warning -- source: spec).
//!
//! Numeric arg parse: leading `'`/`"` -> next byte's code (POSIX); else signed
//! decimal where a partial parse prints the parsed prefix and diagnoses
//! `printf: '<arg>': value not completely converted`, and a digit-less arg diagnoses
//! `printf: '<arg>': expected a numeric value` (wordings match GNU; the *decimal
//! only* rule -- no 0x/0 radix prefixes -- is the reference's documented deviation).
//! Both set exit 1 but processing CONTINUES. Missing args -> empty string / 0
//! (silent). Exit 0, or 1 if any conversion error occurred; usage error 2.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const fmtnum = @import("../core/fmtnum.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "format and print data",
    .synopsis = &.{"printf FORMAT [ARGUMENT]..."},
    .description =
    \\Writes ARGUMENTs to standard output under the C printf FORMAT string. FORMAT is
    \\cycled as long as arguments remain; a cycle that consumes no argument runs exactly
    \\once. Backslash escapes in FORMAT are interpreted, and each conversion consumes one
    \\ARGUMENT.
    \\
    \\Escapes: \a \b \f \n \r \t \v \\, \NNN (octal, <=3 digits), \xHH (hex, 1-2 digits),
    \\\uHHHH / \UHHHHHHHH (Unicode -> UTF-8), and \c (stop all output). Conversions:
    \\%s %b %c %d %i %u %o %x %X %%, with flags - + space 0 #, a field width, and a
    \\.precision -- width and precision may be * to read the value from the next ARGUMENT.
    ,
    .options_note = "printf takes no options. --help and --version are honored only as the first argument.",
    .operands = "FORMAT (required) is the format string. Each ARGUMENT is consumed by a conversion; a missing argument is treated as the empty string (for %s/%b/%c) or 0 (for numeric conversions).",
    .exit = &.{
        .{ .code = 0, .when = "success" },
        .{ .code = 1, .when = "a numeric argument was malformed (a diagnostic is printed and processing continues)" },
        .{ .code = 2, .when = "no FORMAT operand" },
    },
    .deviations_from = "GNU coreutils printf",
    .deviations = &.{
        "Float conversions %f %e %g %a are not supported; any unrecognized conversion is emitted verbatim (\"%f\" prints the two bytes \"%f\").",
        "Numeric arguments are parsed as decimal only; leading-0 octal and 0x hex forms are not recognized (\"0x10\" parses as 0 and reports an error).",
        "No \"ignoring excess arguments\" warning is printed.",
    },
    .examples = &.{
        .{ .cmd = "printf '%s\\n' a b c", .note = "a, b, c -- each on its own line" },
        .{ .cmd = "printf '%d + %d = %d\\n' 2 3 5", .note = "2 + 3 = 5" },
        .{ .cmd = "printf '\\101\\x42\\n'", .note = "AB" },
    },
    .see_also = "seq (number sequences), echo.",
};

const Runner = struct {
    ctx: *Ctx,
    out: textio.BufOut,
    args: []const [:0]const u8,
    argi: usize = 0,
    had_err: bool = false,
    stopped: bool = false,

    fn nextArg(r: *Runner) ?[]const u8 {
        if (r.argi >= r.args.len) return null;
        const a = r.args[r.argi];
        r.argi += 1;
        return a;
    }

    /// POSIX numeric operand: leading quote = next byte's code, else signed decimal.
    /// Diagnostics go to stderr and set the exit-1 flag, but a value is always
    /// produced and processing continues.
    fn parseNumeric(r: *Runner, arg: []const u8) i64 {
        if (arg.len == 0) {
            r.ctx.errPrint("printf: '{s}': expected a numeric value\n", .{arg});
            r.had_err = true;
            return 0;
        }
        if (arg[0] == '\'' or arg[0] == '"') {
            if (arg.len >= 2) return arg[1];
            r.ctx.errPrint("printf: '{s}': expected a numeric value\n", .{arg});
            r.had_err = true;
            return 0;
        }
        var i: usize = 0;
        var neg = false;
        if (arg[0] == '+' or arg[0] == '-') {
            neg = arg[0] == '-';
            i = 1;
        }
        var v: i128 = 0;
        var any = false;
        while (i < arg.len and arg[i] >= '0' and arg[i] <= '9') : (i += 1) {
            any = true;
            v = v * 10 + (arg[i] - '0');
            if (v > std.math.maxInt(i64)) v = std.math.maxInt(i64); // saturate
        }
        if (!any) {
            r.ctx.errPrint("printf: '{s}': expected a numeric value\n", .{arg});
            r.had_err = true;
            return 0;
        }
        if (neg) v = -v;
        if (i != arg.len) {
            r.ctx.errPrint("printf: '{s}': value not completely converted\n", .{arg});
            r.had_err = true;
        }
        return @intCast(std.math.clamp(v, std.math.minInt(i64), std.math.maxInt(i64)));
    }
};

const Esc = struct {
    consumed: usize,
    bytes: [4]u8 = undefined,
    n: usize = 0,
    stop: bool = false,
};

fn isOctal(c: u8) bool {
    return c >= '0' and c <= '7';
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Decodes one escape sequence at `s` (s[0] == '\\'). `b_mode` selects the `%b`
/// octal variant (`\0` + up to 3 more digits).
fn decodeEscape(s: []const u8, b_mode: bool) Esc {
    var e = Esc{ .consumed = 1 };
    if (s.len < 2) {
        e.bytes[0] = '\\';
        e.n = 1;
        return e;
    }
    const c = s[1];
    e.consumed = 2;
    switch (c) {
        'a' => {
            e.bytes[0] = 0x07;
            e.n = 1;
        },
        'b' => {
            e.bytes[0] = 0x08;
            e.n = 1;
        },
        'f' => {
            e.bytes[0] = 0x0c;
            e.n = 1;
        },
        'n' => {
            e.bytes[0] = '\n';
            e.n = 1;
        },
        'r' => {
            e.bytes[0] = '\r';
            e.n = 1;
        },
        't' => {
            e.bytes[0] = '\t';
            e.n = 1;
        },
        'v' => {
            e.bytes[0] = 0x0b;
            e.n = 1;
        },
        '\\' => {
            e.bytes[0] = '\\';
            e.n = 1;
        },
        'c' => e.stop = true,
        '0'...'7' => {
            var j: usize = 1;
            var val: u32 = 0;
            var limit: usize = 1 + 3; // \NNN: up to 3 digits total
            if (b_mode and c == '0') {
                j = 2; // the '0' selects %b octal form; up to 3 MORE digits follow
                limit = 2 + 3;
            }
            while (j < s.len and j < limit and isOctal(s[j])) : (j += 1) {
                val = val * 8 + (s[j] - '0');
            }
            e.bytes[0] = @truncate(val);
            e.n = 1;
            e.consumed = j;
        },
        'x' => {
            var j: usize = 2;
            var val: u32 = 0;
            var any = false;
            while (j < s.len and j < 4) : (j += 1) {
                const h = hexVal(s[j]) orelse break;
                val = val * 16 + h;
                any = true;
            }
            if (!any) {
                // no hex digit: "\x" is literal
                e.bytes[0] = '\\';
                e.bytes[1] = 'x';
                e.n = 2;
                return e;
            }
            e.bytes[0] = @truncate(val);
            e.n = 1;
            e.consumed = j;
        },
        'u', 'U' => {
            const want: usize = if (c == 'u') 4 else 8;
            if (s.len < 2 + want) {
                e.bytes[0] = '\\';
                e.bytes[1] = c;
                e.n = 2;
                return e;
            }
            var val: u32 = 0;
            var j: usize = 2;
            while (j < 2 + want) : (j += 1) {
                const h = hexVal(s[j]) orelse {
                    e.bytes[0] = '\\';
                    e.bytes[1] = c;
                    e.n = 2;
                    return e;
                };
                val = val * 16 + h;
            }
            const cp = std.math.cast(u21, val) orelse {
                e.bytes[0] = '\\';
                e.bytes[1] = c;
                e.n = 2;
                return e;
            };
            const len = std.unicode.utf8Encode(cp, &e.bytes) catch {
                e.bytes[0] = '\\';
                e.bytes[1] = c;
                e.n = 2;
                return e;
            };
            e.n = len;
            e.consumed = 2 + want;
        },
        else => {
            // unknown escape: emitted verbatim (backslash + char)
            e.bytes[0] = '\\';
            e.bytes[1] = c;
            e.n = 2;
        },
    }
    return e;
}

/// Expands `%b`-argument escapes into gpa-owned memory; sets `r.stopped` on `\c`.
fn expandB(r: *Runner, s: []const u8) []const u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\') {
            const e = decodeEscape(s[i..], true);
            if (e.stop) {
                r.stopped = true;
                break;
            }
            list.appendSlice(r.ctx.gpa, e.bytes[0..e.n]) catch @panic("OOM");
            i += e.consumed;
        } else {
            list.append(r.ctx.gpa, s[i]) catch @panic("OOM");
            i += 1;
        }
    }
    return list.items;
}

/// One pass over FORMAT. Returns an error only on a downstream write failure.
fn runFormatOnce(r: *Runner, format: []const u8) !void {
    var i: usize = 0;
    while (i < format.len) {
        const c = format[i];
        if (c == '\\') {
            const e = decodeEscape(format[i..], false);
            if (e.stop) {
                r.stopped = true;
                return;
            }
            try r.out.extend(e.bytes[0..e.n]);
            i += e.consumed;
            continue;
        }
        if (c != '%') {
            try r.out.push(c);
            i += 1;
            continue;
        }
        if (i + 1 < format.len and format[i + 1] == '%') {
            try r.out.push('%');
            i += 2;
            continue;
        }
        const start = i;
        var j = i + 1;
        var spec = fmtnum.Spec{ .conv = 0 };
        // flags ('\'' accepted and ignored)
        while (j < format.len) : (j += 1) {
            switch (format[j]) {
                '-' => spec.flags.minus = true,
                '+' => spec.flags.plus = true,
                ' ' => spec.flags.space = true,
                '0' => spec.flags.zero = true,
                '#' => spec.flags.hash = true,
                '\'' => {},
                else => break,
            }
        }
        // width (digits or * from args; negative * width means left-justify)
        if (j < format.len and format[j] == '*') {
            j += 1;
            const wv = if (r.nextArg()) |a| r.parseNumeric(a) else 0;
            if (wv < 0) {
                spec.flags.minus = true;
                spec.width = @intCast(-wv);
            } else {
                spec.width = @intCast(wv);
            }
        } else {
            while (j < format.len and format[j] >= '0' and format[j] <= '9') : (j += 1) {
                spec.width = spec.width * 10 + (format[j] - '0');
            }
        }
        // precision ('.'; bare '.' means 0; negative * precision means none)
        if (j < format.len and format[j] == '.') {
            j += 1;
            if (j < format.len and format[j] == '*') {
                j += 1;
                const pv = if (r.nextArg()) |a| r.parseNumeric(a) else 0;
                spec.precision = if (pv < 0) null else @intCast(pv);
            } else {
                var p: usize = 0;
                while (j < format.len and format[j] >= '0' and format[j] <= '9') : (j += 1) {
                    p = p * 10 + (format[j] - '0');
                }
                spec.precision = p;
            }
        }
        // C length modifiers, skipped silently
        while (j < format.len and std.mem.indexOfScalar(u8, "lhLqjzt", format[j]) != null) j += 1;
        if (j >= format.len) {
            // dangling '%...' with no conversion char: emitted verbatim (source: spec)
            try r.out.extend(format[start..]);
            return;
        }
        const conv = format[j];
        j += 1;
        spec.conv = conv;
        switch (conv) {
            'd', 'i' => {
                const v = if (r.nextArg()) |a| r.parseNumeric(a) else 0;
                try fmtnum.emitInt(&r.out, spec, v);
            },
            'u', 'o', 'x', 'X' => {
                const v = if (r.nextArg()) |a| r.parseNumeric(a) else 0;
                try fmtnum.emitUint(&r.out, spec, @bitCast(v));
            },
            's' => {
                const a = r.nextArg() orelse "";
                try fmtnum.emitStr(&r.out, spec, a);
            },
            'c' => {
                const a = r.nextArg() orelse "";
                spec.precision = null; // precision is meaningless for %c
                try fmtnum.emitStr(&r.out, spec, if (a.len > 0) a[0..1] else "");
            },
            'b' => {
                const a = r.nextArg() orelse "";
                const expanded = expandB(r, a);
                if (r.stopped) {
                    // \c stops everything immediately; the partial expansion is
                    // written unpadded (source: spec).
                    try r.out.extend(expanded);
                    return;
                }
                try fmtnum.emitStr(&r.out, spec, expanded);
            },
            else => {
                // unknown conversion (incl. %f/%e/%g/%a): verbatim
                try r.out.extend(format[start..j]);
            },
        }
        i = j;
    }
}

pub fn run(ctx: *Ctx) u8 {
    // Only leading --help/--version (matrix: first-arg only, no -h).
    if (ctx.args.len >= 2) {
        const a = ctx.args[1];
        if (std.mem.eql(u8, a, "--help")) {
            cli.renderHelp(ctx, "printf", help_doc);
            return 0;
        }
        if (std.mem.eql(u8, a, "--version")) {
            ctx.print(ctx.stdout, "printf 0.1.0\n", .{});
            return 0;
        }
    }
    if (ctx.args.len < 2) {
        ctx.errPrint("printf: missing operand\n", .{});
        return 2;
    }
    const format = ctx.args[1];
    var r = Runner{
        .ctx = ctx,
        .out = textio.BufOut.init(ctx.stdout),
        .args = ctx.args[2..],
    };
    while (true) {
        const before = r.argi;
        runFormatOnce(&r, format) catch break; // downstream closed: stop quietly
        if (r.stopped) break;
        if (r.argi >= r.args.len) break;
        if (r.argi == before) break; // a pass that consumes nothing runs only once
    }
    r.out.finish() catch {};
    return if (r.had_err) 1 else 0;
}
