const std = @import("std");
const identity_v1 = @import("frontend_identity_v1.zig");

pub const magic = [_]u8{ 'M', 'C', 'L', 'U', 'A', 'O', 'T', 0 };
pub const schema_version: u16 = 1;
pub const header_size: usize = 224;
pub const section_size: usize = 32;
pub const no_id: u32 = 0xffff_ffff;
pub const flag_pre_dse_ir: u32 = 1;
pub const required_flags: u32 = flag_pre_dse_ir;
pub const max_sections: u32 = 21;

pub const Error = error{
    Truncated,
    BadMagic,
    UnsupportedVersion,
    BadHeaderSize,
    BadFlags,
    BadTotalSize,
    ReservedNotZero,
    TooManySections,
    InvalidRoot,
    InvalidCounts,
    UnknownSection,
    NonCanonicalSectionOrder,
    NonCanonicalSectionOffset,
    SectionOutOfBounds,
    InvalidRecordSize,
    InvalidSectionLength,
    MissingSection,
    DuplicateSection,
    PinMismatch,
    PatchsetMismatch,
    FrontendBuildMismatch,
    IrEnumMismatch,
    LayoutMismatch,
    CountMismatch,
    InvalidString,
    InvalidProto,
    InvalidProtoGraph,
    InvalidVmConstant,
    InvalidIrFunction,
    InvalidIrBlock,
    InvalidIrInstruction,
    InvalidIrOperand,
    InvalidIrConstant,
    InvalidBytecodeMapping,
    IndexOutOfBounds,
};

pub const ExpectedIdentity = struct {
    luau_pin: ?[32]u8 = null,
    patchset: ?[32]u8 = null,
    frontend_build: ?[32]u8 = null,
    ir_enum: ?[32]u8 = null,
    layout: ?[32]u8 = null,
};

pub const production_identity = ExpectedIdentity{
    .luau_pin = .{
        0xe5, 0x1e, 0xad, 0x5f, 0x54, 0x16, 0x33, 0x69, 0x3d, 0x54, 0x80, 0x57, 0xe0, 0x43, 0x19, 0x27,
        0xf3, 0x03, 0x6c, 0x13, 0xb1, 0x85, 0xfd, 0xb3, 0x7f, 0xbc, 0x3f, 0x5a, 0x26, 0x1e, 0x66, 0x76,
    },
    .patchset = .{
        0x5f, 0xd5, 0xcf, 0x3a, 0x3f, 0xcb, 0x66, 0xa0, 0x04, 0xaa, 0x53, 0x87, 0x94, 0xb0, 0xef, 0x1e,
        0x43, 0x17, 0xed, 0xd6, 0xa3, 0x20, 0x8d, 0xd8, 0x7c, 0xf1, 0x12, 0xa3, 0x10, 0x5c, 0xf1, 0x22,
    },
    .frontend_build = identity_v1.frontend_contract_sha256,
    .ir_enum = .{
        0x76, 0x5f, 0x91, 0x88, 0xe0, 0x7a, 0x38, 0x86, 0xc2, 0x9b, 0x5b, 0xb1, 0x46, 0x24, 0x12, 0x86,
        0xd1, 0xf9, 0x5c, 0x80, 0x1a, 0x89, 0x07, 0xaa, 0x03, 0x14, 0x7d, 0xf5, 0x24, 0xe7, 0xc3, 0x99,
    },
    .layout = .{
        0x42, 0x5d, 0x38, 0xd7, 0x5e, 0xf9, 0xf4, 0xe2, 0x66, 0x93, 0xa6, 0x90, 0xe0, 0x85, 0x7f, 0x90,
        0x2a, 0xa7, 0x6f, 0x1c, 0x18, 0x56, 0x19, 0x6a, 0xc3, 0x0d, 0xc6, 0x23, 0x6e, 0xa4, 0xc4, 0x96,
    },
};

pub const Header = struct {
    flags: u32,
    total_size: u64,
    luau_pin: [32]u8,
    patchset: [32]u8,
    frontend_build: [32]u8,
    ir_enum: [32]u8,
    layout: [32]u8,
    module_count: u32,
    proto_count: u32,
    ir_function_count: u32,
    string_count: u32,
    root_proto_id: u32,
    section_count: u32,
};

pub const SectionKind = enum(u16) {
    strings = 1,
    string_bytes = 2,
    protos = 3,
    proto_children = 4,
    bytecode_words = 5,
    vm_constants = 6,
    vm_constant_items = 7,
    locals = 8,
    upvalue_names = 9,
    typeinfo_bytes = 10,
    lineinfo_bytes = 11,
    abslineinfo = 12,
    debug_opcodes = 13,
    feedback = 14,
    ir_functions = 15,
    ir_blocks = 16,
    ir_instructions = 17,
    ir_operands = 18,
    ir_constants = 19,
    bc_mapping = 20,
    compiled_bytecode = 21,

    pub fn expectedRecordSize(self: SectionKind) u32 {
        return switch (self) {
            .strings => 16,
            .string_bytes, .typeinfo_bytes, .lineinfo_bytes, .debug_opcodes, .compiled_bytecode => 1,
            .protos => 128,
            .proto_children, .bytecode_words, .upvalue_names, .abslineinfo => 4,
            .vm_constants => 40,
            .vm_constant_items => 8,
            .locals => 20,
            .feedback => 12,
            .ir_functions => 64,
            .ir_blocks => 32,
            .ir_instructions => 24,
            .ir_operands, .bc_mapping => 8,
            .ir_constants => 16,
        };
    }
};

pub const Section = struct {
    kind: SectionKind,
    flags: u16,
    record_size: u32,
    offset: u64,
    length: u64,
    count: u32,

    pub fn bytes(self: Section, snapshot: []const u8) []const u8 {
        const start: usize = @intCast(self.offset);
        const end: usize = @intCast(self.offset + self.length);
        return snapshot[start..end];
    }
};

