//! state.zig — the root `Kernel` state, its allocator, and boot/lifecycle helpers
//! (ZIG_KERNEL §2.1, §4.2).
//!
//! Owns: the ONE `Kernel` struct reachable from a single global cell — the root allocator,
//!   the mount namespace, and the host control scratch buffer. Every subsystem hangs off
//!   `Kernel`, never as a free-floating module global (§4.2 — the discipline the first
//!   attempt broke, §15.4).
//! Invariants: A8 (all mutable state in linear memory, reachable from `Kernel`), A7.
//! Not here: exported symbols (main.zig); the mc_ctl_* protocol (control.zig); base-image
//!   parsing and boot env seeding (boot.zig); console editing (console.zig);
//!   service activation (service/activation.zig).

const std = @import("std");
const vfs = @import("vfs.zig");
const boot = @import("boot.zig");
const bridge = @import("bridge.zig");
const console = @import("console.zig");
const scheduler = @import("scheduler.zig");
const guest = @import("guest.zig");
const rescue = @import("rescue.zig");
const pipe = @import("ipc/pipe.zig");
const net = @import("egress/net.zig");
const host_call = @import("egress/host_call.zig");
const persist = @import("egress/persist.zig");
const mountfs = @import("fs/mountfs.zig");
const persistfs = @import("fs/persistfs.zig");
const activation = @import("service/activation.zig");
const registry = @import("service/registry.zig");
const constants = @import("constants_zig");
const shcore = @import("shcore");

const LineEditor = console.LineEditor;
const flushConsole = console.flushConsole;
const feedConsoleByte = console.feedConsoleByte;
const activateEagerServices = activation.activateEagerServices;

pub const ServicePoll = activation.ServicePoll;
pub const serviceChannel = activation.serviceChannel;
pub const activateServiceLazily = activation.activateServiceLazily;

pub const CtlExecJob = struct {
    pid: ?u32,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    done: bool = false,
    exit_code: i32 = 0,

    pub fn deinit(self: *CtlExecJob, gpa: std.mem.Allocator) void {
        self.stdout.deinit(gpa);
        gpa.destroy(self.stdout);
        self.stderr.deinit(gpa);
        gpa.destroy(self.stderr);
    }
};

pub const CtlSvcJob = struct {
    name: ?[]u8,
    req: ?[]u8,
    channel: ?*registry.ServiceChannel = null,
    session: u32 = 0,
    req_id: u32 = 0,
    out: std.ArrayListUnmanaged(u8) = .empty,
    done: bool = false,
    status: i32 = 0,

    pub fn deinit(self: *CtlSvcJob, gpa: std.mem.Allocator) void {
        if (self.name) |n| gpa.free(n);
        if (self.req) |r| gpa.free(r);
        if (self.channel) |ch| {
            ch.dropSession(self.session);
            ch.release();
        }
        self.out.deinit(gpa);
    }
};

fn say(msg: []const u8) void {
    bridge.mc_stdout_write(msg.ptr, msg.len);
}

