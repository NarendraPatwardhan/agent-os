//! exec.zig - host-control exec job lifecycle.
//!
//! Owns: control exec request decoding, child process setup, capture handles,
//!   exec job polling, peeking, closing, and control-job id allocation.
//! Invariants: captured output stays bounded, child fd state is restored after
//!   spawn, and closed jobs reap or kill their task subtrees.
//! Consumes: scheduler state, guest child creation, syscall fd wrappers,
//!   scratch-buffer helpers, wire codecs, and shared errno helpers.
//! Not here: VFS control operations, service-call sessions, or raw frame fields.

const std = @import("std");
const constants = @import("constants_zig");
const vfs = @import("../vfs.zig");
const state = @import("../state.zig");
const syscall = @import("../syscall.zig");
const guest = @import("../guest.zig");
const task_mod = @import("../task.zig");
const buf_mod = @import("buf.zig");
const fs = @import("fs.zig");
const wire = @import("wire.zig");
const FsError = vfs.FsError;

const StringPair = wire.StringPair;
const ctlBytes = buf_mod.ctlBytes;
const replaceBuffer = buf_mod.replaceBuffer;
const decodeExecRequest = wire.decodeExecRequest;
const encodeExecOutcome = wire.encodeExecOutcome;
const neg = fs.neg;
const errnoFromFs = fs.errnoFromFs;
const absolutize = vfs.absolutize;

fn resolveExecCwd(k: *state.Kernel, arena: std.mem.Allocator, requested: ?[]const u8) union(enum) { ok: []const u8, errno: i32 } {
    const parent = k.sched.getTask(1) orelse return .{ .errno = constants.EIO };
    const raw = requested orelse return .{ .ok = parent.cwd };
    const absolute = absolutize(arena, parent.cwd, raw);
    const path = k.ns.canonicalize(arena, absolute, true) catch |e| return .{ .errno = errnoFromFs(e) };
    const md = k.ns.statPath(arena, path) catch |e| return .{ .errno = errnoFromFs(e) };
    if (md.node_type != .dir) return .{ .errno = constants.ENOTDIR };
    return .{ .ok = path };
}

