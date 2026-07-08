//! guest/pcall.zig - standalone pcall frame helpers.
//!
//! Owns: pcall frame shape, stack bound checks, and native-boundary capture.
//! Invariants: captured return slots are validated against the WAMR operand
//!   stack before host code writes through them.
//! Consumes: the WAMR binding structs that expose exec-env and interp frames.
//! Not here: GuestRuntime pcall stack mutation or suspend/resume policy.

const wamr = @import("../wamr/bindings.zig");

pub const PCALL_STACK_MAX: usize = 32;

pub const PcallFrame = struct {
    saved_sp: i32,
    return_slot: ?*u32 = null,
    native_frame: ?*wamr.InterpFrame = null,
    caller_frame: ?*wamr.InterpFrame = null,
    waiting: bool = false,
};

pub const NativeBoundary = struct {
    native_frame: *wamr.InterpFrame,
    caller_frame: *wamr.InterpFrame,
    return_slot: *u32,
};

/// True if `slot` (a return-slot pointer derived from a caller frame's `lp` + `ret_offset`) lies
/// within the exec_env's wasm operand stack. The pcall bridge trusts WAMR's private InterpFrame
/// layout; a WAMR upgrade that shifted fields (despite the comptime pin in bindings.zig) would yield
/// a garbage lp/ret_offset pointing outside the stack. Reject it and fail closed rather than perform
/// an out-of-bounds host write into whatever the bad pointer names.
pub fn returnSlotInBounds(env: *wamr.ExecEnv, slot: *const u32) bool {
    const bottom = @intFromPtr(env.wasm_stack.bottom orelse return false);
    const boundary = @intFromPtr(env.wasm_stack.top_boundary orelse return false);
    const p = @intFromPtr(slot);
    return p >= bottom and p + @sizeOf(u32) <= boundary;
}

pub fn captureReturnSlot(exec_env: ?*wamr.ExecEnv) ?*u32 {
    const env = exec_env orelse return null;
    const native_frame = env.cur_frame orelse return null;
    const caller = native_frame.prev_frame orelse return null;
    const slot = &caller.lp[caller.ret_offset];
    if (!returnSlotInBounds(env, slot)) return null;
    return slot;
}

pub fn captureNativeBoundary(exec_env: ?*wamr.ExecEnv) ?NativeBoundary {
    const env = exec_env orelse return null;
    const native_frame = env.cur_frame orelse return null;
    const caller = native_frame.prev_frame orelse return null;
    const slot = &caller.lp[caller.ret_offset];
    if (!returnSlotInBounds(env, slot)) return null;
    return .{
        .native_frame = native_frame,
        .caller_frame = caller,
        .return_slot = slot,
    };
}
