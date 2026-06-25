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
//! Scheduling: `boot`/`tick`/`exec`/`snapshot` run on a **DirtyCpu** scheduler. A `tick` is
//! bounded (one fuel quantum) but the first `boot` cranelift-compiles `kernel.wasm`.
//!
//! Output: VM terminal output is captured into a per-VM buffer (NOT the node's stdout — the
//! default `StdioSink` would flood a node hosting thousands of VMs), drained via `take_output`.
//! The structured `exec` returns its own captured streams independently.
//!
//! Scope: boot / restore / tick / send_input / take_output / exec / snapshot. Gated egress
//! (net / host_call / persist) is a later pass — it relays out to the owning process over the
//! host's poll-based capability seam (the WsHostCall/GatedNet pattern), with no kernel change.

use std::sync::{Arc, Mutex};

use host::{ExecResult, KernelHost, KernelHostBuilder, StreamSink};
use rustler::{Atom, Binary, Env, Error, NifResult, OwnedBinary, ResourceArc};

mod atoms {
    rustler::atoms! { ok }
}

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
}

#[rustler::resource_impl]
impl rustler::Resource for Vm {}

/// Map a host-side `anyhow::Error` to a NIF error term; rustler surfaces it to Elixir as
/// `{:error, message}` (a returned value, not a raise).
fn nif_err(e: impl std::fmt::Display) -> Error {
    Error::Term(Box::new(format!("{e}")))
}

/// Copy bytes into a freshly-allocated BEAM binary term (kernel output is binary, never a
/// list-of-ints).
fn to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Binary<'a> {
    let mut bin = OwnedBinary::new(bytes.len()).expect("allocate NIF binary");
    bin.as_mut_slice().copy_from_slice(bytes);
    bin.release(env)
}

/// Install capture sinks so terminal output is buffered into `out`, not the node's stdout.
fn with_capture(builder: KernelHostBuilder, out: &Arc<Mutex<Vec<u8>>>) -> KernelHostBuilder {
    builder
        .with_stdout(Box::new(SharedSink(out.clone())))
        .with_stderr(Box::new(SharedSink(out.clone())))
        .with_log(Box::new(SharedSink(out.clone())))
}

/// Boot a fresh VM from a `kernel.wasm` and an optional base image; ticks to the first prompt.
#[rustler::nif(schedule = "DirtyCpu")]
fn boot(wasm: Binary, base_image: Option<Binary>) -> NifResult<(Atom, ResourceArc<Vm>)> {
    let out = Arc::new(Mutex::new(Vec::new()));
    let host = with_capture(
        KernelHostBuilder::new(wasm.as_slice().to_vec())
            .with_base_image(base_image.map(|b| b.as_slice().to_vec())),
        &out,
    )
    .build()
    .map_err(nif_err)?;
    Ok((atoms::ok(), ResourceArc::new(Vm { host: Mutex::new(host), out })))
}

/// Restore (or fork) a VM from a snapshot blob — "the booted state IS the image" (A8).
#[rustler::nif(schedule = "DirtyCpu")]
fn restore(wasm: Binary, snapshot: Binary) -> NifResult<(Atom, ResourceArc<Vm>)> {
    let out = Arc::new(Mutex::new(Vec::new()));
    let host = with_capture(KernelHostBuilder::new(wasm.as_slice().to_vec()), &out)
        .restore(snapshot.as_slice())
        .map_err(nif_err)?;
    Ok((atoms::ok(), ResourceArc::new(Vm { host: Mutex::new(host), out })))
}

/// Drive one bounded `mc_tick`. `{:ok, true}` while running, `{:ok, false}` once exited.
#[rustler::nif(schedule = "DirtyCpu")]
fn tick(vm: ResourceArc<Vm>) -> NifResult<(Atom, bool)> {
    let alive = vm.host.lock().unwrap().tick().map_err(nif_err)?;
    Ok((atoms::ok(), alive))
}

/// Feed bytes to the kernel as terminal input.
#[rustler::nif(schedule = "DirtyCpu")]
fn send_input(vm: ResourceArc<Vm>, bytes: Binary) -> NifResult<Atom> {
    vm.host
        .lock()
        .unwrap()
        .send_input(bytes.as_slice())
        .map_err(nif_err)?;
    Ok(atoms::ok())
}

/// Drain (and clear) the terminal output captured since the last call. Infallible buffer copy,
/// so it stays on a normal scheduler.
#[rustler::nif]
fn take_output<'a>(env: Env<'a>, vm: ResourceArc<Vm>) -> Binary<'a> {
    let mut buf = vm.out.lock().unwrap();
    let bin = to_binary(env, &buf);
    buf.clear();
    bin
}

/// Run a command to completion → `{:ok, {exit_code, stdout, stderr}}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn exec<'a>(
    env: Env<'a>,
    vm: ResourceArc<Vm>,
    cmd: String,
    max_ticks: u64,
) -> NifResult<(Atom, (i32, Binary<'a>, Binary<'a>))> {
    let result: ExecResult = vm
        .host
        .lock()
        .unwrap()
        .exec(&cmd, max_ticks as usize)
        .map_err(nif_err)?;
    Ok((
        atoms::ok(),
        (
            result.exit_code,
            to_binary(env, &result.stdout),
            to_binary(env, &result.stderr),
        ),
    ))
}

/// Capture the whole VM (linear memory + a small header) into a portable blob (A8). The host
/// refuses while egress is in flight; that surfaces as `{:error, message}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn snapshot<'a>(env: Env<'a>, vm: ResourceArc<Vm>) -> NifResult<(Atom, Binary<'a>)> {
    let bytes = vm.host.lock().unwrap().snapshot().map_err(nif_err)?;
    Ok((atoms::ok(), to_binary(env, &bytes)))
}

rustler::init!("Elixir.AgentOS.Host.Nif");
