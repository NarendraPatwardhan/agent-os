//! Cursor-aware shell completion semantics.
//!
//! This module deliberately does not touch the filesystem. It identifies the
//! shell word at the cursor, classifies what that word means, and renders
//! candidates supplied by the kernel. That split keeps quoting and shell state
//! in shcore while namespace/PATH traversal remains authoritative in the
//! kernel.

const std = @import("std");

pub const Context = enum {
    command,
    path,
    directory,
    variable,
};

pub const Quote = enum {
    bare,
    single,
    double,
};

pub const Candidate = struct {
    value: []const u8,
    kind: []const u8,
};

pub const Probe = struct {
    replace_start: usize,
    replace_end: usize,
    prefix: []u8,
    context: Context,
    quote: Quote,

    pub fn deinit(self: Probe, allocator: std.mem.Allocator) void {
        allocator.free(self.prefix);
    }
};

const Scan = struct {
    token_start: usize,
    token: std.ArrayList(u8),
    quote: Quote = .bare,
    token_quote: Quote = .bare,
    token_active: bool = false,
    command_position: bool = true,
    command_name: std.ArrayList(u8),
    redirection_target: bool = false,

    fn init() Scan {
        return .{
            .token_start = 0,
            .token = .empty,
            .command_name = .empty,
        };
    }

    fn deinit(self: *Scan, allocator: std.mem.Allocator) void {
        self.token.deinit(allocator);
        self.command_name.deinit(allocator);
    }

    fn start(self: *Scan, at: usize) void {
        if (self.token_active) return;
        self.token_active = true;
        self.token_start = at;
        self.token_quote = .bare;
        self.token.clearRetainingCapacity();
    }

    fn finish(self: *Scan, allocator: std.mem.Allocator) !void {
        if (!self.token_active) return;
        if (self.redirection_target) {
            // A redirect operand does not consume the command position: in
            // `>log echo ok`, `echo` is still the command word.
        } else if (self.command_position and !isAssignment(self.token.items)) {
            self.command_name.clearRetainingCapacity();
            try self.command_name.appendSlice(allocator, self.token.items);
            self.command_position = false;
        }
        self.redirection_target = false;
        self.token_active = false;
        self.token.clearRetainingCapacity();
        self.quote = .bare;
        self.token_quote = .bare;
    }
};

fn isAssignment(word: []const u8) bool {
    const equal = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    if (equal == 0 or !(std.ascii.isAlphabetic(word[0]) or word[0] == '_')) return false;
    for (word[1..equal]) |b| if (!(std.ascii.isAlphanumeric(b) or b == '_')) return false;
    return true;
}

fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r' or b == '\n';
}

fn isSeparator(b: u8) bool {
    return b == ';' or b == '|' or b == '&' or b == '(' or b == ')';
}

fn isRedirection(b: u8) bool {
    return b == '<' or b == '>';
}

fn scanTo(allocator: std.mem.Allocator, source: []const u8, cursor: usize) !Scan {
    var scan = Scan.init();
    errdefer scan.deinit(allocator);
    var i: usize = 0;
    while (i < cursor) : (i += 1) {
        const b = source[i];
        switch (scan.quote) {
            .single => {
                if (b == '\'') {
                    scan.quote = .bare;
                } else {
                    try scan.token.append(allocator, b);
                }
                continue;
            },
            .double => {
                if (b == '"') {
                    scan.quote = .bare;
                } else if (b == '\\' and i + 1 < cursor) {
                    i += 1;
                    try scan.token.append(allocator, source[i]);
                } else {
                    try scan.token.append(allocator, b);
                }
                continue;
            },
            .bare => {},
        }

        if (isSpace(b)) {
            try scan.finish(allocator);
        } else if (isSeparator(b)) {
            try scan.finish(allocator);
            scan.command_position = true;
            scan.command_name.clearRetainingCapacity();
            scan.redirection_target = false;
        } else if (isRedirection(b)) {
            var io_number = scan.command_position and scan.token_active and scan.token.items.len != 0;
            if (io_number) {
                for (scan.token.items) |digit| {
                    if (!std.ascii.isDigit(digit)) {
                        io_number = false;
                        break;
                    }
                }
            }
            if (io_number) {
                scan.token_active = false;
                scan.token.clearRetainingCapacity();
                scan.quote = .bare;
                scan.token_quote = .bare;
            } else {
                try scan.finish(allocator);
            }
            scan.redirection_target = true;
        } else {
            scan.start(i);
            if (b == '\'') {
                scan.quote = .single;
                scan.token_quote = .single;
            } else if (b == '"') {
                scan.quote = .double;
                scan.token_quote = .double;
            } else if (b == '\\' and i + 1 < cursor) {
                i += 1;
                try scan.token.append(allocator, source[i]);
            } else {
                try scan.token.append(allocator, b);
            }
        }
    }
    if (!scan.token_active) scan.token_start = cursor;
    return scan;
}

