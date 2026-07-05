//! A stream editor (sed): compiles a script into commands and runs them over the input's
//! line cycle with a pattern space + hold space. Matches the common GNU/POSIX sed surface
//! (the uutils-sed feature contract, docs/analysis/uutils-applets.md). Regex is the
//! project Pike-VM (ERE); BRE (sed's default) is translated to ERE here. Backreferences
//! INSIDE a pattern (`\1` in the regex itself) are a documented deferral -- `\1..\9` and
//! `&` in the REPLACEMENT use the engine's capture spans and are supported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const regex = @import("../regex.zig");

pub const Error = error{ Parse, OutOfMemory };

const Addr = union(enum) {
    none,
    line: usize,
    last, // $
    re: *regex.Regex,
};

const Cmd = struct {
    a1: Addr = .none,
    a2: Addr = .none,
    negate: bool = false,
    range_active: bool = false,
    kind: Kind,

    const Kind = union(enum) {
        subst: Subst,
        print, // p
        print_first, // P (up to first newline)
        delete, // d
        delete_first, // D
        next, // n
        next_append, // N
        get, // g
        get_append, // G
        hold, // h
        hold_append, // H
        exchange, // x
        transliterate: struct { from: []const u8, to: []const u8 }, // y
        quit: struct { code: u8, print: bool }, // q / Q
        equals, // =
        append_text: []const u8, // a
        insert_text: []const u8, // i
        change_text: []const u8, // c
        label: []const u8, // :
        branch: []const u8, // b
        branch_if: []const u8, // t
        branch_if_not: []const u8, // T
        block_open: usize, // { -> index of matching }
        block_close,
        zap, // z (empty pattern space)
    };
};

const Subst = struct {
    re: *regex.Regex,
    repl: []const u8,
    global: bool = false,
    nth: usize = 0, // 0 = default (first), else the Nth occurrence
    print: bool = false, // p flag
};

pub const Program = struct {
    cmds: []Cmd,
};

// ---------------------------------------------------------------- compile

