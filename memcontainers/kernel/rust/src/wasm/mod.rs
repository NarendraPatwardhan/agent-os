// crates/kernel/src/wasm/mod.rs
//
// The user-space runtime: runs wasm32 programs in an embedded `wasmi`
// interpreter as cooperative tasks.
//
// A loaded program is a `GuestProgram` implementing `Builtin`. Each `step()`
// runs the guest for one fuel quantum, mediating syscalls. Syscalls are thin:
// a host function records the request in `GuestState.pending` and returns a
// host error, which `wasmi`'s resumable-call machinery surfaces as a
// `HostTrap` — suspending the guest. `step()` then fulfills the request against
// the kernel (real VFS / pipe I/O via `BuiltinCtx`) and resumes, mapping a
// would-block syscall to `BlockedOn*`, fuel exhaustion to `Pending`, and exit
// or a fatal wasm trap to `Exit`. This composes guest scheduling with the
// existing cooperative model with no special-casing in the scheduler.

#![allow(dead_code)]

pub mod abi;

use alloc::boxed::Box;
use alloc::collections::BTreeMap;
use alloc::format;
use alloc::rc::Rc;
use alloc::string::String;
use alloc::vec::Vec;
use core::cell::RefCell;
use core::fmt;

use wasmi::{
    Caller, Engine, Global, Linker, Memory, Module, Store, StoreLimits, StoreLimitsBuilder,
    TypedFunc, TypedResumableCall, Val,
};

use crate::builtins::{Builtin, BuiltinCtx, BuiltinStep};
use crate::fs::servicefs::{
    clear_activation, grant_holder, lookup_service, mark_failed, register_service,
    service_registered, service_state, valid_service_name, DelegatedHandle, RespondOutcome,
    ServiceChannel, ServiceInbound, ServiceState, SvcCallSource, SvcConnHandle, SvcRead,
    SvcServeOwner, MAX_SVC_REQUEST_BYTES, SVC_RESPONSE_HIGH_WATER,
};
use crate::fs::{MemFs, ServeChannel, ServedFs};
use crate::host_call::{HostCallRead, HostCallSource};
use crate::io::{EmptySource, PipeSink, PipeSource, ReadSource, TerminalSink, WriteSink};
use crate::net::{HttpPoll, HttpReq, NetError, WsConn};
use crate::task::{
    BlockReason, Capabilities, TaskId, TaskState, Tier, CAP_AMBIENT, CAP_FS_READ, CAP_MOUNT,
    CAP_NET, CAP_PERSIST, CAP_SCRATCH, CAP_SPAWN,
};
use crate::vfs::{FileHandle, FsError, KPath, Namespace, NodeType, OpenFlags, SeekFrom};
use crate::wasm::abi::*;

/// Cap on a guest's open fd table — the per-VM "maximum open fds" budget.
/// Standard fds 0/1/2 are not counted; this bounds entries ≥ 3.
const MAX_OPEN_FDS: usize = 256;
/// Max fds one `svc_call` may delegate (SYSTEMS.md) — bounds the server's handle buffer.
const MAX_DELEGATED_HANDLES: usize = 8;
/// svc recv envelope header:
/// `[kind:u8][nhandles:u8][session:u32][req_id:u32][caller:u32][caller_caps:u32][blob_len:u32]` (LE).
const SVC_ENVELOPE_HEADER: usize = 22;
/// Envelope `kind`: a call to answer, vs a session-closed tombstone (a one-way notification).
const SVC_KIND_CALL: u8 = 0;
const SVC_KIND_SESSION_CLOSED: u8 = 1;
const SVC_KIND_DRAIN_READY: u8 = 2;
/// The persistence mount. Access to a path at or under it requires
/// the `CAP_PERSIST` capability in addition to the usual FS read/write checks.
const PERSIST_ROOT: &str = "/var/persist";
/// Kernel/sysroot stat record size, projected from the shared contract.
const STAT_BUF_LEN: usize = STAT_REC_LEN as usize;

/// An entry in a guest's own fd table (fds ≥ 3). Standard fds 0/1/2 route to
/// the task's stdin/stdout/stderr via `BuiltinCtx`.
enum GuestFd {
    File(SharedFile),
    PipeRead(PipeSource),
    PipeWrite(PipeSink),
    /// A readable HTTP response body (`mc_sys_http_get`/`mc_sys_http_request`).
    /// Owns the kernel `HttpReq`, so dropping the slot closes the host handle
    /// (R1).
    Net(SharedNet),
    /// A bidirectional WebSocket (`mc_sys_ws_open`): `read` receives one
    /// message, `write` sends one. Owns the kernel `WsConn`; dropping the slot
    /// closes the host handle (R1).
    Ws(SharedWs),
    /// The server side of a guest-served filesystem (`mc_sys_serve`).
    /// Holds the rendezvous channel; dropping it (the server
    /// guest exiting) closes the channel so pending requesters fail rather than
    /// block forever.
    Serve(ServeOwner),
    /// A readable host-call result (`mc_sys_host_call`): the tool broker and
    /// host-backed mounts. Owns the kernel `HostCallSource`, so dropping the slot
    /// closes the host handle (R1).
    HostCall(SharedHostCall),
    /// The server side of a resident service (`mc_sys_svc_serve`). Holds the
    /// session-keyed channel; dropping it (the server guest exiting) closes the
    /// channel and deregisters the name, so clients fail rather than block forever.
    SvcServe(SvcServeOwner),
    /// A client's connection to a resident service (`mc_sys_svc_connect`). Holds
    /// the channel and the session; dropping it tears the session down.
    SvcConn(SvcConnHandle),
    /// A readable `svc_call` result that drains the server's streamed response.
    /// Owns an `Rc` to the channel, so the warm service outlives an in-flight call.
    SvcCall(SharedSvcCall),
}

/// Owns a serve channel and closes it on drop (server-guest teardown).
struct ServeOwner(Rc<RefCell<ServeChannel>>);

impl Drop for ServeOwner {
    fn drop(&mut self) {
        self.0.borrow_mut().close();
    }
}

/// A guest fd backed by an in-flight `svc_call` result. Parallels `SharedHostCall`:
/// yield while the server computes, stream the response body, EOF.
#[derive(Clone)]
struct SharedSvcCall(Rc<RefCell<SvcCallSource>>);

impl SharedSvcCall {
    fn new(src: SvcCallSource) -> Self {
        SharedSvcCall(Rc::new(RefCell::new(src)))
    }
    fn read_into(&self, buf: &mut [u8]) -> SvcRead {
        self.0.borrow_mut().read_into(buf)
    }
    fn poll_readable(&self) -> bool {
        self.0.borrow().poll_readable()
    }
}

#[derive(Clone)]
struct SharedFile(Rc<RefCell<Box<dyn FileHandle>>>);

impl SharedFile {
    fn new(handle: Box<dyn FileHandle>) -> Self {
        SharedFile(Rc::new(RefCell::new(handle)))
    }

    fn read(&self, buf: &mut [u8]) -> Result<usize, FsError> {
        self.0.borrow_mut().read(buf)
    }

    fn write(&self, buf: &[u8]) -> Result<usize, FsError> {
        self.0.borrow_mut().write(buf)
    }

    fn seek(&self, pos: SeekFrom) -> Result<u64, FsError> {
        self.0.borrow_mut().seek(pos)
    }

    fn truncate(&self, size: u64) -> Result<(), FsError> {
        self.0.borrow_mut().truncate(size)
    }

    fn poll_readable(&self) -> bool {
        self.0.borrow().poll_readable()
    }

    fn poll_writable(&self) -> bool {
        self.0.borrow().poll_writable()
    }
}

struct SharedFileSource(SharedFile);

impl ReadSource for SharedFileSource {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize, FsError> {
        self.0.read(buf)
    }

    fn is_eof(&self) -> bool {
        true
    }
}

struct SharedFileSink(SharedFile);

impl WriteSink for SharedFileSink {
    fn write(&mut self, buf: &[u8]) -> Result<usize, FsError> {
        self.0.write(buf)
    }
}

#[derive(Clone)]
struct SharedNet(Rc<RefCell<NetSource>>);

impl SharedNet {
    fn new(req: HttpReq) -> Self {
        SharedNet(Rc::new(RefCell::new(NetSource::new(req))))
    }

    fn read_into(&self, buf: &mut [u8]) -> NetRead {
        self.0.borrow_mut().read_into(buf)
    }

    fn poll_readable(&self) -> bool {
        self.0.borrow_mut().poll_readable()
    }

    fn drive_status(&self) -> StatusPoll {
        self.0.borrow_mut().drive_status()
    }
}

struct SharedNetSource(SharedNet);

impl ReadSource for SharedNetSource {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize, FsError> {
        match self.0.read_into(buf) {
            NetRead::Pending => Ok(0),
            NetRead::Got(n) => Ok(n),
            NetRead::Eof => Ok(0),
            NetRead::Failed => Err(FsError::IoError),
        }
    }

    fn is_eof(&self) -> bool {
        matches!(self.0 .0.borrow().phase, NetPhase::Eof)
    }
}

/// A guest fd backed by an in-flight host call (`mc_sys_host_call`). Parallels
/// `SharedNet`: poll for readiness, stream the result body, EOF.
#[derive(Clone)]
struct SharedHostCall(Rc<RefCell<HostCallSource>>);

impl SharedHostCall {
    fn new(src: HostCallSource) -> Self {
        SharedHostCall(Rc::new(RefCell::new(src)))
    }
    fn read_into(&self, buf: &mut [u8]) -> HostCallRead {
        self.0.borrow_mut().read_into(buf)
    }
    fn poll_readable(&self) -> bool {
        self.0.borrow_mut().poll_readable()
    }
}

/// A readable HTTP response, driven by `mc_sys_read`. The host buffers the
/// response off-thread, so this is a small state machine: poll for the head
/// (yielding while in flight), then stream the body. It never exposes the host
/// handle — the guest only ever sees an ordinary fd (R1).
struct NetSource {
    req: HttpReq,
    phase: NetPhase,
    /// HTTP status parsed from the response head once it arrives (`0` until
    /// then). Surfaced to the guest via `mc_sys_http_status` so a client like
    /// `fetch` can set a curl-like exit code without seeing the head bytes.
    status: u16,
}

enum NetPhase {
    Polling,
    Body,
    Eof,
    Failed,
}

/// Outcome of pulling bytes from a `NetSource`.
enum NetRead {
    /// The response is still in flight — the guest should yield and retry.
    Pending,
    Got(usize),
    Eof,
    Failed,
}

/// Outcome of querying a `NetSource`'s HTTP status (`mc_sys_http_status`).
enum StatusPoll {
    /// The head has not arrived yet — the guest should yield and retry.
    Pending,
    /// The head arrived; this is the parsed numeric status.
    Ready(u16),
    /// The request failed at the transport level before any head.
    Failed,
}

impl NetSource {
    fn new(req: HttpReq) -> NetSource {
        NetSource {
            req,
            phase: NetPhase::Polling,
            status: 0,
        }
    }

    /// Fill `buf` with body bytes. Drives the poll→body progression; returns
    /// `Pending` (not EOF) while the host is still fetching.
    fn read_into(&mut self, buf: &mut [u8]) -> NetRead {
        loop {
            match self.phase {
                NetPhase::Polling => match self.req.poll() {
                    HttpPoll::Pending => return NetRead::Pending,
                    // Head received and the host has buffered the body; capture
                    // the status, then fall through to read it on this call.
                    HttpPoll::Head(head) => {
                        self.status = parse_http_status(&head);
                        self.phase = NetPhase::Body;
                    }
                    HttpPoll::Failed => {
                        self.phase = NetPhase::Failed;
                        return NetRead::Failed;
                    }
                },
                NetPhase::Body => {
                    return match self.req.read_body(buf) {
                        Ok(0) => {
                            self.phase = NetPhase::Eof;
                            NetRead::Eof
                        }
                        Ok(n) => NetRead::Got(n),
                        Err(_) => {
                            self.phase = NetPhase::Failed;
                            NetRead::Failed
                        }
                    };
                }
                NetPhase::Eof => return NetRead::Eof,
                NetPhase::Failed => return NetRead::Failed,
            }
        }
    }

    /// Non-destructive `mc_sys_poll` readiness: drive the head-poll forward
    /// (so a buffered body becomes visible) WITHOUT consuming body bytes.
    /// Ready (`POLLIN`) once the body is available, on EOF, or on failure;
    /// not-ready while the host is still fetching.
    fn poll_readable(&mut self) -> bool {
        if let NetPhase::Polling = self.phase {
            match self.req.poll() {
                HttpPoll::Pending => return false,
                HttpPoll::Head(head) => {
                    self.status = parse_http_status(&head);
                    self.phase = NetPhase::Body;
                }
                HttpPoll::Failed => self.phase = NetPhase::Failed,
            }
        }
        true
    }

    /// Drive the head-poll forward and report the HTTP status. Like
    /// `poll_readable` it does not consume body bytes — it only advances past
    /// the head — so a later `read` still streams the full body.
    fn drive_status(&mut self) -> StatusPoll {
        if let NetPhase::Polling = self.phase {
            match self.req.poll() {
                HttpPoll::Pending => return StatusPoll::Pending,
                HttpPoll::Head(head) => {
                    self.status = parse_http_status(&head);
                    self.phase = NetPhase::Body;
                }
                HttpPoll::Failed => {
                    self.phase = NetPhase::Failed;
                    return StatusPoll::Failed;
                }
            }
        }
        if let NetPhase::Failed = self.phase {
            return StatusPoll::Failed;
        }
        StatusPoll::Ready(self.status)
    }
}

/// Parse the numeric status from an HTTP head. The host frames the head as
/// `"<status> <reason>\r\n<headers>"` (see `host/src/net.rs`), so the
/// leading bytes ARE the status digits. Returns `0` if none are found.
fn parse_http_status(head: &[u8]) -> u16 {
    let mut n: u16 = 0;
    let mut saw = false;
    for &b in head {
        if b.is_ascii_digit() {
            n = n.saturating_mul(10).saturating_add((b - b'0') as u16);
            saw = true;
        } else {
            break;
        }
    }
    if saw {
        n
    } else {
        0
    }
}

/// Largest single WebSocket message the kernel will buffer per `recv`.
const WS_MSG_BUF: usize = 16 * 1024;

/// Outcome of a guest `read` on a WebSocket fd.
enum WsRead {
    /// `n` message bytes were delivered.
    Got(usize),
    /// Nothing buffered yet — the guest should yield and retry (it normally
    /// `poll`s first, so this is the rare race).
    Pending,
    /// The connection closed or errored; a `read` reports EOF.
    Eof,
}

/// Outcome of a guest `write` on a WebSocket fd — the dual of [`WsRead`].
enum WsWrite {
    /// The whole `n`-byte message was accepted by the host transport.
    Sent(usize),
    /// The transport cannot accept right now (still connecting, or its send
    /// buffer is above the flow-control mark). The guest's write parks and
    /// retries; the unsent bytes stay in the guest's own linear memory (B5).
    /// Mirrors `WsRead::Pending` on the read side.
    Pending,
    /// The frame is larger than the host flow-control window. Retrying the same
    /// bytes cannot make progress, so the guest gets `EMSGSIZE`.
    MessageTooBig,
    /// The connection closed or errored; a `write` reports a broken pipe.
    Closed,
}

/// Inner state of a shared WebSocket: the owned host connection plus a
/// one-message receive buffer so `poll` can report `POLLIN` readiness
/// *without* consuming the message (a later `read` drains the same buffer).
struct WsInner {
    conn: WsConn,
    /// Buffered received bytes not yet handed to the guest, and the read
    /// offset into them.
    pending: Vec<u8>,
    poff: usize,
    /// Sticky: the connection closed or errored (`recv` returned `Err`).
    failed: bool,
}

impl WsInner {
    /// Ensure `pending` holds unread bytes if any message is available.
    /// Returns `true` if a subsequent `read` would make progress (data
    /// buffered) or report EOF (failed) — i.e. the fd is `POLLIN`-ready.
    /// Non-destructive: it buffers but never discards a message.
    fn fill(&mut self) -> bool {
        if self.poff < self.pending.len() {
            return true;
        }
        if self.failed {
            return true; // EOF is "readable": a read returns 0 immediately
        }
        let mut buf = [0u8; WS_MSG_BUF];
        match self.conn.recv(&mut buf) {
            Ok(Some(n)) => {
                self.pending = buf[..n].to_vec();
                self.poff = 0;
                true
            }
            Ok(None) => false,
            Err(_) => {
                self.failed = true;
                true
            }
        }
    }
}

/// A shared, reference-counted WebSocket fd (so `dup`/`dup2` alias one
/// connection). Interior mutability mirrors `SharedFile`/`SharedNet`.
#[derive(Clone)]
struct SharedWs(Rc<RefCell<WsInner>>);

impl SharedWs {
    fn new(conn: WsConn) -> Self {
        SharedWs(Rc::new(RefCell::new(WsInner {
            conn,
            pending: Vec::new(),
            poff: 0,
            failed: false,
        })))
    }

    /// Drain up to `buf.len()` buffered bytes, receiving a fresh message first
    /// if the buffer is empty. See [`WsRead`].
    fn read_into(&self, buf: &mut [u8]) -> WsRead {
        let mut w = self.0.borrow_mut();
        if w.poff >= w.pending.len() && !w.failed {
            // Nothing buffered: try to receive one message.
            let mut tmp = [0u8; WS_MSG_BUF];
            match w.conn.recv(&mut tmp) {
                Ok(Some(n)) => {
                    w.pending = tmp[..n].to_vec();
                    w.poff = 0;
                }
                Ok(None) => return WsRead::Pending,
                Err(_) => {
                    w.failed = true;
                    return WsRead::Eof;
                }
            }
        }
        if w.poff < w.pending.len() {
            let avail = w.pending.len() - w.poff;
            let n = avail.min(buf.len());
            let off = w.poff;
            buf[..n].copy_from_slice(&w.pending[off..off + n]);
            w.poff += n;
            WsRead::Got(n)
        } else {
            // Buffer empty and failed → EOF.
            WsRead::Eof
        }
    }

    /// Send one message. The host no longer buffers, so this is four-valued
    /// (see [`WsWrite`]): the whole message accepted, a permanent size error, a
    /// would-block to park on, or a close. Mirrors `read_into` on the read side.
    fn send(&self, data: &[u8]) -> WsWrite {
        match self.0.borrow_mut().conn.send(data) {
            Ok(n) => WsWrite::Sent(n),
            Err(NetError::WouldBlock) => WsWrite::Pending,
            Err(NetError::MessageTooBig) => WsWrite::MessageTooBig,
            Err(_) => WsWrite::Closed,
        }
    }

    /// `mc_sys_poll` readiness: a message is buffered or the connection failed.
    fn poll_readable(&self) -> bool {
        self.0.borrow_mut().fill()
    }

    /// `mc_sys_poll` write-readiness: the transport can take a frame (open +
    /// below the mark) or is closed (so the write wakes and errors out). Replaces
    /// the old "a ws is always writable" assumption now that the host buffers
    /// nothing — the dual of `poll_readable`.
    fn poll_writable(&self) -> bool {
        self.0.borrow().conn.poll_writable()
    }

    /// `mc_sys_poll` hang-up: the connection has closed/errored.
    fn poll_hup(&self) -> bool {
        self.0.borrow().failed
    }
}

/// Instructions run per scheduler step before yielding (cooperative quantum).
/// Applies UNIFORMLY to every invocation — top-level and nested inside an
/// `mc_sys_pcall` protected call alike. (Nested bodies once needed a special
/// whole-budget slab to dodge a wasmi nested-`OutOfFuel`-resume failure; that was
/// the lazy-translation corruption, now fixed by eager compilation — SYSTEMS.md §4.3
/// — so the slab is gone and the `pcall_stack` governs only throw-unwinding.)
const FUEL_QUANTUM: u64 = 2_000_000;

/// A per-guest resource budget in the runtime contract: memory + lifetime fuel +
/// table size. A guest may DECLARE one in an `mc_budget` wasm custom section
/// (`declare_budget!`); the kernel applies `min(declared|default, vm_ceiling)`,
/// itself clamped to the hard maximum. The image manifest sets the VM ceiling via
/// `mc_boot_contract` — that's "Docker can't say: runs deterministically in ≤N MiB".
#[derive(Clone, Copy)]
pub struct Budget {
    pub mem_bytes: usize,
    pub fuel: u64,
    pub table: usize,
}

impl Budget {
    /// What an undeclared guest gets (today's fixed limits — no behavior change).
    pub const DEFAULT: Budget = Budget {
        mem_bytes: 16 * 1024 * 1024,
        fuel: 50_000_000_000,
        table: 10_000,
    };
    /// The absolute ceiling no budget may exceed (SYSTEMS.md §10.4 hard maxima).
    pub const HARD: Budget = Budget {
        mem_bytes: 1024 * 1024 * 1024,
        fuel: 4_000_000_000_000,
        table: 1_000_000,
    };

    /// Clamp each field to `self ≤ other` (used to intersect declared ∩ ceiling ∩ hard).
    fn clamped_to(self, other: Budget) -> Budget {
        Budget {
            mem_bytes: self.mem_bytes.min(other.mem_bytes),
            fuel: self.fuel.min(other.fuel),
            table: self.table.min(other.table),
        }
    }
}

/// The VM-wide budget ceiling, set once at boot from the image manifest's
/// contract; defaults to the hard maximum (no extra restriction). The newtype +
/// `unsafe impl Sync` is the kernel's single-threaded-static idiom (cf.
/// `CtlBuffer`).
struct BudgetCell(core::cell::UnsafeCell<Budget>);
unsafe impl Sync for BudgetCell {}
static BUDGET_CEILING: BudgetCell = BudgetCell(core::cell::UnsafeCell::new(Budget::HARD));

/// Set the VM budget ceiling (called once at boot before any guest spawns).
pub fn set_budget_ceiling(b: Budget) {
    unsafe {
        *BUDGET_CEILING.0.get() = b;
    }
}

/// The effective budget for a freshly-loaded guest: `min(declared|default,
/// vm_ceiling, hard)`.
fn effective_budget(declared: Option<Budget>) -> Budget {
    let ceiling = unsafe { *BUDGET_CEILING.0.get() };
    declared
        .unwrap_or(Budget::DEFAULT)
        .clamped_to(ceiling)
        .clamped_to(Budget::HARD)
}

