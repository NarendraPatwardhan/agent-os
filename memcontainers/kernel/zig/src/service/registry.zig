//! src/service/registry.zig — the resident-service registry, sessions, and request/response lifecycle (§2.8).
//!
//! Owns: the registry of resident services, their sessions, and the request/response lifecycle behind /svc and mc_ctl_svc_call_*.
//! Invariants: A7 (deterministic activation/retry ordering), A8 (in-flight service requests + delegated handles are snapshot blockers). ASYNC: shallow Pending (§7.4).
//! Oracle (behavior to match): kernel/rust/src/fs/servicefs.rs + service activation in kernel/rust/src/init.rs.
//! Not here: the /svc VFS projection (fs/servicefs.zig); the control-call façade (control.zig). This file is the engine.

const std = @import("std");
const constants = @import("constants_zig");
const vfs = @import("../vfs.zig");
const pipe = @import("../ipc/pipe.zig");

pub const MAX_SVC_REQUEST_BYTES: usize = 1 << 20;
pub const MAX_SVC_RESPONSE_BYTES: usize = 1 << 20;
pub const SVC_RESPONSE_HIGH_WATER: usize = 64 * 1024;
pub const SVC_DRAIN_TIMEOUT_MS: i64 = 5_000;
pub const ACTIVATION_TIMEOUT_MS: i64 = 5_000;
pub const ACTIVATION_BACKOFF_BASE_MS: i64 = 1_000;
pub const ACTIVATION_BACKOFF_MAX_MS: i64 = 30_000;
pub const MAX_DELEGATED_HANDLES: usize = 8;
pub const SVC_ENVELOPE_HEADER: usize = 22;
pub const SVC_KIND_CALL: u8 = 0;
pub const SVC_KIND_SESSION_CLOSED: u8 = 1;
pub const SVC_KIND_DRAIN_READY: u8 = 2;

const ACTIVATION_BACKOFF_SHIFT_CAP: u5 = 5;

const Key = struct {
    session: u32,
    req_id: u32,
};

pub const DelegatedHandle = union(enum) {
    file: vfs.FileHandle,
    pipe_read: *pipe.Pipe,
    pipe_write: *pipe.Pipe,

    pub fn release(self: DelegatedHandle) void {
        switch (self) {
            .file => |fh| fh.close(),
            .pipe_read => |p| p.closeRead(),
            .pipe_write => |p| p.closeWrite(),
        }
    }
};

pub const ServiceRequest = struct {
    session: u32,
    req_id: u32,
    caller: vfs.CallerId,
    caller_caps: u32,
    blob: []u8,
    handles: []DelegatedHandle,

    pub fn deinit(self: *ServiceRequest, gpa: std.mem.Allocator, release_handles: bool) void {
        if (release_handles) {
            for (self.handles) |h| h.release();
        }
        gpa.free(self.handles);
        gpa.free(self.blob);
        self.* = undefined;
    }
};

pub const ServiceInbound = union(enum) {
    call: ServiceRequest,
    session_closed: u32,
};

const ServiceResponse = struct {
    status: i32 = 0,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    offset: usize = 0,
    complete: bool = false,
    drain_deadline: i64 = 0,

    fn buffered(self: *const ServiceResponse) usize {
        if (self.offset >= self.buf.items.len) return 0;
        return self.buf.items.len - self.offset;
    }

    fn deinit(self: *ServiceResponse, gpa: std.mem.Allocator) void {
        self.buf.deinit(gpa);
    }
};

const ResponseEntry = struct {
    key: Key,
    response: ServiceResponse,
};

const Session = struct {
    id: u32,
    caller: vfs.CallerId,
};

pub const ResponsePoll = union(enum) {
    pending,
    closed,
    got: usize,
    eof,
    failed: i32,
};

pub const RespondOutcome = enum {
    ok,
    session_gone,
    overflow,
};

