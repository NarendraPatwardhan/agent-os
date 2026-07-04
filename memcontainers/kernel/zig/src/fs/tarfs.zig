//! src/fs/tarfs.zig — read-only base-image view: POSIX ustar / gzip (§2.5).
//!
//! Owns: ustar+gzip parsing, hardlink/symlink treatment, read-only file/dir handles.
//! Invariants: A7 (deterministic order), A9 (errno).
//! Oracle (behavior to match): kernel/rust/src/fs/tarfs.rs.
//! Not here: COW writes (cowfs.zig); mount policy (vfs.zig).
//!
//! Scaffold status: header-only. Fill Phase 3.

// (intentionally empty — scaffold stub; fill per the header contract above.)
