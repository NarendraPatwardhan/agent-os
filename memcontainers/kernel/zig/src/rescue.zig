//! In-kernel rescue shell binding for shcore.
//!
//! This adapter binds shcore's synchronous ShellOs vtable directly to pid 1's
//! kernel Task and the real scheduler/VFS internals. It is used only when the
//! guest /bin/sh cannot be loaded.

const std = @import("std");
const shcore = @import("shcore");
const shos = shcore.os;
const constants = @import("constants_zig");
const state = @import("state.zig");
const guest = @import("guest.zig");
const syscall = @import("syscall.zig");
const task_mod = @import("task.zig");
const vfs = @import("vfs.zig");

const Task = task_mod.Task;
const TaskId = task_mod.TaskId;
const Fd = task_mod.Fd;

const RESCUE_PID: TaskId = 1;
const INLINE_WAIT_GUARD: usize = 200_000;

pub const KernelShellOs = struct {
    k: *state.Kernel,
    shell_os: shos.ShellOs = undefined,

    pub fn init(self: *KernelShellOs, k: *state.Kernel) void {
        self.* = .{ .k = k };
        self.shell_os = .{
            .ptr = @ptrCast(self),
            .allocator = k.gpa,
            .vtable = &vtable,
        };
    }

    pub fn shellOs(self: *KernelShellOs) *shos.ShellOs {
        return &self.shell_os;
    }

    fn task(self: *KernelShellOs) shos.ShellError!*Task {
        return self.k.sched.getTask(RESCUE_PID) orelse error.NotFound;
    }
};

pub fn start(k: *state.Kernel) void {
    const adapter = k.gpa.create(KernelShellOs) catch @panic("OOM");
    adapter.init(k);
    const shell = k.gpa.create(shcore.Shell) catch @panic("OOM");
    shell.* = shcore.init(k.gpa, adapter.shellOs());
    if (k.sched.getTask(RESCUE_PID)) |t| {
        t.setSignalIgnored(constants.SIGINT, true);
        t.setSignalIgnored(constants.SIGTSTP, true);
    }
    k.rescue_os = adapter;
    k.rescue_shell = shell;
    k.rescue_active = true;
    prompt();
}

pub fn submitLine(k: *state.Kernel, line: []const u8) void {
    const sh = k.rescue_shell orelse return;
    _ = sh.run(line) catch {
        syscall.termWrite("sh: execution error\n", true);
    };
    prompt();
}

pub fn prompt() void {
    syscall.termWrite("$ ", false);
}

fn ctx(ptr: *anyopaque) *KernelShellOs {
    return @ptrCast(@alignCast(ptr));
}

fn fdIndex(fd: shos.Fd) shos.ShellError!usize {
    if (fd < 0) return error.BadFileDescriptor;
    return @intCast(fd);
}

fn fsToShell(e: vfs.FsError) shos.ShellError {
    return switch (e) {
        vfs.FsError.NotFound => error.NotFound,
        vfs.FsError.NotDir => error.NotDir,
        vfs.FsError.PermissionDenied => error.PermissionDenied,
        vfs.FsError.AccessDenied => error.AccessDenied,
        vfs.FsError.InvalidPath => error.InvalidArgument,
        vfs.FsError.BadFileDescriptor => error.BadFileDescriptor,
        vfs.FsError.NotImplemented => error.NotImplemented,
        else => error.Io,
    };
}

fn errnoToShell(errno: i32) shos.ShellError {
    return switch (errno) {
        constants.EACCES => error.AccessDenied,
        constants.EBADF => error.BadFileDescriptor,
        constants.EINVAL => error.InvalidArgument,
        constants.ENOTDIR => error.NotDir,
        constants.ENOENT => error.NotFound,
        constants.ENOSYS => error.NotImplemented,
        constants.EPERM => error.PermissionDenied,
        constants.EMFILE => error.TooManyFiles,
        else => error.Io,
    };
}

fn absolutize(arena: std.mem.Allocator, cwd: []const u8, raw: []const u8) []const u8 {
    if (raw.len == 0) return arena.dupe(u8, cwd) catch @panic("OOM");
    if (raw[0] == '/') return arena.dupe(u8, raw) catch @panic("OOM");
    if (std.mem.eql(u8, cwd, "/")) return std.fmt.allocPrint(arena, "/{s}", .{raw}) catch @panic("OOM");
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ cwd, raw }) catch @panic("OOM");
}

