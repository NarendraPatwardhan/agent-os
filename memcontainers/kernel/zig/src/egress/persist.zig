//! src/egress/persist.zig — the persistence commit state machine (§2.8).
//!
//! Owns: async commit lifecycle, pending-commit accounting, and snapshot blockers.
//! Invariants: A8 (pending commits surfaced via mc_pending_commits and block snapshots). ASYNC: shallow Pending (§7.4).
//! Oracle (behavior to match): kernel/rust/src/persist/mod.rs.
//! Not here: the /var/persist VFS face (fs/persistfs.zig).
//!
//! Scaffold status: header-only. Fill Phase 6.

// (intentionally empty — scaffold stub; fill per the header contract above.)
