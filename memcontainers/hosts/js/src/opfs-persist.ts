// Browser persistence for `/var/persist`. Reads/lists are served from an
// `open()`-loaded cache, while mutations report ready only after OPFS/IndexedDB
// has accepted the write. That makes the kernel's `pending_commits` quiescence
// mean the same thing in browsers as it does for native disk and BEAM relay
// backends.

import type { PersistCapability } from "./types.js";
import {
  PERSIST_OP_GET,
  PERSIST_OP_PUT,
  PERSIST_OP_DELETE,
  PERSIST_OP_LIST,
  decodePersistRequest,
  encodeKeyList,
  getAbsentBody,
  getPresentBody,
} from "./persist_core.js";

/** An async durable key/value backing (OPFS / IndexedDB). Keys are hex strings. */
export interface BrowserKv {
  load(): Promise<Map<string, Uint8Array>>;
  put(hexKey: string, value: Uint8Array): Promise<void>;
  delete(hexKey: string): Promise<void>;
}

interface Slot {
  result: Uint8Array;
  offset: number;
  done: boolean;
  failed: boolean;
}

/** `/var/persist` backed by a browser durable store, via an async bridge slot. */
export class OpfsPersist implements PersistCapability {
  private readonly slots = new Map<number, Slot>();
  private next = 1;
  private mutationTail: Promise<void> = Promise.resolve();

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

  start(req: Uint8Array): number {
    const decoded = decodePersistRequest(req);
    if (!decoded) return -1;
    const handle = this.next;
    this.next = this.next + 1 < 1 ? 1 : this.next + 1;
    const slot: Slot = { result: new Uint8Array(0), offset: 0, done: false, failed: false };
    this.slots.set(handle, slot);
    void this.run(decoded.op, decoded.key.slice(), decoded.value.slice())
      .then((result) => {
        const live = this.slots.get(handle);
        if (!live) return;
        live.result = result;
        live.done = true;
      })
      .catch(() => {
        const live = this.slots.get(handle);
        if (!live) return;
        live.failed = true;
        live.done = true;
      });
    return handle;
  }

  poll(handle: number): number {
    const slot = this.slots.get(handle);
    if (!slot || slot.failed) return -1;
    return slot.done ? 1 : 0;
  }

  body(handle: number, buf: Uint8Array): number {
    const slot = this.slots.get(handle);
    if (!slot || slot.failed || !slot.done) return -1;
    const remaining = slot.result.subarray(slot.offset);
    const n = Math.min(remaining.length, buf.length);
    buf.set(remaining.subarray(0, n), 0);
    slot.offset += n;
    return n;
  }

  close(handle: number): void {
    this.slots.delete(handle);
  }

  private async run(op: number, key: Uint8Array, value: Uint8Array): Promise<Uint8Array> {
    switch (op) {
      case PERSIST_OP_GET: {
        const v = this.cache.get(hexEncode(key));
        return v === undefined ? getAbsentBody() : getPresentBody(v);
      }
      case PERSIST_OP_PUT: {
        const hk = hexEncode(key);
        const copy = value.slice();
        await this.enqueueMutation(async () => {
          await this.backing.put(hk, copy);
          this.cache.set(hk, copy);
        });
        return new Uint8Array(0);
      }
      case PERSIST_OP_DELETE: {
        const hk = hexEncode(key);
        await this.enqueueMutation(async () => {
          await this.backing.delete(hk);
          this.cache.delete(hk);
        });
        return new Uint8Array(0);
      }
      case PERSIST_OP_LIST: {
        const keys: Uint8Array[] = [];
        for (const hk of this.cache.keys()) {
          const candidate = hexDecode(hk);
          if (candidate && startsWith(candidate, key)) keys.push(candidate);
        }
        keys.sort(compareBytes);
        return encodeKeyList(keys);
      }
      default:
        throw new Error(`unknown persist op ${op}`);
    }
  }

  private async enqueueMutation(work: () => Promise<void>): Promise<void> {
    const run = this.mutationTail.then(work, work);
    this.mutationTail = run.catch(() => {});
    await run;
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
