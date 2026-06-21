//! Task representation and the capability/tier policy model.
//!
//! A task carries identity (id, parent, name, command, args, cwd), state (Ready /
//! Running / Blocked / Zombie), its standard streams as trait objects, an optional
//! cooperative `Builtin` program that drives it, its [`Capabilities`], a per-process
//! [`Namespace`], job-control state (pgid, pending signals, stop latches), and its
//! private environment.
//!
//! Pid 1 is special: it is the shell, which runs entirely inside `mc_tick` and never
//! goes through `scheduler.tick()`. It is spawned `Running`, has no program, and is kept
//! off the ready queue (see `init::boot_system` and `Scheduler::spawn_init`).
//!
//! Capabilities are the kernel-side POLICY layer and only ever **narrow** down
//! the process tree: a child's set is `parent ∩ binary-tier ∩ requested-tier`. Eight
//! bits exactly fill the `u8` — a ninth is the moment to ask whether it is a genuinely
//! new authority. `UnsafeCell` interior mutability is sound under the single-threaded
//! cooperative discipline; `Task: Sync` is asserted on that basis.
//!
//! Some of the task API (the fd table and its accessors, `Capabilities::without`) is
//! surface the syscall layer consumes as user programs gain `open`/`dup`; it is present
//! ahead of its first caller, hence the module-level dead-code allowance.
#![allow(dead_code)]

use alloc::boxed::Box;
use alloc::collections::BTreeMap;
use alloc::string::String;
use alloc::vec::Vec;
use core::cell::UnsafeCell;

use crate::builtins::{Builtin, BuiltinCtx, BuiltinStep};
use crate::io::{EmptySource, ReadSource, TerminalSink, WriteSink};
use crate::vfs::Namespace;

/// A file-descriptor slot for `fd_table` (fds 3+) — a growable per-task fd table on top
/// of the three standard I/O slots. Today no builtin opens fds beyond stdin/stdout/
/// stderr, but the contract requires the slot to exist.
pub enum Fd {
    Reader(Box<dyn ReadSource>),
    Writer(Box<dyn WriteSink>),
}

pub mod scheduler;

pub use scheduler::Scheduler;

pub type TaskId = u32;

// The capability bits are the single source of truth in `contracts/constants.kdl`,
// projected into `constants_rust` (B2 — no hand-written ABI). Re-exported here so the
// policy types below and the syscall gate name them `crate::task::CAP_*`; the namespace
// consumes them straight from the projection, so the VFS need not depend on `task`.
pub use constants_rust::{
    CAP_AMBIENT, CAP_FS_READ, CAP_FS_WRITE, CAP_MOUNT, CAP_NET, CAP_PERSIST, CAP_SCRATCH,
    CAP_SPAWN,
};

/// A task's capability set. The kernel-side POLICY layer: a privileged
/// syscall checks the relevant bit and returns `EPERM` if it is absent. It composes with
/// — and does not replace — the host capability gate (e.g. `DeniedNet` without
/// `--allow-net`), which governs whether the underlying resource is *available* at all.
///
/// Capabilities only ever **narrow** down the process tree: a child's set is
/// `parent ∩ binary-tier ∩ requested-tier` (exec is the policy point). A program can
/// therefore run AI-authored or untrusted children at strictly lower privilege than its
/// own, and can never widen beyond what it was granted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Capabilities(u8);

impl Capabilities {
    /// All capabilities — the privilege of pid 1 (the shell).
    pub const fn all() -> Self {
        Capabilities(
            CAP_FS_READ
                | CAP_FS_WRITE
                | CAP_SPAWN
                | CAP_NET
                | CAP_PERSIST
                | CAP_AMBIENT
                | CAP_SCRATCH
                | CAP_MOUNT,
        )
    }

    /// No capabilities.
    pub const fn none() -> Self {
        Capabilities(0)
    }

    pub const fn from_bits(bits: u8) -> Self {
        Capabilities(bits)
    }

