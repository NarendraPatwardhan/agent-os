//! vfs.zig — the per-task namespace and mount resolution (ZIG_KERNEL §2.4, §4.1).
//!
//! Owns: the mount table, longest-prefix mount resolution, path canonicalization (one
//!   symlink-following path, fixed hop limit, `..` cannot escape a confinement root),
//!   stat encoding via the generated offsets, and open/read/write/stat dispatch to a
//!   backend vtable. Distinct denials for capability vs mount vs filesystem level.
//! Invariants: A7 (deterministic directory iteration order), A9 (denials are errno,
//!   not traps); §4.3 error discipline (guest fault → errno, never a host trap).
//! Consumes: :constants_zig (open/seek/poll/stat/mount flags), :mc_zig (path syscalls),
//!   fs/*.zig (the backend vtable implementations).
//! Not here: backend IMPLEMENTATIONS (fs/*.zig); the control scratch protocol
//!   (control.zig); base-image tar seeding (boot.zig). This file is dispatch + policy
//!   only — the anti-conflation rule that the first attempt's control_fs.zig broke
//!   (§15.4). Namespace + mount + path + stat live here; bytes live in fs/*.
//!
//! Scaffold status: header-only. Fill Phase 3, ahead of full guest execution.

// (intentionally empty until Phase 3.)