// These are compiler-owned views of the byte protocol. They intentionally contain values rather
// than pointers into Luau C++ objects, and all instruction/block/constant IDs remain local to an
// IrFunction. Keep the enum values pinned to the identities carried by FrontendSnapshotV1.
pub const IrCommand = enum(u8) {
    nop = 0,
    load_tag = 1,
    load_pointer = 2,
    load_double = 3,
    load_int = 4,
    load_int64 = 5,
    load_float = 6,
    load_tvalue = 7,
    load_env = 8,
    get_closure_upval_addr = 12,
    store_tag = 13,
    store_extra = 14,
    store_pointer = 15,
    store_double = 16,
    store_int = 17,
    store_int64 = 18,
    store_vector = 19,
    store_tvalue = 20,
    store_split_tvalue = 21,
    add_int = 22,
    sub_int = 23,
    add_int64 = 24,
    sub_int64 = 25,
    mul_int64 = 26,
    div_int64 = 27,
    idiv_int64 = 28,
    udiv_int64 = 29,
    rem_int64 = 30,
    urem_int64 = 31,
    mod_int64 = 32,
    check_div_int64 = 33,
    sexti8_int = 34,
    sexti16_int = 35,
    add_num = 36,
    sub_num = 37,
    mul_num = 38,
    div_num = 39,
    idiv_num = 40,
    mod_num = 41,
    muladd_num = 42,
    min_num = 43,
    max_num = 44,
    unm_num = 45,
    floor_num = 46,
    ceil_num = 47,
    round_num = 48,
    sqrt_num = 49,
    abs_num = 50,
    sign_num = 51,
    add_float = 52,
    sub_float = 53,
    mul_float = 54,
    div_float = 55,
    min_float = 56,
    max_float = 57,
    unm_float = 58,
    floor_float = 59,
    ceil_float = 60,
    sqrt_float = 61,
    abs_float = 62,
    sign_float = 63,
    select_num = 64,
    select_int64 = 65,
    select_vec = 66,
    select_if_truthy = 67,
    add_vec = 68,
    sub_vec = 69,
    mul_vec = 70,
    div_vec = 71,
    idiv_vec = 72,
    muladd_vec = 73,
    unm_vec = 74,
    min_vec = 75,
    max_vec = 76,
    floor_vec = 77,
    ceil_vec = 78,
    abs_vec = 79,
    dot_vec = 80,
    extract_vec = 81,
    not_any = 82,
    cmp_any = 83,
    cmp_int = 84,
    cmp_int64 = 85,
    cmp_tag = 86,
    cmp_split_tvalue = 87,
    jump = 88,
    jump_if_truthy = 89,
    jump_if_falsy = 90,
    jump_eq_tag = 91,
    jump_cmp_int = 92,
    jump_eq_pointer = 93,
    jump_cmp_num = 94,
    jump_cmp_float = 95,
    jump_forn_loop_cond = 96,
    int_to_num = 106,
    int64_to_num = 107,
    uint_to_num = 108,
    uint_to_float = 109,
    num_to_int = 110,
    num_to_int64 = 111,
    num_to_uint = 112,
    float_to_num = 113,
    num_to_float = 114,
    float_to_vec = 115,
    tag_vector = 116,
    truncate_uint = 117,
    do_arith = 123,
    get_cached_import = 127,
    get_upvalue = 129,
    set_upvalue = 130,
    check_tag = 131,
    check_truthy = 132,
    check_safe_env = 135,
    check_cmp_num = 142,
    check_cmp_int = 143,
    check_cmp_int64 = 144,
    interrupt = 145,
    check_gc = 146,
    set_savedpc = 150,
    close_upvals = 151,
    capture = 152,
    call = 154,
    return_ = 155,
    fallback_prepvarargs = 165,
    fallback_getvarargs = 166,
    newclosure = 167,
    fallback_dupclosure = 168,
    substitute = 170,
    mark_used = 171,
    mark_dead = 172,
    bitand_int64 = 173,
    bitxor_int64 = 174,
    bitor_int64 = 175,
    bitnot_int64 = 176,
    bitlshift_int64 = 177,
    bitrshift_int64 = 178,
    bitarshift_int64 = 179,
    bitlrotate_int64 = 180,
    bitrrotate_int64 = 181,
    bitcountlz_int64 = 182,
    bitcountrz_int64 = 183,
    byteswap_int64 = 184,
    bitand_uint = 185,
    bitxor_uint = 186,
    bitor_uint = 187,
    bitnot_uint = 188,
    bitlshift_uint = 189,
    bitrshift_uint = 190,
    bitarshift_uint = 191,
    bitlrotate_uint = 192,
    bitrrotate_uint = 193,
    bitcountlz_uint = 194,
    bitcountrz_uint = 195,
    byteswap_uint = 196,
    findupval = 200,
    _,
};

pub const IrOperandKind = enum(u8) {
    none = 0,
    undef = 1,
    constant = 2,
    condition = 3,
    instruction = 4,
    block = 5,
    vm_reg = 6,
    vm_const = 7,
    vm_upvalue = 8,
    vm_exit = 9,
};

pub const IrConstantKind = enum(u8) {
    int = 0,
    int64 = 1,
    uint = 2,
    double = 3,
    tag = 4,
    import = 5,
};

pub const IrBlockKind = enum(u8) {
    bytecode = 0,
    fallback = 1,
    internal = 2,
    linearized = 3,
    exit_sync = 4,
    dead = 5,

    pub fn isCompilable(self: IrBlockKind) bool {
        return switch (self) {
            .bytecode, .internal, .linearized => true,
            .fallback, .exit_sync, .dead => false,
        };
    }
};

