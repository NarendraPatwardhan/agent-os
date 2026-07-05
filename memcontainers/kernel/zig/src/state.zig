//! state.zig — the root `Kernel` state, its allocator, and boot/lifecycle helpers
//! (ZIG_KERNEL §2.1, §4.2).
//!
//! Owns: the ONE `Kernel` struct reachable from a single global cell — the root allocator,
//!   the mount namespace, and the host control scratch buffer. Every subsystem hangs off
//!   `Kernel`, never as a free-floating module global (§4.2 — the discipline the first
//!   attempt broke, §15.4).
//! Invariants: A8 (all mutable state in linear memory, reachable from `Kernel`), A7.
//! Not here: exported symbols (main.zig); the mc_ctl_* protocol (control.zig); base-image
//!   parsing (boot.zig).

const std = @import("std");
const vfs = @import("vfs.zig");
const boot = @import("boot.zig");
const bridge = @import("bridge.zig");
const scheduler = @import("scheduler.zig");
const guest = @import("guest.zig");
const pipe = @import("ipc/pipe.zig");
const constants = @import("constants_zig");

fn say(msg: []const u8) void {
    bridge.mc_stdout_write(msg.ptr, msg.len);
}

/// The single root kernel state. Everything that affects behavior lives here (A8).
pub const Kernel = struct {
    gpa: std.mem.Allocator,
    ns: vfs.Namespace,
    sched: scheduler.Scheduler,
    /// Bidirectional host control scratch buffer (mc_ctl_*); lives in linear memory, so a
    /// snapshot captures it. The host sizes it via mc_ctl_buf, writes a request, and reads
    /// results back out of it.
    ctl_buffer: std.ArrayList(u8) = .empty,
    /// The pid-1 login shell's wasm3 runtime, heap-allocated for a stable address (the raw
    /// syscall trampoline recovers it via m3_GetUserData, §7.4). Null until startLoginShell.
    login_guest: ?*guest.GuestRuntime = null,
    /// The console pipe feeding pid-1 stdin: the kernel holds an extra writer (so the shell
    /// never sees EOF until Ctrl-D), the shell holds the read end as fd 0. Oracle: lib.rs
    /// STATE.console_pipe.
    console_pipe: ?*pipe.Pipe = null,
    initialized: bool = false,
};

/// The single global cell (mirrors the Rust kernel's `static STATE`). Access via `kernel()`.
var g_kernel: Kernel = undefined;
var g_ready: bool = false;

/// The wasm linear-memory allocator (A6). Real malloc/free, not page-granular.
const kernel_allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &std.heap.WasmAllocator.vtable,
};

pub fn kernel() *Kernel {
    return &g_kernel;
}
pub fn isInitialized() bool {
    return g_ready and g_kernel.initialized;
}

/// `mc_init`: construct the root `Kernel`, load the base image, and build the namespace
/// (§2.2). Boot runs to completion and never suspends — off the Asyncify path (§7.4).
pub fn init() i32 {
    g_kernel = .{
        .gpa = kernel_allocator,
        .ns = vfs.Namespace.init(kernel_allocator),
        .sched = scheduler.Scheduler.init(kernel_allocator),
    };
    g_ready = true;
    g_kernel.ctl_buffer.ensureTotalCapacity(g_kernel.gpa, 256) catch @panic("OOM");
    boot.bootSystem(&g_kernel);
    g_kernel.initialized = true;
    startLoginShell(&g_kernel);
    return 0;
}

/// `mc_tick`: advance the machine one step without monopolizing the host. Always returns
/// normally (§2.1). The scheduler/guest stepping attaches here in Phase 4/5.
/// `mc_tick`: step the machine one bounded slice. Returns 1 when there is more work to do
/// (the host keeps ticking) and 0 when the machine is idle — parked on the prompt read,
/// waiting for input (the host settles and checks for the prompt). Never suspends the host
/// itself: a suspended guest is just a blocked task (§2.1, §7.4).
pub fn tick() i32 {
    if (!isInitialized()) return 0;
    const k = &g_kernel;
    // Wake any task whose block condition cleared (an empty stdin pipe that now has bytes).
    k.sched.checkUnblocked();
    if (k.login_guest) |g| {
        return switch (g.step()) {
            .ran => 1, // yielded on the fuel quantum — more work remains
            .suspended => 0, // parked on a syscall (the prompt read) — idle until input
            .exited, .faulted => 0, // TODO(Phase 6): respawn pid 1 (session keep-alive)
        };
    }
    return 0;
}

