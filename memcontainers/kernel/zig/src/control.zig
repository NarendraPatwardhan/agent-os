//! control.zig — the `mc_ctl_*` control plane and the host↔kernel scratch-buffer protocol
//! (ZIG_KERNEL §2.1, §4.1).
//!
//! Owns: the scratch buffer (`mc_ctl_buf`) the host writes requests into and reads results
//!   out of, and the VFS control ops (read/write/readdir/stat/mkdir/unlink/chmod/symlink/
//!   readlink/mount/unmount) dispatched into the namespace as SYSTEM_CALLER. An op may
//!   REPLACE the buffer with its result; the host re-queries mc_ctl_buf(0) to read it.
//!   Oracle: kernel/rust/src/lib.rs (mc_ctl_* handlers).
//! Invariants: A9 (denials are errno via the shared FsError→errno map, never traps), §1.3
//!   (the control ABI is control.kdl; never reintroduce mc_prepare_rewind — §15.2).
//! Not here: the exports themselves (main.zig); guest syscall fulfillment (syscall.zig);
//!   the scheduler that runs control-exec children (scheduler.zig). A thin façade over vfs.

const std = @import("std");
const constants = @import("constants_zig");
const vfs = @import("vfs.zig");
const state = @import("state.zig");
const syscall = @import("syscall.zig");
const guest = @import("guest.zig");
const task_mod = @import("task.zig");
const registry = @import("service/registry.zig");
const MountFs = @import("fs/mountfs.zig").MountFs;
const FsError = vfs.FsError;

// control.kdl scratch-buffer frame ids/versions (the two the VFS ops emit). Little-endian;
// bool = 1 byte; bytes = u32 length + payload; a message list = u32 count + length-prefixed
// frames. The e2e host decodes these via the same contract, so it is the drift oracle.
const FILE_STAT_MSG_ID: u16 = 3;
const FILE_STAT_VERSION: u8 = 1;
const DIR_ENTRY_MSG_ID: u16 = 4;
const DIR_ENTRY_VERSION: u8 = 1;
const DIR_ENTRIES_MSG_ID: u16 = 5;
const DIR_ENTRIES_VERSION: u8 = 1;
const EXEC_REQUEST_MSG_ID: u16 = 1;
const EXEC_REQUEST_VERSION: u8 = 1;
const EXEC_OUTCOME_MSG_ID: u16 = 2;
const EXEC_OUTCOME_VERSION: u8 = 1;
const SVC_REQUEST_MSG_ID: u16 = 6;
const SVC_REQUEST_VERSION: u8 = 1;
const SVC_RESPONSE_MSG_ID: u16 = 7;
const SVC_RESPONSE_VERSION: u8 = 1;

const StringPair = struct { key: []const u8, value: []const u8 };
const ExecRequest = struct {
    cmd: []const u8,
    cwd: ?[]const u8,
    env: []const StringPair,
    stdin: ?[]const u8,
};

const SvcRequest = struct {
    service: []const u8,
    request: []const u8,
};

fn putU8(o: *std.ArrayList(u8), a: std.mem.Allocator, v: u8) void {
    o.append(a, v) catch @panic("OOM");
}
fn putU16(o: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) void {
    o.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, v))) catch @panic("OOM");
}
fn putU32(o: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) void {
    o.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, v))) catch @panic("OOM");
}
fn putI32(o: *std.ArrayList(u8), a: std.mem.Allocator, v: i32) void {
    putU32(o, a, @bitCast(v));
}
fn putI64(o: *std.ArrayList(u8), a: std.mem.Allocator, v: i64) void {
    o.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u64, @bitCast(v)))) catch @panic("OOM");
}
fn putBool(o: *std.ArrayList(u8), a: std.mem.Allocator, v: bool) void {
    putU8(o, a, if (v) 1 else 0);
}
fn putBytes(o: *std.ArrayList(u8), a: std.mem.Allocator, v: []const u8) void {
    putU32(o, a, @intCast(v.len));
    o.appendSlice(a, v) catch @panic("OOM");
}

fn readNeed(bytes: []const u8, off: *usize, len: usize) ?[]const u8 {
    const end = std.math.add(usize, off.*, len) catch return null;
    if (end > bytes.len) return null;
    const out = bytes[off.*..end];
    off.* = end;
    return out;
}

