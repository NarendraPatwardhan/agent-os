//! Resident services — a guest CALLS another guest for typed values, warm between
//! calls. The cross-guest analog of `host_call` (a typed request blob → a readable,
//! streamed result), but routed to a *guest* server instead of the host, keyed by
//! SESSION instead of caller, and captured by snapshot because all state lives in
//! kernel linear memory.
//!
//! The cooperative dance mirrors `servedfs` with one structural change SERVICES.md
//! calls out. A client `svc_connect`s a NAME (opening a session), then `svc_call`s a
//! typed blob: the kernel enqueues the request and hands back a readable result fd,
//! which the client drains with ordinary `read`s (yielding while the answer is in
//! flight — the same `Block(Pending)` re-poll as `host_call`). The server guest
//! `svc_serve`s the name once, then loops `svc_recv` → handle on warm state →
//! `svc_respond`. Routing is by `(session, req_id)`, not by caller: one client may
//! hold several concurrent sessions to the same service (a script with two DB
//! handles), which a caller-keyed map could not express. A server exit `close()`s
//! the channel, so every pending and future client fails (`EIO`) rather than
//! blocking forever — the crash-only contract.

use alloc::boxed::Box;
use alloc::collections::{BTreeMap, BTreeSet, VecDeque};
use alloc::rc::Rc;
use alloc::string::String;
use alloc::vec::Vec;
use core::cell::RefCell;

use constants_rust::{EIO, EMSGSIZE, ETIMEDOUT};

use crate::io::{PipeSink, PipeSource};
use crate::task::TaskId;
use crate::vfs::traits::{
    CallerId, DirEntry, FileHandle, FileSystem, FsError, KPath, Metadata, NodeType, OpenFlags,
    Result, SeekFrom,
};

/// A handle delegated alongside a service call (SERVICES.md §3.4 — SCM_RIGHTS-style). Only the
/// delegatable subset travels: an open file, or a pipe read/write end. The kernel clones the backing
/// object at `svc_call` and installs it into the SERVER's fd table at `svc_recv`; egress/serve/svc fds
/// are refused at the call boundary so a caller cannot launder them into a service. Held as fs-layer
/// types (a `FileHandle` `Rc` + the pipe endpoints) so the channel stays free of wasm-layer `GuestFd` —
/// the `fulfill_svc_*` arms convert `GuestFd` ↔ `DelegatedHandle`.
pub enum DelegatedHandle {
    File(Rc<RefCell<Box<dyn FileHandle>>>),
    PipeRead(PipeSource),
    PipeWrite(PipeSink),
}

/// One typed call routed to the server guest. `session` identifies the client
/// connection; `req_id` is unique within the channel; `blob` is the opaque request
/// bytes (the service + its library define the wire format — the kernel never reads
/// it); `handles` are any fds the caller delegated with this request.
pub struct ServiceRequest {
    pub session: u32,
    pub req_id: u32,
    pub blob: Vec<u8>,
    pub handles: Vec<DelegatedHandle>,
}

/// What a server pulls from its channel with `svc_recv`: a [`ServiceRequest`] to answer, or a
/// notification that a SESSION CLOSED (its client's connection went away) so the service can free that
/// session's own warm state — the kernel can only evict its OWN per-session bookkeeping, never the
/// service guest's heap (codex #1; SERVICES.md is silent on this signal, so we add it). A tombstone is
/// a one-way notification: no answer, no `req_id`.
pub enum ServiceInbound {
    Call(ServiceRequest),
    SessionClosed(u32),
}

/// The un-drained response-buffer cap: past this, a client that isn't draining fails the call cleanly
/// (`EMSGSIZE`) instead of letting the kernel buffer grow without bound (codex #3).
pub const MAX_SVC_RESPONSE_BYTES: usize = 1 << 20; // 1 MiB
/// When the un-drained buffer reaches this, `svc_respond` yields so the client drains before the server
/// sends more — keeping the kernel buffer near one high-water of bytes, not the whole result.
pub const SVC_RESPONSE_HIGH_WATER: usize = 64 * 1024;
/// How long the server waits on a blocked (full) buffer before failing the call — separates a
/// slow-but-live client (keeps draining, refreshing the deadline) from a stuck one.
pub const SVC_DRAIN_TIMEOUT_MS: i64 = 5_000;

