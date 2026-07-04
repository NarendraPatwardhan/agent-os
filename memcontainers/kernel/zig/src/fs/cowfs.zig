//! src/fs/cowfs.zig — writable copy-on-write layer over a read-only base (§2.5).
//!
//! Owns: tombstones, copy-up, commit-layer generation, and conflict behavior.
//! Invariants: A7, A9; commit-layer generation is deterministic and snapshot-safe (A8).
//! Oracle (behavior to match): kernel/rust/src/fs/cowfs.rs.
//! Not here: overlay composition (overlayfs.zig); the base bytes (tarfs.zig).
//!
//! Scaffold status: header-only. Fill Phase 3.

// (intentionally empty — scaffold stub; fill per the header contract above.)
