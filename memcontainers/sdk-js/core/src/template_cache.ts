//! Boot-stack template full cache (PERF-011 / SYSTEMS.md §8).
//!
//! A template is one full MCSN for a **boot stack class**:
//! `(kernel_digest, ordered digests of every layer actually passed to withLayers)`.
//! That includes the image flavor stack **and** create-time sidecar guest layers
//! (guest layers are VFS content in the MCSN, not host-only attachments).
//!
//! Live VMs bind `active_base` to the template's content digest and keep private
//! linear memory — they do not each retain a private full.
//!
//! Fill policy:
//! - **on_demand**: first ready boot of a class captures one full and caches it;
//!   later boots of the same class reuse it. Concurrent first fills share one in-flight promise.
//! - **prepopulated** (server): only look up; never mint at create time.
//! - **off**: do not bind a template at create.
//!
//! Incremental capture must never invent a baseline (see EmbeddedBackend.snapshot).

import type { ContentStore, Runtime } from "./types.js";
import { parseSnapshot } from "@mc/contracts/snapshot";

/** How boot-stack template fulls are obtained when a VM becomes ready. */
export type TemplateFillPolicy = "on_demand" | "prepopulated" | "off";

export type TemplateHit = { digest: string; bytes: Uint8Array };

/** Session L1: class key → content digest (`sha256:…`). Survives for the page/process. */
const sessionClassIndex = new Map<string, string>();

/** In-flight ensure work so concurrent first creates of the same class share one capture. */
const inflightEnsure = new Map<string, Promise<TemplateHit | null>>();

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as Uint8Array<ArrayBuffer>));
  let hex = "";
  for (const b of h) hex += b.toString(16).padStart(2, "0");
  return hex;
}

function hexOf(digest: Uint8Array): string {
  let hex = "";
  for (const b of digest) hex += b.toString(16).padStart(2, "0");
  return hex;
}

/**
 * Durable index key for `ContentStore.snapshot` / `putSnapshot`.
 * Those APIs only allow `[A-Za-z0-9._-]`, so the full class key is hashed.
 */
async function durableIndexKey(classKey: string): Promise<string> {
  const hex = await sha256Hex(new TextEncoder().encode(classKey));
  return `mc-template.${hex}`;
}

/**
 * Default fill policy (PERF-011 create-latency):
 * - **browser**: on_demand when a snapshot-capable store is available (density goal).
 * - **local / other**: on_demand only when the caller **explicitly** passed a store
 *   (signal they want snapshot/template support); otherwise off so plain boots
 *   do not pay a full MCSN capture.
 */
export function defaultTemplateFill(
  runtime?: Runtime,
  explicitStore = false,
): TemplateFillPolicy {
  if (runtime === "browser") return "on_demand";
  if (explicitStore) return "on_demand";
  return "off";
}

/**
 * Stable boot-stack class key for the template index.
 *
 * `layerDigests` must be `sha256:…` of **every** layer passed to `withLayers`, in
 * stack order: image layers then create-time sidecar guest layers. Host-only
 * sidecar grants (no guest layer) do not appear here.
 */
export function imageClassKey(
  kernelDigest: Uint8Array,
  layerDigests: readonly string[],
  warmRecipe = "",
): string {
  return `${hexOf(kernelDigest)}|${layerDigests.join(",")}|${warmRecipe}`;
}

/** Content digests of each layer's tar bytes (stack order). */
export async function layerContentDigests(layers: readonly Uint8Array[]): Promise<string[]> {
  return Promise.all(layers.map(async (layer) => `sha256:${await sha256Hex(layer)}`));
}

function requireSnapshotObjects(store: ContentStore): {
  snapshotObject: (digest: string) => Promise<Uint8Array>;
  putSnapshotObject: (snapshot: Uint8Array) => Promise<string>;
} {
  if (!store.snapshotObject || !store.putSnapshotObject) {
    throw new Error(
      "boot-stack templates require a content store with snapshotObject/putSnapshotObject",
    );
  }
  return {
    snapshotObject: store.snapshotObject.bind(store),
    putSnapshotObject: store.putSnapshotObject.bind(store),
  };
}

