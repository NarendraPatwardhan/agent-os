//! src/egress/host_call.zig — opaque host-call operations (§2.8).
//!
//! Owns: the request/poll/complete lifecycle for opaque host calls and their inflight accounting.
//! Invariants: A9, A8 (inflight host calls block snapshots). ASYNC: shallow Pending (§7.4).
//! Oracle (behavior to match): kernel/rust/src/host_call.rs.
//! Not here: the mountfs VFS face (fs/mountfs.zig).
//!
//! Scaffold status: header-only. Fill Phase 6.

const std = @import("std");
const bridge = @import("../bridge.zig");

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

    pub fn start(self: *Engine, req: []const u8) StartError!*Source {
        const src = self.gpa.create(Source) catch @panic("OOM");
        const h = bridge.mc_host_call(req.ptr, req.len);
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
        bridge.mc_host_call_close(self.handle);
        engine.dec();
        engine.gpa.destroy(self);
    }

    fn poll(self: *Source) enum { pending, ready, failed } {
        var unused: [1]u8 = undefined;
        const n = bridge.mc_host_call_poll(self.handle, &unused, 0);
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
                    const n = bridge.mc_host_call_body(self.handle, out.ptr, out.len);
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
