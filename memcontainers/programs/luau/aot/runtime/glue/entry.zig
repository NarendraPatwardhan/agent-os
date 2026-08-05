//! First production-shaped strict-AOT guest.
//!
//! The linked function is still the bounded numeric WP2 oracle, but every boundary around it is the
//! real product path: kernel argv through the canonical WASI adapter, a real Luau state and protected
//! call, direct mc stdout, the strict no-interpreter runtime, and mc_program stamping/attestation.

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
    .num_params = 1,
    .nups = 0,
    .is_vararg = 0,
    .max_stack_size = 5,
    .reserved = 0,
};

const source_name = "=aot/numeric_loop.luau";

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

fn run(input: i32) ?i32 {
    const state = luaL_newstate() orelse return null;
    defer lua_close(state);

    if (abi.mc_luau_aot_v1_push_root(state, &metadata, source_name.ptr, source_name.len) != 0)
        return null;
    lua_pushnumber(state, @floatFromInt(input));
    if (lua_pcall(state, 1, 1, 0) != 0)
        return null;

    var is_number: c_int = 0;
    const result = lua_tonumberx(state, -1, &is_number);
    if (is_number == 0 or !std.math.isFinite(result) or result != @trunc(result) or
        result < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        result > @as(f64, @floatFromInt(std.math.maxInt(i32))))
        return null;
    return @intFromFloat(result);
}

pub export fn __main_argc_argv(argc: c_int, argv_pointer: [*][*:0]u8) c_int {
    if (argc != 2)
        return fail("usage: luau-aot-oracle INTEGER\n", 2);

    const input = std.fmt.parseInt(i32, std.mem.span(argv_pointer[1]), 10) catch
        return fail("luau-aot-oracle: invalid integer\n", 2);
    const result = run(input) orelse
        return fail("luau-aot-oracle: execution failed\n", 1);

    var buffer: [32]u8 = undefined;
    const output = std.fmt.bufPrint(&buffer, "{d}\n", .{result}) catch
        return fail("luau-aot-oracle: result formatting failed\n", 1);
    return if (writeAll(1, output)) 0 else 1;
}
