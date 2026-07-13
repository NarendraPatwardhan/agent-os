#![no_std]
#![no_main]

extern crate alloc;

mod bridge;
mod builtins;
mod exports;
mod fs;
mod host_call;
mod init;
mod io;
mod ipc;
mod net;
mod persist;
mod seal;
mod sync;
mod task;
mod vfs;
mod wasm;

use alloc::boxed::Box;
use alloc::collections::BTreeMap;
use alloc::format;
use alloc::rc::Rc;
use alloc::string::String;
use alloc::vec::Vec;
use core::cell::{RefCell, UnsafeCell};
use ctl_rust::{
    AutocompleteItem as CtlAutocompleteItem, AutocompleteRequest, AutocompleteResult,
    DirEntries as CtlDirEntries, DirEntry as CtlDirEntry, ExecOutcome, ExecRequest,
    FileStat as CtlFileStat, SvcRequest as CtlSvcRequest, SvcResponse as CtlSvcResponse,
};
use shell_rust::{
    Candidate as ShellCandidate, ProbeRequest, ProbeResponse, RenderRequest, CONTEXT_COMMAND,
    CONTEXT_DIRECTORY, CONTEXT_PATH, CONTEXT_VARIABLE,
};

use fs::ProcFs;
use task::{run_round, Scheduler, TaskId, TaskState};
use vfs::{KPath, Namespace, NodeType, OpenFlags};
use wasm::abi::{
    errno_from_fs, AUTOCOMPLETE_MAX_FRAME_BYTES, AUTOCOMPLETE_MAX_ITEMS,
    AUTOCOMPLETE_MAX_PATH_SEGMENTS, AUTOCOMPLETE_MAX_SCAN_ENTRIES,
    AUTOCOMPLETE_MAX_SOURCE_BYTES, EAGAIN, EINVAL, EIO, EMSGSIZE, ENOENT, ENOSYS, ENOTDIR,
    ESUCCESS, ETIMEDOUT, SERVICE_MARKER, SIGHUP, SIGINT, SIGTSTP,
};

struct OutputCapture {
    stdout: Rc<RefCell<Vec<u8>>>,
    stderr: Rc<RefCell<Vec<u8>>>,
}

fn new_capture() -> OutputCapture {
    OutputCapture {
        stdout: Rc::new(RefCell::new(Vec::new())),
        stderr: Rc::new(RefCell::new(Vec::new())),
    }
}

// ---------- CtlExecJob ----------

enum CtlBody {
    Guest { pid: TaskId },
}

struct CtlExecJob {
    body: CtlBody,
    cap: OutputCapture,
    done: bool,
    exit_code: i32,
}

enum CtlSvcState {
    /// Waiting for the service to activate; the request has not been enqueued yet.
    Connecting { name: String, req: Vec<u8> },
    /// Request enqueued; drain the streaming response through servicefs.
    Calling {
        channel: Rc<RefCell<fs::servicefs::ServiceChannel>>,
        session: u32,
        req_id: u32,
        out: Vec<u8>,
    },
    /// Terminal state: `status == 0` means `out` is the service body; non-zero is a transport errno.
    Done { status: i32, out: Vec<u8> },
}

struct CtlSvcJob {
    state: CtlSvcState,
}

struct PendingAutocomplete {
    request: AutocompleteRequest,
    generation: u64,
    list: bool,
}

struct ResolvedAutocomplete {
    result: AutocompleteResult,
    continuation: bool,
}

// ---------- SystemState ----------

struct SystemState {
    ns: UnsafeCell<Option<Namespace>>,
    scheduler: UnsafeCell<Option<Scheduler>>,
    /// The shared user-space runtime — the wasmi engine, one reusable linker,
    /// and the compiled-module cache — shared by all guests.
    guest_runtime: UnsafeCell<Option<wasm::GuestRuntime>>,
    /// Shell environment variables (`PATH`, `HOME`, …). Set by `export`,
    /// expanded as `$VAR`, and used to resolve programs on `$PATH`.
    env: UnsafeCell<BTreeMap<String, String>>,
    initialized: UnsafeCell<bool>,
    /// Host control-channel `exec` jobs (`mc_ctl_exec_*`), keyed by job id.
    /// Advanced each tick alongside the interactive foreground, but independent
    /// of the prompt.
    ctl_jobs: UnsafeCell<BTreeMap<u32, CtlExecJob>>,
    /// Host control-channel resident-service calls (`mc_ctl_svc_call_*`), keyed by job id.
    ctl_svc_jobs: UnsafeCell<BTreeMap<u32, CtlSvcJob>>,
    pending_autocomplete: UnsafeCell<Option<PendingAutocomplete>>,
    /// Monotonic id source for `ctl_jobs` (starts at 1; 0 is never a job id).
    next_ctl_job: UnsafeCell<u32>,
    /// True while pid 1 is the canonical compatible `/bin/sh`. When false the
    /// VM remains manageable through VFS/control APIs but has no shell facade.
    shell_available: UnsafeCell<bool>,
    /// The console pipe feeding pid-1 `/bin/sh`'s stdin. The kernel cooks
    /// keyboard input (echo, backspace) and writes whole lines into it; the
    /// guest blocks on its read end like any pipe. `None` in maintenance mode.
    console_pipe: UnsafeCell<Option<*const ipc::Pipe>>,
    /// Cooked console bytes not yet accepted by the (bounded) console pipe.
    /// A long pasted line can exceed the pipe's free space; rather than drop the
    /// overflow, the kernel queues it here and flushes more each tick as the
    /// guest drains its stdin — backpressure instead of truncation.
    console_pending: UnsafeCell<Vec<u8>>,
    /// The current login-shell task id (guest mode), for keep-alive respawn.
    login_pid: UnsafeCell<TaskId>,
    /// Wall-clock time (ms since the Unix epoch) sampled once per `mc_tick` from
    /// the host, so filesystem metadata stamping (mtime/atime/ctime) is cheap —
    /// no host call per read/write. Read via [`wall_now_ms`].
    wall_ms: UnsafeCell<i64>,
}

impl SystemState {
    const fn new() -> Self {
        Self {
            ns: UnsafeCell::new(None),
            scheduler: UnsafeCell::new(None),
            guest_runtime: UnsafeCell::new(None),
            env: UnsafeCell::new(BTreeMap::new()),
            initialized: UnsafeCell::new(false),
            ctl_jobs: UnsafeCell::new(BTreeMap::new()),
            ctl_svc_jobs: UnsafeCell::new(BTreeMap::new()),
            pending_autocomplete: UnsafeCell::new(None),
            next_ctl_job: UnsafeCell::new(1),
            shell_available: UnsafeCell::new(false),
            console_pipe: UnsafeCell::new(None),
            console_pending: UnsafeCell::new(Vec::new()),
            login_pid: UnsafeCell::new(0),
            wall_ms: UnsafeCell::new(0),
        }
    }

    unsafe fn ns(&self) -> &Namespace {
        unsafe { (*self.ns.get()).as_ref().unwrap() }
    }

    unsafe fn scheduler(&self) -> &Scheduler {
        unsafe { (*self.scheduler.get()).as_ref().unwrap() }
    }

    unsafe fn guest_runtime(&self) -> &wasm::GuestRuntime {
        unsafe { (*self.guest_runtime.get()).as_ref().unwrap() }
    }

    unsafe fn env(&self) -> &mut BTreeMap<String, String> {
        unsafe { &mut *self.env.get() }
    }

    unsafe fn is_initialized(&self) -> bool {
        unsafe { *self.initialized.get() }
    }

    unsafe fn set_initialized(&self) {
        unsafe {
            *self.initialized.get() = true;
        }
    }

    unsafe fn ctl_jobs(&self) -> &mut BTreeMap<u32, CtlExecJob> {
        unsafe { &mut *self.ctl_jobs.get() }
    }

    unsafe fn ctl_svc_jobs(&self) -> &mut BTreeMap<u32, CtlSvcJob> {
        unsafe { &mut *self.ctl_svc_jobs.get() }
    }

    unsafe fn pending_autocomplete(&self) -> &mut Option<PendingAutocomplete> {
        unsafe { &mut *self.pending_autocomplete.get() }
    }

    unsafe fn shell_available(&self) -> bool {
        unsafe { *self.shell_available.get() }
    }

    /// The console pipe for pid-1 stdin (guest mode only).
    unsafe fn console(&self) -> Option<&'static ipc::Pipe> {
        unsafe { (*self.console_pipe.get()).map(|p| &*p) }
    }

    /// The queue of cooked console bytes awaiting room in the console pipe.
    unsafe fn console_pending(&self) -> &mut Vec<u8> {
        unsafe { &mut *self.console_pending.get() }
    }

    /// Allocate the next control-exec job id (monotonic, wraps; 0 is skipped).
    unsafe fn alloc_ctl_id(&self) -> u32 {
        unsafe {
            let p = &mut *self.next_ctl_job.get();
            let id = *p;
            *p = p.wrapping_add(1).max(1);
            id
        }
    }
}

unsafe impl Sync for SystemState {}

static STATE: SystemState = SystemState::new();

/// The shared user-space runtime (wasmi engine + reusable linker + compiled-
/// module cache). Exposed so the guest spawn syscall (`fulfill_spawn`) loads a
/// child against the same cache as the shell. Safe: single-threaded under the
/// BKL, and initialized at boot before any guest runs.
pub(crate) fn guest_runtime() -> &'static wasm::GuestRuntime {
    unsafe { STATE.guest_runtime() }
}

/// Address of the console pipe feeding pid-1 `/bin/sh`'s stdin, if an
/// interactive guest is running (`None` for maintenance or a headless
/// boot). `mc_sys_isatty` uses it to recognise fd 0 as the controlling
/// terminal: the cooked console is a *pipe* (so `ReadSource::is_terminal` is
/// false), but a child that inherits it shares the same pipe address — that
/// identity is what makes `isatty(0)` true at the live prompt (and only there,
/// never for an ordinary `cat | foo` pipe). Lets REPLs like `/bin/luau` and the
/// SQLite shell detect interactive stdin the conventional way.
pub(crate) fn console_pipe_addr() -> Option<usize> {
    unsafe { (*STATE.console_pipe.get()).map(|p| p as usize) }
}

// ---------- Input buffer ----------

struct InputBuffer(UnsafeCell<Vec<u8>>);

impl InputBuffer {
    const fn new() -> Self {
        InputBuffer(UnsafeCell::new(Vec::new()))
    }
    unsafe fn get(&self) -> &mut Vec<u8> {
        unsafe { &mut *self.0.get() }
    }
}

unsafe impl Sync for InputBuffer {}

static INPUT_BUFFER: InputBuffer = InputBuffer::new();

// ---------- Cooked-mode line editor ----------
//
// The interactive console runs a cooked (canonical) line discipline in the
// kernel: keystrokes are buffered and edited here, and only whole lines are
// handed to the shell. `LineEditor` owns the line being typed, the cursor
// column within it, a session command history, and a small state machine that
// parses ANSI input escape sequences (arrow keys, Home/End, Delete) emitted by
// the terminal. The kernel echoes — the terminal does no local echo — so every
// edit writes the control bytes needed to keep the display in sync.
//
// Editing is byte/ASCII-column based: one input byte is treated as one screen
// column. Multibyte UTF-8 display width is not tracked. This matches the prior
// (append-only) editor and is sufficient for the single-width `$ ` prompt this
// drives; it is a deliberate simplification, not an oversight.

/// Maximum number of committed command lines kept in history.
const HISTORY_CAP: usize = 200;

