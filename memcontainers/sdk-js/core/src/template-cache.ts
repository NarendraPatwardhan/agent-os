//! MCSN template cache (PERF-011 / SYSTEMS.md §8).
//!
//! A template is one full MCSN shared by VMs that boot the same layer set:
//! `(kernel_digest, ordered digests of every layer passed to withLayers)`.
//! That includes the image flavor layers **and** create-time sidecar guest layers
//! (guest layers are VFS content in the MCSN, not host-only attachments).
//!
//! Live VMs bind `active_base` to the template's content digest and keep private
//! linear memory — they do not each retain a private full.
//!
//! Storage layout (reuses existing {@link ContentStore} APIs only):
//! - Body: `putSnapshotObject` / `snapshotObject` (content-addressed full MCSN).
//! - Class index: `putSnapshot` / `snapshot` under `mc-template.<hash>` stores **only**
//!   the UTF-8 content digest (not a second full copy).
//!
//! Fill policy:
//! - **on_demand**: first ready boot of a class captures one full and caches it;
//!   later boots of the same class reuse it. Concurrent first fills share one in-flight promise
//!   **per store**.
//! - **prepopulated** (server): only look up; never mint at create time.
//! - **off**: do not bind a template at create.
//!
//! Incremental capture must never invent a baseline (see EmbeddedBackend.snapshot).

import type { ContentStore, Runtime } from "./types.js";
import { parseSnapshot } from "@mc/contracts/snapshot";

/** How template fulls are obtained when a VM becomes ready. */
export type TemplateFillPolicy = "on_demand" | "prepopulated" | "off";

/** Digest of a cached template full (`sha256:…`). Bytes are loaded from CAS on demand. */
export type TemplateHit = { digest: string };

const enc = new TextEncoder();
const dec = new TextDecoder();
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;

/** Per-store session L1: inflightKey → content digest. */
const sessionClassIndex = new Map<string, string>();

/** In-flight ensure work, keyed by store identity + class key. */
const inflightEnsure = new Map<string, Promise<TemplateHit | null>>();

/** Stable identity for a ContentStore instance (process-local). */
const storeIds = new WeakMap<object, string>();
let storeIdSeq = 0;

function storeId(store: ContentStore): string {
  // ContentStore is always an object in our implementations.
  const obj = store as object;
  let id = storeIds.get(obj);
  if (!id) {
    id = `store-${++storeIdSeq}`;
    storeIds.set(obj, id);
  }
  return id;
}

function sessionKey(store: ContentStore, classKey: string): string {
  return `${storeId(store)}\0${classKey}`;
}

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
  const hex = await sha256Hex(enc.encode(classKey));
  return `mc-template.${hex}`;
}

/**
 * Default fill policy (PERF-011 create-latency):
 * - **browser**: on_demand when a snapshot-capable store is available (density goal).
 * - **local / other**: on_demand only when the caller **explicitly** passed a store;
 *   otherwise off so plain boots do not pay a full MCSN capture.
 */
export function defaultTemplateFill(runtime?: Runtime, explicitStore = false): TemplateFillPolicy {
  if (runtime === "browser") return "on_demand";
  if (explicitStore) return "on_demand";
  return "off";
}

/**
 * Stable template class key for the template index.
 *
 * `layerDigests` must be `sha256:…` of **every** layer passed to `withLayers`, in
 * stack order: image layers then create-time sidecar guest layers. Host-only
 * sidecar grants (no guest layer) do not appear here.
 */
export function templateClassKey(
  kernelDigest: Uint8Array,
  layerDigests: readonly string[],
): string {
  return `${hexOf(kernelDigest)}|${layerDigests.join(",")}`;
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
    throw new Error("templates require a content store with snapshotObject/putSnapshotObject");
  }
  return {
    snapshotObject: store.snapshotObject.bind(store),
    putSnapshotObject: store.putSnapshotObject.bind(store),
  };
}

function encodeDigestPointer(digest: string): Uint8Array {
  if (!DIGEST_RE.test(digest)) throw new Error(`invalid template digest pointer: ${digest}`);
  return enc.encode(digest);
}

function decodeDigestPointer(raw: Uint8Array): string | null {
  // Prefer the compact pointer form.
  try {
    const text = dec.decode(raw).trim();
    if (DIGEST_RE.test(text)) return text;
  } catch {
    /* fall through */
  }
  return null;
}