/// The single root kernel state. Everything that affects behavior lives here (A8).
pub const Kernel = struct {
    gpa: std.mem.Allocator,
    ns: vfs.Namespace,
    sched: scheduler.Scheduler,
    /// Cached wall-clock (ms), refreshed each tick and on a CAP_AMBIENT realtime read from the host
    /// clock. Owned here rather than in a module global so it resets/forks with the rest of kernel
    /// state; the many low-level readers (memfs timestamps, service deadlines) reach it through
    /// vfs.wallNowMs() so they need no Kernel handle.
    wall_ms: i64 = 0,
    /// Bidirectional host control scratch buffer (mc_ctl_*); lives in linear memory, so a
    /// snapshot captures it. The host sizes it via mc_ctl_buf, writes a request, and reads
    /// results back out of it.
    ctl_buffer: std.ArrayList(u8) = .empty,
    /// The pid-1 login shell's WAMR runtime, heap-allocated for a stable address. Null
    /// until startLoginShell.
    login_guest: ?*guest.GuestRuntime = null,
    /// Process-wide WAMR init/registry flags. The WAMR singleton itself is in the embedded
    /// C runtime; the ownership decision lives on Kernel, not in guest.zig globals.
    wamr_runtime_initialized: bool = false,
    wamr_natives_registered: bool = false,
    /// Private WAMR runtime heap. WAMR must not use the Zig kernel's process heap directly:
    /// its freestanding C allocator would race the kernel WasmAllocator for `__heap_base`.
    wamr_runtime_pool: ?[]u64 = null,
    /// The console pipe feeding pid-1 stdin: the kernel holds an extra writer (so the shell
    /// never sees EOF until Ctrl-D), the shell holds the read end as fd 0. Oracle: lib.rs
    /// STATE.console_pipe.
    console_pipe: ?*pipe.Pipe = null,
    /// Native shcore rescue shell, used only when the guest /bin/sh cannot be loaded.
    /// The adapter owns the ShellOs value shcore points at; both allocations live here,
    /// not in module globals.
    rescue_os: ?*rescue.KernelShellOs = null,
    rescue_shell: ?*shcore.Shell = null,
    rescue_active: bool = false,
    /// Cooked terminal line editor and backlog of committed console input that did not fit
    /// into the pipe in one write. Both live in `Kernel`, never module globals (§4.2).
    line_editor: LineEditor = .{},
    console_pending: std.ArrayList(u8) = .empty,
    /// Host control-channel exec jobs (`mc_ctl_exec_*`), keyed by job id. The capture
    /// buffers are heap-owned so fd handles can point at them while child tasks run.
    ctl_exec_jobs: std.AutoHashMapUnmanaged(u32, CtlExecJob) = .{},
    next_ctl_job_id: u32 = 1,
    /// Host egress engines. Open handles are snapshot blockers.
    net: net.Engine,
    host_call: host_call.Engine,
    persist: persist.Engine,
    /// Resident-service registry, activation supervisor, and session channels.
    services: registry.Engine,
    /// Boot/default environment exposed through `/env` before a caller-specific task env
    /// exists, then cloned into pid 1.
    boot_env: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Async persist mounts registered for tick-time commit draining.
    mount_channels: std.ArrayListUnmanaged(*mountfs.MountChannel) = .empty,
    persist_channels: std.ArrayListUnmanaged(*persistfs.PersistChannel) = .empty,
    /// Host control-channel service calls (`mc_ctl_svc_call_*`), keyed by job id.
    ctl_svc_jobs: std.AutoHashMapUnmanaged(u32, CtlSvcJob) = .{},
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
/// (§2.2). Boot runs to completion before the guest scheduler starts.
pub fn init() i32 {
    g_kernel = .{
        .gpa = kernel_allocator,
        .ns = vfs.Namespace.init(kernel_allocator),
        .sched = scheduler.Scheduler.init(kernel_allocator),
        .net = net.Engine.init(kernel_allocator),
        .host_call = host_call.Engine.init(kernel_allocator),
        .persist = persist.Engine.init(kernel_allocator),
        .services = registry.Engine.init(kernel_allocator),
    };
    g_ready = true;
    g_kernel.wall_ms = bridge.mc_time_now();
    g_kernel.ctl_buffer.ensureTotalCapacity(g_kernel.gpa, 256) catch @panic("OOM");
    boot.bootSystem(&g_kernel);
    g_kernel.initialized = true;
    startLoginShell(&g_kernel);
    activateEagerServices(&g_kernel);
    return 0;
}

/// Exit status for a guest that FAULTED (a wasm trap / bad-instruction / host-detected
/// error, distinct from a clean `mc_exit` or a fuel kill): 128 + SIGABRT, the conventional
/// "aborted" code, so `waitpid` reports a non-zero status the shell can surface.
const FAULT_EXIT_CODE: i32 = 134; // 128 + SIGABRT(6): the conventional "aborted" status

/// `mc_tick`: step the machine one bounded slice, then return. 1 ⇒ runnable work remains
/// (the host keeps ticking); 0 ⇒ every task is blocked on input or a child — idle at the
/// prompt, so the host settles and waits for `mc_input`. Never suspends the host itself: a
/// suspended guest is just a blocked task (§2.1, §7.4).
///
/// One cooperative round per tick: step each CURRENTLY-ready task's guest exactly once.
/// A guest that fuel-yields or re-arms a ready syscall requeues itself to the BACK of the
/// ready queue, so it waits for the next tick — an unbounded producer (`yes | head`) can't
/// monopolize a tick (the Rust oracle's bounded run_round). pid 1 is just one ready task
/// here (its console pipe is only its fd 0); a spawned child is picked up the same way.
pub fn tick() i32 {
    if (!isInitialized()) return 0;
    const k = &g_kernel;
    k.wall_ms = bridge.mc_time_now();
    _ = flushConsole(k);
    // Wake any task whose block condition cleared: an empty stdin pipe that now has bytes,
    // a full pipe drained, a waited-for child that exited.
    k.sched.checkUnblocked();
    const ran_any = stepReadyRound(k);
    mountfs.drainAll(&k.mount_channels, callerAlive, k);
    persistfs.drainAll(&k.persist_channels, callerAlive, k);
    if (ran_any or k.sched.readyCount() > 0) return 1;
    return 0;
}

/// True if `caller` is a live (non-zombie) task; SYSTEM_CALLER is always live. The fs drain and
/// svc-eviction callbacks use it to skip channels whose caller has exited or is being reaped — a
/// zombie is not a live recipient.
pub fn callerAlive(ctx: *anyopaque, caller: vfs.CallerId) bool {
    if (caller == vfs.SYSTEM_CALLER) return true;
    const k: *Kernel = @ptrCast(@alignCast(ctx));
    const t = k.sched.getTask(caller) orelse return false;
    return t.state != .zombie;
}

/// Step each CURRENTLY-ready task's guest exactly once — the bounded run-round. Returns true
/// if any guest made progress (`.ran`). Shared by `tick()` and the rescue shell's inline
/// `waitpid` drive: a native (kernel) shell does not own a guest exec_env, so it drives child guests
/// to completion by calling THIS between zombie checks (task #11). Frees an exited/faulted
/// guest via `onGuestFinished`; a signal-terminated task's guest is torn down too. Bounded to
/// the ready count captured up front — a guest that fuel-yields or re-arms a ready syscall
/// requeues to the BACK and waits for the next round, so an unbounded producer can't
/// monopolize a round.
pub fn stepReadyRound(k: *Kernel) bool {
    var ran_any = false;
    const rounds = k.sched.readyCount();
    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        const id = k.sched.popReady() orelse break;
        const t = k.sched.getTask(id) orelse continue;
        // Apply pending signals at this safe point (between steps); `false` ⇒ the task was
        // terminated (now a zombie) — tear its guest down and move on.
        if (!k.sched.processSignals(id)) {
            if (t.guest) |gp| onGuestFinished(k, id, @ptrCast(@alignCast(gp)), t.exit_code orelse 0);
            continue;
        }
        const gp = t.guest orelse {
            // A ready task with no instantiated guest can make no progress: requeue rather
            // than busy-spin. (Shouldn't happen — spawn wires the guest before it enqueues.)
            k.sched.requeue(id);
            continue;
        };
        const g: *guest.GuestRuntime = @ptrCast(@alignCast(gp));
        switch (g.step()) {
            .ran => ran_any = true, // requeued itself (fuel yield / ready syscall) — more work
            .suspended => {}, // parked on a blocking syscall — idle until its wake condition
            .exited => onGuestFinished(k, id, g, g.exitCode()),
            .faulted => onGuestFinished(k, id, g, FAULT_EXIT_CODE),
        }
    }
    return ran_any;
}