    pub fn has(self, cap: u8) -> bool {
        self.0 & cap != 0
    }

    /// Intersection — the only way capabilities combine at exec. The result holds a
    /// capability iff *both* operands do, so it is always a subset of each.
    pub fn intersect(self, other: Capabilities) -> Self {
        Capabilities(self.0 & other.0)
    }

    /// Return this set with `cap` removed (narrowing for a child).
    pub fn without(self, cap: u8) -> Self {
        Capabilities(self.0 & !cap)
    }
}

/// A named capability tier. A binary declares one in its `mc_tier` custom
/// section; a parent MAY request one when spawning a child. Both are intersected with
/// the parent's live capabilities at exec.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    /// Everything: file read/write, spawn, network, persistence, and the ambient host
    /// authorities (clock, entropy, namespace mutation).
    Full,
    /// File read/write plus ambient *observation* (clock, entropy) — no spawn, network,
    /// persistence, or namespace mutation.
    ReadWrite,
    /// File reads plus ambient *observation* (clock, entropy) — no mutation of any kind.
    /// An observer.
    ReadOnly,
    /// Reads confined to the cwd subtree at exec time; no ambient authorities. The sole
    /// fully deterministic tier.
    Isolated,
}

impl Tier {
    /// Parse a tier name (the `mc_tier` section payload / a spawn argument).
    pub fn parse(s: &str) -> Option<Tier> {
        match s {
            "full" => Some(Tier::Full),
            "read-write" => Some(Tier::ReadWrite),
            "read-only" => Some(Tier::ReadOnly),
            "isolated" => Some(Tier::Isolated),
            _ => None,
        }
    }

    /// Decode a tier from the `mc_sys_spawn` argument, using the encodings projected from
    /// the contract. `TIER_INHERIT` (0) — or anything unrecognized — means "inherit, do
    /// not narrow".
    pub fn from_arg(n: i32) -> Option<Tier> {
        use constants_rust::{TIER_FULL, TIER_ISOLATED, TIER_READ_ONLY, TIER_READ_WRITE};
        match n {
            TIER_FULL => Some(Tier::Full),
            TIER_READ_WRITE => Some(Tier::ReadWrite),
            TIER_READ_ONLY => Some(Tier::ReadOnly),
            TIER_ISOLATED => Some(Tier::Isolated),
            _ => None,
        }
    }

    /// The capability ceiling this tier permits — GENERATED from
    /// `contracts/constants.kdl` (`tier-caps`, projected to `constants_rust::tier_caps`),
    /// so this kernel and the Phase-B Zig kernel grant IDENTICAL ceilings (a parity
    /// invariant, §16 / §15.4) with no hand-maintained duplicate. The rationale lives with
    /// the data, in the contract: ambient observation (`CAP_AMBIENT`) and private scratch
    /// (`CAP_SCRATCH`) are granted from `ReadOnly` up — so `date`/`shuf` and spill-to-
    /// `/scratch` work there — while `CAP_MOUNT` and spawn/net/persist stay `Full`-only;
    /// `Isolated` withholds ambient + scratch (the sole deterministic tier — a writable
    /// scratch would re-introduce clock-derived mtimes).
    pub fn caps(self) -> Capabilities {
        use constants_rust::{
            TIER_FULL, TIER_ISOLATED, TIER_READ_ONLY, TIER_READ_WRITE, tier_caps,
        };
        let ordinal = match self {
            Tier::Full => TIER_FULL,
            Tier::ReadWrite => TIER_READ_WRITE,
            Tier::ReadOnly => TIER_READ_ONLY,
            Tier::Isolated => TIER_ISOLATED,
        };
        Capabilities::from_bits(tier_caps(ordinal))
    }

