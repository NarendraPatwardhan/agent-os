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
//! Scheduling: `boot`/`tick`/`exec` run on a **DirtyCpu** scheduler. A `tick` is bounded (one
//! fuel quantum) but the first `boot` cranelift-compiles `kernel.wasm` (hundreds of ms), which
//! must not sit on a normal BEAM scheduler thread.
//!
//! Scope of THIS file (the start): boot / restore / tick / send_input / exec / snapshot. The
//! gated egress capabilities (net / host_call / persist) are a later pass — they relay out to
//! the owning process over the host's poll-based capability seam (the WsHostCall/GatedNet
//! pattern), with no kernel change.

use std::sync::Mutex;

use host::{ExecResult, KernelHost, KernelHostBuilder};
use rustler::{Binary, Env, Error, NifResult, OwnedBinary, ResourceArc};

/// One VM = one `KernelHost`, owned by exactly one BEAM process (see module docs for why the
/// `Mutex`).
struct Vm {
    inner: Mutex<KernelHost>,
}

#[rustler::resource_impl]
impl rustler::Resource for Vm {}

/// Map a host-side `anyhow::Error` to a NIF exception. A raised NIF error crashes the owning
/// process — exactly the crash-only model the control plane wants: the supervisor restarts the
/// VM actor, durable data already lives in `/var/persist`, warm state is only a cache.
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

/// Boot a fresh VM from a `kernel.wasm` and an optional base image (the layered tar).
#[rustler::nif(schedule = "DirtyCpu")]
fn boot(wasm: Binary, base_image: Option<Binary>) -> NifResult<ResourceArc<Vm>> {
    let host = KernelHostBuilder::new(wasm.as_slice().to_vec())
        .with_base_image(base_image.map(|b| b.as_slice().to_vec()))
        .build()
        .map_err(nif_err)?;
    Ok(ResourceArc::new(Vm { inner: Mutex::new(host) }))
}

/// Restore (or fork) a VM from a snapshot blob — "the booted state IS the image" (A8). A fresh
/// VM never shares the original's host handles.
#[rustler::nif(schedule = "DirtyCpu")]
fn restore(wasm: Binary, snapshot: Binary) -> NifResult<ResourceArc<Vm>> {
    let host = KernelHostBuilder::new(wasm.as_slice().to_vec())
        .restore(snapshot.as_slice())
        .map_err(nif_err)?;
    Ok(ResourceArc::new(Vm { inner: Mutex::new(host) }))
}

/// Drive one bounded `mc_tick`. `true` while the kernel runs, `false` once it has exited.
#[rustler::nif(schedule = "DirtyCpu")]
fn tick(vm: ResourceArc<Vm>) -> NifResult<bool> {
    vm.inner.lock().unwrap().tick().map_err(nif_err)
}

/// Feed bytes to the kernel as if typed at the terminal.
#[rustler::nif(schedule = "DirtyCpu")]
fn send_input(vm: ResourceArc<Vm>, bytes: Binary) -> NifResult<()> {
    vm.inner
        .lock()
        .unwrap()
        .send_input(bytes.as_slice())
        .map_err(nif_err)
}

/// Run a command to completion → `{exit_code, stdout, stderr}` (the two streams as binaries).
#[rustler::nif(schedule = "DirtyCpu")]
fn exec<'a>(
    env: Env<'a>,
    vm: ResourceArc<Vm>,
    cmd: String,
    max_ticks: u64,
) -> NifResult<(i32, Binary<'a>, Binary<'a>)> {
    let result: ExecResult = vm
        .inner
        .lock()
        .unwrap()
        .exec(&cmd, max_ticks as usize)
        .map_err(nif_err)?;
    Ok((
        result.exit_code,
        to_binary(env, &result.stdout),
        to_binary(env, &result.stderr),
    ))
}

/// Capture the whole VM (linear memory + a small header) into a portable blob (A8). The host
/// refuses while egress is in flight; that surfaces here as a NIF error.
#[rustler::nif(schedule = "DirtyCpu")]
fn snapshot<'a>(env: Env<'a>, vm: ResourceArc<Vm>) -> NifResult<Binary<'a>> {
    let bytes = vm.inner.lock().unwrap().snapshot().map_err(nif_err)?;
    Ok(to_binary(env, &bytes))
}

rustler::init!("Elixir.AgentOS.Host.Nif");
