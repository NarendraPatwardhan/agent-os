const std = @import("std");
const trap = @import("trap");
const abi = @import("luau_aot_runtime_abi");
const captured_call = @import("luau_aot_captured_call_program");

comptime {
    _ = trap;
}

extern fn __wasm_call_ctors() void;
extern fn luaL_newstate() ?*abi.State;
extern fn lua_close(state: ?*abi.State) void;
extern fn lua_gc(state: ?*abi.State, operation: c_int, argument: c_int) c_int;
extern fn lua_pushlstring(state: ?*abi.State, string: [*]const u8, length: usize) void;
extern fn lua_call(state: ?*abi.State, argument_count: c_int, result_count: c_int) void;
extern fn lua_pcall(state: ?*abi.State, argument_count: c_int, result_count: c_int, error_function: c_int) c_int;
extern fn lua_tonumberx(state: ?*abi.State, index: c_int, is_number: *c_int) f64;

const lua_gc_collect: c_int = 2;
var initialized = false;

export fn mc_luau_aot_v1_captured_call_oracle_init() void {
    if (initialized)
        return;
    initialized = true;
    __wasm_call_ctors();
}

// The protected root call returns the compiled caller Closure. A full collection on either side
// proves that the published Proto graph and returned Closure remain rooted. Decimal strings then
// drive the captured child through its checked arithmetic slow path and nested CALL/RETURN.
export fn mc_luau_aot_v1_captured_call_oracle_run(lhs: i32, rhs: i32) i32 {
    const state = luaL_newstate() orelse return std.math.minInt(i32);
    defer lua_close(state);

    if (abi.mc_luau_aot_v1_push_program(
        state,
        &captured_call.program,
        captured_call.source_name.ptr,
        captured_call.source_name.len,
    ) != 0)
        return std.math.minInt(i32);
    _ = lua_gc(state, lua_gc_collect, 0);
    if (lua_pcall(state, 0, 1, 0) != 0)
        return std.math.minInt(i32);
    _ = lua_gc(state, lua_gc_collect, 0);

    var lhs_buffer: [32]u8 = undefined;
    var rhs_buffer: [32]u8 = undefined;
    const lhs_string = std.fmt.bufPrint(&lhs_buffer, "{d}", .{lhs}) catch return std.math.minInt(i32);
    const rhs_string = std.fmt.bufPrint(&rhs_buffer, "{d}", .{rhs}) catch return std.math.minInt(i32);
    lua_pushlstring(state, lhs_string.ptr, lhs_string.len);
    lua_pushlstring(state, rhs_string.ptr, rhs_string.len);
    lua_call(state, 2, 1);

    var is_number: c_int = 0;
    const result = lua_tonumberx(state, -1, &is_number);
    if (is_number == 0 or !std.math.isFinite(result) or result != @trunc(result) or
        result < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        result > @as(f64, @floatFromInt(std.math.maxInt(i32))))
        return std.math.minInt(i32);
    return @intFromFloat(result);
}
