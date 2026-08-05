//! Generated-code-to-runtime ABI shared by strict runtime executables.
//!
//! Keep this binding small and pin-sized. C++ owns the implementation and the canonical C header;
//! Zig entrypoints use this module instead of cloning offsets, status values, or the layout digest.

const std = @import("std");

pub const State = opaque {};

pub const AotProto = extern struct {
    abi_version: u32,
    struct_size: u32,
    layout_sha256: [32]u8,
    entry: *const fn (?*State, *const AotProto) callconv(.c) u32,
    function_id: u32,
    parent_id: u32,
    flags: u32,
    num_params: u8,
    nups: u8,
    is_vararg: u8,
    max_stack_size: u8,
    reserved: u32,
};

pub const AotProgram = extern struct {
    abi_version: u32,
    struct_size: u32,
    layout_sha256: [32]u8,
    protos: [*]const AotProto,
    proto_count: u32,
    root_proto_id: u32,
    flags: u32,
};

comptime {
    if (@sizeOf(AotProto) != 64 or @offsetOf(AotProto, "entry") != 40 or @offsetOf(AotProto, "num_params") != 56)
        @compileError("McLuauAotProtoV1 Zig layout drift");
    if (@sizeOf(AotProgram) != 56 or @offsetOf(AotProgram, "protos") != 40)
        @compileError("McLuauAotProgramV1 Zig layout drift");
}

pub const abi_version: u32 = 1;
pub const proto_size: u32 = 64;
pub const program_size: u32 = 56;
pub const no_id: u32 = std.math.maxInt(u32);
pub const flag_root: u32 = 1;
pub const multret: i32 = -1;

pub const layout_sha256 = [_]u8{
    0x42, 0x5d, 0x38, 0xd7, 0x5e, 0xf9, 0xf4, 0xe2, 0x66, 0x93, 0xa6, 0x90, 0xe0, 0x85, 0x7f, 0x90,
    0x2a, 0xa7, 0x6f, 0x1c, 0x18, 0x56, 0x19, 0x6a, 0xc3, 0x0d, 0xc6, 0x23, 0x6e, 0xa4, 0xc4, 0x96,
};

pub extern fn mc_luau_aot_v1_push_root(
    state: ?*State,
    metadata: *const AotProto,
    source: [*]const u8,
    source_size: usize,
) u32;

pub extern fn mc_luau_aot_v1_push_program(
    state: ?*State,
    program: *const AotProgram,
    source: [*]const u8,
    source_size: usize,
) u32;
