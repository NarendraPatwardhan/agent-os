//! wamr/bindings.zig - thin Zig bindings over the WAMR C embedding API.
//!
//! This file owns only the extern declarations for the runtime surface used by
//! the Zig kernel driver: runtime init/destroy, module load/unload,
//! instantiate/deinstantiate, exec-env creation, exported-function lookup/call,
//! exception reads, memory lookup, native registration, and the small exec-env
//! frame surface needed for cooperative yield/resume.

pub const Module = opaque {};
pub const ModuleInst = opaque {};
pub const Function = opaque {};
pub const Memory = opaque {};

pub const WASM_SUSPEND_FLAG_BLOCKING: u32 = 0x10;

pub const SuspendFlags = extern union {
    flags: u32,
    padding: usize,
};

pub const InterpFrame = extern struct {
    prev_frame: ?*InterpFrame,
    function: ?*Function,
    ip: ?[*]u8,
    ret_offset: u32,
    lp: [*]u32,
    operand: [1]u32,
};

pub const WasmStack = extern struct {
    top_boundary: ?[*]u8,
    top: ?[*]u8,
    bottom: ?[*]u8,
};

pub const ExecEnv = extern struct {
    next: ?*ExecEnv,
    cur_frame: ?*InterpFrame,
    module_inst: ?*ModuleInst,
    native_stack_boundary: ?[*]u8,
    suspend_flags: SuspendFlags,
    aux_stack_boundary: usize,
    aux_stack_bottom: usize,
    native_stack_top_min: ?[*]u8,
    wasm_stack: WasmStack,
    wasm_call_status: u32,
    instructions_to_execute: c_int,
    attachment: ?*anyopaque,
};

pub const CallStatus = enum(c_int) {
    done = 0,
    yielded = 1,
    trap = 2,
};

pub const NativeSymbol = extern struct {
    symbol: ?[*:0]const u8,
    func_ptr: ?*const anyopaque,
    signature: ?[*:0]const u8,
    attachment: ?*anyopaque,
};

pub const MemAllocType = enum(c_int) {
    pool = 0,
    allocator = 1,
    system = 2,
};

pub const MemAllocOption = extern union {
    pool: extern struct {
        heap_buf: ?*anyopaque,
        heap_size: u32,
    },
    allocator: extern struct {
        malloc_func: ?*anyopaque,
        realloc_func: ?*anyopaque,
        free_func: ?*anyopaque,
        user_data: ?*anyopaque,
    },
};

pub const RunningMode = enum(c_int) {
    interp = 1,
    fast_jit = 2,
    llvm_jit = 3,
    multi_tier_jit = 4,
};

pub const RuntimeInitArgs = extern struct {
    mem_alloc_type: MemAllocType,
    mem_alloc_option: MemAllocOption,
    native_module_name: ?[*:0]const u8,
    native_symbols: ?[*]NativeSymbol,
    n_native_symbols: u32,
    max_thread_num: u32,
    ip_addr: [128]u8,
    unused: c_int,
    instance_port: c_int,
    fast_jit_code_cache_size: u32,
    gc_heap_size: u32,
    running_mode: RunningMode,
    llvm_jit_opt_level: u32,
    llvm_jit_size_level: u32,
    segue_flags: u32,
    enable_linux_perf: bool,
};

pub const ValKind = enum(u8) {
    i32 = 0,
    i64 = 1,
    f32 = 2,
    f64 = 3,
    v128 = 4,
    externref = 128,
    funcref = 129,
};

pub const Val = extern struct {
    kind: ValKind,
    _paddings: [7]u8,
    of: extern union {
        i32: i32,
        i64: i64,
        f32: f32,
        f64: f64,
        foreign: usize,
        ref: ?*anyopaque,
    },
};

pub extern fn wasm_runtime_init() bool;
pub extern fn wasm_runtime_full_init(init_args: *RuntimeInitArgs) bool;
pub extern fn wasm_runtime_destroy() void;

pub extern fn wasm_runtime_malloc(size: c_uint) ?*anyopaque;
pub extern fn wasm_runtime_free(ptr: ?*anyopaque) void;

pub extern fn wasm_runtime_load(
    buf: [*]u8,
    size: u32,
    error_buf: [*]u8,
    error_buf_size: u32,
) ?*Module;
pub extern fn wasm_runtime_unload(module: ?*Module) void;

