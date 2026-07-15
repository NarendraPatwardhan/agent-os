// The `llb` solver. Walks the build DAG, computing each node's Merkle
// digest `sha256(op ⊕ input-digests ⊕ args)` and MEMOIZING the resolved image by
// that digest in the content store — edit one node and only its downstream
// sub-DAG re-runs. A node materializes by booting a fresh VM from its input's
// layers, applying the op (`vm.fs.*` / `vm.exec`), and `commit()`-ing the
// overlay into a new layer. `exec` nodes default to the deterministic
// clock/RNG so their layer digest is reproducible — making the content-addressed
// cache SOUND (a node that opts into net/non-determinism is never memoized).

import {
  encodeNodeDigest,
  type BuildOp as ContractBuildOp,
  type DigestEdge,
  type LayerRef,
  type NodeDigest as ContractNodeDigest,
} from "@mc/contracts/llb";
import { mc, resolveImage, type Vm } from "./memcontainer.js";
import { defaultKernel } from "./artifacts.js";
import { defaultStore } from "./store.js";
import type { BuildNode, BuildState } from "./llb.js";
import type {
  BuildRecord,
  ContentStore,
  ImageConfig,
  ImageManifest,
  MountSpec,
  StatResult,
  VmFs,
} from "./types.js";

const DEFAULT_EXEC_TIER: NonNullable<ImageConfig["tier"]> = "read-write";
const OP_SOURCE = 0;
const OP_LAYER = 1;
const OP_WRITE = 2;
const OP_MKDIR = 3;
const OP_RM = 4;
const OP_CHMOD = 5;
const OP_SYMLINK = 6;
const OP_EXEC = 7;
const OP_COPY = 8;
const OP_MERGE = 9;
const OP_DIFF = 10;
const OP_IMAGE = 11;
const OP_CACHE = 12;
const OP_LOCAL = 13;
const OP_HTTP = 14;
const OP_GIT = 15;

/** A resolved image: an ordered layer stack + the runtime contract. */
interface ResolvedLayer {
  digest: string;
  size: number;
  /** Internal provenance key for DAG algebra. Public image manifests strip it. */
  producer: string;
}

interface ResolvedImage {
  layers: ResolvedLayer[];
  config: ImageConfig;
}

export interface SolveOptions {
  /** Content store for memoization + layer/snapshot persistence. Default
   *  {@link defaultStore}. */
  store?: ContentStore;
  /** Kernel wasm bytes used for VM-executing build steps. Defaults to {@link defaultKernel}. */
  kernel?: Uint8Array;
  /** Warm-up work to perform before `asSnapshot()`. Folded into the snapshot key. */
  warm?: WarmDirective[];
  /** Structured solve status for each vertex, keyed by the canonical node digest. */
  onProgress?: (event: SolveProgressEvent) => void | Promise<void>;
  /** Runtime host hooks for local/git sources and cache mounts. */
  platform?: SolvePlatform;
}

export interface SolvePlatform {
  localSource(root: string): Promise<LocalSource>;
  gitSource(repo: string, ref: string, dest: string): Promise<GitSource>;
  cacheMounts(mounts: readonly BuildState[]): Promise<MountSpec[]>;
}

export type WarmDirective =
  | {
      kind: "exec";
      cmd: string;
      cwd?: string;
      env?: Record<string, string>;
      stdin?: string | Uint8Array;
    }
  | {
      kind: "svc";
      name: string;
      request?: Uint8Array;
    };

export type SolveProgressEvent =
  | { type: "started"; digest: string; op: BuildNode["op"] }
  | { type: "cached"; digest: string; op: BuildNode["op"] }
  | { type: "completed"; digest: string; op: BuildNode["op"] }
  | { type: "failed"; digest: string; op: BuildNode["op"]; error: string };

// --------------------------------------------------------------------------
// Merkle digests (the cache keys).
// --------------------------------------------------------------------------

const te = new TextEncoder();
const td = new TextDecoder();
const EMPTY_TAR = new Uint8Array(1024);
const TAR_BLOCK = 512;

async function sha256hex(data: Uint8Array): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", data as Uint8Array<ArrayBuffer>));
  let s = "";
  for (const b of h) s += b.toString(16).padStart(2, "0");
  return s;
}

/** Concatenate auxiliary key parts with NUL separators. LLB node digests use `NodeDigest`. */
function cat(...parts: (string | Uint8Array)[]): Uint8Array {
  const bufs = parts.map((p) => (typeof p === "string" ? te.encode(p) : p));
  const len = bufs.reduce((n, b) => n + b.length + 1, 0);
  const out = new Uint8Array(len);
  let off = 0;
  for (const b of bufs) {
    out.set(b, off);
    off += b.length;
    out[off++] = 0;
  }
  return out;
}

const stdinBytes = (stdin: string | Uint8Array | undefined): Uint8Array | undefined =>
  typeof stdin === "string" ? te.encode(stdin) : stdin;

function sortedEnv(env: Record<string, string> | undefined): [string, string][] {
  return Object.entries(env ?? {}).sort(([a], [b]) => a.localeCompare(b));
}

async function warmDigest(warm: readonly WarmDirective[] | undefined): Promise<string> {
  if (!warm?.length) return sha256hex(cat("warm"));
  const parts: (string | Uint8Array)[] = ["warm"];
  for (const directive of warm) {
    switch (directive.kind) {
      case "exec":
        parts.push(
          "exec",
          directive.cmd,
          directive.cwd ?? "",
          JSON.stringify(sortedEnv(directive.env)),
          directive.stdin === undefined ? "" : await sha256hex(stdinBytes(directive.stdin)!),
        );
        break;
      case "svc":
        parts.push(
          "svc",
          directive.name,
          directive.request === undefined ? "" : await sha256hex(directive.request),
        );
        break;
    }
  }
  return sha256hex(cat(...parts));
}

export type LocalEntry =
  | { kind: "dir"; rel: string; mode?: number }
  | { kind: "file"; rel: string; bytes: Uint8Array; digest: string; mode?: number }
  | { kind: "symlink"; rel: string; target: string };

export interface LocalSource {
  digest: string;
  entries: LocalEntry[];
}

