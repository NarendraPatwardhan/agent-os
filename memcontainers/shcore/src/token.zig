//! Tokenizer: raw shell input to grammar tokens.

const std = @import("std");
const word = @import("word.zig");

pub const LexError = error{
    Incomplete,
    Syntax,
    OutOfMemory,
};

pub const Token = union(enum) {
    word: word.Word,
    op: Operator,
    io_number: u32,
    heredoc: Heredoc,
    newline,
    eof,
};

pub const Heredoc = struct {
    strip: bool,
    body: []const u8,
    expand: bool,
};

pub const Operator = enum {
    pipe,
    or_if,
    and_if,
    semi,
    dsemi,
    amp,
    less,
    great,
    dgreat,
    less_and,
    great_and,
    less_great,
    clobber,
    lparen,
    rparen,
};

const PendingHeredoc = struct {
    token_index: usize,
    strip: bool,
    delim: []const u8,
};

pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) LexError![]Token {
    var out = std.ArrayList(Token).empty;
    var pending = std.ArrayList(PendingHeredoc).empty;
    var i: usize = 0;
    while (i < source.len) {
        const ch = source[i];
        if (ch == ' ' or ch == '\t') {
            i += 1;
            continue;
        }
        if (ch == '\\' and i + 1 < source.len and source[i + 1] == '\n') {
            i += 2;
            continue;
        }
        if (ch == '#' and atWordBoundary(out.items, source, i)) {
            while (i < source.len and source[i] != '\n') i += 1;
            continue;
        }
        if (ch == '\n') {
            try out.append(allocator, .newline);
            i += 1;
            if (pending.items.len != 0) {
                i = try collectHeredocBodies(allocator, source, i, &out, &pending);
            }
            continue;
        }

        switch (ch) {
            '|' => {
                if (nextIs(source, i, '|')) {
                    try out.append(allocator, .{ .op = .or_if });
                    i += 2;
                } else {
                    try out.append(allocator, .{ .op = .pipe });
                    i += 1;
                }
                continue;
            },
            '&' => {
                if (nextIs(source, i, '&')) {
                    try out.append(allocator, .{ .op = .and_if });
                    i += 2;
                } else {
                    try out.append(allocator, .{ .op = .amp });
                    i += 1;
                }
                continue;
            },
            ';' => {
                if (nextIs(source, i, ';')) {
                    try out.append(allocator, .{ .op = .dsemi });
                    i += 2;
                } else {
                    try out.append(allocator, .{ .op = .semi });
                    i += 1;
                }
                continue;
            },
            '(' => {
                try out.append(allocator, .{ .op = .lparen });
                i += 1;
                continue;
            },
            ')' => {
                try out.append(allocator, .{ .op = .rparen });
                i += 1;
                continue;
            },
            '<' => {
                if (nextIs(source, i, '<')) {
                    const strip = i + 2 < source.len and source[i + 2] == '-';
                    i += if (strip) 3 else 2;
                    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
                    const delim = try readHeredocDelim(allocator, source, i);
                    i = delim.next;
                    try pending.append(allocator, .{ .token_index = out.items.len, .strip = strip, .delim = delim.delim });
                    try out.append(allocator, .{ .heredoc = .{ .strip = strip, .body = "", .expand = delim.expand } });
                } else if (nextIs(source, i, '&')) {
                    try out.append(allocator, .{ .op = .less_and });
                    i += 2;
                } else if (nextIs(source, i, '>')) {
                    try out.append(allocator, .{ .op = .less_great });
                    i += 2;
                } else {
                    try out.append(allocator, .{ .op = .less });
                    i += 1;
                }
                continue;
            },
            '>' => {
                if (nextIs(source, i, '>')) {
                    try out.append(allocator, .{ .op = .dgreat });
                    i += 2;
                } else if (nextIs(source, i, '&')) {
                    try out.append(allocator, .{ .op = .great_and });
                    i += 2;
                } else if (nextIs(source, i, '|')) {
                    try out.append(allocator, .{ .op = .clobber });
                    i += 2;
                } else {
                    try out.append(allocator, .{ .op = .great });
                    i += 1;
                }
                continue;
            },
            else => {},
        }

        if (std.ascii.isDigit(ch)) {
            var j = i;
            while (j < source.len and std.ascii.isDigit(source[j])) j += 1;
            if (j < source.len and (source[j] == '<' or source[j] == '>')) {
                const n = std.fmt.parseInt(u32, source[i..j], 10) catch 0;
                try out.append(allocator, .{ .io_number = n });
                i = j;
                continue;
            }
        }

        const read = try readWord(allocator, source, i);
        try out.append(allocator, .{ .word = read.value });
        i = read.next;
    }

    if (pending.items.len != 0) {
        _ = collectHeredocBodies(allocator, source, i, &out, &pending) catch {};
        if (pending.items.len != 0) return error.Incomplete;
    }
    try out.append(allocator, .eof);
    return out.toOwnedSlice(allocator);
}

