//! state.zig — the root `Kernel` state, its allocator, and boot/lifecycle helpers
//! (ZIG_KERNEL §2.1, §4.2).
//!
//! Owns: the ONE `Kernel` struct reachable from a single global cell, the root
//!   allocator (wasm linear memory; wasm3 routes its allocation here — A6), and the
//!   lifecycle entrypoints `mc_init`/`mc_tick` route to. Every subsystem (task table,
//!   vfs, scheduler, guest runtimes, egress, services, control scratch) hangs off
//!   `Kernel` by value or by stable handle — never as a free-floating global.
//! Invariants: A8 (all mutable state in linear memory, reachable from `Kernel`, incl.
//!   every suspended guest's Asyncify buffer), A7 (deterministic scheduling/ordering),
//!   §4.2 (stable handles + generation counters; NO raw pointers as identity, NO
//!   subsystem-owned allocator that outlives `Kernel`). This is the file whose absence
//!   let the first attempt scatter `var pid1_guest`/`var jobs` across modules (§15.4);
//!   do not reintroduce module-level mutable singletons.
//! Consumes: :constants_zig; later state.zig wires task.zig, vfs.zig, scheduler.zig,
//!   boot.zig, guest.zig, egress/*, service/* as it grows.
//! Not here: exported symbols (main.zig); the mc_ctl_* scratch protocol (control.zig);
//!   base-image parsing (boot.zig). This file is ownership + lifecycle only.
//!
//! Scaffold status: `Kernel` is an empty root; lifecycle helpers return honest stubs.

const std = @import("std");

/// The single root kernel state. Everything that affects behavior lives here (A8) so a
/// snapshot of linear memory captures the whole machine. Fill field-by-field as each
/// subsystem lands; keep it the sole owner of the root allocator.
pub const Kernel = struct {
    booted: bool = false,
    // TODO(§2.1): allocator, namespace/vfs, scheduler, task table, guest runtimes,
    // control scratch, egress/persist/service registries, quiescence counters.
};

/// The single global cell. Access through helpers, never re-declared elsewhere (§4.2).
var g_kernel: Kernel = .{};

/// `mc_init`: construct the root `Kernel`, load the base image via `env`, parse the
/// boot contract, build the namespace, start the login/rescue shell, activate eager
/// services (§2.2). Boot runs to completion and never suspends — it is OFF the Asyncify
/// path (§7.4). Returns 0 on success; a broken image degrades to rescue, never traps.
pub fn init() i32 {
    g_kernel = .{ .booted = true };
    // TODO(§2.2): boot.load(&g_kernel) — base image, MCLS, mounts, boot contract, shell.
    return 0;
}

/// `mc_tick`: advance terminal input, jobs, control jobs, services, egress completions,
/// pending commits, and guest execution without monopolizing the host. ALWAYS returns
/// normally, even when a guest suspended mid-tick — its Asyncify buffer is parked and
/// other tasks continue (§2.1, §7.4).
pub fn tick() i32 {
    // TODO(§2.3): scheduler.step(&g_kernel).
    return 0;
}

pub fn input(ptr: [*]const u8, len: usize) void {
    _ = ptr;
    _ = len;
    // TODO(§2.1): feed the terminal line editor / stdin device.
}

pub fn resize(cols: i32, rows: i32) void {
    _ = cols;
    _ = rows;
    // TODO(§2.1): update the pty winsize device state.
}

pub fn commitLayer() i32 {
    // TODO(§2.5 cowfs): flush the writable overlay to a new commit layer.
    return 0;
}

/// §2.8 quiescence accounting. 0 here is the honest count *only while no egress exists*;
/// wire these to the real inflight/pending registries the moment egress/* or persist land.
pub fn inflightEgress() i32 {
    return 0;
}

pub fn pendingCommits() i32 {
    return 0;
}

pub fn quiesceRequest() i32 {
    return 0;
}

pub fn quiesceRelease() i32 {
    return 0;
}

/// Big-Kernel-Lock worker entry for a future shared-memory multi-worker host (mirrors
/// the Rust kernel's `threads`-gated export). No such host exists yet; stub returns 0.
pub fn workerEntry(arg: i32) i32 {
    _ = arg;
    return 0;
}
