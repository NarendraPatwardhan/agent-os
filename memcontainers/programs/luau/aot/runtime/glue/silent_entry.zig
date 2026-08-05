//! Kernel negative-control entry for a source-built `return 30` root.
//!
//! The returned value is deliberately discarded by the protected root call. Any stdout from this
//! artifact is therefore a compiler/runtime semantic failure, not wrapper-authored behavior.

const abi = @import("luau_aot_runtime_abi");
const trap = @import("trap");
const wasi_shim = @import("wasi_shim");

comptime {
    _ = trap;
    _ = wasi_shim;
}

extern fn luaL_newstate() ?*abi.State;
extern fn lua_close(state: ?*abi.State) void;
extern fn lua_pcall(state: ?*abi.State, argument_count: c_int, result_count: c_int, error_function: c_int) c_int;
extern fn mc_luau_aot_v1_generated_ir_function(state: ?*abi.State, proto: *const abi.AotProto) callconv(.c) u32;

const metadata = abi.AotProto{
    .abi_version = abi.abi_version,
    .struct_size = abi.proto_size,
    .layout_sha256 = abi.layout_sha256,
    .entry = &mc_luau_aot_v1_generated_ir_function,
    .function_id = 0,
    .parent_id = abi.no_id,
    .flags = abi.flag_root,
    .num_params = 0,
    .nups = 0,
    .is_vararg = 1,
    .max_stack_size = 1,
    .reserved = 0,
};

const source_name = "=aot/silent_return.luau";

pub export fn __main_argc_argv(argc: c_int, _: [*][*:0]u8) c_int {
    if (argc != 1)
        return 2;

    const state = luaL_newstate() orelse return 1;
    defer lua_close(state);
    if (abi.mc_luau_aot_v1_push_root(state, &metadata, source_name.ptr, source_name.len) != 0)
        return 1;

    return if (lua_pcall(state, 0, 0, 0) == 0) 0 else 1;
}
