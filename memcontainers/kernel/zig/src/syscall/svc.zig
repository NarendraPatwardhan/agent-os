//! svc.zig - service registry syscall fulfillment.
//!
//! Owns: service serve/recv/respond/connect/call syscalls, service envelopes,
//!   delegated handle installation, and outgoing delegated-fd capture.
//! Invariants: service names are validated before registry access, delegated
//!   descriptors are retained before transfer, and oversized envelopes fail closed.
//! Consumes: service registry state, task fd tables, shared fd ownership, VFS
//!   caller constants, and shared memory codecs.
//! Not here: served filesystem mounts, network egress, or ordinary file syscalls.

const std = @import("std");
const constants = @import("constants_zig");
const mc = @import("mc_zig");
const state = @import("../state.zig");
const task_mod = @import("../task.zig");
const vfs = @import("../vfs.zig");
const registry = @import("../service/registry.zig");
const mem = @import("mem.zig");
const fd_mod = @import("fd.zig");

const Task = task_mod.Task;
const Guest = mem.Guest;
const GuestMemory = mem.GuestMemory;
const Fulfillment = mem.Fulfillment;
const finish = mem.finish;
const neg = mem.neg;
const guestRange = mem.guestRange;
const writeGuestBytes = mem.writeGuestBytes;
const writeGuestU32 = mem.writeGuestU32;
const readLeI32 = mem.readLeI32;
const currentTask = mem.currentTask;
const fdIndex = mem.fdIndex;
const readGuestUtf8 = mem.readGuestUtf8;
const appendU32 = mem.appendU32;
const SharedFile = fd_mod.SharedFile;

fn svcChannel(t: *const Task, fd: i32) ?*registry.ServiceChannel {
    const idx = fdIndex(fd) orelse return null;
    return switch (t.getFd(idx)) {
        .svc_serve => |owner| owner.channel,
        else => null,
    };
}

fn svcConn(t: *const Task, fd: i32) ?struct { channel: *registry.ServiceChannel, session: u32 } {
    const idx = fdIndex(fd) orelse return null;
    return switch (t.getFd(idx)) {
        .svc_conn => |conn| .{ .channel = conn.channel, .session = conn.session },
        else => null,
    };
}

pub fn fulfillSvcServe(guest: *const Guest, memory: GuestMemory, args: mc.SvcServeArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(memory, args.ret_fd, 4) orelse return neg(constants.EINVAL);
    const name = readGuestUtf8(memory, args.name_ptr, args.name_len) orelse return neg(constants.EINVAL);
    if (!registry.validServiceName(name)) return neg(constants.EINVAL);
    if (state.kernel().services.grantHolder(name) != t.id) return neg(constants.EPERM);
    if (state.kernel().services.serviceRegistered(name)) return neg(constants.EEXIST);
    const channel = registry.ServiceChannel.create(state.kernel().gpa);
    if (!state.kernel().services.registerService(name, channel)) return neg(constants.EEXIST);
    state.kernel().services.clearActivation(name);
    const owner = registry.SvcServeOwner.create(state.kernel().gpa, &state.kernel().services, name, channel);
    const fd = t.allocFd(state.kernel().gpa, .{ .svc_serve = owner });
    if (!writeGuestU32(memory, args.ret_fd, @intCast(fd))) {
        t.closeFd(fd);
        return neg(constants.EINVAL);
    }
    return constants.ESUCCESS;
}

fn writeSvcEnvelope(
    memory: GuestMemory,
    buf: u32,
    ret_len: u32,
    hbuf: u32,
    kind: u8,
    session: u32,
    req_id: u32,
    caller: u32,
    caller_caps: u32,
    blob: []const u8,
    handle_bytes: []const u8,
) i32 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(state.kernel().gpa);
    out.append(state.kernel().gpa, kind) catch @panic("OOM");
    out.append(state.kernel().gpa, @intCast(handle_bytes.len / 4)) catch @panic("OOM");
    appendU32(&out, state.kernel().gpa, session);
    appendU32(&out, state.kernel().gpa, req_id);
    appendU32(&out, state.kernel().gpa, caller);
    appendU32(&out, state.kernel().gpa, caller_caps);
    appendU32(&out, state.kernel().gpa, @intCast(blob.len));
    out.appendSlice(state.kernel().gpa, blob) catch @panic("OOM");
    if (!writeGuestBytes(memory, buf, out.items)) return neg(constants.EINVAL);
    if (handle_bytes.len != 0 and !writeGuestBytes(memory, hbuf, handle_bytes)) return neg(constants.EINVAL);
    if (!writeGuestU32(memory, ret_len, @intCast(out.items.len))) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn installDelegated(t: *Task, dh: registry.DelegatedHandle) i32 {
    const fd = switch (dh) {
        .file => |fh| t.allocFd(state.kernel().gpa, .{ .file = fh }),
        .pipe_read => |p| t.allocFd(state.kernel().gpa, .{ .pipe_read = p }),
        .pipe_write => |p| t.allocFd(state.kernel().gpa, .{ .pipe_write = p }),
    };
    return @intCast(fd);
}

