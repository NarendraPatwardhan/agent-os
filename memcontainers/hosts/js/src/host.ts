import {
  EXPORTS,
  decodeDirEntries,
  decodeExecOutcome,
  decodeFileStat,
  decodeSvcResponse,
  encodeExecRequest,
  encodeSvcRequest,
} from "@mc/contracts/ctl";
import { EAGAIN, MAX_WORKERS } from "@mc/contracts/constants";
import {
  SNAPSHOT_HEADER_LEN,
  SNAPSHOT_PAGE_SIZE,
  parseSnapshot,
  snapshotBitmapLen,
  writeSnapshotHeader,
  type SnapshotView,
} from "@mc/contracts/snapshot";
import { Mem } from "./memory.js";
import { makeBridge, type HostState } from "./bridge.js";
import { processStdout, processStderr } from "./io.js";
import { SystemClock, FixedClock, OsRng, SeededRng } from "./sources.js";
import { DeniedNet } from "./net.js";
import { DeniedPersist } from "./persist_core.js";
import { DeniedHostCall } from "./host_call.js";
import type { HostCallCapability } from "./host_call.js";
import type {
  StreamSink,
  ClockSource,
  RngSource,
  NetCapability,
  PersistCapability,
} from "./types.js";

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

// The kernel's control-export surface, DERIVED from the generated contract (ctl.gen.ts `EXPORTS`) — no
// hand-written ABI (B2), so the host's typed call sites can't desync from the contract. A wasm
// i32/u32/cptr/mptr/len arg or ret is a JS `number`; a `void` ret is void; arity comes from the row's
// `args`. Each export is optional because a given kernel build omits some (a cooperative kernel has no
// `mc_quiesce_*`, an imageless one no exec) — except the mandatory trio, promoted to required for
// ergonomic call sites and asserted present by `checkControlExports`.
type WasmRet<R> = R extends "void" ? void : number;
type WasmArgs<A extends readonly unknown[]> = { -readonly [K in keyof A]: number };
type ExportFn<Row extends { args: readonly unknown[]; ret: string }> = (
  ...args: WasmArgs<Row["args"]>
) => WasmRet<Row["ret"]>;
type ContractExports = { [Row in (typeof EXPORTS)[number] as Row["name"]]?: ExportFn<Row> };

// The mandatory trio the host cannot drive a kernel without (the rest gate on the kernel build).
const REQUIRED_EXPORTS = ["mc_init", "mc_tick", "mc_input", "mc_worker_count"] as const;
type RequiredExport = (typeof REQUIRED_EXPORTS)[number];

type KernelExports = { memory: WebAssembly.Memory } & Required<Pick<ContractExports, RequiredExport>> &
  Omit<ContractExports, RequiredExport>;

// Validate the booted kernel's control exports against the contract: every export it actually provides
// must match the contract's ARITY — a control.kdl signature change the kernel picked up surfaces HERE
// at startup (B2), not as a trap on the first call — and the mandatory trio must be present + callable.
function checkControlExports(raw: WebAssembly.Exports): void {
  const exports = raw as Record<string, unknown>;
  for (const row of EXPORTS) {
    const fn = exports[row.name];
    if (typeof fn === "function" && fn.length !== row.args.length) {
      throw new Error(
        `control export "${row.name}" has arity ${fn.length}, but the contract (ctl.gen.ts) declares ` +
          `${row.args.length} — the kernel artifact and the contract disagree`,
      );
    }
  }
  for (const name of REQUIRED_EXPORTS) {
    if (typeof exports[name] !== "function") {
      throw new Error(`kernel artifact is missing the required control export "${name}"`);
    }
  }
}

/** Result of a structured `exec` (control channel): captured streams plus the real exit code —
 *  mirrors the Rust host's `ExecResult`. */
export interface ExecResult {
  stdout: Uint8Array;
  stderr: Uint8Array;
  exitCode: number;
}

export interface ExecOptions {
  cwd?: string;
  env?: Record<string, string>;
  stdin?: Uint8Array;
}

/** A directory entry from `readdir`. */
export interface DirEntry {
  name: string;
  isDir: boolean;
  isSymlink: boolean;
}

const textDecoder = new TextDecoder();
const enc = (s: string): Uint8Array => new TextEncoder().encode(s);
const ctlErr = (op: string, arg: string, code: number): Error =>
  new Error(`control-channel ${op} '${arg}' failed (errno ${-code})`);

// `EAGAIN` (errno, from the generated contract — the single source of truth, NOT a local copy): a
// control-channel fs op that resolves through a host-backed mount (`MountFs`) returns `-EAGAIN` while
// the driver call is in flight. The kernel does not pump from a ctl call, so the caller must yield to
// the pump and retry. The low-level host surfaces this as {@link EagainError}; the retry loop lives in
// the backend, which owns the tick pump.