interface HttpSource {
  digest: string;
  bytes: Uint8Array;
}

export interface GitSource {
  commit: string;
  archiveDigest: string;
  tar: Uint8Array;
}

/** The node's content-addressed digest (the cache key), memoized PER SOLVE. A
 *  `source`'s digest folds in its RESOLVED layer metadata and config (not the ref string), so
 *  a mutable ref — `base:latest` or a flavor/manifest name — whose bytes change
 *  moves every downstream key (the BuildKit tag→digest discipline). It is
 *  per-`(node, store)`, hence per-solve: the same source resolves differently
 *  against a different store. */
function nodeDigest(node: BuildNode, ctx: SolveCtx): Promise<string> {
  let d = ctx.digests.get(node);
  if (!d) {
    d = computeDigest(node, ctx);
    ctx.digests.set(node, d);
  }
  return d;
}

async function computeDigest(node: BuildNode, ctx: SolveCtx): Promise<string> {
  return sha256hex(encodeNodeDigest(await nodeDigestInput(node, ctx)));
}

async function nodeDigestInput(node: BuildNode, ctx: SolveCtx): Promise<ContractNodeDigest> {
  switch (node.op) {
    case "source": {
      // Content-address the source by its RESOLVED layer metadata + config, not the ref string —
      // a `sha256:` ref resolves to itself (stays exact), a mutable name/URL
      // resolves to its current bytes (so a changed base busts the cache).
      const resolved = await resolveSourceCached(node.ref, ctx);
      return digestInput({
        op: digestOp(OP_SOURCE, { source_ref: node.ref }),
        resolved: configResolved(resolved.config),
        layers: resolved.layers.map(layerRef),
      });
    }
    case "layer":
      // A `sha256:` layer digest is already immutable content.
      return digestInput({ op: digestOp(OP_LAYER, { source_ref: node.ref }) });
    case "local": {
      const local = await localSourceCached(node.path, ctx);
      return digestInput({
        op: digestOp(OP_LOCAL, {
          local_path: node.path,
          dest_path: normalizeVmPath(node.dest, "local destination"),
        }),
        resolved: { source_digest: local.digest },
        kernel_digest: await digestKernel(ctx),
      });
    }
    case "http": {
      const http = await httpSourceCached(node.url, node.expectedDigest, ctx);
      return digestInput({
        op: digestOp(OP_HTTP, {
          http_url: node.url,
          dest_path: normalizeVmPath(node.dest, "http destination"),
          expected_digest: node.expectedDigest,
        }),
        resolved: { content_digest: http.digest },
        kernel_digest: await digestKernel(ctx),
      });
    }
    case "git": {
      const git = await gitSourceCached(node.repo, node.ref, node.dest, ctx);
      return digestInput({
        op: digestOp(OP_GIT, {
          git_repo: node.repo,
          git_ref: node.ref,
          dest_path: normalizeVmPath(node.dest, "git destination"),
        }),
        resolved: { archive_digest: git.archiveDigest, commit: git.commit },
        kernel_digest: await digestKernel(ctx),
      });
    }
    case "write": {
      return digestInput({
        op: digestOp(OP_WRITE, {
          input: 0,
          path: node.path,
          data_digest: `sha256:${await sha256hex(node.data)}`,
        }),
        edges: [edge("input", await nodeDigest(node.input, ctx))],
        kernel_digest: await digestKernel(ctx),
      });
    }
    case "mkdir":
      return digestInput({
        op: digestOp(OP_MKDIR, { input: 0, path: node.path }),
        edges: [edge("input", await nodeDigest(node.input, ctx))],
        kernel_digest: await digestKernel(ctx),
      });
    case "rm":
      return digestInput({
        op: digestOp(OP_RM, { input: 0, path: node.path }),
        edges: [edge("input", await nodeDigest(node.input, ctx))],
        kernel_digest: await digestKernel(ctx),
      });
    case "chmod":
      return digestInput({
        op: digestOp(OP_CHMOD, { input: 0, path: node.path, mode: node.mode }),
        edges: [edge("input", await nodeDigest(node.input, ctx))],
        kernel_digest: await digestKernel(ctx),
      });
    case "symlink":
      return digestInput({
        op: digestOp(OP_SYMLINK, { input: 0, target: node.target, link: node.link }),
        edges: [edge("input", await nodeDigest(node.input, ctx))],
        kernel_digest: await digestKernel(ctx),
      });
    case "exec": {
      const mountDigests = node.opts.mounts
        ? await Promise.all(node.opts.mounts.map((m) => nodeDigest(m.node, ctx)))
        : [];
      return digestInput({
        op: digestOp(OP_EXEC, {
          input: 0,
          cmd: node.cmd,
          cwd: node.opts.cwd,
          env: { ...(node.opts.env ?? {}) },
          stdin: stdinBytes(node.opts.stdin),
          tier: node.opts.tier ?? DEFAULT_EXEC_TIER,
          budget_mib: node.opts.budgetMib,
          fuel: node.opts.fuel,
          deterministic: node.opts.deterministic ?? true,
          net: node.opts.net ?? false,
          mounts: mountDigests.map((_digest, i) => inputRef(i + 1)),
        }),
        edges: [
          edge("input", await nodeDigest(node.input, ctx)),
          ...mountDigests.map((digest, i) => edge(`mount:${i}`, digest)),
        ],
        kernel_digest: await digestKernel(ctx),
      });
    }
    case "copy": {
      return digestInput({
        op: digestOp(OP_COPY, {
          dest: 0,
          src: 1,
          copy_paths: node.paths.map((path) => ({ src_path: path.from, dest_path: path.to })),
        }),
        edges: [
          edge("dest", await nodeDigest(node.dest, ctx)),
          edge("src", await nodeDigest(node.src, ctx)),
        ],
        kernel_digest: await digestKernel(ctx),
      });
    }
    case "merge":
      return digestInput({
        op: digestOp(OP_MERGE, { a: 0, b: 1 }),
        edges: [edge("a", await nodeDigest(node.a, ctx)), edge("b", await nodeDigest(node.b, ctx))],
      });
    case "diff":
      return digestInput({
        op: digestOp(OP_DIFF, { lower: 0, upper: 1 }),
        edges: [
          edge("lower", await nodeDigest(node.lower, ctx)),
          edge("upper", await nodeDigest(node.upper, ctx)),
        ],
        kernel_digest: await digestKernel(ctx),
      });
    case "image": {
      const parts = await Promise.all(node.parts.map((n) => nodeDigest(n, ctx)));
      return digestInput({
        op: digestOp(OP_IMAGE, {
          parts: parts.map((_digest, i) => inputRef(i)),
          config_tier: node.config.tier,
          config_budget_mib: node.config.budgetMib,
          config_fuel: node.config.fuel,
        }),
        edges: parts.map((digest, i) => edge(`part:${i}`, digest)),
      });
    }
    case "cache":
      return digestInput({ op: digestOp(OP_CACHE, { path: node.path }) });
  }
}

