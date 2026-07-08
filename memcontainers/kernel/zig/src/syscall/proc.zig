//! proc.zig - process-family syscall fulfillment.
//!
//! Owns: argv reporting, process identity, sleep/wait/signal/job-control
//!   syscalls, spawn policy, program resolution, and native child creation.
//! Invariants: child descriptors are cloned through shared fd ownership helpers,
//!   spawn policy is derived before the child starts, and wait/signal operations
//!   only affect reachable task relationships.
//! Consumes: scheduler state, guest memory codecs, fd cloning, VFS program reads,
//!   ambient time, and wasm tier metadata.
//! Not here: file syscalls, terminal output, network egress, or services.

const std = @import("std");
const bridge = @import("../bridge.zig");
const constants = @import("constants_zig");
const mc = @import("mc_zig");
const state = @import("../state.zig");
const task_mod = @import("../task.zig");
const vfs = @import("../vfs.zig");
const sections = @import("../wasm_sections.zig");
const mem = @import("mem.zig");
const fd = @import("fd.zig");

const Task = task_mod.Task;
const TaskId = task_mod.TaskId;
const Capabilities = task_mod.Capabilities;
const Tier = task_mod.Tier;
const Guest = mem.Guest;
const GuestMemory = mem.GuestMemory;
const Fulfillment = mem.Fulfillment;
const finish = mem.finish;
const neg = mem.neg;
const guestRange = mem.guestRange;
const writeGuestBytes = mem.writeGuestBytes;
const writeGuestU32 = mem.writeGuestU32;
const currentTask = mem.currentTask;
const releaseFdValue = fd.releaseFdValue;
const duplicateReadableFd = fd.duplicateReadableFd;
const duplicateWritableFd = fd.duplicateWritableFd;

const DEFAULT_PATH = "/bin:/usr/bin";
const absolutize = vfs.absolutize;

pub const SpawnResult = union(enum) {
    pid: TaskId,
    errno: i32,
};