/** Thrown by the structured fs ops when a host-backed mount op would block. The embedded backend
 *  catches it, yields to the pump (so the driver promise resolves), and retries. */
export class EagainError extends Error {
  constructor(
    readonly op: string,
    readonly path: string,
  ) {
    super(`control-channel ${op} '${path}' would block (host mount in flight)`);
    this.name = "EagainError";
  }
}

/** Throw on a negative ctl return — `EagainError` for `-EAGAIN` (retryable), a plain error otherwise —
 *  and return the value when non-negative. */
const ctlCheck = (op: string, path: string, n: number): number => {
  if (n === -EAGAIN) throw new EagainError(op, path);
  if (n < 0) throw ctlErr(op, path, n);
  return n;
};

const sha256 = async (bytes: Uint8Array): Promise<Uint8Array> =>
  new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as Uint8Array<ArrayBuffer>));
const digestEqual = (a: Uint8Array, b: Uint8Array): boolean =>
  a.length === b.length && a.every((value, i) => value === b[i]);

async function validateSnapshot(
  snapshot: Uint8Array,
  base: Uint8Array | undefined,
  kernelDigest: Uint8Array,
): Promise<{ view: SnapshotView; baseView?: SnapshotView }> {
  const view = parseSnapshot(snapshot);
  if (!digestEqual(view.kernelDigest, kernelDigest)) {
    throw new Error("invalid snapshot: kernel_digest_mismatch");
  }
  if (view.kind === "full") {
    if (base) throw new Error("invalid snapshot: unexpected_base_snapshot");
    return { view };
  }
  if (!base) throw new Error("invalid snapshot: missing_base_snapshot");
  if (!digestEqual(await sha256(base), view.baseSnapshotDigest)) {
    throw new Error("invalid snapshot: base_snapshot_digest_mismatch");
  }
  const baseView = parseSnapshot(base);
  if (baseView.kind !== "full") throw new Error("invalid snapshot: incremental_base_not_full");
  if (!digestEqual(baseView.kernelDigest, kernelDigest)) {
    throw new Error("invalid snapshot: base_kernel_digest_mismatch");
  }
  if (!digestEqual(await sha256(baseView.pages), baseView.memoryDigest)) {
    throw new Error("invalid snapshot: base_memory_digest_mismatch");
  }
  if (baseView.memoryLen > view.memoryLen) throw new Error("invalid snapshot: memory_shrank");
  return { view, baseView };
}

/** Reconstruct directly in the already-sized wasm memory so restore never holds a second complete
 * memory image next to the module. */
async function applySnapshot(
  view: SnapshotView,
  baseView: SnapshotView | undefined,
  memory: Uint8Array,
): Promise<void> {
  if (memory.length !== view.memoryLen) {
    throw new Error("invalid snapshot: restored_memory_length_mismatch");
  }
  if (!baseView) {
    memory.set(view.pages);
  } else {
    memory.fill(0);
    memory.set(baseView.pages);
    let changed = 0;
    for (let page = 0; page < view.memoryLen / SNAPSHOT_PAGE_SIZE; page++) {
      if ((view.bitmap[page >>> 3]! & (1 << (page & 7))) === 0) continue;
      const start = page * SNAPSHOT_PAGE_SIZE;
      memory.set(view.pages.subarray(changed, changed + SNAPSHOT_PAGE_SIZE), start);
      changed += SNAPSHOT_PAGE_SIZE;
    }
    if (changed !== view.pages.length) throw new Error("invalid snapshot: changed_page_length");
  }
  if (!digestEqual(await sha256(memory), view.memoryDigest)) {
    throw new Error("invalid snapshot: memory_digest_mismatch");
  }
}

/** Frame an ordered layer stack for `mc_load_base_image`: `"MCLS" [u32 count] ([u32 len][bytes])…`
 *  (little-endian). The kernel's `parse_layers` reverses it. Mirrors the Rust host's `frame_layers`. */
function frameLayers(layers: Uint8Array[]): Uint8Array {
  let total = 8;
  for (const l of layers) total += 4 + l.length;
  const out = new Uint8Array(total);
  const dv = new DataView(out.buffer);
  out.set([0x4d, 0x43, 0x4c, 0x53], 0); // "MCLS"
  dv.setUint32(4, layers.length, true);
  let off = 8;
  for (const l of layers) {
    dv.setUint32(off, l.length, true);
    off += 4;
    out.set(l, off);
    off += l.length;
  }
  return out;
}

function contractI32(n: number): number {
  if (!Number.isFinite(n) || n <= 0) return 0;
  return Math.min(Math.trunc(n), 0x7fffffff);
}

