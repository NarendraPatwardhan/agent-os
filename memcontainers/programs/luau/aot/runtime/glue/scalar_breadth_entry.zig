//! Production AgentOS entry for the broad scalar WP3 source artifact.

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
extern fn lua_pushnumber(state: ?*abi.State, value: f64) void;
extern fn lua_pcall(state: ?*abi.State, argument_count: c_int, result_count: c_int, error_function: c_int) c_int;
extern fn lua_tonumberx(state: ?*abi.State, index: c_int, is_number: *c_int) f64;
extern fn mc_luau_aot_v1_generated_ir_function(state: ?*abi.State, proto: *const abi.AotProto) callconv(.c) u32;

const metadata = abi.AotProto{
    .abi_version = abi.abi_version,
    .struct_size = abi.proto_size,
    .layout_sha256 = abi.layout_sha256,
    .entry = &mc_luau_aot_v1_generated_ir_function,
    .function_id = 1,
    .parent_id = abi.no_id,
    .flags = abi.flag_root,
    .num_params = 2,
    .nups = 0,
    .is_vararg = 0,
    .max_stack_size = 13,
    .reserved = 0,
};

const source_name = "=aot/scalar_breadth.luau";

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
    if (argc != 3)
        return fail("usage: luau-aot-scalar LHS NONZERO_RHS\n", 2);

    const lhs = std.fmt.parseInt(i32, std.mem.span(argv_pointer[1]), 10) catch
        return fail("luau-aot-scalar: invalid lhs\n", 2);
    const rhs = std.fmt.parseInt(i32, std.mem.span(argv_pointer[2]), 10) catch
        return fail("luau-aot-scalar: invalid rhs\n", 2);
    if (rhs == 0)
        return fail("luau-aot-scalar: rhs must be nonzero\n", 2);

    const state = luaL_newstate() orelse return fail("luau-aot-scalar: state allocation failed\n", 1);
    defer lua_close(state);
    if (abi.mc_luau_aot_v1_push_root(state, &metadata, source_name.ptr, source_name.len) != 0)
        return fail("luau-aot-scalar: root publication failed\n", 1);

    lua_pushnumber(state, @floatFromInt(lhs));
    lua_pushnumber(state, @floatFromInt(rhs));
    if (lua_pcall(state, 2, 1, 0) != 0)
        return fail("luau-aot-scalar: execution failed\n", 1);

    var is_number: c_int = 0;
    const result = lua_tonumberx(state, -1, &is_number);
    if (is_number == 0 or !std.math.isFinite(result) or result != @trunc(result) or
        result < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        result > @as(f64, @floatFromInt(std.math.maxInt(i32))))
        return fail("luau-aot-scalar: non-integer result\n", 1);

    var buffer: [32]u8 = undefined;
    const output = std.fmt.bufPrint(&buffer, "{d}\n", .{@as(i32, @intFromFloat(result))}) catch
        return fail("luau-aot-scalar: result formatting failed\n", 1);
    return if (writeAll(1, output)) 0 else 1;
}