/// The server guest's answer for one call — a STREAMING buffer (codex #3). The server appends body
/// chunks via `svc_respond` (`last=0` until the final `last=1`); the client drains `buf` from the front
/// through its result fd, so a large result never materializes whole. `status` is a kernel-level
/// transport signal (`0` = body follows; non-zero = an errno surfaced to the client's `read`).
/// `drain_deadline` is refreshed each time the client drains, so a server blocked on a full buffer can
/// tell a slow-but-live client from a stuck one. Application results (rows, errors) ride inside the body.
struct ServiceResponse {
    status: i32,
    buf: VecDeque<u8>,
    complete: bool,
    drain_deadline: i64,
}

/// Per-session bookkeeping: the client task that opened it. The connection fd's `Drop` (on the
/// universal `clear_program` at task exit) is the PRIMARY teardown; `caller` additionally lets the
/// server SELF-HEAL via [`ServiceChannel::evict_dead_sessions`], so a long-lived service never
/// accumulates orphans even if some exit path were to bypass the fd Drop.
struct Session {
    caller: CallerId,
}

/// Outcome of a client draining its streaming response.
pub enum ResponsePoll {
    /// No bytes buffered yet and the answer isn't complete — yield and retry.
    Pending,
    /// The server guest has exited — fail the call.
    Closed,
    /// Drained `n` bytes into the caller's buffer.
    Got(usize),
    /// The answer is complete and fully drained.
    Eof,
    /// A terminal transport error (`status != 0`).
    Failed(i32),
}

/// Outcome of a server appending a response chunk (`svc_respond`).
pub enum RespondOutcome {
    /// The chunk was buffered.
    Ok,
    /// The client's session has closed — the answer is dropped.
    SessionGone,
    /// The un-drained buffer passed the cap (the client isn't draining) — the call fails cleanly.
    Overflow,
}

/// The rendezvous between clients (`svc_connect`/`svc_call`) and one server guest
/// (`svc_serve`/`svc_recv`/`svc_respond`). Shared, interior-mutable, single-threaded.
/// Lives in kernel linear memory, so a snapshot captures the warm service whole.
pub struct ServiceChannel {
    next_session: u32,
    next_req: u32,
    /// Inbounds (calls + session-closed tombstones) waiting for the server to `svc_recv`, in order.
    requests: VecDeque<ServiceInbound>,
    /// Answered calls waiting for the client to drain, keyed by `(session, req_id)`.
    responses: BTreeMap<(u32, u32), ServiceResponse>,
    /// Open client sessions.
    sessions: BTreeMap<u32, Session>,
    /// Set once the server guest exits; pending/new calls then fail (`EIO`).
    closed: bool,
    /// Calls delivered to the server but not yet answered — the service is mid-call (a live wasm
    /// stack). A snapshot must not be taken while this is non-empty (SERVICES.md §3.5; codex #5).
    /// Track request identity, not just a count, so a buggy service cannot make the channel look
    /// quiescent by responding to an unsolicited or duplicate `(session, req_id)`.
    inflight: BTreeSet<(u32, u32)>,
    /// Round-robin cursor for `next_drain_ready`: the last stream we offered the server to resume, so a
    /// single big streaming response can't monopolize the serve loop and starve the others.
    last_drain: Option<(u32, u32)>,
}

impl ServiceChannel {
    pub fn new() -> Rc<RefCell<ServiceChannel>> {
        Rc::new(RefCell::new(ServiceChannel {
            next_session: 1,
            next_req: 1,
            requests: VecDeque::new(),
            responses: BTreeMap::new(),
            sessions: BTreeMap::new(),
            closed: false,
            inflight: BTreeSet::new(),
            last_drain: None,
        }))
    }

    /// Server received a call (`svc_recv` delivered it): the service is now mid-call.
    pub fn mark_delivered(&mut self, session: u32, req_id: u32) {
        self.inflight.insert((session, req_id));
    }

    /// Server answered a delivered call (`svc_respond`): one fewer in-flight. Returns `false` for an
    /// unsolicited or duplicate answer, which must not decrement snapshot quiescence.
    pub fn mark_answered(&mut self, session: u32, req_id: u32) -> bool {
        self.inflight.remove(&(session, req_id))
    }

    /// Whether `(session, req_id)` is a delivered, not-yet-finally-answered call — the check a PARTIAL
    /// `svc_respond` chunk makes (it must not consume the in-flight grant; only the final chunk does).
    pub fn is_inflight(&self, session: u32, req_id: u32) -> bool {
        self.inflight.contains(&(session, req_id))
    }

    // ── client side ──────────────────────────────────────────────────────────

    /// Open a session for `caller`; returns its id.
    pub fn open_session(&mut self, caller: CallerId) -> u32 {
        let id = self.next_session;
        self.next_session = self.next_session.wrapping_add(1).max(1);
        self.sessions.insert(id, Session { caller });
        id
    }