/// Parser state for ANSI input escape sequences. Persisted across
/// `drain_input_line` calls so a sequence split across separate `mc_input`
/// pushes (or scheduler ticks) is still parsed as one unit.
#[derive(Clone, Copy, PartialEq)]
enum EscState {
    /// Not inside an escape sequence.
    Normal,
    /// Saw ESC (0x1b); awaiting `[` (CSI) or `O` (SS3).
    Esc,
    /// Inside a CSI/SS3 sequence; `param` accumulates a numeric argument.
    Csi,
}

/// Emit raw bytes to the console (the kernel-side echo path).
fn term_emit(bytes: &[u8]) {
    if !bytes.is_empty() {
        unsafe { bridge::mc_stdout_write(bytes.as_ptr(), bytes.len()) };
    }
}

/// Move the terminal cursor left `n` columns (`n` × backspace).
fn term_bs(n: usize) {
    for _ in 0..n {
        term_emit(b"\x08");
    }
}

/// Erase `n` columns to the left of the cursor (`n` × "backspace, space,
/// backspace"), leaving the cursor where it started minus `n` columns.
fn term_erase(n: usize) {
    for _ in 0..n {
        term_emit(b"\x08 \x08");
    }
}

struct LineEditor {
    /// The line currently being typed.
    line: Vec<u8>,
    /// Cursor position within `line`, in `0..=line.len()`.
    cursor: usize,
    /// Committed command lines, oldest first, capped at `HISTORY_CAP`.
    history: Vec<Vec<u8>>,
    /// History navigation index in `0..=history.len()`; `history.len()` means
    /// "the freshly-typed line" (held in `stash`). `None` when not navigating.
    hist_nav: Option<usize>,
    /// The in-progress line stashed when history navigation begins, so Down can
    /// restore it.
    stash: Vec<u8>,
    /// Escape-sequence parser state.
    esc: EscState,
    /// Numeric parameter accumulated inside a CSI sequence (e.g. the `3` in the
    /// Delete sequence `ESC [ 3 ~`).
    param: u16,
    /// Monotonic edit/cursor generation used to discard stale lazy-FS
    /// completion results.
    generation: u64,
    /// Exact line/cursor snapshot armed by the first ambiguous Tab. A second
    /// Tab on the same snapshot lists candidates.
    tab_armed: Option<(Vec<u8>, usize)>,
}

impl LineEditor {
    const fn new() -> Self {
        LineEditor {
            line: Vec::new(),
            cursor: 0,
            history: Vec::new(),
            hist_nav: None,
            stash: Vec::new(),
            esc: EscState::Normal,
            param: 0,
            generation: 0,
            tab_armed: None,
        }
    }

    fn touch(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.tab_armed = None;
    }

    /// Insert a byte at the cursor, reprinting the tail and walking back.
    fn insert(&mut self, b: u8) {
        self.touch();
        self.line.insert(self.cursor, b);
        term_emit(&self.line[self.cursor..]);
        term_bs(self.line.len() - self.cursor - 1);
        self.cursor += 1;
    }

    /// Erase the character before the cursor. With the cursor at end-of-line
    /// this emits exactly "\x08 \x08" (the redraw the line-discipline test
    /// expects).
    fn backspace(&mut self) {
        if self.cursor == 0 {
            return;
        }
        self.touch();
        self.line.remove(self.cursor - 1);
        self.cursor -= 1;
        term_bs(1);
        term_emit(&self.line[self.cursor..]);
        term_emit(b" ");
        term_bs(self.line.len() - self.cursor + 1);
    }

    /// Erase the character at the cursor (forward delete).
    fn delete_fwd(&mut self) {
        if self.cursor >= self.line.len() {
            return;
        }
        self.touch();
        self.line.remove(self.cursor);
        term_emit(&self.line[self.cursor..]);
        term_emit(b" ");
        term_bs(self.line.len() - self.cursor + 1);
    }

    fn left(&mut self) {
        if self.cursor > 0 {
            self.touch();
            self.cursor -= 1;
            term_bs(1);
        }
    }

    fn right(&mut self) {
        if self.cursor < self.line.len() {
            self.touch();
            term_emit(&self.line[self.cursor..self.cursor + 1]);
            self.cursor += 1;
        }
    }

    fn home(&mut self) {
        if self.cursor == 0 {
            return;
        }
        self.touch();
        term_bs(self.cursor);
        self.cursor = 0;
    }

    fn end(&mut self) {
        if self.cursor == self.line.len() {
            return;
        }
        self.touch();
        term_emit(&self.line[self.cursor..]);
        self.cursor = self.line.len();
    }

    /// Replace the visible line with `next`, leaving the cursor at its end.
    /// Walks to end-of-line, erases every column, then draws the new line — so
    /// it never touches the prompt to its left.
    fn replace_line(&mut self, next: Vec<u8>) {
        self.touch();
        term_emit(&self.line[self.cursor..]);
        term_erase(self.line.len());
        self.line = next;
        term_emit(&self.line);
        self.cursor = self.line.len();
    }

    /// Up arrow: recall the previous (older) history entry.
    fn history_prev(&mut self) {
        if self.history.is_empty() {
            return;
        }
        let j = match self.hist_nav {
            None => {
                self.stash = self.line.clone();
                self.history.len()
            }
            Some(j) => j,
        };
        if j == 0 {
            return; // already at the oldest entry
        }
        let next = self.history[j - 1].clone();
        self.hist_nav = Some(j - 1);
        self.replace_line(next);
    }

    /// Down arrow: move to the next (newer) history entry, or back to the
    /// stashed in-progress line once past the newest entry.
    fn history_next(&mut self) {
        let j = match self.hist_nav {
            None => return, // not navigating
            Some(j) => j,
        };
        let n = self.history.len();
        if j >= n {
            return;
        }
        let next = if j + 1 == n {
            self.hist_nav = None;
            core::mem::take(&mut self.stash)
        } else {
            self.hist_nav = Some(j + 1);
            self.history[j + 1].clone()
        };
        self.replace_line(next);
    }

    /// Discard the line being typed and reset the editing state (no history
    /// push). Used by Ctrl-C / Ctrl-Z.
    fn reset_line(&mut self) {
        self.touch();
        self.line.clear();
        self.cursor = 0;
        self.hist_nav = None;
        self.stash.clear();
        self.esc = EscState::Normal;
    }

    /// Commit the current line: push it to history (deduped against the most
    /// recent entry), then reset for the next line.
    fn commit(&mut self) {
        if !self.line.is_empty()
            && self.history.last().map(|h| h.as_slice()) != Some(self.line.as_slice())
        {
            self.history.push(self.line.clone());
            if self.history.len() > HISTORY_CAP {
                self.history.remove(0);
            }
        }
        self.reset_line();
    }

    fn replace_range(&mut self, start: usize, end: usize, value: &[u8]) -> bool {
        if start > self.cursor || self.cursor > end || end > self.line.len() {
            return false;
        }
        let mut next = Vec::with_capacity(self.line.len() - (end - start) + value.len());
        next.extend_from_slice(&self.line[..start]);
        next.extend_from_slice(value);
        next.extend_from_slice(&self.line[end..]);
        let cursor = start + value.len();
        term_emit(&self.line[self.cursor..]);
        term_erase(self.line.len());
        self.touch();
        self.line = next;
        self.cursor = cursor;
        term_emit(&self.line);
        term_bs(self.line.len() - self.cursor);
        true
    }
}

struct Editor(UnsafeCell<LineEditor>);
impl Editor {
    const fn new() -> Self {
        Editor(UnsafeCell::new(LineEditor::new()))
    }
    unsafe fn get(&self) -> &mut LineEditor {
        unsafe { &mut *self.0.get() }
    }
}
unsafe impl Sync for Editor {}

static EDITOR: Editor = Editor::new();

/// Bidirectional scratch buffer for the host control channel (`mc_ctl_*`). The
/// host sizes it via `mc_ctl_buf(len)`, writes its request, and reads results
/// back out of it. Lives in linear memory like the other buffers, so it is
/// captured by a snapshot along with everything else.
struct CtlBuffer(UnsafeCell<Vec<u8>>);
impl CtlBuffer {
    const fn new() -> Self {
        CtlBuffer(UnsafeCell::new(Vec::new()))
    }
    unsafe fn get(&self) -> &mut Vec<u8> {
        unsafe { &mut *self.0.get() }
    }
}
unsafe impl Sync for CtlBuffer {}
static CTL_BUFFER: CtlBuffer = CtlBuffer::new();

#[panic_handler]
fn panic(info: &core::panic::PanicInfo) -> ! {
    let msg = format!("kernel panic: {}\r\n", info.message());
    unsafe {
        bridge::mc_stderr_write(msg.as_ptr(), msg.len());
        core::arch::wasm32::unreachable();
    }
}

#[cfg(all(not(target_feature = "atomics"), target_family = "wasm"))]
#[global_allocator]
static ALLOCATOR: talc::wasm::WasmDynamicTalc = talc::wasm::new_wasm_dynamic_allocator();

/// The pid-1 boot tier from the image manifest's runtime contract, set by
/// `apply_boot_contract`; `None` = full (no narrowing). Newtype + `unsafe impl
/// Sync` is the kernel's single-threaded-static idiom (cf. `CtlBuffer`).
struct TierCell(core::cell::UnsafeCell<Option<task::Tier>>);
unsafe impl Sync for TierCell {}
static BOOT_TIER: TierCell = TierCell(core::cell::UnsafeCell::new(None));

/// Read the host's boot contract (`mc_boot_contract`) and apply it: set the VM
/// budget ceiling (caps every guest spawn) and record the pid-1 boot tier.
unsafe fn apply_boot_contract() {
    let mut buf = [0u8; 16];
    let n = unsafe { bridge::mc_boot_contract(buf.as_mut_ptr(), buf.len()) };
    if n < 16 {
        return; // no contract / host doesn't supply one
    }
    let tier_n = i32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]);
    let mem_mib = i32::from_le_bytes([buf[4], buf[5], buf[6], buf[7]]);
    let fuel = i64::from_le_bytes(buf[8..16].try_into().unwrap_or([0; 8]));

    let mut ceiling = wasm::Budget::HARD;
    if mem_mib > 0 {
        ceiling.mem_bytes = (mem_mib as usize).saturating_mul(1024 * 1024);
    }
    if fuel > 0 {
        ceiling.fuel = fuel as u64;
    }
    wasm::set_budget_ceiling(ceiling);

    unsafe {
        *BOOT_TIER.0.get() = task::Tier::from_arg(tier_n);
    }
}

/// The pid-1 boot tier (`None` = full / no narrowing).
unsafe fn boot_tier() -> Option<task::Tier> {
    unsafe { *BOOT_TIER.0.get() }
}

fn boot_policy() -> (task::Capabilities, Option<String>) {
    unsafe {
        match boot_tier() {
            Some(tier) => {
                let root = if tier.confines() {
                    Some(String::from("/home/user"))
                } else {
                    None
                };
                (tier.caps(), root)
            }
            None => (task::Capabilities::all(), None),
        }
    }
}