fn nextIs(source: []const u8, i: usize, ch: u8) bool {
    return i + 1 < source.len and source[i + 1] == ch;
}

fn atWordBoundary(out: []const Token, source: []const u8, i: usize) bool {
    if (i == 0) return true;
    const prev = source[i - 1];
    if (prev == ' ' or prev == '\t' or prev == '\n') return true;
    if (out.len == 0) return true;
    return switch (out[out.len - 1]) {
        .op, .newline => true,
        else => false,
    };
}

const HeredocDelim = struct {
    delim: []const u8,
    expand: bool,
    next: usize,
};

fn readHeredocDelim(allocator: std.mem.Allocator, source: []const u8, start: usize) LexError!HeredocDelim {
    var i = start;
    var delim = std.ArrayList(u8).empty;
    var expand = true;
    while (i < source.len) {
        const ch = source[i];
        if (ch == ' ' or ch == '\t' or ch == '\n' or isOperatorByte(ch)) break;
        switch (ch) {
            '\'' => {
                expand = false;
                i += 1;
                while (i < source.len and source[i] != '\'') : (i += 1) try delim.append(allocator, source[i]);
                if (i >= source.len) return error.Incomplete;
                i += 1;
            },
            '"' => {
                expand = false;
                i += 1;
                while (i < source.len and source[i] != '"') : (i += 1) try delim.append(allocator, source[i]);
                if (i >= source.len) return error.Incomplete;
                i += 1;
            },
            '\\' => {
                expand = false;
                i += 1;
                if (i < source.len) {
                    try delim.append(allocator, source[i]);
                    i += 1;
                }
            },
            else => {
                try delim.append(allocator, ch);
                i += 1;
            },
        }
    }
    if (delim.items.len == 0) return error.Syntax;
    return .{ .delim = try delim.toOwnedSlice(allocator), .expand = expand, .next = i };
}

fn collectHeredocBodies(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: usize,
    out: *std.ArrayList(Token),
    pending: *std.ArrayList(PendingHeredoc),
) LexError!usize {
    var i = start;
    while (pending.items.len != 0) {
        const item = pending.orderedRemove(0);
        var body = std.ArrayList(u8).empty;
        while (true) {
            if (i >= source.len) {
                try pending.append(allocator, item);
                return i;
            }
            const line_start = i;
            while (i < source.len and source[i] != '\n') i += 1;
            const raw = source[line_start..i];
            if (i < source.len) i += 1;
            const compare = if (item.strip) trimLeadingTabs(raw) else raw;
            if (std.mem.eql(u8, compare, item.delim)) break;
            const content = if (item.strip) trimLeadingTabs(raw) else raw;
            try body.appendSlice(allocator, content);
            try body.append(allocator, '\n');
        }
        if (item.token_index < out.items.len and out.items[item.token_index] == .heredoc) {
            out.items[item.token_index].heredoc.body = try body.toOwnedSlice(allocator);
        }
    }
    return i;
}

fn trimLeadingTabs(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and s[i] == '\t') i += 1;
    return s[i..];
}

fn isOperatorByte(ch: u8) bool {
    return ch == '|' or ch == '&' or ch == ';' or ch == '<' or ch == '>' or ch == '(' or ch == ')';
}

fn isWordStop(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or isOperatorByte(ch);
}

const ReadWord = struct {
    value: word.Word,
    next: usize,
};