    /// Tear down a session (the client closed its connection fd, or its task died): forget it and any
    /// buffered responses + un-served calls, then enqueue a [`ServiceInbound::SessionClosed`] tombstone
    /// so the server can free the session's own warm state. Idempotent — the `remove` guard means the
    /// tombstone is enqueued exactly once even though both the fd `Drop` and `evict_dead_sessions` route
    /// here. Skipped if the server has already exited (`closed`) — there is no one to notify.
    pub fn drop_session(&mut self, session: u32) {
        if self.sessions.remove(&session).is_none() {
            return; // already torn down — do not enqueue a second tombstone
        }
        self.responses.retain(|&(s, _), _| s != session);
        self.requests.retain(
            |m| !matches!(m, ServiceInbound::Call(r) if r.session == session),
        );
        if !self.closed {
            self.requests.push_back(ServiceInbound::SessionClosed(session));
        }
    }

    /// Self-heal: drop every session whose client task is no longer alive (`alive(caller)` is the
    /// scheduler's liveness check). The connection fd's `Drop` on the universal `clear_program` is the
    /// primary teardown for a client exit; the server runs this each `svc_recv` as defense in depth,
    /// so a long-lived resident service can't accumulate orphaned sessions from a client that died
    /// abnormally — it never has to trust that some exit path dropped the fd.
    pub fn evict_dead_sessions<F: Fn(CallerId) -> bool>(&mut self, alive: F) {
        let dead: Vec<u32> = self
            .sessions
            .iter()
            .filter(|(_, s)| !alive(s.caller))
            .map(|(&id, _)| id)
            .collect();
        for id in dead {
            self.drop_session(id);
        }
    }

    /// Client `svc_call`: enqueue a request (with any delegated `handles`) on `session` and return its
    /// `req_id` (the key the result fd will drain). `None` if the session is unknown or the server has
    /// exited — the caller then fails crash-only and the handles drop (released).
    pub fn enqueue(
        &mut self,
        session: u32,
        blob: Vec<u8>,
        handles: Vec<DelegatedHandle>,
    ) -> Option<u32> {
        if self.closed || !self.sessions.contains_key(&session) {
            return None;
        }
        let id = self.next_req;
        self.next_req = self.next_req.wrapping_add(1).max(1);
        self.requests.push_back(ServiceInbound::Call(ServiceRequest {
            session,
            req_id: id,
            blob,
            handles,
        }));
        Some(id)
    }

    /// Client (its result fd) drains up to `out.len()` answer bytes for `(session, req_id)` from the
    /// front of the streaming buffer, refreshing the drain deadline (proof the client is alive). A
    /// non-zero status is a terminal `Failed`; an empty-but-complete buffer is `Eof`.
    pub fn drain_response(&mut self, session: u32, req_id: u32, out: &mut [u8]) -> ResponsePoll {
        if let Some(resp) = self.responses.get_mut(&(session, req_id)) {
            if resp.status != 0 {
                let status = resp.status;
                self.responses.remove(&(session, req_id));
                return ResponsePoll::Failed(status);
            }
            if !resp.buf.is_empty() {
                let n = resp.buf.len().min(out.len());
                for (slot, b) in out[..n].iter_mut().zip(resp.buf.drain(..n)) {
                    *slot = b;
                }
                resp.drain_deadline = crate::wall_now_ms() + SVC_DRAIN_TIMEOUT_MS;
                return ResponsePoll::Got(n);
            }
            if resp.complete {
                self.responses.remove(&(session, req_id));
                return ResponsePoll::Eof;
            }
            // The server still owes chunks (no final `last` seen) but its channel is gone — it crashed
            // mid-stream. Crash-only: surface EIO so the client fails cleanly instead of polling the
            // incomplete buffer forever (a partial `last=0` response left undrained on a server exit).
            if self.closed {
                self.responses.remove(&(session, req_id));
                return ResponsePoll::Failed(EIO);
            }
            ResponsePoll::Pending
        } else if self.closed || !self.sessions.contains_key(&session) {
            ResponsePoll::Closed
        } else {
            ResponsePoll::Pending
        }
    }

    /// Non-destructive readiness for the result fd (`poll`): would a `read` make progress — buffered
    /// bytes, a complete/failed answer, or the server gone — rather than block?
    pub fn response_ready(&self, session: u32, req_id: u32) -> bool {
        self.closed
            || !self.sessions.contains_key(&session)
            || self
                .responses
                .get(&(session, req_id))
                .is_some_and(|r| !r.buf.is_empty() || r.complete || r.status != 0)
    }

