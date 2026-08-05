//! Production AgentOS entry for the first mutable reference-capture strict-AOT Proto graph.
//!
//! The root returns a factory. The factory closes its initial raw argv value into an accumulator,
//! which remains rooted and preserves its mutated UpVal across two protected compiled calls.

const std = @import("std");
const abi = @import("luau_aot_runtime_abi");
const reference_capture = @import("luau_aot_reference_capture_program");
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

pub export fn __main_argc_argv(argc: c_int, argv_pointer: [*][*:0]u8) c_int {
    if (argc != 4)
        return fail("usage: luau-aot-reference-capture INITIAL DELTA1 DELTA2\n", 2);

    const state = luaL_newstate() orelse return fail("luau-aot-reference-capture: state allocation failed\n", 1);
    defer lua_close(state);
    if (abi.mc_luau_aot_v1_push_program(
        state,
        &reference_capture.program,
        reference_capture.source_name.ptr,
        reference_capture.source_name.len,
    ) != 0)
        return fail("luau-aot-reference-capture: program publication failed\n", 1);

    if (lua_pcall(state, 0, 1, 0) != 0)
        return fail("luau-aot-reference-capture: root execution failed\n", 1);

    const initial = std.mem.span(argv_pointer[1]);
    lua_pushlstring(state, initial.ptr, initial.len);
    if (lua_pcall(state, 1, 1, 0) != 0)
        return fail("luau-aot-reference-capture: factory execution failed\n", 1);

    // The factory frame is gone. Collection here proves the accumulator owns a correctly closed
    // UpVal, rather than retaining an invalid reference to the factory's former stack slot.
    _ = lua_gc(state, lua_gc_collect, 0);

    lua_pushvalue(state, -1);
    const delta1 = std.mem.span(argv_pointer[2]);
    lua_pushlstring(state, delta1.ptr, delta1.len);
    if (lua_pcall(state, 1, 1, 0) != 0)
        return fail("luau-aot-reference-capture: first accumulator execution failed\n", 1);
    lua_settop(state, -2); // discard the first result, retaining the mutated accumulator

    lua_pushvalue(state, -1);
    const delta2 = std.mem.span(argv_pointer[3]);
    lua_pushlstring(state, delta2.ptr, delta2.len);
    if (lua_pcall(state, 1, 1, 0) != 0)
        return fail("luau-aot-reference-capture: second accumulator execution failed\n", 1);

    var is_number: c_int = 0;
    const result = lua_tonumberx(state, -1, &is_number);
    if (is_number == 0 or !std.math.isFinite(result) or result != @trunc(result) or
        result < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        result > @as(f64, @floatFromInt(std.math.maxInt(i32))))
        return fail("luau-aot-reference-capture: non-integer result\n", 1);

    var buffer: [32]u8 = undefined;
    const output = std.fmt.bufPrint(&buffer, "{d}\n", .{@as(i32, @intFromFloat(result))}) catch
        return fail("luau-aot-reference-capture: result formatting failed\n", 1);
    return if (writeAll(1, output)) 0 else 1;
}