/**
 * Look up a cached template full for `classKey` without capturing.
 * Returns null on miss.
 */
export async function lookupImageTemplate(
  store: ContentStore,
  classKey: string,
): Promise<TemplateHit | null> {
  const objects = requireSnapshotObjects(store);

  const sessionDigest = sessionClassIndex.get(classKey);
  if (sessionDigest) {
    try {
      const bytes = await objects.snapshotObject(sessionDigest);
      return { digest: sessionDigest, bytes };
    } catch {
      sessionClassIndex.delete(classKey);
    }
  }

  if (store.snapshot) {
    const indexed = await store.snapshot(await durableIndexKey(classKey));
    if (indexed) {
      const view = parseSnapshot(indexed);
      if (view.kind !== "full") {
        throw new Error("boot-stack template index must store a full MCSN");
      }
      const digest = await objects.putSnapshotObject(indexed);
      sessionClassIndex.set(classKey, digest);
      return { digest, bytes: indexed };
    }
  }

  return null;
}

async function mintTemplate(
  store: ContentStore,
  classKey: string,
  capture: () => Promise<Uint8Array>,
): Promise<TemplateHit> {
  const objects = requireSnapshotObjects(store);
  const full = await capture();
  const view = parseSnapshot(full);
  if (view.kind !== "full") {
    throw new Error("boot-stack template capture must produce a full MCSN");
  }
  const digest = await objects.putSnapshotObject(full);
  sessionClassIndex.set(classKey, digest);
  if (store.putSnapshot) {
    await store.putSnapshot(await durableIndexKey(classKey), full);
  }
  return { digest, bytes: full };
}

/**
 * Ensure a template full exists for `classKey`.
 *
 * Concurrent callers for the same key share one in-flight promise (single capture).
 *
 * - **on_demand** miss → `capture()` (must return a full MCSN at boot-ready), store it, return it.
 * - **prepopulated** miss → null (caller leaves VM unbound).
 * - **off** → null.
 */
export async function ensureImageTemplate(args: {
  store: ContentStore;
  classKey: string;
  policy: TemplateFillPolicy;
  /** Capture a full MCSN of the live host at boot-ready (pre catalog/mounts). */
  capture: () => Promise<Uint8Array>;
}): Promise<TemplateHit | null> {
  const { store, classKey, policy, capture } = args;
  if (policy === "off") return null;

  const existing = inflightEnsure.get(classKey);
  if (existing) return existing;

  const work = (async (): Promise<TemplateHit | null> => {
    const hit = await lookupImageTemplate(store, classKey);
    if (hit) return hit;
    if (policy === "prepopulated") return null;
    return mintTemplate(store, classKey, capture);
  })();

  inflightEnsure.set(classKey, work);
  try {
    return await work;
  } finally {
    if (inflightEnsure.get(classKey) === work) inflightEnsure.delete(classKey);
  }
}

/**
 * Publish a template full into the cache (server prepopulate / explicit seed).
 * `full` must be a full MCSN. Returns the content digest.
 */
export async function publishImageTemplate(
  store: ContentStore,
  classKey: string,
  full: Uint8Array,
): Promise<string> {
  const objects = requireSnapshotObjects(store);
  const view = parseSnapshot(full);
  if (view.kind !== "full") {
    throw new Error("publishImageTemplate requires a full MCSN");
  }
  const digest = await objects.putSnapshotObject(full);
  sessionClassIndex.set(classKey, digest);
  if (store.putSnapshot) {
    await store.putSnapshot(await durableIndexKey(classKey), full);
  }
  return digest;
}

/** Test helper: clear the in-process class→digest index and in-flight map. */
export function clearSessionTemplateIndex(): void {
  sessionClassIndex.clear();
  inflightEnsure.clear();
}

/** Test helper: session index size. */
export function sessionTemplateIndexSize(): number {
  return sessionClassIndex.size;
}