function contractI64(n: number): number {
  if (!Number.isFinite(n) || n <= 0) return 0;
  return Math.min(Math.trunc(n), Number.MAX_SAFE_INTEGER);
}

/** Builds a {@link KernelHost} from kernel wasm bytes — a 1:1 mirror of the Rust `KernelHostBuilder`
 *  (`with_*` setters → `withX`). */
export class KernelHostBuilder {
  private baseImage: Uint8Array | null = null;
  private _bootTier = 0;
  private _bootBudgetMib = 0;
  private _bootBudgetFuel = 0;
  private _stdout: StreamSink = processStdout();
  private _stderr: StreamSink = processStderr();
  private _log: StreamSink = processStdout();
  private _clock: ClockSource = new SystemClock();
  private _rng: RngSource = new OsRng();
  private _net: NetCapability = new DeniedNet();
  private _persist: PersistCapability = new DeniedPersist();
  private _hostCall: HostCallCapability = new DeniedHostCall();
  private _workers = 0; // single-threaded JS host → cooperative

  constructor(private readonly wasm: Uint8Array) {}

  withBaseImage(image: Uint8Array | null): this {
    this.baseImage = image;
    return this;
  }

  /** The image manifest's runtime contract to enforce at boot. `tier` ordinal: 0=inherit / 1=full /
   *  2=read-write / 3=read-only / 4=isolated; `budgetMib`/`fuel` ≤ 0 = unset (kernel default). */
  withContract(tier: number, budgetMib: number, fuel: number): this {
    this._bootTier = contractI32(tier);
    this._bootBudgetMib = contractI32(budgetMib);
    this._bootBudgetFuel = contractI64(fuel);
    return this;
  }

  /** Boot from an ordered layer STACK (lowest→highest) — `CowFs(OverlayFs([TarFs…]))`. Multiple layers
   *  are framed (`MCLS`) into the single base-image payload; a LONE layer is passed raw so it takes the
   *  kernel's zero-copy move path (identical to `withBaseImage` / `CowFs(TarFs)`). Empty ⇒ no base
   *  image. */
  withLayers(layers: Uint8Array[]): this {
    this.baseImage =
      layers.length === 0 ? null : layers.length === 1 ? layers[0]! : frameLayers(layers);
    return this;
  }
  withStdout(sink: StreamSink): this {
    this._stdout = sink;
    return this;
  }
  withStderr(sink: StreamSink): this {
    this._stderr = sink;
    return this;
  }
  withLog(sink: StreamSink): this {
    this._log = sink;
    return this;
  }
  withClock(clock: ClockSource): this {
    this._clock = clock;
    return this;
  }
  withRng(rng: RngSource): this {
    this._rng = rng;
    return this;
  }
  withNet(net: NetCapability): this {
    this._net = net;
    return this;
  }
  withPersist(persist: PersistCapability): this {
    this._persist = persist;
    return this;
  }
  withHostCall(hostCall: HostCallCapability): this {
    this._hostCall = hostCall;
    return this;
  }
  withWorkers(workers: number): this {
    this._workers = workers;
    return this;
  }
  /** Deterministic replay: a fixed clock + seeded RNG (mirrors Rust `deterministic()`). */
  deterministic(): this {
    this._clock = new FixedClock();
    this._rng = new SeededRng();
    return this;
  }

  private newState(): HostState {
    return {
      mem: undefined as unknown as Mem, // set immediately after instantiate
      baseImage: this.baseImage,
      bootTier: this._bootTier,
      bootBudgetMib: this._bootBudgetMib,
      bootBudgetFuel: this._bootBudgetFuel,
      stdout: this._stdout,
      stderr: this._stderr,
      log: this._log,
      clock: this._clock,
      rng: this._rng,
      net: this._net,
      persist: this._persist,
      hostCall: this._hostCall,
      bytesWritten: 0,
      stdoutTail: [0, 0],
      exitCode: null,
      workers: this._workers,
      workersGranted: 0,
    };
  }

  async build(): Promise<KernelHost> {
    const kernelDigest = await sha256(this.wasm);
    const st = this.newState();
    const { instance } = await WebAssembly.instantiate(this.wasm, {
      env: makeBridge(st),
    });
    checkControlExports(instance.exports);
    const exports = instance.exports as unknown as KernelExports;
    st.mem = new Mem(exports.memory);

    // Reserve a scratch page for input BEFORE mc_init (so the kernel's first allocation already sees
    // the larger memory) — matches the Rust host.
    const prevPages = exports.memory.grow(1);
    const scratchAddr = prevPages * Mem.pageSize;

    // mc_init internally negotiates `mc_threads_init` and calls `mc_load_base_image` back into our
    // bridge.
    exports.mc_init();
    st.workersGranted = exports.mc_worker_count();
    if (st.workersGranted < 0 || st.workersGranted > MAX_WORKERS ||
        (st.workersGranted > 0 && !exports.mc_worker_entry)) {
      throw new Error("kernel returned invalid worker state after boot");
    }

    return new KernelHost(st, exports, scratchAddr, Mem.pageSize, kernelDigest);
  }

