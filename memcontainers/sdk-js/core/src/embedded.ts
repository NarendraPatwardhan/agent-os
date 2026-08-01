// Embedded backend: the kernel runs in-process via the Bun/JS host. A single
// pump loop owns ALL ticking — it advances the kernel, resolves finished `exec`
// jobs, and (through the fan-out stdout sink) streams the interactive shell.
// Centralizing ticking means concurrent exec + shell never double-drive or race
// (JS is single-threaded; structured ops run between the pump's ticks).

import {
  EagainError,
  RUNNABLE_BURST_TICKS,
  TickState,
  releaseCompiledKernelModule,
} from "@mc/host";
import type { KernelHost, MapHostCall, StreamSink } from "@mc/host";
import type { Backend, RawAutocompleteResult, RawExecResult } from "./backend.js";
import type { SidecarBackend } from "./sidecars.js";
import { makeFs } from "./fs.js";
import { dispatchMount } from "./mount.js";
import { assertSessionAgentType, sessionExec } from "./session.js";
import { assertSafeToolBindingName, runToolJson } from "./tools.js";
import type {
  DirEntry,
  Driver,
  ExecOptions,
  SessionEvent,
  SessionHandle,
  Shell,
  StatResult,
  ToolContext,
  ToolDefinition,
  VmStatus,
  ContentStore,
  SnapshotOptions,
  AutocompleteOptions,
} from "./types.js";
import { isGitFsDriver } from "./git/gitfs.js";

const enc = (s: string): Uint8Array => new TextEncoder().encode(s);
const dec = (b: Uint8Array): string => new TextDecoder().decode(b);

/** Emit each COMPLETE (`\n`-terminated) JSON line of the accumulated `bytes` past
 *  the `emitted` line count; returns the new line count. Shared by the live-session
 *  tail (the agent writes one framed JSON event per line). */
function emitSessionLines(
  bytes: Uint8Array,
  emitted: number,
  onEvent: (e: SessionEvent) => void,
): number {
  const lines = dec(bytes).split("\n");
  const complete = lines.length - 1; // the last element is the partial after \n
  for (let i = emitted; i < complete; i++) {
    const t = lines[i]!.trim();
    if (!t) continue;
    try {
      onEvent(JSON.parse(t) as SessionEvent);
    } catch {
      // non-event stdout (ignore)
    }
  }
  return complete;
}

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
const execStdinBytes = (stdin: ExecOptions["stdin"]): Uint8Array | undefined =>
  typeof stdin === "string" ? enc(stdin) : stdin;

/** Wall-clock deadline for a single structured fs op (or commit flush) across a
 *  host-backed mount before giving up. A wall-clock bound — not an iteration
 *  count — so a legitimately slow driver (a large S3 object over a slow link)
 *  isn't mistaken for a hung one; only a truly stuck driver hits it. */
const MOUNT_OP_DEADLINE_MS = 120_000;

/** A stdout sink that buffers (for history/replay) and fans live bytes out to
 *  shell listeners. */
export class FanoutSink implements StreamSink {
  private readonly chunks: Uint8Array[] = [];
  readonly listeners = new Set<(b: Uint8Array) => void>();

  write(bytes: Uint8Array): void {
    const copy = bytes.slice();
    this.chunks.push(copy);
    for (const l of this.listeners) l(copy);
  }

  history(): Uint8Array {
    let len = 0;
    for (const c of this.chunks) len += c.length;
    const out = new Uint8Array(len);
    let off = 0;
    for (const c of this.chunks) {
      out.set(c, off);
      off += c.length;
    }
    return out;
  }
}

/**
 * Per-job host stage accumulators for PERF-013 (only when host perf is enabled).
 * Shared pump ticks/pace are divided evenly across concurrent jobs so totals stay
 * comparable to the single-job Wasmtime driver (A3).
 */
type JobPerfTrace = {
  wall0: number;
  before: {
    kernelTicks: number;
    kernelRunnable: number;
    kernelWaiting: number;
    tasksSpawned: number;
    pipesCreated: number;
    moduleCacheHits: number;
    moduleCacheMisses: number;
    blockedPoll: number;
    blockedPipe: number;
    blockedWaitChild: number;
  };
  tickMs: number;
  paceMs: number;
  hostTicks: number;
  hostRunnable: number;
  hostWaiting: number;
};

