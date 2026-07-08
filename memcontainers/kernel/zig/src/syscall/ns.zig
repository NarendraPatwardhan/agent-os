//! ns.zig - namespace mount and served-filesystem syscall fulfillment.
//!
//! Owns: bind/unmount, served mount creation, and served request receive/respond
//!   syscalls.
//! Invariants: namespace mutation requires mount capability, paths remain inside
//!   the caller confinement root, and served channels are mounted and unwound as a unit.
//! Consumes: VFS namespace state, served-fs handles, task fd tables, and shared
//!   memory codecs.
//! Not here: ordinary file syscalls, service registry calls, or network egress.

const std = @import("std");
const constants = @import("constants_zig");
const mc = @import("mc_zig");
const state = @import("../state.zig");
const task_mod = @import("../task.zig");
const vfs = @import("../vfs.zig");
const servedfs = @import("../fs/servedfs.zig");
const mem = @import("mem.zig");
const fsops = @import("fsops.zig");

const Task = task_mod.Task;
const Guest = mem.Guest;
const GuestMemory = mem.GuestMemory;
const Fulfillment = mem.Fulfillment;
const finish = mem.finish;
const neg = mem.neg;
const guestRange = mem.guestRange;
const writeGuestBytes = mem.writeGuestBytes;
const writeGuestU32 = mem.writeGuestU32;
const currentTask = mem.currentTask;
const fdIndex = mem.fdIndex;
const fsErr = mem.fsErr;
const readGuestUtf8 = mem.readGuestUtf8;
const appendU32 = mem.appendU32;
const pathWithin = fsops.pathWithin;
const absolutize = vfs.absolutize;

pub fn fulfillBind(guest: *const Guest, memory: GuestMemory, args: mc.BindArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    if (!t.caps.has(constants.CAP_MOUNT)) return neg(constants.EPERM);
    const old_raw = readGuestUtf8(memory, args.old_ptr, args.old_len) orelse return neg(constants.EINVAL);
    const new_raw = readGuestUtf8(memory, args.new_ptr, args.new_len) orelse return neg(constants.EINVAL);
    if (std.mem.indexOfScalar(u8, old_raw, 0) != null or std.mem.indexOfScalar(u8, new_raw, 0) != null) return neg(constants.EINVAL);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const old_path = absolutize(arena, t.cwd, old_raw);
    const new_path = absolutize(arena, t.cwd, new_raw);
    if (!pathWithin(t.confine_root, old_path) or !pathWithin(t.confine_root, new_path)) return neg(constants.EPERM);
    state.kernel().ns.bind(arena, old_path, new_path) catch |e| return fsErr(e);
    return constants.ESUCCESS;
}

pub fn fulfillUnmount(guest: *const Guest, memory: GuestMemory, args: mc.UnmountArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    if (!t.caps.has(constants.CAP_MOUNT)) return neg(constants.EPERM);
    const raw = readGuestUtf8(memory, args.path_ptr, args.path_len) orelse return neg(constants.EINVAL);
    if (std.mem.indexOfScalar(u8, raw, 0) != null) return neg(constants.EINVAL);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = absolutize(arena, t.cwd, raw);
    if (!pathWithin(t.confine_root, path)) return neg(constants.EPERM);
    state.kernel().ns.unmount(path) catch |e| return fsErr(e);
    return constants.ESUCCESS;
}

fn serveChannel(t: *const Task, fd: i32) ?*servedfs.ServeChannel {
    const idx = fdIndex(fd) orelse return null;
    return switch (t.getFd(idx)) {
        .serve => |owner| owner.channel,
        else => null,
    };
}

pub fn fulfillServe(guest: *const Guest, memory: GuestMemory, args: mc.ServeArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(memory, args.ret_fd, 4) orelse return neg(constants.EINVAL);
    if (!t.caps.has(constants.CAP_MOUNT)) return neg(constants.EPERM);
    const raw = readGuestUtf8(memory, args.path_ptr, args.path_len) orelse return neg(constants.EINVAL);
    if (raw.len == 0 or std.mem.indexOfScalar(u8, raw, 0) != null) return neg(constants.EINVAL);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = absolutize(arena, t.cwd, raw);
    if (!pathWithin(t.confine_root, path)) return neg(constants.EPERM);

    const channel = servedfs.ServeChannel.create(state.kernel().gpa);
    const fs = servedfs.ServedFs.create(state.kernel().gpa, channel);
    state.kernel().ns.mountLabeled(path, fs.fileSystem(), "served", false);
    const owner = servedfs.ServeOwner.create(state.kernel().gpa, channel);
    const fd = t.allocFd(state.kernel().gpa, .{ .serve = owner });
    if (!writeGuestU32(memory, args.ret_fd, @intCast(fd))) {
        // Undo BOTH the fd and the mount installed above: closeFd releases the owner's channel ref,
        // but without the unmount the namespace keeps an orphaned `served` mount — guest-triggerable
        // inconsistent VFS state (via a bad ret_fd pointer). fulfillSvcServe's failure path is
        // already symmetric this way.
        t.closeFd(fd);
        state.kernel().ns.unmount(path) catch {};
        return neg(constants.EINVAL);
    }
    return constants.ESUCCESS;
}

pub fn fulfillServeRecv(guest: *const Guest, memory: GuestMemory, args: mc.ServeRecvArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    _ = guestRange(memory, args.ret_len, 4) orelse return finish(neg(constants.EINVAL));
    const channel = serveChannel(t, args.fd) orelse return finish(neg(constants.EBADF));
    const req = channel.peekRequest() orelse return .Pending;
    const total = 20 + req.path.len + req.arg.len;
    if (total > @as(usize, @intCast(args.buf_len)) or guestRange(memory, args.buf, @intCast(total)) == null) {
        return finish(neg(constants.EINVAL));
    }
    var taken = channel.takeRequest() orelse return .Pending;
    defer taken.deinit(state.kernel().gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(state.kernel().gpa);
    appendU32(&out, state.kernel().gpa, taken.id);
    appendU32(&out, state.kernel().gpa, taken.caller);
    appendU32(&out, state.kernel().gpa, taken.op);
    appendU32(&out, state.kernel().gpa, @intCast(taken.path.len));
    out.appendSlice(state.kernel().gpa, taken.path) catch @panic("OOM");
    appendU32(&out, state.kernel().gpa, @intCast(taken.arg.len));
    out.appendSlice(state.kernel().gpa, taken.arg) catch @panic("OOM");
    if (!writeGuestBytes(memory, args.buf, out.items)) return finish(neg(constants.EINVAL));
    if (!writeGuestU32(memory, args.ret_len, @intCast(out.items.len))) return finish(neg(constants.EINVAL));
    return finish(constants.ESUCCESS);
}

pub fn fulfillServeRespond(guest: *const Guest, memory: GuestMemory, args: mc.ServeRespondArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    const channel = serveChannel(t, args.fd) orelse return neg(constants.EBADF);
    const data = guestRange(memory, args.data_ptr, args.data_len) orelse return neg(constants.EINVAL);
    return if (channel.respond(args.req_id, args.status, data)) constants.ESUCCESS else neg(constants.EINVAL);
}
