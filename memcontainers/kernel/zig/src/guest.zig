//! guest.zig — the wasm3 guest driver AND the Asyncify unwind-stop / rewind-start
//! boundary (ZIG_KERNEL §2.7, §7.4). This is the most load-bearing file in the port.
//!
//! Owns: one wasm3 runtime per guest (its own stack + linear memory), eager compile
//!   (`m3_CompileModule` at load — off the metered path, so wasmi's lazy-translate
//!   landmine cannot arise), the module cache keyed by content hash, the native fuel
//!   policy (kill on lifetime exhaustion / yield on quantum), and the Zig-owned
//!   suspend/resume driver.
//!
//! THE BOUNDARY (§7.4, §7.7, §15.2 — read before touching Asyncify):
//!   mc_tick                    ← NOT instrumented
//!    └ guest driver (this file) ← NOT instrumented ← unwind STOPS here / rewind STARTS here
//!       └ m3_Call ─┐
//!         wasm3 op chain        ← INSTRUMENTED (only-list)
//!          └ mc_sys_* trampoline ← INSTRUMENTED (thin: records Pending, returns)
//!             └ kernel_suspend() → asyncify_start_unwind(buf)
//!   A blocking syscall or a quantum-yield calls `asyncify_start_unwind(buf)` in the
//!   trampoline; instrumented wasm3 frames spill and return up to THIS driver frame,
//!   which is off the only-list and therefore stops the unwind. The driver stashes the
//!   buffer in linear memory (keyed by task id), marks the task blocked, and returns
//!   normally to mc_tick. Resume calls `asyncify_start_rewind(buf)` and re-enters
//!   m3_Call. The host NEVER sees a suspend — there is no mc_prepare_rewind, no host
//!   asyncify_* call. If catching the unwind seems to need the host, the only-list is
//!   wrong (it must never be empty — §15.1); fix the scope, do not touch the host.
//!
//! Invariants: A4 (wasm3's libc satisfied in-module; adds no `env` imports; Asyncify
//!   adds only optional exports), A6 (wasm3 allocates via the kernel allocator), A8
//!   (all live wasm3 state + every Asyncify buffer lives in linear memory), §4.3
//!   (guest fault → errno via m3ApiCheckMem, never a host trap).
//! Consumes: wasm3/bindings.zig, wasm3/raw.zig, syscall.zig, runtime state in state.zig,
//!   :mc_zig (the generated `Pending` union), :constants_zig.
//! Not here: syscall POLICY/fulfillment (syscall.zig); the thin C bindings and raw
//!   handlers (wasm3/*); scheduler transitions (scheduler.zig). wasm3 itself is vendored
//!   at //third_party/wasm3 (a §15.5 cherry-pick) — never in this tree.
//!
//! This file is DELIBERATELY kept off the Asyncify only-list. The no-creep gate (§9)
//! fails the build if instrumentation ever reaches it. pcall's nested unwind/rewind is
//! the one delicate case (§7.6) — its own Phase-6 tests, not an assumed-solved detail.
//!
//! Status: the wasm3 library is vendored, bound, and linked (task #1). The DRIVER — eager
//! compile, per-guest runtime, the fuel counter, and the Asyncify unwind/rewind boundary —
//! lands in Phase 5. The externs it will own, for reference when filled:
//!   extern "asyncify" fn start_unwind(data: u32) void;  // + stop_unwind/start_rewind/stop_rewind

/// The thin wasm3 C-API bindings (§7.2). No policy here — the driver owns policy (§7.1).
pub const wasm3 = @import("wasm3/bindings.zig");

comptime {
    // The wasm3 allocator hooks (the d_m3AgentOsAllocator patch calls agent_os_wasm3_alloc/
    // free/realloc) must be compiled into the kernel so wasm3's C links against them (A6).
    _ = @import("wasm3/alloc.zig");
}