pub const ServiceChannel = struct {
    gpa: std.mem.Allocator,
    refs: usize = 0,
    next_session: u32 = 1,
    next_req: u32 = 1,
    requests: std.ArrayListUnmanaged(ServiceInbound) = .empty,
    responses: std.ArrayListUnmanaged(ResponseEntry) = .empty,
    sessions: std.ArrayListUnmanaged(Session) = .empty,
    closed: bool = false,
    inflight: std.ArrayListUnmanaged(Key) = .empty,
    last_drain: ?Key = null,

    pub fn create(gpa: std.mem.Allocator) *ServiceChannel {
        const self = gpa.create(ServiceChannel) catch @panic("OOM");
        self.* = .{ .gpa = gpa };
        return self;
    }

    pub fn retain(self: *ServiceChannel) *ServiceChannel {
        self.refs += 1;
        return self;
    }

    pub fn release(self: *ServiceChannel) void {
        self.refs -|= 1;
        if (self.refs != 0) return;
        const gpa = self.gpa;
        self.deinit();
        gpa.destroy(self);
    }

    fn deinit(self: *ServiceChannel) void {
        for (self.requests.items) |*inbound| {
            switch (inbound.*) {
                .call => |*r| r.deinit(self.gpa, true),
                .session_closed => {},
            }
        }
        self.requests.deinit(self.gpa);
        for (self.responses.items) |*entry| entry.response.deinit(self.gpa);
        self.responses.deinit(self.gpa);
        self.sessions.deinit(self.gpa);
        self.inflight.deinit(self.gpa);
    }

    fn nextId(current: *u32) u32 {
        const id = current.*;
        current.* +%= 1;
        if (current.* == 0) current.* = 1;
        return id;
    }

    fn sessionIndex(self: *const ServiceChannel, session: u32) ?usize {
        for (self.sessions.items, 0..) |s, i| {
            if (s.id == session) return i;
        }
        return null;
    }

    fn hasSession(self: *const ServiceChannel, session: u32) bool {
        return self.sessionIndex(session) != null;
    }

    fn responseIndex(self: *const ServiceChannel, key: Key) ?usize {
        for (self.responses.items, 0..) |entry, i| {
            if (entry.key.session == key.session and entry.key.req_id == key.req_id) return i;
        }
        return null;
    }

    fn inflightIndex(self: *const ServiceChannel, key: Key) ?usize {
        for (self.inflight.items, 0..) |entry, i| {
            if (entry.session == key.session and entry.req_id == key.req_id) return i;
        }
        return null;
    }

    pub fn markDelivered(self: *ServiceChannel, session: u32, req_id: u32) void {
        const key = Key{ .session = session, .req_id = req_id };
        if (self.inflightIndex(key) == null) self.inflight.append(self.gpa, key) catch @panic("OOM");
    }

    pub fn markAnswered(self: *ServiceChannel, session: u32, req_id: u32) bool {
        const key = Key{ .session = session, .req_id = req_id };
        const i = self.inflightIndex(key) orelse return false;
        _ = self.inflight.orderedRemove(i);
        return true;
    }

    pub fn isInflight(self: *const ServiceChannel, session: u32, req_id: u32) bool {
        return self.inflightIndex(.{ .session = session, .req_id = req_id }) != null;
    }

    pub fn openSession(self: *ServiceChannel, caller: vfs.CallerId) u32 {
        const id = nextId(&self.next_session);
        self.sessions.append(self.gpa, .{ .id = id, .caller = caller }) catch @panic("OOM");
        return id;
    }

    pub fn dropSession(self: *ServiceChannel, session: u32) void {
        const sidx = self.sessionIndex(session) orelse return;
        _ = self.sessions.orderedRemove(sidx);

        var r: usize = 0;
        while (r < self.responses.items.len) {
            if (self.responses.items[r].key.session == session) {
                var entry = self.responses.orderedRemove(r);
                entry.response.deinit(self.gpa);
            } else {
                r += 1;
            }
        }

        var q: usize = 0;
        while (q < self.requests.items.len) {
            switch (self.requests.items[q]) {
                .call => |req| {
                    if (req.session == session) {
                        var inbound = self.requests.orderedRemove(q);
                        inbound.call.deinit(self.gpa, true);
                        continue;
                    }
                },
                .session_closed => {},
            }
            q += 1;
        }

        if (!self.closed) {
            self.requests.append(self.gpa, .{ .session_closed = session }) catch @panic("OOM");
        }
    }

    pub fn evictDeadSessions(
        self: *ServiceChannel,
        ctx: *anyopaque,
        alive: *const fn (*anyopaque, vfs.CallerId) bool,
    ) void {
        var dead: std.ArrayListUnmanaged(u32) = .empty;
        defer dead.deinit(self.gpa);
        for (self.sessions.items) |s| {
            if (!alive(ctx, s.caller)) dead.append(self.gpa, s.id) catch @panic("OOM");
        }
        for (dead.items) |id| self.dropSession(id);
    }

    pub fn enqueue(
        self: *ServiceChannel,
        session: u32,
        caller: vfs.CallerId,
        caller_caps: u32,
        blob: []const u8,
        handles: []DelegatedHandle,
    ) ?u32 {
        if (!self.hasSession(session) or self.closed) return null;
        const id = nextId(&self.next_req);
        const owned_blob = self.gpa.dupe(u8, blob) catch @panic("OOM");
        const owned_handles = self.gpa.dupe(DelegatedHandle, handles) catch @panic("OOM");
        self.requests.append(self.gpa, .{ .call = .{
            .session = session,
            .req_id = id,
            .caller = caller,
            .caller_caps = caller_caps,
            .blob = owned_blob,
            .handles = owned_handles,
        } }) catch @panic("OOM");
        return id;
    }

    pub fn drainResponse(self: *ServiceChannel, session: u32, req_id: u32, out: []u8) ResponsePoll {
        const key = Key{ .session = session, .req_id = req_id };
        if (self.responseIndex(key)) |idx| {
            var resp = &self.responses.items[idx].response;
            if (resp.status != 0) {
                const status = resp.status;
                var entry = self.responses.orderedRemove(idx);
                entry.response.deinit(self.gpa);
                return .{ .failed = status };
            }
            const buffered = resp.buffered();
            if (buffered != 0) {
                const n = @min(buffered, out.len);
                if (n != 0) @memcpy(out[0..n], resp.buf.items[resp.offset .. resp.offset + n]);
                resp.offset += n;
                resp.drain_deadline = vfs.wallNowMs() + SVC_DRAIN_TIMEOUT_MS;
                if (resp.offset == resp.buf.items.len) {
                    resp.buf.clearRetainingCapacity();
                    resp.offset = 0;
                } else if (resp.offset > 4096 and resp.offset * 2 >= resp.buf.items.len) {
                    const remaining = resp.buf.items.len - resp.offset;
                    std.mem.copyForwards(u8, resp.buf.items[0..remaining], resp.buf.items[resp.offset..]);
                    resp.buf.items.len = remaining;
                    resp.offset = 0;
                }
                return .{ .got = n };
            }
            if (resp.complete) {
                var entry = self.responses.orderedRemove(idx);
                entry.response.deinit(self.gpa);
                return .eof;
            }
            if (self.closed) {
                var entry = self.responses.orderedRemove(idx);
                entry.response.deinit(self.gpa);
                return .{ .failed = constants.EIO };
            }
            return .pending;
        }
        if (self.closed or !self.hasSession(session)) return .closed;
        return .pending;
    }

    pub fn responseReady(self: *const ServiceChannel, session: u32, req_id: u32) bool {
        if (self.closed or !self.hasSession(session)) return true;
        if (self.responseIndex(.{ .session = session, .req_id = req_id })) |idx| {
            const resp = &self.responses.items[idx].response;
            return resp.buffered() != 0 or resp.complete or resp.status != 0;
        }
        return false;
    }

    pub fn takeRequest(self: *ServiceChannel) ?ServiceInbound {
        if (self.requests.items.len == 0) return null;
        return self.requests.orderedRemove(0);
    }

    pub fn respond(self: *ServiceChannel, session: u32, req_id: u32, status: i32, data: []const u8, last: bool) RespondOutcome {
        if (!self.hasSession(session)) return .session_gone;
        const key = Key{ .session = session, .req_id = req_id };
        const idx = self.responseIndex(key) orelse blk: {
            self.responses.append(self.gpa, .{
                .key = key,
                .response = .{ .drain_deadline = vfs.wallNowMs() + SVC_DRAIN_TIMEOUT_MS },
            }) catch @panic("OOM");
            break :blk self.responses.items.len - 1;
        };
        const resp = &self.responses.items[idx].response;
        if (status != 0) resp.status = status;
        resp.buf.appendSlice(self.gpa, data) catch @panic("OOM");
        if (last) resp.complete = true;
        if (resp.buffered() > MAX_SVC_RESPONSE_BYTES) {
            resp.buf.clearRetainingCapacity();
            resp.offset = 0;
            resp.status = constants.EMSGSIZE;
            resp.complete = true;
            return .overflow;
        }
        return .ok;
    }

    pub fn responseBuffered(self: *const ServiceChannel, session: u32, req_id: u32) usize {
        if (self.responseIndex(.{ .session = session, .req_id = req_id })) |idx| {
            return self.responses.items[idx].response.buffered();
        }
        return 0;
    }

    pub fn failResponse(self: *ServiceChannel, session: u32, req_id: u32, errno: i32) void {
        if (self.responseIndex(.{ .session = session, .req_id = req_id })) |idx| {
            const resp = &self.responses.items[idx].response;
            resp.buf.clearRetainingCapacity();
            resp.offset = 0;
            resp.status = errno;
            resp.complete = true;
        }
    }

    fn keyLess(a: Key, b: Key) bool {
        return a.session < b.session or (a.session == b.session and a.req_id < b.req_id);
    }

    pub fn nextDrainReady(self: *ServiceChannel) ?Key {
        var min: ?Key = null;
        var after: ?Key = null;
        for (self.responses.items) |*entry| {
            const resp = &entry.response;
            if (resp.complete or resp.status != 0 or resp.buffered() >= SVC_RESPONSE_HIGH_WATER) continue;
            if (min == null or keyLess(entry.key, min.?)) min = entry.key;
            if (self.last_drain == null or keyLess(self.last_drain.?, entry.key)) {
                if (after == null or keyLess(entry.key, after.?)) after = entry.key;
            }
        }
        const next = after orelse min;
        self.last_drain = next;
        return next;
    }

    pub fn recvReady(self: *const ServiceChannel) bool {
        if (self.closed or self.requests.items.len != 0) return true;
        for (self.responses.items) |*entry| {
            const resp = &entry.response;
            if (!resp.complete and resp.status == 0 and resp.buffered() < SVC_RESPONSE_HIGH_WATER) return true;
        }
        return false;
    }

    pub fn failOverdue(self: *ServiceChannel) void {
        const now = vfs.wallNowMs();
        var i: usize = 0;
        while (i < self.responses.items.len) : (i += 1) {
            const entry = &self.responses.items[i];
            const resp = &entry.response;
            if (!resp.complete and resp.status == 0 and now > resp.drain_deadline) {
                self.failResponse(entry.key.session, entry.key.req_id, constants.ETIMEDOUT);
                _ = self.markAnswered(entry.key.session, entry.key.req_id);
            }
        }
    }

    pub fn close(self: *ServiceChannel) void {
        self.closed = true;
    }
};

