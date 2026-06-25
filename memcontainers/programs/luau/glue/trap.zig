//! trap.zig — kernel-backed protected-call + raise (was loom/src/mc_runtime.cpp; the C/C++ → Zig
//! rewrite, SYSTEMS.md). The Luau guest is built `-fno-exceptions` and runs under wasmi, which has
//! neither the C++ exception runtime nor the wasm-EH proposal setjmp/longjmp needs, so the kernel
//! supplies the unwind: `mc_sys_pcall` runs the stashed thunk as a NESTED guest call (a trap
//! boundary), and `mc_sys_set_throw` records the code a subsequent trap hands back. The C++ side
//! (the patched VM `ldo.cpp`, and error_channel.h's Channel<T>) reaches these through trap.h. See
//! third_party/luau/SYSTEM.md.

const mc = @import("mc");

// The C thunk the kernel-invoked dispatcher runs. Single-threaded guest → one global slot, saved and
// restored across nested protected calls.
var g_thunk: ?*const fn (?*anyopaque) callconv(.c) void = null;
var g_thunk_ud: ?*anyopaque = null;

/// Run fn(ud) under a kernel trap boundary. Returns 0 if fn returned normally, else the mc_raise()
/// code. Re-entrant: a protected call nested inside fn saves/restores the prior thunk.
export fn mc_protected_call(func: *const fn (?*anyopaque) callconv(.c) void, ud: ?*anyopaque) c_int {
    const saved_fn = g_thunk;
    const saved_ud = g_thunk_ud;
    g_thunk = func;
    g_thunk_ud = ud;
    const code = mc.mc_sys_pcall();
    g_thunk = saved_fn;
    g_thunk_ud = saved_ud;
    return @intCast(code);
}

/// Called RE-ENTRANTLY by the kernel from within `mc_sys_pcall` — it resolves this export and invokes
/// it as a fresh nested guest call. Runs the stashed thunk; an mc_raise() inside traps back past here
/// to the kernel boundary. The wasm export name is fixed at `__mc_pcall_run`.
export fn __mc_pcall_run() void {
    if (g_thunk) |t| t(g_thunk_ud);
}

/// Record `code`, then trap to the nearest mc_protected_call boundary. Never returns (wasmi unwinds
/// the native stack to the nearest `mc_sys_pcall`).
export fn mc_raise(code: c_int) noreturn {
    _ = mc.mc_sys_set_throw(@intCast(code));
    @trap();
}