pub extern fn wasm_runtime_instantiate(
    module: ?*Module,
    default_stack_size: u32,
    host_managed_heap_size: u32,
    error_buf: [*]u8,
    error_buf_size: u32,
) ?*ModuleInst;
pub extern fn wasm_runtime_deinstantiate(module_inst: ?*ModuleInst) void;

pub extern fn wasm_runtime_create_exec_env(module_inst: ?*ModuleInst, stack_size: u32) ?*ExecEnv;
pub extern fn wasm_runtime_destroy_exec_env(exec_env: ?*ExecEnv) void;
pub extern fn wasm_runtime_get_module_inst(exec_env: ?*ExecEnv) ?*ModuleInst;

pub extern fn wasm_runtime_lookup_function(module_inst: ?*ModuleInst, name: [*:0]const u8) ?*Function;
pub extern fn wasm_runtime_call_wasm(
    exec_env: ?*ExecEnv,
    function: ?*Function,
    argc: u32,
    argv: [*]u32,
) bool;
pub extern fn wasm_runtime_call_wasm_status(
    exec_env: ?*ExecEnv,
    function: ?*Function,
    argc: u32,
    argv: [*]u32,
) CallStatus;
pub extern fn wasm_runtime_resume(
    exec_env: ?*ExecEnv,
    result_cell_count: u32,
    argv: [*]u32,
) CallStatus;
pub extern fn wasm_runtime_get_call_status(exec_env: ?*ExecEnv) CallStatus;
pub extern fn wasm_runtime_call_wasm_a(
    exec_env: ?*ExecEnv,
    function: ?*Function,
    num_results: u32,
    results: [*]Val,
    num_args: u32,
    args: [*]Val,
) bool;

pub extern fn wasm_runtime_get_exception(module_inst: ?*ModuleInst) ?[*:0]const u8;
pub extern fn wasm_runtime_set_exception(module_inst: ?*ModuleInst, exception: [*:0]const u8) void;
pub extern fn wasm_runtime_clear_exception(module_inst: ?*ModuleInst) void;
pub extern fn wasm_runtime_set_custom_data(module_inst: ?*ModuleInst, custom_data: ?*anyopaque) void;
pub extern fn wasm_runtime_get_custom_data(module_inst: ?*ModuleInst) ?*anyopaque;

pub extern fn wasm_runtime_get_memory(module_inst: ?*ModuleInst, index: u32) ?*Memory;
pub extern fn wasm_memory_get_base_address(memory_inst: ?*Memory) ?*anyopaque;
pub extern fn wasm_memory_get_cur_page_count(memory_inst: ?*Memory) u64;
pub extern fn wasm_memory_get_bytes_per_page(memory_inst: ?*Memory) u64;
pub extern fn wasm_runtime_addr_app_to_native(module_inst: ?*ModuleInst, app_offset: u64) ?*anyopaque;
pub extern fn wasm_runtime_addr_native_to_app(module_inst: ?*ModuleInst, native_ptr: ?*anyopaque) u64;
pub extern fn wasm_runtime_validate_app_addr(module_inst: ?*ModuleInst, app_offset: u64, size: u64) bool;
pub extern fn wasm_runtime_module_malloc(module_inst: ?*ModuleInst, size: u64, p_native_addr: ?*?*anyopaque) u64;
pub extern fn wasm_runtime_module_free(module_inst: ?*ModuleInst, ptr: u64) void;

pub extern fn wasm_runtime_set_instruction_count_limit(exec_env: ?*ExecEnv, instruction_count: c_int) void;
pub extern fn wasm_runtime_register_natives(
    module_name: [*:0]const u8,
    native_symbols: [*]NativeSymbol,
    n_native_symbols: u32,
) bool;
pub extern fn wasm_runtime_register_natives_raw(
    module_name: [*:0]const u8,
    native_symbols: [*]NativeSymbol,
    n_native_symbols: u32,
) bool;
pub extern fn wasm_runtime_unregister_natives(
    module_name: [*:0]const u8,
    native_symbols: [*]NativeSymbol,
) bool;

pub extern fn bh_log_set_verbose_level(level: u32) void;
