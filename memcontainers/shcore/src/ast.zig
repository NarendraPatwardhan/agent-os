//! Shell grammar AST.

const std = @import("std");
const word = @import("word.zig");

const AllocError = std.mem.Allocator.Error;

pub const Script = struct {
    list: List,

    pub fn empty() Script {
        return .{ .list = .{} };
    }

    pub fn deinit(self: *Script, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

pub const List = struct {
    items: []const ListItem = &.{},
};

pub const ListItem = struct {
    and_or: AndOr,
    sep: ListSep,
};

pub const ListSep = enum {
    seq,
    async,
};

pub const AndOr = struct {
    first: Pipeline,
    rest: []const AndOrRest = &.{},
};

pub const AndOrRest = struct {
    op: AndOrOp,
    pipeline: Pipeline,
};

pub const AndOrOp = enum {
    and_if,
    or_if,
};

pub const Pipeline = struct {
    bang: bool = false,
    cmds: []const Command,
};

pub const Command = union(enum) {
    simple: SimpleCommand,
    compound: CompoundCommand,
    function_def: FunctionDef,
};

pub const CompoundCommand = struct {
    kind: Compound,
    redirs: []const Redirect = &.{},
};

pub const FunctionDef = struct {
    name: []const u8,
    body: *const Command,
};

pub const SimpleCommand = struct {
    assigns: []const Assign = &.{},
    words: []const word.Word = &.{},
    redirs: []const Redirect = &.{},
};

pub const Assign = struct {
    name: []const u8,
    value: word.Word,
};

pub const Compound = union(enum) {
    brace_group: List,
    subshell: List,
    if_clause: IfClause,
    for_clause: ForClause,
    while_clause: WhileClause,
    until_clause: WhileClause,
    case_clause: CaseClause,
};

pub const IfClause = struct {
    arms: []const IfArm,
    else_body: ?List = null,
};

pub const IfArm = struct {
    condition: List,
    body: List,
};

pub const ForClause = struct {
    var_name: []const u8,
    words: ?[]const word.Word,
    body: List,
};

pub const WhileClause = struct {
    cond: List,
    body: List,
};

pub const CaseClause = struct {
    subject: word.Word,
    items: []const CaseItem = &.{},
};

pub const CaseItem = struct {
    patterns: []const word.Word = &.{},
    body: List,
};

pub const Redirect = struct {
    io_number: ?u32 = null,
    op: RedirOp,
    target: RedirTarget,
};

pub const RedirOp = enum {
    read,
    write,
    append,
    read_write,
    clobber,
    heredoc,
    dup_in,
    dup_out,
};

pub const RedirTarget = union(enum) {
    word_value: word.Word,
    dup: DupSpec,
    here: Heredoc,
};

pub const DupSpec = union(enum) {
    number: u32,
    close,
};

pub const Heredoc = struct {
    body: []const u8,
    expand: bool,
};

pub fn cloneCommand(allocator: std.mem.Allocator, cmd: *const Command) AllocError!*Command {
    const out = try allocator.create(Command);
    errdefer allocator.destroy(out);
    out.* = try cloneCommandValue(allocator, cmd.*);
    return out;
}

pub fn destroyCommand(allocator: std.mem.Allocator, cmd: *Command) void {
    deinitCommandValue(allocator, cmd.*);
    allocator.destroy(cmd);
}

fn cloneCommandValue(allocator: std.mem.Allocator, cmd: Command) AllocError!Command {
    return switch (cmd) {
        .simple => |simple| .{ .simple = try cloneSimple(allocator, simple) },
        .compound => |compound| .{ .compound = try cloneCompoundCommand(allocator, compound) },
        .function_def => |f| blk: {
            const name = try allocator.dupe(u8, f.name);
            errdefer allocator.free(name);
            const body = try cloneCommand(allocator, f.body);
            break :blk .{ .function_def = .{ .name = name, .body = body } };
        },
    };
}

fn deinitCommandValue(allocator: std.mem.Allocator, cmd: Command) void {
    switch (cmd) {
        .simple => |simple| deinitSimple(allocator, simple),
        .compound => |compound| deinitCompoundCommand(allocator, compound),
        .function_def => |f| {
            allocator.free(f.name);
            destroyCommand(allocator, @constCast(f.body));
        },
    }
}

fn cloneSimple(allocator: std.mem.Allocator, simple: SimpleCommand) AllocError!SimpleCommand {
    return .{
        .assigns = try cloneAssigns(allocator, simple.assigns),
        .words = try cloneWords(allocator, simple.words),
        .redirs = try cloneRedirects(allocator, simple.redirs),
    };
}

fn deinitSimple(allocator: std.mem.Allocator, simple: SimpleCommand) void {
    deinitAssigns(allocator, simple.assigns);
    deinitWords(allocator, simple.words);
    deinitRedirects(allocator, simple.redirs);
}

fn cloneCompoundCommand(allocator: std.mem.Allocator, compound: CompoundCommand) AllocError!CompoundCommand {
    return .{
        .kind = try cloneCompound(allocator, compound.kind),
        .redirs = try cloneRedirects(allocator, compound.redirs),
    };
}

fn deinitCompoundCommand(allocator: std.mem.Allocator, compound: CompoundCommand) void {
    deinitCompound(allocator, compound.kind);
    deinitRedirects(allocator, compound.redirs);
}

fn cloneCompound(allocator: std.mem.Allocator, compound: Compound) AllocError!Compound {
    return switch (compound) {
        .brace_group => |list| .{ .brace_group = try cloneList(allocator, list) },
        .subshell => |list| .{ .subshell = try cloneList(allocator, list) },
        .if_clause => |if_clause| .{ .if_clause = try cloneIfClause(allocator, if_clause) },
        .for_clause => |for_clause| .{ .for_clause = try cloneForClause(allocator, for_clause) },
        .while_clause => |while_clause| .{ .while_clause = try cloneWhileClause(allocator, while_clause) },
        .until_clause => |while_clause| .{ .until_clause = try cloneWhileClause(allocator, while_clause) },
        .case_clause => |case_clause| .{ .case_clause = try cloneCaseClause(allocator, case_clause) },
    };
}

fn deinitCompound(allocator: std.mem.Allocator, compound: Compound) void {
    switch (compound) {
        .brace_group => |list| deinitList(allocator, list),
        .subshell => |list| deinitList(allocator, list),
        .if_clause => |if_clause| deinitIfClause(allocator, if_clause),
        .for_clause => |for_clause| deinitForClause(allocator, for_clause),
        .while_clause => |while_clause| deinitWhileClause(allocator, while_clause),
        .until_clause => |while_clause| deinitWhileClause(allocator, while_clause),
        .case_clause => |case_clause| deinitCaseClause(allocator, case_clause),
    }
}

fn cloneList(allocator: std.mem.Allocator, list: List) AllocError!List {
    if (list.items.len == 0) return .{};
    const items = try allocator.alloc(ListItem, list.items.len);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |item| deinitListItem(allocator, item);
        allocator.free(items);
    }
    for (list.items, 0..) |item, i| {
        items[i] = try cloneListItem(allocator, item);
        initialized += 1;
    }
    return .{ .items = items };
}

fn deinitList(allocator: std.mem.Allocator, list: List) void {
    for (list.items) |item| deinitListItem(allocator, item);
    if (list.items.len != 0) allocator.free(list.items);
}

fn cloneListItem(allocator: std.mem.Allocator, item: ListItem) AllocError!ListItem {
    return .{ .and_or = try cloneAndOr(allocator, item.and_or), .sep = item.sep };
}

fn deinitListItem(allocator: std.mem.Allocator, item: ListItem) void {
    deinitAndOr(allocator, item.and_or);
}

fn cloneAndOr(allocator: std.mem.Allocator, ao: AndOr) AllocError!AndOr {
    return .{
        .first = try clonePipeline(allocator, ao.first),
        .rest = try cloneAndOrRest(allocator, ao.rest),
    };
}

fn deinitAndOr(allocator: std.mem.Allocator, ao: AndOr) void {
    deinitPipeline(allocator, ao.first);
    for (ao.rest) |rest| deinitPipeline(allocator, rest.pipeline);
    if (ao.rest.len != 0) allocator.free(ao.rest);
}

fn cloneAndOrRest(allocator: std.mem.Allocator, rest: []const AndOrRest) AllocError![]const AndOrRest {
    if (rest.len == 0) return &.{};
    const out = try allocator.alloc(AndOrRest, rest.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |item| deinitPipeline(allocator, item.pipeline);
        allocator.free(out);
    }
    for (rest, 0..) |item, i| {
        out[i] = .{ .op = item.op, .pipeline = try clonePipeline(allocator, item.pipeline) };
        initialized += 1;
    }
    return out;
}

fn clonePipeline(allocator: std.mem.Allocator, pipeline: Pipeline) AllocError!Pipeline {
    const cmds = try cloneCommands(allocator, pipeline.cmds);
    return .{ .bang = pipeline.bang, .cmds = cmds };
}

fn deinitPipeline(allocator: std.mem.Allocator, pipeline: Pipeline) void {
    for (pipeline.cmds) |cmd| deinitCommandValue(allocator, cmd);
    if (pipeline.cmds.len != 0) allocator.free(pipeline.cmds);
}

fn cloneCommands(allocator: std.mem.Allocator, cmds: []const Command) AllocError![]const Command {
    if (cmds.len == 0) return &.{};
    const out = try allocator.alloc(Command, cmds.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |cmd| deinitCommandValue(allocator, cmd);
        allocator.free(out);
    }
    for (cmds, 0..) |cmd, i| {
        out[i] = try cloneCommandValue(allocator, cmd);
        initialized += 1;
    }
    return out;
}

fn cloneIfClause(allocator: std.mem.Allocator, if_clause: IfClause) AllocError!IfClause {
    const arms = try cloneIfArms(allocator, if_clause.arms);
    errdefer deinitIfArms(allocator, arms);
    const else_body = if (if_clause.else_body) |body| try cloneList(allocator, body) else null;
    return .{ .arms = arms, .else_body = else_body };
}

fn deinitIfClause(allocator: std.mem.Allocator, if_clause: IfClause) void {
    deinitIfArms(allocator, if_clause.arms);
    if (if_clause.else_body) |body| deinitList(allocator, body);
}

fn cloneIfArms(allocator: std.mem.Allocator, arms: []const IfArm) AllocError![]const IfArm {
    if (arms.len == 0) return &.{};
    const out = try allocator.alloc(IfArm, arms.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |arm| {
            deinitList(allocator, arm.condition);
            deinitList(allocator, arm.body);
        }
        allocator.free(out);
    }
    for (arms, 0..) |arm, i| {
        out[i] = .{
            .condition = try cloneList(allocator, arm.condition),
            .body = try cloneList(allocator, arm.body),
        };
        initialized += 1;
    }
    return out;
}

fn deinitIfArms(allocator: std.mem.Allocator, arms: []const IfArm) void {
    for (arms) |arm| {
        deinitList(allocator, arm.condition);
        deinitList(allocator, arm.body);
    }
    if (arms.len != 0) allocator.free(arms);
}

fn cloneForClause(allocator: std.mem.Allocator, for_clause: ForClause) AllocError!ForClause {
    const var_name = try allocator.dupe(u8, for_clause.var_name);
    errdefer allocator.free(var_name);
    const words = if (for_clause.words) |ws| try cloneWords(allocator, ws) else null;
    errdefer {
        if (words) |ws| deinitWords(allocator, ws);
    }
    return .{
        .var_name = var_name,
        .words = words,
        .body = try cloneList(allocator, for_clause.body),
    };
}

fn deinitForClause(allocator: std.mem.Allocator, for_clause: ForClause) void {
    allocator.free(for_clause.var_name);
    if (for_clause.words) |ws| deinitWords(allocator, ws);
    deinitList(allocator, for_clause.body);
}

fn cloneWhileClause(allocator: std.mem.Allocator, while_clause: WhileClause) AllocError!WhileClause {
    return .{
        .cond = try cloneList(allocator, while_clause.cond),
        .body = try cloneList(allocator, while_clause.body),
    };
}

fn deinitWhileClause(allocator: std.mem.Allocator, while_clause: WhileClause) void {
    deinitList(allocator, while_clause.cond);
    deinitList(allocator, while_clause.body);
}

fn cloneCaseClause(allocator: std.mem.Allocator, case_clause: CaseClause) AllocError!CaseClause {
    const subject = try cloneWord(allocator, case_clause.subject);
    errdefer deinitWord(allocator, subject);
    return .{
        .subject = subject,
        .items = try cloneCaseItems(allocator, case_clause.items),
    };
}

fn deinitCaseClause(allocator: std.mem.Allocator, case_clause: CaseClause) void {
    deinitWord(allocator, case_clause.subject);
    for (case_clause.items) |item| {
        deinitWords(allocator, item.patterns);
        deinitList(allocator, item.body);
    }
    if (case_clause.items.len != 0) allocator.free(case_clause.items);
}

fn cloneCaseItems(allocator: std.mem.Allocator, items: []const CaseItem) AllocError![]const CaseItem {
    if (items.len == 0) return &.{};
    const out = try allocator.alloc(CaseItem, items.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |item| {
            deinitWords(allocator, item.patterns);
            deinitList(allocator, item.body);
        }
        allocator.free(out);
    }
    for (items, 0..) |item, i| {
        out[i] = .{
            .patterns = try cloneWords(allocator, item.patterns),
            .body = try cloneList(allocator, item.body),
        };
        initialized += 1;
    }
    return out;
}

fn cloneAssigns(allocator: std.mem.Allocator, assigns: []const Assign) AllocError![]const Assign {
    if (assigns.len == 0) return &.{};
    const out = try allocator.alloc(Assign, assigns.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |assignment| {
            allocator.free(assignment.name);
            deinitWord(allocator, assignment.value);
        }
        allocator.free(out);
    }
    for (assigns, 0..) |assignment, i| {
        out[i] = .{
            .name = try allocator.dupe(u8, assignment.name),
            .value = try cloneWord(allocator, assignment.value),
        };
        initialized += 1;
    }
    return out;
}

fn deinitAssigns(allocator: std.mem.Allocator, assigns: []const Assign) void {
    for (assigns) |assignment| {
        allocator.free(assignment.name);
        deinitWord(allocator, assignment.value);
    }
    if (assigns.len != 0) allocator.free(assigns);
}

fn cloneRedirects(allocator: std.mem.Allocator, redirs: []const Redirect) AllocError![]const Redirect {
    if (redirs.len == 0) return &.{};
    const out = try allocator.alloc(Redirect, redirs.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |redirect| deinitRedirect(allocator, redirect);
        allocator.free(out);
    }
    for (redirs, 0..) |redirect, i| {
        out[i] = try cloneRedirect(allocator, redirect);
        initialized += 1;
    }
    return out;
}

fn deinitRedirects(allocator: std.mem.Allocator, redirs: []const Redirect) void {
    for (redirs) |redirect| deinitRedirect(allocator, redirect);
    if (redirs.len != 0) allocator.free(redirs);
}

fn cloneRedirect(allocator: std.mem.Allocator, redirect: Redirect) AllocError!Redirect {
    return .{
        .io_number = redirect.io_number,
        .op = redirect.op,
        .target = try cloneRedirTarget(allocator, redirect.target),
    };
}

fn deinitRedirect(allocator: std.mem.Allocator, redirect: Redirect) void {
    deinitRedirTarget(allocator, redirect.target);
}

fn cloneRedirTarget(allocator: std.mem.Allocator, target: RedirTarget) AllocError!RedirTarget {
    return switch (target) {
        .word_value => |w| .{ .word_value = try cloneWord(allocator, w) },
        .dup => |dup| .{ .dup = dup },
        .here => |here| .{ .here = .{ .body = try allocator.dupe(u8, here.body), .expand = here.expand } },
    };
}

fn deinitRedirTarget(allocator: std.mem.Allocator, target: RedirTarget) void {
    switch (target) {
        .word_value => |w| deinitWord(allocator, w),
        .dup => {},
        .here => |here| allocator.free(here.body),
    }
}

fn cloneWords(allocator: std.mem.Allocator, words: []const word.Word) AllocError![]const word.Word {
    if (words.len == 0) return &.{};
    const out = try allocator.alloc(word.Word, words.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |w| deinitWord(allocator, w);
        allocator.free(out);
    }
    for (words, 0..) |w, i| {
        out[i] = try cloneWord(allocator, w);
        initialized += 1;
    }
    return out;
}

fn deinitWords(allocator: std.mem.Allocator, words: []const word.Word) void {
    for (words) |w| deinitWord(allocator, w);
    if (words.len != 0) allocator.free(words);
}

fn cloneWord(allocator: std.mem.Allocator, w: word.Word) AllocError!word.Word {
    if (w.len == 0) return &.{};
    const out = try allocator.alloc(word.WordPart, w.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |part| deinitWordPart(allocator, part);
        allocator.free(out);
    }
    for (w, 0..) |part, i| {
        out[i] = try cloneWordPart(allocator, part);
        initialized += 1;
    }
    return out;
}

fn deinitWord(allocator: std.mem.Allocator, w: word.Word) void {
    for (w) |part| deinitWordPart(allocator, part);
    if (w.len != 0) allocator.free(w);
}

fn cloneWordPart(allocator: std.mem.Allocator, part: word.WordPart) AllocError!word.WordPart {
    return switch (part) {
        .lit => |lit| .{ .lit = .{ .text = try allocator.dupe(u8, lit.text), .from_quote = lit.from_quote } },
        .sub => |sub| .{ .sub = .{ .raw = try allocator.dupe(u8, sub.raw), .quoted = sub.quoted } },
        .arith => |arith| .{ .arith = .{ .raw = try allocator.dupe(u8, arith.raw), .quoted = arith.quoted } },
        .param => |param| blk: {
            const name = try allocator.dupe(u8, param.name);
            errdefer allocator.free(name);
            break :blk .{ .param = .{ .name = name, .op = try cloneParamOp(allocator, param.op), .quoted = param.quoted } };
        },
    };
}

fn deinitWordPart(allocator: std.mem.Allocator, part: word.WordPart) void {
    switch (part) {
        .lit => |lit| allocator.free(lit.text),
        .sub => |sub| allocator.free(sub.raw),
        .arith => |arith| allocator.free(arith.raw),
        .param => |param| {
            allocator.free(param.name);
            deinitParamOp(allocator, param.op);
        },
    }
}

fn cloneParamOp(allocator: std.mem.Allocator, op: word.ParamOp) AllocError!word.ParamOp {
    return switch (op) {
        .get => .get,
        .length => .length,
        .default_value => |param| .{ .default_value = try cloneParamWord(allocator, param) },
        .assign => |param| .{ .assign = try cloneParamWord(allocator, param) },
        .alt => |param| .{ .alt = try cloneParamWord(allocator, param) },
        .err => |param| .{ .err = try cloneParamWord(allocator, param) },
        .trim_prefix => |trim| .{ .trim_prefix = try cloneTrimWord(allocator, trim) },
        .trim_suffix => |trim| .{ .trim_suffix = try cloneTrimWord(allocator, trim) },
    };
}

fn deinitParamOp(allocator: std.mem.Allocator, op: word.ParamOp) void {
    switch (op) {
        .get, .length => {},
        .default_value => |param| deinitWord(allocator, param.word),
        .assign => |param| deinitWord(allocator, param.word),
        .alt => |param| deinitWord(allocator, param.word),
        .err => |param| deinitWord(allocator, param.word),
        .trim_prefix => |trim| deinitWord(allocator, trim.pat),
        .trim_suffix => |trim| deinitWord(allocator, trim.pat),
    }
}

fn cloneParamWord(allocator: std.mem.Allocator, param: word.ParamWord) AllocError!word.ParamWord {
    return .{ .colon = param.colon, .word = try cloneWord(allocator, param.word) };
}

fn cloneTrimWord(allocator: std.mem.Allocator, trim: word.TrimWord) AllocError!word.TrimWord {
    return .{ .longest = trim.longest, .pat = try cloneWord(allocator, trim.pat) };
}
