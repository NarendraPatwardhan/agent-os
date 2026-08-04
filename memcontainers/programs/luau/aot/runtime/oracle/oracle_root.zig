const std = @import("std");
const trap = @import("trap");

comptime {
    _ = trap;
}

const State = opaque {};

const AotProtoV1 = extern struct {
    abi_version: u32,
    struct_size: u32,
    layout_sha256: [32]u8,
    entry: *const fn (?*State, *const AotProtoV1) callconv(.c) u32,
    function_id: u32,
    flags: u32,
};

comptime {
    if (@sizeOf(AotProtoV1) != 52 or @offsetOf(AotProtoV1, "entry") != 40)
        @compileError("McLuauAotProtoV1 Zig layout drift");
}

extern fn __wasm_call_ctors() void;
extern fn luaL_newstate() ?*State;
extern fn lua_close(state: ?*State) void;
extern fn lua_gc(state: ?*State, operation: c_int, data: c_int) c_int;
extern fn lua_pushnil(state: ?*State) void;
extern fn lua_pushnumber(state: ?*State, value: f64) void;
extern fn lua_call(state: ?*State, argument_count: c_int, result_count: c_int) void;
extern fn lua_pcall(state: ?*State, argument_count: c_int, result_count: c_int, error_function: c_int) c_int;
extern fn lua_tonumberx(state: ?*State, index: c_int, is_number: *c_int) f64;
extern fn mc_luau_aot_v1_push_root(
    state: ?*State,
    metadata: *const AotProtoV1,
    source: [*]const u8,
    source_size: usize,
    num_params: u8,
    max_stack_size: u8,
) u32;
extern fn mc_luau_aot_v1_generated_ir_function(state: ?*State, proto: *const AotProtoV1) callconv(.c) u32;

const layout_sha256 = [_]u8{
    0x42, 0x5d, 0x38, 0xd7, 0x5e, 0xf9, 0xf4, 0xe2, 0x66, 0x93, 0xa6, 0x90, 0xe0, 0x85, 0x7f, 0x90,
    0x2a, 0xa7, 0x6f, 0x1c, 0x18, 0x56, 0x19, 0x6a, 0xc3, 0x0d, 0xc6, 0x23, 0x6e, 0xa4, 0xc4, 0x96,
};

const metadata = AotProtoV1{
    .abi_version = 1,
    .struct_size = 52,
    .layout_sha256 = layout_sha256,
    .entry = &mc_luau_aot_v1_generated_ir_function,
    .function_id = 1,
    .flags = 1,
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

    if (mc_luau_aot_v1_push_root(state, &metadata, source.ptr, source.len, 1, 5) != 0)
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

    if (mc_luau_aot_v1_push_root(state, &metadata, source.ptr, source.len, 1, 5) != 0)
        return -2;
    lua_pushnil(state);
    const status = lua_pcall(state, 1, 1, 0);
    return if (status == 0) -3 else status;
}

export fn mc_luau_aot_v1_oracle_gc_publication() i32 {
    const state = luaL_newstate() orelse return -1;
    defer lua_close(state);

    _ = lua_gc(state, 2, 0); // LUA_GCCOLLECT: paint the inactive thread before publication.
    if (mc_luau_aot_v1_push_root(state, &metadata, source.ptr, source.len, 1, 5) != 0)
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

    if (mc_luau_aot_v1_push_root(state, &metadata, source.ptr, source.len, 1, 5) != 0)
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
