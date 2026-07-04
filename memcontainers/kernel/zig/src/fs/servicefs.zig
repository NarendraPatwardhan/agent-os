//! src/fs/servicefs.zig — resident services projected under /svc (§2.5, §2.8).
//!
//! Owns: activation, sessions, request IDs, timeouts, size caps, and delegated handles.
//! Invariants: A9, A7. ASYNC: pending marker, not deep park (§7.4).
//! Oracle (behavior to match): kernel/rust/src/fs/servicefs.rs.
//! Not here: the registry/session lifecycle engine (service/registry.zig) — servicefs is its VFS face.
//!
//! Scaffold status: header-only. Fill Phase 6.

// (intentionally empty — scaffold stub; fill per the header contract above.)
