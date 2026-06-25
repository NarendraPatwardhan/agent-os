//! re.zig — the `re` battery (was loom/src/re_bindings.cpp; the C++ → Zig rewrite). Real (PCRE-ish)
//! regular expressions: a Pike-VM NFA (Thompson construction + a thread list with submatch slots),
//! linear time in the input — NO catastrophic backtracking. Leftmost, greedy-by-default semantics;
//! lazy quantifiers via thread priority. A compiled regex is its own userdata type (mc.re.regex).
//!
//! Supported: literals, `.`, `\d \D \w \W \s \S` and in-class forms, classes `[...]`/`[^...]` with
//! ranges, anchors `^ $`, groups `(...)`/`(?:...)`, alternation `|`, quantifiers `* + ? {m} {m,}
//! {m,n}` (greedy + lazy), flags `i`/`s`/`m`. Not supported: backreferences and `\b`.
//!
//! Contract: a bad pattern is an expected failure → `re.compile` returns `nil, message`. Misuse
//! (wrong arg type) raises. See third_party/luau/SYSTEM.md (SYSTEMS.md section 10.3).

const std = @import("std");
const lua = @import("lua.zig");
const c = lua.c;
const State = lua.State;

const alloc = std.heap.c_allocator;

// ── compiled program ────────────────────────────────────────────────────────

const Op = enum(u8) {
    I_CHAR,
    I_ANY,
    I_CLASS,
    I_MATCH,
    I_JMP,
    I_SPLIT,
    I_SAVE,
    I_BOL,
    I_EOL,
};

const Inst = struct {
    op: Op,
    x: i32 = 0, // jump targets (JMP uses x; SPLIT uses x then y, x = higher priority)
    y: i32 = 0,
    ch: u8 = 0,
    cls: i32 = 0, // index into Prog.classes
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

const Prog = struct {
    insts: std.ArrayList(Inst) = .empty,
    classes: std.ArrayList(CharClass) = .empty,
    nsaves: i32 = 2,
    icase: bool = false,
    dotall: bool = false,
    multiline: bool = false,

    fn deinit(self: *Prog) void {
        self.insts.deinit(alloc);
        self.classes.deinit(alloc);
    }
};

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
        if (alt != ch)
            in = cc.has(alt);
    }
    return if (cc.negate) !in else in;
}

// ── parser → AST ────────────────────────────────────────────────────────────

const Tag = enum {
    N_LIT,
    N_ANY,
    N_CLASS,
    N_CONCAT,
    N_ALT,
    N_STAR,
    N_PLUS,
    N_QUEST,
    N_REPEAT,
    N_GROUP,
    N_BOL,
    N_EOL,
    N_EMPTY,
};

const Node = struct {
    tag: Tag,
    ch: i32 = 0,
    cls: i32 = -1,
    cap: i32 = -1,
    lo: i32 = 0,
    hi: i32 = 0,
    greedy: bool = true,
    kids: std.ArrayList(i32) = .empty,
};

// Shorthand kind: 0 means "not a shorthand".
const Escape = struct {
    value: i32, // literal byte (>=0) when shorthand==0
    shorthand: u8, // 'd'/'w'/'s' or 0
    neg: bool,
};

