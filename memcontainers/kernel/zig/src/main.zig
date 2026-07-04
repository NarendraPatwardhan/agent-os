//! main.zig — the kernel's host-facing edge: the exported control surface, the
//! single global `Kernel` cell, and panic/trap policy (ZIG_KERNEL §2.1, §4.1).
//!
//! Owns: every `pub export fn` the host calls (the 29 control exports of
//!   contracts/control.kdl, and NOTHING more), the boot-time construction of the
//!   root `Kernel`, and the freestanding panic handler. Each export is a thin
//!   shim that routes into `state.zig` (lifecycle/accounting) or `control.zig`
//!   (the mc_ctl_* scratch-buffer plane) — no policy lives here.
//! Invariants: A2 (wasm only), A4 (imports only `env`; Asyncify adds EXPORTS, never
//!   imports), A5 (no native side effects), §4.3 error discipline (a guest fault is
//!   an errno, never a host trap). The export set is exactly control.kdl — proven by
//!   the export-purity gate against `ctl_zig`'s descriptor table.
//! Consumes: //memcontainers/contracts:ctl_zig (export descriptors), :constants_zig.
//! Not here — and this is load-bearing (ZIG_KERNEL §7.4, §7.7, §15.2): there is NO
//!   `mc_prepare_rewind` and NO host-facing Asyncify-driving export. The suspend is
//!   caught INTERNALLY at the non-instrumented `guest.zig` driver frame; the host
//!   keeps calling `mc_tick` and never sees a suspend. The only Zig-specific symbols
//!   are the optional `asyncify_*` exports Binaryen emits, which no host calls. If a
//!   host change ever seems necessary, the scope is wrong — fix guest.zig, not main.
//!
//! Scaffold status: exports return honest stubs (lifecycle 0, control -ENOSYS, buf
//! null) and route through state/control. Fill each callee, not this file.

const constants = @import("constants_zig");
const state = @import("state.zig");
const control = @import("control.zig");

// Freestanding panic policy (§4.3): only a genuinely-impossible invariant violation
// may trap; everything guest-triggered is converted to an errno upstream. Kept trivial
// in the scaffold; the real handler records diagnostics into kernel state before trap.
pub const panic = std.debug.FullPanic(struct {
    pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        _ = msg;
        _ = first_trace_addr;
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

// NOTE (§2.8): these return 0 only because the scaffold has no egress/persist/service
// subsystem yet — that is the honest count. They MUST reflect real inflight/pending
// state the moment egress/* or persist land, or every snapshot gate is a lie.
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

comptime {
    // Anchor the errno namespace into the build so a contract rename breaks loudly here
    // rather than at the first fill. (§5.2 drift discipline.)
    _ = constants.ENOSYS;
}