    // ── server side ──────────────────────────────────────────────────────────

    /// Server `svc_recv`: take the next inbound — a call to answer or a session-closed tombstone. The
    /// recv arm auto-rejects a call too large for the server's buffer (failing the client, not the
    /// server), so taking up front never strands a caller.
    pub fn take_request(&mut self) -> Option<ServiceInbound> {
        self.requests.pop_front()
    }

    /// Server `svc_respond`: append a body chunk to `(session, req_id)`'s answer (`last` marks the final
    /// one). `SessionGone` if the client left (the answer is dropped); `Overflow` if the un-drained
    /// buffer passes the cap (a client that isn't draining — the call fails `EMSGSIZE`, no unbounded
    /// kernel memory); else `Ok`.
    pub fn respond(
        &mut self,
        session: u32,
        req_id: u32,
        status: i32,
        data: Vec<u8>,
        last: bool,
    ) -> RespondOutcome {
        if !self.sessions.contains_key(&session) {
            return RespondOutcome::SessionGone;
        }
        let resp = self.responses.entry((session, req_id)).or_insert_with(|| ServiceResponse {
            status: 0,
            buf: VecDeque::new(),
            complete: false,
            drain_deadline: crate::wall_now_ms() + SVC_DRAIN_TIMEOUT_MS,
        });
        if status != 0 {
            resp.status = status;
        }
        resp.buf.extend(data);
        if last {
            resp.complete = true;
        }
        if resp.buf.len() > MAX_SVC_RESPONSE_BYTES {
            resp.buf.clear();
            resp.status = EMSGSIZE;
            resp.complete = true;
            return RespondOutcome::Overflow;
        }
        RespondOutcome::Ok
    }

    /// The un-drained byte count for `(session, req_id)` — the backpressure level `svc_respond` reads to
    /// decide whether to yield before sending more.
    pub fn response_buffered(&self, session: u32, req_id: u32) -> usize {
        self.responses.get(&(session, req_id)).map_or(0, |r| r.buf.len())
    }

    /// Finalize `(session, req_id)`'s answer as a clean failure with `errno` (a stuck client; the
    /// client's `read` surfaces it).
    pub fn fail_response(&mut self, session: u32, req_id: u32, errno: i32) {
        if let Some(resp) = self.responses.get_mut(&(session, req_id)) {
            resp.buf.clear();
            resp.status = errno;
            resp.complete = true;
        }
    }

    /// An in-progress streaming response the client has drained below the high-water — so the server can
    /// produce MORE for it without overflowing the kernel buffer. `svc_recv` offers this as a `DrainReady`
    /// event so the single-threaded server resumes a paused stream instead of blocking on it. Round-robin
    /// (advance past `last_drain`, wrapping) so a continuously-draining huge result can't starve the rest.
    pub fn next_drain_ready(&mut self) -> Option<(u32, u32)> {
        let ready: Vec<(u32, u32)> = self
            .responses
            .iter()
            .filter(|(_, r)| !r.complete && r.status == 0 && r.buf.len() < SVC_RESPONSE_HIGH_WATER)
            .map(|(&k, _)| k)
            .collect();
        let next = ready
            .iter()
            .copied()
            .find(|&k| Some(k) > self.last_drain)
            .or_else(|| ready.first().copied());
        self.last_drain = next;
        next
    }

    /// Sweep streaming responses a client has stopped draining past their deadline and fail them
    /// (`ETIMEDOUT`) — freeing the buffer and leaving the quiescence gate. Run on each `svc_recv`, so a
    /// stuck client is cleaned up WITHOUT ever blocking the single-threaded server (it never waits on one
    /// client; it just stops being offered that stream and reaps it when the deadline passes).
    pub fn fail_overdue(&mut self) {
        let now = crate::wall_now_ms();
        let stuck: Vec<(u32, u32)> = self
            .responses
            .iter()
            .filter(|(_, r)| !r.complete && r.status == 0 && now > r.drain_deadline)
            .map(|(&k, _)| k)
            .collect();
        for (s, q) in stuck {
            self.fail_response(s, q, ETIMEDOUT);
            self.inflight.remove(&(s, q));
        }
    }

    /// Server side: the server guest has exited — fail everything pending and to
    /// come.
    pub fn close(&mut self) {
        self.closed = true;
    }
}

