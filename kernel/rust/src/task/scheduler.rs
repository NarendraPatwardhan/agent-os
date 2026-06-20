//! The cooperative task scheduler — ready and blocked queues, the task map, pipes,
//! signals, and job-control process groups.
//!
//! `current_task`/`block_current`/the queue accessors are stable public surface for the
//! threaded mode and the wasmi integration; the live pipeline driver manages run state
//! externally and the `step()` loop drives execution rather than the scheduler. All
//! state lives behind `UnsafeCell`, sound under the single-threaded cooperative
//! discipline; `Scheduler: Sync` is asserted on that basis.

#![allow(dead_code)]

use alloc::boxed::Box;
use alloc::collections::{BTreeMap, VecDeque};
use alloc::string::String;
use alloc::vec::Vec;
use core::cell::UnsafeCell;

use super::{BlockReason, Task, TaskId, TaskState};
use crate::ipc::Pipe;
use crate::wasm::abi;

pub struct Scheduler {
    // Task storage
    tasks: UnsafeCell<BTreeMap<TaskId, Box<Task>>>,

    // Scheduling queues
    ready: UnsafeCell<VecDeque<TaskId>>,
    blocked: UnsafeCell<BTreeMap<TaskId, BlockReason>>,
    zombies: UnsafeCell<Vec<TaskId>>,

    // Pipes — boxed so each has a stable heap address (BlockReason carries raw pipe
    // pointers). Indexed only by raw pointer comparisons; the outer Vec may grow without
    // invalidating already-issued addresses.
    pipes: UnsafeCell<Vec<Box<Pipe>>>,

    // Next task ID counter
    next_id: UnsafeCell<TaskId>,

    // Currently running task
    current: UnsafeCell<Option<TaskId>>,

    // The terminal's foreground process group (job control). Terminal signals (Ctrl-C →
    // SIGINT, Ctrl-Z → SIGTSTP) are delivered to this group. The login shell leads group
    // 1 and `tcsetpgrp`s a foreground job into focus.
    foreground_pgid: UnsafeCell<TaskId>,
}

impl Scheduler {
    pub fn new() -> Self {
        Self {
            tasks: UnsafeCell::new(BTreeMap::new()),
            ready: UnsafeCell::new(VecDeque::new()),
            blocked: UnsafeCell::new(BTreeMap::new()),
            zombies: UnsafeCell::new(Vec::new()),
            pipes: UnsafeCell::new(Vec::new()),
            next_id: UnsafeCell::new(1),
            current: UnsafeCell::new(None),
            foreground_pgid: UnsafeCell::new(1),
        }
    }

    /// The terminal's current foreground process group.
    pub fn foreground_pgid(&self) -> TaskId {
        unsafe { *self.foreground_pgid.get() }
    }

    /// Make `pgid` the terminal's foreground group (`mc_sys_tcsetpgrp`).
    pub fn set_foreground_pgid(&self, pgid: TaskId) {
        unsafe {
            *self.foreground_pgid.get() = pgid;
        }
    }

    /// Spawn a new task with the next free id and enqueue it.
    pub fn spawn(
        &self,
        parent_id: Option<TaskId>,
        name: String,
        command: String,
        args: Vec<String>,
        cwd: String,
    ) -> TaskId {
        unsafe {
            let id = *self.next_id.get();
            *self.next_id.get() += 1;
            self.install_task(id, parent_id, name, command, args, cwd);
            id
        }
    }

    /// Spawn a task occupying a SPECIFIC id (e.g. reusing pid 1 when the login shell is
    /// respawned, so `/proc/1` never disappears). Returns `None` if `id` is already live.
    /// `next_id` is advanced past `id` so later ordinary spawns can never collide with
    /// the reused id.
    pub fn spawn_with_id(
        &self,
        id: TaskId,
        parent_id: Option<TaskId>,
        name: String,
        command: String,
        args: Vec<String>,
        cwd: String,
    ) -> Option<TaskId> {
        unsafe {
            if (*self.tasks.get()).contains_key(&id) {
                return None;
            }
            self.install_task(id, parent_id, name, command, args, cwd);
            let nx = &mut *self.next_id.get();
            *nx = (*nx).max(id + 1);
            Some(id)
        }
    }

