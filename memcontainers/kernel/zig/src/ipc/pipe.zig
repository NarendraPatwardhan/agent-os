//! src/ipc/pipe.zig — pipe ring buffers and reader/writer endpoint semantics (§2.6).
//!
//! Owns: stable ref-counted 64 KiB ring buffers with independent reader/writer ends, backpressure + wakeups, EOF on writer close, and EPIPE/signal on write without readers.
//! Invariants: stable pipe identity independent of scheduler storage moves (§2.6); correct fd-table interaction across spawn/exec/dup/close.
//! Oracle (behavior to match): kernel/rust/src/ipc/pipe.rs.
//! Not here: fd tables (task.zig); block/wake scheduling decisions (scheduler.zig). This file owns the buffer + endpoints; the scheduler owns WHEN a blocked task wakes.
//!
//! Scaffold status: header-only. Fill Phase 4 with scheduler.zig.

// (intentionally empty — scaffold stub; fill per the header contract above.)
