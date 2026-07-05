//! A pure-Zig Pike-VM regex engine (DESIGN.md §7.1), adapted from
//! `reference/mc-glue/re.zig` (the same Thompson-construction / thread-list-with-save-
//! slots design used by the kernel's Lua `re` battery). De-Lua'd: takes an explicit
//! `std.mem.Allocator` instead of `std.heap.c_allocator`, and surfaces compile errors
//! as a `CompileError` plus a `Diag.msg` string instead of a Lua `nil, message` return
//! (so callers -- `grep: invalid pattern: <e>` -- can format the reason).
//!
//! Kept from the original: literals, `.`, `\d \D \w \W \s \S`, classes `[...]`/`[^...]`
//! with ranges, anchors `^ $`, groups `(...)`/`(?:...)`, alternation `|`, quantifiers
//! `* + ? {m} {m,} {m,n}` (greedy + lazy via thread priority), flags `i`/`s`/`m`. The
//! Pike VM is linear-time (no catastrophic backtracking): a `seen[pc] == gen` guard in
//! `addThread` collapses the epsilon-closure at each input position, which is also what
//! makes empty-body loops like `(a?)*` terminate instead of looping forever.
//!
//! Added for grep (DESIGN.md M3): `\b`/`\B` word-boundary zero-width asserts (word
//! char = `[A-Za-z0-9_]`), 12 POSIX classes (`[[:alpha:]]` etc., ASCII-only) inside
//! bracket expressions, `\xHH` hex escapes, and a literal-compile mode (`grep -F`: no
//! metacharacters, each pattern is a plain byte string). `compileMulti` builds the
//! alternation `(?:p1)|(?:p2)|...` at the AST level (all patterns parsed into one
//! shared node arena via one `Parser`, then wrapped in a single top-level `.alt` node)
//! so a `|` inside one of the `-e` patterns keeps its own precedence instead of leaking
//! across pattern boundaries the way naive string concatenation would.
//!
//! Grep matches per line (the searcher hands one line at a time to `find`/`isMatch`);
//! `^`/`$` anchor to that line string, so `multiline` is unused by grep but kept for
//! future sed/awk reuse (DESIGN.md §7.1).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Span = struct { start: usize, end: usize };

pub const Options = struct {
    case_insensitive: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
    /// grep -F: no metacharacters at all, each pattern is a literal byte string.
    literal: bool = false,
};

pub const CompileError = error{InvalidPattern};

/// Set by `compile`/`compileMulti` on `error.InvalidPattern`; a static string (no
/// ownership to manage).
pub const Diag = struct {
    msg: []const u8 = "",
};

// ============================================================================ bytecode

const Op = enum(u8) { char, any, class, match, jmp, split, save, bol, eol, wordb, nwordb };

const Inst = struct {
    op: Op,
    x: i32 = 0, // jump target (jmp uses x; split uses x/y, x = higher priority)
    y: i32 = 0,
    ch: u8 = 0,
    cls: i32 = -1, // index into Prog.classes
    n: i32 = 0, // save slot
};

const CharClass = struct {
    bits: [32]u8 = [_]u8{0} ** 32,
    negate: bool = false,

    fn add(self: *CharClass, ch: u32) void {
        self.bits[ch >> 3] |= @as(u8, 1) << @intCast(ch & 7);
    }
    fn has(self: *const CharClass, ch: u32) bool {
        return (self.bits[ch >> 3] >> @intCast(ch & 7)) & 1 != 0;
    }
};

fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_';
}

/// Word-char definition shared with `\b`/`\B` (`[A-Za-z0-9_]`) -- exported so callers
/// implementing their own boundary logic on top of `find` (grep's `-w`, applied at the
/// match level rather than baked into the pattern) agree with the engine's own asserts.
pub fn isWordChar(b: u8) bool {
    return isWordByte(b);
}

inline fn lowerAscii(ch: i32) i32 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

fn classMatch(cc: *const CharClass, ch: u8, icase: bool) bool {
    var in = cc.has(ch);
    if (!in and icase) {
        const alt: u8 = if (ch >= 'a' and ch <= 'z')
            ch - 32
        else if (ch >= 'A' and ch <= 'Z')
            ch + 32
        else
            ch;
        if (alt != ch) in = cc.has(alt);
    }
    return if (cc.negate) !in else in;
}

const Prog = struct {
    insts: std.ArrayListUnmanaged(Inst) = .empty,
    classes: std.ArrayListUnmanaged(CharClass) = .empty,
    nsaves: i32 = 2,
    icase: bool = false,
    dotall: bool = false,
    multiline: bool = false,

    fn deinit(self: *Prog, gpa: Allocator) void {
        self.insts.deinit(gpa);
        self.classes.deinit(gpa);
    }
};

