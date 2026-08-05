const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luau_aot_wasm_object");

pub const generated_symbol = "mc_luau_aot_v1_generated_ir_function";
pub const return_fixed_symbol = "mc_luau_aot_v1_return_fixed";
pub const interrupt_symbol = "mc_luau_aot_v1_interrupt";
pub const do_arith_symbol = "mc_luau_aot_v1_do_arith";
pub const dupclosure_symbol = "mc_luau_aot_v1_dupclosure";
pub const newclosure_value_symbol = "mc_luau_aot_v1_newclosure_value";
pub const get_value_upvalue_symbol = "mc_luau_aot_v1_get_value_upvalue";
pub const call_fixed_symbol = "mc_luau_aot_v1_call_fixed";

const status_ok: i32 = 0;
const status_unsupported_type: i32 = 1;
const status_internal_error: i32 = 2;

const lua_state_base_offset: u32 = 12;
const tvalue_size: u32 = 16;
const tvalue_tag_offset: u32 = 12;
const upstream_tm_add: i32 = 8;
const aot_arith_add: i32 = 0;
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

const ValueClosurePattern = struct {
    primary_destination: u32,
    copy_destination: u32,
    child_proto_id: u32,
    capture_register: u32,
};

const Context = struct {
    allocator: std.mem.Allocator,
    snapshot: snapshot_v1.Snapshot,
    proto: snapshot_v1.Proto,
    function: snapshot_v1.IrFunction,
    slots: []const ValueSlot,
    body: *wasm.Body,
    return_fixed: wasm.FunctionRef,
    interrupt: wasm.FunctionRef,
    do_arith: ?wasm.FunctionRef,
    dupclosure: ?wasm.FunctionRef,
    newclosure_value: ?wasm.FunctionRef,
    get_value_upvalue: ?wasm.FunctionRef,
    call_fixed: ?wasm.FunctionRef,
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
        return (try self.vmRegisterIndex(operand_value)) * tvalue_size + field_offset;
    }

    fn vmRegisterIndex(self: Context, operand_value: snapshot_v1.IrOperand) Error!u32 {
        if (operand_value.kind != .vm_reg or operand_value.value >= self.proto.max_stack_size)
            return Error.InvalidOperandType;
        return operand_value.value;
    }

    fn emitReloadBase(self: Context) Error!void {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Load(self.allocator, 2, lua_state_base_offset);
        try self.body.localSet(self.allocator, self.base_local);
    }

    fn requireSingleBytecodeBlockRange(self: Context, start: u32, finish: u32) Error!void {
        var owner: ?u32 = null;
        var block_id: u32 = 0;
        while (block_id < self.function.block_count) : (block_id += 1) {
            const block = try self.snapshot.irBlock(self.function, block_id);
            if (block.isEmpty() or block.finish < start or block.start > finish)
                continue;
            if (owner != null or block.kind != .bytecode or block.start > start or block.finish < finish)
                return Error.UnsupportedControlFlow;
            owner = block_id;
        }
        if (owner == null)
            return Error.UnsupportedControlFlow;
    }

    fn valueClosurePattern(self: Context, newclosure_id: u32) Error!ValueClosurePattern {
        if (newclosure_id < 2)
            return Error.UnsupportedControlFlow;
        const sequence_end = std.math.add(u32, newclosure_id, 9) catch return Error.ResourceLimit;
        if (sequence_end >= self.function.instruction_count)
            return Error.UnsupportedControlFlow;
        try self.requireSingleBytecodeBlockRange(newclosure_id - 2, sequence_end);

        const marker = try self.instruction(newclosure_id - 2);
        const load_env = try self.instruction(newclosure_id - 1);
        const newclosure = try self.instruction(newclosure_id);
        const store_pointer = try self.instruction(newclosure_id + 1);
        const store_tag = try self.instruction(newclosure_id + 2);
        const capture_load = try self.instruction(newclosure_id + 3);
        const upvalue_address = try self.instruction(newclosure_id + 4);
        const capture_store = try self.instruction(newclosure_id + 5);
        const check_gc = try self.instruction(newclosure_id + 6);
        const capture = try self.instruction(newclosure_id + 7);
        const nop = try self.instruction(newclosure_id + 8);
        const store_copy = try self.instruction(newclosure_id + 9);

        if (marker.command != .set_savedpc or load_env.command != .load_env or
            newclosure.command != .newclosure or store_pointer.command != .store_pointer or
            store_tag.command != .store_tag or capture_load.command != .load_tvalue or
            upvalue_address.command != .get_closure_upval_addr or
            capture_store.command != .store_tvalue or check_gc.command != .check_gc or
            capture.command != .capture or nop.command != .nop or
            store_copy.command != .store_split_tvalue)
            return Error.UnsupportedControlFlow;
        _ = try self.savedPc(marker);
        try self.requireOperandCount(load_env, 0);
        try self.requireOperandCount(newclosure, 3);
        try self.requireOperandCount(store_pointer, 2);
        try self.requireOperandCount(store_tag, 2);
        try self.requireOperandCount(capture_load, 1);
        try self.requireOperandCount(upvalue_address, 2);
        try self.requireOperandCount(capture_store, 2);
        try self.requireOperandCount(check_gc, 0);
        try self.requireOperandCount(capture, 2);
        try self.requireOperandCount(nop, 0);
        try self.requireOperandCount(store_copy, 3);

        const nups_operand = try self.operand(newclosure, 0);
        const env_operand = try self.operand(newclosure, 1);
        const child_index_operand = try self.operand(newclosure, 2);
        if (nups_operand.kind != .constant or env_operand.kind != .instruction or
            env_operand.value != newclosure_id - 1 or child_index_operand.kind != .constant or
            (try self.constant(nups_operand.value)).uintValue() != 1)
            return Error.InvalidOperandType;
        const child_index = (try self.constant(child_index_operand.value)).uintValue() orelse
            return Error.InvalidOperandType;
        const child_proto_id = try self.snapshot.protoChild(self.proto, child_index);
        const child = try self.snapshot.proto(child_proto_id);
        if (child.parent_id != self.proto.id or child.nups != 1)
            return Error.UnsupportedControlFlow;

        const pointer_destination = try self.operand(store_pointer, 0);
        const pointer_source = try self.operand(store_pointer, 1);
        const tag_destination = try self.operand(store_tag, 0);
        const tag_source = try self.operand(store_tag, 1);
        if (pointer_source.kind != .instruction or pointer_source.value != newclosure_id or
            tag_destination.kind != .vm_reg or tag_destination.value != pointer_destination.value or
            tag_source.kind != .constant or (try self.constant(tag_source.value)).tagValue() != 8)
            return Error.InvalidOperandType;
        const primary_destination = try self.vmRegisterIndex(pointer_destination);

        const captured_source = try self.operand(capture_load, 0);
        const capture_register = try self.vmRegisterIndex(captured_source);
        const address_closure = try self.operand(upvalue_address, 0);
        const address_slot = try self.operand(upvalue_address, 1);
        if (address_closure.kind != .instruction or address_closure.value != newclosure_id or
            address_slot.kind != .vm_upvalue or address_slot.value != 0)
            return Error.InvalidOperandType;
        const capture_store_destination = try self.operand(capture_store, 0);
        const capture_store_source = try self.operand(capture_store, 1);
        if (capture_store_destination.kind != .instruction or
            capture_store_destination.value != newclosure_id + 4 or
            capture_store_source.kind != .instruction or
            capture_store_source.value != newclosure_id + 3)
            return Error.InvalidOperandType;

        const capture_marker_source = try self.operand(capture, 0);
        const capture_kind = try self.operand(capture, 1);
        if (capture_marker_source.kind != .vm_reg or capture_marker_source.value != capture_register or
            capture_kind.kind != .constant or (try self.constant(capture_kind.value)).uintValue() != 0)
            return Error.InvalidOperandType;

        const copy_destination = try self.vmRegisterIndex(try self.operand(store_copy, 0));
        const copy_tag = try self.operand(store_copy, 1);
        const copy_source = try self.operand(store_copy, 2);
        if (copy_tag.kind != .constant or (try self.constant(copy_tag.value)).tagValue() != 8 or
            copy_source.kind != .instruction or copy_source.value != newclosure_id)
            return Error.InvalidOperandType;

        return .{
            .primary_destination = primary_destination,
            .copy_destination = copy_destination,
            .child_proto_id = child_proto_id,
            .capture_register = capture_register,
        };
    }

    fn valueClosurePatternAt(self: Context, instruction_id: u32, relative_to_newclosure: u32) Error!?ValueClosurePattern {
        if (instruction_id < relative_to_newclosure)
            return null;
        const newclosure_id = instruction_id - relative_to_newclosure;
        if ((try self.instruction(newclosure_id)).command != .newclosure)
            return null;
        return try self.valueClosurePattern(newclosure_id);
    }

    fn emitCopyTValueRegisters(self: Context, destination: u32, source: u32) Error!void {
        const destination_offset = destination * tvalue_size;
        const source_offset = source * tvalue_size;
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i64Load(self.allocator, 3, source_offset);
        try self.body.i64Store(self.allocator, 3, destination_offset);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i64Load(self.allocator, 3, source_offset + 8);
        try self.body.i64Store(self.allocator, 3, destination_offset + 8);
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

    fn requireCompiledTarget(self: Context, operand_value: snapshot_v1.IrOperand) Error!u32 {
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
        if (try self.valueClosurePatternAt(instruction_id, 3) != null)
            return;
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

    fn emitStoreTag(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        if (try self.valueClosurePatternAt(instruction_id, 2) != null)
            return;
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

    fn emitStoreTValue(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        if (try self.valueClosurePatternAt(instruction_id, 5) != null)
            return;
        try self.requireOperandCount(instruction_value, 2);
        const destination = try self.operand(instruction_value, 0);
        const source = try self.operand(instruction_value, 1);
        if (source.kind == .instruction) {
            const source_instruction = try self.instruction(source.value);
            if (source_instruction.command == .get_upvalue) {
                if (source.value + 1 != instruction_id)
                    return Error.UnsupportedControlFlow;
                try self.requireOperandCount(source_instruction, 1);
                const upvalue = try self.operand(source_instruction, 0);
                if (upvalue.kind != .vm_upvalue or upvalue.value != 0)
                    return Error.InvalidOperandType;

                try self.body.localGet(self.allocator, 0);
                try self.body.i32Const(self.allocator, @intCast(try self.vmRegisterIndex(destination)));
                try self.body.i32Const(self.allocator, @intCast(upvalue.value));
                try self.body.call(self.allocator, self.get_value_upvalue orelse return Error.UnsupportedCommand);
                return;
            }
        }
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

    fn emitGetValueUpvalue(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const upvalue = try self.operand(instruction_value, 0);
        if (upvalue.kind != .vm_upvalue or upvalue.value != 0 or
            instruction_id + 1 >= self.function.instruction_count)
            return Error.InvalidOperandType;
        const store = try self.instruction(instruction_id + 1);
        if (store.command != .store_tvalue or store.operand_count != 2)
            return Error.UnsupportedControlFlow;
        const store_source = try self.operand(store, 1);
        if (store_source.kind != .instruction or store_source.value != instruction_id)
            return Error.UnsupportedControlFlow;
    }

    fn emitNewClosureValue(self: Context, instruction_id: u32) Error!void {
        const pattern = try self.valueClosurePattern(instruction_id);
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.primary_destination));
        try self.body.i32Const(self.allocator, @intCast(pattern.child_proto_id));
        try self.body.i32Const(self.allocator, @intCast(pattern.capture_register));
        try self.body.call(self.allocator, self.newclosure_value orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
        try self.emitCopyTValueRegisters(pattern.copy_destination, pattern.primary_destination);
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
        try self.body.i32Ne(self.allocator);
        try self.body.ifVoid(self.allocator);
        switch (failure.kind) {
            .block => {
                const target_block = try self.snapshot.irBlock(self.function, failure.value);
                if (target_block.kind == .fallback and !try self.supportsArithmeticFallback(target_block)) {
                    // Preserve the existing numeric tier for fallback shapes that have not been
                    // normalized yet. A guard hit fails through the explicit status boundary; the
                    // unsupported fallback instructions are never emitted or accidentally entered.
                    try self.emitStatusReturn(status_unsupported_type);
                } else {
                    const target = if (target_block.kind == .fallback)
                        failure.value
                    else
                        try self.requireCompiledTarget(failure);
                    try self.body.i32Const(self.allocator, @intCast(target));
                    try self.body.localSet(self.allocator, self.dispatch_local);
                    // CHECK_TAG's conditional is nested inside the selected-block conditional.
                    try self.body.branch(self.allocator, 2);
                }
            },
            .vm_exit => try self.emitStatusReturn(status_unsupported_type),
            else => return Error.InvalidOperandType,
        }
        try self.body.end(self.allocator);
    }

    fn savedPc(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!u32 {
        try self.requireOperandCount(instruction_value, 1);
        const operand_value = try self.operand(instruction_value, 0);
        if (operand_value.kind != .constant)
            return Error.InvalidOperandType;
        return (try self.constant(operand_value.value)).uintValue() orelse Error.InvalidOperandType;
    }

    fn emitDoArith(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 4);
        if (instruction_id == 0)
            return Error.UnsupportedControlFlow;

        // Upstream fallback streams establish the bytecode/source location immediately before the
        // semantic helper. Strict AOT has no bytecode PC pointer, so this first slice validates the
        // marker as part of the rewrite instead of fabricating CallInfo::savedpc. WP5 will map the
        // validated integer to AOT traceback metadata.
        const location_marker = try self.instruction(instruction_id - 1);
        if (location_marker.command != .set_savedpc)
            return Error.UnsupportedControlFlow;
        _ = try self.savedPc(location_marker);

        const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
        const lhs = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
        const rhs = try self.vmRegisterIndex(try self.operand(instruction_value, 2));
        const operation_operand = try self.operand(instruction_value, 3);
        if (operation_operand.kind != .constant)
            return Error.InvalidOperandType;
        const upstream_operation = (try self.constant(operation_operand.value)).intValue() orelse return Error.InvalidOperandType;
        if (upstream_operation != upstream_tm_add)
            return Error.UnsupportedCommand;

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(destination));
        try self.body.i32Const(self.allocator, @intCast(lhs));
        try self.body.i32Const(self.allocator, @intCast(rhs));
        try self.body.i32Const(self.allocator, aot_arith_add);
        try self.body.call(self.allocator, self.do_arith orelse return Error.UnsupportedCommand);
        // Generic arithmetic may allocate, invoke a metamethod, and relocate the stack.
        try self.emitReloadBase();
    }

    fn supportsArithmeticFallback(self: Context, block: snapshot_v1.IrBlock) Error!bool {
        if (block.kind != .fallback or block.isEmpty() or block.finish - block.start != 2)
            return false;
        const marker = try self.instruction(block.start);
        const arithmetic = try self.instruction(block.start + 1);
        const jump = try self.instruction(block.start + 2);
        if (marker.command != .set_savedpc or arithmetic.command != .do_arith or jump.command != .jump or
            marker.operand_count != 1 or arithmetic.operand_count != 4 or jump.operand_count != 1)
            return false;

        const marker_operand = try self.operand(marker, 0);
        const destination = try self.operand(arithmetic, 0);
        const lhs = try self.operand(arithmetic, 1);
        const rhs = try self.operand(arithmetic, 2);
        const operation = try self.operand(arithmetic, 3);
        const jump_target = try self.operand(jump, 0);
        if (marker_operand.kind != .constant or destination.kind != .vm_reg or lhs.kind != .vm_reg or rhs.kind != .vm_reg or
            operation.kind != .constant or jump_target.kind != .block)
            return false;
        if ((try self.constant(marker_operand.value)).uintValue() == null or
            (try self.constant(operation.value)).intValue() != upstream_tm_add)
            return false;
        if (destination.value >= self.proto.max_stack_size or lhs.value >= self.proto.max_stack_size or rhs.value >= self.proto.max_stack_size)
            return false;

        const target = try self.snapshot.irBlock(self.function, jump_target.value);
        return target.kind.isCompilable() and !target.isEmpty();
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
        const target = try self.requireCompiledTarget(try self.operand(instruction_value, 0));
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
        const true_target = try self.requireCompiledTarget(try self.operand(instruction_value, 3));
        const false_target = try self.requireCompiledTarget(try self.operand(instruction_value, 4));

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
        if (return_count != 1 and return_count != 2)
            return Error.InvalidReturnCount;

        const source_register = try self.vmRegisterIndex(source);
        if (@as(u32, @intCast(return_count)) > @as(u32, self.proto.max_stack_size) - source_register)
            return Error.InvalidReturnCount;

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(source_register));
        try self.body.i32Const(self.allocator, @intCast(return_count));
        try self.body.call(self.allocator, self.return_fixed);
        try self.emitStatusReturn(status_ok);
    }

    fn emitDupClosure(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        const pc_operand = try self.operand(instruction_value, 0);
        const destination = try self.operand(instruction_value, 1);
        const constant_operand = try self.operand(instruction_value, 2);
        if (pc_operand.kind != .constant or constant_operand.kind != .vm_const)
            return Error.InvalidOperandType;
        _ = (try self.constant(pc_operand.value)).uintValue() orelse return Error.InvalidOperandType;
        const destination_register = try self.vmRegisterIndex(destination);
        const child_id = (try self.snapshot.vmConstant(self.proto, constant_operand.value)).closureProtoId() orelse
            return Error.InvalidOperandType;
        const child = try self.snapshot.proto(child_id);
        if (child.parent_id != self.proto.id or child.nups != 0)
            return Error.UnsupportedControlFlow;

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(destination_register));
        try self.body.i32Const(self.allocator, @intCast(child_id));
        try self.body.call(self.allocator, self.dupclosure orelse return Error.UnsupportedCommand);
        // Closure allocation runs GC and can relocate the active stack.
        try self.emitReloadBase();
    }

    fn emitCallFixed(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        if (instruction_id == 0 or (try self.instruction(instruction_id - 1)).command != .set_savedpc)
            return Error.UnsupportedControlFlow;
        _ = try self.savedPc(try self.instruction(instruction_id - 1));

        const function_register = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
        const parameter_operand = try self.operand(instruction_value, 1);
        const result_operand = try self.operand(instruction_value, 2);
        if (parameter_operand.kind != .constant or result_operand.kind != .constant)
            return Error.InvalidOperandType;
        const parameter_count = (try self.constant(parameter_operand.value)).intValue() orelse return Error.InvalidOperandType;
        const result_count = (try self.constant(result_operand.value)).intValue() orelse return Error.InvalidOperandType;
        if ((parameter_count != 1 and parameter_count != 2) or
            (result_count != 1 and result_count != 2))
            return Error.UnsupportedControlFlow;
        const parameter_count_u32: u32 = @intCast(parameter_count);
        const result_count_u32: u32 = @intCast(result_count);
        if (parameter_count_u32 >= @as(u32, self.proto.max_stack_size) - function_register or
            result_count_u32 > @as(u32, self.proto.max_stack_size) - function_register)
            return Error.UnsupportedControlFlow;

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(function_register));
        try self.body.i32Const(self.allocator, parameter_count);
        try self.body.i32Const(self.allocator, result_count);
        try self.body.call(self.allocator, self.call_fixed orelse return Error.UnsupportedCommand);
        try self.body.localTee(self.allocator, self.status_local);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.emitReloadBase();
        try self.body.else_(self.allocator);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.return_(self.allocator);
        try self.body.end(self.allocator);
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

    fn emitInstruction(self: Context, instruction_id: u32, block_kind: snapshot_v1.IrBlockKind) Error!bool {
        const instruction_value = try self.instruction(instruction_id);
        switch (instruction_value.command) {
            .nop, .mark_used => return false,
            .load_env => {
                if (instruction_id + 1 >= self.function.instruction_count or
                    (try self.instruction(instruction_id + 1)).command != .newclosure)
                    return Error.UnsupportedControlFlow;
                _ = try self.valueClosurePattern(instruction_id + 1);
            },
            .get_closure_upval_addr => {
                if (try self.valueClosurePatternAt(instruction_id, 4) == null)
                    return Error.UnsupportedControlFlow;
            },
            .load_tag => try self.emitLoadTag(instruction_id, instruction_value),
            .load_double => try self.emitLoadDouble(instruction_id, instruction_value),
            .load_tvalue => try self.emitLoadTValue(instruction_id, instruction_value),
            .store_pointer => {
                if (try self.valueClosurePatternAt(instruction_id, 1) == null)
                    return Error.UnsupportedControlFlow;
            },
            .store_tag => try self.emitStoreTag(instruction_id, instruction_value),
            .store_split_tvalue => {
                if (try self.valueClosurePatternAt(instruction_id, 9) == null)
                    return Error.UnsupportedControlFlow;
            },
            .store_double => try self.emitStoreDouble(instruction_value),
            .store_tvalue => try self.emitStoreTValue(instruction_id, instruction_value),
            .add_num => try self.emitAddNumber(instruction_id, instruction_value),
            .get_upvalue => try self.emitGetValueUpvalue(instruction_id, instruction_value),
            .check_tag => try self.emitCheckTag(instruction_value),
            .check_gc => {
                if (try self.valueClosurePatternAt(instruction_id, 6) == null)
                    return Error.UnsupportedControlFlow;
            },
            .set_savedpc => {
                _ = try self.savedPc(instruction_value);
                if (block_kind != .fallback) {
                    if (!block_kind.isCompilable())
                        return Error.UnsupportedControlFlow;
                    if (instruction_id + 2 < self.function.instruction_count and
                        (try self.instruction(instruction_id + 2)).command == .newclosure)
                        _ = try self.valueClosurePattern(instruction_id + 2)
                    else if (instruction_id + 1 >= self.function.instruction_count or
                        (try self.instruction(instruction_id + 1)).command != .call)
                        return Error.UnsupportedControlFlow;
                }
            },
            .capture => {
                if (try self.valueClosurePatternAt(instruction_id, 7) == null)
                    return Error.UnsupportedControlFlow;
            },
            .do_arith => {
                if (block_kind != .fallback)
                    return Error.UnsupportedControlFlow;
                try self.emitDoArith(instruction_id, instruction_value);
            },
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
            .call => try self.emitCallFixed(instruction_id, instruction_value),
            .fallback_prepvarargs => try self.emitPrepVarargsNoop(instruction_value),
            .newclosure => try self.emitNewClosureValue(instruction_id),
            .fallback_dupclosure => try self.emitDupClosure(instruction_value),
            else => return Error.UnsupportedCommand,
        }
        return false;
    }

    fn emitBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock) Error!void {
        if (block.kind == .fallback and !try self.supportsArithmeticFallback(block))
            return Error.UnsupportedControlFlow;

        try self.body.localGet(self.allocator, self.dispatch_local);
        try self.body.i32Const(self.allocator, @intCast(block_id));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);

        var terminated = false;
        var instruction_id = block.start;
        while (instruction_id <= block.finish) : (instruction_id += 1) {
            if (terminated)
                return Error.InvalidBlockTermination;
            terminated = try self.emitInstruction(instruction_id, block.kind);
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

const ImportNeeds = struct {
    do_arith: bool = false,
    dupclosure: bool = false,
    newclosure_value: bool = false,
    get_value_upvalue: bool = false,
    call_fixed: bool = false,
};

const RuntimeImports = struct {
    return_fixed: wasm.FunctionRef,
    interrupt: wasm.FunctionRef,
    do_arith: ?wasm.FunctionRef,
    dupclosure: ?wasm.FunctionRef,
    newclosure_value: ?wasm.FunctionRef,
    get_value_upvalue: ?wasm.FunctionRef,
    call_fixed: ?wasm.FunctionRef,
    generated_type: u32,
};

fn scanImportNeeds(snapshot: snapshot_v1.Snapshot, function_id: u32, needs: *ImportNeeds) Error!void {
    const function = try snapshot.irFunction(function_id);
    var instruction_id: u32 = 0;
    while (instruction_id < function.instruction_count) : (instruction_id += 1) {
        switch ((try snapshot.irInstruction(function, instruction_id)).command) {
            .do_arith => needs.do_arith = true,
            .fallback_dupclosure => needs.dupclosure = true,
            .newclosure => needs.newclosure_value = true,
            .get_upvalue => needs.get_value_upvalue = true,
            .call => needs.call_fixed = true,
            else => {},
        }
    }
}

fn addRuntimeImports(object: *wasm.Object, needs: ImportNeeds) Error!RuntimeImports {
    const return_fixed_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const interrupt_params = [_]wasm.ValueType{ .i32, .i32 };
    const do_arith_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32, .i32 };
    const dupclosure_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const newclosure_value_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const get_value_upvalue_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const call_fixed_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const generated_params = [_]wasm.ValueType{ .i32, .i32 };
    const no_results = [_]wasm.ValueType{};
    const status_result = [_]wasm.ValueType{.i32};

    const return_fixed_type = try object.addType(.{ .params = &return_fixed_params, .results = &no_results });
    const interrupt_type = try object.addType(.{ .params = &interrupt_params, .results = &status_result });
    const generated_type = try object.addType(.{ .params = &generated_params, .results = &status_result });
    const return_fixed = try object.importFunction("env", return_fixed_symbol, return_fixed_type);
    const interrupt = try object.importFunction("env", interrupt_symbol, interrupt_type);
    const do_arith = if (needs.do_arith) blk: {
        const helper_type = try object.addType(.{ .params = &do_arith_params, .results = &no_results });
        break :blk try object.importFunction("env", do_arith_symbol, helper_type);
    } else null;
    const dupclosure = if (needs.dupclosure) blk: {
        const helper_type = try object.addType(.{ .params = &dupclosure_params, .results = &no_results });
        break :blk try object.importFunction("env", dupclosure_symbol, helper_type);
    } else null;
    const newclosure_value = if (needs.newclosure_value) blk: {
        const helper_type = try object.addType(.{ .params = &newclosure_value_params, .results = &no_results });
        break :blk try object.importFunction("env", newclosure_value_symbol, helper_type);
    } else null;
    const get_value_upvalue = if (needs.get_value_upvalue) blk: {
        const helper_type = try object.addType(.{ .params = &get_value_upvalue_params, .results = &no_results });
        break :blk try object.importFunction("env", get_value_upvalue_symbol, helper_type);
    } else null;
    const call_fixed = if (needs.call_fixed) blk: {
        const helper_type = try object.addType(.{ .params = &call_fixed_params, .results = &status_result });
        break :blk try object.importFunction("env", call_fixed_symbol, helper_type);
    } else null;

    return .{
        .return_fixed = return_fixed,
        .interrupt = interrupt,
        .do_arith = do_arith,
        .dupclosure = dupclosure,
        .newclosure_value = newclosure_value,
        .get_value_upvalue = get_value_upvalue,
        .call_fixed = call_fixed,
        .generated_type = generated_type,
    };
}

