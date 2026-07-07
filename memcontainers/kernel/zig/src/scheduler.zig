//! scheduler.zig — cooperative ready/running/blocked/zombie transitions, ticks,
//! waitpid, and wakeups (ZIG_KERNEL §2.3, §4.1).
//!
//! Owns: the run queues, the per-tick stepping of pid 1 + child guests, block/unblock on
//!   pipe read/write and child wait, waitpid semantics, foreground/background job
//!   control, zombie reaping, and the wakeups that resume Asyncify-suspended guests.
//! Invariants: A7 (scheduler decisions, retry ordering, and service activation are
//!   replayable). Deterministic ordering is contractual — tests observe it. A tick never
//!   monopolizes the host; a suspended guest is just a blocked task (§2.1).
//! Consumes: task.zig (identities/fd/caps), guest.zig (step a guest's wasm3 runtime),
//!   ipc/pipe.zig (block reasons).
//! Not here: task identity/allocation (task.zig); the wasm3 driver + Asyncify boundary
//!   (guest.zig); pipe ring buffers (ipc/pipe.zig). The scheduler owns WHEN a task runs,
//!   not HOW a guest executes.
//!
//! Scaffold status: implemented (Phase 4). Oracle: kernel/rust/src/task/scheduler.rs —
//! ported faithfully modulo the single-threaded simplification (SYSTEMS.md): every
//! `UnsafeCell` accessor collapses to a plain field; the task map is
//! `AutoHashMapUnmanaged(TaskId, *Task)`, a direct translation of the oracle's own
//! `BTreeMap<TaskId, Box<Task>>` (a heap box per id), not a novel scheme. `ready`/
//! `zombies` are `ArrayListUnmanaged(TaskId)` used as an explicit FIFO/set — this
//! codebase has no deque container; `popReadyFront`'s `orderedRemove(0)` is O(n),
//! acceptable at cooperative-kernel task counts. `Scheduler` is a plain value
//! (`init(gpa) Scheduler`), matching `vfs.Namespace`'s convention — state.zig hangs it
//! off `Kernel` as a field, not a heap pointer. `allocPipe`/`dropDeadPipes` are ported
//! even though the integration brief's method list didn't spell them out by name: that
//! same brief's "owned pipes" is exactly what they implement, and ipc/pipe.zig's pipes
//! must be created and eventually freed by SOMETHING. `get_task`/`get_task_mut` collapse
//! to one `getTask` (no borrow checker to appease). Not ported: the oracle's
//! `blocked_reader`/`blocked_writer` single-slot `Pipe` fields (dead code there too — see
//! ipc/pipe.zig's header) and anything that steps a guest (guest.zig's job — this file
//! decides WHEN, guest.zig decides HOW).

const std = @import("std");
const task_mod = @import("task.zig");
const pipe = @import("ipc/pipe.zig");
const constants = @import("constants_zig");
const bridge = @import("bridge.zig");

const Task = task_mod.Task;
const TaskId = task_mod.TaskId;
const BlockReason = task_mod.BlockReason;
const Capabilities = task_mod.Capabilities;
const Pipe = pipe.Pipe;
const READY_CAPACITY_HINT: usize = 4096;