// ============================================================================ AST

const Tag = enum {
    lit,
    any,
    class,
    concat,
    alt,
    star,
    plus,
    quest,
    repeat,
    group,
    bol,
    eol,
    wordb,
    nwordb,
    empty,
};

const Node = struct {
    tag: Tag,
    ch: i32 = 0,
    cls: i32 = -1,
    cap: i32 = -1,
    lo: i32 = 0,
    hi: i32 = 0,
    greedy: bool = true,
    kids: std.ArrayListUnmanaged(i32) = .empty,
};

const Escape = struct {
    value: i32 = 0, // literal byte, when shorthand==0 and not a wordb/nwordb marker
    shorthand: u8 = 0, // 'd'/'w'/'s' or 0
    neg: bool = false,
    is_wordb: bool = false,
    is_nwordb: bool = false,
};

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
fn hexVal(c: u8) i32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

/// ASCII membership test for one of the 12 POSIX bracket-expression classes; `null`
/// when `name` isn't a recognized class name.
fn posixClassHas(name: []const u8, ch: u8) ?bool {
    if (std.mem.eql(u8, name, "alpha")) return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
    if (std.mem.eql(u8, name, "digit")) return ch >= '0' and ch <= '9';
    if (std.mem.eql(u8, name, "alnum")) return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9');
    if (std.mem.eql(u8, name, "upper")) return ch >= 'A' and ch <= 'Z';
    if (std.mem.eql(u8, name, "lower")) return ch >= 'a' and ch <= 'z';
    if (std.mem.eql(u8, name, "space")) return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 11 or ch == 12;
    if (std.mem.eql(u8, name, "punct")) return (ch >= '!' and ch <= '/') or (ch >= ':' and ch <= '@') or (ch >= '[' and ch <= '`') or (ch >= '{' and ch <= '~');
    if (std.mem.eql(u8, name, "cntrl")) return ch < 32 or ch == 127;
    if (std.mem.eql(u8, name, "print")) return ch >= 32 and ch <= 126;
    if (std.mem.eql(u8, name, "graph")) return ch >= 33 and ch <= 126;
    if (std.mem.eql(u8, name, "blank")) return ch == ' ' or ch == '\t';
    if (std.mem.eql(u8, name, "xdigit")) return isHexDigit(ch);
    return null;
}

