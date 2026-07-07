//! task.zig — the task table, pid allocation, fd tables, capabilities, process groups,
//! and signal state (ZIG_KERNEL §2.3, §4.1).
//!
//! Owns: stable task identities (a `TaskId` is what every OTHER subsystem holds — a
//!   guest points back by stable id, e.g. `m3_GetUserData`, never a raw pointer, §4.2),
//!   pid allocation, per-task fd tables, the 8-bit capability set (generated from
//!   constants), tier caps applied at exec, process groups, and signal state. Exec
//!   authority is `parent caps & binary tier/caps & requested caps`.
//! Invariants: pid 1 has special reparenting/liveness meaning; a blocked guest is a task
//!   whose wasm3 execution was Asyncify-suspended, its park descriptor in task state
//!   (§2.3). Guest runtime state may point back by stable id (m3_GetUserData), but this
//!   table owns lifecycle.
//! Consumes: :constants_zig (caps, tiers, signals, wait flags).
//! Not here: run-queue transitions and tick logic (scheduler.zig); pipe buffers
//!   (ipc/pipe.zig); the wasm3 runtimes themselves (guest.zig). This file is identity +
//!   capability + fd bookkeeping; the scheduler drives it.
//!
//! Scaffold status: implemented (Phase 4). Oracle: kernel/rust/src/task/mod.rs — ported
//! faithfully modulo the single-threaded simplification (SYSTEMS.md): every `UnsafeCell`
//! accessor pair collapses to a plain field (direct mutation, no aliasing hazard without
//! Rust's borrow checker); `Task` is heap-allocated (`gpa.create`) and the scheduler's map
//! stores the resulting `*Task` for a stable address (matching the oracle's own
//! `BTreeMap<TaskId, Box<Task>>` — a heap box per id, not a slot-map/generation scheme)
//! — but that pointer never leaves the scheduler: every cross-subsystem reference (a
//! parent id, `BlockReason.wait_child`, a future guest back-reference) is still a plain
//! `TaskId`, looked up fresh via `Scheduler.getTask`, exactly as the invariant above
//! requires. `BlockReason` carries raw `*Pipe` pointers directly (Zig has no borrow
//! checker to launder them through a `usize`, unlike the oracle). Per-task namespace
//! forking (the oracle's `Task.namespace`) is deferred: vfs.zig has no fork/clone yet
//! (Phase 3 has one root namespace only, per its own header) — add it alongside that
//! work. `stdin`/`stdout`/`stderr` are not separate typed fields as in the oracle; they
//! are fd slots 0/1/2 of the unified `fds` table (see `Fd`), since this kernel's `Fd` is
//! one uniform tagged union rather than boxed `ReadSource`/`WriteSink` trait objects — a
//! `.none` slot at 0/1/2 means "fall back to the host terminal bridge", a syscall-layer
//! concern out of scope here. The oracle's `Task::step`/`Builtin` plumbing is not ported:
//! execution is wasm3-driven (guest.zig owns `Task.guest`), not a cooperative native
//! closure.

const std = @import("std");
const vfs = @import("vfs.zig");
const pipe = @import("ipc/pipe.zig");
const constants = @import("constants_zig");
const net = @import("egress/net.zig");
const host_call = @import("egress/host_call.zig");
const servedfs = @import("fs/servedfs.zig");
const registry = @import("service/registry.zig");

pub const TaskId = u32;

/// A file-descriptor slot. Indices 0/1/2 are the conventional stdin/stdout/stderr slots;
/// 3+ are opened by open/pipe/dup (see `Task.fds`).
///
pub const Fd = union(enum) {
    none,
    file: vfs.FileHandle,
    pipe_read: *pipe.Pipe,
    pipe_write: *pipe.Pipe,
    net: *net.HttpSource,
    ws: *net.WsSource,
    host_call: *host_call.Source,
    serve: *servedfs.ServeOwner,
    svc_serve: *registry.SvcServeOwner,
    svc_conn: *registry.SvcConnHandle,
    svc_call: *registry.SvcCallSource,
};

