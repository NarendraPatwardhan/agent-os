//! `test` / `[` -- DESIGN.md §1: hand-parsed expression evaluator (no
//! `cli.zig` for operands -- only a leading `--help`/`-h` for `test`, never for `[`).
//! Recursive descent: `or := and (-o and)*`; `and := factor (-a factor)*`;
//! `factor := "!" factor | "(" expr ")" | primary`. `primary` looks only at the
//! immediately-remaining tokens: >=3 with a recognized binary op in slot 1 wins over
//! >=2 with a recognized unary op in slot 0, which wins over the single-token
//! non-empty-string test, which wins over the zero-token `false`. Trailing unconsumed
//! tokens after a full parse are an error. `[` additionally requires a trailing `]`
//! operand (stripped before parsing) -- its absence is `[: missing ']'`, exit 2.
//!
//! Exit: 0 true / 1 false / 2 `<name>: invalid expression`.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "evaluate a conditional expression, exiting 0 (true) or 1 (false)",
    .synopsis = &.{ "test EXPRESSION", "[ EXPRESSION ]" },
    .description =
    \\Evaluates EXPRESSION and exits 0 if it is true, 1 if it is false. There are no
    \\traditional "options" -- every token is either an operand or one of the
    \\operators below, combined via a small recursive-descent grammar: `or := and
    \\(-o and)*`; `and := factor (-a factor)*`; `factor := "!" factor | "(" expr ")"
    \\| primary`. `primary` looks only at the immediately remaining tokens: three
    \\tokens with a recognized binary operator in the middle wins over two tokens
    \\with a recognized unary operator first, which wins over a single non-empty
    \\string token, which wins over zero tokens (false). Trailing tokens left over
    \\after a full parse are a syntax error.
    \\
    \\Operators: file unary `-e` (exists), `-f` (regular file), `-d` (directory),
    \\`-r`/`-w`/`-x` (owner readable/writable/executable), `-s` (size > 0); string
    \\unary `-z` (empty), `-n` (non-empty); string binary `=`/`==` (equal), `!=`
    \\(not equal); integer binary `-eq -ne -lt -le -gt -ge`; file-age binary
    \\`-nt`/`-ot` (newer-than/older-than by mtime; a missing file loses the comparison);
    \\logical `!` (not), `EXPR -a EXPR` (and, binds tighter), `EXPR -o EXPR` (or),
    \\`( EXPR )` (grouping).
    \\
    \\Invoked as `[`, EXPRESSION must be followed by a literal `]` operand (stripped
    \\before parsing); invoked as `test`, no closing token is needed or accepted.
    ,
    .options_note = "test/[ takes no options; every token is an operand or one of the operators listed in DESCRIPTION. --help/-h is recognized only as test's first argument (never for [).",
    .exit = &.{
        .{ .code = 0, .when = "EXPRESSION evaluated true" },
        .{ .code = 1, .when = "EXPRESSION evaluated false" },
        .{ .code = 2, .when = "invalid expression (bad grammar, non-numeric operand to an integer operator, or -- for [ only -- a missing trailing ])" },
    },
    .deviations_from = "GNU coreutils test/[",
    .deviations = &.{
        "Unary predicates -L -h -O -G -N -t -ef -b -c -p -S -k -u -g and the -a/-o short-circuit warnings GNU emits for ambiguous forms are not supported.",
    },
    .examples = &.{
        .{ .cmd = "test 3 -lt 5", .note = "true, exit 0" },
        .{ .cmd = "[ -f /etc/passwd ]", .note = "true iff /etc/passwd is a regular file" },
        .{ .cmd = "test -n \"$x\" -a -d \"$x\"", .note = "true iff $x is non-empty and names a directory" },
    },
    .see_also = "true, false.",
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const EvalError = error{Invalid};

const BinOp = enum { streq, strne, eq, ne, lt, le, gt, ge, nt, ot };
const UnOp = enum { exists, isfile, isdir, readable, writable, executable, sizepos, strempty, strnonempty };

fn binaryOp(tok: []const u8) ?BinOp {
    if (eq(tok, "=") or eq(tok, "==")) return .streq;
    if (eq(tok, "!=")) return .strne;
    if (eq(tok, "-eq")) return .eq;
    if (eq(tok, "-ne")) return .ne;
    if (eq(tok, "-lt")) return .lt;
    if (eq(tok, "-le")) return .le;
    if (eq(tok, "-gt")) return .gt;
    if (eq(tok, "-ge")) return .ge;
    if (eq(tok, "-nt")) return .nt;
    if (eq(tok, "-ot")) return .ot;
    return null;
}

fn unaryOp(tok: []const u8) ?UnOp {
    if (eq(tok, "-e")) return .exists;
    if (eq(tok, "-f")) return .isfile;
    if (eq(tok, "-d")) return .isdir;
    if (eq(tok, "-r")) return .readable;
    if (eq(tok, "-w")) return .writable;
    if (eq(tok, "-x")) return .executable;
    if (eq(tok, "-s")) return .sizepos;
    if (eq(tok, "-z")) return .strempty;
    if (eq(tok, "-n")) return .strnonempty;
    return null;
}

