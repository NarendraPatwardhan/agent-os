//! Reusable wasmtime host for the agent-os kernel.
//!
//! Both the interactive `mc` CLI and the e2e suite drive a compiled `kernel.wasm` through
//! this one library — A2 means the kernel only ever runs as wasm, so every behavior test
//! boots the real artifact through here, never a mock (B6). The library owns the host half
//! of the two boundaries it touches — both GENERATED from the contracts, never
//! hand-written (B2): the `env` bridge implementation (`bridge`, the host's `$emit` on
//! `env_rust`) and the `mc_*` export lookups (`exports`, from `ctl_rust`). It also owns the
//! terminal-independent I/O sinks and the deterministic clock/RNG mode for tests (A7: the
//! only nondeterminism is the clock + entropy, and the deterministic sources make a run
//! byte-for-byte replayable, §15.1).

use std::collections::HashMap;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Result, anyhow};
use sha2::{Digest, Sha256};
use wasmtime::{Caller, Engine, Instance, Linker, Memory, Module, Store};

mod bridge;
mod exports;
mod host_call;
mod net;
mod persist;

pub use host_call::{DeniedHostCall, HostCallCapability, MapHostCall};
pub use net::{DeniedNet, NetCapability, RealNet};
#[cfg(feature = "tokio-net")]
pub use net::TokioNet;
pub use persist::{DeniedPersist, DiskPersist, PersistCapability};

use bridge::register_bridge;
use exports::KernelExports;

/// Convert a `wasmtime::Error` into `anyhow::Error` with a static context. wasmtime's own
/// `Error` does not implement `std::error::Error`, so `anyhow::Context` does not apply.
fn wt<T>(r: std::result::Result<T, wasmtime::Error>, msg: &'static str) -> Result<T> {
    r.map_err(|e| anyhow!("{msg}: {e}"))
}

const WASM_PAGE_SIZE: u64 = 65536;
const DEFAULT_WORKERS: i32 = 2;

// ---------- Stream sinks ----------

/// Receives bytes the kernel writes to stdout, stderr, or the log stream, in whatever
/// chunks the kernel produced.
pub trait StreamSink: Send + 'static {
    fn write(&mut self, bytes: &[u8]);
}

/// Writes to the real terminal. The CLI reaches for this; tests should avoid it (output
/// would leak into the test runner's own output).
pub struct StdioSink {
    target: StdioTarget,
}

enum StdioTarget {
    Stdout,
    Stderr,
}

impl StdioSink {
    pub fn stdout() -> Self {
        Self {
            target: StdioTarget::Stdout,
        }
    }
    pub fn stderr() -> Self {
        Self {
            target: StdioTarget::Stderr,
        }
    }
}

impl StreamSink for StdioSink {
    fn write(&mut self, bytes: &[u8]) {
        use std::io::Write as _;
        match self.target {
            StdioTarget::Stdout => {
                let mut out = std::io::stdout().lock();
                let _ = out.write_all(bytes);
                let _ = out.flush();
            }
            StdioTarget::Stderr => {
                let mut err = std::io::stderr().lock();
                let _ = err.write_all(bytes);
                let _ = err.flush();
            }
        }
    }
}

/// Appends written bytes into an `Arc<Mutex<Vec<u8>>>`. Tests clone the returned reader
/// handle and inspect the buffer after driving ticks.
pub struct CaptureSink {
    buf: Arc<Mutex<Vec<u8>>>,
}

impl CaptureSink {
    /// Returns `(sink, reader)`. Place `sink` into the builder; keep `reader` to inspect
    /// captured bytes from the test.
    pub fn new() -> (Self, Arc<Mutex<Vec<u8>>>) {
        let buf = Arc::new(Mutex::new(Vec::new()));
        (Self { buf: Arc::clone(&buf) }, buf)
    }
}

impl StreamSink for CaptureSink {
    fn write(&mut self, bytes: &[u8]) {
        if let Ok(mut guard) = self.buf.lock() {
            guard.extend_from_slice(bytes);
        }
    }
}

// ---------- Clock + RNG sources (A7: the only nondeterminism, gated on CAP_AMBIENT) ----------

pub trait ClockSource: Send + 'static {
    /// Wall-clock milliseconds since the UNIX epoch.
    fn now_millis(&mut self) -> i64;
    /// Monotonic milliseconds since instance start.
    fn monotonic_millis(&mut self) -> i64;
}

pub struct SystemClock {
    start: Instant,
}

impl SystemClock {
    pub fn new() -> Self {
        Self { start: Instant::now() }
    }
}

impl Default for SystemClock {
    fn default() -> Self {
        Self::new()
    }
}

impl ClockSource for SystemClock {
    fn now_millis(&mut self) -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
    }
    fn monotonic_millis(&mut self) -> i64 {
        self.start.elapsed().as_millis() as i64
    }
}

/// Fixed wall-clock; monotonic advances by 1 ms per call so loops that poll
/// `mc_time_monotonic` make forward progress without leaking real-time jitter into tests.
/// The deterministic half of replayability (§15.1).
pub struct FixedClock {
    epoch_ms: i64,
    monotonic: i64,
}

impl FixedClock {
    pub fn new(epoch_ms: i64) -> Self {
        Self { epoch_ms, monotonic: 0 }
    }
}

impl ClockSource for FixedClock {
    fn now_millis(&mut self) -> i64 {
        self.epoch_ms
    }
    fn monotonic_millis(&mut self) -> i64 {
        let v = self.monotonic;
        self.monotonic = self.monotonic.saturating_add(1);
        v
    }
}

pub trait RngSource: Send + 'static {
    fn fill(&mut self, buf: &mut [u8]);
}

pub struct OsRng;

impl RngSource for OsRng {
    fn fill(&mut self, buf: &mut [u8]) {
        for b in buf.iter_mut() {
            *b = rand::random();
        }
    }
}

/// SplitMix64 over a u64 seed. Cheap, deterministic, and good enough for `/dev/random`
/// reads under test — the other half of replayability.
pub struct SeededRng {
    state: u64,
}

impl SeededRng {
    pub fn new(seed: u64) -> Self {
        Self { state: seed }
    }
    fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
}

impl RngSource for SeededRng {
    fn fill(&mut self, buf: &mut [u8]) {
        let mut i = 0;
        while i < buf.len() {
            let bytes = self.next_u64().to_le_bytes();
            let n = (buf.len() - i).min(8);
            buf[i..i + n].copy_from_slice(&bytes[..n]);
            i += n;
        }
    }
}