fn readU8(bytes: []const u8, off: *usize) ?u8 {
    return (readNeed(bytes, off, 1) orelse return null)[0];
}

fn readU16(bytes: []const u8, off: *usize) ?u16 {
    const b = readNeed(bytes, off, 2) orelse return null;
    return @as(u16, b[0]) | (@as(u16, b[1]) << 8);
}

fn readU32(bytes: []const u8, off: *usize) ?u32 {
    const b = readNeed(bytes, off, 4) orelse return null;
    return @as(u32, b[0]) |
        (@as(u32, b[1]) << 8) |
        (@as(u32, b[2]) << 16) |
        (@as(u32, b[3]) << 24);
}

fn readBytes(bytes: []const u8, off: *usize) ?[]const u8 {
    const len = readU32(bytes, off) orelse return null;
    return readNeed(bytes, off, @intCast(len));
}

fn readStr(bytes: []const u8, off: *usize) ?[]const u8 {
    const out = readBytes(bytes, off) orelse return null;
    if (!std.unicode.utf8ValidateSlice(out)) return null;
    return out;
}

fn readStrMap(arena: std.mem.Allocator, bytes: []const u8, off: *usize) ?[]const StringPair {
    const n = readU32(bytes, off) orelse return null;
    const pairs = arena.alloc(StringPair, @intCast(n)) catch @panic("OOM");
    var prev: ?[]const u8 = null;
    var i: usize = 0;
    while (i < pairs.len) : (i += 1) {
        const key = readStr(bytes, off) orelse return null;
        if (prev) |last| {
            if (!std.mem.lessThan(u8, last, key)) return null;
        }
        const value = readStr(bytes, off) orelse return null;
        pairs[i] = .{ .key = key, .value = value };
        prev = key;
    }
    return pairs;
}

fn decodeExecRequest(arena: std.mem.Allocator, bytes: []const u8) ?ExecRequest {
    var off: usize = 0;
    if ((readU16(bytes, &off) orelse return null) != EXEC_REQUEST_MSG_ID) return null;
    if ((readU8(bytes, &off) orelse return null) != EXEC_REQUEST_VERSION) return null;
    const cmd = readStr(bytes, &off) orelse return null;
    const cwd: ?[]const u8 = switch (readU8(bytes, &off) orelse return null) {
        0 => null,
        1 => readStr(bytes, &off) orelse return null,
        else => return null,
    };
    const env = readStrMap(arena, bytes, &off) orelse return null;
    const stdin: ?[]const u8 = switch (readU8(bytes, &off) orelse return null) {
        0 => null,
        1 => readBytes(bytes, &off) orelse return null,
        else => return null,
    };
    if (off != bytes.len) return null;
    return .{ .cmd = cmd, .cwd = cwd, .env = env, .stdin = stdin };
}

fn decodeSvcRequest(bytes: []const u8) ?SvcRequest {
    var off: usize = 0;
    if ((readU16(bytes, &off) orelse return null) != SVC_REQUEST_MSG_ID) return null;
    if ((readU8(bytes, &off) orelse return null) != SVC_REQUEST_VERSION) return null;
    const service = readStr(bytes, &off) orelse return null;
    const request = readBytes(bytes, &off) orelse return null;
    if (off != bytes.len) return null;
    return .{ .service = service, .request = request };
}

fn encodeExecOutcome(a: std.mem.Allocator, exit_code: i32, stdout: []const u8, stderr: []const u8) []u8 {
    var o: std.ArrayList(u8) = .empty;
    putU16(&o, a, EXEC_OUTCOME_MSG_ID);
    putU8(&o, a, EXEC_OUTCOME_VERSION);
    putI32(&o, a, exit_code);
    putBytes(&o, a, stdout);
    putBytes(&o, a, stderr);
    return o.items;
}

fn encodeSvcResponse(a: std.mem.Allocator, status: i32, body: []const u8) []u8 {
    var o: std.ArrayList(u8) = .empty;
    putU16(&o, a, SVC_RESPONSE_MSG_ID);
    putU8(&o, a, SVC_RESPONSE_VERSION);
    putI32(&o, a, status);
    putBytes(&o, a, body);
    return o.items;
}