  /** Rebuild a host from a snapshot ({@link KernelHost.snapshot}) instead of booting: write the saved
   *  linear-memory image and do NOT call `mc_init` — the booted state IS the image. The restore/fork
   *  primitive (A8). Reuses the builder's wasm + capabilities + sinks; pass fresh capabilities so a
   *  restored VM never shares the original's host handles. */
  async restore(snapshot: Uint8Array, base?: Uint8Array): Promise<KernelHost> {
    const kernelDigest = await sha256(this.wasm);
    const { view, baseView } = await validateSnapshot(snapshot, base, kernelDigest);
    const st = this.newState();
    const { instance } = await WebAssembly.instantiate(this.wasm, {
      env: makeBridge(st),
    });
    checkControlExports(instance.exports);
    const exports = instance.exports as unknown as KernelExports;
    st.mem = new Mem(exports.memory);

    // Grow to the snapshot's size and write the image. No scratch grow and no mc_init: the image
    // already contains the scratch page and the booted state.
    const curBytes = exports.memory.buffer.byteLength;
    const scratchAddr = curBytes;
    const minimum = scratchAddr + SNAPSHOT_PAGE_SIZE;
    if (view.memoryLen < minimum) {
      throw new Error(`invalid snapshot: memory_too_small (need at least ${minimum}, have ${view.memoryLen})`);
    }
    if (view.memoryLen > curBytes) {
      try {
        exports.memory.grow((view.memoryLen - curBytes) / SNAPSHOT_PAGE_SIZE);
      } catch (error) {
        throw new Error(`invalid snapshot: memory_limit (${String(error)})`);
      }
    }
    if (exports.memory.buffer.byteLength !== view.memoryLen) {
      throw new Error("invalid snapshot: restored_memory_length_mismatch");
    }
    await applySnapshot(view, baseView, new Uint8Array(exports.memory.buffer));
    st.workersGranted = exports.mc_worker_count();
    if (st.workersGranted < 0 || st.workersGranted > MAX_WORKERS) {
      throw new Error("invalid snapshot: worker_count_out_of_range");
    }
    if (st.workersGranted > 0 && !exports.mc_worker_entry) {
      throw new Error("invalid snapshot: workers_without_worker_export");
    }

    return new KernelHost(st, exports, scratchAddr, SNAPSHOT_PAGE_SIZE, kernelDigest);
  }
}

/** A booted kernel instance. Mirrors the Rust `KernelHost` driving API
 *  (`tick`/`send_input`/`at_prompt`/`run_script`/…), camelCased. */
export class KernelHost {
  constructor(
    private readonly st: HostState,
    private readonly exports: KernelExports,
    private readonly scratchAddr: number,
    private readonly scratchLen: number,
    private readonly kernelDigest: Uint8Array,
  ) {}

  /** One cooperative step. Returns false once the kernel called `mc_exit`. */
  tick(): boolean {
    if (this.st.exitCode !== null) return false;
    try {
      this.exports.mc_tick();
    } catch (e) {
      // A `mc_exit` is `-> !` in the kernel, so the wasm may hit `unreachable` right after our bridge
      // records the code; treat that as a clean exit.
      if (this.st.exitCode !== null) return false;
      throw e;
    }
    this.driveWorkers();
    return this.st.exitCode === null;
  }

  private driveWorkers(): void {
    const worker = this.exports.mc_worker_entry;
    if (!worker) return; // cooperative artifact: no-op
    for (let w = 0; w < this.st.workersGranted; w++) {
      if (this.st.exitCode !== null) break;
      worker(w);
    }
  }

  /** Push input bytes (keystrokes / a scripted line) via the scratch page + `mc_input`, exactly like
   *  the Rust `send_input`. */
  sendInput(bytes: Uint8Array): void {
    for (let off = 0; off < bytes.length; off += this.scratchLen) {
      const chunk = bytes.subarray(off, Math.min(off + this.scratchLen, bytes.length));
      if (!this.st.mem.write(this.scratchAddr, chunk)) {
        throw new Error("input scratch out of range");
      }
      this.exports.mc_input(this.scratchAddr, chunk.length);
    }
  }

  /** True when the last two stdout bytes are `"$ "` (a settled shell prompt). */
  atPrompt(): boolean {
    return this.st.stdoutTail[0] === 0x24 && this.st.stdoutTail[1] === 0x20;
  }

