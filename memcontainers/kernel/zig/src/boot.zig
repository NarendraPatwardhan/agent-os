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
const DevFs = @import("fs/devfs.zig").DevFs;
const ServiceFs = @import("fs/servicefs.zig").ServiceFs;

fn say(msg: []const u8) void {
    bridge.mc_stdout_write(msg.ptr, msg.len);
}

pub fn bootSystem(k: *state.Kernel) void {
    const gpa = k.gpa;
    const ns = &k.ns;
    say("Booting ...\r\n");

    var mounted_root = false;
    if (loadBaseImage(gpa)) |payload| {
        if (parseSingleLayer(payload)) |tar_bytes| {
            const owned = gpa.dupe(u8, tar_bytes) catch @panic("OOM");
            if (TarFs.create(gpa, owned)) |tar| {
                const cow = CowFs.create(gpa, tar.fileSystem());
                ns.mountLabeled("/", cow.fileSystem(), "cowfs", false);
                mounted_root = true;
                say("Loading image... ok\r\n");
            } else {
                gpa.free(owned);
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
    ns.mkdir(a, vfs.SYSTEM_CALLER, "/proc") catch {};
    ns.mkdir(a, vfs.SYSTEM_CALLER, "/svc") catch {};
    ns.mountLabeled("/svc", ServiceFs.create(gpa).fileSystem(), "servicefs", false);
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

/// The host payload is either a bare `.tar` (one layer) or an `MCLS` layer stack. Phase 3
/// supports a single layer (CowFs(TarFs)); a multi-layer stack needs OverlayFs (Phase 6),
/// so return null there → empty-root fallback. Oracle: init.rs::parse_layers.
fn parseSingleLayer(buf: []const u8) ?[]const u8 {
    if (buf.len >= 8 and std.mem.eql(u8, buf[0..4], "MCLS")) {
        const count = std.mem.readInt(u32, buf[4..8], .little);
        if (count != 1) return null; // multi-layer → OverlayFs (Phase 6)
        var off: usize = 8;
        if (off + 4 > buf.len) return null;
        const len = std.mem.readInt(u32, buf[off..][0..4], .little);
        off += 4;
        if (off + len > buf.len) return null;
        return buf[off .. off + len];
    }
    return buf; // a bare tar is one layer
}