fn lowerFunction(
    allocator: std.mem.Allocator,
    snapshot: snapshot_v1.Snapshot,
    function_id: u32,
    object: *wasm.Object,
    imports: RuntimeImports,
    symbol_name: []const u8,
) Error!void {
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

    var body = try wasm.Body.init(allocator, locals.items);
    defer body.deinit(allocator);
    var context = Context{
        .allocator = allocator,
        .snapshot = snapshot,
        .proto = proto,
        .function = function,
        .slots = slots,
        .body = &body,
        .return_fixed = imports.return_fixed,
        .interrupt = imports.interrupt,
        .do_arith = imports.do_arith,
        .dupclosure = imports.dupclosure,
        .newclosure_value = imports.newclosure_value,
        .get_value_upvalue = imports.get_value_upvalue,
        .call_fixed = imports.call_fixed,
        .base_local = 2,
        .dispatch_local = 3,
        .status_local = 4,
    };

    var block_id: u32 = 0;
    while (block_id < function.block_count) : (block_id += 1) {
        const block = try snapshot.irBlock(function, block_id);
        if (block.kind == .fallback and try context.supportsArithmeticFallback(block)) {
            if (context.do_arith == null)
                return Error.UnsupportedCommand;
            break;
        }
    }

    try context.emitReloadBase();
    try body.i32Const(allocator, @intCast(function.entry_block));
    try body.localSet(allocator, context.dispatch_local);
    try body.loop(allocator);

    block_id = 0;
    while (block_id < function.block_count) : (block_id += 1) {
        const block = try snapshot.irBlock(function, block_id);
        if (block.kind.isCompilable() and !block.isEmpty())
            try context.emitBlock(block_id, block)
        else if (block.kind == .fallback and try context.supportsArithmeticFallback(block))
            try context.emitBlock(block_id, block);
    }

    // Reaching the bottom means a malformed/generated dispatch target escaped static validation.
    try context.emitStatusReturn(status_internal_error);
    try body.end(allocator);
    try body.i32Const(allocator, status_internal_error);
    try body.finish(allocator);

    _ = try object.defineFunction(symbol_name, imports.generated_type, wasm.symbol.visibility_hidden, body);
}

