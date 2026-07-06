//! src/egress/net.zig — HTTP and WebSocket egress state machines (§2.8).
//!
//! Owns: capability checks, request IDs, polling, body reads, close semantics, and inflight accounting for HTTP + WebSocket.
//! Invariants: A9 (capability denials → errno, never host exceptions/traps), A8 (inflight requests are snapshot blockers surfaced via mc_inflight_egress). ASYNC: shallow Pending (§7.4).
//! Oracle (behavior to match): kernel/rust/src/net/mod.rs.
//! Not here: the /net VFS projection (fs/netfs.zig) — this file is the engine.
//!
//! Scaffold status: header-only. Fill Phase 6.

const std = @import("std");
const bridge = @import("../bridge.zig");
const constants = @import("constants_zig");

const HEAD_BUF: usize = 16 * 1024;
const WS_MSG_BUF: usize = 16 * 1024;

pub const StartError = error{Denied};

pub const HttpRead = union(enum) {
    pending,
    got: usize,
    eof,
    failed,
};

pub const StatusPoll = union(enum) {
    pending,
    ready: u16,
    failed,
};

pub const WsRead = union(enum) {
    pending,
    got: usize,
    eof,
};

pub const WsWrite = union(enum) {
    sent: usize,
    pending,
    message_too_big,
    closed,
};

const HttpPhase = enum {
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

    pub fn startHttp(self: *Engine, req: []const u8) StartError!*HttpSource {
        const src = self.gpa.create(HttpSource) catch @panic("OOM");
        const h = bridge.mc_http_request(req.ptr, req.len);
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

    pub fn connectWs(self: *Engine, url: []const u8) StartError!*WsSource {
        const src = self.gpa.create(WsSource) catch @panic("OOM");
        const h = bridge.mc_ws_connect(url.ptr, url.len);
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

pub const HttpSource = struct {
    engine: *Engine,
    handle: i32,
    refs: usize = 1,
    phase: HttpPhase = .polling,
    status: u16 = 0,

    pub fn retain(self: *HttpSource) *HttpSource {
        self.refs += 1;
        return self;
    }

    pub fn release(self: *HttpSource) void {
        self.refs -|= 1;
        if (self.refs != 0) return;
        const engine = self.engine;
        bridge.mc_http_request_close(self.handle);
        engine.dec();
        engine.gpa.destroy(self);
    }

    fn pollHead(self: *HttpSource) union(enum) { pending, head: []const u8, failed } {
        var buf: [HEAD_BUF]u8 = undefined;
        const n = bridge.mc_http_response_poll(self.handle, &buf, buf.len);
        if (n < 0) return .failed;
        if (n == 0) return .pending;
        const len: usize = @min(@as(usize, @intCast(n)), buf.len);
        self.status = parseHttpStatus(buf[0..len]);
        return .{ .head = buf[0..len] };
    }

    pub fn readInto(self: *HttpSource, out: []u8) HttpRead {
        while (true) {
            switch (self.phase) {
                .polling => switch (self.pollHead()) {
                    .pending => return .pending,
                    .head => self.phase = .body,
                    .failed => {
                        self.phase = .failed;
                        return .failed;
                    },
                },
                .body => {
                    const n = bridge.mc_http_response_body(self.handle, out.ptr, out.len);
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

    pub fn pollReadable(self: *HttpSource) bool {
        if (self.phase == .polling) {
            switch (self.pollHead()) {
                .pending => return false,
                .head => self.phase = .body,
                .failed => self.phase = .failed,
            }
        }
        return true;
    }

    pub fn driveStatus(self: *HttpSource) StatusPoll {
        if (self.phase == .polling) {
            switch (self.pollHead()) {
                .pending => return .pending,
                .head => self.phase = .body,
                .failed => {
                    self.phase = .failed;
                    return .failed;
                },
            }
        }
        if (self.phase == .failed) return .failed;
        return .{ .ready = self.status };
    }
};

pub const WsSource = struct {
    engine: *Engine,
    handle: i32,
    refs: usize = 1,
    pending: std.ArrayListUnmanaged(u8) = .empty,
    poff: usize = 0,
    failed: bool = false,

    pub fn retain(self: *WsSource) *WsSource {
        self.refs += 1;
        return self;
    }

    pub fn release(self: *WsSource) void {
        self.refs -|= 1;
        if (self.refs != 0) return;
        const engine = self.engine;
        bridge.mc_ws_close(self.handle);
        self.pending.deinit(engine.gpa);
        engine.dec();
        engine.gpa.destroy(self);
    }

    fn bufferMessage(self: *WsSource, bytes: []const u8) void {
        self.pending.clearRetainingCapacity();
        self.pending.appendSlice(self.engine.gpa, bytes) catch @panic("OOM");
        self.poff = 0;
    }

    fn fill(self: *WsSource) bool {
        if (self.poff < self.pending.items.len) return true;
        if (self.failed) return true;
        var tmp: [WS_MSG_BUF]u8 = undefined;
        const n = bridge.mc_ws_recv(self.handle, &tmp, tmp.len);
        if (n < 0) {
            self.failed = true;
            return true;
        }
        if (n == 0) return false;
        const len: usize = @min(@as(usize, @intCast(n)), tmp.len);
        self.bufferMessage(tmp[0..len]);
        return true;
    }

    pub fn readInto(self: *WsSource, out: []u8) WsRead {
        if (self.poff >= self.pending.items.len and !self.failed) {
            var tmp: [WS_MSG_BUF]u8 = undefined;
            const n = bridge.mc_ws_recv(self.handle, &tmp, tmp.len);
            if (n < 0) {
                self.failed = true;
                return .eof;
            }
            if (n == 0) return .pending;
            const len: usize = @min(@as(usize, @intCast(n)), tmp.len);
            self.bufferMessage(tmp[0..len]);
        }
        if (self.poff < self.pending.items.len) {
            const avail = self.pending.items.len - self.poff;
            const n = @min(avail, out.len);
            if (n != 0) @memcpy(out[0..n], self.pending.items[self.poff .. self.poff + n]);
            self.poff += n;
            return .{ .got = n };
        }
        return .eof;
    }

    pub fn send(self: *WsSource, data: []const u8) WsWrite {
        const n = bridge.mc_ws_send(self.handle, data.ptr, data.len);
        if (n == -constants.EMSGSIZE) return .message_too_big;
        if (n == -constants.EAGAIN) return .pending;
        if (n < 0) return .closed;
        return .{ .sent = @min(@as(usize, @intCast(n)), data.len) };
    }

    pub fn pollReadable(self: *WsSource) bool {
        return self.fill();
    }

    pub fn pollWritable(self: *WsSource) bool {
        return bridge.mc_ws_ready(self.handle) != 0;
    }

    pub fn pollHup(self: *WsSource) bool {
        return self.failed;
    }
};

fn parseHttpStatus(head: []const u8) u16 {
    var n: u16 = 0;
    var saw = false;
    for (head) |b| {
        if (b >= '0' and b <= '9') {
            n = n *| 10 +| @as(u16, b - '0');
            saw = true;
        } else {
            break;
        }
    }
    return if (saw) n else 0;
}