/// `mc_input`: feed terminal keystrokes to the foreground task's stdin. Oracle: lib.rs
/// LineEditor + console_pipe. The cooked line discipline (echo, editing, history) lands
/// with the tty tests (Phase 6); for now raw bytes flow to the console pipe so a blocked
/// stdin read wakes and resumes.
pub fn input(ptr: [*]const u8, len: usize) void {
    if (!isInitialized()) return;
    const k = &g_kernel;
    if (k.console_pipe) |cpipe| {
        _ = cpipe.write(ptr[0..len]);
        k.sched.checkUnblocked();
    }
}

/// Read a whole file from the root namespace into a gpa-owned buffer (resolves the login
/// shell binary + boot scripts). Null if the path can't be opened/read. Oracle: control.zig
/// mc_ctl_read's read loop.
fn readFileAlloc(k: *Kernel, path: []const u8) ?[]u8 {
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    var h = k.ns.openAs(scratch.allocator(), vfs.SYSTEM_CALLER, path, vfs.OpenFlags.READ) catch return null;
    defer h.close();
    var out: std.ArrayList(u8) = .empty;
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = h.read(&tmp) catch {
            out.deinit(k.gpa);
            return null;
        };
        if (n == 0) break;
        out.appendSlice(k.gpa, tmp[0..n]) catch @panic("OOM");
    }
    return out.toOwnedSlice(k.gpa) catch @panic("OOM");
}

/// Start the pid-1 login shell (§2.3): source /etc/profile, resolve /bin/sh, spawn pid 1
/// with the console pipe as its stdin, and load it into a wasm3 runtime. Oracle:
/// lib.rs::boot_login_shell → try_guest_login_shell. A missing /bin/sh degrades to the bare
/// boot transcript rather than trapping (the in-kernel rescue shell is Phase 6).
pub fn startLoginShell(k: *Kernel) void {
    say("Sourcing /etc/profile\r\n");
    const sh_bytes = readFileAlloc(k, "/bin/sh") orelse return;

    // The login shell is always pid 1 (reuse the id so /proc/1 is stable across respawn).
    const pid = k.sched.spawnWithId(1, null, "sh", "sh", &[_][]const u8{}, "/home/user") orelse return;

    // Console pipe: the kernel keeps an extra writer so the shell's stdin never hits EOF
    // until Ctrl-D; the shell holds the read end as fd 0.
    const cpipe = k.sched.allocPipe();
    cpipe.addWriter();
    cpipe.addReader();
    k.console_pipe = cpipe;
    if (k.sched.getTask(pid)) |t| {
        t.setFd(k.gpa, 0, .{ .pipe_read = cpipe });
    }

    // Heap-allocate the runtime (stable address) and load /bin/sh eagerly.
    const g = k.gpa.create(guest.GuestRuntime) catch @panic("OOM");
    g.* = .{};
    if (!g.init(k.gpa, sh_bytes, "_start", pid, "/home/user")) {
        say("login shell failed to load\r\n");
        k.gpa.destroy(g);
        return;
    }
    k.login_guest = g;
}

pub fn resize(cols: i32, rows: i32) void {
    _ = cols;
    _ = rows;
    // TODO(Phase 4): update the pty winsize device state.
}

pub fn commitLayer() i32 {
    // TODO(Phase 6): serialize the root CoW overlay to a new commit layer (needs TarWriter).
    return -constants.ENOSYS;
}

/// §2.8 quiescence accounting. 0 is the honest count while no egress/persist subsystem
/// exists; wired to the real inflight/pending registries in Phase 6.
pub fn inflightEgress() i32 {
    return 0;
}
pub fn pendingCommits() i32 {
    return 0;
}
pub fn quiesceRequest() i32 {
    return 0;
}
pub fn quiesceRelease() i32 {
    return 0;
}
pub fn workerEntry(arg: i32) i32 {
    _ = arg;
    return 0;
}
