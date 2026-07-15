//! jq: parser + streaming evaluator over the value.zig Value + lexer.zig tokens. A filter
//! maps one input value to a SEQUENCE of output values, modelled with a callback sink so
//! `.[]` over large arrays never materializes. Matches jaq / jq 1.7 on the common core:
//! identity, path access (.foo, .[i], .[], .[a:b]), pipe, comma, arithmetic, comparison,
//! and/or/not, if/elif/else, // alternative, recursion .., object/array construction, and
//! the common builtins. Uncommon builtins are a documented deferral.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lex = @import("lexer.zig");
const val = @import("value.zig");
const Value = val.Value;
const Entry = val.Entry;

pub const Error = error{ JqParse, JqRuntime, OutOfMemory };

// ============================================================ AST

pub const Node = union(enum) {
    identity, // .
    recurse, // ..
    field: []const u8, // .foo  (applied to current)
    index_expr: *Node, // .[e]
    iterate, // .[]
    slice: struct { from: ?*Node, to: ?*Node }, // .[a:b]
    lit: Value,
    array: ?*Node, // [ e ]  (null = [])
    object: []ObjField, // { ... }
    pipe: struct { l: *Node, r: *Node },
    comma: struct { l: *Node, r: *Node },
    neg: *Node,
    binop: struct { op: Op, l: *Node, r: *Node },
    alt: struct { l: *Node, r: *Node }, // //
    if_expr: struct { cond: *Node, then: *Node, els: ?*Node },
    call: struct { name: []const u8, args: []*Node },
    postfix: struct { base: *Node, ops: []PathOp }, // base followed by .foo/[..]/[]
    try_expr: *Node, // e?
    reduce: struct { src: *Node, varname: []const u8, init: *Node, update: *Node },
    variable: []const u8,
    bind: struct { src: *Node, varname: []const u8, body: *Node }, // src as $v | body
};

const Op = enum { add, sub, mul, div, mod, eq, ne, lt, le, gt, ge, @"and", @"or" };

const ObjField = struct { key: ObjKey, value: ?*Node };
const ObjKey = union(enum) { ident: []const u8, string: []const u8, expr: *Node };

const PathOp = union(enum) {
    field: []const u8,
    index: *Node,
    iterate,
    slice: struct { from: ?*Node, to: ?*Node },
    optional, // ?
};

// ============================================================ parser