const Parser = struct {
    p: [*]const u8,
    end: [*]const u8,
    prog: *Prog,
    nodes: std.ArrayList(Node) = .empty,
    ngroups: i32 = 0,
    err: ?[*:0]const u8 = null,
    oom: bool = false,

    fn make(self: *Parser, t: Tag) i32 {
        self.nodes.append(alloc, Node{ .tag = t }) catch {
            self.oom = true;
            return 0;
        };
        return @intCast(self.nodes.items.len - 1);
    }
    fn more(self: *const Parser) bool {
        return @intFromPtr(self.p) < @intFromPtr(self.end);
    }
    fn peek(self: *const Parser) u8 {
        return if (self.more()) self.p[0] else 0;
    }

    // Build a shorthand set (\d \w \s) into `cc`; `neg` adds the complement.
    fn addShorthand(cc: *CharClass, kind: u8, neg: bool) void {
        var tmp = CharClass{};
        switch (kind) {
            'd' => {
                var ch: u32 = '0';
                while (ch <= '9') : (ch += 1) tmp.add(ch);
            },
            'w' => {
                var ch: u32 = '0';
                while (ch <= '9') : (ch += 1) tmp.add(ch);
                ch = 'a';
                while (ch <= 'z') : (ch += 1) tmp.add(ch);
                ch = 'A';
                while (ch <= 'Z') : (ch += 1) tmp.add(ch);
                tmp.add('_');
            },
            's' => {
                tmp.add(' ');
                tmp.add('\t');
                tmp.add('\n');
                tmp.add('\r');
                tmp.add(12); // \f
                tmp.add(11); // \v
            },
            else => {},
        }
        var ch: u32 = 0;
        while (ch < 256) : (ch += 1) {
            const member = tmp.has(ch);
            if (if (neg) !member else member)
                cc.add(ch);
        }
    }

    // Translate an escape char into either a literal byte (value >=0, shorthand 0)
    // or a shorthand kind ('d'/'w'/'s' with neg, value -1).
    fn escapeChar(e: u8) Escape {
        return switch (e) {
            'n' => .{ .value = '\n', .shorthand = 0, .neg = false },
            't' => .{ .value = '\t', .shorthand = 0, .neg = false },
            'r' => .{ .value = '\r', .shorthand = 0, .neg = false },
            'f' => .{ .value = 12, .shorthand = 0, .neg = false },
            'v' => .{ .value = 11, .shorthand = 0, .neg = false },
            '0' => .{ .value = 0, .shorthand = 0, .neg = false },
            'd' => .{ .value = -1, .shorthand = 'd', .neg = false },
            'w' => .{ .value = -1, .shorthand = 'w', .neg = false },
            's' => .{ .value = -1, .shorthand = 's', .neg = false },
            'D' => .{ .value = -1, .shorthand = 'd', .neg = true },
            'W' => .{ .value = -1, .shorthand = 'w', .neg = true },
            'S' => .{ .value = -1, .shorthand = 's', .neg = true },
            else => .{ .value = @as(i32, e), .shorthand = 0, .neg = false }, // escaped literal
        };
    }

    fn pushClass(self: *Parser, cc: CharClass) i32 {
        const idx: i32 = @intCast(self.prog.classes.items.len);
        self.prog.classes.append(alloc, cc) catch {
            self.oom = true;
            return 0;
        };
        const nd = self.make(Tag.N_CLASS);
        self.nodes.items[@intCast(nd)].cls = idx;
        return nd;
    }

    // Parse a `[...]` body (cursor just past '['), append a class, return its node.
    fn parseClass(self: *Parser) i32 {
        var cc = CharClass{};
        if (self.peek() == '^') {
            cc.negate = true;
            self.p += 1;
        }
        var first = true;
        while (self.more() and (self.p[0] != ']' or first)) {
            first = false;
            var lo: i32 = undefined;
            if (self.p[0] == '\\' and @intFromPtr(self.p + 1) < @intFromPtr(self.end)) {
                self.p += 1;
                const e = self.p[0];
                self.p += 1;
                const esc = escapeChar(e);
                if (esc.shorthand != 0) {
                    addShorthand(&cc, esc.shorthand, esc.neg);
                    continue;
                }
                lo = esc.value;
            } else {
                lo = @as(i32, self.p[0]);
                self.p += 1;
            }
            // a range  lo-hi  (but not a trailing '-')
            if (self.more() and self.p[0] == '-' and
                @intFromPtr(self.p + 1) < @intFromPtr(self.end) and self.p[1] != ']')
            {
                self.p += 1; // consume '-'
                var hi: i32 = undefined;
                if (self.p[0] == '\\' and @intFromPtr(self.p + 1) < @intFromPtr(self.end)) {
                    self.p += 1;
                    const e = self.p[0];
                    self.p += 1;
                    const esc = escapeChar(e);
                    hi = if (esc.shorthand != 0) lo else esc.value; // shorthand can't end a range; degrade
                } else {
                    hi = @as(i32, self.p[0]);
                    self.p += 1;
                }
                var ch = lo;
                while (ch <= hi) : (ch += 1)
                    cc.add(@intCast(ch));
            } else {
                cc.add(@intCast(lo));
            }
        }
        if (self.peek() == ']')
            self.p += 1
        else
            self.err = "re: unterminated character class";
        return self.pushClass(cc);
    }

    fn singleShorthandNode(self: *Parser, sh: u8, neg: bool) i32 {
        var cc = CharClass{};
        cc.negate = false;
        addShorthand(&cc, sh, neg);
        return self.pushClass(cc);
    }

    fn parseAtom(self: *Parser) i32 {
        const ch = self.p[0];
        self.p += 1;
        if (ch == '(') {
            var cap: i32 = -1;
            if (@intFromPtr(self.p + 1) < @intFromPtr(self.end) and self.p[0] == '?' and self.p[1] == ':') {
                self.p += 2; // non-capturing
            } else {
                self.ngroups += 1;
                cap = self.ngroups;
            }
            const child = self.parseAlt();
            if (self.peek() == ')')
                self.p += 1
            else
                self.err = "re: unbalanced '('";
            const nd = self.make(Tag.N_GROUP);
            self.nodes.items[@intCast(nd)].cap = cap;
            self.nodes.items[@intCast(nd)].kids.append(alloc, child) catch {
                self.oom = true;
            };
            return nd;
        }
        if (ch == '[')
            return self.parseClass();
        if (ch == '.')
            return self.make(Tag.N_ANY);
        if (ch == '^')
            return self.make(Tag.N_BOL);
        if (ch == '$')
            return self.make(Tag.N_EOL);
        if (ch == '\\' and self.more()) {
            const e = self.p[0];
            self.p += 1;
            const esc = escapeChar(e);
            if (esc.shorthand != 0)
                return self.singleShorthandNode(esc.shorthand, esc.neg);
            const nd = self.make(Tag.N_LIT);
            self.nodes.items[@intCast(nd)].ch = esc.value;
            return nd;
        }
        const nd = self.make(Tag.N_LIT);
        self.nodes.items[@intCast(nd)].ch = @as(i32, ch);
        return nd;
    }

    // Try to parse a `{m}` / `{m,}` / `{m,n}` quantifier; advance only on success.
    fn parseBrace(self: *Parser, lo: *i32, hi: *i32) bool {
        const save = self.p;
        if (self.peek() != '{')
            return false;
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
                nd = self.make(Tag.N_STAR);
            } else if (q == '+') {
                self.p += 1;
                nd = self.make(Tag.N_PLUS);
            } else if (q == '?') {
                self.p += 1;
                nd = self.make(Tag.N_QUEST);
            } else if (q == '{') {
                var lo: i32 = undefined;
                var hi: i32 = undefined;
                if (!self.parseBrace(&lo, &hi))
                    break;
                nd = self.make(Tag.N_REPEAT);
                self.nodes.items[@intCast(nd)].lo = lo;
                self.nodes.items[@intCast(nd)].hi = hi;
            } else {
                break;
            }
            self.nodes.items[@intCast(nd)].kids.append(alloc, atom) catch {
                self.oom = true;
            };
            self.nodes.items[@intCast(nd)].greedy = true;
            if (self.peek() == '?') { // lazy
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
        var kids: std.ArrayList(i32) = .empty;
        while (self.more() and self.p[0] != '|' and self.p[0] != ')') {
            kids.append(alloc, self.parseRepeat()) catch {
                self.oom = true;
            };
        }
        if (kids.items.len == 0) {
            kids.deinit(alloc);
            return self.make(Tag.N_EMPTY);
        }
        if (kids.items.len == 1) {
            const only = kids.items[0];
            kids.deinit(alloc);
            return only;
        }
        const nd = self.make(Tag.N_CONCAT);
        self.nodes.items[@intCast(nd)].kids = kids;
        return nd;
    }

    fn parseAlt(self: *Parser) i32 {
        const left = self.parseConcat();
        if (self.peek() != '|')
            return left;
        var kids: std.ArrayList(i32) = .empty;
        kids.append(alloc, left) catch {
            self.oom = true;
        };
        while (self.peek() == '|') {
            self.p += 1;
            kids.append(alloc, self.parseConcat()) catch {
                self.oom = true;
            };
        }
        const nd = self.make(Tag.N_ALT);
        self.nodes.items[@intCast(nd)].kids = kids;
        return nd;
    }

    fn deinit(self: *Parser) void {
        for (self.nodes.items) |*nd|
            nd.kids.deinit(alloc);
        self.nodes.deinit(alloc);
    }
};