/**
 * Host git engines bound for D17 snapshot/fork durable rebind.
 * MCSN never carries the ODB — engines checkpoint AGIT into a durable id/path.
 */
export type EmbeddedGitEngineBinding = {
  /** Guest gitfs mount path. */
  path: string;
  /** Durable backend id (e.g. `default:/workspace/repo`). */
  durableId: string;
  /** Optional DiskDurable directory when using disk. */
  durablePath?: string;
  /** Persist live repo as AGIT (best-effort when unborn / empty). */
  checkpoint(): Promise<void>;
  close(): Promise<void>;
};

export class EmbeddedBackend implements Backend {
  private running = true;
  private readonly resolvers = new Map<number, (r: RawExecResult) => void>();
  private readonly rejecters = new Map<number, (e: Error) => void>();
  /**
   * K21: gitfs mount paths attached on this VM (R63 multi-mount).
   * Same path may not be remounted while live; distinct paths are allowed.
   * Single-writer remains per engine (each path has its own GitEngine).
   */
  private readonly gitFsMountPaths = new Set<string>();
  /**
   * D17: experimental git engines with durable bindings.
   * Snapshot / pinBase checkpoint these before MCSN capture; restore reopens
   * the same durable id/path via CreateOptions.gitDurable.
   */
  private gitEngineBindings: EmbeddedGitEngineBinding[] = [];
  /** PERF-013 traces for in-flight exec jobs (A3 parity with driveExec). */
  private readonly jobPerf = new Map<number, JobPerfTrace>();
  /** Running agent sessions tailed by the pump (job → tail state). */
  private readonly sessions = new Map<
    number,
    { emitted: number; onEvent: (e: SessionEvent) => void; onEnd: () => void }
  >();
  private sessionSeq = 0;
  private readonly pumpDone: Promise<void>;
  private readonly toolContext: ToolContext = { fs: makeFs(this) };

  constructor(
    private readonly host: KernelHost,
    private readonly stdout: FanoutSink,
    private readonly tools: MapHostCall,
    readonly sidecars: SidecarBackend,
    /**
     * Bound full baseline for incremental capture (PERF-011). Prefer digest-only
     * binding to the content store so VMs share one CAS object; bytes are loaded
     * lazily on first incremental (or supplied on restore/pin).
     */
    private activeBase?: { digest?: string; bytes?: Uint8Array },
    private readonly snapshotStore?: ContentStore,
  ) {
    this.pumpDone = this.pump();
  }

  /**
   * Bind host git engines for snapshot-time durable checkpoint (D17 / K10).
   * Called once from makeEmbedded after engines load; replaces any prior list.
   */
  bindGitEngines(bindings: EmbeddedGitEngineBinding[]): void {
    this.gitEngineBindings = [...bindings];
  }

  /** Recorded durable git id/path bindings (empty when experimental git is off). */
  gitDurableBindings(): ReadonlyArray<{
    path: string;
    durableId: string;
    durablePath?: string;
  }> {
    return this.gitEngineBindings.map((b) => ({
      path: b.path,
      durableId: b.durableId,
      durablePath: b.durablePath,
    }));
  }

  /** Checkpoint all bound git engines (best-effort; unborn repos skip export). */
  private async checkpointGitEngines(): Promise<void> {
    for (const eng of this.gitEngineBindings) {
      try {
        await eng.checkpoint();
      } catch {
        // Empty / unborn: keep last good AGIT if any; never block MCSN.
      }
    }
  }

  /**
   * Explicit epoch pin (PERF-011): capture a full MCSN of the **current** live machine,
   * store it as a content-addressed object, and bind it as `active_base` for later
   * incrementals. Does not update the template index.
   * Retains **digest only** so the full lives in the CAS, not as a private VM copy.
   */
  async pinBase(): Promise<string> {
    if (!this.snapshotStore?.putSnapshotObject) {
      throw new Error("pinBase requires a content store with putSnapshotObject");
    }
    // D17: durable git ODB is host-side — checkpoint before MCSN baseline pin.
    await this.checkpointGitEngines();
    const full = await this.host.snapshot(true);
    const digest = await this.snapshotStore.putSnapshotObject(full);
    this.activeBase = { digest };
    return digest;
  }

