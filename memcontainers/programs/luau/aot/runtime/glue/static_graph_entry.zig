//! Production entry for the five-module transitive strict-AOT graph.
//!
//! One compiler-emitted program descriptor publishes the whole Proto forest. The returned entry
//! closure runs twice around full GC, so every transitive require and mutable module export must
//! retain one shared identity across call sites, paths, and collections.

const std = @import("std");
const abi = @import("luau_aot_runtime_abi");
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
extern const mc_luau_aot_v1_program: abi.AotProgram;

const lua_gc_collect: c_int = 2;
const source_name = "=aot/static_graph_package";

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

fn resultInteger(state: ?*abi.State, index: c_int) ?i32 {
    var is_number: c_int = 0;
    const result = lua_tonumberx(state, index, &is_number);
    if (is_number == 0 or !std.math.isFinite(result) or result != @trunc(result) or
        result < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        result > @as(f64, @floatFromInt(std.math.maxInt(i32))))
        return null;
    return @intFromFloat(result);
}

fn runFour(state: ?*abi.State, argv_pointer: [*][*:0]u8, first: usize) ?[4]i32 {
    lua_pushvalue(state, 1);
    for (first..first + 4) |index| {
        const argument = std.mem.span(argv_pointer[index]);
        lua_pushlstring(state, argument.ptr, argument.len);
    }
    if (lua_pcall(state, 4, 4, 0) != 0)
        return null;

    var results: [4]i32 = undefined;
    for (0..4) |index|
        results[index] = resultInteger(state, @as(c_int, @intCast(index)) - 4) orelse return null;
    lua_settop(state, 1);
    return results;
}

pub export fn __main_argc_argv(argc: c_int, argv_pointer: [*][*:0]u8) c_int {
    if (argc != 9)
        return fail("usage: luau-aot-static-graph A B C D E F G H\n", 2);

    const state = luaL_newstate() orelse return fail("luau-aot-static-graph: state allocation failed\n", 1);
    defer lua_close(state);
    if (abi.mc_luau_aot_v1_push_program(state, &mc_luau_aot_v1_program, source_name.ptr, source_name.len) != 0)
        return fail("luau-aot-static-graph: program publication failed\n", 1);

    _ = lua_gc(state, lua_gc_collect, 0);
    if (lua_pcall(state, 0, 1, 0) != 0)
        return fail("luau-aot-static-graph: entry root execution failed\n", 1);

    const first = runFour(state, argv_pointer, 1) orelse
        return fail("luau-aot-static-graph: first graph execution failed\n", 1);
    _ = lua_gc(state, lua_gc_collect, 0);
    const second = runFour(state, argv_pointer, 5) orelse
        return fail("luau-aot-static-graph: second graph execution failed\n", 1);

    var buffer: [192]u8 = undefined;
    const output = std.fmt.bufPrint(
        &buffer,
        "{d}\n{d}\n{d}\n{d}\n{d}\n{d}\n{d}\n{d}\n",
        .{ first[0], first[1], first[2], first[3], second[0], second[1], second[2], second[3] },
    ) catch return fail("luau-aot-static-graph: result formatting failed\n", 1);
    return if (writeAll(1, output)) 0 else 1;
}