// ── AST → instructions ──────────────────────────────────────────────────────

const Emitter = struct {
    prog: *Prog,
    nodes: *std.ArrayList(Node),
    err: ?[*:0]const u8 = null,
    oom: bool = false,

    fn emitInst(self: *Emitter, op: Op) i32 {
        self.prog.insts.append(alloc, Inst{ .op = op }) catch {
            self.oom = true;
            return 0;
        };
        if (self.prog.insts.items.len > 200000)
            self.err = "re: pattern too large";
        return @intCast(self.prog.insts.items.len - 1);
    }

    fn emitStar(self: *Emitter, child: i32, greedy: bool) void {
        const l1 = self.emitInst(Op.I_SPLIT);
        const body: i32 = @intCast(self.prog.insts.items.len);
        self.emit(child);
        const j = self.emitInst(Op.I_JMP);
        self.prog.insts.items[@intCast(j)].x = l1;
        const out: i32 = @intCast(self.prog.insts.items.len);
        self.prog.insts.items[@intCast(l1)].x = if (greedy) body else out;
        self.prog.insts.items[@intCast(l1)].y = if (greedy) out else body;
    }
    fn emitPlus(self: *Emitter, child: i32, greedy: bool) void {
        const body: i32 = @intCast(self.prog.insts.items.len);
        self.emit(child);
        const l = self.emitInst(Op.I_SPLIT);
        const out: i32 = @intCast(self.prog.insts.items.len);
        self.prog.insts.items[@intCast(l)].x = if (greedy) body else out;
        self.prog.insts.items[@intCast(l)].y = if (greedy) out else body;
    }
    fn emitQuest(self: *Emitter, child: i32, greedy: bool) void {
        const sp = self.emitInst(Op.I_SPLIT);
        const body: i32 = @intCast(self.prog.insts.items.len);
        self.emit(child);
        const out: i32 = @intCast(self.prog.insts.items.len);
        self.prog.insts.items[@intCast(sp)].x = if (greedy) body else out;
        self.prog.insts.items[@intCast(sp)].y = if (greedy) out else body;
    }

    fn emit(self: *Emitter, idx: i32) void {
        if (self.err != null or self.oom)
            return;
        const tag = self.nodes.items[@intCast(idx)].tag;
        switch (tag) {
            .N_EMPTY => {},
            .N_LIT => {
                const i = self.emitInst(Op.I_CHAR);
                self.prog.insts.items[@intCast(i)].ch = @intCast(self.nodes.items[@intCast(idx)].ch & 0xff);
            },
            .N_ANY => {
                _ = self.emitInst(Op.I_ANY);
            },
            .N_CLASS => {
                const i = self.emitInst(Op.I_CLASS);
                self.prog.insts.items[@intCast(i)].cls = self.nodes.items[@intCast(idx)].cls;
            },
            .N_BOL => {
                _ = self.emitInst(Op.I_BOL);
            },
            .N_EOL => {
                _ = self.emitInst(Op.I_EOL);
            },
            .N_CONCAT => {
                // copy the kid list defensively: emit() pushes onto insts only, not nodes,
                // so the slice stays valid, but iterate over the stored items directly.
                const kids = self.nodes.items[@intCast(idx)].kids.items;
                for (kids) |k|
                    self.emit(k);
            },
            .N_GROUP => {
                const cap = self.nodes.items[@intCast(idx)].cap;
                if (cap >= 0) {
                    const s = self.emitInst(Op.I_SAVE);
                    self.prog.insts.items[@intCast(s)].n = cap * 2;
                }
                self.emit(self.nodes.items[@intCast(idx)].kids.items[0]);
                if (cap >= 0) {
                    const s = self.emitInst(Op.I_SAVE);
                    self.prog.insts.items[@intCast(s)].n = cap * 2 + 1;
                }
            },
            .N_ALT => {
                self.emitAlt(idx, 0);
            },
            .N_STAR => {
                self.emitStar(self.nodes.items[@intCast(idx)].kids.items[0], self.nodes.items[@intCast(idx)].greedy);
            },
            .N_PLUS => {
                self.emitPlus(self.nodes.items[@intCast(idx)].kids.items[0], self.nodes.items[@intCast(idx)].greedy);
            },
            .N_QUEST => {
                self.emitQuest(self.nodes.items[@intCast(idx)].kids.items[0], self.nodes.items[@intCast(idx)].greedy);
            },
            .N_REPEAT => {
                const lo = self.nodes.items[@intCast(idx)].lo;
                const hi = self.nodes.items[@intCast(idx)].hi;
                if (lo > 1000 or hi > 1000) {
                    self.err = "re: repeat count too large";
                    return;
                }
                const child = self.nodes.items[@intCast(idx)].kids.items[0];
                const greedy = self.nodes.items[@intCast(idx)].greedy;
                var k: i32 = 0;
                while (k < lo) : (k += 1)
                    self.emit(child);
                if (hi < 0) {
                    self.emitStar(child, greedy);
                } else {
                    k = lo;
                    while (k < hi) : (k += 1)
                        self.emitQuest(child, greedy);
                }
            },
        }
    }

    fn emitAlt(self: *Emitter, parent: i32, i: usize) void {
        const kids = self.nodes.items[@intCast(parent)].kids.items;
        if (i + 1 == kids.len) {
            self.emit(kids[i]);
            return;
        }
        const sp = self.emitInst(Op.I_SPLIT);
        self.prog.insts.items[@intCast(sp)].x = @intCast(self.prog.insts.items.len);
        self.emit(kids[i]);
        const j = self.emitInst(Op.I_JMP);
        self.prog.insts.items[@intCast(sp)].y = @intCast(self.prog.insts.items.len);
        self.emitAlt(parent, i + 1);
        self.prog.insts.items[@intCast(j)].x = @intCast(self.prog.insts.items.len);
    }
};