/// Create the shared interpreter engine (one per kernel instance). Fuel
/// metering is on so guest execution is bounded and resumable; compilation is
/// EAGER so translation never happens inside a fuel slice (see below).
pub fn new_engine() -> Engine {
    let mut config = wasmi::Config::default();
    config.consume_fuel(true);
    // Eager: translate every function at `Module::new`, not lazily on first call.
    // wasmi's default `LazyTranslation` charges the *guest's fuel* for translating
    // a function the first time it is called; if a fuel slice runs dry mid-
    // translation, resuming that is the path wasmi 1.0.9 corrupts (host SIGSEGV /
    // `BadConversionToInteger` in-sandbox). Translating up front moves all
    // translation out of the fuel-metered execution path, so heavy guests (typst,
    // agent) run safely on the normal cooperative `FUEL_QUANTUM` slices — no
    // single-slice workaround needed. Cost: the whole module is translated once at
    // load (cached permanently in `GuestRuntime`, captured in snapshots). Root
    // cause + proof: SYSTEMS.md §4.3.
    config.compilation_mode(wasmi::CompilationMode::Eager);
    Engine::new(&config)
}

/// The shared user-space runtime: the wasmi engine, ONE linker (the `mc_sys_*`
/// host functions registered once and reused for every spawn), and a permanent
/// compiled-`Module` cache keyed by a content hash of the program bytes.
///
/// Why the cache: `Module::new` translates the whole program, and wasmi keeps
/// that translated code in an engine-wide arena that is never freed for the
/// engine's lifetime (no `Drop for Module`, no arena removal). Re-translating a
/// program on every spawn therefore piles duplicate code into the engine and
/// grows kernel linear memory without bound. Compiling each distinct program
/// exactly once caps that growth at the set of programs actually run — and makes
/// spawns much cheaper (no re-decode of MB-scale binaries). The cache is
/// PERMANENT by design: evicting a `Module` frees nothing (the engine retains
/// its funcs) and recompiling would only re-leak, so there is deliberately no
/// LRU. `Module`/`Engine` are `Arc`-backed, so caching and cloning are cheap.
///
/// Lives in `STATE`, created once at boot, so it is captured verbatim in a
/// snapshot and restored byte-for-byte — restore needs no special handling.
pub struct GuestRuntime {
    engine: Engine,
    /// Reusable across every guest `Store`: the host-fn closures are stateless
    /// (they only record into `Caller`'s `GuestState.pending`), and
    /// `Linker::instantiate_and_start` takes `&self`.
    linker: Linker<GuestState>,
    cache: RefCell<BTreeMap<u64, Module>>,
}

impl GuestRuntime {
    /// Build the runtime: take the engine and register the syscall host
    /// functions on a single reusable linker.
    pub fn new(engine: Engine) -> GuestRuntime {
        let mut linker = Linker::new(&engine);
        // The import set is the fixed `abi` syscall table, so registration only
        // fails on a programming error — treat it as fatal at boot.
        register_syscalls(&mut linker).expect("register guest syscalls");
        GuestRuntime {
            engine,
            linker,
            cache: RefCell::new(BTreeMap::new()),
        }
    }

    /// The shared interpreter engine.
    pub fn engine(&self) -> &Engine {
        &self.engine
    }

    /// Compile `bytes` to a `Module`, reusing a previously-compiled one when the
    /// same program bytes were loaded before (content-addressed). The returned
    /// `Module` is a cheap `Arc` clone; the cache borrow never spans
    /// instantiation.
    fn module_for(&self, bytes: &[u8]) -> Result<Module, String> {
        let key = fnv1a_64(bytes);
        {
            let cache = self.cache.borrow();
            if let Some(m) = cache.get(&key) {
                return Ok(m.clone());
            }
        }
        let module =
            Module::new(&self.engine, bytes).map_err(|e| format!("invalid wasm module: {e}"))?;
        self.cache.borrow_mut().insert(key, module.clone());
        Ok(module)
    }
}

/// FNV-1a (64-bit) over `bytes` — a fast, dependency-free content hash for the
/// module cache. The input is trusted, kernel-resident program bytes and the
/// distinct-program count is tiny (the shipped toolset), so a 64-bit hash is far
/// more than enough to avoid collisions.
fn fnv1a_64(bytes: &[u8]) -> u64 {
    const OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const PRIME: u64 = 0x0000_0100_0000_01b3;
    let mut h = OFFSET;
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(PRIME);
    }
    h
}

/// The host error a syscall returns to suspend the guest. `wasmi` surfaces it
/// as a resumable `HostTrap`; the kernel reads `GuestState.pending` to learn
/// which syscall and resumes once it is fulfilled.
#[derive(Debug)]
struct Suspend;

impl fmt::Display for Suspend {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "mc_syscall")
    }
}

impl wasmi::errors::HostError for Suspend {}

fn suspend() -> wasmi::Error {
    wasmi::Error::host(Suspend)
}

/// A syscall recorded by a thin host fn, fulfilled by `step()`. **Generated**
/// from the canonical `abi` syscall table: each row becomes a variant whose
/// fields are the syscall's arguments (kernel storage types). Adding a syscall
/// to the table adds a variant here, which makes the exhaustive `fulfill` match
/// fail to compile until its handler is wired — drift is impossible.
macro_rules! mc_pending_enum {
    ( $( $ident:ident => $Variant:ident ( $($arg:ident : $ty:tt),* ) [$ret:tt]; )* ) => {
        #[derive(Clone, Copy)]
        enum Pending {
            $( $Variant { $($arg: $ty),* } ),*
        }
    };
}
crate::wasm::abi::mc_syscall_table!(mc_pending_enum);

/// `wasmi` Store data for one guest.
struct GuestState {
    pending: Option<Pending>,
    /// Monotonic-ms deadline for an in-progress `sleep_ms`/`poll` timeout,
    /// computed on the first fulfillment and carried across cooperative yields
    /// (the macro-generated `Pending` variants can't hold extra state). `None`
    /// when no timed syscall is mid-flight.
    timed_deadline: Option<i64>,
    /// The error code recorded by `mc_sys_set_throw` immediately before a C/C++
    /// guest traps to unwind to its nearest `mc_sys_pcall` boundary (the kernel
    /// trap-unwind shim). `step()` reads it when the trap surfaces to tell
    /// an intentional Lua/parser "throw" (code present → caught) from a genuine
    /// fault (absent → crash), hands the code back as `pcall`'s result, and clears
    /// it. `None` when no throw is in flight.
    throw_code: Option<i32>,
    exit_code: Option<i32>,
    /// The full argument vector, `argv[0]` = program name (POSIX convention),
    /// returned verbatim by `mc_sys_args`.
    argv: Vec<String>,
    limits: StoreLimits,
}

/// Outcome of fulfilling a pending syscall.
enum Fulfilled {
    /// Resume the guest, feeding this value as the syscall's i32 result.
    Resume(i32),
    /// The guest cannot make progress; park it on this block reason.
    Block(BuiltinStep),
    /// The guest is exiting with this code.
    Exit(i32),
}

/// Suspended-call state carried across `step()`s.
enum Resume {
    Start,
    HostTrap(wasmi::TypedResumableCallHostTrap<()>),
    OutOfFuel(wasmi::TypedResumableCallOutOfFuel<()>),
}

/// One suspended `mc_sys_pcall` boundary on the kernel's protected-call stack.
/// When a guest calls `mc_sys_pcall`, the kernel parks the calling
/// invocation here and runs the guest's `__mc_pcall_run` dispatcher as a NESTED
/// guest call (a fresh `call_resumable` on the same store — proven safe: a
/// suspended invocation does not borrow the store). If that child traps
/// (`luaD_throw` → `mc_sys_set_throw` + `unreachable`), wasmi unwinds the nested
/// call and the kernel resumes this parent, feeding back the recorded error code
/// and restoring the shadow-stack pointer the trap left dangling.
struct PcallFrame {
    parent: wasmi::TypedResumableCallHostTrap<()>,
    /// The guest `__stack_pointer` value at the moment the child was started, to
    /// restore after a trap (wasm globals are store-wide and a trap does not
    /// rewind them, so the child's deep SP would otherwise corrupt the parent).
    saved_sp: i32,
}

/// What to do after a guest call returned `Err` (a wasm trap): either continue the
/// `step()` loop with a freshly-resumed parent invocation (an intentional throw
/// caught by a protected boundary), or terminate this step.
enum TrapAction {
    Outcome(TypedResumableCall<()>),
    Step(BuiltinStep),
}

/// A loaded wasm32 user program, driven as a cooperative `Builtin`.
pub struct GuestProgram {
    store: Store<GuestState>,
    memory: Memory,
    entry: TypedFunc<(), ()>,
    resume: Option<Resume>,
    fuel_used: u64,
    /// This guest's lifetime fuel ceiling (from its effective {@link Budget}).
    fuel_budget: u64,
    /// The program's own fd table for fds ≥ 3 (index = fd − 3). Standard fds
    /// 0/1/2 route to the task's stdin/stdout/stderr via `BuiltinCtx`.
    files: Vec<Option<GuestFd>>,
    /// `$PATH` snapshot at spawn time, so a guest's `mc_sys_spawn` can resolve
    /// the program it launches.
    path: String,
    /// Stack of suspended `mc_sys_pcall` boundaries (innermost last), for C/C++
    /// guests that unwind errors through the kernel. Empty for the common
    /// case (native Rust guests, or a C/C++ guest not currently inside a pcall).
    pcall_stack: Vec<PcallFrame>,
    /// The guest's `__mc_pcall_run` dispatcher export — the entry the kernel
    /// re-enters to run a stashed protected thunk. `None` unless the guest opts
    /// into the trap-unwind shim by exporting it (only the Luau guest does today).
    pcall_run: Option<TypedFunc<(), ()>>,
    /// The guest's exported `__stack_pointer` global, saved/restored across a
    /// trap-unwound `pcall`. `None` unless exported (paired with `pcall_run`).
    sp_global: Option<Global>,
}

impl GuestProgram {
    /// Instantiate `bytes` as a fresh guest against the shared [`GuestRuntime`].
    /// The program is compiled once and cached (`rt.module_for`) and the runtime's
    /// single linker is reused — only the per-spawn `Store` is new. Returns an
    /// error string (so the shell can report it) if the module is invalid or
    /// won't link; callers do this before spawning a task so a bad program leaves
    /// no zombie.
    pub fn load(
        rt: &GuestRuntime,
        bytes: &[u8],
        argv: Vec<String>,
        path: &str,
    ) -> Result<GuestProgram, String> {
        let module = rt.module_for(bytes)?;
        // Conformance gate: a duplicate or present-but-malformed mc_tier/mc_budget is a hard load
        // failure, not a silent fall-through (which would inherit the parent tier / default budget).
        validate_mc_sections(bytes)?;
        // The guest's effective budget: its declared `mc_budget` (or the default),
        // clamped to the VM ceiling (image manifest) and the hard maximum.
        let budget = effective_budget(declared_budget(bytes));
        let state = GuestState {
            pending: None,
            timed_deadline: None,
            throw_code: None,
            exit_code: None,
            argv,
            limits: StoreLimitsBuilder::new()
                .memory_size(budget.mem_bytes)
                .table_elements(budget.table)
                .build(),
        };
        let mut store = Store::new(&rt.engine, state);
        store.limiter(|s| &mut s.limits);

        let instance = rt
            .linker
            .instantiate_and_start(&mut store, &module)
            .map_err(|e| format!("instantiate: {e}"))?;

        let memory = instance
            .get_memory(&store, "memory")
            .ok_or_else(|| String::from("program exports no memory"))?;
        let entry = instance
            .get_typed_func::<(), ()>(&store, "_start")
            .map_err(|_| String::from("program exports no _start"))?;
        // Optional trap-unwind shim exports. A guest opts in by exporting
        // BOTH the protected-call dispatcher and its shadow-stack pointer; native
        // Rust guests export neither and never call `mc_sys_pcall`.
        let pcall_run = instance
            .get_typed_func::<(), ()>(&store, "__mc_pcall_run")
            .ok();
        let sp_global = instance.get_global(&store, "__stack_pointer");
        // All-or-nothing: re-entering via __mc_pcall_run needs the shadow-stack pointer to
        // save/restore across the trap, and the pointer is meaningless without the dispatcher. A
        // guest exporting EXACTLY ONE (a mis-linked or hand-crafted shim) would half-arm the unwind
        // and corrupt the stack on its first mc_sys_pcall — reject it at load instead.
        if pcall_run.is_some() != sp_global.is_some() {
            return Err(String::from(
                "trap-unwind shim incomplete: a guest must export BOTH __mc_pcall_run and \
                 __stack_pointer, or neither",
            ));
        }

        Ok(GuestProgram {
            store,
            memory,
            entry,
            resume: Some(Resume::Start),
            fuel_used: 0,
            fuel_budget: budget.fuel,
            files: Vec::new(),
            path: String::from(path),
            pcall_stack: Vec::new(),
            pcall_run,
            sp_global,
        })
    }

    /// Install a guest fd and return its number (≥ 3), or `None` if the
    /// per-VM open-fd budget (`MAX_OPEN_FDS`) is exhausted.
    fn alloc_fd(&mut self, fd: GuestFd) -> Option<i32> {
        for (i, slot) in self.files.iter_mut().enumerate() {
            if slot.is_none() {
                *slot = Some(fd);
                return Some((i + 3) as i32);
            }
        }
        if self.files.len() >= MAX_OPEN_FDS {
            return None;
        }
        self.files.push(Some(fd));
        Some((self.files.len() + 2) as i32)
    }

    fn fd_slots_available(&self, needed: usize) -> bool {
        let used = self.files.iter().filter(|slot| slot.is_some()).count();
        used.saturating_add(needed) <= MAX_OPEN_FDS
    }

    /// The live capability set + confinement of this guest's task. Privileged
    /// syscalls consult this to enforce the policy assigned at exec.
    fn policy(&self, ctx: &BuiltinCtx<'_>) -> (Capabilities, Option<String>) {
        match ctx.sched.get_task(ctx.pid) {
            Some(t) => (t.caps, t.confine_root.clone()),
            None => (Capabilities::none(), None),
        }
    }

    /// Consume a pending *ignored* interrupting signal (INT/TERM/HUP/TSTP), if
    /// any. Returns true when one was found and cleared, meaning a blocking
    /// syscall should return `EINTR` instead of parking. With no async handlers
    /// this is the only way a task that ignores a signal can still react to it
    /// — the interactive shell uses it to break its console read on Ctrl-C.
    fn take_eintr(&self, ctx: &BuiltinCtx<'_>) -> bool {
        let mut hit = false;
        if let Some(t) = ctx.sched.get_task(ctx.pid) {
            for sig in [SIGINT, SIGTERM, SIGHUP, SIGTSTP] {
                if t.signal_pending(sig) && t.signal_ignored(sig) {
                    t.clear_signal(sig);
                    hit = true;
                }
            }
        }
        hit
    }

    /// Copy a path string out of guest memory.
    fn read_guest_str(&self, ptr: u32, len: u32) -> Option<String> {
        let mem = self.memory.data(&self.store);
        let (p, l) = (ptr as usize, len as usize);
        let end = p.checked_add(l).filter(|&e| e <= mem.len())?;
        core::str::from_utf8(&mem[p..end]).ok().map(String::from)
    }

    fn guest_range_valid(&self, ptr: u32, len: usize) -> bool {
        let memlen = self.memory.data(&self.store).len();
        (ptr as usize)
            .checked_add(len)
            .is_some_and(|end| end <= memlen)
    }

    fn write_guest_bytes(&mut self, ptr: u32, bytes: &[u8]) -> Result<(), i32> {
        if !self.guest_range_valid(ptr, bytes.len()) {
            return Err(EINVAL);
        }
        self.memory
            .write(&mut self.store, ptr as usize, bytes)
            .map_err(|_| EINVAL)
    }

    fn write_guest_u32(&mut self, ptr: u32, value: u32) -> Result<(), i32> {
        self.write_guest_bytes(ptr, &value.to_le_bytes())
    }

    fn write_guest_i64(&mut self, ptr: u32, value: i64) -> Result<(), i32> {
        self.write_guest_bytes(ptr, &value.to_le_bytes())
    }

    fn read_guest_i64(&self, ptr: u32) -> Result<i64, i32> {
        if !self.guest_range_valid(ptr, 8) {
            return Err(EINVAL);
        }
        let mem = self.memory.data(&self.store);
        let p = ptr as usize;
        let mut b = [0u8; 8];
        b.copy_from_slice(&mem[p..p + 8]);
        Ok(i64::from_le_bytes(b))
    }

    /// Terminal syscall outcome: clear `pending` (so `step()` does NOT re-run
    /// this syscall) and resume the guest with `code`. The companion to a
    /// `Fulfilled::Block(BuiltinStep::Pending)`, which leaves `pending` set to
    /// re-run the syscall on a later tick.
    fn done(&mut self, code: i32) -> Fulfilled {
        self.store.data_mut().pending = None;
        Fulfilled::Resume(code)
    }

    /// Settle a terminal namespace op whose success carries no payload beyond a
    /// status. `WouldBlock` keeps `pending` set and yields (`BuiltinStep::Pending`)
    /// so `step()` re-runs the whole syscall next tick — the served fs dedups by
    /// caller, so re-issuing is idempotent. Success
    /// resumes with `ok`; any other error resumes with its errno. Call ONLY after
    /// path resolution, which is synchronous by invariant — `Namespace::canonicalize`
    /// never yields, so `WouldBlock` can only arise from the terminal op here.
    fn settle(&mut self, ok: i32, r: core::result::Result<(), FsError>) -> Fulfilled {
        match r {
            Err(FsError::WouldBlock) => Fulfilled::Block(BuiltinStep::Pending),
            Ok(()) => self.done(ok),
            Err(e) => self.done(errno_from_fs(e)),
        }
    }