fn readWord(allocator: std.mem.Allocator, source: []const u8, start: usize) LexError!ReadWord {
    var parts = std.ArrayList(word.WordPart).empty;
    var lit = std.ArrayList(u8).empty;
    var i = start;
    while (i < source.len) {
        const ch = source[i];
        if (isWordStop(ch)) break;
        switch (ch) {
            '\'' => {
                try flushLit(allocator, &parts, &lit, false);
                const sq = try readSQuote(allocator, source, i + 1);
                try parts.append(allocator, .{ .lit = .{ .text = sq.text, .from_quote = true } });
                i = sq.next;
            },
            '"' => {
                try flushLit(allocator, &parts, &lit, false);
                const dq = try readDQuote(allocator, source, i + 1);
                try parts.appendSlice(allocator, dq.parts);
                i = dq.next;
            },
            '\\' => {
                i += 1;
                if (i < source.len) {
                    try lit.append(allocator, source[i]);
                    i += 1;
                } else {
                    try lit.append(allocator, '\\');
                }
            },
            '$' => {
                const rd = try readDollar(allocator, source, i + 1, false);
                if (rd.part) |part| {
                    try flushLit(allocator, &parts, &lit, false);
                    try parts.append(allocator, part);
                } else {
                    try lit.append(allocator, '$');
                }
                i = rd.next;
            },
            '`' => {
                try flushLit(allocator, &parts, &lit, false);
                const bt = try readBacktick(allocator, source, i + 1);
                try parts.append(allocator, .{ .sub = .{ .raw = bt.text, .quoted = false } });
                i = bt.next;
            },
            else => {
                try lit.append(allocator, ch);
                i += 1;
            },
        }
    }
    try flushLit(allocator, &parts, &lit, false);
    return .{ .value = try parts.toOwnedSlice(allocator), .next = i };
}

fn flushLit(allocator: std.mem.Allocator, parts: *std.ArrayList(word.WordPart), lit: *std.ArrayList(u8), from_quote: bool) !void {
    if (lit.items.len == 0) return;
    try parts.append(allocator, .{ .lit = .{ .text = try lit.toOwnedSlice(allocator), .from_quote = from_quote } });
    lit.* = .empty;
}

const ReadText = struct { text: []const u8, next: usize };
const ReadParts = struct { parts: []const word.WordPart, next: usize };

fn readSQuote(allocator: std.mem.Allocator, source: []const u8, start: usize) LexError!ReadText {
    var out = std.ArrayList(u8).empty;
    var i = start;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\'') return .{ .text = try out.toOwnedSlice(allocator), .next = i + 1 };
        try out.append(allocator, source[i]);
    }
    return error.Incomplete;
}

fn readDQuote(allocator: std.mem.Allocator, source: []const u8, start: usize) LexError!ReadParts {
    var parts = std.ArrayList(word.WordPart).empty;
    var lit = std.ArrayList(u8).empty;
    var i = start;
    while (i < source.len) {
        const ch = source[i];
        switch (ch) {
            '"' => {
                try flushLit(allocator, &parts, &lit, true);
                return .{ .parts = try parts.toOwnedSlice(allocator), .next = i + 1 };
            },
            '\\' => {
                i += 1;
                if (i < source.len) {
                    const n = source[i];
                    if (n == '"' or n == '\\' or n == '$' or n == '`' or n == '\n') {
                        if (n != '\n') try lit.append(allocator, n);
                    } else {
                        try lit.append(allocator, '\\');
                        try lit.append(allocator, n);
                    }
                    i += 1;
                } else {
                    try lit.append(allocator, '\\');
                }
            },
            '$' => {
                const rd = try readDollar(allocator, source, i + 1, true);
                if (rd.part) |part| {
                    try flushLit(allocator, &parts, &lit, true);
                    try parts.append(allocator, part);
                } else {
                    try lit.append(allocator, '$');
                }
                i = rd.next;
            },
            '`' => {
                try flushLit(allocator, &parts, &lit, true);
                const bt = try readBacktick(allocator, source, i + 1);
                try parts.append(allocator, .{ .sub = .{ .raw = bt.text, .quoted = true } });
                i = bt.next;
            },
            else => {
                try lit.append(allocator, ch);
                i += 1;
            },
        }
    }
    return error.Incomplete;
}

fn readBacktick(allocator: std.mem.Allocator, source: []const u8, start: usize) LexError!ReadText {
    var out = std.ArrayList(u8).empty;
    var i = start;
    while (i < source.len) {
        const ch = source[i];
        if (ch == '`') return .{ .text = try out.toOwnedSlice(allocator), .next = i + 1 };
        if (ch == '\\') {
            i += 1;
            if (i < source.len) {
                const n = source[i];
                if (n == '`' or n == '\\' or n == '$') {
                    try out.append(allocator, n);
                } else {
                    try out.append(allocator, '\\');
                    try out.append(allocator, n);
                }
                i += 1;
            } else {
                try out.append(allocator, '\\');
            }
        } else {
            try out.append(allocator, ch);
            i += 1;
        }
    }
    return error.Incomplete;
}

const DollarRead = struct {
    part: ?word.WordPart,
    next: usize,
};