// Compile `pattern` with `flags` ("ims") into a Prog, or set err.* / return null.
fn compile(pat: [*]const u8, patlen: usize, flags: ?[*:0]const u8, err: *?[*:0]const u8) ?*Prog {
    const prog = alloc.create(Prog) catch {
        err.* = "re: out of memory";
        return null;
    };
    prog.* = Prog{};
    if (flags) |f| {
        var i: usize = 0;
        while (f[i] != 0) : (i += 1) {
            switch (f[i]) {
                'i' => prog.icase = true,
                's' => prog.dotall = true,
                'm' => prog.multiline = true,
                else => {},
            }
        }
    }
    var ps = Parser{ .p = pat, .end = pat + patlen, .prog = prog };
    const root = ps.parseAlt();
    if (@intFromPtr(ps.p) != @intFromPtr(ps.end) and ps.err == null)
        ps.err = "re: trailing characters (unbalanced ')'?)";
    if (ps.oom and ps.err == null)
        ps.err = "re: out of memory";
    if (ps.err) |e| {
        err.* = e;
        ps.deinit();
        prog.deinit();
        alloc.destroy(prog);
        return null;
    }
    prog.nsaves = 2 * (ps.ngroups + 1);
    var em = Emitter{ .prog = prog, .nodes = &ps.nodes };
    const s0 = em.emitInst(Op.I_SAVE);
    prog.insts.items[@intCast(s0)].n = 0;
    em.emit(root);
    const s1 = em.emitInst(Op.I_SAVE);
    prog.insts.items[@intCast(s1)].n = 1;
    _ = em.emitInst(Op.I_MATCH);
    if (em.oom and em.err == null)
        em.err = "re: out of memory";
    if (em.err) |e| {
        err.* = e;
        ps.deinit();
        prog.deinit();
        alloc.destroy(prog);
        return null;
    }
    ps.deinit();
    return prog;
}

// ── Pike-VM executor ────────────────────────────────────────────────────────

const Thread = struct {
    pc: i32,
    saves: []i32, // owned slice, length == prog.nsaves
};