/// A task's capability set — the kernel-side POLICY layer. A privileged syscall checks
/// the relevant bit and returns `EPERM` if it is absent; this composes with (does not
/// replace) the host capability gate. Capabilities only ever **narrow** down the process
/// tree: a child's set is `parent ∩ binary-tier ∩ requested-tier` (exec is the policy
/// point — the actual narrowing happens in the syscall layer, not here).
pub const Capabilities = struct {
    bits: u8 = 0,

    /// All capabilities — the privilege of pid 1 (the shell). `Task.create` uses this.
    pub fn all() Capabilities {
        return .{ .bits = constants.CAP_FS_READ | constants.CAP_FS_WRITE | constants.CAP_SPAWN |
            constants.CAP_NET | constants.CAP_PERSIST | constants.CAP_AMBIENT |
            constants.CAP_SCRATCH | constants.CAP_MOUNT };
    }

    /// No capabilities.
    pub fn none() Capabilities {
        return .{ .bits = 0 };
    }

    pub fn fromBits(bits: u8) Capabilities {
        return .{ .bits = bits };
    }

    pub fn has(self: Capabilities, cap: u8) bool {
        return self.bits & cap != 0;
    }

    /// Intersection — the only way capabilities combine at exec. The result holds a
    /// capability iff *both* operands do, so it is always a subset of each.
    pub fn intersect(self: Capabilities, other: Capabilities) Capabilities {
        return .{ .bits = self.bits & other.bits };
    }

    /// Return this set with `cap` removed (narrowing for a child).
    pub fn without(self: Capabilities, cap: u8) Capabilities {
        return .{ .bits = self.bits & ~cap };
    }
};

/// A named capability tier. A binary declares one in its `mc_tier` custom section; a
/// parent MAY request one when spawning a child. Both are intersected with the parent's
/// live capabilities at exec.
pub const Tier = enum {
    /// Everything: file read/write, spawn, network, persistence, and the ambient host
    /// authorities (clock, entropy, namespace mutation).
    full,
    /// File read/write plus ambient *observation* (clock, entropy) — no spawn, network,
    /// persistence, or namespace mutation.
    read_write,
    /// File reads plus ambient *observation* (clock, entropy) — no mutation of any kind.
    /// An observer.
    read_only,
    /// Reads confined to the cwd subtree at exec time; no ambient authorities. The sole
    /// fully deterministic tier.
    isolated,

    /// Parse a tier name (the `mc_tier` section payload / a spawn argument).
    pub fn parse(s: []const u8) ?Tier {
        if (std.mem.eql(u8, s, "full")) return .full;
        if (std.mem.eql(u8, s, "read-write")) return .read_write;
        if (std.mem.eql(u8, s, "read-only")) return .read_only;
        if (std.mem.eql(u8, s, "isolated")) return .isolated;
        return null;
    }

    /// Decode a tier from the `mc_sys_spawn` argument, using the encodings projected
    /// from the contract. `TIER_INHERIT` (0) — or anything unrecognized — means
    /// "inherit, do not narrow".
    pub fn fromArg(n: i32) ?Tier {
        return switch (n) {
            constants.TIER_FULL => .full,
            constants.TIER_READ_WRITE => .read_write,
            constants.TIER_READ_ONLY => .read_only,
            constants.TIER_ISOLATED => .isolated,
            else => null,
        };
    }

    /// The capability ceiling this tier permits — GENERATED from `contracts/constants.kdl`
    /// (`tier-caps`, projected via `constants_zig.tier_caps`), so this kernel and the Rust
    /// kernel grant IDENTICAL ceilings (a parity invariant) with no hand-maintained
    /// duplicate.
    pub fn caps(self: Tier) Capabilities {
        const ordinal: i32 = switch (self) {
            .full => constants.TIER_FULL,
            .read_write => constants.TIER_READ_WRITE,
            .read_only => constants.TIER_READ_ONLY,
            .isolated => constants.TIER_ISOLATED,
        };
        return Capabilities.fromBits(constants.tier_caps(ordinal));
    }

    /// Whether this tier confines filesystem access to the cwd subtree.
    pub fn confines(self: Tier) bool {
        return self == .isolated;
    }
};

/// Why a task is parked. Carries a raw, stable `*Pipe` (pipes are heap-allocated by the
/// scheduler, §2.6, so the pointer outlives the block) rather than the oracle's
/// `usize`-cast address — Zig has no borrow-checker reason to launder it through an
/// integer.
pub const BlockReason = union(enum) {
    pipe_read: *pipe.Pipe,
    pipe_write: *pipe.Pipe,
    svc_recv: *registry.ServiceChannel,
    wait_child: TaskId,
    timer: i64,
};

pub const TaskState = union(enum) {
    ready,
    running,
    blocked: BlockReason,
    zombie,
};

