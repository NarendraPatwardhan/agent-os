//! src/fs/servedfs.zig — guest-served filesystems (§2.5).
//!
//! Owns: request/response IDs, metadata cache behavior, and whole-file open behavior.
//! Invariants: A9, A7. ASYNC: pending marker, not deep park (§7.4).
//! Oracle (behavior to match): kernel/rust/src/fs/servedfs.rs.
//! Not here: the resident service registry (service/registry.zig).
//!
//! Scaffold status: header-only. Fill Phase 6.

// (intentionally empty — scaffold stub; fill per the header contract above.)