// ── the service-name grammar ─────────────────────────────────────────────────
//
// One grammar, enforced at every boundary — `svc_serve`/`svc_connect`, the `mc_service` load gate,
// `mc-stamp`/`mc-attest` at build, and the manifest loader — so a name means the same thing to the
// stamp, the kernel, and the `/svc` path layer. The kernel check here is the security boundary; the
// build-time copies in the tools (which match the repo's standalone-tool idiom) only catch a bad name
// earlier. The shape is a clean single `/svc/<name>` path segment and a valid wasm custom-section
// payload.

/// Whether `name` is a syntactically valid service name: `[a-z][a-z0-9-]{0,30}` — lowercase ASCII, a
/// leading letter, hyphens/digits allowed after, 1..=31 bytes. (Tools carry a byte-identical copy.)
pub fn valid_service_name(name: &str) -> bool {
    let b = name.as_bytes();
    if b.is_empty() || b.len() > 31 || !b[0].is_ascii_lowercase() {
        return false;
    }
    b.iter()
        .all(|&c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
}

// ── the global service registry ─────────────────────────────────────────────
//
// Names a kernel-wide so `svc_connect(name)` finds the channel a `svc_serve(name)`
// installed. A free `static mut` is the single-threaded kernel's simplest global;
// it lives in the kernel's own linear memory, so a kernel snapshot carries the
// registry (and through the `Rc`s, the warm channels) intact. `Rc` is `!Sync`, which
// only a `static mut` (not a plain `static`) may hold.

static mut SERVICE_REGISTRY: Option<BTreeMap<String, Rc<RefCell<ServiceChannel>>>> = None;

fn registry() -> &'static mut BTreeMap<String, Rc<RefCell<ServiceChannel>>> {
    // SAFETY: the kernel runs cooperatively on one thread; every `fulfill_*` that
    // touches the registry runs to completion before another can, so there is no
    // aliasing of this `&mut`.
    unsafe {
        let slot = &mut *core::ptr::addr_of_mut!(SERVICE_REGISTRY);
        slot.get_or_insert_with(BTreeMap::new)
    }
}

/// Install `channel` under `name`. Returns `false` if a live service already holds
/// the name (one server per name).
pub fn register_service(name: &str, channel: Rc<RefCell<ServiceChannel>>) -> bool {
    let reg = registry();
    if reg.contains_key(name) {
        return false;
    }
    reg.insert(String::from(name), channel);
    true
}

/// Find the channel a client should `svc_connect` to.
pub fn lookup_service(name: &str) -> Option<Rc<RefCell<ServiceChannel>>> {
    registry().get(name).cloned()
}

/// Remove `name` (the server guest exited). Idempotent.
pub fn deregister_service(name: &str) {
    registry().remove(name);
}

/// Whether a service currently holds `name` (drives lazy-activation: connect spawns
/// the binary only when no live server is registered).
pub fn service_registered(name: &str) -> bool {
    registry().contains_key(name)
}

/// Every service the kernel knows about — REGISTERED (ready) plus mid-ACTIVATION (activating or failed)
/// — sorted and deduped. Drives the `/svc` listing so a STARTING or FAILED service is observable, not
/// just the ready ones (codex #6 observability).
pub fn known_service_names() -> Vec<String> {
    let mut names: BTreeSet<String> = registry().keys().cloned().collect();
    names.extend(activation_states().keys().cloned());
    names.into_iter().collect()
}

/// A one-line human status for `/svc/<name>` — `ready`, `activating`, or `failed: <why>`. `None` if the
/// kernel has never heard of `name`. The observability face of the activation supervisor (codex #6): a
/// `cat /svc/<name>` reports the lifecycle state, so a wedged service is visible, not silent.
pub fn service_status_line(name: &str) -> Option<String> {
    if service_registered(name) {
        return Some(String::from("ready\n"));
    }
    match activation_states().get(name)? {
        ServiceState::Activating { .. } => Some(String::from("activating\n")),
        ServiceState::Failed { last_errno, .. } => {
            let why = match *last_errno {
                ETIMEDOUT => "timed out before serving",
                EIO => "crashed before serving",
                _ => "activation failed",
            };
            Some(alloc::format!("failed: {why}\n"))
        }
    }
}

/// Total calls in flight across all REGISTERED services (delivered to a server, not yet answered). The
/// snapshot gate refuses while this is non-zero, so a snapshot is never taken with a service mid-call —
/// a live wasm stack the snapshot would lose (SERVICES.md §3.5; codex #5). A deregistered (crashed)
/// server is not counted: its warm state is already gone, so it cannot block a snapshot. A channel that
/// is momentarily borrowed counts as in-flight (conservative — never snapshot mid-operation).
pub fn svc_inflight() -> u32 {
    registry()
        .values()
        .map(|c| c.try_borrow().map_or(1, |ch| ch.inflight.len() as u32))
        .sum()
}

