//! host_nif — the BEAM's window into the wasmtime `host` library.
//!
//! Makes Elixir a THIRD host family (CONTROL_PLANE.md §6.1) by wrapping the EXISTING,
//! contract-generated Rust host (`host::KernelHost`) in a Rustler NIF — *not* by
//! re-implementing the `env` bridge, which would be a third hand-written boundary against B2
//! and a third A3 parity target. Because the wasmtime host is underneath, snapshots stay
//! byte-identical and the bridge stays single-sourced; Elixir inherits both for free.
//!
//! Ownership model: one supervised BEAM process owns one VM. `KernelHost` is `Send` but not
//! `Sync` (its `wasmtime::Store` is `!Sync`), so the resource holds it behind a `Mutex` to
//! satisfy `ResourceArc`'s `Sync` bound; the lock is effectively uncontended because the
//! owning process serializes every call — the actor-per-VM discipline, now a BEAM process.
//!
//! Error contract: every fallible call returns `{:ok, value} | {:error, message}` — host
//! failures are *values*, not raises (this is the mechanism; the owning `AgentOS.Vm` decides
//! policy: a boot error becomes a clean GenServer `{:stop, …}`, a mid-run trap can be returned
//! or escalated to a crash-only restart). `take_output` is infallible and returns a bare binary.
//!
//! Scheduling: host calls that can compile, tick, drive jobs, touch the control channel, snapshot,
//! or commit run on a **DirtyCpu** scheduler. A `tick` is bounded (one fuel quantum) but the
//! first `boot` cranelift-compiles `kernel.wasm`.
//!
//! Output: VM terminal output is captured into a per-VM buffer (NOT the node's stdout — the
//! default `StdioSink` would flood a node hosting thousands of VMs), drained via `take_output`.
//! The structured `exec` returns its own captured streams independently.
//!
//! Scope: boot / restore / tick / terminal I/O / structured exec / control-channel fs /
//! snapshot / commit / status / egress relay. The relay is deliberately below the Phoenix/wire
//! edge: Rust queues poll-based `net`, `host_call`, and `persist` requests, while the owning
//! `AgentOS.Vm` process drains and answers them.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, MutexGuard};

use constants_rust::{PERSIST_OP_DELETE, PERSIST_OP_GET, PERSIST_OP_LIST, PERSIST_OP_PUT};
use host::{
    ConnectionCredential, ConnectionError, ConnectionRegistry, ExecResult, HostCallCapability,
    KernelHost, KernelHostBuilder, NetCapability, PersistCapability, RealNet, StreamSink,
};
use rustler::{Atom, Binary, Env, Error, NifResult, OwnedBinary, ResourceArc};

mod atoms {
    rustler::atoms! { ok }
}

const EAGAIN: i32 = 6;
const EMSGSIZE: i32 = 53;
const WS_SEND_MARK: usize = 1024 * 1024;

/// A `StreamSink` that appends the kernel's terminal output (stdout/stderr/log) into a shared
/// buffer the owning process drains via `take_output` — instead of the node's real stdout.
struct SharedSink(Arc<Mutex<Vec<u8>>>);

impl StreamSink for SharedSink {
    fn write(&mut self, bytes: &[u8]) {
        if let Ok(mut buf) = self.0.lock() {
            buf.extend_from_slice(bytes);
        }
    }
}

/// One VM = one `KernelHost`, owned by exactly one BEAM process (see module docs for the
/// `Mutex`). `out` is the captured terminal stream, shared with the sinks inside the host.
struct Vm {
    host: Mutex<KernelHost>,
    out: Arc<Mutex<Vec<u8>>>,
    relay: Arc<Mutex<RelayState>>,
}

#[rustler::resource_impl]
impl rustler::Resource for Vm {}

#[derive(Default)]
struct RelayState {
    next: i32,
    events: VecDeque<RelayEvent>,
    http: HashMap<i32, HttpSlot>,
    host_calls: HashMap<i32, HostCallSlot>,
    persist: HashMap<i32, PersistSlot>,
    ws: HashMap<i32, WsSlot>,
}

impl RelayState {
    fn alloc_handle(&mut self) -> i32 {
        if self.next <= 0 {
            self.next = 1;
        }
        let handle = self.next;
        self.next = self.next.wrapping_add(1).max(1);
        handle
    }
}

enum RelayEvent {
    HttpRequest {
        handle: i32,
        request: Vec<u8>,
    },
    HostCall {
        handle: i32,
        name: String,
        body: Vec<u8>,
    },
    PersistGet {
        handle: i32,
        key: Vec<u8>,
    },
    PersistPut {
        handle: i32,
        key: Vec<u8>,
        value: Vec<u8>,
    },
    PersistDelete {
        handle: i32,
        key: Vec<u8>,
    },
    PersistList {
        handle: i32,
        prefix: Vec<u8>,
    },
    WsConnect {
        handle: i32,
        url: String,
    },
    WsSend {
        handle: i32,
        data: Vec<u8>,
    },
    WsClose {
        handle: i32,
    },
}