const VM = struct {
    prog: *const Prog,
    in: [*]const u8,
    len: i32,
    seen: []i32,
    gen: i32 = 0,
    oom: bool = false, // an allocation failed mid-match → abort the run; the binding raises a Lua error

    // Both return null on OOM (setting .oom) — they never trap. A Pike-VM exists to run untrusted,
    // model-authored patterns safely; a resource limit must surface as a catchable error, not a crash.
    fn dupSaves(self: *VM, saves: []const i32) ?[]i32 {
        const s = alloc.alloc(i32, saves.len) catch {
            self.oom = true;
            return null;
        };
        @memcpy(s, saves);
        return s;
    }

    // A fresh saves slice filled with -1.
    fn initSaves(self: *VM, n: usize) ?[]i32 {
        const s = alloc.alloc(i32, n) catch {
            self.oom = true;
            return null;
        };
        @memset(s, -1);
        return s;
    }

    // Follow ε-transitions, recording threads into `list`. Takes ownership of `saves`.
    fn addThread(self: *VM, list: *std.ArrayList(Thread), pc: i32, saves: []i32, sp: i32) void {
        if (self.seen[@intCast(pc)] == self.gen) {
            alloc.free(saves);
            return;
        }
        self.seen[@intCast(pc)] = self.gen;
        const I = &self.prog.insts.items[@intCast(pc)];
        switch (I.op) {
            .I_JMP => {
                self.addThread(list, I.x, saves, sp);
            },
            .I_SPLIT => {
                if (self.dupSaves(saves)) |d|
                    self.addThread(list, I.x, d, sp); // (on OOM self.oom is set; saves still feeds y)
                self.addThread(list, I.y, saves, sp);
            },
            .I_SAVE => {
                if (self.dupSaves(saves)) |s2| {
                    if (I.n < @as(i32, @intCast(s2.len)))
                        s2[@intCast(I.n)] = sp;
                    alloc.free(saves);
                    self.addThread(list, pc + 1, s2, sp);
                } else {
                    alloc.free(saves); // OOM: drop this thread, the run aborts
                }
            },
            .I_BOL => {
                if (sp == 0 or (self.prog.multiline and sp > 0 and self.in[@intCast(sp - 1)] == '\n'))
                    self.addThread(list, pc + 1, saves, sp)
                else
                    alloc.free(saves);
            },
            .I_EOL => {
                if (sp == self.len or (self.prog.multiline and self.in[@intCast(sp)] == '\n'))
                    self.addThread(list, pc + 1, saves, sp)
                else
                    alloc.free(saves);
            },
            else => {
                list.append(alloc, Thread{ .pc = pc, .saves = saves }) catch {
                    self.oom = true;
                    alloc.free(saves);
                };
            },
        }
    }

    fn freeList(list: *std.ArrayList(Thread)) void {
        for (list.items) |t|
            alloc.free(t.saves);
        list.clearRetainingCapacity();
    }
};

// Search for the leftmost match at or after `start`; fill `out` (size nsaves).
// Returns true on a match (and out is populated); false otherwise.
fn run(prog: *const Prog, in: [*]const u8, len: i32, start: i32, out: []i32, oom: *bool) bool {
    const npc = prog.insts.items.len;
    const seen = alloc.alloc(i32, npc) catch {
        oom.* = true;
        return false;
    };
    defer alloc.free(seen);
    @memset(seen, -1);

    var clist: std.ArrayList(Thread) = .empty;
    var nlist: std.ArrayList(Thread) = .empty;
    defer {
        VM.freeList(&clist);
        VM.freeList(&nlist);
        clist.deinit(alloc);
        nlist.deinit(alloc);
    }

    var vm = VM{ .prog = prog, .in = in, .len = len, .seen = seen };

    const nsaves: usize = @intCast(prog.nsaves);
    var matched = false;

    vm.gen += 1;
    if (vm.initSaves(nsaves)) |s| vm.addThread(&clist, 0, s, start);

    var sp = start;
    while (true) : (sp += 1) {
        if (clist.items.len == 0 and matched)
            break;
        const ch: i32 = if (sp < len) @as(i32, in[@intCast(sp)]) else -1;
        vm.gen += 1;
        VM.freeList(&nlist);
        var ti: usize = 0;
        while (ti < clist.items.len) : (ti += 1) {
            const t = clist.items[ti];
            const I = &prog.insts.items[@intCast(t.pc)];
            var cut = false;
            switch (I.op) {
                .I_CHAR => {
                    if (ch >= 0) {
                        var a = ch;
                        var b: i32 = @as(i32, I.ch);
                        if (prog.icase) {
                            a = lowerAscii(a);
                            b = lowerAscii(b);
                        }
                        if (a == b)
                            if (vm.dupSaves(t.saves)) |s| vm.addThread(&nlist, t.pc + 1, s, sp + 1);
                    }
                },
                .I_ANY => {
                    if (ch >= 0 and (prog.dotall or ch != '\n'))
                        if (vm.dupSaves(t.saves)) |s| vm.addThread(&nlist, t.pc + 1, s, sp + 1);
                },
                .I_CLASS => {
                    if (ch >= 0 and classMatch(&prog.classes.items[@intCast(I.cls)], @intCast(ch), prog.icase))
                        if (vm.dupSaves(t.saves)) |s| vm.addThread(&nlist, t.pc + 1, s, sp + 1);
                },
                .I_MATCH => {
                    @memcpy(out, t.saves);
                    matched = true;
                    cut = true; // lower-priority threads at this step lose
                },
                else => {},
            }
            if (cut)
                break;
        }
        // Unanchored search: seed a fresh start at the next position (lowest priority)
        // until we have a match, so the leftmost start wins.
        if (!matched and sp < len)
            if (vm.initSaves(nsaves)) |s| vm.addThread(&nlist, 0, s, sp + 1);
        // swap clist <-> nlist; the old clist threads are freed next iter via freeList(nlist).
        const tmp = clist;
        clist = nlist;
        nlist = tmp;
        if (sp >= len)
            break;
    }
    if (vm.oom) oom.* = true;
    return matched;
}