pub fn fulfillSvcRecv(guest: *const Guest, memory: GuestMemory, args: mc.SvcRecvArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    _ = guestRange(memory, args.ret_len, 4) orelse return finish(neg(constants.EINVAL));
    const channel = svcChannel(t, args.fd) orelse return finish(neg(constants.EBADF));
    channel.evictDeadSessions(@ptrCast(state.kernel()), state.callerAlive);
    channel.failOverdue();
    while (true) {
        var inbound = channel.takeRequest() orelse {
            if (channel.nextDrainReady()) |key| {
                if (registry.SVC_ENVELOPE_HEADER <= @as(usize, @intCast(args.buf_len)) and guestRange(memory, args.buf, @intCast(registry.SVC_ENVELOPE_HEADER)) != null) {
                    return finish(writeSvcEnvelope(memory, args.buf, args.ret_len, args.hbuf, registry.SVC_KIND_DRAIN_READY, key.session, key.req_id, vfs.SYSTEM_CALLER, 0, "", ""));
                }
            }
            return .{ .Block = .{ .svc_recv = channel } };
        };
        switch (inbound) {
            .session_closed => |session| {
                if (registry.SVC_ENVELOPE_HEADER > @as(usize, @intCast(args.buf_len)) or guestRange(memory, args.buf, @intCast(registry.SVC_ENVELOPE_HEADER)) == null) continue;
                return finish(writeSvcEnvelope(memory, args.buf, args.ret_len, args.hbuf, registry.SVC_KIND_SESSION_CLOSED, session, 0, vfs.SYSTEM_CALLER, 0, "", ""));
            },
            .call => |*req| {
                const nh = req.handles.len;
                const total = registry.SVC_ENVELOPE_HEADER + req.blob.len;
                if (total > @as(usize, @intCast(args.buf_len)) or
                    nh * 4 > @as(usize, @intCast(args.hbuf_len)) or
                    guestRange(memory, args.buf, @intCast(total)) == null or
                    (nh != 0 and guestRange(memory, args.hbuf, @intCast(nh * 4)) == null))
                {
                    _ = channel.respond(req.session, req.req_id, constants.EMSGSIZE, "", true);
                    req.deinit(state.kernel().gpa, true);
                    continue;
                }
                var handle_bytes: std.ArrayList(u8) = .empty;
                defer handle_bytes.deinit(state.kernel().gpa);
                for (req.handles) |dh| appendU32(&handle_bytes, state.kernel().gpa, @bitCast(installDelegated(t, dh)));
                channel.markDelivered(req.session, req.req_id);
                const code = writeSvcEnvelope(memory, args.buf, args.ret_len, args.hbuf, registry.SVC_KIND_CALL, req.session, req.req_id, req.caller, req.caller_caps, req.blob, handle_bytes.items);
                req.deinit(state.kernel().gpa, false);
                return finish(code);
            },
        }
    }
}

pub fn fulfillSvcRespond(guest: *const Guest, memory: GuestMemory, args: mc.SvcRespondArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    const channel = svcChannel(t, args.fd) orelse return neg(constants.EBADF);
    const is_last = args.last != 0;
    if (channel.responseBuffered(args.session, args.req_id) >= registry.SVC_RESPONSE_HIGH_WATER) return neg(constants.EAGAIN);
    const data = guestRange(memory, args.data_ptr, args.data_len) orelse return neg(constants.EINVAL);
    const ok = if (is_last) channel.markAnswered(args.session, args.req_id) else channel.isInflight(args.session, args.req_id);
    if (!ok) return neg(constants.EINVAL);
    return switch (channel.respond(args.session, args.req_id, args.status, data, is_last)) {
        .session_gone => constants.ESUCCESS,
        .overflow => blk: {
            if (!is_last) _ = channel.markAnswered(args.session, args.req_id);
            break :blk neg(constants.EMSGSIZE);
        },
        .ok => constants.ESUCCESS,
    };
}

