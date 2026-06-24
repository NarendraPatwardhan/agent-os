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

/// The server guest's answer for one call. `status` is a kernel-level transport
/// signal (`0` = the response bytes follow; non-zero = an errno for a call that failed before a
/// body, surfaced to the client's `read`). Application-level results
/// (rows, errors) ride inside `data` per the service's own protocol.
struct ServiceResponse {
    status: i32,
    data: Vec<u8>,
}

/// Per-session bookkeeping: the client task that opened it. The connection fd's `Drop` (on the
/// universal `clear_program` at task exit) is the PRIMARY teardown; `caller` additionally lets the
/// server SELF-HEAL via [`ServiceChannel::evict_dead_sessions`], so a long-lived service never
/// accumulates orphans even if some exit path were to bypass the fd Drop.
struct Session {
    caller: CallerId,
}

/// Outcome of a client polling for its response.
pub enum ResponsePoll {
    /// The server has not answered yet — yield and retry.
    Pending,
    /// The server guest has exited — fail the call.
    Closed,
    /// The answer is ready: `(status, data)`.
    Ready(i32, Vec<u8>),
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

    /// Client (its result fd) collects the answer for `(session, req_id)`, if ready.
    pub fn take_response(&mut self, session: u32, req_id: u32) -> ResponsePoll {
        if let Some(resp) = self.responses.remove(&(session, req_id)) {
            return ResponsePoll::Ready(resp.status, resp.data);
        }
        if self.closed || !self.sessions.contains_key(&session) {
            return ResponsePoll::Closed;
        }
        ResponsePoll::Pending
    }

    /// Non-destructive readiness for the result fd (`poll`): would a `read` make
    /// progress (answer present, or the server gone) rather than block?
    pub fn response_ready(&self, session: u32, req_id: u32) -> bool {
        self.closed
            || !self.sessions.contains_key(&session)
            || self.responses.contains_key(&(session, req_id))
    }

    // ── server side ──────────────────────────────────────────────────────────

    /// Server `svc_recv`: take the next inbound — a call to answer or a session-closed tombstone. The
    /// recv arm auto-rejects a call too large for the server's buffer (failing the client, not the
    /// server), so taking up front never strands a caller.
    pub fn take_request(&mut self) -> Option<ServiceInbound> {
        self.requests.pop_front()
    }

    /// Server `svc_respond`: record the answer for `(session, req_id)`. Ignored
    /// (returns `false`) if the session has since closed — a late answer to a gone
    /// client is simply dropped.
    pub fn respond(&mut self, session: u32, req_id: u32, status: i32, data: Vec<u8>) -> bool {
        if !self.sessions.contains_key(&session) {
            return false;
        }
        self.responses
            .insert((session, req_id), ServiceResponse { status, data });
        true
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

/// The names of all currently-REGISTERED services (a live server holds each), in sorted order.
/// Drives the `/svc` listing fs ([`ServiceFs`]); a service mid-activation but not yet serving is not
/// listed (it has no live channel to connect to).
pub fn service_names() -> Vec<String> {
    registry().keys().cloned().collect()
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
/// gives up (`ETIMEDOUT`) — bounds a service that hangs before serving (codex #4).
pub const ACTIVATION_TIMEOUT_MS: i64 = 5_000;
/// How many crash-before-serve respawns to attempt before a connect fails (`EIO`) — bounds a service
/// that crashes on startup, instead of respawning it forever.
pub const MAX_ACTIVATION_ATTEMPTS: u32 = 3;

/// A service mid-activation: the kernel spawned `pid` to serve the name, which has not `svc_serve`d
/// yet. `deadline_ms` (a `wall_now_ms` value) bounds how long a connect waits; `attempts` bounds
/// crash-before-serve respawns. Without these a hung starter makes every client busy-poll forever and
/// a crash-looping one respawns endlessly (codex #4).
#[derive(Clone, Copy)]
pub struct Activation {
    pub pid: TaskId,
    pub deadline_ms: i64,
    pub attempts: u32,
}

static mut ACTIVATING: Option<BTreeMap<String, Activation>> = None;

fn activating() -> &'static mut BTreeMap<String, Activation> {
    // SAFETY: single-threaded kernel; see `registry()`.
    unsafe {
        let slot = &mut *core::ptr::addr_of_mut!(ACTIVATING);
        slot.get_or_insert_with(BTreeMap::new)
    }
}

/// Record (or re-record) that `pid` is the kernel-designated server for `name`, due to `svc_serve` by
/// `deadline_ms`. Carries the attempt count forward across a crash-before-serve respawn (so retries are
/// bounded), starting at 1.
pub fn mark_activating(name: &str, pid: TaskId, deadline_ms: i64) {
    let attempts = activating().get(name).map_or(0, |a| a.attempts) + 1;
    activating().insert(
        String::from(name),
        Activation {
            pid,
            deadline_ms,
            attempts,
        },
    );
}

/// The task the kernel designated to serve `name`, if any — the `svc_serve` grant.
pub fn grant_holder(name: &str) -> Option<TaskId> {
    activating().get(name).map(|a| a.pid)
}

/// The full activation record for `name` (pid + deadline + attempts), for the connect state machine.
pub fn activation(name: &str) -> Option<Activation> {
    activating().get(name).copied()
}

/// Clear `name`'s activation grant (it registered, its starter died and exceeded its retry budget, or
/// it hung past its deadline).
pub fn clear_activating(name: &str) {
    activating().remove(name);
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

enum SvcPhase {
    /// Waiting for the server to answer this `(session, req_id)`.
    Waiting,
    /// Draining the answered response body.
    Streaming { data: Vec<u8>, offset: usize },
    Eof,
    Closed,
    Failed(i32),
}

/// Outcome of pulling bytes from a `SvcCallSource` (mirrors `HostCallRead`).
pub enum SvcRead {
    /// The server has not answered yet — yield and retry.
    Pending,
    Got(usize),
    Eof,
    Closed,
    Failed(i32),
}

/// A readable `svc_call` result, driven by `mc_sys_read`: yield while the answer is
/// in flight, then stream the response body, then EOF. Holds an `Rc` to the channel,
/// so the warm service outlives an in-flight call even if the connection fd closes.
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
            phase: SvcPhase::Waiting,
        }
    }