pub const Task = struct {
    id: TaskId,
    parent_id: ?TaskId,
    /// Owned (duped at `create`).
    name: []const u8,
    state: TaskState = .ready,

    /// Owned (duped at `create`/`setCwd`).
    cwd: []const u8,
    exit_code: ?i32 = null,

    /// Owned (duped at `create`).
    command: []const u8,
    /// Owned: the outer slice and every element are duped at `create`.
    args: []const []const u8,

    /// Capability set governing privileged syscalls. `create` grants `Capabilities.all()`
    /// unconditionally (matching the oracle's `Task::new`); `Scheduler.installTask` then
    /// overwrites it with the parent's live set when there is a parent. Narrowed at exec
    /// (syscall layer, not here). Plain field — assign directly, no owned storage.
    caps: Capabilities = .{ .bits = 0 },

    /// Filesystem confinement root for the `isolated` tier: when non-null, the task may
    /// only touch paths at or under this root. Owned (duped) — mutate through
    /// `setConfineRoot`, never by direct assignment. Inherited and only tightened.
    confine_root: ?[]const u8 = null,

    /// Frozen (`stop`ped) by a `/proc/[pid]/ctl` `stop` command. A frozen task stays in
    /// its queue but the scheduler skips it until a `cont`. Orthogonal to
    /// ready/blocked/zombie state.
    frozen: bool = false,

    /// Scheduling niceness (POSIX-style, `-20..=19`; default 0). Higher = lower priority.
    /// Priority is RELATIVE: a task is deprioritized in proportion to how far its niceness
    /// exceeds the lowest niceness among the ready tasks. Inherited across spawn.
    nice: i8 = 0,

    /// Cooperative-scheduler bookkeeping for `nice`: how many more scheduling rounds this
    /// task is skipped before its next step. Realizes priority without ever stepping a
    /// task twice in a round; reloads to a niceness-derived quota when it reaches zero.
    skip_credit: u16 = 0,

    /// Opaque wasm3 guest-runtime handle, owned and interpreted by guest.zig (a different
    /// file — no wasm/interpreter logic lives here). `null` for pid 1 (the shell, which
    /// runs inline in `mc_tick`) and for a task with no guest instantiated yet. Tearing
    /// down the wasm3 instance behind a non-null `guest` around exit is guest.zig's
    /// responsibility, not the scheduler's (see `Scheduler.exitTask`).
    guest: ?*anyopaque = null,

    /// Monotonic-ms deadline for a timed blocking syscall (`sleep_ms`). The pending
    /// syscall owns clearing it when the deadline is observed or the sleep is interrupted.
    timed_deadline: ?i64 = null,

    /// Per-task fd table. Indices 0/1/2 are the conventional stdin/stdout/stderr slots
    /// (pre-seeded `.none` by `create`); indices 3+ are opened by open/pipe/dup and grow
    /// lazily. A closed slot reverts to `.none` and may be reused by a later `allocFd`.
    fds: std.ArrayListUnmanaged(Fd) = .empty,

    /// Process group id for job control. A task starts in its parent's group; the shell
    /// `setpgid`s a foreground/background pipeline into its own group so terminal signals
    /// (Ctrl-C / Ctrl-Z) can target the running job without hitting the shell. The root
    /// shell leads group 1.
    pgid: TaskId,

    /// Pending-signal bitset: bit `n` set ⇒ signal `n` awaits delivery. Drained by
    /// `Scheduler.processSignals` at a safe point (never mid-step).
    pending_signals: u32 = 0,

    /// Disposition bitset: bit `n` set ⇒ signal `n` is *ignored* (`SIG_IGN`). Cleared bit
    /// ⇒ the default action. There are no async handlers in a cooperative wasm guest, so
    /// these two dispositions are the whole model.
    sig_ignored: u32 = 0,

    /// True while this task is stopped by `SIGTSTP` (Ctrl-Z), as opposed to the `/proc`
    /// `frozen` freeze. `waitpid` reports the transition once so the shell can record a
    /// stopped job and return to its prompt; `SIGCONT` clears it. Both flags independently
    /// keep the task off the run queue.
    sig_stopped: bool = false,

    /// Latch so a stop is reported to `waitpid` exactly once (until the next stop). Set
    /// when `sig_stopped` goes true, cleared once a wait observes it.
    stop_reported: bool = false,

    /// This task's environment (the `/env` view). Owned keys/values — duped on insert,
    /// freed on remove/destroy (the memfs.zig idiom). Copied from the parent at spawn
    /// (POSIX inheritance, via `cloneEnvFrom`), then private: a temporary `FOO=bar cmd`
    /// assignment reaches only `cmd`, never sibling/background tasks.
    env: std.StringHashMapUnmanaged([]const u8) = .{},

    /// Heap-allocate a task with a stable address (`gpa.create`) — the scheduler's map
    /// stores the resulting `*Task`, so identity survives map growth/rehashing.
    /// `name`/`command`/`cwd`/`args` are duped so the caller's buffers may be transient.
    /// `pgid` defaults to the task's own id (own group by default; `installTask`
    /// overwrites it with the parent's group when there is a parent).
    pub fn create(
        gpa: std.mem.Allocator,
        id: TaskId,
        parent_id: ?TaskId,
        name: []const u8,
        command: []const u8,
        args: []const []const u8,
        cwd: []const u8,
    ) *Task {
        const self = gpa.create(Task) catch @panic("OOM");
        const owned_args = gpa.alloc([]const u8, args.len) catch @panic("OOM");
        for (args, 0..) |a, i| owned_args[i] = gpa.dupe(u8, a) catch @panic("OOM");
        self.* = .{
            .id = id,
            .parent_id = parent_id,
            .name = gpa.dupe(u8, name) catch @panic("OOM"),
            .cwd = gpa.dupe(u8, cwd) catch @panic("OOM"),
            .command = gpa.dupe(u8, command) catch @panic("OOM"),
            .args = owned_args,
            .caps = Capabilities.all(),
            .pgid = id,
        };
        self.fds.appendNTimes(gpa, .none, 3) catch @panic("OOM");
        return self;
    }

    /// Free everything this task owns, including releasing any pipe ends still sitting in
    /// the fd table (mirrors the oracle's automatic `Drop` cascade through `Box<Task>`,
    /// which runs `PipeSource`/`PipeSink`'s `Drop` for any fd a task never explicitly
    /// closed before exiting). Called by `Scheduler.reapZombie`.
    pub fn destroy(self: *Task, gpa: std.mem.Allocator) void {
        for (self.fds.items) |fd| {
            switch (fd) {
                .pipe_read => |p| p.closeRead(),
                .pipe_write => |p| p.closeWrite(),
                .file => |fh| fh.close(),
                .net => |src| src.release(),
                .ws => |src| src.release(),
                .host_call => |src| src.release(),
                .serve => |owner| owner.release(),
                .svc_serve => |owner| owner.release(),
                .svc_conn => |conn| conn.release(),
                .svc_call => |src| src.release(),
                .none => {},
            }
        }
        self.fds.deinit(gpa);

        var it = self.env.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.env.deinit(gpa);

        for (self.args) |a| gpa.free(a);
        gpa.free(self.args);

        gpa.free(self.name);
        gpa.free(self.command);
        gpa.free(self.cwd);
        if (self.confine_root) |root| gpa.free(root);

        gpa.destroy(self);
    }

    // ── job control / signals ──────────────────────────────────────────────────────────

    /// True iff this task is runnable-blocked from the scheduler's view: a `SIGTSTP` stop
    /// or a `/proc` freeze both keep it off the ready queue.
    pub fn isStopped(self: *const Task) bool {
        return self.frozen or self.sig_stopped;
    }

    /// Set/clear the `SIGTSTP` stop flag. Entering the stopped state arms the one-shot
    /// `waitpid` report; leaving it disarms it.
    pub fn setSigStopped(self: *Task, stopped: bool) void {
        self.sig_stopped = stopped;
        self.stop_reported = !stopped;
    }

    /// Consume the one-shot "this task just stopped" report. Returns true the first time
    /// it is called after a stop, then false until the next stop.
    pub fn takeStopReport(self: *Task) bool {
        if (self.sig_stopped and !self.stop_reported) {
            self.stop_reported = true;
            return true;
        }
        return false;
    }

    /// Mark signal `sig` (1..=31) pending on this task.
    pub fn raiseSignal(self: *Task, sig: i32) void {
        if (sig >= 1 and sig < 32) self.pending_signals |= @as(u32, 1) << @intCast(sig);
    }

    /// True iff signal `sig` is currently pending.
    pub fn signalPending(self: *const Task, sig: i32) bool {
        if (sig < 1 or sig >= 32) return false;
        return self.pending_signals & (@as(u32, 1) << @intCast(sig)) != 0;
    }

    /// Clear signal `sig` from the pending set.
    pub fn clearSignal(self: *Task, sig: i32) void {
        if (sig >= 1 and sig < 32) self.pending_signals &= ~(@as(u32, 1) << @intCast(sig));
    }

    /// Whether `sig`'s disposition is "ignore" (`SIG_IGN`).
    pub fn signalIgnored(self: *const Task, sig: i32) bool {
        if (sig < 1 or sig >= 32) return false;
        return self.sig_ignored & (@as(u32, 1) << @intCast(sig)) != 0;
    }

    /// Set signal `sig`'s disposition: `true` = ignore, `false` = default.
    pub fn setSignalIgnored(self: *Task, sig: i32, ignored: bool) void {
        if (sig < 1 or sig >= 32) return;
        const mask = @as(u32, 1) << @intCast(sig);
        if (ignored) self.sig_ignored |= mask else self.sig_ignored &= ~mask;
    }

    // ── environment ─────────────────────────────────────────────────────────────────────

    /// Replace this task's environment with an owned deep copy of `parent`'s (POSIX
    /// inheritance at spawn): a child sees the parent's env, but later mutations don't
    /// cross between processes. Only meaningful right after `create` (self.env starts
    /// empty).
    pub fn cloneEnvFrom(self: *Task, gpa: std.mem.Allocator, parent: *std.StringHashMapUnmanaged([]const u8)) void {
        var it = parent.iterator();
        while (it.next()) |entry| {
            const k = gpa.dupe(u8, entry.key_ptr.*) catch @panic("OOM");
            const v = gpa.dupe(u8, entry.value_ptr.*) catch @panic("OOM");
            self.env.put(gpa, k, v) catch @panic("OOM");
        }
    }

    // ── cwd / confinement (owned strings — mutate through these, not direct assignment) ─

    pub fn setCwd(self: *Task, gpa: std.mem.Allocator, new_cwd: []const u8) void {
        const owned = gpa.dupe(u8, new_cwd) catch @panic("OOM");
        gpa.free(self.cwd);
        self.cwd = owned;
    }

    /// Replace this task's filesystem confinement root (used at spawn to inherit).
    pub fn setConfineRoot(self: *Task, gpa: std.mem.Allocator, new_root: ?[]const u8) void {
        const owned = if (new_root) |r| gpa.dupe(u8, r) catch @panic("OOM") else null;
        if (self.confine_root) |old| gpa.free(old);
        self.confine_root = owned;
    }

    // ── fd table ────────────────────────────────────────────────────────────────────────

    /// Look up fd `n`; `.none` for an out-of-range or never-opened slot.
    pub fn getFd(self: *const Task, fd: usize) Fd {
        if (fd >= self.fds.items.len) return .none;
        return self.fds.items[fd];
    }

    /// Set fd `n` directly (growing the table with `.none` padding as needed). Used for
    /// the standard-stream slots (0/1/2) and for `dup2`-style exact-fd installs.
    pub fn setFd(self: *Task, gpa: std.mem.Allocator, fd: usize, value: Fd) void {
        while (self.fds.items.len <= fd) self.fds.append(gpa, .none) catch @panic("OOM");
        self.fds.items[fd] = value;
    }

    /// Allocate the next free slot at index ≥ 3 (0/1/2 stay reserved for stdin/stdout/
    /// stderr) and store `value` there. Returns the fd number — mirrors the oracle's
    /// `alloc_fd`, which likewise always returns ≥ 3.
    pub fn allocFd(self: *Task, gpa: std.mem.Allocator, value: Fd) usize {
        var i: usize = 3;
        while (i < self.fds.items.len) : (i += 1) {
            if (self.fds.items[i] == .none) {
                self.fds.items[i] = value;
                return i;
            }
        }
        while (self.fds.items.len < 3) self.fds.append(gpa, .none) catch @panic("OOM");
        self.fds.append(gpa, value) catch @panic("OOM");
        return self.fds.items.len - 1;
    }

    /// Close fd `n`: release any pipe end it holds (so the peer sees EOF / can observe a
    /// broken pipe) or free a file handle, then revert the slot to `.none`. No-op for an
    /// out-of-range fd. Unlike the oracle, this treats 0/1/2 uniformly with the rest of
    /// the table (there is no separate typed accessor to bypass it through) — call
    /// `closeFd(0)`/`closeFd(1)`/`closeFd(2)` where the oracle calls
    /// `close_stdin`/`close_stdout`/`close_stderr`.
    pub fn closeFd(self: *Task, fd: usize) void {
        if (fd >= self.fds.items.len) return;
        switch (self.fds.items[fd]) {
            .pipe_read => |p| p.closeRead(),
            .pipe_write => |p| p.closeWrite(),
            .file => |fh| fh.close(),
            .net => |src| src.release(),
            .ws => |src| src.release(),
            .host_call => |src| src.release(),
            .serve => |owner| owner.release(),
            .svc_serve => |owner| owner.release(),
            .svc_conn => |conn| conn.release(),
            .svc_call => |src| src.release(),
            .none => {},
        }
        self.fds.items[fd] = .none;
    }
};