#[derive(Default)]
struct HttpSlot {
    done: bool,
    failed: bool,
    head: Vec<u8>,
    body: Vec<u8>,
    body_pos: usize,
}

#[derive(Default)]
struct HostCallSlot {
    done: bool,
    failed: bool,
    result: Vec<u8>,
    offset: usize,
}

#[derive(Default)]
struct PersistSlot {
    done: bool,
    failed: bool,
    result: Vec<u8>,
    offset: usize,
}

#[derive(Default)]
struct WsSlot {
    open: bool,
    failed: bool,
    incoming: VecDeque<Vec<u8>>,
    incoming_pos: usize,
    queued_bytes: usize,
}

#[derive(Clone)]
struct BeamNet {
    relay: Arc<Mutex<RelayState>>,
}

impl NetCapability for BeamNet {
    fn http_request(&mut self, req: &[u8]) -> i32 {
        let Ok(mut relay) = self.relay.lock() else {
            return -1;
        };
        let handle = relay.alloc_handle();
        relay.http.insert(handle, HttpSlot::default());
        relay.events.push_back(RelayEvent::HttpRequest {
            handle,
            request: req.to_vec(),
        });
        handle
    }

    fn http_poll(&mut self, handle: i32, buf: &mut [u8]) -> i32 {
        let Ok(relay) = self.relay.lock() else {
            return -1;
        };
        let Some(slot) = relay.http.get(&handle) else {
            return -1;
        };
        if !slot.done {
            return 0;
        }
        if slot.failed {
            return -1;
        }
        let n = slot.head.len().min(buf.len());
        buf[..n].copy_from_slice(&slot.head[..n]);
        n as i32
    }

    fn http_body(&mut self, handle: i32, buf: &mut [u8]) -> i32 {
        let Ok(mut relay) = self.relay.lock() else {
            return -1;
        };
        let Some(slot) = relay.http.get_mut(&handle) else {
            return -1;
        };
        if !slot.done {
            return 0;
        }
        if slot.failed {
            return -1;
        }
        let start = slot.body_pos.min(slot.body.len());
        let n = (slot.body.len() - start).min(buf.len());
        buf[..n].copy_from_slice(&slot.body[start..start + n]);
        slot.body_pos += n;
        n as i32
    }

    fn http_close(&mut self, handle: i32) {
        if let Ok(mut relay) = self.relay.lock() {
            relay.http.remove(&handle);
            relay.events.retain(|event| match event {
                RelayEvent::HttpRequest { handle: h, .. } => *h != handle,
                _ => true,
            });
        }
    }

    fn ws_connect(&mut self, url: &str) -> i32 {
        let Ok(mut relay) = self.relay.lock() else {
            return -1;
        };
        let handle = relay.alloc_handle();
        relay.ws.insert(handle, WsSlot::default());
        relay.events.push_back(RelayEvent::WsConnect {
            handle,
            url: url.to_string(),
        });
        handle
    }

    fn ws_send(&mut self, handle: i32, data: &[u8]) -> i32 {
        let Ok(mut relay) = self.relay.lock() else {
            return -1;
        };
        let Some(slot) = relay.ws.get_mut(&handle) else {
            return -1;
        };
        if slot.failed {
            return -1;
        }
        if data.len() > WS_SEND_MARK {
            return -EMSGSIZE;
        }
        if !slot.open || slot.queued_bytes + data.len() > WS_SEND_MARK {
            return -EAGAIN;
        }
        slot.queued_bytes += data.len();
        relay.events.push_back(RelayEvent::WsSend {
            handle,
            data: data.to_vec(),
        });
        data.len() as i32
    }

    fn ws_ready(&mut self, handle: i32) -> i32 {
        let Ok(relay) = self.relay.lock() else {
            return 1;
        };
        let Some(slot) = relay.ws.get(&handle) else {
            return 1;
        };
        if slot.failed || (slot.open && slot.queued_bytes < WS_SEND_MARK) {
            1
        } else {
            0
        }
    }

    fn ws_recv(&mut self, handle: i32, buf: &mut [u8]) -> i32 {
        let Ok(mut relay) = self.relay.lock() else {
            return -1;
        };
        let Some(slot) = relay.ws.get_mut(&handle) else {
            return -1;
        };
        if slot.failed {
            return -1;
        }
        let Some(front) = slot.incoming.front() else {
            return 0;
        };
        let n = (front.len() - slot.incoming_pos).min(buf.len());
        buf[..n].copy_from_slice(&front[slot.incoming_pos..slot.incoming_pos + n]);
        slot.incoming_pos += n;
        if slot.incoming_pos >= front.len() {
            slot.incoming.pop_front();
            slot.incoming_pos = 0;
        }
        n as i32
    }

