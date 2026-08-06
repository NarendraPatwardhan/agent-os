//! Production entry for explicit static-module cycle handling.
//!
//! The entry closure is called twice in one state. Each call reaches A -> B -> A and must fail
//! through the closed registry without source loading, bytecode dispatch, a trap, or stale state.

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
extern fn lua_pushvalue(state: ?*abi.State, index: c_int) void;
extern fn lua_settop(state: ?*abi.State, index: c_int) void;
extern fn lua_pcall(state: ?*abi.State, argument_count: c_int, result_count: c_int, error_function: c_int) c_int;
extern fn lua_tolstring(state: ?*abi.State, index: c_int, length: *usize) ?[*]const u8;
extern const mc_luau_aot_v1_program: abi.AotProgram;

const lua_gc_collect: c_int = 2;
const source_name = "=aot/static_cycle_package";

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

fn callMustFailWithCycle(state: ?*abi.State) bool {
    lua_pushvalue(state, 1);
    const failed = lua_pcall(state, 0, 0, 0) != 0;
    var length: usize = 0;
    const message = if (failed) lua_tolstring(state, -1, &length) else null;
    const is_cycle = if (message) |pointer|
        std.mem.indexOf(u8, pointer[0..length], "static require cycle") != null
    else
        false;
    lua_settop(state, 1);
    return is_cycle;
}

pub export fn __main_argc_argv(argc: c_int, _: [*][*:0]u8) c_int {
    if (argc != 1)
        return fail("usage: luau-aot-static-cycle\n", 2);

    const state = luaL_newstate() orelse return fail("luau-aot-static-cycle: state allocation failed\n", 1);
    defer lua_close(state);
    if (abi.mc_luau_aot_v1_push_program(state, &mc_luau_aot_v1_program, source_name.ptr, source_name.len) != 0)
        return fail("luau-aot-static-cycle: program publication failed\n", 1);

    _ = lua_gc(state, lua_gc_collect, 0);
    if (lua_pcall(state, 0, 1, 0) != 0)
        return fail("luau-aot-static-cycle: entry root execution failed\n", 1);

    if (!callMustFailWithCycle(state))
        return fail("luau-aot-static-cycle: first cycle did not raise the explicit cycle error\n", 1);
    _ = lua_gc(state, lua_gc_collect, 0);
    if (!callMustFailWithCycle(state))
        return fail("luau-aot-static-cycle: second cycle did not raise the explicit cycle error\n", 1);

    return if (writeAll(1, "false\nfalse\n")) 0 else 1;
}
