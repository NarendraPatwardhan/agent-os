//! Word expansion: tilde, parameter/command/arithmetic, IFS splitting, globbing.

const std = @import("std");
const glob = @import("glob.zig");
const word = @import("word.zig");

pub const ExpandError = std.mem.Allocator.Error || error{
    AmbiguousRedirectEmpty,
    AmbiguousRedirectMultiple,
    Parameter,
};

pub const ExpandContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (*anyopaque, std.mem.Allocator, []const u8) ?[]const u8,
        set: *const fn (*anyopaque, []const u8, []const u8) void,
        special: *const fn (*anyopaque, std.mem.Allocator, []const u8) ?[]const u8,
        positionals: *const fn (*anyopaque, std.mem.Allocator) []const []const u8,
        command_subst: *const fn (*anyopaque, std.mem.Allocator, []const u8) []const u8,
        arith: *const fn (*anyopaque, std.mem.Allocator, []const u8) i64,
        list_dir: *const fn (*anyopaque, std.mem.Allocator, []const u8) ?[]const []const u8,
        cwd: *const fn (*anyopaque, std.mem.Allocator) []const u8,
        ifs: *const fn (*anyopaque, std.mem.Allocator) []const u8,
        home: *const fn (*anyopaque, std.mem.Allocator) ?[]const u8,
    };

    pub fn get(self: *ExpandContext, allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
        if (self.vtable.special(self.ptr, allocator, name)) |v| return v;
        return self.vtable.get(self.ptr, allocator, name);
    }

    pub fn set(self: *ExpandContext, name: []const u8, value: []const u8) void {
        self.vtable.set(self.ptr, name, value);
    }

    pub fn positionals(self: *ExpandContext, allocator: std.mem.Allocator) []const []const u8 {
        return self.vtable.positionals(self.ptr, allocator);
    }

    pub fn commandSubst(self: *ExpandContext, allocator: std.mem.Allocator, raw: []const u8) []const u8 {
        return self.vtable.command_subst(self.ptr, allocator, raw);
    }

    pub fn arith(self: *ExpandContext, allocator: std.mem.Allocator, raw: []const u8) i64 {
        return self.vtable.arith(self.ptr, allocator, raw);
    }

    pub fn listDir(self: *ExpandContext, allocator: std.mem.Allocator, path: []const u8) ?[]const []const u8 {
        return self.vtable.list_dir(self.ptr, allocator, path);
    }

    pub fn cwd(self: *ExpandContext, allocator: std.mem.Allocator) []const u8 {
        return self.vtable.cwd(self.ptr, allocator);
    }

    pub fn ifs(self: *ExpandContext, allocator: std.mem.Allocator) []const u8 {
        return self.vtable.ifs(self.ptr, allocator);
    }

    pub fn home(self: *ExpandContext, allocator: std.mem.Allocator) ?[]const u8 {
        return self.vtable.home(self.ptr, allocator);
    }
};

const Field = struct {
    text: []const u8,
    active: []const bool,
};

const FieldBuilder = struct {
    fields: std.ArrayList(Field) = .empty,
    cur_text: std.ArrayList(u8) = .empty,
    cur_active: std.ArrayList(bool) = .empty,
    started: bool = false,

    fn flush(self: *FieldBuilder, allocator: std.mem.Allocator) !void {
        if (!self.started) return;
        try self.fields.append(allocator, .{
            .text = try self.cur_text.toOwnedSlice(allocator),
            .active = try self.cur_active.toOwnedSlice(allocator),
        });
        self.cur_text = .empty;
        self.cur_active = .empty;
        self.started = false;
    }

    fn pushUnsplit(self: *FieldBuilder, allocator: std.mem.Allocator, bytes: []const u8, glob_active: bool) !void {
        try self.cur_text.appendSlice(allocator, bytes);
        for (bytes) |_| try self.cur_active.append(allocator, glob_active);
        self.started = true;
    }

    fn pushSplit(self: *FieldBuilder, allocator: std.mem.Allocator, bytes: []const u8, glob_active: bool, ifs: []const u8) !void {
        var i: usize = 0;
        while (i < bytes.len) {
            if (containsByte(ifs, bytes[i])) {
                if (self.started) try self.flush(allocator);
                while (i < bytes.len and containsByte(ifs, bytes[i])) i += 1;
                continue;
            }
            try self.cur_text.append(allocator, bytes[i]);
            try self.cur_active.append(allocator, glob_active);
            self.started = true;
            i += 1;
        }
    }

    fn finish(self: *FieldBuilder, allocator: std.mem.Allocator) ![]const Field {
        try self.flush(allocator);
        return self.fields.toOwnedSlice(allocator);
    }
};

