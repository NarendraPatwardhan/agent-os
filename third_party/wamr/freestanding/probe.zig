const wamr = @import("wamr_bindings");

// Hand-assembled from:
// (module
//   (memory (export "memory") 1)
//   (func (export "add") (param i32 i32) (result i32)
//     local.get 0
//     local.get 1
//     i32.add))
const tiny_add_guest_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01,
    0x7f,
    0x03, 0x02, 0x01, 0x00,
    0x05, 0x03, 0x01, 0x00, 0x01,
    0x07, 0x10, 0x02, 0x06, 0x6d, 0x65, 0x6d, 0x6f,
    0x72, 0x79, 0x02, 0x00, 0x03, 0x61, 0x64, 0x64,
    0x00, 0x00,
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20,
    0x01, 0x6a, 0x0b,
};

// Hand-assembled from:
// (module
//   (func (export "sumto") (param i32) (result i32)
//     (local i32 i32)
//     i32.const 0
//     local.set 1
//     i32.const 1
//     local.set 2
//     block
//       loop
//         local.get 2
//         local.get 0
//         i32.gt_u
//         br_if 1
//         local.get 1
//         local.get 2
//         i32.add
//         local.set 1
//         local.get 2
//         i32.const 1
//         i32.add
//         local.set 2
//         br 0
//       end
//     end
//     local.get 1))
const sumto_guest_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x09, 0x01, 0x05, 0x73, 0x75, 0x6d, 0x74,
    0x6f, 0x00, 0x00,
    0x0a, 0x2d, 0x01, 0x2b, 0x01, 0x02, 0x7f, 0x41,
    0x00, 0x21, 0x01, 0x41, 0x01, 0x21, 0x02, 0x02,
    0x40, 0x03, 0x40, 0x20, 0x02, 0x20, 0x00, 0x4b,
    0x0d, 0x01, 0x20, 0x01, 0x20, 0x02, 0x6a, 0x21,
    0x01, 0x20, 0x02, 0x41, 0x01, 0x6a, 0x21, 0x02,
    0x0c, 0x00, 0x0b, 0x0b, 0x20, 0x01, 0x0b,
};

// Hand-assembled from:
// (module
//   (func (export "trap") (param i32) (result i32)
//     local.get 0
//     i32.const 0
//     i32.div_s))
const trap_guest_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x08, 0x01, 0x04, 0x74, 0x72, 0x61, 0x70,
    0x00, 0x00,
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x41,
    0x00, 0x6d, 0x0b,
};

fn statusCode(status: wamr.CallStatus) i32 {
    return @intCast(@intFromEnum(status));
}

export fn wamr_wasm32_probe() i32 {
    var error_buf: [128]u8 = undefined;
    var guest_wasm = tiny_add_guest_wasm;

    if (!wamr.wasm_runtime_init()) return -1;
    defer wamr.wasm_runtime_destroy();

    const module = wamr.wasm_runtime_load(
        guest_wasm[0..].ptr,
        @intCast(guest_wasm.len),
        error_buf[0..].ptr,
        @intCast(error_buf.len),
    ) orelse return -2;
    defer wamr.wasm_runtime_unload(module);

    const module_inst = wamr.wasm_runtime_instantiate(
        module,
        16 * 1024,
        0,
        error_buf[0..].ptr,
        @intCast(error_buf.len),
    ) orelse return -3;
    defer wamr.wasm_runtime_deinstantiate(module_inst);

    const memory = wamr.wasm_runtime_get_memory(module_inst, 0) orelse return -4;
    if (wamr.wasm_memory_get_base_address(memory) == null) return -5;
    if (wamr.wasm_runtime_addr_app_to_native(module_inst, 0) == null) return -6;

    const exec_env = wamr.wasm_runtime_create_exec_env(module_inst, 16 * 1024) orelse return -7;
    defer wamr.wasm_runtime_destroy_exec_env(exec_env);
    wamr.wasm_runtime_set_instruction_count_limit(exec_env, 1000);

    const add = wamr.wasm_runtime_lookup_function(module_inst, "add") orelse return -8;
    var argv = [_]u32{ 2, 3 };
    if (!wamr.wasm_runtime_call_wasm(exec_env, add, 2, argv[0..].ptr)) {
        _ = wamr.wasm_runtime_get_exception(module_inst);
        return -9;
    }

    if (argv[0] != 5) return -10;
    return @intCast(argv[0]);
}