fn init_system() {
    unsafe {
        if STATE.is_initialized() {
            return;
        }

        match init::boot_system() {
            Ok((ns, scheduler)) => {
                *STATE.ns.get() = Some(ns);
                *STATE.scheduler.get() = Some(scheduler);
                *STATE.guest_runtime.get() = Some(wasm::GuestRuntime::new(wasm::new_engine()));

                // Seed the process environment. The canonical login shell
                // sources `/etc/profile` through shcore after it starts.
                {
                    let env = STATE.env();
                    env.insert(String::from("PATH"), String::from("/bin:/usr/bin"));
                    env.insert(String::from("HOME"), String::from("/home/user"));
                    env.insert(String::from("HOSTNAME"), String::from("agent-os"));
                }

                let sched_ptr: *const Scheduler =
                    (*STATE.scheduler.get()).as_ref().unwrap() as *const Scheduler;
                let ns_ptr: *const Namespace =
                    (*STATE.ns.get()).as_ref().unwrap() as *const Namespace;
                let procfs = ProcFs::new(sched_ptr, ns_ptr);
                // Mounted read-write: procfs enforces its own
                // per-file policy — the info files are read-only, but
                // `/proc/[pid]/ctl` is a writable control file. A blanket
                // namespace `read_only` flag would block the ctl write.
                (*STATE.ns.get()).as_ref().unwrap().mount_labeled(
                    "/proc",
                    Box::new(procfs),
                    "procfs",
                    false,
                );

                // netfs: the network as a file tree at /net.
                // It self-gates on CAP_NET via the caller, so mount it rw.
                let netfs = crate::fs::NetFs::new(sched_ptr);
                (*STATE.ns.get()).as_ref().unwrap().mount_labeled(
                    "/net",
                    Box::new(netfs),
                    "netfs",
                    false,
                );

                // envfs: the shell environment as files at
                // /env. Per-task: resolves against the calling task's env via
                // the scheduler, falling back to the kernel boot env map.
                let env_ptr: *mut BTreeMap<String, String> = STATE.env();
                let sched_ptr: *const Scheduler = STATE.scheduler();
                let envfs = crate::fs::EnvFs::new(sched_ptr, env_ptr);
                (*STATE.ns.get()).as_ref().unwrap().mount_labeled(
                    "/env",
                    Box::new(envfs),
                    "envfs",
                    false,
                );

                // servicefs: the resident-service registry as a listing at /svc
                // (observability — `ls /svc` shows the live services; you
                // `svc_connect` them, never open them). A stateless ZST reading the
                // snapshot-captured global registry; mount rw (it refuses writes itself).
                (*STATE.ns.get()).as_ref().unwrap().mount_labeled(
                    "/svc",
                    Box::new(crate::fs::servicefs::ServiceFs),
                    "servicefs",
                    false,
                );

                // toolsfs: a global read-only catalog tree at /tools. The broker service owns calls,
                // search, and mutation; this filesystem only exposes the checkpointed catalog as files,
                // so every process can browse tools without gaining egress authority.
                let toolsfs = crate::fs::ToolsFs::new(ns_ptr);
                (*STATE.ns.get()).as_ref().unwrap().mount_labeled(
                    "/tools",
                    Box::new(toolsfs),
                    "toolsfs",
                    true,
                );

                // Apply the image manifest's runtime contract: the budget
                // ceiling (every guest spawn is capped by it) and the pid-1 boot
                // tier. Must precede any guest load (so the shell is bounded too).
                apply_boot_contract();

                // Start the login shell FIRST so it claims pid 1 (`spawn_with_id(1)`): the init invariant
                // — an orphaned task reparents to pid 1, which must be the shell, never a resident service
                // (which has no parent and cannot reap). This only SPAWNS the shell; the scheduler runs it
                // later, after the grants below are recorded.
                boot_login_shell();

                // THEN activate eager resident services from /etc/services.d fragments (each runs its svc_serve
                // loop). They take pid 2+, and their grant `name → pid` is recorded here — before any user
                // task actually runs — so a first connect still finds them registered (or briefly blocks).
                activate_services();

                STATE.set_initialized();

                // Negotiate threading with the host. A return
                // of ≤ 0 — including a host that refuses with -1 — leaves
                // the kernel in cooperative mode. When the
                // host provisions workers it must drive `mc_worker_entry`;
                // `mc_tick` then coordinates only.
                #[cfg(feature = "threads")]
                {
                    let n = bridge::mc_threads_init(constants_rust::MAX_WORKERS);
                    sync::set_workers(n);
                }
            }
            Err(e) => {
                let err = format!("Boot failed: {:?}\r\n", e);
                bridge::mc_stderr_write(err.as_ptr(), err.len());
            }
        }
    }
}

/// Start the canonical interactive login shell. A missing or incompatible
/// `/bin/sh` leaves the VM in explicit maintenance mode: VFS and structured
/// control remain usable, but no second shell implementation is substituted.
unsafe fn boot_login_shell() {
    unsafe {
        if try_guest_login_shell() {
            *STATE.shell_available.get() = true;
        } else {
            start_maintenance_init();
        }
    }
}

/// Keep pid 1 present as the orphan-reaping/session anchor when the image has
/// no compatible shell. This task has no program and is deliberately not a
/// command interpreter.
unsafe fn start_maintenance_init() {
    unsafe {
        let sched = STATE.scheduler();
        let pid = sched
            .spawn_with_id(
                1,
                None,
                String::from("init"),
                String::from("init"),
                Vec::new(),
                String::from("/home/user"),
            )
            .unwrap_or_else(|| {
                sched.spawn(
                    None,
                    String::from("init"),
                    String::from("init"),
                    Vec::new(),
                    String::from("/home/user"),
                )
            });
        if let Some(task) = sched.get_task(pid) {
            task.env_mut().clone_from(STATE.env());
        }
        sched.detach(pid);
        let (caps, root) = boot_policy();
        sched.set_task_policy(pid, caps, root);
        *STATE.login_pid.get() = pid;
        *STATE.shell_available.get() = false;
        *STATE.console_pipe.get() = None;
        let message = b"Shell unavailable: image must provide a compatible /bin/sh\r\n";
        bridge::mc_stderr_write(message.as_ptr(), message.len());
    }
}

/// Release the kernel-held console write end, if present.
unsafe fn close_console_writer() {
    unsafe {
        if let Some(p) = STATE.console() {
            p.close_write();
        }
        *STATE.console_pipe.get() = None;
        STATE.console_pending().clear();
    }
}

/// Push as much of the queued console backlog into the console pipe as fits,
/// dropping what was accepted from the front. The remainder (if the pipe is
/// full) stays queued for the next tick — backpressure, never truncation.
unsafe fn flush_console() {
    unsafe {
        let pending = STATE.console_pending();
        if pending.is_empty() {
            return;
        }
        if let Some(p) = STATE.console() {
            let n = p.buffer.write(pending);
            if n > 0 {
                pending.drain(0..n);
            }
        } else {
            // Maintenance mode: no shell consumes console input.
            pending.clear();
        }
    }
}

/// Try to spawn a compatible `/bin/sh` as the login shell (a normal pid-1
/// task). Compatibility includes the generated resident completion boundary.
unsafe fn try_guest_login_shell() -> bool {
    unsafe {
        let sched = STATE.scheduler();
        let ns = STATE.ns();
        let engine = STATE.guest_runtime();
        let path: String = STATE
            .env()
            .get("PATH")
            .cloned()
            .unwrap_or_else(|| String::from("/bin:/usr/bin"));
        let bytes = match wasm::resolve_program(ns, "/home/user", "sh", &path) {
            Some(b) => b,
            None => return false,
        };
        let prog = match wasm::GuestProgram::load(
            engine,
            &bytes,
            alloc::vec![String::from("sh"), String::from("--login")],
            &path,
        ) {
            Ok(p) => p,
            Err(_) => return false,
        };
        if !prog.supports_resident_control() {
            return false;
        }
        // The login shell is always pid 1: reuse id 1 on respawn so `/proc/1`
        // never disappears (fall back to a fresh id only if 1 is somehow live).
        let pid = sched
            .spawn_with_id(
                1,
                None,
                String::from("sh"),
                String::from("sh"),
                Vec::new(),
                String::from("/home/user"),
            )
            .unwrap_or_else(|| {
                sched.spawn(
                    None,
                    String::from("sh"),
                    String::from("sh"),
                    Vec::new(),
                    String::from("/home/user"),
                )
            });
        // Console pipe: the kernel keeps the write end (an extra writer) so the
        // shell never sees EOF until Ctrl-D; the shell holds the read end.
        let pipe = sched.alloc_pipe();
        pipe.add_writer();
        *STATE.console_pipe.get() = Some(pipe as *const ipc::Pipe);
        let task = sched.get_task(pid).expect("spawned sh");
        task.set_namespace(ns.fork(pid));
        task.set_stdin(Box::new(io::PipeSource::new(pipe)));
        task.set_program(Box::new(prog));
        // Seed pid-1's per-task env from the boot env. `/bin/sh --login`
        // sources `/etc/profile`; children then inherit the resulting state.
        task.env_mut().clone_from(STATE.env());
        // pid-1 boots at the image manifest's tier, or full when unset.
        let (caps, root) = boot_policy();
        sched.set_task_policy(pid, caps, root);
        *STATE.login_pid.get() = pid;
        true
    }
}

// SERVICE_MARKER (the reserved SERVICE-mode argv[1]) is now the projected contract constant
// `constants.kdl → service-marker`, imported above via `wasm::abi` — one source for the kernel and
// every service binary, Rust and Zig (codex #5).

struct ServiceSpec {
    binary: String,
    eager: bool,
}

/// Look up a declared service's fragment at `/etc/services.d/<name>.json`. `None` if the fragment is
/// absent/unreadable/malformed. A fragment is `{ binary, eager? }`; the tier is deliberately NOT there
/// — the binary's own `mc_tier` is the single source of truth, so a fragment can never widen the
/// privilege a binary declared it needs.
unsafe fn lookup_service_spec(name: &str) -> Option<ServiceSpec> {
    unsafe {
        if !fs::servicefs::valid_service_name(name) {
            return None;
        }
        let manifest = read_kernel_file(STATE.ns(), &format!("/etc/services.d/{name}.json"))?;
        let text = core::str::from_utf8(&manifest).ok()?;
        let doc = json::parse(text).ok()?;
        let spec = doc.as_obj()?;
        let binary = JsonObj(spec)
            .get("binary")
            .and_then(|b| b.as_str())
            .map(String::from)
            .unwrap_or_else(|| format!("/bin/{name}"));
        let eager = JsonObj(spec)
            .get("eager")
            .and_then(|e| e.as_bool())
            .unwrap_or(false);
        Some(ServiceSpec { binary, eager })
    }
}

struct JsonObj<'a>(&'a [(String, json::Json)]);

impl<'a> JsonObj<'a> {
    fn get(&self, key: &str) -> Option<&'a json::Json> {
        self.0.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }
}

/// Spawn a service `binary` in SERVICE mode (argv[1] = the marker), at the binary's OWN declared
/// tier (`mc_tier`), in a fork of the boot namespace, and record its activation grant (`name → pid`).
/// The service `svc_serve`s on its first tick; a client connecting in the meantime blocks until it
/// does. `None` if the binary is missing, fails to load, or declares a DIFFERENT service name
/// (SYSTEMS.md — a binary cannot be activated under a name it did not claim).
unsafe fn spawn_service(name: &str, binary: &str) -> Option<task::TaskId> {
    unsafe {
        let ns = STATE.ns();
        let engine = STATE.guest_runtime();
        let sched = STATE.scheduler();
        let path = STATE
            .env()
            .get("PATH")
            .cloned()
            .unwrap_or_else(|| String::from("/bin:/usr/bin"));
        // The manifest binary is an absolute VFS path; resolve it EXACTLY (not basename-on-PATH), so a
        // service is always the binary its manifest names — a manifest cannot appear to name one path
        // and silently activate another that happens to share a basename (codex #8).
        if !binary.starts_with('/') {
            return None;
        }
        let bytes = read_kernel_file(ns, binary)?;
        // A binary may not be activated unless it declares exactly this service
        // name (mc_service, SYSTEMS.md). Build-time attestation should catch bad
        // service binaries, but the runtime manifest is still a trust boundary.
        match wasm::declared_service(&bytes) {
            Some(declared) if declared == name => {}
            _ => return None,
        }
        // The binary's DECLARED tier is the source of truth — the manifest carries none, and a service
        // task has no parent tier to inherit. So a binary that declares the service name but NO tier has
        // no ceiling to activate at: fail closed (A9 default-deny) rather than widen a malformed/stripped
        // service binary to Full capabilities.
        let tier = wasm::declared_tier(&bytes)?;
        let argv = alloc::vec![String::from(binary), String::from(SERVICE_MARKER)];
        let prog = wasm::GuestProgram::load(engine, &bytes, argv, &path).ok()?;
        let pid = sched.spawn(
            None,
            String::from(name),
            String::from(binary),
            alloc::vec![String::from(SERVICE_MARKER)],
            String::from("/"),
        );
        let task = sched.get_task(pid)?;
        task.set_namespace(ns.fork(pid));
        task.set_program(Box::new(prog));
        let root = if tier.confines() {
            Some(String::from("/"))
        } else {
            None
        };
        sched.set_task_policy(pid, tier.caps(), root);
        let deadline = wall_now_ms() + fs::servicefs::ACTIVATION_TIMEOUT_MS;
        fs::servicefs::mark_activating(name, pid, deadline);
        Some(pid)
    }
}