pub const Compiler = struct {
    gpa: Allocator,
    ere: bool, // -E/-r
    src: []const u8,
    pos: usize = 0,
    cmds: std.ArrayListUnmanaged(Cmd) = .empty,

    pub fn compile(gpa: Allocator, script: []const u8, ere: bool) Error!Program {
        var c = Compiler{ .gpa = gpa, .ere = ere, .src = script };
        try c.parseAll();
        try c.linkBlocks();
        return .{ .cmds = c.cmds.items };
    }

    fn parseAll(self: *Compiler) Error!void {
        while (true) {
            self.skipSep();
            if (self.pos >= self.src.len) break;
            try self.parseCmd();
        }
    }

    fn skipSep(self: *Compiler) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == ';') {
                self.pos += 1;
            } else if (c == '#') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            } else break;
        }
    }

    fn peek(self: *Compiler) u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else 0;
    }

    fn parseCmd(self: *Compiler) Error!void {
        var cmd = Cmd{ .kind = undefined };
        cmd.a1 = try self.parseAddr();
        if (cmd.a1 != .none and self.peek() == ',') {
            self.pos += 1;
            cmd.a2 = try self.parseAddr();
        }
        // whitespace before the command letter
        while (self.peek() == ' ' or self.peek() == '\t') self.pos += 1;
        while (self.peek() == '!') {
            cmd.negate = !cmd.negate;
            self.pos += 1;
            while (self.peek() == ' ' or self.peek() == '\t') self.pos += 1;
        }
        const letter = self.peek();
        if (letter == 0) return error.Parse;
        self.pos += 1;
        cmd.kind = try self.parseKind(letter);
        try self.cmds.append(self.gpa, cmd);
    }

    fn parseAddr(self: *Compiler) Error!Addr {
        const c = self.peek();
        if (c == '$') {
            self.pos += 1;
            return .last;
        }
        if (c >= '0' and c <= '9') {
            var n: usize = 0;
            while (self.peek() >= '0' and self.peek() <= '9') : (self.pos += 1) n = n * 10 + (self.peek() - '0');
            return .{ .line = n };
        }
        if (c == '/' or c == '\\') {
            var delim: u8 = '/';
            if (c == '\\') {
                self.pos += 1;
                delim = self.peek();
            }
            self.pos += 1; // past opening delim
            const pat = try self.readDelim(delim);
            const re = try self.compileRe(pat);
            return .{ .re = re };
        }
        return .none;
    }

    /// Read until an unescaped `delim`, returning the raw (still-escaped) slice.
    fn readDelim(self: *Compiler, delim: u8) Error![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\\' and self.pos + 1 < self.src.len) {
                const nxt = self.src[self.pos + 1];
                if (nxt == delim) {
                    try out.append(self.gpa, delim);
                    self.pos += 2;
                    continue;
                }
                if (nxt == 'n') {
                    try out.append(self.gpa, '\n');
                    self.pos += 2;
                    continue;
                }
                try out.append(self.gpa, c);
                try out.append(self.gpa, nxt);
                self.pos += 2;
                continue;
            }
            if (c == delim) {
                self.pos += 1;
                return out.items;
            }
            if (c == '\n') break;
            try out.append(self.gpa, c);
            self.pos += 1;
        }
        return error.Parse;
    }

    fn parseKind(self: *Compiler, letter: u8) Error!Cmd.Kind {
        switch (letter) {
            's' => return .{ .subst = try self.parseSubst() },
            'y' => {
                const y = try self.parseY();
                return .{ .transliterate = .{ .from = y.from, .to = y.to } };
            },
            'p' => return .print,
            'P' => return .print_first,
            'd' => return .delete,
            'D' => return .delete_first,
            'n' => return .next,
            'N' => return .next_append,
            'g' => return .get,
            'G' => return .get_append,
            'h' => return .hold,
            'H' => return .hold_append,
            'x' => return .exchange,
            'z' => return .zap,
            '=' => return .equals,
            'q' => return .{ .quit = .{ .code = try self.parseOptCode(), .print = true } },
            'Q' => return .{ .quit = .{ .code = try self.parseOptCode(), .print = false } },
            '{' => return .{ .block_open = 0 },
            '}' => return .block_close,
            ':' => return .{ .label = try self.readLabel() },
            'b' => return .{ .branch = try self.readLabel() },
            't' => return .{ .branch_if = try self.readLabel() },
            'T' => return .{ .branch_if_not = try self.readLabel() },
            'a' => return .{ .append_text = try self.readText() },
            'i' => return .{ .insert_text = try self.readText() },
            'c' => return .{ .change_text = try self.readText() },
            else => return error.Parse,
        }
    }

    fn parseOptCode(self: *Compiler) Error!u8 {
        while (self.peek() == ' ') self.pos += 1;
        var n: u16 = 0;
        var any = false;
        while (self.peek() >= '0' and self.peek() <= '9') : (self.pos += 1) {
            n = n * 10 + (self.peek() - '0');
            any = true;
        }
        return if (any) @intCast(n & 0xff) else 0;
    }

    fn readLabel(self: *Compiler) Error![]const u8 {
        while (self.peek() == ' ') self.pos += 1;
        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ';' or c == '\n' or c == '}') break;
            self.pos += 1;
        }
        return std.mem.trim(u8, self.src[start..self.pos], " \t");
    }

    /// GNU one-line form: `a text` or `a\` then text. We accept `a\<newline>text` and
    /// `a text` (rest of line).
    fn readText(self: *Compiler) Error![]const u8 {
        if (self.peek() == '\\') {
            self.pos += 1;
            if (self.peek() == '\n') self.pos += 1;
        } else {
            while (self.peek() == ' ') self.pos += 1;
        }
        var out: std.ArrayListUnmanaged(u8) = .empty;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\\' and self.pos + 1 < self.src.len) {
                const nxt = self.src[self.pos + 1];
                if (nxt == '\n') {
                    try out.append(self.gpa, '\n');
                    self.pos += 2;
                    continue;
                }
                try out.append(self.gpa, nxt);
                self.pos += 2;
                continue;
            }
            if (c == '\n') break;
            try out.append(self.gpa, c);
            self.pos += 1;
        }
        return out.items;
    }

    fn parseSubst(self: *Compiler) Error!Subst {
        const delim = self.peek();
        if (delim == 0 or delim == '\n' or delim == '\\') return error.Parse;
        self.pos += 1;
        const pat = try self.readDelim(delim);
        const repl = try self.readReplacement(delim);
        var s = Subst{ .re = undefined, .repl = repl };
        // flags
        var icase = false;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            switch (c) {
                'g' => {
                    s.global = true;
                    self.pos += 1;
                },
                'p' => {
                    s.print = true;
                    self.pos += 1;
                },
                'i', 'I' => {
                    icase = true;
                    self.pos += 1;
                },
                'm', 'M' => self.pos += 1,
                '0'...'9' => {
                    var n: usize = 0;
                    while (self.peek() >= '0' and self.peek() <= '9') : (self.pos += 1) n = n * 10 + (self.peek() - '0');
                    s.nth = n;
                },
                else => break,
            }
        }
        s.re = try self.compileReCase(pat, icase);
        return s;
    }

    fn readReplacement(self: *Compiler, delim: u8) Error![]const u8 {
        // Keep escapes intact except the delimiter; the executor interprets & and \N.
        var out: std.ArrayListUnmanaged(u8) = .empty;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\\' and self.pos + 1 < self.src.len) {
                const nxt = self.src[self.pos + 1];
                if (nxt == delim) {
                    try out.append(self.gpa, delim);
                    self.pos += 2;
                    continue;
                }
                try out.append(self.gpa, c);
                try out.append(self.gpa, nxt);
                self.pos += 2;
                continue;
            }
            if (c == delim) {
                self.pos += 1;
                return out.items;
            }
            if (c == '\n') break;
            try out.append(self.gpa, c);
            self.pos += 1;
        }
        return error.Parse;
    }

    fn parseY(self: *Compiler) Error!struct { from: []const u8, to: []const u8 } {
        const delim = self.peek();
        self.pos += 1;
        const from = try self.readYPart(delim);
        const to = try self.readYPart(delim);
        return .{ .from = from, .to = to };
    }

    fn readYPart(self: *Compiler, delim: u8) Error![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\\' and self.pos + 1 < self.src.len) {
                const nxt = self.src[self.pos + 1];
                try out.append(self.gpa, switch (nxt) {
                    'n' => '\n',
                    't' => '\t',
                    else => nxt,
                });
                self.pos += 2;
                continue;
            }
            if (c == delim) {
                self.pos += 1;
                return out.items;
            }
            try out.append(self.gpa, c);
            self.pos += 1;
        }
        return error.Parse;
    }

    fn compileRe(self: *Compiler, pat: []const u8) Error!*regex.Regex {
        return self.compileReCase(pat, false);
    }

    fn compileReCase(self: *Compiler, pat: []const u8, icase: bool) Error!*regex.Regex {
        const ere_pat = if (self.ere) pat else try breToEre(self.gpa, pat);
        var diag: regex.Diag = .{};
        const re = self.gpa.create(regex.Regex) catch return error.OutOfMemory;
        re.* = regex.compile(self.gpa, ere_pat, .{ .case_insensitive = icase }, &diag) catch return error.Parse;
        return re;
    }

    /// Resolve each `{`/`}` block command to its partner index for fast skipping.
    fn linkBlocks(self: *Compiler) Error!void {
        var stack: std.ArrayListUnmanaged(usize) = .empty;
        for (self.cmds.items, 0..) |*cmd, i| {
            switch (cmd.kind) {
                .block_open => try stack.append(self.gpa, i),
                .block_close => {
                    const open = stack.pop() orelse return error.Parse;
                    self.cmds.items[open].kind = .{ .block_open = i };
                },
                else => {},
            }
        }
        if (stack.items.len != 0) return error.Parse;
    }
};