fn resolvePath(self: *KernelShellOs, arena: std.mem.Allocator, raw: []const u8, need_write: bool, follow_final: bool) shos.ShellError![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidArgument;
    const t = try self.task();
    const absolute = absolutize(arena, t.cwd, raw);
    const path = self.k.ns.canonicalize(arena, absolute, follow_final) catch |e| return fsToShell(e);
    const needed = if (need_write) self.k.ns.writeCapAt(arena, path) else constants.CAP_FS_READ;
    if (!t.caps.has(needed)) return error.PermissionDenied;
    return path;
}

fn releaseStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

fn createChild(_: *const anyopaque, child_id: TaskId, bytes: []const u8, cwd: []const u8) bool {
    return guest.createChildGuest(child_id, bytes, cwd);
}

fn vSpawn(ptr: *anyopaque, argv: []const []const u8, in_fd: shos.Fd, out_fd: shos.Fd, err_fd: shos.Fd, tier: i32) shos.ShellError!shos.Pid {
    const self = ctx(ptr);
    return switch (syscall.spawnNative(RESCUE_PID, argv, in_fd, out_fd, err_fd, tier, .{
        .ptr = @ptrCast(self),
        .create_child = createChild,
    })) {
        .pid => |pid| @intCast(pid),
        .errno => |errno| errnoToShell(errno),
    };
}

fn reapIfZombie(self: *KernelShellOs, pid: TaskId) ?i32 {
    const t = self.k.sched.getTask(pid) orelse return null;
    if (t.state != .zombie) return null;
    const code = self.k.sched.getExitCode(pid) orelse 0;
    self.k.sched.reapZombie(pid);
    self.k.sched.dropDeadPipes();
    return code;
}

fn vWaitpid(ptr: *anyopaque, pid: shos.Pid) shos.ShellError!i32 {
    const self = ctx(ptr);
    if (pid == 0) return error.NotFound;
    const child_id: TaskId = @intCast(pid);
    if (self.k.sched.getTask(child_id)) |child| {
        if (child.parent_id == null or child.parent_id.? != RESCUE_PID) return error.NotFound;
    } else return error.NotFound;

    var guard: usize = 0;
    while (guard < INLINE_WAIT_GUARD) : (guard += 1) {
        const child = self.k.sched.getTask(child_id) orelse return error.NotFound;
        if (child.state == .zombie) return reapIfZombie(self, child_id) orelse 0;
        if (child.takeStopReport()) return constants.STOPPED_STATUS_BASE + constants.SIGTSTP;

        self.k.sched.checkUnblocked();
        const ran = state.stepReadyRound(self.k);
        if (reapIfZombie(self, child_id)) |code| return code;
        if (!ran) return error.Io;
    }
    return error.Io;
}

fn lessTaskId(_: void, a: TaskId, b: TaskId) bool {
    return a < b;
}

