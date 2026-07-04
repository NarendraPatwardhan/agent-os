//! src/fs/memfs.zig — mutable in-memory files, dirs, hard links, symlinks (§2.5).
//!
//! Owns: inodes, the path tree, link counts, rename semantics, timestamps, and metadata records.
//! Invariants: A7 (deterministic dir iteration), A9 (errno denials).
//! Oracle (behavior to match): kernel/rust/src/fs/memfs.rs.
//! Not here: mount resolution / path policy (vfs.zig). This is a backend behind the vtable.
//!
//! Scaffold status: header-only. Fill Phase 3 (first bootable namespace).

// (intentionally empty — scaffold stub; fill per the header contract above.)
