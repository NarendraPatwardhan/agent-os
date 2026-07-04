//! wasm3/bindings.zig — thin Zig bindings over the wasm3 C API (ZIG_KERNEL §7.2, §4.1).
//!
//! Owns: the `extern` declarations for the wasm3 C surface the kernel uses — one
//!   environment for the kernel's lifetime, one runtime per guest, eager compile
//!   (m3_CompileModule), raw-function registration, invocation, memory access, and the
//!   fuel API added by the in-tree patch (m3_SetFuel/GetFuel/ConsumeFuel).
//! Invariants: A6 (wasm3 allocation routes to the kernel via d_m3AgentOsAllocator →
//!   wasm3/alloc.zig), A4 (no new host import — wasm3's libc is satisfied in-module).
//! Consumes: @wasm3 (vendored at //third_party/wasm3, http_archive + fuel patch, B3).
//! Not here: ANY kernel policy (fuel, suspend, scheduling, snapshot) — wasm3 is a thin
//!   library (§7.1, §12.1). The raw handlers that record Pending live in raw.zig; the
//!   driver (eager compile, per-guest runtime, the Asyncify boundary) is guest.zig.

pub const Runtime = opaque {};
pub const Environment = opaque {};
pub const Module = opaque {};
pub const Function = opaque {};
pub const Global = opaque {};
pub const Result = ?*const anyopaque;
pub const ImportContext = extern struct {
    userdata: ?*const anyopaque,
    function: ?*Function,
};
pub const RawCall = *const fn (?*Runtime, ImportContext, [*]u64, ?*anyopaque) callconv(.c) Result;
pub const ValueType = enum(c_int) {
    none = 0,
    i32 = 1,
    i64 = 2,
    f32 = 3,
    f64 = 4,
    unknown,
};
pub const ValueUnion = extern union {
    i32_value: u32,
    i64_value: u64,
    f32_value: f32,
    f64_value: f64,
};
pub const TaggedValue = extern struct {
    type: ValueType,
    value: ValueUnion,
};

pub extern var m3Err_trapOutOfFuel: Result;
pub extern var m3Err_trapUnreachable: Result;
pub extern var m3Err_functionLookupFailed: Result;

pub extern fn m3_NewEnvironment() ?*Environment;
pub extern fn m3_FreeEnvironment(environment: ?*Environment) void;
pub extern fn m3_NewRuntime(environment: ?*Environment, stack_size_in_bytes: u32, userdata: ?*anyopaque) ?*Runtime;
pub extern fn m3_FreeRuntime(runtime: ?*Runtime) void;
pub extern fn m3_GetMemory(runtime: ?*Runtime, memory_size_in_bytes: *u32, memory_index: u32) ?*anyopaque;
pub extern fn m3_GetMemorySize(runtime: ?*Runtime) u32;
pub extern fn m3_ParseModule(environment: ?*Environment, module: *?*Module, wasm_bytes: [*]const u8, wasm_len: u32) Result;
pub extern fn m3_FreeModule(module: ?*Module) void;
pub extern fn m3_LoadModule(runtime: ?*Runtime, module: ?*Module) Result;
pub extern fn m3_CompileModule(module: ?*Module) Result;
pub extern fn m3_LinkRawFunctionEx(module: ?*Module, module_name: [*:0]const u8, function_name: [*:0]const u8, signature: [*:0]const u8, function: RawCall, userdata: ?*const anyopaque) Result;
pub extern fn m3_FindGlobal(module: ?*Module, name: [*:0]const u8) ?*Global;
pub extern fn m3_GetGlobal(global: ?*Global, value: *TaggedValue) Result;
pub extern fn m3_SetGlobal(global: ?*Global, value: *const TaggedValue) Result;
pub extern fn m3_GetGlobalType(global: ?*Global) ValueType;
pub extern fn m3_FindFunction(function: *?*Function, runtime: ?*Runtime, name: [*:0]const u8) Result;
pub extern fn m3_Call(function: ?*Function, argc: u32, argptrs: ?[*]const ?*const anyopaque) Result;
pub extern fn m3_GetResults(function: ?*Function, retc: u32, retptrs: [*]const ?*anyopaque) Result;
pub extern fn m3_GetUserData(runtime: ?*Runtime) ?*anyopaque;
pub extern fn m3_ClearFuel(runtime: ?*Runtime) void;
pub extern fn m3_SetFuel(runtime: ?*Runtime, fuel: u64) void;
pub extern fn m3_AddFuel(runtime: ?*Runtime, fuel: u64) void;
pub extern fn m3_GetFuel(runtime: ?*Runtime) u64;
pub extern fn m3_ConsumeFuel(runtime: ?*Runtime, units: u64) Result;