function digestInput(input: {
  op: ContractBuildOp;
  edges?: DigestEdge[];
  resolved?: Record<string, string>;
  layers?: LayerRef[];
  kernel_digest?: string;
}): ContractNodeDigest {
  return {
    op: input.op,
    edges: input.edges ?? [],
    resolved: input.resolved ?? {},
    layers: input.layers ?? [],
    ...(input.kernel_digest ? { kernel_digest: input.kernel_digest } : {}),
  };
}

function digestOp(kind: number, fields: Partial<ContractBuildOp> = {}): ContractBuildOp {
  return { kind, parts: [], copy_paths: [], env: {}, mounts: [], ...fields };
}

function inputRef(index: number): { index: number } {
  return { index };
}

function edge(role: string, digest: string): DigestEdge {
  return { role, digest };
}

function layerRef(layer: ResolvedLayer): LayerRef {
  return { producer: layer.producer, digest: layer.digest, size: layer.size };
}

function configResolved(config: ImageConfig): Record<string, string> {
  return {
    ...(config.tier ? { config_tier: config.tier } : {}),
    ...(config.budgetMib !== undefined ? { config_budget_mib: String(config.budgetMib) } : {}),
    ...(config.fuel !== undefined ? { config_fuel: String(config.fuel) } : {}),
  };
}

async function digestKernel(ctx: SolveCtx): Promise<string> {
  return `sha256:${await kernelDigest(ctx)}`;
}

// --------------------------------------------------------------------------
// The solver.
// --------------------------------------------------------------------------

interface SolveCtx {
  store: ContentStore;
  kernel: Uint8Array | undefined;
  kernelBytes: Promise<Uint8Array> | null;
  kernelDigest: Promise<string> | null;
  onProgress: SolveOptions["onProgress"];
  platform: SolvePlatform | undefined;
  defaultPlatform: Promise<SolvePlatform> | null;
  /** Per-solve digest memo (keyed by node; valid because one store per ctx). */
  digests: Map<BuildNode, Promise<string>>;
  /** Per-solve materialization memo, keyed by node digest, including uncacheable shared vertices. */
  solved: Map<string, Promise<ResolvedImage>>;
  /** Per-solve resolved-source memo (keyed by ref) so a source resolves ONCE —
   *  its content feeds both the cache key and the materialized layers. */
  sources: Map<string, Promise<ResolvedImage>>;
  /** Per-solve local source scans, keyed by host path. */
  locals: Map<string, Promise<LocalSource>>;
  /** Per-solve HTTP source fetches, keyed by URL + expected digest. */
  httpSources: Map<string, Promise<HttpSource>>;
  /** Per-solve git archives, keyed by repo + ref + destination prefix. */
  gitSources: Map<string, Promise<GitSource>>;
}

/** A fresh solve context (its own digest + source memos). */
function newCtx(store: ContentStore, opts: SolveOptions = {}): SolveCtx {
  return {
    store,
    kernel: opts.kernel,
    kernelBytes: null,
    kernelDigest: null,
    onProgress: opts.onProgress,
    platform: opts.platform,
    defaultPlatform: null,
    digests: new Map(),
    solved: new Map(),
    sources: new Map(),
    locals: new Map(),
    httpSources: new Map(),
    gitSources: new Map(),
  };
}

function kernelBytes(ctx: SolveCtx): Promise<Uint8Array> {
  if (!ctx.kernelBytes) {
    ctx.kernelBytes = Promise.resolve(ctx.kernel ?? defaultKernel());
  }
  return ctx.kernelBytes;
}

function kernelDigest(ctx: SolveCtx): Promise<string> {
  if (!ctx.kernelDigest) {
    ctx.kernelDigest = kernelBytes(ctx).then((kernel) => sha256hex(kernel));
  }
  return ctx.kernelDigest;
}

async function emitProgress(ctx: SolveCtx, event: SolveProgressEvent): Promise<void> {
  if (ctx.onProgress) await ctx.onProgress(event);
}

function solvePlatform(ctx: SolveCtx): Promise<SolvePlatform> {
  if (ctx.platform) return Promise.resolve(ctx.platform);
  if (!ctx.defaultPlatform) {
    ctx.defaultPlatform = import("./solve-node.js").then((mod) => mod.nodeSolvePlatform);
  }
  return ctx.defaultPlatform;
}

/** Resolve a source ref ONCE per solve (shared by digest + materialization). */
function resolveSourceCached(ref: string, ctx: SolveCtx): Promise<ResolvedImage> {
  let r = ctx.sources.get(ref);
  if (!r) {
    r = resolveSource(ref, ctx.store);
    ctx.sources.set(ref, r);
  }
  return r;
}

function localSourceCached(path: string, ctx: SolveCtx): Promise<LocalSource> {
  let r = ctx.locals.get(path);
  if (!r) {
    r = solvePlatform(ctx).then((platform) => platform.localSource(path));
    ctx.locals.set(path, r);
  }
  return r;
}

function httpSourceCached(
  url: string,
  expectedDigest: string | undefined,
  ctx: SolveCtx,
): Promise<HttpSource> {
  const key = `${url}\0${expectedDigest ?? ""}`;
  let r = ctx.httpSources.get(key);
  if (!r) {
    r = fetchHttpSource(url, expectedDigest);
    ctx.httpSources.set(key, r);
  }
  return r;
}

