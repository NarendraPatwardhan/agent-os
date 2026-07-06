//! src/egress/persist.zig — the persistence commit state machine (§2.8).
//!
//! Owns: async commit lifecycle, pending-commit accounting, and snapshot blockers.
//! Invariants: A8 (pending commits surfaced via mc_pending_commits and block snapshots). ASYNC: shallow Pending (§7.4).
//! Oracle (behavior to match): kernel/rust/src/persist/mod.rs.
//! Not here: the /var/persist VFS face (fs/persistfs.zig).
//!
//! Scaffold status: header-only. Fill Phase 6.

const std = @import("std");
const bridge = @import("../bridge.zig");
const constants = @import("constants_zig");

pub const StartError = error{Denied};

pub const Read = union(enum) {
    pending,
    got: usize,
    eof,
    failed,
};

const Phase = enum {
    polling,
    body,
    eof,
    failed,
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    inflight_count: i32 = 0,

    pub fn init(gpa: std.mem.Allocator) Engine {
        return .{ .gpa = gpa };
    }

    pub fn inflight(self: *const Engine) i32 {
        return self.inflight_count;
    }

    fn inc(self: *Engine) void {
        self.inflight_count += 1;
    }

    fn dec(self: *Engine) void {
        if (self.inflight_count > 0) self.inflight_count -= 1;
    }

    pub fn start(self: *Engine, op: u32, key: []const u8, value: []const u8) StartError!*Source {
        var req: std.ArrayList(u8) = .empty;
        defer req.deinit(self.gpa);
        appendU32(&req, self.gpa, op);
        appendU32(&req, self.gpa, @intCast(key.len));
        req.appendSlice(self.gpa, key) catch @panic("OOM");
        req.appendSlice(self.gpa, value) catch @panic("OOM");

        const src = self.gpa.create(Source) catch @panic("OOM");
        const h = bridge.mc_persist_start(req.items.ptr, req.items.len);
        if (h < 0) {
            self.gpa.destroy(src);
            return StartError.Denied;
        }
        self.inc();
        src.* = .{
            .engine = self,
            .handle = h,
        };
        return src;
    }
};

pub const Source = struct {
    engine: *Engine,
    handle: i32,
    refs: usize = 1,
    phase: Phase = .polling,

    pub fn retain(self: *Source) *Source {
        self.refs += 1;
        return self;
    }

    pub fn release(self: *Source) void {
        self.refs -|= 1;
        if (self.refs != 0) return;
        const engine = self.engine;
        bridge.mc_persist_close(self.handle);
        engine.dec();
        engine.gpa.destroy(self);
    }

    fn poll(self: *Source) enum { pending, ready, failed } {
        const n = bridge.mc_persist_poll(self.handle);
        if (n < 0) return .failed;
        if (n == 0) return .pending;
        return .ready;
    }

    pub fn readInto(self: *Source, out: []u8) Read {
        while (true) {
            switch (self.phase) {
                .polling => switch (self.poll()) {
                    .pending => return .pending,
                    .ready => self.phase = .body,
                    .failed => {
                        self.phase = .failed;
                        return .failed;
                    },
                },
                .body => {
                    const n = bridge.mc_persist_body(self.handle, out.ptr, out.len);
                    if (n < 0) {
                        self.phase = .failed;
                        return .failed;
                    }
                    const len: usize = @min(@as(usize, @intCast(n)), out.len);
                    if (len == 0) {
                        self.phase = .eof;
                        return .eof;
                    }
                    return .{ .got = len };
                },
                .eof => return .eof,
                .failed => return .failed,
            }
        }
    }

    pub fn pollReadable(self: *Source) bool {
        if (self.phase == .polling) {
            switch (self.poll()) {
                .pending => return false,
                .ready => self.phase = .body,
                .failed => self.phase = .failed,
            }
        }
        return true;
    }
};

fn appendU32(out: *std.ArrayList(u8), a: std.mem.Allocator, value: u32) void {
    out.append(a, @truncate(value)) catch @panic("OOM");
    out.append(a, @truncate(value >> 8)) catch @panic("OOM");
    out.append(a, @truncate(value >> 16)) catch @panic("OOM");
    out.append(a, @truncate(value >> 24)) catch @panic("OOM");
}

pub const OP_GET = constants.PERSIST_OP_GET;
pub const OP_PUT = constants.PERSIST_OP_PUT;
pub const OP_DELETE = constants.PERSIST_OP_DELETE;
pub const OP_LIST = constants.PERSIST_OP_LIST;
