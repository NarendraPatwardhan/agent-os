//! task.zig — the task table, pid allocation, fd tables, capabilities, process groups,
//! and signal state (ZIG_KERNEL §2.3, §4.1).
//!
//! Owns: stable task identities (slot map + generation counters — NOT raw pointers,
//!   §4.2), pid allocation, per-task fd tables, the 8-bit capability set (generated
//!   from constants), tier caps applied at exec, process groups, and signal state.
//!   Exec authority is `parent caps & binary tier/caps & requested caps`.
//! Invariants: pid 1 has special reparenting/liveness meaning; a blocked guest is a task
//!   whose wasm3 execution was Asyncify-suspended, its park descriptor in task state
//!   (§2.3). Guest runtime state may point back by stable id (m3_GetUserData), but this
//!   table owns lifecycle.
//! Consumes: :constants_zig (caps, tiers, signals, wait flags).
//! Not here: run-queue transitions and tick logic (scheduler.zig); pipe buffers
//!   (ipc/pipe.zig); the wasm3 runtimes themselves (guest.zig). This file is identity +
//!   capability + fd bookkeeping; the scheduler drives it.
//!
//! Scaffold status: header-only. Fill Phase 4 with scheduler.zig.

// (intentionally empty until Phase 4.)