    pub fn read_into(&mut self, buf: &mut [u8]) -> SvcRead {
        loop {
            match &mut self.phase {
                SvcPhase::Waiting => {
                    let poll = self
                        .channel
                        .borrow_mut()
                        .take_response(self.session, self.req_id);
                    match poll {
                        ResponsePoll::Pending => return SvcRead::Pending,
                        ResponsePoll::Closed => {
                            self.phase = SvcPhase::Closed;
                            return SvcRead::Closed;
                        }
                        ResponsePoll::Ready(status, data) => {
                            if status != 0 {
                                // Transport-level failure reported by the server.
                                self.phase = SvcPhase::Failed(status);
                                return SvcRead::Failed(status);
                            }
                            self.phase = SvcPhase::Streaming { data, offset: 0 };
                        }
                    }
                }
                SvcPhase::Streaming { data, offset } => {
                    if *offset >= data.len() {
                        self.phase = SvcPhase::Eof;
                        return SvcRead::Eof;
                    }
                    let n = (data.len() - *offset).min(buf.len());
                    buf[..n].copy_from_slice(&data[*offset..*offset + n]);
                    *offset += n;
                    return SvcRead::Got(n);
                }
                SvcPhase::Eof => return SvcRead::Eof,
                SvcPhase::Closed => return SvcRead::Closed,
                SvcPhase::Failed(errno) => return SvcRead::Failed(*errno),
            }
        }
    }

    /// Non-destructive readiness for `poll`: would a `read` make progress?
    pub fn poll_readable(&self) -> bool {
        match self.phase {
            SvcPhase::Waiting => self
                .channel
                .borrow()
                .response_ready(self.session, self.req_id),
            // Streaming/Eof/Failed all return immediately from `read`.
            _ => true,
        }
    }
}

// ── the /svc listing fs (observability) ──────────────────────────────────────
//
// A read-only synthetic fs mounted at /svc so the registry is observable: `ls /svc` lists the live
// services (readdir → service_names()), each a 0-byte marker node. You don't READ a service — you
// `svc_connect` it — so opening an entry yields an empty file (existence + the listing is the point);
// writes/mkdir/unlink/rename are refused. A ZST: it reads the (snapshot-captured) global registry
// live, so a kernel snapshot reflects the services without the fs holding any state of its own.

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
                if service_registered(name) {
                    Ok(Box::new(EmptyMarker))
                } else {
                    Err(FsError::NotFound)
                }
            }
        }
    }

    fn stat(&self, path: &KPath) -> Result<Metadata> {
        match Self::name(path.as_str()) {
            None => Ok(Metadata::dir()),
            Some(name) if service_registered(name) => Ok(Metadata::file(0)),
            Some(_) => Err(FsError::NotFound),
        }
    }

    fn readdir(&self, _caller: CallerId, path: &KPath) -> Result<Vec<DirEntry>> {
        if Self::name(path.as_str()).is_some() || !path.as_str().trim_start_matches('/').is_empty() {
            return Err(FsError::NotDir);
        }
        Ok(service_names()
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

/// The handle for an open `/svc/<name>`: a 0-byte marker (the listing IS the information; you connect
/// to the service rather than read this file).
struct EmptyMarker;

impl FileHandle for EmptyMarker {
    fn read(&mut self, _buf: &mut [u8]) -> Result<usize> {
        Ok(0) // immediate EOF
    }
    fn write(&mut self, _buf: &[u8]) -> Result<usize> {
        Err(FsError::PermissionDenied)
    }
    fn seek(&mut self, _pos: SeekFrom) -> Result<u64> {
        Ok(0)
    }
    fn stat(&self) -> Result<Metadata> {
        Ok(Metadata::file(0))
    }
}