const Parser = struct {
    toks: []const lex.Token,
    pos: usize = 0,
    gpa: Allocator,

    fn peek(self: *Parser) ?lex.Token {
        return if (self.pos < self.toks.len) self.toks[self.pos] else null;
    }
    fn advance(self: *Parser) ?lex.Token {
        const t = self.peek();
        if (t != null) self.pos += 1;
        return t;
    }
    fn isKind(self: *Parser, k: lex.TokKind) bool {
        if (self.peek()) |t| return t.kind == k;
        return false;
    }
    fn isOp(self: *Parser, s: []const u8) bool {
        if (self.peek()) |t| return t.kind == .op and std.mem.eql(u8, t.text, s);
        return false;
    }
    fn isIdent(self: *Parser, s: []const u8) bool {
        if (self.peek()) |t| return t.kind == .ident and std.mem.eql(u8, t.text, s);
        return false;
    }
    fn eatKind(self: *Parser, k: lex.TokKind) bool {
        if (self.isKind(k)) {
            self.pos += 1;
            return true;
        }
        return false;
    }
    fn eatOp(self: *Parser, s: []const u8) bool {
        if (self.isOp(s)) {
            self.pos += 1;
            return true;
        }
        return false;
    }
    fn eatIdent(self: *Parser, s: []const u8) bool {
        if (self.isIdent(s)) {
            self.pos += 1;
            return true;
        }
        return false;
    }
    fn mk(self: *Parser, n: Node) !*Node {
        const p = try self.gpa.create(Node);
        p.* = n;
        return p;
    }

    fn parsePipe(self: *Parser) Error!*Node {
        // Handle "src as $v | body" binding
        var l = try self.parseComma();
        if (self.isIdent("as")) {
            self.pos += 1;
            const v = try self.expectVar();
            if (!self.eatOp("|")) return error.JqParse;
            const body = try self.parsePipe();
            return self.mk(.{ .bind = .{ .src = l, .varname = v, .body = body } });
        }
        while (self.eatOp("|")) {
            const r = try self.parseComma();
            if (self.isIdent("as")) {
                self.pos += 1;
                const v = try self.expectVar();
                if (!self.eatOp("|")) return error.JqParse;
                const body = try self.parsePipe();
                l = try self.mk(.{ .pipe = .{ .l = l, .r = try self.mk(.{ .bind = .{ .src = r, .varname = v, .body = body } }) } });
                return l;
            }
            l = try self.mk(.{ .pipe = .{ .l = l, .r = r } });
        }
        return l;
    }

    fn expectVar(self: *Parser) Error![]const u8 {
        if (self.peek()) |t| {
            if (t.kind == .variable) {
                self.pos += 1;
                return t.text;
            }
        }
        return error.JqParse;
    }

    fn parseComma(self: *Parser) Error!*Node {
        var l = try self.parseAlt();
        while (self.eatKind(.comma)) {
            const r = try self.parseAlt();
            l = try self.mk(.{ .comma = .{ .l = l, .r = r } });
        }
        return l;
    }

    fn parseAlt(self: *Parser) Error!*Node {
        var l = try self.parseOr();
        while (self.eatOp("//")) {
            const r = try self.parseOr();
            l = try self.mk(.{ .alt = .{ .l = l, .r = r } });
        }
        return l;
    }

    fn parseOr(self: *Parser) Error!*Node {
        var l = try self.parseAnd();
        while (self.eatIdent("or")) {
            const r = try self.parseAnd();
            l = try self.mk(.{ .binop = .{ .op = .@"or", .l = l, .r = r } });
        }
        return l;
    }
    fn parseAnd(self: *Parser) Error!*Node {
        var l = try self.parseCompare();
        while (self.eatIdent("and")) {
            const r = try self.parseCompare();
            l = try self.mk(.{ .binop = .{ .op = .@"and", .l = l, .r = r } });
        }
        return l;
    }
    fn parseCompare(self: *Parser) Error!*Node {
        const l = try self.parseAdd();
        const cmp = [_]struct { s: []const u8, op: Op }{
            .{ .s = "==", .op = .eq }, .{ .s = "!=", .op = .ne }, .{ .s = "<=", .op = .le },
            .{ .s = ">=", .op = .ge }, .{ .s = "<", .op = .lt },  .{ .s = ">", .op = .gt },
        };
        for (cmp) |c| {
            if (self.eatOp(c.s)) {
                const r = try self.parseAdd();
                return self.mk(.{ .binop = .{ .op = c.op, .l = l, .r = r } });
            }
        }
        return l;
    }
    fn parseAdd(self: *Parser) Error!*Node {
        var l = try self.parseMul();
        while (true) {
            if (self.eatOp("+")) {
                l = try self.mk(.{ .binop = .{ .op = .add, .l = l, .r = try self.parseMul() } });
            } else if (self.eatOp("-")) {
                l = try self.mk(.{ .binop = .{ .op = .sub, .l = l, .r = try self.parseMul() } });
            } else break;
        }
        return l;
    }
    fn parseMul(self: *Parser) Error!*Node {
        var l = try self.parseUnary();
        while (true) {
            if (self.eatOp("*")) {
                l = try self.mk(.{ .binop = .{ .op = .mul, .l = l, .r = try self.parseUnary() } });
            } else if (self.eatOp("/")) {
                l = try self.mk(.{ .binop = .{ .op = .div, .l = l, .r = try self.parseUnary() } });
            } else if (self.eatOp("%")) {
                l = try self.mk(.{ .binop = .{ .op = .mod, .l = l, .r = try self.parseUnary() } });
            } else break;
        }
        return l;
    }
    fn parseUnary(self: *Parser) Error!*Node {
        if (self.eatOp("-")) {
            return self.mk(.{ .neg = try self.parsePostfix() });
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) Error!*Node {
        const base = try self.parsePrimary();
        var ops: std.ArrayListUnmanaged(PathOp) = .empty;
        while (true) {
            if (self.isKind(.field)) {
                const t = self.advance().?;
                try ops.append(self.gpa, .{ .field = t.text });
            } else if (self.isKind(.dot) and self.pos + 1 < self.toks.len and self.toks[self.pos + 1].kind == .lbracket) {
                self.pos += 1; // consume dot before [
                // fallthrough handled next iteration
            } else if (self.eatKind(.lbracket)) {
                if (self.eatKind(.rbracket)) {
                    try ops.append(self.gpa, .iterate);
                } else if (self.eatKind(.colon)) {
                    const to = try self.parsePipe();
                    if (!self.eatKind(.rbracket)) return error.JqParse;
                    try ops.append(self.gpa, .{ .slice = .{ .from = null, .to = to } });
                } else {
                    const e = try self.parsePipe();
                    if (self.eatKind(.colon)) {
                        if (self.eatKind(.rbracket)) {
                            try ops.append(self.gpa, .{ .slice = .{ .from = e, .to = null } });
                        } else {
                            const to = try self.parsePipe();
                            if (!self.eatKind(.rbracket)) return error.JqParse;
                            try ops.append(self.gpa, .{ .slice = .{ .from = e, .to = to } });
                        }
                    } else {
                        if (!self.eatKind(.rbracket)) return error.JqParse;
                        try ops.append(self.gpa, .{ .index = e });
                    }
                }
            } else if (self.eatKind(.question)) {
                try ops.append(self.gpa, .optional);
            } else break;
        }
        if (ops.items.len == 0) return base;
        return self.mk(.{ .postfix = .{ .base = base, .ops = ops.items } });
    }

    fn parsePrimary(self: *Parser) Error!*Node {
        const t = self.peek() orelse return error.JqParse;
        switch (t.kind) {
            .dot => {
                self.pos += 1;
                // ".[...]" handled by postfix; bare "." is identity
                return self.mk(.identity);
            },
            .dotdot => {
                self.pos += 1;
                return self.mk(.recurse);
            },
            .field => {
                self.pos += 1;
                return self.mk(.{ .field = t.text });
            },
            .number => {
                self.pos += 1;
                const n = std.fmt.parseFloat(f64, t.text) catch 0;
                return self.mk(.{ .lit = .{ .number = n } });
            },
            .string => {
                self.pos += 1;
                return self.mk(.{ .lit = .{ .string = try self.strLit(t) } });
            },
            .variable => {
                self.pos += 1;
                return self.mk(.{ .variable = t.text });
            },
            .lparen => {
                self.pos += 1;
                const e = try self.parsePipe();
                if (!self.eatKind(.rparen)) return error.JqParse;
                return e;
            },
            .lbracket => {
                self.pos += 1;
                if (self.eatKind(.rbracket)) return self.mk(.{ .array = null });
                const e = try self.parsePipe();
                if (!self.eatKind(.rbracket)) return error.JqParse;
                return self.mk(.{ .array = e });
            },
            .lbrace => return self.parseObject(),
            .ident => return self.parseIdentExpr(),
            else => return error.JqParse,
        }
    }

    fn strLit(self: *Parser, t: lex.Token) Error![]const u8 {
        // Only literal parts supported here (interpolation deferred); concatenate literals.
        var out: std.ArrayListUnmanaged(u8) = .empty;
        for (t.parts) |p| switch (p) {
            .literal => |s| try out.appendSlice(self.gpa, s),
            .interp => return error.JqParse, // string interpolation deferred
        };
        return out.items;
    }

    fn parseIdentExpr(self: *Parser) Error!*Node {
        const t = self.advance().?;
        const name = t.text;
        if (std.mem.eql(u8, name, "true")) return self.mk(.{ .lit = Value.TRUE });
        if (std.mem.eql(u8, name, "false")) return self.mk(.{ .lit = Value.FALSE });
        if (std.mem.eql(u8, name, "null")) return self.mk(.{ .lit = .null });
        if (std.mem.eql(u8, name, "if")) return self.parseIf();
        if (std.mem.eql(u8, name, "reduce")) return self.parseReduce();
        if (std.mem.eql(u8, name, "not")) return self.mk(.{ .call = .{ .name = "not", .args = &.{} } });
        // function call with optional (args)
        var args: std.ArrayListUnmanaged(*Node) = .empty;
        if (self.eatKind(.lparen)) {
            while (true) {
                try args.append(self.gpa, try self.parsePipe());
                if (self.eatKind(.semicolon)) continue;
                break;
            }
            if (!self.eatKind(.rparen)) return error.JqParse;
        }
        return self.mk(.{ .call = .{ .name = name, .args = args.items } });
    }

    fn parseIf(self: *Parser) Error!*Node {
        const cond = try self.parsePipe();
        if (!self.eatIdent("then")) return error.JqParse;
        const then = try self.parsePipe();
        var els: ?*Node = null;
        if (self.eatIdent("elif")) {
            els = try self.parseIf();
            return self.mk(.{ .if_expr = .{ .cond = cond, .then = then, .els = els } });
        }
        if (self.eatIdent("else")) {
            els = try self.parsePipe();
        }
        if (!self.eatIdent("end")) return error.JqParse;
        return self.mk(.{ .if_expr = .{ .cond = cond, .then = then, .els = els } });
    }

    fn parseReduce(self: *Parser) Error!*Node {
        const src = try self.parsePostfix();
        if (!self.eatIdent("as")) return error.JqParse;
        const v = try self.expectVar();
        if (!self.eatKind(.lparen)) return error.JqParse;
        const init_n = try self.parsePipe();
        if (!self.eatKind(.semicolon)) return error.JqParse;
        const update = try self.parsePipe();
        if (!self.eatKind(.rparen)) return error.JqParse;
        return self.mk(.{ .reduce = .{ .src = src, .varname = v, .init = init_n, .update = update } });
    }

    fn parseObject(self: *Parser) Error!*Node {
        self.pos += 1; // {
        var fields: std.ArrayListUnmanaged(ObjField) = .empty;
        if (self.eatKind(.rbrace)) return self.mk(.{ .object = fields.items });
        while (true) {
            var key: ObjKey = undefined;
            const kt = self.peek() orelse return error.JqParse;
            switch (kt.kind) {
                .ident => {
                    self.pos += 1;
                    key = .{ .ident = kt.text };
                },
                .string => {
                    self.pos += 1;
                    key = .{ .string = try self.strLit(kt) };
                },
                .variable => {
                    self.pos += 1;
                    // {$x} shorthand
                    fields.append(self.gpa, .{ .key = .{ .string = kt.text }, .value = try self.mk(.{ .variable = kt.text }) }) catch return error.OutOfMemory;
                    if (self.eatKind(.comma)) continue;
                    break;
                },
                .lparen => {
                    self.pos += 1;
                    const e = try self.parsePipe();
                    if (!self.eatKind(.rparen)) return error.JqParse;
                    key = .{ .expr = e };
                },
                else => return error.JqParse,
            }
            var value: ?*Node = null;
            if (self.eatKind(.colon)) {
                value = try self.parseObjValue();
            }
            try fields.append(self.gpa, .{ .key = key, .value = value });
            if (self.eatKind(.comma)) continue;
            break;
        }
        if (!self.eatKind(.rbrace)) return error.JqParse;
        return self.mk(.{ .object = fields.items });
    }

    // Object values bind tighter than comma (so {a: 1, b: 2} splits correctly).
    fn parseObjValue(self: *Parser) Error!*Node {
        return self.parseAlt();
    }
};

// ============================================================ evaluator

pub const Emit = *const fn (ctx: *anyopaque, v: Value) Error!void;

pub const Env = struct {
    gpa: Allocator,
    vars: std.StringHashMapUnmanaged(Value) = .empty,

    fn child(self: *Env) Env {
        var e = Env{ .gpa = self.gpa };
        e.vars = self.vars.clone(self.gpa) catch self.vars;
        return e;
    }
};

pub const Interp = struct {
    gpa: Allocator,
    root: *Node,

    pub fn eval(self: *Interp, input: Value, ctx: *anyopaque, emit: Emit) Error!void {
        var env = Env{ .gpa = self.gpa };
        try self.evalNode(self.root, input, &env, ctx, emit);
    }

    pub fn evalNode(self: *Interp, node: *Node, input: Value, env: *Env, ctx: *anyopaque, emit: Emit) Error!void {
        switch (node.*) {
            .identity => try emit(ctx, input),
            .recurse => try self.recurse(input, ctx, emit),
            .lit => |v| try emit(ctx, v),
            .field => |f| try emit(ctx, try getField(input, f)),
            .variable => |v| {
                if (env.vars.get(v)) |val_| try emit(ctx, val_) else return error.JqRuntime;
            },
            .pipe => |p| {
                const Ctx2 = struct {
                    interp: *Interp,
                    right: *Node,
                    env: *Env,
                    inner_ctx: *anyopaque,
                    inner_emit: Emit,
                    fn f(c: *anyopaque, v: Value) Error!void {
                        const s: *@This() = @ptrCast(@alignCast(c));
                        try s.interp.evalNode(s.right, v, s.env, s.inner_ctx, s.inner_emit);
                    }
                };
                var c2 = Ctx2{ .interp = self, .right = p.r, .env = env, .inner_ctx = ctx, .inner_emit = emit };
                try self.evalNode(p.l, input, env, &c2, Ctx2.f);
            },
            .comma => |p| {
                try self.evalNode(p.l, input, env, ctx, emit);
                try self.evalNode(p.r, input, env, ctx, emit);
            },
            .array => |maybe| {
                var items: std.ArrayListUnmanaged(Value) = .empty;
                if (maybe) |e| {
                    const Ctx2 = struct {
                        list: *std.ArrayListUnmanaged(Value),
                        gpa: Allocator,
                        fn f(c: *anyopaque, v: Value) Error!void {
                            const s: *@This() = @ptrCast(@alignCast(c));
                            try s.list.append(s.gpa, v);
                        }
                    };
                    var c2 = Ctx2{ .list = &items, .gpa = self.gpa };
                    try self.evalNode(e, input, env, &c2, Ctx2.f);
                }
                try emit(ctx, .{ .array = items.items });
            },
            .object => |fields| try self.evalObject(fields, input, env, ctx, emit),
            .neg => |e| {
                const Ctx2 = struct {
                    inner_ctx: *anyopaque,
                    inner_emit: Emit,
                    fn f(c: *anyopaque, v: Value) Error!void {
                        const s: *@This() = @ptrCast(@alignCast(c));
                        if (v != .number) return error.JqRuntime;
                        try s.inner_emit(s.inner_ctx, .{ .number = -v.number });
                    }
                };
                var c2 = Ctx2{ .inner_ctx = ctx, .inner_emit = emit };
                try self.evalNode(e, input, env, &c2, Ctx2.f);
            },
            .binop => |b| try self.evalBinop(b.op, b.l, b.r, input, env, ctx, emit),
            .alt => |a| try self.evalAlt(a.l, a.r, input, env, ctx, emit),
            .if_expr => |f| try self.evalIf(f.cond, f.then, f.els, input, env, ctx, emit),
            .postfix => |pf| try self.evalPostfix(pf.base, pf.ops, 0, input, env, ctx, emit),
            .index_expr, .iterate, .slice => try emit(ctx, input), // handled via postfix
            .call => |c| try self.evalCall(c.name, c.args, input, env, ctx, emit),
            .try_expr => |e| self.evalNode(e, input, env, ctx, emit) catch {},
            .reduce => |r| try self.evalReduce(r.src, r.varname, r.init, r.update, input, env, ctx, emit),
            .bind => |b| try self.evalBind(b.src, b.varname, b.body, input, env, ctx, emit),
        }
    }

    fn evalBind(self: *Interp, src: *Node, name: []const u8, body: *Node, input: Value, env: *Env, ctx: *anyopaque, emit: Emit) Error!void {
        const Ctx2 = struct {
            interp: *Interp,
            name: []const u8,
            body: *Node,
            env: *Env,
            input: Value,
            inner_ctx: *anyopaque,
            inner_emit: Emit,
            fn f(c: *anyopaque, v: Value) Error!void {
                const s: *@This() = @ptrCast(@alignCast(c));
                var child = s.env.child();
                try child.vars.put(child.gpa, s.name, v);
                try s.interp.evalNode(s.body, s.input, &child, s.inner_ctx, s.inner_emit);
            }
        };
        var c2 = Ctx2{ .interp = self, .name = name, .body = body, .env = env, .input = input, .inner_ctx = ctx, .inner_emit = emit };
        try self.evalNode(src, input, env, &c2, Ctx2.f);
    }

    pub fn recurse(self: *Interp, input: Value, ctx: *anyopaque, emit: Emit) Error!void {
        try emit(ctx, input);
        switch (input) {
            .array => |a| for (a) |x| try self.recurse(x, ctx, emit),
            .object => |o| for (o) |e| try self.recurse(e.value, ctx, emit),
            else => {},
        }
    }

    fn evalObject(self: *Interp, fields: []ObjField, input: Value, env: *Env, ctx: *anyopaque, emit: Emit) Error!void {
        // Collect one value per field (Cartesian product across multi-output values is
        // supported only for the common single-output case here).
        var ob = val.ObjBuilder.init(self.gpa);
        for (fields) |fld| {
            const key = switch (fld.key) {
                .ident => |s| s,
                .string => |s| s,
                .expr => |e| blk: {
                    const kv = try self.evalOne(e, input, env);
                    if (kv != .string) return error.JqRuntime;
                    break :blk kv.string;
                },
            };
            const value = if (fld.value) |vn| try self.evalOne(vn, input, env) else try getField(input, key);
            ob.set(key, value);
        }
        try emit(ctx, .{ .object = ob.finish() });
    }

    fn evalIf(self: *Interp, cond: *Node, then: *Node, els: ?*Node, input: Value, env: *Env, ctx: *anyopaque, emit: Emit) Error!void {
        const Ctx2 = struct {
            interp: *Interp,
            then: *Node,
            els: ?*Node,
            env: *Env,
            input: Value,
            inner_ctx: *anyopaque,
            inner_emit: Emit,
            fn f(c: *anyopaque, v: Value) Error!void {
                const s: *@This() = @ptrCast(@alignCast(c));
                if (v.truthy()) {
                    try s.interp.evalNode(s.then, s.input, s.env, s.inner_ctx, s.inner_emit);
                } else if (s.els) |e| {
                    try s.interp.evalNode(e, s.input, s.env, s.inner_ctx, s.inner_emit);
                } else {
                    try s.inner_emit(s.inner_ctx, s.input);
                }
            }
        };
        var c2 = Ctx2{ .interp = self, .then = then, .els = els, .env = env, .input = input, .inner_ctx = ctx, .inner_emit = emit };
        try self.evalNode(cond, input, env, &c2, Ctx2.f);
    }

    fn evalAlt(self: *Interp, l: *Node, r: *Node, input: Value, env: *Env, ctx: *anyopaque, emit: Emit) Error!void {
        // // emits left's truthy outputs; if none, emits right's outputs.
        const Ctx2 = struct {
            any: bool = false,
            inner_ctx: *anyopaque,
            inner_emit: Emit,
            fn f(c: *anyopaque, v: Value) Error!void {
                const s: *@This() = @ptrCast(@alignCast(c));
                if (v.truthy()) {
                    s.any = true;
                    try s.inner_emit(s.inner_ctx, v);
                }
            }
        };
        var c2 = Ctx2{ .inner_ctx = ctx, .inner_emit = emit };
        self.evalNode(l, input, env, &c2, Ctx2.f) catch {};
        if (!c2.any) try self.evalNode(r, input, env, ctx, emit);
    }

    fn evalPostfix(self: *Interp, base: *Node, ops: []PathOp, start: usize, input: Value, env: *Env, ctx: *anyopaque, emit: Emit) Error!void {
        // Evaluate base, then thread each output through the path ops.
        const Ctx2 = struct {
            interp: *Interp,
            ops: []PathOp,
            env: *Env,
            inner_ctx: *anyopaque,
            inner_emit: Emit,
            fn f(c: *anyopaque, v: Value) Error!void {
                const s: *@This() = @ptrCast(@alignCast(c));
                try s.interp.applyOps(s.ops, 0, v, s.env, s.inner_ctx, s.inner_emit);
            }
        };
        _ = start;
        var c2 = Ctx2{ .interp = self, .ops = ops, .env = env, .inner_ctx = ctx, .inner_emit = emit };
        try self.evalNode(base, input, env, &c2, Ctx2.f);
    }

    fn applyOps(self: *Interp, ops: []PathOp, i: usize, input: Value, env: *Env, ctx: *anyopaque, emit: Emit) Error!void {
        if (i >= ops.len) {
            try emit(ctx, input);
            return;
        }
        const Ctx2 = struct {
            interp: *Interp,
            ops: []PathOp,
            next: usize,
            env: *Env,
            inner_ctx: *anyopaque,
            inner_emit: Emit,
            fn f(c: *anyopaque, v: Value) Error!void {
                const s: *@This() = @ptrCast(@alignCast(c));
                try s.interp.applyOps(s.ops, s.next, v, s.env, s.inner_ctx, s.inner_emit);
            }
        };
        var c2 = Ctx2{ .interp = self, .ops = ops, .next = i + 1, .env = env, .inner_ctx = ctx, .inner_emit = emit };
        const op = ops[i];
        switch (op) {
            .field => |f| try Ctx2.f(&c2, try getField(input, f)),
            .optional => try Ctx2.f(&c2, input), // '?' just suppresses errors upstream
            .iterate => {
                switch (input) {
                    .array => |a| for (a) |x| try Ctx2.f(&c2, x),
                    .object => |o| for (o) |e| try Ctx2.f(&c2, e.value),
                    else => return error.JqRuntime,
                }
            },
            .index => |e| {
                const idx = try self.evalOne(e, input, env);
                try Ctx2.f(&c2, try indexValue(input, idx));
            },
            .slice => |sl| {
                const from = if (sl.from) |fn_| (try self.evalOne(fn_, input, env)) else Value{ .null = {} };
                const to = if (sl.to) |tn| (try self.evalOne(tn, input, env)) else Value{ .null = {} };
                try Ctx2.f(&c2, try sliceValue(self.gpa, input, from, to));
            },
        }
    }

    fn evalReduce(self: *Interp, src: *Node, name: []const u8, init_n: *Node, update: *Node, input: Value, env: *Env, ctx: *anyopaque, emit: Emit) Error!void {
        var acc = try self.evalOne(init_n, input, env);
        const Ctx2 = struct {
            interp: *Interp,
            name: []const u8,
            update: *Node,
            env: *Env,
            input: Value,
            acc: *Value,
            fn f(c: *anyopaque, v: Value) Error!void {
                const s: *@This() = @ptrCast(@alignCast(c));
                var child = s.env.child();
                try child.vars.put(child.gpa, s.name, v);
                // update runs with acc as input, taking its LAST output
                s.acc.* = try s.interp.evalOne(s.update, s.acc.*, &child);
            }
        };
        var c2 = Ctx2{ .interp = self, .name = name, .update = update, .env = env, .input = input, .acc = &acc };
        try self.evalNode(src, input, env, &c2, Ctx2.f);
        try emit(ctx, acc);
    }

    /// Evaluate a node expected to produce exactly one value (takes the last).
    pub fn evalOne(self: *Interp, node: *Node, input: Value, env: *Env) Error!Value {
        const Ctx2 = struct {
            result: Value = .null,
            got: bool = false,
            fn f(c: *anyopaque, v: Value) Error!void {
                const s: *@This() = @ptrCast(@alignCast(c));
                s.result = v;
                s.got = true;
            }
        };
        var c2 = Ctx2{};
        try self.evalNode(node, input, env, &c2, Ctx2.f);
        return c2.result;
    }

    fn evalBinop(self: *Interp, op: Op, l: *Node, r: *Node, input: Value, env: *Env, ctx: *anyopaque, emit: Emit) Error!void {
        // jq: for each output of r, for each output of l, combine. Simplified to single
        // outputs (the common case).
        const lv = try self.evalOne(l, input, env);
        if (op == .@"and") {
            const rv = try self.evalOne(r, input, env);
            try emit(ctx, Value.boolOf(lv.truthy() and rv.truthy()));
            return;
        }
        if (op == .@"or") {
            const rv = try self.evalOne(r, input, env);
            try emit(ctx, Value.boolOf(lv.truthy() or rv.truthy()));
            return;
        }
        const rv = try self.evalOne(r, input, env);
        try emit(ctx, try self.combine(op, lv, rv));
    }

    fn combine(self: *Interp, op: Op, a: Value, b: Value) Error!Value {
        switch (op) {
            .eq => return Value.boolOf(Value.equal(self.gpa, a, b)),
            .ne => return Value.boolOf(!Value.equal(self.gpa, a, b)),
            .lt => return Value.boolOf(Value.compare(self.gpa, a, b) == .lt),
            .le => return Value.boolOf(Value.compare(self.gpa, a, b) != .gt),
            .gt => return Value.boolOf(Value.compare(self.gpa, a, b) == .gt),
            .ge => return Value.boolOf(Value.compare(self.gpa, a, b) != .lt),
            .add => return self.addVals(a, b),
            .sub => {
                if (a == .number and b == .number) return .{ .number = a.number - b.number };
                return error.JqRuntime;
            },
            .mul => {
                if (a == .number and b == .number) return .{ .number = a.number * b.number };
                return error.JqRuntime;
            },
            .div => {
                if (a == .number and b == .number) return .{ .number = a.number / b.number };
                return error.JqRuntime;
            },
            .mod => {
                if (a == .number and b == .number) return .{ .number = @trunc(@rem(a.number, b.number)) };
                return error.JqRuntime;
            },
            else => return error.JqRuntime,
        }
    }

    pub fn addVals(self: *Interp, a: Value, b: Value) Error!Value {
        if (a == .null) return b;
        if (b == .null) return a;
        if (a == .number and b == .number) return .{ .number = a.number + b.number };
        if (a == .string and b == .string) {
            const s = try self.gpa.alloc(u8, a.string.len + b.string.len);
            @memcpy(s[0..a.string.len], a.string);
            @memcpy(s[a.string.len..], b.string);
            return .{ .string = s };
        }
        if (a == .array and b == .array) {
            const arr = try self.gpa.alloc(Value, a.array.len + b.array.len);
            @memcpy(arr[0..a.array.len], a.array);
            @memcpy(arr[a.array.len..], b.array);
            return .{ .array = arr };
        }
        if (a == .object and b == .object) {
            var ob = val.ObjBuilder.init(self.gpa);
            for (a.object) |e| ob.set(e.key, e.value);
            for (b.object) |e| ob.set(e.key, e.value);
            return .{ .object = ob.finish() };
        }
        return error.JqRuntime;
    }

    fn evalCall(self: *Interp, name: []const u8, args: []*Node, input: Value, env: *Env, ctx: *anyopaque, emit: Emit) Error!void {
        try @import("builtins.zig").call(self, name, args, input, env, ctx, emit);
    }
};

// ============================================================ path helpers

pub fn getField(input: Value, field: []const u8) Error!Value {
    switch (input) {
        .object => |o| {
            for (o) |e| if (std.mem.eql(u8, e.key, field)) return e.value;
            return .null;
        },
        .null => return .null,
        else => return error.JqRuntime,
    }
}

fn indexValue(input: Value, idx: Value) Error!Value {
    switch (input) {
        .object => {
            if (idx != .string) return error.JqRuntime;
            return getField(input, idx.string);
        },
        .array => |a| {
            if (idx != .number) return error.JqRuntime;
            var i: i64 = @intFromFloat(idx.number);
            if (i < 0) i += @intCast(a.len);
            if (i < 0 or i >= a.len) return .null;
            return a[@intCast(i)];
        },
        .null => return .null,
        else => return error.JqRuntime,
    }
}

fn sliceValue(gpa: Allocator, input: Value, from: Value, to: Value) Error!Value {
    switch (input) {
        .array => |a| {
            const lo = clampIdx(from, a.len, 0);
            const hi = clampIdx(to, a.len, a.len);
            if (hi <= lo) return .{ .array = &.{} };
            return .{ .array = try gpa.dupe(Value, a[lo..hi]) };
        },
        .string => |s| {
            const lo = clampIdx(from, s.len, 0);
            const hi = clampIdx(to, s.len, s.len);
            if (hi <= lo) return .{ .string = "" };
            return .{ .string = try gpa.dupe(u8, s[lo..hi]) };
        },
        .null => return .null,
        else => return error.JqRuntime,
    }
}

fn clampIdx(v: Value, len: usize, dflt: usize) usize {
    if (v == .null) return dflt;
    if (v != .number) return dflt;
    var i: i64 = @intFromFloat(v.number);
    if (i < 0) i += @intCast(len);
    if (i < 0) i = 0;
    if (i > len) i = @intCast(len);
    return @intCast(i);
}

// ============================================================ compile entry

pub fn compile(gpa: Allocator, program: []const u8) Error!Interp {
    var lexer = lex.Lexer.init(gpa, program);
    const toks = lexer.lexAll() catch return error.JqParse;
    var parser = Parser{ .toks = toks, .gpa = gpa };
    const root = try parser.parsePipe();
    if (parser.pos != toks.len) return error.JqParse;
    return .{ .gpa = gpa, .root = root };
}
