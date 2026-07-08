//! main.zig — the kernel's host-facing edge: the exported control surface, the
//! single global `Kernel` cell, and panic/trap policy (ZIG_KERNEL §2.1, §4.1).
//!
//! Owns: every `pub export fn` the host calls (the 29 control exports of
//!   contracts/control.kdl, and NOTHING more), the boot-time construction of the
//!   root `Kernel`, and the freestanding panic handler. Each export is a thin
//!   shim that routes into `state.zig` (lifecycle/accounting) or `control.zig`
//!   (the mc_ctl_* scratch-buffer plane) — no policy lives here.
//! Invariants: A2 (wasm only), A4 (imports only `env`), A5 (no native side effects),
//!   §4.3 error discipline (a guest fault is an errno, never a host trap). The export set
//!   is exactly control.kdl — enforced by `exports_covered` below, which fails the kernel
//!   build if a control.kdl export lacks a `pub export fn` here (the mirror of
//!   `bridge.contract_covered` for the host→kernel direction).
//! Consumes: //memcontainers/contracts:ctl_zig (the EXPORTS descriptor — the drift oracle),
//!   :constants_zig.
//! Not here: guest suspend/resume. WAMR re-entry is owned by `guest.zig`; the host
//! keeps calling `mc_tick` and never sees a suspend.

const constants = @import("constants_zig");
const ctl = @import("ctl_zig");
const bridge = @import("bridge.zig");
const state = @import("state.zig");
const control = @import("control.zig");

// Freestanding panic policy (§4.3): only a genuinely-impossible invariant violation may trap;
// everything guest-triggered is converted to an errno upstream (guest-facing syscalls fail closed
// with an errno, not @panic). Reaching here therefore means a real kernel invariant broke — so
// record the message to the host before trapping rather than trapping silently. No allocation on
// this path: the allocator may be the very thing that failed.
pub const panic = std.debug.FullPanic(struct {
    pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        _ = first_trace_addr;
        const prefix = "kernel panic: ";
        bridge.mc_stderr_write(prefix, prefix.len);
        bridge.mc_stderr_write(msg.ptr, msg.len);
        bridge.mc_stderr_write("\n", 1);
        @trap();
    }
}.panic);
const std = @import("std");

// ── Lifecycle + snapshot/quiescence accounting → state.zig ───────────────────────
pub export fn mc_init() i32 {
    return state.init();
}

pub export fn mc_tick() i32 {
    return state.tick();
}

pub export fn mc_input(ptr: [*]const u8, len: usize) void {
    state.input(ptr, len);
}

pub export fn mc_resize(cols: i32, rows: i32) void {
    state.resize(cols, rows);
}

pub export fn mc_commit_layer() i32 {
    return state.commitLayer();
}

// The snapshot quiescence gate (§2.8, A8): the host refuses to snapshot while these are
// non-zero. `inflightEgress` sums the live net + host_call + persist + service-call handles
// (state.inflightEgress); a raw host handle mid-flight would not survive a restore, so a
// snapshot is only ever taken at a quiescent boundary.
pub export fn mc_inflight_egress() i32 {
    return state.inflightEgress();
}

pub export fn mc_pending_commits() i32 {
    return state.pendingCommits();
}

pub export fn mc_quiesce_request() i32 {
    return state.quiesceRequest();
}

pub export fn mc_quiesce_release() i32 {
    return state.quiesceRelease();
}

pub export fn mc_worker_entry(arg: i32) i32 {
    return state.workerEntry(arg);
}

// ── Control plane (host↔kernel scratch buffer protocol) → control.zig ────────────
pub export fn mc_ctl_buf(len: usize) ?[*]u8 {
    return control.buf(len);
}

pub export fn mc_ctl_read(path_ptr: u32, path_len: u32) i32 {
    return control.read(path_ptr, path_len);
}

pub export fn mc_ctl_readlink(path_ptr: u32, path_len: u32) i32 {
    return control.readlink(path_ptr, path_len);
}

pub export fn mc_ctl_write(path_ptr: u32, path_len: u32, data_ptr: u32, data_len: u32) i32 {
    return control.write(path_ptr, path_len, data_ptr, data_len);
}

pub export fn mc_ctl_readdir(path_ptr: u32, path_len: u32) i32 {
    return control.readdir(path_ptr, path_len);
}

pub export fn mc_ctl_stat(path_ptr: u32, path_len: u32) i32 {
    return control.stat(path_ptr, path_len);
}

pub export fn mc_ctl_mkdir(path_ptr: u32, path_len: u32) i32 {
    return control.mkdir(path_ptr, path_len);
}

pub export fn mc_ctl_unlink(path_ptr: u32, path_len: u32) i32 {
    return control.unlink(path_ptr, path_len);
}

pub export fn mc_ctl_chmod(path_ptr: u32, path_len: u32, mode: u32) i32 {
    return control.chmod(path_ptr, path_len, mode);
}

pub export fn mc_ctl_symlink(target_ptr: u32, target_len: u32, link_ptr: u32, link_len: u32) i32 {
    return control.symlink(target_ptr, target_len, link_ptr, link_len);
}

pub export fn mc_ctl_mount(path_ptr: u32, path_len: u32, read_only: i32) i32 {
    return control.mount(path_ptr, path_len, read_only);
}

pub export fn mc_ctl_unmount(path_ptr: u32, path_len: u32) i32 {
    return control.unmount(path_ptr, path_len);
}

pub export fn mc_ctl_exec_start(request_len: u32) i32 {
    return control.execStart(request_len);
}

pub export fn mc_ctl_exec_poll(job_id: u32) i32 {
    return control.execPoll(job_id);
}

pub export fn mc_ctl_exec_peek(job_id: u32) i32 {
    return control.execPeek(job_id);
}

pub export fn mc_ctl_exec_close(job_id: u32) i32 {
    return control.execClose(job_id);
}

pub export fn mc_ctl_svc_call_start(request_len: u32) i32 {
    return control.svcCallStart(request_len);
}

pub export fn mc_ctl_svc_call_poll(job_id: u32) i32 {
    return control.svcCallPoll(job_id);
}

pub export fn mc_ctl_svc_call_close(job_id: u32) i32 {
    return control.svcCallClose(job_id);
}

/// Export-purity gate (§5.2): every control export `control.kdl` declares is defined below as a
/// `pub export fn`. Referenced from the comptime block so a control.kdl add/rename breaks the
/// kernel build here rather than drifting silently from the host — the host→kernel mirror of
/// `bridge.contract_covered`. `@hasDecl` is type-level, so no export materializes from this check.
pub const exports_covered = blk: {
    for (ctl.EXPORTS) |desc| {
        if (!@hasDecl(@This(), desc.name)) {
            @compileError("main.zig: missing `pub export fn` for control export '" ++ desc.name ++ "' — control.kdl changed; declare it here.");
        }
    }
    break :blk ctl.EXPORTS.len;
};

comptime {
    // Anchor the generated contract surfaces into the build so a contract change breaks loudly
    // here rather than at a call site (§5.2 drift discipline): the errno namespace, the bridge's
    // per-import coverage check, and the control-export coverage gate.
    _ = constants.ENOSYS;
    _ = bridge.contract_covered;
    _ = exports_covered;
    _ = @import("guest.zig"); // compile the WAMR guest driver and native bridge
}