// ── activation grants ────────────────────────────────────────────────────────
//
// When the kernel activates a service it spawns the binary as a specific task and
// records the grant `name → pid` here. The grant does double duty:
//   * a `svc_connect` to a name that is mid-activation BLOCKS (re-poll) until the
//     service registers — the connect-before-serve race;
//   * `svc_serve(name)` is authorized ONLY for the granted task, so a service runs at
//     its own narrow tier (serve-authority is granted by activation, not a blanket
//     `CAP_MOUNT`) and no other guest can squat a service name.

/// How long a service has to reach `svc_serve` after the kernel spawns it before a connecting client
/// gives up (`ETIMEDOUT`) — bounds a service that hangs before serving (codex #4/#6).
pub const ACTIVATION_TIMEOUT_MS: i64 = 5_000;
/// Backoff after a FAILED activation: the n-th consecutive failure puts the service in cooldown for
/// `min(BASE << min(n-1, SHIFT_CAP), MAX)` ms, during which connects fail FAST (no respawn). So a
/// permanently-broken service is retried ever more rarely (1s, 2s, 4s, …, capped at MAX) rather than
/// respawned on every connect — codex #6's backoff, replacing the old fixed attempt budget.
pub const ACTIVATION_BACKOFF_BASE_MS: i64 = 1_000;
pub const ACTIVATION_BACKOFF_MAX_MS: i64 = 30_000;
const ACTIVATION_BACKOFF_SHIFT_CAP: u32 = 5;

/// The cooldown a service enters after its `attempts`-th consecutive failed activation.
fn backoff_ms(attempts: u32) -> i64 {
    let shift = attempts.saturating_sub(1).min(ACTIVATION_BACKOFF_SHIFT_CAP);
    (ACTIVATION_BACKOFF_BASE_MS << shift).min(ACTIVATION_BACKOFF_MAX_MS)
}

/// Where a service sits in its lifecycle, BESIDE the registry (which holds the ready ones). The kernel
/// spawns a service `Activating`; it goes ready by `svc_serve` (→ registry, this entry cleared), or
/// `Failed` if it hangs past its deadline (`ETIMEDOUT`) or crashes before serving (`EIO`). A `Failed`
/// service fails connects fast with `last_errno` until `until_ms` (a backoff growing with `attempts`),
/// then one retry is allowed — turning the old busy-poll / respawn-forever into a bounded supervisor
/// (codex #6). `attempts` is the consecutive-failure count (drives the backoff), carried across retries.
#[derive(Clone, Copy)]
pub enum ServiceState {
    Activating { pid: TaskId, deadline_ms: i64, attempts: u32 },
    Failed { until_ms: i64, last_errno: i32, attempts: u32 },
}

impl ServiceState {
    fn attempts(&self) -> u32 {
        match self {
            ServiceState::Activating { attempts, .. } | ServiceState::Failed { attempts, .. } => *attempts,
        }
    }
}

static mut ACTIVATION: Option<BTreeMap<String, ServiceState>> = None;

fn activation_states() -> &'static mut BTreeMap<String, ServiceState> {
    // SAFETY: single-threaded kernel; see `registry()`.
    unsafe {
        let slot = &mut *core::ptr::addr_of_mut!(ACTIVATION);
        slot.get_or_insert_with(BTreeMap::new)
    }
}

/// Record that `pid` is the kernel-designated server for `name`, due to `svc_serve` by `deadline_ms`.
/// Carries the failure count forward (so the backoff keeps growing for a service that keeps failing),
/// starting at 1 for a first activation.
pub fn mark_activating(name: &str, pid: TaskId, deadline_ms: i64) {
    let attempts = activation_states().get(name).map_or(0, ServiceState::attempts) + 1;
    activation_states().insert(
        String::from(name),
        ServiceState::Activating { pid, deadline_ms, attempts },
    );
}

/// Move `name` to `Failed` after a hung-past-deadline (`ETIMEDOUT`) or crash-before-serve (`EIO`)
/// activation: connects fail fast with `errno` until the `attempts`-based backoff elapses.
pub fn mark_failed(name: &str, errno: i32) {
    let attempts = activation_states().get(name).map_or(1, ServiceState::attempts);
    let until_ms = crate::wall_now_ms() + backoff_ms(attempts);
    activation_states().insert(
        String::from(name),
        ServiceState::Failed { until_ms, last_errno: errno, attempts },
    );
}

