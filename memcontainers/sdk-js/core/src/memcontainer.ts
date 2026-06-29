// mc.create / restore / connect and the Vm surface, over the embedded (in-process) backend. The
// `"remote"` runtime (mc-server over the wire protocol) throws until mc-server is ported; the Vm
// surface is identical across backends, so it slots in later without changing this file's shape.

import {
  ConnectionRegistry,
  defaultCatalogCompiler,
  HostNet,
  KernelHostBuilder,
  MapHostCall,
  OpfsPersist,
} from "@mc/host";
import type { KernelHost, ToolApprovalFacts, ToolApprover } from "@mc/host";
// Boot-contract tier ordinals come from the generated contract — the single source of truth the
// kernel's `Tier` also derives from (contracts/constants.kdl → constants.gen.ts), never a local copy.
import {
  TIER_INHERIT,
  TIER_FULL,
  TIER_READ_WRITE,
  TIER_READ_ONLY,
  TIER_ISOLATED,
} from "@mc/contracts/constants";
import { EmbeddedBackend, FanoutSink } from "./embedded.js";
import { defaultImage, defaultKernel } from "./artifacts.js";
import { defaultStore } from "./store.js";
import { record } from "./record.js";
import { makeFs } from "./fs.js";
import { mergeToolCatalogBundles, toolCatalogBundle } from "./tools.js";
import {
  catalogToolSelectors,
  connectionToolCatalogBundle,
  deriveConnectionOrigins,
  hostToolDefinitions,
  resolvePolicyByConnection,
} from "./catalog.js";
import { startCron } from "./cron.js";
import type { CronAction, CronHandle, CronOptions } from "./cron.js";
import type { Backend } from "./backend.js";
import { RemoteBackend } from "./remote.js";
import type { ToolCatalogBundle } from "./tools.js";
import type {
  ContentStore,
  ConnectionDefinition,
  CreateOptions,
  DirEntry,
  Driver,
  ExecResult,
  ImageConfig,
  ImageManifest,
  MountSpec,
  SessionHandle,
  Shell,
  ToolDefinition,
  VmFs,
  VmStatus,
} from "./types.js";

const dec = (b: Uint8Array): string => new TextDecoder().decode(b);
const enc = (s: string): Uint8Array => new TextEncoder().encode(s);

