//! jq lexer: a flat token stream (no pre-grouped blocks -- the parser does recursive
//! descent directly over parens/brackets/braces). Modeled on jaq's lexer (reference/
//! jaq/jaq-core/src/load/lex.rs) but simplified: keywords (`if`, `and`, `reduce`, ...)
//! are NOT special tokens, just `.ident` text that the parser recognizes contextually
//! -- exactly like jaq. `$x` (`.variable`) and `@name` (`.format`) keep their sigil off
//! the token text. `.foo` (dot directly followed by an identifier, no space) lexes as
//! ONE `.field` token carrying `foo`, matching jq's own "no whitespace before a bare
//! field" rule.
//!
//! String literals with `\(...)` interpolation are lexed recursively: the lexer
//! tracks paren/bracket/brace nesting depth while scanning the interpolation body so
//! that `\("a" + (1+2))` finds the correct matching `)` even though it contains a
//! nested string and parens.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TokKind = enum {
    dot, // '.'
    dotdot, // '..'
    field, // '.name' (text = name)
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    lparen,
    rparen,
    comma,
    colon,
    semicolon,
    question,
    ident, // word/keyword
    variable, // $name (text = name)
    format, // @name (text = name)
    number, // raw text, e.g. "3.14e5"
    string, // see `parts`
    op, // raw operator run, e.g. "+", "==", "|=" (unrecognized ops are a parser error)
};

pub const StrPart = union(enum) {
    literal: []const u8,
    interp: []const Token,
};

pub const Token = struct {
    kind: TokKind,
    text: []const u8 = "",
    parts: []const StrPart = &.{},
};

pub const LexError = error{JqLex};

