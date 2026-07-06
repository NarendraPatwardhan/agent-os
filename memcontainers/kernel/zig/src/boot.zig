//! boot.zig — base-image load and namespace construction (ZIG_KERNEL §2.2, §4.1).
//!
//! Owns: `mc_load_base_image` via the bridge, MCLS layer parsing, mounting a writable COW
//!   view over the read-only base (or falling back to memfs), and mounting /dev + /tmp +
//!   the boot directory skeleton. Oracle: kernel/rust/src/init.rs::boot_system.
//! Invariants: boot runs to completion and NEVER suspends — off the Asyncify path (§7.4);
//!   a failed base image degrades to an empty root, never traps the host (§2.2).
//! Not here: mount resolution / path policy (vfs.zig); backend bytes (fs/*). Boot
//!   orchestrates. The persistfs mount, /etc/profile sourcing, and the login shell land
//!   with the scheduler/shell (Phase 4) and the egress/persist tier (Phase 6).

const std = @import("std");
const vfs = @import("vfs.zig");
const bridge = @import("bridge.zig");
const state = @import("state.zig");
const MemFs = @import("fs/memfs.zig").MemFs;
const TarFs = @import("fs/tarfs.zig").TarFs;
const CowFs = @import("fs/cowfs.zig").CowFs;
const OverlayFs = @import("fs/overlayfs.zig").OverlayFs;
const DevFs = @import("fs/devfs.zig").DevFs;
const ServiceFs = @import("fs/servicefs.zig").ServiceFs;
const ProcFs = @import("fs/procfs.zig").ProcFs;
const EnvFs = @import("fs/envfs.zig").EnvFs;
const NetFs = @import("fs/netfs.zig").NetFs;
const ToolsFs = @import("fs/toolsfs.zig").ToolsFs;
const PersistFs = @import("fs/persistfs.zig").PersistFs;

fn say(msg: []const u8) void {
    bridge.mc_stdout_write(msg.ptr, msg.len);
}

pub fn bootSystem(k: *state.Kernel) void {
    const gpa = k.gpa;
    const ns = &k.ns;
    say("Booting ...\r\n");

    var mounted_root = false;
    if (loadBaseImage(gpa)) |payload| {
        if (parseLayers(gpa, payload)) |layers| {
            if (layers.len == 1) {
                const owned = gpa.dupe(u8, layers[0]) catch @panic("OOM");
                if (TarFs.create(gpa, owned)) |tar| {
                    const cow = CowFs.create(gpa, tar.fileSystem());
                    ns.mountLabeled("/", cow.fileSystem(), "cowfs", false);
                    mounted_root = true;
                    say("Loading image... ok\r\n");
                } else {
                    gpa.free(owned);
                }
            } else {
                var tar_layers: std.ArrayList(*TarFs) = .empty;
                for (layers) |layer| {
                    const owned = gpa.dupe(u8, layer) catch @panic("OOM");
                    if (TarFs.create(gpa, owned)) |tar| {
                        tar_layers.append(gpa, tar) catch @panic("OOM");
                    } else {
                        gpa.free(owned);
                    }
                }
                if (tar_layers.items.len != 0) {
                    const overlay = OverlayFs.create(gpa, tar_layers.items);
                    const cow = CowFs.create(gpa, overlay.fileSystem());
                    ns.mountLabeled("/", cow.fileSystem(), "cowfs", false);
                    mounted_root = true;
                    say("Loading image... ok\r\n");
                }
            }
        }
    }
    if (!mounted_root) {
        say("No/invalid base image, using empty root\r\n");
        ns.mountLabeled("/", MemFs.create(gpa).fileSystem(), "memfs", false);
    }

    say("Mounting /dev... ok\r\n");
    ns.mountLabeled("/dev", DevFs.create(gpa).fileSystem(), "devfs", false);

    // Boot-time directory skeleton + the writable tmpfs, mounted like the oracle.
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    ns.mkdir(a, vfs.SYSTEM_CALLER, "/home") catch {};
    ns.mkdir(a, vfs.SYSTEM_CALLER, "/home/user") catch {};
    ns.mkdir(a, vfs.SYSTEM_CALLER, "/tmp") catch {};
    say("Mounting /tmp (tmpfs)... ok\r\n");
    ns.mountLabeled("/tmp", MemFs.create(gpa).fileSystem(), "tmpfs", false);
    ns.mkdir(a, vfs.SYSTEM_CALLER, "/var") catch {};
    ns.mkdir(a, vfs.SYSTEM_CALLER, "/var/persist") catch {};
    say("Mounting /var/persist (persistfs)... ok\r\n");
    ns.mountLabeled("/var/persist", PersistFs.create(gpa, &k.persist, &k.persist_channels).fileSystem(), "persistfs", false);
    ns.mkdir(a, vfs.SYSTEM_CALLER, "/proc") catch {};
    say("Mounting /proc... ok\r\n");
    ns.mountLabeled("/proc", ProcFs.create(gpa, &k.sched, &k.ns).fileSystem(), "procfs", false);
    ns.mkdir(a, vfs.SYSTEM_CALLER, "/env") catch {};
    say("Mounting /env... ok\r\n");
    ns.mountLabeled("/env", EnvFs.create(gpa, &k.sched, &k.boot_env).fileSystem(), "envfs", false);
    ns.mkdir(a, vfs.SYSTEM_CALLER, "/net") catch {};
    say("Mounting /net... ok\r\n");
    ns.mountLabeled("/net", NetFs.create(gpa, &k.sched, &k.net).fileSystem(), "netfs", false);
    ns.mkdir(a, vfs.SYSTEM_CALLER, "/svc") catch {};
    say("Mounting /svc... ok\r\n");
    ns.mountLabeled("/svc", ServiceFs.create(gpa).fileSystem(), "servicefs", false);
    ns.mkdir(a, vfs.SYSTEM_CALLER, "/tools") catch {};
    say("Mounting /tools... ok\r\n");
    ns.mountLabeled("/tools", ToolsFs.create(gpa, &k.ns).fileSystem(), "toolsfs", true);
    say("\r\n");
}

/// Load the host base image into an exactly-sized buffer. Probe the length with a 0-length
/// read, then read the whole image. Returns null when no image was provided.
fn loadBaseImage(gpa: std.mem.Allocator) ?[]u8 {
    var probe: [1]u8 = undefined;
    const size = bridge.mc_load_base_image(&probe, 0);
    if (size < 0) return null;
    const sz: usize = @intCast(size);
    if (sz == 0) return null;
    const buffer = gpa.alloc(u8, sz) catch @panic("OOM");
    const read = bridge.mc_load_base_image(buffer.ptr, buffer.len);
    if (read < 0) {
        gpa.free(buffer);
        return null;
    }
    const got: usize = @min(@as(usize, @intCast(read)), sz);
    return buffer[0..got];
}

/// The host payload is either a bare `.tar` (one layer) or an `MCLS` layer stack.
/// Oracle: init.rs::parse_layers.
fn parseLayers(gpa: std.mem.Allocator, buf: []const u8) ?[]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (buf.len >= 8 and std.mem.eql(u8, buf[0..4], "MCLS")) {
        const count = std.mem.readInt(u32, buf[4..8], .little);
        var off: usize = 8;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (off + 4 > buf.len) return null;
            const len = std.mem.readInt(u32, buf[off..][0..4], .little);
            off += 4;
            if (off + len > buf.len) return null;
            out.append(gpa, buf[off .. off + len]) catch @panic("OOM");
            off += len;
        }
        return out.toOwnedSlice(gpa) catch @panic("OOM");
    }
    out.append(gpa, buf) catch @panic("OOM");
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}
