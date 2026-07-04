//! syscall.zig — fulfillment of generated `Pending` syscalls against kernel state
//! (ZIG_KERNEL §2.7, §5.1, §4.1).
//!
//! Owns: the policy half of the guest syscall ABI — one Zig fulfillment function per
//!   `mc_sys_*`, each taking a decoded generated argument struct and acting on the real
//!   VFS/pipes/scheduler/egress, then writing results back to guest memory. A would-block
//!   syscall maps to a `BlockedOn*` park; an in-flight host op maps to `Pending`. The
//!   dispatch from a recorded `Pending` variant to its fulfillment is generated (§5.1).
//! Invariants: §4.3 error discipline (bad fd → EBADF, bad path → EINVAL, denial →
//!   EPERM/EACCES, unsupported → ENOSYS — never a host trap); one checked path from guest
//!   memory to kernel values and one back (§4.3). Errno/ABI values come from :constants_zig
//!   and :mc_zig — never hand-copied (§5, §10.2).
//! Consumes: :mc_zig (the generated `Pending` union + syscall descriptors), :constants_zig,
//!   vfs.zig, ipc/pipe.zig, task.zig, scheduler.zig, egress/*, service/*.
//! Not here: the raw wasm3 handlers that RECORD a Pending (wasm3/raw.zig — thin, no
//!   policy); the suspend/resume mechanism (guest.zig). This file decides; it never
//!   touches wasm3 or Asyncify directly. The shallow-Pending discipline (§7.4) lives at
//!   the boundary between wasm3/raw.zig and this file: record shallow, fulfill here.
//!
//! Scaffold status: header-only. Fill Phase 5+, syscall group by group (§13 step 8),
//! each with a parity row before the next group.

// (intentionally empty until Phase 5.)
