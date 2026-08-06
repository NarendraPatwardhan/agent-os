//! Production AgentOS entry for the first closed two-module strict-AOT package.
//!
//! The entry root returns a main closure. It is invoked twice in one state with full collection
//! between calls, proving that both require sites and both calls share one cached module result.

const std = @import("std");
const abi = @import("luau_aot_runtime_abi");
const static_import = @import("luau_aot_static_import_program");
const mc = @import("mc");
const trap = @import("trap");
const wasi_shim = @import("wasi_shim");

comptime {
    _ = trap;
    _ = wasi_shim;
}

extern fn luaL_newstate() ?*abi.State;
extern fn lua_close(state: ?*abi.State) void;
extern fn lua_gc(state: ?*abi.State, operation: c_int, argument: c_int) c_int;
extern fn lua_pushlstring(state: ?*abi.State, string: [*]const u8, length: usize) void;
extern fn lua_pushvalue(state: ?*abi.State, index: c_int) void;
extern fn lua_settop(state: ?*abi.State, index: c_int) void;
extern fn lua_pcall(state: ?*abi.State, argument_count: c_int, result_count: c_int, error_function: c_int) c_int;
extern fn lua_tonumberx(state: ?*abi.State, index: c_int, is_number: *c_int) f64;

const lua_gc_collect: c_int = 2;

fn writeAll(fd: i32, bytes: []const u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var written: u32 = 0;
        if (mc.mc_sys_write(fd, mc.addr(bytes.ptr + offset), @intCast(bytes.len - offset), mc.addr(&written)) != 0 or written == 0)
            return false;
        offset += written;
    }
    return true;
}

fn fail(message: []const u8, status: c_int) c_int {
    _ = writeAll(2, message);
    return status;
}

fn resultInteger(state: ?*abi.State) ?i32 {
    var is_number: c_int = 0;
    const result = lua_tonumberx(state, -1, &is_number);
    if (is_number == 0 or !std.math.isFinite(result) or result != @trunc(result) or
        result < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        result > @as(f64, @floatFromInt(std.math.maxInt(i32))))
        return null;
    return @intFromFloat(result);
}

pub export fn __main_argc_argv(argc: c_int, argv_pointer: [*][*:0]u8) c_int {
    if (argc != 5)
        return fail("usage: luau-aot-static-import A B C D\n", 2);

    const state = luaL_newstate() orelse return fail("luau-aot-static-import: state allocation failed\n", 1);
    defer lua_close(state);
    if (abi.mc_luau_aot_v1_push_program(
        state,
        &static_import.program,
        static_import.source_name.ptr,
        static_import.source_name.len,
    ) != 0)
        return fail("luau-aot-static-import: program publication failed\n", 1);

    _ = lua_gc(state, lua_gc_collect, 0);
    if (lua_pcall(state, 0, 1, 0) != 0)
        return fail("luau-aot-static-import: entry root execution failed\n", 1);
    _ = lua_gc(state, lua_gc_collect, 0);

    lua_pushvalue(state, -1);
    const first_argument = std.mem.span(argv_pointer[1]);
    const second_argument = std.mem.span(argv_pointer[2]);
    lua_pushlstring(state, first_argument.ptr, first_argument.len);
    lua_pushlstring(state, second_argument.ptr, second_argument.len);
    if (lua_pcall(state, 2, 1, 0) != 0)
        return fail("luau-aot-static-import: first entry execution failed\n", 1);
    const first = resultInteger(state) orelse
        return fail("luau-aot-static-import: first result is not an integer\n", 1);
    lua_settop(state, -2); // discard the result while retaining the entry closure

    // The module result is reachable only through the runtime registry across this collection.
    _ = lua_gc(state, lua_gc_collect, 0);

    lua_pushvalue(state, -1);
    const third_argument = std.mem.span(argv_pointer[3]);
    const fourth_argument = std.mem.span(argv_pointer[4]);
    lua_pushlstring(state, third_argument.ptr, third_argument.len);
    lua_pushlstring(state, fourth_argument.ptr, fourth_argument.len);
    if (lua_pcall(state, 2, 1, 0) != 0)
        return fail("luau-aot-static-import: second entry execution failed\n", 1);
    const second = resultInteger(state) orelse
        return fail("luau-aot-static-import: second result is not an integer\n", 1);

    var buffer: [64]u8 = undefined;
    const output = std.fmt.bufPrint(&buffer, "{d}\n{d}\n", .{ first, second }) catch
        return fail("luau-aot-static-import: result formatting failed\n", 1);
    return if (writeAll(1, output)) 0 else 1;
}
