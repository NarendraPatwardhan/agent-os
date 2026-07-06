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
const task = @import("task.zig");
const pipe = @import("ipc/pipe.zig");
const net = @import("egress/net.zig");
const host_call = @import("egress/host_call.zig");
const persist = @import("egress/persist.zig");
const mountfs = @import("fs/mountfs.zig");
const persistfs = @import("fs/persistfs.zig");
const registry = @import("service/registry.zig");
const constants = @import("constants_zig");
const shcore = @import("shcore");

const HISTORY_CAP: usize = 200;
const DEFAULT_PATH = "/bin:/usr/bin";

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
/// (§2.2). Boot runs to completion and never suspends — off the Asyncify path (§7.4).
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
    vfs.wall_ms = bridge.mc_time_now();
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
    vfs.wall_ms = bridge.mc_time_now();
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

fn callerAlive(ctx: *anyopaque, caller: vfs.CallerId) bool {
    if (caller == vfs.SYSTEM_CALLER) return true;
    const k: *Kernel = @ptrCast(@alignCast(ctx));
    return k.sched.getTask(caller) != null;
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

fn readDirNames(k: *Kernel, arena: std.mem.Allocator, path: []const u8) ?[]const []const u8 {
    var out: std.ArrayList(vfs.DirEntry) = .empty;
    k.ns.readdir(arena, vfs.SYSTEM_CALLER, path, &out) catch return null;
    var names: std.ArrayList([]const u8) = .empty;
    for (out.items) |entry| names.append(arena, entry.name) catch @panic("OOM");
    return names.items;
}

fn readUleb(bytes: []const u8, at: usize) ?struct { value: u32, adv: usize } {
    var result: u32 = 0;
    var shift: u32 = 0;
    var n: usize = 0;
    while (true) {
        if (at + n >= bytes.len or shift >= 32) return null;
        const byte = bytes[at + n];
        n += 1;
        const low = @as(u32, byte & 0x7f);
        if (shift == 28 and low > 0x0f) return null;
        result |= low << @as(u5, @intCast(shift));
        if ((byte & 0x80) == 0) return .{ .value = result, .adv = n };
        shift += 7;
    }
}

fn uniqueCustom(bytes: []const u8, name: []const u8) ?[]const u8 {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], "\x00asm")) return null;
    var found: ?[]const u8 = null;
    var i: usize = 8;
    while (i < bytes.len) {
        const id = bytes[i];
        i += 1;
        const size_info = readUleb(bytes, i) orelse return null;
        i += size_info.adv;
        const body_start = i;
        const body_end = std.math.add(usize, body_start, @intCast(size_info.value)) catch return null;
        if (body_end > bytes.len) return null;
        if (id == 0) {
            const name_info = readUleb(bytes, body_start) orelse return null;
            const name_start = body_start + name_info.adv;
            const name_end = std.math.add(usize, name_start, @intCast(name_info.value)) catch return null;
            if (name_end <= body_end and std.mem.eql(u8, bytes[name_start..name_end], name)) {
                if (found != null) return null;
                found = bytes[name_end..body_end];
            }
        }
        i = body_end;
    }
    return found;
}

fn declaredTier(bytes: []const u8) ?task.Tier {
    const payload = uniqueCustom(bytes, "mc_tier") orelse return null;
    if (!std.unicode.utf8ValidateSlice(payload)) return null;
    return task.Tier.parse(payload);
}

fn declaredService(bytes: []const u8) ?[]const u8 {
    const payload = uniqueCustom(bytes, "mc_service") orelse return null;
    if (!std.unicode.utf8ValidateSlice(payload)) return null;
    if (!registry.validServiceName(payload)) return null;
    return payload;
}

const ServiceSpec = struct {
    binary: []u8,
    eager: bool,
};

fn skipWs(text: []const u8, at: *usize) void {
    while (at.* < text.len and (text[at.*] == ' ' or text[at.*] == '\n' or text[at.*] == '\r' or text[at.*] == '\t')) at.* += 1;
}

fn jsonStringField(gpa: std.mem.Allocator, text: []const u8, field: []const u8) ?[]u8 {
    const needle = std.fmt.allocPrint(gpa, "\"{s}\"", .{field}) catch @panic("OOM");
    defer gpa.free(needle);
    var pos = std.mem.indexOf(u8, text, needle) orelse return null;
    pos += needle.len;
    skipWs(text, &pos);
    if (pos >= text.len or text[pos] != ':') return null;
    pos += 1;
    skipWs(text, &pos);
    if (pos >= text.len or text[pos] != '"') return null;
    pos += 1;
    const start = pos;
    while (pos < text.len and text[pos] != '"') : (pos += 1) {
        if (text[pos] == '\\') return null;
    }
    if (pos >= text.len) return null;
    return gpa.dupe(u8, text[start..pos]) catch @panic("OOM");
}