function gitSourceCached(
  repo: string,
  ref: string,
  dest: string,
  ctx: SolveCtx,
): Promise<GitSource> {
  const key = `${repo}\0${ref}\0${dest}`;
  let r = ctx.gitSources.get(key);
  if (!r) {
    r = solvePlatform(ctx).then((platform) => platform.gitSource(repo, ref, dest));
    ctx.gitSources.set(key, r);
  }
  return r;
}

const cacheableMemo = new WeakMap<BuildNode, boolean>();

/** Whether a node's result may be memoized (cache-SOUND). This is transitive:
 *  anything depending on an unsafe `exec` is unsafe too, otherwise a child node
 *  could cache one arbitrary result of a non-deterministic/network input under
 *  a stable Merkle key. Cache mount content stays outside the key; the mount
 *  identity is folded into the exec digest. */
function cacheable(node: BuildNode): boolean {
  const memo = cacheableMemo.get(node);
  if (memo !== undefined) return memo;
  const result = (() => {
    switch (node.op) {
      case "source":
      case "layer":
      case "cache":
        return true;
      case "local":
      case "http":
      case "git":
        return true;
      case "write":
      case "mkdir":
      case "rm":
      case "chmod":
      case "symlink":
        return cacheable(node.input);
      case "exec":
        return cacheable(node.input) && node.opts.net !== true && node.opts.deterministic !== false;
      case "copy":
        return cacheable(node.dest) && cacheable(node.src);
      case "merge":
        return cacheable(node.a) && cacheable(node.b);
      case "diff":
        return cacheable(node.lower) && cacheable(node.upper);
      case "image":
        return node.parts.every(cacheable);
    }
  })();
  cacheableMemo.set(node, result);
  return result;
}

/** Resolve a node to its image, reusing the memoized result when present. */
async function solve(node: BuildNode, ctx: SolveCtx): Promise<ResolvedImage> {
  const digest = await nodeDigest(node, ctx);
  const inFlight = ctx.solved.get(digest);
  if (inFlight) return inFlight;

  const resolved = solveOnce(node, digest, ctx);
  ctx.solved.set(digest, resolved);
  return resolved;
}

async function solveOnce(node: BuildNode, digest: string, ctx: SolveCtx): Promise<ResolvedImage> {
  const memoKey = `node-${digest}`;
  if (cacheable(node)) {
    const memo = await ctx.store.manifest(memoKey).catch(() => null);
    if (memo) {
      await emitProgress(ctx, { type: "cached", digest, op: node.op });
      return fromManifest(memo);
    }
  }
  await emitProgress(ctx, { type: "started", digest, op: node.op });
  try {
    const result = await materialize(node, ctx);
    if (cacheable(node)) {
      await ctx.store.putManifest(memoKey, {
        schema: 1,
        layers: result.layers,
        config: result.config,
      });
    }
    await emitProgress(ctx, { type: "completed", digest, op: node.op });
    return result;
  } catch (error) {
    await emitProgress(ctx, {
      type: "failed",
      digest,
      op: node.op,
      error: error instanceof Error ? error.message : String(error),
    });
    throw error;
  }
}

async function materialize(node: BuildNode, ctx: SolveCtx): Promise<ResolvedImage> {
  switch (node.op) {
    case "source":
      return resolveSourceCached(node.ref, ctx);
    case "layer": {
      const producer = await nodeDigest(node, ctx);
      const tar = await ctx.store.layer(node.ref);
      return { layers: [{ digest: node.ref, size: tar.length, producer }], config: {} };
    }
    case "local": {
      const { digest, tar } = await runLocalSource(node.path, node.dest, ctx);
      return {
        layers: [{ digest, size: tar.length, producer: await nodeDigest(node, ctx) }],
        config: {},
      };
    }
    case "http": {
      const { digest, tar } = await runHttpSource(node.url, node.dest, node.expectedDigest, ctx);
      return {
        layers: [{ digest, size: tar.length, producer: await nodeDigest(node, ctx) }],
        config: {},
      };
    }
    case "git": {
      const git = await gitSourceCached(node.repo, node.ref, node.dest, ctx);
      await ctx.store.put(git.tar);
      return {
        layers: [
          {
            digest: git.archiveDigest,
            size: git.tar.length,
            producer: await nodeDigest(node, ctx),
          },
        ],
        config: {},
      };
    }
    case "write":
    case "mkdir":
    case "rm":
    case "chmod":
    case "symlink":
    case "exec": {
      const base = await solve(node.input, ctx);
      const { digest, tar, config } = await runStep(base, node, ctx);
      return {
        layers: [
          ...base.layers,
          { digest, size: tar.length, producer: await nodeDigest(node, ctx) },
        ],
        config,
      };
    }
    case "copy": {
      const [dest, src] = await Promise.all([solve(node.dest, ctx), solve(node.src, ctx)]);
      const { digest, tar } = await runCopyStep(dest, src, node, ctx);
      return {
        layers: [
          ...dest.layers,
          { digest, size: tar.length, producer: await nodeDigest(node, ctx) },
        ],
        config: dest.config,
      };
    }
    case "merge": {
      const [a, b] = await Promise.all([solve(node.a, ctx), solve(node.b, ctx)]);
      return { layers: unionLayers(a, b), config: { ...a.config, ...b.config } };
    }
    case "diff": {
      const [lower, upper] = await Promise.all([solve(node.lower, ctx), solve(node.upper, ctx)]);
      const lowerSet = new Set(lower.layers.map((l) => l.producer));
      const upperSet = new Set(upper.layers.map((l) => l.producer));
      let ancestral = true;
      for (const producer of lowerSet) {
        if (!upperSet.has(producer)) {
          ancestral = false;
          break;
        }
      }
      if (ancestral) {
        return { layers: upper.layers.filter((l) => !lowerSet.has(l.producer)), config: {} };
      }
      const { digest, tar } = await runDiffStep(lower, upper, ctx);
      return {
        layers: [{ digest, size: tar.length, producer: await nodeDigest(node, ctx) }],
        config: {},
      };
    }
    case "image": {
      const parts = await Promise.all(node.parts.map((n) => solve(n, ctx)));
      return { layers: unionLayers(...parts), config: { ...mergeConfigs(parts), ...node.config } };
    }
    case "cache":
      // A cache node is a mount spec, not an image — it contributes no layers.
      return { layers: [], config: {} };
  }
}