/// EAGER service activation at boot: spawn each service marked `"eager": true` in
/// `/etc/services.d/<name>.json`. Lazy services (the default) are instead spawned on their first
/// `svc_connect` ([`activate_service_lazily`]), so a flavor pays a service's cold start only when
/// something actually uses it. Absent/malformed fragments are ignored — boot continues.
unsafe fn activate_services() {
    unsafe {
        let Some(mut names) = read_kernel_dir(STATE.ns(), "/etc/services.d") else {
            return;
        };
        names.sort();
        for file in names {
            let Some(name) = file.strip_suffix(".json") else {
                continue;
            };
            if !fs::servicefs::valid_service_name(name) {
                continue; // a fragment name that isn't a valid service name can't match any binary
            }
            let Some(spec) = lookup_service_spec(name) else {
                continue;
            };
            if spec.eager {
                spawn_service(name, &spec.binary);
            }
        }
    }
}

/// Lazily (re-)activate a service on its first `svc_connect` (spawn-on-connect): look it up in
/// `/etc/services.d/<name>.json` and spawn it. Returns whether an activation was STARTED (the connecting
/// client then blocks until it serves); `false` means the name is not a declared service. This is
/// also the crash-recovery path — a connect after a service died re-runs it and gets a fresh instance.
pub(crate) unsafe fn activate_service_lazily(name: &str) -> bool {
    unsafe {
        match lookup_service_spec(name) {
            Some(spec) => spawn_service(name, &spec.binary).is_some(),
            None => false,
        }
    }
}

/// Read a whole (small) file from the boot namespace. `None` if it is absent or
/// unreadable.
fn read_kernel_file(ns: &Namespace, path: &str) -> Option<Vec<u8>> {
    let kpath = KPath::new(path);
    ns.stat(&kpath).ok()?;
    let mut handle = ns.open(&kpath, OpenFlags::READ).ok()?;
    let mut out = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        match handle.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => out.extend_from_slice(&buf[..n]),
            Err(_) => return None,
        }
    }
    Some(out)
}

/// List a small boot-namespace directory as names only. `None` if absent/unreadable.
fn read_kernel_dir(ns: &Namespace, path: &str) -> Option<Vec<String>> {
    let kpath = KPath::new(path);
    let entries = ns.readdir_owner(&kpath).ok()?;
    Some(entries.into_iter().map(|e| e.name).collect())
}

// ---------- Exported functions ----------

/// The wall clock (ms since the Unix epoch) sampled at the start of the current
/// tick. The filesystem uses it to stamp mtime/atime/ctime without a host call
/// per operation. Returns `0` before the first `mc_tick` (boot).
pub(crate) fn wall_now_ms() -> i64 {
    unsafe { *STATE.wall_ms.get() }
}

pub(crate) fn mc_init() -> i32 {
    init_system();
    0
}

pub(crate) fn mc_tick() -> i32 {
    // Hold the Big Kernel Lock for the whole tick. No-op on the
    // cooperative-only build; serializes against `mc_worker_entry` and
    // `mc_input` on the threaded build.
    let _bkl = sync::lock_kernel();
    unsafe {
        // Sample the wall clock once per tick (before init, so boot-time file
        // creation is stamped too). Filesystem metadata reads this cached value
        // via `wall_now_ms()` — no host call per read/write.
        *STATE.wall_ms.get() = bridge::mc_time_now();
        if !STATE.is_initialized() {
            init_system();
            return 1;
        }

        let scheduler = STATE.scheduler();
        let ns = STATE.ns();

        // 1. Cook terminal input for the one canonical guest shell. In
        // maintenance mode discard it so an absent shell cannot turn host
        // input into unbounded kernel memory.
        if STATE.shell_available() {
            drain_input_line(scheduler);
        } else {
            INPUT_BUFFER.get().clear();
        }

        // 2. Wake any task whose pipe condition is now satisfied, then
        //    step every ready task once. The foreground current stage and
        //    all background pipelines share the single ready queue, so one
        //    round advances them together. In threaded mode the stepping is
        //    delegated to `mc_worker_entry` (the host drains the ready
        //    queue via workers between ticks), so `mc_tick` only coordinates.
        scheduler.check_unblocked();
        if !sync::threaded() {
            run_round(scheduler, ns);
        }

        // 2.5 Host-backed mount maintenance: flush parked write-commits and
        //     reclaim in-flight calls left by tasks that have since died (so a
        //     killed mid-mount-op task can't strand a host handle and pin
        //     `inflight_egress` non-zero forever). `SYSTEM_CALLER` (the host
        //     control channel) is always treated as live.
        fs::mountfs::drain_all(|caller| {
            caller == vfs::SYSTEM_CALLER || scheduler.get_task(caller).is_some()
        });
        fs::persistfs::drain_all(|caller| {
            caller == vfs::SYSTEM_CALLER || scheduler.get_task(caller).is_some()
        });
        drive_pending_autocomplete();

        // 2.6 Login-shell keep-alive. If the canonical shell can no longer be
        // loaded, transition to explicit maintenance mode.
        if STATE.shell_available() {
            let lp = *STATE.login_pid.get();
            let dead = scheduler
                .get_task(lp)
                .map(|t| matches!(t.state, TaskState::Zombie))
                .unwrap_or(true);
            if dead {
                // Closing the controlling terminal hangs up the session. The
                // login shell is the root of the whole process tree, so every
                // other live task is a member of its session — deliver SIGHUP to
                // all of them (background jobs sit in their own process groups, so
                // a single `signal_group` would miss them). Plain jobs terminate;
                // jobs that ignore SIGHUP (`nohup`, and their children via
                // disposition inheritance) survive. Done before the reap so the
                // now-zombie shell is skipped.
                scheduler.signal_all_except(lp, SIGHUP);
                scheduler.reap_zombie(lp);
                close_console_writer();
                scheduler.drop_dead_pipes();
                if try_guest_login_shell() {
                    *STATE.shell_available.get() = true;
                } else {
                    start_maintenance_init();
                }
            }
        }

        // 3.5 Advance host control-channel exec jobs (mc_ctl_exec_*). Their
        //     tasks share the ready queue (stepped in the round above); here we
        //     only run each job's stage machine and record completion. Kept
        //     separate from the interactive foreground so an operator exec and
        //     the shell prompt never interleave their output.
        {
            let jobs = STATE.ctl_jobs();
            for job in jobs.values_mut() {
                if job.done {
                    continue;
                }
                match &mut job.body {
                    CtlBody::Guest { pid } => {
                        // The `/bin/sh -c` task runs via run_round above; finish
                        // the job when it becomes a zombie.
                        let p = *pid;
                        let exited = scheduler
                            .get_task(p)
                            .map(|t| matches!(t.state, TaskState::Zombie))
                            .unwrap_or(true);
                        if exited {
                            job.exit_code = scheduler.get_exit_code(p).unwrap_or(0);
                            scheduler.reap_zombie(p);
                            scheduler.drop_dead_pipes();
                            job.done = true;
                        }
                    }
                }
            }
        }
    }
    1
}

/// Consume bytes from INPUT_BUFFER through the cooked line editor and feed
/// complete lines to the canonical guest shell.
unsafe fn drain_input_line(scheduler: &Scheduler) {
    // Drain any console backlog first — a previous long line may not have fit
    // the pipe in one go. Done before the empty-input early-return so the
    // backlog keeps flowing across ticks even when nothing new is typed.
    unsafe { flush_console() };

    let input_buf = unsafe { INPUT_BUFFER.get() };
    if input_buf.is_empty() {
        return;
    }
    let input: Vec<u8> = input_buf.clone();
    input_buf.clear();

    let ed = unsafe { EDITOR.get() };
    let mut i = 0;
    while i < input.len() {
        let byte = input[i];
        i += 1; // advance now; the foreground early-return below saves `input[i..]`

        // Mid-sequence: route the byte through the escape-sequence parser. State
        // persists across calls, so a sequence split across ticks still parses.
        match ed.esc {
            EscState::Esc => {
                ed.esc = if byte == b'[' || byte == b'O' {
                    ed.param = 0;
                    EscState::Csi
                } else {
                    EscState::Normal // not a sequence we recognize; drop it
                };
                continue;
            }
            EscState::Csi => {
                if byte.is_ascii_digit() {
                    ed.param = ed
                        .param
                        .saturating_mul(10)
                        .saturating_add((byte - b'0') as u16);
                    continue;
                }
                ed.esc = EscState::Normal;
                match byte {
                    b'A' => ed.history_prev(),
                    b'B' => ed.history_next(),
                    b'C' => ed.right(),
                    b'D' => ed.left(),
                    b'H' => ed.home(),
                    b'F' => ed.end(),
                    b'~' => match ed.param {
                        1 | 7 => ed.home(),
                        4 | 8 => ed.end(),
                        3 => ed.delete_fwd(),
                        _ => {}
                    },
                    _ => {}
                }
                continue;
            }
            EscState::Normal => {}
        }

        if byte == 0x1b {
            ed.esc = EscState::Esc;
        } else if byte == 0x7F || byte == 0x08 {
            ed.backspace();
        } else if byte == 0x01 {
            ed.home(); // Ctrl-A → start of line
        } else if byte == 0x05 {
            ed.end(); // Ctrl-E → end of line
        } else if byte == b'\t' {
            interactive_autocomplete(ed);
        } else if byte == 0x04 {
            // Ctrl-D on an empty line: close the console write end → the guest
            // shell sees EOF on its next read and exits (then is respawned).
            if ed.line.is_empty() {
                if let Some(p) = unsafe { STATE.console() } {
                    p.close_write();
                }
            }
        } else if byte == 0x03 {
            // Ctrl-C: discard the partial line and deliver SIGINT to the
            // terminal's foreground process group. A running foreground command
            // (default disposition) dies; the shell ignores SIGINT, so at the
            // prompt its console read takes EINTR and redraws a fresh prompt.
            term_emit(b"^C\r\n");
            ed.reset_line();
            let pgid = scheduler.foreground_pgid();
            scheduler.signal_group(pgid, SIGINT);
        } else if byte == 0x1a {
            // Ctrl-Z: discard the partial line and deliver SIGTSTP to the
            // foreground group, suspending a running foreground command.
            term_emit(b"^Z\r\n");
            ed.reset_line();
            let pgid = scheduler.foreground_pgid();
            scheduler.signal_group(pgid, SIGTSTP);
        } else if byte == b'\n' || byte == b'\r' {
            term_emit(b"\r\n");
            // Snapshot before commit (which clears the line + pushes to history).
            let line_bytes = ed.line.clone();
            ed.commit();
            // Queue the cooked line (with newline) for pid-1 sh's stdin and
            // flush as much as the pipe accepts; the rest drains next tick.
            let mut bytes = line_bytes;
            bytes.push(b'\n');
            unsafe {
                STATE.console_pending().extend_from_slice(&bytes);
                flush_console();
            }
        } else if byte.is_ascii_graphic() || byte == b' ' {
            ed.insert(byte);
        }
    }
}

