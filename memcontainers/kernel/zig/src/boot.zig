//! boot.zig — base-image load, namespace construction, boot contract, and the initial
//! shell (ZIG_KERNEL §2.2, §4.1).
//!
//! Owns: `mc_load_base_image` via the bridge, MCLS layer-stack parsing, mounting a
//!   writable COW view over the read-only base (or falling back to memfs), mounting
//!   /dev /tmp /var/persist /proc /net /env /svc /tools, applying boot-contract settings
//!   (incl. fuel/mem ceilings — §7.3), starting the login or rescue shell, and
//!   activating eager resident services.
//! Invariants: boot runs to completion and NEVER suspends — it is OFF the Asyncify path
//!   (§7.4). A failed base image must degrade to the same recoverable rescue shell the
//!   Rust oracle exposes, never trap the host (§2.2).
//! Consumes: bridge.zig (base image + boot contract), vfs.zig + fs/{tarfs,cowfs,memfs,
//!   devfs,envfs,procfs,...}, task.zig (pid 1), service/registry.zig (eager services).
//! Not here: mount RESOLUTION and path policy (vfs.zig); backend bytes (fs/*); the
//!   control plane (control.zig). Boot orchestrates; it does not implement backends.
//!
//! Scaffold status: header-only. state.init() calls into here once Phase 3 lands.

// (intentionally empty until Phase 3.)