  /** Whether this VM has a bound full baseline for incremental capture. */
  hasSnapshotBase(): boolean {
    return this.activeBase?.bytes !== undefined || this.activeBase?.digest !== undefined;
  }

  /**
   * Load baseline full bytes for one incremental capture.
   * Prefer CAS by digest (no long-lived private full on the VM). Ephemeral load only.
   */
  private async resolveActiveBase(): Promise<Uint8Array> {
    if (this.activeBase?.digest && this.snapshotStore?.snapshotObject) {
      return this.snapshotStore.snapshotObject(this.activeBase.digest);
    }
    if (this.activeBase?.bytes) return this.activeBase.bytes;
    throw new Error(
      "incremental snapshot requires a bound full baseline " +
        "(template, restore from full/incremental, or pinBase)",
    );
  }

  /** Register a host tool the VM can invoke through `/svc/tools`. The
   *  handler runs in this process and receives the parsed JSON args. */
  tool(def: ToolDefinition): void {
    assertSafeToolBindingName(def.name);
    this.tools.register(def.name, (argsJson: string, context) =>
      runToolJson(def, argsJson, { ...this.toolContext, signal: context.signal }),
    );
  }

  unregisterTool(name: string): void {
    this.tools.unregister(name);
  }

  serviceCall(name: string, req: Uint8Array): Promise<Uint8Array> {
    return this.host.svcCall(name, req);
  }

  private async pump(): Promise<void> {
    let runnableBurst = 0;
    while (this.running) {
      const trace = this.host.perfEnabled() && this.jobPerf.size > 0;
      const t0 = trace ? performance.now() : 0;
      let state: TickState;
      try {
        state = this.host.tick();
      } catch (e) {
        this.failAll(asError(e));
        this.running = false;
        break;
      }
      if (trace) {
        // Share host tick cost across concurrent jobs so serial-equivalent totals stay honest.
        const n = this.jobPerf.size;
        if (n > 0) {
          const tickMs = (performance.now() - t0) / n;
          for (const p of this.jobPerf.values()) {
            p.tickMs += tickMs;
            p.hostTicks += 1 / n;
            if (state === TickState.Runnable) p.hostRunnable += 1 / n;
            else if (state === TickState.Waiting) p.hostWaiting += 1 / n;
          }
        }
      }
      for (const job of [...this.resolvers.keys()]) {
        let done: RawExecResult | null = null;
        try {
          done = this.host.execPoll(job);
        } catch (e) {
          this.rejecters.get(job)?.(asError(e));
          this.resolvers.delete(job);
          this.rejecters.delete(job);
          this.jobPerf.delete(job);
          continue;
        }
        if (done) {
          this.finishJobPerf(job);
          this.resolvers.get(job)?.(done);
          this.resolvers.delete(job);
          this.rejecters.delete(job);
        }
      }
      // Tail running sessions: emit newly-completed stdout lines, then end on exit.
      for (const [job, t] of [...this.sessions]) {
        let peeked: Uint8Array;
        try {
          peeked = this.host.execStdoutPeek(job);
        } catch {
          peeked = new Uint8Array(0);
        }
        t.emitted = emitSessionLines(peeked, t.emitted, t.onEvent);
        let done: { stdout: Uint8Array } | null = null;
        try {
          done = this.host.execPoll(job);
        } catch {
          done = { stdout: new Uint8Array(0) };
        }
        if (done) {
          emitSessionLines(done.stdout, t.emitted, t.onEvent);
          this.sessions.delete(job);
          this.jobPerf.delete(job);
          t.onEnd();
        }
      }
      if (state === TickState.Exited) {
        this.running = false;
        this.failAll(new Error("VM exited"));
        break;
      }
      const busy =
        this.resolvers.size > 0 || this.sessions.size > 0 || this.stdout.listeners.size > 0;
      if (state === TickState.Runnable && busy && ++runnableBurst < RUNNABLE_BURST_TICKS) {
        continue;
      }
      if (state === TickState.Runnable) {
        runnableBurst = 0;
        await sleep(0);
      } else {
        runnableBurst = 0;
        const p0 = trace ? performance.now() : 0;
        await sleep(busy ? 1 : 15);
        if (trace) {
          const n = this.jobPerf.size;
          // Jobs may have completed during the sleep; only attribute when still traced.
          if (n > 0) {
            const pace = (performance.now() - p0) / n;
            for (const p of this.jobPerf.values()) p.paceMs += pace;
          }
        }
      }
    }
  }

