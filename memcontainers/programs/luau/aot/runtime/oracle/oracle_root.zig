const std = @import("std");
const trap = @import("trap");
const abi = @import("luau_aot_runtime_abi");

comptime {
    _ = trap;
}

extern fn __wasm_call_ctors() void;
extern fn luaL_newstate() ?*abi.State;
extern fn lua_close(state: ?*abi.State) void;
extern fn lua_gc(state: ?*abi.State, operation: c_int, data: c_int) c_int;
extern fn lua_pushnil(state: ?*abi.State) void;
extern fn lua_pushnumber(state: ?*abi.State, value: f64) void;
extern fn lua_call(state: ?*abi.State, argument_count: c_int, result_count: c_int) void;
extern fn lua_pcall(state: ?*abi.State, argument_count: c_int, result_count: c_int, error_function: c_int) c_int;
extern fn lua_tonumberx(state: ?*abi.State, index: c_int, is_number: *c_int) f64;
extern fn mc_luau_aot_v1_generated_ir_function(state: ?*abi.State, proto: *const abi.AotProto) callconv(.c) u32;

const metadata = abi.AotProto{
    .abi_version = abi.abi_version,
    .struct_size = abi.proto_size,
    .layout_sha256 = abi.layout_sha256,
    .entry = &mc_luau_aot_v1_generated_ir_function,
    .function_id = 1,
    .parent_id = abi.no_id,
    .flags = abi.flag_root,
    .num_params = 1,
    .nups = 0,
    .is_vararg = 0,
    .max_stack_size = 5,
    .reserved = 0,
};

const source = "=aot-upstream-ir-loop-oracle";

var initialized = false;

export fn mc_luau_aot_v1_oracle_init() void {
    if (initialized)
        return;
    initialized = true;
    __wasm_call_ctors();
}

export fn mc_luau_aot_v1_oracle_run_i32(input: i32) i32 {
    const state = luaL_newstate() orelse return std.math.minInt(i32);
    defer lua_close(state);

    if (abi.mc_luau_aot_v1_push_root(state, &metadata, source.ptr, source.len) != 0)
        return std.math.minInt(i32);
    lua_pushnumber(state, @floatFromInt(input));
    lua_call(state, 1, 1);

    var is_number: c_int = 0;
    const result = lua_tonumberx(state, -1, &is_number);
    if (is_number == 0 or result < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        result > @as(f64, @floatFromInt(std.math.maxInt(i32))))
        return std.math.minInt(i32);
    return @intFromFloat(result);
}

export fn mc_luau_aot_v1_oracle_reject_non_number() i32 {
    const state = luaL_newstate() orelse return -1;
    defer lua_close(state);

    if (abi.mc_luau_aot_v1_push_root(state, &metadata, source.ptr, source.len) != 0)
        return -2;
    lua_pushnil(state);
    const status = lua_pcall(state, 1, 1, 0);
    return if (status == 0) -3 else status;
}

export fn mc_luau_aot_v1_oracle_gc_publication() i32 {
    const state = luaL_newstate() orelse return -1;
    defer lua_close(state);

    _ = lua_gc(state, 2, 0); // LUA_GCCOLLECT: paint the inactive thread before publication.
    if (abi.mc_luau_aot_v1_push_root(state, &metadata, source.ptr, source.len) != 0)
        return -2;
    _ = lua_gc(state, 2, 0); // The published Closure/Proto/source graph must remain reachable.

    lua_pushnumber(state, 4);
    lua_call(state, 1, 1);
    var is_number: c_int = 0;
    const result = lua_tonumberx(state, -1, &is_number);
    return if (is_number != 0 and result == 10) 0 else -3;
}

// Staged real-state probe retained by the oracle so a failure names the first broken ABI boundary
// instead of collapsing construction, closure materialization, call dispatch, and result access
// into one opaque WebAssembly trap.
export fn mc_luau_aot_v1_oracle_probe(stage: u32) i32 {
    const state = luaL_newstate() orelse return -1;
    defer lua_close(state);
    if (stage == 0)
        return 0;

    if (abi.mc_luau_aot_v1_push_root(state, &metadata, source.ptr, source.len) != 0)
        return -2;
    if (stage == 1)
        return 0;

    lua_pushnumber(state, 4);
    if (stage == 2)
        return 0;

    lua_call(state, 1, 1);
    if (stage == 3)
        return 0;

    var is_number: c_int = 0;
    const result = lua_tonumberx(state, -1, &is_number);
    if (stage == 4)
        return if (is_number != 0 and result == 10) 0 else -3;

    return 0;
}