pub fn fulfillArgs(guest: *const Guest, memory: GuestMemory, args: mc.ArgsArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(state.kernel().gpa);
    const argv0 = if (t.command.len != 0) t.command else t.name;
    // Fail closed with EMSGSIZE rather than trapping the whole VM if the kernel heap is exhausted
    // building this (guest-influenced) blob — a guest fault is an errno, never a host trap (§4.3).
    blob.appendSlice(state.kernel().gpa, argv0) catch return neg(constants.EMSGSIZE);
    blob.append(state.kernel().gpa, 0) catch return neg(constants.EMSGSIZE);
    for (t.args) |a| {
        blob.appendSlice(state.kernel().gpa, a) catch return neg(constants.EMSGSIZE);
        blob.append(state.kernel().gpa, 0) catch return neg(constants.EMSGSIZE);
    }

    const n = @min(blob.items.len, @as(usize, @intCast(args.len)));
    if (blob.items.len > std.math.maxInt(u32)) return neg(constants.EINVAL);
    if (guestRange(memory, args.ret_len, 4) == null or guestRange(memory, args.ptr, @intCast(n)) == null) {
        return neg(constants.EINVAL);
    }
    if (n != 0 and !writeGuestBytes(memory, args.ptr, blob.items[0..n])) return neg(constants.EINVAL);
    if (!writeGuestU32(memory, args.ret_len, @intCast(blob.items.len))) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

pub fn fulfillGetpid(guest: *const Guest, memory: GuestMemory, args: mc.GetpidArgs) i32 {
    if (!writeGuestU32(memory, args.ret, guest.taskId())) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

pub fn fulfillGetppid(guest: *const Guest, memory: GuestMemory, args: mc.GetppidArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    const ppid: u32 = t.parent_id orelse 0;
    if (!writeGuestU32(memory, args.ret, ppid)) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn lessTaskId(_: void, a: TaskId, b: TaskId) bool {
    return a < b;
}

fn sortedTaskIds(arena: std.mem.Allocator) []TaskId {
    const ids = state.kernel().sched.taskIds(arena);
    std.mem.sort(TaskId, ids, {}, lessTaskId);
    return ids;
}

const ExecPolicy = struct {
    caps: Capabilities,
    root: ?[]const u8,
};

pub const ChildFactory = struct {
    ptr: *const anyopaque,
    create_child: *const fn (*const anyopaque, TaskId, []const u8, []const u8) bool,

    fn createChild(self: ChildFactory, child_id: TaskId, bytes: []const u8, cwd: []const u8) bool {
        return self.create_child(self.ptr, child_id, bytes, cwd);
    }
};

fn execPolicy(parent_caps: Capabilities, parent_root: ?[]const u8, binary: ?Tier, requested: ?Tier, cwd: []const u8) ExecPolicy {
    var caps = parent_caps;
    if (binary) |t| caps = caps.intersect(t.caps());
    if (requested) |t| caps = caps.intersect(t.caps());
    const confines = (binary != null and binary.?.confines()) or (requested != null and requested.?.confines());
    return .{
        .caps = caps,
        .root = if (confines) cwd else parent_root,
    };
}

fn appendProgramCandidate(arena: std.mem.Allocator, candidates: *std.ArrayList([]const u8), cwd: []const u8, raw: []const u8) void {
    const absolute = absolutize(arena, cwd, raw);
    candidates.append(arena, absolute) catch @panic("OOM");
}

fn resolveProgram(arena: std.mem.Allocator, owner: TaskId, cwd: []const u8, cmd: []const u8, path: []const u8) ?[]u8 {
    var candidates: std.ArrayList([]const u8) = .empty;
    if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
        appendProgramCandidate(arena, &candidates, cwd, cmd);
    } else {
        var dirs = std.mem.splitScalar(u8, path, ':');
        while (dirs.next()) |dir| {
            if (dir.len == 0) continue;
            const joined = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, cmd }) catch @panic("OOM");
            appendProgramCandidate(arena, &candidates, cwd, joined);
        }
    }

    for (candidates.items) |candidate| {
        // TODO(Phase 6, namespace/services group): served-fs `WouldBlock`
        // should re-arm spawn and retry; Zig has no served fs yet, so this
        // path is treated as NotFound by continuing the lookup.
        const real = state.kernel().ns.canonicalize(arena, candidate, true) catch continue;
        const md = state.kernel().ns.statPath(arena, real) catch continue;
        if (!md.ownerExecutable()) continue;
        var h = state.kernel().ns.openAs(arena, owner, real, vfs.OpenFlags.READ) catch continue;
        defer h.close();
        var out: std.ArrayList(u8) = .empty;
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = h.read(&tmp) catch {
                out.deinit(state.kernel().gpa);
                break;
            };
            if (n == 0) {
                if (out.items.len == 0) {
                    out.deinit(state.kernel().gpa);
                    break;
                }
                return out.toOwnedSlice(state.kernel().gpa) catch @panic("OOM");
            }
            out.appendSlice(state.kernel().gpa, tmp[0..n]) catch @panic("OOM");
        }
    }
    return null;
}

fn takeEintr(t: *Task) bool {
    var hit = false;
    for ([_]i32{ constants.SIGINT, constants.SIGTERM, constants.SIGHUP, constants.SIGTSTP }) |sig| {
        if (t.signalPending(sig) and t.signalIgnored(sig)) {
            t.clearSignal(sig);
            hit = true;
        }
    }
    return hit;
}

pub fn fulfillSleepMs(guest: *const Guest, args: mc.SleepMsArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    if (!t.caps.has(constants.CAP_AMBIENT)) {
        t.timed_deadline = null;
        return finish(neg(constants.EPERM));
    }
    if (args.ms <= 0) {
        t.timed_deadline = null;
        return finish(constants.ESUCCESS);
    }

    const now = bridge.mc_time_monotonic();
    const deadline = t.timed_deadline orelse blk: {
        const d = std.math.add(i64, now, @as(i64, args.ms)) catch std.math.maxInt(i64);
        t.timed_deadline = d;
        break :blk d;
    };
    if (now >= deadline) {
        t.timed_deadline = null;
        return finish(constants.ESUCCESS);
    }
    if (takeEintr(t)) {
        t.timed_deadline = null;
        return finish(neg(constants.EINTR));
    }
    return .{ .Block = .{ .timer = deadline } };
}