    fn ws_close(&mut self, handle: i32) {
        if let Ok(mut relay) = self.relay.lock() {
            relay.ws.remove(&handle);
            relay.events.push_back(RelayEvent::WsClose { handle });
            relay.events.retain(|event| match event {
                RelayEvent::WsConnect { handle: h, .. } | RelayEvent::WsSend { handle: h, .. } => {
                    *h != handle
                }
                _ => true,
            });
        }
    }
}

#[derive(Clone)]
struct BeamHostCall {
    relay: Arc<Mutex<RelayState>>,
}

impl HostCallCapability for BeamHostCall {
    fn start(&mut self, req: &[u8]) -> i32 {
        let nul = req.iter().position(|&b| b == 0).unwrap_or(req.len());
        let name = String::from_utf8_lossy(&req[..nul]).into_owned();
        let body = if nul < req.len() {
            req[nul + 1..].to_vec()
        } else {
            Vec::new()
        };

        let Ok(mut relay) = self.relay.lock() else {
            return -1;
        };
        let handle = relay.alloc_handle();
        relay.host_calls.insert(handle, HostCallSlot::default());
        relay
            .events
            .push_back(RelayEvent::HostCall { handle, name, body });
        handle
    }

    fn poll(&mut self, handle: i32) -> i32 {
        let Ok(relay) = self.relay.lock() else {
            return -1;
        };
        match relay.host_calls.get(&handle) {
            Some(slot) if slot.failed => -1,
            Some(slot) if slot.done => 1,
            Some(_) => 0,
            None => -1,
        }
    }

    fn body(&mut self, handle: i32, buf: &mut [u8]) -> i32 {
        let Ok(mut relay) = self.relay.lock() else {
            return -1;
        };
        let Some(slot) = relay.host_calls.get_mut(&handle) else {
            return -1;
        };
        if slot.failed || !slot.done {
            return -1;
        }
        let start = slot.offset.min(slot.result.len());
        let n = (slot.result.len() - start).min(buf.len());
        buf[..n].copy_from_slice(&slot.result[start..start + n]);
        slot.offset += n;
        n as i32
    }

    fn close(&mut self, handle: i32) {
        if let Ok(mut relay) = self.relay.lock() {
            relay.host_calls.remove(&handle);
            relay.events.retain(|event| match event {
                RelayEvent::HostCall { handle: h, .. } => *h != handle,
                _ => true,
            });
        }
    }
}

/// Persistence relay to the BEAM owner.
///
/// The old synchronous ABI (`mc_persist_get/put/delete/list`) could not safely
/// round-trip to Elixir: the NIF would have had to block a scheduler while the
/// owner process answered, or suspend/re-enter the VM inside a host import. The
/// ABI alteration is the poll-based quartet now used here: `start` queues an
/// op-tagged request and returns a handle; `poll` observes whether Elixir has
/// answered; `body` streams the answer bytes; `close` releases the slot. Missing
/// GETs are ordinary body data (`<<0>>`), not transport failure.
#[derive(Clone)]
struct BeamPersist {
    relay: Arc<Mutex<RelayState>>,
}

impl PersistCapability for BeamPersist {
    fn start(&mut self, req: &[u8]) -> i32 {
        let Some((op, key, value)) = decode_persist_request(req) else {
            return -1;
        };
        let Ok(mut relay) = self.relay.lock() else {
            return -1;
        };
        let handle = relay.alloc_handle();
        relay.persist.insert(handle, PersistSlot::default());
        match op {
            PERSIST_OP_GET => relay
                .events
                .push_back(RelayEvent::PersistGet { handle, key }),
            PERSIST_OP_PUT => relay
                .events
                .push_back(RelayEvent::PersistPut { handle, key, value }),
            PERSIST_OP_DELETE => relay
                .events
                .push_back(RelayEvent::PersistDelete { handle, key }),
            PERSIST_OP_LIST => relay.events.push_back(RelayEvent::PersistList {
                handle,
                prefix: key,
            }),
            _ => {
                relay.persist.remove(&handle);
                return -1;
            }
        }
        handle
    }

    fn poll(&mut self, handle: i32) -> i32 {
        let Ok(relay) = self.relay.lock() else {
            return -1;
        };
        match relay.persist.get(&handle) {
            Some(slot) if slot.failed => -1,
            Some(slot) if slot.done => 1,
            Some(_) => 0,
            None => -1,
        }
    }

    fn body(&mut self, handle: i32, buf: &mut [u8]) -> i32 {
        let Ok(mut relay) = self.relay.lock() else {
            return -1;
        };
        let Some(slot) = relay.persist.get_mut(&handle) else {
            return -1;
        };
        if slot.failed || !slot.done {
            return -1;
        }
        let start = slot.offset.min(slot.result.len());
        let n = (slot.result.len() - start).min(buf.len());
        buf[..n].copy_from_slice(&slot.result[start..start + n]);
        slot.offset += n;
        n as i32
    }

