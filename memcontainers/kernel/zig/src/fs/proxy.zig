//! src/fs/proxy.zig — the shared metadata/dirent codec used across backends (§2.5).
//!
//! Owns: exact binary decoding of metadata + dirents, escape rejection, unsupported-symlink behavior.
//! Invariants: byte-exact decoding (parity is bit-for-bit), A9.
//! Oracle (behavior to match): kernel/rust/src/fs/proxy.rs.
//! Not here: backend-specific storage — this is the shared codec only.
//!
//! Scaffold status: header-only. Fill alongside the first backend that needs it.

// (intentionally empty — scaffold stub; fill per the header contract above.)