    /// Fulfill the currently-pending syscall against the kernel.
    fn fulfill(&mut self, ctx: &mut BuiltinCtx<'_>) -> Fulfilled {
        let pending = match self.store.data().pending {
            Some(p) => p,
            None => return Fulfilled::Resume(EINVAL),
        };
        match pending {
            Pending::Exit { code } => {
                self.store.data_mut().pending = None;
                Fulfilled::Exit(code)
            }
            // Record the error code a C/C++ guest is about to "throw" with; it then
            // executes `unreachable` to unwind to its nearest `mc_sys_pcall`.
            Pending::SetThrow { code } => {
                let st = self.store.data_mut();
                st.pending = None;
                st.throw_code = Some(code);
                Fulfilled::Resume(ESUCCESS)
            }
            // `mc_sys_pcall` never reaches `fulfill`: `step()` intercepts it to run
            // the guest's `__mc_pcall_run` dispatcher as a nested call. Reaching here
            // would mean the interception was bypassed — fail closed, don't panic.
            Pending::Pcall {} => {
                self.store.data_mut().pending = None;
                Fulfilled::Resume(EINVAL)
            }
            Pending::Write {
                fd,
                ptr,
                len,
                ret_n,
            } => self.fulfill_write(ctx, fd, ptr, len, ret_n),
            Pending::Read {
                fd,
                ptr,
                len,
                ret_n,
            } => self.fulfill_read(ctx, fd, ptr, len, ret_n),
            Pending::Open {
                path_ptr,
                path_len,
                flags,
                ret_fd,
            } => self.fulfill_open(ctx, path_ptr, path_len, flags, ret_fd),
            Pending::Close { fd } => {
                self.store.data_mut().pending = None;
                if fd >= 3 {
                    if let Some(slot) = self.files.get_mut((fd - 3) as usize) {
                        // Closing a pipe end marks it closed so the peer sees
                        // EOF / broken-pipe.
                        match slot.take() {
                            Some(GuestFd::PipeRead(mut ps)) => ps.close(),
                            Some(GuestFd::PipeWrite(mut pk)) => pk.close(),
                            _ => {}
                        }
                    }
                }
                Fulfilled::Resume(ESUCCESS)
            }
            Pending::Args { ptr, len, ret_len } => self.fulfill_args(ptr, len, ret_len),
            Pending::Stat {
                path_ptr,
                path_len,
                ret_stat,
            } => self.fulfill_stat(ctx, path_ptr, path_len, ret_stat),
            Pending::Readdir {
                path_ptr,
                path_len,
                buf,
                buf_len,
                ret_len,
            } => self.fulfill_readdir(ctx, path_ptr, path_len, buf, buf_len, ret_len),
            Pending::Mkdir { path_ptr, path_len } => self.fulfill_mkdir(ctx, path_ptr, path_len),
            Pending::Unlink { path_ptr, path_len } => self.fulfill_unlink(ctx, path_ptr, path_len),
            Pending::Rename {
                from_ptr,
                from_len,
                to_ptr,
                to_len,
            } => self.fulfill_rename(ctx, from_ptr, from_len, to_ptr, to_len),
            Pending::Chmod {
                path_ptr,
                path_len,
                mode,
            } => self.fulfill_chmod(ctx, path_ptr, path_len, mode),
            Pending::Utimes {
                path_ptr,
                path_len,
                times_ptr,
            } => self.fulfill_utimes(ctx, path_ptr, path_len, times_ptr),
            Pending::Pipe { ret_r, ret_w } => self.fulfill_pipe(ctx, ret_r, ret_w),
            Pending::Dup { fd, ret_fd } => self.fulfill_dup(fd, ret_fd),
            Pending::Dup2 { old_fd, new_fd } => self.fulfill_dup2(old_fd, new_fd),
            Pending::Getpid { ret } => {
                self.store.data_mut().pending = None;
                match self.write_guest_u32(ret, ctx.pid as u32) {
                    Ok(()) => Fulfilled::Resume(ESUCCESS),
                    Err(e) => Fulfilled::Resume(e),
                }
            }
            Pending::Getppid { ret } => {
                self.store.data_mut().pending = None;
                let ppid = ctx
                    .sched
                    .get_task(ctx.pid)
                    .and_then(|t| t.parent_id)
                    .unwrap_or(0);
                match self.write_guest_u32(ret, ppid as u32) {
                    Ok(()) => Fulfilled::Resume(ESUCCESS),
                    Err(e) => Fulfilled::Resume(e),
                }
            }
            Pending::Spawn {
                argv_ptr,
                argv_len,
                in_fd,
                out_fd,
                err_fd,
                tier,
                ret_pid,
            } => self.fulfill_spawn(
                ctx, argv_ptr, argv_len, in_fd, out_fd, err_fd, tier, ret_pid,
            ),
            Pending::Waitpid {
                pid,
                opts,
                ret_status,
                ret_pid,
            } => self.fulfill_waitpid(ctx, pid, opts, ret_status, ret_pid),
            Pending::HttpGet {
                url_ptr,
                url_len,
                ret_fd,
            } => self.fulfill_http_get(ctx, url_ptr, url_len, ret_fd),
            Pending::HttpRequest {
                req_ptr,
                req_len,
                ret_fd,
            } => self.fulfill_http_request(ctx, req_ptr, req_len, ret_fd),
            Pending::HttpStatus { fd, ret_status } => self.fulfill_http_status(fd, ret_status),
            Pending::WsOpen {
                url_ptr,
                url_len,
                ret_fd,
            } => self.fulfill_ws_open(ctx, url_ptr, url_len, ret_fd),
            Pending::TimeMonotonic { ret } => {
                self.store.data_mut().pending = None;
                // CAP_AMBIENT: reading the host clock is an ambient, nondeterministic
                // authority; a narrowed (sub-`full`) child is denied it.
                if !self.policy(ctx).0.has(CAP_AMBIENT) {
                    return Fulfilled::Resume(EPERM);
                }
                let ms = unsafe { crate::bridge::mc_time_monotonic() };
                match self.write_guest_i64(ret, ms) {
                    Ok(()) => Fulfilled::Resume(ESUCCESS),
                    Err(e) => Fulfilled::Resume(e),
                }
            }
            Pending::TimeRealtime { ret } => {
                self.store.data_mut().pending = None;
                // Wall clock (ms since the Unix epoch). Same ambient CAP_AMBIENT
                // authority as the monotonic clock — a narrowed child is denied it.
                if !self.policy(ctx).0.has(CAP_AMBIENT) {
                    return Fulfilled::Resume(EPERM);
                }
                let ms = unsafe { crate::bridge::mc_time_now() };
                match self.write_guest_i64(ret, ms) {
                    Ok(()) => Fulfilled::Resume(ESUCCESS),
                    Err(e) => Fulfilled::Resume(e),
                }
            }
            Pending::Random { ptr, len } => self.fulfill_random(ctx, ptr, len),
            Pending::AbiVersion { ret } => {
                self.store.data_mut().pending = None;
                let v = abi_version() as u32;
                match self.write_guest_u32(ret, v) {
                    Ok(()) => Fulfilled::Resume(ESUCCESS),
                    Err(e) => Fulfilled::Resume(e),
                }
            }
            Pending::Getcwd {
                buf,
                buf_len,
                ret_len,
            } => self.fulfill_getcwd(ctx, buf, buf_len, ret_len),
            Pending::Chdir { path_ptr, path_len } => self.fulfill_chdir(ctx, path_ptr, path_len),
            Pending::Lseek {
                fd,
                off_ptr,
                whence,
            } => self.fulfill_lseek(fd, off_ptr, whence),
            Pending::Ftruncate {
                fd,
                size_lo,
                size_hi,
            } => self.fulfill_ftruncate(fd, size_lo, size_hi),
            Pending::SleepMs { ms } => self.fulfill_sleep_ms(ctx, ms),
            Pending::Poll {
                fds_ptr,
                nfds,
                timeout_ms,
                ret_ready,
            } => self.fulfill_poll(ctx, fds_ptr, nfds, timeout_ms, ret_ready),
            Pending::Bind {
                old_ptr,
                old_len,
                new_ptr,
                new_len,
            } => self.fulfill_bind(ctx, old_ptr, old_len, new_ptr, new_len),
            Pending::Unmount { path_ptr, path_len } => {
                self.fulfill_unmount(ctx, path_ptr, path_len)
            }
            Pending::Serve {
                path_ptr,
                path_len,
                ret_fd,
            } => self.fulfill_serve(ctx, path_ptr, path_len, ret_fd),
            Pending::ServeRecv {
                fd,
                buf,
                buf_len,
                ret_len,
            } => self.fulfill_serve_recv(fd, buf, buf_len, ret_len),
            Pending::ServeRespond {
                fd,
                req_id,
                status,
                data_ptr,
                data_len,
            } => self.fulfill_serve_respond(fd, req_id, status, data_ptr, data_len),
            Pending::HostCall {
                req_ptr,
                req_len,
                ret_fd,
            } => self.fulfill_host_call(ctx, req_ptr, req_len, ret_fd),
            Pending::SvcServe {
                name_ptr,
                name_len,
                ret_fd,
            } => self.fulfill_svc_serve(ctx, name_ptr, name_len, ret_fd),
            Pending::SvcRecv {
                fd,
                buf,
                buf_len,
                hbuf,
                hbuf_len,
                ret_len,
            } => self.fulfill_svc_recv(ctx, fd, buf, buf_len, hbuf, hbuf_len, ret_len),
            Pending::SvcRespond {
                fd,
                session,
                req_id,
                status,
                data_ptr,
                data_len,
                last,
            } => self.fulfill_svc_respond(fd, session, req_id, status, data_ptr, data_len, last),
            Pending::SvcConnect {
                name_ptr,
                name_len,
                ret_fd,
            } => self.fulfill_svc_connect(ctx, name_ptr, name_len, ret_fd),
            Pending::SvcCall {
                fd,
                req_ptr,
                req_len,
                handles_ptr,
                nhandles,
                ret_fd,
            } => self.fulfill_svc_call(ctx, fd, req_ptr, req_len, handles_ptr, nhandles, ret_fd),
            Pending::Kill { pid, sig } => self.fulfill_kill(ctx, pid, sig),
            Pending::Sigdisp { sig, disp } => self.fulfill_sigdisp(ctx, sig, disp),
            Pending::Setpgid { pid, pgid } => self.fulfill_setpgid(ctx, pid, pgid),
            Pending::Tcsetpgrp { pgid } => self.fulfill_tcsetpgrp(ctx, pgid),
            Pending::Symlink {
                target_ptr,
                target_len,
                link_ptr,
                link_len,
            } => self.fulfill_symlink(ctx, target_ptr, target_len, link_ptr, link_len),
            Pending::Link {
                old_ptr,
                old_len,
                new_ptr,
                new_len,
            } => self.fulfill_link(ctx, old_ptr, old_len, new_ptr, new_len),
            Pending::Readlink {
                path_ptr,
                path_len,
                buf,
                buf_len,
                ret_len,
            } => self.fulfill_readlink(ctx, path_ptr, path_len, buf, buf_len, ret_len),
            Pending::Lstat {
                path_ptr,
                path_len,
                ret_stat,
            } => self.fulfill_lstat(ctx, path_ptr, path_len, ret_stat),
            Pending::Nice { inc, ret } => self.fulfill_nice(ctx, inc, ret),
            Pending::Isatty { fd, ret } => self.fulfill_isatty(ctx, fd, ret),
        }
    }

    fn fulfill_read(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        fd: i32,
        ptr: u32,
        len: u32,
        ret_n: u32,
    ) -> Fulfilled {
        let l = len as usize;
        if !self.guest_range_valid(ptr, l) || !self.guest_range_valid(ret_n, 4) {
            self.store.data_mut().pending = None;
            return Fulfilled::Resume(EINVAL);
        }
        let mut tmp = Vec::new();
        tmp.resize(l, 0u8);

        // Read result: bytes read, EOF (0), block on a pipe, yield (an HTTP
        // body still in flight), or an error.
        enum R {
            Got(usize),
            Block(BlockReason),
            Pending,
            Err(i32),
        }
        let r = if fd == 0 {
            match ctx.stdin.read(&mut tmp) {
                Ok(0) if !ctx.stdin.is_eof() => match ctx.stdin.block_handle() {
                    Some(p) => R::Block(BlockReason::PipeRead { pipe_ptr: p }),
                    None => R::Got(0),
                },
                Ok(n) => R::Got(n),
                Err(_) => R::Err(EIO),
            }
        } else if fd >= 3 {
            match self
                .files
                .get_mut((fd - 3) as usize)
                .and_then(|s| s.as_mut())
            {
                Some(GuestFd::File(h)) => match h.read(&mut tmp) {
                    Ok(n) => R::Got(n),
                    // A connection/server-backed handle not yet ready —
                    // yield and re-read next tick (same machinery as a net fd).
                    Err(FsError::WouldBlock) => R::Pending,
                    Err(_) => R::Err(EIO),
                },
                Some(GuestFd::PipeRead(ps)) => match ps.read(&mut tmp) {
                    Ok(0) if !ps.is_eof() => R::Block(BlockReason::PipeRead {
                        pipe_ptr: ps.pipe as usize,
                    }),
                    Ok(n) => R::Got(n),
                    Err(_) => R::Err(EIO),
                },
                Some(GuestFd::Net(ns)) => match ns.read_into(&mut tmp) {
                    NetRead::Pending => R::Pending,
                    NetRead::Got(n) => R::Got(n),
                    NetRead::Eof => R::Got(0),
                    NetRead::Failed => R::Err(EIO),
                },
                Some(GuestFd::HostCall(hc)) => match hc.read_into(&mut tmp) {
                    HostCallRead::Pending => R::Pending,
                    HostCallRead::Got(n) => R::Got(n),
                    HostCallRead::Eof => R::Got(0),
                    HostCallRead::Failed => R::Err(EIO),
                },
                Some(GuestFd::SvcCall(sc)) => match sc.read_into(&mut tmp) {
                    SvcRead::Pending => R::Pending,
                    SvcRead::Got(n) => R::Got(n),
                    SvcRead::Eof => R::Got(0),
                    SvcRead::Closed => R::Err(EIO),
                    SvcRead::Failed(errno) => R::Err(errno),
                },
                Some(GuestFd::Ws(ws)) => match ws.read_into(&mut tmp) {
                    WsRead::Got(n) => R::Got(n),
                    WsRead::Pending => R::Pending,
                    WsRead::Eof => R::Got(0),
                },
                Some(GuestFd::PipeWrite(_))
                | Some(GuestFd::Serve(_))
                | Some(GuestFd::SvcServe(_))
                | Some(GuestFd::SvcConn(_))
                | None => R::Err(EBADF),
            }
        } else {
            R::Err(EBADF)
        };

        match r {
            R::Block(reason) => {
                // An ignored, pending interrupting signal aborts the blocking
                // read with EINTR rather than parking (e.g. the interactive
                // shell redraws its prompt on Ctrl-C).
                if self.take_eintr(ctx) {
                    self.store.data_mut().pending = None;
                    return Fulfilled::Resume(EINTR);
                }
                Fulfilled::Block(BuiltinStep::BlockedOn(reason))
            }
            // The response is still being fetched: keep `pending` set and yield
            // so the next step re-polls (no pipe to park on).
            R::Pending => Fulfilled::Block(BuiltinStep::Pending),
            R::Err(e) => {
                self.store.data_mut().pending = None;
                Fulfilled::Resume(e)
            }
            R::Got(n) => {
                if let Err(e) = self.write_guest_bytes(ptr, &tmp[..n]) {
                    self.store.data_mut().pending = None;
                    return Fulfilled::Resume(e);
                }
                if let Err(e) = self.write_guest_u32(ret_n, n as u32) {
                    self.store.data_mut().pending = None;
                    return Fulfilled::Resume(e);
                }
                self.store.data_mut().pending = None;
                Fulfilled::Resume(ESUCCESS)
            }
        }
    }

    fn fulfill_open(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        path_ptr: u32,
        path_len: u32,
        flags: i32,
        ret_fd: u32,
    ) -> Fulfilled {
        self.store.data_mut().pending = None;
        if !self.guest_range_valid(ret_fd, 4) {
            return Fulfilled::Resume(EINVAL);
        }
        let raw = match self.read_guest_str(path_ptr, path_len) {
            Some(s) => s,
            None => return Fulfilled::Resume(EINVAL),
        };
        let lexical = crate::builtins::fs::resolve_path(ctx.cwd, &raw);
        let f = if flags == 0 { O_READ } else { flags };
        let mut of = open_flags(f);
        // `open` follows a trailing symlink (this ABI has no `O_NOFOLLOW`).
        // Canonicalize before the confinement check so a symlink target cannot
        // escape the isolation root.
        let path = match ctx.ns.canonicalize(&lexical, true) {
            Ok(p) => p,
            Err(e) => return Fulfilled::Resume(errno_from_fs(e)),
        };

        // Capability check: writing requires the resolved mount's write
        // capability (CAP_FS_WRITE for ordinary mounts, CAP_SCRATCH for the
        // private /scratch tmpfs), reading requires CAP_FS_READ, and an isolated
        // task may not escape its root.
        let (caps, root) = self.policy(ctx);
        // Deterministic (isolated) tasks lack ambient authority; suppress atime
        // updates on their reads so a read cannot leak the wall clock via atime.
        of.noatime = !caps.has(CAP_AMBIENT);
        let writes = of.write || of.create || of.truncate || of.append;
        if writes && !caps.has(ctx.ns.write_cap_at(&path)) {
            return Fulfilled::Resume(EPERM);
        }
        if (of.read || !writes) && !caps.has(CAP_FS_READ) {
            return Fulfilled::Resume(EPERM);
        }
        if !path_within(root.as_deref(), path.as_str()) {
            return Fulfilled::Resume(EPERM);
        }
        // Persistence is a distinct capability: any access under
        // /var/persist additionally requires CAP_PERSIST.
        if path_within(Some(PERSIST_ROOT), path.as_str()) && !caps.has(CAP_PERSIST) {
            return Fulfilled::Resume(EPERM);
        }

        match ctx.ns.open_as(ctx.pid, &path, of) {
            Ok(handle) => match self.alloc_fd(GuestFd::File(SharedFile::new(handle))) {
                Some(fd) => match self.write_guest_u32(ret_fd, fd as u32) {
                    Ok(()) => Fulfilled::Resume(ESUCCESS),
                    Err(e) => Fulfilled::Resume(e),
                },
                None => Fulfilled::Resume(EMFILE),
            },
            // A served-fs open is waiting on its server guest: re-issue
            // the same open next tick (the ServedFs dedups by caller, so this
            // does not re-enqueue). Reconstruct the pending request and yield.
            Err(FsError::WouldBlock) => {
                self.store.data_mut().pending = Some(Pending::Open {
                    path_ptr,
                    path_len,
                    flags,
                    ret_fd,
                });
                Fulfilled::Block(BuiltinStep::Pending)
            }
            Err(e) => Fulfilled::Resume(errno_from_fs(e)),
        }
    }

    /// Read a guest path argument, lexically resolve it against the cwd, then
    /// CANONICALIZE it (follow symlinks, collapse `.`/`..`) **before** any policy
    /// check — so confinement applies to the real target and neither a symlink
    /// nor `..` can escape the isolation root. `need_write` selects the required
    /// capability; `follow_final` follows a trailing symlink (set `false` for the
    /// no-follow operations: lstat/readlink/unlink/symlink/link/rename, which act
    /// on the link itself). There is no TOCTOU window: canonicalization and the
    /// operation that consumes the result both run in this one syscall under the
    /// BKL with no yield between.
    fn resolve_guest_path(
        &mut self,
        ctx: &BuiltinCtx<'_>,
        path_ptr: u32,
        path_len: u32,
        need_write: bool,
        follow_final: bool,
    ) -> Result<KPath, i32> {
        let raw = self.read_guest_str(path_ptr, path_len).ok_or(EINVAL)?;
        let lexical = crate::builtins::fs::resolve_path(ctx.cwd, &raw);
        let path = ctx
            .ns
            .canonicalize(&lexical, follow_final)
            .map_err(errno_from_fs)?;
        let (caps, root) = self.policy(ctx);
        // For a write, the required capability is the one the resolved mount
        // declares (CAP_FS_WRITE normally; CAP_SCRATCH for the /scratch tmpfs) —
        // a bit-test selected by the mount, never a path comparison here.
        let needed = if need_write {
            ctx.ns.write_cap_at(&path)
        } else {
            CAP_FS_READ
        };
        if !caps.has(needed) {
            return Err(EPERM);
        }
        if !path_within(root.as_deref(), path.as_str()) {
            return Err(EPERM);
        }
        if path_within(Some(PERSIST_ROOT), path.as_str()) && !caps.has(CAP_PERSIST) {
            return Err(EPERM);
        }
        Ok(path)
    }

    /// FS-read path, following a trailing symlink (`stat`/`readdir`).
    fn resolve_read_path(
        &mut self,
        ctx: &BuiltinCtx<'_>,
        path_ptr: u32,
        path_len: u32,
    ) -> Result<KPath, i32> {
        self.resolve_guest_path(ctx, path_ptr, path_len, false, true)
    }

    /// FS-write path, following a trailing symlink.
    fn resolve_write_path(
        &mut self,
        ctx: &BuiltinCtx<'_>,
        path_ptr: u32,
        path_len: u32,
    ) -> Result<KPath, i32> {
        self.resolve_guest_path(ctx, path_ptr, path_len, true, true)
    }

    /// FS-read path that does NOT follow a trailing symlink (`lstat`/`readlink`).
    fn resolve_read_path_nofollow(
        &mut self,
        ctx: &BuiltinCtx<'_>,
        path_ptr: u32,
        path_len: u32,
    ) -> Result<KPath, i32> {
        self.resolve_guest_path(ctx, path_ptr, path_len, false, false)
    }

    /// FS-write path that does NOT follow a trailing symlink (`unlink`/`symlink`/
    /// `link`/`rename` endpoints all act on the named link, not its target).
    fn resolve_write_path_nofollow(
        &mut self,
        ctx: &BuiltinCtx<'_>,
        path_ptr: u32,
        path_len: u32,
    ) -> Result<KPath, i32> {
        self.resolve_guest_path(ctx, path_ptr, path_len, true, false)
    }

    /// Write the contract-defined stat record into guest memory. Its length, field offsets, and
    /// node-kind values are projected from `contracts/constants.kdl`.
    fn write_stat_buf(&mut self, ret_stat: u32, md: &crate::vfs::Metadata) -> Fulfilled {
        // Stat blob layout (little-endian, 44 bytes). MUST stay in lockstep with
        // the guest sysroot (`parse_stat`, `crates/sysroot`) and the WASI adapter
        // (`parse_mc_stat`, `crates/wasi/adapter`):
        //   size@0 u64 · kind@8 u32 · nlink@12 u32 · mode@16 u32 ·
        //   mtime@20 i64 · atime@28 i64 · ctime@36 i64   (times = ms since epoch)
        let mut buf = [0u8; STAT_BUF_LEN];
        let kind: u32 = match md.node_type {
            NodeType::Dir => STAT_NODE_DIR as u32,
            NodeType::Symlink => STAT_NODE_SYMLINK as u32,
            NodeType::File => STAT_NODE_FILE as u32,
        };
        let size_off = STAT_REC_SIZE_OFF as usize;
        let kind_off = STAT_REC_NODE_TYPE_OFF as usize;
        let nlink_off = STAT_REC_NLINK_OFF as usize;
        let mode_off = STAT_REC_MODE_OFF as usize;
        let mtime_off = STAT_REC_MTIME_OFF as usize;
        let atime_off = STAT_REC_ATIME_OFF as usize;
        let ctime_off = STAT_REC_CTIME_OFF as usize;
        buf[size_off..size_off + 8].copy_from_slice(&md.size.to_le_bytes());
        buf[kind_off..kind_off + 4].copy_from_slice(&kind.to_le_bytes());
        buf[nlink_off..nlink_off + 4].copy_from_slice(&md.nlink.to_le_bytes());
        buf[mode_off..mode_off + 4].copy_from_slice(&(md.mode as u32).to_le_bytes());
        buf[mtime_off..mtime_off + 8].copy_from_slice(&md.mtime.to_le_bytes());
        buf[atime_off..atime_off + 8].copy_from_slice(&md.atime.to_le_bytes());
        buf[ctime_off..ctime_off + 8].copy_from_slice(&md.ctime.to_le_bytes());
        match self.write_guest_bytes(ret_stat, &buf) {
            Ok(()) => Fulfilled::Resume(ESUCCESS),
            Err(e) => Fulfilled::Resume(e),
        }
    }

    fn fulfill_stat(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        path_ptr: u32,
        path_len: u32,
        ret_stat: u32,
    ) -> Fulfilled {
        if !self.guest_range_valid(ret_stat, STAT_BUF_LEN) {
            return self.done(EINVAL);
        }
        let path = match self.resolve_read_path(ctx, path_ptr, path_len) {
            Ok(p) => p,
            Err(e) => return self.done(e),
        };
        // `stat` follows symlinks (the resolver canonicalized with follow=true),
        // so a symlink reports its target's metadata; `lstat` reports the link.
        match ctx.ns.stat_as(ctx.pid, &path) {
            Ok(md) => {
                self.store.data_mut().pending = None;
                self.write_stat_buf(ret_stat, &md)
            }
            Err(FsError::WouldBlock) => Fulfilled::Block(BuiltinStep::Pending),
            Err(e) => self.done(errno_from_fs(e)),
        }
    }

    fn fulfill_readdir(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        path_ptr: u32,
        path_len: u32,
        buf: u32,
        buf_len: u32,
        ret_len: u32,
    ) -> Fulfilled {
        if !self.guest_range_valid(ret_len, 4) {
            return self.done(EINVAL);
        }
        let path = match self.resolve_read_path(ctx, path_ptr, path_len) {
            Ok(p) => p,
            Err(e) => return self.done(e),
        };
        let entries = match ctx.ns.readdir(ctx.pid, &path) {
            Ok(es) => es,
            // A served directory is still fetching its listing: keep `pending`
            // and re-read next tick.
            Err(FsError::WouldBlock) => return Fulfilled::Block(BuiltinStep::Pending),
            Err(e) => return self.done(errno_from_fs(e)),
        };
        // Serialize entry names as NUL-separated bytes (like `args`); a guest
        // splits on NUL and may `stat` each for its type.
        let mut blob = Vec::new();
        for e in &entries {
            blob.extend_from_slice(e.name.as_bytes());
            blob.push(0);
        }
        let total = blob.len();
        let cap = buf_len as usize;
        let n = total.min(cap);
        if !self.guest_range_valid(buf, n) {
            return self.done(EINVAL);
        }
        if let Err(e) = self.write_guest_bytes(buf, &blob[..n]) {
            return self.done(e);
        }
        if let Err(e) = self.write_guest_u32(ret_len, total as u32) {
            return self.done(e);
        }
        self.done(ESUCCESS)
    }

    fn fulfill_mkdir(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        path_ptr: u32,
        path_len: u32,
    ) -> Fulfilled {
        let path = match self.resolve_write_path_nofollow(ctx, path_ptr, path_len) {
            Ok(p) => p,
            Err(e) => return self.done(e),
        };
        let r = ctx.ns.mkdir(ctx.pid, &path);
        self.settle(ESUCCESS, r)
    }

    fn fulfill_unlink(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        path_ptr: u32,
        path_len: u32,
    ) -> Fulfilled {
        let path = match self.resolve_write_path_nofollow(ctx, path_ptr, path_len) {
            Ok(p) => p,
            Err(e) => return self.done(e),
        };
        let r = ctx.ns.unlink(ctx.pid, &path);
        self.settle(ESUCCESS, r)
    }