    fn close(&mut self, handle: i32) {
        if let Ok(mut relay) = self.relay.lock() {
            relay.persist.remove(&handle);
            relay.events.retain(|event| match event {
                RelayEvent::PersistGet { handle: h, .. }
                | RelayEvent::PersistPut { handle: h, .. }
                | RelayEvent::PersistDelete { handle: h, .. }
                | RelayEvent::PersistList { handle: h, .. } => *h != handle,
                _ => true,
            });
        }
    }
}

/// Map a host-side `anyhow::Error` to a NIF error term; rustler surfaces it to Elixir as
/// `{:error, message}` (a returned value, not a raise).
fn nif_err(e: impl std::fmt::Display) -> Error {
    Error::Term(Box::new(format!("{e}")))
}

fn vm_lock(vm: &ResourceArc<Vm>) -> NifResult<MutexGuard<'_, KernelHost>> {
    vm.host
        .lock()
        .map_err(|_| nif_err("vm resource lock poisoned"))
}

fn relay_lock(vm: &ResourceArc<Vm>) -> NifResult<MutexGuard<'_, RelayState>> {
    vm.relay
        .lock()
        .map_err(|_| nif_err("vm relay lock poisoned"))
}

/// Copy bytes into a freshly-allocated BEAM binary term (kernel output is binary, never a
/// list-of-ints).
fn to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> NifResult<Binary<'a>> {
    let mut bin = OwnedBinary::new(bytes.len()).ok_or_else(|| nif_err("allocate NIF binary"))?;
    bin.as_mut_slice().copy_from_slice(bytes);
    Ok(bin.release(env))
}

fn decode_persist_request(req: &[u8]) -> Option<(u32, Vec<u8>, Vec<u8>)> {
    if req.len() < 8 {
        return None;
    }
    let op = u32::from_le_bytes([req[0], req[1], req[2], req[3]]);
    let key_len = u32::from_le_bytes([req[4], req[5], req[6], req[7]]) as usize;
    let key_start = 8usize;
    let key_end = key_start.checked_add(key_len)?;
    if key_end > req.len() {
        return None;
    }
    Some((
        op,
        req[key_start..key_end].to_vec(),
        req[key_end..].to_vec(),
    ))
}

/// Install capture sinks so terminal output is buffered into `out`, not the node's stdout.
fn with_capture(builder: KernelHostBuilder, out: &Arc<Mutex<Vec<u8>>>) -> KernelHostBuilder {
    builder
        .with_stdout(Box::new(SharedSink(out.clone())))
        .with_stderr(Box::new(SharedSink(out.clone())))
        .with_log(Box::new(SharedSink(out.clone())))
}

fn ticks_to_usize(max_ticks: u64) -> NifResult<usize> {
    usize::try_from(max_ticks).map_err(|_| nif_err("max_ticks is too large for this host"))
}

fn build_connections(
    defs: Vec<(String, String, String, String, Vec<String>)>,
) -> NifResult<ConnectionRegistry> {
    let mut registry = ConnectionRegistry::new();
    for (reference, kind, a, b, origins) in defs {
        let credential = match kind.as_str() {
            "none" => ConnectionCredential::None,
            "bearer" => ConnectionCredential::Bearer { token: a },
            "header" => ConnectionCredential::Header { name: a, value: b },
            "query" => ConnectionCredential::Query { name: a, value: b },
            _ => return Err(nif_err(format!("unknown connection credential kind {kind:?}"))),
        };
        registry
            .insert(reference.clone(), credential, origins)
            .map_err(|err| {
                nif_err(format!(
                    "invalid connection {reference:?}: {}",
                    connection_error(err)
                ))
            })?;
    }
    Ok(registry)
}

fn connection_error(err: ConnectionError) -> &'static str {
    match err {
        ConnectionError::InvalidReference => "invalid reference",
        ConnectionError::InvalidHeader => "invalid header",
        ConnectionError::InvalidOrigin => "invalid origin",
        ConnectionError::InvalidSecret => "invalid secret",
        ConnectionError::MissingOrigin => "missing origin",
        ConnectionError::DuplicateConnection => "duplicate connection",
        ConnectionError::UnknownConnection => "unknown connection",
        ConnectionError::OriginNotAllowed => "origin not allowed",
        ConnectionError::DuplicateMarker => "duplicate marker",
        ConnectionError::MalformedRequest => "malformed request",
        ConnectionError::HeaderAlreadyPresent => "header already present",
    }
}

