//! src/fs/netfs.zig — capability-gated HTTP/WebSocket projected as a filesystem (§2.5).
//!
//! Owns: the /net tree that projects egress/net.zig; request/response file handles.
//! Invariants: A9 (capability denials → EPERM/EACCES), A7. ASYNC backend: return a pending marker to the trampoline, never park deep (§7.4).
//! Oracle (behavior to match): kernel/rust/src/fs/netfs.rs.
//! Not here: the egress state machine itself (egress/net.zig) — netfs is its VFS face.
//!
//! Scaffold status: header-only. Fill Phase 6.

// (intentionally empty — scaffold stub; fill per the header contract above.)
