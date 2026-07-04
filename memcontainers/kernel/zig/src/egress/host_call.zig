//! src/egress/host_call.zig — opaque host-call operations (§2.8).
//!
//! Owns: the request/poll/complete lifecycle for opaque host calls and their inflight accounting.
//! Invariants: A9, A8 (inflight host calls block snapshots). ASYNC: shallow Pending (§7.4).
//! Oracle (behavior to match): kernel/rust/src/host_call.rs.
//! Not here: the mountfs VFS face (fs/mountfs.zig).
//!
//! Scaffold status: header-only. Fill Phase 6.

// (intentionally empty — scaffold stub; fill per the header contract above.)