fn build_builder(
    wasm: Vec<u8>,
    base_image: Option<Vec<u8>>,
    layers: Vec<Vec<u8>>,
    deterministic: bool,
    contract: Option<(i32, i32, i64)>,
    workers: Option<i32>,
    net_relay: bool,
    net_real: bool,
    connections: Vec<(String, String, String, String, Vec<String>)>,
    host_call_relay: bool,
    persist_relay: bool,
    out: &Arc<Mutex<Vec<u8>>>,
    relay: &Arc<Mutex<RelayState>>,
) -> NifResult<KernelHostBuilder> {
    if base_image.is_some() && !layers.is_empty() {
        return Err(nif_err("base_image and layers are mutually exclusive"));
    }
    if matches!(workers, Some(n) if n < 0) {
        return Err(nif_err("workers must be non-negative"));
    }
    if net_relay && net_real {
        return Err(nif_err("net cannot be both relay and real"));
    }
    if !net_real && !connections.is_empty() {
        return Err(nif_err("connections require real net"));
    }

    let mut builder = KernelHostBuilder::new(wasm);
    if layers.is_empty() {
        builder = builder.with_base_image(base_image);
    } else {
        builder = builder.with_layers(layers);
    }
    if deterministic {
        builder = builder.deterministic();
    }
    if let Some((tier, budget_mib, fuel)) = contract {
        builder = builder.with_contract(tier, budget_mib, fuel);
    }
    if let Some(workers) = workers {
        builder = builder.with_workers(workers);
    }
    if net_relay {
        builder = builder.with_net(Box::new(BeamNet {
            relay: relay.clone(),
        }));
    } else if net_real {
        let net = RealNet::new().with_connections(build_connections(connections)?);
        builder = builder.with_net(Box::new(net));
    }
    if host_call_relay {
        builder = builder.with_host_call(Box::new(BeamHostCall {
            relay: relay.clone(),
        }));
    }
    if persist_relay {
        builder = builder.with_persist(Box::new(BeamPersist {
            relay: relay.clone(),
        }));
    }
    Ok(with_capture(builder, out))
}

/// Boot a fresh VM from a `kernel.wasm` and an optional base image; ticks to the first prompt.
#[rustler::nif(name = "boot_nif", schedule = "DirtyCpu")]
fn boot(
    wasm: Binary,
    base_image: Option<Binary>,
    layers: Vec<Binary>,
    deterministic: bool,
    contract: Option<(i32, i32, i64)>,
    workers: Option<i32>,
    net_relay: bool,
    net_real: bool,
    connections: Vec<(String, String, String, String, Vec<String>)>,
    host_call_relay: bool,
    persist_relay: bool,
) -> NifResult<(Atom, ResourceArc<Vm>)> {
    let out = Arc::new(Mutex::new(Vec::new()));
    let relay = Arc::new(Mutex::new(RelayState {
        next: 1,
        ..RelayState::default()
    }));
    let host = build_builder(
        wasm.as_slice().to_vec(),
        base_image.map(|b| b.as_slice().to_vec()),
        layers.into_iter().map(|b| b.as_slice().to_vec()).collect(),
        deterministic,
        contract,
        workers,
        net_relay,
        net_real,
        connections,
        host_call_relay,
        persist_relay,
        &out,
        &relay,
    )?
    .build()
    .map_err(nif_err)?;
    Ok((
        atoms::ok(),
        ResourceArc::new(Vm {
            host: Mutex::new(host),
            out,
            relay,
        }),
    ))
}

/// Restore (or fork) a VM from a snapshot blob — "the booted state IS the image" (A8).
#[rustler::nif(name = "restore_nif", schedule = "DirtyCpu")]
fn restore(
    wasm: Binary,
    snapshot: Binary,
    deterministic: bool,
    workers: Option<i32>,
    net_relay: bool,
    net_real: bool,
    connections: Vec<(String, String, String, String, Vec<String>)>,
    host_call_relay: bool,
    persist_relay: bool,
) -> NifResult<(Atom, ResourceArc<Vm>)> {
    let out = Arc::new(Mutex::new(Vec::new()));
    let relay = Arc::new(Mutex::new(RelayState {
        next: 1,
        ..RelayState::default()
    }));
    if matches!(workers, Some(n) if n < 0) {
        return Err(nif_err("workers must be non-negative"));
    }
    if net_relay && net_real {
        return Err(nif_err("net cannot be both relay and real"));
    }
    if !net_real && !connections.is_empty() {
        return Err(nif_err("connections require real net"));
    }
    let mut builder = KernelHostBuilder::new(wasm.as_slice().to_vec());
    if deterministic {
        builder = builder.deterministic();
    }
    if let Some(workers) = workers {
        builder = builder.with_workers(workers);
    }
    if net_relay {
        builder = builder.with_net(Box::new(BeamNet {
            relay: relay.clone(),
        }));
    } else if net_real {
        let net = RealNet::new().with_connections(build_connections(connections)?);
        builder = builder.with_net(Box::new(net));
    }
    if host_call_relay {
        builder = builder.with_host_call(Box::new(BeamHostCall {
            relay: relay.clone(),
        }));
    }
    if persist_relay {
        builder = builder.with_persist(Box::new(BeamPersist {
            relay: relay.clone(),
        }));
    }
    let host = with_capture(builder, &out)
        .restore(snapshot.as_slice())
        .map_err(nif_err)?;
    Ok((
        atoms::ok(),
        ResourceArc::new(Vm {
            host: Mutex::new(host),
            out,
            relay,
        }),
    ))
}