// ---------- HostState ----------

/// The mutable state every bridge handler sees, living inside the wasmtime `Store`. The
/// generated `env` handlers (`bridge`) reach through `Caller` to read/write it.
pub struct HostState {
    memory: Option<Memory>,
    base_image: Option<Vec<u8>>,
    /// The image manifest's runtime contract, served via `mc_boot_contract`: tier ordinal
    /// (0=inherit / 1=full / 2=rw / 3=ro / 4=isolated), memory ceiling MiB (≤0 unset),
    /// fuel ceiling (≤0 unset).
    boot_tier: i32,
    boot_budget_mib: i32,
    boot_budget_fuel: i64,
    pub stdout: Box<dyn StreamSink>,
    pub stderr: Box<dyn StreamSink>,
    pub log: Box<dyn StreamSink>,
    pub clock: Box<dyn ClockSource>,
    pub rng: Box<dyn RngSource>,
    /// Network capability. Default `DeniedNet` (refuse, A9); the CLI installs `RealNet`
    /// under `--allow-net`, tests inject it directly.
    pub net: Box<dyn NetCapability>,
    /// Persistence capability. Default `DeniedPersist` (refuse, A9); the CLI installs
    /// `DiskPersist` under `--persist-dir`. Surfaced to the agent as `/var/persist`.
    pub persist: Box<dyn PersistCapability>,
    /// Host-call capability — the host side of `mc_sys_host_call` (the tool shim /
    /// host-backed mounts). Default `DeniedHostCall` (refuse); install `MapHostCall` to
    /// expose tools to the VM.
    pub host_call: Box<dyn HostCallCapability>,
    /// Worker count returned to the kernel from `mc_threads_init`. `0` keeps the kernel
    /// cooperative; `> 0` makes `mc_tick` delegate task stepping to `mc_worker_entry`,
    /// which this host drives from its tick loop.
    pub workers: i32,
    /// The count actually granted, clamped to `0..=max_workers`. The host drives exactly
    /// this many worker invocations per tick, so host and kernel never disagree. `0` until
    /// negotiation runs (and stays `0` on the cooperative-only artifact).
    pub workers_granted: i32,
    /// Set by `mc_exit`. `KernelHost::tick` reports `Ok(false)` once this is `Some(_)`.
    pub exit_code: Option<i32>,
    /// Total bytes the kernel has written to any stream — `run_*` uses it to detect output
    /// quiescence (the only reliable signal, since `mc_tick` always returns 1 today).
    pub bytes_written: u64,
    /// Last two bytes written to stdout. Lets the script driver tell a settled prompt
    /// (`"$ "`) from merely-quiet (a network command in flight, prompt held).
    pub stdout_tail: [u8; 2],
}

impl HostState {
    pub fn memory(&self) -> Option<Memory> {
        self.memory
    }
}

// ---------- Memory helpers (shared by the generated env handlers) ----------

/// Read `len` bytes at `ptr` out of the kernel's linear memory. `None` if the range is out
/// of bounds — the host never trusts the (untrusted) kernel's pointer/length.
pub(crate) fn read_memory(caller: &mut Caller<'_, HostState>, ptr: i32, len: i32) -> Option<Vec<u8>> {
    let memory = caller.data().memory?;
    let data = memory.data(&*caller);
    let start = ptr as usize;
    let end = start.checked_add(len as usize)?;
    if end > data.len() {
        return None;
    }
    Some(data[start..end].to_vec())
}

/// Drive a buffer-filling net call (poll / body / recv): hand `f` a scratch buffer of
/// `len`, and on a positive result copy that many bytes into kernel memory at `ptr`. `0`
/// and `-1` pass through. The guest range is validated against current memory BEFORE
/// allocating a buffer sized by the (untrusted) guest length — a malformed module
/// requesting a huge `len` is rejected here, not after forcing a large host allocation.
pub(crate) fn net_read_into(
    caller: &mut Caller<'_, HostState>,
    ptr: i32,
    len: i32,
    f: impl FnOnce(&mut dyn NetCapability, &mut [u8]) -> i32,
) -> i32 {
    if len < 0 {
        return -1;
    }
    let memory = match caller.data().memory {
        Some(m) => m,
        None => return -1,
    };
    let mem_len = memory.data(&*caller).len();
    let start = ptr as usize;
    let end = match start.checked_add(len as usize) {
        Some(e) if e <= mem_len => e,
        _ => return -1,
    };
    let mut tmp = vec![0u8; len as usize];
    let n = f(caller.data_mut().net.as_mut(), &mut tmp);
    if n <= 0 {
        return n;
    }
    let n = (n as usize).min(tmp.len());
    let data = memory.data_mut(caller);
    data[start..start + n].copy_from_slice(&tmp[..n]);
    let _ = end;
    n as i32
}

/// Like [`net_read_into`] for the persistence capability. `get`/`list` return the FULL
/// value/key length, so the kernel resizes and retries when `n > len`; `-1` denied, `-2`
/// not-found, `0` empty all pass through unchanged.
pub(crate) fn persist_read_into(
    caller: &mut Caller<'_, HostState>,
    ptr: i32,
    len: i32,
    f: impl FnOnce(&mut dyn PersistCapability, &mut [u8]) -> i32,
) -> i32 {
    if len < 0 {
        return -1;
    }
    let memory = match caller.data().memory {
        Some(m) => m,
        None => return -1,
    };
    let mem_len = memory.data(&*caller).len();
    let start = ptr as usize;
    let end = match start.checked_add(len as usize) {
        Some(e) if e <= mem_len => e,
        _ => return -1,
    };
    let mut tmp = vec![0u8; len as usize];
    let n = f(caller.data_mut().persist.as_mut(), &mut tmp);
    if n <= 0 {
        return n;
    }
    let copy = (n as usize).min(tmp.len());
    let data = memory.data_mut(caller);
    data[start..start + copy].copy_from_slice(&tmp[..copy]);
    let _ = end;
    n
}

/// Like [`net_read_into`] for the host-call capability.
pub(crate) fn host_call_read_into(
    caller: &mut Caller<'_, HostState>,
    ptr: i32,
    len: i32,
    f: impl FnOnce(&mut dyn HostCallCapability, &mut [u8]) -> i32,
) -> i32 {
    if len < 0 {
        return -1;
    }
    let memory = match caller.data().memory {
        Some(m) => m,
        None => return -1,
    };
    let mem_len = memory.data(&*caller).len();
    let start = ptr as usize;
    let end = match start.checked_add(len as usize) {
        Some(e) if e <= mem_len => e,
        _ => return -1,
    };
    let mut tmp = vec![0u8; len as usize];
    let n = f(caller.data_mut().host_call.as_mut(), &mut tmp);
    if n <= 0 {
        return n;
    }
    let n = (n as usize).min(tmp.len());
    let data = memory.data_mut(caller);
    data[start..start + n].copy_from_slice(&tmp[..n]);
    let _ = end;
    n as i32
}

