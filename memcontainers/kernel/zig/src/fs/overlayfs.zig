//! src/fs/overlayfs.zig — overlay composition of a writable layer over read-only lowers (§2.5).
//!
//! Owns: the lower/upper stack view and lookup precedence that cowfs writes into.
//! Invariants: A7, A9.
//! Oracle (behavior to match): kernel/rust/src/fs/overlayfs.rs.
//! Not here: copy-up mechanics (cowfs.zig); mount policy (vfs.zig).
//!
//! Scaffold status: header-only. Fill Phase 3.

// (intentionally empty — scaffold stub; fill per the header contract above.)