/// Drive one bounded `mc_tick`. `{:ok, true}` while running, `{:ok, false}` once exited.
#[rustler::nif(name = "tick_nif", schedule = "DirtyCpu")]
fn tick(vm: ResourceArc<Vm>) -> NifResult<(Atom, bool)> {
    let alive = vm_lock(&vm)?.tick().map_err(nif_err)?;
    Ok((atoms::ok(), alive))
}

/// Feed bytes to the kernel as terminal input.
#[rustler::nif(name = "send_input_nif", schedule = "DirtyCpu")]
fn send_input(vm: ResourceArc<Vm>, bytes: Binary) -> NifResult<Atom> {
    vm_lock(&vm)?
        .send_input(bytes.as_slice())
        .map_err(nif_err)?;
    Ok(atoms::ok())
}

/// Drain (and clear) the terminal output captured since the last call. Infallible buffer copy,
/// so it stays on a normal scheduler.
#[rustler::nif]
fn take_output<'a>(env: Env<'a>, vm: ResourceArc<Vm>) -> Binary<'a> {
    match vm.out.lock() {
        Ok(mut buf) => {
            let bin = to_binary(env, &buf).unwrap_or_else(|_| {
                OwnedBinary::new(0)
                    .expect("allocate empty NIF binary")
                    .release(env)
            });
            buf.clear();
            bin
        }
        Err(_) => OwnedBinary::new(0)
            .expect("allocate empty NIF binary")
            .release(env),
    }
}

/// Run a command to completion → `{:ok, {exit_code, stdout, stderr}}`.
#[rustler::nif(name = "exec_nif", schedule = "DirtyCpu")]
fn exec<'a>(
    env: Env<'a>,
    vm: ResourceArc<Vm>,
    cmd: String,
    max_ticks: u64,
) -> NifResult<(Atom, (i32, Binary<'a>, Binary<'a>))> {
    let result: ExecResult = vm_lock(&vm)?
        .exec(&cmd, ticks_to_usize(max_ticks)?)
        .map_err(nif_err)?;
    Ok((
        atoms::ok(),
        (
            result.exit_code,
            to_binary(env, &result.stdout)?,
            to_binary(env, &result.stderr)?,
        ),
    ))
}

#[rustler::nif(name = "exec_start_nif", schedule = "DirtyCpu")]
fn exec_start(vm: ResourceArc<Vm>, cmd: String) -> NifResult<(Atom, i32)> {
    let job = vm_lock(&vm)?.exec_start(&cmd).map_err(nif_err)?;
    Ok((atoms::ok(), job))
}

#[rustler::nif(name = "exec_poll_nif", schedule = "DirtyCpu")]
fn exec_poll<'a>(
    env: Env<'a>,
    vm: ResourceArc<Vm>,
    job: i32,
) -> NifResult<(Atom, Option<(i32, Binary<'a>, Binary<'a>)>)> {
    let result = vm_lock(&vm)?.exec_poll(job).map_err(nif_err)?;
    let result = match result {
        Some(result) => Some((
            result.exit_code,
            to_binary(env, &result.stdout)?,
            to_binary(env, &result.stderr)?,
        )),
        None => None,
    };
    Ok((atoms::ok(), result))
}

#[rustler::nif(name = "exec_stdout_peek_nif", schedule = "DirtyCpu")]
fn exec_stdout_peek<'a>(
    env: Env<'a>,
    vm: ResourceArc<Vm>,
    job: i32,
) -> NifResult<(Atom, Binary<'a>)> {
    let bytes = vm_lock(&vm)?.exec_stdout_peek(job).map_err(nif_err)?;
    Ok((atoms::ok(), to_binary(env, &bytes)?))
}

#[rustler::nif(name = "exec_cancel_nif", schedule = "DirtyCpu")]
fn exec_cancel(vm: ResourceArc<Vm>, job: i32) -> NifResult<Atom> {
    vm_lock(&vm)?.exec_cancel(job).map_err(nif_err)?;
    Ok(atoms::ok())
}

#[rustler::nif(name = "read_file_nif", schedule = "DirtyCpu")]
fn read_file<'a>(env: Env<'a>, vm: ResourceArc<Vm>, path: String) -> NifResult<(Atom, Binary<'a>)> {
    let bytes = vm_lock(&vm)?.read_file(&path).map_err(nif_err)?;
    Ok((atoms::ok(), to_binary(env, &bytes)?))
}

#[rustler::nif(name = "write_file_nif", schedule = "DirtyCpu")]
fn write_file(vm: ResourceArc<Vm>, path: String, data: Binary) -> NifResult<Atom> {
    vm_lock(&vm)?
        .write_file(&path, data.as_slice())
        .map_err(nif_err)?;
    Ok(atoms::ok())
}

#[rustler::nif(name = "readdir_nif", schedule = "DirtyCpu")]
fn readdir(vm: ResourceArc<Vm>, path: String) -> NifResult<(Atom, Vec<(String, bool, bool)>)> {
    let entries = vm_lock(&vm)?.readdir(&path).map_err(nif_err)?;
    let entries = entries
        .into_iter()
        .map(|e| (e.name, e.is_dir, e.is_symlink))
        .collect();
    Ok((atoms::ok(), entries))
}