fn isChildOf(parent: TaskId, child_id: TaskId) bool {
    const child = state.kernel().sched.getTask(child_id) orelse return false;
    return child.parent_id != null and child.parent_id.? == parent;
}

fn findZombieChild(arena: std.mem.Allocator, parent: TaskId, pid: i32) ?TaskId {
    if (pid > 0) {
        const id: TaskId = @intCast(pid);
        const child = state.kernel().sched.getTask(id) orelse return null;
        return if (child.parent_id != null and child.parent_id.? == parent and child.state == .zombie) id else null;
    }
    for (sortedTaskIds(arena)) |id| {
        const child = state.kernel().sched.getTask(id) orelse continue;
        if (child.parent_id != null and child.parent_id.? == parent and child.state == .zombie) return id;
    }
    return null;
}

fn findStoppedChild(arena: std.mem.Allocator, parent: TaskId, pid: i32) ?TaskId {
    if (pid > 0) {
        const id: TaskId = @intCast(pid);
        const child = state.kernel().sched.getTask(id) orelse return null;
        return if (child.parent_id != null and child.parent_id.? == parent and child.sig_stopped) id else null;
    }
    for (sortedTaskIds(arena)) |id| {
        const child = state.kernel().sched.getTask(id) orelse continue;
        if (child.parent_id != null and child.parent_id.? == parent and child.sig_stopped) return id;
    }
    return null;
}

fn hasWaitTarget(arena: std.mem.Allocator, parent: TaskId, pid: i32) bool {
    if (pid > 0) return isChildOf(parent, @intCast(pid));
    for (sortedTaskIds(arena)) |id| {
        if (isChildOf(parent, id)) return true;
    }
    return false;
}

pub fn spawnNative(parent_id: TaskId, argv: []const []const u8, in_fd: i32, out_fd: i32, err_fd: i32, tier: i32, factory: ChildFactory) SpawnResult {
    const parent = state.kernel().sched.getTask(parent_id) orelse return .{ .errno = constants.EIO };
    if (!parent.caps.has(constants.CAP_SPAWN)) return .{ .errno = constants.EPERM };
    if (argv.len == 0) return .{ .errno = constants.EINVAL };

    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prog_name = argv[0];
    const child_args = argv[1..];
    const cwd = parent.cwd;
    const live_path = parent.env.get("PATH") orelse DEFAULT_PATH;
    const bytes = resolveProgram(arena, parent.id, cwd, prog_name, live_path) orelse return .{ .errno = constants.ENOENT };
    defer state.kernel().gpa.free(bytes);

    const policy = execPolicy(parent.caps, parent.confine_root, Tier.fromModule(bytes), Tier.fromArg(tier), cwd);

    var stdin = duplicateReadableFd(parent, in_fd) orelse return .{ .errno = constants.EBADF };
    var stdout = duplicateWritableFd(parent, out_fd) orelse {
        releaseFdValue(stdin);
        return .{ .errno = constants.EBADF };
    };
    var stderr = duplicateWritableFd(parent, err_fd) orelse {
        releaseFdValue(stdin);
        releaseFdValue(stdout);
        return .{ .errno = constants.EBADF };
    };

    const child_pid = state.kernel().sched.spawn(parent.id, prog_name, prog_name, child_args, cwd);
    state.kernel().sched.setTaskPolicy(child_pid, policy.caps, policy.root);
    if (state.kernel().sched.getTask(child_pid)) |child| {
        child.setFd(state.kernel().gpa, 0, stdin);
        child.setFd(state.kernel().gpa, 1, stdout);
        child.setFd(state.kernel().gpa, 2, stderr);
        stdin = .none;
        stdout = .none;
        stderr = .none;
        // TODO(Phase 6, namespace/services group): fork the parent's namespace
        // for child_pid and install a private `/scratch` mount according to
        // CAP_SCRATCH. Zig vfs currently has one root namespace, not per-task
        // namespace ownership.
    }

    if (!factory.createChild(child_pid, bytes, cwd)) {
        state.kernel().sched.exitTask(child_pid, neg(constants.EINVAL));
        state.kernel().sched.reapZombie(child_pid);
        state.kernel().sched.dropDeadPipes();
        return .{ .errno = constants.EINVAL };
    }

    return .{ .pid = child_pid };
}