pub const VmConstantKind = enum(u8) {
    nil = 0,
    boolean = 1,
    number = 2,
    vector = 3,
    string = 4,
    integer = 5,
    import = 6,
    table = 7,
    closure = 8,
    class_shape = 9,
};

pub const IrCondition = enum(u8) {
    equal = 0,
    not_equal = 1,
    less = 2,
    not_less = 3,
    less_equal = 4,
    not_less_equal = 5,
    greater = 6,
    not_greater = 7,
    greater_equal = 8,
    not_greater_equal = 9,
    unsigned_less = 10,
    unsigned_less_equal = 11,
    unsigned_greater = 12,
    unsigned_greater_equal = 13,
};

pub const Proto = struct {
    id: u32,
    parent_id: u32,
    nups: u8,
    num_params: u8,
    is_vararg: bool,
    max_stack_size: u8,
    code_count: u32,
    vm_constant_start: u32,
    vm_constant_count: u32,
    child_start: u32,
    child_count: u32,
};

pub const VmConstant = struct {
    kind: VmConstantKind,
    payload0: u32,
    payload1: u32,
    payload2: u32,
    payload3: u32,
    bits0: u64,

    pub fn closureProtoId(self: VmConstant) ?u32 {
        if (self.kind != .closure)
            return null;
        return self.payload0;
    }
};

pub const VmConstantItem = struct {
    key: u32,
    value: u32,
};

pub const IrFunction = struct {
    id: u32,
    proto_id: u32,
    entry_block: u32,
    variadic: bool,
    block_start: u32,
    block_count: u32,
    instruction_start: u32,
    instruction_count: u32,
    operand_start: u32,
    operand_count: u32,
    constant_start: u32,
    constant_count: u32,
};

pub const IrBlock = struct {
    kind: IrBlockKind,
    flags: u8,
    use_count: u16,
    start: u32,
    finish: u32,
    expected_next_block: u32,
    start_pc: u32,

    pub fn isEmpty(self: IrBlock) bool {
        return self.start == no_id;
    }
};

pub const IrInstruction = struct {
    command: IrCommand,
    use_count: u16,
    operand_start: u32,
    operand_count: u32,
};

pub const IrOperand = struct {
    kind: IrOperandKind,
    value: u32,
};

pub const IrConstant = struct {
    kind: IrConstantKind,
    bits: u64,

    pub fn intValue(self: IrConstant) ?i32 {
        if (self.kind != .int)
            return null;
        return @bitCast(@as(u32, @truncate(self.bits)));
    }

    pub fn uintValue(self: IrConstant) ?u32 {
        if (self.kind != .uint)
            return null;
        return @truncate(self.bits);
    }

    pub fn int64Value(self: IrConstant) ?i64 {
        if (self.kind != .int64)
            return null;
        return @bitCast(self.bits);
    }

    pub fn doubleValue(self: IrConstant) ?f64 {
        if (self.kind != .double)
            return null;
        return @bitCast(self.bits);
    }

    pub fn tagValue(self: IrConstant) ?u8 {
        if (self.kind != .tag)
            return null;
        return @truncate(self.bits);
    }

    pub fn importValue(self: IrConstant) ?u32 {
        if (self.kind != .import)
            return null;
        return @truncate(self.bits);
    }
};