fn readDollar(allocator: std.mem.Allocator, source: []const u8, start: usize, quoted: bool) LexError!DollarRead {
    if (start >= source.len) return .{ .part = null, .next = start };
    const ch = source[start];
    switch (ch) {
        '(' => {
            if (start + 1 < source.len and source[start + 1] == '(') {
                const inner = scanToMatching(allocator, source, start + 1, '(', ')') orelse return error.Incomplete;
                const raw = if (inner.text.len >= 2 and inner.text[0] == '(' and inner.text[inner.text.len - 1] == ')')
                    inner.text[1 .. inner.text.len - 1]
                else
                    inner.text;
                return .{ .part = .{ .arith = .{ .raw = raw, .quoted = quoted } }, .next = inner.next };
            }
            const inner = scanToMatching(allocator, source, start + 1, '(', ')') orelse return error.Incomplete;
            return .{ .part = .{ .sub = .{ .raw = inner.text, .quoted = quoted } }, .next = inner.next };
        },
        '{' => {
            const inner = scanToMatching(allocator, source, start + 1, '{', '}') orelse return error.Incomplete;
            return .{ .part = try parseParam(allocator, inner.text, quoted), .next = inner.next };
        },
        '?', '$', '!', '#', '@', '*', '-' => return .{ .part = varPart(try allocator.dupe(u8, source[start .. start + 1]), .get, quoted), .next = start + 1 },
        else => {},
    }
    if (ch == '_' or std.ascii.isAlphabetic(ch)) {
        const rn = readName(source, start);
        return .{ .part = varPart(try allocator.dupe(u8, rn.name), .get, quoted), .next = rn.next };
    }
    if (std.ascii.isDigit(ch)) {
        return .{ .part = varPart(try allocator.dupe(u8, source[start .. start + 1]), .get, quoted), .next = start + 1 };
    }
    return .{ .part = null, .next = start };
}

fn varPart(name: []const u8, op: word.ParamOp, quoted: bool) word.WordPart {
    return .{ .param = .{ .name = name, .op = op, .quoted = quoted } };
}

const NameRead = struct { name: []const u8, next: usize };

fn readName(source: []const u8, start: usize) NameRead {
    var i = start;
    while (i < source.len and (source[i] == '_' or std.ascii.isAlphanumeric(source[i]))) i += 1;
    return .{ .name = source[start..i], .next = i };
}

fn parseParam(allocator: std.mem.Allocator, inner: []const u8, quoted: bool) LexError!word.WordPart {
    if (inner.len == 0) return varPart("", .get, quoted);
    if (inner[0] == '#' and inner.len > 1) {
        const name = readName(inner, 1);
        if (name.name.len != 0 and name.next == inner.len) {
            return varPart(try allocator.dupe(u8, name.name), .length, quoted);
        }
    }
    if (inner.len == 1 and isSpecialParam(inner[0])) {
        return varPart(try allocator.dupe(u8, inner), .get, quoted);
    }
    const nr = if (std.ascii.isDigit(inner[0])) digitName(inner) else readName(inner, 0);
    const rest = inner[nr.next..];
    return varPart(try allocator.dupe(u8, nr.name), try parseOp(allocator, rest, quoted), quoted);
}

fn digitName(source: []const u8) NameRead {
    var i: usize = 0;
    while (i < source.len and std.ascii.isDigit(source[i])) i += 1;
    return .{ .name = source[0..i], .next = i };
}

fn isSpecialParam(ch: u8) bool {
    return ch == '?' or ch == '$' or ch == '!' or ch == '#' or ch == '@' or ch == '*' or ch == '-';
}

fn parseOp(allocator: std.mem.Allocator, rest: []const u8, quoted: bool) LexError!word.ParamOp {
    if (rest.len == 0) return .get;
    if (std.mem.startsWith(u8, rest, ":-")) return .{ .default_value = .{ .colon = true, .word = try lexParamWord(allocator, rest[2..], quoted) } };
    if (std.mem.startsWith(u8, rest, ":=")) return .{ .assign = .{ .colon = true, .word = try lexParamWord(allocator, rest[2..], quoted) } };
    if (std.mem.startsWith(u8, rest, ":+")) return .{ .alt = .{ .colon = true, .word = try lexParamWord(allocator, rest[2..], quoted) } };
    if (std.mem.startsWith(u8, rest, ":?")) return .{ .err = .{ .colon = true, .word = try lexParamWord(allocator, rest[2..], quoted) } };
    return switch (rest[0]) {
        '-' => .{ .default_value = .{ .colon = false, .word = try lexParamWord(allocator, rest[1..], quoted) } },
        '=' => .{ .assign = .{ .colon = false, .word = try lexParamWord(allocator, rest[1..], quoted) } },
        '+' => .{ .alt = .{ .colon = false, .word = try lexParamWord(allocator, rest[1..], quoted) } },
        '?' => .{ .err = .{ .colon = false, .word = try lexParamWord(allocator, rest[1..], quoted) } },
        '#' => if (std.mem.startsWith(u8, rest, "##"))
            .{ .trim_prefix = .{ .longest = true, .pat = try lexParamWord(allocator, rest[2..], quoted) } }
        else
            .{ .trim_prefix = .{ .longest = false, .pat = try lexParamWord(allocator, rest[1..], quoted) } },
        '%' => if (std.mem.startsWith(u8, rest, "%%"))
            .{ .trim_suffix = .{ .longest = true, .pat = try lexParamWord(allocator, rest[2..], quoted) } }
        else
            .{ .trim_suffix = .{ .longest = false, .pat = try lexParamWord(allocator, rest[1..], quoted) } },
        else => .get,
    };
}