fn vTryWaitAny(ptr: *anyopaque) shos.ShellError!?shos.WaitStatus {
    const self = ctx(ptr);
    self.k.sched.checkUnblocked();
    var arena_state = std.heap.ArenaAllocator.init(self.k.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ids = self.k.sched.taskIds(arena);
    std.mem.sort(TaskId, ids, {}, lessTaskId);
    for (ids) |id| {
        const child = self.k.sched.getTask(id) orelse continue;
        if (child.parent_id == null or child.parent_id.? != RESCUE_PID or child.state != .zombie) continue;
        const code = self.k.sched.getExitCode(id) orelse 0;
        self.k.sched.reapZombie(id);
        self.k.sched.dropDeadPipes();
        return .{ .pid = id, .status = code };
    }
    return null;
}

fn vGetpid(_: *anyopaque) shos.Pid {
    return RESCUE_PID;
}

fn vPipe(ptr: *anyopaque) shos.ShellError!struct { shos.Fd, shos.Fd } {
    const self = ctx(ptr);
    const t = try self.task();
    const p = self.k.sched.allocPipe();
    p.addReader();
    const rfd = t.allocFd(self.k.gpa, .{ .pipe_read = p });
    p.addWriter();
    const wfd = t.allocFd(self.k.gpa, .{ .pipe_write = p });
    return .{ @intCast(rfd), @intCast(wfd) };
}

fn vDup(ptr: *anyopaque, fd: shos.Fd) shos.ShellError!shos.Fd {
    const self = ctx(ptr);
    const t = try self.task();
    const idx = try fdIndex(fd);
    const cloned = syscall.cloneFd(t.getFd(idx)) orelse return error.BadFileDescriptor;
    return @intCast(t.allocFd(self.k.gpa, cloned));
}

fn vDup2(ptr: *anyopaque, old_fd: shos.Fd, new_fd: shos.Fd) shos.ShellError!void {
    const self = ctx(ptr);
    const t = try self.task();
    const old_idx = try fdIndex(old_fd);
    const new_idx = try fdIndex(new_fd);
    if (old_idx == new_idx) {
        if (t.getFd(old_idx) == .none) return error.BadFileDescriptor;
        return;
    }
    const cloned = syscall.cloneFd(t.getFd(old_idx)) orelse return error.BadFileDescriptor;
    t.closeFd(new_idx);
    t.setFd(self.k.gpa, new_idx, cloned);
    self.k.sched.checkUnblocked();
}

fn vClose(ptr: *anyopaque, fd: shos.Fd) void {
    const self = ctx(ptr);
    if (fd < 0) return;
    if (self.k.sched.getTask(RESCUE_PID)) |t| t.closeFd(@intCast(fd));
    self.k.sched.checkUnblocked();
}

fn vOpen(ptr: *anyopaque, path_raw: []const u8, raw_flags: i32) shos.ShellError!shos.Fd {
    const self = ctx(ptr);
    const t = try self.task();
    var flags = syscall.openFlags(raw_flags) orelse return error.InvalidArgument;
    const need_write = flags.write or flags.create or flags.truncate or flags.append;
    var arena_state = std.heap.ArenaAllocator.init(self.k.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try resolvePath(self, arena, path_raw, need_write, true);
    if ((flags.read or !need_write) and !t.caps.has(constants.CAP_FS_READ)) return error.PermissionDenied;
    flags.noatime = !t.caps.has(constants.CAP_AMBIENT);
    const h = self.k.ns.openAs(arena, RESCUE_PID, path, flags) catch |e| return fsToShell(e);
    const wrapped = syscall.wrapFileHandle(self.k.gpa, h, flags.read or !need_write, flags.write);
    return @intCast(t.allocFd(self.k.gpa, .{ .file = wrapped }));
}

fn vRead(ptr: *anyopaque, fd: shos.Fd, buf: []u8) shos.ShellError!usize {
    if (buf.len == 0) return 0;
    const self = ctx(ptr);
    const t = try self.task();
    const idx = try fdIndex(fd);
    return switch (t.getFd(idx)) {
        .file => |fh| fh.read(buf) catch |e| fsToShell(e),
        .pipe_read => |p| blk: {
            const n = p.read(buf);
            if (n == 0 and !p.isWriteClosed()) return error.Io;
            self.k.sched.checkUnblocked();
            break :blk n;
        },
        else => error.BadFileDescriptor,
    };
}

fn vWriteAll(ptr: *anyopaque, fd: shos.Fd, bytes: []const u8) shos.ShellError!void {
    if (bytes.len == 0) return;
    const self = ctx(ptr);
    const t = try self.task();
    const idx = try fdIndex(fd);
    switch (t.getFd(idx)) {
        .none => {
            if (fd == shos.STDOUT or fd == shos.STDERR) {
                syscall.termWrite(bytes, fd == shos.STDERR);
                return;
            }
            return error.BadFileDescriptor;
        },
        .file => |fh| {
            var off: usize = 0;
            while (off < bytes.len) {
                const n = fh.write(bytes[off..]) catch |e| return fsToShell(e);
                if (n == 0) return error.Io;
                off += n;
            }
        },
        .pipe_write => |p| {
            var off: usize = 0;
            while (off < bytes.len) {
                if (p.isReadClosed()) return error.Io;
                const n = p.write(bytes[off..]);
                if (n == 0) return error.Io;
                off += n;
                self.k.sched.checkUnblocked();
            }
        },
        .pipe_read => return error.BadFileDescriptor,
        .net => return error.BadFileDescriptor,
        .ws => return error.BadFileDescriptor,
        .host_call => return error.BadFileDescriptor,
        .serve => return error.BadFileDescriptor,
        .svc_serve => return error.BadFileDescriptor,
        .svc_conn => return error.BadFileDescriptor,
        .svc_call => return error.BadFileDescriptor,
    }
}

fn vReaddir(ptr: *anyopaque, allocator: std.mem.Allocator, path_raw: []const u8) shos.ShellError![]const []const u8 {
    const self = ctx(ptr);
    var arena_state = std.heap.ArenaAllocator.init(self.k.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try resolvePath(self, arena, path_raw, false, true);
    var entries: std.ArrayList(vfs.DirEntry) = .empty;
    self.k.ns.readdir(arena, RESCUE_PID, path, &entries) catch |e| return fsToShell(e);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer releaseStringList(allocator, &out);
    for (entries.items) |entry| {
        const owned = allocator.dupe(u8, entry.name) catch return error.Io;
        errdefer allocator.free(owned);
        out.append(allocator, owned) catch return error.Io;
    }
    return out.toOwnedSlice(allocator) catch error.Io;
}

fn vStat(ptr: *anyopaque, path_raw: []const u8) shos.ShellError!shos.FileStat {
    const self = ctx(ptr);
    var arena_state = std.heap.ArenaAllocator.init(self.k.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try resolvePath(self, arena, path_raw, false, true);
    const md = self.k.ns.statPath(arena, path) catch |e| return fsToShell(e);
    return .{
        .is_dir = md.node_type == .dir,
        .size = md.size,
        .mode = md.mode,
        .mtime = md.mtime,
    };
}

fn vMkdir(ptr: *anyopaque, path_raw: []const u8) shos.ShellError!void {
    const self = ctx(ptr);
    var arena_state = std.heap.ArenaAllocator.init(self.k.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try resolvePath(self, arena, path_raw, true, false);
    self.k.ns.mkdir(arena, RESCUE_PID, path) catch |e| return fsToShell(e);
}

fn vUnlink(ptr: *anyopaque, path_raw: []const u8) shos.ShellError!void {
    const self = ctx(ptr);
    var arena_state = std.heap.ArenaAllocator.init(self.k.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try resolvePath(self, arena, path_raw, true, false);
    self.k.ns.unlink(arena, RESCUE_PID, path) catch |e| return fsToShell(e);
}

fn vGetcwd(ptr: *anyopaque, allocator: std.mem.Allocator) shos.ShellError![]const u8 {
    const self = ctx(ptr);
    const t = try self.task();
    return allocator.dupe(u8, t.cwd) catch error.Io;
}

fn vChdir(ptr: *anyopaque, path_raw: []const u8) shos.ShellError!void {
    const self = ctx(ptr);
    const t = try self.task();
    var arena_state = std.heap.ArenaAllocator.init(self.k.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try resolvePath(self, arena, path_raw, false, true);
    const md = self.k.ns.statPath(arena, path) catch |e| return fsToShell(e);
    if (md.node_type != .dir) return error.NotDir;
    if (!md.ownerExecutable()) return error.AccessDenied;
    t.setCwd(self.k.gpa, path);
}

fn vBind(ptr: *anyopaque, old_raw: []const u8, new_raw: []const u8) shos.ShellError!void {
    const self = ctx(ptr);
    const t = try self.task();
    if (!t.caps.has(constants.CAP_MOUNT)) return error.PermissionDenied;
    var arena_state = std.heap.ArenaAllocator.init(self.k.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const old_abs = absolutize(arena, t.cwd, old_raw);
    const new_abs = absolutize(arena, t.cwd, new_raw);
    self.k.ns.bind(arena, old_abs, new_abs) catch |e| return fsToShell(e);
}

fn vUnmount(ptr: *anyopaque, path_raw: []const u8) shos.ShellError!void {
    const self = ctx(ptr);
    const t = try self.task();
    if (!t.caps.has(constants.CAP_MOUNT)) return error.PermissionDenied;
    var arena_state = std.heap.ArenaAllocator.init(self.k.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path_abs = absolutize(arena, t.cwd, path_raw);
    const path = self.k.ns.canonicalize(arena, path_abs, false) catch |e| return fsToShell(e);
    self.k.ns.unmount(path) catch |e| return fsToShell(e);
}

fn vGetenv(ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) shos.ShellError!?[]const u8 {
    const self = ctx(ptr);
    const t = try self.task();
    const value = t.env.get(name) orelse return null;
    return allocator.dupe(u8, value) catch error.Io;
}

fn vSetenv(ptr: *anyopaque, name: []const u8, value: []const u8) shos.ShellError!void {
    const self = ctx(ptr);
    const t = try self.task();
    if (t.env.fetchRemove(name)) |old| {
        self.k.gpa.free(old.key);
        self.k.gpa.free(old.value);
    }
    const owned_name = self.k.gpa.dupe(u8, name) catch return error.Io;
    errdefer self.k.gpa.free(owned_name);
    const owned_value = self.k.gpa.dupe(u8, value) catch return error.Io;
    errdefer self.k.gpa.free(owned_value);
    t.env.put(self.k.gpa, owned_name, owned_value) catch return error.Io;
}

fn vUnsetenv(ptr: *anyopaque, name: []const u8) shos.ShellError!void {
    const self = ctx(ptr);
    const t = try self.task();
    if (t.env.fetchRemove(name)) |old| {
        self.k.gpa.free(old.key);
        self.k.gpa.free(old.value);
    }
}

fn vEnviron(ptr: *anyopaque, allocator: std.mem.Allocator) shos.ShellError![]const []const u8 {
    const self = ctx(ptr);
    const t = try self.task();
    var out: std.ArrayList([]const u8) = .empty;
    errdefer releaseStringList(allocator, &out);
    var it = t.env.keyIterator();
    while (it.next()) |name| {
        const owned = allocator.dupe(u8, name.*) catch return error.Io;
        errdefer allocator.free(owned);
        out.append(allocator, owned) catch return error.Io;
    }
    return out.toOwnedSlice(allocator) catch error.Io;
}

fn vKill(ptr: *anyopaque, pid: i32, sig: shos.Signal) shos.ShellError!void {
    const self = ctx(ptr);
    const sig_num = @intFromEnum(sig);
    const me = try self.task();
    if (!me.caps.has(constants.CAP_SPAWN)) return error.PermissionDenied;
    if (pid > 0) {
        const target: TaskId = @intCast(pid);
        if (self.k.sched.getTask(target) == null) return error.NotFound;
        if (target != RESCUE_PID and !self.k.sched.isAncestorOf(RESCUE_PID, target)) return error.PermissionDenied;
        self.k.sched.deliverSignal(target, sig_num);
        return;
    }

    const pgid: TaskId = if (pid == 0) me.pgid else blk: {
        const abs_pid = std.math.negate(pid) catch return error.InvalidArgument;
        break :blk @intCast(abs_pid);
    };
    var arena_state = std.heap.ArenaAllocator.init(self.k.gpa);
    defer arena_state.deinit();
    const ids = self.k.sched.taskIds(arena_state.allocator());
    var found = false;
    for (ids) |id| {
        const t = self.k.sched.getTask(id) orelse continue;
        if (t.pgid == pgid and (id == RESCUE_PID or self.k.sched.isAncestorOf(RESCUE_PID, id))) {
            found = true;
            self.k.sched.deliverSignal(id, sig_num);
        }
    }
    if (!found) return error.NotFound;
}

fn vSetSigdisp(ptr: *anyopaque, sig: shos.Signal, disp: shos.SigDisp) void {
    if (sig == .kill) return;
    const self = ctx(ptr);
    if (self.k.sched.getTask(RESCUE_PID)) |t| {
        t.setSignalIgnored(@intFromEnum(sig), disp == .ignore);
    }
}

fn vSetpgid(ptr: *anyopaque, pid: shos.Pid, pgid: shos.Pid) shos.ShellError!void {
    const self = ctx(ptr);
    const target: TaskId = if (pid == 0) RESCUE_PID else @intCast(pid);
    if (self.k.sched.getTask(target) == null) return error.NotFound;
    if (target != RESCUE_PID and !self.k.sched.isAncestorOf(RESCUE_PID, target)) return error.PermissionDenied;
    self.k.sched.setPgid(target, @intCast(pgid));
}

fn vSetForegroundPgid(ptr: *anyopaque, pgid: shos.Pid) shos.ShellError!void {
    if (pgid == 0) return error.InvalidArgument;
    const self = ctx(ptr);
    const t = try self.task();
    if (!t.caps.has(constants.CAP_SPAWN)) return error.PermissionDenied;
    self.k.sched.foreground_pgid = @intCast(pgid);
}

fn vIsatty(_: *anyopaque, fd: shos.Fd) bool {
    return fd >= 0 and fd <= 2;
}

const vtable = shos.ShellOs.VTable{
    .spawn = vSpawn,
    .waitpid = vWaitpid,
    .try_wait_any = vTryWaitAny,
    .getpid = vGetpid,
    .pipe = vPipe,
    .dup = vDup,
    .dup2 = vDup2,
    .close = vClose,
    .open = vOpen,
    .read = vRead,
    .write_all = vWriteAll,
    .readdir = vReaddir,
    .stat = vStat,
    .mkdir = vMkdir,
    .unlink = vUnlink,
    .getcwd = vGetcwd,
    .chdir = vChdir,
    .bind = vBind,
    .unmount = vUnmount,
    .getenv = vGetenv,
    .setenv = vSetenv,
    .unsetenv = vUnsetenv,
    .environ = vEnviron,
    .kill = vKill,
    .set_sigdisp = vSetSigdisp,
    .setpgid = vSetpgid,
    .set_foreground_pgid = vSetForegroundPgid,
    .isatty = vIsatty,
};