const Parser = struct {
    gpa: Allocator,
    p: [*]const u8,
    end: [*]const u8,
    prog: *Prog,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    ngroups: i32 = 0,
    err: ?[]const u8 = null,

    fn make(self: *Parser, t: Tag) i32 {
        self.nodes.append(self.gpa, Node{ .tag = t }) catch @panic("OOM");
        return @intCast(self.nodes.items.len - 1);
    }
    fn more(self: *const Parser) bool {
        return @intFromPtr(self.p) < @intFromPtr(self.end);
    }
    fn peek(self: *const Parser) u8 {
        return if (self.more()) self.p[0] else 0;
    }
    fn remaining(self: *const Parser) usize {
        return @intFromPtr(self.end) - @intFromPtr(self.p);
    }

    fn addShorthand(cc: *CharClass, kind: u8, neg: bool) void {
        var tmp = CharClass{};
        switch (kind) {
            'd' => {
                var ch: u32 = '0';
                while (ch <= '9') : (ch += 1) tmp.add(ch);
            },
            'w' => {
                var ch: u32 = 0;
                while (ch < 256) : (ch += 1) {
                    if (isWordByte(@intCast(ch))) tmp.add(ch);
                }
            },
            's' => {
                tmp.add(' ');
                tmp.add('\t');
                tmp.add('\n');
                tmp.add('\r');
                tmp.add(12);
                tmp.add(11);
            },
            else => {},
        }
        var ch: u32 = 0;
        while (ch < 256) : (ch += 1) {
            const member = tmp.has(ch);
            if (if (neg) !member else member) cc.add(ch);
        }
    }

    fn addPosixClass(cc: *CharClass, name: []const u8) bool {
        var found = false;
        var ch: u32 = 0;
        while (ch < 256) : (ch += 1) {
            const m = posixClassHas(name, @intCast(ch)) orelse {
                if (ch == 0) return false;
                continue;
            };
            found = true;
            if (m) cc.add(ch);
        }
        return found;
    }

    /// Consumes the char after a backslash (cursor must already be past the `\`),
    /// producing a literal byte, a `\d\w\s` shorthand, or a `\b`/`\B` word-boundary
    /// marker. `\xHH` consumes up to two following hex digits (lenient: falls back to
    /// literal `x` when none follow).
    fn parseEscape(self: *Parser) Escape {
        const e = self.p[0];
        self.p += 1;
        return switch (e) {
            'n' => .{ .value = '\n' },
            't' => .{ .value = '\t' },
            'r' => .{ .value = '\r' },
            'f' => .{ .value = 12 },
            'v' => .{ .value = 11 },
            'a' => .{ .value = 7 },
            '0' => .{ .value = 0 },
            'd' => .{ .shorthand = 'd' },
            'w' => .{ .shorthand = 'w' },
            's' => .{ .shorthand = 's' },
            'D' => .{ .shorthand = 'd', .neg = true },
            'W' => .{ .shorthand = 'w', .neg = true },
            'S' => .{ .shorthand = 's', .neg = true },
            'b' => .{ .is_wordb = true },
            'B' => .{ .is_nwordb = true },
            'x' => blk: {
                var v: i32 = 0;
                var got = false;
                var count: usize = 0;
                while (count < 2 and self.more() and isHexDigit(self.p[0])) : (count += 1) {
                    v = v * 16 + hexVal(self.p[0]);
                    self.p += 1;
                    got = true;
                }
                break :blk .{ .value = if (got) v else 'x' };
            },
            else => .{ .value = @as(i32, e) }, // escaped literal (incl. metachars)
        };
    }

    fn pushClass(self: *Parser, cc: CharClass) i32 {
        const idx: i32 = @intCast(self.prog.classes.items.len);
        self.prog.classes.append(self.gpa, cc) catch @panic("OOM");
        const nd = self.make(.class);
        self.nodes.items[@intCast(nd)].cls = idx;
        return nd;
    }

    /// Tries to parse a `[:name:]` POSIX class at the cursor (which must be sitting on
    /// the outer `[`); on success ORs it into `cc` and advances past `:]`, returning
    /// true. On any mismatch (unknown name, no closing `:]`) leaves the cursor
    /// untouched and returns false, so the caller falls back to treating `[` as an
    /// ordinary class member.
    fn tryPosixClass(self: *Parser, cc: *CharClass) bool {
        if (self.remaining() < 2 or self.p[0] != '[' or self.p[1] != ':') return false;
        const save = self.p;
        var q = self.p + 2;
        const name_start = q;
        while (@intFromPtr(q) < @intFromPtr(self.end) and q[0] != ':') : (q += 1) {}
        if (@intFromPtr(q) >= @intFromPtr(self.end) or @intFromPtr(q) + 1 >= @intFromPtr(self.end) or q[1] != ']') {
            self.p = save;
            return false;
        }
        const name = name_start[0 .. @intFromPtr(q) - @intFromPtr(name_start)];
        if (!addPosixClass(cc, name)) {
            self.p = save;
            return false;
        }
        self.p = q + 2;
        return true;
    }

    /// Parses a `[...]` body (cursor just past `[`), appends a class node, returns it.
    fn parseClass(self: *Parser) i32 {
        var cc = CharClass{};
        if (self.peek() == '^') {
            cc.negate = true;
            self.p += 1;
        }
        var first = true;
        while (self.more() and (self.p[0] != ']' or first)) {
            first = false;
            if (self.tryPosixClass(&cc)) continue;
            var lo: i32 = undefined;
            if (self.p[0] == '\\' and self.remaining() > 1) {
                self.p += 1;
                const esc = self.parseEscape();
                if (esc.is_wordb) {
                    lo = 'b';
                } else if (esc.is_nwordb) {
                    lo = 'B';
                } else if (esc.shorthand != 0) {
                    addShorthand(&cc, esc.shorthand, esc.neg);
                    continue;
                } else {
                    lo = esc.value;
                }
            } else {
                lo = @as(i32, self.p[0]);
                self.p += 1;
            }
            if (self.more() and self.p[0] == '-' and self.remaining() > 1 and self.p[1] != ']') {
                self.p += 1; // consume '-'
                var hi: i32 = undefined;
                if (self.p[0] == '\\' and self.remaining() > 1) {
                    self.p += 1;
                    const esc = self.parseEscape();
                    hi = if (esc.shorthand != 0 or esc.is_wordb or esc.is_nwordb) lo else esc.value; // can't end a range; degrade
                } else {
                    hi = @as(i32, self.p[0]);
                    self.p += 1;
                }
                var ch = lo;
                while (ch <= hi) : (ch += 1) cc.add(@intCast(ch));
            } else {
                cc.add(@intCast(lo));
            }
        }
        if (self.peek() == ']') self.p += 1 else self.err = "unterminated character class";
        return self.pushClass(cc);
    }

    fn singleShorthandNode(self: *Parser, sh: u8, neg: bool) i32 {
        var cc = CharClass{};
        addShorthand(&cc, sh, neg);
        return self.pushClass(cc);
    }

    fn parseAtom(self: *Parser) i32 {
        const ch = self.p[0];
        self.p += 1;
        if (ch == '(') {
            var cap: i32 = -1;
            if (self.remaining() >= 1 and self.p[0] == '?' and self.remaining() >= 2 and self.p[1] == ':') {
                self.p += 2; // non-capturing
            } else {
                self.ngroups += 1;
                cap = self.ngroups;
            }
            const child = self.parseAlt();
            if (self.peek() == ')') self.p += 1 else self.err = "unbalanced '('";
            const nd = self.make(.group);
            self.nodes.items[@intCast(nd)].cap = cap;
            self.nodes.items[@intCast(nd)].kids.append(self.gpa, child) catch @panic("OOM");
            return nd;
        }
        if (ch == '[') return self.parseClass();
        if (ch == '.') return self.make(.any);
        if (ch == '^') return self.make(.bol);
        if (ch == '$') return self.make(.eol);
        if (ch == '\\' and self.more()) {
            const esc = self.parseEscape();
            if (esc.is_wordb) return self.make(.wordb);
            if (esc.is_nwordb) return self.make(.nwordb);
            if (esc.shorthand != 0) return self.singleShorthandNode(esc.shorthand, esc.neg);
            const nd = self.make(.lit);
            self.nodes.items[@intCast(nd)].ch = esc.value;
            return nd;
        }
        const nd = self.make(.lit);
        self.nodes.items[@intCast(nd)].ch = @as(i32, ch);
        return nd;
    }

    fn parseBrace(self: *Parser, lo: *i32, hi: *i32) bool {
        const save = self.p;
        if (self.peek() != '{') return false;
        self.p += 1;
        var m: i32 = 0;
        var gotm = false;
        while (self.more() and self.p[0] >= '0' and self.p[0] <= '9') {
            m = m * 10 + (@as(i32, self.p[0]) - '0');
            self.p += 1;
            gotm = true;
        }
        if (!gotm) {
            self.p = save;
            return false;
        }
        var n: i32 = m;
        if (self.peek() == ',') {
            self.p += 1;
            if (self.more() and self.p[0] >= '0' and self.p[0] <= '9') {
                n = 0;
                while (self.more() and self.p[0] >= '0' and self.p[0] <= '9') {
                    n = n * 10 + (@as(i32, self.p[0]) - '0');
                    self.p += 1;
                }
            } else {
                n = -1; // {m,}
            }
        }
        if (self.peek() != '}') {
            self.p = save;
            return false;
        }
        self.p += 1;
        lo.* = m;
        hi.* = n;
        return true;
    }

    fn wrapQuant(self: *Parser, atom_in: i32) i32 {
        var atom = atom_in;
        while (self.more()) {
            const q = self.peek();
            var nd: i32 = -1;
            if (q == '*') {
                self.p += 1;
                nd = self.make(.star);
            } else if (q == '+') {
                self.p += 1;
                nd = self.make(.plus);
            } else if (q == '?') {
                self.p += 1;
                nd = self.make(.quest);
            } else if (q == '{') {
                var lo: i32 = undefined;
                var hi: i32 = undefined;
                if (!self.parseBrace(&lo, &hi)) break;
                nd = self.make(.repeat);
                self.nodes.items[@intCast(nd)].lo = lo;
                self.nodes.items[@intCast(nd)].hi = hi;
            } else {
                break;
            }
            self.nodes.items[@intCast(nd)].kids.append(self.gpa, atom) catch @panic("OOM");
            self.nodes.items[@intCast(nd)].greedy = true;
            if (self.peek() == '?') {
                self.p += 1;
                self.nodes.items[@intCast(nd)].greedy = false;
            }
            atom = nd;
        }
        return atom;
    }

    fn parseRepeat(self: *Parser) i32 {
        return self.wrapQuant(self.parseAtom());
    }

    fn parseConcat(self: *Parser) i32 {
        var kids: std.ArrayListUnmanaged(i32) = .empty;
        while (self.more() and self.p[0] != '|' and self.p[0] != ')') {
            kids.append(self.gpa, self.parseRepeat()) catch @panic("OOM");
        }
        if (kids.items.len == 0) {
            kids.deinit(self.gpa);
            return self.make(.empty);
        }
        if (kids.items.len == 1) {
            const only = kids.items[0];
            kids.deinit(self.gpa);
            return only;
        }
        const nd = self.make(.concat);
        self.nodes.items[@intCast(nd)].kids = kids;
        return nd;
    }

    fn parseAlt(self: *Parser) i32 {
        const left = self.parseConcat();
        if (self.peek() != '|') return left;
        var kids: std.ArrayListUnmanaged(i32) = .empty;
        kids.append(self.gpa, left) catch @panic("OOM");
        while (self.peek() == '|') {
            self.p += 1;
            kids.append(self.gpa, self.parseConcat()) catch @panic("OOM");
        }
        const nd = self.make(.alt);
        self.nodes.items[@intCast(nd)].kids = kids;
        return nd;
    }

    /// grep -F: the entire remaining pattern is a literal byte string, no
    /// metacharacter/escape interpretation at all.
    fn parseLiteralAll(self: *Parser) i32 {
        var kids: std.ArrayListUnmanaged(i32) = .empty;
        while (self.more()) {
            const nd = self.make(.lit);
            self.nodes.items[@intCast(nd)].ch = @as(i32, self.p[0]);
            self.p += 1;
            kids.append(self.gpa, nd) catch @panic("OOM");
        }
        if (kids.items.len == 0) {
            kids.deinit(self.gpa);
            return self.make(.empty);
        }
        if (kids.items.len == 1) {
            const only = kids.items[0];
            kids.deinit(self.gpa);
            return only;
        }
        const nd = self.make(.concat);
        self.nodes.items[@intCast(nd)].kids = kids;
        return nd;
    }
};