// run() + raise a catchable Lua error on OOM (instead of returning a bogus no-match). All the
// bindings go through this, so a resource limit is always a `re: out of memory` error, never a trap.
fn runChecked(L: ?*State, prog: *const Prog, in: [*]const u8, len: i32, start: i32, out: []i32) bool {
    var oom = false;
    const matched = run(prog, in, len, start, out, &oom);
    if (oom) _ = c.luaL_errorL(L, "re: out of memory"); // raises (mc trap → pcall); does not return
    return matched;
}

// ── Lua glue ────────────────────────────────────────────────────────────────

const kMeta = "mc.re.regex";

fn reDtor(ud: ?*anyopaque) callconv(.c) void {
    const cell: *?*Prog = @ptrCast(@alignCast(ud.?));
    if (cell.*) |prog| {
        prog.deinit();
        alloc.destroy(prog);
        cell.* = null;
    }
}

fn checkRegex(L: ?*State, idx: c_int) *Prog {
    const ud = c.luaL_checkudata(L, idx, kMeta);
    const cell: *?*Prog = @ptrCast(@alignCast(ud));
    return cell.*.?;
}

fn pushRegex(L: ?*State, prog: *Prog) void {
    const ud = c.lua_newuserdatadtor(L, @sizeOf(?*Prog), reDtor);
    const cell: *?*Prog = @ptrCast(@alignCast(ud));
    cell.* = prog;
    _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, kMeta); // luaL_getmetatable
    _ = c.lua_setmetatable(L, -2);
}

// re.compile(pattern [, flags]) -> regex | nil, err
fn lCompile(L: ?*State) callconv(.c) c_int {
    var n: usize = 0;
    const pat = c.luaL_checklstring(L, 1, &n);
    const flags = c.luaL_optlstring(L, 2, "", null);
    var err: ?[*:0]const u8 = null;
    const prog = compile(pat, n, flags, &err);
    if (prog == null) {
        c.lua_pushnil(L);
        _ = c.lua_pushstring(L, err orelse "re: compile error");
        return 2;
    }
    pushRegex(L, prog.?);
    return 1;
}

// Build the match table { match, start, stop, groups = {...} } from saves.
fn pushMatch(L: ?*State, prog: *const Prog, s: [*]const u8, sv: []const i32) void {
    lua.newtable(L);
    const ms = sv[0];
    const me = sv[1];
    c.lua_pushlstring(L, s + @as(usize, @intCast(ms)), @intCast(me - ms));
    c.lua_setfield(L, -2, "match");
    c.lua_pushinteger(L, ms + 1); // 1-based start
    c.lua_setfield(L, -2, "start");
    c.lua_pushinteger(L, me); // 1-based inclusive stop (== exclusive end)
    c.lua_setfield(L, -2, "stop");
    lua.newtable(L); // groups
    const ng = @divTrunc(prog.nsaves, 2) - 1;
    var g: i32 = 1;
    while (g <= ng) : (g += 1) {
        const a = sv[@intCast(g * 2)];
        const b = sv[@intCast(g * 2 + 1)];
        if (a >= 0 and b >= 0)
            c.lua_pushlstring(L, s + @as(usize, @intCast(a)), @intCast(b - a))
        else
            c.lua_pushboolean(L, 0); // unset group → false
        c.lua_rawseti(L, -2, g);
    }
    c.lua_setfield(L, -2, "groups");
}

// rx:match(s [, init]) -> match table | nil
fn lMatch(L: ?*State) callconv(.c) c_int {
    const prog = checkRegex(L, 1);
    var n: usize = 0;
    const s = c.luaL_checklstring(L, 2, &n);
    var init = c.luaL_optinteger(L, 3, 1);
    if (init < 1)
        init = 1;
    if (init > @as(c_int, @intCast(n)) + 1) {
        c.lua_pushnil(L);
        return 1;
    }
    const sv = alloc.alloc(i32, @intCast(prog.nsaves)) catch {
        return c.luaL_errorL(L, "re: out of memory");
    };
    defer alloc.free(sv);
    if (!runChecked(L, prog, s, @intCast(n), init - 1, sv)) {
        c.lua_pushnil(L);
        return 1;
    }
    pushMatch(L, prog, s, sv);
    return 1;
}