function fromManifest(manifest: ImageManifest): ResolvedImage {
  return {
    layers: manifest.layers.map((layer) => {
      const producer = (layer as { producer?: unknown }).producer;
      return {
        digest: layer.digest,
        size: layer.size,
        producer: typeof producer === "string" ? producer : layer.digest,
      };
    }),
    config: manifest.config,
  };
}

function publicLayers(layers: readonly ResolvedLayer[]): { digest: string; size: number }[] {
  return layers.map(({ digest, size }) => ({ digest, size }));
}

function unionLayers(...images: ResolvedImage[]): ResolvedLayer[] {
  const seen = new Set<string>();
  const out: ResolvedLayer[] = [];
  for (const image of images) {
    for (const layer of image.layers) {
      if (seen.has(layer.producer)) continue;
      seen.add(layer.producer);
      out.push(layer);
    }
  }
  return out;
}

function mergeConfigs(images: readonly ResolvedImage[]): ImageConfig {
  return images.reduce<ImageConfig>((acc, image) => ({ ...acc, ...image.config }), {});
}

type RunNode = Extract<
  BuildNode,
  | { op: "write" }
  | { op: "mkdir" }
  | { op: "rm" }
  | { op: "chmod" }
  | { op: "symlink" }
  | { op: "exec" }
>;
type CopyNode = Extract<BuildNode, { op: "copy" }>;

/** Boot a VM from `base`, apply the node's op, and commit the overlay → a layer. */
async function runStep(
  base: ResolvedImage,
  node: RunNode,
  ctx: SolveCtx,
): Promise<{ digest: string; tar: Uint8Array; config: ImageConfig }> {
  const isExec = node.op === "exec";
  const det = isExec ? (node.opts.deterministic ?? true) : true;
  const config: ImageConfig = isExec
    ? {
        ...base.config,
        tier: node.opts.tier ?? DEFAULT_EXEC_TIER,
        ...(node.opts.budgetMib ? { budgetMib: node.opts.budgetMib } : {}),
        ...(node.opts.fuel ? { fuel: node.opts.fuel } : {}),
      }
    : base.config;
  const manifest: ImageManifest = { schema: 1, layers: publicLayers(base.layers), config };
  const mounts =
    isExec && node.opts.mounts
      ? await (await solvePlatform(ctx)).cacheMounts(node.opts.mounts)
      : [];

  const vm = await mc.create({
    image: manifest,
    store: ctx.store,
    kernel: await kernelBytes(ctx),
    deterministic: det,
    mounts,
    net: isExec ? node.opts.net === true : false,
  });
  try {
    switch (node.op) {
      case "write":
        await vm.fs.write(node.path, node.data);
        break;
      case "mkdir":
        await vm.fs.mkdir(node.path);
        break;
      case "rm":
        await vm.fs.rm(node.path);
        break;
      case "chmod":
        await vm.fs.chmod(node.path, node.mode);
        break;
      case "symlink":
        await vm.fs.symlink(node.target, node.link);
        break;
      case "exec": {
        const r = await vm.exec(node.cmd, {
          cwd: node.opts.cwd,
          env: node.opts.env,
          stdin: node.opts.stdin,
        });
        if (r.exitCode !== 0) {
          throw new Error(`llb.exec "${node.cmd}" failed (exit ${r.exitCode}): ${r.stderr}`);
        }
        break;
      }
    }
    const out = await vm.commit().asLayer();
    await ctx.store.put(out.tar); // persist the layer by digest
    return { ...out, config };
  } finally {
    await vm.close();
  }
}

/** Boot `dest` and `src`, copy through the typed VM filesystem API, and commit
 *  only the destination overlay. */
async function runCopyStep(
  dest: ResolvedImage,
  src: ResolvedImage,
  node: CopyNode,
  ctx: SolveCtx,
): Promise<{ digest: string; tar: Uint8Array }> {
  const kernel = await kernelBytes(ctx);
  const destVm = await mc.create({
    image: { schema: 1, layers: publicLayers(dest.layers), config: dest.config },
    store: ctx.store,
    kernel,
    deterministic: true,
  });
  let srcVm: Awaited<ReturnType<typeof mc.create>> | null = null;
  try {
    srcVm = await mc.create({
      image: { schema: 1, layers: publicLayers(src.layers), config: src.config },
      store: ctx.store,
      kernel,
      deterministic: true,
    });
    for (const path of node.paths) {
      await copyTree(
        srcVm.fs,
        destVm.fs,
        normalizeVmPath(path.from, "copy source path"),
        normalizeVmPath(path.to, "copy destination path"),
      );
    }
    const out = await destVm.commit().asLayer();
    await ctx.store.put(out.tar);
    return out;
  } finally {
    if (srcVm) await srcVm.close();
    await destVm.close();
  }
}

/** Materialize a non-ancestral diff by editing a VM booted from `lower` until it
 *  matches `upper`, then committing the overlay. Deletes become real whiteouts
 *  because they are performed through the VM filesystem. */
async function runDiffStep(
  lower: ResolvedImage,
  upper: ResolvedImage,
  ctx: SolveCtx,
): Promise<{ digest: string; tar: Uint8Array }> {
  const candidatePaths = await diffCandidatePaths(lower, upper, ctx);
  if (candidatePaths.length === 0) {
    const tar = EMPTY_TAR.slice();
    const digest = await ctx.store.put(tar);
    return { digest, tar };
  }

  const kernel = await kernelBytes(ctx);
  const lowerVm = await mc.create({
    image: { schema: 1, layers: publicLayers(lower.layers), config: lower.config },
    store: ctx.store,
    kernel,
    deterministic: true,
  });
  let upperVm: Awaited<ReturnType<typeof mc.create>> | null = null;
  try {
    upperVm = await mc.create({
      image: { schema: 1, layers: publicLayers(upper.layers), config: upper.config },
      store: ctx.store,
      kernel,
      deterministic: true,
    });
    for (const path of candidatePaths) {
      await syncTreeDiff(upperVm.fs, lowerVm.fs, path);
    }
    const out = await lowerVm.commit().asLayer();
    await ctx.store.put(out.tar);
    return out;
  } finally {
    if (upperVm) await upperVm.close();
    await lowerVm.close();
  }
}

