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
const rescue = @import("rescue.zig");
const pipe = @import("ipc/pipe.zig");
const net = @import("egress/net.zig");
const host_call = @import("egress/host_call.zig");
const constants = @import("constants_zig");
const shcore = @import("shcore");

const HISTORY_CAP: usize = 200;

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

const EscState = enum {
    normal,
    esc,
    csi,
};

fn termEmit(bytes: []const u8) void {
    if (bytes.len != 0) bridge.mc_stdout_write(bytes.ptr, bytes.len);
}

fn termBs(n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) termEmit("\x08");
}

fn termErase(n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) termEmit("\x08 \x08");
}

const LineEditor = struct {
    line: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    history: std.ArrayList([]u8) = .empty,
    hist_nav: ?usize = null,
    stash: std.ArrayList(u8) = .empty,
    esc: EscState = .normal,
    param: u16 = 0,

    fn insert(self: *LineEditor, gpa: std.mem.Allocator, b: u8) void {
        const old_len = self.line.items.len;
        self.line.append(gpa, b) catch @panic("OOM");
        if (self.cursor < old_len) {
            std.mem.copyBackwards(
                u8,
                self.line.items[self.cursor + 1 .. old_len + 1],
                self.line.items[self.cursor..old_len],
            );
        }
        self.line.items[self.cursor] = b;
        termEmit(self.line.items[self.cursor..]);
        termBs(self.line.items.len - self.cursor - 1);
        self.cursor += 1;
    }

    fn removeAt(self: *LineEditor, idx: usize) void {
        const old_len = self.line.items.len;
        if (idx + 1 < old_len) {
            std.mem.copyForwards(u8, self.line.items[idx .. old_len - 1], self.line.items[idx + 1 .. old_len]);
        }
        self.line.items.len = old_len - 1;
    }

    fn backspace(self: *LineEditor) void {
        if (self.cursor == 0) return;
        self.cursor -= 1;
        self.removeAt(self.cursor);
        termBs(1);
        termEmit(self.line.items[self.cursor..]);
        termEmit(" ");
        termBs(self.line.items.len - self.cursor + 1);
    }

    fn deleteFwd(self: *LineEditor) void {
        if (self.cursor >= self.line.items.len) return;
        self.removeAt(self.cursor);
        termEmit(self.line.items[self.cursor..]);
        termEmit(" ");
        termBs(self.line.items.len - self.cursor + 1);
    }

    fn left(self: *LineEditor) void {
        if (self.cursor == 0) return;
        self.cursor -= 1;
        termBs(1);
    }

    fn right(self: *LineEditor) void {
        if (self.cursor >= self.line.items.len) return;
        termEmit(self.line.items[self.cursor .. self.cursor + 1]);
        self.cursor += 1;
    }

    fn home(self: *LineEditor) void {
        termBs(self.cursor);
        self.cursor = 0;
    }

    fn end(self: *LineEditor) void {
        termEmit(self.line.items[self.cursor..]);
        self.cursor = self.line.items.len;
    }

    fn replaceLine(self: *LineEditor, gpa: std.mem.Allocator, next: []const u8) void {
        termEmit(self.line.items[self.cursor..]);
        termErase(self.line.items.len);
        self.line.clearRetainingCapacity();
        self.line.appendSlice(gpa, next) catch @panic("OOM");
        termEmit(self.line.items);
        self.cursor = self.line.items.len;
    }

    fn historyPrev(self: *LineEditor, gpa: std.mem.Allocator) void {
        if (self.history.items.len == 0) return;
        const j = self.hist_nav orelse blk: {
            self.stash.clearRetainingCapacity();
            self.stash.appendSlice(gpa, self.line.items) catch @panic("OOM");
            break :blk self.history.items.len;
        };
        if (j == 0) return;
        self.hist_nav = j - 1;
        self.replaceLine(gpa, self.history.items[j - 1]);
    }

    fn historyNext(self: *LineEditor, gpa: std.mem.Allocator) void {
        const j = self.hist_nav orelse return;
        const n = self.history.items.len;
        if (j >= n) return;
        if (j + 1 == n) {
            self.hist_nav = null;
            self.replaceLine(gpa, self.stash.items);
            self.stash.clearRetainingCapacity();
        } else {
            self.hist_nav = j + 1;
            self.replaceLine(gpa, self.history.items[j + 1]);
        }
    }

    fn resetLine(self: *LineEditor) void {
        self.line.clearRetainingCapacity();
        self.cursor = 0;
        self.hist_nav = null;
        self.stash.clearRetainingCapacity();
        self.esc = .normal;
        self.param = 0;
    }

    fn commit(self: *LineEditor, gpa: std.mem.Allocator) void {
        if (self.line.items.len != 0) {
            const duplicate = if (self.history.items.len == 0)
                false
            else
                std.mem.eql(u8, self.history.items[self.history.items.len - 1], self.line.items);
            if (!duplicate) {
                const owned = gpa.dupe(u8, self.line.items) catch @panic("OOM");
                self.history.append(gpa, owned) catch @panic("OOM");
                if (self.history.items.len > HISTORY_CAP) {
                    const old = self.history.orderedRemove(0);
                    gpa.free(old);
                }
            }
        }
        self.resetLine();
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
        .net = net.Engine.init(kernel_allocator),
        .host_call = host_call.Engine.init(kernel_allocator),
    };
    g_ready = true;
    vfs.wall_ms = bridge.mc_time_now();
    g_kernel.ctl_buffer.ensureTotalCapacity(g_kernel.gpa, 256) catch @panic("OOM");
    boot.bootSystem(&g_kernel);
    g_kernel.initialized = true;
    startLoginShell(&g_kernel);
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
    vfs.wall_ms = bridge.mc_time_now();
    _ = flushConsole(k);
    // Wake any task whose block condition cleared: an empty stdin pipe that now has bytes,
    // a full pipe drained, a waited-for child that exited.
    k.sched.checkUnblocked();
    const ran_any = stepReadyRound(k);
    if (ran_any or k.sched.readyCount() > 0) return 1;
    return 0;
}

