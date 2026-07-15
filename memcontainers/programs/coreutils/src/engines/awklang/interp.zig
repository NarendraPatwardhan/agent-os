//! A POSIX-subset awk: lexer -> AST -> tree-walking interpreter, matching the awk-rs
//! 0.1.0 crate the memcontainers box wrapped (its subset is the spec). Fields/FS/OFS/ORS/
//! NR/NF/FNR/FILENAME/RS, BEGIN/END, pattern-action rules (incl. /re/ and range patterns),
//! the full expression grammar, if/while/for/for-in/do-while/break/continue/next/exit,
//! user functions, associative arrays, and the common builtins (length substr index split
//! sub gsub match sprintf sin cos atan2 exp log sqrt int rand srand tolower toupper).
//! print/printf render through core/fmtnum; ~ / match / split(re) / sub / gsub use the
//! Pike-VM regex (ERE). Numeric-string coercion is value.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("value.zig");
const Value = value.Value;
const fmtnum = @import("../../core/fmtnum.zig");
const regex = @import("../regex.zig");

// ============================================================ lexer

const Tok = union(enum) {
    number: f64,
    string: []const u8,
    ere: []const u8,
    ident: []const u8,
    func_name: []const u8, // ident immediately followed by '(' (no space)
    builtin: []const u8,
    keyword: Kw,
    op: []const u8, // multi-char and single-char operators/punctuation
    newline,
    eof,
};

const Kw = enum { BEGIN, END, function, @"if", @"else", @"while", @"for", do, @"break", @"continue", next, exit, @"return", delete, in, getline, print, printf };

const keywords = std.StaticStringMap(Kw).initComptime(.{
    .{ "BEGIN", .BEGIN },     .{ "END", .END },          .{ "function", .function },    .{ "func", .function },
    .{ "if", .@"if" },        .{ "else", .@"else" },     .{ "while", .@"while" },       .{ "for", .@"for" },
    .{ "do", .do },           .{ "break", .@"break" },   .{ "continue", .@"continue" }, .{ "next", .next },
    .{ "exit", .exit },       .{ "return", .@"return" }, .{ "delete", .delete },        .{ "in", .in },
    .{ "getline", .getline }, .{ "print", .print },      .{ "printf", .printf },
});

const builtins = std.StaticStringMap(void).initComptime(.{
    .{"length"},  .{"substr"}, .{"index"}, .{"split"},   .{"sub"},     .{"gsub"},   .{"match"},
    .{"sprintf"}, .{"sin"},    .{"cos"},   .{"atan2"},   .{"exp"},     .{"log"},    .{"sqrt"},
    .{"int"},     .{"rand"},   .{"srand"}, .{"tolower"}, .{"toupper"}, .{"system"}, .{"close"},
});