pub const Snapshot = struct {
    bytes: []const u8,
    header: Header,

    pub fn section(self: Snapshot, wanted: SectionKind) ?Section {
        var index: u32 = 0;
        while (index < self.header.section_count) : (index += 1) {
            const descriptor = readSection(self.bytes, index) catch unreachable;
            if (descriptor.kind == wanted)
                return descriptor;
        }
        return null;
    }

    pub fn requireSection(self: Snapshot, wanted: SectionKind) Error!Section {
        return self.section(wanted) orelse Error.MissingSection;
    }

    pub fn proto(self: Snapshot, id: u32) Error!Proto {
        const records = try self.requireSection(.protos);
        if (id >= records.count)
            return Error.IndexOutOfBounds;
        const item = recordBytes(self, records, id);
        return .{
            .id = readU32(item, 0),
            .parent_id = readU32(item, 4),
            .nups = item[29],
            .num_params = item[30],
            .is_vararg = item[31] != 0,
            .max_stack_size = item[32],
            .code_count = readU32(item, 40),
            .vm_constant_start = readU32(item, 44),
            .vm_constant_count = readU32(item, 48),
            .child_start = readU32(item, 52),
            .child_count = readU32(item, 56),
        };
    }

    pub fn protoChild(self: Snapshot, proto_value: Proto, id: u32) Error!u32 {
        if (id >= proto_value.child_count)
            return Error.IndexOutOfBounds;
        const records = try self.requireSection(.proto_children);
        return readU32(recordBytes(self, records, proto_value.child_start + id), 0);
    }

    pub fn vmConstant(self: Snapshot, proto_value: Proto, id: u32) Error!VmConstant {
        if (id >= proto_value.vm_constant_count)
            return Error.IndexOutOfBounds;
        const records = try self.requireSection(.vm_constants);
        const item = recordBytes(self, records, proto_value.vm_constant_start + id);
        return .{
            .kind = @enumFromInt(item[0]),
            .payload0 = readU32(item, 4),
            .payload1 = readU32(item, 8),
            .payload2 = readU32(item, 12),
            .payload3 = readU32(item, 16),
            .bits0 = readU64(item, 24),
        };
    }

    pub fn vmConstantItem(self: Snapshot, id: u32) Error!VmConstantItem {
        const records = try self.requireSection(.vm_constant_items);
        if (id >= records.count)
            return Error.IndexOutOfBounds;
        const item = recordBytes(self, records, id);
        return .{ .key = readU32(item, 0), .value = readU32(item, 4) };
    }

    pub fn string(self: Snapshot, id: u32) Error![]const u8 {
        const strings = try self.requireSection(.strings);
        const bytes = try self.requireSection(.string_bytes);
        if (id >= strings.count)
            return Error.IndexOutOfBounds;
        const item = recordBytes(self, strings, id);
        const start = readU64(item, 0);
        const size = readU32(item, 8);
        if (start > bytes.count or size > bytes.count - start)
            return Error.InvalidString;
        const begin = std.math.add(usize, @as(usize, @intCast(bytes.offset)), @as(usize, @intCast(start))) catch return Error.InvalidString;
        const end = std.math.add(usize, begin, @as(usize, size)) catch return Error.InvalidString;
        return self.bytes[begin..end];
    }

    pub fn irFunction(self: Snapshot, id: u32) Error!IrFunction {
        const records = try self.requireSection(.ir_functions);
        if (id >= records.count)
            return Error.IndexOutOfBounds;
        const item = recordBytes(self, records, id);
        return .{
            .id = readU32(item, 0),
            .proto_id = readU32(item, 4),
            .entry_block = readU32(item, 8),
            .variadic = item[12] != 0,
            .block_start = readU32(item, 16),
            .block_count = readU32(item, 20),
            .instruction_start = readU32(item, 24),
            .instruction_count = readU32(item, 28),
            .operand_start = readU32(item, 32),
            .operand_count = readU32(item, 36),
            .constant_start = readU32(item, 40),
            .constant_count = readU32(item, 44),
        };
    }

    pub fn irBlock(self: Snapshot, function: IrFunction, id: u32) Error!IrBlock {
        if (id >= function.block_count)
            return Error.IndexOutOfBounds;
        const records = try self.requireSection(.ir_blocks);
        const item = recordBytes(self, records, function.block_start + id);
        return .{
            .kind = @enumFromInt(item[0]),
            .flags = item[1],
            .use_count = readU16(item, 2),
            .start = readU32(item, 4),
            .finish = readU32(item, 8),
            .expected_next_block = readU32(item, 20),
            .start_pc = readU32(item, 24),
        };
    }

    pub fn irInstruction(self: Snapshot, function: IrFunction, id: u32) Error!IrInstruction {
        if (id >= function.instruction_count)
            return Error.IndexOutOfBounds;
        const records = try self.requireSection(.ir_instructions);
        const item = recordBytes(self, records, function.instruction_start + id);
        return .{
            .command = @enumFromInt(item[0]),
            .use_count = readU16(item, 2),
            .operand_start = readU32(item, 8),
            .operand_count = readU32(item, 12),
        };
    }

    pub fn irOperand(self: Snapshot, instruction: IrInstruction, id: u32) Error!IrOperand {
        if (id >= instruction.operand_count)
            return Error.IndexOutOfBounds;
        const records = try self.requireSection(.ir_operands);
        const item = recordBytes(self, records, instruction.operand_start + id);
        return .{ .kind = @enumFromInt(item[0]), .value = readU32(item, 4) };
    }

    pub fn irConstant(self: Snapshot, function: IrFunction, id: u32) Error!IrConstant {
        if (id >= function.constant_count)
            return Error.IndexOutOfBounds;
        const records = try self.requireSection(.ir_constants);
        const item = recordBytes(self, records, function.constant_start + id);
        return .{ .kind = @enumFromInt(item[0]), .bits = readU64(item, 8) };
    }
};

pub fn parse(bytes: []const u8, expected: ExpectedIdentity) Error!Snapshot {
    if (bytes.len < header_size)
        return Error.Truncated;
    if (!std.mem.eql(u8, bytes[0..8], &magic))
        return Error.BadMagic;
    if (readU16(bytes, 8) != schema_version)
        return Error.UnsupportedVersion;
    if (readU16(bytes, 10) != header_size)
        return Error.BadHeaderSize;

    const flags = readU32(bytes, 12);
    if (flags != required_flags)
        return Error.BadFlags;

    const total_size = readU64(bytes, 16);
    if (total_size != bytes.len)
        return Error.BadTotalSize;
    if (!allZero(bytes[208..224]))
        return Error.ReservedNotZero;

    const section_count = readU32(bytes, 204);
    if (section_count > max_sections)
        return Error.TooManySections;
    const directory_size = std.math.mul(usize, @as(usize, section_count), section_size) catch return Error.SectionOutOfBounds;
    const payload_start = std.math.add(usize, header_size, directory_size) catch return Error.SectionOutOfBounds;
    if (payload_start > bytes.len)
        return Error.Truncated;

    const header = Header{
        .flags = flags,
        .total_size = total_size,
        .luau_pin = bytes[24..56].*,
        .patchset = bytes[56..88].*,
        .frontend_build = bytes[88..120].*,
        .ir_enum = bytes[120..152].*,
        .layout = bytes[152..184].*,
        .module_count = readU32(bytes, 184),
        .proto_count = readU32(bytes, 188),
        .ir_function_count = readU32(bytes, 192),
        .string_count = readU32(bytes, 196),
        .root_proto_id = readU32(bytes, 200),
        .section_count = section_count,
    };

    if (header.module_count != 1 or header.proto_count == 0 or header.ir_function_count != header.proto_count or header.root_proto_id >= header.proto_count)
        return Error.InvalidCounts;

    try checkIdentity(expected.luau_pin, header.luau_pin, Error.PinMismatch);
    try checkIdentity(expected.patchset, header.patchset, Error.PatchsetMismatch);
    try checkIdentity(expected.frontend_build, header.frontend_build, Error.FrontendBuildMismatch);
    try checkIdentity(expected.ir_enum, header.ir_enum, Error.IrEnumMismatch);
    try checkIdentity(expected.layout, header.layout, Error.LayoutMismatch);

    var previous_kind: u16 = 0;
    var expected_offset: u64 = payload_start;
    var index: u32 = 0;
    while (index < section_count) : (index += 1) {
        const section = try readSection(bytes, index);
        const raw_kind = @intFromEnum(section.kind);
        if (raw_kind <= previous_kind)
            return if (raw_kind == previous_kind) Error.DuplicateSection else Error.NonCanonicalSectionOrder;
        previous_kind = raw_kind;
        if (section.flags != 0)
            return Error.ReservedNotZero;
        if (section.record_size != section.kind.expectedRecordSize())
            return Error.InvalidRecordSize;
        const computed_length = std.math.mul(u64, section.record_size, section.count) catch return Error.InvalidSectionLength;
        if (section.length != computed_length)
            return Error.InvalidSectionLength;
        if (section.offset != expected_offset)
            return Error.NonCanonicalSectionOffset;
        expected_offset = std.math.add(u64, section.offset, section.length) catch return Error.SectionOutOfBounds;
        if (expected_offset > bytes.len)
            return Error.SectionOutOfBounds;
    }
    if (expected_offset != bytes.len)
        return Error.BadTotalSize;

    return .{ .bytes = bytes, .header = header };
}