    fn fulfill_rename(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        from_ptr: u32,
        from_len: u32,
        to_ptr: u32,
        to_len: u32,
    ) -> Fulfilled {
        // Both endpoints require write; confinement applies to each.
        let from = match self.resolve_write_path_nofollow(ctx, from_ptr, from_len) {
            Ok(p) => p,
            Err(e) => return self.done(e),
        };
        let to = match self.resolve_write_path_nofollow(ctx, to_ptr, to_len) {
            Ok(p) => p,
            Err(e) => return self.done(e),
        };
        let r = ctx.ns.rename(ctx.pid, &from, &to);
        self.settle(ESUCCESS, r)
    }

    /// `mc_sys_chmod(path, mode)`: set the permission bits. A write op — gated by
    /// `CAP_FS_WRITE` (via the resolver) and confined like the others.
    fn fulfill_chmod(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        path_ptr: u32,
        path_len: u32,
        mode: u32,
    ) -> Fulfilled {
        let path = match self.resolve_write_path_nofollow(ctx, path_ptr, path_len) {
            Ok(p) => p,
            Err(e) => return self.done(e),
        };
        let r = ctx.ns.set_mode(&path, (mode & 0o7777) as u16);
        self.settle(ESUCCESS, r)
    }

    /// `mc_sys_utimes(path, times_ptr)`: set atime+mtime (ms since the epoch). A
    /// NULL `times_ptr` (0) means "now" from the cached wall clock; otherwise it
    /// points at two little-endian i64s — `atime_ms@0`, `mtime_ms@8`. Write op.
    fn fulfill_utimes(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        path_ptr: u32,
        path_len: u32,
        times_ptr: u32,
    ) -> Fulfilled {
        let path = match self.resolve_write_path_nofollow(ctx, path_ptr, path_len) {
            Ok(p) => p,
            Err(e) => return self.done(e),
        };
        let (atime, mtime) = if times_ptr == 0 {
            let now = crate::wall_now_ms();
            (now, now)
        } else {
            match (
                self.read_guest_i64(times_ptr),
                self.read_guest_i64(times_ptr + 8),
            ) {
                (Ok(a), Ok(m)) => (a, m),
                _ => return self.done(EINVAL),
            }
        };
        let r = ctx.ns.set_times(&path, atime, mtime);
        self.settle(ESUCCESS, r)
    }

    /// `mc_sys_symlink(target, link)`: create a symbolic link at `link` whose
    /// stored target text is `target` (verbatim — never resolved here). The link
    /// path is resolved no-follow (we create the link, not chase an existing one)
    /// and requires write capability.
    fn fulfill_symlink(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        target_ptr: u32,
        target_len: u32,
        link_ptr: u32,
        link_len: u32,
    ) -> Fulfilled {
        let target = match self.read_guest_str(target_ptr, target_len) {
            Some(s) => s,
            None => return self.done(EINVAL),
        };
        let link = match self.resolve_write_path_nofollow(ctx, link_ptr, link_len) {
            Ok(p) => p,
            Err(e) => return self.done(e),
        };
        let r = ctx.ns.symlink(&target, &link);
        self.settle(ESUCCESS, r)
    }

    /// `mc_sys_link(old, new)`: create a hard link `new` to the same node as
    /// `old` (both no-follow — a hard link references the named node, including a
    /// symlink, not its target).
    fn fulfill_link(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        old_ptr: u32,
        old_len: u32,
        new_ptr: u32,
        new_len: u32,
    ) -> Fulfilled {
        let existing = match self.resolve_read_path_nofollow(ctx, old_ptr, old_len) {
            Ok(p) => p,
            Err(e) => return self.done(e),
        };
        let new = match self.resolve_write_path_nofollow(ctx, new_ptr, new_len) {
            Ok(p) => p,
            Err(e) => return self.done(e),
        };
        let r = ctx.ns.link(&existing, &new);
        self.settle(ESUCCESS, r)
    }

    /// `mc_sys_readlink(path, buf, buf_len, ret_len)`: copy a symlink's target
    /// text into the guest buffer (no trailing NUL) and report its full length
    /// (which may exceed `buf_len`). `EINVAL` when `path` is not a symlink.
    fn fulfill_readlink(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        path_ptr: u32,
        path_len: u32,
        buf: u32,
        buf_len: u32,
        ret_len: u32,
    ) -> Fulfilled {
        self.store.data_mut().pending = None;
        if !self.guest_range_valid(ret_len, 4) {
            return Fulfilled::Resume(EINVAL);
        }
        let path = match self.resolve_read_path_nofollow(ctx, path_ptr, path_len) {
            Ok(p) => p,
            Err(e) => return Fulfilled::Resume(e),
        };
        let target = match ctx.ns.readlink(&path) {
            Ok(t) => t,
            Err(e) => return Fulfilled::Resume(errno_from_fs(e)),
        };
        let bytes = target.as_bytes();
        let total = bytes.len();
        let n = total.min(buf_len as usize);
        if n > 0 {
            if let Err(e) = self.write_guest_bytes(buf, &bytes[..n]) {
                return Fulfilled::Resume(e);
            }
        }
        match self.write_guest_u32(ret_len, total as u32) {
            Ok(()) => Fulfilled::Resume(ESUCCESS),
            Err(e) => Fulfilled::Resume(e),
        }
    }

    /// `mc_sys_lstat(path, ret_stat)`: like `stat`, but does NOT follow a
    /// trailing symlink — it reports the link itself (kind 2).
    fn fulfill_lstat(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        path_ptr: u32,
        path_len: u32,
        ret_stat: u32,
    ) -> Fulfilled {
        if !self.guest_range_valid(ret_stat, STAT_BUF_LEN) {
            return self.done(EINVAL);
        }
        let path = match self.resolve_read_path_nofollow(ctx, path_ptr, path_len) {
            Ok(p) => p,
            Err(e) => return self.done(e),
        };
        match ctx.ns.stat_as(ctx.pid, &path) {
            Ok(md) => {
                self.store.data_mut().pending = None;
                self.write_stat_buf(ret_stat, &md)
            }
            Err(FsError::WouldBlock) => Fulfilled::Block(BuiltinStep::Pending),
            Err(e) => self.done(errno_from_fs(e)),
        }
    }

    /// `mc_sys_nice(inc, ret)`: adjust this task's niceness by `inc`, clamped to
    /// the POSIX `-20..=19` range, and report the result. No capability gate —
    /// niceness is purely relative scheduling weight, and a child inherits
    /// the value at spawn.
    fn fulfill_nice(&mut self, ctx: &mut BuiltinCtx<'_>, inc: i32, ret: u32) -> Fulfilled {
        self.store.data_mut().pending = None;
        if !self.guest_range_valid(ret, 4) {
            return Fulfilled::Resume(EINVAL);
        }
        let new = match ctx.sched.get_task_mut(ctx.pid) {
            Some(t) => {
                let n = ((t.nice as i32) + inc).clamp(-20, 19) as i8;
                t.nice = n;
                n
            }
            None => 0,
        };
        // Sign-extend to i32, then reinterpret as the u32 the guest reads back.
        match self.write_guest_u32(ret, new as i32 as u32) {
            Ok(()) => Fulfilled::Resume(ESUCCESS),
            Err(e) => Fulfilled::Resume(e),
        }
    }

    /// `mc_sys_isatty(fd, ret)`: write 1 iff `fd` is connected to the terminal
    /// (a `TerminalSink`), else 0. Only the standard streams can be a tty; fds
    /// 3+ are always files or pipes. Used by `nohup`.
    fn fulfill_isatty(&mut self, ctx: &mut BuiltinCtx<'_>, fd: i32, ret: u32) -> Fulfilled {
        self.store.data_mut().pending = None;
        if !self.guest_range_valid(ret, 4) {
            return Fulfilled::Resume(EINVAL);
        }
        let is_tty = match fd {
            // fd 0: a direct terminal source, OR stdin inherited from the cooked
            // console pipe (pid-1 sh and its children share that one pipe
            // address). The latter is how an interactive REPL — `luau`, `sqlite3`
            // — is told apart from `cat | luau` (an ordinary pipe, different
            // address) without the CLI special-casing anything. See
            // `crate::console_pipe_addr`.
            0 => {
                ctx.stdin.is_terminal()
                    || matches!(
                        (ctx.stdin.block_handle(), crate::console_pipe_addr()),
                        (Some(h), Some(c)) if h == c
                    )
            }
            1 => ctx.stdout.is_terminal(),
            2 => ctx.stderr.is_terminal(),
            _ => false,
        };
        match self.write_guest_u32(ret, is_tty as u32) {
            Ok(()) => Fulfilled::Resume(ESUCCESS),
            Err(e) => Fulfilled::Resume(e),
        }
    }

    /// `mc_sys_getcwd(buf, buf_len, ret_len)`: copy this task's cwd into the
    /// guest buffer and report its length. `ctx.cwd` is a live `&mut` into the
    /// task's own cwd (via `Task::step`), so the guest reads exactly the cwd a
    /// `chdir` would have changed. `EINVAL` if the buffer is too small (the
    /// guest sizes generously; there is no partial-copy contract).
    fn fulfill_getcwd(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        buf: u32,
        buf_len: u32,
        ret_len: u32,
    ) -> Fulfilled {
        self.store.data_mut().pending = None;
        let bytes = ctx.cwd.as_bytes().to_vec();
        if !self.guest_range_valid(ret_len, 4) {
            return Fulfilled::Resume(EINVAL);
        }
        if bytes.len() > buf_len as usize {
            return Fulfilled::Resume(EINVAL);
        }
        if let Err(e) = self.write_guest_bytes(buf, &bytes) {
            return Fulfilled::Resume(e);
        }
        match self.write_guest_u32(ret_len, bytes.len() as u32) {
            Ok(()) => Fulfilled::Resume(ESUCCESS),
            Err(e) => Fulfilled::Resume(e),
        }
    }

    /// `mc_sys_chdir(path)`: change *this* task's cwd. The path must resolve to
    /// a directory; an isolated task may not `chdir` outside its confinement
    /// root (`EPERM`). The shell's own `cd` stays a builtin — it mutates the
    /// shell's cwd, which a child guest's `chdir` can never reach.
    fn fulfill_chdir(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        path_ptr: u32,
        path_len: u32,
    ) -> Fulfilled {
        let raw = match self.read_guest_str(path_ptr, path_len) {
            Some(s) => s,
            None => return self.done(EINVAL),
        };
        let lexical = crate::builtins::fs::resolve_path(ctx.cwd, &raw);
        // `chdir` sees through a symlink to its target directory.
        let path = match ctx.ns.canonicalize(&lexical, true) {
            Ok(p) => p,
            Err(e) => return self.done(errno_from_fs(e)),
        };
        let (caps, root) = self.policy(ctx);
        // `chdir` performs a directory `stat`, so it requires the read
        // capability like any other path probe (it previously checked only
        // confinement, letting a no-read task probe directory existence).
        if !caps.has(CAP_FS_READ) {
            return self.done(EPERM);
        }
        if !path_within(root.as_deref(), path.as_str()) {
            return self.done(EPERM);
        }
        match ctx.ns.stat_as(ctx.pid, &path) {
            Ok(md) if md.node_type == NodeType::Dir => {
                if !md.owner_executable() {
                    return self.done(EACCES);
                }
                *ctx.cwd = String::from(path.as_str());
                self.done(ESUCCESS)
            }
            Ok(_) => self.done(ENOTDIR),
            Err(FsError::WouldBlock) => Fulfilled::Block(BuiltinStep::Pending),
            Err(e) => self.done(errno_from_fs(e)),
        }
    }

    /// `mc_sys_bind(old, new)`: alias the `old` path subtree onto `new` in THIS
    /// task's per-process namespace (Plan 9 `bind`). Affects
    /// only the calling task and its future children (copy-on-write). A confined
    /// (isolated-tier) task may not bind across its confinement root — otherwise
    /// it could alias an outside path into a reachable one and escape.
    fn fulfill_bind(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        old_ptr: u32,
        old_len: u32,
        new_ptr: u32,
        new_len: u32,
    ) -> Fulfilled {
        self.store.data_mut().pending = None;
        let old_raw = match self.read_guest_str(old_ptr, old_len) {
            Some(s) => s,
            None => return Fulfilled::Resume(EINVAL),
        };
        let new_raw = match self.read_guest_str(new_ptr, new_len) {
            Some(s) => s,
            None => return Fulfilled::Resume(EINVAL),
        };
        let old = crate::builtins::fs::resolve_path(ctx.cwd, &old_raw);
        let new = crate::builtins::fs::resolve_path(ctx.cwd, &new_raw);
        let (caps, root) = self.policy(ctx);
        // CAP_MOUNT: reshaping the namespace is an authority distinct from FS
        // read/write; confinement (below) applies on top of it.
        if !caps.has(CAP_MOUNT) {
            return Fulfilled::Resume(EPERM);
        }
        if !path_within(root.as_deref(), old.as_str())
            || !path_within(root.as_deref(), new.as_str())
        {
            return Fulfilled::Resume(EPERM);
        }
        match ctx.ns.bind(old.as_str(), new.as_str()) {
            Ok(()) => Fulfilled::Resume(ESUCCESS),
            Err(e) => Fulfilled::Resume(errno_from_fs(e)),
        }
    }

    /// `mc_sys_unmount(path)`: detach a mount/bind from THIS task's namespace.
    /// Busy (`ENOTEMPTY`) while a child mount exists under
    /// it. Confinement-gated like `bind`.
    fn fulfill_unmount(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        path_ptr: u32,
        path_len: u32,
    ) -> Fulfilled {
        self.store.data_mut().pending = None;
        let raw = match self.read_guest_str(path_ptr, path_len) {
            Some(s) => s,
            None => return Fulfilled::Resume(EINVAL),
        };
        let path = crate::builtins::fs::resolve_path(ctx.cwd, &raw);
        let (caps, root) = self.policy(ctx);
        if !caps.has(CAP_MOUNT) {
            return Fulfilled::Resume(EPERM);
        }
        if !path_within(root.as_deref(), path.as_str()) {
            return Fulfilled::Resume(EPERM);
        }
        match ctx.ns.unmount(path.as_str()) {
            Ok(()) => Fulfilled::Resume(ESUCCESS),
            Err(e) => Fulfilled::Resume(errno_from_fs(e)),
        }
    }

    /// The serve channel behind a server's control fd (`GuestFd::Serve`).
    fn serve_channel(&self, fd: i32) -> Option<Rc<RefCell<ServeChannel>>> {
        if fd < 3 {
            return None;
        }
        match self.files.get((fd - 3) as usize).and_then(|s| s.as_ref()) {
            Some(GuestFd::Serve(owner)) => Some(owner.0.clone()),
            _ => None,
        }
    }

    /// `mc_sys_serve(path) -> fd`: register THIS guest as the file server for the
    /// subtree `path`. Mounts a `ServedFs` at `path` in the
    /// server's OWN per-process namespace, so tasks it later spawns (which fork
    /// that namespace) reach the served tree; the server drives it with a
    /// control fd via `serve_recv`/`serve_respond`. Confinement-gated like
    /// `bind`.
    fn fulfill_serve(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        path_ptr: u32,
        path_len: u32,
        ret_fd: u32,
    ) -> Fulfilled {
        self.store.data_mut().pending = None;
        if !self.guest_range_valid(ret_fd, 4) {
            return Fulfilled::Resume(EINVAL);
        }
        let raw = match self.read_guest_str(path_ptr, path_len) {
            Some(s) if !s.is_empty() => s,
            _ => return Fulfilled::Resume(EINVAL),
        };
        let path = crate::builtins::fs::resolve_path(ctx.cwd, &raw);
        let (caps, root) = self.policy(ctx);
        // CAP_MOUNT: serving a subtree installs a provider into the namespace —
        // the same authority as `bind`.
        if !caps.has(CAP_MOUNT) {
            return Fulfilled::Resume(EPERM);
        }
        if !path_within(root.as_deref(), path.as_str()) {
            return Fulfilled::Resume(EPERM);
        }
        if !self.fd_slots_available(1) {
            return Fulfilled::Resume(EMFILE);
        }
        let channel = ServeChannel::new();
        ctx.ns.mount_labeled(
            path.as_str(),
            Box::new(ServedFs::new(channel.clone())),
            "served",
            false,
        );
        match self.alloc_fd(GuestFd::Serve(ServeOwner(channel))) {
            Some(fd) => match self.write_guest_u32(ret_fd, fd as u32) {
                Ok(()) => Fulfilled::Resume(ESUCCESS),
                Err(e) => Fulfilled::Resume(e),
            },
            None => Fulfilled::Resume(EMFILE),
        }
    }

    /// `mc_sys_serve_recv(fd, buf, buf_len) -> len`: receive the next request for
    /// a served filesystem (blocking). Encodes it as
    /// `[req_id:u32][caller:u32][op:u32][path_len:u32][path…][arg_len:u32][arg…]`
    /// (LE) and returns the byte length; yields (`Pending`) until a request is
    /// available. `op` is one of `abi::SERVE_OP_*`; `arg` is the secondary path
    /// (the `rename` target), empty otherwise. The guest decodes it with
    /// `sysroot::parse_serve_request`.
    fn fulfill_serve_recv(&mut self, fd: i32, buf: u32, buf_len: u32, ret_len: u32) -> Fulfilled {
        if !self.guest_range_valid(ret_len, 4) {
            self.store.data_mut().pending = None;
            return Fulfilled::Resume(EINVAL);
        }
        let channel = match self.serve_channel(fd) {
            Some(c) => c,
            None => {
                self.store.data_mut().pending = None;
                return Fulfilled::Resume(EBADF);
            }
        };
        let req = {
            let ch = channel.borrow();
            ch.peek_request()
                .map(|r| (r.id, r.caller, r.op, r.path.clone(), r.arg.clone()))
        };
        match req {
            // No request yet: keep `pending` set and re-poll next tick.
            None => Fulfilled::Block(BuiltinStep::Pending),
            Some((id, caller, op, path_string, arg_string)) => {
                let path = path_string.as_bytes();
                let arg = arg_string.as_bytes();
                // [id][caller][op][path_len][path][arg_len][arg]
                let total = 20 + path.len() + arg.len();
                if total > buf_len as usize || !self.guest_range_valid(buf, total) {
                    self.store.data_mut().pending = None;
                    return Fulfilled::Resume(EINVAL);
                }
                let taken = channel.borrow_mut().take_request();
                match taken {
                    Some(r) if r.id == id && r.caller == caller => {}
                    _ => return Fulfilled::Block(BuiltinStep::Pending),
                }
                self.store.data_mut().pending = None;
                let mut out = Vec::with_capacity(total);
                out.extend_from_slice(&id.to_le_bytes());
                out.extend_from_slice(&caller.to_le_bytes());
                out.extend_from_slice(&op.to_le_bytes());
                out.extend_from_slice(&(path.len() as u32).to_le_bytes());
                out.extend_from_slice(path);
                out.extend_from_slice(&(arg.len() as u32).to_le_bytes());
                out.extend_from_slice(arg);
                if let Err(e) = self.write_guest_bytes(buf, &out) {
                    return Fulfilled::Resume(e);
                }
                match self.write_guest_u32(ret_len, total as u32) {
                    Ok(()) => Fulfilled::Resume(ESUCCESS),
                    Err(e) => Fulfilled::Resume(e),
                }
            }
        }
    }

    /// `mc_sys_serve_respond(fd, req_id, status, data, data_len)`: answer a
    /// served-fs request — `status` 0 = ok (`data` is the file content),
    /// nonzero = the file does not exist.
    fn fulfill_serve_respond(
        &mut self,
        fd: i32,
        req_id: u32,
        status: i32,
        data_ptr: u32,
        data_len: u32,
    ) -> Fulfilled {
        self.store.data_mut().pending = None;
        let channel = match self.serve_channel(fd) {
            Some(c) => c,
            None => return Fulfilled::Resume(EBADF),
        };
        let data = match self.read_guest_bytes(data_ptr, data_len) {
            Some(d) => d,
            None => return Fulfilled::Resume(EINVAL),
        };
        if channel.borrow_mut().respond(req_id, status, data) {
            Fulfilled::Resume(ESUCCESS)
        } else {
            Fulfilled::Resume(EINVAL)
        }
    }

    /// The service channel behind a server's control fd (`GuestFd::SvcServe`).
    fn svc_channel(&self, fd: i32) -> Option<Rc<RefCell<ServiceChannel>>> {
        if fd < 3 {
            return None;
        }
        match self.files.get((fd - 3) as usize).and_then(|s| s.as_ref()) {
            Some(GuestFd::SvcServe(owner)) => Some(owner.channel().clone()),
            _ => None,
        }
    }

    /// The `(channel, session)` behind a client's connection fd (`GuestFd::SvcConn`).
    fn svc_conn(&self, fd: i32) -> Option<(Rc<RefCell<ServiceChannel>>, u32)> {
        if fd < 3 {
            return None;
        }
        match self.files.get((fd - 3) as usize).and_then(|s| s.as_ref()) {
            Some(GuestFd::SvcConn(h)) => Some((h.channel().clone(), h.session())),
            _ => None,
        }
    }

    /// `mc_sys_svc_serve(name) -> fd`: register THIS guest as the resident service
    /// `name`. Installs a session-keyed `ServiceChannel` in the kernel registry and
    /// returns a control fd the server drives with `svc_recv`/`svc_respond`. One
    /// server per name; authority comes from the kernel's activation grant for the
    /// spawned task, not from a broad capability. The fd's `Drop` closes the channel
    /// and deregisters the name, so a server crash fails its clients rather than
    /// hanging them.
    fn fulfill_svc_serve(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        name_ptr: u32,
        name_len: u32,
        ret_fd: u32,
    ) -> Fulfilled {
        self.store.data_mut().pending = None;
        if !self.guest_range_valid(ret_fd, 4) {
            return Fulfilled::Resume(EINVAL);
        }
        let name = match self.read_guest_str(name_ptr, name_len) {
            Some(s) if valid_service_name(&s) => s,
            _ => return Fulfilled::Resume(EINVAL),
        };
        // Serve-authority is the kernel's activation grant, not a capability: only the
        // task the kernel spawned to serve `name` may register it. This lets a service
        // run at its own narrow tier and stops any other guest squatting a name.
        if grant_holder(&name) != Some(ctx.pid) {
            return Fulfilled::Resume(EPERM);
        }
        if service_registered(&name) {
            // A live server already holds this name.
            return Fulfilled::Resume(EEXIST);
        }
        if !self.fd_slots_available(1) {
            return Fulfilled::Resume(EMFILE);
        }
        let channel = ServiceChannel::new();
        register_service(&name, channel.clone());
        clear_activation(&name); // grant consumed; the channel is now in the registry
                                 // On `alloc_fd` failure the `SvcServeOwner` is dropped here, which closes the
                                 // channel and deregisters `name` — no orphaned registration.
        match self.alloc_fd(GuestFd::SvcServe(SvcServeOwner::new(name, channel))) {
            Some(fd) => match self.write_guest_u32(ret_fd, fd as u32) {
                Ok(()) => Fulfilled::Resume(ESUCCESS),
                Err(e) => Fulfilled::Resume(e),
            },
            None => Fulfilled::Resume(EMFILE),
        }
    }