    /// Build and enqueue a task at `id`, inheriting policy from its parent. The shared
    /// core of [`spawn`]/[`spawn_with_id`].
    unsafe fn install_task(
        &self,
        id: TaskId,
        parent_id: Option<TaskId>,
        name: String,
        command: String,
        args: Vec<String>,
        cwd: String,
    ) {
        unsafe {
            let mut task = Box::new(Task::new(id, parent_id, name, command, args, cwd));
            // A child inherits its parent's capabilities and confinement (it may only be
            // narrowed, never widened — exec applies any further narrowing). Roots default
            // to the full set, unconfined.
            if let Some(pid) = parent_id {
                if let Some(parent) = self.get_task(pid) {
                    task.set_caps(parent.caps);
                    task.set_confine_root(parent.confine_root.clone());
                    // A child starts in its parent's process group (POSIX); the shell
                    // `setpgid`s a job into its own group afterwards.
                    task.set_pgid(parent.pgid());
                    // POSIX environment inheritance: copy (not share) the parent's env so
                    // a child sees it but later mutations don't cross between processes.
                    task.env_mut().clone_from(parent.env());
                    // Scheduling niceness is inherited across spawn (POSIX); a child of
                    // `nice` therefore runs at the adjusted priority.
                    task.nice = parent.nice;
                    // Signal dispositions are inherited across spawn, so a `nohup`
                    // parent's SIGHUP-ignore reaches the child (spawn is the exec point
                    // here) — EXCEPT the terminal job-control signals SIGINT/SIGTSTP,
                    // which reset to default in the child. The login shell ignores those
                    // on itself; without this carve-out every job would inherit the ignore
                    // and Ctrl-C / Ctrl-Z would stop reaching foreground jobs.
                    let inherited_disp = parent.sig_ignored_mask()
                        & !(1u32 << abi::SIGINT)
                        & !(1u32 << abi::SIGTSTP);
                    task.set_sig_ignored_mask(inherited_disp);
                }
            }

            (*self.tasks.get()).insert(id, task);
            (*self.ready.get()).push_back(id);
        }
    }

    /// The pid of the task currently being stepped, if any. Used by `/env` to resolve the
    /// calling task for the filesystem methods not handed a `CallerId` (stat/readdir/
    /// unlink) — sound under the single-threaded cooperative discipline (the running task
    /// is the caller).
    pub fn current_pid(&self) -> Option<TaskId> {
        unsafe { *self.current.get() }
    }

    /// Detach a task from the ready queue and mark it Running. Used for pid 1 (the
    /// shell), which lives inside `mc_tick` and must not be reachable by `scheduler.tick`.
    pub fn detach(&self, id: TaskId) {
        unsafe {
            (*self.ready.get()).retain(|&tid| tid != id);
            if let Some(t) = self.get_task_mut(id) {
                t.state = TaskState::Running;
            }
        }
    }

    /// Allocate a fresh pipe owned by the scheduler. The returned reference is stable for
    /// the lifetime of the scheduler.
    pub fn alloc_pipe(&self) -> &Pipe {
        unsafe {
            let pipes = &mut *self.pipes.get();
            pipes.push(Box::new(Pipe::new()));
            let p = pipes.last().expect("just pushed").as_ref();
            // Erase the lifetime to the scheduler's; safe because the scheduler outlives
            // all pipes (it owns them) and the Box is never moved out of the Vec.
            &*(p as *const Pipe)
        }
    }