// ---------- Module cache ----------

/// Compiled-module cache keyed by the wasm bytes' hash. Booting the same `kernel.wasm`
/// many times (a test suite) compiles it once.
static MODULE_CACHE: OnceLock<Mutex<HashMap<u64, (Engine, Module)>>> = OnceLock::new();

fn get_or_compile(wasm: &[u8]) -> Result<(Engine, Module)> {
    let mut h = DefaultHasher::new();
    wasm.hash(&mut h);
    let key = h.finish();

    // Hold the lock ACROSS the compile, not just around the lookup. A test binary runs its
    // cases in parallel (one thread per core), so they boot at once; if the lock were
    // released between the miss and the insert, every case would see an empty cache and
    // redundantly cranelift-compile kernel.wasm (~0.9s each — the cost that dominates a
    // boot). Held across `Module::new`, the first caller compiles and the rest block here
    // and reuse it: the module is compiled exactly once.
    let mut cache = MODULE_CACHE
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap();
    if let Some((e, m)) = cache.get(&key) {
        return Ok((e.clone(), m.clone()));
    }
    let engine = Engine::default();
    let module = wt(Module::new(&engine, wasm), "compiling kernel.wasm")?;
    cache.insert(key, (engine.clone(), module.clone()));
    Ok((engine, module))
}

// ---------- Builder ----------

pub struct KernelHostBuilder {
    wasm_bytes: Vec<u8>,
    base_image: Option<Vec<u8>>,
    boot_tier: i32,
    boot_budget_mib: i32,
    boot_budget_fuel: i64,
    stdout: Option<Box<dyn StreamSink>>,
    stderr: Option<Box<dyn StreamSink>>,
    log: Option<Box<dyn StreamSink>>,
    clock: Option<Box<dyn ClockSource>>,
    rng: Option<Box<dyn RngSource>>,
    net: Option<Box<dyn NetCapability>>,
    persist: Option<Box<dyn PersistCapability>>,
    host_call: Option<Box<dyn HostCallCapability>>,
    workers: Option<i32>,
}

impl KernelHostBuilder {
    pub fn new(wasm_bytes: Vec<u8>) -> Self {
        Self {
            wasm_bytes,
            base_image: None,
            boot_tier: 0,
            boot_budget_mib: 0,
            boot_budget_fuel: 0,
            stdout: None,
            stderr: None,
            log: None,
            clock: None,
            rng: None,
            net: None,
            persist: None,
            host_call: None,
            workers: None,
        }
    }

    /// The image manifest's runtime contract to enforce at boot. `tier` ordinal: 0=inherit
    /// / 1=full / 2=read-write / 3=read-only / 4=isolated; `budget_mib`/`fuel` ≤ 0 = unset.
    pub fn with_contract(mut self, tier: i32, budget_mib: i32, fuel: i64) -> Self {
        self.boot_tier = tier;
        self.boot_budget_mib = budget_mib;
        self.boot_budget_fuel = fuel;
        self
    }

    /// Install a network capability. Default `DeniedNet` (refuse). The CLI passes `RealNet`
    /// under `--allow-net`; tests pass `RealNet` directly.
    pub fn with_net(mut self, net: Box<dyn NetCapability>) -> Self {
        self.net = Some(net);
        self
    }

    /// Install a persistence capability. Default `DeniedPersist` (refuse). The CLI passes
    /// `DiskPersist` under `--persist-dir`.
    pub fn with_persist(mut self, persist: Box<dyn PersistCapability>) -> Self {
        self.persist = Some(persist);
        self
    }

    /// Install a host-call capability. Default `DeniedHostCall` (refuse). Pass a
    /// `MapHostCall` to expose registered tools to the VM.
    pub fn with_host_call(mut self, host_call: Box<dyn HostCallCapability>) -> Self {
        self.host_call = Some(host_call);
        self
    }

    /// Number of worker threads to advertise to the kernel via `mc_threads_init`. `0`
    /// selects the cooperative fallback; the default is `DEFAULT_WORKERS`. The
    /// cooperative-backed host drives these workers from its tick loop, not OS threads.
    pub fn with_workers(mut self, workers: i32) -> Self {
        self.workers = Some(workers);
        self
    }

    pub fn with_base_image(mut self, image: Option<Vec<u8>>) -> Self {
        self.base_image = image;
        self
    }

    /// Boot from an ordered layer STACK (lowest→highest) — `CowFs(OverlayFs([TarFs…]))`.
    /// Multiple layers are framed (`MCLS`) into the single `mc_load_base_image` payload; a
    /// LONE layer is passed raw (no framing) so it takes the kernel's zero-copy move path
    /// — framing a single large base would otherwise force a ~2× transient copy in the
    /// kernel heap. Empty ⇒ no base image.
    pub fn with_layers(mut self, layers: Vec<Vec<u8>>) -> Self {
        self.base_image = match layers.len() {
            0 => None,
            1 => layers.into_iter().next(),
            _ => Some(frame_layers(&layers)),
        };
        self
    }

    pub fn with_stdout(mut self, sink: Box<dyn StreamSink>) -> Self {
        self.stdout = Some(sink);
        self
    }

    pub fn with_stderr(mut self, sink: Box<dyn StreamSink>) -> Self {
        self.stderr = Some(sink);
        self
    }

    pub fn with_log(mut self, sink: Box<dyn StreamSink>) -> Self {
        self.log = Some(sink);
        self
    }

    pub fn with_clock(mut self, clock: Box<dyn ClockSource>) -> Self {
        self.clock = Some(clock);
        self
    }

    pub fn with_rng(mut self, rng: Box<dyn RngSource>) -> Self {
        self.rng = Some(rng);
        self
    }

    /// Wire deterministic sources so two runs with the same input transcript produce
    /// byte-identical output (§15.1). Tests should call this; the CLI should not.
    pub fn deterministic(mut self) -> Self {
        self.clock = Some(Box::new(FixedClock::new(1_700_000_000_000)));
        self.rng = Some(Box::new(SeededRng::new(0xDEAD_BEEF_CAFE_F00D)));
        self
    }