#[rustler::nif(name = "stat_nif", schedule = "DirtyCpu")]
fn stat(vm: ResourceArc<Vm>, path: String) -> NifResult<(Atom, (u64, bool, bool, u32))> {
    let stat = vm_lock(&vm)?.stat(&path).map_err(nif_err)?;
    Ok((
        atoms::ok(),
        (stat.size, stat.is_dir, stat.is_symlink, stat.nlink),
    ))
}

#[rustler::nif(name = "mkdir_nif", schedule = "DirtyCpu")]
fn mkdir(vm: ResourceArc<Vm>, path: String) -> NifResult<Atom> {
    vm_lock(&vm)?.mkdir(&path).map_err(nif_err)?;
    Ok(atoms::ok())
}

#[rustler::nif(name = "unlink_nif", schedule = "DirtyCpu")]
fn unlink(vm: ResourceArc<Vm>, path: String) -> NifResult<Atom> {
    vm_lock(&vm)?.unlink(&path).map_err(nif_err)?;
    Ok(atoms::ok())
}

#[rustler::nif(name = "symlink_nif", schedule = "DirtyCpu")]
fn symlink(vm: ResourceArc<Vm>, target: String, link: String) -> NifResult<Atom> {
    vm_lock(&vm)?.symlink(&target, &link).map_err(nif_err)?;
    Ok(atoms::ok())
}

#[rustler::nif(name = "mount_nif", schedule = "DirtyCpu")]
fn mount(vm: ResourceArc<Vm>, path: String, read_only: bool) -> NifResult<Atom> {
    vm_lock(&vm)?.mount(&path, read_only).map_err(nif_err)?;
    Ok(atoms::ok())
}

#[rustler::nif(name = "unmount_nif", schedule = "DirtyCpu")]
fn unmount(vm: ResourceArc<Vm>, path: String) -> NifResult<Atom> {
    vm_lock(&vm)?.unmount(&path).map_err(nif_err)?;
    Ok(atoms::ok())
}

#[rustler::nif(name = "commit_layer_nif", schedule = "DirtyCpu")]
fn commit_layer<'a>(env: Env<'a>, vm: ResourceArc<Vm>) -> NifResult<(Atom, (Binary<'a>, String))> {
    let (tar, digest) = vm_lock(&vm)?.commit_layer().map_err(nif_err)?;
    Ok((atoms::ok(), (to_binary(env, &tar)?, digest)))
}

#[rustler::nif(name = "status_nif", schedule = "DirtyCpu")]
fn status(vm: ResourceArc<Vm>) -> NifResult<(Atom, (u64, Option<i32>, bool, i32, bool, i32, i32))> {
    let mut host = vm_lock(&vm)?;
    let bytes_written = host.bytes_written();
    let exit_code = host.exit_code();
    let at_prompt = host.at_prompt();
    let workers = host.workers();
    let has_worker_entry = host.has_worker_entry();
    let inflight_egress = host.inflight_egress().map_err(nif_err)?;
    let pending_commits = host.pending_commits().map_err(nif_err)?;
    Ok((
        atoms::ok(),
        (
            bytes_written,
            exit_code,
            at_prompt,
            workers,
            has_worker_entry,
            inflight_egress,
            pending_commits,
        ),
    ))
}

/// Capture the whole VM (linear memory + a small header) into a portable blob (A8). The host
/// refuses while egress is in flight; that surfaces as `{:error, message}`.
#[rustler::nif(name = "snapshot_nif", schedule = "DirtyCpu")]
fn snapshot<'a>(env: Env<'a>, vm: ResourceArc<Vm>) -> NifResult<(Atom, Binary<'a>)> {
    let bytes = vm_lock(&vm)?.snapshot().map_err(nif_err)?;
    Ok((atoms::ok(), to_binary(env, &bytes)?))
}