    /// Drop pipes that are closed on both ends and no task is parked on. Called from the
    /// reaper after every pipeline drains.
    pub fn drop_dead_pipes(&self) {
        unsafe {
            let blocked = &*self.blocked.get();
            let referenced = |addr: usize| -> bool {
                blocked.values().any(|r| match r {
                    BlockReason::PipeRead { pipe_ptr } | BlockReason::PipeWrite { pipe_ptr } => {
                        *pipe_ptr == addr
                    }
                    _ => false,
                })
            };
            let pipes = &mut *self.pipes.get();
            pipes.retain(|p| {
                let dead = p.is_read_closed() && p.is_write_closed();
                let addr = p.as_ref() as *const Pipe as usize;
                !(dead && !referenced(addr))
            });
        }
    }

    pub fn get_task(&self, id: TaskId) -> Option<&Task> {
        unsafe { (*self.tasks.get()).get(&id).map(|b| b.as_ref()) }
    }

    pub fn get_task_mut(&self, id: TaskId) -> Option<&mut Task> {
        unsafe { (*self.tasks.get()).get_mut(&id).map(|b| b.as_mut()) }
    }

    /// Install the capability policy a task is `exec`'d with. Done through the owned
    /// `Box` so the plain `caps`/`confine_root` fields take a `&mut` without aliasing the
    /// shared `&Task` other code holds.
    pub fn set_task_policy(
        &self,
        id: TaskId,
        caps: crate::task::Capabilities,
        confine_root: Option<String>,
    ) {
        if let Some(t) = self.get_task_mut(id) {
            t.set_caps(caps);
            t.set_confine_root(confine_root);
        }
    }

    /// Snapshot all live task IDs (used by procfs to enumerate /proc/[pid]).
    pub fn task_ids(&self) -> Vec<TaskId> {
        unsafe { (*self.tasks.get()).keys().copied().collect() }
    }

    pub fn current_task(&self) -> Option<&Task> {
        unsafe { (*self.current.get()).and_then(|id| self.get_task(id)) }
    }

    /// Park the currently-running task on `reason`.
    pub fn block_current(&self, reason: BlockReason) {
        unsafe {
            if let Some(id) = *self.current.get() {
                (*self.blocked.get()).insert(id, reason);
                if let Some(task) = self.get_task_mut(id) {
                    task.state = TaskState::Blocked(reason);
                }
                *self.current.get() = None;
            }
        }
    }

    /// Park a specific task by id on `reason`. Used by `run_next` when a stepped task
    /// reports it must wait on a pipe.
    pub fn block_task(&self, id: TaskId, reason: BlockReason) {
        unsafe {
            (*self.ready.get()).retain(|&tid| tid != id);
            (*self.blocked.get()).insert(id, reason);
            if let Some(task) = self.get_task_mut(id) {
                task.state = TaskState::Blocked(reason);
            }
            if *self.current.get() == Some(id) {
                *self.current.get() = None;
            }
        }
    }

    /// Return a task that ran a step but did not finish (it has no pipe behind the stream
    /// it reported blocked on, so it is not truly parked) to the back of the ready queue.
    /// Clears `current`.
    pub fn requeue(&self, id: TaskId) {
        unsafe {
            if let Some(task) = self.get_task_mut(id) {
                task.state = TaskState::Ready;
            }
            (*self.ready.get()).push_back(id);
            if *self.current.get() == Some(id) {
                *self.current.get() = None;
            }
        }
    }

    pub fn unblock(&self, id: TaskId) {
        unsafe {
            if (*self.blocked.get()).remove(&id).is_some() {
                (*self.ready.get()).push_back(id);
                if let Some(task) = self.get_task_mut(id) {
                    task.state = TaskState::Ready;
                }
            }
        }
    }