const BytesReadHandle = struct {
    gpa: std.mem.Allocator,
    bytes: []u8,
    offset: usize = 0,

    fn fileHandle(self: *BytesReadHandle) vfs.FileHandle {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn read(self: *BytesReadHandle, out: []u8) FsError!usize {
        if (self.offset >= self.bytes.len) return 0;
        const n = @min(out.len, self.bytes.len - self.offset);
        @memcpy(out[0..n], self.bytes[self.offset..][0..n]);
        self.offset += n;
        return n;
    }
    fn write(_: *BytesReadHandle, _: []const u8) FsError!usize {
        return FsError.BadFileDescriptor;
    }
    fn seek(self: *BytesReadHandle, pos: vfs.SeekFrom) FsError!u64 {
        const size: i64 = @intCast(self.bytes.len);
        const cur: i64 = @intCast(self.offset);
        const next: i64 = switch (pos) {
            .start => |n| @intCast(n),
            .current => |n| cur + n,
            .end => |n| size + n,
        };
        if (next < 0) return FsError.InvalidPath;
        self.offset = @intCast(next);
        return @intCast(self.offset);
    }
    fn stat(self: *BytesReadHandle) FsError!vfs.Metadata {
        return vfs.Metadata.file(@intCast(self.bytes.len));
    }
    fn truncate(_: *BytesReadHandle, _: u64) FsError!void {
        return FsError.BadFileDescriptor;
    }
    fn close(self: *BytesReadHandle) void {
        const gpa = self.gpa;
        gpa.free(self.bytes);
        gpa.destroy(self);
    }
    const vtable = vfs.FileHandle.VTable{
        .read = hRead,
        .write = hWrite,
        .seek = hSeek,
        .stat = hStat,
        .truncate = hTruncate,
        .close = hClose,
    };
    fn hRead(p: *anyopaque, out: []u8) FsError!usize {
        return self_(p).read(out);
    }
    fn hWrite(p: *anyopaque, bytes: []const u8) FsError!usize {
        return self_(p).write(bytes);
    }
    fn hSeek(p: *anyopaque, pos: vfs.SeekFrom) FsError!u64 {
        return self_(p).seek(pos);
    }
    fn hStat(p: *anyopaque) FsError!vfs.Metadata {
        return self_(p).stat();
    }
    fn hTruncate(p: *anyopaque, size: u64) FsError!void {
        return self_(p).truncate(size);
    }
    fn hClose(p: *anyopaque) void {
        self_(p).close();
    }
    fn self_(p: *anyopaque) *BytesReadHandle {
        return @ptrCast(@alignCast(p));
    }
};

/// Ceiling on a single exec job's captured stdout/stderr — a runaway guest program must not be able
/// to grow the capture buffer until the kernel heap is exhausted and the VM traps. Generous: normal
/// control-channel exec output (coreutils) is tiny; heavy engines use the (separately capped) svc
/// channel, not exec capture.
const MAX_CAPTURE_BYTES: usize = 64 << 20;

const CaptureWriteHandle = struct {
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    offset: usize = 0,

    fn fileHandle(self: *CaptureWriteHandle) vfs.FileHandle {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn read(_: *CaptureWriteHandle, _: []u8) FsError!usize {
        return FsError.BadFileDescriptor;
    }
    fn write(self: *CaptureWriteHandle, bytes: []const u8) FsError!usize {
        // Exec stdout/stderr capture is an unbounded guest-driven sink: a runaway program could
        // otherwise grow this buffer until the kernel heap is exhausted and the whole VM traps.
        // Cap it and fail closed with EMSGSIZE (via MessageTooBig) at the ceiling or on OOM —
        // a guest fault is an errno, never a host trap (§4.3). Invariant: buf.items.len never
        // exceeds MAX_CAPTURE_BYTES, so the subtraction cannot underflow.
        if (bytes.len > MAX_CAPTURE_BYTES - self.buf.items.len) return FsError.MessageTooBig;
        self.buf.appendSlice(self.gpa, bytes) catch return FsError.MessageTooBig;
        self.offset = self.buf.items.len;
        return bytes.len;
    }
    fn seek(self: *CaptureWriteHandle, pos: vfs.SeekFrom) FsError!u64 {
        const size: i64 = @intCast(self.buf.items.len);
        const cur: i64 = @intCast(self.offset);
        const next: i64 = switch (pos) {
            .start => |n| @intCast(n),
            .current => |n| cur + n,
            .end => |n| size + n,
        };
        if (next < 0) return FsError.InvalidPath;
        self.offset = @intCast(next);
        return @intCast(self.offset);
    }
    fn stat(self: *CaptureWriteHandle) FsError!vfs.Metadata {
        return vfs.Metadata.file(@intCast(self.buf.items.len));
    }
    fn truncate(self: *CaptureWriteHandle, size: u64) FsError!void {
        if (size > MAX_CAPTURE_BYTES) return FsError.MessageTooBig;
        self.buf.resize(self.gpa, @intCast(size)) catch return FsError.MessageTooBig;
        if (self.offset > self.buf.items.len) self.offset = self.buf.items.len;
    }
    fn close(self: *CaptureWriteHandle) void {
        self.gpa.destroy(self);
    }
    const vtable = vfs.FileHandle.VTable{
        .read = hRead,
        .write = hWrite,
        .seek = hSeek,
        .stat = hStat,
        .truncate = hTruncate,
        .close = hClose,
    };
    fn hRead(p: *anyopaque, out: []u8) FsError!usize {
        return self_(p).read(out);
    }
    fn hWrite(p: *anyopaque, bytes: []const u8) FsError!usize {
        return self_(p).write(bytes);
    }
    fn hSeek(p: *anyopaque, pos: vfs.SeekFrom) FsError!u64 {
        return self_(p).seek(pos);
    }
    fn hStat(p: *anyopaque) FsError!vfs.Metadata {
        return self_(p).stat();
    }
    fn hTruncate(p: *anyopaque, size: u64) FsError!void {
        return self_(p).truncate(size);
    }
    fn hClose(p: *anyopaque) void {
        self_(p).close();
    }
    fn self_(p: *anyopaque) *CaptureWriteHandle {
        return @ptrCast(@alignCast(p));
    }
};

fn makeBytesFd(k: *state.Kernel, bytes: ?[]const u8) vfs.FileHandle {
    const h = k.gpa.create(BytesReadHandle) catch @panic("OOM");
    const src = bytes orelse "";
    h.* = .{ .gpa = k.gpa, .bytes = k.gpa.dupe(u8, src) catch @panic("OOM") };
    return syscall.wrapFileHandle(k.gpa, h.fileHandle(), true, false);
}

fn makeCaptureFd(k: *state.Kernel, capture: *std.ArrayList(u8)) vfs.FileHandle {
    const h = k.gpa.create(CaptureWriteHandle) catch @panic("OOM");
    h.* = .{ .gpa = k.gpa, .buf = capture };
    return syscall.wrapFileHandle(k.gpa, h.fileHandle(), false, true);
}

fn freeEnvEntry(k: *state.Kernel, task: *task_mod.Task, key: []const u8) void {
    if (task.env.fetchRemove(key)) |kv| {
        k.gpa.free(kv.key);
        k.gpa.free(kv.value);
    }
}

fn applyExecEnv(k: *state.Kernel, task: *task_mod.Task, env: []const StringPair) void {
    for (env) |pair| {
        freeEnvEntry(k, task, pair.key);
        const key = k.gpa.dupe(u8, pair.key) catch @panic("OOM");
        const value = k.gpa.dupe(u8, pair.value) catch @panic("OOM");
        task.env.put(k.gpa, key, value) catch @panic("OOM");
    }
}

fn createCtlChild(_: *const anyopaque, child_id: u32, bytes: []const u8, cwd: []const u8) bool {
    return guest.createChildGuest(child_id, bytes, cwd);
}

pub fn allocCtlJobId(k: *state.Kernel) u32 {
    while (true) {
        const id = k.next_ctl_job_id;
        k.next_ctl_job_id +%= 1;
        if (k.next_ctl_job_id == 0) k.next_ctl_job_id = 1;
        if (id != 0 and !k.ctl_exec_jobs.contains(id) and !k.ctl_svc_jobs.contains(id)) return id;
    }
}

fn finishExecJobIfZombie(k: *state.Kernel, job: *state.CtlExecJob) void {
    if (job.done) return;
    const pid = job.pid orelse {
        job.done = true;
        return;
    };
    const t = k.sched.getTask(pid) orelse {
        job.done = true;
        return;
    };
    if (t.state != .zombie) return;
    job.exit_code = k.sched.getExitCode(pid) orelse 0;
    k.sched.reapZombie(pid);
    k.sched.dropDeadPipes();
    job.done = true;
}

fn taskIdDesc(_: void, a: u32, b: u32) bool {
    return a > b;
}

fn killExecSubtree(k: *state.Kernel, root: u32) void {
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var ids: std.ArrayList(u32) = .empty;
    for (k.sched.taskIds(arena)) |pid| {
        if (pid == root or k.sched.isAncestorOf(root, pid)) ids.append(arena, pid) catch @panic("OOM");
    }
    std.mem.sort(u32, ids.items, {}, taskIdDesc);
    for (ids.items) |pid| {
        if (k.sched.getTask(pid)) |t| {
            if (t.state != .zombie) k.sched.killTask(pid, 130);
        }
        k.sched.reapZombie(pid);
    }
    k.sched.dropDeadPipes();
}

pub fn execStart(request_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const req_bytes = ctlBytes(a, 0, request_len) orelse return neg(constants.EINVAL);
    const req = decodeExecRequest(a, req_bytes) orelse return neg(constants.EINVAL);
    const cwd = switch (resolveExecCwd(k, a, req.cwd)) {
        .ok => |path| path,
        .errno => |errno| return neg(errno),
    };
    const parent = k.sched.getTask(1) orelse return neg(constants.EIO);

    const stdout_buf = k.gpa.create(std.ArrayList(u8)) catch @panic("OOM");
    stdout_buf.* = .empty;
    const stderr_buf = k.gpa.create(std.ArrayList(u8)) catch @panic("OOM");
    stderr_buf.* = .empty;

    const stdin_handle = makeBytesFd(k, req.stdin);
    const stdout_handle = makeCaptureFd(k, stdout_buf);
    const stderr_handle = makeCaptureFd(k, stderr_buf);
    const stdin_fd = task_mod.Fd{ .file = stdin_handle };
    const stdout_fd = task_mod.Fd{ .file = stdout_handle };
    const stderr_fd = task_mod.Fd{ .file = stderr_handle };

    const old0 = parent.getFd(0);
    const old1 = parent.getFd(1);
    const old2 = parent.getFd(2);
    parent.setFd(k.gpa, 0, stdin_fd);
    parent.setFd(k.gpa, 1, stdout_fd);
    parent.setFd(k.gpa, 2, stderr_fd);
    const argv: [3][]const u8 = .{ "sh", "-c", req.cmd };
    const spawn_result = syscall.spawnNative(1, &argv, 0, 1, 2, constants.TIER_INHERIT, .{
        .ptr = @ptrCast(k),
        .create_child = createCtlChild,
    });
    parent.setFd(k.gpa, 0, old0);
    parent.setFd(k.gpa, 1, old1);
    parent.setFd(k.gpa, 2, old2);
    syscall.releaseFdValue(stdin_fd);
    syscall.releaseFdValue(stdout_fd);
    syscall.releaseFdValue(stderr_fd);

    const pid = switch (spawn_result) {
        .pid => |child_pid| child_pid,
        .errno => |errno| {
            stdout_buf.deinit(k.gpa);
            k.gpa.destroy(stdout_buf);
            stderr_buf.deinit(k.gpa);
            k.gpa.destroy(stderr_buf);
            return neg(errno);
        },
    };
    const child_id: u32 = @intCast(pid);
    k.sched.setPgid(child_id, 0);
    if (k.sched.getTask(child_id)) |child| {
        child.setCwd(k.gpa, cwd);
        applyExecEnv(k, child, req.env);
    }

    const id = allocCtlJobId(k);
    k.ctl_exec_jobs.put(k.gpa, id, .{
        .pid = child_id,
        .stdout = stdout_buf,
        .stderr = stderr_buf,
    }) catch @panic("OOM");
    return @intCast(id);
}

pub fn execPoll(job_id: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    {
        const job = k.ctl_exec_jobs.getPtr(job_id) orelse return neg(constants.EINVAL);
        if (!job.done) {
            k.sched.checkUnblocked();
            _ = state.stepReadyRound(k);
            finishExecJobIfZombie(k, job);
        }
        if (!job.done) return 0;
    }

    var kv = k.ctl_exec_jobs.fetchRemove(job_id) orelse return neg(constants.EINVAL);
    defer kv.value.deinit(k.gpa);
    const encoded = encodeExecOutcome(k.gpa, kv.value.exit_code, kv.value.stdout.items, kv.value.stderr.items);
    defer k.gpa.free(encoded);
    replaceBuffer(encoded);
    return @intCast(encoded.len);
}
pub fn execPeek(job_id: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    const job = k.ctl_exec_jobs.getPtr(job_id) orelse return neg(constants.EINVAL);
    replaceBuffer(job.stdout.items);
    return @intCast(job.stdout.items.len);
}
pub fn execClose(job_id: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var kv = k.ctl_exec_jobs.fetchRemove(job_id) orelse return neg(constants.EINVAL);
    if (kv.value.pid) |pid| killExecSubtree(k, pid);
    kv.value.deinit(k.gpa);
    return 0;
}
