//! Production AgentOS entry for the widened fixed-call strict-AOT Proto graph.
//!
//! The root returns a compiled caller. That caller invokes one compiled child with no parameters or
//! results and a second compiled child with four parameters and three results, consuming all three.

const std = @import("std");
const abi = @import("luau_aot_runtime_abi");
const general_call = @import("luau_aot_general_call_program");
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

pub export fn __main_argc_argv(argc: c_int, argv_pointer: [*][*:0]u8) c_int {
    if (argc != 5)
        return fail("usage: luau-aot-general-call A B C D\n", 2);

    const state = luaL_newstate() orelse return fail("luau-aot-general-call: state allocation failed\n", 1);
    defer lua_close(state);
    if (abi.mc_luau_aot_v1_push_program(
        state,
        &general_call.program,
        general_call.source_name.ptr,
        general_call.source_name.len,
    ) != 0)
        return fail("luau-aot-general-call: program publication failed\n", 1);

    _ = lua_gc(state, lua_gc_collect, 0);
    if (lua_pcall(state, 0, 1, 0) != 0)
        return fail("luau-aot-general-call: root execution failed\n", 1);
    _ = lua_gc(state, lua_gc_collect, 0);

    for (1..5) |index| {
        const argument = std.mem.span(argv_pointer[index]);
        lua_pushlstring(state, argument.ptr, argument.len);
    }
    if (lua_pcall(state, 4, 1, 0) != 0)
        return fail("luau-aot-general-call: nested execution failed\n", 1);

    var is_number: c_int = 0;
    const result = lua_tonumberx(state, -1, &is_number);
    if (is_number == 0 or !std.math.isFinite(result) or result != @trunc(result) or
        result < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        result > @as(f64, @floatFromInt(std.math.maxInt(i32))))
        return fail("luau-aot-general-call: non-integer result\n", 1);

    var buffer: [32]u8 = undefined;
    const output = std.fmt.bufPrint(&buffer, "{d}\n", .{@as(i32, @intFromFloat(result))}) catch
        return fail("luau-aot-general-call: result formatting failed\n", 1);
    return if (writeAll(1, output)) 0 else 1;
}