fn list_completions(editor: &LineEditor, completion: &ResolvedAutocomplete) {
    let result = &completion.result;
    term_emit(b"\r\n");
    for (index, item) in result.items.iter().enumerate() {
        if index != 0 {
            term_emit(b"  ");
        }
        term_emit(item.label.as_bytes());
    }
    if result.truncated {
        term_emit(b"  ...");
    }
    term_emit(if completion.continuation { b"\r\n> " } else { b"\r\n$ " });
    term_emit(&editor.line);
    term_bs(editor.line.len().saturating_sub(editor.cursor));
}

fn apply_interactive_autocomplete(
    editor: &mut LineEditor,
    completion: ResolvedAutocomplete,
    list: bool,
) {
    let result = &completion.result;
    if result.items.is_empty() {
        term_emit(b"\x07");
        editor.tab_armed = None;
        return;
    }
    let start = result.replace_start as usize;
    let end = result.replace_end as usize;
    if start > editor.cursor || editor.cursor > end || end > editor.line.len() {
        term_emit(b"\x07");
        editor.tab_armed = None;
        return;
    }

    if result.items.len() == 1 {
        let item = &result.items[0];
        let mut value = item.value.as_bytes().to_vec();
        if item.kind != "directory" && end == editor.line.len() {
            value.push(b' ');
        }
        if !editor.replace_range(start, end, &value) {
            term_emit(b"\x07");
        }
        editor.tab_armed = None;
        return;
    }

    let current = &editor.line[start..end];
    if !result.common_prefix.is_empty() && result.common_prefix.as_bytes() != current {
        if !editor.replace_range(start, end, result.common_prefix.as_bytes()) {
            term_emit(b"\x07");
            return;
        }
    }
    if list {
        list_completions(editor, &completion);
    }
    editor.tab_armed = Some((editor.line.clone(), editor.cursor));
}

fn interactive_autocomplete(editor: &mut LineEditor) {
    let list = editor
        .tab_armed
        .as_ref()
        .is_some_and(|(line, cursor)| line == &editor.line && *cursor == editor.cursor);
    let pending = unsafe { STATE.pending_autocomplete() };
    if pending
        .as_ref()
        .is_some_and(|request| request.generation == editor.generation)
    {
        if list {
            pending.as_mut().expect("checked").list = true;
        }
        return;
    }
    let request = AutocompleteRequest {
        source: editor.line.clone(),
        cursor: editor.cursor as u32,
        cwd: None,
        env: BTreeMap::new(),
        limit: AUTOCOMPLETE_MAX_ITEMS as u32,
    };
    match autocomplete(request.clone(), true) {
        Ok(result) => apply_interactive_autocomplete(editor, result, list),
        Err(EAGAIN) => {
            *pending = Some(PendingAutocomplete {
                request,
                generation: editor.generation,
                list,
            });
        }
        Err(_) => term_emit(b"\x07"),
    }
}

unsafe fn drive_pending_autocomplete() {
    unsafe {
        let Some(pending) = STATE.pending_autocomplete().take() else {
            return;
        };
        let editor = EDITOR.get();
        if pending.generation != editor.generation {
            return;
        }
        match autocomplete(pending.request.clone(), true) {
            Ok(result) => apply_interactive_autocomplete(editor, result, pending.list),
            Err(EAGAIN) => *STATE.pending_autocomplete() = Some(pending),
            Err(_) => term_emit(b"\x07"),
        }
    }
}

pub(crate) fn mc_input(ptr: *const u8, len: usize) {
    let _bkl = sync::lock_kernel();
    unsafe {
        let bytes = core::slice::from_raw_parts(ptr, len);
        INPUT_BUFFER.get().extend_from_slice(bytes);
    }
}

pub(crate) fn mc_resize(_cols: i32, _rows: i32) {
    // Known gap — no-op until the kernel does line wrapping.
}

// ---------- Control channel (host-initiated, structured) ----------
//
// New kernel EXPORTS (alongside mc_init/mc_tick/mc_input) that let a host drive
// the VM with fidelity the prompt-scraping path lacks: structured file ops and
// an `exec` that reports a REAL exit code plus separately-captured
// stdout/stderr. File ops run synchronously under SYSTEM_CALLER against the root
// namespace; `exec` is async (it spans cooperative ticks) and mirrors the HTTP
// poll discipline. These are exports, not bridge imports — the host already
// drives the kernel through exports, so this needs no new host capability: the
// kernel still performs every operation through its own VFS/scheduler; the host
// only moves bytes.
//
// Marshalling: the host sizes/addresses a kernel-owned control buffer via
// `mc_ctl_buf(len) -> ptr`, writes its request there, calls an op with byte
// offsets/lengths into that buffer, and reads any result back out of it. An op
// may REPLACE the buffer (e.g. with file contents), so the host re-queries
// `mc_ctl_buf(0)` for the current pointer before reading a result.

/// Ensure the control buffer is at least `len` bytes and return its address in
/// linear memory. The host writes its request bytes here, then invokes an op.
pub(crate) fn mc_ctl_buf(len: usize) -> *mut u8 {
    let _bkl = sync::lock_kernel();
    unsafe {
        let buf = CTL_BUFFER.get();
        if buf.len() < len {
            buf.resize(len, 0);
        }
        buf.as_mut_ptr()
    }
}

/// The negative errno a control op returns on failure (reuses the kernel's
/// canonical FsError → errno mapping so the control channel and the syscall ABI
/// never drift).
fn ctl_neg_errno(e: vfs::FsError) -> i32 {
    -errno_from_fs(e)
}

/// Copy `len` bytes out of the control buffer at `ptr` (bounds-checked).
unsafe fn ctl_bytes(ptr: u32, len: u32) -> Option<Vec<u8>> {
    unsafe {
        let buf = CTL_BUFFER.get();
        let start = ptr as usize;
        let end = start.checked_add(len as usize)?;
        if end > buf.len() {
            return None;
        }
        Some(buf[start..end].to_vec())
    }
}

/// Read a UTF-8 string (a path or command line) out of the control buffer.
unsafe fn ctl_str(ptr: u32, len: u32) -> Option<String> {
    String::from_utf8(unsafe { ctl_bytes(ptr, len)? }).ok()
}

/// Read a file in full. The path is in the control buffer at
/// `[path_ptr..path_ptr+path_len]`. On success the buffer is REPLACED with the
/// file's contents and its length (>= 0) is returned; otherwise a negative
/// errno. Runs as SYSTEM_CALLER against the root namespace.
pub(crate) fn mc_ctl_read(path_ptr: u32, path_len: u32) -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        if !STATE.is_initialized() {
            return -EIO;
        }
        let path = match ctl_str(path_ptr, path_len) {
            Some(p) => p,
            None => return -EINVAL,
        };
        // `read` follows the final symlink — POSIX `open` semantics — so a ctl read of a
        // symlink path returns the TARGET's content. Canonicalize through the link before
        // opening; `stat`/`readdir` stay lstat (the namespace is the kernel's only
        // symlink-following site, so the following must be requested here).
        let real = match STATE.ns().canonicalize(&KPath::new(&path), true) {
            Ok(c) => c,
            Err(e) => return ctl_neg_errno(e),
        };
        let mut h = match STATE
            .ns()
            .open_as(vfs::SYSTEM_CALLER, &real, OpenFlags::READ)
        {
            Ok(h) => h,
            Err(e) => return ctl_neg_errno(e),
        };
        let mut out = Vec::new();
        let mut tmp = [0u8; 4096];
        loop {
            match h.read(&mut tmp) {
                Ok(0) => break,
                Ok(n) => out.extend_from_slice(&tmp[..n]),
                Err(vfs::FsError::WouldBlock) => return -EAGAIN,
                Err(e) => return ctl_neg_errno(e),
            }
        }
        let len = out.len() as i32;
        *CTL_BUFFER.get() = out;
        len
    }
}

/// Read the target text of a symlink without following it. The path is in the
/// control buffer at `[path_ptr..path_ptr+path_len]`; on success the buffer is
/// replaced with the UTF-8 target bytes.
pub(crate) fn mc_ctl_readlink(path_ptr: u32, path_len: u32) -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        if !STATE.is_initialized() {
            return -EIO;
        }
        let path = match ctl_str(path_ptr, path_len) {
            Some(p) => p,
            None => return -EINVAL,
        };
        let target = match STATE.ns().readlink(&KPath::new(&path)) {
            Ok(target) => target,
            Err(e) => return ctl_neg_errno(e),
        };
        let out = target.into_bytes();
        let len = out.len() as i32;
        *CTL_BUFFER.get() = out;
        len
    }
}

/// Serialize the root CoW overlay's writable diff into a content-addressed `.tar`
/// layer (the `commit` primitive — inverse of `tarfs`): write the bytes to
/// the control buffer and return their length. `-EINVAL` if root isn't an overlay,
/// `-EIO` before init. The host reads it via `mc_ctl_buf(0)`, like `mc_ctl_read`.
pub(crate) fn mc_commit_layer() -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        if !STATE.is_initialized() {
            return -EIO;
        }
        let bytes = match STATE.ns().commit_root_layer() {
            Some(b) => b,
            None => return -EINVAL,
        };
        let len = bytes.len() as i32;
        *CTL_BUFFER.get() = bytes;
        len
    }
}

/// Write a file, truncating it first. The control buffer holds the path at
/// `[path_ptr..+path_len]` and the data at `[data_ptr..+data_len]`. Returns the
/// number of bytes written (>= 0) or a negative errno.
pub(crate) fn mc_ctl_write(path_ptr: u32, path_len: u32, data_ptr: u32, data_len: u32) -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        if !STATE.is_initialized() {
            return -EIO;
        }
        let path = match ctl_str(path_ptr, path_len) {
            Some(p) => p,
            None => return -EINVAL,
        };
        let data = match ctl_bytes(data_ptr, data_len) {
            Some(d) => d,
            None => return -EINVAL,
        };
        let mut h =
            match STATE
                .ns()
                .open_as(vfs::SYSTEM_CALLER, &KPath::new(&path), OpenFlags::TRUNCATE)
            {
                Ok(h) => h,
                Err(e) => return ctl_neg_errno(e),
            };
        let mut written = 0usize;
        while written < data.len() {
            match h.write(&data[written..]) {
                Ok(0) => break,
                Ok(n) => written += n,
                Err(e) => return ctl_neg_errno(e),
            }
        }
        written as i32
    }
}

/// List a directory. The path is in the control buffer. On success the buffer
/// is replaced with an encoded [`CtlDirEntries`] frame and the total length is
/// returned; otherwise a negative errno.
pub(crate) fn mc_ctl_readdir(path_ptr: u32, path_len: u32) -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        if !STATE.is_initialized() {
            return -EIO;
        }
        let path = match ctl_str(path_ptr, path_len) {
            Some(p) => p,
            None => return -EINVAL,
        };
        let entries = match STATE.ns().readdir(vfs::SYSTEM_CALLER, &KPath::new(&path)) {
            Ok(e) => e,
            Err(e) => return ctl_neg_errno(e),
        };
        let out = CtlDirEntries {
            entries: entries
                .into_iter()
                .map(|e| CtlDirEntry {
                    name: e.name,
                    is_dir: matches!(e.node_type, NodeType::Dir),
                    is_symlink: matches!(e.node_type, NodeType::Symlink),
                })
                .collect(),
        }
        .encode();
        let len = out.len() as i32;
        *CTL_BUFFER.get() = out;
        len
    }
}