fn tokenEnd(source: []const u8, cursor: usize, initial_quote: Quote) usize {
    var quote = initial_quote;
    var escaped = false;
    var i = cursor;
    while (i < source.len) : (i += 1) {
        const b = source[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        switch (quote) {
            .single => {
                if (b == '\'') quote = .bare;
            },
            .double => {
                if (b == '"') quote = .bare else if (b == '\\') escaped = true;
            },
            .bare => {
                if (b == '\\') escaped = true else if (b == '\'') quote = .single else if (b == '"') quote = .double else if (isSpace(b) or isSeparator(b) or isRedirection(b)) return i;
            },
        }
    }
    return source.len;
}

pub fn probe(allocator: std.mem.Allocator, source: []const u8, cursor: usize) !Probe {
    if (cursor > source.len) return error.InvalidCursor;
    var scan = try scanTo(allocator, source, cursor);
    defer scan.deinit(allocator);

    var prefix = try allocator.dupe(u8, scan.token.items);
    errdefer allocator.free(prefix);
    var start = scan.token_start;
    var end = tokenEnd(source, cursor, scan.quote);
    var context: Context = if (scan.command_position) .command else if (scan.redirection_target) .path else if (std.mem.eql(u8, scan.command_name.items, "cd")) .directory else .path;
    var quote = scan.token_quote;

    var variable_start = scan.token_start;
    if (variable_start < cursor and (source[variable_start] == '"' or source[variable_start] == '\'')) {
        variable_start += 1;
    }
    const raw = source[variable_start..cursor];
    if (scan.token_quote != .single and raw.len >= 2 and raw[0] == '$' and raw[1] == '{') {
        const next = try allocator.dupe(u8, raw[2..]);
        allocator.free(prefix);
        prefix = next;
        start = variable_start + 2;
        if (end > cursor and source[end - 1] == '}') end -= 1;
        context = .variable;
        quote = .bare;
    } else if (scan.token_quote != .single and raw.len >= 1 and raw[0] == '$') {
        const next = try allocator.dupe(u8, raw[1..]);
        allocator.free(prefix);
        prefix = next;
        start = variable_start + 1;
        context = .variable;
        quote = .bare;
    }

    return .{
        .replace_start = start,
        .replace_end = end,
        .prefix = prefix,
        .context = context,
        .quote = quote,
    };
}

fn needsBareEscape(b: u8) bool {
    return isSpace(b) or isSeparator(b) or isRedirection(b) or b == '\\' or b == '\'' or b == '"' or b == '$' or b == '`';
}

pub fn renderValue(allocator: std.mem.Allocator, value: []const u8, quote: Quote) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    switch (quote) {
        .bare => for (value) |b| {
            if (needsBareEscape(b)) try out.append(allocator, '\\');
            try out.append(allocator, b);
        },
        .double => {
            try out.append(allocator, '"');
            for (value) |b| {
                if (b == '\\' or b == '"' or b == '$' or b == '`') try out.append(allocator, '\\');
                try out.append(allocator, b);
            }
            try out.append(allocator, '"');
        },
        .single => {
            try out.append(allocator, '\'');
            for (value) |b| {
                if (b == '\'') {
                    try out.appendSlice(allocator, "'\\''");
                } else try out.append(allocator, b);
            }
            try out.append(allocator, '\'');
        },
    }
    return out.toOwnedSlice(allocator);
}

pub fn commonPrefix(values: []const []const u8) []const u8 {
    if (values.len == 0) return "";
    var n = values[0].len;
    for (values[1..]) |value| {
        n = @min(n, value.len);
        var i: usize = 0;
        while (i < n and values[0][i] == value[i]) : (i += 1) {}
        n = i;
    }
    while (n > 0 and n < values[0].len and (values[0][n] & 0xc0) == 0x80) n -= 1;
    return values[0][0..n];
}

test "probe classifies command, directory, path, and variable words" {
    const a = std.testing.allocator;
    const cases = [_]struct { source: []const u8, context: Context, prefix: []const u8 }{
        .{ .source = "ec", .context = .command, .prefix = "ec" },
        .{ .source = "cd src/", .context = .directory, .prefix = "src/" },
        .{ .source = "cat src/ma", .context = .path, .prefix = "src/ma" },
        .{ .source = "echo $PA", .context = .variable, .prefix = "PA" },
        .{ .source = "FOO=bar ec", .context = .command, .prefix = "ec" },
        .{ .source = ">log ec", .context = .command, .prefix = "ec" },
        .{ .source = "2>log ec", .context = .command, .prefix = "ec" },
    };
    for (cases) |case| {
        const result = try probe(a, case.source, case.source.len);
        defer result.deinit(a);
        try std.testing.expectEqual(case.context, result.context);
        try std.testing.expectEqualStrings(case.prefix, result.prefix);
    }
}

test "probe preserves variable sigils and quote delimiters outside its replacement" {
    const a = std.testing.allocator;
    const quoted = try probe(a, "echo \"$PA", 9);
    defer quoted.deinit(a);
    try std.testing.expectEqual(Context.variable, quoted.context);
    try std.testing.expectEqual(@as(usize, 7), quoted.replace_start);
    try std.testing.expectEqualStrings("PA", quoted.prefix);

    const literal = try probe(a, "echo '$PA", 9);
    defer literal.deinit(a);
    try std.testing.expectEqual(Context.path, literal.context);
}

test "render quotes candidates without changing their shell value" {
    const a = std.testing.allocator;
    const bare = try renderValue(a, "two words", .bare);
    defer a.free(bare);
    try std.testing.expectEqualStrings("two\\ words", bare);
    const single = try renderValue(a, "it's", .single);
    defer a.free(single);
    try std.testing.expectEqualStrings("'it'\\''s'", single);
}

test "common prefix never splits UTF-8" {
    try std.testing.expectEqualStrings("", commonPrefix(&.{ "éclair", "être" }));
    try std.testing.expectEqualStrings("é", commonPrefix(&.{ "éclair", "école" }));
}
