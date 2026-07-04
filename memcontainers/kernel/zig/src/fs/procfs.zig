//! src/fs/procfs.zig — the process view exposed to userland (§2.5).
//!
//! Owns: task metadata records rendered for /proc as tests and userland observe them.
//! Invariants: A7 (stable ordering), A9.
//! Oracle (behavior to match): kernel/rust/src/fs/procfs.rs.
//! Not here: the task table itself (task.zig) — procfs only RENDERS it.
//!
//! Scaffold status: header-only. Fill Phase 3/4.

// (intentionally empty — scaffold stub; fill per the header contract above.)