  private beginJobPerf(job: number): void {
    if (!this.host.perfEnabled()) return;
    const k = this.host.readKernelPerfCounters();
    this.jobPerf.set(job, {
      wall0: performance.now(),
      before: {
        kernelTicks: k.kernelTicks,
        kernelRunnable: k.kernelRunnable,
        kernelWaiting: k.kernelWaiting,
        tasksSpawned: k.tasksSpawned,
        pipesCreated: k.pipesCreated,
        moduleCacheHits: k.moduleCacheHits,
        moduleCacheMisses: k.moduleCacheMisses,
        blockedPoll: k.blockedPoll,
        blockedPipe: k.blockedPipe,
        blockedWaitChild: k.blockedWaitChild,
      },
      tickMs: 0,
      paceMs: 0,
      hostTicks: 0,
      hostRunnable: 0,
      hostWaiting: 0,
    });
  }

  private finishJobPerf(job: number): void {
    const t = this.jobPerf.get(job);
    this.jobPerf.delete(job);
    if (!t || !this.host.perfEnabled()) return;
    const after = this.host.readKernelPerfCounters();
    this.host.publishCommandPerf({
      wallMs: performance.now() - t.wall0,
      tickMs: t.tickMs,
      paceMs: t.paceMs,
      hostTicks: Math.round(t.hostTicks),
      hostRunnable: Math.round(t.hostRunnable),
      hostWaiting: Math.round(t.hostWaiting),
      kernelTicks: Math.max(0, after.kernelTicks - t.before.kernelTicks),
      kernelRunnable: Math.max(0, after.kernelRunnable - t.before.kernelRunnable),
      kernelWaiting: Math.max(0, after.kernelWaiting - t.before.kernelWaiting),
      tasksSpawned: Math.max(0, after.tasksSpawned - t.before.tasksSpawned),
      pipesCreated: Math.max(0, after.pipesCreated - t.before.pipesCreated),
      moduleCacheHits: Math.max(0, after.moduleCacheHits - t.before.moduleCacheHits),
      moduleCacheMisses: Math.max(0, after.moduleCacheMisses - t.before.moduleCacheMisses),
      blockedPoll: Math.max(0, after.blockedPoll - t.before.blockedPoll),
      blockedPipe: Math.max(0, after.blockedPipe - t.before.blockedPipe),
      blockedWaitChild: Math.max(0, after.blockedWaitChild - t.before.blockedWaitChild),
      kernelMemoryLen: after.kernelMemoryLen,
    });
  }

  private failAll(err: Error): void {
    for (const reject of this.rejecters.values()) reject(err);
    this.resolvers.clear();
    this.rejecters.clear();
    this.jobPerf.clear();
  }

  private async completeExec(start: () => number): Promise<RawExecResult> {
    if (!this.running) throw new Error("VM closed");
    let job: number;
    try {
      job = start();
    } catch (e) {
      throw asError(e);
    }
    this.beginJobPerf(job);
    const result = await new Promise<RawExecResult>((resolve, reject) => {
      this.resolvers.set(job, resolve);
      this.rejecters.set(job, reject);
    });
    // Flush any host-backed mount writes the command made (committed on close,
    // asynchronously) so they are durable once `exec` resolves. A no-op when the
    // command touched no mount.
    await this.drainCommits();
    return result;
  }

  async exec(cmd: string, opts: ExecOptions = {}): Promise<RawExecResult> {
    return this.completeExec(() =>
      this.host.execStart(cmd, {
        cwd: opts.cwd,
        env: opts.env,
        stdin: execStdinBytes(opts.stdin),
      }),
    );
  }

  async run(
    program: string,
    args: readonly string[] = [],
    opts: ExecOptions = {},
  ): Promise<RawExecResult> {
    return this.completeExec(() =>
      this.host.runStart(program, args, {
        cwd: opts.cwd,
        env: opts.env,
        stdin: execStdinBytes(opts.stdin),
      }),
    );
  }

