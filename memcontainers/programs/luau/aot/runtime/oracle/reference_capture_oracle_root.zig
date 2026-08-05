const std = @import("std");
const trap = @import("trap");
const abi = @import("luau_aot_runtime_abi");
const reference_capture = @import("luau_aot_reference_capture_program");

comptime {
    _ = trap;
}

extern fn __wasm_call_ctors() void;
extern fn luaL_newstate() ?*abi.State;
extern fn lua_close(state: ?*abi.State) void;
extern fn lua_gc(state: ?*abi.State, operation: c_int, argument: c_int) c_int;
extern fn lua_pushlstring(state: ?*abi.State, string: [*]const u8, length: usize) void;
extern fn lua_pushvalue(state: ?*abi.State, index: c_int) void;
extern fn lua_settop(state: ?*abi.State, index: c_int) void;
extern fn lua_call(state: ?*abi.State, argument_count: c_int, result_count: c_int) void;
extern fn lua_tonumberx(state: ?*abi.State, index: c_int, is_number: *c_int) f64;

const lua_gc_collect: c_int = 2;
var initialized = false;

export fn mc_luau_aot_v1_reference_capture_oracle_init() void {
    if (initialized)
        return;
    initialized = true;
    __wasm_call_ctors();
}

fn pushDecimal(state: ?*abi.State, value: i32, buffer: *[32]u8) bool {
    const string = std.fmt.bufPrint(buffer, "{d}", .{value}) catch return false;
    lua_pushlstring(state, string.ptr, string.len);
    return true;
}

// Keep the accumulator rooted below each call result. The collection after the factory returns is
// the critical boundary: its captured stack slot is gone, so only a correctly closed UpVal can keep
// the initial decimal string alive and preserve mutation across both slow-path arithmetic calls.
export fn mc_luau_aot_v1_reference_capture_oracle_run(initial: i32, delta1: i32, delta2: i32) i32 {
    const state = luaL_newstate() orelse return std.math.minInt(i32);
    defer lua_close(state);

    if (abi.mc_luau_aot_v1_push_program(
        state,
        &reference_capture.program,
        reference_capture.source_name.ptr,
        reference_capture.source_name.len,
    ) != 0)
        return std.math.minInt(i32);

    lua_call(state, 0, 1); // root -> factory
    var initial_buffer: [32]u8 = undefined;
    if (!pushDecimal(state, initial, &initial_buffer))
        return std.math.minInt(i32);
    lua_call(state, 1, 1); // factory(initial string) -> accumulator

    _ = lua_gc(state, lua_gc_collect, 0);

    lua_pushvalue(state, -1); // retain one accumulator below the called copy
    var delta1_buffer: [32]u8 = undefined;
    if (!pushDecimal(state, delta1, &delta1_buffer))
        return std.math.minInt(i32);
    lua_call(state, 1, 1);
    lua_settop(state, -2); // discard result, retain accumulator with its mutated closed UpVal

    lua_pushvalue(state, -1);
    var delta2_buffer: [32]u8 = undefined;
    if (!pushDecimal(state, delta2, &delta2_buffer))
        return std.math.minInt(i32);
    lua_call(state, 1, 1);

    var is_number: c_int = 0;
    const result = lua_tonumberx(state, -1, &is_number);
    if (is_number == 0 or !std.math.isFinite(result) or result != @trunc(result) or
        result < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        result > @as(f64, @floatFromInt(std.math.maxInt(i32))))
        return std.math.minInt(i32);
    return @intFromFloat(result);
}