  bytesWritten(): number {
    return this.st.bytesWritten;
  }

  /** Current size of the kernel's WASM linear memory, in bytes — the VM's whole RAM footprint
   *  (filesystem, processes, heap, every guest's wasmi store). Grows as Talc grows the heap, so sample
   *  it after boot and after work to see the peak. Re-read each call: `memory.grow` detaches the old
   *  buffer. */
  vmMemoryBytes(): number {
    return this.exports.memory.buffer.byteLength;
  }

  exitCode(): number | null {
    return this.st.exitCode;
  }

  /** Drive the kernel just until the login shell's first prompt — the moment the VM is interactive.
   *  Synchronous and budget-bounded, mirroring the Rust host's boot loop. Unlike `runScript` it does
   *  NOT wait out a quiescence settle, so boot resolves in ~one tick instead of paying ~320 ms of idle
   *  settle; there is no in-flight I/O to pace at boot. Returns the number of ticks driven. */
  bootToPrompt(maxTicks = 8_192): number {
    for (let n = 0; n < maxTicks; n++) {
      if (this.atPrompt()) return n;
      if (!this.tick()) return n + 1; // kernel exited before a prompt
    }
    return maxTicks;
  }

  /** Drive until the shell is at a settled prompt or `mc_exit`, pacing idle ticks so in-flight
   *  `fetch`/WS resolve (mirrors Rust `run_script`). A MACROTASK yield (`setTimeout`) — not a microtask
   *  — is required for the event loop to advance network I/O between ticks. */
  async runScript(maxTicks = 20_000): Promise<number> {
    const SETTLE_TICKS = 64; // ~320ms quiet at the prompt = done
    let settle = 0;
    let last = this.bytesWritten();
    for (let n = 0; n < maxTicks; n++) {
      if (!this.tick()) return n + 1;
      const now = this.bytesWritten();
      if (now !== last) {
        last = now;
        settle = 0;
        continue; // output produced — run at full speed
      }
      if (this.atPrompt()) {
        settle++;
        if (settle >= SETTLE_TICKS) return n + 1;
      }
      await sleep(5);
    }
    return maxTicks;
  }

  /** Drive until `idleTicksRequired` consecutive output-free ticks (for non-interactive scenarios;
   *  mirrors Rust `run_until_idle`). */
  async runUntilIdle(maxTicks: number, idleTicksRequired: number): Promise<number> {
    let last = this.bytesWritten();
    let idle = 0;
    for (let n = 0; n < maxTicks; n++) {
      if (!this.tick()) return n + 1;
      const now = this.bytesWritten();
      if (now === last) {
        if (++idle >= idleTicksRequired) return n + 1;
      } else {
        idle = 0;
        last = now;
      }
      await sleep(5);
    }
    return maxTicks;
  }

  // ---------- Control channel (structured host ops) ----------

  private ctlFn<T>(fn: T | undefined, name: string): T {
    if (!fn) throw new Error(`this kernel artifact lacks ${name}; rebuild the kernel`);
    return fn;
  }

  private ctlBuf(len: number): number {
    return this.ctlFn(this.exports.mc_ctl_buf, "mc_ctl_buf")(len);
  }

  /** Write a request into the control buffer at offset 0 (the kernel addresses the buffer by offset,
   *  so requests are laid out from 0). */
  private ctlPut(bytes: Uint8Array): void {
    const ptr = this.ctlBuf(bytes.length);
    if (!this.st.mem.write(ptr, bytes)) throw new Error("control buffer out of range");
  }

  /** Read `len` bytes back out of the control buffer (offset 0). */
  private ctlGet(len: number): Uint8Array {
    const ptr = this.ctlBuf(0);
    return this.st.mem.read(ptr, len);
  }

  /** Read a file in full through the control channel. */
  readFile(path: string): Uint8Array {
    const f = this.ctlFn(this.exports.mc_ctl_read, "mc_ctl_read");
    const p = enc(path);
    this.ctlPut(p);
    const n = ctlCheck("read_file", path, f(0, p.length));
    return this.ctlGet(n);
  }

  /** Read the target text of a symlink without following it. */
  readlink(path: string): string {
    const f = this.ctlFn(this.exports.mc_ctl_readlink, "mc_ctl_readlink");
    const p = enc(path);
    this.ctlPut(p);
    const n = ctlCheck("readlink", path, f(0, p.length));
    return textDecoder.decode(this.ctlGet(n));
  }

  /** Write (truncating) a file through the control channel. */
  writeFile(path: string, data: Uint8Array): void {
    const f = this.ctlFn(this.exports.mc_ctl_write, "mc_ctl_write");
    const p = enc(path);
    const req = new Uint8Array(p.length + data.length);
    req.set(p, 0);
    req.set(data, p.length);
    this.ctlPut(req);
    ctlCheck("write_file", path, f(0, p.length, p.length, data.length));
  }