    /// Mark task as exited (zombie state).
    pub fn exit_task(&self, id: TaskId, exit_code: i32) {
        unsafe {
            (*self.ready.get()).retain(|&tid| tid != id);
            (*self.blocked.get()).remove(&id);

            (*self.zombies.get()).push(id);

            if let Some(task) = self.get_task_mut(id) {
                task.state = TaskState::Zombie;
                *task.exit_code.get() = Some(exit_code);
            }

            if *self.current.get() == Some(id) {
                *self.current.get() = None;
            }

            // Reparent this task's children to pid 1 (init), POSIX-style, so they are not
            // left with a dangling parent id once this task is reaped — and so a session
            // hangup delivered to pid 1's group can still reach a detached (`nohup`'d)
            // grandchild.
            let orphans: Vec<TaskId> = (*self.tasks.get())
                .values()
                .filter(|t| t.parent_id == Some(id) && t.id != id)
                .map(|t| t.id)
                .collect();
            for child in orphans {
                if let Some(c) = self.get_task_mut(child) {
                    c.parent_id = Some(1);
                }
            }

            // If a parent was waiting on this child, wake it.
            if let Some(task) = self.get_task(id) {
                if let Some(parent_id) = task.parent_id {
                    if let Some(reason) = (*self.blocked.get()).get(&parent_id) {
                        if let BlockReason::WaitChild { child_id } = reason {
                            if *child_id == id {
                                self.unblock(parent_id);
                            }
                        }
                    }
                }
            }
        }
    }

    pub fn get_exit_code(&self, id: TaskId) -> Option<i32> {
        unsafe {
            (*self.tasks.get())
                .get(&id)
                .and_then(|t| *t.exit_code.get())
        }
    }

    /// Pop the next ready task and mark it Running. The pipeline runner calls this only
    /// to read the current pid; in this architecture the step() loop drives execution
    /// rather than the scheduler.
    pub fn pop_ready(&self) -> Option<TaskId> {
        unsafe {
            // Skip frozen (`stop`ped) tasks: rotate them to the back and try the next,
            // bounded by the queue length so an all-frozen ready queue returns `None`
            // rather than spinning.
            let n = (*self.ready.get()).len();
            for _ in 0..n {
                let id = (*self.ready.get()).pop_front()?;
                // Skip tasks held off the CPU — a `/proc` freeze or a SIGTSTP stop.
                // Rotate them to the back, bounded by the queue length.
                if self.get_task(id).map(|t| t.is_stopped()).unwrap_or(false) {
                    (*self.ready.get()).push_back(id);
                    continue;
                }
                *self.current.get() = Some(id);
                if let Some(t) = self.get_task_mut(id) {
                    t.state = TaskState::Running;
                }
                return Some(id);
            }
            None
        }
    }

    /// Forcibly terminate `id` (a `/proc/[pid]/ctl` `kill`). Reuses the ordinary exit
    /// path: removes it from the queues, marks it a zombie with `exit_code`, and wakes a
    /// parent blocked on `WaitChild`.
    pub fn kill_task(&self, id: TaskId, exit_code: i32) {
        if let Some(task) = self.get_task(id) {
            // A stopped task can still be killed (e.g. `kill %1` on a Ctrl-Z'd job): clear
            // the stop so it lands as a normal zombie.
            task.set_sig_stopped(false);
            task.close_stdout();
            task.close_stdin();
        }
        self.exit_task(id, exit_code);
    }

    /// Freeze (`stop`) or unfreeze (`cont`) a task.
    pub fn set_frozen(&self, id: TaskId, frozen: bool) {
        if let Some(t) = self.get_task_mut(id) {
            t.frozen = frozen;
        }
    }

    /// Put task `id` in process group `pgid` (`mc_sys_setpgid`; `pgid == 0` means "use
    /// the task's own pid", making it a group leader).
    pub fn set_pgid(&self, id: TaskId, pgid: TaskId) {
        if let Some(t) = self.get_task(id) {
            t.set_pgid(if pgid == 0 { id } else { pgid });
        }
    }

    /// Deliver signal `sig` to task `id`: mark it pending and, unless `id` is the task
    /// currently mid-step (terminating it under its own feet is unsafe), apply it now.
    /// The running task's signals are applied at its next step boundary via
    /// `process_signals` in `run_next`.
    pub fn deliver_signal(&self, id: TaskId, sig: i32) {
        let exists = self
            .get_task(id)
            .map(|t| t.state != TaskState::Zombie)
            .unwrap_or(false);
        if !exists {
            return;
        }
        if let Some(t) = self.get_task(id) {
            t.raise_signal(sig);
        }
        let is_current = unsafe { *self.current.get() == Some(id) };
        if !is_current {
            self.process_signals(id);
        }
    }

