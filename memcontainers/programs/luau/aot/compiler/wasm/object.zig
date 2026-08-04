const std = @import("std");

pub const Error = error{
    TooManyTypes,
    TooManyFunctions,
    InvalidTypeIndex,
    EmptyFunctionName,
    MissingFunctionEnd,
    InvalidRelocationOffset,
    OutOfMemory,
};

pub const ValueType = enum(u8) {
    i32 = 0x7f,
    i64 = 0x7e,
    f32 = 0x7d,
    f64 = 0x7c,
};

pub const FunctionType = struct {
    params: []const ValueType,
    results: []const ValueType,
};

pub const Local = struct {
    count: u32,
    value_type: ValueType,
};

pub const FunctionRef = struct {
    function_index: u32,
    symbol_index: u32,
    type_index: u32,
};

pub const symbol = struct {
    pub const binding_weak: u32 = 0x01;
    pub const binding_local: u32 = 0x02;
    pub const visibility_hidden: u32 = 0x04;
    pub const is_undefined: u32 = 0x10;
    pub const exported: u32 = 0x20;
    pub const explicit_name: u32 = 0x40;
    pub const no_strip: u32 = 0x80;
};

pub const relocation = struct {
    pub const function_index_leb: u8 = 0;
};

const ImportFunction = struct {
    module: []const u8,
    name: []const u8,
    type_index: u32,
};

const DefinedFunction = struct {
    name: []const u8,
    type_index: u32,
    symbol_flags: u32,
    body: []const u8,
    relocations: []const Body.Relocation,
};

pub const Body = struct {
    bytes: std.ArrayList(u8) = .empty,
    relocations: std.ArrayList(Relocation) = .empty,
    finished: bool = false,

    pub const Relocation = struct {
        kind: u8,
        body_offset: u32,
        symbol_index: u32,
    };

    pub fn init(allocator: std.mem.Allocator, locals: []const Local) !Body {
        var body = Body{};
        errdefer body.deinit(allocator);
        try appendUleb(&body.bytes, allocator, locals.len);
        for (locals) |local| {
            try appendUleb(&body.bytes, allocator, local.count);
            try body.bytes.append(allocator, @intFromEnum(local.value_type));
        }
        return body;
    }

    pub fn deinit(self: *Body, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.relocations.deinit(allocator);
        self.* = .{};
    }

    pub fn finish(self: *Body, allocator: std.mem.Allocator) !void {
        if (self.finished)
            return;
        try self.bytes.append(allocator, 0x0b);
        self.finished = true;
    }

    pub fn localGet(self: *Body, allocator: std.mem.Allocator, index: u32) !void {
        try self.opU32(allocator, 0x20, index);
    }

    pub fn localSet(self: *Body, allocator: std.mem.Allocator, index: u32) !void {
        try self.opU32(allocator, 0x21, index);
    }

    pub fn i32Load(self: *Body, allocator: std.mem.Allocator, alignment_log2: u32, offset: u32) !void {
        try self.bytes.append(allocator, 0x28);
        try appendUleb(&self.bytes, allocator, alignment_log2);
        try appendUleb(&self.bytes, allocator, offset);
    }

    pub fn f64Load(self: *Body, allocator: std.mem.Allocator, alignment_log2: u32, offset: u32) !void {
        try self.bytes.append(allocator, 0x2b);
        try appendUleb(&self.bytes, allocator, alignment_log2);
        try appendUleb(&self.bytes, allocator, offset);
    }

    pub fn i32Const(self: *Body, allocator: std.mem.Allocator, value: i32) !void {
        try self.bytes.append(allocator, 0x41);
        try appendSleb(&self.bytes, allocator, value);
    }

    pub fn f64Const(self: *Body, allocator: std.mem.Allocator, value: f64) !void {
        try self.bytes.append(allocator, 0x44);
        const bits: u64 = @bitCast(value);
        var byte_index: u6 = 0;
        while (byte_index < 8) : (byte_index += 1)
            try self.bytes.append(allocator, @truncate(bits >> (byte_index * 8)));
    }

    pub fn block(self: *Body, allocator: std.mem.Allocator) !void {
        try self.blockOp(allocator, 0x02);
    }

    pub fn loop(self: *Body, allocator: std.mem.Allocator) !void {
        try self.blockOp(allocator, 0x03);
    }

    pub fn ifVoid(self: *Body, allocator: std.mem.Allocator) !void {
        try self.blockOp(allocator, 0x04);
    }

    pub fn branch(self: *Body, allocator: std.mem.Allocator, depth: u32) !void {
        try self.opU32(allocator, 0x0c, depth);
    }

    pub fn branchIf(self: *Body, allocator: std.mem.Allocator, depth: u32) !void {
        try self.opU32(allocator, 0x0d, depth);
    }

    pub fn return_(self: *Body, allocator: std.mem.Allocator) !void {
        try self.bytes.append(allocator, 0x0f);
    }

    pub fn end(self: *Body, allocator: std.mem.Allocator) !void {
        try self.bytes.append(allocator, 0x0b);
    }

    pub fn opcode(self: *Body, allocator: std.mem.Allocator, byte: u8) !void {
        try self.bytes.append(allocator, byte);
    }

    pub fn call(self: *Body, allocator: std.mem.Allocator, function: FunctionRef) !void {
        try self.bytes.append(allocator, 0x10);
        const body_offset: u32 = @intCast(self.bytes.items.len);
        try appendPaddedUleb32(&self.bytes, allocator, function.function_index);
        try self.relocations.append(allocator, .{
            .kind = relocation.function_index_leb,
            .body_offset = body_offset,
            .symbol_index = function.symbol_index,
        });
    }

    fn blockOp(self: *Body, allocator: std.mem.Allocator, opcode_byte: u8) !void {
        try self.bytes.append(allocator, opcode_byte);
        try self.bytes.append(allocator, 0x40);
    }

    fn opU32(self: *Body, allocator: std.mem.Allocator, opcode_byte: u8, value: u32) !void {
        try self.bytes.append(allocator, opcode_byte);
        try appendUleb(&self.bytes, allocator, value);
    }
};