/** POSIX single-quote an argv element so it survives the shell `vm.exec` runs. */
const shQuote = (s: string): string => `'${s.replace(/'/g, `'\\''`)}'`;

export type { VmFs } from "./types.js";

/** A booted memcontainers VM. One surface, embedded or remote. */
export class Vm {
  /** Filesystem ops (`vm.fs.read` / `write` / `ls` / `stat` / `mkdir` / `rm`). */
  readonly fs: VmFs;
  /** All registered tools (boot-time + runtime), mirrored into the `/svc/tools` live catalog. */
  private readonly registeredTools: ToolDefinition[];
  /** String entries from `create({ tools })`, used as connection group selectors. */
  private readonly registeredToolSelectors: string[];
  /** Host-backed mounts that must be re-registered when this VM is forked. */
  private readonly registeredMounts: MountSpec[];
  /** Tool alias names already handled for this VM (created or deliberately skipped). */
  private readonly handledToolAliases = new Set<string>();
  /** Live cron jobs, stopped on {@link Vm.close}. */
  private readonly cronJobs = new Set<CronHandle>();
  /** Monotonic counter for the temp files {@link Vm.luau} writes. */
  private luauSeq = 0;
  /** Cosmetic monotonic label carried in the index; NOT the concurrency primitive (the digest below
   *  is). The broker is idempotent by content digest, so this can never desync into a wrong decision. */
  private catalogGeneration = 0;
  /** The last index digest this VM committed — the compare-and-swap base for the next `catalog.apply`,
   *  so a runtime `vm.tool` cannot clobber a catalog that moved under it. */
  private catalogDigest = "";

  /** @internal — use {@link mc.create}. */
  constructor(
    private readonly backend: Backend,
    private readonly opts: CreateOptions,
  ) {
    this.fs = makeFs(backend);
    this.registeredTools = hostToolDefinitions(opts.tools);
    this.registeredToolSelectors = catalogToolSelectors(opts.tools);
    this.registeredMounts = [...(opts.mounts ?? [])];
    for (const name of toolAliasNames(this.registeredTools)) {
      if (isSafeToolAlias(name)) this.handledToolAliases.add(name);
    }
  }

  /** Run a command to completion: decoded stdout/stderr + the real exit code. */
  async exec(cmd: string): Promise<ExecResult> {
    const r = await this.backend.exec(cmd);
    return {
      stdout: dec(r.stdout),
      stderr: dec(r.stderr),
      stdoutBytes: r.stdout,
      stderrBytes: r.stderr,
      exitCode: r.exitCode,
    };
  }

  /** Run a Luau script (SYSTEMS.md §10.3). The source is written to a temp file
   *  and executed by `/bin/luau`, so multi-line programs and embedded quotes need
   *  no escaping (unlike `luau -e`). `args` reach the script as `arg`/`...`. The VM
   *  must run the `loom` flavor (or a domain pack built on it), which ships `/bin/luau`. */
  async luau(src: string, args: string[] = []): Promise<ExecResult> {
    const path = `/tmp/.mc-luau-${++this.luauSeq}.luau`;
    await this.backend.write(path, enc(src));
    const cmd = ["luau", path, ...args].map(shQuote).join(" ");
    return this.exec(cmd);
  }

  /** Open a live Luau session: a thin alias for `session("luau")`. Each
   *  `prompt(src)` runs `src` as a Luau script and streams the framed JSON events
   *  it emits via the `log` battery (`log.event{…}` / `log.info(…)`). */
  luauSession(): SessionHandle {
    return this.session("luau");
  }

  /** Capture the whole VM as a portable blob (A8). */
  snapshot(): Promise<Uint8Array> {
    return this.backend.snapshot();
  }

  /** Fork: snapshot + restore into a fresh, independent VM (same options). */
  async fork(): Promise<Vm> {
    const snap = await this.snapshot();
    return mc.restore(snap, this.opts);
  }

  /** The `commit` primitive: turn this VM's accrued state into a portable
   *  artifact. `asLayer()` serializes the CoW overlay (the diff since boot) into a
   *  content-addressed `.tar` layer — stack it under `mc.create({ image })`.
   *  `asSnapshot()` is the whole-VM memory image (== {@link snapshot}, A8). */
  commit(): {
    asLayer(): Promise<{ digest: string; tar: Uint8Array }>;
    asSnapshot(): Promise<Uint8Array>;
  } {
    return {
      asLayer: () => this.backend.commitLayer(),
      asSnapshot: () => this.snapshot(),
    };
  }

  /** Register one or more host-resident tools the agent inside the VM can invoke through
   *  `/svc/tools` and the Luau `tools` battery. The handler runs host-side. Build defs with
   *  {@link tool} / {@link kit}. The returned promise resolves only after the warm service has
   *  atomically accepted the new catalog. */
  async tool(def: ToolDefinition | ToolDefinition[]): Promise<void> {
    const defs = Array.isArray(def) ? def : [def];
    const previous = [...this.registeredTools];
    const next = [...this.registeredTools];
    for (const d of defs) {
      this.backend.tool(d);
      const existing = next.findIndex((t) => t.name === d.name);
      if (existing >= 0) next[existing] = d;
      else next.push(d);
    }
    try {
      const generation = this.catalogGeneration + 1;
      const digest = await applyToolCatalog(this.backend, this.opts, next, generation, this.catalogDigest);
      await seedToolAliases(this.backend, defs, this.handledToolAliases);
      this.catalogGeneration = generation;
      this.catalogDigest = digest;
    } catch (e) {
      for (const d of defs) {
        const prev = previous.find((t) => t.name === d.name);
        if (prev) this.backend.tool(prev);
        else this.backend.unregisterTool(d.name);
      }
      throw e;
    }
    this.registeredTools.splice(0, this.registeredTools.length, ...next);
    this.opts.tools = [...this.registeredToolSelectors, ...this.registeredTools];
  }

  /** Install a host-backed driver as a `FileSystem` at `path`. The driver
   *  runs host-side; reads/writes from inside the VM (`vm.exec`, the agent) and
   *  via `vm.fs.*` are proxied to it. Visible to subsequently-spawned tasks.
   *  Supported by embedded and served backends; served relays the driver over the
   *  per-VM control WebSocket. */
  async mount(path: string, driver: Driver, opts: { readOnly?: boolean } = {}): Promise<void> {
    const readOnly = opts.readOnly ?? driver.readOnly ?? false;
    await this.backend.mount(path, driver, readOnly);
    const spec = { path, driver, readOnly };
    const existing = this.registeredMounts.findIndex((m) => m.path === path);
    if (existing >= 0) this.registeredMounts[existing] = spec;
    else this.registeredMounts.push(spec);
    this.opts.mounts = [...this.registeredMounts];
  }

  /** Remove a host-backed mount installed by {@link Vm.mount}. */
  async unmount(path: string): Promise<void> {
    await this.backend.unmount(path);
    const existing = this.registeredMounts.findIndex((m) => m.path === path);
    if (existing >= 0) this.registeredMounts.splice(existing, 1);
    this.opts.mounts = [...this.registeredMounts];
  }

  /** Open an in-VM agent session (the internal agent loop). Returns a handle with
   *  `prompt(text)` and `on(event)` that streams the agent's framed events live as
   *  they're emitted (the backend tails the running agent via the kernel
   *  exec-peek). `agentType` is the `/bin` agent guest to run (default `"agent"`). */
  session(agentType = "agent"): SessionHandle {
    return this.backend.liveSession(agentType);
  }

  /** Schedule a recurring action against this VM. `schedule` is a
   *  5-field cron expression (e.g. every 30 min: `0,30 * * * *`), a macro
   *  (`"@hourly"`, `"@daily"`, `"@reboot"`), an interval (`"@every 30s"`,
   *  `"@every 1h30m"`), or a raw number of ms. `action` is `{ type:"exec", cmd }`,
   *  `{ type:"session", prompt }`, or a callback handed this VM. The timer runs
   *  host-side over the public surface (so it works on any backend) and fires as
   *  long as the VM handle lives; {@link Vm.close} stops every job. Returns a
   *  {@link CronHandle} (`stop()` / `next()` / `runs`). */
  cron(schedule: string | number, action: CronAction, opts: CronOptions = {}): CronHandle {
    const handle = startCron(this, schedule, action, opts, () => this.cronJobs.delete(handle));
    this.cronJobs.add(handle);
    return handle;
  }

  /** Open an interactive shell view (bytes in, bytes out). With
   *  `{ language: "luau" }` it drops the view into the `/bin/luau` REPL (a nested
   *  process over the boot `sh`; `exit`/Ctrl-D returns to the shell) — the
   *  programmatic counterpart to typing `luau` at the prompt. No web/hero-terminal
   *  change; this is the SDK surface (SYSTEMS.md §10.3). */
  shell(opts: { language?: "sh" | "luau" } = {}): Shell {
    const sh = this.backend.shell();
    if (opts.language === "luau") sh.write("luau\n");
    return sh;
  }

  /** A lightweight status snapshot (running, memory, in-flight egress). */
  status(): Promise<VmStatus> {
    return this.backend.status();
  }

  /** How many host-egress operations are in flight (a snapshot will refuse if
   *  non-zero). */
  inflightEgress(): Promise<number> {
    return this.backend.inflightEgress();
  }

  /** Current size of the VM's WASM linear memory, in bytes — the whole RAM
   *  footprint. `0` on a remote backend (not measurable over the wire). */
  memoryBytes(): number {
    return this.backend.memoryBytes();
  }

  /** Tear down the VM and stop its run loop (and any cron jobs). */
  close(): Promise<void> {
    for (const job of [...this.cronJobs]) job.stop();
    this.cronJobs.clear();
    return this.backend.close();
  }
}

/** Resolve `opts.image` to an ORDERED layer stack (lowest→highest tar bytes) for
 *  the host's `withLayers`. `null` = empty fs. Accepts raw bytes (one layer), the
 *  `"base:latest"` baseline, a flavor name or built {@link ImageManifest} (its
 *  layer digests resolved from the store), or a committed `"sha256:…"` diff
 *  layer stacked over the default base. */
export async function resolveImage(
  image: CreateOptions["image"],
  store?: ContentStore,
): Promise<Uint8Array[] | null> {
  if (image === null) return null;
  if (image instanceof Uint8Array) return [image];
  if (image === undefined || image === "base:latest") return [await defaultImage()];
  if (typeof image === "string") {
    const s = requireStore(store, image);
    if (image.startsWith("sha256:")) return [await defaultImage(), await s.layer(image)];
    return resolveManifest(await s.manifest(image), s); // a flavor name
  }
  const s = requireStore(store, "manifest");
  return resolveManifest(image, s); // a built ImageManifest
}

/** Map a manifest's ordered layer digests to their `.tar` bytes via the store. */
async function resolveManifest(m: ImageManifest, store: ContentStore): Promise<Uint8Array[]> {
  return Promise.all(m.layers.map((l) => store.layer(l.digest)));
}

/** Encode an {@link ImageConfig} tier as the kernel's boot ordinal (0 = inherit /
 *  full). Mirrors `task::Tier::from_arg`. */
function tierOrdinal(tier?: ImageConfig["tier"]): number {
  switch (tier) {
    case "full":
      return TIER_FULL;
    case "read-write":
      return TIER_READ_WRITE;
    case "read-only":
      return TIER_READ_ONLY;
    case "isolated":
      return TIER_ISOLATED;
    default:
      return TIER_INHERIT;
  }
}

function contractI32(n: number | undefined): number {
  if (!Number.isFinite(n) || n === undefined || n <= 0) return 0;
  return Math.min(Math.trunc(n), 0x7fffffff);
}

function contractFuel(n: number | undefined): number {
  if (!Number.isFinite(n) || n === undefined || n <= 0) return 0;
  return Math.min(Math.trunc(n), Number.MAX_SAFE_INTEGER);
}

/** The runtime contract (tier/budget) a manifest image enforces at boot; `{}` for
 *  a raw/flavorless image. */
async function imageConfig(
  image: CreateOptions["image"],
  store?: ContentStore,
): Promise<ImageConfig> {
  if (typeof image === "string" && !image.startsWith("sha256:") && image !== "base:latest") {
    return (await requireStore(store, image).manifest(image)).config;
  }
  if (image && typeof image === "object" && !(image instanceof Uint8Array)) {
    return image.config;
  }
  return {};
}

function requireStore(store: ContentStore | undefined, image: string): ContentStore {
  if (!store) {
    throw new Error(`image ${image} requires a content store`);
  }
  return store;
}

function imageNeedsStore(image: CreateOptions["image"]): boolean {
  if (image === undefined || image === null || image === "base:latest") return false;
  if (image instanceof Uint8Array) return false;
  return true;
}

function validateBrowserArtifacts(opts: CreateOptions): void {
  if (!(opts.kernel instanceof Uint8Array)) {
    throw new Error(
      "runtime 'browser' requires opts.kernel — the kernel.wasm bytes you fetched (and opts.image bytes, or null)",
    );
  }
  if (opts.image === undefined || opts.image === "base:latest") {
    throw new Error("runtime 'browser' requires opts.image bytes, a browser-readable image store, or null");
  }
  if (typeof opts.image === "string" && opts.image.startsWith("sha256:")) {
    throw new Error("runtime 'browser' cannot resolve sha256 diff layers without default base image bytes");
  }
  if (imageNeedsStore(opts.image) && !opts.store) {
    throw new Error("runtime 'browser' image references require opts.store, or pass fetched image bytes as opts.image");
  }
}

function netEnabled(opts: CreateOptions): boolean {
  const n = opts.permissions?.network;
  if (n === "deny") return false;
  if (opts.net) return true;
  if (n === "allow") return true;
  // An allowlist object implies net is on (the host filters per-host below).
  if (n !== undefined && typeof n === "object") return true;
  return false;
}

function connectionRegistry(defs: ConnectionDefinition[]): ConnectionRegistry {
  const registry = new ConnectionRegistry();
  for (const def of defs) {
    registry.insert(def.ref, def.auth, def.origins);
  }
  return registry;
}

/** The set of hosts allowed without prompting, from `permissions.network.allow`.
 *  `undefined` = no filtering (open net). An empty/missing array = prompt for
 *  every host. */
function netAllowlist(opts: CreateOptions): Set<string> | undefined {
  const n = opts.permissions?.network;
  if (n && typeof n === "object") return new Set(Array.isArray(n.allow) ? n.allow : []);
  return undefined;
}

/** Adapt `onPermission(req => req.allow()/reject())` into the host net approver
 *  (a host→decision promise). Default-deny on any handler error. */
function makeApprover(
  onPermission: CreateOptions["onPermission"],
): ((host: string, url: string) => Promise<{ allow: boolean; remember?: "once" | "session" }>) | undefined {
  if (!onPermission) return undefined;
  let id = 0;
  return (host, url) =>
    new Promise((resolve) => {
      const req = {
        id: ++id,
        kind: "network" as const,
        host,
        url,
        allow: (o?: { remember?: "once" | "session" }) => resolve({ allow: true, remember: o?.remember }),
        reject: () => resolve({ allow: false }),
      };
      void Promise.resolve(onPermission(req)).catch(() => resolve({ allow: false }));
    });
}

function makeToolApprover(onPermission: CreateOptions["onPermission"]): ToolApprover | undefined {
  if (!onPermission) return undefined;
  let id = 0;
  return (facts: ToolApprovalFacts) =>
    new Promise((resolve) => {
      const req = {
        id: ++id,
        kind: "tool_approval" as const,
        connection: facts.connection,
        method: facts.method,
        url: facts.url,
        origin: facts.origin,
        ...(facts.argsDigest ? { argsDigest: facts.argsDigest } : {}),
        allow: (o?: { remember?: "once" | "session" }) =>
          resolve({ allow: true, remember: o?.remember }),
        reject: () => resolve({ allow: false }),
      };
      void Promise.resolve(onPermission(req)).catch(() => resolve({ allow: false }));
    });
}

async function makeEmbedded(
  opts: CreateOptions,
  snapshot: Uint8Array | null,
): Promise<Backend> {
  const wasm = opts.kernel ?? (await defaultKernel());
  // Fill each connection's credential-egress origins from the curated registry when omitted, so the
  // credential store and the compiled catalog below both see the same derived allowlist.
  opts = { ...opts, connections: await deriveConnectionOrigins(opts) };
  const hostTools = hostToolDefinitions(opts.tools);
  const stdout = new FanoutSink();
  const tools = new MapHostCall();
  let builder = new KernelHostBuilder(wasm)
    .withStdout(stdout)
    .withStderr(stdout)
    .withLog(stdout)
    .withHostCall(tools);
  if (opts.deterministic) builder = builder.deterministic();
  if (netEnabled(opts)) {
    builder = builder.withNet(
      new HostNet({
        allowlist: netAllowlist(opts),
        approver: makeApprover(opts.onPermission),
        connections: connectionRegistry(opts.connections ?? []),
        toolApprover: makeToolApprover(opts.onPermission),
        policyByConnection: await resolvePolicyByConnection(opts),
      }),
    );
  }
  // Durable `/var/persist`: in a browser OPFS/IndexedDB survives a reload; the
  // capability is loaded (async) before boot/restore so the VM sees it.
  if (opts.persist) {
    builder = builder.withPersist(await OpfsPersist.open());
  }

  let host: KernelHost;
  if (snapshot) {
    host = await builder.restore(snapshot);
  } else {
    const store = opts.store ?? (imageNeedsStore(opts.image) ? defaultStore() : undefined);
    const layers = await resolveImage(opts.image, store);
    const cfg = await imageConfig(opts.image, store);
    host = await builder
      .withLayers(layers ?? [])
      .withContract(tierOrdinal(cfg.tier), contractI32(cfg.budgetMib), contractFuel(cfg.fuel))
      .build();
    host.bootToPrompt(); // drive boot only to the first prompt (no settle wait)
  }
  const backend = new EmbeddedBackend(host, stdout, tools);
  for (const t of hostTools) backend.tool(t);
  await seedToolCatalog(backend, opts, hostTools);
  if (snapshot) {
    await applyToolCatalog(backend, opts, hostTools, 1);
  }
  await seedToolAliases(backend, hostTools, undefined, snapshot !== null);
  // Install boot-time mounts before the backend is returned (and before any
  // exec), so the first command already sees them. Declaration order is kept.
  for (const m of opts.mounts ?? []) {
    await backend.mount(m.path, m.driver, m.readOnly ?? m.driver.readOnly ?? false);
  }
  return backend;
}

/** Write the boot-seed `/etc/tools/catalog/` tree. Once `/svc/tools` is active, catalog mutation
 *  must go through `applyToolCatalog`; these files are only the cold-start seed/checkpoint. */
async function seedToolCatalog(
  backend: Backend,
  opts: CreateOptions,
  defs: ToolDefinition[],
): Promise<void> {
  const bundle = await mergedCatalogBundle(opts, defs, 0);
  await ensureToolCatalogDirs(backend);
  for (const record of bundle.records) {
    await backend.write(`/etc/tools/catalog/records/${record.sha}`, record.bytes);
  }
  await backend.write("/etc/tools/catalog/index.json", bundle.indexBytes);
  await backend.write("/etc/tools/catalog/index.sha256", enc(`${bundle.indexDigest}\n`));
}

async function ensureToolCatalogDirs(backend: Backend): Promise<void> {
  try {
    await backend.mkdir("/etc");
  } catch {
    /* already exists */
  }
  try {
    await backend.mkdir("/etc/tools");
  } catch {
    /* already exists */
  }
  try {
    await backend.mkdir("/etc/tools/catalog");
  } catch {
    /* already exists */
  }
  try {
    await backend.mkdir("/etc/tools/catalog/records");
  } catch {
    /* already exists */
  }
}

async function applyToolCatalog(
  backend: Backend,
  opts: CreateOptions,
  defs: ToolDefinition[],
  generation: number,
  baseDigest = "",
): Promise<string> {
  const bundle = await mergedCatalogBundle(opts, defs, generation);
  await ensureToolCatalogDirs(backend);
  for (const record of bundle.records) {
    await backend.write(`/etc/tools/catalog/records/${record.sha}`, record.bytes);
  }
  const req = JSON.stringify({
    op: "catalog.apply",
    generation,
    index: bundle.index,
    digest: bundle.indexDigest,
    // Compare-and-swap base: omitted on the first commit (idempotent-by-digest is the safety net), set
    // on subsequent runtime commits so a concurrent change is caught instead of clobbered.
    ...(baseDigest ? { base_digest: baseDigest } : {}),
  });
  const raw = await backend.serviceCall("tools", enc(req));
  let response: unknown;
  try {
    response = JSON.parse(dec(raw));
  } catch {
    throw new Error("/svc/tools returned a non-JSON catalog.apply response");
  }
  if (!response || typeof response !== "object" || (response as { ok?: unknown }).ok !== true) {
    const err = (response as { err?: { code?: unknown; message?: unknown } } | null)?.err;
    const code = typeof err?.code === "string" ? err.code : "catalog_apply_failed";
    const message = typeof err?.message === "string" ? err.message : "tool catalog update failed";
    throw new Error(`/svc/tools ${code}: ${message}`);
  }
  return bundle.indexDigest;
}

async function mergedCatalogBundle(
  opts: CreateOptions,
  defs: ToolDefinition[],
  generation: number,
): Promise<ToolCatalogBundle> {
  const bundles: ToolCatalogBundle[] = [];
  // Only touch the compiler when there are host tools to validate — a bare VM (no host tools, no
  // connections) must not require catalog-compiler.wasm.
  if (defs.length > 0) {
    const compiler = await defaultCatalogCompiler(opts.catalogCompiler);
    bundles.push(await toolCatalogBundle(defs, compiler, generation));
  }
  const connectionBundle = await connectionToolCatalogBundle(opts, generation);
  if (connectionBundle) bundles.push(connectionBundle);
  return mergeToolCatalogBundles(bundles, generation);
}

/** Make each registered tool/kit a first-class command: a `/bin/<name>` symlink →
 *  `tools`, so the agent can run `weather get …` directly instead of
 *  `tools call …` (busybox-style argv[0] dispatch, like mcbox — one
 *  `tools` binary + tiny symlinks, no per-tool copy). One alias per unique
 *  leading name token (a kit's `"weather get"`/`"weather set"` → one `/bin/weather`).
 *  Guarded: a name that isn't a safe single path component, or that already exists
 *  in `/bin`, is skipped (never clobbers a real command). */
function toolAliasNames(defs: ToolDefinition[]): Set<string> {
  const names = new Set<string>();
  for (const d of defs) {
    const alias = d.name.split(/\s+/)[0];
    if (alias) names.add(alias);
  }
  return names;
}

function isSafeToolAlias(name: string): boolean {
  return name !== "tools" && /^[A-Za-z0-9._-]+$/.test(name);
}

async function seedToolAliases(
  backend: Backend,
  defs: ToolDefinition[],
  handledAliases?: Set<string>,
  quietExistingSymlinks = false,
): Promise<void> {
  const names = toolAliasNames(defs);
  for (const name of names) {
    if (!isSafeToolAlias(name)) {
      console.warn(`mc: tool "${name}" not aliased (reserved or unsafe command name)`);
      continue;
    }
    if (handledAliases?.has(name)) continue;
    const link = `/bin/${name}`;
    let existing: { isSymlink: boolean } | undefined;
    try {
      existing = await backend.stat(link);
    } catch {
      existing = undefined; // ENOENT — free to create
    }
    if (!existing) {
      await backend.symlink("tools", link);
    } else if (!(quietExistingSymlinks && existing.isSymlink)) {
      // Any existing `/bin` path is occupied, including symlinks like `date ->
      // mcbox-ro`. Without readlink in the public fs API, assuming "symlink means
      // our prior alias" silently routes a tool name to the wrong command.
      console.warn(`mc: tool "${name}" not aliased — /bin/${name} already exists`);
    }
    handledAliases?.add(name);
  }
}