pub const Scheduler = struct {
    gpa: std.mem.Allocator,

    /// Task storage — heap-allocated `Task`s (stable address; see task.zig's header)
    /// keyed by id.
    tasks: std.AutoHashMapUnmanaged(TaskId, *Task) = .{},

    /// FIFO run queue of ready task ids (push back / pop front — see `popReadyFront`).
    ready: std.ArrayListUnmanaged(TaskId) = .empty,
    blocked: std.AutoHashMapUnmanaged(TaskId, BlockReason) = .{},
    zombies: std.ArrayListUnmanaged(TaskId) = .empty,

    /// Pipes this scheduler owns; heap-allocated with stable addresses (§2.6) —
    /// `BlockReason` and a task's fd-table entries hold raw `*Pipe` into this set.
    pipes: std.ArrayListUnmanaged(*Pipe) = .empty,

    next_id: TaskId = 1,

    /// The pid of the task currently being stepped, if any.
    current: ?TaskId = null,

    /// The terminal's foreground process group (job control). Terminal signals (Ctrl-C →
    /// SIGINT, Ctrl-Z → SIGTSTP) are delivered to this group. The login shell leads group
    /// 1 and `tcsetpgrp`s a foreground job into focus. Plain field — read/write directly
    /// (`mc_sys_tcsetpgrp` just assigns it).
    foreground_pgid: TaskId = 1,

    pub fn init(gpa: std.mem.Allocator) Scheduler {
        var self = Scheduler{ .gpa = gpa };
        self.ready.ensureTotalCapacity(gpa, READY_CAPACITY_HINT) catch @panic("OOM");
        return self;
    }

    /// Spawn a new task with the next free id and enqueue it.
    pub fn spawn(
        self: *Scheduler,
        parent_id: ?TaskId,
        name: []const u8,
        command: []const u8,
        args: []const []const u8,
        cwd: []const u8,
    ) TaskId {
        const id = self.next_id;
        self.next_id += 1;
        self.installTask(id, parent_id, name, command, args, cwd);
        return id;
    }

    /// Spawn a task occupying a SPECIFIC id (e.g. reusing pid 1 when the login shell is
    /// respawned, so `/proc/1` never disappears). Returns `null` if `id` is already live.
    /// `next_id` is advanced past `id` so later ordinary spawns can never collide with
    /// the reused id.
    pub fn spawnWithId(
        self: *Scheduler,
        id: TaskId,
        parent_id: ?TaskId,
        name: []const u8,
        command: []const u8,
        args: []const []const u8,
        cwd: []const u8,
    ) ?TaskId {
        if (self.tasks.contains(id)) return null;
        self.installTask(id, parent_id, name, command, args, cwd);
        self.next_id = @max(self.next_id, id + 1);
        return id;
    }

    /// Build and enqueue a task at `id`, inheriting policy from its parent. The shared
    /// core of `spawn`/`spawnWithId`.
    fn installTask(
        self: *Scheduler,
        id: TaskId,
        parent_id: ?TaskId,
        name: []const u8,
        command: []const u8,
        args: []const []const u8,
        cwd: []const u8,
    ) void {
        const t = Task.create(self.gpa, id, parent_id, name, command, args, cwd);
        // A child inherits its parent's capabilities and confinement (it may only be
        // narrowed, never widened — exec applies any further narrowing, elsewhere).
        // Roots default to the full set, unconfined (Task.create's default).
        if (parent_id) |pid| {
            if (self.getTask(pid)) |parent| {
                t.caps = parent.caps;
                t.setConfineRoot(self.gpa, parent.confine_root);
                // A child starts in its parent's process group (POSIX); the shell
                // `setpgid`s a job into its own group afterwards.
                t.pgid = parent.pgid;
                // POSIX environment inheritance: copy (not share) the parent's env so a
                // child sees it but later mutations don't cross between processes.
                t.cloneEnvFrom(self.gpa, &parent.env);
                // Scheduling niceness is inherited across spawn (POSIX); a child of
                // `nice` therefore runs at the adjusted priority.
                t.nice = parent.nice;
                // Signal dispositions are inherited across spawn, so a `nohup` parent's
                // SIGHUP-ignore reaches the child — EXCEPT the terminal job-control
                // signals SIGINT/SIGTSTP, which reset to default in the child. The login
                // shell ignores those on itself; without this carve-out every job would
                // inherit the ignore and Ctrl-C / Ctrl-Z would stop reaching foreground
                // jobs.
                const sigint_bit: u32 = @as(u32, 1) << @intCast(constants.SIGINT);
                const sigtstp_bit: u32 = @as(u32, 1) << @intCast(constants.SIGTSTP);
                t.sig_ignored = parent.sig_ignored & ~sigint_bit & ~sigtstp_bit;
            }
        }

        self.tasks.put(self.gpa, id, t) catch @panic("OOM");
        self.ready.append(self.gpa, id) catch @panic("OOM");
    }

    /// Remove every occurrence of `id` from the ready queue (there is normally at most
    /// one). Zig has no deque `retain`, so this is the explicit equivalent.
    fn removeFromReady(self: *Scheduler, id: TaskId) void {
        var i: usize = 0;
        while (i < self.ready.items.len) {
            if (self.ready.items[i] == id) {
                _ = self.ready.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn isReadyQueued(self: *Scheduler, id: TaskId) bool {
        for (self.ready.items) |queued| {
            if (queued == id) return true;
        }
        return false;
    }

    fn compactReadyQueue(self: *Scheduler) void {
        var write: usize = 0;
        var read: usize = 0;
        while (read < self.ready.items.len) : (read += 1) {
            const id = self.ready.items[read];
            const t = self.getTask(id) orelse continue;
            if (t.state == .zombie) continue;
            var seen = false;
            var j: usize = 0;
            while (j < write) : (j += 1) {
                if (self.ready.items[j] == id) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            self.ready.items[write] = id;
            write += 1;
        }
        self.ready.items.len = write;
    }

    fn enqueueReadyIfLive(self: *Scheduler, id: TaskId) void {
        const t = self.getTask(id) orelse return;
        if (t.state == .zombie) return;
        if (t.state == .ready) return;
        if (!self.isReadyQueued(id)) {
            if (self.ready.items.len >= self.ready.capacity) self.compactReadyQueue();
            if (self.ready.items.len >= self.ready.capacity) return;
            t.state = .ready;
            self.ready.appendAssumeCapacity(id);
        } else {
            t.state = .ready;
        }
    }

    /// Detach a task from the ready queue and mark it Running. Used for pid 1 (the
    /// shell), which lives inside `mc_tick` and must not be reachable by
    /// `Scheduler.popReady`.
    pub fn detach(self: *Scheduler, id: TaskId) void {
        self.removeFromReady(id);
        if (self.getTask(id)) |t| t.state = .running;
    }

    /// Allocate a fresh pipe owned by the scheduler. The returned pointer is stable for
    /// the lifetime of the scheduler (until `dropDeadPipes` frees it).
    pub fn allocPipe(self: *Scheduler) *Pipe {
        const p = Pipe.create(self.gpa);
        self.pipes.append(self.gpa, p) catch @panic("OOM");
        return p;
    }

    /// Drop pipes that are closed on both ends and no task is parked on. Called from the
    /// reaper after every pipeline drains.
    pub fn dropDeadPipes(self: *Scheduler) void {
        var i: usize = 0;
        outer: while (i < self.pipes.items.len) {
            const p = self.pipes.items[i];
            if (p.isReadClosed() and p.isWriteClosed()) {
                var it = self.blocked.valueIterator();
                while (it.next()) |reason_ptr| {
                    const referenced = switch (reason_ptr.*) {
                        .pipe_read => |rp| rp == p,
                        .pipe_write => |wp| wp == p,
                        .svc_recv => false,
                        .wait_child => false,
                        .timer => false,
                    };
                    if (referenced) {
                        i += 1;
                        continue :outer;
                    }
                }
                _ = self.pipes.orderedRemove(i);
                self.gpa.destroy(p);
            } else {
                i += 1;
            }
        }
    }

    /// Look up a task by id. Collapses the oracle's `get_task`/`get_task_mut` split
    /// (shared vs. exclusive borrow) into one accessor — Zig has no borrow checker to
    /// appease, and the map already stores a plain `*Task`.
    pub fn getTask(self: *Scheduler, id: TaskId) ?*Task {
        return self.tasks.get(id);
    }

    /// Install the capability policy a task is `exec`'d with.
    pub fn setTaskPolicy(self: *Scheduler, id: TaskId, caps: Capabilities, confine_root: ?[]const u8) void {
        if (self.getTask(id)) |t| {
            t.caps = caps;
            t.setConfineRoot(self.gpa, confine_root);
        }
    }

    /// Snapshot all live task IDs into `arena` (used by procfs to enumerate /proc/[pid]).
    pub fn taskIds(self: *Scheduler, arena: std.mem.Allocator) []TaskId {
        var out: std.ArrayListUnmanaged(TaskId) = .empty;
        var it = self.tasks.keyIterator();
        while (it.next()) |k| out.append(arena, k.*) catch @panic("OOM");
        return out.items;
    }

    pub fn currentTask(self: *Scheduler) ?*Task {
        const id = self.current orelse return null;
        return self.getTask(id);
    }

    /// Park the currently-running task on `reason`.
    pub fn blockCurrent(self: *Scheduler, reason: BlockReason) void {
        const id = self.current orelse return;
        self.blocked.put(self.gpa, id, reason) catch @panic("OOM");
        if (self.getTask(id)) |t| t.state = .{ .blocked = reason };
        self.current = null;
    }

    /// Park a specific task by id on `reason`. Used when a stepped task reports it must
    /// wait on a pipe.
    pub fn blockTask(self: *Scheduler, id: TaskId, reason: BlockReason) void {
        self.removeFromReady(id);
        self.blocked.put(self.gpa, id, reason) catch @panic("OOM");
        if (self.getTask(id)) |t| t.state = .{ .blocked = reason };
        if (self.current) |cur| {
            if (cur == id) self.current = null;
        }
    }

    /// Return a task that ran a step but did not finish (it has no pipe behind the
    /// stream it reported blocked on, so it is not truly parked) to the back of the
    /// ready queue. Clears `current`.
    pub fn requeue(self: *Scheduler, id: TaskId) void {
        self.enqueueReadyIfLive(id);
        if (self.current) |cur| {
            if (cur == id) self.current = null;
        }
    }

    pub fn unblock(self: *Scheduler, id: TaskId) void {
        if (self.blocked.fetchRemove(id) != null) {
            self.enqueueReadyIfLive(id);
        }
    }

    /// Mark task as exited (zombie state).
    pub fn exitTask(self: *Scheduler, id: TaskId, exit_code: i32) void {
        self.removeFromReady(id);
        _ = self.blocked.remove(id);
        self.zombies.append(self.gpa, id) catch @panic("OOM");

        if (self.getTask(id)) |t| {
            t.state = .zombie;
            t.exit_code = exit_code;
        }

        if (self.current) |cur| {
            if (cur == id) self.current = null;
        }

        // Reparent this task's children to pid 1 (init), POSIX-style, so they are not
        // left with a dangling parent id once this task is reaped — and so a session
        // hangup delivered to pid 1's group can still reach a detached (`nohup`'d)
        // grandchild.
        var orphans: std.ArrayListUnmanaged(TaskId) = .empty;
        defer orphans.deinit(self.gpa);
        {
            var it = self.tasks.valueIterator();
            while (it.next()) |tp| {
                const child = tp.*;
                if (child.parent_id != null and child.parent_id.? == id and child.id != id) {
                    orphans.append(self.gpa, child.id) catch @panic("OOM");
                }
            }
        }
        for (orphans.items) |cid| {
            if (self.getTask(cid)) |c| c.parent_id = 1;
        }

        // If a parent was waiting on this child, wake it.
        if (self.getTask(id)) |t| {
            if (t.parent_id) |parent_id| {
                if (self.blocked.get(parent_id)) |reason| {
                    switch (reason) {
                        .wait_child => |child_id| if (child_id == id) self.unblock(parent_id),
                        else => {},
                    }
                }
            }
        }

        // A parentless task (a resident service; pid 1 is the exception) has no one to
        // waitpid its zombie — so the kernel is its reaper of last resort, reaping it on
        // the spot rather than leaking it into the scheduler and /proc until the name is
        // next re-activated.
        const parentless = if (self.getTask(id)) |t| t.parent_id == null else false;
        if (parentless and id != 1) {
            self.reapZombie(id);
        }
    }

    pub fn getExitCode(self: *Scheduler, id: TaskId) ?i32 {
        const t = self.getTask(id) orelse return null;
        return t.exit_code;
    }

    /// Pop the next ready task and mark it Running. Bounded by the queue length so an
    /// all-frozen/all-stopped ready queue returns `null` rather than spinning.
    fn popReadyFront(self: *Scheduler) ?TaskId {
        if (self.ready.items.len == 0) return null;
        return self.ready.orderedRemove(0);
    }

    /// Pop the next ready task and mark it Running. Skips frozen (`stop`ped) / SIGTSTP-
    /// stopped tasks: rotates them to the back and tries the next, bounded by the queue
    /// length.
    pub fn popReady(self: *Scheduler) ?TaskId {
        const n = self.ready.items.len;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const id = self.popReadyFront() orelse return null;
            const t = self.getTask(id) orelse continue;
            if (t.state == .zombie) continue;
            if (t.isStopped()) {
                self.enqueueReadyIfLive(id);
                continue;
            }
            self.current = id;
            t.state = .running;
            return id;
        }
        return null;
    }

    /// Forcibly terminate `id` (a `/proc/[pid]/ctl` `kill`). Reuses the ordinary exit
    /// path after closing every fd-owning object immediately, so a killed task cannot
    /// keep pipes alive until reap.
    pub fn killTask(self: *Scheduler, id: TaskId, exit_code: i32) void {
        if (self.getTask(id)) |t| {
            // A stopped task can still be killed (e.g. `kill %1` on a Ctrl-Z'd job):
            // clear the stop so it lands as a normal zombie.
            t.setSigStopped(false);
            t.closeFd(1); // stdout
            t.closeFd(0); // stdin
            t.closeFd(2); // stderr
            // Tearing down the wasm3 instance behind `t.guest` (if any) is guest.zig's
            // responsibility — not touched here (see task.zig's `guest` field doc).
        }
        self.exitTask(id, exit_code);
    }

    /// Freeze (`stop`) or unfreeze (`cont`) a task.
    pub fn setFrozen(self: *Scheduler, id: TaskId, frozen: bool) void {
        if (self.getTask(id)) |t| t.frozen = frozen;
    }

    /// Put task `id` in process group `pgid` (`mc_sys_setpgid`; `pgid == 0` means "use
    /// the task's own pid", making it a group leader).
    pub fn setPgid(self: *Scheduler, id: TaskId, pgid: TaskId) void {
        if (self.getTask(id)) |t| t.pgid = if (pgid == 0) id else pgid;
    }

    /// Deliver signal `sig` to task `id`: mark it pending and, unless `id` is the task
    /// currently mid-step (terminating it under its own feet is unsafe), apply it now.
    /// The running task's signals are applied at its next step boundary via
    /// `processSignals` (called from whatever drives stepping).
    pub fn deliverSignal(self: *Scheduler, id: TaskId, sig: i32) void {
        const exists = if (self.getTask(id)) |t| t.state != .zombie else false;
        if (!exists) return;
        if (self.getTask(id)) |t| t.raiseSignal(sig);
        const is_current = if (self.current) |cur| cur == id else false;
        if (!is_current) _ = self.processSignals(id);
    }

    /// Deliver `sig` to every (live) task in process group `pgid`.
    pub fn signalGroup(self: *Scheduler, pgid: TaskId, sig: i32) void {
        var ids: std.ArrayListUnmanaged(TaskId) = .empty;
        defer ids.deinit(self.gpa);
        var it = self.tasks.valueIterator();
        while (it.next()) |tp| {
            const t = tp.*;
            if (t.pgid == pgid and t.state != .zombie) ids.append(self.gpa, t.id) catch @panic("OOM");
        }
        for (ids.items) |id| self.deliverSignal(id, sig);
    }

    /// Deliver `sig` to every live task except `except`. Used on login-shell exit to
    /// hang up the whole session: the login shell (pid 1) is the root of the entire
    /// process tree, so every other live task is a session member — and background jobs
    /// sit in their own process groups, so a single `signalGroup` would miss them.
    pub fn signalAllExcept(self: *Scheduler, except: TaskId, sig: i32) void {
        var ids: std.ArrayListUnmanaged(TaskId) = .empty;
        defer ids.deinit(self.gpa);
        var it = self.tasks.valueIterator();
        while (it.next()) |tp| {
            const t = tp.*;
            if (t.id != except and t.state != .zombie) ids.append(self.gpa, t.id) catch @panic("OOM");
        }
        for (ids.items) |id| self.deliverSignal(id, sig);
    }

    /// Apply `id`'s pending signals at a safe point. Returns `false` if the task was
    /// terminated (now a zombie) so the caller skips stepping it.
    ///
    /// Disposition model (no async handlers): a signal is either ignored (`SIG_IGN`) or
    /// takes its default action. KILL is unconditional; INT/TERM/HUP terminate
    /// (`128 + signo`); TSTP stops (frozen); CONT resumes; CHLD is dropped. An *ignored*
    /// interrupting signal is left pending so a blocked syscall can observe it as
    /// `EINTR`; if the task is parked, it is woken so that syscall re-runs.
    pub fn processSignals(self: *Scheduler, id: TaskId) bool {
        const pending = blk: {
            const t = self.getTask(id) orelse return false;
            if (t.state == .zombie) return false;
            break :blk t.pending_signals;
        };
        if (pending == 0) return true;
        const bit = struct {
            fn f(p: u32, s: i32) bool {
                return p & (@as(u32, 1) << @intCast(s)) != 0;
            }
        }.f;

        // KILL — uncatchable, un-ignorable.
        if (bit(pending, constants.SIGKILL)) {
            self.killTask(id, 128 + constants.SIGKILL);
            return false;
        }
        // CONT — resume a SIGTSTP-stopped task.
        if (bit(pending, constants.SIGCONT)) {
            if (self.getTask(id)) |t| {
                t.clearSignal(constants.SIGCONT);
                t.setSigStopped(false);
            }
        }
        // Terminating signals (default action) or, when ignored, EINTR fodder.
        var woke_for_eintr = false;
        for ([_]i32{ constants.SIGINT, constants.SIGTERM, constants.SIGHUP }) |sig| {
            if (!bit(pending, sig)) continue;
            const ignored = if (self.getTask(id)) |t| t.signalIgnored(sig) else true;
            if (ignored) {
                // Leave it pending for the next blocking syscall to consume as EINTR;
                // wake a parked task so that syscall actually re-runs.
                const blocked = if (self.getTask(id)) |t| (t.state == .blocked) else false;
                if (blocked) woke_for_eintr = true;
            } else {
                self.killTask(id, 128 + sig);
                return false;
            }
        }
        // TSTP — terminal stop.
        if (bit(pending, constants.SIGTSTP)) {
            const ignored = if (self.getTask(id)) |t| t.signalIgnored(constants.SIGTSTP) else true;
            if (self.getTask(id)) |t| t.clearSignal(constants.SIGTSTP);
            if (!ignored) {
                if (self.getTask(id)) |t| t.setSigStopped(true);
                // Let a parent blocked in `waitpid` on this child observe the stop
                // (Ctrl-Z job control) instead of hanging forever.
                self.wakeParentWaiter(id);
            }
        }
        // CHLD — default action is to ignore.
        if (self.getTask(id)) |t| t.clearSignal(constants.SIGCHLD);

        if (woke_for_eintr) self.unblock(id);
        return true;
    }

    /// Wake a parent parked in `waitpid` on child `id` (used when the child exits or
    /// stops). The parent re-runs `waitpid`, which then reports the child's new state.
    fn wakeParentWaiter(self: *Scheduler, id: TaskId) void {
        const t = self.getTask(id) orelse return;
        const parent_id = t.parent_id orelse return;
        const reason = self.blocked.get(parent_id) orelse return;
        switch (reason) {
            .wait_child => |child_id| if (child_id == id) self.unblock(parent_id),
            else => {},
        }
    }

    /// True iff `anc` is `desc` or one of its ancestors (a parent-id walk). Used to gate
    /// `/proc/[pid]/ctl` control: you may control only your own process subtree. Bounded
    /// against an (impossible) parent cycle.
    pub fn isAncestorOf(self: *Scheduler, anc: TaskId, desc: TaskId) bool {
        var cur: ?TaskId = desc;
        var guard: usize = 0;
        while (cur) |id| {
            if (id == anc) return true;
            cur = if (self.getTask(id)) |t| t.parent_id else null;
            guard += 1;
            if (guard > 4096) break;
        }
        return false;
    }

    /// Wake any task whose block condition is now satisfied.
    pub fn checkUnblocked(self: *Scheduler) void {
        var to_unblock: std.ArrayListUnmanaged(TaskId) = .empty;
        defer to_unblock.deinit(self.gpa);
        var it = self.blocked.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            const should_unblock = switch (entry.value_ptr.*) {
                .pipe_read => |p| p.isWriteClosed() or !p.isEmpty(),
                .pipe_write => |p| p.isReadClosed() or !p.isFull(),
                .svc_recv => |channel| channel.recvReady(),
                .wait_child => false,
                .timer => |deadline| bridge.mc_time_monotonic() >= deadline,
            };
            if (should_unblock) to_unblock.append(self.gpa, id) catch @panic("OOM");
        }
        for (to_unblock.items) |id| self.unblock(id);
    }

    pub fn readyCount(self: *Scheduler) usize {
        return self.ready.items.len;
    }

    pub fn blockedCount(self: *Scheduler) usize {
        return self.blocked.count();
    }

    pub fn hasWork(self: *Scheduler) bool {
        return self.readyCount() > 0 or self.blockedCount() > 0;
    }

    /// The lowest niceness among currently-runnable (ready, not stopped) tasks, or
    /// `i8`'s max if there are none. The cooperative scheduler deprioritizes a task
    /// RELATIVE to this floor, so a negative-nice task (which becomes the floor) makes
    /// its higher-nice peers skip — making negative niceness real, not a no-op.
    pub fn minReadyNice(self: *Scheduler) i8 {
        var min: i8 = std.math.maxInt(i8);
        var it = self.tasks.valueIterator();
        while (it.next()) |tp| {
            const t = tp.*;
            if (t.state == .ready and !t.isStopped() and t.nice < min) min = t.nice;
        }
        return min;
    }

    /// Reap a zombie task, removing it from the task map and freeing everything it owns.
    pub fn reapZombie(self: *Scheduler, id: TaskId) void {
        const is_zombie = if (self.getTask(id)) |t| t.state == .zombie else false;
        if (!is_zombie) return;

        var i: usize = 0;
        while (i < self.zombies.items.len) {
            if (self.zombies.items[i] == id) {
                _ = self.zombies.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        if (self.tasks.fetchRemove(id)) |kv| {
            kv.value.destroy(self.gpa);
        }
    }
};