    /// Consume the builder into the initial `HostState` (capabilities + sinks).
    fn into_state(self) -> HostState {
        HostState {
            memory: None,
            base_image: self.base_image,
            boot_tier: self.boot_tier,
            boot_budget_mib: self.boot_budget_mib,
            boot_budget_fuel: self.boot_budget_fuel,
            stdout: self.stdout.unwrap_or_else(|| Box::new(StdioSink::stdout())),
            stderr: self.stderr.unwrap_or_else(|| Box::new(StdioSink::stderr())),
            log: self.log.unwrap_or_else(|| Box::new(StdioSink::stdout())),
            clock: self.clock.unwrap_or_else(|| Box::new(SystemClock::new())),
            rng: self.rng.unwrap_or_else(|| Box::new(OsRng)),
            net: self.net.unwrap_or_else(|| Box::new(DeniedNet)),
            persist: self.persist.unwrap_or_else(|| Box::new(DeniedPersist)),
            host_call: self.host_call.unwrap_or_else(|| Box::new(DeniedHostCall)),
            workers: self.workers.unwrap_or(DEFAULT_WORKERS),
            workers_granted: 0,
            exit_code: None,
            bytes_written: 0,
            stdout_tail: [0, 0],
        }
    }

    pub fn build(self) -> Result<KernelHost> {
        let (engine, module) = get_or_compile(&self.wasm_bytes)?;
        let state = self.into_state();
        let (mut store, instance, memory) = instantiate(&engine, &module, state)?;

        // Reserve a scratch page above current memory for input. Grow before mc_init so
        // Talc's first allocation already sees a larger memory; our scratch sits in the
        // newly added page. Talc only grows above the existing end, so it can never
        // reclaim this page.
        let prev_pages = wt(memory.grow(&mut store, 1), "growing memory for input scratch page")?;
        let scratch_addr = (prev_pages * WASM_PAGE_SIZE) as i32;
        let scratch_len = WASM_PAGE_SIZE as usize;

        let mc_init = wt(
            instance.get_typed_func::<(), i32>(&mut store, "mc_init"),
            "looking up mc_init",
        )?;
        let _ = wt(mc_init.call(&mut store, ()), "calling mc_init")?;

        // Drive the count the kernel actually negotiated (mc_init ran mc_threads_init), not
        // the advertised request — so the host never invokes the worker export more times
        // than the kernel agreed.
        let workers = store.data().workers_granted;
        let mut host = finalize(store, instance, memory, scratch_addr, scratch_len, workers)?;

        // The login shell (pid 1) prints its first prompt only after running, which needs
        // ticks. Drive boot until the prompt settles so callers observe a ready shell. (The
        // in-kernel rescue shell prints its prompt during mc_init, so this returns at once.)
        for _ in 0..8192 {
            if host.at_prompt() {
                break;
            }
            if !host.tick()? {
                break;
            }
        }
        Ok(host)
    }

    /// Rebuild a host from a snapshot ([`KernelHost::snapshot`]) instead of booting. Reuses
    /// the builder's wasm + capabilities + sinks, but writes the saved linear-memory image
    /// and does NOT call `mc_init` — the booted state IS the image. The restore/fork
    /// primitive. Pass fresh capabilities; a restored VM never shares the original's host
    /// handles.
    pub fn restore(self, snapshot: &[u8]) -> Result<KernelHost> {
        let hdr = SnapshotHeader::parse(snapshot)?;
        let (engine, module) = get_or_compile(&self.wasm_bytes)?;
        let state = self.into_state();
        let (mut store, instance, memory) = instantiate(&engine, &module, state)?;

        let cur = memory.data(&store).len();
        if hdr.mem_len > cur {
            let extra = ((hdr.mem_len - cur) as u64).div_ceil(WASM_PAGE_SIZE);
            wt(memory.grow(&mut store, extra), "growing memory for restore")?;
        }
        let image = &snapshot[SNAPSHOT_HEADER_LEN..SNAPSHOT_HEADER_LEN + hdr.mem_len];
        memory.data_mut(&mut store)[..hdr.mem_len].copy_from_slice(image);

        finalize(store, instance, memory, hdr.scratch_addr, hdr.scratch_len, hdr.workers)
    }
}

// ---------- Instantiation / finalization (shared by build + restore) ----------

/// Instantiate the kernel module with `state`, wiring the GENERATED bridge and capturing
/// the `memory` export. Does NOT boot (mc_init) — the caller decides.
fn instantiate(
    engine: &Engine,
    module: &Module,
    state: HostState,
) -> Result<(Store<HostState>, Instance, Memory)> {
    let mut linker = Linker::<HostState>::new(engine);
    register_bridge(&mut linker)?;
    let mut store = Store::new(engine, state);
    let instance = wt(linker.instantiate(&mut store, module), "instantiating kernel module")?;
    let memory = instance
        .get_export(&mut store, "memory")
        .ok_or_else(|| anyhow!("kernel module is missing the `memory` export"))?
        .into_memory()
        .ok_or_else(|| anyhow!("kernel `memory` export is not a Memory"))?;
    store.data_mut().memory = Some(memory);
    Ok((store, instance, memory))
}

/// Look up the kernel's exports (from the generated `ctl` table) and assemble the
/// `KernelHost`.
fn finalize(
    mut store: Store<HostState>,
    instance: Instance,
    memory: Memory,
    scratch_addr: i32,
    scratch_len: usize,
    workers: i32,
) -> Result<KernelHost> {
    let exports = KernelExports::lookup(&instance, &mut store);
    Ok(KernelHost {
        store,
        _instance: instance,
        memory,
        exports,
        workers,
        scratch_addr,
        scratch_len,
    })
}

// ---------- Snapshot format ----------

const SNAPSHOT_MAGIC: &[u8; 4] = b"MCSN";
const SNAPSHOT_VERSION: u32 = 1;
/// magic(4) + version(4) + scratch_addr(4) + scratch_len(4) + workers(4) + mem_len(4)
const SNAPSHOT_HEADER_LEN: usize = 24;

struct SnapshotHeader {
    scratch_addr: i32,
    scratch_len: usize,
    workers: i32,
    mem_len: usize,
}