/// Stat a path. On success the buffer is replaced with an encoded
/// [`CtlFileStat`] frame and its byte length is returned; otherwise a negative
/// errno.
pub(crate) fn mc_ctl_stat(path_ptr: u32, path_len: u32) -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        if !STATE.is_initialized() {
            return -EIO;
        }
        let path = match ctl_str(path_ptr, path_len) {
            Some(p) => p,
            None => return -EINVAL,
        };
        // `stat_as` (not the synchronous `stat`) so an identity-aware filesystem —
        // a host-backed `MountFs` — asks its driver for the real terminal metadata
        // instead of returning the provisional directory it uses for resolution. It
        // may yield (`WouldBlock` → `-EAGAIN`); the host retries. Plain filesystems
        // fall back to the synchronous path, so this is transparent for them.
        let md = match STATE.ns().stat_as(vfs::SYSTEM_CALLER, &KPath::new(&path)) {
            Ok(m) => m,
            Err(vfs::FsError::WouldBlock) => return -EAGAIN,
            Err(e) => return ctl_neg_errno(e),
        };
        if md.size > i64::MAX as u64 {
            return -EINVAL;
        }
        let out = CtlFileStat {
            size: md.size as i64,
            is_dir: matches!(md.node_type, NodeType::Dir),
            is_symlink: matches!(md.node_type, NodeType::Symlink),
            nlink: md.nlink,
            mode: md.mode as u32,
        }
        .encode();
        let len = out.len() as i32;
        *CTL_BUFFER.get() = out;
        len
    }
}

/// Create a directory. Returns 0 or a negative errno.
pub(crate) fn mc_ctl_mkdir(path_ptr: u32, path_len: u32) -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        if !STATE.is_initialized() {
            return -EIO;
        }
        let path = match ctl_str(path_ptr, path_len) {
            Some(p) => p,
            None => return -EINVAL,
        };
        match STATE.ns().mkdir(vfs::SYSTEM_CALLER, &KPath::new(&path)) {
            Ok(()) => 0,
            Err(e) => ctl_neg_errno(e),
        }
    }
}

/// Remove a file or empty directory. Returns 0 or a negative errno.
pub(crate) fn mc_ctl_unlink(path_ptr: u32, path_len: u32) -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        if !STATE.is_initialized() {
            return -EIO;
        }
        let path = match ctl_str(path_ptr, path_len) {
            Some(p) => p,
            None => return -EINVAL,
        };
        match STATE.ns().unlink(vfs::SYSTEM_CALLER, &KPath::new(&path)) {
            Ok(()) => 0,
            Err(e) => ctl_neg_errno(e),
        }
    }
}

/// Set POSIX permission bits. Returns 0 or a negative errno.
pub(crate) fn mc_ctl_chmod(path_ptr: u32, path_len: u32, mode: u32) -> i32 {
    let _bkl = sync::lock_kernel();
    if mode > 0o7777 {
        return -EINVAL;
    }
    unsafe {
        if !STATE.is_initialized() {
            return -EIO;
        }
        let path = match ctl_str(path_ptr, path_len) {
            Some(p) => p,
            None => return -EINVAL,
        };
        match STATE.ns().set_mode(&KPath::new(&path), mode as u16) {
            Ok(()) => 0,
            Err(e) => ctl_neg_errno(e),
        }
    }
}

/// Create a symbolic link at `link` with target text `target`. The control buffer
/// holds the target at `[target_ptr..+target_len]` and the link path at
/// `[link_ptr..+link_len]` (the two-region layout `mc_ctl_write` uses). Returns 0
/// or a negative errno.
pub(crate) fn mc_ctl_symlink(
    target_ptr: u32,
    target_len: u32,
    link_ptr: u32,
    link_len: u32,
) -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        if !STATE.is_initialized() {
            return -EIO;
        }
        let target = match ctl_str(target_ptr, target_len) {
            Some(t) => t,
            None => return -EINVAL,
        };
        let link = match ctl_str(link_ptr, link_len) {
            Some(l) => l,
            None => return -EINVAL,
        };
        match STATE.ns().symlink(&target, &KPath::new(&link)) {
            Ok(()) => 0,
            Err(e) => ctl_neg_errno(e),
        }
    }
}

/// Mount a host-backed driver at `path`. The driver is reached over
/// the `mc_host_call` bridge under a handler name equal to `path` — the Unix
/// convention: a mount's name IS its absolute path (conventionally under `/mnt/`).
/// `read_only != 0` mounts it read-only (the namespace rejects writes). The mount
/// goes into the ROOT namespace, so every subsequent `vm.exec`/`vm.session` (which
/// forks root) and every `vm.fs.*` op resolves it. The guest login shell owns a
/// per-process fork created during boot, so mirror the host mount into that one
/// long-lived namespace as well; otherwise commands typed at the prompt disagree
/// with `vm.exec` about what is mounted. Returns 0 or a negative errno.
pub(crate) fn mc_ctl_mount(path_ptr: u32, path_len: u32, read_only: i32) -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        if !STATE.is_initialized() {
            return -EIO;
        }
        let path = match ctl_str(path_ptr, path_len) {
            Some(p) => p,
            None => return -EINVAL,
        };
        // A mount point — and thus the handler name — must be absolute. This also
        // keeps mount handler names disjoint from bare tool names (which never
        // begin with `/`), so the one host-call router can't confuse them.
        if !path.starts_with('/') {
            return -EINVAL;
        }
        let read_only = read_only != 0;
        let fs = crate::fs::MountFs::new(&path);
        STATE
            .ns()
            .mount_labeled(&path, Box::new(fs), "mountfs", read_only);
        let login_pid = *STATE.login_pid.get();
        if let Some(login_ns) = STATE
            .scheduler()
            .get_task(login_pid)
            .and_then(|task| task.namespace())
        {
            let login_fs = crate::fs::MountFs::new(&path);
            login_ns.mount_labeled(&path, Box::new(login_fs), "mountfs", read_only);
        }
        0
    }
}

/// Unmount a host-backed mount at `path`. Returns 0 or a negative errno (`EBUSY`-
/// style `NotEmpty` if a child mount still lives beneath it).
pub(crate) fn mc_ctl_unmount(path_ptr: u32, path_len: u32) -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        if !STATE.is_initialized() {
            return -EIO;
        }
        let path = match ctl_str(path_ptr, path_len) {
            Some(p) => p,
            None => return -EINVAL,
        };
        match STATE.ns().unmount(&path) {
            Ok(()) => {
                let login_pid = *STATE.login_pid.get();
                if let Some(login_ns) = STATE
                    .scheduler()
                    .get_task(login_pid)
                    .and_then(|task| task.namespace())
                {
                    match login_ns.unmount(&path) {
                        Ok(()) | Err(vfs::FsError::NotFound) => {}
                        Err(e) => return ctl_neg_errno(e),
                    }
                }
                0
            }
            Err(e) => ctl_neg_errno(e),
        }
    }
}

enum CtlSvcAdvance {
    Pending,
    Done,
}

unsafe fn ctl_service_channel(
    name: &str,
) -> Result<Option<Rc<RefCell<fs::servicefs::ServiceChannel>>>, i32> {
    unsafe {
        if let Some(channel) = fs::servicefs::lookup_service(name) {
            return Ok(Some(channel));
        }
        match fs::servicefs::service_state(name) {
            Some(fs::servicefs::ServiceState::Activating {
                pid, deadline_ms, ..
            }) => {
                let alive = STATE
                    .scheduler()
                    .get_task(pid)
                    .is_some_and(|t| !matches!(t.state, TaskState::Zombie));
                if alive {
                    if wall_now_ms() > deadline_ms {
                        STATE.scheduler().kill_task(pid, 124);
                        fs::servicefs::mark_failed(name, ETIMEDOUT);
                        return Err(ETIMEDOUT);
                    }
                    return Ok(None);
                }
                fs::servicefs::mark_failed(name, EIO);
                return Err(EIO);
            }
            Some(fs::servicefs::ServiceState::Failed {
                until_ms,
                last_errno,
                ..
            }) => {
                if wall_now_ms() < until_ms {
                    return Err(last_errno);
                }
            }
            None => {}
        }
        if activate_service_lazily(name) {
            Ok(None)
        } else {
            Err(ENOENT)
        }
    }
}

unsafe fn advance_ctl_svc_job(job: &mut CtlSvcJob) -> CtlSvcAdvance {
    unsafe {
        loop {
            match &mut job.state {
                CtlSvcState::Connecting { name, req } => {
                    let channel = match ctl_service_channel(name) {
                        Ok(Some(channel)) => channel,
                        Ok(None) => return CtlSvcAdvance::Pending,
                        Err(errno) => {
                            job.state = CtlSvcState::Done {
                                status: errno,
                                out: Vec::new(),
                            };
                            return CtlSvcAdvance::Done;
                        }
                    };
                    let session = channel.borrow_mut().open_session(vfs::SYSTEM_CALLER);
                    let body = core::mem::take(req);
                    let req_id = match channel.borrow_mut().enqueue(
                        session,
                        vfs::SYSTEM_CALLER,
                        task::Capabilities::all().bits() as u32,
                        body,
                        Vec::new(),
                    ) {
                        Some(req_id) => req_id,
                        None => {
                            channel.borrow_mut().drop_session(session);
                            job.state = CtlSvcState::Done {
                                status: EIO,
                                out: Vec::new(),
                            };
                            return CtlSvcAdvance::Done;
                        }
                    };
                    job.state = CtlSvcState::Calling {
                        channel,
                        session,
                        req_id,
                        out: Vec::new(),
                    };
                }
                CtlSvcState::Calling {
                    channel,
                    session,
                    req_id,
                    out,
                } => {
                    let mut tmp = [0u8; 4096];
                    loop {
                        let poll = channel
                            .borrow_mut()
                            .drain_response(*session, *req_id, &mut tmp);
                        match poll {
                            fs::servicefs::ResponsePoll::Pending => return CtlSvcAdvance::Pending,
                            fs::servicefs::ResponsePoll::Got(n) => {
                                out.extend_from_slice(&tmp[..n]);
                            }
                            fs::servicefs::ResponsePoll::Eof => {
                                let channel = channel.clone();
                                let session = *session;
                                let body = core::mem::take(out);
                                channel.borrow_mut().drop_session(session);
                                job.state = CtlSvcState::Done {
                                    status: ESUCCESS,
                                    out: body,
                                };
                                return CtlSvcAdvance::Done;
                            }
                            fs::servicefs::ResponsePoll::Failed(errno) => {
                                let channel = channel.clone();
                                let session = *session;
                                channel.borrow_mut().drop_session(session);
                                job.state = CtlSvcState::Done {
                                    status: errno,
                                    out: Vec::new(),
                                };
                                return CtlSvcAdvance::Done;
                            }
                            fs::servicefs::ResponsePoll::Closed => {
                                let channel = channel.clone();
                                let session = *session;
                                channel.borrow_mut().drop_session(session);
                                job.state = CtlSvcState::Done {
                                    status: EIO,
                                    out: Vec::new(),
                                };
                                return CtlSvcAdvance::Done;
                            }
                        }
                    }
                }
                CtlSvcState::Done { .. } => return CtlSvcAdvance::Done,
            }
        }
    }
}

fn close_ctl_svc_job(job: CtlSvcJob) {
    if let CtlSvcState::Calling {
        channel, session, ..
    } = job.state
    {
        channel.borrow_mut().drop_session(session);
    }
}