    /// Whether this tier confines filesystem access to the cwd subtree.
    pub fn confines(self) -> bool {
        matches!(self, Tier::Isolated)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BlockReason {
    PipeRead { pipe_ptr: usize },
    PipeWrite { pipe_ptr: usize },
    WaitChild { child_id: TaskId },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaskState {
    Ready,
    Running,
    Blocked(BlockReason),
    Zombie,
}

pub struct Task {
    pub id: TaskId,
    pub parent_id: Option<TaskId>,
    pub name: String,
    pub state: TaskState,

    pub stdin: UnsafeCell<Box<dyn ReadSource>>,
    pub stdout: UnsafeCell<Box<dyn WriteSink>>,
    pub stderr: UnsafeCell<Box<dyn WriteSink>>,

    pub cwd: UnsafeCell<String>,
    pub exit_code: UnsafeCell<Option<i32>>,

    pub command: String,
    pub args: Vec<String>,

    /// Capability set governing privileged syscalls. Inherited from the parent at
    /// spawn, then narrowed at exec; the root shell holds [`Capabilities::all`].
    pub caps: Capabilities,

    /// Filesystem confinement root for the `isolated` tier: when `Some(root)`,
    /// the task may only touch paths at or under `root`. Inherited and only tightened.
    pub confine_root: Option<String>,

    /// Frozen (`stop`ped) by a `/proc/[pid]/ctl` `stop` command. A frozen task stays in
    /// its queue but the scheduler skips it until a `cont`. Orthogonal to
    /// ready/blocked/zombie state.
    pub frozen: bool,

    /// Scheduling niceness (POSIX-style, `-20..=19`; default 0). Higher = lower priority.
    /// Priority is RELATIVE: a task is deprioritized in proportion to how far its niceness
    /// exceeds the lowest niceness among the ready tasks. Inherited across spawn.
    pub nice: i8,

    /// Cooperative-scheduler bookkeeping for `nice`: how many more scheduling rounds this
    /// task is skipped before its next step. Realizes priority without ever stepping a
    /// task twice in a round; reloads to a niceness-derived quota when it reaches zero.
    pub skip_credit: UnsafeCell<u16>,

    /// The cooperative builtin program. `None` for pid 1 (the shell runs in mc_tick) and
    /// for zombies after their final step.
    pub program: UnsafeCell<Option<Box<dyn Builtin>>>,

    /// Growable file-descriptor table for fds 3+; no current builtin
    /// allocates entries.
    pub fd_table: UnsafeCell<Vec<Option<Fd>>>,

    /// This task's per-process mount namespace. `None` means "use the root namespace"; a
    /// spawned task is given a fork of its parent's, so a `bind`/`unmount` is private to
    /// the task and its future children.
    pub namespace: UnsafeCell<Option<Namespace>>,

    /// Process group id for job control. A task starts in its parent's group; the
    /// shell `setpgid`s a foreground/background pipeline into its own group so terminal
    /// signals (Ctrl-C / Ctrl-Z) can target the running job without hitting the shell.
    /// The root shell leads group 1.
    pub pgid: UnsafeCell<TaskId>,

    /// Pending-signal bitset: bit `n` set ⇒ signal `n` awaits delivery. Drained by
    /// `Scheduler::process_signals` at a safe point (never mid-step).
    pub pending_signals: UnsafeCell<u32>,

    /// Disposition bitset: bit `n` set ⇒ signal `n` is *ignored* (`SIG_IGN`). Cleared bit
    /// ⇒ the default action. There are no async handlers in a cooperative wasm guest, so
    /// these two dispositions are the whole model.
    pub sig_ignored: UnsafeCell<u32>,

    /// True while this task is stopped by `SIGTSTP` (Ctrl-Z), as opposed to the `/proc`
    /// `frozen` freeze. `waitpid` reports the transition once so the shell can record a
    /// stopped job and return to its prompt; `SIGCONT` clears it. Both flags independently
    /// keep the task off the run queue.
    pub sig_stopped: UnsafeCell<bool>,

    /// Latch so a stop is reported to `waitpid` exactly once (until the next stop). Set
    /// when `sig_stopped` goes true, cleared once a wait observes it.
    pub stop_reported: UnsafeCell<bool>,

    /// This task's environment (the `/env` view). Copied from the parent at spawn (POSIX
    /// inheritance), then private — so a temporary `FOO=bar cmd` assignment reaches only
    /// `cmd`, never sibling/background tasks.
    pub env: UnsafeCell<BTreeMap<String, String>>,
}

impl Task {
    pub fn new(
        id: TaskId,
        parent_id: Option<TaskId>,
        name: String,
        command: String,
        args: Vec<String>,
        cwd: String,
    ) -> Self {
        Self {
            id,
            parent_id,
            name,
            state: TaskState::Ready,
            stdin: UnsafeCell::new(Box::new(EmptySource)),
            stdout: UnsafeCell::new(Box::new(TerminalSink::Stdout)),
            stderr: UnsafeCell::new(Box::new(TerminalSink::Stderr)),
            cwd: UnsafeCell::new(cwd),
            exit_code: UnsafeCell::new(None),
            command,
            args,
            caps: Capabilities::all(),
            confine_root: None,
            frozen: false,
            nice: 0,
            skip_credit: UnsafeCell::new(0),
            program: UnsafeCell::new(None),
            fd_table: UnsafeCell::new(Vec::new()),
            namespace: UnsafeCell::new(None),
            pgid: UnsafeCell::new(id), // own group by default; spawn inherits parent's
            pending_signals: UnsafeCell::new(0),
            sig_ignored: UnsafeCell::new(0),
            sig_stopped: UnsafeCell::new(false),
            stop_reported: UnsafeCell::new(false),
            env: UnsafeCell::new(BTreeMap::new()),
        }
    }

    /// This task's environment map (the `/env` view).
    pub fn env(&self) -> &BTreeMap<String, String> {
        unsafe { &*self.env.get() }
    }

    /// Mutable access to this task's environment map.
    #[allow(clippy::mut_from_ref)]
    pub fn env_mut(&self) -> &mut BTreeMap<String, String> {
        unsafe { &mut *self.env.get() }
    }

    /// Raw pointer to this task's environment map (stable: the task is boxed). Used by
    /// `/env` (envfs) to resolve the calling task's environment.
    pub fn env_ptr(&self) -> *mut BTreeMap<String, String> {
        self.env.get()
    }

    /// Whether this task is stopped by `SIGTSTP`.
    pub fn sig_stopped(&self) -> bool {
        unsafe { *self.sig_stopped.get() }
    }

    /// Set/clear the `SIGTSTP` stop flag. Entering the stopped state arms the one-shot
    /// `waitpid` report; leaving it disarms it.
    pub fn set_sig_stopped(&self, stopped: bool) {
        unsafe {
            *self.sig_stopped.get() = stopped;
            *self.stop_reported.get() = !stopped;
        }
    }

    /// Consume the one-shot "this task just stopped" report. Returns true the first time
    /// it is called after a stop, then false until the next stop.
    pub fn take_stop_report(&self) -> bool {
        unsafe {
            if *self.sig_stopped.get() && !*self.stop_reported.get() {
                *self.stop_reported.get() = true;
                true
            } else {
                false
            }
        }
    }

    /// True iff this task is runnable-blocked from the scheduler's view: a `SIGTSTP` stop
    /// or a `/proc` freeze both keep it off the ready queue.
    pub fn is_stopped(&self) -> bool {
        self.frozen || self.sig_stopped()
    }

    /// Remaining `nice` skip-credit (cooperative scheduler bookkeeping).
    pub fn skip_credit(&self) -> u16 {
        unsafe { *self.skip_credit.get() }
    }

    /// Set this task's `nice` skip-credit.
    pub fn set_skip_credit(&self, n: u16) {
        unsafe {
            *self.skip_credit.get() = n;
        }
    }

    /// This task's process-group id.
    pub fn pgid(&self) -> TaskId {
        unsafe { *self.pgid.get() }
    }

    /// Put this task in process group `pgid`.
    pub fn set_pgid(&self, pgid: TaskId) {
        unsafe {
            *self.pgid.get() = pgid;
        }
    }

    /// Mark signal `sig` (1..=31) pending on this task.
    pub fn raise_signal(&self, sig: i32) {
        if (1..32).contains(&sig) {
            unsafe {
                *self.pending_signals.get() |= 1u32 << sig;
            }
        }
    }

    /// True iff signal `sig` is currently pending.
    pub fn signal_pending(&self, sig: i32) -> bool {
        if !(1..32).contains(&sig) {
            return false;
        }
        unsafe { *self.pending_signals.get() & (1u32 << sig) != 0 }
    }

    /// Clear signal `sig` from the pending set.
    pub fn clear_signal(&self, sig: i32) {
        if (1..32).contains(&sig) {
            unsafe {
                *self.pending_signals.get() &= !(1u32 << sig);
            }
        }
    }

    /// The raw pending-signal bitset.
    pub fn pending_signals(&self) -> u32 {
        unsafe { *self.pending_signals.get() }
    }

    /// Whether `sig`'s disposition is "ignore" (`SIG_IGN`).
    pub fn signal_ignored(&self, sig: i32) -> bool {
        if !(1..32).contains(&sig) {
            return false;
        }
        unsafe { *self.sig_ignored.get() & (1u32 << sig) != 0 }
    }

    /// Set signal `sig`'s disposition: `true` = ignore, `false` = default.
    pub fn set_signal_ignored(&self, sig: i32, ignored: bool) {
        if !(1..32).contains(&sig) {
            return;
        }
        unsafe {
            if ignored {
                *self.sig_ignored.get() |= 1u32 << sig;
            } else {
                *self.sig_ignored.get() &= !(1u32 << sig);
            }
        }
    }

    /// The raw signal-disposition bitset (bit `n` set ⇒ signal `n` is ignored). Read to
    /// inherit dispositions across spawn.
    pub fn sig_ignored_mask(&self) -> u32 {
        unsafe { *self.sig_ignored.get() }
    }

    /// Replace the raw signal-disposition bitset (spawn inheritance).
    pub fn set_sig_ignored_mask(&self, mask: u32) {
        unsafe {
            *self.sig_ignored.get() = mask;
        }
    }

    /// Give this task its own per-process namespace.
    pub fn set_namespace(&self, ns: Namespace) {
        unsafe {
            *self.namespace.get() = Some(ns);
        }
    }

    /// This task's namespace, if it has been given one.
    pub fn namespace(&self) -> Option<&Namespace> {
        unsafe { (*self.namespace.get()).as_ref() }
    }

    /// Replace this task's capability set (used at spawn to inherit/narrow).
    pub fn set_caps(&mut self, caps: Capabilities) {
        self.caps = caps;
    }

    /// Replace this task's filesystem confinement root.
    pub fn set_confine_root(&mut self, root: Option<String>) {
        self.confine_root = root;
    }

    /// Allocate the next free entry in `fd_table` and return its number (always ≥ 3).
    pub fn alloc_fd(&self, fd: Fd) -> usize {
        unsafe {
            let table = &mut *self.fd_table.get();
            for (i, slot) in table.iter_mut().enumerate() {
                if slot.is_none() {
                    *slot = Some(fd);
                    return i + 3;
                }
            }
            table.push(Some(fd));
            table.len() + 2
        }
    }

    /// Look up a numbered fd. `0..=2` map to the standard streams via the dedicated typed
    /// accessors; `3+` consults the table.
    pub fn get_fd(&self, fd: usize) -> Option<&Fd> {
        if fd < 3 {
            return None; // standard streams use stdin_mut / stdout_mut / stderr_mut
        }
        unsafe {
            let table = &*self.fd_table.get();
            table.get(fd - 3).and_then(|opt| opt.as_ref())
        }
    }

    /// Close fd `n`. No-op for 0/1/2 (close via setter).
    pub fn close_fd(&self, fd: usize) {
        if fd < 3 {
            return;
        }
        unsafe {
            let table = &mut *self.fd_table.get();
            if let Some(slot) = table.get_mut(fd - 3) {
                *slot = None;
            }
        }
    }

    pub fn get_cwd(&self) -> &str {
        unsafe { &*self.cwd.get() }
    }

    pub fn set_cwd(&self, new_cwd: String) {
        unsafe {
            *self.cwd.get() = new_cwd;
        }
    }

    pub fn get_exit_code(&self) -> Option<i32> {
        unsafe { *self.exit_code.get() }
    }

    pub fn set_stdin(&self, src: Box<dyn ReadSource>) {
        unsafe {
            *self.stdin.get() = src;
        }
    }

    pub fn set_stdout(&self, sink: Box<dyn WriteSink>) {
        unsafe {
            *self.stdout.get() = sink;
        }
    }

    pub fn set_stderr(&self, sink: Box<dyn WriteSink>) {
        unsafe {
            *self.stderr.get() = sink;
        }
    }

    pub fn set_program(&self, p: Box<dyn Builtin>) {
        unsafe {
            *self.program.get() = Some(p);
        }
    }

    pub fn has_program(&self) -> bool {
        unsafe { (*self.program.get()).is_some() }
    }

    pub fn stdin_mut(&self) -> &mut dyn ReadSource {
        unsafe { (*self.stdin.get()).as_mut() }
    }

    pub fn stdout_mut(&self) -> &mut dyn WriteSink {
        unsafe { (*self.stdout.get()).as_mut() }
    }

    pub fn stderr_mut(&self) -> &mut dyn WriteSink {
        unsafe { (*self.stderr.get()).as_mut() }
    }

    /// Drive the program one step. Returns `None` if the task has no program (pid 1, or
    /// already exited). `sched` is threaded in so a user-space guest's syscalls can spawn
    /// children / allocate pipes.
    ///
    /// `fallback_ns` is the root namespace; a task that was given its own per-process
    /// namespace uses that instead, so binds and confinement are private to the task.
    pub fn step(&self, fallback_ns: &Namespace, sched: &Scheduler) -> Option<BuiltinStep> {
        unsafe {
            let prog_opt = &mut *self.program.get();
            let prog = prog_opt.as_mut()?;
            let cwd = &mut *self.cwd.get();
            let stdin = (*self.stdin.get()).as_mut();
            let stdout = (*self.stdout.get()).as_mut();
            let stderr = (*self.stderr.get()).as_mut();
            let ns = (*self.namespace.get()).as_ref().unwrap_or(fallback_ns);
            let mut ctx = BuiltinCtx {
                ns,
                root_ns: fallback_ns,
                cwd,
                stdin,
                stdout,
                stderr,
                sched,
                pid: self.id,
            };
            Some(prog.step(&mut ctx))
        }
    }

    /// Close any pipe write end attached to stdout. Called when the task exits so
    /// downstream readers see EOF.
    pub fn close_stdout(&self) {
        self.stdout_mut().close();
    }

    /// Close any pipe read end attached to stdin. Called when the task exits so the
    /// upstream writer sees a broken pipe and bails out instead of blocking on PipeWrite
    /// forever.
    pub fn close_stdin(&self) {
        self.stdin_mut().close();
    }

    /// Close any pipe write end attached to stderr. Called when the task exits — POSIX
    /// closes *every* fd on exit, so a child that holds a pipe write end on stderr (e.g.
    /// a captured `2>&1`, or stdout+stderr sharing one pipe) must also deliver EOF to the
    /// reader, not linger until it is reaped.
    pub fn close_stderr(&self) {
        self.stderr_mut().close();
    }
}

// SAFETY: the kernel is single-threaded and cooperative; no two references to a `Task`'s
// `UnsafeCell` interiors are ever live across a yield. `Sync` is asserted on that basis.
unsafe impl Sync for Task {}
