const std = @import("std");
const trap = @import("trap");

comptime {
    _ = trap;
}

const State = opaque {};

extern fn __wasm_call_ctors() void;
extern fn luaL_newstate() ?*State;
extern fn lua_close(state: ?*State) void;
extern fn lua_pushnumber(state: ?*State, value: f64) void;
extern fn lua_pushlstring(state: ?*State, string: [*]const u8, length: usize) void;
extern fn lua_pushvalue(state: ?*State, index: c_int) void;
extern fn lua_settop(state: ?*State, index: c_int) void;
extern fn lua_call(state: ?*State, argument_count: c_int, result_count: c_int) void;
extern fn lua_tonumberx(state: ?*State, index: c_int, is_number: *c_int) f64;
extern fn luau_compile(source: [*]const u8, size: usize, options: ?*anyopaque, out_size: *usize) [*c]u8;
extern fn luau_load(state: ?*State, chunk_name: [*:0]const u8, bytecode: [*c]const u8, size: usize, environment: c_int) c_int;
extern fn free(pointer: ?*anyopaque) void;

var initialized = false;
const max_source_size = 64 * 1024;
var source_buffer: [max_source_size]u8 = undefined;

export fn mc_luau_interpreter_oracle_init() void {
    if (initialized)
        return;
    initialized = true;
    __wasm_call_ctors();
}

export fn mc_luau_interpreter_oracle_source_buffer() u32 {
    return @intCast(@intFromPtr(&source_buffer));
}

// Test-only differential oracle built from the exact pinned interpreter/compiler source family.
// It is a separate artifact and can never enter the strict target-runtime link graph.
export fn mc_luau_interpreter_oracle_run_i32(source_size: u32, input: i32) i32 {
    if (source_size == 0 or source_size > source_buffer.len)
        return std.math.minInt(i32);

    const state = luaL_newstate() orelse return std.math.minInt(i32);
    defer lua_close(state);

    var bytecode_size: usize = 0;
    const source = source_buffer[0..source_size];
    const bytecode = luau_compile(source.ptr, source.len, null, &bytecode_size);
    if (bytecode == null)
        return std.math.minInt(i32);
    defer free(bytecode);
    if (luau_load(state, "=aot-differential", bytecode, bytecode_size, 0) != 0)
        return std.math.minInt(i32);

    lua_call(state, 0, 1); // Source chunk returns the loop closure.
    lua_pushnumber(state, @floatFromInt(input));
    lua_call(state, 1, 1);

    var is_number: c_int = 0;
    const result = lua_tonumberx(state, -1, &is_number);
    if (is_number == 0 or result < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        result > @as(f64, @floatFromInt(std.math.maxInt(i32))))
        return std.math.minInt(i32);
    return @intFromFloat(result);
}

// Exercise the exact source's generic arithmetic path with string operands. This remains in the
// separately linked pinned-interpreter oracle and is never a dependency of the strict AOT runtime.
export fn mc_luau_interpreter_oracle_run_add_strings(source_size: u32, lhs: i32, rhs: i32) i32 {
    if (source_size == 0 or source_size > source_buffer.len)
        return std.math.minInt(i32);

    const state = luaL_newstate() orelse return std.math.minInt(i32);
    defer lua_close(state);

    var bytecode_size: usize = 0;
    const source = source_buffer[0..source_size];
    const bytecode = luau_compile(source.ptr, source.len, null, &bytecode_size);
    if (bytecode == null)
        return std.math.minInt(i32);
    defer free(bytecode);
    if (luau_load(state, "=aot-slow-arithmetic-differential", bytecode, bytecode_size, 0) != 0)
        return std.math.minInt(i32);

    lua_call(state, 0, 1);
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

// Execute the exact mutable-reference-capture source shape: root -> factory(initial) -> accumulator,
// then invoke the same returned accumulator twice. All three operands are decimal strings so both
// mutations traverse Luau's generic arithmetic semantics rather than only the numeric fast path.
export fn mc_luau_interpreter_oracle_run_reference_capture_strings(
    source_size: u32,
    initial: i32,
    first_delta: i32,
    second_delta: i32,
) i32 {
    if (source_size == 0 or source_size > source_buffer.len)
        return std.math.minInt(i32);

    const state = luaL_newstate() orelse return std.math.minInt(i32);
    defer lua_close(state);

    var bytecode_size: usize = 0;
    const source = source_buffer[0..source_size];
    const bytecode = luau_compile(source.ptr, source.len, null, &bytecode_size);
    if (bytecode == null)
        return std.math.minInt(i32);
    defer free(bytecode);
    if (luau_load(state, "=aot-reference-capture-differential", bytecode, bytecode_size, 0) != 0)
        return std.math.minInt(i32);

    lua_call(state, 0, 1);
    var initial_buffer: [32]u8 = undefined;
    const initial_string = std.fmt.bufPrint(&initial_buffer, "{d}", .{initial}) catch return std.math.minInt(i32);
    lua_pushlstring(state, initial_string.ptr, initial_string.len);
    lua_call(state, 1, 1);

    lua_pushvalue(state, -1);
    var first_buffer: [32]u8 = undefined;
    const first_string = std.fmt.bufPrint(&first_buffer, "{d}", .{first_delta}) catch return std.math.minInt(i32);
    lua_pushlstring(state, first_string.ptr, first_string.len);
    lua_call(state, 1, 1);
    lua_settop(state, -2);

    lua_pushvalue(state, -1);
    var second_buffer: [32]u8 = undefined;
    const second_string = std.fmt.bufPrint(&second_buffer, "{d}", .{second_delta}) catch return std.math.minInt(i32);
    lua_pushlstring(state, second_string.ptr, second_string.len);
    lua_call(state, 1, 1);

    var is_number: c_int = 0;
    const result = lua_tonumberx(state, -1, &is_number);
    if (is_number == 0 or !std.math.isFinite(result) or result != @trunc(result) or
        result < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        result > @as(f64, @floatFromInt(std.math.maxInt(i32))))
        return std.math.minInt(i32);
    return @intFromFloat(result);
}
