// Browser persistence for `/var/persist`. The kernel's persist bridge is SYNCHRONOUS (`get` returns
// the value immediately), but the browser's durable stores — OPFS and IndexedDB — are async. So this
// keeps an authoritative in-memory cache (sync get/put/delete/list) that is LOADED from the durable
// backing at `open()`, and WRITES BEHIND to the backing so a VM's `/var/persist` survives a page
// reload. The durable backing is injectable, so the cache semantics are unit-tested in bun/node
// without a browser.

import type { PersistCapability } from "./types.js";

/** An async durable key/value backing (OPFS / IndexedDB). Keys are hex strings. */
export interface BrowserKv {
  load(): Promise<Map<string, Uint8Array>>;
  put(hexKey: string, value: Uint8Array): Promise<void>;
  delete(hexKey: string): Promise<void>;
}

/** `/var/persist` backed by a browser durable store, via a sync cache. */
export class OpfsPersist implements PersistCapability {
  private constructor(
    private readonly cache: Map<string, Uint8Array>,
    private readonly backing: BrowserKv,
  ) {}

  /** Load the durable backing into memory and return a ready capability. Prefers OPFS, then
   *  IndexedDB; with neither (or an explicit {@link MemoryKv}) it is in-memory only (no cross-reload
   *  durability). */
  static async open(backing?: BrowserKv): Promise<OpfsPersist> {
    const kv = backing ?? (await defaultBrowserKv());
    const cache = await kv.load().catch(() => new Map<string, Uint8Array>());
    return new OpfsPersist(cache, kv);
  }

  get(key: Uint8Array, out: Uint8Array): number {
    const v = this.cache.get(hexEncode(key));
    if (v === undefined) return -2; // not found
    const n = Math.min(v.length, out.length);
    out.set(v.subarray(0, n));
    return v.length; // FULL length (the kernel resizes + retries if needed)
  }

  put(key: Uint8Array, val: Uint8Array): number {
    const hk = hexEncode(key);
    const copy = val.slice();
    this.cache.set(hk, copy);
    void this.backing.put(hk, copy).catch((e) => console.warn("persist: write-behind failed", e));
    return 0;
  }

  delete(key: Uint8Array): number {
    const hk = hexEncode(key);
    this.cache.delete(hk);
    void this.backing
      .delete(hk)
      .catch((e) => console.warn("persist: delete write-behind failed", e));
    return 0; // missing key is ok
  }

  list(prefix: Uint8Array, out: Uint8Array): number {
    const keys: Uint8Array[] = [];
    for (const hk of this.cache.keys()) {
      const key = hexDecode(hk);
      if (key && startsWith(key, prefix)) keys.push(key);
    }
    keys.sort(compareBytes);
    let total = 0;
    for (const k of keys) total += k.length + 1;
    const blob = new Uint8Array(total);
    let off = 0;
    for (const k of keys) {
      blob.set(k, off);
      off += k.length;
      blob[off++] = 0; // NUL separator
    }
    const n = Math.min(blob.length, out.length);
    out.set(blob.subarray(0, n));
    return blob.length; // FULL length
  }
}

/** Feature-detect a durable backing: OPFS first, then IndexedDB, else memory. The browser globals are
 *  real DOM types (lib.dom) but may be absent at runtime under node/bun, so each is `typeof`-guarded. */
async function defaultBrowserKv(): Promise<BrowserKv> {
  if (typeof navigator !== "undefined" && typeof navigator.storage?.getDirectory === "function") {
    try {
      return new OpfsKv(await navigator.storage.getDirectory());
    } catch {
      /* fall through to IndexedDB */
    }
  }
  if (typeof indexedDB !== "undefined") return new IdbKv();
  return new MemoryKv();
}

/** OPFS backing (async main-thread API: `getDirectory` + per-file read/write). */
export class OpfsKv implements BrowserKv {
  constructor(private readonly dir: FileSystemDirectoryHandle) {}