/// mtime tie-break: true iff `a` exists and (`b` is missing or `a`.mtime > `b`.mtime).
fn newerThan(a: []const u8, b: []const u8) bool {
    const sa = sys.stat(a) catch return false;
    const sb = sys.stat(b) catch null;
    if (sb) |s| return sa.mtime_ms > s.mtime_ms;
    return true;
}

fn evalBinary(op: BinOp, a: []const u8, b: []const u8) EvalError!bool {
    return switch (op) {
        .streq => eq(a, b),
        .strne => !eq(a, b),
        .nt => newerThan(a, b),
        .ot => newerThan(b, a),
        else => {
            const ia = std.fmt.parseInt(i64, a, 10) catch return error.Invalid;
            const ib = std.fmt.parseInt(i64, b, 10) catch return error.Invalid;
            return switch (op) {
                .eq => ia == ib,
                .ne => ia != ib,
                .lt => ia < ib,
                .le => ia <= ib,
                .gt => ia > ib,
                .ge => ia >= ib,
                else => unreachable,
            };
        },
    };
}

fn evalUnary(op: UnOp, a: []const u8) bool {
    return switch (op) {
        .strempty => a.len == 0,
        .strnonempty => a.len != 0,
        else => {
            const st = sys.stat(a) catch return false;
            return switch (op) {
                .exists => true,
                .isfile => !st.is_dir,
                .isdir => st.is_dir,
                .readable => st.readable(),
                .writable => st.writable(),
                .executable => st.executable(),
                .sizepos => st.size > 0,
                else => unreachable,
            };
        },
    };
}

const Parser = struct {
    toks: []const []const u8,
    pos: usize = 0,

    fn peek(self: *const Parser) ?[]const u8 {
        if (self.pos < self.toks.len) return self.toks[self.pos];
        return null;
    }

    fn parseOr(self: *Parser) EvalError!bool {
        var v = try self.parseAnd();
        while (self.peek()) |t| {
            if (!eq(t, "-o")) break;
            self.pos += 1;
            const rhs = try self.parseAnd();
            v = v or rhs;
        }
        return v;
    }

    fn parseAnd(self: *Parser) EvalError!bool {
        var v = try self.parseFactor();
        while (self.peek()) |t| {
            if (!eq(t, "-a")) break;
            self.pos += 1;
            const rhs = try self.parseFactor();
            v = v and rhs;
        }
        return v;
    }

    fn parseFactor(self: *Parser) EvalError!bool {
        if (self.peek()) |t| {
            if (eq(t, "!")) {
                self.pos += 1;
                const v = try self.parseFactor();
                return !v;
            }
            if (eq(t, "(")) {
                self.pos += 1;
                const v = try self.parseOr();
                const close = self.peek() orelse return error.Invalid;
                if (!eq(close, ")")) return error.Invalid;
                self.pos += 1;
                return v;
            }
        }
        return self.primary();
    }

    fn primary(self: *Parser) EvalError!bool {
        const left = self.toks.len - self.pos;
        if (left >= 3) {
            if (binaryOp(self.toks[self.pos + 1])) |op| {
                const a = self.toks[self.pos];
                const b = self.toks[self.pos + 2];
                self.pos += 3;
                return evalBinary(op, a, b);
            }
        }
        if (left >= 2) {
            if (unaryOp(self.toks[self.pos])) |op| {
                const a = self.toks[self.pos + 1];
                self.pos += 2;
                return evalUnary(op, a);
            }
        }
        if (left >= 1) {
            const a = self.toks[self.pos];
            self.pos += 1;
            return a.len != 0;
        }
        return false;
    }
};

pub fn run(ctx: *Ctx) u8 {
    const prog = ctx.args[0];
    const is_bracket = eq(prog, "[");
    var toks: []const [:0]const u8 = ctx.args[1..];

    if (!is_bracket and toks.len >= 1 and (eq(toks[0], "--help") or eq(toks[0], "-h"))) {
        cli.renderHelp(ctx, "test", help_doc);
        return 0;
    }

    if (is_bracket) {
        if (toks.len == 0 or !eq(toks[toks.len - 1], "]")) {
            ctx.errPrint("[: missing ']'\n", .{});
            return 2;
        }
        toks = toks[0 .. toks.len - 1];
    }

    // Parser wants `[]const []const u8`; the sentinel-terminated argv slice coerces
    // element-wise but not as a whole slice type, so copy the (small) pointer list.
    var buf: [256][]const u8 = undefined;
    const n = @min(toks.len, buf.len);
    for (toks[0..n], 0..) |t, i| buf[i] = t;

    var p = Parser{ .toks = buf[0..n] };
    const result = p.parseOr() catch {
        ctx.errPrint("{s}: invalid expression\n", .{prog});
        return 2;
    };
    if (p.pos != p.toks.len) {
        ctx.errPrint("{s}: invalid expression\n", .{prog});
        return 2;
    }
    return if (result) @as(u8, 0) else 1;
}