impl SnapshotHeader {
    fn parse(snap: &[u8]) -> Result<SnapshotHeader> {
        if snap.len() < SNAPSHOT_HEADER_LEN {
            return Err(anyhow!("snapshot too short ({} bytes)", snap.len()));
        }
        if &snap[0..4] != SNAPSHOT_MAGIC {
            return Err(anyhow!("not an agent-os snapshot (bad magic)"));
        }
        let version = u32::from_le_bytes(snap[4..8].try_into().unwrap());
        if version != SNAPSHOT_VERSION {
            return Err(anyhow!(
                "unsupported snapshot version {version} (host expects {SNAPSHOT_VERSION})"
            ));
        }
        let scratch_addr = i32::from_le_bytes(snap[8..12].try_into().unwrap());
        let scratch_len = u32::from_le_bytes(snap[12..16].try_into().unwrap()) as usize;
        let workers = i32::from_le_bytes(snap[16..20].try_into().unwrap());
        let mem_len = u32::from_le_bytes(snap[20..24].try_into().unwrap()) as usize;
        if snap.len() < SNAPSHOT_HEADER_LEN + mem_len {
            return Err(anyhow!(
                "snapshot truncated: need {} bytes, have {}",
                SNAPSHOT_HEADER_LEN + mem_len,
                snap.len()
            ));
        }
        Ok(SnapshotHeader { scratch_addr, scratch_len, workers, mem_len })
    }
}

// ---------- Structured results ----------

/// Result of a structured `exec` (control channel): captured streams plus the real exit
/// code — no prompt scraping.
#[derive(Debug, Clone)]
pub struct ExecResult {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub exit_code: i32,
}

/// Metadata from [`KernelHost::stat`]. Reports the link itself for a symlink (the control
/// channel uses lstat semantics).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileStat {
    pub size: u64,
    pub is_dir: bool,
    pub is_symlink: bool,
    /// Hard-link count (POSIX `st_nlink`).
    pub nlink: u32,
}

/// One entry from [`KernelHost::readdir`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirEntry {
    pub name: String,
    pub is_dir: bool,
    pub is_symlink: bool,
}

// ---------- KernelHost ----------

pub struct KernelHost {
    store: Store<HostState>,
    _instance: Instance,
    memory: Memory,
    /// Every export the host calls, looked up from the generated `ctl` table.
    exports: KernelExports,
    workers: i32,
    scratch_addr: i32,
    scratch_len: usize,
}

impl KernelHost {
    /// Number of bytes the kernel has written to any stream so far.
    pub fn bytes_written(&self) -> u64 {
        self.store.data().bytes_written
    }

    pub fn exit_code(&self) -> Option<i32> {
        self.store.data().exit_code
    }

    /// Feed bytes to the kernel as if typed at the terminal. Bytes are written into the
    /// reserved scratch page and `mc_input` is called once per chunk that fits.
    pub fn send_input(&mut self, bytes: &[u8]) -> Result<()> {
        if bytes.is_empty() {
            return Ok(());
        }
        let f = self.exports.require_input()?;
        for chunk in bytes.chunks(self.scratch_len) {
            {
                let data = self.memory.data_mut(&mut self.store);
                let start = self.scratch_addr as usize;
                let end = start + chunk.len();
                if end > data.len() {
                    return Err(anyhow!(
                        "input scratch out of range: addr {:#x}, chunk {} bytes, memory size {}",
                        self.scratch_addr,
                        chunk.len(),
                        data.len(),
                    ));
                }
                data[start..end].copy_from_slice(chunk);
            }
            wt(
                f.call(&mut self.store, (self.scratch_addr, chunk.len() as i32)),
                "calling mc_input",
            )?;
        }
        Ok(())
    }

    /// Run one `mc_tick`. `Ok(true)` to continue, `Ok(false)` once the kernel has called
    /// `mc_exit`. The kernel's own return value is ignored today (always 1).
    pub fn tick(&mut self) -> Result<bool> {
        if self.store.data().exit_code.is_some() {
            return Ok(false);
        }
        let tick = self.exports.require_tick()?;
        let _ = wt(tick.call(&mut self.store, ()), "calling mc_tick")?;
        // In threaded mode `mc_tick` only coordinates; drive the workers to step tasks for
        // this tick. No-op when cooperative.
        self.drive_workers()?;
        Ok(self.store.data().exit_code.is_none())
    }

    /// Drive each provisioned worker once for this tick. `mc_worker_entry` runs one bounded
    /// round per call (stepping each ready task once), so calling it once per worker
    /// performs a fixed, bounded amount of work per tick — mirroring the cooperative
    /// one-round-per-tick schedule. No-op on the cooperative-only artifact or `workers==0`.
    fn drive_workers(&mut self) -> Result<()> {
        let Some(worker) = self.exports.mc_worker_entry.clone() else {
            return Ok(());
        };
        for w in 0..self.workers {
            if self.store.data().exit_code.is_some() {
                break;
            }
            let _ = wt(worker.call(&mut self.store, w), "calling mc_worker_entry")?;
        }
        Ok(())
    }

    /// Number of workers advertised to the kernel (0 = cooperative).
    pub fn workers(&self) -> i32 {
        self.workers
    }

    /// Whether the loaded artifact exports the threading worker entry.
    pub fn has_worker_entry(&self) -> bool {
        self.exports.mc_worker_entry.is_some()
    }

    /// Drive a single worker step (1 = stepped a task, 0 = idle/parked). Returns 0 on the
    /// cooperative-only artifact.
    pub fn worker_step(&mut self, worker_id: i32) -> Result<i32> {
        match self.exports.mc_worker_entry.clone() {
            Some(f) => wt(f.call(&mut self.store, worker_id), "calling mc_worker_entry"),
            None => Ok(0),
        }
    }

    /// Request quiesce: workers park at their safe point so the host can snapshot
    /// consistently. No-op on the cooperative-only artifact.
    pub fn quiesce(&mut self) -> Result<()> {
        if let Some(f) = self.exports.mc_quiesce_request.clone() {
            let _ = wt(f.call(&mut self.store, ()), "calling mc_quiesce_request")?;
        }
        Ok(())
    }

    /// Release a previous quiesce so workers resume.
    pub fn quiesce_release(&mut self) -> Result<()> {
        if let Some(f) = self.exports.mc_quiesce_release.clone() {
            let _ = wt(f.call(&mut self.store, ()), "calling mc_quiesce_release")?;
        }
        Ok(())
    }

    /// True when the last bytes written to stdout were the shell prompt `"$ "` — the shell
    /// is idle and ready, not mid-command.
    pub fn at_prompt(&self) -> bool {
        self.store.data().stdout_tail == [b'$', b' ']
    }