pub fn validServiceName(name: []const u8) bool {
    if (name.len == 0 or name.len > 31) return false;
    if (name[0] < 'a' or name[0] > 'z') return false;
    for (name) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-')) return false;
    }
    return true;
}

pub const ServiceState = union(enum) {
    activating: struct {
        pid: u32,
        deadline_ms: i64,
        attempts: u32,
    },
    failed: struct {
        until_ms: i64,
        last_errno: i32,
        attempts: u32,
    },

    pub fn attempts(self: ServiceState) u32 {
        return switch (self) {
            .activating => |s| s.attempts,
            .failed => |s| s.attempts,
        };
    }
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    registry: std.StringHashMapUnmanaged(*ServiceChannel) = .{},
    activation: std.StringHashMapUnmanaged(ServiceState) = .{},

    pub fn init(gpa: std.mem.Allocator) Engine {
        return .{ .gpa = gpa };
    }

    pub fn registerService(self: *Engine, name: []const u8, channel: *ServiceChannel) bool {
        if (self.registry.contains(name)) return false;
        const owned = self.gpa.dupe(u8, name) catch @panic("OOM");
        self.registry.put(self.gpa, owned, channel) catch @panic("OOM");
        return true;
    }

    pub fn lookupService(self: *Engine, name: []const u8) ?*ServiceChannel {
        return self.registry.get(name);
    }

    pub fn deregisterService(self: *Engine, name: []const u8) void {
        if (self.registry.fetchRemove(name)) |kv| self.gpa.free(kv.key);
    }

    pub fn serviceRegistered(self: *Engine, name: []const u8) bool {
        return self.registry.contains(name);
    }

    fn putActivation(self: *Engine, name: []const u8, value: ServiceState) void {
        if (self.activation.getPtr(name)) |slot| {
            slot.* = value;
            return;
        }
        const owned = self.gpa.dupe(u8, name) catch @panic("OOM");
        self.activation.put(self.gpa, owned, value) catch @panic("OOM");
    }

    pub fn markActivating(self: *Engine, name: []const u8, pid: u32, deadline_ms: i64) void {
        const attempts = if (self.activation.get(name)) |s| s.attempts() + 1 else 1;
        self.putActivation(name, .{ .activating = .{ .pid = pid, .deadline_ms = deadline_ms, .attempts = attempts } });
    }

    fn backoffMs(attempts: u32) i64 {
        const shift: u5 = @intCast(@min(attempts -| 1, ACTIVATION_BACKOFF_SHIFT_CAP));
        return @min(ACTIVATION_BACKOFF_BASE_MS << shift, ACTIVATION_BACKOFF_MAX_MS);
    }

    pub fn markFailed(self: *Engine, name: []const u8, errno: i32) void {
        const attempts = if (self.activation.get(name)) |s| s.attempts() else 1;
        self.putActivation(name, .{ .failed = .{
            .until_ms = vfs.wallNowMs() + backoffMs(attempts),
            .last_errno = errno,
            .attempts = attempts,
        } });
    }

    pub fn grantHolder(self: *Engine, name: []const u8) ?u32 {
        return switch (self.activation.get(name) orelse return null) {
            .activating => |s| s.pid,
            .failed => null,
        };
    }

    pub fn serviceState(self: *Engine, name: []const u8) ?ServiceState {
        return self.activation.get(name);
    }

    pub fn clearActivation(self: *Engine, name: []const u8) void {
        if (self.activation.fetchRemove(name)) |kv| self.gpa.free(kv.key);
    }

    fn appendUniqueName(arena: std.mem.Allocator, out: *std.ArrayList([]const u8), name: []const u8) void {
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        out.append(arena, arena.dupe(u8, name) catch @panic("OOM")) catch @panic("OOM");
    }

    fn lessName(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    pub fn knownServiceNames(self: *Engine, arena: std.mem.Allocator, out: *std.ArrayList([]const u8)) void {
        var rit = self.registry.keyIterator();
        while (rit.next()) |name| appendUniqueName(arena, out, name.*);
        var ait = self.activation.keyIterator();
        while (ait.next()) |name| appendUniqueName(arena, out, name.*);
        std.mem.sort([]const u8, out.items, {}, lessName);
    }

    pub fn serviceStatusLine(self: *Engine, allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
        if (self.serviceRegistered(name)) return allocator.dupe(u8, "ready\n") catch @panic("OOM");
        const s = self.activation.get(name) orelse return null;
        return switch (s) {
            .activating => allocator.dupe(u8, "activating\n") catch @panic("OOM"),
            .failed => |f| blk: {
                const why = switch (f.last_errno) {
                    constants.ETIMEDOUT => "timed out before serving",
                    constants.EIO => "crashed before serving",
                    else => "activation failed",
                };
                break :blk std.fmt.allocPrint(allocator, "failed: {s}\n", .{why}) catch @panic("OOM");
            },
        };
    }

    pub fn svcInflight(self: *Engine) i32 {
        var total: i32 = 0;
        var it = self.registry.valueIterator();
        while (it.next()) |ch| total += @intCast(ch.*.inflight.items.len);
        return total;
    }
};

pub const SvcServeOwner = struct {
    gpa: std.mem.Allocator,
    engine: *Engine,
    name: []u8,
    channel: *ServiceChannel,

    pub fn create(gpa: std.mem.Allocator, engine: *Engine, name: []const u8, channel: *ServiceChannel) *SvcServeOwner {
        const self = gpa.create(SvcServeOwner) catch @panic("OOM");
        self.* = .{
            .gpa = gpa,
            .engine = engine,
            .name = gpa.dupe(u8, name) catch @panic("OOM"),
            .channel = channel.retain(),
        };
        return self;
    }

    pub fn release(self: *SvcServeOwner) void {
        self.channel.close();
        self.engine.deregisterService(self.name);
        self.channel.release();
        const gpa = self.gpa;
        gpa.free(self.name);
        gpa.destroy(self);
    }
};

pub const SvcConnHandle = struct {
    gpa: std.mem.Allocator,
    channel: *ServiceChannel,
    session: u32,

    pub fn create(gpa: std.mem.Allocator, channel: *ServiceChannel, session: u32) *SvcConnHandle {
        const self = gpa.create(SvcConnHandle) catch @panic("OOM");
        self.* = .{ .gpa = gpa, .channel = channel.retain(), .session = session };
        return self;
    }

    pub fn release(self: *SvcConnHandle) void {
        self.channel.dropSession(self.session);
        self.channel.release();
        self.gpa.destroy(self);
    }
};

const SvcPhase = union(enum) {
    active,
    done,
    closed,
    failed: i32,
};

pub const SvcRead = union(enum) {
    pending,
    got: usize,
    eof,
    closed,
    failed: i32,
};

pub const SvcCallSource = struct {
    gpa: std.mem.Allocator,
    channel: *ServiceChannel,
    session: u32,
    req_id: u32,
    phase: SvcPhase = .active,

    pub fn create(gpa: std.mem.Allocator, channel: *ServiceChannel, session: u32, req_id: u32) *SvcCallSource {
        const self = gpa.create(SvcCallSource) catch @panic("OOM");
        self.* = .{ .gpa = gpa, .channel = channel.retain(), .session = session, .req_id = req_id };
        return self;
    }

    pub fn release(self: *SvcCallSource) void {
        self.channel.release();
        self.gpa.destroy(self);
    }

    pub fn readInto(self: *SvcCallSource, buf: []u8) SvcRead {
        switch (self.phase) {
            .done => return .eof,
            .closed => return .closed,
            .failed => |errno| return .{ .failed = errno },
            .active => {},
        }
        return switch (self.channel.drainResponse(self.session, self.req_id, buf)) {
            .pending => .pending,
            .got => |n| .{ .got = n },
            .eof => blk: {
                self.phase = .done;
                break :blk .eof;
            },
            .closed => blk: {
                self.phase = .closed;
                break :blk .closed;
            },
            .failed => |errno| blk: {
                self.phase = .{ .failed = errno };
                break :blk .{ .failed = errno };
            },
        };
    }

    pub fn pollReadable(self: *const SvcCallSource) bool {
        return switch (self.phase) {
            .active => self.channel.responseReady(self.session, self.req_id),
            else => true,
        };
    }
};