// rx:find(s [, init]) -> start, stop | nil
fn lFind(L: ?*State) callconv(.c) c_int {
    const prog = checkRegex(L, 1);
    var n: usize = 0;
    const s = c.luaL_checklstring(L, 2, &n);
    var init = c.luaL_optinteger(L, 3, 1);
    if (init < 1)
        init = 1;
    const sv = alloc.alloc(i32, @intCast(prog.nsaves)) catch {
        return c.luaL_errorL(L, "re: out of memory");
    };
    defer alloc.free(sv);
    if (init > @as(c_int, @intCast(n)) + 1 or !runChecked(L, prog, s, @intCast(n), init - 1, sv)) {
        c.lua_pushnil(L);
        return 1;
    }
    c.lua_pushinteger(L, sv[0] + 1);
    c.lua_pushinteger(L, sv[1]);
    return 2;
}

// rx:test(s) -> bool
fn lTest(L: ?*State) callconv(.c) c_int {
    const prog = checkRegex(L, 1);
    var n: usize = 0;
    const s = c.luaL_checklstring(L, 2, &n);
    const sv = alloc.alloc(i32, @intCast(prog.nsaves)) catch {
        return c.luaL_errorL(L, "re: out of memory");
    };
    defer alloc.free(sv);
    c.lua_pushboolean(L, @intFromBool(runChecked(L, prog, s, @intCast(n), 0, sv)));
    return 1;
}

// gmatch iterator: upvalues = (regex, subject, pos). Yields a match table.
fn lGmatchIter(L: ?*State) callconv(.c) c_int {
    const prog = checkRegex(L, c.lua_upvalueindex(1));
    var n: usize = 0;
    const s = c.lua_tolstring(L, c.lua_upvalueindex(2), &n);
    const pos = c.lua_tointegerx(L, c.lua_upvalueindex(3), null);
    if (pos > @as(c_int, @intCast(n))) {
        c.lua_pushnil(L);
        return 1;
    }
    const sv = alloc.alloc(i32, @intCast(prog.nsaves)) catch {
        return c.luaL_errorL(L, "re: out of memory");
    };
    defer alloc.free(sv);
    if (!runChecked(L, prog, s, @intCast(n), pos, sv)) {
        c.lua_pushnil(L);
        return 1;
    }
    var next = sv[1];
    if (next == sv[0]) // empty match → advance to avoid an infinite loop
        next += 1;
    c.lua_pushinteger(L, next);
    c.lua_replace(L, c.lua_upvalueindex(3));
    pushMatch(L, prog, s, sv);
    return 1;
}

// rx:gmatch(s) -> iterator
fn lGmatch(L: ?*State) callconv(.c) c_int {
    _ = checkRegex(L, 1);
    _ = c.luaL_checklstring(L, 2, null);
    c.lua_pushvalue(L, 1); // regex
    c.lua_pushvalue(L, 2); // subject
    c.lua_pushinteger(L, 0); // pos
    c.lua_pushcclosurek(L, &lGmatchIter, "re.gmatch.iter", 3, null);
    return 1;
}

// Raise `re: out of memory` (a catchable Lua error). The mc trap unwinds to the enclosing pcall;
// like runChecked, an allocation failure is surfaced, never silently dropped (which would corrupt the
// result) and never trapped.
fn oomRaise(L: ?*State) void {
    _ = c.luaL_errorL(L, "re: out of memory");
}

// Expand a `$N` / `$0` / `$$` template against the captures.
fn expandTemplate(L: ?*State, out: *std.ArrayList(u8), repl: [*]const u8, rn: usize, s: [*]const u8, sv: []const i32) void {
    var i: usize = 0;
    while (i < rn) : (i += 1) {
        const ch = repl[i];
        if (ch == '$' and i + 1 < rn) {
            const d = repl[i + 1];
            if (d == '$') {
                out.append(alloc, '$') catch oomRaise(L);
                i += 1;
                continue;
            }
            if (d >= '0' and d <= '9') {
                var g: i32 = 0;
                var j = i + 1;
                while (j < rn and repl[j] >= '0' and repl[j] <= '9') {
                    g = g * 10 + (@as(i32, repl[j]) - '0');
                    j += 1;
                }
                if (g * 2 + 1 < @as(i32, @intCast(sv.len))) {
                    const a = sv[@intCast(g * 2)];
                    const b = sv[@intCast(g * 2 + 1)];
                    if (a >= 0 and b >= 0)
                        out.appendSlice(alloc, (s + @as(usize, @intCast(a)))[0..@intCast(b - a)]) catch oomRaise(L);
                }
                i = j - 1;
                continue;
            }
        }
        out.append(alloc, ch) catch oomRaise(L);
    }
}

