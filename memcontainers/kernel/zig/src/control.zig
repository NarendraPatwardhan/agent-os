//! control.zig — the `mc_ctl_*` control plane and the host↔kernel scratch-buffer
//! protocol (ZIG_KERNEL §2.1, §4.1).
//!
//! Owns: the scratch buffer the host writes requests into / reads results out of
//!   (`mc_ctl_buf`), and the control operations that drive the kernel out-of-band from
//!   the terminal: VFS control (read/write/readdir/stat/mkdir/unlink/chmod/symlink/
//!   mount/unmount), exec jobs (`/bin/sh -c` capture), and resident-service calls.
//!   Control ops return results THROUGH the scratch buffer, never as host-owned data.
//! Invariants: A9 (denials are errno — EPERM/EACCES — never traps), §1.3 (the control
//!   ABI is contracts/control.kdl, language-neutral; this file must not grow an export
//!   the contract lacks, and MUST NOT reintroduce `mc_prepare_rewind` — §15.2).
//! Consumes: :constants_zig; later :ctl_zig (ExecRequest/SvcRequest wire types) and
//!   vfs.zig (the real namespace the control VFS ops dispatch into).
//! Not here: the exports themselves (main.zig); guest VFS syscall fulfillment
//!   (syscall.zig + vfs.zig); the scheduler that runs control-exec children
//!   (scheduler.zig). Control is a thin request/response façade over vfs + scheduler.
//!
//! Scaffold status: every op returns -ENOSYS and `buf` returns null. Fill Phase 3
//! (control VFS) first, then exec/svc jobs, dispatching into vfs.zig — never a
//! conflated control+memfs+tar file like the first attempt's control_fs.zig (§15.4).

const constants = @import("constants_zig");

inline fn nosys() i32 {
    return -constants.ENOSYS;
}

/// Return a pointer into the kernel scratch buffer sized for `len` bytes, or null if it
/// cannot be served. All control I/O flows through this buffer (no host-owned memory).
pub fn buf(len: usize) ?[*]u8 {
    _ = len;
    // TODO(§2.1): hand out the reusable control scratch region from Kernel state.
    return null;
}

// ── Control VFS (Phase 3) — dispatch into vfs.zig once it exists ──────────────────
pub fn read(path_ptr: u32, path_len: u32) i32 {
    _ = path_ptr;
    _ = path_len;
    return nosys();
}

pub fn readlink(path_ptr: u32, path_len: u32) i32 {
    _ = path_ptr;
    _ = path_len;
    return nosys();
}

pub fn write(path_ptr: u32, path_len: u32, data_ptr: u32, data_len: u32) i32 {
    _ = path_ptr;
    _ = path_len;
    _ = data_ptr;
    _ = data_len;
    return nosys();
}

pub fn readdir(path_ptr: u32, path_len: u32) i32 {
    _ = path_ptr;
    _ = path_len;
    return nosys();
}

pub fn stat(path_ptr: u32, path_len: u32) i32 {
    _ = path_ptr;
    _ = path_len;
    return nosys();
}

pub fn mkdir(path_ptr: u32, path_len: u32) i32 {
    _ = path_ptr;
    _ = path_len;
    return nosys();
}

pub fn unlink(path_ptr: u32, path_len: u32) i32 {
    _ = path_ptr;
    _ = path_len;
    return nosys();
}

pub fn chmod(path_ptr: u32, path_len: u32, mode: u32) i32 {
    _ = path_ptr;
    _ = path_len;
    _ = mode;
    return nosys();
}

pub fn symlink(target_ptr: u32, target_len: u32, link_ptr: u32, link_len: u32) i32 {
    _ = target_ptr;
    _ = target_len;
    _ = link_ptr;
    _ = link_len;
    return nosys();
}

pub fn mount(path_ptr: u32, path_len: u32, read_only: i32) i32 {
    _ = path_ptr;
    _ = path_len;
    _ = read_only;
    return nosys();
}

pub fn unmount(path_ptr: u32, path_len: u32) i32 {
    _ = path_ptr;
    _ = path_len;
    return nosys();
}

// ── Control exec jobs (Phase 4) — `/bin/sh -c`, captured via scheduler child slots ─
pub fn execStart(request_len: u32) i32 {
    _ = request_len;
    return nosys();
}

pub fn execPoll(job_id: u32) i32 {
    _ = job_id;
    return nosys();
}

pub fn execPeek(job_id: u32) i32 {
    _ = job_id;
    return nosys();
}

pub fn execClose(job_id: u32) i32 {
    _ = job_id;
    return nosys();
}

// ── Resident-service calls (Phase 6) — dispatch into service/registry.zig ─────────
pub fn svcCallStart(request_len: u32) i32 {
    _ = request_len;
    return nosys();
}

pub fn svcCallPoll(job_id: u32) i32 {
    _ = job_id;
    return nosys();
}

pub fn svcCallClose(job_id: u32) i32 {
    _ = job_id;
    return nosys();
}