    /// Deliver `sig` to every (live) task in process group `pgid`.
    pub fn signal_group(&self, pgid: TaskId, sig: i32) {
        let ids: Vec<TaskId> = unsafe {
            (*self.tasks.get())
                .values()
                .filter(|t| t.pgid() == pgid && t.state != TaskState::Zombie)
                .map(|t| t.id)
                .collect()
        };
        for id in ids {
            self.deliver_signal(id, sig);
        }
    }

    /// Deliver `sig` to every live task except `except`. Used on login-shell exit to hang
    /// up the whole session: the login shell (pid 1) is the root of the entire process
    /// tree, so every other live task is a session member — and background jobs sit in
    /// their own process groups, so a single `signal_group` would miss them.
    pub fn signal_all_except(&self, except: TaskId, sig: i32) {
        let ids: Vec<TaskId> = unsafe {
            (*self.tasks.get())
                .values()
                .filter(|t| t.id != except && t.state != TaskState::Zombie)
                .map(|t| t.id)
                .collect()
        };
        for id in ids {
            self.deliver_signal(id, sig);
        }
    }

    /// Apply `id`'s pending signals at a safe point. Returns `false` if the task was
    /// terminated (now a zombie) so the caller skips stepping it.
    ///
    /// Disposition model (no async handlers): a signal is either ignored (`SIG_IGN`) or
    /// takes its default action. KILL is unconditional; INT/TERM/HUP terminate
    /// (`128 + signo`); TSTP stops (frozen); CONT resumes; CHLD is dropped. An *ignored*
    /// interrupting signal is left pending so a blocked syscall can observe it as `EINTR`;
    /// if the task is parked, it is woken so that syscall re-runs.
    pub fn process_signals(&self, id: TaskId) -> bool {
        let pending = match self.get_task(id) {
            Some(t) if t.state != TaskState::Zombie => t.pending_signals(),
            _ => return false,
        };
        if pending == 0 {
            return true;
        }
        let bit = |s: i32| pending & (1u32 << s) != 0;

        // KILL — uncatchable, un-ignorable.
        if bit(abi::SIGKILL) {
            self.kill_task(id, 128 + abi::SIGKILL);
            return false;
        }
        // CONT — resume a SIGTSTP-stopped task.
        if bit(abi::SIGCONT) {
            if let Some(t) = self.get_task(id) {
                t.clear_signal(abi::SIGCONT);
                t.set_sig_stopped(false);
            }
        }
        // Terminating signals (default action) or, when ignored, EINTR fodder.
        let mut woke_for_eintr = false;
        for sig in [abi::SIGINT, abi::SIGTERM, abi::SIGHUP] {
            if !bit(sig) {
                continue;
            }
            let ignored = self
                .get_task(id)
                .map(|t| t.signal_ignored(sig))
                .unwrap_or(true);
            if ignored {
                // Leave it pending for the next blocking syscall to consume as EINTR;
                // wake a parked task so that syscall actually re-runs.
                let blocked = matches!(
                    self.get_task(id).map(|t| t.state),
                    Some(TaskState::Blocked(_))
                );
                if blocked {
                    woke_for_eintr = true;
                }
            } else {
                self.kill_task(id, 128 + sig);
                return false;
            }
        }
        // TSTP — terminal stop.
        if bit(abi::SIGTSTP) {
            let ignored = self
                .get_task(id)
                .map(|t| t.signal_ignored(abi::SIGTSTP))
                .unwrap_or(true);
            if let Some(t) = self.get_task(id) {
                t.clear_signal(abi::SIGTSTP);
            }
            if !ignored {
                if let Some(t) = self.get_task(id) {
                    t.set_sig_stopped(true);
                }
                // Let a parent blocked in `waitpid` on this child observe the stop
                // (Ctrl-Z job control) instead of hanging forever.
                self.wake_parent_waiter(id);
            }
        }
        // CHLD — default action is to ignore.
        if let Some(t) = self.get_task(id) {
            t.clear_signal(abi::SIGCHLD);
        }
        if woke_for_eintr {
            self.unblock(id);
        }
        true
    }