/// Step each CURRENTLY-ready task's guest exactly once — the bounded run-round. Returns true
/// if any guest made progress (`.ran`). Shared by `tick()` and the rescue shell's inline
/// `waitpid` drive: a native (kernel) shell can't Asyncify-suspend, so it drives child guests
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
/// is a zombie carrying `code`, free its wasm3 runtime, and — for pid 1 — end the session.
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

fn flushConsole(k: *Kernel) bool {
    const cpipe = k.console_pipe orelse return false;
    if (cpipe.isWriteClosed()) return false;
    var wrote = false;
    while (k.console_pending.items.len != 0) {
        const n = cpipe.write(k.console_pending.items);
        if (n == 0) break;
        wrote = true;
        const remaining = k.console_pending.items.len - n;
        if (remaining != 0) {
            std.mem.copyForwards(u8, k.console_pending.items[0..remaining], k.console_pending.items[n..]);
        }
        k.console_pending.items.len = remaining;
    }
    if (wrote) k.sched.checkUnblocked();
    return wrote;
}

fn queueConsoleLine(k: *Kernel, line: []const u8) void {
    k.console_pending.appendSlice(k.gpa, line) catch @panic("OOM");
    k.console_pending.append(k.gpa, '\n') catch @panic("OOM");
    _ = flushConsole(k);
}

fn feedConsoleByte(k: *Kernel, byte: u8) void {
    const ed = &k.line_editor;

    switch (ed.esc) {
        .esc => {
            ed.esc = if (byte == '[' or byte == 'O') blk: {
                ed.param = 0;
                break :blk .csi;
            } else .normal;
            return;
        },
        .csi => {
            if (byte >= '0' and byte <= '9') {
                ed.param = (ed.param *| 10) +| @as(u16, @intCast(byte - '0'));
                return;
            }
            ed.esc = .normal;
            switch (byte) {
                'A' => ed.historyPrev(k.gpa),
                'B' => ed.historyNext(k.gpa),
                'C' => ed.right(),
                'D' => ed.left(),
                'H' => ed.home(),
                'F' => ed.end(),
                '~' => switch (ed.param) {
                    1, 7 => ed.home(),
                    4, 8 => ed.end(),
                    3 => ed.deleteFwd(),
                    else => {},
                },
                else => {},
            }
            return;
        },
        .normal => {},
    }

    if (byte == 0x1b) {
        ed.esc = .esc;
    } else if (byte == 0x7f or byte == 0x08) {
        ed.backspace();
    } else if (byte == 0x01) {
        ed.home();
    } else if (byte == 0x05) {
        ed.end();
    } else if (byte == 0x04) {
        if (k.rescue_active) {
            return;
        } else if (ed.line.items.len == 0) {
            if (k.console_pipe) |cpipe| cpipe.closeWrite();
            k.sched.checkUnblocked();
        }
    } else if (byte == 0x03) {
        termEmit("^C\r\n");
        ed.resetLine();
        if (k.rescue_active) {
            rescue.prompt();
        } else {
            k.sched.signalGroup(k.sched.foreground_pgid, constants.SIGINT);
        }
    } else if (byte == 0x1a) {
        termEmit("^Z\r\n");
        ed.resetLine();
        if (k.rescue_active) {
            rescue.prompt();
        } else {
            k.sched.signalGroup(k.sched.foreground_pgid, constants.SIGTSTP);
        }
    } else if (byte == '\n' or byte == '\r') {
        termEmit("\r\n");
        if (k.rescue_active) {
            rescue.submitLine(k, ed.line.items);
        } else {
            queueConsoleLine(k, ed.line.items);
        }
        ed.commit(k.gpa);
    } else if ((byte >= '!' and byte <= '~') or byte == ' ') {
        ed.insert(k.gpa, byte);
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
/// lib.rs::boot_login_shell → try_guest_login_shell. A missing or unloadable /bin/sh
/// falls back to the native in-kernel rescue shell bound to the same pid-1 Task.
pub fn startLoginShell(k: *Kernel) void {
    say("Sourcing /etc/profile\r\n");
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
    g.* = .{};
    if (!g.init(k.gpa, bytes, "_start", pid, "/home/user")) {
        say("login shell failed to load\r\n");
        k.gpa.destroy(g);
        k.sched.detach(pid);
        rescue.start(k);
        return;
    }
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
    return g_kernel.net.inflight() + g_kernel.host_call.inflight();
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
