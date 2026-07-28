//! Opt-in kernel performance counters (PERF-013).
//!
//! ## Not machine state (A8)
//!
//! This module is **diagnostic session state**, not part of the VM identity. It is deliberately
//! **not** stored in [`crate::SystemState`]. All wasm statics live in linear memory, so hosts
//! **scrub when tracing is on** before snapshot capture, and **always scrub after restore**, so
//! MCSN images never carry a live `enabled` session. When tracing is off, the snapshot path does
//! not touch this module. When disabled, every update is a single predicted-false branch.
//!
//! ## Ops (`mc_ctl_perf`)
//!
//! - `PERF_OP_SCRUB` (0) — disable and zero (MCSN-safe)
//! - `PERF_OP_ENABLE` (1) — enable and zero
//! - `PERF_OP_READ` (2) — write fixed little-endian u64 counter block to the ctl buffer

use core::cell::Cell;

/// Number of little-endian u64 counters in the `mc_ctl_perf(op=2)` block.
pub const PERF_COUNTER_COUNT: usize = 11;

/// Fixed little-endian counter block size written by `mc_ctl_perf(op=2)`.
/// Not MCSN snapshot state — diagnostic bytes on the ctl channel only.
pub const PERF_COUNTER_BLOCK_BYTES: usize = PERF_COUNTER_COUNT * 8;

pub const PERF_OP_SCRUB: i32 = 0;
pub const PERF_OP_ENABLE: i32 = 1;
pub const PERF_OP_READ: i32 = 2;

// op=2 block field order (little-endian u64 each):
//   0 ticks, 1 runnable, 2 waiting, 3 tasks_spawned, 4 pipes_created,
//   5 module_cache_hits (Ready only), 6 module_cache_misses,
//   7 blocked_poll, 8 blocked_pipe, 9 blocked_wait_child,
//   10 kernel_memory_len (kernel linear memory bytes, not guest wasmi).

/// Process-global diagnostic counters. Outside SystemState so authors do not treat them as
/// snapshot identity; hosts still scrub before copy because all wasm statics live in linear memory.
///
/// `Sync` is asserted the same way as `SystemState`: the Big Kernel Lock / single-threaded
/// cooperative model ensure no concurrent interior access (SYSTEMS.md).
pub struct PerfState {
    enabled: Cell<bool>,
    ticks: Cell<u64>,
    runnable: Cell<u64>,
    waiting: Cell<u64>,
    tasks_spawned: Cell<u64>,
    pipes_created: Cell<u64>,
    module_cache_hits: Cell<u64>,
    module_cache_misses: Cell<u64>,
    blocked_poll: Cell<u64>,
    blocked_pipe: Cell<u64>,
    blocked_wait_child: Cell<u64>,
    kernel_memory_len: Cell<u64>,
}

// SAFETY: same concurrency model as `SystemState` — exclusive kernel critical sections only.
unsafe impl Sync for PerfState {}

impl PerfState {
    pub const fn new() -> Self {
        Self {
            enabled: Cell::new(false),
            ticks: Cell::new(0),
            runnable: Cell::new(0),
            waiting: Cell::new(0),
            tasks_spawned: Cell::new(0),
            pipes_created: Cell::new(0),
            module_cache_hits: Cell::new(0),
            module_cache_misses: Cell::new(0),
            blocked_poll: Cell::new(0),
            blocked_pipe: Cell::new(0),
            blocked_wait_child: Cell::new(0),
            kernel_memory_len: Cell::new(0),
        }
    }

    /// Disable and zero every field. Idempotent; safe on the snapshot/restore path.
    pub fn scrub(&self) {
        self.enabled.set(false);
        self.zero_counters();
        self.kernel_memory_len.set(0);
    }

    pub fn set_enabled(&self, on: bool) {
        self.enabled.set(on);
        self.zero_counters();
        // Always clear the gauge so enable starts from a clean slate (same as scrub).
        self.kernel_memory_len.set(0);
    }

    fn zero_counters(&self) {
        self.ticks.set(0);
        self.runnable.set(0);
        self.waiting.set(0);
        self.tasks_spawned.set(0);
        self.pipes_created.set(0);
        self.module_cache_hits.set(0);
        self.module_cache_misses.set(0);
        self.blocked_poll.set(0);
        self.blocked_pipe.set(0);
        self.blocked_wait_child.set(0);
    }

    #[inline(always)]
    fn bump(&self, cell: &Cell<u64>) {
        if !self.enabled.get() {
            return;
        }
        cell.set(cell.get().wrapping_add(1));
    }

    #[inline(always)]
    pub fn on_tick(&self, runnable: bool) {
        if !self.enabled.get() {
            return;
        }
        self.ticks.set(self.ticks.get().wrapping_add(1));
        if runnable {
            self.runnable.set(self.runnable.get().wrapping_add(1));
        } else {
            self.waiting.set(self.waiting.get().wrapping_add(1));
        }
    }

    #[inline(always)]
    pub fn on_task_spawned(&self) {
        self.bump(&self.tasks_spawned);
    }

    #[inline(always)]
    pub fn on_pipe_created(&self) {
        self.bump(&self.pipes_created);
    }

    /// Ready compilation cache hit (successful module only).
    #[inline(always)]
    pub fn on_module_hit(&self) {
        self.bump(&self.module_cache_hits);
    }

    #[inline(always)]
    pub fn on_module_miss(&self) {
        self.bump(&self.module_cache_misses);
    }

    #[inline(always)]
    pub fn on_blocked_poll(&self) {
        self.bump(&self.blocked_poll);
    }

    #[inline(always)]
    pub fn on_blocked_pipe(&self) {
        self.bump(&self.blocked_pipe);
    }

    #[inline(always)]
    pub fn on_blocked_wait_child(&self) {
        self.bump(&self.blocked_wait_child);
    }

    pub fn set_kernel_memory_len(&self, len: u64) {
        if self.enabled.get() {
            self.kernel_memory_len.set(len);
        }
    }

    /// Pack counters into `out` (must be ≥ [`PERF_COUNTER_BLOCK_BYTES`]).
    pub fn write_block(&self, out: &mut [u8]) -> usize {
        debug_assert!(out.len() >= PERF_COUNTER_BLOCK_BYTES);
        let vals = [
            self.ticks.get(),
            self.runnable.get(),
            self.waiting.get(),
            self.tasks_spawned.get(),
            self.pipes_created.get(),
            self.module_cache_hits.get(),
            self.module_cache_misses.get(),
            self.blocked_poll.get(),
            self.blocked_pipe.get(),
            self.blocked_wait_child.get(),
            self.kernel_memory_len.get(),
        ];
        debug_assert_eq!(vals.len(), PERF_COUNTER_COUNT);
        for (i, v) in vals.iter().enumerate() {
            out[i * 8..(i + 1) * 8].copy_from_slice(&v.to_le_bytes());
        }
        PERF_COUNTER_BLOCK_BYTES
    }
}

/// Global diagnostic counters. Not part of SystemState / machine identity (A8).
pub static PERF: PerfState = PerfState::new();
