//! The awk execution engine: runs a parsed Program over input records. Holds globals +
//! arrays + special variables + the current record's fields, and evaluates the AST from
//! interp.zig. Output goes through a caller-provided writer (the applet wires it to stdout
//! / redirect files). Matches awk-rs 0.1.0 semantics (numeric-string coercion via
//! value.zig; FS/OFS/ORS/RS handling; the common builtins).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("interp.zig");
const value = @import("value.zig");
const Value = value.Value;
const fmtnum = @import("../../core/fmtnum.zig");
const regex = @import("../regex.zig");

const Signal = enum { none, next, exit, brk, cont, ret };

pub const OutFn = *const fn (ctx: *anyopaque, bytes: []const u8) void;

const Array = std.StringHashMapUnmanaged(Value);

pub const Interp = struct {
    gpa: Allocator,
    prog: ast.AstProgram,
    globals: std.StringHashMapUnmanaged(Value) = .empty,
    arrays: std.StringHashMapUnmanaged(Array) = .empty,
    // current record
    record: []const u8 = "",
    fields: std.ArrayListUnmanaged([]const u8) = .empty,
    nf: usize = 0,
    // special vars kept as fields for speed; mirrored into globals map lazily on read
    nr: f64 = 0,
    fnr: f64 = 0,
    fs: []const u8 = " ",
    ofs: []const u8 = " ",
    ors: []const u8 = "\n",
    rs: []const u8 = "\n",
    subsep: []const u8 = "\x1c",
    filename: []const u8 = "",
    rstart: f64 = 0,
    rlength: f64 = -1,
    convfmt: []const u8 = "%.6g",
    ofmt: []const u8 = "%.6g",
    seed: u64 = 0,
    rng: std.Random.DefaultPrng = undefined,
    // control
    exit_code: u8 = 0,
    signal: Signal = .none,
    ret_val: Value = Value.UNINIT,
    range_active: []bool = &.{}, // per-rule range state
    // output
    out_ctx: *anyopaque,
    out: OutFn,
    // locals stack for function calls
    locals: ?*std.StringHashMapUnmanaged(Value) = null,
    local_arrays: ?*std.StringHashMapUnmanaged(Array) = null,

    pub fn init(gpa: Allocator, prog: ast.AstProgram, out_ctx: *anyopaque, out: OutFn) !Interp {
        var it = Interp{ .gpa = gpa, .prog = prog, .out_ctx = out_ctx, .out = out };
        it.rng = std.Random.DefaultPrng.init(0);
        it.range_active = try gpa.alloc(bool, prog.rules.len);
        @memset(it.range_active, false);
        return it;
    }

    fn write(self: *Interp, bytes: []const u8) void {
        self.out(self.out_ctx, bytes);
    }

    pub fn signal_is_exit(self: *Interp) bool {
        return self.signal == .exit;
    }

    pub fn setVarPublic(self: *Interp, name: []const u8, v: Value) void {
        self.setVar(name, v) catch {};
    }

    // -------- run phases --------

    pub fn runBegin(self: *Interp) !void {
        for (self.prog.rules) |r| {
            if (r.pat == .begin) {
                if (r.action) |a| try self.execBlock(a);
                if (self.signal == .exit) return;
            }
        }
    }

    pub fn runEnd(self: *Interp) !void {
        self.signal = .none;
        for (self.prog.rules) |r| {
            if (r.pat == .end) {
                if (r.action) |a| try self.execBlock(a);
                if (self.signal == .exit) return;
            }
        }
    }

    pub fn hasMainOrEnd(self: *Interp) bool {
        for (self.prog.rules) |r| if (r.pat != .begin) return true;
        return false;
    }

    /// Process one input record.
    pub fn runRecord(self: *Interp, rec: []const u8) !void {
        self.setRecord(rec);
        self.nr += 1;
        self.fnr += 1;
        for (self.prog.rules, 0..) |r, i| {
            const matched = switch (r.pat) {
                .begin, .end => false,
                .always => true,
                .expr => |e| (try self.eval(e)).isTruthy(),
                .range => |rg| blk: {
                    if (!self.range_active[i]) {
                        if ((try self.eval(rg.lo)).isTruthy()) {
                            self.range_active[i] = true;
                            if ((try self.eval(rg.hi)).isTruthy()) self.range_active[i] = false;
                            break :blk true;
                        }
                        break :blk false;
                    } else {
                        if ((try self.eval(rg.hi)).isTruthy()) self.range_active[i] = false;
                        break :blk true;
                    }
                },
            };
            if (matched) {
                if (r.action) |a| {
                    try self.execBlock(a);
                } else {
                    // default action: print $0
                    self.write(self.record);
                    self.write(self.ors);
                }
                if (self.signal == .next) {
                    self.signal = .none;
                    return;
                }
                if (self.signal == .exit) return;
            }
        }
    }

    // -------- records & fields --------

    fn setRecord(self: *Interp, rec: []const u8) void {
        self.record = rec;
        self.splitRecord();
    }

    fn splitRecord(self: *Interp) void {
        self.fields.clearRetainingCapacity();
        if (std.mem.eql(u8, self.fs, " ")) {
            // default: split on runs of whitespace, ignoring leading/trailing
            var it = std.mem.tokenizeAny(u8, self.record, " \t\n");
            while (it.next()) |f| self.fields.append(self.gpa, f) catch {};
        } else if (self.fs.len == 1 and self.fs[0] != ' ') {
            if (self.record.len == 0) {
                // empty record -> zero fields
            } else {
                var it = std.mem.splitScalar(u8, self.record, self.fs[0]);
                while (it.next()) |f| self.fields.append(self.gpa, f) catch {};
            }
        } else {
            // regex FS
            if (self.record.len == 0) {
                // zero fields
            } else if (regex.compile(self.gpa, self.fs, .{}, undefined)) |re_const| {
                var re = re_const;
                defer re.deinit();
                var start: usize = 0;
                var pos: usize = 0;
                while (pos <= self.record.len) {
                    if (re.find(self.record, pos)) |m| {
                        if (m.end == m.start) {
                            pos += 1;
                            continue;
                        }
                        self.fields.append(self.gpa, self.record[start..m.start]) catch {};
                        start = m.end;
                        pos = m.end;
                    } else break;
                }
                self.fields.append(self.gpa, self.record[start..]) catch {};
            } else |_| {
                self.fields.append(self.gpa, self.record) catch {};
            }
        }
        self.nf = self.fields.items.len;
    }

    fn getField(self: *Interp, n: usize) []const u8 {
        if (n == 0) return self.record;
        if (n <= self.fields.items.len) return self.fields.items[n - 1];
        return "";
    }

    fn setField(self: *Interp, n: usize, val: []const u8) !void {
        if (n == 0) {
            self.record = try self.gpa.dupe(u8, val);
            self.splitRecord();
            return;
        }
        while (self.fields.items.len < n) try self.fields.append(self.gpa, "");
        self.fields.items[n - 1] = try self.gpa.dupe(u8, val);
        if (n > self.nf) self.nf = n;
        try self.rebuildRecord();
    }

    fn rebuildRecord(self: *Interp) !void {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < self.nf) : (i += 1) {
            if (i != 0) try buf.appendSlice(self.gpa, self.ofs);
            try buf.appendSlice(self.gpa, if (i < self.fields.items.len) self.fields.items[i] else "");
        }
        self.record = buf.items;
    }

    // -------- statement execution --------

    fn execBlock(self: *Interp, stmts: []*ast.AstStmt) anyerror!void {
        for (stmts) |s| {
            try self.execStmt(s);
            if (self.signal != .none) return;
        }
    }

    fn execStmt(self: *Interp, s: *ast.AstStmt) anyerror!void {
        switch (s.*) {
            .expr => |e| _ = try self.eval(e),
            .block => |b| try self.execBlock(b),
            .print => |p| try self.doPrint(p.args, p.redir),
            .printf => |p| try self.doPrintf(p.args, p.redir),
            .@"if" => |f| {
                if ((try self.eval(f.c)).isTruthy()) {
                    try self.execStmt(f.then);
                } else if (f.els) |e| try self.execStmt(e);
            },
            .@"while" => |w| {
                while ((try self.eval(w.c)).isTruthy()) {
                    try self.execStmt(w.body);
                    if (self.loopSignal()) break;
                }
            },
            .do => |d| {
                while (true) {
                    try self.execStmt(d.body);
                    if (self.loopSignal()) break;
                    if (!(try self.eval(d.c)).isTruthy()) break;
                }
            },
            .@"for" => |f| {
                if (f.init) |i| try self.execStmt(i);
                while (f.c == null or (try self.eval(f.c.?)).isTruthy()) {
                    try self.execStmt(f.body);
                    if (self.loopSignal()) break;
                    if (f.post) |p| try self.execStmt(p);
                }
            },
            .for_in => |f| {
                const arr = try self.getArray(f.arr);
                var keys: std.ArrayListUnmanaged([]const u8) = .empty;
                var it = arr.iterator();
                while (it.next()) |kv| try keys.append(self.gpa, kv.key_ptr.*);
                for (keys.items) |k| {
                    try self.setVar(f.v, Value.fromStr(k));
                    try self.execStmt(f.body);
                    if (self.loopSignal()) break;
                }
            },
            .next => self.signal = .next,
            .exit => |e| {
                if (e) |ex| self.exit_code = @intFromFloat(@mod((try self.eval(ex)).toNumber(), 256));
                self.signal = .exit;
            },
            .@"return" => |e| {
                self.ret_val = if (e) |ex| try self.eval(ex) else Value.UNINIT;
                self.signal = .ret;
            },
            .@"break" => self.signal = .brk,
            .@"continue" => self.signal = .cont,
            .delete => |d| {
                const arr = try self.getArrayPtr(d.name);
                if (d.subs.len == 0) {
                    arr.clearRetainingCapacity();
                } else {
                    const key = try self.subKey(d.subs);
                    _ = arr.remove(key);
                }
            },
            .getline_stmt => |e| _ = try self.eval(e),
        }
    }

    fn loopSignal(self: *Interp) bool {
        switch (self.signal) {
            .brk => {
                self.signal = .none;
                return true;
            },
            .cont => {
                self.signal = .none;
                return false;
            },
            .none => return false,
            else => return true, // next/exit/ret propagate
        }
    }

    fn doPrint(self: *Interp, args: []*ast.AstExpr, redir: ?ast.AstRedir) anyerror!void {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        if (args.len == 0) {
            try buf.appendSlice(self.gpa, self.record);
        } else {
            for (args, 0..) |a, i| {
                if (i != 0) try buf.appendSlice(self.gpa, self.ofs);
                const v = try self.eval(a);
                try buf.appendSlice(self.gpa, try self.toOutputStr(v));
            }
        }
        try buf.appendSlice(self.gpa, self.ors);
        try self.emit(buf.items, redir);
    }

    fn doPrintf(self: *Interp, args: []*ast.AstExpr, redir: ?ast.AstRedir) anyerror!void {
        if (args.len == 0) return;
        const fmt = try self.evalStr(args[0]);
        const out = try self.sprintf(fmt, args[1..]);
        try self.emit(out, redir);
    }

    fn emit(self: *Interp, bytes: []const u8, redir: ?ast.AstRedir) anyerror!void {
        _ = redir; // redirection to files/pipes is a documented deferral (ledgered)
        self.write(bytes);
    }

    fn toOutputStr(self: *Interp, v: Value) ![]const u8 {
        // Numbers use OFMT for non-integers in output context.
        switch (v) {
            .number => |n| {
                if (n == @floor(n) and std.math.isFinite(n) and @abs(n) < 1e16) {
                    var b: [64]u8 = undefined;
                    return self.gpa.dupe(u8, std.fmt.bufPrint(&b, "{d}", .{@as(i64, @intFromFloat(n))}) catch "0");
                }
                return self.sprintfOne(self.ofmt, n);
            },
            else => return v.toStringValAlloc(self.gpa),
        }
    }

    // -------- expression evaluation --------

    fn eval(self: *Interp, e: *ast.AstExpr) anyerror!Value {
        switch (e.*) {
            .num => |n| return Value.fromNumber(n),
            .str => |s| return .{ .string = s },
            .ere => |re| return Value.fromNumber(if (try self.matchRe(self.record, re)) 1 else 0),
            .grouping => |g| return self.eval(g),
            .field => |f| {
                const n: usize = @intFromFloat(@max(0, (try self.eval(f)).toNumber()));
                return Value.fromStr(self.getField(n));
            },
            .variable => |name| return self.getVar(name),
            .index => |ix| {
                const arr = try self.getArrayPtr(ix.name);
                const key = try self.subKey(ix.subs);
                if (arr.get(key)) |v| return v;
                try arr.put(self.gpa, try self.gpa.dupe(u8, key), Value.UNINIT);
                return Value.UNINIT;
            },
            .assign => |a| return self.evalAssign(a.op, a.target, a.val),
            .binary => |b| return self.evalBinary(b.op, b.l, b.r),
            .unary => |u| {
                const v = try self.eval(u.e);
                return switch (u.op) {
                    '!' => Value.fromNumber(if (v.isTruthy()) 0 else 1),
                    '-' => Value.fromNumber(-v.toNumber()),
                    '+' => Value.fromNumber(v.toNumber()),
                    else => Value.UNINIT,
                };
            },
            .incdec => |id| {
                const old = (try self.evalLvalue(id.target)).toNumber();
                const new = if (id.op == '+') old + 1 else old - 1;
                try self.storeLvalue(id.target, Value.fromNumber(new));
                return Value.fromNumber(if (id.pre) new else old);
            },
            .ternary => |t| return if ((try self.eval(t.c)).isTruthy()) self.eval(t.a) else self.eval(t.b),
            .match => |m| {
                const s = try self.evalStr(m.l);
                const re = try self.evalReSource(m.r);
                const matched = try self.matchRe(s, re);
                return Value.fromNumber(if (matched != m.neg) 1 else 0);
            },
            .concat => |c| {
                const l = try self.evalStr(c.l);
                const r = try self.evalStr(c.r);
                const out = try self.gpa.alloc(u8, l.len + r.len);
                @memcpy(out[0..l.len], l);
                @memcpy(out[l.len..], r);
                return Value.fromStr(out);
            },
            .in => |i| {
                const arr = try self.getArrayPtr(i.arr);
                const key = try self.subKey(i.key);
                return Value.fromNumber(if (arr.contains(key)) 1 else 0);
            },
            .builtin => |b| return self.callBuiltin(b.name, b.args),
            .call => |c| return self.callFunc(c.name, c.args),
            .getline => |g| return self.doGetline(g.target),
        }
    }

    fn evalStr(self: *Interp, e: *ast.AstExpr) anyerror![]const u8 {
        const v = try self.eval(e);
        return self.valStr(v);
    }

    fn valStr(self: *Interp, v: Value) ![]const u8 {
        switch (v) {
            .number => |n| {
                if (n == @floor(n) and std.math.isFinite(n) and @abs(n) < 1e16) {
                    var b: [64]u8 = undefined;
                    return self.gpa.dupe(u8, std.fmt.bufPrint(&b, "{d}", .{@as(i64, @intFromFloat(n))}) catch "0");
                }
                return self.sprintfOne(self.convfmt, n);
            },
            else => return v.toStringValAlloc(self.gpa),
        }
    }

    fn evalReSource(self: *Interp, e: *ast.AstExpr) ![]const u8 {
        return switch (e.*) {
            .ere => |re| re,
            else => try self.evalStr(e),
        };
    }

    fn evalBinary(self: *Interp, op: []const u8, le: *ast.AstExpr, re: *ast.AstExpr) anyerror!Value {
        if (std.mem.eql(u8, op, "&&")) {
            if (!(try self.eval(le)).isTruthy()) return Value.fromNumber(0);
            return Value.fromNumber(if ((try self.eval(re)).isTruthy()) 1 else 0);
        }
        if (std.mem.eql(u8, op, "||")) {
            if ((try self.eval(le)).isTruthy()) return Value.fromNumber(1);
            return Value.fromNumber(if ((try self.eval(re)).isTruthy()) 1 else 0);
        }
        const l = try self.eval(le);
        const r = try self.eval(re);
        // comparisons
        const cmp = struct {
            fn f(o: []const u8) ?u8 {
                if (std.mem.eql(u8, o, "<")) return '<';
                if (std.mem.eql(u8, o, "<=")) return 'l';
                if (std.mem.eql(u8, o, ">")) return '>';
                if (std.mem.eql(u8, o, ">=")) return 'g';
                if (std.mem.eql(u8, o, "==")) return '=';
                if (std.mem.eql(u8, o, "!=")) return 'n';
                return null;
            }
        }.f(op);
        if (cmp) |c| {
            const ord = value.compare(l, r);
            const res: bool = switch (c) {
                '<' => ord == .lt,
                'l' => ord != .gt,
                '>' => ord == .gt,
                'g' => ord != .lt,
                '=' => ord == .eq,
                'n' => ord != .eq,
                else => false,
            };
            return Value.fromNumber(if (res) 1 else 0);
        }
        const a = l.toNumber();
        const b = r.toNumber();
        const n: f64 = switch (op[0]) {
            '+' => a + b,
            '-' => a - b,
            '*' => a * b,
            '/' => a / b,
            '%' => @rem(a, b),
            '^' => std.math.pow(f64, a, b),
            else => 0,
        };
        return Value.fromNumber(n);
    }

    fn evalAssign(self: *Interp, op: u8, target: *ast.AstExpr, val: *ast.AstExpr) anyerror!Value {
        var v = try self.eval(val);
        if (op != '=') {
            const cur = (try self.evalLvalue(target)).toNumber();
            const rv = v.toNumber();
            const n: f64 = switch (op) {
                '+' => cur + rv,
                '-' => cur - rv,
                '*' => cur * rv,
                '/' => cur / rv,
                '%' => @rem(cur, rv),
                '^' => std.math.pow(f64, cur, rv),
                else => rv,
            };
            v = Value.fromNumber(n);
        }
        try self.storeLvalue(target, v);
        return v;
    }

    fn evalLvalue(self: *Interp, target: *ast.AstExpr) anyerror!Value {
        return self.eval(target);
    }

    fn storeLvalue(self: *Interp, target: *ast.AstExpr, v: Value) anyerror!void {
        switch (target.*) {
            .variable => |name| try self.setVar(name, v),
            .field => |f| {
                const n: usize = @intFromFloat(@max(0, (try self.eval(f)).toNumber()));
                try self.setField(n, try self.valStr(v));
            },
            .index => |ix| {
                const arr = try self.getArrayPtr(ix.name);
                const key = try self.subKey(ix.subs);
                const owned_key = if (arr.contains(key)) key else try self.gpa.dupe(u8, key);
                try arr.put(self.gpa, owned_key, v);
            },
            .grouping => |g| try self.storeLvalue(g, v),
            else => return error.Runtime,
        }
    }

    // -------- variables & arrays --------

    fn getVar(self: *Interp, name: []const u8) Value {
        if (self.locals) |l| if (l.get(name)) |v| return v;
        // special variables
        if (std.mem.eql(u8, name, "NR")) return Value.fromNumber(self.nr);
        if (std.mem.eql(u8, name, "NF")) return Value.fromNumber(@floatFromInt(self.nf));
        if (std.mem.eql(u8, name, "FNR")) return Value.fromNumber(self.fnr);
        if (std.mem.eql(u8, name, "FS")) return Value.fromStr(self.fs);
        if (std.mem.eql(u8, name, "OFS")) return Value.fromStr(self.ofs);
        if (std.mem.eql(u8, name, "ORS")) return Value.fromStr(self.ors);
        if (std.mem.eql(u8, name, "RS")) return Value.fromStr(self.rs);
        if (std.mem.eql(u8, name, "SUBSEP")) return Value.fromStr(self.subsep);
        if (std.mem.eql(u8, name, "FILENAME")) return Value.fromStr(self.filename);
        if (std.mem.eql(u8, name, "RSTART")) return Value.fromNumber(self.rstart);
        if (std.mem.eql(u8, name, "RLENGTH")) return Value.fromNumber(self.rlength);
        if (std.mem.eql(u8, name, "CONVFMT")) return Value.fromStr(self.convfmt);
        if (std.mem.eql(u8, name, "OFMT")) return Value.fromStr(self.ofmt);
        if (self.globals.get(name)) |v| return v;
        return Value.UNINIT;
    }

    fn setVar(self: *Interp, name: []const u8, v: Value) !void {
        if (self.locals) |l| {
            if (l.getPtr(name)) |p| {
                p.* = v;
                return;
            }
        }
        if (std.mem.eql(u8, name, "NF")) {
            const newnf: usize = @intFromFloat(@max(0, v.toNumber()));
            if (newnf < self.nf) {
                self.fields.shrinkRetainingCapacity(@min(newnf, self.fields.items.len));
            } else {
                while (self.fields.items.len < newnf) try self.fields.append(self.gpa, "");
            }
            self.nf = newnf;
            try self.rebuildRecord();
            return;
        }
        if (std.mem.eql(u8, name, "NR")) {
            self.nr = v.toNumber();
            return;
        }
        if (std.mem.eql(u8, name, "FNR")) {
            self.fnr = v.toNumber();
            return;
        }
        const strv = try self.valStr(v);
        if (std.mem.eql(u8, name, "FS")) {
            self.fs = strv;
            return;
        }
        if (std.mem.eql(u8, name, "OFS")) {
            self.ofs = strv;
            return;
        }
        if (std.mem.eql(u8, name, "ORS")) {
            self.ors = strv;
            return;
        }
        if (std.mem.eql(u8, name, "RS")) {
            self.rs = strv;
            return;
        }
        if (std.mem.eql(u8, name, "SUBSEP")) {
            self.subsep = strv;
            return;
        }
        if (std.mem.eql(u8, name, "FILENAME")) {
            self.filename = strv;
            return;
        }
        if (std.mem.eql(u8, name, "CONVFMT")) {
            self.convfmt = strv;
            return;
        }
        if (std.mem.eql(u8, name, "OFMT")) {
            self.ofmt = strv;
            return;
        }
        if (std.mem.eql(u8, name, "RSTART")) {
            self.rstart = v.toNumber();
            return;
        }
        if (std.mem.eql(u8, name, "RLENGTH")) {
            self.rlength = v.toNumber();
            return;
        }
        try self.globals.put(self.gpa, name, v);
    }

    fn getArray(self: *Interp, name: []const u8) !Array {
        return (try self.getArrayPtr(name)).*;
    }

    fn getArrayPtr(self: *Interp, name: []const u8) !*Array {
        if (self.local_arrays) |la| {
            if (la.getPtr(name)) |p| return p;
        }
        const gop = try self.arrays.getOrPut(self.gpa, name);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    fn subKey(self: *Interp, subs: []*ast.AstExpr) ![]const u8 {
        if (subs.len == 1) return self.evalStr(subs[0]);
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        for (subs, 0..) |s, i| {
            if (i != 0) try buf.appendSlice(self.gpa, self.subsep);
            try buf.appendSlice(self.gpa, try self.evalStr(s));
        }
        return buf.items;
    }

    // -------- regex helpers --------

    fn matchRe(self: *Interp, s: []const u8, pattern: []const u8) !bool {
        var diag: regex.Diag = .{};
        var re = regex.compile(self.gpa, pattern, .{}, &diag) catch return false;
        defer re.deinit();
        return re.find(s, 0) != null;
    }

    // -------- builtins --------

    fn callBuiltin(self: *Interp, name: []const u8, args: []*ast.AstExpr) anyerror!Value {
        if (std.mem.eql(u8, name, "length")) {
            if (args.len == 0) return Value.fromNumber(@floatFromInt(self.record.len));
            // length(arr) not distinguished; treat as string length
            const s = try self.evalStr(args[0]);
            return Value.fromNumber(@floatFromInt(s.len));
        }
        if (std.mem.eql(u8, name, "substr")) {
            const s = try self.evalStr(args[0]);
            const m = (try self.eval(args[1])).toNumber();
            var start = @as(i64, @intFromFloat(m));
            var len: i64 = if (args.len >= 3) @intFromFloat((try self.eval(args[2])).toNumber()) else @as(i64, @intCast(s.len)) - start + 1;
            // awk is 1-based; clamp
            if (start < 1) {
                len += start - 1;
                start = 1;
            }
            if (len < 0) len = 0;
            const si: usize = @intCast(@min(@max(start - 1, 0), @as(i64, @intCast(s.len))));
            const ei: usize = @intCast(@min(@as(i64, @intCast(si)) + len, @as(i64, @intCast(s.len))));
            return Value.fromStr(try self.gpa.dupe(u8, s[si..ei]));
        }
        if (std.mem.eql(u8, name, "index")) {
            const s = try self.evalStr(args[0]);
            const t = try self.evalStr(args[1]);
            if (std.mem.indexOf(u8, s, t)) |idx| return Value.fromNumber(@floatFromInt(idx + 1));
            return Value.fromNumber(0);
        }
        if (std.mem.eql(u8, name, "toupper") or std.mem.eql(u8, name, "tolower")) {
            const s = try self.evalStr(args[0]);
            const out = try self.gpa.dupe(u8, s);
            const up = std.mem.eql(u8, name, "toupper");
            for (out) |*c| c.* = if (up) std.ascii.toUpper(c.*) else std.ascii.toLower(c.*);
            return Value.fromStr(out);
        }
        if (std.mem.eql(u8, name, "sprintf")) {
            const fmt = try self.evalStr(args[0]);
            return Value.fromStr(try self.sprintf(fmt, args[1..]));
        }
        if (std.mem.eql(u8, name, "split")) return self.doSplit(args);
        if (std.mem.eql(u8, name, "sub")) return self.doSub(args, false);
        if (std.mem.eql(u8, name, "gsub")) return self.doSub(args, true);
        if (std.mem.eql(u8, name, "match")) return self.doMatch(args);
        // math
        if (std.mem.eql(u8, name, "int")) return Value.fromNumber(@trunc((try self.eval(args[0])).toNumber()));
        if (std.mem.eql(u8, name, "sqrt")) return Value.fromNumber(@sqrt((try self.eval(args[0])).toNumber()));
        if (std.mem.eql(u8, name, "sin")) return Value.fromNumber(@sin((try self.eval(args[0])).toNumber()));
        if (std.mem.eql(u8, name, "cos")) return Value.fromNumber(@cos((try self.eval(args[0])).toNumber()));
        if (std.mem.eql(u8, name, "exp")) return Value.fromNumber(@exp((try self.eval(args[0])).toNumber()));
        if (std.mem.eql(u8, name, "log")) return Value.fromNumber(@log((try self.eval(args[0])).toNumber()));
        if (std.mem.eql(u8, name, "atan2")) return Value.fromNumber(std.math.atan2((try self.eval(args[0])).toNumber(), (try self.eval(args[1])).toNumber()));
        if (std.mem.eql(u8, name, "rand")) return Value.fromNumber(self.rng.random().float(f64));
        if (std.mem.eql(u8, name, "srand")) {
            const old = self.seed;
            self.seed = if (args.len >= 1) @intFromFloat(@abs((try self.eval(args[0])).toNumber())) else @as(u64, @intFromFloat(self.nr));
            self.rng = std.Random.DefaultPrng.init(self.seed);
            return Value.fromNumber(@floatFromInt(old));
        }
        if (std.mem.eql(u8, name, "system") or std.mem.eql(u8, name, "close")) {
            return Value.fromNumber(0); // deferred (ledgered)
        }
        return error.Runtime;
    }

    fn doSplit(self: *Interp, args: []*ast.AstExpr) !Value {
        const s = try self.evalStr(args[0]);
        const arr_name = switch (args[1].*) {
            .variable => |n| n,
            .index => |ix| ix.name,
            else => return error.Runtime,
        };
        const arr = try self.getArrayPtr(arr_name);
        arr.clearRetainingCapacity();
        const sep: []const u8 = if (args.len >= 3) try self.evalReSource(args[2]) else self.fs;
        var count: usize = 0;
        if (s.len == 0) return Value.fromNumber(0);
        if (std.mem.eql(u8, sep, " ")) {
            var it = std.mem.tokenizeAny(u8, s, " \t\n");
            while (it.next()) |f| {
                count += 1;
                try self.arrPutIdx(arr, count, f);
            }
        } else if (sep.len == 1) {
            var it = std.mem.splitScalar(u8, s, sep[0]);
            while (it.next()) |f| {
                count += 1;
                try self.arrPutIdx(arr, count, f);
            }
        } else {
            var re = regex.compile(self.gpa, sep, .{}, undefined) catch {
                count += 1;
                try self.arrPutIdx(arr, count, s);
                return Value.fromNumber(@floatFromInt(count));
            };
            defer re.deinit();
            var start: usize = 0;
            var pos: usize = 0;
            while (pos <= s.len) {
                if (re.find(s, pos)) |mm| {
                    if (mm.end == mm.start) {
                        pos += 1;
                        continue;
                    }
                    count += 1;
                    try self.arrPutIdx(arr, count, s[start..mm.start]);
                    start = mm.end;
                    pos = mm.end;
                } else break;
            }
            count += 1;
            try self.arrPutIdx(arr, count, s[start..]);
        }
        return Value.fromNumber(@floatFromInt(count));
    }

    fn arrPutIdx(self: *Interp, arr: *Array, idx: usize, val: []const u8) !void {
        var kb: [32]u8 = undefined;
        const key = try self.gpa.dupe(u8, std.fmt.bufPrint(&kb, "{d}", .{idx}) catch "0");
        try arr.put(self.gpa, key, Value.fromStr(try self.gpa.dupe(u8, val)));
    }

    fn doMatch(self: *Interp, args: []*ast.AstExpr) !Value {
        const s = try self.evalStr(args[0]);
        const pat = try self.evalReSource(args[1]);
        var re = regex.compile(self.gpa, pat, .{}, undefined) catch {
            self.rstart = 0;
            self.rlength = -1;
            return Value.fromNumber(0);
        };
        defer re.deinit();
        if (re.find(s, 0)) |m| {
            self.rstart = @floatFromInt(m.start + 1);
            self.rlength = @floatFromInt(m.end - m.start);
            return Value.fromNumber(self.rstart);
        }
        self.rstart = 0;
        self.rlength = -1;
        return Value.fromNumber(0);
    }

    fn doSub(self: *Interp, args: []*ast.AstExpr, global: bool) !Value {
        const pat = try self.evalReSource(args[0]);
        const repl = try self.evalStr(args[1]);
        const target = if (args.len >= 3) args[2] else undefined;
        const has_target = args.len >= 3;
        const s = if (has_target) try self.evalStr(target) else self.record;
        var re = regex.compile(self.gpa, pat, .{}, undefined) catch return Value.fromNumber(0);
        defer re.deinit();
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var count: usize = 0;
        var pos: usize = 0;
        while (pos <= s.len) {
            if (re.find(s, pos)) |m| {
                try out.appendSlice(self.gpa, s[pos..m.start]);
                // replacement: & = matched text, \& = literal &
                var i: usize = 0;
                while (i < repl.len) : (i += 1) {
                    if (repl[i] == '&') {
                        try out.appendSlice(self.gpa, s[m.start..m.end]);
                    } else if (repl[i] == '\\' and i + 1 < repl.len and repl[i + 1] == '&') {
                        try out.append(self.gpa, '&');
                        i += 1;
                    } else {
                        try out.append(self.gpa, repl[i]);
                    }
                }
                count += 1;
                if (m.end == m.start) {
                    if (m.end < s.len) try out.append(self.gpa, s[m.end]);
                    pos = m.end + 1;
                } else {
                    pos = m.end;
                }
                if (!global) {
                    try out.appendSlice(self.gpa, s[pos..]);
                    break;
                }
            } else {
                try out.appendSlice(self.gpa, s[pos..]);
                break;
            }
        }
        if (count > 0) {
            if (has_target) {
                try self.storeLvalue(target, Value.fromStr(out.items));
            } else {
                try self.setField(0, out.items);
            }
        }
        return Value.fromNumber(@floatFromInt(count));
    }

    // -------- user functions --------

    fn callFunc(self: *Interp, name: []const u8, args: []*ast.AstExpr) anyerror!Value {
        const func = for (self.prog.funcs) |f| {
            if (std.mem.eql(u8, f.name, name)) break f;
        } else return error.Runtime;

        var locals: std.StringHashMapUnmanaged(Value) = .empty;
        var local_arrays: std.StringHashMapUnmanaged(Array) = .empty;
        // Bind parameters. Extra params are locals (uninitialized). Array args pass by ref
        // is approximated: we detect a bare-variable arg naming an existing/absent array by
        // whether the param is used as an array — simplification: scalars by value, and a
        // bare-ident arg is also exposed as a shared array alias.
        for (func.params, 0..) |p, i| {
            if (i < args.len) {
                switch (args[i].*) {
                    .variable => |vn| {
                        // could be scalar or array; bind scalar value, and alias array
                        try locals.put(self.gpa, p, self.getVar(vn));
                        if (self.arrays.getPtr(vn)) |ap| try local_arrays.put(self.gpa, p, ap.*);
                    },
                    else => try locals.put(self.gpa, p, try self.eval(args[i])),
                }
            } else {
                try locals.put(self.gpa, p, Value.UNINIT);
            }
        }
        const saved_locals = self.locals;
        const saved_arrays = self.local_arrays;
        self.locals = &locals;
        self.local_arrays = &local_arrays;
        defer {
            self.locals = saved_locals;
            self.local_arrays = saved_arrays;
        }
        try self.execBlock(func.body);
        const rv = if (self.signal == .ret) self.ret_val else Value.UNINIT;
        if (self.signal == .ret) self.signal = .none;
        return rv;
    }

    // -------- getline (stdin/current stream only; file/pipe deferred) --------

    fn doGetline(self: *Interp, target: ?*ast.AstExpr) anyerror!Value {
        _ = target;
        _ = self;
        return Value.fromNumber(0); // deferred (ledgered): only main-loop record iteration
    }

    // -------- sprintf (awk printf semantics over fmtnum) --------

    fn sprintfOne(self: *Interp, fmt: []const u8, n: f64) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try self.renderFmt(&buf, fmt, &.{}, n);
        return buf.items;
    }

    fn sprintf(self: *Interp, fmt: []const u8, args: []*ast.AstExpr) ![]const u8 {
        var vals: std.ArrayListUnmanaged(Value) = .empty;
        for (args) |a| try vals.append(self.gpa, try self.eval(a));
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try self.renderFmt(&buf, fmt, vals.items, 0);
        return buf.items;
    }

    /// Minimal printf: walks `fmt`, handling %[flags][width][.prec]conv for
    /// d i o x X u c s e E f g G %. Uses core/fmtnum for numeric conversions.
    fn renderFmt(self: *Interp, buf: *std.ArrayListUnmanaged(u8), fmt: []const u8, vals: []Value, single: f64) anyerror!void {
        var ai: usize = 0;
        var single_used = false;
        var i: usize = 0;
        while (i < fmt.len) : (i += 1) {
            if (fmt[i] != '%') {
                try buf.append(self.gpa, fmt[i]);
                continue;
            }
            const spec_start = i;
            i += 1;
            if (i < fmt.len and fmt[i] == '%') {
                try buf.append(self.gpa, '%');
                continue;
            }
            // scan flags/width/.prec
            while (i < fmt.len and (fmt[i] == '-' or fmt[i] == '+' or fmt[i] == ' ' or fmt[i] == '0' or fmt[i] == '#')) i += 1;
            while (i < fmt.len and isDigitB(fmt[i])) i += 1;
            if (i < fmt.len and fmt[i] == '.') {
                i += 1;
                while (i < fmt.len and isDigitB(fmt[i])) i += 1;
            }
            if (i >= fmt.len) {
                try buf.appendSlice(self.gpa, fmt[spec_start..]);
                break;
            }
            const conv = fmt[i];
            const spec = fmt[spec_start .. i + 1];
            const nextVal = struct {
                fn f(it: *Interp, vs: []Value, idx: *usize, sng: f64, used: *bool) Value {
                    _ = it;
                    if (vs.len == 0) {
                        used.* = true;
                        return Value.fromNumber(sng);
                    }
                    if (idx.* < vs.len) {
                        const v = vs[idx.*];
                        idx.* += 1;
                        return v;
                    }
                    return Value.UNINIT;
                }
            }.f;
            switch (conv) {
                'd', 'i' => {
                    const v = nextVal(self, vals, &ai, single, &single_used);
                    try self.emitNumConv(buf, spec, 'd', v.toNumber());
                },
                'o', 'x', 'X', 'u' => {
                    const v = nextVal(self, vals, &ai, single, &single_used);
                    try self.emitNumConv(buf, spec, conv, v.toNumber());
                },
                'e', 'E', 'f', 'F', 'g', 'G' => {
                    const v = nextVal(self, vals, &ai, single, &single_used);
                    try self.emitFloatConv(buf, spec, v.toNumber());
                },
                'c' => {
                    const v = nextVal(self, vals, &ai, single, &single_used);
                    switch (v) {
                        .string, .numeric_string => {
                            const s = v.toStringVal(&[0]u8{});
                            if (s.len > 0) try buf.append(self.gpa, s[0]);
                        },
                        else => {
                            const n: u8 = @intCast(@as(u64, @intFromFloat(@mod(v.toNumber(), 256))));
                            try buf.append(self.gpa, n);
                        },
                    }
                },
                's' => {
                    const v = nextVal(self, vals, &ai, single, &single_used);
                    const s = try self.valStr(v);
                    try self.emitStrConv(buf, spec, s);
                },
                else => try buf.appendSlice(self.gpa, spec),
            }
        }
    }

    fn emitNumConv(self: *Interp, buf: *std.ArrayListUnmanaged(u8), spec_str: []const u8, conv: u8, n: f64) !void {
        const spec = fmtnum.parseSpec(spec_str);
        var sink = fmtnum.ListSink{ .gpa = self.gpa, .list = buf };
        if (conv == 'u' or conv == 'o' or conv == 'x' or conv == 'X') {
            const u: u64 = if (n < 0) @bitCast(@as(i64, @intFromFloat(n))) else @intFromFloat(@min(n, 1.8e19));
            fmtnum.emitUint(&sink, spec, u) catch {};
        } else {
            fmtnum.emitInt(&sink, spec, @intFromFloat(@max(-9.2e18, @min(n, 9.2e18)))) catch {};
        }
    }

    fn emitFloatConv(self: *Interp, buf: *std.ArrayListUnmanaged(u8), spec_str: []const u8, n: f64) !void {
        const spec = fmtnum.parseSpec(spec_str);
        var sink = fmtnum.ListSink{ .gpa = self.gpa, .list = buf };
        fmtnum.emitFloat(&sink, spec, n) catch {};
    }

    fn emitStrConv(self: *Interp, buf: *std.ArrayListUnmanaged(u8), spec_str: []const u8, str: []const u8) !void {
        const spec = fmtnum.parseSpec(spec_str);
        var sink = fmtnum.ListSink{ .gpa = self.gpa, .list = buf };
        fmtnum.emitStr(&sink, spec, str) catch {};
    }
};

fn isDigitB(c: u8) bool {
    return c >= '0' and c <= '9';
}