fn jsonBoolField(text: []const u8, field: []const u8) ?bool {
    var tmp: [64]u8 = undefined;
    if (field.len + 2 > tmp.len) return null;
    tmp[0] = '"';
    @memcpy(tmp[1 .. 1 + field.len], field);
    tmp[1 + field.len] = '"';
    const needle = tmp[0 .. field.len + 2];
    var pos = std.mem.indexOf(u8, text, needle) orelse return null;
    pos += needle.len;
    skipWs(text, &pos);
    if (pos >= text.len or text[pos] != ':') return null;
    pos += 1;
    skipWs(text, &pos);
    if (std.mem.startsWith(u8, text[pos..], "true")) return true;
    if (std.mem.startsWith(u8, text[pos..], "false")) return false;
    return null;
}

fn lookupServiceSpec(k: *Kernel, name: []const u8) ?ServiceSpec {
    if (!registry.validServiceName(name)) return null;
    const path = std.fmt.allocPrint(k.gpa, "/etc/services.d/{s}.json", .{name}) catch @panic("OOM");
    defer k.gpa.free(path);
    const bytes = readFileAlloc(k, path) orelse return null;
    defer k.gpa.free(bytes);
    if (!std.unicode.utf8ValidateSlice(bytes)) return null;
    const binary = jsonStringField(k.gpa, bytes, "binary") orelse
        std.fmt.allocPrint(k.gpa, "/bin/{s}", .{name}) catch @panic("OOM");
    const eager = jsonBoolField(bytes, "eager") orelse false;
    return .{ .binary = binary, .eager = eager };
}

fn spawnService(k: *Kernel, name: []const u8, binary: []const u8) bool {
    if (binary.len == 0 or binary[0] != '/') return false;
    const bytes = readFileAlloc(k, binary) orelse return false;
    defer k.gpa.free(bytes);
    const service = declaredService(bytes) orelse return false;
    if (!std.mem.eql(u8, service, name)) return false;
    const tier = declaredTier(bytes) orelse return false;
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

pub fn activateServiceLazily(k: *Kernel, name: []const u8) bool {
    const spec = lookupServiceSpec(k, name) orelse return false;
    defer k.gpa.free(spec.binary);
    return spawnService(k, name, spec.binary);
}

fn activateEagerServices(k: *Kernel) void {
    var arena_state = std.heap.ArenaAllocator.init(k.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const names = readDirNames(k, arena, "/etc/services.d") orelse return;
    for (names) |file| {
        if (!std.mem.endsWith(u8, file, ".json")) continue;
        const name = file[0 .. file.len - ".json".len];
        if (!registry.validServiceName(name)) continue;
        const spec = lookupServiceSpec(k, name) orelse continue;
        defer k.gpa.free(spec.binary);
        if (spec.eager) _ = spawnService(k, name, spec.binary);
    }
}

fn setBootEnv(k: *Kernel, key: []const u8, value: []const u8) void {
    if (key.len == 0) return;
    if (k.boot_env.fetchRemove(key)) |old| {
        k.gpa.free(old.key);
        k.gpa.free(old.value);
    }
    const owned_key = k.gpa.dupe(u8, key) catch @panic("OOM");
    const owned_value = k.gpa.dupe(u8, value) catch @panic("OOM");
    k.boot_env.put(k.gpa, owned_key, owned_value) catch @panic("OOM");
}

fn profileValue(raw: []const u8) []const u8 {
    var value = std.mem.trim(u8, raw, " \t");
    if (value.len >= 2) {
        const q = value[0];
        if ((q == '"' or q == '\'') and value[value.len - 1] == q) {
            value = value[1 .. value.len - 1];
        }
    }
    return value;
}

fn seedBootEnv(k: *Kernel) void {
    if (k.boot_env.count() == 0) {
        setBootEnv(k, "PATH", DEFAULT_PATH);
        setBootEnv(k, "HOME", "/home/user");
        setBootEnv(k, "HOSTNAME", "agent-os");
    }

    const bytes = readFileAlloc(k, "/etc/profile") orelse return;
    defer k.gpa.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        var line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) {
            line = std.mem.trim(u8, line["export ".len..], " \t");
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) continue;
        var valid = true;
        for (key, 0..) |b, i| {
            const ok = std.ascii.isAlphabetic(b) or b == '_' or (i != 0 and std.ascii.isDigit(b));
            if (!ok) {
                valid = false;
                break;
            }
        }
        if (!valid) continue;
        setBootEnv(k, key, profileValue(line[eq + 1 ..]));
    }
}

/// Start the pid-1 login shell (§2.3): source /etc/profile, resolve /bin/sh, spawn pid 1
/// with the console pipe as its stdin, and load it into a wasm3 runtime. Oracle:
/// lib.rs::boot_login_shell → try_guest_login_shell. A missing or unloadable /bin/sh
/// falls back to the native in-kernel rescue shell bound to the same pid-1 Task.
pub fn startLoginShell(k: *Kernel) void {
    say("Sourcing /etc/profile\r\n");
    seedBootEnv(k);
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