const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    gpa: Allocator,
    toks: std.ArrayListUnmanaged(Tok) = .empty,
    // A '/' is a division operator when the previous token could end an expression,
    // else it begins an ERE literal.
    prev_ends_expr: bool = false,

    fn err(self: *Lexer) error{Lex} {
        _ = self;
        return error.Lex;
    }

    fn run(self: *Lexer) error{ Lex, OutOfMemory }![]Tok {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\\' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\n') {
                self.pos += 2; // line continuation
                continue;
            }
            if (c == ' ' or c == '\t') {
                self.pos += 1;
                continue;
            }
            if (c == '\r') {
                self.pos += 1;
                continue;
            }
            if (c == '#') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                continue;
            }
            if (c == '\n') {
                self.pos += 1;
                try self.push(.newline);
                continue;
            }
            if (c == '"') {
                try self.lexString();
                continue;
            }
            if (c == '/' and !self.prev_ends_expr) {
                try self.lexEre();
                continue;
            }
            if (isDigit(c) or (c == '.' and self.pos + 1 < self.src.len and isDigit(self.src[self.pos + 1]))) {
                try self.lexNumber();
                continue;
            }
            if (isIdentStart(c)) {
                try self.lexIdent();
                continue;
            }
            try self.lexOp();
        }
        try self.push(.eof);
        return self.toks.items;
    }

    fn push(self: *Lexer, t: Tok) !void {
        self.prev_ends_expr = switch (t) {
            .number, .string, .ident, .ere => true,
            .op => |o| std.mem.eql(u8, o, ")") or std.mem.eql(u8, o, "]") or std.mem.eql(u8, o, "$") == false and (std.mem.eql(u8, o, "++") or std.mem.eql(u8, o, "--")),
            .keyword => false,
            else => false,
        };
        // A closing ) or ] or an identifier/number/string/ere ends an expression.
        try self.toks.append(self.gpa, t);
    }

    fn lexString(self: *Lexer) !void {
        self.pos += 1; // opening quote
        var out: std.ArrayListUnmanaged(u8) = .empty;
        while (self.pos < self.src.len and self.src[self.pos] != '"') {
            const c = self.src[self.pos];
            if (c == '\\' and self.pos + 1 < self.src.len) {
                self.pos += 1;
                const e = self.src[self.pos];
                try out.append(self.gpa, switch (e) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"' => '"',
                    '/' => '/',
                    'a' => 0x07,
                    'b' => 0x08,
                    'f' => 0x0C,
                    'v' => 0x0B,
                    else => e,
                });
                self.pos += 1;
            } else {
                try out.append(self.gpa, c);
                self.pos += 1;
            }
        }
        if (self.pos >= self.src.len) return self.err();
        self.pos += 1; // closing quote
        try self.push(.{ .string = out.items });
    }

    fn lexEre(self: *Lexer) !void {
        self.pos += 1; // opening /
        var out: std.ArrayListUnmanaged(u8) = .empty;
        while (self.pos < self.src.len and self.src[self.pos] != '/') {
            const c = self.src[self.pos];
            if (c == '\\' and self.pos + 1 < self.src.len) {
                try out.append(self.gpa, c);
                try out.append(self.gpa, self.src[self.pos + 1]);
                self.pos += 2;
            } else if (c == '\n') {
                return self.err();
            } else {
                try out.append(self.gpa, c);
                self.pos += 1;
            }
        }
        if (self.pos >= self.src.len) return self.err();
        self.pos += 1; // closing /
        try self.push(.{ .ere = out.items });
    }

    fn lexNumber(self: *Lexer) !void {
        const start = self.pos;
        // hex
        if (self.src[self.pos] == '0' and self.pos + 1 < self.src.len and (self.src[self.pos + 1] == 'x' or self.src[self.pos + 1] == 'X')) {
            self.pos += 2;
            while (self.pos < self.src.len and isHex(self.src[self.pos])) self.pos += 1;
            const n = std.fmt.parseInt(i64, self.src[start + 2 .. self.pos], 16) catch 0;
            try self.push(.{ .number = @floatFromInt(n) });
            return;
        }
        while (self.pos < self.src.len and (isDigit(self.src[self.pos]) or self.src[self.pos] == '.')) self.pos += 1;
        if (self.pos < self.src.len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) self.pos += 1;
            while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.pos += 1;
        }
        const n = std.fmt.parseFloat(f64, self.src[start..self.pos]) catch 0;
        try self.push(.{ .number = n });
    }

    fn lexIdent(self: *Lexer) !void {
        const start = self.pos;
        while (self.pos < self.src.len and isIdentPart(self.src[self.pos])) self.pos += 1;
        const word = self.src[start..self.pos];
        if (keywords.get(word)) |kw| {
            try self.push(.{ .keyword = kw });
            return;
        }
        if (builtins.has(word)) {
            try self.push(.{ .builtin = word });
            return;
        }
        // function call: ident immediately followed by '(' (no whitespace)
        if (self.pos < self.src.len and self.src[self.pos] == '(') {
            try self.push(.{ .func_name = word });
            return;
        }
        try self.push(.{ .ident = word });
    }

    fn lexOp(self: *Lexer) !void {
        const two = if (self.pos + 1 < self.src.len) self.src[self.pos .. self.pos + 2] else "";
        const twos = [_][]const u8{ "==", "!=", "<=", ">=", "&&", "||", "++", "--", "+=", "-=", "*=", "/=", "%=", "^=", "!~", ">>" };
        for (twos) |t| {
            if (std.mem.eql(u8, two, t)) {
                self.pos += 2;
                try self.push(.{ .op = t });
                return;
            }
        }
        const one = self.src[self.pos .. self.pos + 1];
        self.pos += 1;
        try self.push(.{ .op = one });
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isHex(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
fn isIdentPart(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

// ============================================================ AST

const Expr = union(enum) {
    num: f64,
    str: []const u8,
    ere: []const u8, // bare /re/ -> matches against $0
    field: *Expr, // $expr
    variable: []const u8,
    index: struct { name: []const u8, subs: []*Expr }, // arr[subs]
    assign: struct { op: u8, target: *Expr, val: *Expr }, // op: '='..., '+','-','*','/','%','^'
    binary: struct { op: []const u8, l: *Expr, r: *Expr },
    unary: struct { op: u8, e: *Expr },
    incdec: struct { op: u8, pre: bool, target: *Expr },
    ternary: struct { c: *Expr, a: *Expr, b: *Expr },
    match: struct { neg: bool, l: *Expr, r: *Expr },
    concat: struct { l: *Expr, r: *Expr },
    in: struct { key: []*Expr, arr: []const u8 },
    call: struct { name: []const u8, args: []*Expr },
    builtin: struct { name: []const u8, args: []*Expr },
    getline: struct { target: ?*Expr }, // simple getline / getline var
    grouping: *Expr,
};

const Stmt = union(enum) {
    expr: *Expr,
    print: struct { args: []*Expr, redir: ?Redir },
    printf: struct { args: []*Expr, redir: ?Redir },
    @"if": struct { c: *Expr, then: *Stmt, els: ?*Stmt },
    @"while": struct { c: *Expr, body: *Stmt },
    do: struct { body: *Stmt, c: *Expr },
    @"for": struct { init: ?*Stmt, c: ?*Expr, post: ?*Stmt, body: *Stmt },
    for_in: struct { v: []const u8, arr: []const u8, body: *Stmt },
    block: []*Stmt,
    next,
    exit: ?*Expr,
    @"return": ?*Expr,
    @"break",
    @"continue",
    delete: struct { name: []const u8, subs: []*Expr },
    getline_stmt: *Expr,
};

const Redir = struct { kind: enum { truncate, append }, target: *Expr };

const Pattern = union(enum) {
    begin,
    end,
    always,
    expr: *Expr,
    range: struct { lo: *Expr, hi: *Expr },
};

const Rule = struct { pat: Pattern, action: ?[]*Stmt };
const Func = struct { name: []const u8, params: [][]const u8, body: []*Stmt };
const Program = struct { rules: []Rule, funcs: []Func };

// ============================================================ parser

const Parser = struct {
    toks: []Tok,
    pos: usize = 0,
    gpa: Allocator,

    fn peek(self: *Parser) Tok {
        return self.toks[self.pos];
    }
    fn next(self: *Parser) Tok {
        const t = self.toks[self.pos];
        if (self.pos + 1 < self.toks.len) self.pos += 1;
        return t;
    }
    fn isOp(self: *Parser, o: []const u8) bool {
        return switch (self.peek()) {
            .op => |x| std.mem.eql(u8, x, o),
            else => false,
        };
    }
    fn isKw(self: *Parser, k: Kw) bool {
        return switch (self.peek()) {
            .keyword => |x| x == k,
            else => false,
        };
    }
    fn eatOp(self: *Parser, o: []const u8) bool {
        if (self.isOp(o)) {
            _ = self.next();
            return true;
        }
        return false;
    }
    fn expectOp(self: *Parser, o: []const u8) !void {
        if (!self.eatOp(o)) return error.Parse;
    }
    fn skipNewlines(self: *Parser) void {
        while (true) switch (self.peek()) {
            .newline => _ = self.next(),
            .op => |o| if (std.mem.eql(u8, o, ";")) {
                _ = self.next();
            } else return,
            else => return,
        };
    }
    fn skipOptTerm(self: *Parser) void {
        // statement terminators: ; or newline (optional)
        while (true) switch (self.peek()) {
            .newline => _ = self.next(),
            .op => |o| if (std.mem.eql(u8, o, ";")) {
                _ = self.next();
            } else return,
            else => return,
        };
    }

    fn new(self: *Parser, e: Expr) !*Expr {
        const p = try self.gpa.create(Expr);
        p.* = e;
        return p;
    }
    fn newStmt(self: *Parser, s: Stmt) !*Stmt {
        const p = try self.gpa.create(Stmt);
        p.* = s;
        return p;
    }

    fn parseProgram(self: *Parser) !Program {
        var rules: std.ArrayListUnmanaged(Rule) = .empty;
        var funcs: std.ArrayListUnmanaged(Func) = .empty;
        self.skipNewlines();
        while (self.peek() != .eof) {
            if (self.isKw(.function)) {
                try funcs.append(self.gpa, try self.parseFunc());
            } else {
                try rules.append(self.gpa, try self.parseRule());
            }
            self.skipNewlines();
        }
        return .{ .rules = rules.items, .funcs = funcs.items };
    }

    fn parseFunc(self: *Parser) !Func {
        _ = self.next(); // function
        const name = switch (self.next()) {
            .ident, .func_name => |n| n,
            else => return error.Parse,
        };
        try self.expectOp("(");
        var params: std.ArrayListUnmanaged([]const u8) = .empty;
        while (!self.isOp(")")) {
            switch (self.next()) {
                .ident => |n| try params.append(self.gpa, n),
                else => return error.Parse,
            }
            if (!self.eatOp(",")) break;
        }
        try self.expectOp(")");
        self.skipNewlines();
        const body = try self.parseBlock();
        return .{ .name = name, .params = params.items, .body = body };
    }

    fn parseRule(self: *Parser) !Rule {
        var pat: Pattern = .always;
        if (self.isKw(.BEGIN)) {
            _ = self.next();
            pat = .begin;
        } else if (self.isKw(.END)) {
            _ = self.next();
            pat = .end;
        } else if (!self.isOp("{")) {
            const e = try self.parseExpr();
            if (self.eatOp(",")) {
                self.skipNewlines();
                const hi = try self.parseExpr();
                pat = .{ .range = .{ .lo = e, .hi = hi } };
            } else {
                pat = .{ .expr = e };
            }
        }
        var action: ?[]*Stmt = null;
        if (self.isOp("{")) {
            action = try self.parseBlock();
        }
        return .{ .pat = pat, .action = action };
    }

    fn parseBlock(self: *Parser) ![]*Stmt {
        try self.expectOp("{");
        var stmts: std.ArrayListUnmanaged(*Stmt) = .empty;
        self.skipOptTerm();
        while (!self.isOp("}")) {
            const s = try self.parseStmt();
            try stmts.append(self.gpa, s);
            self.skipOptTerm();
            if (self.peek() == .eof) return error.Parse;
        }
        try self.expectOp("}");
        return stmts.items;
    }

    fn parseStmt(self: *Parser) anyerror!*Stmt {
        switch (self.peek()) {
            .op => |o| if (std.mem.eql(u8, o, "{")) {
                return self.newStmt(.{ .block = try self.parseBlock() });
            },
            .keyword => |k| switch (k) {
                .print => return self.parsePrint(false),
                .printf => return self.parsePrint(true),
                .@"if" => return self.parseIf(),
                .@"while" => return self.parseWhile(),
                .do => return self.parseDo(),
                .@"for" => return self.parseFor(),
                .next => {
                    _ = self.next();
                    return self.newStmt(.next);
                },
                .@"break" => {
                    _ = self.next();
                    return self.newStmt(.@"break");
                },
                .@"continue" => {
                    _ = self.next();
                    return self.newStmt(.@"continue");
                },
                .exit => {
                    _ = self.next();
                    const e = if (self.atStmtEnd()) null else try self.parseExpr();
                    return self.newStmt(.{ .exit = e });
                },
                .@"return" => {
                    _ = self.next();
                    const e = if (self.atStmtEnd()) null else try self.parseExpr();
                    return self.newStmt(.{ .@"return" = e });
                },
                .delete => {
                    _ = self.next();
                    const name = switch (self.next()) {
                        .ident => |n| n,
                        else => return error.Parse,
                    };
                    var subs: std.ArrayListUnmanaged(*Expr) = .empty;
                    if (self.eatOp("[")) {
                        while (true) {
                            try subs.append(self.gpa, try self.parseExpr());
                            if (!self.eatOp(",")) break;
                        }
                        try self.expectOp("]");
                    }
                    return self.newStmt(.{ .delete = .{ .name = name, .subs = subs.items } });
                },
                else => {},
            },
            else => {},
        }
        // expression statement
        const e = try self.parseExpr();
        return self.newStmt(.{ .expr = e });
    }

    fn atStmtEnd(self: *Parser) bool {
        return switch (self.peek()) {
            .newline, .eof => true,
            .op => |o| std.mem.eql(u8, o, ";") or std.mem.eql(u8, o, "}"),
            else => false,
        };
    }

    fn parsePrint(self: *Parser, is_printf: bool) !*Stmt {
        _ = self.next();
        var args: std.ArrayListUnmanaged(*Expr) = .empty;
        if (!self.atStmtEnd() and !self.isOp(">") and !self.isOp(">>")) {
            while (true) {
                try args.append(self.gpa, try self.parseTernaryNoIn(true));
                if (!self.eatOp(",")) break;
                self.skipNewlines();
            }
        }
        var redir: ?Redir = null;
        if (self.eatOp(">")) {
            redir = .{ .kind = .truncate, .target = try self.parseExpr() };
        } else if (self.eatOp(">>")) {
            redir = .{ .kind = .append, .target = try self.parseExpr() };
        }
        if (is_printf) return self.newStmt(.{ .printf = .{ .args = args.items, .redir = redir } });
        return self.newStmt(.{ .print = .{ .args = args.items, .redir = redir } });
    }

    fn parseIf(self: *Parser) !*Stmt {
        _ = self.next();
        try self.expectOp("(");
        const c = try self.parseExpr();
        try self.expectOp(")");
        self.skipNewlines();
        const then = try self.parseStmt();
        var els: ?*Stmt = null;
        const save = self.pos;
        self.skipOptTerm();
        if (self.isKw(.@"else")) {
            _ = self.next();
            self.skipNewlines();
            els = try self.parseStmt();
        } else {
            self.pos = save;
        }
        return self.newStmt(.{ .@"if" = .{ .c = c, .then = then, .els = els } });
    }

    fn parseWhile(self: *Parser) !*Stmt {
        _ = self.next();
        try self.expectOp("(");
        const c = try self.parseExpr();
        try self.expectOp(")");
        self.skipNewlines();
        const body = try self.parseStmt();
        return self.newStmt(.{ .@"while" = .{ .c = c, .body = body } });
    }

    fn parseDo(self: *Parser) !*Stmt {
        _ = self.next();
        self.skipNewlines();
        const body = try self.parseStmt();
        self.skipOptTerm();
        if (!self.isKw(.@"while")) return error.Parse;
        _ = self.next();
        try self.expectOp("(");
        const c = try self.parseExpr();
        try self.expectOp(")");
        return self.newStmt(.{ .do = .{ .body = body, .c = c } });
    }

    fn parseFor(self: *Parser) !*Stmt {
        _ = self.next();
        try self.expectOp("(");
        // for (v in arr)
        if (self.peek() == .ident) {
            const save = self.pos;
            const v = self.next().ident;
            if (self.isKw(.in)) {
                _ = self.next();
                const arr = switch (self.next()) {
                    .ident => |n| n,
                    else => return error.Parse,
                };
                try self.expectOp(")");
                self.skipNewlines();
                const body = try self.parseStmt();
                return self.newStmt(.{ .for_in = .{ .v = v, .arr = arr, .body = body } });
            }
            self.pos = save;
        }
        var init_s: ?*Stmt = null;
        if (!self.isOp(";")) init_s = try self.parseStmt();
        try self.expectOp(";");
        var cond: ?*Expr = null;
        if (!self.isOp(";")) cond = try self.parseExpr();
        try self.expectOp(";");
        var post: ?*Stmt = null;
        if (!self.isOp(")")) post = try self.parseStmt();
        try self.expectOp(")");
        self.skipNewlines();
        const body = try self.parseStmt();
        return self.newStmt(.{ .@"for" = .{ .init = init_s, .c = cond, .post = post, .body = body } });
    }

    // ---- expressions (precedence climbing) ----

    fn parseExpr(self: *Parser) anyerror!*Expr {
        return self.parseTernary(false);
    }
    fn parseTernaryNoIn(self: *Parser, no_gt: bool) anyerror!*Expr {
        _ = no_gt;
        return self.parseTernary(true);
    }

    fn parseTernary(self: *Parser, in_print: bool) anyerror!*Expr {
        const c = try self.parseAssign(in_print);
        if (self.eatOp("?")) {
            const a = try self.parseTernary(in_print);
            try self.expectOp(":");
            const b = try self.parseTernary(in_print);
            return self.new(.{ .ternary = .{ .c = c, .a = a, .b = b } });
        }
        return c;
    }

    fn parseAssign(self: *Parser, in_print: bool) anyerror!*Expr {
        const l = try self.parseOr(in_print);
        const assign_ops = [_]struct { s: []const u8, op: u8 }{
            .{ .s = "=", .op = '=' },  .{ .s = "+=", .op = '+' }, .{ .s = "-=", .op = '-' },
            .{ .s = "*=", .op = '*' }, .{ .s = "/=", .op = '/' }, .{ .s = "%=", .op = '%' },
            .{ .s = "^=", .op = '^' },
        };
        for (assign_ops) |ao| {
            if (self.isOp(ao.s)) {
                _ = self.next();
                const r = try self.parseTernary(in_print);
                return self.new(.{ .assign = .{ .op = ao.op, .target = l, .val = r } });
            }
        }
        return l;
    }

    fn parseOr(self: *Parser, in_print: bool) anyerror!*Expr {
        var l = try self.parseAnd(in_print);
        while (self.isOp("||")) {
            _ = self.next();
            self.skipNewlines();
            const r = try self.parseAnd(in_print);
            l = try self.new(.{ .binary = .{ .op = "||", .l = l, .r = r } });
        }
        return l;
    }
    fn parseAnd(self: *Parser, in_print: bool) anyerror!*Expr {
        var l = try self.parseIn(in_print);
        while (self.isOp("&&")) {
            _ = self.next();
            self.skipNewlines();
            const r = try self.parseIn(in_print);
            l = try self.new(.{ .binary = .{ .op = "&&", .l = l, .r = r } });
        }
        return l;
    }
    fn parseIn(self: *Parser, in_print: bool) anyerror!*Expr {
        var l = try self.parseMatch(in_print);
        while (self.isKw(.in)) {
            _ = self.next();
            const arr = switch (self.next()) {
                .ident => |n| n,
                else => return error.Parse,
            };
            const keys = try self.gpa.alloc(*Expr, 1);
            keys[0] = l;
            l = try self.new(.{ .in = .{ .key = keys, .arr = arr } });
        }
        return l;
    }
    fn parseMatch(self: *Parser, in_print: bool) anyerror!*Expr {
        var l = try self.parseCompare(in_print);
        while (self.isOp("~") or self.isOp("!~")) {
            const neg = self.isOp("!~");
            _ = self.next();
            const r = try self.parseCompare(in_print);
            l = try self.new(.{ .match = .{ .neg = neg, .l = l, .r = r } });
        }
        return l;
    }
    fn parseCompare(self: *Parser, in_print: bool) anyerror!*Expr {
        const l = try self.parseConcat(in_print);
        const cmp = [_][]const u8{ "<", "<=", "==", "!=", ">=", ">" };
        for (cmp) |c| {
            if (std.mem.eql(u8, c, ">") and in_print) continue; // '>' is redirection in print
            if (self.isOp(c)) {
                _ = self.next();
                const r = try self.parseConcat(in_print);
                return self.new(.{ .binary = .{ .op = c, .l = l, .r = r } });
            }
        }
        return l;
    }
    fn parseConcat(self: *Parser, in_print: bool) anyerror!*Expr {
        var l = try self.parseAdd(in_print);
        while (self.startsConcatOperand(in_print)) {
            const r = try self.parseAdd(in_print);
            l = try self.new(.{ .concat = .{ .l = l, .r = r } });
        }
        return l;
    }
    fn startsConcatOperand(self: *Parser, in_print: bool) bool {
        _ = in_print;
        return switch (self.peek()) {
            .number, .string, .ere, .ident, .func_name, .builtin => true,
            .keyword => false,
            .op => |o| std.mem.eql(u8, o, "$") or std.mem.eql(u8, o, "!") or std.mem.eql(u8, o, "("),
            else => false,
        };
    }
    fn parseAdd(self: *Parser, in_print: bool) anyerror!*Expr {
        var l = try self.parseMul(in_print);
        while (self.isOp("+") or self.isOp("-")) {
            const op = self.next().op;
            const r = try self.parseMul(in_print);
            l = try self.new(.{ .binary = .{ .op = op, .l = l, .r = r } });
        }
        return l;
    }
    fn parseMul(self: *Parser, in_print: bool) anyerror!*Expr {
        var l = try self.parseUnary(in_print);
        while (self.isOp("*") or self.isOp("/") or self.isOp("%")) {
            const op = self.next().op;
            const r = try self.parseUnary(in_print);
            l = try self.new(.{ .binary = .{ .op = op, .l = l, .r = r } });
        }
        return l;
    }
    fn parseUnary(self: *Parser, in_print: bool) anyerror!*Expr {
        if (self.isOp("!")) {
            _ = self.next();
            return self.new(.{ .unary = .{ .op = '!', .e = try self.parseUnary(in_print) } });
        }
        if (self.isOp("-")) {
            _ = self.next();
            return self.new(.{ .unary = .{ .op = '-', .e = try self.parseUnary(in_print) } });
        }
        if (self.isOp("+")) {
            _ = self.next();
            return self.new(.{ .unary = .{ .op = '+', .e = try self.parseUnary(in_print) } });
        }
        return self.parsePow(in_print);
    }
    fn parsePow(self: *Parser, in_print: bool) anyerror!*Expr {
        const l = try self.parsePostfix(in_print);
        if (self.isOp("^")) {
            _ = self.next();
            const r = try self.parseUnary(in_print); // right-assoc
            return self.new(.{ .binary = .{ .op = "^", .l = l, .r = r } });
        }
        return l;
    }
    fn parsePostfix(self: *Parser, in_print: bool) anyerror!*Expr {
        var e = try self.parsePrimary(in_print);
        while (self.isOp("++") or self.isOp("--")) {
            const op = self.next().op[0];
            e = try self.new(.{ .incdec = .{ .op = op, .pre = false, .target = e } });
        }
        return e;
    }
    fn parsePrimary(self: *Parser, in_print: bool) anyerror!*Expr {
        const t = self.peek();
        switch (t) {
            .number => |n| {
                _ = self.next();
                return self.new(.{ .num = n });
            },
            .string => |s| {
                _ = self.next();
                return self.new(.{ .str = s });
            },
            .ere => |r| {
                _ = self.next();
                return self.new(.{ .ere = r });
            },
            .keyword => |k| {
                if (k == .getline) {
                    _ = self.next();
                    var target: ?*Expr = null;
                    if (self.peek() == .ident or self.isOp("$")) {
                        target = try self.parsePrimary(in_print);
                    }
                    return self.new(.{ .getline = .{ .target = target } });
                }
                return error.Parse;
            },
            .op => |o| {
                if (std.mem.eql(u8, o, "$")) {
                    _ = self.next();
                    const f = try self.parsePrimary(in_print);
                    return self.new(.{ .field = f });
                }
                if (std.mem.eql(u8, o, "(")) {
                    _ = self.next();
                    const e = try self.parseExpr();
                    // Could be (e,e) in arr -> handle multi-subscript membership
                    if (self.isOp(",")) {
                        var keys: std.ArrayListUnmanaged(*Expr) = .empty;
                        try keys.append(self.gpa, e);
                        while (self.eatOp(",")) try keys.append(self.gpa, try self.parseExpr());
                        try self.expectOp(")");
                        if (self.isKw(.in)) {
                            _ = self.next();
                            const arr = self.next().ident;
                            return self.new(.{ .in = .{ .key = keys.items, .arr = arr } });
                        }
                        return error.Parse;
                    }
                    try self.expectOp(")");
                    return self.new(.{ .grouping = e });
                }
                if (std.mem.eql(u8, o, "++") or std.mem.eql(u8, o, "--")) {
                    const op = self.next().op[0];
                    const tgt = try self.parseUnary(in_print);
                    return self.new(.{ .incdec = .{ .op = op, .pre = true, .target = tgt } });
                }
                return error.Parse;
            },
            .builtin => |name| {
                _ = self.next();
                var args: std.ArrayListUnmanaged(*Expr) = .empty;
                if (self.eatOp("(")) {
                    while (!self.isOp(")")) {
                        try args.append(self.gpa, try self.parseExpr());
                        if (!self.eatOp(",")) break;
                    }
                    try self.expectOp(")");
                }
                return self.new(.{ .builtin = .{ .name = name, .args = args.items } });
            },
            .func_name => |name| {
                _ = self.next();
                try self.expectOp("(");
                var args: std.ArrayListUnmanaged(*Expr) = .empty;
                while (!self.isOp(")")) {
                    try args.append(self.gpa, try self.parseExpr());
                    if (!self.eatOp(",")) break;
                }
                try self.expectOp(")");
                return self.new(.{ .call = .{ .name = name, .args = args.items } });
            },
            .ident => |name| {
                _ = self.next();
                if (self.eatOp("[")) {
                    var subs: std.ArrayListUnmanaged(*Expr) = .empty;
                    while (true) {
                        try subs.append(self.gpa, try self.parseExpr());
                        if (!self.eatOp(",")) break;
                    }
                    try self.expectOp("]");
                    return self.new(.{ .index = .{ .name = name, .subs = subs.items } });
                }
                return self.new(.{ .variable = name });
            },
            else => return error.Parse,
        }
    }
};

// The interpreter is large; it lives in interp_exec.zig via @import to keep files focused.
pub const exec = @import("interp_exec.zig");
pub const Interp = exec.Interp;

/// Parse `src` into a Program (arena-allocated in `gpa`).
pub fn parse(gpa: Allocator, src: []const u8) !Program {
    var lx = Lexer{ .src = src, .gpa = gpa };
    const toks = try lx.run();
    var ps = Parser{ .toks = toks, .gpa = gpa };
    return ps.parseProgram();
}

pub const AstProgram = Program;
pub const AstRule = Rule;
pub const AstFunc = Func;
pub const AstStmt = Stmt;
pub const AstExpr = Expr;
pub const AstPattern = Pattern;
pub const AstRedir = Redir;