// ============================================================================ AST -> bytecode

const Emitter = struct {
    gpa: Allocator,
    prog: *Prog,
    nodes: []const Node,
    err: ?[]const u8 = null,

    fn emitInst(self: *Emitter, op: Op) i32 {
        self.prog.insts.append(self.gpa, Inst{ .op = op }) catch @panic("OOM");
        if (self.prog.insts.items.len > 200000 and self.err == null) self.err = "pattern too large";
        return @intCast(self.prog.insts.items.len - 1);
    }

    fn emitStar(self: *Emitter, child: i32, greedy: bool) void {
        const l1 = self.emitInst(.split);
        const body: i32 = @intCast(self.prog.insts.items.len);
        self.emit(child);
        const j = self.emitInst(.jmp);
        self.prog.insts.items[@intCast(j)].x = l1;
        const out: i32 = @intCast(self.prog.insts.items.len);
        self.prog.insts.items[@intCast(l1)].x = if (greedy) body else out;
        self.prog.insts.items[@intCast(l1)].y = if (greedy) out else body;
    }
    fn emitPlus(self: *Emitter, child: i32, greedy: bool) void {
        const body: i32 = @intCast(self.prog.insts.items.len);
        self.emit(child);
        const l = self.emitInst(.split);
        const out: i32 = @intCast(self.prog.insts.items.len);
        self.prog.insts.items[@intCast(l)].x = if (greedy) body else out;
        self.prog.insts.items[@intCast(l)].y = if (greedy) out else body;
    }
    fn emitQuest(self: *Emitter, child: i32, greedy: bool) void {
        const sp = self.emitInst(.split);
        const body: i32 = @intCast(self.prog.insts.items.len);
        self.emit(child);
        const out: i32 = @intCast(self.prog.insts.items.len);
        self.prog.insts.items[@intCast(sp)].x = if (greedy) body else out;
        self.prog.insts.items[@intCast(sp)].y = if (greedy) out else body;
    }

    fn emit(self: *Emitter, idx: i32) void {
        if (self.err != null) return;
        const nd = &self.nodes[@intCast(idx)];
        switch (nd.tag) {
            .empty => {},
            .lit => {
                const i = self.emitInst(.char);
                self.prog.insts.items[@intCast(i)].ch = @intCast(nd.ch & 0xff);
            },
            .any => _ = self.emitInst(.any),
            .class => {
                const i = self.emitInst(.class);
                self.prog.insts.items[@intCast(i)].cls = nd.cls;
            },
            .bol => _ = self.emitInst(.bol),
            .eol => _ = self.emitInst(.eol),
            .wordb => _ = self.emitInst(.wordb),
            .nwordb => _ = self.emitInst(.nwordb),
            .concat => for (nd.kids.items) |k| self.emit(k),
            .group => {
                const cap = nd.cap;
                if (cap >= 0) {
                    const s = self.emitInst(.save);
                    self.prog.insts.items[@intCast(s)].n = cap * 2;
                }
                self.emit(nd.kids.items[0]);
                if (cap >= 0) {
                    const s = self.emitInst(.save);
                    self.prog.insts.items[@intCast(s)].n = cap * 2 + 1;
                }
            },
            .alt => self.emitAlt(idx, 0),
            .star => self.emitStar(nd.kids.items[0], nd.greedy),
            .plus => self.emitPlus(nd.kids.items[0], nd.greedy),
            .quest => self.emitQuest(nd.kids.items[0], nd.greedy),
            .repeat => {
                const lo = nd.lo;
                const hi = nd.hi;
                if (lo > 1000 or hi > 1000) {
                    self.err = "repeat count too large";
                    return;
                }
                const child = nd.kids.items[0];
                const greedy = nd.greedy;
                var k: i32 = 0;
                while (k < lo) : (k += 1) self.emit(child);
                if (hi < 0) {
                    self.emitStar(child, greedy);
                } else {
                    k = lo;
                    while (k < hi) : (k += 1) self.emitQuest(child, greedy);
                }
            },
        }
    }

    fn emitAlt(self: *Emitter, parent: i32, i: usize) void {
        const kids = self.nodes[@intCast(parent)].kids.items;
        if (i + 1 == kids.len) {
            self.emit(kids[i]);
            return;
        }
        const sp = self.emitInst(.split);
        self.prog.insts.items[@intCast(sp)].x = @intCast(self.prog.insts.items.len);
        self.emit(kids[i]);
        const j = self.emitInst(.jmp);
        self.prog.insts.items[@intCast(sp)].y = @intCast(self.prog.insts.items.len);
        self.emitAlt(parent, i + 1);
        self.prog.insts.items[@intCast(j)].x = @intCast(self.prog.insts.items.len);
    }
};