/// Translate a POSIX/GNU BRE to the ERE the Pike-VM parses: swap the escaped-vs-bare
/// meaning of ( ) { } + ? |. Character classes `[...]` pass through untouched.
pub fn breToEre(gpa: Allocator, bre: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < bre.len) {
        const c = bre[i];
        if (c == '[') {
            // copy the whole bracket expression verbatim
            try out.append(gpa, c);
            i += 1;
            if (i < bre.len and bre[i] == '^') {
                try out.append(gpa, bre[i]);
                i += 1;
            }
            if (i < bre.len and bre[i] == ']') {
                try out.append(gpa, bre[i]);
                i += 1;
            }
            while (i < bre.len and bre[i] != ']') {
                try out.append(gpa, bre[i]);
                i += 1;
            }
            if (i < bre.len) {
                try out.append(gpa, ']');
                i += 1;
            }
            continue;
        }
        if (c == '\\' and i + 1 < bre.len) {
            const n = bre[i + 1];
            switch (n) {
                '(', ')', '{', '}', '+', '?', '|' => {
                    // escaped special in BRE -> bare special in ERE
                    try out.append(gpa, n);
                },
                else => {
                    // keep the escape (\., \*, \\, \1.. etc.)
                    try out.append(gpa, '\\');
                    try out.append(gpa, n);
                },
            }
            i += 2;
            continue;
        }
        switch (c) {
            '(', ')', '{', '}', '+', '?', '|' => {
                // bare special in BRE -> literal in ERE
                try out.append(gpa, '\\');
                try out.append(gpa, c);
            },
            else => try out.append(gpa, c),
        }
        i += 1;
    }
    return out.items;
}

