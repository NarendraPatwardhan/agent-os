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