fn encodeFileStat(a: std.mem.Allocator, md: vfs.Metadata) []u8 {
    var o: std.ArrayList(u8) = .empty;
    putU16(&o, a, FILE_STAT_MSG_ID);
    putU8(&o, a, FILE_STAT_VERSION);
    putI64(&o, a, @intCast(md.size));
    putBool(&o, a, md.node_type == .dir);
    putBool(&o, a, md.node_type == .symlink);
    putU32(&o, a, md.nlink);
    putU32(&o, a, md.mode);
    return o.items;
}

fn encodeDirEntry(a: std.mem.Allocator, e: vfs.DirEntry) []u8 {
    var o: std.ArrayList(u8) = .empty;
    putU16(&o, a, DIR_ENTRY_MSG_ID);
    putU8(&o, a, DIR_ENTRY_VERSION);
    putBytes(&o, a, e.name);
    putBool(&o, a, e.node_type == .dir);
    putBool(&o, a, e.node_type == .symlink);
    return o.items;
}

fn encodeDirEntries(a: std.mem.Allocator, entries: []const vfs.DirEntry) []u8 {
    var o: std.ArrayList(u8) = .empty;
    putU16(&o, a, DIR_ENTRIES_MSG_ID);
    putU8(&o, a, DIR_ENTRIES_VERSION);
    putU32(&o, a, @intCast(entries.len));
    for (entries) |e| putBytes(&o, a, encodeDirEntry(a, e));
    return o.items;
}

inline fn neg(errno: i32) i32 {
    return -errno;
}

/// FsError -> errno, the single map in errno.zig (re-exported so control's call sites keep the
/// bare spelling). Control's local `neg` negates the result for the control-channel sign
/// convention — the map itself is sign-agnostic.
const errnoFromFs = @import("errno.zig").errnoFromFs;

/// Copy `len` bytes out of the control buffer at `ptr` (bounds-checked), duped into `a`.
fn ctlBytes(a: std.mem.Allocator, ptr: u32, len: u32) ?[]u8 {
    const k = state.kernel();
    const start: usize = ptr;
    const end = start +% @as(usize, len);
    if (end < start or end > k.ctl_buffer.items.len) return null;
    return a.dupe(u8, k.ctl_buffer.items[start..end]) catch @panic("OOM");
}

/// Read a UTF-8 path/string out of the control buffer.
fn ctlStr(a: std.mem.Allocator, ptr: u32, len: u32) ?[]u8 {
    const b = ctlBytes(a, ptr, len) orelse return null;
    if (!std.unicode.utf8ValidateSlice(b)) return null;
    return b;
}

/// Replace the scratch buffer with `bytes` (an op result the host reads via mc_ctl_buf(0)).
fn replaceBuffer(bytes: []const u8) void {
    const k = state.kernel();
    k.ctl_buffer.clearRetainingCapacity();
    k.ctl_buffer.appendSlice(k.gpa, bytes) catch @panic("OOM");
}

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

fn allocCtlJobId(k: *state.Kernel) u32 {
    while (true) {
        const id = k.next_ctl_job_id;
        k.next_ctl_job_id +%= 1;
        if (k.next_ctl_job_id == 0) k.next_ctl_job_id = 1;
        if (id != 0 and !k.ctl_exec_jobs.contains(id) and !k.ctl_svc_jobs.contains(id)) return id;
    }
}

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

/// Ensure the control buffer is at least `len` bytes and return its address. mc_ctl_buf(0)
/// returns the current pointer for reading a result.
pub fn buf(len: usize) ?[*]u8 {
    const k = state.kernel();
    if (k.ctl_buffer.items.len < len) {
        k.ctl_buffer.resize(k.gpa, len) catch return null;
    }
    return k.ctl_buffer.items.ptr;
}

// ── Control VFS ─────────────────────────────────────────────────────────────────────────

/// Read a file in full. `read` follows the final symlink (POSIX open semantics), so a ctl
/// read of a symlink returns the TARGET's content; stat/readdir stay lstat.
pub fn read(path_ptr: u32, path_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    const real = k.ns.canonicalize(a, path, true) catch |e| return neg(errnoFromFs(e));
    var h = k.ns.openAs(a, vfs.SYSTEM_CALLER, real, vfs.OpenFlags.READ) catch |e| return neg(errnoFromFs(e));
    defer h.close();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(k.gpa);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = h.read(&tmp) catch |e| return switch (e) {
            FsError.WouldBlock => neg(constants.EAGAIN),
            else => neg(errnoFromFs(e)),
        };
        if (n == 0) break;
        out.appendSlice(k.gpa, tmp[0..n]) catch @panic("OOM");
    }
    replaceBuffer(out.items);
    return @intCast(out.items.len);
}

