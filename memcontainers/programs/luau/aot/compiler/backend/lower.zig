const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luau_aot_wasm_object");

pub const generated_symbol = "mc_luau_aot_v1_generated_ir_function";
pub const return_symbol = "mc_luau_aot_v1_return";
pub const interrupt_symbol = "mc_luau_aot_v1_interrupt";
pub const do_arith_symbol = "mc_luau_aot_v1_do_arith";
pub const compare_any_symbol = "mc_luau_aot_v1_compare_any";
pub const dupclosure_symbol = "mc_luau_aot_v1_dupclosure";
pub const newclosure_value_symbol = "mc_luau_aot_v1_newclosure_value";
pub const newclosure_ref_symbol = "mc_luau_aot_v1_newclosure_ref";
pub const get_upvalue_symbol = "mc_luau_aot_v1_get_upvalue";
pub const set_upvalue_symbol = "mc_luau_aot_v1_set_upvalue";
pub const close_upvalues_symbol = "mc_luau_aot_v1_close_upvalues";
pub const call_symbol = "mc_luau_aot_v1_call";
pub const prep_varargs_symbol = "mc_luau_aot_v1_prep_varargs";
pub const get_varargs_fixed_symbol = "mc_luau_aot_v1_get_varargs_fixed";
pub const get_varargs_multret_symbol = "mc_luau_aot_v1_get_varargs_multret";

const status_ok: i32 = 0;
const status_unsupported_type: i32 = 1;
const status_internal_error: i32 = 2;

const lua_state_base_offset: u32 = 12;
const tvalue_size: u32 = 16;
const tvalue_extra_offset: u32 = 8;
const tvalue_tag_offset: u32 = 12;
const lua_tag_nil: i32 = 0;
const lua_tag_boolean: i32 = 1;
const lua_tag_number: u8 = 3;
const lua_tag_integer: u8 = 4;
const lua_tag_vector: i64 = 5;
const lua_tag_string: u8 = 6;
const vector_lane_count: u32 = 3;
const tvalue_lane_count: u32 = 4;
const round_number_bias: f64 = @bitCast(@as(u64, 0x3fdf_ffff_ffff_ffff));
const upstream_tm_add: i32 = 8;
const upstream_tm_unm: i32 = 15;
const max_lowered_locals: u32 = 262_144;

fn aotArithmeticOperation(upstream_operation: i32) ?i32 {
    if (upstream_operation < upstream_tm_add or upstream_operation > upstream_tm_unm)
        return null;
    return upstream_operation - upstream_tm_add;
}

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
    pointer,
    i64,
    f32,
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

const ReferenceClosurePattern = struct {
    destination: u32,
    child_proto_id: u32,
    capture_register: u32,
};

const SetUpvaluePattern = struct {
    upvalue_index: u32,
    source_register: u32,
};