    /// `mc_sys_svc_recv(fd, buf, buf_len, hbuf, hbuf_len) -> len`: receive the next inbound for a
    /// resident service (blocking). Encodes the envelope
    /// `[kind:u8][nhandles:u8][session:u32][req_id:u32][caller:u32][caller_caps:u32][blob_len:u32][blob…]` (LE) into
    /// `buf` and any delegated fd numbers (cloned into THIS server's fd table) into `hbuf`, returning the
    /// envelope length. `kind` is a call (0) or a session-closed tombstone (1, freeing the service's own
    /// per-session state — codex #1). A call too large for the server's buffers is auto-rejected (the
    /// client's call fails; the server is never stalled or killed — codex #3). Yields (`Pending`) until
    /// an inbound is available.
    fn fulfill_svc_recv(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        fd: i32,
        buf: u32,
        buf_len: u32,
        hbuf: u32,
        hbuf_len: u32,
        ret_len: u32,
    ) -> Fulfilled {
        if !self.guest_range_valid(ret_len, 4) {
            self.store.data_mut().pending = None;
            return Fulfilled::Resume(EINVAL);
        }
        let channel = match self.svc_channel(fd) {
            Some(c) => c,
            None => {
                self.store.data_mut().pending = None;
                return Fulfilled::Resume(EBADF);
            }
        };
        // Self-heal before serving: drop sessions whose client task has died (the connection fd's Drop
        // is the primary teardown; this is defense-in-depth). Each drop also enqueues a SessionClosed
        // tombstone, which we may deliver below so the service can free that session's own warm state.
        channel.borrow_mut().evict_dead_sessions(|pid| {
            pid == crate::vfs::SYSTEM_CALLER
                || ctx
                    .sched
                    .get_task(pid)
                    .is_some_and(|t| !matches!(t.state, TaskState::Zombie))
        });
        // Reap any streaming response a client has stopped draining past its deadline — keeps a stuck
        // client from pinning the kernel buffer / quiescence gate, without the server ever blocking on it.
        channel.borrow_mut().fail_overdue();
        // Deliver the next inbound. A call too large for the server's buffers is AUTO-REJECTED — the
        // client's call fails (status != 0), its delegated handles drop, and we advance — so an
        // oversize request can never stall or kill a service. Loop until deliverable or drained.
        loop {
            let inbound = channel.borrow_mut().take_request();
            let req = match inbound {
                None => {
                    // No new call or tombstone. Offer a paused stream the client has drained below the
                    // high-water (room to produce more) so the server RESUMES it rather than blocking —
                    // this is what lets one slow client never stall the others. Else yield.
                    let ready = channel.borrow_mut().next_drain_ready();
                    if let Some((session, req_id)) = ready {
                        if SVC_ENVELOPE_HEADER <= buf_len as usize
                            && self.guest_range_valid(buf, SVC_ENVELOPE_HEADER)
                        {
                            self.store.data_mut().pending = None;
                            return self.write_svc_envelope(
                                buf,
                                ret_len,
                                hbuf,
                                SVC_KIND_DRAIN_READY,
                                session,
                                req_id,
                                crate::vfs::SYSTEM_CALLER,
                                0,
                                &[],
                                &[],
                            );
                        }
                    }
                    return Fulfilled::Block(BuiltinStep::Pending);
                }
                Some(ServiceInbound::SessionClosed(session)) => {
                    if SVC_ENVELOPE_HEADER > buf_len as usize
                        || !self.guest_range_valid(buf, SVC_ENVELOPE_HEADER)
                    {
                        continue; // can't deliver the tombstone here; drop it (the session is gone)
                    }
                    self.store.data_mut().pending = None;
                    return self.write_svc_envelope(
                        buf,
                        ret_len,
                        hbuf,
                        SVC_KIND_SESSION_CLOSED,
                        session,
                        0,
                        crate::vfs::SYSTEM_CALLER,
                        0,
                        &[],
                        &[],
                    );
                }
                Some(ServiceInbound::Call(r)) => r,
            };
            let nh = req.handles.len();
            let total = SVC_ENVELOPE_HEADER + req.blob.len();
            if total > buf_len as usize
                || nh * 4 > hbuf_len as usize
                || !self.guest_range_valid(buf, total)
                || (nh > 0 && !self.guest_range_valid(hbuf, nh * 4))
                || !self.fd_slots_available(nh)
            {
                // Auto-reject: fail the client crash-only; `req` (and its handles) drop here.
                channel
                    .borrow_mut()
                    .respond(req.session, req.req_id, EMSGSIZE, Vec::new(), true);
                continue;
            }
            // Install the delegated handles into THIS server's fd table (slots reserved above).
            let mut handle_bytes: Vec<u8> = Vec::with_capacity(nh * 4);
            for dh in req.handles {
                match self.install_delegated(dh) {
                    Some(f) => handle_bytes.extend_from_slice(&(f as u32).to_le_bytes()),
                    None => break, // unreachable given the slot check; envelope stays self-consistent
                }
            }
            channel.borrow_mut().mark_delivered(req.session, req.req_id); // now mid-call (snapshot gate)
            self.store.data_mut().pending = None;
            return self.write_svc_envelope(
                buf,
                ret_len,
                hbuf,
                SVC_KIND_CALL,
                req.session,
                req.req_id,
                req.caller,
                req.caller_caps,
                &req.blob,
                &handle_bytes,
            );
        }
    }

    /// `mc_sys_svc_respond(fd, session, req_id, status, data, data_len)`: answer a
    /// service call. `status` 0 = ok (`data` is the response body the client
    /// drains); nonzero = a transport errno surfaced to the client's `read`.
    /// Application results (rows, errors) ride inside `data`.
    fn fulfill_svc_respond(
        &mut self,
        fd: i32,
        session: u32,
        req_id: u32,
        status: i32,
        data_ptr: u32,
        data_len: u32,
        last: u32,
    ) -> Fulfilled {
        let channel = match self.svc_channel(fd) {
            Some(c) => c,
            None => {
                self.store.data_mut().pending = None;
                return Fulfilled::Resume(EBADF);
            }
        };
        let is_last = last != 0;
        // NON-BLOCKING backpressure: if this call's un-drained buffer is at the high-water, the kernel can
        // hold no more right now — return EAGAIN so the server YIELDS this chunk and serves other sessions,
        // resuming on the `DrainReady` that `svc_recv` delivers once the client drains. The single-threaded
        // server thus NEVER blocks on one client, so a slow client cannot stall the others (the old design
        // blocked here for up to a 5 s deadline). A client that stops draining entirely is reaped by
        // `fail_overdue` on that deadline (in `svc_recv`), not by waiting here.
        if channel.borrow().response_buffered(session, req_id) >= SVC_RESPONSE_HIGH_WATER {
            self.store.data_mut().pending = None;
            return Fulfilled::Resume(EAGAIN);
        }
        self.store.data_mut().pending = None;
        let data = match self.read_guest_bytes(data_ptr, data_len) {
            Some(d) => d,
            None => return Fulfilled::Resume(EINVAL),
        };
        // Only a call actually delivered by `svc_recv` may be answered, tying snapshot quiescence to
        // concrete `(session, req_id)` ownership. A PARTIAL chunk only CHECKS the in-flight grant (the
        // call stays mid-response); the FINAL chunk CONSUMES it. Duplicate/unsolicited answers fail.
        let outcome = {
            let mut ch = channel.borrow_mut();
            let ok = if is_last {
                ch.mark_answered(session, req_id)
            } else {
                ch.is_inflight(session, req_id)
            };
            if !ok {
                return Fulfilled::Resume(EINVAL);
            }
            ch.respond(session, req_id, status, data, is_last)
        };
        match outcome {
            // A late chunk to a closed session is accepted and dropped (the client left).
            RespondOutcome::SessionGone => Fulfilled::Resume(ESUCCESS),
            // The client isn't draining — the call failed cleanly. A partial chunk's grant is still
            // in-flight; consume it so the call leaves the quiescence counter.
            RespondOutcome::Overflow => {
                if !is_last {
                    channel.borrow_mut().mark_answered(session, req_id);
                }
                Fulfilled::Resume(EMSGSIZE)
            }
            RespondOutcome::Ok => Fulfilled::Resume(ESUCCESS),
        }
    }

    /// `mc_sys_svc_connect(name) -> fd`: open a session to the resident service
    /// `name`, returning a connection fd the client drives with `svc_call`. Lazy
    /// activation (spawning a registered-but-not-running service) is layered on in a
    /// later step; for now an unregistered name is `ENOENT`.
    fn fulfill_svc_connect(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        name_ptr: u32,
        name_len: u32,
        ret_fd: u32,
    ) -> Fulfilled {
        if !self.guest_range_valid(ret_fd, 4) {
            self.store.data_mut().pending = None;
            return Fulfilled::Resume(EINVAL);
        }
        let name = match self.read_guest_str(name_ptr, name_len) {
            Some(s) if valid_service_name(&s) => s,
            _ => {
                self.store.data_mut().pending = None;
                return Fulfilled::Resume(EINVAL);
            }
        };
        let channel = match lookup_service(&name) {
            Some(c) => c,
            None => {
                // Not registered. Drive the activation supervisor (codex #6): a live starter within its
                // deadline → re-poll (the connect-before-serve race); hung past its deadline → kill it
                // and FAIL with a cooldown (`ETIMEDOUT`); crashed before serving → FAIL with a cooldown
                // (`EIO`). A service already in its backoff window fails fast with the prior error (no
                // respawn); past it, the connect retries with the backoff growing each failure. Absent
                // from the manifest → no such service (`ENOENT`). Bounds the busy-poll / respawn-forever a
                // hung or crash-looping service used to cause (#4), now with backoff (#6).
                match service_state(&name) {
                    Some(ServiceState::Activating {
                        pid, deadline_ms, ..
                    }) => {
                        let alive = ctx
                            .sched
                            .get_task(pid)
                            .is_some_and(|t| !matches!(t.state, TaskState::Zombie));
                        if alive {
                            if crate::wall_now_ms() > deadline_ms {
                                ctx.sched.kill_task(pid, 124); // hung before serving — reap it
                                mark_failed(&name, ETIMEDOUT); // → cooldown; meanwhile connects fail fast
                                self.store.data_mut().pending = None;
                                return Fulfilled::Resume(ETIMEDOUT);
                            }
                            return Fulfilled::Block(BuiltinStep::Pending); // still starting — re-poll
                        }
                        // Crashed before serving — record the failure (→ backoff) and fail this connect.
                        mark_failed(&name, EIO);
                        self.store.data_mut().pending = None;
                        return Fulfilled::Resume(EIO);
                    }
                    Some(ServiceState::Failed {
                        until_ms,
                        last_errno,
                        ..
                    }) => {
                        if crate::wall_now_ms() < until_ms {
                            self.store.data_mut().pending = None;
                            return Fulfilled::Resume(last_errno); // in cooldown — fail fast, no respawn
                        }
                        // Cooldown elapsed — fall through to retry (attempts carry forward → longer backoff).
                    }
                    None => {} // never activated — fall through to first activation
                }
                if unsafe { crate::activate_service_lazily(&name) } {
                    return Fulfilled::Block(BuiltinStep::Pending);
                }
                self.store.data_mut().pending = None;
                return Fulfilled::Resume(ENOENT);
            }
        };
        self.store.data_mut().pending = None;
        if !self.fd_slots_available(1) {
            return Fulfilled::Resume(EMFILE);
        }
        let session = channel.borrow_mut().open_session(ctx.pid);
        // On `alloc_fd` failure the `SvcConnHandle` is dropped here, tearing the
        // just-opened session back down.
        match self.alloc_fd(GuestFd::SvcConn(SvcConnHandle::new(channel, session))) {
            Some(fd) => match self.write_guest_u32(ret_fd, fd as u32) {
                Ok(()) => Fulfilled::Resume(ESUCCESS),
                Err(e) => Fulfilled::Resume(e),
            },
            None => Fulfilled::Resume(EMFILE),
        }
    }

    /// `mc_sys_svc_call(fd, req, req_len, handles, nhandles) -> ret_fd`: send a typed request on a
    /// connection (optionally delegating `nhandles` fds) and get a readable result fd that streams the
    /// server's response. Like `host_call`, the call itself does not block — the client drains the
    /// result fd, yielding while the answer is in flight. Delegated fds are cloned into the service's
    /// table at `svc_recv`; only `File`/`PipeRead`/`PipeWrite` may travel (SYSTEMS.md).
    fn fulfill_svc_call(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        fd: i32,
        req_ptr: u32,
        req_len: u32,
        handles_ptr: u32,
        nhandles: u32,
        ret_fd: u32,
    ) -> Fulfilled {
        self.store.data_mut().pending = None;
        if !self.guest_range_valid(ret_fd, 4) {
            return Fulfilled::Resume(EINVAL);
        }
        let (channel, session) = match self.svc_conn(fd) {
            Some(c) => c,
            None => return Fulfilled::Resume(EBADF),
        };
        if req_len as usize > MAX_SVC_REQUEST_BYTES || nhandles as usize > MAX_DELEGATED_HANDLES {
            return Fulfilled::Resume(EINVAL);
        }
        let blob = match self.read_guest_bytes(req_ptr, req_len) {
            Some(b) => b,
            None => return Fulfilled::Resume(EINVAL),
        };
        // Clone each delegated fd into a transferable handle (refusing non-delegatable fds — egress,
        // serve, svc, std) BEFORE touching the queue, so a bad handle fails the whole call with nothing
        // enqueued and no half-delegation.
        let mut handles: Vec<DelegatedHandle> = Vec::with_capacity(nhandles as usize);
        if nhandles > 0 {
            let hb = match self.read_guest_bytes(handles_ptr, nhandles * 4) {
                Some(b) => b,
                None => return Fulfilled::Resume(EINVAL),
            };
            for i in 0..nhandles as usize {
                let hfd =
                    i32::from_le_bytes([hb[i * 4], hb[i * 4 + 1], hb[i * 4 + 2], hb[i * 4 + 3]]);
                match self.delegate_fd(hfd) {
                    Some(dh) => handles.push(dh),
                    None => return Fulfilled::Resume(EINVAL),
                }
            }
        }
        if !self.fd_slots_available(1) {
            return Fulfilled::Resume(EMFILE);
        }
        let caller_caps = self.policy(ctx).0.bits() as u32;
        let req_id =
            match channel
                .borrow_mut()
                .enqueue(session, ctx.pid, caller_caps, blob, handles)
            {
                Some(id) => id,
                // The server has exited (or the session is gone): fail crash-only; handles drop (released).
                None => return Fulfilled::Resume(EIO),
            };
        let source = SvcCallSource::new(channel, session, req_id);
        match self.alloc_fd(GuestFd::SvcCall(SharedSvcCall::new(source))) {
            Some(fd) => match self.write_guest_u32(ret_fd, fd as u32) {
                Ok(()) => Fulfilled::Resume(ESUCCESS),
                Err(e) => Fulfilled::Resume(e),
            },
            None => Fulfilled::Resume(EMFILE),
        }
    }

    /// Clone a client's fd into a [`DelegatedHandle`] for delegation to a service (`svc_call`). Only
    /// the delegatable subset travels (SYSTEMS.md): an open file (shared `Rc`) or a pipe end (a
    /// fresh ref-counted endpoint on the same pipe — exactly `inherit_for_child`'s clone). `None` for a
    /// std fd or an egress/serve/svc fd, so a caller cannot launder those into a callee.
    fn delegate_fd(&self, fd: i32) -> Option<DelegatedHandle> {
        if fd < 3 {
            return None;
        }
        match self.files.get((fd - 3) as usize).and_then(|s| s.as_ref()) {
            Some(GuestFd::File(sf)) => Some(DelegatedHandle::File(sf.0.clone())),
            Some(GuestFd::PipeRead(ps)) => {
                Some(DelegatedHandle::PipeRead(PipeSource::new(unsafe {
                    &*ps.pipe
                })))
            }
            Some(GuestFd::PipeWrite(pk)) => {
                Some(DelegatedHandle::PipeWrite(PipeSink::new(unsafe {
                    &*pk.pipe
                })))
            }
            _ => None,
        }
    }

    /// Install a delegated handle into THIS (server) guest's fd table, returning its fresh fd number.
    fn install_delegated(&mut self, dh: DelegatedHandle) -> Option<i32> {
        let gfd = match dh {
            DelegatedHandle::File(rc) => GuestFd::File(SharedFile(rc)),
            DelegatedHandle::PipeRead(ps) => GuestFd::PipeRead(ps),
            DelegatedHandle::PipeWrite(pk) => GuestFd::PipeWrite(pk),
        };
        self.alloc_fd(gfd)
    }

    /// Frame a svc inbound envelope into the server's `buf` (header + blob) and its `hbuf` (delegated
    /// fd numbers), writing the envelope length to `ret_len`. The caller has already validated that the
    /// buffers are large enough and in range.
    #[allow(clippy::too_many_arguments)]
    fn write_svc_envelope(
        &mut self,
        buf: u32,
        ret_len: u32,
        hbuf: u32,
        kind: u8,
        session: u32,
        req_id: u32,
        caller: u32,
        caller_caps: u32,
        blob: &[u8],
        handle_bytes: &[u8],
    ) -> Fulfilled {
        let total = SVC_ENVELOPE_HEADER + blob.len();
        let mut out = Vec::with_capacity(total);
        out.push(kind);
        out.push((handle_bytes.len() / 4) as u8);
        out.extend_from_slice(&session.to_le_bytes());
        out.extend_from_slice(&req_id.to_le_bytes());
        out.extend_from_slice(&caller.to_le_bytes());
        out.extend_from_slice(&caller_caps.to_le_bytes());
        out.extend_from_slice(&(blob.len() as u32).to_le_bytes());
        out.extend_from_slice(blob);
        if let Err(e) = self.write_guest_bytes(buf, &out) {
            return Fulfilled::Resume(e);
        }
        if !handle_bytes.is_empty() {
            if let Err(e) = self.write_guest_bytes(hbuf, handle_bytes) {
                return Fulfilled::Resume(e);
            }
        }
        match self.write_guest_u32(ret_len, total as u32) {
            Ok(()) => Fulfilled::Resume(ESUCCESS),
            Err(e) => Fulfilled::Resume(e),
        }
    }

    /// `mc_sys_lseek(fd, off_ptr, whence)`: reposition an open file. `off_ptr`
    /// is an in/out `i64` (LE in guest memory) — the requested offset in, the
    /// resulting absolute position out — which keeps every wire argument an
    /// `i32` while still moving a 64-bit offset. Only regular file fds are
    /// seekable; pipes/net/std fds return `EINVAL` (no ESPIPE in our errno set).
    fn fulfill_lseek(&mut self, fd: i32, off_ptr: u32, whence: i32) -> Fulfilled {
        self.store.data_mut().pending = None;
        let off = match self.read_guest_i64(off_ptr) {
            Ok(o) => o,
            Err(e) => return Fulfilled::Resume(e),
        };
        let pos = match whence {
            SEEK_SET => SeekFrom::Start(off as u64),
            SEEK_CUR => SeekFrom::Current(off),
            SEEK_END => SeekFrom::End(off),
            _ => return Fulfilled::Resume(EINVAL),
        };
        let file = match self.file_at(fd) {
            Some(f) => f,
            None => return Fulfilled::Resume(EINVAL),
        };
        match file.seek(pos) {
            Ok(n) => match self.write_guest_i64(off_ptr, n as i64) {
                Ok(()) => Fulfilled::Resume(ESUCCESS),
                Err(e) => Fulfilled::Resume(e),
            },
            Err(e) => Fulfilled::Resume(errno_from_fs(e)),
        }
    }

    /// `mc_sys_ftruncate(fd, size_lo, size_hi)`: set a file's length. The `u64`
    /// size arrives as two `u32` halves (keeping the all-`i32` wire ABI). The
    /// write-capability gate already ran at `open`; a read-only handle's
    /// `truncate` returns `NotImplemented`/`PermissionDenied` → `ENOSYS`/`EPERM`.
    fn fulfill_ftruncate(&mut self, fd: i32, size_lo: u32, size_hi: u32) -> Fulfilled {
        self.store.data_mut().pending = None;
        let size = ((size_hi as u64) << 32) | (size_lo as u64);
        let file = match self.file_at(fd) {
            Some(f) => f,
            None => return Fulfilled::Resume(EINVAL),
        };
        match file.truncate(size) {
            Ok(()) => Fulfilled::Resume(ESUCCESS),
            Err(e) => Fulfilled::Resume(errno_from_fs(e)),
        }
    }

    /// `mc_sys_sleep_ms(ms)`: cooperatively yield until a monotonic deadline.
    /// The deadline is computed once (from `mc_time_monotonic`) and carried in
    /// `GuestState.timed_deadline` across re-fulfillments; the `Pending` stays
    /// set so the task is re-stepped each tick until the deadline passes. A
    /// non-positive `ms` returns immediately.
    fn fulfill_sleep_ms(&mut self, ctx: &BuiltinCtx<'_>, ms: i32) -> Fulfilled {
        // CAP_AMBIENT: sleeping consumes the host clock and exposes wall-time
        // progress, so it is gated like `time_monotonic` (re-checked each tick
        // this blocks — caps are immutable for the task's life).
        if !self.policy(ctx).0.has(CAP_AMBIENT) {
            self.store.data_mut().pending = None;
            self.store.data_mut().timed_deadline = None;
            return Fulfilled::Resume(EPERM);
        }
        if ms <= 0 {
            self.store.data_mut().pending = None;
            self.store.data_mut().timed_deadline = None;
            return Fulfilled::Resume(ESUCCESS);
        }
        let now = unsafe { crate::bridge::mc_time_monotonic() };
        let deadline = match self.store.data().timed_deadline {
            Some(d) => d,
            None => {
                let d = now.saturating_add(ms as i64);
                self.store.data_mut().timed_deadline = Some(d);
                d
            }
        };
        if now >= deadline {
            self.store.data_mut().pending = None;
            self.store.data_mut().timed_deadline = None;
            Fulfilled::Resume(ESUCCESS)
        } else if self.take_eintr(ctx) {
            // Interrupted by an ignored, pending signal: end the sleep early.
            self.store.data_mut().pending = None;
            self.store.data_mut().timed_deadline = None;
            Fulfilled::Resume(EINTR)
        } else {
            // Keep `pending` set; re-poll next tick (bounded by the deadline).
            Fulfilled::Block(BuiltinStep::Pending)
        }
    }