// ============================================================================ Pike-VM executor

const Thread = struct {
    pc: i32,
    saves: []i32, // owned, length == prog.nsaves
};

const VM = struct {
    gpa: Allocator,
    prog: *const Prog,
    in: [*]const u8,
    len: i32,
    seen: []i32,
    gen: i32 = 0,

    fn dupSaves(self: *VM, saves: []const i32) []i32 {
        const s = self.gpa.alloc(i32, saves.len) catch @panic("OOM");
        @memcpy(s, saves);
        return s;
    }
    fn initSaves(self: *VM, n: usize) []i32 {
        const s = self.gpa.alloc(i32, n) catch @panic("OOM");
        @memset(s, -1);
        return s;
    }

    /// Follows epsilon transitions, recording real (consuming/match) threads into
    /// `list`. Takes ownership of `saves`. The `seen[pc] == gen` guard is the
    /// empty-loop breaker: a pattern like `(a?)*` revisits the same split/save
    /// instructions at a given input position, and the guard collapses that into a
    /// single visit instead of recursing forever.
    fn addThread(self: *VM, list: *std.ArrayListUnmanaged(Thread), pc: i32, saves: []i32, sp: i32) void {
        if (self.seen[@intCast(pc)] == self.gen) {
            self.gpa.free(saves);
            return;
        }
        self.seen[@intCast(pc)] = self.gen;
        const I = &self.prog.insts.items[@intCast(pc)];
        switch (I.op) {
            .jmp => self.addThread(list, I.x, saves, sp),
            .split => {
                const d = self.dupSaves(saves);
                self.addThread(list, I.x, d, sp);
                self.addThread(list, I.y, saves, sp);
            },
            .save => {
                const s2 = self.dupSaves(saves);
                if (I.n < @as(i32, @intCast(s2.len))) s2[@intCast(I.n)] = sp;
                self.gpa.free(saves);
                self.addThread(list, pc + 1, s2, sp);
            },
            .bol => {
                if (sp == 0 or (self.prog.multiline and sp > 0 and self.in[@intCast(sp - 1)] == '\n'))
                    self.addThread(list, pc + 1, saves, sp)
                else
                    self.gpa.free(saves);
            },
            .eol => {
                if (sp == self.len or (self.prog.multiline and self.in[@intCast(sp)] == '\n'))
                    self.addThread(list, pc + 1, saves, sp)
                else
                    self.gpa.free(saves);
            },
            .wordb, .nwordb => {
                const before = sp > 0 and isWordByte(self.in[@intCast(sp - 1)]);
                const after = sp < self.len and isWordByte(self.in[@intCast(sp)]);
                const boundary = before != after;
                const ok = if (I.op == .wordb) boundary else !boundary;
                if (ok) self.addThread(list, pc + 1, saves, sp) else self.gpa.free(saves);
            },
            else => list.append(self.gpa, Thread{ .pc = pc, .saves = saves }) catch @panic("OOM"),
        }
    }

    fn freeList(self: *VM, list: *std.ArrayListUnmanaged(Thread)) void {
        for (list.items) |t| self.gpa.free(t.saves);
        list.clearRetainingCapacity();
    }
};