const Context = struct {
    allocator: std.mem.Allocator,
    snapshot: snapshot_v1.Snapshot,
    proto: snapshot_v1.Proto,
    function: snapshot_v1.IrFunction,
    slots: []const ValueSlot,
    body: *wasm.Body,
    return_: wasm.FunctionRef,
    interrupt: wasm.FunctionRef,
    do_arith: ?wasm.FunctionRef,
    compare_any: ?wasm.FunctionRef,
    dupclosure: ?wasm.FunctionRef,
    newclosure_value: ?wasm.FunctionRef,
    newclosure_ref: ?wasm.FunctionRef,
    get_upvalue: ?wasm.FunctionRef,
    set_upvalue: ?wasm.FunctionRef,
    close_upvalues: ?wasm.FunctionRef,
    call: ?wasm.FunctionRef,
    prep_varargs: ?wasm.FunctionRef,
    get_varargs_fixed: ?wasm.FunctionRef,
    get_varargs_multret: ?wasm.FunctionRef,
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

    fn requireSingleCompilableBlockRange(self: Context, start: u32, finish: u32) Error!void {
        var owner: ?u32 = null;
        var block_id: u32 = 0;
        while (block_id < self.function.block_count) : (block_id += 1) {
            const block = try self.snapshot.irBlock(self.function, block_id);
            if (block.isEmpty() or block.finish < start or block.start > finish)
                continue;
            if (owner != null or !block.kind.isCompilable() or block.start > start or block.finish < finish)
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
        if (newclosure_id + 3 < self.function.instruction_count and
            (try self.instruction(newclosure_id + 3)).command == .findupval)
            return null;
        return try self.valueClosurePattern(newclosure_id);
    }

    fn referenceClosurePattern(self: Context, newclosure_id: u32) Error!ReferenceClosurePattern {
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
        const find_upvalue = try self.instruction(newclosure_id + 3);
        const upvalue_address = try self.instruction(newclosure_id + 4);
        const store_upvalue_pointer = try self.instruction(newclosure_id + 5);
        const store_upvalue_tag = try self.instruction(newclosure_id + 6);
        const check_gc = try self.instruction(newclosure_id + 7);
        const capture = try self.instruction(newclosure_id + 8);
        const close_upvalues = try self.instruction(newclosure_id + 9);

        if (marker.command != .set_savedpc or load_env.command != .load_env or
            newclosure.command != .newclosure or store_pointer.command != .store_pointer or
            store_tag.command != .store_tag or find_upvalue.command != .findupval or
            upvalue_address.command != .get_closure_upval_addr or
            store_upvalue_pointer.command != .store_pointer or
            store_upvalue_tag.command != .store_tag or check_gc.command != .check_gc or
            capture.command != .capture or close_upvalues.command != .close_upvals)
            return Error.UnsupportedControlFlow;
        _ = try self.savedPc(marker);
        try self.requireOperandCount(load_env, 0);
        try self.requireOperandCount(newclosure, 3);
        try self.requireOperandCount(store_pointer, 2);
        try self.requireOperandCount(store_tag, 2);
        try self.requireOperandCount(find_upvalue, 1);
        try self.requireOperandCount(upvalue_address, 2);
        try self.requireOperandCount(store_upvalue_pointer, 2);
        try self.requireOperandCount(store_upvalue_tag, 2);
        try self.requireOperandCount(check_gc, 0);
        try self.requireOperandCount(capture, 2);
        try self.requireOperandCount(close_upvalues, 1);

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
        const destination = try self.vmRegisterIndex(pointer_destination);

        const find_source = try self.operand(find_upvalue, 0);
        const capture_register = try self.vmRegisterIndex(find_source);
        if (destination == capture_register)
            return Error.UnsupportedControlFlow;
        const address_closure = try self.operand(upvalue_address, 0);
        const address_slot = try self.operand(upvalue_address, 1);
        if (address_closure.kind != .instruction or address_closure.value != newclosure_id or
            address_slot.kind != .vm_upvalue or address_slot.value != 0)
            return Error.InvalidOperandType;

        const upvalue_pointer_destination = try self.operand(store_upvalue_pointer, 0);
        const upvalue_pointer_source = try self.operand(store_upvalue_pointer, 1);
        if (upvalue_pointer_destination.kind != .instruction or
            upvalue_pointer_destination.value != newclosure_id + 4 or
            upvalue_pointer_source.kind != .instruction or
            upvalue_pointer_source.value != newclosure_id + 3)
            return Error.InvalidOperandType;
        const upvalue_tag_destination = try self.operand(store_upvalue_tag, 0);
        const upvalue_tag_source = try self.operand(store_upvalue_tag, 1);
        if (upvalue_tag_destination.kind != .instruction or
            upvalue_tag_destination.value != newclosure_id + 4 or
            upvalue_tag_source.kind != .constant or
            (try self.constant(upvalue_tag_source.value)).tagValue() != 16)
            return Error.InvalidOperandType;

        const capture_source = try self.operand(capture, 0);
        const capture_kind = try self.operand(capture, 1);
        const close_source = try self.operand(close_upvalues, 0);
        if (capture_source.kind != .vm_reg or capture_source.value != capture_register or
            capture_kind.kind != .constant or (try self.constant(capture_kind.value)).uintValue() != 1 or
            close_source.kind != .vm_reg or close_source.value != capture_register)
            return Error.InvalidOperandType;

        return .{
            .destination = destination,
            .child_proto_id = child_proto_id,
            .capture_register = capture_register,
        };
    }

    fn referenceClosurePatternAt(self: Context, instruction_id: u32, relative_to_newclosure: u32) Error!?ReferenceClosurePattern {
        if (instruction_id < relative_to_newclosure)
            return null;
        const newclosure_id = instruction_id - relative_to_newclosure;
        if ((try self.instruction(newclosure_id)).command != .newclosure)
            return null;
        if (newclosure_id + 3 >= self.function.instruction_count or
            (try self.instruction(newclosure_id + 3)).command != .findupval)
            return null;
        return try self.referenceClosurePattern(newclosure_id);
    }

    fn setUpvaluePattern(self: Context, instruction_id: u32) Error!SetUpvaluePattern {
        if (instruction_id == 0)
            return Error.UnsupportedControlFlow;
        try self.requireSingleCompilableBlockRange(instruction_id - 1, instruction_id);
        const load = try self.instruction(instruction_id - 1);
        const set = try self.instruction(instruction_id);
        if (load.command != .load_tvalue or set.command != .set_upvalue)
            return Error.UnsupportedControlFlow;
        try self.requireOperandCount(load, 1);
        try self.requireOperandCount(set, 3);
        const source_register = try self.vmRegisterIndex(try self.operand(load, 0));
        const upvalue = try self.operand(set, 0);
        const value = try self.operand(set, 1);
        const tag = try self.operand(set, 2);
        if (upvalue.kind != .vm_upvalue or upvalue.value != 0 or
            value.kind != .instruction or value.value != instruction_id - 1 or
            tag.kind != .undef or tag.value != 0)
            return Error.InvalidOperandType;
        return .{ .upvalue_index = upvalue.value, .source_register = source_register };
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

    fn emitPointerValue(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        switch (operand_value.kind) {
            .constant => {
                const value = try self.constant(operand_value.value);
                const integer = value.intValue() orelse return Error.InvalidOperandType;
                if (integer != 0)
                    return Error.InvalidOperandType;
                try self.body.i32Const(self.allocator, 0);
            },
            .instruction => {
                if (operand_value.value >= self.slots.len)
                    return Error.InvalidInstructionResult;
                const slot = self.slots[operand_value.value];
                if (slot.shape != .pointer)
                    return Error.InvalidInstructionResult;
                try self.body.localGet(self.allocator, slot.first);
            },
            else => return Error.UnsupportedOperand,
        }
    }

    fn vmConstantTag(self: Context, operand_value: snapshot_v1.IrOperand) Error!i32 {
        if (operand_value.kind != .vm_const)
            return Error.InvalidOperandType;
        const value = try self.snapshot.vmConstant(self.proto, operand_value.value);
        return switch (value.kind) {
            .nil => lua_tag_nil,
            .boolean => lua_tag_boolean,
            .number => lua_tag_number,
            .integer => lua_tag_integer,
            .vector => @intCast(lua_tag_vector),
            .string => lua_tag_string,
            .table => 7,
            .closure => 8,
            .class_shape => 12,
            // Imports are resolved while loading bytecode and have no statically known tag.
            .import => return Error.UnsupportedOperand,
        };
    }

    const VmConstantParts = struct {
        low: u64,
        high: u64,
    };

    fn vmConstantParts(self: Context, operand_value: snapshot_v1.IrOperand) Error!VmConstantParts {
        if (operand_value.kind != .vm_const)
            return Error.InvalidOperandType;
        const value = try self.snapshot.vmConstant(self.proto, operand_value.value);
        const tag: u64 = @intCast(try self.vmConstantTag(operand_value));
        const low: u64 = switch (value.kind) {
            .nil => 0,
            .boolean => value.payload0,
            .number, .integer => value.bits0,
            .vector => @as(u64, value.payload0) | (@as(u64, value.payload1) << 32),
            // The snapshot deliberately contains stable IDs instead of runtime GC pointers.
            .string, .import, .table, .closure, .class_shape => return Error.UnsupportedOperand,
        };
        const extra: u64 = switch (value.kind) {
            .vector => value.payload2,
            else => 0,
        };
        return .{ .low = low, .high = extra | (tag << 32) };
    }

    fn emitTValueAddress(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        switch (operand_value.kind) {
            .vm_reg => {
                _ = try self.vmRegisterIndex(operand_value);
                try self.body.localGet(self.allocator, self.base_local);
            },
            .instruction => try self.emitPointerValue(operand_value),
            else => return Error.UnsupportedOperand,
        }
    }

    fn tvalueByteOffset(self: Context, instruction_value: snapshot_v1.IrInstruction, operand_index: u32) Error!u32 {
        const offset_operand = try self.operand(instruction_value, operand_index);
        if (offset_operand.kind != .constant)
            return Error.InvalidOperandType;
        const offset = (try self.constant(offset_operand.value)).intValue() orelse return Error.InvalidOperandType;
        if (offset < 0 or @mod(offset, 4) != 0 or offset > 4092)
            return Error.InvalidOperandType;
        return @intCast(offset);
    }

    fn emitI64Value(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        switch (operand_value.kind) {
            .constant => {
                const value = try self.constant(operand_value.value);
                try self.body.i64Const(self.allocator, value.int64Value() orelse return Error.InvalidOperandType);
            },
            .instruction => {
                if (operand_value.value >= self.slots.len)
                    return Error.InvalidInstructionResult;
                const slot = self.slots[operand_value.value];
                if (slot.shape != .i64)
                    return Error.InvalidInstructionResult;
                try self.body.localGet(self.allocator, slot.first);
            },
            else => return Error.UnsupportedOperand,
        }
    }

    fn emitF32Value(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        switch (operand_value.kind) {
            .constant => {
                const value = try self.constant(operand_value.value);
                try self.body.f32Const(self.allocator, @floatCast(value.doubleValue() orelse return Error.InvalidOperandType));
            },
            .instruction => {
                if (operand_value.value >= self.slots.len)
                    return Error.InvalidInstructionResult;
                const slot = self.slots[operand_value.value];
                if (slot.shape != .f32)
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

    fn emitTagValue(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        if (operand_value.kind == .vm_reg) {
            try self.body.localGet(self.allocator, self.base_local);
            try self.body.i32Load(self.allocator, 2, try self.vmRegisterOffset(operand_value, tvalue_tag_offset));
        } else {
            try self.emitI32Value(operand_value);
        }
    }

    fn tvalueSlot(self: Context, operand_value: snapshot_v1.IrOperand) Error!ValueSlot {
        if (operand_value.kind != .instruction or operand_value.value >= self.slots.len)
            return Error.InvalidOperandType;
        const slot = self.slots[operand_value.value];
        if (slot.shape != .tvalue)
            return Error.InvalidInstructionResult;
        return slot;
    }

    fn emitTValuePart(self: Context, operand_value: snapshot_v1.IrOperand, high: bool) Error!void {
        switch (operand_value.kind) {
            .vm_reg => {
                try self.body.localGet(self.allocator, self.base_local);
                const offset = try self.vmRegisterOffset(operand_value, if (high) 8 else 0);
                try self.body.i64Load(self.allocator, 3, offset);
            },
            .instruction => {
                const slot = try self.tvalueSlot(operand_value);
                try self.body.localGet(self.allocator, if (high) slot.second else slot.first);
            },
            else => return Error.UnsupportedOperand,
        }
    }

    fn emitTValueTag(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        if (operand_value.kind == .vm_reg) {
            try self.emitTagValue(operand_value);
            return;
        }

        try self.emitTValuePart(operand_value, true);
        try self.body.i64Const(self.allocator, 32);
        try self.body.opcode(self.allocator, 0x88); // i64.shr_u
        try self.body.opcode(self.allocator, 0xa7); // i32.wrap_i64
    }

    fn emitTValuePayloadI32(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        if (operand_value.kind == .vm_reg) {
            try self.body.localGet(self.allocator, self.base_local);
            try self.body.i32Load(self.allocator, 2, try self.vmRegisterOffset(operand_value, 0));
            return;
        }

        try self.emitTValuePart(operand_value, false);
        try self.body.opcode(self.allocator, 0xa7); // i32.wrap_i64
    }

    fn emitTValueTruthy(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        try self.emitTValueTag(operand_value);
        try self.body.i32Const(self.allocator, lua_tag_nil);
        try self.body.i32Ne(self.allocator);

        try self.emitTValueTag(operand_value);
        try self.body.i32Const(self.allocator, lua_tag_boolean);
        try self.body.i32Ne(self.allocator);
        try self.emitTValuePayloadI32(operand_value);
        try self.body.i32Eqz(self.allocator);
        try self.body.i32Eqz(self.allocator);
        try self.body.opcode(self.allocator, 0x72); // i32.or
        try self.body.opcode(self.allocator, 0x71); // i32.and
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
        if (source.kind == .vm_const) {
            try self.body.i32Const(self.allocator, try self.vmConstantTag(source));
        } else {
            try self.emitTValueAddress(source);
            const offset = if (source.kind == .vm_reg)
                try self.vmRegisterOffset(source, tvalue_tag_offset)
            else
                tvalue_tag_offset;
            try self.body.i32Load(self.allocator, 2, offset);
        }
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitLoadI32(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const source = try self.operand(instruction_value, 0);
        if (instruction_value.command == .load_pointer) {
            if (source.kind == .vm_const) {
                try self.body.i32Const(self.allocator, @bitCast(@as(u32, @truncate((try self.vmConstantParts(source)).low))));
            } else {
                try self.emitTValueAddress(source);
                const offset = if (source.kind == .vm_reg) try self.vmRegisterOffset(source, 0) else 0;
                try self.body.i32Load(self.allocator, 2, offset);
            }
        } else {
            if (source.kind != .vm_reg)
                return Error.UnsupportedOperand;
            try self.body.localGet(self.allocator, self.base_local);
            try self.body.i32Load(self.allocator, 2, try self.vmRegisterOffset(source, 0));
        }
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitLoadI64(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const source = try self.operand(instruction_value, 0);
        if (source.kind == .vm_const) {
            try self.body.i64Const(self.allocator, @bitCast((try self.vmConstantParts(source)).low));
        } else {
            try self.emitTValueAddress(source);
            const offset = if (source.kind == .vm_reg) try self.vmRegisterOffset(source, 0) else 0;
            try self.body.i64Load(self.allocator, 3, offset);
        }
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitLoadFloat(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const source = try self.operand(instruction_value, 0);
        const offset_operand = try self.operand(instruction_value, 1);
        if (offset_operand.kind != .constant)
            return Error.InvalidOperandType;
        const offset = (try self.constant(offset_operand.value)).intValue() orelse return Error.InvalidOperandType;
        if (offset < 0 or offset > 8 or @mod(offset, 4) != 0)
            return Error.InvalidOperandType;
        if (source.kind == .vm_const) {
            const parts = try self.vmConstantParts(source);
            const bits: u32 = switch (offset) {
                0 => @truncate(parts.low),
                4 => @truncate(parts.low >> 32),
                8 => @truncate(parts.high),
                else => unreachable,
            };
            try self.body.f32Const(self.allocator, @bitCast(bits));
        } else {
            try self.emitTValueAddress(source);
            const address_offset = if (source.kind == .vm_reg)
                try self.vmRegisterOffset(source, @intCast(offset))
            else
                @as(u32, @intCast(offset));
            try self.body.f32Load(self.allocator, 2, address_offset);
        }
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitLoadDouble(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const source = try self.operand(instruction_value, 0);
        if (source.kind == .vm_const) {
            try self.body.f64Const(self.allocator, @bitCast((try self.vmConstantParts(source)).low));
        } else {
            try self.emitTValueAddress(source);
            const offset = if (source.kind == .vm_reg) try self.vmRegisterOffset(source, 0) else 0;
            try self.body.f64Load(self.allocator, 3, offset);
        }
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitLoadTValue(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        if (try self.valueClosurePatternAt(instruction_id, 3) != null)
            return;
        if (instruction_id + 1 < self.function.instruction_count and
            (try self.instruction(instruction_id + 1)).command == .set_upvalue)
        {
            _ = try self.setUpvaluePattern(instruction_id + 1);
            return;
        }
        if (instruction_value.operand_count != 1 and instruction_value.operand_count != 2)
            return Error.InvalidOperandCount;
        if (instruction_id >= self.slots.len or self.slots[instruction_id].shape != .tvalue)
            return Error.InvalidInstructionResult;
        const source = try self.operand(instruction_value, 0);
        const address_offset = if (instruction_value.operand_count == 2)
            try self.tvalueByteOffset(instruction_value, 1)
        else
            0;
        if (source.kind != .instruction and address_offset != 0)
            return Error.InvalidOperandType;
        if (source.kind == .vm_const) {
            const parts = try self.vmConstantParts(source);
            try self.body.i64Const(self.allocator, @bitCast(parts.low));
            try self.body.localSet(self.allocator, self.slots[instruction_id].first);
            try self.body.i64Const(self.allocator, @bitCast(parts.high));
            try self.body.localSet(self.allocator, self.slots[instruction_id].second);
            return;
        }
        try self.emitTValueAddress(source);
        const value_offset = if (source.kind == .vm_reg)
            try self.vmRegisterOffset(source, address_offset)
        else
            address_offset;
        try self.body.i64Load(self.allocator, 3, value_offset);
        try self.body.localSet(self.allocator, self.slots[instruction_id].first);
        try self.emitTValueAddress(source);
        try self.body.i64Load(self.allocator, 3, value_offset + 8);
        try self.body.localSet(self.allocator, self.slots[instruction_id].second);
    }

    fn emitStoreTag(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        if (try self.valueClosurePatternAt(instruction_id, 2) != null)
            return;
        if (try self.referenceClosurePatternAt(instruction_id, 2) != null or
            try self.referenceClosurePatternAt(instruction_id, 6) != null)
            return;
        try self.requireOperandCount(instruction_value, 2);
        const destination = try self.operand(instruction_value, 0);
        const source = try self.operand(instruction_value, 1);
        if (source.kind != .constant or (try self.constant(source.value)).kind != .tag)
            return Error.InvalidOperandType;
        try self.emitTValueAddress(destination);
        try self.emitI32Value(source);
        const offset = if (destination.kind == .vm_reg)
            try self.vmRegisterOffset(destination, tvalue_tag_offset)
        else
            tvalue_tag_offset;
        try self.body.i32Store(self.allocator, 2, offset);
    }

    fn emitStoreDouble(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const destination = try self.operand(instruction_value, 0);
        try self.emitTValueAddress(destination);
        try self.emitF64Value(try self.operand(instruction_value, 1));
        const offset = if (destination.kind == .vm_reg) try self.vmRegisterOffset(destination, 0) else 0;
        try self.body.f64Store(self.allocator, 3, offset);
    }

    fn emitStoreI32(self: Context, instruction_value: snapshot_v1.IrInstruction, field_offset: u32) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const destination = try self.operand(instruction_value, 0);
        const source = try self.operand(instruction_value, 1);
        if (instruction_value.command == .store_int) {
            try self.body.localGet(self.allocator, self.base_local);
            try self.emitI32Value(source);
            try self.body.i32Store(self.allocator, 2, try self.vmRegisterOffset(destination, field_offset));
            return;
        }
        try self.emitTValueAddress(destination);
        switch (instruction_value.command) {
            .store_pointer => try self.emitPointerValue(source),
            .store_extra => {
                if (source.kind != .constant or (try self.constant(source.value)).kind != .int)
                    return Error.InvalidOperandType;
                try self.emitI32Value(source);
            },
            else => return Error.UnsupportedCommand,
        }
        const offset = if (destination.kind == .vm_reg)
            try self.vmRegisterOffset(destination, field_offset)
        else
            field_offset;
        try self.body.i32Store(self.allocator, 2, offset);
    }

    fn emitStoreI64(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const destination = try self.operand(instruction_value, 0);
        try self.body.localGet(self.allocator, self.base_local);
        try self.emitI64Value(try self.operand(instruction_value, 1));
        try self.body.i64Store(self.allocator, 3, try self.vmRegisterOffset(destination, 0));
    }

    fn emitStoreVector(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        if (instruction_value.operand_count != 4 and instruction_value.operand_count != 5)
            return Error.InvalidOperandCount;
        const destination = try self.operand(instruction_value, 0);
        _ = try self.vmRegisterIndex(destination);
        var lane: u32 = 0;
        while (lane < vector_lane_count) : (lane += 1) {
            try self.body.localGet(self.allocator, self.base_local);
            try self.emitF32Value(try self.operand(instruction_value, lane + 1));
            try self.body.f32Store(self.allocator, 2, try self.vmRegisterOffset(destination, lane * 4));
        }
        if (instruction_value.operand_count == 5) {
            try self.body.localGet(self.allocator, self.base_local);
            try self.emitTagValue(try self.operand(instruction_value, 4));
            try self.body.i32Store(self.allocator, 2, try self.vmRegisterOffset(destination, tvalue_tag_offset));
        }
    }

    fn emitStoreTValue(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        if (try self.valueClosurePatternAt(instruction_id, 5) != null)
            return;
        if (instruction_value.operand_count != 2 and instruction_value.operand_count != 3)
            return Error.InvalidOperandCount;
        const destination = try self.operand(instruction_value, 0);
        const source = try self.operand(instruction_value, 1);
        if (source.kind == .instruction) {
            const source_instruction = try self.instruction(source.value);
            if (source_instruction.command == .get_upvalue) {
                if (source.value + 1 != instruction_id)
                    return Error.UnsupportedControlFlow;
                if (instruction_value.operand_count != 2)
                    return Error.UnsupportedControlFlow;
                try self.requireOperandCount(source_instruction, 1);
                const upvalue = try self.operand(source_instruction, 0);
                if (upvalue.kind != .vm_upvalue or upvalue.value != 0)
                    return Error.InvalidOperandType;

                try self.body.localGet(self.allocator, 0);
                try self.body.i32Const(self.allocator, @intCast(try self.vmRegisterIndex(destination)));
                try self.body.i32Const(self.allocator, @intCast(upvalue.value));
                try self.body.call(self.allocator, self.get_upvalue orelse return Error.UnsupportedCommand);
                return;
            }
        }
        if (source.kind != .instruction or source.value >= self.slots.len or self.slots[source.value].shape != .tvalue)
            return Error.InvalidOperandType;
        const address_offset = if (instruction_value.operand_count == 3)
            try self.tvalueByteOffset(instruction_value, 2)
        else
            0;
        if (destination.kind != .instruction and address_offset != 0)
            return Error.InvalidOperandType;
        try self.emitTValueAddress(destination);
        const destination_offset = if (destination.kind == .vm_reg)
            try self.vmRegisterOffset(destination, address_offset)
        else
            address_offset;
        try self.body.localGet(self.allocator, self.slots[source.value].first);
        try self.body.i64Store(self.allocator, 3, destination_offset);
        try self.emitTValueAddress(destination);
        try self.body.localGet(self.allocator, self.slots[source.value].second);
        try self.body.i64Store(self.allocator, 3, destination_offset + 8);
    }

    fn emitGetUpvalue(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
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

    fn emitNewClosureRef(self: Context, instruction_id: u32) Error!void {
        const pattern = try self.referenceClosurePattern(instruction_id);
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.destination));
        try self.body.i32Const(self.allocator, @intCast(pattern.child_proto_id));
        try self.body.i32Const(self.allocator, @intCast(pattern.capture_register));
        try self.body.call(self.allocator, self.newclosure_ref orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
    }

    fn emitSetUpvalue(self: Context, instruction_id: u32) Error!void {
        const pattern = try self.setUpvaluePattern(instruction_id);
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.upvalue_index));
        try self.body.i32Const(self.allocator, @intCast(pattern.source_register));
        try self.body.call(self.allocator, self.set_upvalue orelse return Error.UnsupportedCommand);
    }

    fn emitCloseUpvalues(self: Context, instruction_id: u32) Error!void {
        const pattern = try self.referenceClosurePatternAt(instruction_id, 9) orelse
            return Error.UnsupportedControlFlow;
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.capture_register));
        try self.body.call(self.allocator, self.close_upvalues orelse return Error.UnsupportedCommand);
    }

    fn emitAddNumber(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.body.f64Add(self.allocator);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitUnaryI32(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        try self.emitI32Value(try self.operand(instruction_value, 0));
        try self.body.opcode(self.allocator, opcode);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitUnaryI64(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        try self.emitI64Value(try self.operand(instruction_value, 0));
        try self.body.opcode(self.allocator, opcode);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitUnaryF32(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        try self.emitF32Value(try self.operand(instruction_value, 0));
        try self.body.opcode(self.allocator, opcode);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitUnaryF64(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.body.opcode(self.allocator, opcode);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitBinaryI32(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        try self.emitI32Value(try self.operand(instruction_value, 0));
        try self.emitI32Value(try self.operand(instruction_value, 1));
        try self.body.opcode(self.allocator, opcode);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitBinaryI64(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        try self.emitI64Value(try self.operand(instruction_value, 0));
        try self.emitI64Value(try self.operand(instruction_value, 1));
        try self.body.opcode(self.allocator, opcode);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitInvalidI64DivisionGuard(self: Context, lhs: snapshot_v1.IrOperand, rhs: snapshot_v1.IrOperand) Error!void {
        try self.emitI64Value(rhs);
        try self.body.opcode(self.allocator, 0x50); // i64.eqz

        try self.emitI64Value(lhs);
        try self.body.i64Const(self.allocator, std.math.minInt(i64));
        try self.body.opcode(self.allocator, 0x51); // i64.eq
        try self.emitI64Value(rhs);
        try self.body.i64Const(self.allocator, -1);
        try self.body.opcode(self.allocator, 0x51); // i64.eq
        try self.body.opcode(self.allocator, 0x71); // i32.and
        try self.body.opcode(self.allocator, 0x72); // i32.or

        try self.body.ifVoid(self.allocator);
        // Well-formed upstream IR puts CHECK_DIV_INT64 before signed division. Keep malformed
        // snapshots on the explicit status boundary instead of exposing Wasm's integer trap.
        try self.emitStatusReturn(status_internal_error);
        try self.body.end(self.allocator);
    }

    fn emitZeroI64DivisorGuard(self: Context, rhs: snapshot_v1.IrOperand) Error!void {
        try self.emitI64Value(rhs);
        try self.body.opcode(self.allocator, 0x50); // i64.eqz
        try self.body.ifVoid(self.allocator);
        // UDIV/UREM and REM/MOD are guarded separately by upstream. Reject malformed streams
        // explicitly so the raw Wasm div/rem instructions below can never trap.
        try self.emitStatusReturn(status_internal_error);
        try self.body.end(self.allocator);
    }

    fn emitSignedDivisionI64(
        self: Context,
        instruction_id: u32,
        instruction_value: snapshot_v1.IrInstruction,
        floor_result: bool,
    ) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        try self.emitInvalidI64DivisionGuard(lhs, rhs);

        try self.emitI64Value(lhs);
        try self.emitI64Value(rhs);
        try self.body.opcode(self.allocator, 0x7f); // i64.div_s
        try self.emitInstructionResultSet(instruction_id);

        if (floor_result) {
            // Native x64 adjusts a truncating quotient when a non-zero remainder and the divisor
            // have opposite signs. This is the mathematical floor for every guarded input.
            try self.emitI64Value(lhs);
            try self.emitI64Value(rhs);
            try self.body.opcode(self.allocator, 0x81); // i64.rem_s
            try self.body.i64Const(self.allocator, 0);
            try self.body.opcode(self.allocator, 0x52); // i64.ne

            try self.emitI64Value(lhs);
            try self.emitI64Value(rhs);
            try self.body.opcode(self.allocator, 0x81); // i64.rem_s
            try self.emitI64Value(rhs);
            try self.body.opcode(self.allocator, 0x85); // i64.xor
            try self.body.i64Const(self.allocator, 0);
            try self.body.opcode(self.allocator, 0x53); // i64.lt_s
            try self.body.opcode(self.allocator, 0x71); // i32.and
            try self.body.ifVoid(self.allocator);
            try self.body.localGet(self.allocator, self.slots[instruction_id].first);
            try self.body.i64Const(self.allocator, 1);
            try self.body.opcode(self.allocator, 0x7d); // i64.sub
            try self.emitInstructionResultSet(instruction_id);
            try self.body.end(self.allocator);
        }
    }

    fn emitUnsignedDivisionI64(
        self: Context,
        instruction_id: u32,
        instruction_value: snapshot_v1.IrInstruction,
        remainder: bool,
    ) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        try self.emitZeroI64DivisorGuard(rhs);
        try self.emitI64Value(lhs);
        try self.emitI64Value(rhs);
        try self.body.opcode(self.allocator, if (remainder) 0x82 else 0x80); // i64.rem_u / i64.div_u
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitSignedRemainderI64(
        self: Context,
        instruction_id: u32,
        instruction_value: snapshot_v1.IrInstruction,
        floor_result: bool,
    ) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        try self.emitZeroI64DivisorGuard(rhs);

        // Wasm rem_s traps for INT64_MIN % -1, while both pinned native lowerers define the
        // remainder (and modulus) as zero for that otherwise overflowing quotient.
        try self.emitI64Value(lhs);
        try self.body.i64Const(self.allocator, std.math.minInt(i64));
        try self.body.opcode(self.allocator, 0x51); // i64.eq
        try self.emitI64Value(rhs);
        try self.body.i64Const(self.allocator, -1);
        try self.body.opcode(self.allocator, 0x51); // i64.eq
        try self.body.opcode(self.allocator, 0x71); // i32.and
        try self.body.ifVoid(self.allocator);
        try self.body.i64Const(self.allocator, 0);
        try self.emitInstructionResultSet(instruction_id);
        try self.body.else_(self.allocator);
        try self.emitI64Value(lhs);
        try self.emitI64Value(rhs);
        try self.body.opcode(self.allocator, 0x81); // i64.rem_s
        try self.emitInstructionResultSet(instruction_id);

        if (floor_result) {
            // Lua modulus has the divisor's sign: adjust C's truncating remainder only when it is
            // non-zero and its sign differs from the divisor.
            try self.body.localGet(self.allocator, self.slots[instruction_id].first);
            try self.body.i64Const(self.allocator, 0);
            try self.body.opcode(self.allocator, 0x52); // i64.ne
            try self.body.localGet(self.allocator, self.slots[instruction_id].first);
            try self.emitI64Value(rhs);
            try self.body.opcode(self.allocator, 0x85); // i64.xor
            try self.body.i64Const(self.allocator, 0);
            try self.body.opcode(self.allocator, 0x53); // i64.lt_s
            try self.body.opcode(self.allocator, 0x71); // i32.and
            try self.body.ifVoid(self.allocator);
            try self.body.localGet(self.allocator, self.slots[instruction_id].first);
            try self.emitI64Value(rhs);
            try self.body.opcode(self.allocator, 0x7c); // i64.add
            try self.emitInstructionResultSet(instruction_id);
            try self.body.end(self.allocator);
        }
        try self.body.end(self.allocator);
    }

    fn emitNotI32(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        try self.emitI32Value(try self.operand(instruction_value, 0));
        try self.body.i32Const(self.allocator, -1);
        try self.body.opcode(self.allocator, 0x73); // i32.xor
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitNotI64(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        try self.emitI64Value(try self.operand(instruction_value, 0));
        try self.body.i64Const(self.allocator, -1);
        try self.body.opcode(self.allocator, 0x85); // i64.xor
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitSignedI64Shift(
        self: Context,
        instruction_id: u32,
        instruction_value: snapshot_v1.IrInstruction,
        positive_opcode: u8,
        negative_opcode: u8,
        saturate_sign: bool,
    ) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const value = try self.operand(instruction_value, 0);
        const amount = try self.operand(instruction_value, 1);

        try self.emitI64Value(amount);
        try self.body.i64Const(self.allocator, -64);
        try self.body.opcode(self.allocator, 0x57); // i64.le_s
        try self.body.ifVoid(self.allocator);
        try self.body.i64Const(self.allocator, 0);
        try self.emitInstructionResultSet(instruction_id);
        try self.body.else_(self.allocator);

        try self.emitI64Value(amount);
        try self.body.i64Const(self.allocator, 64);
        try self.body.opcode(self.allocator, 0x59); // i64.ge_s
        try self.body.ifVoid(self.allocator);
        if (saturate_sign) {
            try self.emitI64Value(value);
            try self.body.i64Const(self.allocator, 63);
            try self.body.opcode(self.allocator, 0x87); // i64.shr_s
        } else {
            try self.body.i64Const(self.allocator, 0);
        }
        try self.emitInstructionResultSet(instruction_id);
        try self.body.else_(self.allocator);

        try self.emitI64Value(amount);
        try self.body.i64Const(self.allocator, 0);
        try self.body.opcode(self.allocator, 0x53); // i64.lt_s
        try self.body.ifVoid(self.allocator);
        try self.emitI64Value(value);
        try self.body.i64Const(self.allocator, 0);
        try self.emitI64Value(amount);
        try self.body.opcode(self.allocator, 0x7d); // i64.sub
        try self.body.opcode(self.allocator, negative_opcode);
        try self.emitInstructionResultSet(instruction_id);
        try self.body.else_(self.allocator);
        try self.emitI64Value(value);
        try self.emitI64Value(amount);
        try self.body.opcode(self.allocator, positive_opcode);
        try self.emitInstructionResultSet(instruction_id);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
    }

    fn emitByteSwapI32(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const value = try self.operand(instruction_value, 0);
        try self.emitI32Value(value);
        try self.body.i32Const(self.allocator, 0x00ff_00ff);
        try self.body.opcode(self.allocator, 0x71); // i32.and
        try self.body.i32Const(self.allocator, 8);
        try self.body.opcode(self.allocator, 0x74); // i32.shl
        try self.emitI32Value(value);
        try self.body.i32Const(self.allocator, 8);
        try self.body.opcode(self.allocator, 0x76); // i32.shr_u
        try self.body.i32Const(self.allocator, 0x00ff_00ff);
        try self.body.opcode(self.allocator, 0x71); // i32.and
        try self.body.opcode(self.allocator, 0x72); // i32.or
        try self.body.i32Const(self.allocator, 16);
        try self.body.opcode(self.allocator, 0x77); // i32.rotl
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitAdjacentByteSwapI64(self: Context, value: snapshot_v1.IrOperand) Error!void {
        try self.emitI64Value(value);
        try self.body.i64Const(self.allocator, 0x00ff_00ff_00ff_00ff);
        try self.body.opcode(self.allocator, 0x83); // i64.and
        try self.body.i64Const(self.allocator, 8);
        try self.body.opcode(self.allocator, 0x86); // i64.shl
        try self.emitI64Value(value);
        try self.body.i64Const(self.allocator, 8);
        try self.body.opcode(self.allocator, 0x88); // i64.shr_u
        try self.body.i64Const(self.allocator, 0x00ff_00ff_00ff_00ff);
        try self.body.opcode(self.allocator, 0x83); // i64.and
        try self.body.opcode(self.allocator, 0x84); // i64.or
    }

    fn emitByteSwapI64(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const value = try self.operand(instruction_value, 0);
        try self.emitAdjacentByteSwapI64(value);
        try self.body.i64Const(self.allocator, 0x0000_ffff_0000_ffff);
        try self.body.opcode(self.allocator, 0x83); // i64.and
        try self.body.i64Const(self.allocator, 16);
        try self.body.opcode(self.allocator, 0x86); // i64.shl
        try self.emitAdjacentByteSwapI64(value);
        try self.body.i64Const(self.allocator, 16);
        try self.body.opcode(self.allocator, 0x88); // i64.shr_u
        try self.body.i64Const(self.allocator, 0x0000_ffff_0000_ffff);
        try self.body.opcode(self.allocator, 0x83); // i64.and
        try self.body.opcode(self.allocator, 0x84); // i64.or
        try self.body.i64Const(self.allocator, 32);
        try self.body.opcode(self.allocator, 0x89); // i64.rotl
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitBinaryF32(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        try self.emitF32Value(try self.operand(instruction_value, 0));
        try self.emitF32Value(try self.operand(instruction_value, 1));
        try self.body.opcode(self.allocator, opcode);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitBinaryF64(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.body.opcode(self.allocator, opcode);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitMulAddNumber(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.body.opcode(self.allocator, 0xa2); // f64.mul
        try self.emitF64Value(try self.operand(instruction_value, 2));
        try self.body.opcode(self.allocator, 0xa0); // f64.add
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitFloorDivisionNumber(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.body.opcode(self.allocator, 0xa3); // f64.div
        try self.body.opcode(self.allocator, 0x9c); // f64.floor
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitModNumber(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        try self.emitF64Value(lhs);
        try self.emitF64Value(lhs);
        try self.emitF64Value(rhs);
        try self.body.opcode(self.allocator, 0xa3); // f64.div
        try self.body.opcode(self.allocator, 0x9c); // f64.floor
        try self.emitF64Value(rhs);
        try self.body.opcode(self.allocator, 0xa2); // f64.mul
        try self.body.opcode(self.allocator, 0xa1); // f64.sub
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitMinMaxNumber(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, comparison_opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        try self.emitF64Value(lhs);
        try self.emitF64Value(rhs);
        try self.emitF64Value(lhs);
        try self.emitF64Value(rhs);
        try self.body.opcode(self.allocator, comparison_opcode);
        try self.body.select(self.allocator);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitRoundNumber(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const value = try self.operand(instruction_value, 0);
        try self.emitF64Value(value);
        try self.body.f64Const(self.allocator, round_number_bias);
        try self.emitF64Value(value);
        try self.body.opcode(self.allocator, 0xa6); // f64.copysign
        try self.body.opcode(self.allocator, 0xa0); // f64.add
        try self.body.opcode(self.allocator, 0x9d); // f64.trunc
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitSignNumber(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const value = try self.operand(instruction_value, 0);
        try self.body.f64Const(self.allocator, 1.0);
        try self.body.f64Const(self.allocator, -1.0);
        try self.body.f64Const(self.allocator, 0.0);
        try self.emitF64Value(value);
        try self.body.f64Const(self.allocator, 0.0);
        try self.body.opcode(self.allocator, 0x63); // f64.lt
        try self.body.select(self.allocator);
        try self.emitF64Value(value);
        try self.body.f64Const(self.allocator, 0.0);
        try self.body.opcode(self.allocator, 0x64); // f64.gt
        try self.body.select(self.allocator);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitMinMaxFloat(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, comparison_opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        try self.emitF32Value(lhs);
        try self.emitF32Value(rhs);
        try self.emitF32Value(lhs);
        try self.emitF32Value(rhs);
        try self.body.opcode(self.allocator, comparison_opcode);
        try self.body.select(self.allocator);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitSignFloat(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const value = try self.operand(instruction_value, 0);
        try self.body.f32Const(self.allocator, 1.0);
        try self.body.f32Const(self.allocator, -1.0);
        try self.body.f32Const(self.allocator, 0.0);
        try self.emitF32Value(value);
        try self.body.f32Const(self.allocator, 0.0);
        try self.body.opcode(self.allocator, 0x5d); // f32.lt
        try self.body.select(self.allocator);
        try self.emitF32Value(value);
        try self.body.f32Const(self.allocator, 0.0);
        try self.body.opcode(self.allocator, 0x5e); // f32.gt
        try self.body.select(self.allocator);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn vectorSlot(self: Context, operand_value: snapshot_v1.IrOperand) Error!ValueSlot {
        if (operand_value.kind != .instruction or operand_value.value >= self.slots.len)
            return Error.InvalidOperandType;
        const slot = self.slots[operand_value.value];
        if (slot.shape != .tvalue)
            return Error.InvalidInstructionResult;
        return slot;
    }

    fn emitVectorLaneBits(self: Context, operand_value: snapshot_v1.IrOperand, lane: u32) Error!void {
        const slot = try self.vectorSlot(operand_value);
        switch (lane) {
            0 => try self.body.localGet(self.allocator, slot.first),
            1 => {
                try self.body.localGet(self.allocator, slot.first);
                try self.body.i64Const(self.allocator, 32);
                try self.body.opcode(self.allocator, 0x88); // i64.shr_u
            },
            2 => try self.body.localGet(self.allocator, slot.second),
            3 => {
                try self.body.localGet(self.allocator, slot.second);
                try self.body.i64Const(self.allocator, 32);
                try self.body.opcode(self.allocator, 0x88); // i64.shr_u
            },
            else => return Error.InvalidOperandType,
        }
        try self.body.opcode(self.allocator, 0xa7); // i32.wrap_i64
    }

    fn emitVectorLane(self: Context, operand_value: snapshot_v1.IrOperand, lane: u32) Error!void {
        try self.emitVectorLaneBits(operand_value, lane);
        try self.body.opcode(self.allocator, 0xbe); // f32.reinterpret_i32
    }

    fn emitVectorPackPrefix(self: Context, instruction_id: u32, lane: u32) Error!void {
        if (instruction_id >= self.slots.len or self.slots[instruction_id].shape != .tvalue)
            return Error.InvalidInstructionResult;
        if (lane == 1)
            try self.body.localGet(self.allocator, self.slots[instruction_id].first)
        else if (lane == 3)
            try self.body.localGet(self.allocator, self.slots[instruction_id].second);
    }

    fn emitVectorLaneBitsSet(self: Context, instruction_id: u32, lane: u32) Error!void {
        const slot = self.slots[instruction_id];
        try self.body.opcode(self.allocator, 0xad); // i64.extend_i32_u
        switch (lane) {
            0 => try self.body.localSet(self.allocator, slot.first),
            1 => {
                try self.body.i64Const(self.allocator, 32);
                try self.body.opcode(self.allocator, 0x86); // i64.shl
                try self.body.opcode(self.allocator, 0x84); // i64.or
                try self.body.localSet(self.allocator, slot.first);
            },
            2 => try self.body.localSet(self.allocator, slot.second),
            3 => {
                try self.body.i64Const(self.allocator, 32);
                try self.body.opcode(self.allocator, 0x86); // i64.shl
                try self.body.opcode(self.allocator, 0x84); // i64.or
                try self.body.localSet(self.allocator, slot.second);
            },
            else => return Error.InvalidOperandType,
        }
    }

    fn emitVectorLaneSet(self: Context, instruction_id: u32, lane: u32) Error!void {
        try self.body.opcode(self.allocator, 0xbc); // i32.reinterpret_f32
        try self.emitVectorLaneBitsSet(instruction_id, lane);
    }

    fn emitVectorUnary(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const value = try self.operand(instruction_value, 0);
        var lane: u32 = 0;
        while (lane < vector_lane_count) : (lane += 1) {
            try self.emitVectorPackPrefix(instruction_id, lane);
            try self.emitVectorLane(value, lane);
            try self.body.opcode(self.allocator, opcode);
            try self.emitVectorLaneSet(instruction_id, lane);
        }
    }

    fn emitVectorBinary(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        var lane: u32 = 0;
        while (lane < vector_lane_count) : (lane += 1) {
            try self.emitVectorPackPrefix(instruction_id, lane);
            try self.emitVectorLane(lhs, lane);
            try self.emitVectorLane(rhs, lane);
            try self.body.opcode(self.allocator, opcode);
            try self.emitVectorLaneSet(instruction_id, lane);
        }
    }

    fn emitFloorDivisionVector(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        var lane: u32 = 0;
        while (lane < vector_lane_count) : (lane += 1) {
            try self.emitVectorPackPrefix(instruction_id, lane);
            try self.emitVectorLane(lhs, lane);
            try self.emitVectorLane(rhs, lane);
            try self.body.opcode(self.allocator, 0x95); // f32.div
            try self.body.opcode(self.allocator, 0x8e); // f32.floor
            try self.emitVectorLaneSet(instruction_id, lane);
        }
    }

    fn emitMulAddVector(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        const addend = try self.operand(instruction_value, 2);
        var lane: u32 = 0;
        while (lane < vector_lane_count) : (lane += 1) {
            try self.emitVectorPackPrefix(instruction_id, lane);
            try self.emitVectorLane(lhs, lane);
            try self.emitVectorLane(rhs, lane);
            try self.body.opcode(self.allocator, 0x94); // f32.mul
            try self.emitVectorLane(addend, lane);
            try self.body.opcode(self.allocator, 0x92); // f32.add
            try self.emitVectorLaneSet(instruction_id, lane);
        }
    }

    fn emitMinMaxVector(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, comparison_opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        var lane: u32 = 0;
        while (lane < vector_lane_count) : (lane += 1) {
            try self.emitVectorPackPrefix(instruction_id, lane);
            try self.emitVectorLaneBits(lhs, lane);
            try self.emitVectorLaneBits(rhs, lane);
            try self.emitVectorLane(lhs, lane);
            try self.emitVectorLane(rhs, lane);
            try self.body.opcode(self.allocator, comparison_opcode);
            try self.body.select(self.allocator);
            try self.emitVectorLaneBitsSet(instruction_id, lane);
        }
    }

    fn emitDotVector(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        var lane: u32 = 0;
        while (lane < vector_lane_count) : (lane += 1) {
            try self.emitVectorLane(lhs, lane);
            try self.emitVectorLane(rhs, lane);
            try self.body.opcode(self.allocator, 0x94); // f32.mul
            if (lane != 0)
                try self.body.opcode(self.allocator, 0x92); // f32.add
        }
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitExtractVector(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lane_operand = try self.operand(instruction_value, 1);
        if (lane_operand.kind != .constant)
            return Error.InvalidOperandType;
        const lane = (try self.constant(lane_operand.value)).intValue() orelse return Error.InvalidOperandType;
        if (lane < 0 or lane >= @as(i32, @intCast(vector_lane_count)))
            return Error.InvalidOperandType;
        try self.emitVectorLane(try self.operand(instruction_value, 0), @intCast(lane));
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitFloatToVector(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const value = try self.operand(instruction_value, 0);
        var lane: u32 = 0;
        while (lane < vector_lane_count) : (lane += 1) {
            try self.emitVectorPackPrefix(instruction_id, lane);
            try self.emitF32Value(value);
            try self.emitVectorLaneSet(instruction_id, lane);
        }
    }

    fn emitTagVector(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        if (instruction_id >= self.slots.len or self.slots[instruction_id].shape != .tvalue)
            return Error.InvalidInstructionResult;
        const source = try self.vectorSlot(try self.operand(instruction_value, 0));
        const destination = self.slots[instruction_id];
        try self.body.localGet(self.allocator, source.first);
        try self.body.localSet(self.allocator, destination.first);
        try self.body.localGet(self.allocator, source.second);
        try self.body.i64Const(self.allocator, 0xffff_ffff);
        try self.body.opcode(self.allocator, 0x83); // i64.and
        try self.body.i64Const(self.allocator, lua_tag_vector << 32);
        try self.body.opcode(self.allocator, 0x84); // i64.or
        try self.body.localSet(self.allocator, destination.second);
    }

    fn conditionOperand(self: Context, instruction_value: snapshot_v1.IrInstruction, index: u32) Error!snapshot_v1.IrCondition {
        const operand_value = try self.operand(instruction_value, index);
        if (operand_value.kind != .condition)
            return Error.InvalidOperandType;
        return @enumFromInt(@as(u8, @intCast(operand_value.value)));
    }

    fn emitIntegerCondition(self: Context, condition: snapshot_v1.IrCondition) Error!void {
        const opcode: u8 = switch (condition) {
            .equal => 0x46,
            .not_equal => 0x47,
            .less => 0x48,
            .not_less => 0x4e,
            .less_equal => 0x4c,
            .not_less_equal => 0x4a,
            .greater => 0x4a,
            .not_greater => 0x4c,
            .greater_equal => 0x4e,
            .not_greater_equal => 0x48,
            .unsigned_less => 0x49,
            .unsigned_less_equal => 0x4d,
            .unsigned_greater => 0x4b,
            .unsigned_greater_equal => 0x4f,
        };
        try self.body.opcode(self.allocator, opcode);
    }

    fn emitInt64Condition(self: Context, condition: snapshot_v1.IrCondition) Error!void {
        const opcode: u8 = switch (condition) {
            .equal => 0x51,
            .not_equal => 0x52,
            .less => 0x53,
            .not_less => 0x59,
            .less_equal => 0x57,
            .not_less_equal => 0x55,
            .greater => 0x55,
            .not_greater => 0x57,
            .greater_equal => 0x59,
            .not_greater_equal => 0x53,
            .unsigned_less => 0x54,
            .unsigned_less_equal => 0x58,
            .unsigned_greater => 0x56,
            .unsigned_greater_equal => 0x5a,
        };
        try self.body.opcode(self.allocator, opcode);
    }

    fn emitFloatCondition(self: Context, condition: snapshot_v1.IrCondition) Error!void {
        switch (condition) {
            .equal => try self.body.opcode(self.allocator, 0x5b),
            .not_equal => try self.body.opcode(self.allocator, 0x5c),
            .less => try self.body.opcode(self.allocator, 0x5d),
            .not_less => {
                try self.body.opcode(self.allocator, 0x5d);
                try self.body.i32Eqz(self.allocator);
            },
            .less_equal => try self.body.opcode(self.allocator, 0x5f),
            .not_less_equal => {
                try self.body.opcode(self.allocator, 0x5f);
                try self.body.i32Eqz(self.allocator);
            },
            .greater => try self.body.opcode(self.allocator, 0x5e),
            .not_greater => {
                try self.body.opcode(self.allocator, 0x5e);
                try self.body.i32Eqz(self.allocator);
            },
            .greater_equal => try self.body.opcode(self.allocator, 0x60),
            .not_greater_equal => {
                try self.body.opcode(self.allocator, 0x60);
                try self.body.i32Eqz(self.allocator);
            },
            .unsigned_less, .unsigned_less_equal, .unsigned_greater, .unsigned_greater_equal => return Error.UnsupportedCondition,
        }
    }

    fn emitComparisonI32(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        try self.emitI32Value(try self.operand(instruction_value, 0));
        try self.emitI32Value(try self.operand(instruction_value, 1));
        try self.emitIntegerCondition(try self.conditionOperand(instruction_value, 2));
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitComparisonI64(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        try self.emitI64Value(try self.operand(instruction_value, 0));
        try self.emitI64Value(try self.operand(instruction_value, 1));
        try self.emitInt64Condition(try self.conditionOperand(instruction_value, 2));
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitComparisonTag(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        const condition = try self.conditionOperand(instruction_value, 2);
        if (condition != .equal and condition != .not_equal)
            return Error.UnsupportedCondition;
        try self.emitTagValue(try self.operand(instruction_value, 0));
        try self.emitTagValue(try self.operand(instruction_value, 1));
        try self.emitIntegerCondition(condition);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitSplitTValueComparison(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 5);
        const expected_tag_operand = try self.operand(instruction_value, 1);
        if (expected_tag_operand.kind != .constant)
            return Error.InvalidOperandType;
        const expected_tag = (try self.constant(expected_tag_operand.value)).tagValue() orelse return Error.InvalidOperandType;
        const condition = try self.conditionOperand(instruction_value, 4);
        if (condition != .equal and condition != .not_equal)
            return Error.UnsupportedCondition;

        try self.emitTagValue(try self.operand(instruction_value, 0));
        try self.emitTagValue(expected_tag_operand);
        try self.emitIntegerCondition(condition);

        const lhs = try self.operand(instruction_value, 2);
        const rhs = try self.operand(instruction_value, 3);
        switch (expected_tag) {
            lua_tag_boolean, lua_tag_string => {
                try self.emitI32Value(lhs);
                try self.emitI32Value(rhs);
                try self.emitIntegerCondition(condition);
            },
            lua_tag_number => {
                try self.emitF64Value(lhs);
                try self.emitF64Value(rhs);
                if (condition == .equal)
                    try self.body.f64Eq(self.allocator)
                else
                    try self.body.f64Ne(self.allocator);
            },
            lua_tag_integer => {
                try self.emitI64Value(lhs);
                try self.emitI64Value(rhs);
                try self.emitInt64Condition(condition);
            },
            else => return Error.UnsupportedOperand,
        }

        try self.body.opcode(self.allocator, if (condition == .equal) 0x71 else 0x72); // i32.and / i32.or
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitSelectNumber(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 4);
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.emitF64Value(try self.operand(instruction_value, 2));
        try self.emitF64Value(try self.operand(instruction_value, 3));
        try self.body.f64Eq(self.allocator);
        try self.body.select(self.allocator);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitSelectInt64(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 5);
        try self.emitI64Value(try self.operand(instruction_value, 1));
        try self.emitI64Value(try self.operand(instruction_value, 0));
        try self.emitI64Value(try self.operand(instruction_value, 2));
        try self.emitI64Value(try self.operand(instruction_value, 3));
        try self.emitInt64Condition(try self.conditionOperand(instruction_value, 4));
        try self.body.select(self.allocator);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitSelectVector(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 4);
        const false_value = try self.operand(instruction_value, 0);
        const true_value = try self.operand(instruction_value, 1);
        const lhs = try self.operand(instruction_value, 2);
        const rhs = try self.operand(instruction_value, 3);
        var lane: u32 = 0;
        while (lane < tvalue_lane_count) : (lane += 1) {
            try self.emitVectorPackPrefix(instruction_id, lane);
            try self.emitVectorLaneBits(true_value, lane);
            try self.emitVectorLaneBits(false_value, lane);
            if (lane < vector_lane_count) {
                try self.emitVectorLane(lhs, lane);
                try self.emitVectorLane(rhs, lane);
            } else {
                // Upstream vecOp normalizes the non-semantic W lane to zero even when the source
                // TValue carries a tag in its high word. Preserve the selected raw lane above, but
                // compare the normalized vector operands here.
                try self.body.f32Const(self.allocator, 0.0);
                try self.body.f32Const(self.allocator, 0.0);
            }
            try self.body.opcode(self.allocator, 0x5b); // f32.eq
            try self.body.select(self.allocator);
            try self.emitVectorLaneBitsSet(instruction_id, lane);
        }
    }

    fn emitSelectIfTruthy(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        if (instruction_id >= self.slots.len or self.slots[instruction_id].shape != .tvalue)
            return Error.InvalidInstructionResult;
        const condition = try self.operand(instruction_value, 0);
        const true_value = try self.operand(instruction_value, 1);
        const false_value = try self.operand(instruction_value, 2);
        const destination = self.slots[instruction_id];

        try self.emitTValuePart(true_value, false);
        try self.emitTValuePart(false_value, false);
        try self.emitTValueTruthy(condition);
        try self.body.select(self.allocator);
        try self.body.localSet(self.allocator, destination.first);

        try self.emitTValuePart(true_value, true);
        try self.emitTValuePart(false_value, true);
        try self.emitTValueTruthy(condition);
        try self.body.select(self.allocator);
        try self.body.localSet(self.allocator, destination.second);
    }

    fn emitCopyI32(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        try self.emitI32Value(try self.operand(instruction_value, 0));
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitNotAny(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const tag = try self.operand(instruction_value, 0);
        const value = try self.operand(instruction_value, 1);
        try self.emitI32Value(tag);
        try self.body.i32Const(self.allocator, lua_tag_nil);
        try self.body.i32Eq(self.allocator);
        try self.emitI32Value(tag);
        try self.body.i32Const(self.allocator, lua_tag_boolean);
        try self.body.i32Eq(self.allocator);
        try self.emitI32Value(value);
        try self.body.i32Eqz(self.allocator);
        try self.body.opcode(self.allocator, 0x71); // i32.and
        try self.body.opcode(self.allocator, 0x72); // i32.or
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitCheckDivInt64(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        const failure = try self.operand(instruction_value, 2);

        // Reject b == 0 and INT64_MIN / -1, exactly the two cases guarded by the pinned native
        // lowerers before their signed division instructions.
        try self.emitI64Value(rhs);
        try self.body.opcode(self.allocator, 0x50); // i64.eqz
        try self.emitI64Value(lhs);
        try self.body.i64Const(self.allocator, std.math.minInt(i64));
        try self.body.opcode(self.allocator, 0x51); // i64.eq
        try self.emitI64Value(rhs);
        try self.body.i64Const(self.allocator, -1);
        try self.body.opcode(self.allocator, 0x51); // i64.eq
        try self.body.opcode(self.allocator, 0x71); // i32.and
        try self.body.opcode(self.allocator, 0x72); // i32.or
        try self.body.ifVoid(self.allocator);
        switch (failure.kind) {
            .block => {
                const target_block = try self.snapshot.irBlock(self.function, failure.value);
                if (target_block.kind == .fallback and !try self.supportsFallback(target_block)) {
                    try self.emitStatusReturn(status_unsupported_type);
                } else {
                    const target = if (target_block.kind == .fallback)
                        failure.value
                    else
                        try self.requireCompiledTarget(failure);
                    try self.body.i32Const(self.allocator, @intCast(target));
                    try self.body.localSet(self.allocator, self.dispatch_local);
                    try self.body.branch(self.allocator, 2);
                }
            },
            // Strict AOT has no bytecode VM exit to resume yet. Match the existing CHECK_TAG
            // boundary until the WP5 error helper can preserve the precise Luau error identity.
            .vm_exit => try self.emitStatusReturn(status_unsupported_type),
            .undef => try self.emitStatusReturn(status_internal_error),
            else => return Error.InvalidOperandType,
        }
        try self.body.end(self.allocator);
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
                if (target_block.kind == .fallback and !try self.supportsFallback(target_block)) {
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
            .undef => try self.emitStatusReturn(status_internal_error),
            else => return Error.InvalidOperandType,
        }
        try self.body.end(self.allocator);
    }

    fn emitGuardFailure(self: Context, failure: snapshot_v1.IrOperand) Error!void {
        try self.body.ifVoid(self.allocator);
        switch (failure.kind) {
            .block => {
                const target_block = try self.snapshot.irBlock(self.function, failure.value);
                if (target_block.kind == .fallback and !try self.supportsFallback(target_block)) {
                    try self.emitStatusReturn(status_unsupported_type);
                } else {
                    const target = if (target_block.kind == .fallback)
                        failure.value
                    else
                        try self.requireCompiledTarget(failure);
                    try self.body.i32Const(self.allocator, @intCast(target));
                    try self.body.localSet(self.allocator, self.dispatch_local);
                    // The guard conditional is nested inside the selected-block conditional.
                    try self.body.branch(self.allocator, 2);
                }
            },
            .vm_exit => try self.emitStatusReturn(status_unsupported_type),
            .undef => try self.emitStatusReturn(status_internal_error),
            else => return Error.InvalidOperandType,
        }
        try self.body.end(self.allocator);
    }

    fn emitCheckTruthy(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        const tag = try self.operand(instruction_value, 0);
        const value = try self.operand(instruction_value, 1);

        // Fail for nil, or for a boolean whose payload is zero. Every other tag is truthy.
        try self.emitI32Value(tag);
        try self.body.i32Const(self.allocator, lua_tag_nil);
        try self.body.i32Eq(self.allocator);
        try self.emitI32Value(tag);
        try self.body.i32Const(self.allocator, lua_tag_boolean);
        try self.body.i32Eq(self.allocator);
        try self.emitI32Value(value);
        try self.body.i32Eqz(self.allocator);
        try self.body.opcode(self.allocator, 0x71); // i32.and
        try self.body.opcode(self.allocator, 0x72); // i32.or
        try self.emitGuardFailure(try self.operand(instruction_value, 2));
    }

    fn emitCheckCompareNumber(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 4);
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.emitNumericCondition(try self.conditionOperand(instruction_value, 2));
        try self.body.i32Eqz(self.allocator);
        try self.emitGuardFailure(try self.operand(instruction_value, 3));
    }

    fn emitCheckCompareInteger(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 4);
        try self.emitI32Value(try self.operand(instruction_value, 0));
        try self.emitI32Value(try self.operand(instruction_value, 1));
        try self.emitIntegerCondition(try self.conditionOperand(instruction_value, 2));
        try self.body.i32Eqz(self.allocator);
        try self.emitGuardFailure(try self.operand(instruction_value, 3));
    }

    fn emitCheckCompareInt64(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 4);
        try self.emitI64Value(try self.operand(instruction_value, 0));
        try self.emitI64Value(try self.operand(instruction_value, 1));
        try self.emitInt64Condition(try self.conditionOperand(instruction_value, 2));
        try self.body.i32Eqz(self.allocator);
        try self.emitGuardFailure(try self.operand(instruction_value, 3));
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
        const operation = aotArithmeticOperation(upstream_operation) orelse return Error.UnsupportedCommand;

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(destination));
        try self.body.i32Const(self.allocator, @intCast(lhs));
        try self.body.i32Const(self.allocator, @intCast(rhs));
        try self.body.i32Const(self.allocator, operation);
        try self.body.call(self.allocator, self.do_arith orelse return Error.UnsupportedCommand);
        // Generic arithmetic may allocate, invoke a metamethod, and relocate the stack.
        try self.emitReloadBase();
    }

    fn comparisonOperation(condition: snapshot_v1.IrCondition) Error!i32 {
        return switch (condition) {
            .equal => 0,
            .less => 1,
            .less_equal => 2,
            else => Error.UnsupportedCondition,
        };
    }

    fn emitCompareAny(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        if (instruction_id == 0 or (try self.instruction(instruction_id - 1)).command != .set_savedpc)
            return Error.UnsupportedControlFlow;
        _ = try self.savedPc(try self.instruction(instruction_id - 1));

        const lhs = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
        const rhs = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
        const operation = try comparisonOperation(try self.conditionOperand(instruction_value, 2));

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(lhs));
        try self.body.i32Const(self.allocator, @intCast(rhs));
        try self.body.i32Const(self.allocator, operation);
        try self.body.call(self.allocator, self.compare_any orelse return Error.UnsupportedCommand);
        try self.emitInstructionResultSet(instruction_id);
        // Generic comparison can invoke a metamethod and relocate the active stack.
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
        if ((try self.constant(marker_operand.value)).uintValue() == null)
            return false;
        const upstream_operation = (try self.constant(operation.value)).intValue() orelse return false;
        if (aotArithmeticOperation(upstream_operation) == null)
            return false;
        if (destination.value >= self.proto.max_stack_size or lhs.value >= self.proto.max_stack_size or rhs.value >= self.proto.max_stack_size)
            return false;

        const target = try self.snapshot.irBlock(self.function, jump_target.value);
        return target.kind.isCompilable() and !target.isEmpty();
    }

    fn supportsComparisonFallback(self: Context, block: snapshot_v1.IrBlock) Error!bool {
        if (block.kind != .fallback or block.isEmpty() or block.finish - block.start != 2)
            return false;
        const marker = try self.instruction(block.start);
        const comparison = try self.instruction(block.start + 1);
        const jump = try self.instruction(block.start + 2);
        if (marker.command != .set_savedpc or comparison.command != .cmp_any or jump.command != .jump_cmp_int or
            marker.operand_count != 1 or comparison.operand_count != 3 or jump.operand_count != 5)
            return false;

        const marker_operand = try self.operand(marker, 0);
        const lhs = try self.operand(comparison, 0);
        const rhs = try self.operand(comparison, 1);
        const comparison_condition = try self.operand(comparison, 2);
        const jump_lhs = try self.operand(jump, 0);
        const jump_rhs = try self.operand(jump, 1);
        const jump_condition = try self.operand(jump, 2);
        const true_target = try self.operand(jump, 3);
        const false_target = try self.operand(jump, 4);
        if (marker_operand.kind != .constant or lhs.kind != .vm_reg or rhs.kind != .vm_reg or comparison_condition.kind != .condition or
            jump_lhs.kind != .instruction or jump_lhs.value != block.start + 1 or jump_rhs.kind != .constant or
            jump_condition.kind != .condition or true_target.kind != .block or false_target.kind != .block)
            return false;
        if ((try self.constant(marker_operand.value)).uintValue() == null or
            lhs.value >= self.proto.max_stack_size or rhs.value >= self.proto.max_stack_size)
            return false;
        const comparison_condition_value: snapshot_v1.IrCondition = @enumFromInt(@as(u8, @intCast(comparison_condition.value)));
        _ = comparisonOperation(comparison_condition_value) catch return false;
        const zero = (try self.constant(jump_rhs.value)).intValue() orelse return false;
        if (zero != 0)
            return false;
        const jump_condition_value: snapshot_v1.IrCondition = @enumFromInt(@as(u8, @intCast(jump_condition.value)));
        if (jump_condition_value != .equal and jump_condition_value != .not_equal)
            return false;

        const true_block = try self.snapshot.irBlock(self.function, true_target.value);
        const false_block = try self.snapshot.irBlock(self.function, false_target.value);
        return true_block.kind.isCompilable() and !true_block.isEmpty() and
            false_block.kind.isCompilable() and !false_block.isEmpty();
    }

    fn supportsFallback(self: Context, block: snapshot_v1.IrBlock) Error!bool {
        return (try self.supportsArithmeticFallback(block)) or (try self.supportsComparisonFallback(block));
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

    fn emitConditionalDispatch(self: Context, true_target: u32, false_target: u32) Error!void {
        try self.body.ifVoid(self.allocator);
        try self.body.i32Const(self.allocator, @intCast(true_target));
        try self.body.localSet(self.allocator, self.dispatch_local);
        try self.body.else_(self.allocator);
        try self.body.i32Const(self.allocator, @intCast(false_target));
        try self.body.localSet(self.allocator, self.dispatch_local);
        try self.body.end(self.allocator);
        try self.body.branch(self.allocator, 1);
    }

    fn emitJumpIfTruthy(self: Context, instruction_value: snapshot_v1.IrInstruction, invert: bool) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        const source = try self.operand(instruction_value, 0);
        _ = try self.vmRegisterIndex(source);
        const true_target = try self.requireCompiledTarget(try self.operand(instruction_value, 1));
        const false_target = try self.requireCompiledTarget(try self.operand(instruction_value, 2));
        try self.emitTValueTruthy(source);
        if (invert)
            try self.body.i32Eqz(self.allocator);
        try self.emitConditionalDispatch(true_target, false_target);
    }

    fn emitJumpEqualTag(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 4);
        const true_target = try self.requireCompiledTarget(try self.operand(instruction_value, 2));
        const false_target = try self.requireCompiledTarget(try self.operand(instruction_value, 3));
        try self.emitTagValue(try self.operand(instruction_value, 0));
        try self.emitTagValue(try self.operand(instruction_value, 1));
        try self.body.i32Eq(self.allocator);
        try self.emitConditionalDispatch(true_target, false_target);
    }

    fn emitJumpCompareInteger(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 5);
        const true_target = try self.requireCompiledTarget(try self.operand(instruction_value, 3));
        const false_target = try self.requireCompiledTarget(try self.operand(instruction_value, 4));
        try self.emitI32Value(try self.operand(instruction_value, 0));
        try self.emitI32Value(try self.operand(instruction_value, 1));
        try self.emitIntegerCondition(try self.conditionOperand(instruction_value, 2));
        try self.emitConditionalDispatch(true_target, false_target);
    }

    fn emitJumpEqualPointer(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 4);
        const true_target = try self.requireCompiledTarget(try self.operand(instruction_value, 2));
        const false_target = try self.requireCompiledTarget(try self.operand(instruction_value, 3));
        try self.emitPointerValue(try self.operand(instruction_value, 0));
        try self.emitPointerValue(try self.operand(instruction_value, 1));
        try self.body.i32Eq(self.allocator);
        try self.emitConditionalDispatch(true_target, false_target);
    }

    fn emitJumpCompareFloat(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 5);
        const true_target = try self.requireCompiledTarget(try self.operand(instruction_value, 3));
        const false_target = try self.requireCompiledTarget(try self.operand(instruction_value, 4));
        try self.emitF32Value(try self.operand(instruction_value, 0));
        try self.emitF32Value(try self.operand(instruction_value, 1));
        try self.emitFloatCondition(try self.conditionOperand(instruction_value, 2));
        try self.emitConditionalDispatch(true_target, false_target);
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

    fn emitJumpFornLoopCondition(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 5);
        const true_target = try self.requireCompiledTarget(try self.operand(instruction_value, 3));
        const false_target = try self.requireCompiledTarget(try self.operand(instruction_value, 4));

        // step > 0 ? index <= limit : limit <= index. Ordered comparisons preserve the
        // upstream behavior for NaN: a NaN index/limit exits, and a NaN step selects the
        // non-positive-step comparison.
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.body.f64Le(self.allocator);
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.body.f64Le(self.allocator);
        try self.emitF64Value(try self.operand(instruction_value, 2));
        try self.body.f64Const(self.allocator, 0.0);
        try self.body.f64Gt(self.allocator);
        try self.body.select(self.allocator);
        try self.emitConditionalDispatch(true_target, false_target);
    }

    fn emitReturn(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const source = try self.operand(instruction_value, 0);
        const return_count_operand = try self.operand(instruction_value, 1);
        if (return_count_operand.kind != .constant)
            return Error.InvalidReturnCount;
        const return_count = (try self.constant(return_count_operand.value)).intValue() orelse return Error.InvalidReturnCount;
        // The pinned builder encodes LUA_MULTRET as exactly -1. Other negative values are malformed.
        if (return_count < -1)
            return Error.InvalidReturnCount;

        const source_register: u32 = if (return_count == 0)
            0
        else blk: {
            const register = try self.vmRegisterIndex(source);
            if (return_count > 0) {
                const return_count_u32: u32 = @intCast(return_count);
                if (return_count_u32 > @as(u32, self.proto.max_stack_size) - register)
                    return Error.InvalidReturnCount;
            }
            break :blk register;
        };

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(source_register));
        try self.body.i32Const(self.allocator, @intCast(return_count));
        try self.body.call(self.allocator, self.return_);
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

    fn emitCall(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
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
        // The pinned builder encodes dynamic arguments and LUA_MULTRET results as exactly -1.
        if (parameter_count < -1 or result_count < -1)
            return Error.UnsupportedControlFlow;
        if (parameter_count >= 0) {
            const parameter_count_u32: u32 = @intCast(parameter_count);
            if (parameter_count_u32 >= @as(u32, self.proto.max_stack_size) - function_register)
                return Error.UnsupportedControlFlow;
        }
        if (result_count >= 0) {
            const result_count_u32: u32 = @intCast(result_count);
            if (result_count_u32 > @as(u32, self.proto.max_stack_size) - function_register)
                return Error.UnsupportedControlFlow;
        }

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(function_register));
        try self.body.i32Const(self.allocator, parameter_count);
        try self.body.i32Const(self.allocator, result_count);
        try self.body.call(self.allocator, self.call orelse return Error.UnsupportedCommand);
        try self.body.localTee(self.allocator, self.status_local);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.emitReloadBase();
        try self.body.else_(self.allocator);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.return_(self.allocator);
        try self.body.end(self.allocator);
    }

    fn emitPrepVarargs(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        if (!self.function.variadic or !self.proto.is_vararg)
            return Error.UnsupportedVariadicFunction;

        const pc_operand = try self.operand(instruction_value, 0);
        const parameter_operand = try self.operand(instruction_value, 1);
        if (pc_operand.kind != .constant or parameter_operand.kind != .constant)
            return Error.InvalidOperandType;
        _ = (try self.constant(pc_operand.value)).uintValue() orelse return Error.InvalidOperandType;
        const parameter_count = (try self.constant(parameter_operand.value)).intValue() orelse return Error.InvalidOperandType;
        if (parameter_count < 0 or parameter_count != @as(i32, self.proto.num_params))
            return Error.UnsupportedVariadicFunction;

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, parameter_count);
        try self.body.call(self.allocator, self.prep_varargs orelse return Error.UnsupportedCommand);
        // PREPVARARGS checks/grows the stack and always rewires the active frame base.
        try self.emitReloadBase();
    }

    fn emitGetVarargs(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        if (!self.function.variadic or !self.proto.is_vararg)
            return Error.UnsupportedVariadicFunction;

        const pc_operand = try self.operand(instruction_value, 0);
        if (pc_operand.kind != .constant)
            return Error.InvalidOperandType;
        _ = (try self.constant(pc_operand.value)).uintValue() orelse return Error.InvalidOperandType;

        const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
        const count_operand = try self.operand(instruction_value, 2);
        if (count_operand.kind != .constant)
            return Error.InvalidOperandType;
        const count = (try self.constant(count_operand.value)).intValue() orelse return Error.InvalidOperandType;
        if (count < -1)
            return Error.UnsupportedVariadicFunction;

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(destination));
        if (count == -1) {
            try self.body.call(self.allocator, self.get_varargs_multret orelse return Error.UnsupportedCommand);
            // The multret helper checks/grows the stack and updates L->top.
            try self.emitReloadBase();
        } else {
            const count_u32: u32 = @intCast(count);
            if (count_u32 > @as(u32, self.proto.max_stack_size) - destination)
                return Error.UnsupportedVariadicFunction;
            try self.body.i32Const(self.allocator, count);
            try self.body.call(self.allocator, self.get_varargs_fixed orelse return Error.UnsupportedCommand);
        }
    }

    fn emitInstruction(self: Context, instruction_id: u32, block_kind: snapshot_v1.IrBlockKind) Error!bool {
        const instruction_value = try self.instruction(instruction_id);
        switch (instruction_value.command) {
            .nop, .substitute, .mark_used, .mark_dead => return false,
            .load_env => {
                if (instruction_id + 1 >= self.function.instruction_count or
                    (try self.instruction(instruction_id + 1)).command != .newclosure)
                    return Error.UnsupportedControlFlow;
                if (instruction_id + 4 < self.function.instruction_count and
                    (try self.instruction(instruction_id + 4)).command == .findupval)
                    _ = try self.referenceClosurePattern(instruction_id + 1)
                else
                    _ = try self.valueClosurePattern(instruction_id + 1);
            },
            .get_closure_upval_addr => {
                if (try self.valueClosurePatternAt(instruction_id, 4) == null and
                    try self.referenceClosurePatternAt(instruction_id, 4) == null)
                    return Error.UnsupportedControlFlow;
            },
            .load_tag => try self.emitLoadTag(instruction_id, instruction_value),
            .load_pointer, .load_int => try self.emitLoadI32(instruction_id, instruction_value),
            .load_int64 => try self.emitLoadI64(instruction_id, instruction_value),
            .load_float => try self.emitLoadFloat(instruction_id, instruction_value),
            .load_double => try self.emitLoadDouble(instruction_id, instruction_value),
            .load_tvalue => try self.emitLoadTValue(instruction_id, instruction_value),
            .store_pointer => {
                if (try self.valueClosurePatternAt(instruction_id, 1) == null and
                    try self.referenceClosurePatternAt(instruction_id, 1) == null and
                    try self.referenceClosurePatternAt(instruction_id, 5) == null)
                    try self.emitStoreI32(instruction_value, 0);
            },
            .store_tag => try self.emitStoreTag(instruction_id, instruction_value),
            .store_extra => try self.emitStoreI32(instruction_value, tvalue_extra_offset),
            .store_split_tvalue => {
                if (try self.valueClosurePatternAt(instruction_id, 9) == null)
                    return Error.UnsupportedControlFlow;
            },
            .store_double => try self.emitStoreDouble(instruction_value),
            .store_int => try self.emitStoreI32(instruction_value, 0),
            .store_int64 => try self.emitStoreI64(instruction_value),
            .store_vector => try self.emitStoreVector(instruction_value),
            .store_tvalue => try self.emitStoreTValue(instruction_id, instruction_value),
            .add_int => try self.emitBinaryI32(instruction_id, instruction_value, 0x6a),
            .sub_int => try self.emitBinaryI32(instruction_id, instruction_value, 0x6b),
            .add_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x7c),
            .sub_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x7d),
            .mul_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x7e),
            .div_int64 => try self.emitSignedDivisionI64(instruction_id, instruction_value, false),
            .idiv_int64 => try self.emitSignedDivisionI64(instruction_id, instruction_value, true),
            .udiv_int64 => try self.emitUnsignedDivisionI64(instruction_id, instruction_value, false),
            .rem_int64 => try self.emitSignedRemainderI64(instruction_id, instruction_value, false),
            .urem_int64 => try self.emitUnsignedDivisionI64(instruction_id, instruction_value, true),
            .mod_int64 => try self.emitSignedRemainderI64(instruction_id, instruction_value, true),
            .sexti8_int => try self.emitUnaryI32(instruction_id, instruction_value, 0xc0),
            .sexti16_int => try self.emitUnaryI32(instruction_id, instruction_value, 0xc1),
            .add_num => try self.emitAddNumber(instruction_id, instruction_value),
            .sub_num => try self.emitBinaryF64(instruction_id, instruction_value, 0xa1),
            .mul_num => try self.emitBinaryF64(instruction_id, instruction_value, 0xa2),
            .div_num => try self.emitBinaryF64(instruction_id, instruction_value, 0xa3),
            .idiv_num => try self.emitFloorDivisionNumber(instruction_id, instruction_value),
            .mod_num => try self.emitModNumber(instruction_id, instruction_value),
            .muladd_num => try self.emitMulAddNumber(instruction_id, instruction_value),
            .min_num => try self.emitMinMaxNumber(instruction_id, instruction_value, 0x63),
            .max_num => try self.emitMinMaxNumber(instruction_id, instruction_value, 0x64),
            .unm_num => try self.emitUnaryF64(instruction_id, instruction_value, 0x9a),
            .floor_num => try self.emitUnaryF64(instruction_id, instruction_value, 0x9c),
            .ceil_num => try self.emitUnaryF64(instruction_id, instruction_value, 0x9b),
            .round_num => try self.emitRoundNumber(instruction_id, instruction_value),
            .sqrt_num => try self.emitUnaryF64(instruction_id, instruction_value, 0x9f),
            .abs_num => try self.emitUnaryF64(instruction_id, instruction_value, 0x99),
            .sign_num => try self.emitSignNumber(instruction_id, instruction_value),
            .add_float => try self.emitBinaryF32(instruction_id, instruction_value, 0x92),
            .sub_float => try self.emitBinaryF32(instruction_id, instruction_value, 0x93),
            .mul_float => try self.emitBinaryF32(instruction_id, instruction_value, 0x94),
            .div_float => try self.emitBinaryF32(instruction_id, instruction_value, 0x95),
            .min_float => try self.emitMinMaxFloat(instruction_id, instruction_value, 0x5d),
            .max_float => try self.emitMinMaxFloat(instruction_id, instruction_value, 0x5e),
            .unm_float => try self.emitUnaryF32(instruction_id, instruction_value, 0x8c),
            .floor_float => try self.emitUnaryF32(instruction_id, instruction_value, 0x8e),
            .ceil_float => try self.emitUnaryF32(instruction_id, instruction_value, 0x8d),
            .sqrt_float => try self.emitUnaryF32(instruction_id, instruction_value, 0x91),
            .abs_float => try self.emitUnaryF32(instruction_id, instruction_value, 0x8b),
            .sign_float => try self.emitSignFloat(instruction_id, instruction_value),
            .select_num => try self.emitSelectNumber(instruction_id, instruction_value),
            .select_int64 => try self.emitSelectInt64(instruction_id, instruction_value),
            .select_vec => try self.emitSelectVector(instruction_id, instruction_value),
            .select_if_truthy => try self.emitSelectIfTruthy(instruction_id, instruction_value),
            .add_vec => try self.emitVectorBinary(instruction_id, instruction_value, 0x92),
            .sub_vec => try self.emitVectorBinary(instruction_id, instruction_value, 0x93),
            .mul_vec => try self.emitVectorBinary(instruction_id, instruction_value, 0x94),
            .div_vec => try self.emitVectorBinary(instruction_id, instruction_value, 0x95),
            .idiv_vec => try self.emitFloorDivisionVector(instruction_id, instruction_value),
            .muladd_vec => try self.emitMulAddVector(instruction_id, instruction_value),
            .unm_vec => try self.emitVectorUnary(instruction_id, instruction_value, 0x8c),
            .min_vec => try self.emitMinMaxVector(instruction_id, instruction_value, 0x5d),
            .max_vec => try self.emitMinMaxVector(instruction_id, instruction_value, 0x5e),
            .floor_vec => try self.emitVectorUnary(instruction_id, instruction_value, 0x8e),
            .ceil_vec => try self.emitVectorUnary(instruction_id, instruction_value, 0x8d),
            .abs_vec => try self.emitVectorUnary(instruction_id, instruction_value, 0x8b),
            .dot_vec => try self.emitDotVector(instruction_id, instruction_value),
            .extract_vec => try self.emitExtractVector(instruction_id, instruction_value),
            .float_to_vec => try self.emitFloatToVector(instruction_id, instruction_value),
            .tag_vector => try self.emitTagVector(instruction_id, instruction_value),
            .not_any => try self.emitNotAny(instruction_id, instruction_value),
            .cmp_any => {
                if (block_kind != .fallback)
                    return Error.UnsupportedControlFlow;
                try self.emitCompareAny(instruction_id, instruction_value);
            },
            .cmp_int => try self.emitComparisonI32(instruction_id, instruction_value),
            .cmp_int64 => try self.emitComparisonI64(instruction_id, instruction_value),
            .cmp_tag => try self.emitComparisonTag(instruction_id, instruction_value),
            .cmp_split_tvalue => try self.emitSplitTValueComparison(instruction_id, instruction_value),
            .int_to_num => try self.emitUnaryI32(instruction_id, instruction_value, 0xb7), // f64.convert_i32_s
            .int64_to_num => try self.emitUnaryI64(instruction_id, instruction_value, 0xb9), // f64.convert_i64_s
            .uint_to_num => try self.emitUnaryI32(instruction_id, instruction_value, 0xb8), // f64.convert_i32_u
            .uint_to_float => try self.emitUnaryI32(instruction_id, instruction_value, 0xb3), // f32.convert_i32_u
            .float_to_num => try self.emitUnaryF32(instruction_id, instruction_value, 0xbb), // f64.promote_f32
            .num_to_float => try self.emitUnaryF64(instruction_id, instruction_value, 0xb6), // f32.demote_f64
            .truncate_uint => try self.emitCopyI32(instruction_id, instruction_value),
            .bitand_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x83),
            .bitxor_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x85),
            .bitor_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x84),
            .bitnot_int64 => try self.emitNotI64(instruction_id, instruction_value),
            .bitlshift_int64 => try self.emitSignedI64Shift(instruction_id, instruction_value, 0x86, 0x88, false),
            .bitrshift_int64 => try self.emitSignedI64Shift(instruction_id, instruction_value, 0x88, 0x86, false),
            .bitarshift_int64 => try self.emitSignedI64Shift(instruction_id, instruction_value, 0x87, 0x86, true),
            .bitlrotate_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x89),
            .bitrrotate_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x8a),
            .bitcountlz_int64 => try self.emitUnaryI64(instruction_id, instruction_value, 0x79),
            .bitcountrz_int64 => try self.emitUnaryI64(instruction_id, instruction_value, 0x7a),
            .byteswap_int64 => try self.emitByteSwapI64(instruction_id, instruction_value),
            .bitand_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x71),
            .bitxor_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x73),
            .bitor_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x72),
            .bitnot_uint => try self.emitNotI32(instruction_id, instruction_value),
            .bitlshift_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x74),
            .bitrshift_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x76),
            .bitarshift_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x75),
            .bitlrotate_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x77),
            .bitrrotate_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x78),
            .bitcountlz_uint => try self.emitUnaryI32(instruction_id, instruction_value, 0x67),
            .bitcountrz_uint => try self.emitUnaryI32(instruction_id, instruction_value, 0x68),
            .byteswap_uint => try self.emitByteSwapI32(instruction_id, instruction_value),
            .get_upvalue => try self.emitGetUpvalue(instruction_id, instruction_value),
            .set_upvalue => try self.emitSetUpvalue(instruction_id),
            .check_div_int64 => try self.emitCheckDivInt64(instruction_value),
            .check_tag => try self.emitCheckTag(instruction_value),
            .check_truthy => try self.emitCheckTruthy(instruction_value),
            .check_cmp_num => try self.emitCheckCompareNumber(instruction_value),
            .check_cmp_int => try self.emitCheckCompareInteger(instruction_value),
            .check_cmp_int64 => try self.emitCheckCompareInt64(instruction_value),
            .check_gc => {
                if (try self.valueClosurePatternAt(instruction_id, 6) == null and
                    try self.referenceClosurePatternAt(instruction_id, 7) == null)
                    return Error.UnsupportedControlFlow;
            },
            .set_savedpc => {
                _ = try self.savedPc(instruction_value);
                if (block_kind != .fallback) {
                    if (!block_kind.isCompilable())
                        return Error.UnsupportedControlFlow;
                    if (instruction_id + 2 < self.function.instruction_count and
                        (try self.instruction(instruction_id + 2)).command == .newclosure)
                    {
                        if (instruction_id + 5 < self.function.instruction_count and
                            (try self.instruction(instruction_id + 5)).command == .findupval)
                            _ = try self.referenceClosurePattern(instruction_id + 2)
                        else
                            _ = try self.valueClosurePattern(instruction_id + 2);
                    } else if (instruction_id + 1 >= self.function.instruction_count or
                        (try self.instruction(instruction_id + 1)).command != .call)
                        return Error.UnsupportedControlFlow;
                }
            },
            .capture => {
                if (try self.valueClosurePatternAt(instruction_id, 7) == null and
                    try self.referenceClosurePatternAt(instruction_id, 8) == null)
                    return Error.UnsupportedControlFlow;
            },
            .findupval => {
                if (try self.referenceClosurePatternAt(instruction_id, 3) == null)
                    return Error.UnsupportedControlFlow;
            },
            .close_upvals => try self.emitCloseUpvalues(instruction_id),
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
            .jump_if_truthy => {
                try self.emitJumpIfTruthy(instruction_value, false);
                return true;
            },
            .jump_if_falsy => {
                try self.emitJumpIfTruthy(instruction_value, true);
                return true;
            },
            .jump_eq_tag => {
                try self.emitJumpEqualTag(instruction_value);
                return true;
            },
            .jump_cmp_int => {
                try self.emitJumpCompareInteger(instruction_value);
                return true;
            },
            .jump_eq_pointer => {
                try self.emitJumpEqualPointer(instruction_value);
                return true;
            },
            .jump_cmp_num => {
                try self.emitJumpCompareNumber(instruction_value);
                return true;
            },
            .jump_cmp_float => {
                try self.emitJumpCompareFloat(instruction_value);
                return true;
            },
            .jump_forn_loop_cond => {
                try self.emitJumpFornLoopCondition(instruction_value);
                return true;
            },
            .return_ => {
                try self.emitReturn(instruction_value);
                return true;
            },
            .call => try self.emitCall(instruction_id, instruction_value),
            .fallback_prepvarargs => try self.emitPrepVarargs(instruction_value),
            .fallback_getvarargs => try self.emitGetVarargs(instruction_value),
            .newclosure => {
                if (instruction_id + 3 < self.function.instruction_count and
                    (try self.instruction(instruction_id + 3)).command == .findupval)
                    try self.emitNewClosureRef(instruction_id)
                else
                    try self.emitNewClosureValue(instruction_id);
            },
            .fallback_dupclosure => try self.emitDupClosure(instruction_value),
            else => return Error.UnsupportedCommand,
        }
        return false;
    }

    fn emitBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock) Error!void {
        if (block.kind == .fallback and !try self.supportsFallback(block))
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
        .load_tag,
        .load_int,
        .add_int,
        .sub_int,
        .sexti8_int,
        .sexti16_int,
        .not_any,
        .cmp_any,
        .cmp_int,
        .cmp_int64,
        .cmp_tag,
        .cmp_split_tvalue,
        .num_to_int,
        .num_to_uint,
        .truncate_uint,
        .bitand_uint,
        .bitxor_uint,
        .bitor_uint,
        .bitnot_uint,
        .bitlshift_uint,
        .bitrshift_uint,
        .bitarshift_uint,
        .bitlrotate_uint,
        .bitrrotate_uint,
        .bitcountlz_uint,
        .bitcountrz_uint,
        .byteswap_uint,
        => .i32,
        .load_pointer,
        .load_env,
        .get_closure_upval_addr,
        .newclosure,
        .findupval,
        => .pointer,
        .load_int64,
        .add_int64,
        .sub_int64,
        .mul_int64,
        .div_int64,
        .idiv_int64,
        .udiv_int64,
        .rem_int64,
        .urem_int64,
        .mod_int64,
        .select_int64,
        .num_to_int64,
        .bitand_int64,
        .bitxor_int64,
        .bitor_int64,
        .bitnot_int64,
        .bitlshift_int64,
        .bitrshift_int64,
        .bitarshift_int64,
        .bitlrotate_int64,
        .bitrrotate_int64,
        .bitcountlz_int64,
        .bitcountrz_int64,
        .byteswap_int64,
        => .i64,
        .load_float,
        .add_float,
        .sub_float,
        .mul_float,
        .div_float,
        .min_float,
        .max_float,
        .unm_float,
        .floor_float,
        .ceil_float,
        .sqrt_float,
        .abs_float,
        .sign_float,
        .dot_vec,
        .extract_vec,
        .uint_to_float,
        .num_to_float,
        => .f32,
        .load_double,
        .add_num,
        .sub_num,
        .mul_num,
        .div_num,
        .idiv_num,
        .mod_num,
        .muladd_num,
        .min_num,
        .max_num,
        .unm_num,
        .floor_num,
        .ceil_num,
        .round_num,
        .sqrt_num,
        .abs_num,
        .sign_num,
        .select_num,
        .int_to_num,
        .int64_to_num,
        .uint_to_num,
        .float_to_num,
        => .f64,
        .load_tvalue,
        .select_vec,
        .select_if_truthy,
        .add_vec,
        .sub_vec,
        .mul_vec,
        .div_vec,
        .idiv_vec,
        .muladd_vec,
        .unm_vec,
        .min_vec,
        .max_vec,
        .floor_vec,
        .ceil_vec,
        .abs_vec,
        .float_to_vec,
        .tag_vector,
        => .tvalue,
        else => .none,
    };
}