pub fn expandToFields(allocator: std.mem.Allocator, input: word.Word, ctx: *ExpandContext) ExpandError![]const []const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const ifs = ctx.ifs(scratch);
    const expanded_word = try applyTilde(scratch, input, ctx);
    var builder = FieldBuilder{};

    for (expanded_word) |part| {
        switch (part) {
            .lit => |lit| try builder.pushUnsplit(scratch, lit.text, !lit.from_quote),
            .sub => |sub| {
                const out = ctx.commandSubst(scratch, sub.raw);
                if (sub.quoted) {
                    try builder.pushUnsplit(scratch, out, false);
                } else {
                    try builder.pushSplit(scratch, out, true, ifs);
                }
            },
            .arith => |arith_part| {
                const value = try std.fmt.allocPrint(scratch, "{d}", .{ctx.arith(scratch, arith_part.raw)});
                if (arith_part.quoted) {
                    try builder.pushUnsplit(scratch, value, false);
                } else {
                    try builder.pushSplit(scratch, value, true, ifs);
                }
            },
            .param => |param| try expandVarInto(scratch, &builder, param.name, param.op, param.quoted, ctx, ifs),
        }
    }

    const raw_fields = try builder.finish(scratch);
    const cwd = ctx.cwd(scratch);
    var out = std.ArrayList([]const u8).empty;
    errdefer freePendingStrings(allocator, &out);
    for (raw_fields) |field| {
        const matches = try glob.expandGlobMasked(
            scratch,
            field.text,
            field.active,
            cwd,
            @ptrCast(ctx),
            listDirAdapter,
        );
        for (matches) |match| {
            const owned = try allocator.dupe(u8, match);
            out.append(allocator, owned) catch |err| {
                allocator.free(owned);
                return err;
            };
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn expandToString(allocator: std.mem.Allocator, input: word.Word, ctx: *ExpandContext) ExpandError![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const expanded_word = try applyTilde(scratch, input, ctx);
    var out = std.ArrayList(u8).empty;
    for (expanded_word) |part| {
        switch (part) {
            .lit => |lit| try out.appendSlice(scratch, lit.text),
            .sub => |sub| try out.appendSlice(scratch, ctx.commandSubst(scratch, sub.raw)),
            .arith => |arith_part| {
                const value = try std.fmt.allocPrint(scratch, "{d}", .{ctx.arith(scratch, arith_part.raw)});
                try out.appendSlice(scratch, value);
            },
            .param => |param| try out.appendSlice(scratch, try scalarVar(scratch, param.name, param.op, ctx)),
        }
    }
    return allocator.dupe(u8, out.items);
}

pub fn expandRedirectTarget(allocator: std.mem.Allocator, input: word.Word, ctx: *ExpandContext) ExpandError![]const u8 {
    const fields = try expandToFields(allocator, input, ctx);
    return switch (fields.len) {
        0 => blk: {
            if (fields.len != 0) allocator.free(fields);
            break :blk error.AmbiguousRedirectEmpty;
        },
        1 => blk: {
            const out = fields[0];
            allocator.free(fields);
            break :blk out;
        },
        else => blk: {
            freeStringList(allocator, fields);
            break :blk error.AmbiguousRedirectMultiple;
        },
    };
}

fn freePendingStrings(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

fn freeStringList(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn expandVarInto(
    allocator: std.mem.Allocator,
    builder: *FieldBuilder,
    name: []const u8,
    op: word.ParamOp,
    quoted: bool,
    ctx: *ExpandContext,
    ifs: []const u8,
) ExpandError!void {
    if ((std.mem.eql(u8, name, "@") or std.mem.eql(u8, name, "*")) and op == .get) {
        const params = ctx.positionals(allocator);
        if (std.mem.eql(u8, name, "*") and quoted) {
            try builder.pushUnsplit(allocator, try joinPositionals(allocator, params, ifs), false);
            return;
        }
        for (params, 0..) |param, idx| {
            if (idx > 0) try builder.flush(allocator);
            if (quoted) {
                try builder.pushUnsplit(allocator, param, false);
            } else {
                try builder.pushSplit(allocator, param, true, ifs);
            }
        }
        return;
    }

    if ((std.mem.eql(u8, name, "@") or std.mem.eql(u8, name, "*")) and op == .length) {
        const len = ctx.positionals(allocator).len;
        const value = try std.fmt.allocPrint(allocator, "{d}", .{len});
        if (quoted) {
            try builder.pushUnsplit(allocator, value, false);
        } else {
            try builder.pushSplit(allocator, value, true, ifs);
        }
        return;
    }

    const value = try scalarVar(allocator, name, op, ctx);
    if (quoted) {
        try builder.pushUnsplit(allocator, value, false);
    } else {
        try builder.pushSplit(allocator, value, true, ifs);
    }
}

fn scalarVar(allocator: std.mem.Allocator, name: []const u8, op: word.ParamOp, ctx: *ExpandContext) ExpandError![]const u8 {
    const base = ctx.get(allocator, name);
    return switch (op) {
        .get => if (base) |v| v else "",
        .length => blk: {
            const v = base orelse "";
            break :blk try std.fmt.allocPrint(allocator, "{d}", .{v.len});
        },
        .default_value => |param| if (isUnsetOrNull(base, param.colon))
            try expandToString(allocator, param.word, ctx)
        else
            base.?,
        .assign => |param| blk: {
            if (isUnsetOrNull(base, param.colon)) {
                const value = try expandToString(allocator, param.word, ctx);
                if (assignable(name)) ctx.set(name, value);
                break :blk value;
            }
            break :blk base.?;
        },
        .alt => |param| if (isUnsetOrNull(base, param.colon))
            ""
        else
            try expandToString(allocator, param.word, ctx),
        .err => |param| {
            if (isUnsetOrNull(base, param.colon)) return error.Parameter;
            return base.?;
        },
        .trim_prefix => |trim| blk: {
            const pat = try expandToString(allocator, trim.pat, ctx);
            break :blk try trimPrefix(allocator, base orelse "", pat, trim.longest);
        },
        .trim_suffix => |trim| blk: {
            const pat = try expandToString(allocator, trim.pat, ctx);
            break :blk try trimSuffix(allocator, base orelse "", pat, trim.longest);
        },
    };
}

fn applyTilde(allocator: std.mem.Allocator, input: word.Word, ctx: *ExpandContext) ExpandError!word.Word {
    if (input.len == 0) return input;
    const lit = switch (input[0]) {
        .lit => |lit| lit,
        else => return input,
    };
    if (lit.from_quote or lit.text.len == 0 or lit.text[0] != '~') return input;
    if (!(lit.text.len == 1 or lit.text[1] == '/')) return input;
    const home = ctx.home(allocator) orelse return input;

    const out = try allocator.alloc(word.WordPart, input.len);
    @memcpy(out, input);
    out[0] = .{ .lit = .{
        .text = try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, lit.text[1..] }),
        .from_quote = false,
    } };
    return out;
}

fn trimPrefix(allocator: std.mem.Allocator, value: []const u8, pat: []const u8, longest: bool) ![]const u8 {
    if (pat.len == 0) return allocator.dupe(u8, value);
    var best: ?usize = null;
    var i: usize = 0;
    while (i <= value.len) : (i += 1) {
        if (glob.globFull(pat, value[0..i])) {
            best = i;
            if (!longest) break;
        }
    }
    if (best) |idx| return allocator.dupe(u8, value[idx..]);
    return allocator.dupe(u8, value);
}

fn trimSuffix(allocator: std.mem.Allocator, value: []const u8, pat: []const u8, longest: bool) ![]const u8 {
    if (pat.len == 0) return allocator.dupe(u8, value);
    var best: ?usize = null;
    var j: usize = 0;
    while (j <= value.len) : (j += 1) {
        if (glob.globFull(pat, value[value.len - j ..])) {
            best = j;
            if (!longest) break;
        }
    }
    if (best) |len| return allocator.dupe(u8, value[0 .. value.len - len]);
    return allocator.dupe(u8, value);
}

fn joinPositionals(allocator: std.mem.Allocator, params: []const []const u8, ifs: []const u8) ![]const u8 {
    const sep: []const u8 = if (ifs.len == 0) " " else ifs[0..1];
    var out = std.ArrayList(u8).empty;
    for (params, 0..) |param, idx| {
        if (idx > 0) try out.appendSlice(allocator, sep);
        try out.appendSlice(allocator, param);
    }
    return out.toOwnedSlice(allocator);
}

fn isUnsetOrNull(base: ?[]const u8, colon: bool) bool {
    const v = base orelse return true;
    return colon and v.len == 0;
}

fn assignable(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.ascii.isDigit(name[0])) return false;
    for (name) |ch| {
        if (!(ch == '_' or std.ascii.isAlphanumeric(ch))) return false;
    }
    return true;
}

fn containsByte(haystack: []const u8, needle: u8) bool {
    for (haystack) |ch| {
        if (ch == needle) return true;
    }
    return false;
}

fn listDirAdapter(ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ?[]const []const u8 {
    const ctx: *ExpandContext = @ptrCast(@alignCast(ptr));
    return ctx.listDir(allocator, path);
}