  /** List a directory: `{ name, isDir, isSymlink }` entries. */
  readdir(path: string): DirEntry[] {
    const f = this.ctlFn(this.exports.mc_ctl_readdir, "mc_ctl_readdir");
    const p = enc(path);
    this.ctlPut(p);
    const n = ctlCheck("readdir", path, f(0, p.length));
    const listing = decodeDirEntries(this.ctlGet(n));
    return listing.entries.map((entry) => ({
      name: entry.name,
      isDir: entry.is_dir,
      isSymlink: entry.is_symlink,
    }));
  }

  /** Stat a path: `{ size, isDir, isSymlink, nlink, mode }` (the link itself for a symlink). */
  stat(path: string): { size: number; isDir: boolean; isSymlink: boolean; nlink: number; mode: number } {
    const f = this.ctlFn(this.exports.mc_ctl_stat, "mc_ctl_stat");
    const p = enc(path);
    this.ctlPut(p);
    const n = ctlCheck("stat", path, f(0, p.length));
    const stat = decodeFileStat(this.ctlGet(n));
    if (stat.size < 0) {
      throw new Error("malformed stat frame from kernel: negative size");
    }
    return {
      size: stat.size,
      isDir: stat.is_dir,
      isSymlink: stat.is_symlink,
      nlink: stat.nlink,
      mode: stat.mode,
    };
  }

  /** Create a directory through the control channel. */
  mkdir(path: string): void {
    const f = this.ctlFn(this.exports.mc_ctl_mkdir, "mc_ctl_mkdir");
    const p = enc(path);
    this.ctlPut(p);
    ctlCheck("mkdir", path, f(0, p.length));
  }

  /** Remove a file or empty directory through the control channel. */
  unlink(path: string): void {
    const f = this.ctlFn(this.exports.mc_ctl_unlink, "mc_ctl_unlink");
    const p = enc(path);
    this.ctlPut(p);
    ctlCheck("unlink", path, f(0, p.length));
  }

  /** Set POSIX permission bits through the control channel. */
  chmod(path: string, mode: number): void {
    const f = this.ctlFn(this.exports.mc_ctl_chmod, "mc_ctl_chmod");
    const p = enc(path);
    this.ctlPut(p);
    ctlCheck("chmod", path, f(0, p.length, mode));
  }

  /** Create a symbolic link at `link` with target text `target`. The control buffer holds the target
   *  then the link (the two-region layout `writeFile` uses). */
  symlink(target: string, link: string): void {
    const f = this.ctlFn(this.exports.mc_ctl_symlink, "mc_ctl_symlink");
    const t = enc(target);
    const l = enc(link);
    const req = new Uint8Array(t.length + l.length);
    req.set(t, 0);
    req.set(l, t.length);
    this.ctlPut(req);
    ctlCheck("symlink", link, f(0, t.length, t.length, l.length));
  }

  /** Mount a host-backed driver at `path` (the driver is reached over `mc_host_call` under a handler
   *  name equal to `path`). `readOnly` mounts it read-only. Visible to every subsequent `exec`/
   *  `session` and to `vm.fs.*`. */
  mount(path: string, readOnly: boolean): void {
    const f = this.ctlFn(this.exports.mc_ctl_mount, "mc_ctl_mount");
    const p = enc(path);
    this.ctlPut(p);
    ctlCheck("mount", path, f(0, p.length, readOnly ? 1 : 0));
  }

  /** Unmount a host-backed mount at `path`. */
  unmount(path: string): void {
    const f = this.ctlFn(this.exports.mc_ctl_unmount, "mc_ctl_unmount");
    const p = enc(path);
    this.ctlPut(p);
    ctlCheck("unmount", path, f(0, p.length));
  }

  /** Begin a command without driving it to completion; returns a job id. Drive ticks yourself and call
   *  {@link execPoll} until it returns a result. A job survives `snapshot`/`restore`, so a command
   *  begun in one VM can finish in a forked/rehydrated one. */
  execStart(cmd: string, opts: ExecOptions = {}): number {
    const start = this.ctlFn(this.exports.mc_ctl_exec_start, "mc_ctl_exec_start");
    const req = encodeExecRequest({
      cmd,
      cwd: opts.cwd,
      env: opts.env ?? {},
      stdin: opts.stdin,
    });
    this.ctlPut(req);
    const job = start(req.length);
    if (job < 0) throw ctlErr("exec", cmd, job);
    return job;
  }

