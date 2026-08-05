const std = @import("std");
const trap = @import("trap");
const abi = @import("luau_aot_runtime_abi");

comptime {
    _ = trap;
}

extern fn __wasm_call_ctors() void;
extern fn luaL_newstate() ?*abi.State;
extern fn lua_close(state: ?*abi.State) void;
extern fn lua_gc(state: ?*abi.State, operation: c_int, argument: c_int) c_int;
extern fn lua_pushlstring(state: ?*abi.State, string: [*]const u8, length: usize) void;
extern fn lua_call(state: ?*abi.State, argument_count: c_int, result_count: c_int) void;
extern fn lua_tonumberx(state: ?*abi.State, index: c_int, is_number: *c_int) f64;

extern fn mc_luau_aot_v1_function_00000000(state: ?*abi.State, proto: *const abi.AotProto) callconv(.c) u32;
extern fn mc_luau_aot_v1_function_00000001(state: ?*abi.State, proto: *const abi.AotProto) callconv(.c) u32;
extern fn mc_luau_aot_v1_function_00000002(state: ?*abi.State, proto: *const abi.AotProto) callconv(.c) u32;

const protos = [_]abi.AotProto{
    .{
        .abi_version = abi.abi_version,
        .struct_size = abi.proto_size,
        .layout_sha256 = abi.layout_sha256,
        .entry = &mc_luau_aot_v1_function_00000000,
        .function_id = 0,
        .parent_id = abi.no_id,
        .flags = abi.flag_root,
        .num_params = 0,
        .nups = 0,
        .is_vararg = 1,
        .max_stack_size = 1,
        .reserved = 0,
    },
    .{
        .abi_version = abi.abi_version,
        .struct_size = abi.proto_size,
        .layout_sha256 = abi.layout_sha256,
        .entry = &mc_luau_aot_v1_function_00000001,
        .function_id = 1,
        .parent_id = 0,
        .flags = 0,
        .num_params = 2,
        .nups = 0,
        .is_vararg = 0,
        .max_stack_size = 6,
        .reserved = 0,
    },
    .{
        .abi_version = abi.abi_version,
        .struct_size = abi.proto_size,
        .layout_sha256 = abi.layout_sha256,
        .entry = &mc_luau_aot_v1_function_00000002,
        .function_id = 2,
        .parent_id = 1,
        .flags = 0,
        .num_params = 2,
        .nups = 0,
        .is_vararg = 0,
        .max_stack_size = 3,
        .reserved = 0,
    },
};

const program = abi.AotProgram{
    .abi_version = abi.abi_version,
    .struct_size = abi.program_size,
    .layout_sha256 = abi.layout_sha256,
    .protos = &protos,
    .proto_count = protos.len,
    .root_proto_id = 0,
    .flags = 0,
};

const source = "=aot/compiled_call.luau";
const lua_gc_collect: c_int = 2;
var initialized = false;

export fn mc_luau_aot_v1_compiled_call_oracle_init() void {
    if (initialized)
        return;
    initialized = true;
    __wasm_call_ctors();
}

// The first call executes the compiled root and returns its real child Closure. The second executes
// the compiled caller, which materializes Proto 2, enters it through CALL, and rejoins before RETURN.
// Decimal strings make Proto 2 take its checked arithmetic slow path as part of the same vertical.
export fn mc_luau_aot_v1_compiled_call_oracle_run(lhs: i32, rhs: i32) i32 {
    const state = luaL_newstate() orelse return std.math.minInt(i32);
    defer lua_close(state);

    if (abi.mc_luau_aot_v1_push_program(state, &program, source.ptr, source.len) != 0)
        return std.math.minInt(i32);
    _ = lua_gc(state, lua_gc_collect, 0);
    lua_call(state, 0, 1);
    _ = lua_gc(state, lua_gc_collect, 0);

    var lhs_buffer: [32]u8 = undefined;
    var rhs_buffer: [32]u8 = undefined;
    const lhs_string = std.fmt.bufPrint(&lhs_buffer, "{d}", .{lhs}) catch return std.math.minInt(i32);
    const rhs_string = std.fmt.bufPrint(&rhs_buffer, "{d}", .{rhs}) catch return std.math.minInt(i32);
    lua_pushlstring(state, lhs_string.ptr, lhs_string.len);
    lua_pushlstring(state, rhs_string.ptr, rhs_string.len);
    lua_call(state, 2, 1);

    var is_number: c_int = 0;
    const result = lua_tonumberx(state, -1, &is_number);
    if (is_number == 0 or !std.math.isFinite(result) or result != @trunc(result) or
        result < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        result > @as(f64, @floatFromInt(std.math.maxInt(i32))))
        return std.math.minInt(i32);
    return @intFromFloat(result);
}
