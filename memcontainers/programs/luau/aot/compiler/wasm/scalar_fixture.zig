const std = @import("std");
const wasm = @import("object.zig");

pub const generated_symbol = "mc_luau_aot_v1_generated_scalar_fixture";
pub const commit_symbol = "mc_luau_aot_v1_commit_number";

// This is deliberately a runtime-value fixture, not a compiler evaluator. It reads a number from
// the first real Luau TValue stack slot, computes 1+...+n with a Wasm loop, and commits the result
// through the versioned runtime ABI. The next lowering slice replaces this construction with the
// same operations selected from normalized upstream IR.
pub fn build(allocator: std.mem.Allocator) ![]u8 {
    const commit_params = [_]wasm.ValueType{ .i32, .f64 };
    const generated_params = [_]wasm.ValueType{ .i32, .i32 };
    const no_results = [_]wasm.ValueType{};
    const status_result = [_]wasm.ValueType{.i32};

    var object = wasm.Object.init(allocator);
    defer object.deinit();

    const commit_type = try object.addType(.{ .params = &commit_params, .results = &no_results });
    const generated_type = try object.addType(.{ .params = &generated_params, .results = &status_result });
    const commit = try object.importFunction("env", commit_symbol, commit_type);

    const locals = [_]wasm.Local{
        .{ .count = 2, .value_type = .i32 },
        .{ .count = 1, .value_type = .f64 },
    };
    var body = try wasm.Body.init(allocator, &locals);
    defer body.deinit(allocator);

    // local 0 = lua_State*, local 1 = AotProto*, local 2 = base, local 3 = n, local 4 = sum.
    try body.localGet(allocator, 0);
    try body.i32Load(allocator, 2, 12); // lua_State::base
    try body.localSet(allocator, 2);

    try body.localGet(allocator, 2);
    try body.i32Load(allocator, 2, 12); // TValue::tt
    try body.i32Const(allocator, 3); // LUA_TNUMBER
    try body.opcode(allocator, 0x47); // i32.ne
    try body.ifVoid(allocator);
    try body.i32Const(allocator, 1); // MC_LUAU_AOT_V1_UNSUPPORTED_TYPE
    try body.return_(allocator);
    try body.end(allocator);

    try body.localGet(allocator, 2);
    try body.f64Load(allocator, 3, 0); // TValue::value.n
    try body.opcode(allocator, 0xaa); // i32.trunc_f64_s
    try body.localSet(allocator, 3);
    try body.f64Const(allocator, 0.0);
    try body.localSet(allocator, 4);

    try body.block(allocator);
    try body.loop(allocator);
    try body.localGet(allocator, 3);
    try body.i32Const(allocator, 0);
    try body.opcode(allocator, 0x4c); // i32.le_s
    try body.branchIf(allocator, 1);
    try body.localGet(allocator, 4);
    try body.localGet(allocator, 3);
    try body.opcode(allocator, 0xb7); // f64.convert_i32_s
    try body.opcode(allocator, 0xa0); // f64.add
    try body.localSet(allocator, 4);
    try body.localGet(allocator, 3);
    try body.i32Const(allocator, 1);
    try body.opcode(allocator, 0x6b); // i32.sub
    try body.localSet(allocator, 3);
    try body.branch(allocator, 0);
    try body.end(allocator);
    try body.end(allocator);

    try body.localGet(allocator, 0);
    try body.localGet(allocator, 4);
    try body.call(allocator, commit);
    try body.i32Const(allocator, 0); // MC_LUAU_AOT_V1_OK
    try body.finish(allocator);

    _ = try object.defineFunction(generated_symbol, generated_type, wasm.symbol.visibility_hidden, body);
    return object.emit();
}

test "dynamic scalar fixture is deterministic and relocatable" {
    const allocator = std.testing.allocator;
    const first = try build(allocator);
    defer allocator.free(first);
    const second = try build(allocator);
    defer allocator.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, generated_symbol) != null);
    try std.testing.expect(std.mem.indexOf(u8, first, commit_symbol) != null);
}