    /// `mc_sys_poll(fds_ptr, nfds, timeout_ms, ret_ready)`: wait until one or
    /// more of the listed fds is ready (or the timeout elapses). Each `pollfd`
    /// is 8 bytes LE (`fd: i32, events: i16, revents: i16`). Fulfillment is a
    /// cooperative blocking syscall (like `waitpid`): recompute every fd's
    /// `revents` from a *non-destructive* readiness check; if any are set (or a
    /// `0` timeout was given) write the array back and return the ready count;
    /// otherwise yield (`Pending`) and re-check next tick until ready or the
    /// deadline (`timed_deadline`, shared with `sleep_ms`) passes.
    fn fulfill_poll(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        fds_ptr: u32,
        nfds: u32,
        timeout_ms: i32,
        ret_ready: u32,
    ) -> Fulfilled {
        let n = nfds as usize;
        let total = match n.checked_mul(8) {
            Some(v) => v,
            None => {
                self.store.data_mut().pending = None;
                self.store.data_mut().timed_deadline = None;
                return Fulfilled::Resume(EINVAL);
            }
        };
        if !self.guest_range_valid(ret_ready, 4) || !self.guest_range_valid(fds_ptr, total) {
            self.store.data_mut().pending = None;
            self.store.data_mut().timed_deadline = None;
            return Fulfilled::Resume(EINVAL);
        }

        // Snapshot the pollfd array out of guest memory, then fill in revents.
        let mut raw = Vec::new();
        raw.resize(total, 0u8);
        {
            let mem = self.memory.data(&self.store);
            let p = fds_ptr as usize;
            raw.copy_from_slice(&mem[p..p + total]);
        }
        let mut ready: u32 = 0;
        for i in 0..n {
            let b = i * 8;
            let fd = i32::from_le_bytes([raw[b], raw[b + 1], raw[b + 2], raw[b + 3]]);
            let events = i16::from_le_bytes([raw[b + 4], raw[b + 5]]);
            let revents = self.poll_one(ctx, fd, events);
            raw[b + 6..b + 8].copy_from_slice(&revents.to_le_bytes());
            if revents != 0 {
                ready += 1;
            }
        }

        let finish = |me: &mut Self, raw: &[u8], ready: u32| -> Fulfilled {
            me.store.data_mut().pending = None;
            me.store.data_mut().timed_deadline = None;
            if let Err(e) = me.write_guest_bytes(fds_ptr, raw) {
                return Fulfilled::Resume(e);
            }
            match me.write_guest_u32(ret_ready, ready) {
                Ok(()) => Fulfilled::Resume(ESUCCESS),
                Err(e) => Fulfilled::Resume(e),
            }
        };

        // Ready now, or a non-blocking poll (`timeout == 0`): return immediately.
        if ready > 0 || timeout_ms == 0 {
            return finish(self, &raw, ready);
        }
        // Timed wait: arm a deadline on the first pass and return 0 once it
        // passes (revents are all zero in that case — nothing became ready).
        if timeout_ms > 0 {
            let now = unsafe { crate::bridge::mc_time_monotonic() };
            let deadline = match self.store.data().timed_deadline {
                Some(d) => d,
                None => {
                    let d = now.saturating_add(timeout_ms as i64);
                    self.store.data_mut().timed_deadline = Some(d);
                    d
                }
            };
            if now >= deadline {
                return finish(self, &raw, 0);
            }
        }
        // Interrupted by an ignored, pending signal: return EINTR.
        if self.take_eintr(ctx) {
            self.store.data_mut().pending = None;
            self.store.data_mut().timed_deadline = None;
            return Fulfilled::Resume(EINTR);
        }
        // Block: keep `pending` set so we are re-stepped and re-poll next tick.
        Fulfilled::Block(BuiltinStep::Pending)
    }

    /// Compute the `revents` mask for a single `pollfd`. Readiness is
    /// non-destructive — a readable pipe/ws is not drained, so the guest's
    /// subsequent `read` still sees the data. `POLLERR`/`POLLHUP` are reported
    /// whenever they hold, regardless of the requested `events` (POSIX).
    fn poll_one(&self, ctx: &BuiltinCtx<'_>, fd: i32, events: i16) -> i16 {
        let ev = events as i32;
        let want_in = ev & POLLIN != 0;
        let want_out = ev & POLLOUT != 0;
        let mut r: i32 = 0;
        match fd {
            0 => {
                if want_in && ctx.stdin.poll_readable() {
                    r |= POLLIN;
                }
                if ctx.stdin.poll_hup() {
                    r |= POLLHUP;
                }
            }
            1 => {
                if want_out && ctx.stdout.poll_writable() {
                    r |= POLLOUT;
                }
                if ctx.stdout.poll_err() {
                    r |= POLLERR;
                }
            }
            2 => {
                if want_out && ctx.stderr.poll_writable() {
                    r |= POLLOUT;
                }
                if ctx.stderr.poll_err() {
                    r |= POLLERR;
                }
            }
            f if f >= 3 => match self.files.get((f - 3) as usize) {
                // Ordinary files default poll_readable/writable to true, so
                // this is unchanged for them; a connection/server-backed handle
                // (netfs, guest fs) reports real readiness.
                Some(Some(GuestFd::File(h))) => {
                    if want_in && h.poll_readable() {
                        r |= POLLIN;
                    }
                    if want_out && h.poll_writable() {
                        r |= POLLOUT;
                    }
                }
                Some(Some(GuestFd::PipeRead(ps))) => {
                    if want_in && ps.poll_readable() {
                        r |= POLLIN;
                    }
                    if ps.poll_hup() {
                        r |= POLLHUP;
                    }
                }
                Some(Some(GuestFd::PipeWrite(pk))) => {
                    if want_out && pk.poll_writable() {
                        r |= POLLOUT;
                    }
                    if pk.poll_err() {
                        r |= POLLERR;
                    }
                }
                Some(Some(GuestFd::Net(ns))) => {
                    if want_in && ns.poll_readable() {
                        r |= POLLIN;
                    }
                }
                Some(Some(GuestFd::HostCall(hc))) => {
                    if want_in && hc.poll_readable() {
                        r |= POLLIN;
                    }
                }
                Some(Some(GuestFd::SvcCall(sc))) => {
                    if want_in && sc.poll_readable() {
                        r |= POLLIN;
                    }
                }
                Some(Some(GuestFd::Ws(ws))) => {
                    if want_in && ws.poll_readable() {
                        r |= POLLIN;
                    }
                    // Real write-readiness now that the host buffers nothing: the
                    // transport is open + below the mark, OR closed (so a POLLOUT
                    // waiter wakes and its write errors out — POSIX). Reporting
                    // POLLOUT unconditionally would let a guest that polls-then-
                    // writes busy-loop on a full/connecting socket.
                    if want_out && ws.poll_writable() {
                        r |= POLLOUT;
                    }
                    if ws.poll_hup() {
                        r |= POLLHUP;
                    }
                }
                // An unallocated or closed fd is an error condition, not a hang.
                _ => r |= POLLERR,
            },
            // A negative fd is conventionally ignored (revents 0); treat as such.
            _ => {}
        }
        r as i16
    }

    /// Look up a seekable/truncatable regular-file handle by guest fd. Only
    /// `GuestFd::File` qualifies; std fds (0/1/2) and pipe/net fds do not.
    fn file_at(&self, fd: i32) -> Option<SharedFile> {
        if fd < 3 {
            return None;
        }
        let idx = (fd - 3) as usize;
        match self.files.get(idx) {
            Some(Some(GuestFd::File(h))) => Some(h.clone()),
            _ => None,
        }
    }

    fn fulfill_random(&mut self, ctx: &BuiltinCtx<'_>, ptr: u32, len: u32) -> Fulfilled {
        self.store.data_mut().pending = None;
        // CAP_AMBIENT: host entropy is ambient and nondeterministic; a narrowed
        // (sub-`full`) child is denied it.
        if !self.policy(ctx).0.has(CAP_AMBIENT) {
            return Fulfilled::Resume(EPERM);
        }
        let l = len as usize;
        if !self.guest_range_valid(ptr, l) {
            return Fulfilled::Resume(EINVAL);
        }
        let mut tmp = Vec::new();
        tmp.resize(l, 0u8);
        unsafe { crate::bridge::mc_random(tmp.as_mut_ptr(), l) };
        match self.write_guest_bytes(ptr, &tmp) {
            Ok(()) => Fulfilled::Resume(ESUCCESS),
            Err(e) => Fulfilled::Resume(e),
        }
    }

    fn fulfill_args(&mut self, ptr: u32, len: u32, ret_len: u32) -> Fulfilled {
        self.store.data_mut().pending = None;
        // Serialize argv (argv[0] = program name) as NUL-separated bytes.
        let mut blob = Vec::new();
        for a in &self.store.data().argv {
            blob.extend_from_slice(a.as_bytes());
            blob.push(0);
        }
        let total = blob.len();
        let cap = len as usize;
        let n = total.min(cap);
        if !self.guest_range_valid(ret_len, 4) || !self.guest_range_valid(ptr, n) {
            return Fulfilled::Resume(EINVAL);
        }
        if let Err(e) = self.write_guest_bytes(ptr, &blob[..n]) {
            return Fulfilled::Resume(e);
        }
        if let Err(e) = self.write_guest_u32(ret_len, total as u32) {
            return Fulfilled::Resume(e);
        }
        Fulfilled::Resume(ESUCCESS)
    }

    fn fulfill_write(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        fd: i32,
        ptr: u32,
        len: u32,
        ret_n: u32,
    ) -> Fulfilled {
        let (p, l) = (ptr as usize, len as usize);
        if !self.guest_range_valid(ptr, l) || !self.guest_range_valid(ret_n, 4) {
            self.store.data_mut().pending = None;
            return Fulfilled::Resume(EINVAL);
        }
        let bytes = self.memory.data(&self.store)[p..p + l].to_vec();

        // fds 1/2 are stream sinks (terminal or pipe); fds ≥ 3 are open files.
        if fd == 1 || fd == 2 {
            let sink: &mut dyn WriteSink = if fd == 1 { ctx.stdout } else { ctx.stderr };
            return match sink.write(&bytes) {
                // A full pipe accepts nothing: park on it and retry next step.
                Ok(0) if !bytes.is_empty() => Fulfilled::Block(BuiltinStep::BlockedOnStdout),
                Ok(n) => {
                    if let Err(e) = self.write_guest_u32(ret_n, n as u32) {
                        self.store.data_mut().pending = None;
                        return Fulfilled::Resume(e);
                    }
                    self.store.data_mut().pending = None;
                    Fulfilled::Resume(ESUCCESS)
                }
                Err(_) => {
                    self.store.data_mut().pending = None;
                    Fulfilled::Resume(EPIPE)
                }
            };
        }

        if fd >= 3 {
            enum W {
                Wrote(usize),
                Block(usize),
                /// Yield and re-write next tick (connection/server fd).
                Pending,
                Err(i32),
            }
            let w = match self
                .files
                .get_mut((fd - 3) as usize)
                .and_then(|s| s.as_mut())
            {
                Some(GuestFd::File(h)) => match h.write(&bytes) {
                    Ok(n) => W::Wrote(n),
                    Err(FsError::WouldBlock) => W::Pending,
                    Err(e) => W::Err(errno_from_fs(e)),
                },
                Some(GuestFd::PipeWrite(pk)) => match pk.write(&bytes) {
                    Ok(0) if !bytes.is_empty() => W::Block(pk.pipe as usize),
                    Ok(n) => W::Wrote(n),
                    Err(_) => W::Err(EPIPE),
                },
                // A WebSocket write sends one message. On accept the host took
                // the whole buffer; a would-block PARKS the write (re-`send` next
                // tick — the unsent bytes stay in the guest's memory, B5, exactly
                // like a parked net/file read); a close is a broken pipe.
                Some(GuestFd::Ws(ws)) => match ws.send(&bytes) {
                    WsWrite::Sent(n) => W::Wrote(n),
                    WsWrite::Pending => W::Pending,
                    WsWrite::MessageTooBig => W::Err(EMSGSIZE),
                    WsWrite::Closed => W::Err(EPIPE),
                },
                Some(GuestFd::PipeRead(_))
                | Some(GuestFd::Net(_))
                | Some(GuestFd::HostCall(_))
                | Some(GuestFd::Serve(_))
                | Some(GuestFd::SvcServe(_))
                | Some(GuestFd::SvcConn(_))
                | Some(GuestFd::SvcCall(_))
                | None => W::Err(EBADF),
            };
            return match w {
                W::Block(ptr) => Fulfilled::Block(BuiltinStep::BlockedOn(BlockReason::PipeWrite {
                    pipe_ptr: ptr,
                })),
                // Keep `pending` set; re-poll next tick (no pipe to park on).
                W::Pending => Fulfilled::Block(BuiltinStep::Pending),
                W::Wrote(n) => {
                    if let Err(e) = self.write_guest_u32(ret_n, n as u32) {
                        self.store.data_mut().pending = None;
                        return Fulfilled::Resume(e);
                    }
                    self.store.data_mut().pending = None;
                    Fulfilled::Resume(ESUCCESS)
                }
                W::Err(e) => {
                    self.store.data_mut().pending = None;
                    Fulfilled::Resume(e)
                }
            };
        }

        self.store.data_mut().pending = None;
        Fulfilled::Resume(EBADF)
    }

    /// Copy raw bytes out of guest memory.
    fn read_guest_bytes(&self, ptr: u32, len: u32) -> Option<Vec<u8>> {
        let mem = self.memory.data(&self.store);
        let (p, l) = (ptr as usize, len as usize);
        let end = p.checked_add(l).filter(|&e| e <= mem.len())?;
        Some(mem[p..end].to_vec())
    }

    fn fulfill_pipe(&mut self, ctx: &mut BuiltinCtx<'_>, ret_r: u32, ret_w: u32) -> Fulfilled {
        self.store.data_mut().pending = None;
        if !self.guest_range_valid(ret_r, 4) || !self.guest_range_valid(ret_w, 4) {
            return Fulfilled::Resume(EINVAL);
        }
        if !self.fd_slots_available(2) {
            return Fulfilled::Resume(EMFILE);
        }
        let pipe = ctx.sched.alloc_pipe();
        let rfd = match self.alloc_fd(GuestFd::PipeRead(PipeSource::new(pipe))) {
            Some(fd) => fd,
            None => return Fulfilled::Resume(EMFILE),
        };
        let wfd = match self.alloc_fd(GuestFd::PipeWrite(PipeSink::new(pipe))) {
            Some(fd) => fd,
            None => {
                // Roll back the read end so a failed pipe leaks no fd.
                if let Some(slot) = self.files.get_mut((rfd - 3) as usize) {
                    *slot = None;
                }
                return Fulfilled::Resume(EMFILE);
            }
        };
        if let Err(e) = self.write_guest_u32(ret_r, rfd as u32) {
            return Fulfilled::Resume(e);
        }
        if let Err(e) = self.write_guest_u32(ret_w, wfd as u32) {
            return Fulfilled::Resume(e);
        }
        Fulfilled::Resume(ESUCCESS)
    }

    /// Duplicate the kernel object behind a guest fd into a fresh fd slot.
    fn clone_fd(&self, fd: i32) -> Option<GuestFd> {
        if fd < 3 {
            return None;
        }
        match self.files.get((fd - 3) as usize).and_then(|s| s.as_ref()) {
            Some(GuestFd::PipeRead(ps)) => {
                Some(GuestFd::PipeRead(PipeSource::new(unsafe { &*ps.pipe })))
            }
            Some(GuestFd::PipeWrite(pk)) => {
                Some(GuestFd::PipeWrite(PipeSink::new(unsafe { &*pk.pipe })))
            }
            Some(GuestFd::File(h)) => Some(GuestFd::File(h.clone())),
            Some(GuestFd::Net(ns)) => Some(GuestFd::Net(ns.clone())),
            Some(GuestFd::Ws(ws)) => Some(GuestFd::Ws(ws.clone())),
            Some(GuestFd::HostCall(hc)) => Some(GuestFd::HostCall(hc.clone())),
            _ => None,
        }
    }

    fn fulfill_dup(&mut self, fd: i32, ret_fd: u32) -> Fulfilled {
        self.store.data_mut().pending = None;
        if !self.guest_range_valid(ret_fd, 4) {
            return Fulfilled::Resume(EINVAL);
        }
        let dup = match self.clone_fd(fd) {
            Some(d) => d,
            None => return Fulfilled::Resume(EBADF),
        };
        let nfd = match self.alloc_fd(dup) {
            Some(fd) => fd,
            None => return Fulfilled::Resume(EMFILE),
        };
        match self.write_guest_u32(ret_fd, nfd as u32) {
            Ok(()) => Fulfilled::Resume(ESUCCESS),
            Err(e) => Fulfilled::Resume(e),
        }
    }

    /// `dup2(old, new)`: make `new_fd` refer to a duplicate of `old_fd`,
    /// closing whatever `new_fd` referred to first. Both must be ≥ 3 (the
    /// standard streams are wired by the spawner, not redirected mid-run).
    fn fulfill_dup2(&mut self, old_fd: i32, new_fd: i32) -> Fulfilled {
        self.store.data_mut().pending = None;
        if new_fd < 3 {
            return Fulfilled::Resume(EBADF);
        }
        if old_fd == new_fd {
            // Duplicating onto itself is a no-op, provided old_fd is valid.
            return match self
                .files
                .get((old_fd - 3) as usize)
                .and_then(|s| s.as_ref())
            {
                Some(_) => Fulfilled::Resume(ESUCCESS),
                None => Fulfilled::Resume(EBADF),
            };
        }
        let dup = match self.clone_fd(old_fd) {
            Some(d) => d,
            None => return Fulfilled::Resume(EBADF),
        };
        let idx = (new_fd - 3) as usize;
        if idx >= MAX_OPEN_FDS {
            return Fulfilled::Resume(EMFILE);
        }
        if self.files.len() <= idx {
            self.files.resize_with(idx + 1, || None);
        }
        // Close whatever occupied new_fd, then install the duplicate.
        match self.files[idx].take() {
            Some(GuestFd::PipeRead(mut ps)) => ps.close(),
            Some(GuestFd::PipeWrite(mut pk)) => pk.close(),
            _ => {}
        }
        self.files[idx] = Some(dup);
        Fulfilled::Resume(ESUCCESS)
    }

    /// Build the child's stdin from the parent's `fd`: a pipe/file/net fd is
    /// shared; `0` inherits the parent's own stdin when it is inheritable
    /// (pipe or control-channel byte stream), otherwise empty.
    /// Invalid or non-readable fds return EBADF instead of silently changing
    /// the child's stdio wiring.
    fn dup_read_source(&self, ctx: &BuiltinCtx<'_>, fd: i32) -> Result<Box<dyn ReadSource>, i32> {
        if fd >= 3 {
            match self.files.get((fd - 3) as usize).and_then(|s| s.as_ref()) {
                Some(GuestFd::PipeRead(ps)) => {
                    return Ok(Box::new(PipeSource::new(unsafe { &*ps.pipe })));
                }
                Some(GuestFd::File(h)) => return Ok(Box::new(SharedFileSource(h.clone()))),
                Some(GuestFd::Net(ns)) => return Ok(Box::new(SharedNetSource(ns.clone()))),
                _ => {}
            }
            return Err(EBADF);
        } else if fd == 0 {
            if let Some(src) = ctx.stdin.inherit_for_child() {
                return Ok(src);
            }
            return Ok(Box::new(EmptySource));
        }
        Err(EBADF)
    }

    /// Build the child's stdout/stderr from the parent's `fd`: a pipe write
    /// end is shared; `1`/`2` inherit the parent's stream (a pipe or the
    /// terminal). `which` is 1 for stdout, 2 for stderr (the default terminal).
    /// Invalid or non-writable fds return EBADF.
    fn dup_write_sink(
        &self,
        ctx: &BuiltinCtx<'_>,
        fd: i32,
        which: i32,
    ) -> Result<Box<dyn WriteSink>, i32> {
        if fd >= 3 {
            match self.files.get((fd - 3) as usize).and_then(|s| s.as_ref()) {
                Some(GuestFd::PipeWrite(pk)) => {
                    return Ok(Box::new(PipeSink::new(unsafe { &*pk.pipe })));
                }
                Some(GuestFd::File(h)) => return Ok(Box::new(SharedFileSink(h.clone()))),
                _ => {}
            }
            return Err(EBADF);
        } else if fd == 1 || fd == 2 {
            let parent: &dyn WriteSink = if fd == 1 { ctx.stdout } else { ctx.stderr };
            // Inherit the parent's actual stream: a pipe yields a fresh write
            // end, a capture buffer is shared, the terminal falls through.
            if let Some(sink) = parent.inherit_for_child() {
                return Ok(sink);
            }
            return if which == 2 {
                Ok(Box::new(TerminalSink::Stderr))
            } else {
                Ok(Box::new(TerminalSink::Stdout))
            };
        }
        Err(EBADF)
    }