pub fn validateModel(snapshot: Snapshot) Error!void {
    var kind_value: u16 = @intFromEnum(SectionKind.strings);
    while (kind_value <= @intFromEnum(SectionKind.compiled_bytecode)) : (kind_value += 1) {
        _ = try snapshot.requireSection(@enumFromInt(kind_value));
    }

    const strings = try snapshot.requireSection(.strings);
    const string_bytes = try snapshot.requireSection(.string_bytes);
    const protos = try snapshot.requireSection(.protos);
    const children = try snapshot.requireSection(.proto_children);
    const code = try snapshot.requireSection(.bytecode_words);
    const vm_constants = try snapshot.requireSection(.vm_constants);
    const vm_constant_items = try snapshot.requireSection(.vm_constant_items);
    const locals = try snapshot.requireSection(.locals);
    const upvalue_names = try snapshot.requireSection(.upvalue_names);
    const typeinfo = try snapshot.requireSection(.typeinfo_bytes);
    const lineinfo = try snapshot.requireSection(.lineinfo_bytes);
    const abslineinfo = try snapshot.requireSection(.abslineinfo);
    const debug_opcodes = try snapshot.requireSection(.debug_opcodes);
    const feedback = try snapshot.requireSection(.feedback);
    const ir_functions = try snapshot.requireSection(.ir_functions);
    const ir_blocks = try snapshot.requireSection(.ir_blocks);
    const ir_instructions = try snapshot.requireSection(.ir_instructions);
    const ir_operands = try snapshot.requireSection(.ir_operands);
    const ir_constants = try snapshot.requireSection(.ir_constants);
    const bc_mapping = try snapshot.requireSection(.bc_mapping);
    const compiled_bytecode = try snapshot.requireSection(.compiled_bytecode);

    if (strings.count != snapshot.header.string_count or protos.count != snapshot.header.proto_count or ir_functions.count != snapshot.header.ir_function_count)
        return Error.CountMismatch;
    if (compiled_bytecode.count == 0)
        return Error.InvalidCounts;

    var string_cursor: u64 = 0;
    var index: u32 = 0;
    while (index < strings.count) : (index += 1) {
        const item = recordBytes(snapshot, strings, index);
        if (readU64(item, 0) != string_cursor or !spanFits(readU64(item, 0), readU32(item, 8), string_bytes.count))
            return Error.InvalidString;
        if (readU32(item, 12) != 0)
            return Error.InvalidString;
        string_cursor += readU32(item, 8);
    }
    if (string_cursor != string_bytes.count)
        return Error.InvalidString;

    index = 0;
    while (index < protos.count) : (index += 1) {
        const proto = recordBytes(snapshot, protos, index);
        if (readU32(proto, 0) != index or readU32(proto, 116) != index)
            return Error.InvalidProto;
        if (!allZero(proto[34..36]) or !allZero(proto[120..128]))
            return Error.ReservedNotZero;

        const parent = readU32(proto, 4);
        if ((index == snapshot.header.root_proto_id and parent != no_id) or
            (index != snapshot.header.root_proto_id and (parent >= protos.count or parent >= index)))
            return Error.InvalidProtoGraph;
        try validateOptionalId(readU32(proto, 8), strings.count, Error.InvalidProto);
        try validateOptionalId(readU32(proto, 12), strings.count, Error.InvalidProto);
        try validateSpan(proto, 36, code.count, Error.InvalidProto);
        try validateSpan(proto, 44, vm_constants.count, Error.InvalidProto);
        try validateSpan(proto, 52, children.count, Error.InvalidProto);
        try validateSpan(proto, 60, upvalue_names.count, Error.InvalidProto);
        try validateSpan(proto, 68, locals.count, Error.InvalidProto);
        try validateSpan(proto, 76, typeinfo.count, Error.InvalidProto);
        try validateSpan(proto, 84, lineinfo.count, Error.InvalidProto);
        try validateSpan(proto, 92, abslineinfo.count, Error.InvalidProto);
        try validateSpan(proto, 100, debug_opcodes.count, Error.InvalidProto);
        try validateSpan(proto, 108, feedback.count, Error.InvalidProto);

        const child_start = readU32(proto, 52);
        const child_count = readU32(proto, 56);
        var child_index: u32 = 0;
        while (child_index < child_count) : (child_index += 1) {
            const child = readU32(recordBytes(snapshot, children, child_start + child_index), 0);
            if (child <= index or child >= protos.count or readU32(recordBytes(snapshot, protos, child), 4) != index)
                return Error.InvalidProtoGraph;
        }

        const upvalue_start = readU32(proto, 60);
        const upvalue_count = readU32(proto, 64);
        if (upvalue_count != 0 and upvalue_count != proto[29])
            return Error.InvalidProto;
        var upvalue_index: u32 = 0;
        while (upvalue_index < upvalue_count) : (upvalue_index += 1)
            try validateOptionalId(readU32(recordBytes(snapshot, upvalue_names, upvalue_start + upvalue_index), 0), strings.count, Error.InvalidProto);

        const local_start = readU32(proto, 68);
        const local_count = readU32(proto, 72);
        const code_count = readU32(proto, 40);
        var local_index: u32 = 0;
        while (local_index < local_count) : (local_index += 1) {
            const local = recordBytes(snapshot, locals, local_start + local_index);
            try validateOptionalId(readU32(local, 0), strings.count, Error.InvalidProto);
            if (readU32(local, 4) > readU32(local, 8) or readU32(local, 8) > code_count or local[12] >= proto[32])
                return Error.InvalidProto;
            if (!allZero(local[13..20]))
                return Error.ReservedNotZero;
        }

        const line_count = readU32(proto, 88);
        const abs_count = readU32(proto, 96);
        if ((line_count != 0 and line_count != code_count) or (line_count == 0 and abs_count != 0))
            return Error.InvalidProto;

        const constant_start = readU32(proto, 44);
        const constant_count = readU32(proto, 48);
        var constant_index: u32 = 0;
        while (constant_index < constant_count) : (constant_index += 1) {
            const constant = recordBytes(snapshot, vm_constants, constant_start + constant_index);
            const constant_kind = constant[0];
            if (constant[1] != 0 or readU16(constant, 2) != 0 or !allZero(constant[20..24]) or !allZero(constant[32..40]))
                return Error.InvalidVmConstant;
            switch (constant_kind) {
                0 => if (!allZero(constant[4..32])) return Error.InvalidVmConstant,
                1 => if (readU32(constant, 4) > 1 or !allZero(constant[8..32])) return Error.InvalidVmConstant,
                2, 5 => if (!allZero(constant[4..24])) return Error.InvalidVmConstant,
                3 => if (!allZero(constant[20..32])) return Error.InvalidVmConstant,
                4 => {
                    if (readU32(constant, 4) >= strings.count or !allZero(constant[8..32])) return Error.InvalidVmConstant;
                },
                8 => {
                    if (readU32(constant, 4) >= protos.count or !allZero(constant[8..32])) return Error.InvalidVmConstant;
                },
                6 => {
                    const item_start = readU32(constant, 4);
                    const item_count = readU32(constant, 8);
                    if (item_count < 1 or item_count > 3 or !spanFits(item_start, item_count, vm_constant_items.count))
                        return Error.InvalidVmConstant;
                    var item_index: u32 = 0;
                    while (item_index < item_count) : (item_index += 1) {
                        const item = recordBytes(snapshot, vm_constant_items, item_start + item_index);
                        if (readU32(item, 0) >= constant_count or readU32(item, 4) != no_id)
                            return Error.InvalidVmConstant;
                    }
                },
                7 => {
                    const item_start = readU32(constant, 4);
                    const item_count = readU32(constant, 8);
                    if (!spanFits(item_start, item_count, vm_constant_items.count))
                        return Error.InvalidVmConstant;
                    var item_index: u32 = 0;
                    while (item_index < item_count) : (item_index += 1) {
                        const item = recordBytes(snapshot, vm_constant_items, item_start + item_index);
                        if (readU32(item, 0) >= constant_count)
                            return Error.InvalidVmConstant;
                        try validateOptionalId(readU32(item, 4), constant_count, Error.InvalidVmConstant);
                    }
                },
                9 => {
                    const item_start = readU32(constant, 8);
                    const item_count = std.math.add(u32, readU32(constant, 12), readU32(constant, 16)) catch return Error.InvalidVmConstant;
                    if (readU32(constant, 4) >= constant_count or !spanFits(item_start, item_count, vm_constant_items.count))
                        return Error.InvalidVmConstant;
                    var item_index: u32 = 0;
                    while (item_index < item_count) : (item_index += 1) {
                        const item = recordBytes(snapshot, vm_constant_items, item_start + item_index);
                        if (readU32(item, 0) >= constant_count or readU32(item, 4) != no_id)
                            return Error.InvalidVmConstant;
                    }
                },
                else => return Error.InvalidVmConstant,
            }
        }
    }

    try validateExactPartitions(snapshot, protos, 36, code.count, Error.InvalidProto);
    try validateExactPartitions(snapshot, protos, 44, vm_constants.count, Error.InvalidProto);
    try validateExactPartitions(snapshot, protos, 52, children.count, Error.InvalidProtoGraph);
    try validateExactPartitions(snapshot, protos, 60, upvalue_names.count, Error.InvalidProto);
    try validateExactPartitions(snapshot, protos, 68, locals.count, Error.InvalidProto);
    try validateExactPartitions(snapshot, protos, 76, typeinfo.count, Error.InvalidProto);
    try validateExactPartitions(snapshot, protos, 84, lineinfo.count, Error.InvalidProto);
    try validateExactPartitions(snapshot, protos, 92, abslineinfo.count, Error.InvalidProto);
    try validateExactPartitions(snapshot, protos, 100, debug_opcodes.count, Error.InvalidProto);
    try validateExactPartitions(snapshot, protos, 108, feedback.count, Error.InvalidProto);

    index = 0;
    while (index < protos.count) : (index += 1) {
        if (index == snapshot.header.root_proto_id)
            continue;
        var references: u32 = 0;
        var parent_index: u32 = 0;
        while (parent_index < protos.count) : (parent_index += 1) {
            const parent = recordBytes(snapshot, protos, parent_index);
            const child_start = readU32(parent, 52);
            const child_count = readU32(parent, 56);
            var child_index: u32 = 0;
            while (child_index < child_count) : (child_index += 1) {
                if (readU32(recordBytes(snapshot, children, child_start + child_index), 0) == index)
                    references += 1;
            }
        }
        if (references != 1)
            return Error.InvalidProtoGraph;
    }

    index = 0;
    while (index < ir_functions.count) : (index += 1) {
        const function = recordBytes(snapshot, ir_functions, index);
        if (readU32(function, 0) != index or readU32(function, 4) != index or function[12] > 1 or !allZero(function[13..16]) or !allZero(function[56..64]))
            return Error.InvalidIrFunction;
        const proto = recordBytes(snapshot, protos, index);
        if (function[12] != proto[31])
            return Error.InvalidIrFunction;

        try validateSpan(function, 16, ir_blocks.count, Error.InvalidIrFunction);
        try validateSpan(function, 24, ir_instructions.count, Error.InvalidIrFunction);
        try validateSpan(function, 32, ir_operands.count, Error.InvalidIrFunction);
        try validateSpan(function, 40, ir_constants.count, Error.InvalidIrFunction);
        try validateSpan(function, 48, bc_mapping.count, Error.InvalidIrFunction);

        const block_start = readU32(function, 16);
        const block_count = readU32(function, 20);
        const instruction_start = readU32(function, 24);
        const instruction_count = readU32(function, 28);
        const operand_start = readU32(function, 32);
        const operand_count = readU32(function, 36);
        const ir_constant_start = readU32(function, 40);
        const ir_constant_count = readU32(function, 44);
        if (block_count == 0 or instruction_count == 0 or readU32(function, 8) >= block_count)
            return Error.InvalidIrFunction;

        var block_index: u32 = 0;
        while (block_index < block_count) : (block_index += 1) {
            const block = recordBytes(snapshot, ir_blocks, block_start + block_index);
            if (block[0] > 5 or block[1] & ~@as(u8, 7) != 0 or !allZero(block[28..32]))
                return Error.InvalidIrBlock;
            const start = readU32(block, 4);
            const finish = readU32(block, 8);
            if ((start == no_id) != (finish == no_id))
                return Error.InvalidIrBlock;
            if (start != no_id and (start > finish or finish >= instruction_count))
                return Error.InvalidIrBlock;
            try validateOptionalId(readU32(block, 20), block_count, Error.InvalidIrBlock);
            try validateOptionalId(readU32(block, 24), readU32(proto, 40), Error.InvalidIrBlock);
        }

        var instruction_index: u32 = 0;
        while (instruction_index < instruction_count) : (instruction_index += 1) {
            const instruction = recordBytes(snapshot, ir_instructions, instruction_start + instruction_index);
            if (instruction[0] > 215 or instruction[1] != 0 or readU32(instruction, 4) != no_id or !allZero(instruction[16..24]))
                return Error.InvalidIrInstruction;
            const first_operand = readU32(instruction, 8);
            const instruction_operand_count = readU32(instruction, 12);
            if (!spanWithin(first_operand, instruction_operand_count, operand_start, operand_count))
                return Error.InvalidIrInstruction;

            var operand_index: u32 = 0;
            while (operand_index < instruction_operand_count) : (operand_index += 1) {
                const operand = recordBytes(snapshot, ir_operands, first_operand + operand_index);
                if (!allZero(operand[1..4]))
                    return Error.InvalidIrOperand;
                const operand_kind = operand[0];
                const operand_value = readU32(operand, 4);
                switch (operand_kind) {
                    0, 1 => if (operand_value != 0) return Error.InvalidIrOperand,
                    2 => if (operand_value >= ir_constant_count) return Error.InvalidIrOperand,
                    3 => if (operand_value >= 14) return Error.InvalidIrOperand,
                    4 => if (operand_value >= instruction_index) return Error.InvalidIrOperand,
                    5 => if (operand_value >= block_count) return Error.InvalidIrOperand,
                    6 => {
                        // Luau represents `return` with zero results as RETURN R0, 0 even when the
                        // Proto has maxstacksize=0. R0 is a non-dereferenced placeholder in that
                        // exact position; lowering still rejects every result-bearing out-of-frame
                        // source.
                        const zero_result_return_source = proto[32] == 0 and
                            instruction[0] == @intFromEnum(IrCommand.return_) and
                            operand_index == 0 and operand_value == 0;
                        if (!zero_result_return_source and operand_value >= proto[32])
                            return Error.InvalidIrOperand;
                    },
                    7 => if (operand_value >= readU32(proto, 48)) return Error.InvalidIrOperand,
                    8 => {
                        // GET_CLOSURE_UPVAL_ADDR addresses the newly allocated child closure, so
                        // its slot is bounded by that child's metadata during lowering rather than
                        // by the current Proto's own upvalue count. Every other VM_UPVALUE operand
                        // remains a reference into the current closure and is validated here.
                        const child_closure_slot = instruction[0] == @intFromEnum(IrCommand.get_closure_upval_addr) and
                            operand_index == 1;
                        if (!child_closure_slot and operand_value >= proto[29])
                            return Error.InvalidIrOperand;
                    },
                    9 => if (operand_value != 0x0fff_ffff and operand_value >= readU32(proto, 40)) return Error.InvalidIrOperand,
                    else => return Error.InvalidIrOperand,
                }
            }
        }

        var constant_index: u32 = 0;
        while (constant_index < ir_constant_count) : (constant_index += 1) {
            const constant = recordBytes(snapshot, ir_constants, ir_constant_start + constant_index);
            if (constant[0] > 5 or !allZero(constant[1..8]))
                return Error.InvalidIrConstant;
            const bits = readU64(constant, 8);
            switch (constant[0]) {
                0 => {
                    const low: u32 = @truncate(bits);
                    const canonical: u64 = @bitCast(@as(i64, @as(i32, @bitCast(low))));
                    if (bits != canonical) return Error.InvalidIrConstant;
                },
                2, 5 => if (bits >> 32 != 0) return Error.InvalidIrConstant,
                4 => if (bits >> 8 != 0) return Error.InvalidIrConstant,
                else => {},
            }
        }

        const mapping_start = readU32(function, 48);
        const mapping_count = readU32(function, 52);
        if (mapping_count != readU32(proto, 40))
            return Error.InvalidBytecodeMapping;
        var mapping_index: u32 = 0;
        while (mapping_index < mapping_count) : (mapping_index += 1) {
            const entry = recordBytes(snapshot, bc_mapping, mapping_start + mapping_index);
            try validateOptionalId(readU32(entry, 0), instruction_count, Error.InvalidBytecodeMapping);
            if (readU32(entry, 4) != no_id)
                return Error.InvalidBytecodeMapping;
        }
    }

    try validateExactPartitions(snapshot, ir_functions, 16, ir_blocks.count, Error.InvalidIrFunction);
    try validateExactPartitions(snapshot, ir_functions, 24, ir_instructions.count, Error.InvalidIrFunction);
    try validateExactPartitions(snapshot, ir_functions, 32, ir_operands.count, Error.InvalidIrFunction);
    try validateExactPartitions(snapshot, ir_functions, 40, ir_constants.count, Error.InvalidIrFunction);
    try validateExactPartitions(snapshot, ir_functions, 48, bc_mapping.count, Error.InvalidIrFunction);
}