pub fn build(allocator: std.mem.Allocator, snapshot_bytes: []const u8, function_id: u32) Error![]u8 {
    const snapshot = try snapshot_v1.parse(snapshot_bytes, snapshot_v1.production_identity);
    try snapshot_v1.validateModel(snapshot);
    if (function_id >= snapshot.header.ir_function_count)
        return Error.FunctionOutOfBounds;

    var needs = ImportNeeds{};
    try scanImportNeeds(snapshot, function_id, &needs);
    var object = wasm.Object.init(allocator);
    defer object.deinit();
    const imports = try addRuntimeImports(&object, needs);
    try lowerFunction(allocator, snapshot, function_id, &object, imports, generated_symbol);
    return object.emit();
}

pub fn buildPackage(allocator: std.mem.Allocator, snapshot_bytes: []const u8) Error![]u8 {
    const snapshot = try snapshot_v1.parse(snapshot_bytes, snapshot_v1.production_identity);
    try snapshot_v1.validateModel(snapshot);

    var needs = ImportNeeds{};
    var function_id: u32 = 0;
    while (function_id < snapshot.header.ir_function_count) : (function_id += 1)
        try scanImportNeeds(snapshot, function_id, &needs);

    var object = wasm.Object.init(allocator);
    defer object.deinit();
    const imports = try addRuntimeImports(&object, needs);

    function_id = 0;
    while (function_id < snapshot.header.ir_function_count) : (function_id += 1) {
        const symbol_name = try std.fmt.allocPrint(allocator, "mc_luau_aot_v1_function_{d:0>8}", .{function_id});
        defer allocator.free(symbol_name);
        try lowerFunction(allocator, snapshot, function_id, &object, imports, symbol_name);
    }
    return object.emit();
}
