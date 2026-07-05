//! POSIX arithmetic expansion `$(( ... ))`.

const std = @import("std");

pub const ArithError = error{
    BadHex,
    BadNumber,
    BadOperator,
    DivisionByZero,
    ExpectedColon,
    ExpectedRParen,
    NeedsVariable,
    OutOfMemory,
    TrailingTokens,
    UnexpectedChar,
    UnexpectedToken,
};

pub const ArithEnv = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (*anyopaque, []const u8) i64,
        set: *const fn (*anyopaque, []const u8, i64) void,
    };

    pub fn get(self: *ArithEnv, name: []const u8) i64 {
        return self.vtable.get(self.ptr, name);
    }

    pub fn set(self: *ArithEnv, name: []const u8, val: i64) void {
        self.vtable.set(self.ptr, name, val);
    }
};

pub fn eval(allocator: std.mem.Allocator, expr: []const u8, env: *ArithEnv) ArithError!i64 {
    const toks = try lex(allocator, expr);
    var parser = Parser{ .toks = toks, .pos = 0, .env = env };
    const value = try parser.expr(0);
    try parser.expectEof();
    return value;
}

const Tok = union(enum) {
    num: i64,
    name: []const u8,
    op: []const u8,
    lparen,
    rparen,
};

fn lex(allocator: std.mem.Allocator, source: []const u8) ArithError![]Tok {
    var out = std.ArrayList(Tok).empty;
    var i: usize = 0;
    while (i < source.len) {
        const ch = source[i];
        if (std.ascii.isWhitespace(ch)) {
            i += 1;
            continue;
        }
        if (std.ascii.isDigit(ch)) {
            const start = i;
            if (ch == '0' and i + 1 < source.len and (source[i + 1] == 'x' or source[i + 1] == 'X')) {
                i += 2;
                const hex_start = i;
                while (i < source.len and std.ascii.isHex(source[i])) i += 1;
                const value = std.fmt.parseInt(i64, source[hex_start..i], 16) catch return error.BadHex;
                try out.append(allocator, .{ .num = value });
                continue;
            }
            while (i < source.len and std.ascii.isDigit(source[i])) i += 1;
            const value = std.fmt.parseInt(i64, source[start..i], 10) catch return error.BadNumber;
            try out.append(allocator, .{ .num = value });
            continue;
        }
        if (ch == '_' or std.ascii.isAlphabetic(ch)) {
            const start = i;
            i += 1;
            while (i < source.len and (source[i] == '_' or std.ascii.isAlphanumeric(source[i]))) i += 1;
            try out.append(allocator, .{ .name = source[start..i] });
            continue;
        }
        if (ch == '(') {
            try out.append(allocator, .lparen);
            i += 1;
            continue;
        }
        if (ch == ')') {
            try out.append(allocator, .rparen);
            i += 1;
            continue;
        }
        if (matchOp(source[i..])) |op| {
            try out.append(allocator, .{ .op = op });
            i += op.len;
            continue;
        }
        return error.UnexpectedChar;
    }
    return out.toOwnedSlice(allocator) catch return error.BadNumber;
}

fn matchOp(rest: []const u8) ?[]const u8 {
    inline for (.{ "<<=", ">>=" }) |op| {
        if (std.mem.startsWith(u8, rest, op)) return op;
    }
    inline for (.{ "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "++", "--", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=" }) |op| {
        if (std.mem.startsWith(u8, rest, op)) return op;
    }
    inline for (.{ "+", "-", "*", "/", "%", "<", ">", "=", "!", "~", "&", "|", "^", "?", ":", "," }) |op| {
        if (std.mem.startsWith(u8, rest, op)) return op;
    }
    return null;
}

const Parser = struct {
    toks: []Tok,
    pos: usize,
    env: *ArithEnv,

    fn peek(self: *Parser) ?Tok {
        if (self.pos >= self.toks.len) return null;
        return self.toks[self.pos];
    }

    fn bump(self: *Parser) ?Tok {
        const tok = self.peek() orelse return null;
        self.pos += 1;
        return tok;
    }

    fn expectEof(self: *Parser) ArithError!void {
        if (self.pos != self.toks.len) return error.TrailingTokens;
    }

    fn expr(self: *Parser, min_bp: u8) ArithError!i64 {
        var lhs = try self.unary();
        while (true) {
            const op = switch (self.peek() orelse break) {
                .op => |o| o,
                else => break,
            };
            const bp = infixBp(op) orelse break;
            if (bp.l < min_bp) break;
            _ = self.bump();
            if (std.mem.eql(u8, op, "?")) {
                const then_v = try self.expr(0);
                switch (self.bump() orelse return error.ExpectedColon) {
                    .op => |colon| if (!std.mem.eql(u8, colon, ":")) return error.ExpectedColon,
                    else => return error.ExpectedColon,
                }
                const else_v = try self.expr(bp.r);
                lhs = if (lhs != 0) then_v else else_v;
                continue;
            }
            const rhs = try self.expr(bp.r);
            lhs = try apply(op, lhs, rhs);
        }
        return lhs;
    }

    fn unary(self: *Parser) ArithError!i64 {
        const tok = self.peek() orelse return error.UnexpectedToken;
        switch (tok) {
            .op => |op| {
                if (std.mem.eql(u8, op, "+")) {
                    _ = self.bump();
                    return self.unary();
                }
                if (std.mem.eql(u8, op, "-")) {
                    _ = self.bump();
                    return 0 -% try self.unary();
                }
                if (std.mem.eql(u8, op, "!")) {
                    _ = self.bump();
                    return if ((try self.unary()) == 0) 1 else 0;
                }
                if (std.mem.eql(u8, op, "~")) {
                    _ = self.bump();
                    return ~(try self.unary());
                }
                if (std.mem.eql(u8, op, "++") or std.mem.eql(u8, op, "--")) {
                    _ = self.bump();
                    const next = self.bump() orelse return error.NeedsVariable;
                    const name = switch (next) {
                        .name => |n| n,
                        else => return error.NeedsVariable,
                    };
                    const cur = self.env.get(name);
                    const nv = if (std.mem.eql(u8, op, "++")) cur +% 1 else cur -% 1;
                    self.env.set(name, nv);
                    return nv;
                }
            },
            else => {},
        }
        return self.primary();
    }

    fn primary(self: *Parser) ArithError!i64 {
        const tok = self.bump() orelse return error.UnexpectedToken;
        return switch (tok) {
            .num => |n| n,
            .lparen => blk: {
                const value = try self.expr(0);
                switch (self.bump() orelse return error.ExpectedRParen) {
                    .rparen => break :blk value,
                    else => return error.ExpectedRParen,
                }
            },
            .name => |name| try self.nameValue(name),
            else => error.UnexpectedToken,
        };
    }

    fn nameValue(self: *Parser, name: []const u8) ArithError!i64 {
        const tok = self.peek() orelse return self.env.get(name);
        const op = switch (tok) {
            .op => |o| o,
            else => return self.env.get(name),
        };
        if (std.mem.eql(u8, op, "=")) {
            _ = self.bump();
            const value = try self.expr(2);
            self.env.set(name, value);
            return value;
        }
        if (compoundBase(op)) |base| {
            _ = self.bump();
            const rhs = try self.expr(2);
            const value = try apply(base, self.env.get(name), rhs);
            self.env.set(name, value);
            return value;
        }
        if (std.mem.eql(u8, op, "++")) {
            _ = self.bump();
            const cur = self.env.get(name);
            self.env.set(name, cur +% 1);
            return cur;
        }
        if (std.mem.eql(u8, op, "--")) {
            _ = self.bump();
            const cur = self.env.get(name);
            self.env.set(name, cur -% 1);
            return cur;
        }
        return self.env.get(name);
    }
};

