//! fd.zig - shared syscall file-descriptor ownership.
//!
//! Owns: SharedFile reference counting, fd cloning/release, and the vfs handle
//!   wrapper used when descriptors cross task boundaries.
//! Invariants: every retained descriptor has a matching release path, and shared
//!   file handles preserve their readable/writable mode checks.
//! Consumes: task fd variants and the VFS file-handle interface.
//! Not here: path resolution, descriptor-number syscalls, or service envelopes.

const std = @import("std");
const task_mod = @import("../task.zig");
const vfs = @import("../vfs.zig");

const Task = task_mod.Task;
const Fd = task_mod.Fd;

pub const SharedFile = struct {
    gpa: std.mem.Allocator,
    inner: vfs.FileHandle,
    refs: usize = 1,
    readable: bool,
    writable: bool,

    pub fn wrap(gpa: std.mem.Allocator, inner: vfs.FileHandle, readable: bool, writable: bool) vfs.FileHandle {
        const self = gpa.create(SharedFile) catch @panic("OOM");
        self.* = .{ .gpa = gpa, .inner = inner, .readable = readable, .writable = writable };
        return .{ .ptr = self, .vtable = &handle_vtable };
    }

    pub fn retain(handle: vfs.FileHandle) ?vfs.FileHandle {
        if (handle.vtable != &handle_vtable) return null;
        const self: *SharedFile = @ptrCast(@alignCast(handle.ptr));
        self.refs += 1;
        return handle;
    }

    pub fn readableHandle(handle: vfs.FileHandle) bool {
        if (handle.vtable != &handle_vtable) return true;
        const self: *SharedFile = @ptrCast(@alignCast(handle.ptr));
        return self.readable;
    }

    pub fn writableHandle(handle: vfs.FileHandle) bool {
        if (handle.vtable != &handle_vtable) return true;
        const self: *SharedFile = @ptrCast(@alignCast(handle.ptr));
        return self.writable;
    }

    fn read(self: *SharedFile, buf: []u8) vfs.FsError!usize {
        if (!self.readable) return vfs.FsError.BadFileDescriptor;
        return self.inner.read(buf);
    }

    fn write(self: *SharedFile, buf: []const u8) vfs.FsError!usize {
        if (!self.writable) return vfs.FsError.BadFileDescriptor;
        return self.inner.write(buf);
    }

    fn seek(self: *SharedFile, pos: vfs.SeekFrom) vfs.FsError!u64 {
        return self.inner.seek(pos);
    }

    fn stat(self: *SharedFile) vfs.FsError!vfs.Metadata {
        return self.inner.stat();
    }

    fn truncate(self: *SharedFile, size: u64) vfs.FsError!void {
        if (!self.writable) return vfs.FsError.BadFileDescriptor;
        return self.inner.truncate(size);
    }

    fn close(self: *SharedFile) void {
        self.refs -|= 1;
        if (self.refs != 0) return;
        const gpa = self.gpa;
        self.inner.close();
        gpa.destroy(self);
    }

    const handle_vtable = vfs.FileHandle.VTable{
        .read = hRead,
        .write = hWrite,
        .seek = hSeek,
        .stat = hStat,
        .truncate = hTruncate,
        .close = hClose,
    };
    fn hRead(p: *anyopaque, buf: []u8) vfs.FsError!usize {
        return self_(p).read(buf);
    }
    fn hWrite(p: *anyopaque, buf: []const u8) vfs.FsError!usize {
        return self_(p).write(buf);
    }
    fn hSeek(p: *anyopaque, pos: vfs.SeekFrom) vfs.FsError!u64 {
        return self_(p).seek(pos);
    }
    fn hStat(p: *anyopaque) vfs.FsError!vfs.Metadata {
        return self_(p).stat();
    }
    fn hTruncate(p: *anyopaque, size: u64) vfs.FsError!void {
        return self_(p).truncate(size);
    }
    fn hClose(p: *anyopaque) void {
        self_(p).close();
    }
    fn self_(p: *anyopaque) *SharedFile {
        return @ptrCast(@alignCast(p));
    }
};

pub fn cloneFd(fd: Fd) ?Fd {
    return switch (fd) {
        .none => null,
        .file => |fh| if (SharedFile.retain(fh)) |retained| Fd{ .file = retained } else null,
        .pipe_read => |p| blk: {
            p.addReader();
            break :blk Fd{ .pipe_read = p };
        },
        .pipe_write => |p| blk: {
            p.addWriter();
            break :blk Fd{ .pipe_write = p };
        },
        .net => |src| Fd{ .net = src.retain() },
        .ws => |src| Fd{ .ws = src.retain() },
        .host_call => |src| Fd{ .host_call = src.retain() },
        .serve, .svc_serve, .svc_conn, .svc_call => null,
    };
}

pub fn releaseFdValue(fd: Fd) void {
    switch (fd) {
        .pipe_read => |p| p.closeRead(),
        .pipe_write => |p| p.closeWrite(),
        .file => |fh| fh.close(),
        .net => |src| src.release(),
        .ws => |src| src.release(),
        .host_call => |src| src.release(),
        .serve => |owner| owner.release(),
        .svc_serve => |owner| owner.release(),
        .svc_conn => |conn| conn.release(),
        .svc_call => |src| src.release(),
        .none => {},
    }
}

pub fn duplicateReadableFd(parent: *const Task, fd: i32) ?Fd {
    if (fd < 0) return null;
    if (fd < 3 and fd != 0) return null;
    const idx: usize = @intCast(fd);
    return switch (parent.getFd(idx)) {
        .none => if (fd == 0) Fd.none else null,
        .pipe_read => |p| blk: {
            p.addReader();
            break :blk Fd{ .pipe_read = p };
        },
        .file => |fh| blk: {
            // TODO(Phase 6, fd/file redirection): non-SharedFile handles need a
            // vfs-level retain/clone operation before they can be inherited.
            if (!SharedFile.readableHandle(fh)) break :blk null;
            const retained = SharedFile.retain(fh) orelse break :blk null;
            break :blk Fd{ .file = retained };
        },
        .net => |src| Fd{ .net = src.retain() },
        .pipe_write => null,
        .ws => null,
        .host_call => null,
        .serve => null,
        .svc_serve => null,
        .svc_conn => null,
        .svc_call => null,
    };
}

pub fn duplicateWritableFd(parent: *const Task, fd: i32) ?Fd {
    if (fd < 0) return null;
    if (fd < 3 and fd != 1 and fd != 2) return null;
    const idx: usize = @intCast(fd);
    return switch (parent.getFd(idx)) {
        .none => if (fd == 1 or fd == 2) Fd.none else null,
        .pipe_write => |p| blk: {
            p.addWriter();
            break :blk Fd{ .pipe_write = p };
        },
        .file => |fh| blk: {
            // TODO(Phase 6, fd/file redirection): non-SharedFile handles need a
            // vfs-level retain/clone operation before they can be inherited.
            if (!SharedFile.writableHandle(fh)) break :blk null;
            const retained = SharedFile.retain(fh) orelse break :blk null;
            break :blk Fd{ .file = retained };
        },
        .pipe_read => null,
        .net => null,
        .ws => null,
        .host_call => null,
        .serve => null,
        .svc_serve => null,
        .svc_conn => null,
        .svc_call => null,
    };
}

pub fn wrapFileHandle(gpa: std.mem.Allocator, inner: vfs.FileHandle, readable: bool, writable: bool) vfs.FileHandle {
    return SharedFile.wrap(gpa, inner, readable, writable);
}
