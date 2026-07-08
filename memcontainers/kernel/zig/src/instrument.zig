//! instrument.zig — dev-only spawn/instantiate phase profiler (OFF by default).
//!
//! The kernel cannot measure real wall-time: `mc_time_monotonic` is a DETERMINISTIC clock (it
//! advances a fixed step per call so runs are reproducible, A7). So to attribute where a guest spawn
//! spends time, the kernel emits phase-boundary MARKERS through `mc_log` — `"mcinstr B <phase>"` and
//! `"mcinstr E <phase>"` — and the wasmtime host timestamps them with its REAL clock, accumulating
//! per-phase totals (hosts/wasmtime `Instr` + `KernelHost::instr_report`).
//!
//! Gated by `enabled`: false in production, so `begin`/`end` compile to nothing, `mc_log` is never
//! referenced from here (stays a lazy, unmaterialized import), and there is zero added bridge traffic.
//! Flip to true + rebuild to profile, then read the breakdown from a bench via `host.instr_report()`.
//!
//! Not here: any timing logic — the host owns the clock; this only marks boundaries.

const std = @import("std");
const bridge = @import("bridge.zig");

/// Flip to `true` and rebuild to profile the guest spawn path. Keep `false` in committed code.
pub const enabled = false;

pub const Phase = enum { load, loadmiss, instantiate, execenv, run, teardown };

/// Open a timed phase (emits the host-timestamped begin marker).
pub fn begin(comptime p: Phase) void {
    if (comptime !enabled) return;
    emit("B ", @tagName(p));
}

/// Close a timed phase (emits the end marker; the host folds the elapsed real time into the total).
pub fn end(comptime p: Phase) void {
    if (comptime !enabled) return;
    emit("E ", @tagName(p));
}

fn emit(comptime edge: []const u8, comptime phase: []const u8) void {
    const msg = "mcinstr " ++ edge ++ phase;
    bridge.mc_log(0, msg.ptr, msg.len);
}