    #[allow(clippy::too_many_arguments)]
    fn fulfill_spawn(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        argv_ptr: u32,
        argv_len: u32,
        in_fd: i32,
        out_fd: i32,
        err_fd: i32,
        tier: i32,
        ret_pid: u32,
    ) -> Fulfilled {
        self.store.data_mut().pending = None;
        if !self.guest_range_valid(ret_pid, 4) {
            return Fulfilled::Resume(EINVAL);
        }

        // Capability check: spawning requires CAP_SPAWN.
        let (parent_caps, parent_root) = self.policy(ctx);
        if !parent_caps.has(CAP_SPAWN) {
            return Fulfilled::Resume(EPERM);
        }

        let blob = match self.read_guest_bytes(argv_ptr, argv_len) {
            Some(b) => b,
            None => return Fulfilled::Resume(EINVAL),
        };
        let argv: Vec<String> = blob
            .split(|&b| b == 0)
            .filter(|s| !s.is_empty())
            .filter_map(|s| core::str::from_utf8(s).ok().map(String::from))
            .collect();
        let prog_name = match argv.first() {
            Some(n) => n.clone(),
            None => return Fulfilled::Resume(EINVAL),
        };
        let args: Vec<String> = argv.iter().skip(1).cloned().collect();

        let cwd = ctx.cwd.clone();
        let live_path = ctx
            .sched
            .get_task(ctx.pid)
            .and_then(|task| task.env().get("PATH").cloned())
            .unwrap_or_else(|| self.path.clone());
        let bytes = match resolve_program_lookup(ctx.ns, &cwd, &prog_name, &live_path) {
            ProgLookup::Found(b) => b,
            ProgLookup::NotFound => return Fulfilled::Resume(ENOENT),
            ProgLookup::Blocked => {
                // The program lives on a served fs (e.g. `/pkg/bin/<tool>` via
                // pkgfsd) whose open is mid-dance. Re-arm this spawn and yield —
                // the next tick re-resolves once the server answers, so `exec`
                // from a served filesystem is transparent. Idempotent:
                // nothing has been spawned yet, and the argv pointer is stable.
                self.store.data_mut().pending = Some(Pending::Spawn {
                    argv_ptr,
                    argv_len,
                    in_fd,
                    out_fd,
                    err_fd,
                    tier,
                    ret_pid,
                });
                return Fulfilled::Block(BuiltinStep::Pending);
            }
        };

        // Exec is the policy point: the child's privilege is the parent's,
        // narrowed by both the binary's declared tier and the tier the parent
        // requested at spawn. Capabilities only ever shrink down the tree.
        let requested = Tier::from_arg(tier);
        let binary = declared_tier(&bytes);
        let (child_caps, child_root) =
            exec_policy(parent_caps, parent_root, binary, requested, &cwd);

        let child_prog = match GuestProgram::load(crate::guest_runtime(), &bytes, argv, &live_path)
        {
            Ok(g) => g,
            Err(_) => return Fulfilled::Resume(EINVAL),
        };

        // Build the child's std streams from the parent's fds before creating
        // the task (so a borrow of `self.files` doesn't overlap the scheduler).
        let stdin = match self.dup_read_source(ctx, in_fd) {
            Ok(s) => s,
            Err(e) => return Fulfilled::Resume(e),
        };
        let stdout = match self.dup_write_sink(ctx, out_fd, 1) {
            Ok(s) => s,
            Err(e) => return Fulfilled::Resume(e),
        };
        let stderr = match self.dup_write_sink(ctx, err_fd, 2) {
            Ok(s) => s,
            Err(e) => return Fulfilled::Resume(e),
        };

        let child_pid = ctx
            .sched
            .spawn(Some(ctx.pid), prog_name.clone(), prog_name, args, cwd);
        ctx.sched.set_task_policy(child_pid, child_caps, child_root);
        if let Some(child) = ctx.sched.get_task(child_pid) {
            child.set_stdin(stdin);
            child.set_stdout(stdout);
            child.set_stderr(stderr);
            child.set_program(Box::new(child_prog));
            // The child inherits a fork of this task's per-process namespace,
            // so the parent's binds carry down but the
            // child's later binds do not leak back up.
            let child_ns = ctx.ns.fork(child_pid);
            // A scratch-capable child gets a fresh, PRIVATE `/scratch` tmpfs
            // gated on CAP_SCRATCH — so a `read-only` tool (which lacks
            // CAP_FS_WRITE) can spill working files there without write-anywhere
            // authority, and without sharing the space with any other task (each
            // mounts its own MemFs, dropped when the task's namespace drops).
            if child_caps.has(CAP_SCRATCH) {
                child_ns.mount_labeled_caps(
                    "/scratch",
                    Box::new(MemFs::new()),
                    "scratchfs",
                    false,
                    CAP_SCRATCH,
                );
            } else {
                // The forked namespace may carry the parent's scratch mount.
                // Children without CAP_SCRATCH must not inherit even a readable
                // view of that private task-local storage.
                let _ = child_ns.unmount("/scratch");
            }
            child.set_namespace(child_ns);
        }

        match self.write_guest_u32(ret_pid, child_pid as u32) {
            Ok(()) => Fulfilled::Resume(ESUCCESS),
            Err(e) => Fulfilled::Resume(e),
        }
    }

    fn fulfill_waitpid(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        pid: i32,
        opts: i32,
        ret_status: u32,
        ret_pid: u32,
    ) -> Fulfilled {
        if !self.guest_range_valid(ret_status, 4) || !self.guest_range_valid(ret_pid, 4) {
            self.store.data_mut().pending = None;
            return Fulfilled::Resume(EINVAL);
        }
        let me = ctx.pid;
        // Find a reaped-able child: a specific pid, or any (pid == -1).
        let is_my_zombie = |id: TaskId| -> bool {
            ctx.sched
                .get_task(id)
                .map(|t| t.parent_id == Some(me) && t.state == TaskState::Zombie)
                .unwrap_or(false)
        };
        let zombie: Option<TaskId> = if pid == -1 {
            ctx.sched
                .task_ids()
                .into_iter()
                .find(|&id| is_my_zombie(id))
        } else if pid > 0 && is_my_zombie(pid as TaskId) {
            Some(pid as TaskId)
        } else {
            None
        };

        if let Some(zpid) = zombie {
            let code = ctx.sched.get_exit_code(zpid).unwrap_or(0);
            ctx.sched.reap_zombie(zpid);
            self.store.data_mut().pending = None;
            if let Err(e) = self.write_guest_u32(ret_status, code as u32) {
                return Fulfilled::Resume(e);
            }
            if let Err(e) = self.write_guest_u32(ret_pid, zpid as u32) {
                return Fulfilled::Resume(e);
            }
            return Fulfilled::Resume(ESUCCESS);
        }

        // A child that just STOPPED (Ctrl-Z / SIGTSTP) is reported once, so the
        // shell can record a stopped job and reclaim the prompt instead of
        // hanging on a suspended foreground command (a small `WIFSTOPPED`).
        // Only a *blocking* wait reports stops; the non-blocking background
        // reaper (`WNOHANG`) wants real exits only, never a stop notification.
        if opts & WNOHANG == 0 {
            let is_my_fresh_stop = |id: TaskId| -> bool {
                ctx.sched
                    .get_task(id)
                    .map(|t| t.parent_id == Some(me) && t.sig_stopped())
                    .unwrap_or(false)
            };
            let stopped: Option<TaskId> = if pid == -1 {
                ctx.sched
                    .task_ids()
                    .into_iter()
                    .find(|&id| is_my_fresh_stop(id))
            } else if pid > 0 && is_my_fresh_stop(pid as TaskId) {
                Some(pid as TaskId)
            } else {
                None
            };
            if let Some(spid) = stopped {
                // Only report the stop edge once (per stop); a still-stopped
                // child already reported falls through to the block below.
                let report = ctx
                    .sched
                    .get_task(spid)
                    .map(|t| t.take_stop_report())
                    .unwrap_or(false);
                if report {
                    self.store.data_mut().pending = None;
                    let status = (STOPPED_STATUS_BASE + SIGTSTP) as u32;
                    if let Err(e) = self.write_guest_u32(ret_status, status) {
                        return Fulfilled::Resume(e);
                    }
                    if let Err(e) = self.write_guest_u32(ret_pid, spid as u32) {
                        return Fulfilled::Resume(e);
                    }
                    return Fulfilled::Resume(ESUCCESS);
                }
            }
        }

        // No reaped-able zombie yet. Is there a living child to wait for?
        let target_alive = if pid > 0 {
            ctx.sched
                .get_task(pid as TaskId)
                .map(|t| t.parent_id == Some(me))
                .unwrap_or(false)
        } else {
            ctx.sched.task_ids().into_iter().any(|id| {
                ctx.sched
                    .get_task(id)
                    .map(|t| t.parent_id == Some(me))
                    .unwrap_or(false)
            })
        };
        if !target_alive {
            self.store.data_mut().pending = None;
            return Fulfilled::Resume(ECHILD);
        }
        // WNOHANG: a living-but-unexited child means "nothing to report yet".
        // Return pid 0 (no wait performed) instead of blocking.
        if opts & WNOHANG != 0 {
            self.store.data_mut().pending = None;
            return match self.write_guest_u32(ret_pid, 0) {
                Ok(()) => Fulfilled::Resume(ESUCCESS),
                Err(e) => Fulfilled::Resume(e),
            };
        }
        // A pending, ignored signal interrupts the wait with EINTR rather than
        // parking (so an ignoring shell can react instead of hanging).
        if self.take_eintr(ctx) {
            self.store.data_mut().pending = None;
            return Fulfilled::Resume(EINTR);
        }
        // Block until it exits. A specific pid uses the WaitChild wake-up that
        // `exit_task` honors; `-1` re-polls (Pending) since the wake-up keys on
        // a specific child.
        if pid > 0 {
            Fulfilled::Block(BuiltinStep::BlockedOn(BlockReason::WaitChild {
                child_id: pid as TaskId,
            }))
        } else {
            Fulfilled::Block(BuiltinStep::Pending)
        }
    }

    /// `mc_sys_kill(pid, sig)`: deliver `sig` to a process (`pid > 0`), to a
    /// process group (`pid < 0` ⇒ group `|pid|`), or to the caller's own group
    /// (`pid == 0`). Requires `CAP_SPAWN` (the authority to manage processes);
    /// you may only signal your own process subtree. `sig == 0` is the
    /// existence probe (no signal sent). Returns `ESRCH` if the target is gone.
    fn fulfill_kill(&mut self, ctx: &mut BuiltinCtx<'_>, pid: i32, sig: i32) -> Fulfilled {
        self.store.data_mut().pending = None;
        if !(0..32).contains(&sig) {
            return Fulfilled::Resume(EINVAL);
        }
        if !self.policy(ctx).0.has(CAP_SPAWN) {
            return Fulfilled::Resume(EPERM);
        }
        let me = ctx.pid;
        // Confinement: a task may only signal itself or a descendant.
        let may_signal = |target: TaskId| target == me || ctx.sched.is_ancestor_of(me, target);

        if pid > 0 {
            let target = pid as TaskId;
            if ctx.sched.get_task(target).is_none() {
                return Fulfilled::Resume(ESRCH);
            }
            if !may_signal(target) {
                return Fulfilled::Resume(EPERM);
            }
            if sig != 0 {
                ctx.sched.deliver_signal(target, sig);
            }
            Fulfilled::Resume(ESUCCESS)
        } else {
            // pid == 0 → caller's group; pid < 0 → group |pid|.
            let pgid = if pid == 0 {
                ctx.sched.get_task(me).map(|t| t.pgid()).unwrap_or(me)
            } else {
                (-pid) as TaskId
            };
            // Gate group sends on owning at least one member of the subtree.
            let members: Vec<TaskId> = ctx
                .sched
                .task_ids()
                .into_iter()
                .filter(|&id| {
                    ctx.sched.get_task(id).map(|t| t.pgid()).unwrap_or(0) == pgid && may_signal(id)
                })
                .collect();
            if members.is_empty() {
                return Fulfilled::Resume(ESRCH);
            }
            if sig != 0 {
                for id in members {
                    ctx.sched.deliver_signal(id, sig);
                }
            }
            Fulfilled::Resume(ESUCCESS)
        }
    }

    /// `mc_sys_sigdisp(sig, disp)`: set this task's disposition for `sig` to
    /// default (`SIG_DFL`) or ignore (`SIG_IGN`). KILL cannot be ignored.
    fn fulfill_sigdisp(&mut self, ctx: &mut BuiltinCtx<'_>, sig: i32, disp: i32) -> Fulfilled {
        self.store.data_mut().pending = None;
        if !(1..32).contains(&sig) || sig == SIGKILL {
            return Fulfilled::Resume(EINVAL);
        }
        if let Some(t) = ctx.sched.get_task(ctx.pid) {
            t.set_signal_ignored(sig, disp == SIG_IGN);
        }
        Fulfilled::Resume(ESUCCESS)
    }

    /// `mc_sys_setpgid(pid, pgid)`: put `pid` (0 ⇒ self) into group `pgid`
    /// (0 ⇒ make it a new group led by `pid`). You may only move your own
    /// process subtree.
    fn fulfill_setpgid(&mut self, ctx: &mut BuiltinCtx<'_>, pid: i32, pgid: i32) -> Fulfilled {
        self.store.data_mut().pending = None;
        let target = if pid == 0 { ctx.pid } else { pid as TaskId };
        if ctx.sched.get_task(target).is_none() {
            return Fulfilled::Resume(ESRCH);
        }
        if target != ctx.pid && !ctx.sched.is_ancestor_of(ctx.pid, target) {
            return Fulfilled::Resume(EPERM);
        }
        ctx.sched.set_pgid(target, pgid.max(0) as TaskId);
        Fulfilled::Resume(ESUCCESS)
    }

    /// `mc_sys_tcsetpgrp(pgid)`: make `pgid` the terminal's foreground group,
    /// so subsequent Ctrl-C / Ctrl-Z reach it. Requires `CAP_SPAWN`.
    fn fulfill_tcsetpgrp(&mut self, ctx: &mut BuiltinCtx<'_>, pgid: i32) -> Fulfilled {
        self.store.data_mut().pending = None;
        if pgid <= 0 {
            return Fulfilled::Resume(EINVAL);
        }
        if !self.policy(ctx).0.has(CAP_SPAWN) {
            return Fulfilled::Resume(EPERM);
        }
        ctx.sched.set_foreground_pgid(pgid as TaskId);
        Fulfilled::Resume(ESUCCESS)
    }

    /// `mc_sys_http_get(url) -> fd`: open an HTTP GET and hand the guest a
    /// readable fd backed by the response body. Two real gates compose here:
    /// the task's **NET capability** (policy — narrowable per process; `EPERM`
    /// if absent) and the host **network capability** (availability — denied
    /// without `--allow-net`, surfaced as `EPERM` via `HttpReq::start`). The
    /// guest never sees the host handle; it streams the body with `mc_sys_read`.
    fn fulfill_http_get(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        url_ptr: u32,
        url_len: u32,
        ret_fd: u32,
    ) -> Fulfilled {
        self.store.data_mut().pending = None;
        if !self.guest_range_valid(ret_fd, 4) {
            return Fulfilled::Resume(EINVAL);
        }
        // Policy gate: does this process hold the NET capability?
        let permitted = ctx
            .sched
            .get_task(ctx.pid)
            .map(|t| t.caps.has(CAP_NET))
            .unwrap_or(false);
        if !permitted {
            return Fulfilled::Resume(EPERM);
        }
        let url = match self.read_guest_str(url_ptr, url_len) {
            Some(s) if !s.is_empty() => s,
            _ => return Fulfilled::Resume(EINVAL),
        };
        // Serialize the minimal request blob the host parses: `GET URL\n\n`.
        let mut blob = Vec::new();
        blob.extend_from_slice(b"GET ");
        blob.extend_from_slice(url.as_bytes());
        blob.extend_from_slice(b"\n\n");
        match HttpReq::start(&blob) {
            Ok(req) => match self.alloc_fd(GuestFd::Net(SharedNet::new(req))) {
                Some(fd) => match self.write_guest_u32(ret_fd, fd as u32) {
                    Ok(()) => Fulfilled::Resume(ESUCCESS),
                    Err(e) => Fulfilled::Resume(e),
                },
                None => Fulfilled::Resume(EMFILE),
            },
            // Availability gate: the host refused (no `--allow-net`).
            Err(crate::net::NetError::Denied) => Fulfilled::Resume(EPERM),
            // Send-only outcomes cannot arise from start; fold them with a
            // transport failure, fail-closed (A5).
            Err(
                crate::net::NetError::Failed
                | crate::net::NetError::WouldBlock
                | crate::net::NetError::MessageTooBig,
            ) => Fulfilled::Resume(EIO),
        }
    }

    /// Whether this task holds the NET capability (the policy gate shared by
    /// every egress syscall; the host availability gate is separate).
    fn net_permitted(&self, ctx: &BuiltinCtx<'_>) -> bool {
        ctx.sched
            .get_task(ctx.pid)
            .map(|t| t.caps.has(CAP_NET))
            .unwrap_or(false)
    }

    /// `mc_sys_http_request(req_ptr, req_len) -> fd`: the general form of
    /// `http_get`. The guest passes a full serialized request blob
    /// (`METHOD URL\n<headers>\n\n<body>`, the format `HttpReq::start` parses)
    /// and receives a **readable** response-body fd. Same two gates as
    /// `http_get` (NET capability + host availability); the guest never sees
    /// the host handle (R1). This is what lets `fetch` be a guest.
    fn fulfill_http_request(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        req_ptr: u32,
        req_len: u32,
        ret_fd: u32,
    ) -> Fulfilled {
        self.store.data_mut().pending = None;
        if !self.guest_range_valid(ret_fd, 4) {
            return Fulfilled::Resume(EINVAL);
        }
        if !self.net_permitted(ctx) {
            return Fulfilled::Resume(EPERM);
        }
        let blob = match self.read_guest_bytes(req_ptr, req_len) {
            Some(b) if !b.is_empty() => b,
            _ => return Fulfilled::Resume(EINVAL),
        };
        match HttpReq::start(&blob) {
            Ok(req) => match self.alloc_fd(GuestFd::Net(SharedNet::new(req))) {
                Some(fd) => match self.write_guest_u32(ret_fd, fd as u32) {
                    Ok(()) => Fulfilled::Resume(ESUCCESS),
                    Err(e) => Fulfilled::Resume(e),
                },
                None => Fulfilled::Resume(EMFILE),
            },
            Err(crate::net::NetError::Denied) => Fulfilled::Resume(EPERM),
            // Send-only outcomes cannot arise from start; fold them with a
            // transport failure, fail-closed (A5).
            Err(
                crate::net::NetError::Failed
                | crate::net::NetError::WouldBlock
                | crate::net::NetError::MessageTooBig,
            ) => Fulfilled::Resume(EIO),
        }
    }

    /// `mc_sys_host_call(req_ptr, req_len) -> fd`: invoke a host-resident
    /// function (the tool broker / a host-backed mount). The guest passes an
    /// opaque request blob and receives a **readable** result fd; it never sees
    /// the host handle (R1). Gated by `CAP_NET` (a host call is host-terminated
    /// egress, the same authority class) plus host availability — default-deny
    /// (R9), so a narrowed/sandboxed child cannot reach host tools.
    fn fulfill_host_call(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        req_ptr: u32,
        req_len: u32,
        ret_fd: u32,
    ) -> Fulfilled {
        self.store.data_mut().pending = None;
        if !self.guest_range_valid(ret_fd, 4) {
            return Fulfilled::Resume(EINVAL);
        }
        if !self.net_permitted(ctx) {
            return Fulfilled::Resume(EPERM);
        }
        let blob = match self.read_guest_bytes(req_ptr, req_len) {
            Some(b) if !b.is_empty() => b,
            _ => return Fulfilled::Resume(EINVAL),
        };
        match HostCallSource::start(&blob) {
            Ok(src) => match self.alloc_fd(GuestFd::HostCall(SharedHostCall::new(src))) {
                Some(fd) => match self.write_guest_u32(ret_fd, fd as u32) {
                    Ok(()) => Fulfilled::Resume(ESUCCESS),
                    Err(e) => Fulfilled::Resume(e),
                },
                None => Fulfilled::Resume(EMFILE),
            },
            Err(crate::host_call::HostCallError::Denied) => Fulfilled::Resume(EPERM),
            Err(crate::host_call::HostCallError::Failed) => Fulfilled::Resume(EIO),
        }
    }

    /// `mc_sys_http_status(fd, ret_status)`: report the HTTP status of a
    /// response-body fd (from `http_get`/`http_request`). Cooperative-blocking
    /// like `read`: it drives the head-poll without consuming the body, yielding
    /// (`Pending`) until the head arrives, then writes the numeric status.
    /// `EBADF` if `fd` is not an HTTP fd, `EIO` on a transport failure. This is
    /// what lets a guest `fetch` set a curl-like exit code (≥400 → failure).
    fn fulfill_http_status(&mut self, fd: i32, ret_status: u32) -> Fulfilled {
        if !self.guest_range_valid(ret_status, 4) {
            self.store.data_mut().pending = None;
            return Fulfilled::Resume(EINVAL);
        }
        let net = if fd >= 3 {
            match self.files.get((fd - 3) as usize).and_then(|s| s.as_ref()) {
                Some(GuestFd::Net(ns)) => ns.clone(),
                _ => {
                    self.store.data_mut().pending = None;
                    return Fulfilled::Resume(EBADF);
                }
            }
        } else {
            self.store.data_mut().pending = None;
            return Fulfilled::Resume(EBADF);
        };
        match net.drive_status() {
            // Head not in yet: keep `pending` set and re-poll next tick.
            StatusPoll::Pending => Fulfilled::Block(BuiltinStep::Pending),
            StatusPoll::Ready(s) => {
                self.store.data_mut().pending = None;
                match self.write_guest_u32(ret_status, s as u32) {
                    Ok(()) => Fulfilled::Resume(ESUCCESS),
                    Err(e) => Fulfilled::Resume(e),
                }
            }
            StatusPoll::Failed => {
                self.store.data_mut().pending = None;
                Fulfilled::Resume(EIO)
            }
        }
    }

    /// `mc_sys_ws_open(url_ptr, url_len) -> fd`: open a WebSocket and hand the
    /// guest a **bidirectional** fd — `mc_sys_read` receives a message,
    /// `mc_sys_write` sends one, `mc_sys_poll` reports readiness. Same gates as
    /// the HTTP syscalls; the host handle stays kernel-side (R1). This is what
    /// lets `wscat` be a guest.
    fn fulfill_ws_open(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        url_ptr: u32,
        url_len: u32,
        ret_fd: u32,
    ) -> Fulfilled {
        self.store.data_mut().pending = None;
        if !self.guest_range_valid(ret_fd, 4) {
            return Fulfilled::Resume(EINVAL);
        }
        if !self.net_permitted(ctx) {
            return Fulfilled::Resume(EPERM);
        }
        let url = match self.read_guest_str(url_ptr, url_len) {
            Some(s) if !s.is_empty() => s,
            _ => return Fulfilled::Resume(EINVAL),
        };
        match WsConn::connect(&url) {
            Ok(conn) => match self.alloc_fd(GuestFd::Ws(SharedWs::new(conn))) {
                Some(fd) => match self.write_guest_u32(ret_fd, fd as u32) {
                    Ok(()) => Fulfilled::Resume(ESUCCESS),
                    Err(e) => Fulfilled::Resume(e),
                },
                None => Fulfilled::Resume(EMFILE),
            },
            Err(crate::net::NetError::Denied) => Fulfilled::Resume(EPERM),
            // Send-only outcomes cannot arise from connect; fold them with a
            // transport failure, fail-closed (A5).
            Err(
                crate::net::NetError::Failed
                | crate::net::NetError::WouldBlock
                | crate::net::NetError::MessageTooBig,
            ) => Fulfilled::Resume(EIO),
        }
    }

    /// A fatal (non-resumable) wasm trap: report and exit like a crash.
    fn crashed(&mut self, ctx: &mut BuiltinCtx<'_>, e: &wasmi::Error) -> BuiltinStep {
        let msg = format!("{}: {}\n", program_name(self), e);
        let _ = ctx.stderr.write(msg.as_bytes());
        BuiltinStep::Exit(134)
    }
}