/// Leftmost match at or after `start`; fills `out` (length `prog.nsaves`). `seen` is
/// reused scratch sized `prog.insts.items.len`.
fn execFrom(gpa: Allocator, prog: *const Prog, in: [*]const u8, len: i32, start: i32, out: []i32, seen: []i32) bool {
    @memset(seen, -1);
    var clist: std.ArrayListUnmanaged(Thread) = .empty;
    var nlist: std.ArrayListUnmanaged(Thread) = .empty;
    var vm = VM{ .gpa = gpa, .prog = prog, .in = in, .len = len, .seen = seen };
    defer {
        vm.freeList(&clist);
        vm.freeList(&nlist);
        clist.deinit(gpa);
        nlist.deinit(gpa);
    }

    const nsaves: usize = @intCast(prog.nsaves);
    var matched = false;

    vm.gen += 1;
    vm.addThread(&clist, 0, vm.initSaves(nsaves), start);

    var sp = start;
    while (true) : (sp += 1) {
        if (clist.items.len == 0 and matched) break;
        const ch: i32 = if (sp < len) @as(i32, in[@intCast(sp)]) else -1;
        vm.gen += 1;
        vm.freeList(&nlist);
        var ti: usize = 0;
        while (ti < clist.items.len) : (ti += 1) {
            const t = clist.items[ti];
            const I = &prog.insts.items[@intCast(t.pc)];
            var cut = false;
            switch (I.op) {
                .char => {
                    if (ch >= 0) {
                        var a = ch;
                        var b: i32 = @as(i32, I.ch);
                        if (prog.icase) {
                            a = lowerAscii(a);
                            b = lowerAscii(b);
                        }
                        if (a == b) vm.addThread(&nlist, t.pc + 1, vm.dupSaves(t.saves), sp + 1);
                    }
                },
                .any => {
                    if (ch >= 0 and (prog.dotall or ch != '\n')) vm.addThread(&nlist, t.pc + 1, vm.dupSaves(t.saves), sp + 1);
                },
                .class => {
                    if (ch >= 0 and classMatch(&prog.classes.items[@intCast(I.cls)], @intCast(ch), prog.icase))
                        vm.addThread(&nlist, t.pc + 1, vm.dupSaves(t.saves), sp + 1);
                },
                .match => {
                    @memcpy(out, t.saves);
                    matched = true;
                    cut = true; // lower-priority threads at this step lose (leftmost-longest-by-priority)
                },
                else => {},
            }
            if (cut) break;
        }
        // Unanchored search: seed a fresh start at the next position (lowest
        // priority) until a match is found, so the leftmost start wins.
        if (!matched and sp < len) vm.addThread(&nlist, 0, vm.initSaves(nsaves), sp + 1);
        const tmp = clist;
        clist = nlist;
        nlist = tmp;
        if (sp >= len) break;
    }
    return matched;
}

