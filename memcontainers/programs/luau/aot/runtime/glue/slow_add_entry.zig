//! Production-shaped entry for the first strict-runtime arithmetic slow-path vertical.
//!
//! Raw argv strings deliberately reach the generated function as Luau strings, forcing upstream's
//! CHECK_TAG guards into the compiled DO_ARITH fallback before rejoining the shared return block.

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
extern fn lua_pushlstring(state: ?*abi.State, string: [*]const u8, length: usize) void;
extern fn lua_pcall(state: ?*abi.State, argument_count: c_int, result_count: c_int, error_function: c_int) c_int;
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

const source_name = "=aot/slow_add.luau";

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
        return fail("usage: luau-aot-slow-add LHS RHS\n", 2);

    const state = luaL_newstate() orelse return fail("luau-aot-slow-add: state allocation failed\n", 1);
    defer lua_close(state);
    if (abi.mc_luau_aot_v1_push_root(state, &metadata, source_name.ptr, source_name.len, 2, 3) != 0)
        return fail("luau-aot-slow-add: root publication failed\n", 1);

    const lhs = std.mem.span(argv_pointer[1]);
    const rhs = std.mem.span(argv_pointer[2]);
    lua_pushlstring(state, lhs.ptr, lhs.len);
    lua_pushlstring(state, rhs.ptr, rhs.len);
    if (lua_pcall(state, 2, 1, 0) != 0)
        return fail("luau-aot-slow-add: execution failed\n", 1);

    var is_number: c_int = 0;
    const result = lua_tonumberx(state, -1, &is_number);
    if (is_number == 0 or !std.math.isFinite(result) or result != @trunc(result) or
        result < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        result > @as(f64, @floatFromInt(std.math.maxInt(i32))))
        return fail("luau-aot-slow-add: non-integer result\n", 1);

    var buffer: [32]u8 = undefined;
    const output = std.fmt.bufPrint(&buffer, "{d}\n", .{@as(i32, @intFromFloat(result))}) catch
        return fail("luau-aot-slow-add: result formatting failed\n", 1);
    return if (writeAll(1, output)) 0 else 1;
}
