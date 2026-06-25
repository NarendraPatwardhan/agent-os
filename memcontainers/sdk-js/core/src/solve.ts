// The `llb` solver. Walks the build DAG, computing each node's Merkle
// digest `sha256(op ⊕ input-digests ⊕ args)` and MEMOIZING the resolved image by
// that digest in the content store — edit one node and only its downstream
// sub-DAG re-runs. A node materializes by booting a fresh VM from its input's
// layers, applying the op (`vm.fs.write` / `vm.exec`), and `commit()`-ing the
// overlay into a new layer. `exec` nodes default to the deterministic
// clock/RNG so their layer digest is reproducible — making the content-addressed
// cache SOUND (a node that opts into net/non-determinism is never memoized).

import { mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mc, resolveImage } from "./memcontainer.js";
import { defaultStore } from "./store.js";
import { hostDir } from "./drivers.js";
import type { BuildNode, BuildState } from "./llb.js";
import type { ContentStore, ImageConfig, ImageManifest, MountSpec } from "./types.js";

/** A resolved image: an ordered layer stack + the runtime contract. */
interface ResolvedImage {
  layers: { digest: string; size: number }[];
  config: ImageConfig;
}

export interface SolveOptions {
  /** Content store for memoization + layer/snapshot persistence. Default
   *  {@link defaultStore}. */
  store?: ContentStore;
}

// --------------------------------------------------------------------------
// Merkle digests (the cache keys).
// --------------------------------------------------------------------------

const te = new TextEncoder();

async function sha256hex(data: Uint8Array): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", data as Uint8Array<ArrayBuffer>));
  let s = "";
  for (const b of h) s += b.toString(16).padStart(2, "0");
  return s;
}

/** Concatenate parts with NUL separators (a non-ambiguous canonical encoding). */
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

/** The node's content-addressed digest (the cache key), memoized PER SOLVE. A
 *  `source`'s digest folds in its RESOLVED layer digests (not the ref string), so
 *  a mutable ref — `base:latest`, a flavor name, a `/net/…` URL — whose bytes
 *  change moves every downstream key (the BuildKit tag→digest discipline). It is
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
  switch (node.op) {
    case "source": {
      // Content-address the source by its RESOLVED layers, not the ref string —
      // a `sha256:` ref resolves to itself (stays exact), a mutable name/URL
      // resolves to its current bytes (so a changed base busts the cache).
      const resolved = await resolveSourceCached(node.ref, ctx);
      return sha256hex(cat("source", ...resolved.layers.map((l) => l.digest)));
    }
    case "layer":
      // A `sha256:` layer digest is already immutable content.
      return sha256hex(cat("layer", node.ref));
    case "write":
      return sha256hex(cat("write", await nodeDigest(node.input, ctx), node.path, await sha256hex(node.data)));
    case "exec": {
      const mountDigests = node.opts.mounts
        ? await Promise.all(node.opts.mounts.map((m) => nodeDigest(m.node, ctx)))
        : [];
      const args = JSON.stringify({
        tier: node.opts.tier ?? null,
        budgetMib: node.opts.budgetMib ?? null,
        fuel: node.opts.fuel ?? null,
        deterministic: node.opts.deterministic ?? true,
        net: node.opts.net ?? false,
        mounts: mountDigests,
      });
      return sha256hex(cat("exec", await nodeDigest(node.input, ctx), node.cmd, args));
    }
    case "merge":
      return sha256hex(cat("merge", await nodeDigest(node.a, ctx), await nodeDigest(node.b, ctx)));
    case "diff":
      return sha256hex(cat("diff", await nodeDigest(node.lower, ctx), await nodeDigest(node.upper, ctx)));
    case "image": {
      const parts = await Promise.all(node.parts.map((n) => nodeDigest(n, ctx)));
      return sha256hex(cat("image", ...parts, JSON.stringify(node.config)));
    }
    case "cache":
      return sha256hex(cat("cache", node.path));
  }
}

// --------------------------------------------------------------------------
// The solver.
// --------------------------------------------------------------------------

interface SolveCtx {
  store: ContentStore;
  /** Per-solve digest memo (keyed by node; valid because one store per ctx). */
  digests: Map<BuildNode, Promise<string>>;
  /** Per-solve resolved-source memo (keyed by ref) so a source resolves ONCE —
   *  its content feeds both the cache key and the materialized layers (no double
   *  fetch for a `/net` source). */
  sources: Map<string, Promise<ResolvedImage>>;
}