function remoteId(): string {
  const random = globalThis.crypto?.randomUUID?.();
  if (random) return random;
  return `vm-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}

function remoteNetPolicy(opts: CreateOptions): string {
  return netEnabled(opts) ? "real" : "deny";
}

function remotePersistPolicy(opts: CreateOptions): string {
  if (opts.persist) {
    throw new Error("remote runtime: persist requires a server-side persistence policy; client-side persist relay is not in the wire contract");
  }
  return "deny";
}

function remoteHostCallPolicy(_opts: CreateOptions): string {
  return "relay";
}

function remoteConnectionAuth(auth: ConnectionDefinition["auth"]): Record<string, string> {
  switch (auth.kind) {
    case "none":
      return { kind: "none" };
    case "bearer":
      return { kind: "bearer", token: auth.token };
    case "header":
      return { kind: "header", name: auth.name, value: auth.value };
    case "query":
      return { kind: "query", name: auth.name, value: auth.value };
  }
}

function remoteConnections(defs: readonly ConnectionDefinition[] | undefined): Record<string, unknown>[] {
  return (defs ?? []).map((connection) => ({
    ref: connection.ref,
    auth: remoteConnectionAuth(connection.auth),
    origins: [...(connection.origins ?? [])],
  }));
}

function remoteImageFields(image: CreateOptions["image"]): Record<string, unknown> {
  if (image === undefined || image === "base:latest") return {};
  if (image === null) return { layers: [] };
  if (image instanceof Uint8Array) {
    throw new Error(
      "remote runtime: image must be a packaged flavor, sha256 layer digest, ImageManifest, or null; raw tar bytes are not sent over REST",
    );
  }
  if (typeof image === "string") {
    return image.startsWith("sha256:") ? { layers: [image] } : { image };
  }
  return { layers: image.layers.map((layer) => layer.digest) };
}

function remoteCreateBody(opts: CreateOptions, id?: string): Record<string, unknown> {
  return {
    ...(id ? { id } : {}),
    ...remoteImageFields(opts.image),
    ...(opts.deterministic ? { deterministic: true } : {}),
    net: remoteNetPolicy(opts),
    persist: remotePersistPolicy(opts),
    hostCall: remoteHostCallPolicy(opts),
    connections: remoteConnections(opts.connections),
  };
}

async function makeRemote(opts: CreateOptions, snapshot: Uint8Array | null): Promise<Backend> {
  if (!opts.endpoint) {
    throw new Error("runtime 'remote' requires opts.endpoint");
  }
  const endpoint = opts.endpoint.replace(/\/$/, "");
  const headers: Record<string, string> = opts.token ? { authorization: `Bearer ${opts.token}` } : {};
  const hostTools = hostToolDefinitions(opts.tools);
  let id: string;

  if (snapshot) {
    id = opts.id ?? remoteId();
    const response = await fetch(`${endpoint}/v1/vms/${encodeURIComponent(id)}/restore`, {
      method: "POST",
      headers: { ...headers, "content-type": "application/octet-stream" },
      body: snapshot as BodyInit,
    });
    if (!response.ok) throw new Error(`remote restore failed: ${response.status}`);
    const body = (await response.json()) as { id?: string };
    id = body.id ?? id;
  } else {
    const response = await fetch(`${endpoint}/v1/vms`, {
      method: "POST",
      headers: { ...headers, "content-type": "application/json" },
      body: JSON.stringify(remoteCreateBody(opts, opts.id)),
    });
    if (!response.ok) throw new Error(`remote create failed: ${response.status}`);
    const body = (await response.json()) as { id?: string };
    if (!body.id) throw new Error("remote create response did not include a VM id");
    id = body.id;
  }

  const backend = new RemoteBackend({
    endpoint,
    token: opts.token,
    vmId: id,
    onPermission: opts.onPermission,
  });
  for (const tool of hostTools) backend.tool(tool);
  if (hostTools.length || opts.mounts?.length || opts.onPermission) await backend.connect();
  await seedToolCatalog(backend, opts, hostTools);
  await seedToolAliases(backend, hostTools, undefined, snapshot !== null);
  for (const mount of opts.mounts ?? []) {
    await backend.mount(mount.path, mount.driver, mount.readOnly ?? mount.driver.readOnly ?? false);
  }
  return backend;
}

/** Derive the connection + tool selectors for one or more `integration.group` capabilities — the pure
 *  core of {@link mc.use}, exported for testing. All capabilities must share one integration so a single
 *  credential/connection covers them; origins are filled from the curated registry, so the connection is
 *  just `{ ref: "<integration>.org.main", auth }` (no spec, no origins). A bare string credential is a
 *  bearer token. */
export function capabilityConnection(
  capability: string | string[],
  credential: string | ConnectionDefinition["auth"],
): { connections: ConnectionDefinition[]; tools: string[] } {
  const caps = Array.isArray(capability) ? capability : [capability];
  if (caps.length === 0) throw new Error("mc.use requires at least one capability");
  const auth: ConnectionDefinition["auth"] =
    typeof credential === "string" ? { kind: "bearer", token: credential } : credential;
  const parsed = caps.map((c) => {
    const dot = c.indexOf(".");
    if (dot < 0) {
      throw new Error(`capability '${c}' must be 'integration.group' (e.g. 'github.issues')`);
    }
    const integration = c.slice(0, dot);
    const group = c.slice(dot + 1);
    if (!integration || !group) {
      throw new Error(`capability '${c}' must be 'integration.group' (e.g. 'github.issues')`);
    }
    return { integration, group };
  });
  const integration = parsed[0]!.integration;
  if (parsed.some((p) => p.integration !== integration)) {
    throw new Error("mc.use capabilities must share one integration; use mc.create for several");
  }
  return {
    connections: [{ ref: `${integration}.org.main`, auth }],
    tools: parsed.map((p) => `${p.integration}/${p.group}`),
  };
}

/** Entry point: create, restore, or connect to a VM. */
export const mc = {
  /** Create a fresh VM. */
  async create(opts: CreateOptions = {}): Promise<Vm> {
    const runtime = opts.runtime ?? "bun";
    if (runtime === "remote") return new Vm(await makeRemote(opts, null), opts);
    // Browser and Bun share the embedded backend — the kernel runs in-process
    // via WebAssembly + the JS bridge (fetch/WebSocket/crypto are browser-native).
    // The only difference is artifact loading: a browser caller fetches the
    // kernel.wasm (+ base.tar) and passes the bytes, since the workspace
    // build paths (Bun.file) don't exist in a browser.
    if (runtime === "browser") validateBrowserArtifacts(opts);
    return new Vm(await makeEmbedded(opts, null), opts);
  },

  /** Capability sugar over {@link create}: turn on one or more `integration.group` capabilities with a
   *  credential and get a running VM. `mc.use("github.issues", token, { kernel, image })` derives the
   *  connection `{ ref: "github.org.main", auth }` and the `github/issues` tool selector for you, with
   *  net + network permission on. A bare token string is treated as a bearer credential. Multiple
   *  capabilities must share one integration (one connection); use {@link create} for several. */
  async use(
    capability: string | string[],
    credential: string | ConnectionDefinition["auth"],
    opts: Omit<CreateOptions, "connections" | "tools"> = {},
  ): Promise<Vm> {
    const { connections, tools } = capabilityConnection(capability, credential);
    return mc.create({
      ...opts,
      net: opts.net ?? true,
      permissions: { network: "allow", ...opts.permissions },
      connections,
      tools,
    });
  },

  /** Restore a VM from a snapshot blob (embedded or remote). */
  async restore(snapshot: Uint8Array, opts: CreateOptions = {}): Promise<Vm> {
    const runtime = opts.runtime ?? "bun";
    if (runtime === "remote") return new Vm(await makeRemote(opts, snapshot), opts);
    if (runtime === "browser" && !(opts.kernel instanceof Uint8Array)) {
      throw new Error("runtime 'browser' restore requires opts.kernel bytes");
    }
    return new Vm(await makeEmbedded(opts, snapshot), opts);
  },

  /** Connect to a served AgentOS host and get-or-create VMs by key. */
  connect(endpoint: string, token?: string): { vm: (key: string) => Promise<Vm> } {
    const base = endpoint.replace(/\/$/, "");
    const headers: Record<string, string> = token ? { authorization: `Bearer ${token}` } : {};
    return {
      async vm(key: string): Promise<Vm> {
        const response = await fetch(`${base}/v1/vms`, {
          method: "POST",
          headers: { ...headers, "content-type": "application/json" },
          body: JSON.stringify({ id: key }),
        });
        if (!response.ok) throw new Error(`connect.vm(${key}) failed: ${response.status}`);
        const body = (await response.json()) as { id?: string };
        const id = body.id ?? key;
        const opts: CreateOptions = { runtime: "remote", endpoint: base, token, id };
        return new Vm(new RemoteBackend({ endpoint: base, token, vmId: id }), opts);
      },
    };
  },

  /** Create a VM that records its `fs.write` + `exec` as a replayable `llb` build
   *  DAG while running live. `await rec.build()`'s tip is the image you just
   *  authored by *driving* the VM. */
  record,
};