async function diffCandidatePaths(
  lower: ResolvedImage,
  upper: ResolvedImage,
  ctx: SolveCtx,
): Promise<string[]> {
  const lowerProducers = new Set(lower.layers.map((layer) => layer.producer));
  const upperProducers = new Set(upper.layers.map((layer) => layer.producer));
  const pathSet = new Set<string>();
  const parsed = new Map<string, Promise<string[]>>();

  async function addLayer(layer: ResolvedLayer): Promise<void> {
    let paths = parsed.get(layer.digest);
    if (!paths) {
      paths = ctx.store.layer(layer.digest).then(layerCandidatePaths);
      parsed.set(layer.digest, paths);
    }
    for (const path of await paths) pathSet.add(path);
  }

  for (const layer of lower.layers) {
    if (!upperProducers.has(layer.producer)) await addLayer(layer);
  }
  for (const layer of upper.layers) {
    if (!lowerProducers.has(layer.producer)) await addLayer(layer);
  }

  return [...pathSet]
    .filter((path) => path !== "/")
    .sort((a, b) => pathDepth(a) - pathDepth(b) || a.localeCompare(b));
}

function layerCandidatePaths(tar: Uint8Array): string[] {
  const paths = new Set<string>();
  forEachTarEntry(tar, (entry) => {
    const whiteout = whiteoutTarget(entry.path);
    paths.add(whiteout ?? entry.path);
  });
  return [...paths];
}

interface TarEntry {
  path: string;
  typeflag: number;
}

function forEachTarEntry(tar: Uint8Array, fn: (entry: TarEntry) => void): void {
  let offset = 0;
  while (offset + TAR_BLOCK <= tar.length) {
    if (isZeroBlock(tar, offset)) return;

    const size = tarOctal(tar, offset + 124, 12);
    const typeflag = tar[offset + 156] || "0".charCodeAt(0);
    const path = tarPath(tar, offset);
    if (path && !tarMetadataEntry(typeflag)) fn({ path, typeflag });

    offset += TAR_BLOCK + Math.ceil(size / TAR_BLOCK) * TAR_BLOCK;
  }
}

function tarMetadataEntry(typeflag: number): boolean {
  return typeflag === 0x67 || typeflag === 0x78 || typeflag === 0x4b || typeflag === 0x4c;
}

function tarPath(tar: Uint8Array, offset: number): string | null {
  const name = tarString(tar, offset, 100);
  const prefix = tarString(tar, offset + 345, 155);
  const raw = prefix ? `${prefix}/${name}` : name;
  return normalizeTarPath(raw);
}

function normalizeTarPath(raw: string): string | null {
  let path = raw;
  while (path.startsWith("./")) path = path.slice(2);
  while (path.startsWith("/")) path = path.slice(1);
  while (path.endsWith("/") && path.length > 1) path = path.slice(0, -1);
  const parts: string[] = [];
  for (const part of path.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..")
      throw new Error(`llb.diff layer contains parent path escape: ${JSON.stringify(raw)}`);
    parts.push(part);
  }
  return parts.length ? `/${parts.join("/")}` : null;
}

function whiteoutTarget(path: string): string | null {
  const slash = path.lastIndexOf("/");
  const parent = slash <= 0 ? "/" : path.slice(0, slash);
  const name = slash < 0 ? path : path.slice(slash + 1);
  if (!name.startsWith(".wh.")) return null;
  if (name === ".wh..wh..opq") return parent;
  const target = name.slice(".wh.".length);
  if (!target) return null;
  return parent === "/" ? `/${target}` : `${parent}/${target}`;
}

function tarString(tar: Uint8Array, start: number, length: number): string {
  let end = start;
  const limit = Math.min(start + length, tar.length);
  while (end < limit && tar[end] !== 0) end++;
  return td.decode(tar.subarray(start, end));
}

function tarOctal(tar: Uint8Array, start: number, length: number): number {
  const text = tarString(tar, start, length).trim();
  if (!text) return 0;
  const value = Number.parseInt(text, 8);
  if (!Number.isFinite(value))
    throw new Error(`llb.diff layer contains invalid tar size: ${JSON.stringify(text)}`);
  return value;
}

function isZeroBlock(tar: Uint8Array, offset: number): boolean {
  for (let i = 0; i < TAR_BLOCK; i++) {
    if (tar[offset + i] !== 0) return false;
  }
  return true;
}

function pathDepth(path: string): number {
  return path === "/" ? 0 : path.split("/").length - 1;
}

async function runLocalSource(
  hostPath: string,
  destPath: string,
  ctx: SolveCtx,
): Promise<{ digest: string; tar: Uint8Array }> {
  const local = await localSourceCached(hostPath, ctx);
  const dest = normalizeVmPath(destPath, "local destination");
  const vm = await mc.create({
    image: EMPTY_TAR,
    store: ctx.store,
    kernel: await kernelBytes(ctx),
    deterministic: true,
  });
  try {
    await writeLocalEntries(vm.fs, dest, local.entries);
    const out = await vm.commit().asLayer();
    await ctx.store.put(out.tar);
    return out;
  } finally {
    await vm.close();
  }
}

async function runHttpSource(
  url: string,
  destPath: string,
  expectedDigest: string | undefined,
  ctx: SolveCtx,
): Promise<{ digest: string; tar: Uint8Array }> {
  const source = await httpSourceCached(url, expectedDigest, ctx);
  const dest = normalizeVmPath(destPath, "http destination");
  const vm = await mc.create({
    image: EMPTY_TAR,
    store: ctx.store,
    kernel: await kernelBytes(ctx),
    deterministic: true,
  });
  try {
    await ensureDir(vm.fs, parentVmPath(dest));
    await vm.fs.write(dest, source.bytes);
    const out = await vm.commit().asLayer();
    await ctx.store.put(out.tar);
    return out;
  } finally {
    await vm.close();
  }
}

