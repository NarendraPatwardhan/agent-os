//! src/fs/persistfs.zig — the persistence tree with async commit semantics (§2.5, §2.8).
//!
//! Owns: the /var/persist projection of egress/persist.zig, incl. snapshot blockers.
//! Invariants: A8 (pending commits are snapshot blockers surfaced via counters), A9. ASYNC: pending marker, not deep park (§7.4).
//! Oracle (behavior to match): kernel/rust/src/fs/persistfs.rs.
//! Not here: the commit state machine (egress/persist.zig).
//!
//! Scaffold status: header-only. Fill Phase 6.

// (intentionally empty — scaffold stub; fill per the header contract above.)