fn compoundBase(op: []const u8) ?[]const u8 {
    inline for (.{ "+=", "-=", "*=", "/=", "%=", "<<=", ">>=", "&=", "|=", "^=" }) |candidate| {
        if (std.mem.eql(u8, op, candidate)) return candidate[0 .. candidate.len - 1];
    }
    return null;
}

const BindingPower = struct { l: u8, r: u8 };

fn infixBp(op: []const u8) ?BindingPower {
    if (std.mem.eql(u8, op, ",")) return .{ .l = 1, .r = 2 };
    if (std.mem.eql(u8, op, "?")) return .{ .l = 4, .r = 3 };
    if (std.mem.eql(u8, op, "||")) return .{ .l = 5, .r = 6 };
    if (std.mem.eql(u8, op, "&&")) return .{ .l = 7, .r = 8 };
    if (std.mem.eql(u8, op, "|")) return .{ .l = 9, .r = 10 };
    if (std.mem.eql(u8, op, "^")) return .{ .l = 11, .r = 12 };
    if (std.mem.eql(u8, op, "&")) return .{ .l = 13, .r = 14 };
    if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=")) return .{ .l = 15, .r = 16 };
    if (std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, "<=") or std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, ">=")) return .{ .l = 17, .r = 18 };
    if (std.mem.eql(u8, op, "<<") or std.mem.eql(u8, op, ">>")) return .{ .l = 19, .r = 20 };
    if (std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "-")) return .{ .l = 21, .r = 22 };
    if (std.mem.eql(u8, op, "*") or std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "%")) return .{ .l = 23, .r = 24 };
    return null;
}

fn apply(op: []const u8, a: i64, b: i64) ArithError!i64 {
    if (std.mem.eql(u8, op, ",")) return b;
    if (std.mem.eql(u8, op, "||")) return if (a != 0 or b != 0) 1 else 0;
    if (std.mem.eql(u8, op, "&&")) return if (a != 0 and b != 0) 1 else 0;
    if (std.mem.eql(u8, op, "|")) return a | b;
    if (std.mem.eql(u8, op, "^")) return a ^ b;
    if (std.mem.eql(u8, op, "&")) return a & b;
    if (std.mem.eql(u8, op, "==")) return if (a == b) 1 else 0;
    if (std.mem.eql(u8, op, "!=")) return if (a != b) 1 else 0;
    if (std.mem.eql(u8, op, "<")) return if (a < b) 1 else 0;
    if (std.mem.eql(u8, op, "<=")) return if (a <= b) 1 else 0;
    if (std.mem.eql(u8, op, ">")) return if (a > b) 1 else 0;
    if (std.mem.eql(u8, op, ">=")) return if (a >= b) 1 else 0;
    if (std.mem.eql(u8, op, "<<")) return a << shiftAmount(b);
    if (std.mem.eql(u8, op, ">>")) return a >> shiftAmount(b);
    if (std.mem.eql(u8, op, "+")) return a +% b;
    if (std.mem.eql(u8, op, "-")) return a -% b;
    if (std.mem.eql(u8, op, "*")) return a *% b;
    if (std.mem.eql(u8, op, "/")) {
        if (b == 0) return error.DivisionByZero;
        if (a == std.math.minInt(i64) and b == -1) return std.math.minInt(i64);
        return @divTrunc(a, b);
    }
    if (std.mem.eql(u8, op, "%")) {
        if (b == 0) return error.DivisionByZero;
        if (a == std.math.minInt(i64) and b == -1) return 0;
        return @rem(a, b);
    }
    return error.BadOperator;
}

fn shiftAmount(v: i64) u6 {
    const as_u: u64 = @bitCast(v);
    return @truncate(as_u);
}
