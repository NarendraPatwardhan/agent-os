//! Recursive-descent parser: token stream to AST.

const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");
const word = @import("word.zig");

pub const ParseError = token.LexError;

pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!ast.Script {
    const toks = try token.tokenize(allocator, source);
    var p = Parser{
        .allocator = allocator,
        .toks = toks,
    };
    const list = try p.parseList();
    p.skipNewlines();
    if (!p.atEof()) return error.Syntax;
    return .{ .list = list };
}

const Parser = struct {
    allocator: std.mem.Allocator,
    toks: []const token.Token,
    pos: usize = 0,

    fn peek(self: *const Parser) token.Token {
        if (self.pos < self.toks.len) return self.toks[self.pos];
        return .eof;
    }

    fn peekAt(self: *const Parser, n: usize) token.Token {
        const idx = self.pos + n;
        if (idx < self.toks.len) return self.toks[idx];
        return .eof;
    }

    fn bump(self: *Parser) token.Token {
        const t = self.peek();
        if (self.pos < self.toks.len) self.pos += 1;
        return t;
    }

    fn atEof(self: *const Parser) bool {
        return self.peek() == .eof;
    }

    fn syntax(self: *const Parser) ParseError {
        if (self.atEof()) return error.Incomplete;
        return error.Syntax;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.peek() == .newline) _ = self.bump();
    }

    fn peekKeyword(self: *const Parser) ?[]const u8 {
        return switch (self.peek()) {
            .word => |w| wordKeyword(w),
            else => null,
        };
    }

    fn atKeyword(self: *const Parser, kw: []const u8) bool {
        const got = self.peekKeyword() orelse return false;
        return std.mem.eql(u8, got, kw);
    }

    fn expectKeyword(self: *Parser, kw: []const u8) ParseError!void {
        if (self.atKeyword(kw)) {
            _ = self.bump();
            return;
        }
        return self.syntax();
    }

    fn atListEnd(self: *const Parser) bool {
        switch (self.peek()) {
            .eof => return true,
            .op => |op| if (op == .rparen or op == .dsemi) return true,
            else => {},
        }
        const kw = self.peekKeyword() orelse return false;
        return std.mem.eql(u8, kw, "then") or
            std.mem.eql(u8, kw, "elif") or
            std.mem.eql(u8, kw, "else") or
            std.mem.eql(u8, kw, "fi") or
            std.mem.eql(u8, kw, "do") or
            std.mem.eql(u8, kw, "done") or
            std.mem.eql(u8, kw, "esac") or
            std.mem.eql(u8, kw, "}");
    }

    fn parseList(self: *Parser) ParseError!ast.List {
        var items = std.ArrayList(ast.ListItem).empty;
        while (true) {
            self.skipNewlines();
            if (self.atListEnd()) break;

            const and_or = try self.parseAndOr();
            var sep: ast.ListSep = .seq;
            var had_sep = false;
            switch (self.peek()) {
                .op => |op| switch (op) {
                    .amp => {
                        _ = self.bump();
                        sep = .async;
                        had_sep = true;
                    },
                    .semi => {
                        _ = self.bump();
                        had_sep = true;
                    },
                    else => {},
                },
                .newline => {
                    _ = self.bump();
                    had_sep = true;
                },
                else => {},
            }
            try items.append(self.allocator, .{ .and_or = and_or, .sep = sep });
            if (!had_sep) break;
        }
        return .{ .items = try items.toOwnedSlice(self.allocator) };
    }

    fn parseAndOr(self: *Parser) ParseError!ast.AndOr {
        const first = try self.parsePipeline();
        var rest = std.ArrayList(ast.AndOrRest).empty;
        while (true) {
            const op: ast.AndOrOp = switch (self.peek()) {
                .op => |op| switch (op) {
                    .and_if => .and_if,
                    .or_if => .or_if,
                    else => break,
                },
                else => break,
            };
            _ = self.bump();
            self.skipNewlines();
            try rest.append(self.allocator, .{
                .op = op,
                .pipeline = try self.parsePipeline(),
            });
        }
        return .{ .first = first, .rest = try rest.toOwnedSlice(self.allocator) };
    }

    fn parsePipeline(self: *Parser) ParseError!ast.Pipeline {
        var bang = false;
        if (self.atKeyword("!")) {
            _ = self.bump();
            bang = true;
        }

        var cmds = std.ArrayList(ast.Command).empty;
        try cmds.append(self.allocator, try self.parseCommand());
        while (true) {
            switch (self.peek()) {
                .op => |op| if (op == .pipe) {
                    _ = self.bump();
                    self.skipNewlines();
                    try cmds.append(self.allocator, try self.parseCommand());
                    continue;
                },
                else => {},
            }
            break;
        }
        return .{ .bang = bang, .cmds = try cmds.toOwnedSlice(self.allocator) };
    }

    fn parseCommand(self: *Parser) ParseError!ast.Command {
        if (self.isFunctionDef()) return self.parseFunctionDef();

        if (self.peekKeyword()) |kw| {
            const compound: ?ast.Compound = if (std.mem.eql(u8, kw, "if"))
                try self.parseIf()
            else if (std.mem.eql(u8, kw, "for"))
                try self.parseFor()
            else if (std.mem.eql(u8, kw, "while"))
                try self.parseWhile(false)
            else if (std.mem.eql(u8, kw, "until"))
                try self.parseWhile(true)
            else if (std.mem.eql(u8, kw, "case"))
                try self.parseCase()
            else if (std.mem.eql(u8, kw, "{"))
                try self.parseBraceGroup()
            else
                null;

            if (compound) |kind| {
                return .{ .compound = .{
                    .kind = kind,
                    .redirs = try self.parseRedirectList(),
                } };
            }
        }

        switch (self.peek()) {
            .op => |op| if (op == .lparen) {
                return .{ .compound = .{
                    .kind = try self.parseSubshell(),
                    .redirs = try self.parseRedirectList(),
                } };
            },
            else => {},
        }

        return self.parseSimpleCommand();
    }

    fn isFunctionDef(self: *const Parser) bool {
        switch (self.peek()) {
            .word => |w| {
                if (wordName(w) != null) {
                    const one = self.peekAt(1);
                    const two = self.peekAt(2);
                    if (one == .op and one.op == .lparen and two == .op and two.op == .rparen) {
                        return true;
                    }
                }
            },
            else => {},
        }
        return self.atKeyword("function");
    }

    fn parseFunctionDef(self: *Parser) ParseError!ast.Command {
        const name = if (self.atKeyword("function")) blk: {
            _ = self.bump();
            const n = self.takeName() orelse return self.syntax();
            switch (self.peek()) {
                .op => |op| if (op == .lparen) {
                    _ = self.bump();
                    switch (self.bump()) {
                        .op => |close| if (close != .rparen) return self.syntax(),
                        else => return self.syntax(),
                    }
                },
                else => {},
            }
            break :blk n;
        } else blk: {
            const n = self.takeName() orelse return self.syntax();
            _ = self.bump();
            _ = self.bump();
            break :blk n;
        };

        self.skipNewlines();
        const parsed_body = try self.parseCommand();
        switch (parsed_body) {
            .compound => {},
            else => return self.syntax(),
        }
        const body = try self.allocator.create(ast.Command);
        body.* = parsed_body;
        return .{ .function_def = .{ .name = name, .body = body } };
    }

    fn parseSimpleCommand(self: *Parser) ParseError!ast.Command {
        var assigns = std.ArrayList(ast.Assign).empty;
        var words = std.ArrayList(word.Word).empty;
        var redirs = std.ArrayList(ast.Redirect).empty;

        while (true) {
            const is_assign = switch (self.peek()) {
                .word => |w| words.items.len == 0 and splitAssignment(w) != null,
                else => false,
            };
            if (!is_assign) break;
            switch (self.bump()) {
                .word => |w| {
                    const split = splitAssignment(w).?;
                    try assigns.append(self.allocator, .{
                        .name = split.name,
                        .value = try self.assignmentValue(split),
                    });
                },
                else => unreachable,
            }
        }

        while (true) {
            switch (self.peek()) {
                .word => |w| {
                    _ = self.bump();
                    try words.append(self.allocator, w);
                },
                .io_number, .heredoc => {
                    try redirs.append(self.allocator, try self.parseRedirect());
                },
                .op => |op| switch (op) {
                    .less, .great, .dgreat, .less_great, .clobber, .less_and, .great_and => {
                        try redirs.append(self.allocator, try self.parseRedirect());
                    },
                    else => break,
                },
                else => break,
            }
        }

        if (assigns.items.len == 0 and words.items.len == 0 and redirs.items.len == 0) {
            return self.syntax();
        }

        return .{ .simple = .{
            .assigns = try assigns.toOwnedSlice(self.allocator),
            .words = try words.toOwnedSlice(self.allocator),
            .redirs = try redirs.toOwnedSlice(self.allocator),
        } };
    }

    fn parseRedirectList(self: *Parser) ParseError![]const ast.Redirect {
        var redirs = std.ArrayList(ast.Redirect).empty;
        while (true) {
            switch (self.peek()) {
                .io_number, .heredoc => try redirs.append(self.allocator, try self.parseRedirect()),
                .op => |op| switch (op) {
                    .less, .great, .dgreat, .less_great, .clobber, .less_and, .great_and => {
                        try redirs.append(self.allocator, try self.parseRedirect());
                    },
                    else => break,
                },
                else => break,
            }
        }
        return redirs.toOwnedSlice(self.allocator);
    }

    fn parseRedirect(self: *Parser) ParseError!ast.Redirect {
        const io_number: ?u32 = switch (self.peek()) {
            .io_number => |n| blk: {
                _ = self.bump();
                break :blk n;
            },
            else => null,
        };

        return switch (self.bump()) {
            .op => |op| switch (op) {
                .less => .{ .io_number = io_number, .op = .read, .target = .{ .word_value = try self.expectWord() } },
                .great => .{ .io_number = io_number, .op = .write, .target = .{ .word_value = try self.expectWord() } },
                .dgreat => .{ .io_number = io_number, .op = .append, .target = .{ .word_value = try self.expectWord() } },
                .less_great => .{ .io_number = io_number, .op = .read_write, .target = .{ .word_value = try self.expectWord() } },
                .clobber => .{ .io_number = io_number, .op = .clobber, .target = .{ .word_value = try self.expectWord() } },
                .less_and => .{ .io_number = io_number, .op = .dup_in, .target = try self.dupTarget() },
                .great_and => .{ .io_number = io_number, .op = .dup_out, .target = try self.dupTarget() },
                else => self.syntax(),
            },
            .heredoc => |h| .{ .io_number = io_number, .op = .heredoc, .target = .{ .here = .{ .body = h.body, .expand = h.expand } } },
            else => self.syntax(),
        };
    }

    fn dupTarget(self: *Parser) ParseError!ast.RedirTarget {
        const w = try self.expectWord();
        if (w.len == 1) {
            switch (w[0]) {
                .lit => |lit| if (!lit.from_quote) {
                    if (std.mem.eql(u8, lit.text, "-")) return .{ .dup = .close };
                    const n = std.fmt.parseInt(u32, lit.text, 10) catch null;
                    if (n) |fd| return .{ .dup = .{ .number = fd } };
                },
                else => {},
            }
        }
        return error.Syntax;
    }

    fn expectWord(self: *Parser) ParseError!word.Word {
        return switch (self.bump()) {
            .word => |w| w,
            else => self.syntax(),
        };
    }

    fn takeName(self: *Parser) ?[]const u8 {
        switch (self.peek()) {
            .word => |w| if (wordName(w)) |n| {
                _ = self.bump();
                return n;
            },
            else => {},
        }
        return null;
    }

    fn parseIf(self: *Parser) ParseError!ast.Compound {
        try self.expectKeyword("if");
        var arms = std.ArrayList(ast.IfArm).empty;
        const cond = try self.parseList();
        try self.expectKeyword("then");
        try arms.append(self.allocator, .{ .condition = cond, .body = try self.parseList() });

        while (self.atKeyword("elif")) {
            _ = self.bump();
            const c = try self.parseList();
            try self.expectKeyword("then");
            try arms.append(self.allocator, .{ .condition = c, .body = try self.parseList() });
        }

        const else_body: ?ast.List = if (self.atKeyword("else")) blk: {
            _ = self.bump();
            break :blk try self.parseList();
        } else null;

        try self.expectKeyword("fi");
        return .{ .if_clause = .{ .arms = try arms.toOwnedSlice(self.allocator), .else_body = else_body } };
    }

    fn parseFor(self: *Parser) ParseError!ast.Compound {
        try self.expectKeyword("for");
        const var_name = self.takeName() orelse return self.syntax();
        self.skipNewlines();

        const words: ?[]const word.Word = if (self.atKeyword("in")) blk: {
            _ = self.bump();
            var ws = std.ArrayList(word.Word).empty;
            while (true) {
                switch (self.peek()) {
                    .word => |w| {
                        _ = self.bump();
                        try ws.append(self.allocator, w);
                    },
                    else => break,
                }
            }
            break :blk try ws.toOwnedSlice(self.allocator);
        } else null;

        self.consumeSeqSeparators();
        try self.expectKeyword("do");
        const body = try self.parseList();
        try self.expectKeyword("done");
        return .{ .for_clause = .{ .var_name = var_name, .words = words, .body = body } };
    }

    fn parseWhile(self: *Parser, until: bool) ParseError!ast.Compound {
        try self.expectKeyword(if (until) "until" else "while");
        const cond = try self.parseList();
        try self.expectKeyword("do");
        const body = try self.parseList();
        try self.expectKeyword("done");
        const clause = ast.WhileClause{ .cond = cond, .body = body };
        return if (until) .{ .until_clause = clause } else .{ .while_clause = clause };
    }

    fn parseCase(self: *Parser) ParseError!ast.Compound {
        try self.expectKeyword("case");
        const subject = try self.expectWord();
        self.skipNewlines();
        try self.expectKeyword("in");
        self.skipNewlines();

        var items = std.ArrayList(ast.CaseItem).empty;
        while (!self.atKeyword("esac")) {
            switch (self.peek()) {
                .op => |op| {
                    if (op == .lparen) _ = self.bump();
                },
                else => {},
            }

            var patterns = std.ArrayList(word.Word).empty;
            try patterns.append(self.allocator, try self.expectWord());
            while (true) {
                switch (self.peek()) {
                    .op => |op| if (op == .pipe) {
                        _ = self.bump();
                        try patterns.append(self.allocator, try self.expectWord());
                        continue;
                    },
                    else => {},
                }
                break;
            }

            switch (self.bump()) {
                .op => |op| if (op != .rparen) return self.syntax(),
                else => return self.syntax(),
            }

            self.skipNewlines();
            try items.append(self.allocator, .{
                .patterns = try patterns.toOwnedSlice(self.allocator),
                .body = try self.parseList(),
            });
            switch (self.peek()) {
                .op => |op| if (op == .dsemi) {
                    _ = self.bump();
                    self.skipNewlines();
                    continue;
                },
                else => {},
            }
            break;
        }
        try self.expectKeyword("esac");
        return .{ .case_clause = .{ .subject = subject, .items = try items.toOwnedSlice(self.allocator) } };
    }

    fn parseBraceGroup(self: *Parser) ParseError!ast.Compound {
        try self.expectKeyword("{");
        const list = try self.parseList();
        try self.expectKeyword("}");
        return .{ .brace_group = list };
    }

    fn parseSubshell(self: *Parser) ParseError!ast.Compound {
        switch (self.bump()) {
            .op => |op| if (op != .lparen) return self.syntax(),
            else => return self.syntax(),
        }
        const list = try self.parseList();
        switch (self.bump()) {
            .op => |op| if (op != .rparen) return self.syntax(),
            else => return self.syntax(),
        }
        return .{ .subshell = list };
    }

    fn consumeSeqSeparators(self: *Parser) void {
        while (true) {
            switch (self.peek()) {
                .op => |op| {
                    if (op == .semi) {
                        _ = self.bump();
                        continue;
                    }
                },
                .newline => {
                    _ = self.bump();
                    continue;
                },
                else => {},
            }
            break;
        }
    }

    fn assignmentValue(self: *Parser, split: AssignmentSplit) ParseError!word.Word {
        var value_len = split.tail.len;
        if (split.rest.len != 0) value_len += 1;
        if (value_len == 0) return &.{};

        const value = try self.allocator.alloc(word.WordPart, value_len);
        var out: usize = 0;
        if (split.rest.len != 0) {
            value[out] = .{ .lit = .{ .text = split.rest, .from_quote = false } };
            out += 1;
        }
        for (split.tail) |part| {
            value[out] = part;
            out += 1;
        }
        return value;
    }
};