const ImportNeeds = struct {
    do_arith: bool = false,
    compare_any: bool = false,
    dupclosure: bool = false,
    newclosure_value: bool = false,
    newclosure_ref: bool = false,
    get_upvalue: bool = false,
    set_upvalue: bool = false,
    close_upvalues: bool = false,
    call: bool = false,
    prep_varargs: bool = false,
    get_varargs_fixed: bool = false,
    get_varargs_multret: bool = false,
};

const RuntimeImports = struct {
    return_: wasm.FunctionRef,
    interrupt: wasm.FunctionRef,
    do_arith: ?wasm.FunctionRef,
    compare_any: ?wasm.FunctionRef,
    dupclosure: ?wasm.FunctionRef,
    newclosure_value: ?wasm.FunctionRef,
    newclosure_ref: ?wasm.FunctionRef,
    get_upvalue: ?wasm.FunctionRef,
    set_upvalue: ?wasm.FunctionRef,
    close_upvalues: ?wasm.FunctionRef,
    call: ?wasm.FunctionRef,
    prep_varargs: ?wasm.FunctionRef,
    get_varargs_fixed: ?wasm.FunctionRef,
    get_varargs_multret: ?wasm.FunctionRef,
    generated_type: u32,
};

fn scanImportNeeds(snapshot: snapshot_v1.Snapshot, function_id: u32, needs: *ImportNeeds) Error!void {
    const function = try snapshot.irFunction(function_id);
    var instruction_id: u32 = 0;
    while (instruction_id < function.instruction_count) : (instruction_id += 1) {
        switch ((try snapshot.irInstruction(function, instruction_id)).command) {
            .do_arith => needs.do_arith = true,
            .cmp_any => needs.compare_any = true,
            .fallback_dupclosure => needs.dupclosure = true,
            .newclosure => {
                if (instruction_id + 3 < function.instruction_count and
                    (try snapshot.irInstruction(function, instruction_id + 3)).command == .findupval)
                    needs.newclosure_ref = true
                else
                    needs.newclosure_value = true;
            },
            .get_upvalue => needs.get_upvalue = true,
            .set_upvalue => needs.set_upvalue = true,
            .close_upvals => needs.close_upvalues = true,
            .call => needs.call = true,
            .fallback_prepvarargs => needs.prep_varargs = true,
            .fallback_getvarargs => {
                needs.get_varargs_fixed = true;
                needs.get_varargs_multret = true;
            },
            else => {},
        }
    }
}