pub fn fulfillSvcConnect(guest: *const Guest, memory: GuestMemory, args: mc.SvcConnectArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    _ = guestRange(memory, args.ret_fd, 4) orelse return finish(neg(constants.EINVAL));
    const name = readGuestUtf8(memory, args.name_ptr, args.name_len) orelse return finish(neg(constants.EINVAL));
    if (!registry.validServiceName(name)) return finish(neg(constants.EINVAL));
    const channel = switch (state.serviceChannel(state.kernel(), name)) {
        .ready => |ch| ch,
        .pending => return .Pending,
        .errno => |errno| return finish(neg(errno)),
    };
    const session = channel.openSession(t.id);
    const conn = registry.SvcConnHandle.create(state.kernel().gpa, channel, session);
    const fd = t.allocFd(state.kernel().gpa, .{ .svc_conn = conn });
    if (!writeGuestU32(memory, args.ret_fd, @intCast(fd))) {
        t.closeFd(fd);
        return finish(neg(constants.EINVAL));
    }
    return finish(constants.ESUCCESS);
}

fn readHandleFdList(memory: GuestMemory, ptr: u32, nhandles: u32) ?[]const u8 {
    if (nhandles == 0) return &[_]u8{};
    return guestRange(memory, ptr, nhandles * 4);
}

fn delegateFd(t: *Task, fd: i32) ?registry.DelegatedHandle {
    const idx = fdIndex(fd) orelse return null;
    return switch (t.getFd(idx)) {
        .file => |fh| blk: {
            const retained = SharedFile.retain(fh) orelse break :blk null;
            break :blk .{ .file = retained };
        },
        .pipe_read => |p| blk: {
            p.addReader();
            break :blk .{ .pipe_read = p };
        },
        .pipe_write => |p| blk: {
            p.addWriter();
            break :blk .{ .pipe_write = p };
        },
        else => null,
    };
}

fn releaseDelegatedList(handles: []registry.DelegatedHandle) void {
    for (handles) |h| h.release();
}

pub fn fulfillSvcCall(guest: *const Guest, memory: GuestMemory, args: mc.SvcCallArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(memory, args.ret_fd, 4) orelse return neg(constants.EINVAL);
    const conn = svcConn(t, args.fd) orelse return neg(constants.EBADF);
    if (@as(usize, @intCast(args.req_len)) > registry.MAX_SVC_REQUEST_BYTES or @as(usize, @intCast(args.nhandles)) > registry.MAX_DELEGATED_HANDLES) return neg(constants.EINVAL);
    const blob = guestRange(memory, args.req_ptr, args.req_len) orelse return neg(constants.EINVAL);
    const raw_handles = readHandleFdList(memory, args.handles_ptr, args.nhandles) orelse return neg(constants.EINVAL);
    var handles: std.ArrayListUnmanaged(registry.DelegatedHandle) = .empty;
    defer handles.deinit(state.kernel().gpa);
    var i: usize = 0;
    while (i < @as(usize, @intCast(args.nhandles))) : (i += 1) {
        const hfd = readLeI32(raw_handles, i * 4);
        const dh = delegateFd(t, hfd) orelse {
            releaseDelegatedList(handles.items);
            return neg(constants.EINVAL);
        };
        handles.append(state.kernel().gpa, dh) catch @panic("OOM");
    }
    const req_id = conn.channel.enqueue(conn.session, t.id, t.caps.bits, blob, handles.items) orelse {
        releaseDelegatedList(handles.items);
        return neg(constants.EIO);
    };
    state.kernel().sched.checkUnblocked();
    const src = registry.SvcCallSource.create(state.kernel().gpa, conn.channel, conn.session, req_id);
    const fd = t.allocFd(state.kernel().gpa, .{ .svc_call = src });
    if (!writeGuestU32(memory, args.ret_fd, @intCast(fd))) {
        t.closeFd(fd);
        return neg(constants.EINVAL);
    }
    return constants.ESUCCESS;
}