pub const Lexer = struct {
    gpa: Allocator,
    src: []const u8,
    pos: usize = 0,
    errmsg: []const u8 = "lex error",

    pub fn init(gpa: Allocator, src: []const u8) Lexer {
        return .{ .gpa = gpa, .src = src };
    }

    fn fail(self: *Lexer, comptime msg: []const u8) LexError {
        self.errmsg = msg;
        return error.JqLex;
    }

    fn failFmt(self: *Lexer, comptime fmt: []const u8, args: anytype) LexError {
        self.errmsg = std.fmt.allocPrint(self.gpa, fmt, args) catch msgFallback;
        return error.JqLex;
    }

    fn at(self: *Lexer, off: usize) ?u8 {
        const p = self.pos + off;
        if (p >= self.src.len) return null;
        return self.src[p];
    }

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C or c == 0x0B;
    }
    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }
    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }
    fn isIdentCont(c: u8) bool {
        return isIdentStart(c) or isDigit(c);
    }
    fn isOpChar(c: u8) bool {
        return switch (c) {
            '|', '=', '!', '<', '>', '+', '-', '*', '/', '%' => true,
            else => false,
        };
    }
    fn isOpCont(c: u8) bool {
        return isOpChar(c) and c != '-';
    }

    fn skipSpaceAndComments(self: *Lexer) void {
        while (true) {
            while (self.pos < self.src.len and isSpace(self.src[self.pos])) self.pos += 1;
            if (self.pos < self.src.len and self.src[self.pos] == '#') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                continue;
            }
            break;
        }
    }

    fn lexIdentRun(self: *Lexer) []const u8 {
        const start = self.pos;
        while (self.pos < self.src.len and isIdentCont(self.src[self.pos])) self.pos += 1;
        return self.src[start..self.pos];
    }

    fn lexNumber(self: *Lexer) []const u8 {
        const start = self.pos;
        while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.pos += 1;
        if (self.at(0) == '.' and self.at(1) != null and isDigit(self.at(1).?)) {
            self.pos += 1;
            while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.pos += 1;
        }
        if (self.at(0) == 'e' or self.at(0) == 'E') {
            var p = self.pos + 1;
            if (p < self.src.len and (self.src[p] == '+' or self.src[p] == '-')) p += 1;
            if (p < self.src.len and isDigit(self.src[p])) {
                self.pos = p;
                while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.pos += 1;
            }
        }
        return self.src[start..self.pos];
    }

    fn hexDigit(c: u8) ?u21 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => null,
        };
    }

    fn readHex4Raw(self: *Lexer) LexError!u21 {
        if (self.pos + 4 > self.src.len) return self.fail("bad \\u escape: need 4 hex digits");
        var v: u21 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const d = hexDigit(self.src[self.pos + i]) orelse return self.fail("bad \\u escape: not hex");
            v = (v << 4) | d;
        }
        self.pos += 4;
        return v;
    }

    fn lexHex4(self: *Lexer) LexError!u21 {
        const h1 = try self.readHex4Raw();
        if (h1 >= 0xD800 and h1 <= 0xDBFF) {
            if (self.at(0) == '\\' and self.at(1) == 'u') {
                const save = self.pos;
                self.pos += 2;
                const h2 = self.readHex4Raw() catch {
                    self.pos = save;
                    return 0xFFFD;
                };
                if (h2 >= 0xDC00 and h2 <= 0xDFFF) {
                    return 0x10000 + (@as(u21, h1 - 0xD800) << 10) + (h2 - 0xDC00);
                }
                self.pos = save;
                return 0xFFFD;
            }
            return 0xFFFD;
        }
        return h1;
    }

    /// Consumes the opening `"` through the closing `"`, decoding escapes.
    fn lexString(self: *Lexer) LexError!Token {
        self.pos += 1; // opening quote
        var parts: std.ArrayListUnmanaged(StrPart) = .empty;
        var buf: std.ArrayListUnmanaged(u8) = .empty;

        while (true) {
            if (self.pos >= self.src.len) return self.fail("unterminated string literal");
            const c = self.src[self.pos];
            if (c == '"') {
                self.pos += 1;
                break;
            }
            if (c != '\\') {
                buf.append(self.gpa, c) catch @panic("OOM");
                self.pos += 1;
                continue;
            }
            self.pos += 1;
            if (self.pos >= self.src.len) return self.fail("unterminated escape in string");
            const e = self.src[self.pos];
            switch (e) {
                '"', '\\', '/' => {
                    buf.append(self.gpa, e) catch @panic("OOM");
                    self.pos += 1;
                },
                'b' => {
                    buf.append(self.gpa, 0x08) catch @panic("OOM");
                    self.pos += 1;
                },
                'f' => {
                    buf.append(self.gpa, 0x0C) catch @panic("OOM");
                    self.pos += 1;
                },
                'n' => {
                    buf.append(self.gpa, '\n') catch @panic("OOM");
                    self.pos += 1;
                },
                'r' => {
                    buf.append(self.gpa, '\r') catch @panic("OOM");
                    self.pos += 1;
                },
                't' => {
                    buf.append(self.gpa, '\t') catch @panic("OOM");
                    self.pos += 1;
                },
                'u' => {
                    self.pos += 1;
                    const cp = try self.lexHex4();
                    var enc: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &enc) catch 0;
                    if (n > 0) buf.appendSlice(self.gpa, enc[0..n]) catch @panic("OOM");
                },
                '(' => {
                    self.pos += 1;
                    if (buf.items.len > 0) {
                        parts.append(self.gpa, .{ .literal = buf.toOwnedSlice(self.gpa) catch @panic("OOM") }) catch @panic("OOM");
                        buf = .empty;
                    }
                    const sub = try self.lexInterpBody();
                    parts.append(self.gpa, .{ .interp = sub }) catch @panic("OOM");
                },
                else => return self.failFmt("bad string escape '\\{c}'", .{e}),
            }
        }
        if (buf.items.len > 0) {
            parts.append(self.gpa, .{ .literal = buf.toOwnedSlice(self.gpa) catch @panic("OOM") }) catch @panic("OOM");
        }
        return Token{ .kind = .string, .parts = parts.toOwnedSlice(self.gpa) catch @panic("OOM") };
    }

    /// Consumes tokens up to (and including) the `)` that matches the `\(` which
    /// invoked this, tracking nested `([{`/`)]}` so an inner `f(1;2)` or nested string
    /// doesn't end the interpolation early.
    fn lexInterpBody(self: *Lexer) LexError![]const Token {
        var toks: std.ArrayListUnmanaged(Token) = .empty;
        var depth: usize = 0;
        while (true) {
            self.skipSpaceAndComments();
            if (self.pos >= self.src.len) return self.fail("unterminated \\( interpolation )");
            const c = self.src[self.pos];
            if (c == ')' and depth == 0) {
                self.pos += 1;
                break;
            }
            if (c == '(' or c == '[' or c == '{') depth += 1;
            if ((c == ')' or c == ']' or c == '}') and depth > 0) depth -= 1;
            const tok = (try self.dispatch()) orelse return self.fail("unterminated \\( interpolation )");
            toks.append(self.gpa, tok) catch @panic("OOM");
        }
        return toks.toOwnedSlice(self.gpa) catch @panic("OOM");
    }

    /// Core single-token dispatch, shared by the top-level scan and interpolation
    /// bodies. Caller must have already skipped whitespace/comments.
    fn dispatch(self: *Lexer) LexError!?Token {
        if (self.pos >= self.src.len) return null;
        const c = self.src[self.pos];
        switch (c) {
            '.' => {
                self.pos += 1;
                if (self.at(0) == '.') {
                    self.pos += 1;
                    return Token{ .kind = .dotdot };
                }
                if (self.at(0)) |n| {
                    if (isIdentStart(n)) return Token{ .kind = .field, .text = self.lexIdentRun() };
                }
                return Token{ .kind = .dot };
            },
            '$' => {
                self.pos += 1;
                if (self.at(0)) |n| {
                    if (!isIdentStart(n)) return self.fail("expected identifier after '$'");
                } else return self.fail("expected identifier after '$'");
                return Token{ .kind = .variable, .text = self.lexIdentRun() };
            },
            '@' => {
                self.pos += 1;
                if (self.at(0)) |n| {
                    if (!isIdentStart(n)) return self.fail("expected identifier after '@'");
                } else return self.fail("expected identifier after '@'");
                return Token{ .kind = .format, .text = self.lexIdentRun() };
            },
            '0'...'9' => return Token{ .kind = .number, .text = self.lexNumber() },
            '"' => return try self.lexString(),
            '(' => {
                self.pos += 1;
                return Token{ .kind = .lparen };
            },
            ')' => {
                self.pos += 1;
                return Token{ .kind = .rparen };
            },
            '[' => {
                self.pos += 1;
                return Token{ .kind = .lbracket };
            },
            ']' => {
                self.pos += 1;
                return Token{ .kind = .rbracket };
            },
            '{' => {
                self.pos += 1;
                return Token{ .kind = .lbrace };
            },
            '}' => {
                self.pos += 1;
                return Token{ .kind = .rbrace };
            },
            ',' => {
                self.pos += 1;
                return Token{ .kind = .comma };
            },
            ':' => {
                self.pos += 1;
                return Token{ .kind = .colon };
            },
            ';' => {
                self.pos += 1;
                return Token{ .kind = .semicolon };
            },
            '?' => {
                self.pos += 1;
                return Token{ .kind = .question };
            },
            else => {
                if (isIdentStart(c)) return Token{ .kind = .ident, .text = self.lexIdentRun() };
                if (isOpChar(c)) {
                    const start = self.pos;
                    self.pos += 1;
                    while (self.pos < self.src.len and isOpCont(self.src[self.pos])) self.pos += 1;
                    return Token{ .kind = .op, .text = self.src[start..self.pos] };
                }
                return self.failFmt("unexpected character '{c}'", .{c});
            },
        }
    }

    fn next(self: *Lexer) LexError!?Token {
        self.skipSpaceAndComments();
        return self.dispatch();
    }

    pub fn lexAll(self: *Lexer) LexError![]const Token {
        var toks: std.ArrayListUnmanaged(Token) = .empty;
        while (try self.next()) |t| {
            toks.append(self.gpa, t) catch @panic("OOM");
        }
        return toks.toOwnedSlice(self.gpa) catch @panic("OOM");
    }
};

const msgFallback = "lex error";

pub fn lex(gpa: Allocator, src: []const u8) LexError!struct { tokens: []const Token, errmsg: []const u8 } {
    var lexer = Lexer.init(gpa, src);
    const toks = lexer.lexAll() catch |e| return switch (e) {
        error.JqLex => blk: {
            break :blk e;
        },
    };
    return .{ .tokens = toks, .errmsg = "" };
}