fn addRuntimeImports(object: *wasm.Object, needs: ImportNeeds) Error!RuntimeImports {
    const return_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const interrupt_params = [_]wasm.ValueType{ .i32, .i32 };
    const do_arith_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32, .i32 };
    const compare_any_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const dupclosure_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const newclosure_value_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const newclosure_ref_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const get_upvalue_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const set_upvalue_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const close_upvalues_params = [_]wasm.ValueType{ .i32, .i32 };
    const call_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const prep_varargs_params = [_]wasm.ValueType{ .i32, .i32 };
    const get_varargs_fixed_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const get_varargs_multret_params = [_]wasm.ValueType{ .i32, .i32 };
    const generated_params = [_]wasm.ValueType{ .i32, .i32 };
    const no_results = [_]wasm.ValueType{};
    const status_result = [_]wasm.ValueType{.i32};

    const return_type = try object.addType(.{ .params = &return_params, .results = &no_results });
    const interrupt_type = try object.addType(.{ .params = &interrupt_params, .results = &status_result });
    const generated_type = try object.addType(.{ .params = &generated_params, .results = &status_result });
    const return_ = try object.importFunction("env", return_symbol, return_type);
    const interrupt = try object.importFunction("env", interrupt_symbol, interrupt_type);
    const do_arith = if (needs.do_arith) blk: {
        const helper_type = try object.addType(.{ .params = &do_arith_params, .results = &no_results });
        break :blk try object.importFunction("env", do_arith_symbol, helper_type);
    } else null;
    const compare_any = if (needs.compare_any) blk: {
        const helper_type = try object.addType(.{ .params = &compare_any_params, .results = &status_result });
        break :blk try object.importFunction("env", compare_any_symbol, helper_type);
    } else null;
    const dupclosure = if (needs.dupclosure) blk: {
        const helper_type = try object.addType(.{ .params = &dupclosure_params, .results = &no_results });
        break :blk try object.importFunction("env", dupclosure_symbol, helper_type);
    } else null;
    const newclosure_value = if (needs.newclosure_value) blk: {
        const helper_type = try object.addType(.{ .params = &newclosure_value_params, .results = &no_results });
        break :blk try object.importFunction("env", newclosure_value_symbol, helper_type);
    } else null;
    const newclosure_ref = if (needs.newclosure_ref) blk: {
        const helper_type = try object.addType(.{ .params = &newclosure_ref_params, .results = &no_results });
        break :blk try object.importFunction("env", newclosure_ref_symbol, helper_type);
    } else null;
    const get_upvalue = if (needs.get_upvalue) blk: {
        const helper_type = try object.addType(.{ .params = &get_upvalue_params, .results = &no_results });
        break :blk try object.importFunction("env", get_upvalue_symbol, helper_type);
    } else null;
    const set_upvalue = if (needs.set_upvalue) blk: {
        const helper_type = try object.addType(.{ .params = &set_upvalue_params, .results = &no_results });
        break :blk try object.importFunction("env", set_upvalue_symbol, helper_type);
    } else null;
    const close_upvalues = if (needs.close_upvalues) blk: {
        const helper_type = try object.addType(.{ .params = &close_upvalues_params, .results = &no_results });
        break :blk try object.importFunction("env", close_upvalues_symbol, helper_type);
    } else null;
    const call = if (needs.call) blk: {
        const helper_type = try object.addType(.{ .params = &call_params, .results = &status_result });
        break :blk try object.importFunction("env", call_symbol, helper_type);
    } else null;
    const prep_varargs = if (needs.prep_varargs) blk: {
        const helper_type = try object.addType(.{ .params = &prep_varargs_params, .results = &no_results });
        break :blk try object.importFunction("env", prep_varargs_symbol, helper_type);
    } else null;
    const get_varargs_fixed = if (needs.get_varargs_fixed) blk: {
        const helper_type = try object.addType(.{ .params = &get_varargs_fixed_params, .results = &no_results });
        break :blk try object.importFunction("env", get_varargs_fixed_symbol, helper_type);
    } else null;
    const get_varargs_multret = if (needs.get_varargs_multret) blk: {
        const helper_type = try object.addType(.{ .params = &get_varargs_multret_params, .results = &no_results });
        break :blk try object.importFunction("env", get_varargs_multret_symbol, helper_type);
    } else null;

    return .{
        .return_ = return_,
        .interrupt = interrupt,
        .do_arith = do_arith,
        .compare_any = compare_any,
        .dupclosure = dupclosure,
        .newclosure_value = newclosure_value,
        .newclosure_ref = newclosure_ref,
        .get_upvalue = get_upvalue,
        .set_upvalue = set_upvalue,
        .close_upvalues = close_upvalues,
        .call = call,
        .prep_varargs = prep_varargs,
        .get_varargs_fixed = get_varargs_fixed,
        .get_varargs_multret = get_varargs_multret,
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
    if (function.variadic != proto.is_vararg)
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
            .pointer => {
                if (next_local >= max_lowered_locals)
                    return Error.ResourceLimit;
                slots[instruction_id].first = next_local;
                next_local += 1;
                try locals.append(allocator, .{ .count = 1, .value_type = .i32 });
            },
            .i64 => {
                if (next_local >= max_lowered_locals)
                    return Error.ResourceLimit;
                slots[instruction_id].first = next_local;
                next_local += 1;
                try locals.append(allocator, .{ .count = 1, .value_type = .i64 });
            },
            .f32 => {
                if (next_local >= max_lowered_locals)
                    return Error.ResourceLimit;
                slots[instruction_id].first = next_local;
                next_local += 1;
                try locals.append(allocator, .{ .count = 1, .value_type = .f32 });
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
        .return_ = imports.return_,
        .interrupt = imports.interrupt,
        .do_arith = imports.do_arith,
        .compare_any = imports.compare_any,
        .dupclosure = imports.dupclosure,
        .newclosure_value = imports.newclosure_value,
        .newclosure_ref = imports.newclosure_ref,
        .get_upvalue = imports.get_upvalue,
        .set_upvalue = imports.set_upvalue,
        .close_upvalues = imports.close_upvalues,
        .call = imports.call,
        .prep_varargs = imports.prep_varargs,
        .get_varargs_fixed = imports.get_varargs_fixed,
        .get_varargs_multret = imports.get_varargs_multret,
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
        } else if (block.kind == .fallback and try context.supportsComparisonFallback(block)) {
            if (context.compare_any == null)
                return Error.UnsupportedCommand;
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
        else if (block.kind == .fallback and try context.supportsFallback(block))
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