// ---------------------------------------------------------------- executor

pub const OutFn = *const fn (ctx: *anyopaque, bytes: []const u8) void;

pub const Executor = struct {
    gpa: Allocator,
    prog: Program,
    out_ctx: *anyopaque,
    out: OutFn,
    auto_print: bool, // !-n
    pattern: std.ArrayListUnmanaged(u8) = .empty,
    hold: std.ArrayListUnmanaged(u8) = .empty,
    line_no: usize = 0,
    quit: bool = false,
    quit_code: u8 = 0,
    tflag: bool = false, // for t/T
    slots: [20]?regex.Span = undefined,
    append_queue: std.ArrayListUnmanaged(u8) = .empty, // queued `a` text, drained after each cycle

    pub fn init(gpa: Allocator, prog: Program, out_ctx: *anyopaque, out: OutFn, auto_print: bool) Executor {
        return .{ .gpa = gpa, .prog = prog, .out_ctx = out_ctx, .out = out, .auto_print = auto_print };
    }

    fn emit(self: *Executor, bytes: []const u8) void {
        self.out(self.out_ctx, bytes);
    }
    fn emitLine(self: *Executor, bytes: []const u8) void {
        self.emit(bytes);
        self.emit("\n");
    }

    /// Run over `lines` (already split, without terminators). is_last tells `$`.
    pub fn run(self: *Executor, lines: []const []const u8) !void {
        var idx: usize = 0;
        while (idx < lines.len) : (idx += 1) {
            self.line_no = idx + 1;
            self.pattern.clearRetainingCapacity();
            try self.pattern.appendSlice(self.gpa, lines[idx]);
            self.tflag = false;
            const action = try self.cycle(lines, &idx);
            switch (action) {
                .normal => if (self.auto_print) self.emitLine(self.pattern.items),
                .deleted => {},
                .quit_print => {
                    if (self.auto_print) self.emitLine(self.pattern.items);
                    self.quit = true;
                },
                .quit_noprint => self.quit = true,
            }
            self.drainAppend();
            if (self.quit) return;
        }
    }

    const CycleAction = enum { normal, deleted, quit_print, quit_noprint };

    fn cycle(self: *Executor, lines: []const []const u8, idx: *usize) !CycleAction {
        var pc: usize = 0;
        while (pc < self.prog.cmds.len) {
            const cmd = &self.prog.cmds[pc];
            const matches = self.addrMatches(cmd, lines.len);
            if (!matches) {
                // skip block body if this is an unmatched block open
                if (cmd.kind == .block_open) {
                    pc = cmd.kind.block_open + 1;
                    continue;
                }
                pc += 1;
                continue;
            }
            switch (cmd.kind) {
                .block_open, .block_close, .label => {},
                .print => self.emitLine(self.pattern.items),
                .print_first => {
                    const nl = std.mem.indexOfScalar(u8, self.pattern.items, '\n') orelse self.pattern.items.len;
                    self.emitLine(self.pattern.items[0..nl]);
                },
                .delete => return .deleted,
                .delete_first => {
                    const nl = std.mem.indexOfScalar(u8, self.pattern.items, '\n');
                    if (nl) |p| {
                        const rest = try self.gpa.dupe(u8, self.pattern.items[p + 1 ..]);
                        self.pattern.clearRetainingCapacity();
                        try self.pattern.appendSlice(self.gpa, rest);
                        pc = 0;
                        continue;
                    } else return .deleted;
                },
                .next => {
                    if (self.auto_print) self.emitLine(self.pattern.items);
                    if (idx.* + 1 >= lines.len) return .deleted;
                    idx.* += 1;
                    self.line_no = idx.* + 1;
                    self.pattern.clearRetainingCapacity();
                    try self.pattern.appendSlice(self.gpa, lines[idx.*]);
                },
                .next_append => {
                    if (idx.* + 1 >= lines.len) {
                        // GNU: print pattern (if auto) and end
                        return .normal;
                    }
                    idx.* += 1;
                    self.line_no = idx.* + 1;
                    try self.pattern.append(self.gpa, '\n');
                    try self.pattern.appendSlice(self.gpa, lines[idx.*]);
                },
                .get => {
                    self.pattern.clearRetainingCapacity();
                    try self.pattern.appendSlice(self.gpa, self.hold.items);
                },
                .get_append => {
                    try self.pattern.append(self.gpa, '\n');
                    try self.pattern.appendSlice(self.gpa, self.hold.items);
                },
                .hold => {
                    self.hold.clearRetainingCapacity();
                    try self.hold.appendSlice(self.gpa, self.pattern.items);
                },
                .hold_append => {
                    try self.hold.append(self.gpa, '\n');
                    try self.hold.appendSlice(self.gpa, self.pattern.items);
                },
                .exchange => {
                    const tmp = try self.gpa.dupe(u8, self.pattern.items);
                    self.pattern.clearRetainingCapacity();
                    try self.pattern.appendSlice(self.gpa, self.hold.items);
                    self.hold.clearRetainingCapacity();
                    try self.hold.appendSlice(self.gpa, tmp);
                },
                .zap => self.pattern.clearRetainingCapacity(),
                .equals => {
                    var b: [24]u8 = undefined;
                    self.emitLine(std.fmt.bufPrint(&b, "{d}", .{self.line_no}) catch "0");
                },
                .append_text => |t| {
                    // 'a' queues text to print after the cycle; simplified: print at end via
                    // immediate emit after auto-print. Here we emit immediately after the
                    // line is output -> store on a small queue.
                    try self.append_queue.appendSlice(self.gpa, t);
                    try self.append_queue.append(self.gpa, '\n');
                },
                .insert_text => |t| self.emitLine(t),
                .change_text => |t| {
                    // Print text and delete pattern (for a range, GNU prints once at range end;
                    // simplified: print on each matched line's delete).
                    self.emitLine(t);
                    return .deleted;
                },
                .transliterate => |y| self.doY(y.from, y.to),
                .subst => |s| try self.doSubst(s),
                .quit => |q| return if (q.print) .quit_print else blk: {
                    self.quit_code = q.code;
                    break :blk .quit_noprint;
                },
                .branch => |label| {
                    pc = self.findLabel(label) orelse self.prog.cmds.len;
                    if (label.len == 0) break; // branch to end
                    continue;
                },
                .branch_if => |label| {
                    if (self.tflag) {
                        self.tflag = false;
                        if (label.len == 0) break;
                        pc = self.findLabel(label) orelse self.prog.cmds.len;
                        continue;
                    }
                },
                .branch_if_not => |label| {
                    if (!self.tflag) {
                        if (label.len == 0) break;
                        pc = self.findLabel(label) orelse self.prog.cmds.len;
                        continue;
                    }
                    self.tflag = false;
                },
            }
            if (cmd.kind == .quit) {} // handled above
            pc += 1;
        }
        return .normal;
    }

    fn drainAppend(self: *Executor) void {
        if (self.append_queue.items.len != 0) {
            self.emit(self.append_queue.items);
            self.append_queue.clearRetainingCapacity();
        }
    }

    fn findLabel(self: *Executor, label: []const u8) ?usize {
        for (self.prog.cmds, 0..) |cmd, i| {
            if (cmd.kind == .label and std.mem.eql(u8, cmd.kind.label, label)) return i;
        }
        return null;
    }

    fn addrMatches(self: *Executor, cmd: *Cmd, nlines: usize) bool {
        const base = self.addrMatchesRaw(cmd, nlines);
        return base != cmd.negate;
    }

    fn addrMatchesRaw(self: *Executor, cmd: *Cmd, nlines: usize) bool {
        if (cmd.a1 == .none) return true;
        if (cmd.a2 == .none) return self.oneAddr(cmd.a1, nlines);
        // range
        if (!cmd.range_active) {
            if (self.oneAddr(cmd.a1, nlines)) {
                cmd.range_active = true;
                // a numeric end <= current line means single line
                if (cmd.a2 == .line and cmd.a2.line <= self.line_no) cmd.range_active = false;
                return true;
            }
            return false;
        } else {
            if (self.oneAddr(cmd.a2, nlines)) cmd.range_active = false;
            return true;
        }
    }

    fn oneAddr(self: *Executor, a: Addr, nlines: usize) bool {
        return switch (a) {
            .none => true,
            .line => |n| self.line_no == n,
            .last => self.line_no == nlines,
            .re => |re| re.find(self.pattern.items, 0) != null,
        };
    }

    fn doY(self: *Executor, from: []const u8, to: []const u8) void {
        for (self.pattern.items) |*ch| {
            if (std.mem.indexOfScalar(u8, from, ch.*)) |i| {
                if (i < to.len) ch.* = to[i];
            }
        }
    }

    fn doSubst(self: *Executor, s: Subst) !void {
        const input = try self.gpa.dupe(u8, self.pattern.items);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var pos: usize = 0;
        var count: usize = 0;
        var did = false;
        while (pos <= input.len) {
            const m = s.re.captures(input, pos, &self.slots) orelse {
                try out.appendSlice(self.gpa, input[pos..]);
                break;
            };
            count += 1;
            const want = if (s.nth == 0) count == 1 or s.global else (count == s.nth) or (s.global and count >= s.nth);
            try out.appendSlice(self.gpa, input[pos..m.start]);
            if (want) {
                did = true;
                try self.applyRepl(&out, s.repl, input, m);
            } else {
                try out.appendSlice(self.gpa, input[m.start..m.end]);
            }
            if (m.end == m.start) {
                if (m.end < input.len) try out.append(self.gpa, input[m.end]);
                pos = m.end + 1;
            } else {
                pos = m.end;
            }
            if (!s.global and s.nth == 0 and did) {
                try out.appendSlice(self.gpa, input[pos..]);
                break;
            }
        }
        if (did) {
            self.pattern.clearRetainingCapacity();
            try self.pattern.appendSlice(self.gpa, out.items);
            self.tflag = true;
            if (s.print) self.emitLine(self.pattern.items);
        }
    }

    fn applyRepl(self: *Executor, out: *std.ArrayListUnmanaged(u8), repl: []const u8, input: []const u8, m: regex.Span) !void {
        var i: usize = 0;
        while (i < repl.len) : (i += 1) {
            const c = repl[i];
            if (c == '&') {
                try out.appendSlice(self.gpa, input[m.start..m.end]);
            } else if (c == '\\' and i + 1 < repl.len) {
                const n = repl[i + 1];
                i += 1;
                if (n >= '0' and n <= '9') {
                    const g = n - '0';
                    if (g == 0) {
                        try out.appendSlice(self.gpa, input[m.start..m.end]);
                    } else if (g <= self.slots.len) {
                        if (self.slots[g - 1]) |sp| try out.appendSlice(self.gpa, input[sp.start..sp.end]);
                    }
                } else {
                    try out.append(self.gpa, switch (n) {
                        'n' => '\n',
                        't' => '\t',
                        else => n,
                    });
                }
            } else {
                try out.append(self.gpa, c);
            }
        }
    }
};
