//! src/fs/devfs.zig — terminal and device files (§2.5).
//!
//! Owns: stdin/stdout/stderr device nodes and device metadata behavior.
//! Invariants: A5 (device effects flow through the bridge), A9.
//! Oracle (behavior to match): kernel/rust/src/fs/devfs.rs.
//! Not here: the terminal line editor (state.zig/scheduler.zig); pipes (ipc/pipe.zig).
//!
//! Scaffold status: header-only. Fill Phase 3.

// (intentionally empty — scaffold stub; fill per the header contract above.)
