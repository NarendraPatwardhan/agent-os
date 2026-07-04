//! scheduler.zig — cooperative ready/running/blocked/zombie transitions, ticks,
//! waitpid, and wakeups (ZIG_KERNEL §2.3, §4.1).
//!
//! Owns: the run queues, the per-tick stepping of pid 1 + child guests, block/unblock on
//!   pipe read/write and child wait, waitpid semantics, foreground/background job
//!   control, zombie reaping, and the wakeups that resume Asyncify-suspended guests.
//! Invariants: A7 (scheduler decisions, retry ordering, and service activation are
//!   replayable). Deterministic ordering is contractual — tests observe it. A tick never
//!   monopolizes the host; a suspended guest is just a blocked task (§2.1).
//! Consumes: task.zig (identities/fd/caps), guest.zig (step a guest's wasm3 runtime),
//!   ipc/pipe.zig (block reasons).
//! Not here: task identity/allocation (task.zig); the wasm3 driver + Asyncify boundary
//!   (guest.zig); pipe ring buffers (ipc/pipe.zig). The scheduler owns WHEN a task runs,
//!   not HOW a guest executes.
//!
//! Scaffold status: header-only. state.tick() calls into here once Phase 4 lands.

// (intentionally empty until Phase 4.)