async function fetchHttpSource(
  url: string,
  expectedDigest: string | undefined,
): Promise<HttpSource> {
  const parsed = new URL(url);
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new Error(`llb.http URL must use http or https: ${url}`);
  }
  const response = await fetch(parsed);
  if (!response.ok) {
    throw new Error(`llb.http ${url} failed: ${response.status} ${response.statusText}`);
  }
  const bytes = new Uint8Array(await response.arrayBuffer());
  const digest = `sha256:${await sha256hex(bytes)}`;
  if (expectedDigest !== undefined && expectedDigest !== digest) {
    throw new Error(
      `llb.http digest mismatch for ${url}: expected ${expectedDigest}, got ${digest}`,
    );
  }
  return { digest, bytes };
}

async function writeLocalEntries(
  fs: VmFs,
  dest: string,
  entries: readonly LocalEntry[],
): Promise<void> {
  await ensureDir(fs, dest);
  for (const entry of entries) {
    if (!entry.rel) {
      if (entry.kind === "dir" && entry.mode !== undefined && dest !== "/") {
        await fs.chmod(dest, entry.mode);
      }
      continue;
    }
    const out = vmJoin(dest, entry.rel);
    switch (entry.kind) {
      case "dir":
        await ensureDir(fs, out);
        if (entry.mode !== undefined && out !== "/") await fs.chmod(out, entry.mode);
        break;
      case "file":
        await ensureDir(fs, parentVmPath(out));
        await fs.write(out, entry.bytes);
        if (entry.mode !== undefined) await fs.chmod(out, entry.mode);
        break;
      case "symlink":
        await ensureDir(fs, parentVmPath(out));
        await fs.symlink(entry.target, out);
        break;
    }
  }
}

function normalizeVmPath(path: string, field: string): string {
  if (!path.startsWith("/"))
    throw new Error(`llb.copy ${field} must be absolute: ${JSON.stringify(path)}`);
  if (path.includes("\0")) throw new Error(`llb.copy ${field} contains NUL`);
  const parts: string[] = [];
  for (const part of path.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..")
      throw new Error(`llb.copy ${field} must not contain '..': ${JSON.stringify(path)}`);
    parts.push(part);
  }
  return `/${parts.join("/")}`;
}

function vmJoin(parent: string, name: string): string {
  return parent === "/" ? `/${name}` : `${parent}/${name}`;
}

function parentVmPath(path: string): string {
  if (path === "/") return "/";
  const i = path.lastIndexOf("/");
  return i <= 0 ? "/" : path.slice(0, i);
}

async function ensureDir(fs: VmFs, path: string): Promise<void> {
  if (path === "/") return;
  const parts = path.slice(1).split("/");
  let cur = "";
  for (const part of parts) {
    cur = `${cur}/${part}`;
    try {
      const stat = await fs.stat(cur);
      if (!stat.isDir) throw new Error(`llb.copy destination parent is not a directory: ${cur}`);
    } catch (e) {
      if (!/ENOENT|not found|no such|errno 44/i.test(String(e))) throw e;
      await fs.mkdir(cur);
    }
  }
}

async function copyTree(src: VmFs, dest: VmFs, from: string, to: string): Promise<void> {
  const stat = await src.stat(from);
  if (stat.isSymlink) {
    await ensureDir(dest, parentVmPath(to));
    await dest.symlink(await src.readlink(from), to);
    return;
  }
  if (stat.isDir) {
    await ensureDir(dest, to);
    if (to !== "/") await dest.chmod(to, stat.mode);
    for (const entry of await src.ls(from)) {
      await copyTree(src, dest, vmJoin(from, entry.name), vmJoin(to, entry.name));
    }
    return;
  }
  await ensureDir(dest, parentVmPath(to));
  await dest.write(to, await src.read(from));
  await dest.chmod(to, stat.mode);
}

async function syncTreeDiff(src: VmFs, dest: VmFs, path: string): Promise<void> {
  const [srcStat, destStat] = await Promise.all([maybeStat(src, path), maybeStat(dest, path)]);
  if (!srcStat) {
    if (destStat) await removeTree(dest, path);
    return;
  }
  if (!destStat) {
    await copyTreeWithMode(src, dest, path, path);
    return;
  }

  if (srcStat.isSymlink || destStat.isSymlink) {
    if (srcStat.isSymlink && destStat.isSymlink) {
      const [srcTarget, destTarget] = await Promise.all([src.readlink(path), dest.readlink(path)]);
      if (srcTarget === destTarget) return;
    }
    await removeTree(dest, path);
    await copyTreeWithMode(src, dest, path, path);
    return;
  }

  if (srcStat.isDir !== destStat.isDir) {
    await removeTree(dest, path);
    await copyTreeWithMode(src, dest, path, path);
    return;
  }

  if (srcStat.isDir) {
    if (path !== "/" && srcStat.mode !== destStat.mode) await dest.chmod(path, srcStat.mode);
    return;
  }

  if (srcStat.mode !== destStat.mode || !(await sameFile(src, dest, path))) {
    await dest.write(path, await src.read(path));
    await dest.chmod(path, srcStat.mode);
  }
}

async function copyTreeWithMode(src: VmFs, dest: VmFs, from: string, to: string): Promise<void> {
  const stat = await src.stat(from);
  if (stat.isSymlink) {
    await ensureDir(dest, parentVmPath(to));
    await dest.symlink(await src.readlink(from), to);
    return;
  }
  if (stat.isDir) {
    await ensureDir(dest, to);
    if (to !== "/") await dest.chmod(to, stat.mode);
    for (const entry of await src.ls(from)) {
      await copyTreeWithMode(src, dest, vmJoin(from, entry.name), vmJoin(to, entry.name));
    }
    return;
  }
  await ensureDir(dest, parentVmPath(to));
  await dest.write(to, await src.read(from));
  await dest.chmod(to, stat.mode);
}

async function removeTree(fs: VmFs, path: string): Promise<void> {
  if (path === "/") throw new Error("llb.diff cannot remove the VM root");
  const stat = await fs.stat(path);
  if (stat.isDir && !stat.isSymlink) {
    for (const entry of await fs.ls(path)) {
      await removeTree(fs, vmJoin(path, entry.name));
    }
  }
  await fs.rm(path);
}