fn program_name(_g: &GuestProgram) -> &'static str {
    "program"
}

/// True if `path` is at or under `root` (a confinement check). `None` root
/// means "unconfined" → always allowed.
fn path_within(root: Option<&str>, path: &str) -> bool {
    match root {
        None => true,
        Some("/") => path.starts_with('/'),
        Some(root) => {
            path == root
                || path
                    .strip_prefix(root)
                    .is_some_and(|rest| rest.starts_with('/'))
        }
    }
}

/// The capability policy applied at `exec`: a child's privilege is
/// `parent ∩ binary_declared_tier ∩ requested_tier`, and its confinement is
/// the parent's (never escapable), tightened to `cwd` if any tier is
/// `isolated`. Both inputs default to "inherit" (the parent's ceiling) when
/// absent, so an undeclared binary spawned without a tier request runs at the
/// parent's privilege unchanged.
pub fn exec_policy(
    parent_caps: Capabilities,
    parent_root: Option<String>,
    binary: Option<Tier>,
    requested: Option<Tier>,
    cwd: &str,
) -> (Capabilities, Option<String>) {
    let mut caps = parent_caps;
    if let Some(t) = binary {
        caps = caps.intersect(t.caps());
    }
    if let Some(t) = requested {
        caps = caps.intersect(t.caps());
    }
    let confines = binary.is_some_and(Tier::confines) || requested.is_some_and(Tier::confines);
    let root = if confines {
        Some(String::from(cwd))
    } else {
        parent_root
    };
    (caps, root)
}

/// Find the UNIQUE custom section named `name`: `Ok(None)` absent, `Ok(Some(payload))` exactly one,
/// `Err` a DUPLICATE (ambiguous — which is authoritative?) or a malformed section boundary. The
/// single bounds-checked section walk that [`declared_budget`], [`declared_tier`], and the load-time
/// [`validate_mc_sections`] gate all share.
fn unique_custom<'a>(bytes: &'a [u8], name: &[u8]) -> Result<Option<&'a [u8]>, &'static str> {
    if bytes.len() < 8 || &bytes[..4] != b"\0asm" {
        return Ok(None);
    }
    let mut found: Option<&[u8]> = None;
    let mut i = 8usize;
    while i < bytes.len() {
        let id = bytes[i];
        i += 1;
        let (size, adv) = read_uleb(bytes, i).ok_or("truncated section size")?;
        i += adv;
        let body_start = i;
        let body_end = body_start
            .checked_add(size as usize)
            .ok_or("section size overflow")?;
        if body_end > bytes.len() {
            return Err("section past end of module");
        }
        if id == 0 {
            let (name_len, nadv) = read_uleb(bytes, body_start).ok_or("truncated custom name")?;
            let name_start = body_start + nadv;
            let name_end = name_start
                .checked_add(name_len as usize)
                .ok_or("custom name overflow")?;
            if name_end <= body_end && &bytes[name_start..name_end] == name {
                if found.is_some() {
                    return Err("duplicate section");
                }
                found = Some(&bytes[name_end..body_end]);
            }
        }
        i = body_end;
    }
    Ok(found)
}

/// Reject a guest whose `mc_tier`/`mc_budget` is DUPLICATED or PRESENT-BUT-MALFORMED. Absent is fine
/// (the guest inherits the parent tier / gets the default budget). This is the load-time gate
/// ([`GuestProgram::load`]) that turns a corrupt or tampered section into a hard load failure rather
/// than a silent fall-through — which for `mc_tier` would mean inheriting the PARENT's privilege
/// instead of the declared restriction (a sandbox escalation), and for `mc_budget` the default ceiling.
fn validate_mc_sections(bytes: &[u8]) -> Result<(), String> {
    match unique_custom(bytes, b"mc_tier").map_err(|e| format!("mc_tier: {e}"))? {
        Some(p) => {
            let s = core::str::from_utf8(p).map_err(|_| String::from("mc_tier: not UTF-8"))?;
            if Tier::parse(s).is_none() {
                return Err(format!("mc_tier: unknown tier `{s}`"));
            }
        }
        None => {}
    }
    match unique_custom(bytes, b"mc_budget").map_err(|e| format!("mc_budget: {e}"))? {
        Some(p) => {
            if p.len() < 24 {
                return Err(String::from("mc_budget: truncated (< 24 bytes)"));
            }
            if u32::from_le_bytes([p[0], p[1], p[2], p[3]]) != 1 {
                return Err(String::from("mc_budget: unknown version"));
            }
        }
        None => {}
    }
    // mc_service (SYSTEMS.md): a corrupt/empty/ungrammatical service name must fail the load rather
    // than silently read as "not a service" (which would skip the activation-time name check), or be
    // accepted as a name the runtime `svc_serve`/`svc_connect` gate would then reject.
    match unique_custom(bytes, b"mc_service").map_err(|e| format!("mc_service: {e}"))? {
        Some(p) => {
            match core::str::from_utf8(p) {
                Ok(s) if valid_service_name(s) => {}
                _ => {
                    return Err(String::from(
                        "mc_service: not a valid service name ([a-z][a-z0-9-]*, <=31 bytes)",
                    ))
                }
            }
            // A resident service has no parent to inherit a tier from, so a binary that declares a
            // service name MUST also declare its tier — else activation has no capability ceiling to
            // apply. Enforce it at LOAD, uniform with the build (mc-attest) and activation (spawn_service)
            // gates, so the "service ⟹ tier" invariant holds at all three boundaries (codex audit).
            if unique_custom(bytes, b"mc_tier")
                .map_err(|e| format!("mc_tier: {e}"))?
                .is_none()
            {
                return Err(String::from(
                    "mc_service present but mc_tier absent — a resident service must declare its tier",
                ));
            }
        }
        None => {}
    }
    Ok(())
}

/// Read a program's declared resource budget from its (validated) `mc_budget` WASM custom section
/// (emitted by `sysroot::declare_budget!`): little-endian `[u32 version=1][u64 mem][u64 fuel][u32
/// table]`. `None` when absent (→ the default budget). Malformed/duplicate is rejected earlier by
/// [`validate_mc_sections`] at load, so this only sees a well-formed-or-absent section.
pub fn declared_budget(bytes: &[u8]) -> Option<Budget> {
    let p = unique_custom(bytes, b"mc_budget").ok().flatten()?;
    if p.len() < 24 || u32::from_le_bytes([p[0], p[1], p[2], p[3]]) != 1 {
        return None;
    }
    let mem = u64::from_le_bytes(p[4..12].try_into().ok()?);
    let fuel = u64::from_le_bytes(p[12..20].try_into().ok()?);
    let table = u32::from_le_bytes(p[20..24].try_into().ok()?);
    Some(Budget {
        mem_bytes: if mem > usize::MAX as u64 {
            usize::MAX
        } else {
            mem as usize
        },
        fuel,
        table: table as usize,
    })
}

/// Read a program's declared capability tier from its (validated) `mc_tier` WASM custom section
/// (emitted by `sysroot::declare_tier!`). `None` when absent — the program then inherits its parent's
/// privilege unchanged. Malformed/duplicate is rejected earlier by [`validate_mc_sections`] at load,
/// so an absent section here genuinely means "inherit", never "the section was corrupt".
pub fn declared_tier(bytes: &[u8]) -> Option<Tier> {
    let p = unique_custom(bytes, b"mc_tier").ok().flatten()?;
    core::str::from_utf8(p).ok().and_then(Tier::parse)
}

/// Read a program's declared SERVICE name from its (validated) `mc_service` WASM custom section
/// (emitted by `sysroot::declare_service!` or `mc-stamp --service`). `None` when absent — the program
/// is not a resident service. Malformed/duplicate is rejected at load by [`validate_mc_sections`], so
/// an absent section here genuinely means "not a service", never "the section was corrupt".
pub fn declared_service(bytes: &[u8]) -> Option<String> {
    let p = unique_custom(bytes, b"mc_service").ok().flatten()?;
    core::str::from_utf8(p).ok().map(String::from)
}

/// Read an unsigned LEB128 from `bytes` at `at`. Returns `(value, bytes_read)`,
/// or `None` on truncation / overflow (values are bounded to `u32`).
fn read_uleb(bytes: &[u8], at: usize) -> Option<(u32, usize)> {
    let mut result: u32 = 0;
    let mut shift = 0u32;
    let mut n = 0usize;
    loop {
        let byte = *bytes.get(at + n)?;
        n += 1;
        if shift >= 32 {
            return None;
        }
        result |= ((byte & 0x7f) as u32) << shift;
        if byte & 0x80 == 0 {
            return Some((result, n));
        }
        shift += 7;
    }
}

impl GuestProgram {
    /// Read the guest's exported `__stack_pointer`. `0` when not exported — then
    /// the guest isn't using the pcall shim and the value is never consumed.
    fn read_sp(&self) -> i32 {
        match self.sp_global {
            Some(g) => match g.get(&self.store) {
                Val::I32(v) => v,
                _ => 0,
            },
            None => 0,
        }
    }

    /// Restore the guest's `__stack_pointer` after a trap unwound a nested pcall
    /// (wasm globals are store-wide; a trap leaves SP at the child's deep value).
    fn write_sp(&mut self, v: i32) {
        if let Some(g) = self.sp_global {
            let _ = g.set(&mut self.store, Val::I32(v));
        }
    }

    /// Start a nested protected call: park `parent` (the suspended
    /// `mc_sys_pcall` invocation) on the pcall stack and run the guest's
    /// `__mc_pcall_run` dispatcher as a fresh nested invocation on the same store.
    /// Returns its first outcome to drive, or a terminal step.
    fn start_pcall(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        parent: wasmi::TypedResumableCallHostTrap<()>,
    ) -> Result<TypedResumableCall<()>, BuiltinStep> {
        let run = match self.pcall_run {
            Some(f) => f,
            // The guest invoked `mc_sys_pcall` without exporting the dispatcher — a
            // malformed guest. Resume it with EINVAL so it can report, not crash.
            None => {
                return match parent.resume(&mut self.store, &[Val::I32(EINVAL)]) {
                    Ok(o) => Ok(o),
                    Err(e) => Err(self.crashed(ctx, &e)),
                };
            }
        };
        let saved_sp = self.read_sp();
        self.pcall_stack.push(PcallFrame { parent, saved_sp });
        self.grant_fuel(); // nested body runs on the normal cooperative quantum
        match run.call_resumable(&mut self.store, ()) {
            Ok(o) => Ok(o),
            Err(e) => match self.on_trap(ctx, &e) {
                TrapAction::Outcome(o) => Ok(o),
                TrapAction::Step(s) => Err(s),
            },
        }
    }

    /// A nested invocation returned normally. If it was a pcall child, pop its
    /// boundary, restore the parent's shadow stack, and resume the parent with
    /// `code` (0 = the protected thunk did not throw). `None` at the outermost
    /// level (empty stack) — the whole guest has finished.
    fn finish_invocation(
        &mut self,
        ctx: &mut BuiltinCtx<'_>,
        code: i32,
    ) -> Option<Result<TypedResumableCall<()>, BuiltinStep>> {
        let frame = self.pcall_stack.pop()?;
        self.write_sp(frame.saved_sp);
        self.grant_fuel();
        Some(
            match frame.parent.resume(&mut self.store, &[Val::I32(code)]) {
                Ok(o) => Ok(o),
                Err(e) => match self.on_trap(ctx, &e) {
                    TrapAction::Outcome(o) => Ok(o),
                    TrapAction::Step(s) => Err(s),
                },
            },
        )
    }

    /// A guest call returned `Err` (a wasm trap). If the guest recorded a throw
    /// code (`mc_sys_set_throw`) AND a protected boundary is active, this is an
    /// intentional Lua/parser "throw": unwind to the innermost `mc_sys_pcall`,
    /// restore its shadow stack, and resume it with the code. A trap with no
    /// recorded code (a genuine fault) or with no active boundary crashes the
    /// guest — a real trap is never masked as a catchable error.
    fn on_trap(&mut self, ctx: &mut BuiltinCtx<'_>, e: &wasmi::Error) -> TrapAction {
        loop {
            let code = match self.store.data_mut().throw_code.take() {
                Some(c) => c,
                None => return TrapAction::Step(self.crashed(ctx, e)),
            };
            let frame = match self.pcall_stack.pop() {
                Some(f) => f,
                None => return TrapAction::Step(self.crashed(ctx, e)),
            };
            self.write_sp(frame.saved_sp);
            self.grant_fuel();
            match frame.parent.resume(&mut self.store, &[Val::I32(code)]) {
                Ok(o) => return TrapAction::Outcome(o),
                // The resumed parent immediately threw again — keep unwinding (the
                // next iteration consumes the new code it recorded before trapping).
                Err(_) => continue,
            }
        }
    }

    /// Set the store's fuel for the next slice of guest execution: one cooperative
    /// `FUEL_QUANTUM`, the same at every nesting depth (top-level and inside an
    /// `mc_sys_pcall` body). The lifetime budget is enforced by the OutOfFuel
    /// handler, which records progress per slice.
    fn grant_fuel(&mut self) {
        // Uniform: every invocation gets exactly the cooperative quantum, whether
        // it is top-level or nested inside an `mc_sys_pcall` body. Eager compilation
        // keeps function translation out of the fuel-metered path, so OutOfFuel→
        // resume is sound at every nesting depth (SYSTEMS.md §4.3). The lifetime budget
        // is enforced where progress is recorded (the OutOfFuel handler), not here.
        let _ = self.store.set_fuel(FUEL_QUANTUM);
    }
}

impl Builtin for GuestProgram {
    fn step(&mut self, ctx: &mut BuiltinCtx<'_>) -> BuiltinStep {
        // Produce the first outcome to process this step, based on how the
        // previous step left us. A trap is routed through `on_trap`, which unwinds
        // an active protected boundary (if any) or crashes the guest.
        let mut outcome: TypedResumableCall<()> = match self.resume.take() {
            Some(Resume::Start) => {
                self.grant_fuel();
                match self.entry.call_resumable(&mut self.store, ()) {
                    Ok(o) => o,
                    Err(e) => match self.on_trap(ctx, &e) {
                        TrapAction::Outcome(o) => o,
                        TrapAction::Step(s) => return s,
                    },
                }
            }
            Some(Resume::HostTrap(inv)) => {
                // Re-fulfill the (normal) syscall that blocked us last step; a
                // blocked `mc_sys_pcall` can't occur (it never returns `Block`).
                match self.fulfill(ctx) {
                    Fulfilled::Resume(r) => match inv.resume(&mut self.store, &[Val::I32(r)]) {
                        Ok(o) => o,
                        Err(e) => match self.on_trap(ctx, &e) {
                            TrapAction::Outcome(o) => o,
                            TrapAction::Step(s) => return s,
                        },
                    },
                    Fulfilled::Block(s) => {
                        self.resume = Some(Resume::HostTrap(inv));
                        return s;
                    }
                    Fulfilled::Exit(c) => return BuiltinStep::Exit(c),
                }
            }
            Some(Resume::OutOfFuel(inv)) => {
                self.grant_fuel();
                match inv.resume(&mut self.store) {
                    Ok(o) => o,
                    Err(e) => match self.on_trap(ctx, &e) {
                        TrapAction::Outcome(o) => o,
                        TrapAction::Step(s) => return s,
                    },
                }
            }
            None => return BuiltinStep::Exit(self.store.data().exit_code.unwrap_or(0)),
        };

        loop {
            match outcome {
                TypedResumableCall::Finished(()) => {
                    // A nested pcall child returned normally → resume its parent
                    // with code 0. At the outermost level the guest is done.
                    match self.finish_invocation(ctx, 0) {
                        Some(Ok(o)) => {
                            outcome = o;
                            continue;
                        }
                        Some(Err(s)) => return s,
                        None => {
                            return BuiltinStep::Exit(self.store.data().exit_code.unwrap_or(0));
                        }
                    }
                }
                TypedResumableCall::OutOfFuel(inv) => {
                    // Uniform for top-level AND nested (pcall) invocations: charge the
                    // quantum against the lifetime budget, then either kill a genuine
                    // runaway or park for cooperative resume next tick. Eager
                    // compilation makes the resume sound at every depth (SYSTEMS.md §4.3),
                    // so a nested body preempts at the normal quantum like any guest —
                    // no special slab, no kill-not-resume.
                    self.fuel_used = self.fuel_used.saturating_add(FUEL_QUANTUM);
                    if self.fuel_used > self.fuel_budget {
                        let _ = ctx.stderr.write(b"program killed: cpu budget exceeded\n");
                        return BuiltinStep::Exit(137);
                    }
                    self.resume = Some(Resume::OutOfFuel(inv));
                    return BuiltinStep::Pending;
                }
                TypedResumableCall::HostTrap(inv) => {
                    // `mc_sys_pcall` is intercepted to start a nested protected
                    // call rather than be fulfilled to a value.
                    if matches!(self.store.data().pending, Some(Pending::Pcall {})) {
                        self.store.data_mut().pending = None;
                        match self.start_pcall(ctx, inv) {
                            Ok(o) => {
                                outcome = o;
                                continue;
                            }
                            Err(s) => return s,
                        }
                    }
                    match self.fulfill(ctx) {
                        Fulfilled::Resume(r) => match inv.resume(&mut self.store, &[Val::I32(r)]) {
                            Ok(o) => {
                                outcome = o;
                                continue;
                            }
                            Err(e) => match self.on_trap(ctx, &e) {
                                TrapAction::Outcome(o) => {
                                    outcome = o;
                                    continue;
                                }
                                TrapAction::Step(s) => return s,
                            },
                        },
                        Fulfilled::Block(s) => {
                            self.resume = Some(Resume::HostTrap(inv));
                            return s;
                        }
                        Fulfilled::Exit(c) => return BuiltinStep::Exit(c),
                    }
                }
            }
        }
    }
}

/// Register the `mc_sys_*` host functions on a guest's linker. **Generated**
/// from the canonical `abi` syscall table: each row becomes a thin host fn
/// that records its arguments in `pending` (a bit-preserving `as` cast to the
/// variant's storage type) and suspends the guest with a host error, which
/// `step()` fulfills against the kernel. Name, arity, and types come from the
/// one table, so the kernel side and the guest `extern` block cannot disagree.
macro_rules! mc_register_syscalls {
    ( $( $ident:ident => $Variant:ident ( $($arg:ident : $ty:tt),* ) [$ret:tt]; )* ) => {
        fn register_syscalls(linker: &mut Linker<GuestState>) -> Result<(), wasmi::Error> {
            $(
                linker.func_wrap(
                    "mc",
                    stringify!($ident),
                    |mut caller: Caller<'_, GuestState>, $($arg: i32),*| -> Result<i32, wasmi::Error> {
                        caller.data_mut().pending = Some(Pending::$Variant { $($arg: $arg as $ty),* });
                        Err(suspend())
                    },
                )?;
            )*
            Ok(())
        }
    };
}
crate::wasm::abi::mc_syscall_table!(mc_register_syscalls);

/// Resolve a command name to program bytes from the VFS. Absolute/relative
/// paths (containing `/`) are read directly; bare names are searched in each
/// `:`-separated directory of `path` (the shell's `$PATH`).
/// Outcome of locating an executable on `$PATH` (or by path). `Blocked` means a
/// candidate lives on a SERVED filesystem whose `open` is mid-dance (`WouldBlock`)
/// — a resumable `spawn` should yield and re-resolve once the server answers.
/// That cooperative retry is what makes `exec` from `pkgfsd` transparent:
/// the loader reads a tool's bytes through the VFS without learning they're remote.
pub enum ProgLookup {
    Found(Vec<u8>),
    NotFound,
    Blocked,
}

/// Locate + read an executable, surfacing a served-fs `WouldBlock` as `Blocked`
/// (so the spawn path can yield and retry) rather than swallowing it as not-found.
pub fn resolve_program_lookup(ns: &Namespace, cwd: &str, cmd: &str, path: &str) -> ProgLookup {
    let mut candidates: Vec<String> = Vec::new();
    if cmd.contains('/') {
        candidates.push(String::from(
            crate::builtins::fs::resolve_path(cwd, cmd).as_str(),
        ));
    } else {
        for dir in path.split(':') {
            if dir.is_empty() {
                continue;
            }
            candidates.push(format!("{dir}/{cmd}"));
        }
    }
    for path in candidates {
        // Follow symlinks before opening: `ns.open`/`resolve` is purely lexical
        // and a filesystem won't open a symlink node directly, so a busybox-style
        // multicall link (`/bin/base64` -> `mcbox-ro`) would otherwise fail to
        // load. Canonicalizing here mirrors the guest open syscall, which also
        // canonicalizes first. A non-existent candidate canonicalizes to an error
        // — skip to the next PATH entry.
        let real = match ns.canonicalize(&KPath::new(&path), true) {
            Ok(p) => p,
            Err(FsError::WouldBlock) => return ProgLookup::Blocked,
            Err(_) => continue,
        };
        // Require execute permission (owner-`x`): a readable-but-not-executable
        // file is not a runnable program. Skip it so a bare-name `$PATH` search
        // moves on to the next directory (and `chmod -x prog; prog` fails). If
        // terminal metadata for a served path is still pending, yield and retry.
        match ns.stat(&real) {
            Ok(meta) if !meta.owner_executable() => continue,
            Err(FsError::WouldBlock) => return ProgLookup::Blocked,
            Err(_) => continue,
            Ok(_) => {}
        }
        match ns.open(&real, OpenFlags::READ) {
            Ok(mut f) => {
                let mut bytes = Vec::new();
                let mut buf = [0u8; 4096];
                loop {
                    match f.read(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => bytes.extend_from_slice(&buf[..n]),
                        Err(FsError::WouldBlock) => return ProgLookup::Blocked,
                        Err(_) => return ProgLookup::NotFound,
                    }
                }
                if !bytes.is_empty() {
                    return ProgLookup::Found(bytes);
                }
            }
            // First touch of a served file yields here; the caller re-resolves.
            Err(FsError::WouldBlock) => return ProgLookup::Blocked,
            Err(_) => continue,
        }
    }
    ProgLookup::NotFound
}

/// Locate + read an executable, or `None` if absent. Synchronous callers (boot,
/// the control shell, the in-kernel pipeline) where the program is a baked `/bin`
/// file never see a served `WouldBlock`; the resumable guest `spawn` uses
/// [`resolve_program_lookup`] directly to honor it.
pub fn resolve_program(ns: &Namespace, cwd: &str, cmd: &str, path: &str) -> Option<Vec<u8>> {
    match resolve_program_lookup(ns, cwd, cmd, path) {
        ProgLookup::Found(bytes) => Some(bytes),
        ProgLookup::NotFound | ProgLookup::Blocked => None,
    }
}