/// Read a symlink's target text (no following).
pub fn readlink(path_ptr: u32, path_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(k.gpa);
    k.ns.readlink(a, path, &out) catch |e| return neg(errnoFromFs(e));
    replaceBuffer(out.items);
    return @intCast(out.items.len);
}

/// Write a file, truncating first. The buffer holds the path then the data.
pub fn write(path_ptr: u32, path_len: u32, data_ptr: u32, data_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    const data = ctlBytes(a, data_ptr, data_len) orelse return neg(constants.EINVAL);
    var h = k.ns.openAs(a, vfs.SYSTEM_CALLER, path, vfs.OpenFlags.TRUNCATE) catch |e| return neg(errnoFromFs(e));
    defer h.close();
    var written: usize = 0;
    while (written < data.len) {
        const n = h.write(data[written..]) catch |e| return neg(errnoFromFs(e));
        if (n == 0) break;
        written += n;
    }
    return @intCast(written);
}

/// List a directory into an encoded CtlDirEntries frame.
pub fn readdir(path_ptr: u32, path_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    var entries: std.ArrayList(vfs.DirEntry) = .empty;
    k.ns.readdir(a, vfs.SYSTEM_CALLER, path, &entries) catch |e| return neg(errnoFromFs(e));
    const encoded = encodeDirEntries(a, entries.items);
    replaceBuffer(encoded);
    return @intCast(encoded.len);
}

/// Stat a path (lstat — no symlink following) into an encoded CtlFileStat frame.
pub fn stat(path_ptr: u32, path_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    const md = k.ns.statPath(a, path) catch |e| return switch (e) {
        FsError.WouldBlock => neg(constants.EAGAIN),
        else => neg(errnoFromFs(e)),
    };
    if (md.size > std.math.maxInt(i64)) return neg(constants.EINVAL);
    const encoded = encodeFileStat(a, md);
    replaceBuffer(encoded);
    return @intCast(encoded.len);
}

pub fn mkdir(path_ptr: u32, path_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    k.ns.mkdir(a, vfs.SYSTEM_CALLER, path) catch |e| return neg(errnoFromFs(e));
    return 0;
}

pub fn unlink(path_ptr: u32, path_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    k.ns.unlink(a, vfs.SYSTEM_CALLER, path) catch |e| return neg(errnoFromFs(e));
    return 0;
}

pub fn chmod(path_ptr: u32, path_len: u32, mode: u32) i32 {
    const k = state.kernel();
    if (mode > 0o7777) return neg(constants.EINVAL);
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    k.ns.setMode(a, path, @intCast(mode)) catch |e| return neg(errnoFromFs(e));
    return 0;
}

/// Create a symlink at `link` with target text `target` (two-region buffer layout).
pub fn symlink(target_ptr: u32, target_len: u32, link_ptr: u32, link_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const target = ctlStr(a, target_ptr, target_len) orelse return neg(constants.EINVAL);
    const link = ctlStr(a, link_ptr, link_len) orelse return neg(constants.EINVAL);
    k.ns.symlink(a, target, link) catch |e| return neg(errnoFromFs(e));
    return 0;
}

/// Host-backed mounts need MountFs (the mc_host_call driver) — Phase 6.
pub fn mount(path_ptr: u32, path_len: u32, read_only: i32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    if (path.len == 0 or path[0] != '/') return neg(constants.EINVAL);
    k.ns.mountLabeled(path, MountFs.create(k.gpa, path, &k.host_call, &k.mount_channels).fileSystem(), "mountfs", read_only != 0);
    return 0;
}

pub fn unmount(path_ptr: u32, path_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    k.ns.unmount(path) catch |e| return neg(errnoFromFs(e));
    return 0;
}

// ── Control exec jobs (Phase 4) + resident-service calls (Phase 6) ────────────────────────
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
pub fn svcCallStart(request_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const req_bytes = ctlBytes(a, 0, request_len) orelse return neg(constants.EINVAL);
    const req = decodeSvcRequest(req_bytes) orelse return neg(constants.EINVAL);
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