fn spawnGuestChild(ptr: *const anyopaque, child_id: TaskId, bytes: []const u8, cwd: []const u8) bool {
    const g: *const Guest = @ptrCast(@alignCast(ptr));
    return g.createChild(child_id, bytes, cwd);
}

pub fn fulfillSpawn(guest: *const Guest, memory: GuestMemory, args: mc.SpawnArgs) Fulfillment {
    _ = guestRange(memory, args.ret_pid, 4) orelse return finish(neg(constants.EINVAL));

    const blob = guestRange(memory, args.argv_ptr, args.argv_len) orelse return finish(neg(constants.EINVAL));
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var argv: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, blob, 0);
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (!std.unicode.utf8ValidateSlice(part)) continue;
        argv.append(arena, arena.dupe(u8, part) catch @panic("OOM")) catch @panic("OOM");
    }

    const child_pid = switch (spawnNative(guest.taskId(), argv.items, args.in_fd, args.out_fd, args.err_fd, args.tier, .{
        .ptr = @ptrCast(guest),
        .create_child = spawnGuestChild,
    })) {
        .pid => |pid| pid,
        .errno => |errno| return finish(neg(errno)),
    };
    if (!writeGuestU32(memory, args.ret_pid, @intCast(child_pid))) return finish(neg(constants.EINVAL));
    return finish(constants.ESUCCESS);
}

pub fn fulfillWaitpid(guest: *const Guest, memory: GuestMemory, args: mc.WaitpidArgs) Fulfillment {
    const me_task = currentTask(guest) orelse return finish(neg(constants.EIO));
    _ = guestRange(memory, args.ret_status, 4) orelse return finish(neg(constants.EINVAL));
    _ = guestRange(memory, args.ret_pid, 4) orelse return finish(neg(constants.EINVAL));

    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (findZombieChild(arena, me_task.id, args.pid)) |zpid| {
        const code = state.kernel().sched.getExitCode(zpid) orelse 0;
        state.kernel().sched.reapZombie(zpid);
        state.kernel().sched.dropDeadPipes();
        if (!writeGuestU32(memory, args.ret_status, @bitCast(code))) return finish(neg(constants.EINVAL));
        if (!writeGuestU32(memory, args.ret_pid, zpid)) return finish(neg(constants.EINVAL));
        return finish(constants.ESUCCESS);
    }

    if ((args.opts & constants.WNOHANG) == 0) {
        if (findStoppedChild(arena, me_task.id, args.pid)) |spid| {
            const report = if (state.kernel().sched.getTask(spid)) |child| child.takeStopReport() else false;
            if (report) {
                const status: u32 = @intCast(constants.STOPPED_STATUS_BASE + constants.SIGTSTP);
                if (!writeGuestU32(memory, args.ret_status, status)) return finish(neg(constants.EINVAL));
                if (!writeGuestU32(memory, args.ret_pid, spid)) return finish(neg(constants.EINVAL));
                return finish(constants.ESUCCESS);
            }
        }
    }

    if (!hasWaitTarget(arena, me_task.id, args.pid)) return finish(neg(constants.ECHILD));
    if ((args.opts & constants.WNOHANG) != 0) {
        if (!writeGuestU32(memory, args.ret_pid, 0)) return finish(neg(constants.EINVAL));
        return finish(constants.ESUCCESS);
    }
    if (takeEintr(me_task)) return finish(neg(constants.EINTR));
    if (args.pid > 0) return .{ .Block = .{ .wait_child = @intCast(args.pid) } };
    return .Pending;
}

