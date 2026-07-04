//! src/fs/mountfs.zig — host-backed mounted filesystems (§2.5).
//!
//! Owns: host-call request shape, polling, stale-call aging, and commit draining.
//! Invariants: A9, A8 (stale calls are snapshot blockers). ASYNC: pending marker (§7.4).
//! Oracle (behavior to match): kernel/rust/src/fs/mountfs.rs.
//! Not here: the opaque host_call engine (egress/host_call.zig).
//!
//! Scaffold status: header-only. Fill Phase 6.

// (intentionally empty — scaffold stub; fill per the header contract above.)