#[rustler::nif(name = "relay_next_nif")]
fn relay_next<'a>(
    env: Env<'a>,
    vm: ResourceArc<Vm>,
) -> NifResult<(Atom, Option<(String, i32, Binary<'a>, Binary<'a>)>)> {
    let mut relay = relay_lock(&vm)?;
    let Some(event) = relay.events.pop_front() else {
        return Ok((atoms::ok(), None));
    };

    let event = match event {
        RelayEvent::HttpRequest { handle, request } => (
            "http".to_string(),
            handle,
            to_binary(env, &request)?,
            to_binary(env, b"")?,
        ),
        RelayEvent::HostCall { handle, name, body } => (
            "host_call".to_string(),
            handle,
            to_binary(env, name.as_bytes())?,
            to_binary(env, &body)?,
        ),
        RelayEvent::PersistGet { handle, key } => (
            "persist_get".to_string(),
            handle,
            to_binary(env, &key)?,
            to_binary(env, b"")?,
        ),
        RelayEvent::PersistPut { handle, key, value } => (
            "persist_put".to_string(),
            handle,
            to_binary(env, &key)?,
            to_binary(env, &value)?,
        ),
        RelayEvent::PersistDelete { handle, key } => (
            "persist_delete".to_string(),
            handle,
            to_binary(env, &key)?,
            to_binary(env, b"")?,
        ),
        RelayEvent::PersistList { handle, prefix } => (
            "persist_list".to_string(),
            handle,
            to_binary(env, &prefix)?,
            to_binary(env, b"")?,
        ),
        RelayEvent::WsConnect { handle, url } => (
            "ws_connect".to_string(),
            handle,
            to_binary(env, url.as_bytes())?,
            to_binary(env, b"")?,
        ),
        RelayEvent::WsSend { handle, data } => {
            if let Some(slot) = relay.ws.get_mut(&handle) {
                slot.queued_bytes = slot.queued_bytes.saturating_sub(data.len());
            }
            (
                "ws_send".to_string(),
                handle,
                to_binary(env, &data)?,
                to_binary(env, b"")?,
            )
        }
        RelayEvent::WsClose { handle } => (
            "ws_close".to_string(),
            handle,
            to_binary(env, b"")?,
            to_binary(env, b"")?,
        ),
    };
    Ok((atoms::ok(), Some(event)))
}

#[rustler::nif(name = "relay_persist_respond_nif")]
fn relay_persist_respond(
    vm: ResourceArc<Vm>,
    handle: i32,
    ok: bool,
    body: Binary,
) -> NifResult<Atom> {
    let mut relay = relay_lock(&vm)?;
    let Some(slot) = relay.persist.get_mut(&handle) else {
        return Err(nif_err(format!("unknown persist relay handle {handle}")));
    };
    slot.done = true;
    slot.failed = !ok;
    slot.result = if ok {
        body.as_slice().to_vec()
    } else {
        Vec::new()
    };
    slot.offset = 0;
    Ok(atoms::ok())
}

#[rustler::nif(name = "relay_http_respond_nif")]
fn relay_http_respond(
    vm: ResourceArc<Vm>,
    handle: i32,
    ok: bool,
    head: Binary,
    body: Binary,
) -> NifResult<Atom> {
    let mut relay = relay_lock(&vm)?;
    let Some(slot) = relay.http.get_mut(&handle) else {
        return Err(nif_err(format!("unknown HTTP relay handle {handle}")));
    };
    slot.done = true;
    slot.failed = !ok;
    slot.head = if ok {
        head.as_slice().to_vec()
    } else {
        Vec::new()
    };
    slot.body = if ok {
        body.as_slice().to_vec()
    } else {
        Vec::new()
    };
    slot.body_pos = 0;
    Ok(atoms::ok())
}

#[rustler::nif(name = "relay_host_call_respond_nif")]
fn relay_host_call_respond(
    vm: ResourceArc<Vm>,
    handle: i32,
    ok: bool,
    result: Binary,
) -> NifResult<Atom> {
    let mut relay = relay_lock(&vm)?;
    let Some(slot) = relay.host_calls.get_mut(&handle) else {
        return Err(nif_err(format!("unknown host_call relay handle {handle}")));
    };
    slot.done = true;
    slot.failed = !ok;
    slot.result = if ok {
        result.as_slice().to_vec()
    } else {
        Vec::new()
    };
    slot.offset = 0;
    Ok(atoms::ok())
}

#[rustler::nif(name = "relay_ws_open_nif")]
fn relay_ws_open(vm: ResourceArc<Vm>, handle: i32, ok: bool) -> NifResult<Atom> {
    let mut relay = relay_lock(&vm)?;
    let Some(slot) = relay.ws.get_mut(&handle) else {
        return Err(nif_err(format!("unknown WebSocket relay handle {handle}")));
    };
    slot.open = ok;
    slot.failed = !ok;
    Ok(atoms::ok())
}

#[rustler::nif(name = "relay_ws_push_nif")]
fn relay_ws_push(vm: ResourceArc<Vm>, handle: i32, data: Binary) -> NifResult<Atom> {
    let mut relay = relay_lock(&vm)?;
    let Some(slot) = relay.ws.get_mut(&handle) else {
        return Err(nif_err(format!("unknown WebSocket relay handle {handle}")));
    };
    if slot.failed {
        return Err(nif_err(format!("closed WebSocket relay handle {handle}")));
    }
    slot.incoming.push_back(data.as_slice().to_vec());
    Ok(atoms::ok())
}

#[rustler::nif(name = "relay_ws_close_nif")]
fn relay_ws_close(vm: ResourceArc<Vm>, handle: i32) -> NifResult<Atom> {
    let mut relay = relay_lock(&vm)?;
    let Some(slot) = relay.ws.get_mut(&handle) else {
        return Err(nif_err(format!("unknown WebSocket relay handle {handle}")));
    };
    slot.failed = true;
    slot.open = false;
    Ok(atoms::ok())
}

rustler::init!("Elixir.AgentOS.Host.Nif");