/// The task the kernel designated to serve `name`, if it is mid-activation — the `svc_serve` grant.
pub fn grant_holder(name: &str) -> Option<TaskId> {
    match activation_states().get(name) {
        Some(ServiceState::Activating { pid, .. }) => Some(*pid),
        _ => None,
    }
}

/// `name`'s current lifecycle state, for the connect state machine.
pub fn service_state(name: &str) -> Option<ServiceState> {
    activation_states().get(name).copied()
}

/// Clear `name`'s activation entry — it registered (now ready, in the registry).
pub fn clear_activation(name: &str) {
    activation_states().remove(name);
}

// ── fd owners (wrapped by `GuestFd` in wasm/mod.rs) ──────────────────────────

/// The server's control fd (`svc_serve`). Holds the channel and its name; dropping
/// it (the server guest exiting) closes the channel and deregisters the name, so
/// pending clients fail rather than block.
pub struct SvcServeOwner {
    name: String,
    channel: Rc<RefCell<ServiceChannel>>,
}

impl SvcServeOwner {
    pub fn new(name: String, channel: Rc<RefCell<ServiceChannel>>) -> Self {
        SvcServeOwner { name, channel }
    }

    pub fn channel(&self) -> &Rc<RefCell<ServiceChannel>> {
        &self.channel
    }
}

impl Drop for SvcServeOwner {
    fn drop(&mut self) {
        self.channel.borrow_mut().close();
        deregister_service(&self.name);
    }
}

/// A client's connection fd (`svc_connect`). Holds the channel and its session;
/// dropping it (the client closing the connection) tears the session down.
pub struct SvcConnHandle {
    channel: Rc<RefCell<ServiceChannel>>,
    session: u32,
}

impl SvcConnHandle {
    pub fn new(channel: Rc<RefCell<ServiceChannel>>, session: u32) -> Self {
        SvcConnHandle { channel, session }
    }

    pub fn channel(&self) -> &Rc<RefCell<ServiceChannel>> {
        &self.channel
    }

    pub fn session(&self) -> u32 {
        self.session
    }
}

impl Drop for SvcConnHandle {
    fn drop(&mut self) {
        self.channel.borrow_mut().drop_session(self.session);
    }
}

// ── the readable result fd (`svc_call`'s `ret_fd`) ───────────────────────────

#[derive(Clone, Copy)]
enum SvcPhase {
    /// Draining the streaming answer from the channel (Pending until bytes arrive, Eof when complete).
    Active,
    /// The answer was fully drained.
    Done,
    Closed,
    Failed(i32),
}

/// Outcome of pulling bytes from a `SvcCallSource` (mirrors `HostCallRead`).
pub enum SvcRead {
    /// The server has not buffered the next bytes yet — yield and retry.
    Pending,
    Got(usize),
    Eof,
    Closed,
    Failed(i32),
}

/// A readable `svc_call` result, driven by `mc_sys_read`: yield while the answer is in flight, then
/// drain the server's response body chunk by chunk from the channel's STREAMING buffer (codex #3), then
/// EOF. Holds an `Rc` to the channel, so the warm service outlives an in-flight call even if the
/// connection fd closes.
pub struct SvcCallSource {
    channel: Rc<RefCell<ServiceChannel>>,
    session: u32,
    req_id: u32,
    phase: SvcPhase,
}

impl SvcCallSource {
    pub fn new(channel: Rc<RefCell<ServiceChannel>>, session: u32, req_id: u32) -> Self {
        SvcCallSource {
            channel,
            session,
            req_id,
            phase: SvcPhase::Active,
        }
    }

    pub fn read_into(&mut self, buf: &mut [u8]) -> SvcRead {
        match self.phase {
            SvcPhase::Done => return SvcRead::Eof,
            SvcPhase::Closed => return SvcRead::Closed,
            SvcPhase::Failed(errno) => return SvcRead::Failed(errno),
            SvcPhase::Active => {}
        }
        // Drain the next bytes from the channel's streaming buffer (the server appends chunks).
        match self.channel.borrow_mut().drain_response(self.session, self.req_id, buf) {
            ResponsePoll::Pending => SvcRead::Pending,
            ResponsePoll::Got(n) => SvcRead::Got(n),
            ResponsePoll::Eof => {
                self.phase = SvcPhase::Done;
                SvcRead::Eof
            }
            ResponsePoll::Closed => {
                self.phase = SvcPhase::Closed;
                SvcRead::Closed
            }
            ResponsePoll::Failed(errno) => {
                self.phase = SvcPhase::Failed(errno);
                SvcRead::Failed(errno)
            }
        }
    }