    /// Drive a scripted session to completion. Keeps ticking while a command is in flight
    /// even if it produces no output — it treats the session as finished only once the
    /// shell has returned to a *settled prompt*. Paces (sleeps) only on idle ticks, so a
    /// network command (silent on the wire while it runs) gets real wall-clock time
    /// instead of spinning the tick budget away, while output-producing commands run at
    /// full speed.
    pub fn run_script(&mut self, max_ticks: usize) -> Result<usize> {
        const SETTLE_TICKS: usize = 64; // ~320ms quiet at the prompt = done
        let pace = std::time::Duration::from_millis(5);
        let mut settle = 0usize;
        let mut last = self.bytes_written();
        for n in 0..max_ticks {
            if !self.tick()? {
                return Ok(n + 1);
            }
            let now = self.bytes_written();
            if now != last {
                last = now;
                settle = 0;
                continue;
            }
            if self.at_prompt() {
                settle += 1;
                if settle >= SETTLE_TICKS {
                    return Ok(n + 1);
                }
            }
            std::thread::sleep(pace);
        }
        Ok(max_ticks)
    }

    /// Pump ticks until `mc_exit`, the kernel stops producing output for
    /// `idle_ticks_required` consecutive ticks, or `max_ticks` is exhausted.
    pub fn run_until_idle(&mut self, max_ticks: usize, idle_ticks_required: usize) -> Result<usize> {
        let mut last = self.bytes_written();
        let mut idle = 0usize;
        for n in 0..max_ticks {
            if !self.tick()? {
                return Ok(n + 1);
            }
            let now = self.bytes_written();
            if now == last {
                idle += 1;
                if idle >= idle_ticks_required {
                    return Ok(n + 1);
                }
            } else {
                idle = 0;
                last = now;
            }
        }
        Ok(max_ticks)
    }

    /// Number of host-egress operations currently in flight. A non-zero value means
    /// `snapshot`/`commit_layer` will refuse. `0` on a kernel without the export.
    pub fn inflight_egress(&mut self) -> Result<i32> {
        match self.exports.mc_inflight_egress.clone() {
            Some(f) => wt(f.call(&mut self.store, ()), "mc_inflight_egress"),
            None => Ok(0),
        }
    }

    /// Number of host-backed-mount write commits parked in the kernel but not yet
    /// acknowledged by their host driver. `0` on artifacts without the export.
    pub fn pending_commits(&mut self) -> Result<i32> {
        match self.exports.mc_pending_commits.clone() {
            Some(f) => wt(f.call(&mut self.store, ()), "mc_pending_commits"),
            None => Ok(0),
        }
    }

    /// Capture the entire VM as a portable byte blob: the linear-memory image — all kernel
    /// and guest state — behind a small header (A8). Refuses while a host-egress operation
    /// is in flight, since an open connection's raw host handle would not survive a
    /// restore; let in-flight requests finish first. Pair with
    /// [`KernelHostBuilder::restore`] to rehydrate or fork.
    pub fn snapshot(&mut self) -> Result<Vec<u8>> {
        if let Some(f) = self.exports.mc_inflight_egress.clone() {
            let n = wt(f.call(&mut self.store, ()), "mc_inflight_egress")?;
            if n > 0 {
                return Err(anyhow!(
                    "cannot snapshot: {n} host-egress operation(s) in flight; quiesce first"
                ));
            }
        }
        let mem = self.memory.data(&self.store);
        let mem_len = mem.len();
        let mut out = Vec::with_capacity(SNAPSHOT_HEADER_LEN + mem_len);
        out.extend_from_slice(SNAPSHOT_MAGIC);
        out.extend_from_slice(&SNAPSHOT_VERSION.to_le_bytes());
        out.extend_from_slice(&(self.scratch_addr as u32).to_le_bytes());
        out.extend_from_slice(&(self.scratch_len as u32).to_le_bytes());
        out.extend_from_slice(&(self.workers as u32).to_le_bytes());
        out.extend_from_slice(&(mem_len as u32).to_le_bytes());
        out.extend_from_slice(mem);
        Ok(out)
    }
}

// ---------- Control channel (structured host ops) ----------

/// `EAGAIN` — a control-channel fs op that resolves through a host-backed mount returns
/// `-EAGAIN` while the driver call is in flight. The kernel does not pump from a ctl call,
/// so the host retries, ticking between tries so the cooperative scheduler can advance the
/// driver's host call.
const EAGAIN: i32 = 6;

/// A ctl op can yield (`-EAGAIN`) across a host-backed mount. Drive at most this many
/// tick/retry rounds before giving up — generous, since a healthy driver answers within a
/// tick or two; a stuck driver becomes a clean error rather than an infinite loop.
const CTL_RETRY_TICKS: usize = 10_000;

fn ctl_err(op: &str, arg: &str, code: i32) -> anyhow::Error {
    anyhow!("control-channel {} '{}' failed (errno {})", op, arg, -code)
}

impl KernelHost {
    /// Size the control buffer to at least `len` and return its base address in linear
    /// memory.
    fn ctl_buf(&mut self, len: i32) -> Result<usize> {
        let f = self.exports.require_ctl_buf()?;
        let ptr = wt(f.call(&mut self.store, len), "mc_ctl_buf")?;
        Ok(ptr as usize)
    }

    /// Write `bytes` into the control buffer at offset 0. The kernel addresses the buffer
    /// by offset, so requests are always laid out from 0.
    fn ctl_put(&mut self, bytes: &[u8]) -> Result<()> {
        let base = self.ctl_buf(bytes.len() as i32)?;
        let data = self.memory.data_mut(&mut self.store);
        let end = base
            .checked_add(bytes.len())
            .filter(|e| *e <= data.len())
            .ok_or_else(|| anyhow!("control buffer out of range"))?;
        data[base..end].copy_from_slice(bytes);
        Ok(())
    }

    /// Read `len` bytes back out of the control buffer (offset 0).
    fn ctl_get(&mut self, len: usize) -> Result<Vec<u8>> {
        let base = self.ctl_buf(0)?;
        let data = self.memory.data(&self.store);
        let end = base
            .checked_add(len)
            .filter(|e| *e <= data.len())
            .ok_or_else(|| anyhow!("control buffer read out of range"))?;
        Ok(data[base..end].to_vec())
    }