pub(crate) fn mc_ctl_svc_call_start(request_len: u32) -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        if !STATE.is_initialized() {
            return -EIO;
        }
        let frame = match ctl_bytes(0, request_len) {
            Some(frame) => frame,
            None => return -EINVAL,
        };
        let req = match CtlSvcRequest::decode(&frame) {
            Ok(req) => req,
            Err(_) => return -EINVAL,
        };
        let name = match req.service {
            name if fs::servicefs::valid_service_name(&name) => name,
            _ => return -EINVAL,
        };
        if req.request.len() > fs::servicefs::MAX_SVC_REQUEST_BYTES {
            return -EINVAL;
        }
        let id = STATE.alloc_ctl_id();
        STATE.ctl_svc_jobs().insert(
            id,
            CtlSvcJob {
                state: CtlSvcState::Connecting {
                    name,
                    req: req.request,
                },
            },
        );
        id as i32
    }
}

pub(crate) fn mc_ctl_svc_call_poll(job_id: u32) -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        let jobs = STATE.ctl_svc_jobs();
        let Some(job) = jobs.get_mut(&job_id) else {
            return -EINVAL;
        };
        if matches!(advance_ctl_svc_job(job), CtlSvcAdvance::Pending) {
            return 0;
        }
        let job = jobs.remove(&job_id).expect("present");
        let CtlSvcState::Done { status, out } = job.state else {
            return -EIO;
        };
        let framed = CtlSvcResponse { status, body: out }.encode();
        let len = framed.len() as i32;
        *CTL_BUFFER.get() = framed;
        len
    }
}

pub(crate) fn mc_ctl_svc_call_close(job_id: u32) -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        let Some(job) = STATE.ctl_svc_jobs().remove(&job_id) else {
            return -EINVAL;
        };
        close_ctl_svc_job(job);
        0
    }
}

unsafe fn resolve_exec_cwd(requested: Option<&str>) -> Result<String, i32> {
    unsafe {
        let task = STATE.scheduler().get_task(1).ok_or(-ENOENT)?;
        let current = &*task.cwd.get();
        let ns = task.namespace().unwrap_or_else(|| STATE.ns());
        match requested {
            Some(cwd) => {
                let path = builtins::fs::resolve_path(current, cwd);
                match ns.stat_as(task.id, &path) {
                    Ok(md) if md.node_type == NodeType::Dir => Ok(String::from(path.as_str())),
                    Ok(_) | Err(vfs::FsError::NotDir) => Err(-ENOTDIR),
                    Err(vfs::FsError::NotFound) => Err(-ENOENT),
                    Err(e) => Err(ctl_neg_errno(e)),
                }
            }
            None => Ok(current.clone()),
        }
    }
}

fn autocomplete_fs_error(error: vfs::FsError) -> i32 {
    if error == vfs::FsError::WouldBlock {
        EAGAIN
    } else {
        errno_from_fs(error)
    }
}

struct CompletionCandidates {
    values: BTreeMap<String, String>,
    limit: usize,
    truncated: bool,
}

impl CompletionCandidates {
    fn new(limit: usize, truncated: bool) -> Self {
        Self {
            values: BTreeMap::new(),
            limit,
            truncated,
        }
    }

    fn insert(&mut self, value: String, kind: &str) {
        if self.values.contains_key(&value) {
            return;
        }
        if self.values.len() < self.limit {
            self.values.insert(value, String::from(kind));
            return;
        }

        self.truncated = true;
        let replace = self
            .values
            .last_key_value()
            .is_some_and(|(last, _)| value < *last);
        if replace {
            let last = self
                .values
                .last_key_value()
                .map(|(key, _)| key.clone())
                .expect("bounded candidate set is nonempty");
            self.values.remove(&last);
            self.values.insert(value, String::from(kind));
        }
    }
}

fn autocomplete_path_candidates(
    ns: &Namespace,
    caller: TaskId,
    cwd: &str,
    prefix: &str,
    directories_only: bool,
    executables_only: bool,
    candidates: &mut CompletionCandidates,
    scan_remaining: &mut usize,
) -> Result<(), i32> {
    let (typed_dir, base) = match prefix.rfind('/') {
        Some(index) => (&prefix[..=index], &prefix[index + 1..]),
        None => ("", prefix),
    };
    let search = if typed_dir.is_empty() {
        builtins::fs::resolve_path(cwd, ".")
    } else {
        let directory = typed_dir.trim_end_matches('/');
        builtins::fs::resolve_path(cwd, if directory.is_empty() { "/" } else { directory })
    };
    let entries = ns
        .readdir(caller, &search)
        .map_err(autocomplete_fs_error)?;
    for entry in entries {
        if *scan_remaining == 0 {
            candidates.truncated = true;
            break;
        }
        *scan_remaining -= 1;
        if !entry.name.starts_with(base) || (!base.starts_with('.') && entry.name.starts_with('.')) {
            continue;
        }
        let full = search.join(&entry.name);
        let metadata = match ns.stat_as(caller, &full) {
            Ok(metadata) => metadata,
            Err(vfs::FsError::WouldBlock) => return Err(EAGAIN),
            Err(_) => continue,
        };
        let is_dir = metadata.node_type == NodeType::Dir;
        if directories_only && !is_dir {
            continue;
        }
        if executables_only && (is_dir || !metadata.owner_executable()) {
            continue;
        }
        let mut value = String::from(typed_dir);
        value.push_str(&entry.name);
        if is_dir {
            value.push('/');
        }
        if value.len() > AUTOCOMPLETE_MAX_SOURCE_BYTES as usize {
            candidates.truncated = true;
            continue;
        }
        candidates.insert(
            value,
            if is_dir {
                "directory"
            } else if executables_only {
                "command"
            } else {
                "file"
            },
        );
    }
    Ok(())
}

/// Resolve a shell completion request against pid 1's live shell state and
/// namespace. The operation is read-only and bounded; `EAGAIN` is surfaced for
/// lazy filesystem data so hosts can drive a tick and retry exactly as they do
/// for structured readdir.
fn autocomplete(req: AutocompleteRequest, interactive: bool) -> Result<ResolvedAutocomplete, i32> {
    if req.source.len() > AUTOCOMPLETE_MAX_SOURCE_BYTES as usize {
        return Err(EMSGSIZE);
    }
    let source = core::str::from_utf8(&req.source).map_err(|_| EINVAL)?;
    let cursor = req.cursor as usize;
    if cursor > source.len() || !source.is_char_boundary(cursor) {
        return Err(EINVAL);
    }
    let limit = (req.limit as usize).clamp(1, AUTOCOMPLETE_MAX_ITEMS as usize);
    let scheduler = unsafe { STATE.scheduler() };
    let task = scheduler.get_task(1).ok_or(ENOENT)?;
    if !task.has_control() {
        return Err(ENOSYS);
    }
    let ns = task.namespace().unwrap_or_else(|| unsafe { STATE.ns() });
    let live_cwd = unsafe { &*task.cwd.get() };
    let cwd = match req.cwd.as_deref() {
        Some(requested) => {
            let resolved = builtins::fs::resolve_path(live_cwd, requested);
            match ns.stat_as(task.id, &resolved) {
                Ok(metadata) if metadata.node_type == NodeType::Dir => String::from(resolved.as_str()),
                Ok(_) | Err(vfs::FsError::NotDir) => return Err(ENOTDIR),
                Err(error) => return Err(autocomplete_fs_error(error)),
            }
        }
        None => live_cwd.clone(),
    };
    let live_env = task.env();
    let env_overlay = req.env;

    let probe = ProbeRequest {
        source: req.source.clone(),
        cursor: req.cursor,
        interactive,
    };
    let probe = ProbeResponse::decode(&task.control(&probe.encode())?).map_err(|_| EIO)?;
    let start = probe.replace_start as usize;
    let end = probe.replace_end as usize;
    if start > cursor
        || cursor > end
        || end > source.len()
        || !source.is_char_boundary(start)
        || !source.is_char_boundary(end)
        || probe.prefix.len() > AUTOCOMPLETE_MAX_SOURCE_BYTES as usize
    {
        return Err(EIO);
    }

    let mut candidates = CompletionCandidates::new(limit, probe.truncated);
    let mut scan_remaining = AUTOCOMPLETE_MAX_SCAN_ENTRIES as usize;
    for candidate in probe
        .shell_candidates
        .into_iter()
        .take(AUTOCOMPLETE_MAX_ITEMS as usize)
    {
        candidates.insert(candidate.value, &candidate.kind);
    }
    match probe.context.as_str() {
        CONTEXT_VARIABLE => {
            for key in live_env.keys().chain(env_overlay.keys()) {
                if scan_remaining == 0 {
                    candidates.truncated = true;
                    break;
                }
                scan_remaining -= 1;
                if key.starts_with(&probe.prefix) {
                    candidates.insert(key.clone(), "variable");
                }
            }
        }
        CONTEXT_COMMAND if probe.prefix.contains('/') => autocomplete_path_candidates(
            ns,
            task.id,
            &cwd,
            &probe.prefix,
            false,
            true,
            &mut candidates,
            &mut scan_remaining,
        )?,
        CONTEXT_COMMAND => {
            let path = env_overlay
                .get("PATH")
                .or_else(|| live_env.get("PATH"))
                .map(String::as_str)
                .unwrap_or("/bin:/usr/bin");
            for directory in path
                .split(':')
                .take(AUTOCOMPLETE_MAX_PATH_SEGMENTS as usize)
            {
                if scan_remaining == 0 {
                    candidates.truncated = true;
                    break;
                }
                let directory = if directory.is_empty() { "." } else { directory };
                autocomplete_path_candidates(
                    ns,
                    task.id,
                    &builtins::fs::resolve_path(&cwd, directory).0,
                    &probe.prefix,
                    false,
                    true,
                    &mut candidates,
                    &mut scan_remaining,
                )?;
            }
        }
        CONTEXT_PATH => autocomplete_path_candidates(
            ns,
            task.id,
            &cwd,
            &probe.prefix,
            false,
            false,
            &mut candidates,
            &mut scan_remaining,
        )?,
        CONTEXT_DIRECTORY => autocomplete_path_candidates(
            ns,
            task.id,
            &cwd,
            &probe.prefix,
            true,
            false,
            &mut candidates,
            &mut scan_remaining,
        )?,
        _ => return Err(EIO),
    }

    let truncated = candidates.truncated;
    let candidates: Vec<ShellCandidate> = candidates
        .values
        .into_iter()
        .map(|(value, kind)| ShellCandidate { value, kind })
        .collect();
    let render = RenderRequest {
        replace_start: probe.replace_start,
        replace_end: probe.replace_end,
        quote: probe.quote,
        candidates,
        truncated,
    };
    let rendered = shell_rust::CompletionResult::decode(&task.control(&render.encode())?)
        .map_err(|_| EIO)?;
    if rendered.replace_start != render.replace_start
        || rendered.replace_end != render.replace_end
        || rendered.items.len() > limit
    {
        return Err(EIO);
    }
    Ok(ResolvedAutocomplete {
        result: AutocompleteResult {
            replace_start: rendered.replace_start,
            replace_end: rendered.replace_end,
            common_prefix: rendered.common_prefix,
            items: rendered
                .items
                .into_iter()
                .map(|item| CtlAutocompleteItem {
                    label: item.label,
                    value: item.value,
                    kind: item.kind,
                })
                .collect(),
            truncated: rendered.truncated,
        },
        continuation: probe.continuation,
    })
}