    /// Wake a parent parked in `waitpid` on child `id` (used when the child exits or
    /// stops). The parent re-runs `waitpid`, which then reports the child's new state.
    fn wake_parent_waiter(&self, id: TaskId) {
        unsafe {
            if let Some(task) = self.get_task(id) {
                if let Some(parent_id) = task.parent_id {
                    if let Some(BlockReason::WaitChild { child_id }) =
                        (*self.blocked.get()).get(&parent_id).copied()
                    {
                        if child_id == id {
                            self.unblock(parent_id);
                        }
                    }
                }
            }
        }
    }

    /// True iff `anc` is `desc` or one of its ancestors (a parent-id walk). Used to gate
    /// `/proc/[pid]/ctl` control: you may control only your own process subtree. Bounded
    /// against an (impossible) parent cycle.
    pub fn is_ancestor_of(&self, anc: TaskId, desc: TaskId) -> bool {
        let mut cur = Some(desc);
        let mut guard = 0usize;
        while let Some(id) = cur {
            if id == anc {
                return true;
            }
            cur = self.get_task(id).and_then(|t| t.parent_id);
            guard += 1;
            if guard > 4096 {
                break;
            }
        }
        false
    }

    /// Wake any task whose block condition is now satisfied.
    pub fn check_unblocked(&self) {
        unsafe {
            let to_unblock: Vec<TaskId> = (*self.blocked.get())
                .iter()
                .filter_map(|(&id, reason)| match *reason {
                    BlockReason::PipeRead { pipe_ptr } => {
                        let pipe = &*(pipe_ptr as *const Pipe);
                        if pipe.is_write_closed() || !pipe.buffer.is_empty() {
                            Some(id)
                        } else {
                            None
                        }
                    }
                    BlockReason::PipeWrite { pipe_ptr } => {
                        let pipe = &*(pipe_ptr as *const Pipe);
                        if pipe.is_read_closed() || !pipe.buffer.is_full() {
                            Some(id)
                        } else {
                            None
                        }
                    }
                    _ => None,
                })
                .collect();

            for id in to_unblock {
                self.unblock(id);
            }
        }
    }

    pub fn ready_count(&self) -> usize {
        unsafe { (*self.ready.get()).len() }
    }

    pub fn blocked_count(&self) -> usize {
        unsafe { (*self.blocked.get()).len() }
    }

    pub fn has_work(&self) -> bool {
        self.ready_count() > 0 || self.blocked_count() > 0
    }

    /// The lowest niceness among currently-runnable (ready, not stopped) tasks, or
    /// `i8::MAX` if there are none. The cooperative scheduler deprioritizes a task
    /// RELATIVE to this floor, so a negative-nice task (which becomes the floor) makes its
    /// higher-nice peers skip — making negative niceness real, not a no-op.
    pub fn min_ready_nice(&self) -> i8 {
        unsafe {
            (*self.tasks.get())
                .values()
                .filter(|t| t.state == TaskState::Ready && !t.is_stopped())
                .map(|t| t.nice)
                .min()
                .unwrap_or(i8::MAX)
        }
    }

    /// Reap a zombie task, removing it from the task map.
    pub fn reap_zombie(&self, id: TaskId) {
        unsafe {
            let is_zombie = self
                .get_task(id)
                .map(|t| t.state == TaskState::Zombie)
                .unwrap_or(false);

            if is_zombie {
                (*self.zombies.get()).retain(|&tid| tid != id);
                (*self.tasks.get()).remove(&id);
            }
        }
    }
}

// SAFETY: single-threaded cooperative kernel; no aliasing across a yield (see task::mod).
unsafe impl Sync for Scheduler {}