  async autocomplete(
    source: Uint8Array,
    cursor: number,
    opts: Omit<AutocompleteOptions, "cursor"> = {},
  ): Promise<RawAutocompleteResult> {
    return this.withMountRetry(() =>
      this.host.autocomplete(source, cursor, {
        cwd: opts.cwd,
        env: opts.env,
        limit: opts.limit,
      }),
    );
  }

  /** A live agent session: runs the validated guest agent with the prompt path
   *  passed through a typed exec env var, and streams its framed
   *  events as the pump tails the running exec (via the kernel exec-peek). on()
   *  fires as events arrive; prompt() resolves when the agent exits. */
  liveSession(agentType: string): SessionHandle {
    assertSessionAgentType(agentType);
    const id = `s${++this.sessionSeq}`;
    const listeners = new Set<(e: SessionEvent) => void>();
    const backend = this;
    return {
      id,
      on(cb: (e: SessionEvent) => void): () => void {
        listeners.add(cb);
        return () => {
          listeners.delete(cb);
        };
      },
      async prompt(text: string): Promise<SessionEvent[]> {
        if (!backend.running) throw new Error("VM closed");
        const promptFile = `/tmp/.mc-session-${id}`;
        await backend.write(promptFile, enc(text));
        const events: SessionEvent[] = [];
        const onEvent = (e: SessionEvent): void => {
          events.push(e);
          for (const l of listeners) l(e);
        };
        const { program, args, opts } = sessionExec(agentType, promptFile);
        const job = backend.host.runStart(program, args, {
          cwd: opts.cwd,
          env: opts.env,
          stdin: execStdinBytes(opts.stdin),
        });
        await new Promise<void>((resolve) => {
          backend.sessions.set(job, { emitted: 0, onEvent, onEnd: resolve });
        });
        return events;
      },
    };
  }

  /** Run a structured fs op, retrying while it would block on a host-backed mount
   *  (`EagainError`). The op's driver call resolves on the JS event loop, which a
   *  `sleep(0)` yields to (and the pump advances) between tries; the kernel dedups
   *  the in-flight call by caller, so a retry collects it rather than re-issuing. */
  private async withMountRetry<T>(op: () => T): Promise<T> {
    const deadline = Date.now() + MOUNT_OP_DEADLINE_MS;
    for (;;) {
      try {
        return op();
      } catch (e) {
        if (e instanceof EagainError && Date.now() < deadline) {
          await sleep(0);
          continue;
        }
        if (e instanceof EagainError) {
          throw new Error("structured fs op stuck on a host mount (driver may be hung)");
        }
        throw e;
      }
    }
  }

  /** Drive ticks until parked mount write-commits drain — used after a mount
   *  write so the commit (`MountFs` flushes writes on close) has actually reached
   *  the driver before `write` resolves. Bounded; a no-op when nothing is parked.
   *  Keyed on the dedicated pending-commit count, NOT global egress, so durability
   *  doesn't wait on unrelated in-flight egress (an open WebSocket / a fetch). */
  private async drainCommits(deadlineMs = MOUNT_OP_DEADLINE_MS): Promise<void> {
    const deadline = Date.now() + deadlineMs;
    while (this.host.pendingCommits() > 0 && Date.now() < deadline) {
      // Stop early if the VM has exited — its commits can't drain, so don't spin
      // to the deadline (this is what keeps close() from hanging on a dead VM).
      if (this.host.tick() === TickState.Exited) break;
      await sleep(0);
    }
  }

  async read(path: string): Promise<Uint8Array> {
    return this.withMountRetry(() => this.host.readFile(path));
  }
  async write(path: string, data: Uint8Array): Promise<void> {
    await this.withMountRetry(() => this.host.writeFile(path, data));
    // A mount commits writes on close (asynchronously); flush so the write is
    // durable once this resolves. Non-mount writes park nothing (no wait).
    await this.drainCommits();
  }
  async ls(path: string): Promise<DirEntry[]> {
    return this.withMountRetry(() => this.host.readdir(path));
  }
  async stat(path: string): Promise<StatResult> {
    return this.withMountRetry(() => this.host.stat(path));
  }
  async readlink(path: string): Promise<string> {
    return this.withMountRetry(() => this.host.readlink(path));
  }
  async mkdir(path: string): Promise<void> {
    await this.withMountRetry(() => this.host.mkdir(path));
  }
  async rm(path: string): Promise<void> {
    await this.withMountRetry(() => this.host.unlink(path));
  }
  async chmod(path: string, mode: number): Promise<void> {
    await this.withMountRetry(() => this.host.chmod(path, mode));
  }
  async symlink(target: string, link: string): Promise<void> {
    await this.withMountRetry(() => this.host.symlink(target, link));
  }