pub(crate) fn mc_ctl_autocomplete(request_len: u32) -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        if !STATE.is_initialized() {
            return -EIO;
        }
        if request_len as usize > AUTOCOMPLETE_MAX_FRAME_BYTES as usize {
            return -EMSGSIZE;
        }
        let bytes = match ctl_bytes(0, request_len) {
            Some(bytes) => bytes,
            None => return -EINVAL,
        };
        let request = match AutocompleteRequest::decode(&bytes) {
            Ok(request) => request,
            Err(_) => return -EINVAL,
        };
        match autocomplete(request, false) {
            Ok(completion) => {
                let encoded = completion.result.encode();
                if encoded.len() > AUTOCOMPLETE_MAX_FRAME_BYTES as usize {
                    return -EMSGSIZE;
                }
                let len = encoded.len() as i32;
                *CTL_BUFFER.get() = encoded;
                len
            }
            Err(errno) => -errno,
        }
    }
}

/// Spawn `/bin/sh -c "<cmd>"` as a guest task with stdout/stderr captured into
/// `cap`. Returns its pid, or `None` if `/bin/sh` can't be loaded.
unsafe fn spawn_ctl_sh(
    cmd: &str,
    cwd: &str,
    env: &BTreeMap<String, String>,
    stdin: Option<&[u8]>,
    cap: &OutputCapture,
) -> Option<TaskId> {
    unsafe {
        let sched = STATE.scheduler();
        let ns = STATE.ns();
        let engine = STATE.guest_runtime();
        let path: String = env
            .get("PATH")
            .cloned()
            .unwrap_or_else(|| String::from("/bin:/usr/bin"));
        let bytes = wasm::resolve_program(ns, cwd, "sh", &path)?;
        let argv = alloc::vec![String::from("sh"), String::from("-c"), String::from(cmd)];
        let prog = wasm::GuestProgram::load(engine, &bytes, argv.clone(), &path).ok()?;
        let pid = sched.spawn(
            Some(1),
            String::from("sh"),
            String::from("sh"),
            argv[1..].to_vec(),
            String::from(cwd),
        );
        // A structured operator exec is not the interactive foreground job.
        // Keep it out of the terminal's foreground process group so Ctrl-C /
        // Ctrl-Z typed at the prompt do not accidentally signal it.
        sched.set_pgid(pid, 0);
        let task = sched.get_task(pid).expect("spawned ctl sh");
        task.set_namespace(ns.fork(pid));
        // Seed this control-channel command from the decoded ExecRequest context:
        // live boot env overlaid by request env, explicit cwd, and optional stdin.
        task.env_mut().clone_from(env);
        if let Some(stdin) = stdin {
            task.set_stdin(Box::new(io::BytesSource::new(stdin.to_vec())));
        }
        task.set_stdout(Box::new(io::CaptureSink(cap.stdout.clone())));
        task.set_stderr(Box::new(io::CaptureSink(cap.stderr.clone())));
        task.set_program(Box::new(prog));
        let (parent_caps, parent_root) = sched
            .get_task(1)
            .map(|parent| (parent.caps, parent.confine_root.clone()))
            .unwrap_or_else(|| (task::Capabilities::all(), None));
        let (caps, root) = wasm::exec_policy(
            parent_caps,
            parent_root,
            wasm::declared_tier(&bytes),
            None,
            cwd,
        );
        sched.set_task_policy(pid, caps, root);
        Some(pid)
    }
}

/// Collect a task and all of its descendants, deepest children first.
fn task_subtree(scheduler: &Scheduler, root: TaskId) -> Vec<TaskId> {
    let mut pids: Vec<TaskId> = scheduler
        .task_ids()
        .into_iter()
        .filter(|&pid| pid == root || scheduler.is_ancestor_of(root, pid))
        .collect();
    pids.reverse();
    pids
}

/// Begin a host-initiated exec. An `ExecRequest` is in the control buffer at
/// `[0..request_len]`. Returns a job id (> 0) or a negative errno; drive ticks and
/// `mc_ctl_exec_poll` until the job reports done.
pub(crate) fn mc_ctl_exec_start(request_len: u32) -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        if !STATE.is_initialized() {
            return -EIO;
        }
        let req_bytes = match ctl_bytes(0, request_len) {
            Some(bytes) => bytes,
            None => return -EINVAL,
        };
        let req = match ExecRequest::decode(&req_bytes) {
            Ok(req) => req,
            Err(_) => return -EINVAL,
        };
        let cwd = match resolve_exec_cwd(req.cwd.as_deref()) {
            Ok(cwd) => cwd,
            Err(errno) => return errno,
        };
        let mut env = match STATE.scheduler().get_task(1) {
            Some(task) => task.env().clone(),
            None => return -ENOENT,
        };
        for (k, v) in req.env {
            env.insert(k, v);
        }
        let stdin = req.stdin;
        let cmd = req.cmd;
        let cap = new_capture();

        // Preferred path: run the command through the unified guest `/bin/sh -c`,
        // capturing its stdout/stderr under pid 1's live capability ceiling.
        if let Some(pid) = spawn_ctl_sh(&cmd, &cwd, &env, stdin.as_deref(), &cap) {
            let id = STATE.alloc_ctl_id();
            STATE.ctl_jobs().insert(
                id,
                CtlExecJob {
                    body: CtlBody::Guest { pid },
                    cap,
                    done: false,
                    exit_code: 0,
                },
            );
            return id as i32;
        }

        -ENOENT
    }
}

/// Poll a host exec. Returns 0 while running. On finish the result is written to
/// the control buffer as an encoded `ExecOutcome`, the job is freed, and the
/// encoded byte length is returned. A negative errno is returned for an unknown
/// job id.
pub(crate) fn mc_ctl_exec_poll(job_id: u32) -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        let jobs = STATE.ctl_jobs();
        match jobs.get(&job_id) {
            Some(j) if !j.done => return 0,
            Some(_) => {}
            None => return -EINVAL,
        }
        let job = jobs.remove(&job_id).expect("present");
        let so = job.cap.stdout.borrow();
        let se = job.cap.stderr.borrow();
        let out = ExecOutcome {
            exit_code: job.exit_code,
            stdout: so.to_vec(),
            stderr: se.to_vec(),
        }
        .encode();
        let len = out.len() as i32;
        drop(so);
        drop(se);
        *CTL_BUFFER.get() = out;
        len
    }
}

/// Peek a *running* host exec's stdout without finalizing it. Writes the bytes
/// captured so far to the control buffer (read via `mc_ctl_buf(0)`) and returns
/// their length; the job keeps running. Lets the host tail a long-running command
/// (e.g. an agent session emitting framed events) and stream output incrementally.
/// A negative errno is returned for an unknown job id.
pub(crate) fn mc_ctl_exec_peek(job_id: u32) -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        let jobs = STATE.ctl_jobs();
        match jobs.get(&job_id) {
            Some(j) => {
                let so = j.cap.stdout.borrow();
                let bytes = so[..].to_vec();
                let len = bytes.len() as i32;
                drop(so);
                *CTL_BUFFER.get() = bytes;
                len
            }
            None => -EINVAL,
        }
    }
}

/// Abandon a host exec job, freeing it without reading its result. Returns 0.
pub(crate) fn mc_ctl_exec_close(job_id: u32) -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        if let Some(job) = STATE.ctl_jobs().remove(&job_id) {
            let CtlBody::Guest { pid } = job.body;
            let pids = task_subtree(STATE.scheduler(), pid);
            if !pids.is_empty() {
                let scheduler = STATE.scheduler();
                for pid in pids {
                    if scheduler
                        .get_task(pid)
                        .is_some_and(|t| !matches!(t.state, TaskState::Zombie))
                    {
                        scheduler.kill_task(pid, 130);
                    }
                    scheduler.reap_zombie(pid);
                }
                scheduler.drop_dead_pipes();
            }
        }
    }
    0
}

// ---------- Snapshot support ----------
//
// snapshot/restore are HOST operations: the host dumps the kernel's linear
// memory (where ALL mutable state lives — STATE, the scheduler with every
// guest's wasmi Store, the Talc heap, the VFS, the control buffer) and rebuilds
// a fresh instance from it WITHOUT calling mc_init. The kernel needs to expose
// only one thing the host cannot see for itself: whether a host-terminated
// egress operation is in flight, since its raw host handle does not survive the
// restore. Everything else is just bytes.

/// Number of operations in flight that a snapshot must not interrupt. Host egress — HTTP, WebSocket,
/// AND host calls (host-backed mount reads and parked write-commits, whose raw host handles don't
/// survive a restore) — PLUS resident-service calls mid-flight: a service between `svc_recv` and
/// `svc_respond` has a live wasm stack a snapshot would lose (SYSTEMS.md; codex #5). The host
/// reads this before a snapshot and refuses (driving ticks to drain) while it is non-zero, so a
/// snapshot is always taken at a quiescent, no-egress-and-no-service-mid-call boundary.
pub(crate) fn mc_inflight_egress() -> i32 {
    net::inflight_egress() + fs::servicefs::svc_inflight() as i32
}

/// Number of host-backed filesystem write-commits parked but not yet acknowledged
/// by their drivers (`mountfs` and `/var/persist`). The host polls this (driving
/// ticks to drain them) to make a write durable on return WITHOUT waiting on
/// unrelated egress — a write's durability must not block on an open WebSocket
/// or a concurrent fetch.
pub(crate) fn mc_pending_commits() -> i32 {
    let _bkl = sync::lock_kernel();
    unsafe {
        if !STATE.is_initialized() {
            return 0;
        }
    }
    (fs::mountfs::pending_commit_count() + fs::persistfs::pending_commit_count()) as i32
}

/// Scheduler driving state is snapshot-resident. A restoring host queries it after copying the
/// memory image instead of trusting duplicated header metadata (A8/C1).
pub(crate) fn mc_worker_count() -> i32 {
    sync::workers()
}

// ---------- Threading exports ----------
// Present iff the kernel was built with the `threads` feature.

/// Worker entry point. The host invokes this once per provisioned worker
/// per tick to drive task execution. Under the BKL it wakes any unblocked
/// tasks and runs one bounded round — stepping each currently-ready task
/// exactly once (`run_round`, the same primitive cooperative `mc_tick`
/// uses) — then returns 1 if work remains (ready or blocked tasks) or 0
/// when idle / a quiesce is pending.
///
/// Bounding to one round per call (rather than draining to empty) is what
/// keeps an unbounded producer such as `cat /dev/zero > /dev/null &` from
/// monopolizing a tick, and makes threaded execution observably identical
/// to the cooperative one-round-per-tick schedule (cooperative-equivalence).
/// Under a future real-OS-thread build (Option A) this becomes a
/// pop-one-task loop so N threads distribute work through the shared ready
/// queue; the cooperative-backed build needs only the bounded round.
#[cfg(feature = "threads")]
pub(crate) fn mc_worker_entry(_arg: i32) -> i32 {
    let _bkl = sync::lock_kernel();
    // Safe point for snapshotting: while a quiesce is pending
    // a worker does no work and returns, so its wasm stack unwinds and the
    // host can park it with all kernel state at rest in linear memory.
    if sync::quiesce_requested() {
        return 0;
    }
    unsafe {
        if !STATE.is_initialized() {
            return 0;
        }
        let scheduler = STATE.scheduler();
        let ns = STATE.ns();
        scheduler.check_unblocked();
        run_round(scheduler, ns);
        if scheduler.has_work() {
            1
        } else {
            0
        }
    }
}

/// Signal all workers to reach their safe point and park, so the host can
/// snapshot `(memory, globals, tables)` consistently.
/// Deliberately does NOT take the BKL — a snapshot request must not block
/// behind a worker that is mid-step; it only flips an atomic flag the
/// workers poll at their loop top.
#[cfg(feature = "threads")]
pub(crate) fn mc_quiesce_request() -> i32 {
    sync::request_quiesce();
    0
}

/// Resume workers after a snapshot.
#[cfg(feature = "threads")]
pub(crate) fn mc_quiesce_release() -> i32 {
    sync::release_quiesce();
    0
}
