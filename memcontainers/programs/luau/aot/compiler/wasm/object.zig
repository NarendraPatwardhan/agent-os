const std = @import("std");

pub const Error = error{
    TooManyTypes,
    TooManyFunctions,
    InvalidTypeIndex,
    EmptyFunctionName,
    MissingFunctionEnd,
    InvalidRelocationOffset,
    InvalidDataRelocationOffset,
    InvalidObjectOrder,
    IntegerOverflow,
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

pub const DataRef = struct {
    segment_index: u32,
    symbol_index: u32,
    memory_offset: u32,
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
    pub const table_index_i32: u8 = 2;
    pub const memory_addr_i32: u8 = 5;
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

const DataRelocation = struct {
    kind: u8,
    segment_offset: u32,
    symbol_index: u32,
    addend: i32,
};

const DataSegment = struct {
    name: []const u8,
    symbol_name: []const u8,
    symbol_flags: u32,
    alignment_log2: u32,
    memory_offset: u32,
    bytes: []const u8,
    relocations: std.ArrayList(DataRelocation),
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

    pub fn localTee(self: *Body, allocator: std.mem.Allocator, index: u32) !void {
        try self.opU32(allocator, 0x22, index);
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

    pub fn f32Load(self: *Body, allocator: std.mem.Allocator, alignment_log2: u32, offset: u32) !void {
        try self.memoryOp(allocator, 0x2a, alignment_log2, offset);
    }

    pub fn i64Load(self: *Body, allocator: std.mem.Allocator, alignment_log2: u32, offset: u32) !void {
        try self.memoryOp(allocator, 0x29, alignment_log2, offset);
    }

    pub fn i32Store(self: *Body, allocator: std.mem.Allocator, alignment_log2: u32, offset: u32) !void {
        try self.memoryOp(allocator, 0x36, alignment_log2, offset);
    }

    pub fn i64Store(self: *Body, allocator: std.mem.Allocator, alignment_log2: u32, offset: u32) !void {
        try self.memoryOp(allocator, 0x37, alignment_log2, offset);
    }

    pub fn f64Store(self: *Body, allocator: std.mem.Allocator, alignment_log2: u32, offset: u32) !void {
        try self.memoryOp(allocator, 0x39, alignment_log2, offset);
    }

    pub fn f32Store(self: *Body, allocator: std.mem.Allocator, alignment_log2: u32, offset: u32) !void {
        try self.memoryOp(allocator, 0x38, alignment_log2, offset);
    }

    pub fn i32Const(self: *Body, allocator: std.mem.Allocator, value: i32) !void {
        try self.bytes.append(allocator, 0x41);
        try appendSleb(&self.bytes, allocator, value);
    }

    pub fn i64Const(self: *Body, allocator: std.mem.Allocator, value: i64) !void {
        try self.bytes.append(allocator, 0x42);
        try appendSleb64(&self.bytes, allocator, value);
    }

    pub fn f32Const(self: *Body, allocator: std.mem.Allocator, value: f32) !void {
        try self.bytes.append(allocator, 0x43);
        const bits: u32 = @bitCast(value);
        var byte_index: u5 = 0;
        while (byte_index < 4) : (byte_index += 1)
            try self.bytes.append(allocator, @truncate(bits >> (byte_index * 8)));
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

    pub fn else_(self: *Body, allocator: std.mem.Allocator) !void {
        try self.bytes.append(allocator, 0x05);
    }

    pub fn select(self: *Body, allocator: std.mem.Allocator) !void {
        try self.bytes.append(allocator, 0x1b);
    }

    pub fn i32Eqz(self: *Body, allocator: std.mem.Allocator) !void {
        try self.bytes.append(allocator, 0x45);
    }

    pub fn i32Eq(self: *Body, allocator: std.mem.Allocator) !void {
        try self.bytes.append(allocator, 0x46);
    }

    pub fn i32Ne(self: *Body, allocator: std.mem.Allocator) !void {
        try self.bytes.append(allocator, 0x47);
    }

    pub fn f64Eq(self: *Body, allocator: std.mem.Allocator) !void {
        try self.bytes.append(allocator, 0x61);
    }

    pub fn f64Ne(self: *Body, allocator: std.mem.Allocator) !void {
        try self.bytes.append(allocator, 0x62);
    }

    pub fn f64Lt(self: *Body, allocator: std.mem.Allocator) !void {
        try self.bytes.append(allocator, 0x63);
    }

    pub fn f64Gt(self: *Body, allocator: std.mem.Allocator) !void {
        try self.bytes.append(allocator, 0x64);
    }

    pub fn f64Le(self: *Body, allocator: std.mem.Allocator) !void {
        try self.bytes.append(allocator, 0x65);
    }

    pub fn f64Ge(self: *Body, allocator: std.mem.Allocator) !void {
        try self.bytes.append(allocator, 0x66);
    }

    pub fn f64Add(self: *Body, allocator: std.mem.Allocator) !void {
        try self.bytes.append(allocator, 0xa0);
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

    fn memoryOp(self: *Body, allocator: std.mem.Allocator, opcode_byte: u8, alignment_log2: u32, offset: u32) !void {
        try self.bytes.append(allocator, opcode_byte);
        try appendUleb(&self.bytes, allocator, alignment_log2);
        try appendUleb(&self.bytes, allocator, offset);
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
    data_segments: std.ArrayList(DataSegment) = .empty,
    data_size: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Object {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Object) void {
        for (self.types.items) |function_type| {
            self.allocator.free(function_type.params);
            self.allocator.free(function_type.results);
        }
        for (self.imports.items) |function_import| {
            self.allocator.free(function_import.module);
            self.allocator.free(function_import.name);
        }
        for (self.functions.items) |function| {
            self.allocator.free(function.name);
            self.allocator.free(function.body);
            self.allocator.free(function.relocations);
        }
        for (self.data_segments.items) |segment| {
            self.allocator.free(segment.name);
            self.allocator.free(segment.symbol_name);
            self.allocator.free(segment.bytes);
            var relocations = segment.relocations;
            relocations.deinit(self.allocator);
        }
        self.types.deinit(self.allocator);
        self.imports.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.data_segments.deinit(self.allocator);
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
        const owned_params = try self.allocator.dupe(ValueType, function_type.params);
        errdefer self.allocator.free(owned_params);
        const owned_results = try self.allocator.dupe(ValueType, function_type.results);
        errdefer self.allocator.free(owned_results);
        try self.types.append(self.allocator, .{ .params = owned_params, .results = owned_results });
        return @intCast(self.types.items.len - 1);
    }

    pub fn importFunction(self: *Object, module: []const u8, name: []const u8, type_index: u32) !FunctionRef {
        if (self.data_segments.items.len != 0)
            return Error.InvalidObjectOrder;
        if (type_index >= self.types.items.len)
            return Error.InvalidTypeIndex;
        if (name.len == 0)
            return Error.EmptyFunctionName;
        if (self.imports.items.len == std.math.maxInt(u32))
            return Error.TooManyFunctions;
        const owned_module = try self.allocator.dupe(u8, module);
        errdefer self.allocator.free(owned_module);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.imports.append(self.allocator, .{
            .module = owned_module,
            .name = owned_name,
            .type_index = type_index,
        });
        const index: u32 = @intCast(self.imports.items.len - 1);
        return .{ .function_index = index, .symbol_index = index, .type_index = type_index };
    }

    pub fn defineFunction(self: *Object, name: []const u8, type_index: u32, symbol_flags: u32, body: Body) !FunctionRef {
        if (self.data_segments.items.len != 0)
            return Error.InvalidObjectOrder;
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

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_body = try self.allocator.dupe(u8, body.bytes.items);
        errdefer self.allocator.free(owned_body);
        const owned_relocations = try self.allocator.dupe(Body.Relocation, body.relocations.items);
        errdefer self.allocator.free(owned_relocations);

        try self.functions.append(self.allocator, .{
            .name = owned_name,
            .type_index = type_index,
            .symbol_flags = symbol_flags,
            .body = owned_body,
            .relocations = owned_relocations,
        });
        const function_index: u32 = @intCast(self.imports.items.len + self.functions.items.len - 1);
        const symbol_index: u32 = function_index;
        return .{ .function_index = function_index, .symbol_index = symbol_index, .type_index = type_index };
    }

    pub fn defineData(
        self: *Object,
        segment_name: []const u8,
        symbol_name: []const u8,
        symbol_flags: u32,
        alignment_log2: u32,
        bytes: []const u8,
    ) !DataRef {
        if (segment_name.len == 0 or symbol_name.len == 0)
            return Error.EmptyFunctionName;
        if (alignment_log2 >= 32 or bytes.len > std.math.maxInt(u32) or self.data_segments.items.len >= std.math.maxInt(u32))
            return Error.IntegerOverflow;
        const alignment = @as(u32, 1) << @intCast(alignment_log2);
        const padded = std.math.add(u32, self.data_size, alignment - 1) catch return Error.IntegerOverflow;
        const memory_offset = padded & ~(alignment - 1);
        const end = std.math.add(u32, memory_offset, @intCast(bytes.len)) catch return Error.IntegerOverflow;
        const segment_index: u32 = @intCast(self.data_segments.items.len);
        const symbol_count = std.math.add(usize, self.imports.items.len, self.functions.items.len) catch return Error.IntegerOverflow;
        if (symbol_count > std.math.maxInt(u32))
            return Error.IntegerOverflow;
        const symbol_index = std.math.add(u32, @intCast(symbol_count), segment_index) catch return Error.IntegerOverflow;

        const owned_name = try self.allocator.dupe(u8, segment_name);
        errdefer self.allocator.free(owned_name);
        const owned_symbol_name = try self.allocator.dupe(u8, symbol_name);
        errdefer self.allocator.free(owned_symbol_name);
        const owned_bytes = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned_bytes);
        try self.data_segments.append(self.allocator, .{
            .name = owned_name,
            .symbol_name = owned_symbol_name,
            .symbol_flags = symbol_flags,
            .alignment_log2 = alignment_log2,
            .memory_offset = memory_offset,
            .bytes = owned_bytes,
            .relocations = .empty,
        });
        self.data_size = end;
        return .{ .segment_index = segment_index, .symbol_index = symbol_index, .memory_offset = memory_offset };
    }

    pub fn relocateDataTableIndex(self: *Object, source: DataRef, offset: u32, target: FunctionRef) !void {
        if (target.symbol_index >= self.imports.items.len + self.functions.items.len)
            return Error.InvalidDataRelocationOffset;
        try self.appendDataRelocation(source, .{
            .kind = relocation.table_index_i32,
            .segment_offset = offset,
            .symbol_index = target.symbol_index,
            .addend = 0,
        });
    }

    pub fn relocateDataMemoryAddress(self: *Object, source: DataRef, offset: u32, target: DataRef, addend: i32) !void {
        if (target.segment_index >= self.data_segments.items.len)
            return Error.InvalidDataRelocationOffset;
        try self.appendDataRelocation(source, .{
            .kind = relocation.memory_addr_i32,
            .segment_offset = offset,
            .symbol_index = target.symbol_index,
            .addend = addend,
        });
    }

    fn appendDataRelocation(self: *Object, source: DataRef, item: DataRelocation) !void {
        if (source.segment_index >= self.data_segments.items.len)
            return Error.InvalidDataRelocationOffset;
        const segment = &self.data_segments.items[source.segment_index];
        if (@as(usize, item.segment_offset) + 4 > segment.bytes.len)
            return Error.InvalidDataRelocationOffset;
        if (segment.relocations.items.len != 0 and segment.relocations.items[segment.relocations.items.len - 1].segment_offset >= item.segment_offset)
            return Error.InvalidDataRelocationOffset;
        try segment.relocations.append(self.allocator, item);
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

        const has_data = self.data_segments.items.len != 0;
        const has_table_relocations = self.hasTableRelocations();
        if (self.imports.items.len != 0 or has_data or has_table_relocations) {
            var import_payload: std.ArrayList(u8) = .empty;
            defer import_payload.deinit(self.allocator);
            const infrastructure_imports: usize = @as(usize, @intFromBool(has_data)) + @as(usize, @intFromBool(has_table_relocations));
            try appendUleb(&import_payload, self.allocator, self.imports.items.len + infrastructure_imports);
            if (has_data) {
                try appendName(&import_payload, self.allocator, "env");
                try appendName(&import_payload, self.allocator, "__linear_memory");
                try import_payload.append(self.allocator, 0x02);
                try appendUleb(&import_payload, self.allocator, 0);
                try appendUleb(&import_payload, self.allocator, 1);
            }
            for (self.imports.items) |function_import| {
                try appendName(&import_payload, self.allocator, function_import.module);
                try appendName(&import_payload, self.allocator, function_import.name);
                try import_payload.append(self.allocator, 0x00);
                try appendUleb(&import_payload, self.allocator, function_import.type_index);
            }
            if (has_table_relocations) {
                try appendName(&import_payload, self.allocator, "env");
                try appendName(&import_payload, self.allocator, "__indirect_function_table");
                try import_payload.append(self.allocator, 0x01);
                try import_payload.append(self.allocator, 0x70);
                try appendUleb(&import_payload, self.allocator, 0);
                try appendUleb(&import_payload, self.allocator, self.functions.items.len);
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

        if (has_table_relocations) {
            var element_payload: std.ArrayList(u8) = .empty;
            defer element_payload.deinit(self.allocator);
            try appendUleb(&element_payload, self.allocator, 1);
            try appendUleb(&element_payload, self.allocator, 0);
            try element_payload.append(self.allocator, 0x41);
            try appendSleb(&element_payload, self.allocator, 1);
            try element_payload.append(self.allocator, 0x0b);
            try appendUleb(&element_payload, self.allocator, self.functions.items.len);
            for (self.functions.items, 0..) |_, index|
                try appendUleb(&element_payload, self.allocator, self.imports.items.len + index);
            try appendSection(&output, self.allocator, 9, element_payload.items);
            section_index += 1;
        }

        if (has_data) {
            var data_count_payload: std.ArrayList(u8) = .empty;
            defer data_count_payload.deinit(self.allocator);
            try appendUleb(&data_count_payload, self.allocator, self.data_segments.items.len);
            try appendSection(&output, self.allocator, 12, data_count_payload.items);
            section_index += 1;
        }

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
        section_index += 1;

        const data_section_index = section_index;
        var data_relocations: std.ArrayList(DataRelocation) = .empty;
        defer data_relocations.deinit(self.allocator);
        if (has_data) {
            var data_payload: std.ArrayList(u8) = .empty;
            defer data_payload.deinit(self.allocator);
            try appendUleb(&data_payload, self.allocator, self.data_segments.items.len);
            for (self.data_segments.items) |segment| {
                try appendUleb(&data_payload, self.allocator, 0);
                try data_payload.append(self.allocator, 0x41);
                try appendSleb(&data_payload, self.allocator, @bitCast(segment.memory_offset));
                try data_payload.append(self.allocator, 0x0b);
                try appendUleb(&data_payload, self.allocator, segment.bytes.len);
                const bytes_start = data_payload.items.len;
                try data_payload.appendSlice(self.allocator, segment.bytes);
                for (segment.relocations.items) |item| {
                    var relocated = item;
                    relocated.segment_offset = @intCast(bytes_start + item.segment_offset);
                    try data_relocations.append(self.allocator, relocated);
                }
            }
            try appendSection(&output, self.allocator, 11, data_payload.items);
            section_index += 1;
        }

        var linking_payload: std.ArrayList(u8) = .empty;
        defer linking_payload.deinit(self.allocator);
        try appendUleb(&linking_payload, self.allocator, 2);
        var symbols_payload: std.ArrayList(u8) = .empty;
        defer symbols_payload.deinit(self.allocator);
        try appendUleb(&symbols_payload, self.allocator, self.imports.items.len + self.functions.items.len + self.data_segments.items.len);
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
        for (self.data_segments.items, 0..) |segment, index| {
            try symbols_payload.append(self.allocator, 0x01);
            try appendUleb(&symbols_payload, self.allocator, segment.symbol_flags);
            try appendName(&symbols_payload, self.allocator, segment.symbol_name);
            try appendUleb(&symbols_payload, self.allocator, index);
            try appendUleb(&symbols_payload, self.allocator, 0);
            try appendUleb(&symbols_payload, self.allocator, segment.bytes.len);
        }
        try linking_payload.append(self.allocator, 8);
        try appendUleb(&linking_payload, self.allocator, symbols_payload.items.len);
        try linking_payload.appendSlice(self.allocator, symbols_payload.items);
        if (has_data) {
            var segment_info_payload: std.ArrayList(u8) = .empty;
            defer segment_info_payload.deinit(self.allocator);
            try appendUleb(&segment_info_payload, self.allocator, self.data_segments.items.len);
            for (self.data_segments.items) |segment| {
                try appendName(&segment_info_payload, self.allocator, segment.name);
                try appendUleb(&segment_info_payload, self.allocator, segment.alignment_log2);
                try appendUleb(&segment_info_payload, self.allocator, 0);
            }
            try linking_payload.append(self.allocator, 5);
            try appendUleb(&linking_payload, self.allocator, segment_info_payload.items.len);
            try linking_payload.appendSlice(self.allocator, segment_info_payload.items);
        }
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

        if (data_relocations.items.len != 0) {
            var reloc_payload: std.ArrayList(u8) = .empty;
            defer reloc_payload.deinit(self.allocator);
            try appendUleb(&reloc_payload, self.allocator, data_section_index);
            try appendUleb(&reloc_payload, self.allocator, data_relocations.items.len);
            for (data_relocations.items) |item| {
                try reloc_payload.append(self.allocator, item.kind);
                try appendUleb(&reloc_payload, self.allocator, item.segment_offset);
                try appendUleb(&reloc_payload, self.allocator, item.symbol_index);
                if (item.kind == relocation.memory_addr_i32)
                    try appendSleb(&reloc_payload, self.allocator, item.addend);
            }
            try appendCustomSection(&output, self.allocator, "reloc.DATA", reloc_payload.items);
        }

        return output.toOwnedSlice(self.allocator);
    }

    fn hasTableRelocations(self: *const Object) bool {
        for (self.data_segments.items) |segment|
            for (segment.relocations.items) |item|
                if (item.kind == relocation.table_index_i32)
                    return true;
        return false;
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

fn appendSleb64(output: *std.ArrayList(u8), allocator: std.mem.Allocator, input: i64) !void {
    var value = input;
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

test "defined functions own their names bodies and relocations" {
    const allocator = std.testing.allocator;
    const no_values = [_]ValueType{};

    var object = Object.init(allocator);
    defer object.deinit();
    const function_type = try object.addType(.{ .params = &no_values, .results = &no_values });
    const external = try object.importFunction("env", "callee", function_type);

    {
        const dynamic_name = try std.fmt.allocPrint(allocator, "dynamic_{d}", .{17});
        defer allocator.free(dynamic_name);
        var body = try Body.init(allocator, &.{});
        defer body.deinit(allocator);
        try body.call(allocator, external);
        try body.finish(allocator);
        _ = try object.defineFunction(dynamic_name, function_type, symbol.exported, body);

        try std.testing.expect(object.functions.items[0].name.ptr != dynamic_name.ptr);
        try std.testing.expect(object.functions.items[0].body.ptr != body.bytes.items.ptr);
        try std.testing.expect(object.functions.items[0].relocations.ptr != body.relocations.items.ptr);

        dynamic_name[0] = 'X';
        body.bytes.items[0] = 0xff;
        body.relocations.items[0].body_offset = 0;
    }

    const emitted = try object.emit();
    defer allocator.free(emitted);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "dynamic_17") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "reloc.CODE") != null);
}

test "emits linking-v2 data symbols and table and memory relocations" {
    const allocator = std.testing.allocator;
    const params = [_]ValueType{ .i32, .i32 };
    const status_result = [_]ValueType{.i32};

    var object = Object.init(allocator);
    defer object.deinit();
    const function_type = try object.addType(.{ .params = &params, .results = &status_result });

    var body = try Body.init(allocator, &.{});
    defer body.deinit(allocator);
    try body.i32Const(allocator, 0);
    try body.finish(allocator);
    const function = try object.defineFunction("generated", function_type, symbol.visibility_hidden, body);

    var proto_bytes = [_]u8{0} ** 64;
    std.mem.writeInt(u32, proto_bytes[40..44], 1, .little);
    const protos = try object.defineData(".rodata.protos", "protos", symbol.visibility_hidden, 2, &proto_bytes);
    var program_bytes = [_]u8{0} ** 68;
    std.mem.writeInt(u32, program_bytes[40..44], protos.memory_offset, .little);
    const program = try object.defineData(".rodata.program", "program", 0, 2, &program_bytes);
    try object.relocateDataTableIndex(protos, 40, function);
    try object.relocateDataMemoryAddress(program, 40, protos, 0);

    const first = try object.emit();
    defer allocator.free(first);
    const second = try object.emit();
    defer allocator.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "__linear_memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "__indirect_function_table") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "reloc.DATA") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, ".rodata.protos") != null);
}