/** A fresh solve context (its own digest + source memos). */
function newCtx(store: ContentStore): SolveCtx {
  return { store, digests: new Map(), sources: new Map() };
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

const cacheableMemo = new WeakMap<BuildNode, boolean>();

/** Whether a node's result may be memoized (cache-SOUND). This is transitive:
 *  anything depending on an unsafe `exec` is unsafe too, otherwise a child node
 *  could cache one arbitrary result of a non-deterministic/network/cache-mount
 *  input under a stable Merkle key. */
function cacheable(node: BuildNode): boolean {
  const memo = cacheableMemo.get(node);
  if (memo !== undefined) return memo;
  const result = (() => {
    switch (node.op) {
      case "source":
      case "layer":
      case "cache":
        return true;
      case "write":
        return cacheable(node.input);
      case "exec":
        return (
          cacheable(node.input) &&
          node.opts.net !== true &&
          node.opts.deterministic !== false &&
          !node.opts.mounts?.length
        );
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
  const memoKey = `node-${digest}`;
  if (cacheable(node)) {
    const memo = await ctx.store.manifest(memoKey).catch(() => null);
    if (memo) return { layers: memo.layers, config: memo.config };
  }
  const result = await materialize(node, ctx);
  if (cacheable(node)) {
    await ctx.store.putManifest(memoKey, { schema: 1, layers: result.layers, config: result.config });
  }
  return result;
}

async function materialize(node: BuildNode, ctx: SolveCtx): Promise<ResolvedImage> {
  switch (node.op) {
    case "source":
      return resolveSourceCached(node.ref, ctx);
    case "layer": {
      const tar = await ctx.store.layer(node.ref);
      return { layers: [{ digest: node.ref, size: tar.length }], config: {} };
    }
    case "write":
    case "exec": {
      const base = await solve(node.input, ctx);
      const { digest, tar } = await runStep(base, node, ctx);
      return { layers: [...base.layers, { digest, size: tar.length }], config: base.config };
    }
    case "merge": {
      const a = await solve(node.a, ctx);
      const b = await solve(node.b, ctx);
      return { layers: [...a.layers, ...b.layers], config: { ...a.config, ...b.config } };
    }
    case "diff": {
      const lower = await solve(node.lower, ctx);
      const upper = await solve(node.upper, ctx);
      const lowerSet = new Set(lower.layers.map((l) => l.digest));
      return { layers: upper.layers.filter((l) => !lowerSet.has(l.digest)), config: {} };
    }
    case "image": {
      const parts = await Promise.all(node.parts.map((n) => solve(n, ctx)));
      return { layers: parts.flatMap((p) => p.layers), config: node.config };
    }
    case "cache":
      // A cache node is a mount spec, not an image — it contributes no layers.
      return { layers: [], config: {} };
  }
}

type RunNode = Extract<BuildNode, { op: "write" } | { op: "exec" }>;

/** Boot a VM from `base`, apply the node's op, and commit the overlay → a layer. */
async function runStep(base: ResolvedImage, node: RunNode, ctx: SolveCtx): Promise<{ digest: string; tar: Uint8Array }> {
  const isExec = node.op === "exec";
  const det = isExec ? node.opts.deterministic ?? true : true;
  const config: ImageConfig = isExec
    ? {
        ...base.config,
        ...(node.opts.tier ? { tier: node.opts.tier } : {}),
        ...(node.opts.budgetMib ? { budgetMib: node.opts.budgetMib } : {}),
        ...(node.opts.fuel ? { fuel: node.opts.fuel } : {}),
      }
    : base.config;
  const manifest: ImageManifest = { schema: 1, layers: base.layers, config };
  const mounts = isExec && node.opts.mounts ? cacheMounts(node.opts.mounts) : [];

  const vm = await mc.create({
    image: manifest,
    store: ctx.store,
    deterministic: det,
    mounts,
    net: isExec ? node.opts.net === true : false,
  });
  try {
    if (node.op === "write") {
      await vm.fs.write(node.path, node.data);
    } else {
      const r = await vm.exec(node.cmd);
      if (r.exitCode !== 0) {
        throw new Error(`llb.exec "${node.cmd}" failed (exit ${r.exitCode}): ${r.stderr}`);
      }
    }
    const out = await vm.commit().asLayer();
    await ctx.store.put(out.tar); // persist the layer by digest
    return out;
  } finally {
    await vm.close();
  }
}

/** Persistent cache mounts for an `exec` step (`llb.cache(path)` → a host dir that
 *  survives across builds, keyed by the cache path). */
function cacheMounts(mounts: BuildState[]): MountSpec[] {
  const root = process.env.MC_BUILD_CACHE ?? join(tmpdir(), "mc-build-cache");
  const specs: MountSpec[] = [];
  for (const m of mounts) {
    if (m.node.op !== "cache") continue;
    const path = m.node.path;
    const dir = join(root, path.replace(/[^A-Za-z0-9._-]/g, "_"));
    mkdirSync(dir, { recursive: true });
    specs.push({ path, driver: hostDir({ root: dir }) });
  }
  return specs;
}

/** Resolve an `llb.source` ref to a layer stack + config. A named flavor / built
 *  image uses its stored manifest (preserving the runtime contract); a digest /
 *  URL / `base:latest` is content-addressed from its resolved bytes. */
async function resolveSource(ref: string, store: ContentStore): Promise<ResolvedImage> {
  if (!ref.startsWith("sha256:") && !ref.startsWith("/net/") && ref !== "base:latest") {
    const m = await store.manifest(ref).catch(() => null);
    if (m) return { layers: m.layers, config: m.config };
  }
  const tars = (await resolveImage(ref, store)) ?? [];
  const layers = await Promise.all(
    tars.map(async (t) => ({ digest: await store.put(t), size: t.length })),
  );
  return { layers, config: {} };
}

// --------------------------------------------------------------------------
// Result selectors (`llb.commit(state).asLayer() / .asSnapshot()`).
// --------------------------------------------------------------------------

/** The portable `.tar` layer the node produced (its tip layer). */
export async function commitLayer(node: BuildNode, opts: SolveOptions = {}): Promise<{ digest: string; tar: Uint8Array }> {
  const store = opts.store ?? defaultStore();
  const resolved = await solve(node, newCtx(store));
  const tip = resolved.layers[resolved.layers.length - 1];
  if (!tip) throw new Error("llb.commit().asLayer(): the node produced no layer");
  return { digest: tip.digest, tar: await store.layer(tip.digest) };
}

/** The full resolved image (the whole layer stack + runtime config) — boot it with
 *  `mc.create({ image })`. */
export async function commitImage(node: BuildNode, opts: SolveOptions = {}): Promise<ImageManifest> {
  const store = opts.store ?? defaultStore();
  const resolved = await solve(node, newCtx(store));
  return { schema: 1, layers: resolved.layers, config: resolved.config };
}

/** The whole-VM memory image of the node's result, memoized by node digest
 *  for cache-safe DAGs so a re-solve can restore instead of re-stacking layers. */
export async function commitSnapshot(node: BuildNode, opts: SolveOptions = {}): Promise<Uint8Array> {
  const store = opts.store ?? defaultStore();
  const ctx = newCtx(store);
  const digest = await nodeDigest(node, ctx);
  const canCache = cacheable(node);
  if (canCache && store.snapshot) {
    const cached = await store.snapshot(`node-${digest}`).catch(() => null);
    if (cached) return cached;
  }
  const resolved = await solve(node, ctx);
  const manifest: ImageManifest = { schema: 1, layers: resolved.layers, config: resolved.config };
  const vm = await mc.create({ image: manifest, store, deterministic: true });
  try {
    const snap = await vm.snapshot();
    if (canCache && store.putSnapshot) await store.putSnapshot(`node-${digest}`, snap);
    return snap;
  } finally {
    await vm.close();
  }
}