fn lexParamWord(allocator: std.mem.Allocator, source: []const u8, quoted: bool) LexError!word.Word {
    var parts = std.ArrayList(word.WordPart).empty;
    var lit = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < source.len) {
        const ch = source[i];
        switch (ch) {
            '\'' => {
                try flushLit(allocator, &parts, &lit, quoted);
                const sq = try readSQuote(allocator, source, i + 1);
                try parts.append(allocator, .{ .lit = .{ .text = sq.text, .from_quote = true } });
                i = sq.next;
            },
            '"' => {
                try flushLit(allocator, &parts, &lit, quoted);
                const dq = try readDQuote(allocator, source, i + 1);
                try parts.appendSlice(allocator, dq.parts);
                i = dq.next;
            },
            '\\' => {
                i += 1;
                if (i < source.len) {
                    try lit.append(allocator, source[i]);
                    i += 1;
                } else {
                    try lit.append(allocator, '\\');
                }
            },
            '$' => {
                const rd = try readDollar(allocator, source, i + 1, quoted);
                if (rd.part) |part| {
                    try flushLit(allocator, &parts, &lit, quoted);
                    try parts.append(allocator, part);
                } else {
                    try lit.append(allocator, '$');
                }
                i = rd.next;
            },
            '`' => {
                try flushLit(allocator, &parts, &lit, quoted);
                const bt = try readBacktick(allocator, source, i + 1);
                try parts.append(allocator, .{ .sub = .{ .raw = bt.text, .quoted = quoted } });
                i = bt.next;
            },
            else => {
                try lit.append(allocator, ch);
                i += 1;
            },
        }
    }
    try flushLit(allocator, &parts, &lit, quoted);
    return parts.toOwnedSlice(allocator);
}

const ScanResult = struct { text: []const u8, next: usize };

fn scanToMatching(allocator: std.mem.Allocator, source: []const u8, start: usize, open: u8, close: u8) ?ScanResult {
    var depth: usize = 1;
    var out = std.ArrayList(u8).empty;
    var i = start;
    while (i < source.len) {
        const ch = source[i];
        if (ch == '\\') {
            out.append(allocator, ch) catch return null;
            i += 1;
            if (i < source.len) {
                out.append(allocator, source[i]) catch return null;
                i += 1;
            }
            continue;
        }
        if (ch == '\'' or ch == '"' or ch == '`') {
            const quote = ch;
            out.append(allocator, ch) catch return null;
            i += 1;
            while (i < source.len and source[i] != quote) {
                if (source[i] == '\\') {
                    out.append(allocator, source[i]) catch return null;
                    i += 1;
                    if (i < source.len) {
                        out.append(allocator, source[i]) catch return null;
                        i += 1;
                    }
                } else {
                    out.append(allocator, source[i]) catch return null;
                    i += 1;
                }
            }
            if (i < source.len) {
                out.append(allocator, quote) catch return null;
                i += 1;
            }
            continue;
        }
        if (ch == '$' and i + 1 < source.len and source[i + 1] == '(') {
            out.appendSlice(allocator, "$(") catch return null;
            i += 2;
            const inner = scanToMatching(allocator, source, i, '(', ')') orelse return null;
            out.appendSlice(allocator, inner.text) catch return null;
            out.append(allocator, ')') catch return null;
            i = inner.next;
            continue;
        }
        if (ch == open) {
            depth += 1;
            out.append(allocator, ch) catch return null;
            i += 1;
            continue;
        }
        if (ch == close) {
            depth -= 1;
            if (depth == 0) return .{ .text = out.toOwnedSlice(allocator) catch return null, .next = i + 1 };
            out.append(allocator, ch) catch return null;
            i += 1;
            continue;
        }
        out.append(allocator, ch) catch return null;
        i += 1;
    }
    return null;
}