async function maybeStat(fs: VmFs, path: string) {
  try {
    return await fs.stat(path);
  } catch (e) {
    if (/ENOENT|not found|no such|errno 44/i.test(String(e))) return null;
    throw e;
  }
}

async function sameFile(aFs: VmFs, bFs: VmFs, path: string): Promise<boolean> {
  const [a, b] = await Promise.all([aFs.read(path), bFs.read(path)]);
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

function sameStat(a: StatResult, b: StatResult): boolean {
  return (
    a.size === b.size && a.isDir === b.isDir && a.isSymlink === b.isSymlink && a.mode === b.mode
  );
}

/** Resolve an `llb.source` ref to a layer stack + config. A named flavor / built
 *  image uses its stored manifest (preserving the runtime contract); a digest /
 *  `base:latest` is content-addressed from its resolved bytes. */
async function resolveSource(ref: string, store: ContentStore): Promise<ResolvedImage> {
  if (!ref.startsWith("sha256:") && ref !== "base:latest") {
    const m = await store.manifest(ref).catch(() => null);
    if (m) return fromManifest(m);
  }
  const tars = (await resolveImage(ref, store)) ?? [];
  const layers = await Promise.all(
    tars.map(async (t) => {
      const digest = await store.put(t);
      return { digest, size: t.length, producer: digest };
    }),
  );
  return { layers, config: {} };
}

// --------------------------------------------------------------------------
// Result selectors (`llb.commit(state).asLayer() / .asSnapshot()`).
// --------------------------------------------------------------------------

/** The portable `.tar` layer the node produced (its tip layer). */
export async function commitLayer(
  node: BuildNode,
  opts: SolveOptions = {},
): Promise<{ digest: string; tar: Uint8Array }> {
  const store = opts.store ?? defaultStore();
  const resolved = await solve(node, newCtx(store, opts));
  const tip = resolved.layers[resolved.layers.length - 1];
  if (!tip) throw new Error("llb.commit().asLayer(): the node produced no layer");
  return { digest: tip.digest, tar: await store.layer(tip.digest) };
}

/** The full resolved image (the whole layer stack + runtime config) — boot it with
 *  `mc.create({ image })`. */
export async function commitImage(
  node: BuildNode,
  opts: SolveOptions = {},
): Promise<ImageManifest> {
  return (await solveImageWithMetadata(node, opts)).manifest;
}

export async function commitImageWithBuildRecord(
  node: BuildNode,
  definitionBytes: Uint8Array,
  blobRefs: readonly string[],
  opts: SolveOptions = {},
): Promise<ImageManifest> {
  const solved = await solveImageWithMetadata(node, opts);
  return {
    ...solved.manifest,
    build: buildRecord(
      solved.manifest,
      definitionBytes,
      `sha256:${await sha256hex(definitionBytes)}`,
      blobRefs,
      solved.rootDigest,
      solved.kernelDigest,
    ),
  };
}

async function solveImageWithMetadata(
  node: BuildNode,
  opts: SolveOptions,
): Promise<{ manifest: ImageManifest; rootDigest: string; kernelDigest: string }> {
  const store = opts.store ?? defaultStore();
  const ctx = newCtx(store, opts);
  const resolved = await solve(node, ctx);
  return {
    manifest: { schema: 1, layers: publicLayers(resolved.layers), config: resolved.config },
    rootDigest: `sha256:${await nodeDigest(node, ctx)}`,
    kernelDigest: `sha256:${await kernelDigest(ctx)}`,
  };
}

function buildRecord(
  manifest: ImageManifest,
  definitionBytes: Uint8Array,
  definitionDigest: string,
  blobRefs: readonly string[],
  rootDigest: string,
  kernelDigest: string,
): BuildRecord {
  return {
    schema: 1,
    definition: {
      encoding: "mc.llb.definition.v1",
      digest: definitionDigest,
      bytes: [...definitionBytes],
    },
    rootDigest,
    kernelDigest,
    storeRefs: {
      layers: manifest.layers.map((layer) => ({ digest: layer.digest, size: layer.size })),
      blobs: [...new Set(blobRefs)].sort(),
    },
  };
}

/** The whole-VM memory image of the node's result, memoized by node digest
 *  for cache-safe DAGs so a re-solve can restore instead of re-stacking layers. */
export async function commitSnapshot(
  node: BuildNode,
  opts: SolveOptions = {},
): Promise<Uint8Array> {
  const store = opts.store ?? defaultStore();
  const ctx = newCtx(store, opts);
  const digest = await nodeDigest(node, ctx);
  const snapshotKey = `snapshot-${await sha256hex(cat(digest, await kernelDigest(ctx), await warmDigest(opts.warm)))}`;
  const canCache = cacheable(node);
  if (canCache && store.snapshot) {
    const cached = await store.snapshot(snapshotKey).catch(() => null);
    if (cached) return cached;
  }
  const resolved = await solve(node, ctx);
  const manifest: ImageManifest = {
    schema: 1,
    layers: publicLayers(resolved.layers),
    config: resolved.config,
  };
  const vm = await mc.create({
    image: manifest,
    store,
    kernel: await kernelBytes(ctx),
    deterministic: true,
  });
  try {
    await applyWarm(vm, opts.warm);
    const inflight = await vm.inflightEgress();
    if (inflight !== 0) {
      throw new Error(
        `llb.commit().asSnapshot(): warm-up left ${inflight} host-egress operation(s) in flight`,
      );
    }
    const snap = await vm.snapshot();
    if (canCache && store.putSnapshot) await store.putSnapshot(snapshotKey, snap);
    return snap;
  } finally {
    await vm.close();
  }
}

async function applyWarm(vm: Vm, warm: readonly WarmDirective[] | undefined): Promise<void> {
  for (const directive of warm ?? []) {
    switch (directive.kind) {
      case "exec": {
        const result = await vm.exec(directive.cmd, {
          cwd: directive.cwd,
          env: directive.env,
          stdin: directive.stdin,
        });
        if (result.exitCode !== 0) {
          throw new Error(
            `llb warm exec "${directive.cmd}" failed (exit ${result.exitCode}): ${result.stderr}`,
          );
        }
        break;
      }
      case "svc":
        await vm.serviceCall(directive.name, directive.request ?? new Uint8Array());
        break;
    }
  }
}