/// A guest reported `.exited`/`.faulted` (or a signal killed its task): make sure the task
/// is a zombie carrying `code`, free its WAMR runtime, and — for pid 1 — end the session.
/// The zombie stays until a parent `waitpid` reaps it: guest.zig owns the runtime, the
/// scheduler owns the task. Respawning pid 1 for session keep-alive is a later refinement.
fn onGuestFinished(k: *Kernel, id: u32, g: *guest.GuestRuntime, code: i32) void {
    if (k.sched.getTask(id)) |t| {
        if (t.state != .zombie) k.sched.exitTask(id, code);
    }
    const is_login = if (k.login_guest) |lg| lg == g else false;
    guest.destroyGuest(g); // deinit clears Task.guest + frees the runtime; then frees `g`
    if (is_login) {
        k.login_guest = null;
        k.sched.signalAllExcept(1, constants.SIGHUP); // hang up the session
    }
}

/// `mc_input`: feed terminal keystrokes through the kernel cooked line discipline. The
/// terminal has no local echo: `LineEditor` echoes edits and only committed lines reach
/// pid-1 sh's console pipe.
pub fn input(ptr: [*]const u8, len: usize) void {
    if (!isInitialized()) return;
    const k = &g_kernel;
    _ = flushConsole(k);
    for (ptr[0..len]) |byte| feedConsoleByte(k, byte);
}