  /** Poll a job from {@link execStart}. `null` while running; the result once finished (the job is then
   *  freed). */
  execPoll(job: number): ExecResult | null {
    const poll = this.ctlFn(this.exports.mc_ctl_exec_poll, "mc_ctl_exec_poll");
    const status = poll(job);
    if (status < 0) throw ctlErr("exec_poll", "job", status);
    return status > 0 ? this.readExecResult(status) : null;
  }

  /** Stdout a *running* job has produced so far, without finalizing it (empty if the kernel lacks the
   *  peek export). Lets a caller tail a long-running command — e.g. an agent session streaming framed
   *  events. */
  execStdoutPeek(job: number): Uint8Array {
    const peek = this.exports.mc_ctl_exec_peek;
    if (!peek) return new Uint8Array(0);
    const len = peek(job);
    if (len < 0) throw ctlErr("exec_peek", "job", len);
    const ptr = this.ctlBuf(0);
    return this.st.mem.read(ptr, len);
  }

  /** Abandon a running job, freeing it without reading its result. */
  execCancel(job: number): void {
    this.ctlFn(this.exports.mc_ctl_exec_close, "mc_ctl_exec_close")(job);
  }

  /** Begin a host-originated resident-service call. The service sees caller=SYSTEM_CALLER. */
  svcCallStart(name: string, req: Uint8Array): number {
    const start = this.ctlFn(this.exports.mc_ctl_svc_call_start, "mc_ctl_svc_call_start");
    const frame = encodeSvcRequest({ service: name, request: req });
    this.ctlPut(frame);
    const job = start(frame.length);
    if (job < 0) throw ctlErr("svc_call", name, job);
    return job;
  }

  /** Poll a host-originated resident-service call. `null` means the service is still working. */
  svcCallPoll(job: number): Uint8Array | null {
    const poll = this.ctlFn(this.exports.mc_ctl_svc_call_poll, "mc_ctl_svc_call_poll");
    const status = poll(job);
    if (status === 0) return null;
    if (status < 0) throw ctlErr("svc_call_poll", "job", status);
    return this.readSvcCallResult(status);
  }

  /** Abandon a host-originated resident-service call. */
  svcCallCancel(job: number): void {
    this.ctlFn(this.exports.mc_ctl_svc_call_close, "mc_ctl_svc_call_close")(job);
  }

  private readSvcCallResult(len: number): Uint8Array {
    const response = decodeSvcResponse(this.ctlGet(len));
    if (response.status !== 0) {
      throw new Error(`control-channel svc_call failed (errno ${response.status})`);
    }
    return response.body;
  }

  /** Run a host-originated resident-service call to completion. */
  async svcCall(name: string, req: Uint8Array, maxTicks = 20_000): Promise<Uint8Array> {
    const job = this.svcCallStart(name, req);
    for (let i = 0; i < maxTicks; i++) {
      const r = this.svcCallPoll(job);
      if (r) return r;
      if (!this.tick()) {
        const r2 = this.svcCallPoll(job);
        if (r2) return r2;
        this.svcCallCancel(job);
        throw new Error(`kernel exited before service call '${name}' completed`);
      }
      await sleep(1);
    }
    this.svcCallCancel(job);
    throw new Error(`service call '${name}' did not finish within ${maxTicks} ticks`);
  }

  /** Run `cmd` to completion: captured stdout/stderr + the real exit code. Drives ticks, yielding a
   *  macrotask between them so in-flight `fetch`/WS can resolve (mirrors the Rust host's `exec`). */
  async exec(cmd: string, opts: ExecOptions = {}, maxTicks = 20_000): Promise<ExecResult> {
    const job = this.execStart(cmd, opts);
    for (let i = 0; i < maxTicks; i++) {
      const r = this.execPoll(job);
      if (r) return r;
      if (!this.tick()) {
        const r2 = this.execPoll(job);
        if (r2) return r2;
        this.execCancel(job);
        throw new Error(`kernel exited before exec '${cmd}' completed`);
      }
      await sleep(1);
    }
    this.execCancel(job);
    throw new Error(`exec '${cmd}' did not finish within ${maxTicks} ticks`);
  }

  /** Number of host-egress operations (HTTP/WebSocket) currently in flight. A non-zero value means
   *  {@link snapshot} will refuse. `0` if the kernel lacks the export. */
  inflightEgress(): number {
    return this.exports.mc_inflight_egress ? this.exports.mc_inflight_egress() : 0;
  }

  /** Host-backed-mount write-commits parked but not yet acknowledged by their drivers. Poll this
   *  (driving ticks) to make a mount write durable without waiting on unrelated egress. `0` if the
   *  kernel lacks the export. */
  pendingCommits(): number {
    return this.exports.mc_pending_commits ? this.exports.mc_pending_commits() : 0;
  }

