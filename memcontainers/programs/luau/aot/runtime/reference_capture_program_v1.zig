//! Link-time descriptor for the first mutable reference-capture strict-AOT program.
//!
//! The factory returns a closure over one open UpVal. Generated CLOSE_UPVALS closes that cell before
//! the factory frame disappears; the returned accumulator then reads and mutates the same closed cell.

const abi = @import("luau_aot_runtime_abi");

extern fn mc_luau_aot_v1_function_00000000(state: ?*abi.State, proto: *const abi.AotProto) callconv(.c) u32;
extern fn mc_luau_aot_v1_function_00000001(state: ?*abi.State, proto: *const abi.AotProto) callconv(.c) u32;
extern fn mc_luau_aot_v1_function_00000002(state: ?*abi.State, proto: *const abi.AotProto) callconv(.c) u32;

pub const protos = [_]abi.AotProto{
    .{
        .abi_version = abi.abi_version,
        .struct_size = abi.proto_size,
        .layout_sha256 = abi.layout_sha256,
        .entry = &mc_luau_aot_v1_function_00000000,
        .function_id = 0,
        .parent_id = abi.no_id,
        .flags = abi.flag_root,
        .num_params = 0,
        .nups = 0,
        .is_vararg = 1,
        .max_stack_size = 1,
        .reserved = 0,
    },
    .{
        .abi_version = abi.abi_version,
        .struct_size = abi.proto_size,
        .layout_sha256 = abi.layout_sha256,
        .entry = &mc_luau_aot_v1_function_00000001,
        .function_id = 1,
        .parent_id = 0,
        .flags = 0,
        .num_params = 1,
        .nups = 0,
        .is_vararg = 0,
        .max_stack_size = 3,
        .reserved = 0,
    },
    .{
        .abi_version = abi.abi_version,
        .struct_size = abi.proto_size,
        .layout_sha256 = abi.layout_sha256,
        .entry = &mc_luau_aot_v1_function_00000002,
        .function_id = 2,
        .parent_id = 1,
        .flags = 0,
        .num_params = 1,
        .nups = 1,
        .is_vararg = 0,
        .max_stack_size = 2,
        .reserved = 0,
    },
};

pub const program = abi.AotProgram{
    .abi_version = abi.abi_version,
    .struct_size = abi.program_size,
    .layout_sha256 = abi.layout_sha256,
    .protos = &protos,
    .proto_count = protos.len,
    .root_proto_id = 0,
    .flags = 0,
};

pub const source_name = "=aot/reference_capture.luau";
