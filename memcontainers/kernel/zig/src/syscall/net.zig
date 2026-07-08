//! net.zig - network and host-call syscall fulfillment.
//!
//! Owns: HTTP request handles, HTTP status polling, WebSocket opens, and opaque
//!   host-call descriptor creation.
//! Invariants: egress requires network capability, guest request buffers are
//!   range-checked, and returned handles are installed atomically with ret_fd writes.
//! Consumes: egress state, task fd tables, constants, and shared memory codecs.
//! Not here: file reads from those handles, service calls, or mount operations.

const std = @import("std");
const constants = @import("constants_zig");
const mc = @import("mc_zig");
const state = @import("../state.zig");
const task_mod = @import("../task.zig");
const mem = @import("mem.zig");

const Task = task_mod.Task;
const Fd = task_mod.Fd;
const Guest = mem.Guest;
const GuestMemory = mem.GuestMemory;
const Fulfillment = mem.Fulfillment;
const finish = mem.finish;
const neg = mem.neg;
const guestRange = mem.guestRange;
const writeGuestU32 = mem.writeGuestU32;
const currentTask = mem.currentTask;
const fdIndex = mem.fdIndex;
const readGuestUtf8 = mem.readGuestUtf8;

fn netPermitted(guest: *const Guest) bool {
    const t = currentTask(guest) orelse return false;
    return t.caps.has(constants.CAP_NET);
}


fn installFd(t: *Task, memory: GuestMemory, ret_fd: u32, fd_value: Fd) i32 {
    const fd = t.allocFd(state.kernel().gpa, fd_value);
    if (!writeGuestU32(memory, ret_fd, @intCast(fd))) {
        t.closeFd(fd);
        return neg(constants.EINVAL);
    }
    return constants.ESUCCESS;
}

pub fn fulfillHttpGet(guest: *const Guest, memory: GuestMemory, args: mc.HttpGetArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(memory, args.ret_fd, 4) orelse return neg(constants.EINVAL);
    if (!netPermitted(guest)) return neg(constants.EPERM);
    const url = readGuestUtf8(memory, args.url_ptr, args.url_len) orelse return neg(constants.EINVAL);
    if (url.len == 0) return neg(constants.EINVAL);

    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(state.kernel().gpa);
    blob.appendSlice(state.kernel().gpa, "GET ") catch @panic("OOM");
    blob.appendSlice(state.kernel().gpa, url) catch @panic("OOM");
    blob.appendSlice(state.kernel().gpa, "\n\n") catch @panic("OOM");

    const src = state.kernel().net.startHttp(blob.items) catch return neg(constants.EPERM);
    return installFd(t, memory, args.ret_fd, .{ .net = src });
}

pub fn fulfillHttpRequest(guest: *const Guest, memory: GuestMemory, args: mc.HttpRequestArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(memory, args.ret_fd, 4) orelse return neg(constants.EINVAL);
    if (!netPermitted(guest)) return neg(constants.EPERM);
    const blob = guestRange(memory, args.req_ptr, args.req_len) orelse return neg(constants.EINVAL);
    if (blob.len == 0) return neg(constants.EINVAL);
    const src = state.kernel().net.startHttp(blob) catch return neg(constants.EPERM);
    return installFd(t, memory, args.ret_fd, .{ .net = src });
}

pub fn fulfillHttpStatus(guest: *const Guest, memory: GuestMemory, args: mc.HttpStatusArgs) Fulfillment {
    _ = guestRange(memory, args.ret_status, 4) orelse return finish(neg(constants.EINVAL));
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    const idx = fdIndex(args.fd) orelse return finish(neg(constants.EBADF));
    const src = switch (t.getFd(idx)) {
        .net => |s| s,
        else => return finish(neg(constants.EBADF)),
    };
    switch (src.driveStatus()) {
        .pending => return .Pending,
        .ready => |status| {
            if (!writeGuestU32(memory, args.ret_status, status)) return finish(neg(constants.EINVAL));
            return finish(constants.ESUCCESS);
        },
        .failed => return finish(neg(constants.EIO)),
    }
}

pub fn fulfillWsOpen(guest: *const Guest, memory: GuestMemory, args: mc.WsOpenArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(memory, args.ret_fd, 4) orelse return neg(constants.EINVAL);
    if (!netPermitted(guest)) return neg(constants.EPERM);
    const url = readGuestUtf8(memory, args.url_ptr, args.url_len) orelse return neg(constants.EINVAL);
    if (url.len == 0) return neg(constants.EINVAL);
    const src = state.kernel().net.connectWs(url) catch return neg(constants.EPERM);
    return installFd(t, memory, args.ret_fd, .{ .ws = src });
}

pub fn fulfillHostCall(guest: *const Guest, memory: GuestMemory, args: mc.HostCallArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(memory, args.ret_fd, 4) orelse return neg(constants.EINVAL);
    if (!netPermitted(guest)) return neg(constants.EPERM);
    const blob = guestRange(memory, args.req_ptr, args.req_len) orelse return neg(constants.EINVAL);
    if (blob.len == 0) return neg(constants.EINVAL);
    const src = state.kernel().host_call.start(blob) catch return neg(constants.EPERM);
    return installFd(t, memory, args.ret_fd, .{ .host_call = src });
}