    /// Non-destructive readiness for `poll`: would a `read` make progress?
    pub fn poll_readable(&self) -> bool {
        match self.phase {
            SvcPhase::Active => self
                .channel
                .borrow()
                .response_ready(self.session, self.req_id),
            // Done/Closed/Failed all return immediately from `read`.
            _ => true,
        }
    }
}

// ── the /svc listing fs (observability) ──────────────────────────────────────
//
// A read-only synthetic fs mounted at /svc so the service supervisor is observable (codex #6): `ls /svc`
// lists every KNOWN service — ready, activating, or failed (readdir → known_service_names()) — and
// `cat /svc/<name>` reports that one service's status line (open → its live status). You don't READ a
// service to USE it (you `svc_connect`); this is inspection. Writes/mkdir/unlink/rename are refused. A
// ZST that reads the (snapshot-captured) registry + activation state live, holding no state of its own.

pub struct ServiceFs;

impl ServiceFs {
    /// The service name for a path (`/kv` → `kv`); `None` for the root (`/svc` itself).
    fn name(path: &str) -> Option<&str> {
        let n = path.trim_start_matches('/');
        if n.is_empty() || n.contains('/') {
            None
        } else {
            Some(n)
        }
    }
}

impl FileSystem for ServiceFs {
    fn open(
        &mut self,
        _caller: CallerId,
        path: &KPath,
        flags: OpenFlags,
    ) -> Result<Box<dyn FileHandle>> {
        match Self::name(path.as_str()) {
            None => Err(FsError::IsDir), // /svc itself is a directory
            Some(name) => {
                if flags.write || flags.create || flags.truncate || flags.append {
                    return Err(FsError::PermissionDenied); // read-only: you svc_connect, not write
                }
                match service_status_line(name) {
                    Some(line) => Ok(Box::new(StatusMarker { data: line.into_bytes(), pos: 0 })),
                    None => Err(FsError::NotFound),
                }
            }
        }
    }

    fn stat(&self, path: &KPath) -> Result<Metadata> {
        match Self::name(path.as_str()) {
            None => Ok(Metadata::dir()),
            Some(name) => match service_status_line(name) {
                Some(line) => Ok(Metadata::file(line.len() as u64)),
                None => Err(FsError::NotFound),
            },
        }
    }

    fn readdir(&self, _caller: CallerId, path: &KPath) -> Result<Vec<DirEntry>> {
        if Self::name(path.as_str()).is_some() || !path.as_str().trim_start_matches('/').is_empty() {
            return Err(FsError::NotDir);
        }
        Ok(known_service_names()
            .into_iter()
            .map(|name| DirEntry {
                name,
                node_type: NodeType::File,
            })
            .collect())
    }

    fn mkdir(&mut self, _caller: CallerId, _path: &KPath) -> Result<()> {
        Err(FsError::PermissionDenied)
    }

    fn unlink(&mut self, _caller: CallerId, _path: &KPath) -> Result<()> {
        Err(FsError::PermissionDenied)
    }

    fn rename(&mut self, _caller: CallerId, _from: &KPath, _to: &KPath) -> Result<()> {
        Err(FsError::PermissionDenied)
    }
}

/// The handle for an open `/svc/<name>`: the service's status line (`ready` / `activating` / `failed:
/// …`), captured at open, so a `cat /svc/<name>` reports its lifecycle state (codex #6). Read-only — you
/// `svc_connect` to USE the service; this is for inspection.
struct StatusMarker {
    data: Vec<u8>,
    pos: usize,
}

impl FileHandle for StatusMarker {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize> {
        let n = (self.data.len() - self.pos).min(buf.len());
        buf[..n].copy_from_slice(&self.data[self.pos..self.pos + n]);
        self.pos += n;
        Ok(n)
    }
    fn write(&mut self, _buf: &[u8]) -> Result<usize> {
        Err(FsError::PermissionDenied)
    }
    fn seek(&mut self, pos: SeekFrom) -> Result<u64> {
        let target = match pos {
            SeekFrom::Start(n) => n as i64,
            SeekFrom::Current(n) => self.pos as i64 + n,
            SeekFrom::End(n) => self.data.len() as i64 + n,
        };
        self.pos = target.clamp(0, self.data.len() as i64) as usize;
        Ok(self.pos as u64)
    }
    fn stat(&self) -> Result<Metadata> {
        Ok(Metadata::file(self.data.len() as u64))
    }
}