fn recordBytes(snapshot: Snapshot, descriptor: Section, index: u32) []const u8 {
    std.debug.assert(index < descriptor.count);
    const start: usize = @intCast(descriptor.offset + @as(u64, index) * descriptor.record_size);
    return snapshot.bytes[start .. start + descriptor.record_size];
}

fn spanFits(start: u64, count: u32, total: u32) bool {
    return start <= total and @as(u64, count) <= @as(u64, total) - start;
}

fn spanWithin(start: u32, count: u32, outer_start: u32, outer_count: u32) bool {
    if (start < outer_start)
        return false;
    return spanFits(start - outer_start, count, outer_count);
}

fn validateSpan(record: []const u8, offset: usize, total: u32, failure: Error) Error!void {
    if (!spanFits(readU32(record, offset), readU32(record, offset + 4), total))
        return failure;
}

fn validateOptionalId(id: u32, count: u32, failure: Error) Error!void {
    if (id != no_id and id >= count)
        return failure;
}

fn validateExactPartitions(snapshot: Snapshot, records: Section, range_offset: usize, total: u32, failure: Error) Error!void {
    var cursor: u64 = 0;
    var index: u32 = 0;
    while (index < records.count) : (index += 1) {
        const item = recordBytes(snapshot, records, index);
        const start = readU32(item, range_offset);
        const count = readU32(item, range_offset + 4);
        if (start != cursor or !spanFits(start, count, total))
            return failure;
        cursor += count;
    }
    if (cursor != total)
        return failure;
}

