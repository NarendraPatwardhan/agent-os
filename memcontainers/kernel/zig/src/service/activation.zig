//! service/activation.zig — resident-service manifest lookup and activation.
//!
//! Owns: service declarations, JSON service specs, lazy/eager activation, and
//!   activation-state polling for channel consumers.
//! Invariants: service names are validated before lookup/spawn; activation state stays
//!   rooted in `Kernel.services`; spawned service modules must declare the requested name.
//! Consumes: root-namespace reads, scheduler spawning, guest creation, service registry
//!   activation state, and wall-clock deadlines.
//! Not here: service request/response queues, `/svc` projection, or control/syscall wire
//!   codecs.

const std = @import("std");
const state = @import("../state.zig");
const sections = @import("../wasm_sections.zig");
const guest = @import("../guest.zig");
const task = @import("../task.zig");
const vfs = @import("../vfs.zig");
const registry = @import("registry.zig");
const constants = @import("constants_zig");

fn declaredService(bytes: []const u8) ?[]const u8 {
    const payload = sections.uniqueCustom(bytes, "mc_service") orelse return null;
    if (!std.unicode.utf8ValidateSlice(payload)) return null;
    if (!registry.validServiceName(payload)) return null;
    return payload;
}

const ServiceSpec = struct {
    binary: []u8,
    eager: bool,
};

fn lookupServiceSpec(k: *state.Kernel, name: []const u8) ?ServiceSpec {
    if (!registry.validServiceName(name)) return null;
    const path = std.fmt.allocPrint(k.gpa, "/etc/services.d/{s}.json", .{name}) catch @panic("OOM");
    defer k.gpa.free(path);
    const bytes = state.readFileAlloc(k, path) orelse return null;
    defer k.gpa.free(bytes);
    if (!std.unicode.utf8ValidateSlice(bytes)) return null;

    // Parse with std.json (as fs/toolsfs.zig does) rather than a hand-rolled scanner that matched a
    // key even inside a string value and rejected any escaped string. `binary` defaults to /bin/<name>,
    // `eager` to false; both are duped onto k.gpa so they outlive the parse arena.
    var arena_state = std.heap.ArenaAllocator.init(k.gpa);
    defer arena_state.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena_state.allocator(), bytes, .{}) catch return null;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const binary = blk: {
        if (obj.get("binary")) |v| switch (v) {
            .string => |s| break :blk k.gpa.dupe(u8, s) catch @panic("OOM"),
            else => {},
        };
        break :blk std.fmt.allocPrint(k.gpa, "/bin/{s}", .{name}) catch @panic("OOM");
    };
    const eager = if (obj.get("eager")) |v| switch (v) {
        .bool => |b| b,
        else => false,
    } else false;
    return .{ .binary = binary, .eager = eager };
}

fn spawnService(k: *state.Kernel, name: []const u8, binary: []const u8) bool {
    if (binary.len == 0 or binary[0] != '/') return false;
    const bytes = state.readFileAlloc(k, binary) orelse return false;
    defer k.gpa.free(bytes);
    const service = declaredService(bytes) orelse return false;
    if (!std.mem.eql(u8, service, name)) return false;
    const tier = task.Tier.fromModule(bytes) orelse return false;
    const args = [_][]const u8{constants.SERVICE_MARKER};
    const pid = k.sched.spawn(null, name, binary, &args, "/");
    const root: ?[]const u8 = if (tier.confines()) "/" else null;
    k.sched.setTaskPolicy(pid, tier.caps(), root);
    if (!guest.createChildGuest(pid, bytes, "/")) {
        k.sched.exitTask(pid, 126);
        k.sched.dropDeadPipes();
        return false;
    }
    k.services.markActivating(name, pid, vfs.wallNowMs() + registry.ACTIVATION_TIMEOUT_MS);
    return true;
}

pub const ServicePoll = union(enum) {
    ready: *registry.ServiceChannel,
    pending,
    errno: i32,
};

/// Resolve a service by name into its channel, driving lazy activation: `ready` = connected;
/// `pending` = activating, retry next tick; `errno` = timed-out / failed (within backoff) / absent.
/// Shared by the control-channel svc-call path and the guest svc_connect syscall.
pub fn serviceChannel(k: *state.Kernel, name: []const u8) ServicePoll {
    if (k.services.lookupService(name)) |channel| return .{ .ready = channel };
    if (k.services.serviceState(name)) |s| {
        switch (s) {
            .activating => |a| {
                const alive = if (k.sched.getTask(a.pid)) |t| t.state != .zombie else false;
                if (alive) {
                    if (vfs.wallNowMs() > a.deadline_ms) {
                        k.sched.killTask(a.pid, 124);
                        k.services.markFailed(name, constants.ETIMEDOUT);
                        return .{ .errno = constants.ETIMEDOUT };
                    }
                    return .pending;
                }
                k.services.markFailed(name, constants.EIO);
                return .{ .errno = constants.EIO };
            },
            .failed => |f| {
                if (vfs.wallNowMs() < f.until_ms) return .{ .errno = f.last_errno };
            },
        }
    }
    if (activateServiceLazily(k, name)) return .pending;
    return .{ .errno = constants.ENOENT };
}

pub fn activateServiceLazily(k: *state.Kernel, name: []const u8) bool {
    const spec = lookupServiceSpec(k, name) orelse return false;
    defer k.gpa.free(spec.binary);
    return spawnService(k, name, spec.binary);
}

pub fn activateEagerServices(k: *state.Kernel) void {
    var arena_state = std.heap.ArenaAllocator.init(k.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const names = state.readDirNames(k, arena, "/etc/services.d") orelse return;
    for (names) |file| {
        if (!std.mem.endsWith(u8, file, ".json")) continue;
        const name = file[0 .. file.len - ".json".len];
        if (!registry.validServiceName(name)) continue;
        const spec = lookupServiceSpec(k, name) orelse continue;
        defer k.gpa.free(spec.binary);
        if (spec.eager) _ = spawnService(k, name, spec.binary);
    }
}