export fn wamr_wasm32_resume_probe() i32 {
    const n: u32 = 500;
    const expected: u32 = (n * (n + 1)) / 2;
    const instruction_budget: c_int = 1;
    var error_buf: [128]u8 = undefined;
    var guest_wasm = sumto_guest_wasm;

    if (!wamr.wasm_runtime_init()) return -1;
    defer wamr.wasm_runtime_destroy();

    const module = wamr.wasm_runtime_load(
        guest_wasm[0..].ptr,
        @intCast(guest_wasm.len),
        error_buf[0..].ptr,
        @intCast(error_buf.len),
    ) orelse return -2;
    defer wamr.wasm_runtime_unload(module);

    const module_inst = wamr.wasm_runtime_instantiate(
        module,
        16 * 1024,
        0,
        error_buf[0..].ptr,
        @intCast(error_buf.len),
    ) orelse return -3;
    defer wamr.wasm_runtime_deinstantiate(module_inst);

    const exec_env = wamr.wasm_runtime_create_exec_env(module_inst, 16 * 1024) orelse return -4;
    defer wamr.wasm_runtime_destroy_exec_env(exec_env);

    const sumto = wamr.wasm_runtime_lookup_function(module_inst, "sumto") orelse return -5;
    var argv = [_]u32{n};
    wamr.wasm_runtime_set_instruction_count_limit(exec_env, instruction_budget);
    var status = wamr.wasm_runtime_call_wasm_status(exec_env, sumto, 1, argv[0..].ptr);
    var yield_count: i32 = 0;

    while (status == .yielded) {
        yield_count += 1;
        if (yield_count > 10_000) return -6;
        wamr.wasm_runtime_set_instruction_count_limit(exec_env, instruction_budget);
        status = wamr.wasm_runtime_resume(exec_env, 1, argv[0..].ptr);
    }

    if (status != .done) {
        _ = wamr.wasm_runtime_get_exception(module_inst);
        return -70 - statusCode(status);
    }
    if (yield_count <= 1) return -80 - yield_count;
    if (argv[0] != expected) return -90;

    return yield_count;
}

export fn wamr_wasm32_trap_probe() i32 {
    var error_buf: [128]u8 = undefined;
    var guest_wasm = trap_guest_wasm;

    if (!wamr.wasm_runtime_init()) return -1;
    defer wamr.wasm_runtime_destroy();

    const module = wamr.wasm_runtime_load(
        guest_wasm[0..].ptr,
        @intCast(guest_wasm.len),
        error_buf[0..].ptr,
        @intCast(error_buf.len),
    ) orelse return -2;
    defer wamr.wasm_runtime_unload(module);

    const module_inst = wamr.wasm_runtime_instantiate(
        module,
        16 * 1024,
        0,
        error_buf[0..].ptr,
        @intCast(error_buf.len),
    ) orelse return -3;
    defer wamr.wasm_runtime_deinstantiate(module_inst);

    const exec_env = wamr.wasm_runtime_create_exec_env(module_inst, 16 * 1024) orelse return -4;
    defer wamr.wasm_runtime_destroy_exec_env(exec_env);
    wamr.wasm_runtime_set_instruction_count_limit(exec_env, 1000);

    const trap = wamr.wasm_runtime_lookup_function(module_inst, "trap") orelse return -5;
    var argv = [_]u32{1};
    const status = wamr.wasm_runtime_call_wasm_status(exec_env, trap, 1, argv[0..].ptr);

    if (status == .yielded) return -60;
    if (status != .trap) return -70 - statusCode(status);

    return 0;
}