/// Read a whole file from the root namespace into a gpa-owned buffer (resolves the login
/// shell binary + boot scripts). Null if the path can't be opened/read. Oracle: control.zig
/// mc_ctl_read's read loop.
pub fn readFileAlloc(k: *Kernel, path: []const u8) ?[]u8 {
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

pub fn readDirNames(k: *Kernel, arena: std.mem.Allocator, path: []const u8) ?[]const []const u8 {
    var out: std.ArrayList(vfs.DirEntry) = .empty;
    k.ns.readdir(arena, vfs.SYSTEM_CALLER, path, &out) catch return null;
    var names: std.ArrayList([]const u8) = .empty;
    for (out.items) |entry| names.append(arena, entry.name) catch @panic("OOM");
    return names.items;
}

/// Start the pid-1 login shell (§2.3): source /etc/profile, resolve /bin/sh, spawn pid 1
/// with the console pipe as its stdin, and load it into a WAMR runtime. Oracle:
/// lib.rs::boot_login_shell → try_guest_login_shell. A missing or unloadable /bin/sh
/// falls back to the native in-kernel rescue shell bound to the same pid-1 Task.
pub fn startLoginShell(k: *Kernel) void {
    say("Sourcing /etc/profile\r\n");
    boot.seedBootEnv(k);
    const sh_bytes = readFileAlloc(k, "/bin/sh");

    // The login shell is always pid 1 (reuse the id so /proc/1 is stable across respawn).
    const pid = k.sched.spawnWithId(1, null, "sh", "sh", &[_][]const u8{}, "/home/user") orelse return;

    // Console pipe: the kernel keeps an extra writer so the shell's stdin never hits EOF
    // until Ctrl-D; the shell holds the read end as fd 0.
    const cpipe = k.sched.allocPipe();
    cpipe.addWriter();
    cpipe.addReader();
    k.console_pipe = cpipe;
    if (k.sched.getTask(pid)) |t| {
        t.cloneEnvFrom(k.gpa, &k.boot_env);
        t.setFd(k.gpa, 0, .{ .pipe_read = cpipe });
    }

    const bytes = sh_bytes orelse {
        say("login shell unavailable; starting rescue shell\r\n");
        k.sched.detach(pid);
        rescue.start(k);
        return;
    };
    defer k.gpa.free(bytes);

    // Heap-allocate the runtime (stable address) and load /bin/sh eagerly.
    const g = k.gpa.create(guest.GuestRuntime) catch @panic("OOM");
    g.init(k.gpa, bytes, "_start", pid, "/home/user") catch {
        say("login shell failed to load\r\n");
        k.gpa.destroy(g);
        k.sched.detach(pid);
        rescue.start(k);
        return;
    };
    k.rescue_active = false;
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

/// §2.8 quiescence accounting. Host egress handles are host-owned capabilities and
/// cannot be snapshotted safely while open.
pub fn inflightEgress() i32 {
    if (!isInitialized()) return 0;
    return g_kernel.net.inflight() + g_kernel.host_call.inflight() + g_kernel.persist.inflight() +
        g_kernel.services.svcInflight();
}
pub fn pendingCommits() i32 {
    if (!isInitialized()) return 0;
    return mountfs.pendingCommitCount(&g_kernel.mount_channels) + persistfs.pendingCommitCount(&g_kernel.persist_channels);
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