  async load(): Promise<Map<string, Uint8Array>> {
    const map = new Map<string, Uint8Array>();
    for await (const [name, handle] of this.dir.entries()) {
      if (handle.kind !== "file") continue;
      // `.kind === "file"` guarantees a file handle, but TS doesn't narrow the union by `.kind`.
      const file = await (handle as FileSystemFileHandle).getFile();
      map.set(name, new Uint8Array(await file.arrayBuffer()));
    }
    return map;
  }
  async put(hexKey: string, value: Uint8Array): Promise<void> {
    const fh = await this.dir.getFileHandle(hexKey, { create: true });
    const w = await fh.createWritable();
    await w.write(value);
    await w.close();
  }
  async delete(hexKey: string): Promise<void> {
    await this.dir.removeEntry(hexKey).catch(() => {});
  }
}

/** IndexedDB backing — a natural key/value store; the OPFS fallback. */
export class IdbKv implements BrowserKv {
  private static readonly DB = "mc-persist";
  private static readonly STORE = "kv";

  private open(): Promise<IDBDatabase> {
    return new Promise((res, rej) => {
      const r = indexedDB.open(IdbKv.DB, 1);
      r.onupgradeneeded = () => r.result.createObjectStore(IdbKv.STORE);
      r.onsuccess = () => res(r.result);
      r.onerror = () => rej(r.error);
    });
  }
  async load(): Promise<Map<string, Uint8Array>> {
    const db = await this.open();
    return new Promise((res, rej) => {
      const map = new Map<string, Uint8Array>();
      const cur = db.transaction(IdbKv.STORE, "readonly").objectStore(IdbKv.STORE).openCursor();
      cur.onsuccess = () => {
        const c = cur.result;
        if (c) {
          map.set(String(c.key), new Uint8Array(c.value as ArrayBuffer));
          c.continue();
        } else res(map);
      };
      cur.onerror = () => rej(cur.error);
    });
  }
  async put(hexKey: string, value: Uint8Array): Promise<void> {
    const db = await this.open();
    return new Promise((res, rej) => {
      const tx = db.transaction(IdbKv.STORE, "readwrite");
      // Store a standalone ArrayBuffer copy (the Uint8Array may be a view).
      tx.objectStore(IdbKv.STORE).put(value.slice().buffer, hexKey);
      tx.oncomplete = () => res();
      tx.onerror = () => rej(tx.error);
    });
  }
  async delete(hexKey: string): Promise<void> {
    const db = await this.open();
    return new Promise((res, rej) => {
      const tx = db.transaction(IdbKv.STORE, "readwrite");
      tx.objectStore(IdbKv.STORE).delete(hexKey);
      tx.oncomplete = () => res();
      tx.onerror = () => rej(tx.error);
    });
  }
}

/** In-memory backing (no durability) — used when neither OPFS nor IndexedDB is available, and as the
 *  unit-test seam. */
export class MemoryKv implements BrowserKv {
  private store = new Map<string, Uint8Array>();
  async load(): Promise<Map<string, Uint8Array>> {
    return new Map(this.store);
  }
  async put(hexKey: string, value: Uint8Array): Promise<void> {
    this.store.set(hexKey, value.slice());
  }
  async delete(hexKey: string): Promise<void> {
    this.store.delete(hexKey);
  }
}

// ---- byte/hex helpers (mirror persist.ts) ----

function hexEncode(b: Uint8Array): string {
  let s = "";
  for (const x of b) s += x.toString(16).padStart(2, "0");
  return s;
}
function hexDecode(s: string): Uint8Array | null {
  if (s.length % 2 !== 0) return null;
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) {
    const v = parseInt(s.slice(i * 2, i * 2 + 2), 16);
    if (Number.isNaN(v)) return null;
    out[i] = v;
  }
  return out;
}
function startsWith(key: Uint8Array, prefix: Uint8Array): boolean {
  if (prefix.length > key.length) return false;
  for (let i = 0; i < prefix.length; i++) if (key[i] !== prefix[i]) return false;
  return true;
}
function compareBytes(a: Uint8Array, b: Uint8Array): number {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) {
    const d = (a[i] as number) - (b[i] as number);
    if (d !== 0) return d;
  }
  return a.length - b.length;
}