fn wordKeyword(w: word.Word) ?[]const u8 {
    if (w.len != 1) return null;
    return switch (w[0]) {
        .lit => |lit| blk: {
            if (lit.from_quote) break :blk null;
            const text = lit.text;
            if (std.mem.eql(u8, text, "if")) break :blk "if";
            if (std.mem.eql(u8, text, "then")) break :blk "then";
            if (std.mem.eql(u8, text, "elif")) break :blk "elif";
            if (std.mem.eql(u8, text, "else")) break :blk "else";
            if (std.mem.eql(u8, text, "fi")) break :blk "fi";
            if (std.mem.eql(u8, text, "for")) break :blk "for";
            if (std.mem.eql(u8, text, "in")) break :blk "in";
            if (std.mem.eql(u8, text, "while")) break :blk "while";
            if (std.mem.eql(u8, text, "until")) break :blk "until";
            if (std.mem.eql(u8, text, "do")) break :blk "do";
            if (std.mem.eql(u8, text, "done")) break :blk "done";
            if (std.mem.eql(u8, text, "case")) break :blk "case";
            if (std.mem.eql(u8, text, "esac")) break :blk "esac";
            if (std.mem.eql(u8, text, "function")) break :blk "function";
            if (std.mem.eql(u8, text, "{")) break :blk "{";
            if (std.mem.eql(u8, text, "}")) break :blk "}";
            if (std.mem.eql(u8, text, "!")) break :blk "!";
            break :blk null;
        },
        else => null,
    };
}

fn wordName(w: word.Word) ?[]const u8 {
    if (w.len != 1) return null;
    return switch (w[0]) {
        .lit => |lit| if (!lit.from_quote and isName(lit.text)) lit.text else null,
        else => null,
    };
}

fn isName(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(s[0] == '_' or std.ascii.isAlphabetic(s[0]))) return false;
    for (s[1..]) |ch| {
        if (!(ch == '_' or std.ascii.isAlphanumeric(ch))) return false;
    }
    return true;
}

const AssignmentSplit = struct {
    name: []const u8,
    rest: []const u8,
    tail: []const word.WordPart,
};

fn splitAssignment(w: word.Word) ?AssignmentSplit {
    if (w.len == 0) return null;
    const first = switch (w[0]) {
        .lit => |lit| lit,
        else => return null,
    };
    if (first.from_quote) return null;
    const eq = std.mem.indexOfScalar(u8, first.text, '=') orelse return null;
    const name = first.text[0..eq];
    if (!isName(name)) return null;
    return .{
        .name = name,
        .rest = first.text[eq + 1 ..],
        .tail = w[1..],
    };
}