  /** Capture the entire VM as a portable byte blob (A8): the linear-memory image — all kernel and guest
   *  state — behind a small header. Refuses while a host-egress operation is in flight (its raw host
   *  handle would not survive a restore). Pair with {@link KernelHostBuilder.restore}. */
  async snapshot(): Promise<Uint8Array> {
    this.ensureSnapshotReady();
    // Hashing is asynchronous in JS. Freeze the linear-memory image before the first await so the
    // SDK pump cannot advance the kernel between hashing and copying the payload.
    const mem = new Uint8Array(this.exports.memory.buffer).slice();
    const header = writeSnapshotHeader(
      "full",
      mem.length,
      0,
      this.kernelDigest,
      await sha256(mem),
      new Uint8Array(32),
    );
    const out = new Uint8Array(header.length + mem.length);
    out.set(header);
    out.set(mem, header.length);
    return out;
  }

  /** Cumulative changed-page snapshot against one full baseline. Incrementals never chain. */
  async snapshotIncremental(base: Uint8Array): Promise<Uint8Array> {
    this.ensureSnapshotReady();
    const baseView = parseSnapshot(base);
    if (baseView.kind !== "full") throw new Error("incremental snapshot base must be full");
    if (!digestEqual(baseView.kernelDigest, this.kernelDigest)) {
      throw new Error("incremental snapshot base uses a different kernel");
    }
    if (!digestEqual(await sha256(baseView.pages), baseView.memoryDigest)) {
      throw new Error("incremental snapshot base memory digest mismatch");
    }
    // Keep the digest, bitmap, and page payload tied to one instant even while async hashing yields.
    const mem = new Uint8Array(this.exports.memory.buffer).slice();
    if (baseView.memoryLen > mem.length) throw new Error("incremental snapshot memory cannot shrink");
    const bitmap = new Uint8Array(snapshotBitmapLen(mem.length));
    const changed: Uint8Array[] = [];
    for (let page = 0; page < mem.length / SNAPSHOT_PAGE_SIZE; page++) {
      const start = page * SNAPSHOT_PAGE_SIZE;
      const current = mem.subarray(start, start + SNAPSHOT_PAGE_SIZE);
      const prior = start < baseView.memoryLen
        ? baseView.pages.subarray(start, start + SNAPSHOT_PAGE_SIZE)
        : undefined;
      let differs = prior === undefined;
      if (prior) {
        for (let i = 0; i < SNAPSHOT_PAGE_SIZE; i++) {
          if (current[i] !== prior[i]) { differs = true; break; }
        }
      } else {
        differs = current.some((b) => b !== 0);
      }
      if (differs) {
        bitmap[page >>> 3] |= 1 << (page & 7);
        changed.push(current.slice());
      }
    }
    const header = writeSnapshotHeader(
      "incremental",
      mem.length,
      changed.length,
      this.kernelDigest,
      await sha256(mem),
      await sha256(base),
    );
    const out = new Uint8Array(header.length + bitmap.length + changed.length * SNAPSHOT_PAGE_SIZE);
    out.set(header);
    out.set(bitmap, header.length);
    let off = header.length + bitmap.length;
    for (const page of changed) { out.set(page, off); off += page.length; }
    return out;
  }

  private ensureSnapshotReady(): void {
    const inflight = this.inflightEgress();
    if (inflight > 0) {
      throw new Error(
        `cannot snapshot: ${inflight} host-egress operation(s) in flight; quiesce first`,
      );
    }
  }

  /** Serialize the live CoW overlay into a content-addressed `.tar` layer (the `commit` primitive):
   *  `{ digest:"sha256:…", tar }`. Refuses while host egress is in flight, exactly like
   *  {@link snapshot}. */
  async commitLayer(): Promise<{ digest: string; tar: Uint8Array }> {
    const inflight = this.inflightEgress();
    if (inflight > 0) {
      throw new Error(`cannot commit: ${inflight} host-egress operation(s) in flight; quiesce first`);
    }
    const commit = this.exports.mc_commit_layer;
    if (!commit) throw new Error("kernel lacks mc_commit_layer (commit unsupported)");
    const len = commit();
    if (len < 0) throw new Error(`commit_layer failed (${len})`);
    const ptr = this.ctlBuf(0);
    const tar = this.st.mem.read(ptr, len).slice(); // copy out of linear memory
    const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", tar));
    let hex = "";
    for (const b of hash) hex += b.toString(16).padStart(2, "0");
    return { digest: `sha256:${hex}`, tar };
  }

  private readExecResult(len: number): ExecResult {
    const outcome = decodeExecOutcome(this.ctlGet(len));
    return {
      stdout: outcome.stdout,
      stderr: outcome.stderr,
      exitCode: outcome.exit_code,
    };
  }
}