pub fn fulfillKill(guest: *const Guest, args: mc.KillArgs) Fulfillment {
    const me_task = currentTask(guest) orelse return finish(neg(constants.EIO));
    if (args.sig < 0 or args.sig >= 32) return finish(neg(constants.EINVAL));
    if (!me_task.caps.has(constants.CAP_SPAWN)) return finish(neg(constants.EPERM));
    const me = me_task.id;

    if (args.pid > 0) {
        const target: TaskId = @intCast(args.pid);
        if (state.kernel().sched.getTask(target) == null) return finish(neg(constants.ESRCH));
        if (target != me and !state.kernel().sched.isAncestorOf(me, target)) return finish(neg(constants.EPERM));
        if (args.sig != 0) state.kernel().sched.deliverSignal(target, args.sig);
        return finish(constants.ESUCCESS);
    }

    const pgid: TaskId = if (args.pid == 0) me_task.pgid else blk: {
        const abs_pid = std.math.negate(args.pid) catch return finish(neg(constants.EINVAL));
        break :blk @intCast(abs_pid);
    };

    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var members: std.ArrayList(TaskId) = .empty;
    for (sortedTaskIds(arena)) |id| {
        const t = state.kernel().sched.getTask(id) orelse continue;
        if (t.pgid == pgid and (id == me or state.kernel().sched.isAncestorOf(me, id))) {
            members.append(arena, id) catch @panic("OOM");
        }
    }
    if (members.items.len == 0) return finish(neg(constants.ESRCH));
    if (args.sig != 0) {
        for (members.items) |id| state.kernel().sched.deliverSignal(id, args.sig);
    }
    return finish(constants.ESUCCESS);
}

pub fn fulfillSigdisp(guest: *const Guest, args: mc.SigdispArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    if (args.sig < 1 or args.sig >= 32 or args.sig == constants.SIGKILL) return finish(neg(constants.EINVAL));
    t.setSignalIgnored(args.sig, args.disp == constants.SIG_IGN);
    return finish(constants.ESUCCESS);
}

pub fn fulfillSetpgid(guest: *const Guest, args: mc.SetpgidArgs) Fulfillment {
    const me = guest.taskId();
    if (args.pid < 0) return finish(neg(constants.ESRCH));
    const target: TaskId = if (args.pid == 0) me else @intCast(args.pid);
    if (state.kernel().sched.getTask(target) == null) return finish(neg(constants.ESRCH));
    if (target != me and !state.kernel().sched.isAncestorOf(me, target)) return finish(neg(constants.EPERM));
    const pgid: TaskId = if (args.pgid <= 0) 0 else @intCast(args.pgid);
    state.kernel().sched.setPgid(target, pgid);
    return finish(constants.ESUCCESS);
}

pub fn fulfillTcsetpgrp(guest: *const Guest, args: mc.TcsetpgrpArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    if (args.pgid <= 0) return finish(neg(constants.EINVAL));
    if (!t.caps.has(constants.CAP_SPAWN)) return finish(neg(constants.EPERM));
    state.kernel().sched.foreground_pgid = @intCast(args.pgid);
    return finish(constants.ESUCCESS);
}

pub fn fulfillNice(guest: *const Guest, memory: GuestMemory, args: mc.NiceArgs) Fulfillment {
    _ = guestRange(memory, args.ret, 4) orelse return finish(neg(constants.EINVAL));
    const new_nice: i8 = blk: {
        const t = currentTask(guest) orelse break :blk 0;
        const next = std.math.clamp(@as(i32, t.nice) + args.inc, -20, 19);
        t.nice = @intCast(next);
        break :blk t.nice;
    };
    const signed: i32 = new_nice;
    if (!writeGuestU32(memory, args.ret, @bitCast(signed))) return finish(neg(constants.EINVAL));
    return finish(constants.ESUCCESS);
}