    /// Run one ctl `attempt` (which lays out its request and calls the export), retrying
    /// while it returns `-EAGAIN` and ticking the kernel between tries so a host-backed
    /// mount's in-flight driver call can resolve. `attempt` takes `&mut Self` so it can
    /// re-`ctl_put` its request each round — a tick never touches the control buffer, but
    /// re-laying it is cheap and robust.
    fn ctl_with_retry(&mut self, mut attempt: impl FnMut(&mut Self) -> Result<i32>) -> Result<i32> {
        for _ in 0..CTL_RETRY_TICKS {
            let n = attempt(self)?;
            if n == -EAGAIN {
                self.tick()?;
                continue;
            }
            return Ok(n);
        }
        Err(anyhow!(
            "control-channel op stuck on EAGAIN after {CTL_RETRY_TICKS} ticks (a host mount driver may be hung)"
        ))
    }

    /// Read a file in full through the control channel.
    pub fn read_file(&mut self, path: &str) -> Result<Vec<u8>> {
        let f = self.exports.require_ctl_read()?;
        let n = self.ctl_with_retry(|s| {
            s.ctl_put(path.as_bytes())?;
            wt(f.call(&mut s.store, (0, path.len() as i32)), "mc_ctl_read")
        })?;
        if n < 0 {
            return Err(ctl_err("read_file", path, n));
        }
        self.ctl_get(n as usize)
    }

    /// Write (truncating) a file through the control channel.
    pub fn write_file(&mut self, path: &str, data: &[u8]) -> Result<()> {
        let f = self.exports.require_ctl_write()?;
        let n = self.ctl_with_retry(|s| {
            let mut req = Vec::with_capacity(path.len() + data.len());
            req.extend_from_slice(path.as_bytes());
            req.extend_from_slice(data);
            s.ctl_put(&req)?;
            wt(
                f.call(&mut s.store, (0, path.len() as i32, path.len() as i32, data.len() as i32)),
                "mc_ctl_write",
            )
        })?;
        if n < 0 {
            return Err(ctl_err("write_file", path, n));
        }
        Ok(())
    }

    /// List a directory.
    pub fn readdir(&mut self, path: &str) -> Result<Vec<DirEntry>> {
        let f = self.exports.require_ctl_readdir()?;
        let n = self.ctl_with_retry(|s| {
            s.ctl_put(path.as_bytes())?;
            wt(f.call(&mut s.store, (0, path.len() as i32)), "mc_ctl_readdir")
        })?;
        if n < 0 {
            return Err(ctl_err("readdir", path, n));
        }
        let raw = self.ctl_get(n as usize)?;
        let mut out = Vec::new();
        let mut i = 0;
        while i < raw.len() {
            let rel = raw[i..]
                .iter()
                .position(|&b| b == 0)
                .ok_or_else(|| anyhow!("malformed readdir entry"))?;
            let nul = i + rel;
            let name = String::from_utf8_lossy(&raw[i..nul]).into_owned();
            let kind = *raw.get(nul + 1).ok_or_else(|| anyhow!("truncated readdir entry"))?;
            out.push(DirEntry {
                name,
                is_dir: kind == b'd',
                is_symlink: kind == b'l',
            });
            i = nul + 2;
        }
        Ok(out)
    }

    /// Stat a path (the link itself for a symlink — lstat semantics).
    pub fn stat(&mut self, path: &str) -> Result<FileStat> {
        let f = self.exports.require_ctl_stat()?;
        let n = self.ctl_with_retry(|s| {
            s.ctl_put(path.as_bytes())?;
            wt(f.call(&mut s.store, (0, path.len() as i32)), "mc_ctl_stat")
        })?;
        if n < 0 {
            return Err(ctl_err("stat", path, n));
        }
        let raw = self.ctl_get(16)?;
        let size = u64::from_le_bytes(raw[0..8].try_into().unwrap());
        let kind = u32::from_le_bytes(raw[8..12].try_into().unwrap());
        let nlink = u32::from_le_bytes(raw[12..16].try_into().unwrap());
        Ok(FileStat {
            size,
            is_dir: kind == 1,
            is_symlink: kind == 2,
            nlink,
        })
    }

    /// Create a directory through the control channel.
    pub fn mkdir(&mut self, path: &str) -> Result<()> {
        let f = self.exports.require_ctl_mkdir()?;
        let n = self.ctl_with_retry(|s| {
            s.ctl_put(path.as_bytes())?;
            wt(f.call(&mut s.store, (0, path.len() as i32)), "mc_ctl_mkdir")
        })?;
        if n < 0 {
            return Err(ctl_err("mkdir", path, n));
        }
        Ok(())
    }

    /// Remove a file or empty directory through the control channel.
    pub fn unlink(&mut self, path: &str) -> Result<()> {
        let f = self.exports.require_ctl_unlink()?;
        let n = self.ctl_with_retry(|s| {
            s.ctl_put(path.as_bytes())?;
            wt(f.call(&mut s.store, (0, path.len() as i32)), "mc_ctl_unlink")
        })?;
        if n < 0 {
            return Err(ctl_err("unlink", path, n));
        }
        Ok(())
    }

    /// Create a symbolic link at `link` with target text `target`. The control buffer holds
    /// the target then the link (the two-region layout `write_file` uses).
    pub fn symlink(&mut self, target: &str, link: &str) -> Result<()> {
        let f = self.exports.require_ctl_symlink()?;
        let n = self.ctl_with_retry(|s| {
            let mut req = Vec::with_capacity(target.len() + link.len());
            req.extend_from_slice(target.as_bytes());
            req.extend_from_slice(link.as_bytes());
            s.ctl_put(&req)?;
            wt(
                f.call(&mut s.store, (0, target.len() as i32, target.len() as i32, link.len() as i32)),
                "mc_ctl_symlink",
            )
        })?;
        if n < 0 {
            return Err(ctl_err("symlink", link, n));
        }
        Ok(())
    }

    /// Mount a host-backed driver at `path` (reached over `mc_host_call` under a handler
    /// name equal to `path`). `read_only` mounts it read-only. Visible to every subsequent
    /// `exec` and to the structured fs ops.
    pub fn mount(&mut self, path: &str, read_only: bool) -> Result<()> {
        let f = self.exports.require_ctl_mount()?;
        self.ctl_put(path.as_bytes())?;
        let n = wt(
            f.call(&mut self.store, (0, path.len() as i32, read_only as i32)),
            "mc_ctl_mount",
        )?;
        if n < 0 {
            return Err(ctl_err("mount", path, n));
        }
        Ok(())
    }

