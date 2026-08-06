//! Production entry for failed static-module initializer retry semantics.
//!
//! A successful probe module owns the attempt count. The failing initializer increments it before
//! raising through real arithmetic fallback. Two failed calls with successful probes between them
//! must therefore observe counts one and two, even across full GC.

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
extern fn lua_pushboolean(state: ?*abi.State, value: c_int) void;
extern fn lua_pushvalue(state: ?*abi.State, index: c_int) void;
extern fn lua_settop(state: ?*abi.State, index: c_int) void;
extern fn lua_pcall(state: ?*abi.State, argument_count: c_int, result_count: c_int, error_function: c_int) c_int;
extern fn lua_tonumberx(state: ?*abi.State, index: c_int, is_number: *c_int) f64;
extern const mc_luau_aot_v1_program: abi.AotProgram;

const lua_gc_collect: c_int = 2;
const source_name = "=aot/static_initializer_package";

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

fn callMustFail(state: ?*abi.State) bool {
    lua_pushvalue(state, 1);
    lua_pushboolean(state, 1);
    const failed = lua_pcall(state, 1, 0, 0) != 0;
    lua_settop(state, 1);
    return failed;
}

fn attemptCount(state: ?*abi.State) ?i32 {
    lua_pushvalue(state, 1);
    lua_pushboolean(state, 0);
    if (lua_pcall(state, 1, 1, 0) != 0)
        return null;
    var is_number: c_int = 0;
    const value = lua_tonumberx(state, -1, &is_number);
    lua_settop(state, 1);
    if (is_number == 0 or !std.math.isFinite(value) or value != @trunc(value) or
        value < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        value > @as(f64, @floatFromInt(std.math.maxInt(i32))))
        return null;
    return @intFromFloat(value);
}

pub export fn __main_argc_argv(argc: c_int, _: [*][*:0]u8) c_int {
    if (argc != 1)
        return fail("usage: luau-aot-static-initializer\n", 2);

    const state = luaL_newstate() orelse return fail("luau-aot-static-initializer: state allocation failed\n", 1);
    defer lua_close(state);
    if (abi.mc_luau_aot_v1_push_program(state, &mc_luau_aot_v1_program, source_name.ptr, source_name.len) != 0)
        return fail("luau-aot-static-initializer: program publication failed\n", 1);

    _ = lua_gc(state, lua_gc_collect, 0);
    if (lua_pcall(state, 0, 1, 0) != 0)
        return fail("luau-aot-static-initializer: entry root execution failed\n", 1);

    if (!callMustFail(state))
        return fail("luau-aot-static-initializer: first initializer unexpectedly succeeded\n", 1);
    const first = attemptCount(state) orelse
        return fail("luau-aot-static-initializer: first attempt probe failed\n", 1);
    _ = lua_gc(state, lua_gc_collect, 0);
    if (!callMustFail(state))
        return fail("luau-aot-static-initializer: second initializer unexpectedly succeeded\n", 1);
    const second = attemptCount(state) orelse
        return fail("luau-aot-static-initializer: second attempt probe failed\n", 1);
    if (first != 1 or second != 2)
        return fail("luau-aot-static-initializer: failed module was not retried exactly once\n", 1);

    var buffer: [48]u8 = undefined;
    const output = std.fmt.bufPrint(&buffer, "false\n{d}\nfalse\n{d}\n", .{ first, second }) catch
        return fail("luau-aot-static-initializer: result formatting failed\n", 1);
    return if (writeAll(1, output)) 0 else 1;
}