// ============================================================================ public API

pub const Regex = struct {
    gpa: Allocator,
    prog: Prog,
    sv_scratch: []i32, // length prog.nsaves, reused across find/captures/isMatch calls
    seen_scratch: []i32, // length prog.insts.items.len

    pub fn deinit(self: *Regex) void {
        self.gpa.free(self.sv_scratch);
        self.gpa.free(self.seen_scratch);
        self.prog.deinit(self.gpa);
    }

    pub fn groupCount(self: *const Regex) usize {
        return @intCast(@divTrunc(self.prog.nsaves, 2) - 1);
    }

    /// Leftmost match at or after byte offset `start`, or `null`.
    pub fn find(self: *Regex, hay: []const u8, start: usize) ?Span {
        if (start > hay.len) return null;
        const matched = execFrom(self.gpa, &self.prog, hay.ptr, @intCast(hay.len), @intCast(start), self.sv_scratch, self.seen_scratch);
        if (!matched) return null;
        return .{ .start = @intCast(self.sv_scratch[0]), .end = @intCast(self.sv_scratch[1]) };
    }

    pub fn isMatch(self: *Regex, hay: []const u8) bool {
        return self.find(hay, 0) != null;
    }

    /// Like `find`, but also fills `slots[0..min(slots.len, groupCount())]` with each
    /// capture group's span (`null` if that group didn't participate in the match).
    pub fn captures(self: *Regex, hay: []const u8, start: usize, slots: []?Span) ?Span {
        const m = self.find(hay, start) orelse return null;
        const ng = @min(slots.len, self.groupCount());
        for (0..ng) |g| {
            const a = self.sv_scratch[(g + 1) * 2];
            const b = self.sv_scratch[(g + 1) * 2 + 1];
            slots[g] = if (a >= 0 and b >= 0) Span{ .start = @intCast(a), .end = @intCast(b) } else null;
        }
        return m;
    }
};