pub const Object = struct {
    allocator: std.mem.Allocator,
    types: std.ArrayList(FunctionType) = .empty,
    imports: std.ArrayList(ImportFunction) = .empty,
    functions: std.ArrayList(DefinedFunction) = .empty,

    pub fn init(allocator: std.mem.Allocator) Object {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Object) void {
        self.types.deinit(self.allocator);
        self.imports.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addType(self: *Object, function_type: FunctionType) !u32 {
        for (self.types.items, 0..) |existing, index| {
            if (std.mem.eql(ValueType, existing.params, function_type.params) and
                std.mem.eql(ValueType, existing.results, function_type.results))
                return @intCast(index);
        }
        if (self.types.items.len == std.math.maxInt(u32))
            return Error.TooManyTypes;
        try self.types.append(self.allocator, function_type);
        return @intCast(self.types.items.len - 1);
    }

    pub fn importFunction(self: *Object, module: []const u8, name: []const u8, type_index: u32) !FunctionRef {
        if (type_index >= self.types.items.len)
            return Error.InvalidTypeIndex;
        if (name.len == 0)
            return Error.EmptyFunctionName;
        if (self.imports.items.len == std.math.maxInt(u32))
            return Error.TooManyFunctions;
        try self.imports.append(self.allocator, .{
            .module = module,
            .name = name,
            .type_index = type_index,
        });
        const index: u32 = @intCast(self.imports.items.len - 1);
        return .{ .function_index = index, .symbol_index = index, .type_index = type_index };
    }

    pub fn defineFunction(self: *Object, name: []const u8, type_index: u32, symbol_flags: u32, body: Body) !FunctionRef {
        if (type_index >= self.types.items.len)
            return Error.InvalidTypeIndex;
        if (name.len == 0)
            return Error.EmptyFunctionName;
        if (!body.finished or body.bytes.items.len == 0 or body.bytes.items[body.bytes.items.len - 1] != 0x0b)
            return Error.MissingFunctionEnd;
        if (self.functions.items.len == std.math.maxInt(u32) - self.imports.items.len)
            return Error.TooManyFunctions;
        for (body.relocations.items) |item| {
            if (@as(usize, item.body_offset) + 5 > body.bytes.items.len)
                return Error.InvalidRelocationOffset;
        }
        try self.functions.append(self.allocator, .{
            .name = name,
            .type_index = type_index,
            .symbol_flags = symbol_flags,
            .body = body.bytes.items,
            .relocations = body.relocations.items,
        });
        const function_index: u32 = @intCast(self.imports.items.len + self.functions.items.len - 1);
        const symbol_index: u32 = function_index;
        return .{ .function_index = function_index, .symbol_index = symbol_index, .type_index = type_index };
    }

    pub fn emit(self: *const Object) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        try output.appendSlice(self.allocator, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

        var section_index: u32 = 0;

        var type_payload: std.ArrayList(u8) = .empty;
        defer type_payload.deinit(self.allocator);
        try appendUleb(&type_payload, self.allocator, self.types.items.len);
        for (self.types.items) |function_type| {
            try type_payload.append(self.allocator, 0x60);
            try appendValueTypes(&type_payload, self.allocator, function_type.params);
            try appendValueTypes(&type_payload, self.allocator, function_type.results);
        }
        try appendSection(&output, self.allocator, 1, type_payload.items);
        section_index += 1;

        if (self.imports.items.len != 0) {
            var import_payload: std.ArrayList(u8) = .empty;
            defer import_payload.deinit(self.allocator);
            try appendUleb(&import_payload, self.allocator, self.imports.items.len);
            for (self.imports.items) |function_import| {
                try appendName(&import_payload, self.allocator, function_import.module);
                try appendName(&import_payload, self.allocator, function_import.name);
                try import_payload.append(self.allocator, 0x00);
                try appendUleb(&import_payload, self.allocator, function_import.type_index);
            }
            try appendSection(&output, self.allocator, 2, import_payload.items);
            section_index += 1;
        }

        var function_payload: std.ArrayList(u8) = .empty;
        defer function_payload.deinit(self.allocator);
        try appendUleb(&function_payload, self.allocator, self.functions.items.len);
        for (self.functions.items) |function|
            try appendUleb(&function_payload, self.allocator, function.type_index);
        try appendSection(&output, self.allocator, 3, function_payload.items);
        section_index += 1;

        const code_section_index = section_index;
        var code_payload: std.ArrayList(u8) = .empty;
        defer code_payload.deinit(self.allocator);
        var code_relocations: std.ArrayList(Body.Relocation) = .empty;
        defer code_relocations.deinit(self.allocator);
        try appendUleb(&code_payload, self.allocator, self.functions.items.len);
        for (self.functions.items) |function| {
            try appendUleb(&code_payload, self.allocator, function.body.len);
            const body_start = code_payload.items.len;
            try code_payload.appendSlice(self.allocator, function.body);
            for (function.relocations) |item| {
                var relocated = item;
                relocated.body_offset = @intCast(body_start + item.body_offset);
                try code_relocations.append(self.allocator, relocated);
            }
        }
        try appendSection(&output, self.allocator, 10, code_payload.items);

        var linking_payload: std.ArrayList(u8) = .empty;
        defer linking_payload.deinit(self.allocator);
        try appendUleb(&linking_payload, self.allocator, 2);
        var symbols_payload: std.ArrayList(u8) = .empty;
        defer symbols_payload.deinit(self.allocator);
        try appendUleb(&symbols_payload, self.allocator, self.imports.items.len + self.functions.items.len);
        for (self.imports.items, 0..) |_, index| {
            try symbols_payload.append(self.allocator, 0x00);
            try appendUleb(&symbols_payload, self.allocator, symbol.is_undefined);
            try appendUleb(&symbols_payload, self.allocator, index);
        }
        for (self.functions.items, 0..) |function, index| {
            try symbols_payload.append(self.allocator, 0x00);
            try appendUleb(&symbols_payload, self.allocator, function.symbol_flags);
            try appendUleb(&symbols_payload, self.allocator, self.imports.items.len + index);
            try appendName(&symbols_payload, self.allocator, function.name);
        }
        try linking_payload.append(self.allocator, 8);
        try appendUleb(&linking_payload, self.allocator, symbols_payload.items.len);
        try linking_payload.appendSlice(self.allocator, symbols_payload.items);
        try appendCustomSection(&output, self.allocator, "linking", linking_payload.items);

        if (code_relocations.items.len != 0) {
            var reloc_payload: std.ArrayList(u8) = .empty;
            defer reloc_payload.deinit(self.allocator);
            try appendUleb(&reloc_payload, self.allocator, code_section_index);
            try appendUleb(&reloc_payload, self.allocator, code_relocations.items.len);
            for (code_relocations.items) |item| {
                try reloc_payload.append(self.allocator, item.kind);
                try appendUleb(&reloc_payload, self.allocator, item.body_offset);
                try appendUleb(&reloc_payload, self.allocator, item.symbol_index);
            }
            try appendCustomSection(&output, self.allocator, "reloc.CODE", reloc_payload.items);
        }

        return output.toOwnedSlice(self.allocator);
    }
};

fn appendValueTypes(output: *std.ArrayList(u8), allocator: std.mem.Allocator, values: []const ValueType) !void {
    try appendUleb(output, allocator, values.len);
    for (values) |value|
        try output.append(allocator, @intFromEnum(value));
}

fn appendName(output: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8) !void {
    try appendUleb(output, allocator, name.len);
    try output.appendSlice(allocator, name);
}

fn appendSection(output: *std.ArrayList(u8), allocator: std.mem.Allocator, id: u8, payload: []const u8) !void {
    try output.append(allocator, id);
    try appendUleb(output, allocator, payload.len);
    try output.appendSlice(allocator, payload);
}

fn appendCustomSection(output: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, payload: []const u8) !void {
    var section_payload: std.ArrayList(u8) = .empty;
    defer section_payload.deinit(allocator);
    try appendName(&section_payload, allocator, name);
    try section_payload.appendSlice(allocator, payload);
    try appendSection(output, allocator, 0, section_payload.items);
}

fn appendUleb(output: *std.ArrayList(u8), allocator: std.mem.Allocator, input: anytype) !void {
    var value: u64 = @intCast(input);
    while (true) {
        var byte: u8 = @truncate(value & 0x7f);
        value >>= 7;
        if (value != 0)
            byte |= 0x80;
        try output.append(allocator, byte);
        if (value == 0)
            return;
    }
}

fn appendSleb(output: *std.ArrayList(u8), allocator: std.mem.Allocator, input: i32) !void {
    var value: i64 = input;
    while (true) {
        const byte: u8 = @truncate(@as(u64, @bitCast(value)) & 0x7f);
        value >>= 7;
        const done = (value == 0 and byte & 0x40 == 0) or (value == -1 and byte & 0x40 != 0);
        try output.append(allocator, if (done) byte else byte | 0x80);
        if (done)
            return;
    }
}

fn appendPaddedUleb32(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    try output.append(allocator, @truncate(value | 0x80));
    try output.append(allocator, @truncate((value >> 7) | 0x80));
    try output.append(allocator, @truncate((value >> 14) | 0x80));
    try output.append(allocator, @truncate((value >> 21) | 0x80));
    try output.append(allocator, @truncate(value >> 28));
}

test "emits deterministic linking-v2 object with a relocated external call" {
    const allocator = std.testing.allocator;
    const params = [_]ValueType{.i32};
    const no_results = [_]ValueType{};

    var object = Object.init(allocator);
    defer object.deinit();
    const function_type = try object.addType(.{ .params = &params, .results = &no_results });
    const external = try object.importFunction("env", "mc_luau_aot_v1_test_hook", function_type);

    var body = try Body.init(allocator, &.{});
    defer body.deinit(allocator);
    try body.localGet(allocator, 0);
    try body.call(allocator, external);
    try body.finish(allocator);
    _ = try object.defineFunction("mc_luau_aot_v1_test_function", function_type, symbol.exported, body);

    const first = try object.emit();
    defer allocator.free(first);
    const second = try object.emit();
    defer allocator.free(second);

    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 }, first[0..8]);
    try std.testing.expect(std.mem.indexOf(u8, first, "linking") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "reloc.CODE") != null);
}