// rx:replace(s, repl [, n]) -> result, count. `repl` is a $N template string or a
// function receiving the match table and returning a string.
fn lReplace(L: ?*State) callconv(.c) c_int {
    const prog = checkRegex(L, 1);
    var n: usize = 0;
    const s = c.luaL_checklstring(L, 2, &n);
    const is_fn = c.lua_type(L, 3) == c.LUA_TFUNCTION;
    var rn: usize = 0;
    const repl: ?[*]const u8 = if (is_fn) null else c.luaL_checklstring(L, 3, &rn);
    const limit = c.luaL_optinteger(L, 4, -1);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const sv = alloc.alloc(i32, @intCast(prog.nsaves)) catch {
        return c.luaL_errorL(L, "re: out of memory");
    };
    defer alloc.free(sv);

    var count: c_int = 0;
    var pos: i32 = 0;
    const nlen: i32 = @intCast(n);
    while (pos <= nlen) {
        if (limit >= 0 and count >= limit)
            break;
        if (!runChecked(L, prog, s, nlen, pos, sv))
            break;
        // text before the match
        out.appendSlice(alloc, (s + @as(usize, @intCast(pos)))[0..@intCast(sv[0] - pos)]) catch oomRaise(L);
        if (is_fn) {
            c.lua_pushvalue(L, 3);
            pushMatch(L, prog, s, sv);
            c.lua_call(L, 1, 1);
            var outlen: usize = 0;
            const r = c.lua_tolstring(L, -1, &outlen);
            if (r != null)
                out.appendSlice(alloc, r[0..outlen]) catch oomRaise(L)
            else // non-string → keep original
                out.appendSlice(alloc, (s + @as(usize, @intCast(sv[0])))[0..@intCast(sv[1] - sv[0])]) catch oomRaise(L);
            lua.pop(L, 1);
        } else {
            expandTemplate(L, &out, repl.?, rn, s, sv);
        }
        count += 1;
        var next = sv[1];
        if (next == sv[0]) { // empty match: emit one char and advance
            if (next < nlen)
                out.append(alloc, s[@intCast(next)]) catch oomRaise(L);
            next += 1;
        }
        pos = next;
    }
    if (pos < nlen)
        out.appendSlice(alloc, (s + @as(usize, @intCast(pos)))[0..@intCast(nlen - pos)]) catch oomRaise(L);
    c.lua_pushlstring(L, out.items.ptr, out.items.len);
    c.lua_pushinteger(L, count);
    return 2;
}

// ── module-level convenience (compile + apply) ──────────────────────────────

// Compile arg-1 pattern with optional flags; return the Prog or raise the error.
fn compileArg(L: ?*State, pat: [*]const u8, n: usize, flags: ?[*:0]const u8) *Prog {
    var err: ?[*:0]const u8 = null;
    const prog = compile(pat, n, flags, &err);
    if (prog == null)
        _ = c.luaL_errorL(L, "%s", err orelse "re: compile error");
    return prog.?;
}

fn lModMatch(L: ?*State) callconv(.c) c_int {
    var pn: usize = 0;
    var sn: usize = 0;
    const pat = c.luaL_checklstring(L, 1, &pn);
    const s = c.luaL_checklstring(L, 2, &sn);
    const flags = c.luaL_optlstring(L, 3, "", null);
    const prog = compileArg(L, pat, pn, flags);
    defer {
        prog.deinit();
        alloc.destroy(prog);
    }
    const sv = alloc.alloc(i32, @intCast(prog.nsaves)) catch {
        return c.luaL_errorL(L, "re: out of memory");
    };
    defer alloc.free(sv);
    if (runChecked(L, prog, s, @intCast(sn), 0, sv))
        pushMatch(L, prog, s, sv)
    else
        c.lua_pushnil(L);
    return 1;
}

fn lModTest(L: ?*State) callconv(.c) c_int {
    var pn: usize = 0;
    var sn: usize = 0;
    const pat = c.luaL_checklstring(L, 1, &pn);
    const s = c.luaL_checklstring(L, 2, &sn);
    const flags = c.luaL_optlstring(L, 3, "", null);
    const prog = compileArg(L, pat, pn, flags);
    defer {
        prog.deinit();
        alloc.destroy(prog);
    }
    const sv = alloc.alloc(i32, @intCast(prog.nsaves)) catch {
        return c.luaL_errorL(L, "re: out of memory");
    };
    defer alloc.free(sv);
    c.lua_pushboolean(L, @intFromBool(runChecked(L, prog, s, @intCast(sn), 0, sv)));
    return 1;
}

pub export fn mc_open_re(L: ?*State) c_int {
    // Metatable for compiled regex userdata: __index = the methods table.
    _ = c.luaL_newmetatable(L, kMeta);
    lua.newtable(L); // methods
    lua.pushcfunction(L, &lMatch, "match");
    c.lua_setfield(L, -2, "match");
    lua.pushcfunction(L, &lFind, "find");
    c.lua_setfield(L, -2, "find");
    lua.pushcfunction(L, &lTest, "test");
    c.lua_setfield(L, -2, "test");
    lua.pushcfunction(L, &lGmatch, "gmatch");
    c.lua_setfield(L, -2, "gmatch");
    lua.pushcfunction(L, &lReplace, "replace");
    c.lua_setfield(L, -2, "replace");
    c.lua_setfield(L, -2, "__index");
    _ = c.lua_pushstring(L, kMeta);
    c.lua_setfield(L, -2, "__type"); // friendlier tostring/typeof
    lua.pop(L, 1); // pop the metatable

    lua.newtable(L); // the `re` module
    lua.pushcfunction(L, &lCompile, "compile");
    c.lua_setfield(L, -2, "compile");
    lua.pushcfunction(L, &lModMatch, "match");
    c.lua_setfield(L, -2, "match");
    lua.pushcfunction(L, &lModTest, "test");
    c.lua_setfield(L, -2, "test");
    return 1;
}