  /** Install a host-backed driver at `path`: register the driver as a binary-safe
   *  host-call handler keyed by the mount path, then mount a `MountFs` there.
   *  K21/R63: one gitfs driver **per path**; distinct paths may each carry gitfs.
   *  Remounting gitfs at an already-live path fails closed. */
  async mount(path: string, driver: Driver, readOnly: boolean): Promise<void> {
    if (isGitFsDriver(driver)) {
      if (this.gitFsMountPaths.has(path)) {
        throw new Error(
          `gitfs already mounted at ${path}; one gitfs engine per mount path (K21)`,
        );
      }
      this.gitFsMountPaths.add(path);
    }
    this.tools.registerRaw(path, (body) => dispatchMount(driver, body));
    this.host.mount(path, readOnly || !!driver.readOnly);
  }
  async unmount(path: string): Promise<void> {
    this.host.unmount(path);
    this.tools.unregister(path);
    this.gitFsMountPaths.delete(path);
  }
  async snapshot(opts: SnapshotOptions = {}): Promise<Uint8Array> {
    // D17 / K10: record durable git id/path content (AGIT) before MCSN.
    // Restored VMs re-open the same CreateOptions.gitDurable id/path and rebind.
    await this.checkpointGitEngines();
    if ((opts.mode ?? "full") === "full") return this.host.snapshot();
    if (!this.snapshotStore?.putSnapshotObject || !this.snapshotStore.snapshotObject) {
      throw new Error("incremental snapshots require a content store with snapshot-object support");
    }
    // PERF-011: never invent a full on incremental. Base must already be bound
    // (template at create, restore, or pinBase).
    const base = await this.resolveActiveBase();
    // Ensure CAS has the object (no-op if already stored under this content digest).
    const digest = await this.snapshotStore.putSnapshotObject(base);
    // Prefer digest-only binding after the first successful CAS put (density).
    this.activeBase = { digest };
    return this.host.snapshotIncremental(base);
  }
  async commitLayer(): Promise<{ digest: string; tar: Uint8Array }> {
    if (!this.running) throw new Error("VM closed");
    return this.host.commitLayer();
  }
  async inflightEgress(): Promise<number> {
    return this.host.inflightEgress();
  }

  memoryBytes(): number {
    return this.host.vmMemoryBytes();
  }

  async status(): Promise<VmStatus> {
    return {
      running: this.running && this.host.exitCode() === null,
      memoryBytes: this.host.vmMemoryBytes(),
      inflightEgress: this.host.inflightEgress(),
    };
  }

  shell(): Shell {
    const sink = this.stdout;
    const host = this.host;
    return {
      on(cb: (bytes: Uint8Array) => void): () => void {
        sink.listeners.add(cb);
        return () => {
          sink.listeners.delete(cb);
        };
      },
      write(data: string | Uint8Array): void {
        host.sendInput(typeof data === "string" ? new TextEncoder().encode(data) : data);
      },
      history(): Uint8Array {
        return sink.history();
      },
    };
  }

  async close(): Promise<void> {
    // Flush any parked mount write-commits before tearing down the pump, so a
    // write issued just before close() still reaches its driver. Best-effort with
    // a short deadline — teardown must not hang on a slow/stuck driver.
    try {
      await this.drainCommits(5_000);
    } catch {
      /* best-effort on teardown */
    }
    await this.sidecars.close();
    this.running = false;
    await this.pumpDone;
    // PERF-011: drop one Module cache retain so the last closed VM can free the compile.
    try {
      releaseCompiledKernelModule(this.host.kernelDigestBytes());
    } catch {
      /* best-effort */
    }
    this.activeBase = undefined;
  }
}

function asError(e: unknown): Error {
  return e instanceof Error ? e : new Error(String(e));
}