    /// Unmount a host-backed mount at `path`.
    pub fn unmount(&mut self, path: &str) -> Result<()> {
        let f = self.exports.require_ctl_unmount()?;
        self.ctl_put(path.as_bytes())?;
        let n = wt(f.call(&mut self.store, (0, path.len() as i32)), "mc_ctl_unmount")?;
        if n < 0 {
            return Err(ctl_err("unmount", path, n));
        }
        Ok(())
    }

    /// Begin a command without driving it to completion. Returns a job id; drive ticks
    /// yourself and call [`exec_poll`](Self::exec_poll) until it returns `Some`. A job
    /// survives `snapshot`/`restore`.
    pub fn exec_start(&mut self, cmd: &str) -> Result<i32> {
        let start = self.exports.require_ctl_exec_start()?;
        self.ctl_put(cmd.as_bytes())?;
        let job = wt(start.call(&mut self.store, cmd.len() as i32), "mc_ctl_exec_start")?;
        if job < 0 {
            return Err(ctl_err("exec", cmd, job));
        }
        Ok(job)
    }

    /// Poll a job from [`exec_start`](Self::exec_start). `None` while running;
    /// `Some(result)` once finished (the job is then freed).
    pub fn exec_poll(&mut self, job: i32) -> Result<Option<ExecResult>> {
        let poll = self.exports.require_ctl_exec_poll()?;
        let status = wt(poll.call(&mut self.store, job), "mc_ctl_exec_poll")?;
        if status == 1 {
            Ok(Some(self.read_exec_result()?))
        } else if status < 0 {
            Err(ctl_err("exec_poll", "job", status))
        } else {
            Ok(None)
        }
    }

    /// Stdout a *running* exec job has produced so far, without finalizing it (empty on a
    /// kernel lacking the peek export). Lets a caller tail a long-running command.
    pub fn exec_stdout_peek(&mut self, job: i32) -> Result<Vec<u8>> {
        let Some(peek) = self.exports.mc_ctl_exec_peek.clone() else {
            return Ok(Vec::new());
        };
        let len = wt(peek.call(&mut self.store, job), "mc_ctl_exec_peek")?;
        if len < 0 {
            return Err(anyhow!("exec_peek failed for job {job} ({len})"));
        }
        let base = self.ctl_buf(0)?;
        let data = self.memory.data(&self.store);
        let end = base
            .checked_add(len as usize)
            .filter(|e| *e <= data.len())
            .ok_or_else(|| anyhow!("exec_peek result out of range"))?;
        Ok(data[base..end].to_vec())
    }

    /// Abandon a running job, freeing it without reading its result.
    pub fn exec_cancel(&mut self, job: i32) -> Result<()> {
        let close = self.exports.require_ctl_exec_close()?;
        let _ = wt(close.call(&mut self.store, job), "mc_ctl_exec_close")?;
        Ok(())
    }

    /// Run `cmd` to completion, returning captured stdout/stderr and the real exit code.
    /// Drives ticks (pacing idle ticks so in-flight host I/O can resolve) up to `max_ticks`.
    pub fn exec(&mut self, cmd: &str, max_ticks: usize) -> Result<ExecResult> {
        let job = self.exec_start(cmd)?;
        for _ in 0..max_ticks {
            if let Some(r) = self.exec_poll(job)? {
                return Ok(r);
            }
            if !self.tick()? {
                if let Some(r) = self.exec_poll(job)? {
                    return Ok(r);
                }
                let _ = self.exec_cancel(job);
                return Err(anyhow!("kernel exited before exec '{}' completed", cmd));
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        let _ = self.exec_cancel(job);
        Err(anyhow!("exec '{}' did not finish within {} ticks", cmd, max_ticks))
    }

    fn read_exec_result(&mut self) -> Result<ExecResult> {
        let base = self.ctl_buf(0)?;
        let data = self.memory.data(&self.store);
        let hdr_end = base
            .checked_add(12)
            .filter(|e| *e <= data.len())
            .ok_or_else(|| anyhow!("exec result header truncated"))?;
        let exit_code = i32::from_le_bytes(data[base..base + 4].try_into().unwrap());
        let so_len = u32::from_le_bytes(data[base + 4..base + 8].try_into().unwrap()) as usize;
        let se_len = u32::from_le_bytes(data[base + 8..hdr_end].try_into().unwrap()) as usize;
        let so_start = base + 12;
        let se_start = so_start + so_len;
        let se_end = se_start + se_len;
        if se_end > data.len() {
            return Err(anyhow!("exec result body out of range"));
        }
        Ok(ExecResult {
            stdout: data[so_start..se_start].to_vec(),
            stderr: data[se_start..se_end].to_vec(),
            exit_code,
        })
    }

    /// Serialize the live CoW overlay into a content-addressed `.tar` layer (the `commit`
    /// primitive) — returns `(tar_bytes, "sha256:<hex>")`. Refuses while host egress is in
    /// flight, exactly like [`snapshot`](Self::snapshot). Errors on a kernel without the
    /// `mc_commit_layer` export.
    pub fn commit_layer(&mut self) -> Result<(Vec<u8>, String)> {
        if let Some(f) = self.exports.mc_inflight_egress.clone() {
            let n = wt(f.call(&mut self.store, ()), "mc_inflight_egress")?;
            if n > 0 {
                return Err(anyhow!(
                    "cannot commit: {n} host-egress operation(s) in flight; quiesce first"
                ));
            }
        }
        let f = self
            .exports
            .mc_commit_layer
            .clone()
            .ok_or_else(|| anyhow!("kernel lacks mc_commit_layer (commit unsupported)"))?;
        let n = wt(f.call(&mut self.store, ()), "mc_commit_layer")?;
        if n < 0 {
            return Err(anyhow!("commit_layer failed ({n})"));
        }
        let tar = self.ctl_get(n as usize)?;
        let mut hasher = Sha256::new();
        hasher.update(&tar);
        let digest = alloc_hex(&hasher.finalize());
        Ok((tar, digest))
    }
}

/// Lowercase `sha256:<hex>` digest of a 32-byte hash.
fn alloc_hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(7 + bytes.len() * 2);
    s.push_str("sha256:");
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

/// Frame an ordered layer stack for `mc_load_base_image`: `"MCLS" [u32 count]
/// ([u32 len][bytes])…` (little-endian). The kernel's `parse_layers` reverses it.
fn frame_layers(layers: &[Vec<u8>]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(b"MCLS");
    out.extend_from_slice(&(layers.len() as u32).to_le_bytes());
    for l in layers {
        out.extend_from_slice(&(l.len() as u32).to_le_bytes());
        out.extend_from_slice(l);
    }
    out
}