fn readSection(bytes: []const u8, index: u32) Error!Section {
    const start = header_size + @as(usize, index) * section_size;
    if (start + section_size > bytes.len)
        return Error.Truncated;
    if (readU32(bytes, start + 28) != 0)
        return Error.ReservedNotZero;
    const raw_kind = readU16(bytes, start);
    if (raw_kind < @intFromEnum(SectionKind.strings) or raw_kind > @intFromEnum(SectionKind.compiled_bytecode))
        return Error.UnknownSection;
    const kind: SectionKind = @enumFromInt(raw_kind);
    return .{
        .kind = kind,
        .flags = readU16(bytes, start + 2),
        .record_size = readU32(bytes, start + 4),
        .offset = readU64(bytes, start + 8),
        .length = readU64(bytes, start + 16),
        .count = readU32(bytes, start + 24),
    };
}

fn checkIdentity(expected: ?[32]u8, actual: [32]u8, mismatch: Error) Error!void {
    if (expected) |value| {
        if (!std.mem.eql(u8, &value, &actual))
            return mismatch;
    }
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0)
            return false;
    }
    return true;
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn readU64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn writeU64(bytes: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[offset..][0..8], value, .little);
}

fn makeMinimal(bytes: []u8) void {
    @memset(bytes, 0);
    @memcpy(bytes[0..8], &magic);
    writeU16(bytes, 8, schema_version);
    writeU16(bytes, 10, header_size);
    writeU32(bytes, 12, required_flags);
    writeU64(bytes, 16, bytes.len);
    writeU32(bytes, 184, 1);
    writeU32(bytes, 188, 1);
    writeU32(bytes, 192, 1);
    writeU32(bytes, 196, 0);
    writeU32(bytes, 200, 0);
    writeU32(bytes, 204, 0);
}

test "accepts canonical minimal container" {
    var bytes: [header_size]u8 = undefined;
    makeMinimal(&bytes);
    const snapshot = try parse(&bytes, .{});
    try std.testing.expectEqual(@as(u32, 1), snapshot.header.proto_count);
}

test "rejects noncanonical section gap and identity mismatch" {
    var bytes: [header_size + section_size + 4]u8 = undefined;
    makeMinimal(&bytes);
    writeU32(&bytes, 204, 1);
    writeU16(&bytes, header_size, @intFromEnum(SectionKind.proto_children));
    writeU32(&bytes, header_size + 4, 4);
    writeU64(&bytes, header_size + 8, header_size + section_size + 1);
    writeU64(&bytes, header_size + 16, 4);
    writeU32(&bytes, header_size + 24, 1);
    try std.testing.expectError(Error.NonCanonicalSectionOffset, parse(&bytes, .{}));

    var clean: [header_size]u8 = undefined;
    makeMinimal(&clean);
    var wrong_pin = [_]u8{0} ** 32;
    wrong_pin[0] = 1;
    try std.testing.expectError(Error.PinMismatch, parse(&clean, .{ .luau_pin = wrong_pin }));
}
