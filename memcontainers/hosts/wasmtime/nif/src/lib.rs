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
//! snapshot / commit / status. Gated egress (net / host_call / persist) is a separate relay
//! capability pass — it sends work to the owning process over the host's poll-based capability
//! seam (the WsHostCall/GatedNet pattern), with no kernel change.

use std::sync::{Arc, Mutex, MutexGuard};

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

fn vm_lock(vm: &ResourceArc<Vm>) -> NifResult<MutexGuard<'_, KernelHost>> {
    vm.host
        .lock()
        .map_err(|_| nif_err("vm resource lock poisoned"))
}

/// Copy bytes into a freshly-allocated BEAM binary term (kernel output is binary, never a
/// list-of-ints).
fn to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> NifResult<Binary<'a>> {
    let mut bin = OwnedBinary::new(bytes.len()).ok_or_else(|| nif_err("allocate NIF binary"))?;
    bin.as_mut_slice().copy_from_slice(bytes);
    Ok(bin.release(env))
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

fn build_builder(
    wasm: Vec<u8>,
    base_image: Option<Vec<u8>>,
    layers: Vec<Vec<u8>>,
    deterministic: bool,
    contract: Option<(i32, i32, i64)>,
    workers: Option<i32>,
    out: &Arc<Mutex<Vec<u8>>>,
) -> NifResult<KernelHostBuilder> {
    if base_image.is_some() && !layers.is_empty() {
        return Err(nif_err("base_image and layers are mutually exclusive"));
    }
    if matches!(workers, Some(n) if n < 0) {
        return Err(nif_err("workers must be non-negative"));
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
) -> NifResult<(Atom, ResourceArc<Vm>)> {
    let out = Arc::new(Mutex::new(Vec::new()));
    let host = build_builder(
        wasm.as_slice().to_vec(),
        base_image.map(|b| b.as_slice().to_vec()),
        layers.into_iter().map(|b| b.as_slice().to_vec()).collect(),
        deterministic,
        contract,
        workers,
        &out,
    )?
    .build()
    .map_err(nif_err)?;
    Ok((
        atoms::ok(),
        ResourceArc::new(Vm {
            host: Mutex::new(host),
            out,
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
) -> NifResult<(Atom, ResourceArc<Vm>)> {
    let out = Arc::new(Mutex::new(Vec::new()));
    if matches!(workers, Some(n) if n < 0) {
        return Err(nif_err("workers must be non-negative"));
    }
    let mut builder = KernelHostBuilder::new(wasm.as_slice().to_vec());
    if deterministic {
        builder = builder.deterministic();
    }
    if let Some(workers) = workers {
        builder = builder.with_workers(workers);
    }
    let host = with_capture(builder, &out)
        .restore(snapshot.as_slice())
        .map_err(nif_err)?;
    Ok((
        atoms::ok(),
        ResourceArc::new(Vm {
            host: Mutex::new(host),
            out,
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

rustler::init!("Elixir.AgentOS.Host.Nif");