/**
 * Read class → digest from the durable index. Migrates legacy full-MCSN index
 * values (pre-pointer) into digest-only form when found.
 */
async function readDurableDigest(
  store: ContentStore,
  classKey: string,
  objects: { putSnapshotObject: (s: Uint8Array) => Promise<string> },
): Promise<string | null> {
  if (!store.snapshot) return null;
  const key = await durableIndexKey(classKey);
  const indexed = await store.snapshot(key);
  if (!indexed) return null;

  const pointer = decodeDigestPointer(indexed);
  if (pointer) return pointer;

  // Legacy: index held a full MCSN. Promote body to putSnapshotObject and rewrite index.
  try {
    const view = parseSnapshot(indexed);
    if (view.kind !== "full") return null;
    const digest = await objects.putSnapshotObject(indexed);
    if (store.putSnapshot) {
      await store.putSnapshot(key, encodeDigestPointer(digest));
    }
    return digest;
  } catch {
    return null;
  }
}

async function writeDurableDigest(
  store: ContentStore,
  classKey: string,
  digest: string,
): Promise<void> {
  if (!store.putSnapshot) return;
  await store.putSnapshot(await durableIndexKey(classKey), encodeDigestPointer(digest));
}

/**
 * Look up a cached template for `classKey` without capturing.
 * Returns the content digest only (load bytes via `snapshotObject` when needed).
 */
export async function lookupTemplate(
  store: ContentStore,
  classKey: string,
): Promise<TemplateHit | null> {
  const objects = requireSnapshotObjects(store);
  const sk = sessionKey(store, classKey);

  const sessionDigest = sessionClassIndex.get(sk);
  if (sessionDigest) {
    try {
      // Prove the body still exists; discard session entry on miss.
      await objects.snapshotObject(sessionDigest);
      return { digest: sessionDigest };
    } catch {
      sessionClassIndex.delete(sk);
    }
  }

  const durable = await readDurableDigest(store, classKey, objects);
  if (durable) {
    try {
      await objects.snapshotObject(durable);
      sessionClassIndex.set(sk, durable);
      return { digest: durable };
    } catch {
      return null;
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
    throw new Error("template capture must produce a full MCSN");
  }
  const digest = await objects.putSnapshotObject(full);
  sessionClassIndex.set(sessionKey(store, classKey), digest);
  await writeDurableDigest(store, classKey, digest);
  return { digest };
}

/**
 * Ensure a template full exists for `classKey` on `store`.
 *
 * Concurrent callers for the same (store, classKey) share one in-flight promise.
 */
export async function ensureTemplate(args: {
  store: ContentStore;
  classKey: string;
  policy: TemplateFillPolicy;
  /** Capture a full MCSN of the live host at boot-ready (pre catalog/mounts). */
  capture: () => Promise<Uint8Array>;
}): Promise<TemplateHit | null> {
  const { store, classKey, policy, capture } = args;
  if (policy === "off") return null;

  const key = sessionKey(store, classKey);
  const existing = inflightEnsure.get(key);
  if (existing) return existing;

  const work = (async (): Promise<TemplateHit | null> => {
    const hit = await lookupTemplate(store, classKey);
    if (hit) return hit;
    if (policy === "prepopulated") return null;
    return mintTemplate(store, classKey, capture);
  })();

  inflightEnsure.set(key, work);
  try {
    return await work;
  } finally {
    if (inflightEnsure.get(key) === work) inflightEnsure.delete(key);
  }
}

/**
 * Publish a template full into the cache (server prepopulate / explicit seed).
 * `full` must be a full MCSN. Returns the content digest.
 */
export async function publishTemplate(
  store: ContentStore,
  classKey: string,
  full: Uint8Array,
): Promise<string> {
  const objects = requireSnapshotObjects(store);
  const view = parseSnapshot(full);
  if (view.kind !== "full") {
    throw new Error("publishTemplate requires a full MCSN");
  }
  const digest = await objects.putSnapshotObject(full);
  sessionClassIndex.set(sessionKey(store, classKey), digest);
  await writeDurableDigest(store, classKey, digest);
  return digest;
}

// ── test-only helpers (not re-exported from @mc/core package index) ──────────

/** @internal Test helper: clear session index and in-flight map. */
export function clearSessionTemplateIndex(): void {
  sessionClassIndex.clear();
  inflightEnsure.clear();
}

/** @internal Test helper: session index size. */
export function sessionTemplateIndexSize(): number {
  return sessionClassIndex.size;
}
