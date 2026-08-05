const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luau_aot_wasm_object");

pub const generated_symbol = "mc_luau_aot_v1_generated_ir_function";
pub const commit_number_symbol = "mc_luau_aot_v1_commit_number";
pub const interrupt_symbol = "mc_luau_aot_v1_interrupt";

const status_ok: i32 = 0;
const status_unsupported_type: i32 = 1;
const status_internal_error: i32 = 2;

const lua_state_base_offset: u32 = 12;
const tvalue_size: u32 = 16;
const tvalue_tag_offset: u32 = 12;
const lua_tnumber: i32 = 3;
const max_lowered_locals: u32 = 262_144;

pub const Error = snapshot_v1.Error || wasm.Error || std.mem.Allocator.Error || error{
    FunctionOutOfBounds,
    UnsupportedVariadicFunction,
    UnsupportedCommand,
    UnsupportedOperand,
    UnsupportedCondition,
    UnsupportedControlFlow,
    InvalidOperandCount,
    InvalidOperandType,
    InvalidInstructionResult,
    InvalidBlockTermination,
    InvalidReturnCount,
    ResourceLimit,
};

const ValueShape = enum {
    none,
    i32,
    f64,
    tvalue,
};

const ValueSlot = struct {
    shape: ValueShape = .none,
    first: u32 = snapshot_v1.no_id,
    second: u32 = snapshot_v1.no_id,
};

