const std = @import("std");
const trap = @import("trap");
const abi = @import("luau_aot_runtime_abi");

comptime {
    _ = trap;
}

extern fn __wasm_call_ctors() void;
extern fn luaL_newstate() ?*abi.State;
extern fn lua_close(state: ?*abi.State) void;
extern fn lua_pushlstring(state: ?*abi.State, string: [*]const u8, length: usize) void;
extern fn lua_call(state: ?*abi.State, argument_count: c_int, result_count: c_int) void;
extern fn lua_tonumberx(state: ?*abi.State, index: c_int, is_number: *c_int) f64;
extern fn mc_luau_aot_v1_generated_ir_function(state: ?*abi.State, proto: *const abi.AotProto) callconv(.c) u32;

const metadata = abi.AotProto{
    .abi_version = abi.abi_version,
    .struct_size = abi.proto_size,
    .layout_sha256 = abi.layout_sha256,
    .entry = &mc_luau_aot_v1_generated_ir_function,
    .function_id = 1,
    .flags = abi.flag_root,
};

const source = "=aot-upstream-ir-slow-add-oracle";
var initialized = false;

export fn mc_luau_aot_v1_slow_arith_oracle_init() void {
    if (initialized)
        return;
    initialized = true;
    __wasm_call_ctors();
}

// Decimal strings force both upstream CHECK_TAG guards into the compiled DO_ARITH fallback. A
// successful numeric result therefore proves the strict helper ran and rejoined compiled code.
export fn mc_luau_aot_v1_slow_arith_oracle_run(lhs: i32, rhs: i32) i32 {
    const state = luaL_newstate() orelse return std.math.minInt(i32);
    defer lua_close(state);

    if (abi.mc_luau_aot_v1_push_root(state, &metadata, source.ptr, source.len, 2, 3) != 0)
        return std.math.minInt(i32);

    var lhs_buffer: [32]u8 = undefined;
    var rhs_buffer: [32]u8 = undefined;
    const lhs_string = std.fmt.bufPrint(&lhs_buffer, "{d}", .{lhs}) catch return std.math.minInt(i32);
    const rhs_string = std.fmt.bufPrint(&rhs_buffer, "{d}", .{rhs}) catch return std.math.minInt(i32);
    lua_pushlstring(state, lhs_string.ptr, lhs_string.len);
    lua_pushlstring(state, rhs_string.ptr, rhs_string.len);
    lua_call(state, 2, 1);

    var is_number: c_int = 0;
    const result = lua_tonumberx(state, -1, &is_number);
    if (is_number == 0 or result < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        result > @as(f64, @floatFromInt(std.math.maxInt(i32))))
        return std.math.minInt(i32);
    return @intFromFloat(result);
}
