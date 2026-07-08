//! svc.zig - host-control resident service calls.
//!
//! Owns: service-call job creation, polling, closing, session progression, and
//!   cleanup of service request payloads.
//! Invariants: service names and request sizes are validated before enqueue,
//!   sessions are released on completion, and responses are returned through the
//!   scratch buffer.
//! Consumes: service registry state, scheduler progression, scratch-buffer
//!   helpers, wire codecs, control job-id allocation, and shared errno helpers.
//! Not here: VFS control operations, exec-child capture, or raw wire primitives.

const std = @import("std");
const constants = @import("constants_zig");
const vfs = @import("../vfs.zig");
const state = @import("../state.zig");
const task_mod = @import("../task.zig");
const registry = @import("../service/registry.zig");
const buf_mod = @import("buf.zig");
const exec = @import("exec.zig");
const fs = @import("fs.zig");
const wire = @import("wire.zig");

const ctlBytes = buf_mod.ctlBytes;
const replaceBuffer = buf_mod.replaceBuffer;
const allocCtlJobId = exec.allocCtlJobId;
const neg = fs.neg;
const decodeSvcRequest = wire.decodeSvcRequest;
const encodeSvcResponse = wire.encodeSvcResponse;

fn freeCtlSvcConnectPayload(k: *state.Kernel, job: *state.CtlSvcJob) void {
    if (job.name) |name| {
        k.gpa.free(name);
        job.name = null;
    }
    if (job.req) |req| {
        k.gpa.free(req);
        job.req = null;
    }
}

fn finishCtlSvcJob(k: *state.Kernel, job: *state.CtlSvcJob, status: i32) void {
    if (job.channel) |channel| {
        channel.dropSession(job.session);
        channel.release();
        job.channel = null;
    }
    freeCtlSvcConnectPayload(k, job);
    job.status = status;
    job.done = true;
}

fn advanceCtlSvcJob(k: *state.Kernel, job: *state.CtlSvcJob) bool {
    if (job.done) return true;
    while (true) {
        if (job.channel == null) {
            const name = job.name orelse {
                finishCtlSvcJob(k, job, constants.EIO);
                return true;
            };
            const channel = switch (state.serviceChannel(k, name)) {
                .ready => |ch| ch,
                .pending => return false,
                .errno => |errno| {
                    finishCtlSvcJob(k, job, errno);
                    return true;
                },
            };
            const req = job.req orelse {
                finishCtlSvcJob(k, job, constants.EIO);
                return true;
            };
            const session = channel.openSession(vfs.SYSTEM_CALLER);
            const req_id = channel.enqueue(session, vfs.SYSTEM_CALLER, task_mod.Capabilities.all().bits, req, &.{}) orelse {
                channel.dropSession(session);
                finishCtlSvcJob(k, job, constants.EIO);
                return true;
            };
            job.channel = channel.retain();
            job.session = session;
            job.req_id = req_id;
            freeCtlSvcConnectPayload(k, job);
        }

        const channel = job.channel orelse {
            finishCtlSvcJob(k, job, constants.EIO);
            return true;
        };
        var tmp: [4096]u8 = undefined;
        while (true) {
            switch (channel.drainResponse(job.session, job.req_id, &tmp)) {
                .pending => return false,
                .got => |n| job.out.appendSlice(k.gpa, tmp[0..n]) catch @panic("OOM"),
                .eof => {
                    finishCtlSvcJob(k, job, constants.ESUCCESS);
                    return true;
                },
                .failed => |errno| {
                    job.out.clearRetainingCapacity();
                    finishCtlSvcJob(k, job, errno);
                    return true;
                },
                .closed => {
                    job.out.clearRetainingCapacity();
                    finishCtlSvcJob(k, job, constants.EIO);
                    return true;
                },
            }
        }
    }
}

pub fn svcCallStart(request_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const req_bytes = ctlBytes(a, 0, request_len) orelse return neg(constants.EINVAL);
    const req = decodeSvcRequest(a, req_bytes) orelse return neg(constants.EINVAL);
    if (!registry.validServiceName(req.service)) return neg(constants.EINVAL);
    if (req.request.len > registry.MAX_SVC_REQUEST_BYTES) return neg(constants.EINVAL);
    const id = allocCtlJobId(k);
    k.ctl_svc_jobs.put(k.gpa, id, .{
        .name = k.gpa.dupe(u8, req.service) catch @panic("OOM"),
        .req = k.gpa.dupe(u8, req.request) catch @panic("OOM"),
    }) catch @panic("OOM");
    return @intCast(id);
}
pub fn svcCallPoll(job_id: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    {
        const job = k.ctl_svc_jobs.getPtr(job_id) orelse return neg(constants.EINVAL);
        if (!job.done) {
            k.sched.checkUnblocked();
            _ = state.stepReadyRound(k);
        }
    }
    {
        const job = k.ctl_svc_jobs.getPtr(job_id) orelse return neg(constants.EINVAL);
        if (!advanceCtlSvcJob(k, job)) return 0;
    }
    var kv = k.ctl_svc_jobs.fetchRemove(job_id) orelse return neg(constants.EINVAL);
    defer kv.value.deinit(k.gpa);
    const encoded = encodeSvcResponse(k.gpa, kv.value.status, kv.value.out.items);
    defer k.gpa.free(encoded);
    replaceBuffer(encoded);
    return @intCast(encoded.len);
}
pub fn svcCallClose(job_id: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var kv = k.ctl_svc_jobs.fetchRemove(job_id) orelse return neg(constants.EINVAL);
    kv.value.deinit(k.gpa);
    return 0;
}