const Context = struct {
    allocator: std.mem.Allocator,
    snapshot: snapshot_v1.Snapshot,
    proto: snapshot_v1.Proto,
    function: snapshot_v1.IrFunction,
    slots: []const ValueSlot,
    body: *wasm.Body,
    commit_number: wasm.FunctionRef,
    interrupt: wasm.FunctionRef,
    base_local: u32,
    dispatch_local: u32,
    status_local: u32,

    fn instruction(self: Context, id: u32) Error!snapshot_v1.IrInstruction {
        return self.snapshot.irInstruction(self.function, id);
    }

    fn operand(self: Context, instruction_value: snapshot_v1.IrInstruction, id: u32) Error!snapshot_v1.IrOperand {
        return self.snapshot.irOperand(instruction_value, id);
    }

    fn constant(self: Context, id: u32) Error!snapshot_v1.IrConstant {
        return self.snapshot.irConstant(self.function, id);
    }

    fn requireOperandCount(_: Context, instruction_value: snapshot_v1.IrInstruction, expected: u32) Error!void {
        if (instruction_value.operand_count != expected)
            return Error.InvalidOperandCount;
    }

    fn vmRegisterOffset(self: Context, operand_value: snapshot_v1.IrOperand, field_offset: u32) Error!u32 {
        if (operand_value.kind != .vm_reg or operand_value.value >= self.proto.max_stack_size)
            return Error.InvalidOperandType;
        return @as(u32, operand_value.value) * tvalue_size + field_offset;
    }

    fn emitReloadBase(self: Context) Error!void {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Load(self.allocator, 2, lua_state_base_offset);
        try self.body.localSet(self.allocator, self.base_local);
    }

    fn emitI32Value(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        switch (operand_value.kind) {
            .constant => {
                const value = try self.constant(operand_value.value);
                const integer: i32 = switch (value.kind) {
                    .int => value.intValue().?,
                    .uint => @bitCast(value.uintValue().?),
                    .tag => value.tagValue().?,
                    else => return Error.InvalidOperandType,
                };
                try self.body.i32Const(self.allocator, integer);
            },
            .instruction => {
                if (operand_value.value >= self.slots.len)
                    return Error.InvalidInstructionResult;
                const slot = self.slots[operand_value.value];
                if (slot.shape != .i32)
                    return Error.InvalidInstructionResult;
                try self.body.localGet(self.allocator, slot.first);
            },
            else => return Error.UnsupportedOperand,
        }
    }

    fn emitF64Value(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        switch (operand_value.kind) {
            .constant => {
                const value = try self.constant(operand_value.value);
                try self.body.f64Const(self.allocator, value.doubleValue() orelse return Error.InvalidOperandType);
            },
            .instruction => {
                if (operand_value.value >= self.slots.len)
                    return Error.InvalidInstructionResult;
                const slot = self.slots[operand_value.value];
                if (slot.shape != .f64)
                    return Error.InvalidInstructionResult;
                try self.body.localGet(self.allocator, slot.first);
            },
            else => return Error.UnsupportedOperand,
        }
    }

    fn requireTarget(self: Context, operand_value: snapshot_v1.IrOperand) Error!u32 {
        if (operand_value.kind != .block)
            return Error.InvalidOperandType;
        const target = try self.snapshot.irBlock(self.function, operand_value.value);
        if (!target.kind.isCompilable() or target.isEmpty())
            return Error.UnsupportedControlFlow;
        return operand_value.value;
    }

    fn emitStatusReturn(self: Context, status: i32) Error!void {
        try self.body.i32Const(self.allocator, status);
        try self.body.return_(self.allocator);
    }

    fn emitInstructionResultSet(self: Context, instruction_id: u32) Error!void {
        if (instruction_id >= self.slots.len or self.slots[instruction_id].shape == .none)
            return Error.InvalidInstructionResult;
        try self.body.localSet(self.allocator, self.slots[instruction_id].first);
    }

    fn emitLoadTag(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const source = try self.operand(instruction_value, 0);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Load(self.allocator, 2, try self.vmRegisterOffset(source, tvalue_tag_offset));
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitLoadDouble(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const source = try self.operand(instruction_value, 0);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.f64Load(self.allocator, 3, try self.vmRegisterOffset(source, 0));
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitLoadTValue(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        if (instruction_id >= self.slots.len or self.slots[instruction_id].shape != .tvalue)
            return Error.InvalidInstructionResult;
        const source = try self.operand(instruction_value, 0);
        const value_offset = try self.vmRegisterOffset(source, 0);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i64Load(self.allocator, 3, value_offset);
        try self.body.localSet(self.allocator, self.slots[instruction_id].first);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i64Load(self.allocator, 3, value_offset + 8);
        try self.body.localSet(self.allocator, self.slots[instruction_id].second);
    }

    fn emitStoreTag(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const destination = try self.operand(instruction_value, 0);
        try self.body.localGet(self.allocator, self.base_local);
        try self.emitI32Value(try self.operand(instruction_value, 1));
        try self.body.i32Store(self.allocator, 2, try self.vmRegisterOffset(destination, tvalue_tag_offset));
    }

    fn emitStoreDouble(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const destination = try self.operand(instruction_value, 0);
        try self.body.localGet(self.allocator, self.base_local);
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.body.f64Store(self.allocator, 3, try self.vmRegisterOffset(destination, 0));
    }

    fn emitStoreTValue(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const destination = try self.operand(instruction_value, 0);
        const source = try self.operand(instruction_value, 1);
        if (source.kind != .instruction or source.value >= self.slots.len or self.slots[source.value].shape != .tvalue)
            return Error.InvalidOperandType;
        const destination_offset = try self.vmRegisterOffset(destination, 0);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.localGet(self.allocator, self.slots[source.value].first);
        try self.body.i64Store(self.allocator, 3, destination_offset);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.localGet(self.allocator, self.slots[source.value].second);
        try self.body.i64Store(self.allocator, 3, destination_offset + 8);
    }

    fn emitAddNumber(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.body.f64Add(self.allocator);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitCheckTag(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        try self.emitI32Value(try self.operand(instruction_value, 0));
        try self.emitI32Value(try self.operand(instruction_value, 1));
        const failure = try self.operand(instruction_value, 2);
        if (failure.kind != .block and failure.kind != .vm_exit)
            return Error.InvalidOperandType;
        try self.body.i32Ne(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.emitStatusReturn(status_unsupported_type);
        try self.body.end(self.allocator);
    }

    fn emitInterrupt(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const pc_operand = try self.operand(instruction_value, 0);
        if (pc_operand.kind != .constant)
            return Error.InvalidOperandType;
        const pc_constant = try self.constant(pc_operand.value);
        const pc = pc_constant.uintValue() orelse return Error.InvalidOperandType;
        const signed_pc = std.math.cast(i32, pc) orelse return Error.ResourceLimit;

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, signed_pc);
        try self.body.call(self.allocator, self.interrupt);
        try self.body.localTee(self.allocator, self.status_local);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.emitReloadBase();
        try self.body.else_(self.allocator);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.return_(self.allocator);
        try self.body.end(self.allocator);
    }

    fn emitJump(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const target = try self.requireTarget(try self.operand(instruction_value, 0));
        try self.body.i32Const(self.allocator, @intCast(target));
        try self.body.localSet(self.allocator, self.dispatch_local);
        try self.body.branch(self.allocator, 1);
    }

    fn emitNumericCondition(self: Context, condition: snapshot_v1.IrCondition) Error!void {
        switch (condition) {
            .equal => try self.body.f64Eq(self.allocator),
            .not_equal => try self.body.f64Ne(self.allocator),
            .less => try self.body.f64Lt(self.allocator),
            .not_less => {
                try self.body.f64Lt(self.allocator);
                try self.body.i32Eqz(self.allocator);
            },
            .less_equal => try self.body.f64Le(self.allocator),
            .not_less_equal => {
                try self.body.f64Le(self.allocator);
                try self.body.i32Eqz(self.allocator);
            },
            .greater => try self.body.f64Gt(self.allocator),
            .not_greater => {
                try self.body.f64Gt(self.allocator);
                try self.body.i32Eqz(self.allocator);
            },
            .greater_equal => try self.body.f64Ge(self.allocator),
            .not_greater_equal => {
                try self.body.f64Ge(self.allocator);
                try self.body.i32Eqz(self.allocator);
            },
            .unsigned_less, .unsigned_less_equal, .unsigned_greater, .unsigned_greater_equal => return Error.UnsupportedCondition,
        }
    }

    fn emitJumpCompareNumber(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 5);
        const condition_operand = try self.operand(instruction_value, 2);
        if (condition_operand.kind != .condition)
            return Error.InvalidOperandType;
        const condition: snapshot_v1.IrCondition = @enumFromInt(@as(u8, @intCast(condition_operand.value)));
        const true_target = try self.requireTarget(try self.operand(instruction_value, 3));
        const false_target = try self.requireTarget(try self.operand(instruction_value, 4));

        try self.body.i32Const(self.allocator, @intCast(true_target));
        try self.body.i32Const(self.allocator, @intCast(false_target));
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.emitNumericCondition(condition);
        try self.body.select(self.allocator);
        try self.body.localSet(self.allocator, self.dispatch_local);
        try self.body.branch(self.allocator, 1);
    }

    fn emitReturn(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const source = try self.operand(instruction_value, 0);
        const return_count_operand = try self.operand(instruction_value, 1);
        if (return_count_operand.kind != .constant)
            return Error.InvalidReturnCount;
        const return_count = (try self.constant(return_count_operand.value)).intValue() orelse return Error.InvalidReturnCount;
        if (return_count != 1)
            return Error.InvalidReturnCount;

        const tag_offset = try self.vmRegisterOffset(source, tvalue_tag_offset);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Load(self.allocator, 2, tag_offset);
        try self.body.i32Const(self.allocator, lua_tnumber);
        try self.body.i32Ne(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.emitStatusReturn(status_unsupported_type);
        try self.body.end(self.allocator);

        try self.body.localGet(self.allocator, 0);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.f64Load(self.allocator, 3, try self.vmRegisterOffset(source, 0));
        try self.body.call(self.allocator, self.commit_number);
        try self.emitStatusReturn(status_ok);
    }

    fn emitPrepVarargsNoop(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        if (!self.function.variadic or !self.proto.is_vararg or self.proto.num_params != 0)
            return Error.UnsupportedVariadicFunction;

        const pc_operand = try self.operand(instruction_value, 0);
        const parameter_operand = try self.operand(instruction_value, 1);
        if (pc_operand.kind != .constant or parameter_operand.kind != .constant)
            return Error.InvalidOperandType;
        _ = (try self.constant(pc_operand.value)).uintValue() orelse return Error.InvalidOperandType;
        const parameter_count = (try self.constant(parameter_operand.value)).intValue() orelse return Error.InvalidOperandType;
        if (parameter_count != 0)
            return Error.UnsupportedVariadicFunction;

        // Native PREPVARARGS relocates fixed parameters after the caller's extra arguments. With
        // zero fixed parameters and no reachable GETVARARGS, the strict non-vararg AOT frame is
        // observationally equivalent: generated registers begin at base and ignored extra arguments
        // remain rooted in the frame. Any GETVARARGS command still fails closed below.
    }

    fn emitInstruction(self: Context, instruction_id: u32) Error!bool {
        const instruction_value = try self.instruction(instruction_id);
        switch (instruction_value.command) {
            .nop, .mark_used => return false,
            .load_tag => try self.emitLoadTag(instruction_id, instruction_value),
            .load_double => try self.emitLoadDouble(instruction_id, instruction_value),
            .load_tvalue => try self.emitLoadTValue(instruction_id, instruction_value),
            .store_tag => try self.emitStoreTag(instruction_value),
            .store_double => try self.emitStoreDouble(instruction_value),
            .store_tvalue => try self.emitStoreTValue(instruction_value),
            .add_num => try self.emitAddNumber(instruction_id, instruction_value),
            .check_tag => try self.emitCheckTag(instruction_value),
            .interrupt => try self.emitInterrupt(instruction_value),
            .jump => {
                try self.emitJump(instruction_value);
                return true;
            },
            .jump_cmp_num => {
                try self.emitJumpCompareNumber(instruction_value);
                return true;
            },
            .return_ => {
                try self.emitReturn(instruction_value);
                return true;
            },
            .fallback_prepvarargs => try self.emitPrepVarargsNoop(instruction_value),
            else => return Error.UnsupportedCommand,
        }
        return false;
    }

    fn emitBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock) Error!void {
        try self.body.localGet(self.allocator, self.dispatch_local);
        try self.body.i32Const(self.allocator, @intCast(block_id));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);

        var terminated = false;
        var instruction_id = block.start;
        while (instruction_id <= block.finish) : (instruction_id += 1) {
            if (terminated)
                return Error.InvalidBlockTermination;
            terminated = try self.emitInstruction(instruction_id);
        }
        if (!terminated)
            return Error.InvalidBlockTermination;
        try self.body.end(self.allocator);
    }
};

fn resultShape(command: snapshot_v1.IrCommand) ValueShape {
    return switch (command) {
        .load_tag => .i32,
        .load_double, .add_num => .f64,
        .load_tvalue => .tvalue,
        else => .none,
    };
}

pub fn build(allocator: std.mem.Allocator, snapshot_bytes: []const u8, function_id: u32) Error![]u8 {
    const snapshot = try snapshot_v1.parse(snapshot_bytes, snapshot_v1.production_identity);
    try snapshot_v1.validateModel(snapshot);
    if (function_id >= snapshot.header.ir_function_count)
        return Error.FunctionOutOfBounds;

    const function = try snapshot.irFunction(function_id);
    const proto = try snapshot.proto(function.proto_id);
    if (function.variadic != proto.is_vararg or (function.variadic and proto.num_params != 0))
        return Error.UnsupportedVariadicFunction;

    const entry_block = try snapshot.irBlock(function, function.entry_block);
    if (!entry_block.kind.isCompilable() or entry_block.isEmpty())
        return Error.UnsupportedControlFlow;

    const slots = try allocator.alloc(ValueSlot, function.instruction_count);
    defer allocator.free(slots);
    @memset(slots, .{});

    var locals: std.ArrayList(wasm.Local) = .empty;
    defer locals.deinit(allocator);
    try locals.append(allocator, .{ .count = 3, .value_type = .i32 });
    var next_local: u32 = 5; // parameters 0/1; base, dispatcher, helper status are 2/3/4.

    var instruction_id: u32 = 0;
    while (instruction_id < function.instruction_count) : (instruction_id += 1) {
        const shape = resultShape((try snapshot.irInstruction(function, instruction_id)).command);
        slots[instruction_id].shape = shape;
        switch (shape) {
            .none => {},
            .i32 => {
                if (next_local >= max_lowered_locals)
                    return Error.ResourceLimit;
                slots[instruction_id].first = next_local;
                next_local += 1;
                try locals.append(allocator, .{ .count = 1, .value_type = .i32 });
            },
            .f64 => {
                if (next_local >= max_lowered_locals)
                    return Error.ResourceLimit;
                slots[instruction_id].first = next_local;
                next_local += 1;
                try locals.append(allocator, .{ .count = 1, .value_type = .f64 });
            },
            .tvalue => {
                if (next_local > max_lowered_locals - 2)
                    return Error.ResourceLimit;
                slots[instruction_id].first = next_local;
                slots[instruction_id].second = next_local + 1;
                next_local += 2;
                try locals.append(allocator, .{ .count = 2, .value_type = .i64 });
            },
        }
    }

    const commit_params = [_]wasm.ValueType{ .i32, .f64 };
    const interrupt_params = [_]wasm.ValueType{ .i32, .i32 };
    const generated_params = [_]wasm.ValueType{ .i32, .i32 };
    const no_results = [_]wasm.ValueType{};
    const status_result = [_]wasm.ValueType{.i32};

    var object = wasm.Object.init(allocator);
    defer object.deinit();
    const commit_type = try object.addType(.{ .params = &commit_params, .results = &no_results });
    const interrupt_type = try object.addType(.{ .params = &interrupt_params, .results = &status_result });
    const generated_type = try object.addType(.{ .params = &generated_params, .results = &status_result });
    const commit_number = try object.importFunction("env", commit_number_symbol, commit_type);
    const interrupt = try object.importFunction("env", interrupt_symbol, interrupt_type);

    var body = try wasm.Body.init(allocator, locals.items);
    defer body.deinit(allocator);
    const context = Context{
        .allocator = allocator,
        .snapshot = snapshot,
        .proto = proto,
        .function = function,
        .slots = slots,
        .body = &body,
        .commit_number = commit_number,
        .interrupt = interrupt,
        .base_local = 2,
        .dispatch_local = 3,
        .status_local = 4,
    };

    try context.emitReloadBase();
    try body.i32Const(allocator, @intCast(function.entry_block));
    try body.localSet(allocator, context.dispatch_local);
    try body.loop(allocator);

    var block_id: u32 = 0;
    while (block_id < function.block_count) : (block_id += 1) {
        const block = try snapshot.irBlock(function, block_id);
        if (block.kind.isCompilable() and !block.isEmpty())
            try context.emitBlock(block_id, block);
    }

    // Reaching the bottom means a malformed/generated dispatch target escaped static validation.
    try context.emitStatusReturn(status_internal_error);
    try body.end(allocator);
    try body.i32Const(allocator, status_internal_error);
    try body.finish(allocator);

    _ = try object.defineFunction(generated_symbol, generated_type, wasm.symbol.visibility_hidden, body);
    return object.emit();
}