/// Frees every node's owned `kids` list, then the node array itself. `Node` values are
/// plain structs copied around by index (never moved after `Parser.make` allocates
/// them), so this is safe to run once, after the emitter is done reading `nodes.items`.
fn freeNodes(nodes: *std.ArrayListUnmanaged(Node), gpa: Allocator) void {
    for (nodes.items) |*n| n.kids.deinit(gpa);
    nodes.deinit(gpa);
}

fn finishCompile(gpa: Allocator, prog: *Prog, parser: *Parser, root: i32, diag: *Diag) CompileError!Regex {
    if (parser.p != parser.end and parser.err == null) {
        parser.err = "trailing characters (unbalanced ')'?)";
    }
    if (parser.err) |e| {
        diag.msg = e;
        freeNodes(&parser.nodes, gpa);
        prog.deinit(gpa);
        return error.InvalidPattern;
    }
    prog.nsaves = 2 * (parser.ngroups + 1);
    var em = Emitter{ .gpa = gpa, .prog = prog, .nodes = parser.nodes.items };
    const s0 = em.emitInst(.save);
    prog.insts.items[@intCast(s0)].n = 0;
    em.emit(root);
    const s1 = em.emitInst(.save);
    prog.insts.items[@intCast(s1)].n = 1;
    _ = em.emitInst(.match);
    freeNodes(&parser.nodes, gpa);
    if (em.err) |e| {
        diag.msg = e;
        prog.deinit(gpa);
        return error.InvalidPattern;
    }
    const sv = gpa.alloc(i32, @intCast(prog.nsaves)) catch @panic("OOM");
    const seen = gpa.alloc(i32, prog.insts.items.len) catch @panic("OOM");
    return Regex{ .gpa = gpa, .prog = prog.*, .sv_scratch = sv, .seen_scratch = seen };
}

/// Compiles `pattern` under `opts`. On `error.InvalidPattern`, `diag.msg` explains why
/// (`grep: invalid pattern: {diag.msg}`).
pub fn compile(gpa: Allocator, pattern: []const u8, opts: Options, diag: *Diag) CompileError!Regex {
    return compileMulti(gpa, &.{pattern}, opts, diag);
}

/// Compiles the alternation `(?:patterns[0])|(?:patterns[1])|...` -- built at the AST
/// level (one shared `Parser`/node arena, each pattern parsed independently and then
/// wrapped in one top-level `.alt` node) so a `|` inside an individual pattern keeps
/// its own precedence. Used by grep's repeated `-e PATTERN`.
pub fn compileMulti(gpa: Allocator, patterns: []const []const u8, opts: Options, diag: *Diag) CompileError!Regex {
    var prog = Prog{
        .icase = opts.case_insensitive,
        .dotall = opts.dot_all,
        .multiline = opts.multiline,
    };
    var parser = Parser{ .gpa = gpa, .p = undefined, .end = undefined, .prog = &prog };

    if (patterns.len == 0) {
        const root = parser.make(.empty);
        return finishCompile(gpa, &prog, &parser, root, diag);
    }

    var roots: std.ArrayListUnmanaged(i32) = .empty;
    for (patterns) |pat| {
        parser.p = pat.ptr;
        parser.end = pat.ptr + pat.len;
        const root = if (opts.literal) parser.parseLiteralAll() else parser.parseAlt();
        if (parser.p != parser.end and parser.err == null) {
            parser.err = "trailing characters (unbalanced ')'?)";
        }
        if (parser.err != null) {
            roots.deinit(gpa);
            return finishCompile(gpa, &prog, &parser, root, diag);
        }
        roots.append(gpa, root) catch @panic("OOM");
    }
    const combined_root: i32 = if (roots.items.len == 1) blk: {
        const only = roots.items[0];
        roots.deinit(gpa);
        break :blk only;
    } else blk: {
        const nd = parser.make(.alt);
        parser.nodes.items[@intCast(nd)].kids = roots;
        break :blk nd;
    };
    return finishCompile(gpa, &prog, &parser, combined_root, diag);
}
