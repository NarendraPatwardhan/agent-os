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
