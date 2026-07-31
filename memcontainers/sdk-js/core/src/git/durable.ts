/**
 * Durable backends for host git engine (GIT.md PR8a OPFS / PR8b server disk).
 *
 * Backends store an opaque byte blob. {@link GitEngine} serializes real repo
 * state as a versioned **AGIT** envelope (refs JSON + packfile) — not a MEMFS
 * filesystem dump. Load rebinds via `importPack` + `refs.import` + `clone.apply`.
 */

export interface DurableBackend {
  /** Absolute or logical key for the worktree store. */
  readonly id: string;
  /** Persist durable snapshot bytes (AGIT envelope or legacy opaque). */
  save(snapshot: Uint8Array): Promise<void>;
  /** Load last snapshot; null if none. */
  load(): Promise<Uint8Array | null>;
  /** Drop durable state. */
  clear(): Promise<void>;
}

/** In-memory durability (tests / default when OPFS unavailable). */
export class MemoryDurable implements DurableBackend {
  private data: Uint8Array | null = null;
  constructor(readonly id = "memory") {}
  async save(snapshot: Uint8Array): Promise<void> {
    this.data = snapshot.slice();
  }
  async load(): Promise<Uint8Array | null> {
    return this.data ? this.data.slice() : null;
  }
  async clear(): Promise<void> {
    this.data = null;
  }
}

/**
 * Browser OPFS durable store (PR8a). Keyed under `agentos-git/{id}/snapshot.bin`.
 * No-op constructor throw if OPFS missing — callers fall back to MemoryDurable.
 */
export class OpfsDurable implements DurableBackend {
  private constructor(
    readonly id: string,
    private readonly root: FileSystemDirectoryHandle,
  ) {}

  static async open(id = "default"): Promise<OpfsDurable | null> {
    try {
      const nav = globalThis.navigator as
        | (Navigator & {
            storage?: { getDirectory?: () => Promise<FileSystemDirectoryHandle> };
          })
        | undefined;
      if (!nav?.storage?.getDirectory) return null;
      const opfs = await nav.storage.getDirectory();
      const agent = await opfs.getDirectoryHandle("agentos-git", { create: true });
      const root = await agent.getDirectoryHandle(id, { create: true });
      return new OpfsDurable(id, root);
    } catch {
      return null;
    }
  }

  async save(snapshot: Uint8Array): Promise<void> {
    const fh = await this.root.getFileHandle("snapshot.bin", { create: true });
    const w = await fh.createWritable();
    await w.write(snapshot);
    await w.close();
  }

  async load(): Promise<Uint8Array | null> {
    try {
      const fh = await this.root.getFileHandle("snapshot.bin");
      const file = await fh.getFile();
      return new Uint8Array(await file.arrayBuffer());
    } catch {
      return null;
    }
  }

  async clear(): Promise<void> {
    try {
      await this.root.removeEntry("snapshot.bin");
    } catch {
      /* missing */
    }
  }
}

/**
 * Server / Node disk durable store (PR8b). Writes `{dir}/snapshot.bin`.
 */
export class DiskDurable implements DurableBackend {
  constructor(
    readonly id: string,
    private readonly dir: string,
  ) {}

  private path(): string {
    return `${this.dir.replace(/\/$/, "")}/snapshot.bin`;
  }

  async save(snapshot: Uint8Array): Promise<void> {
    const { mkdir, writeFile } = await import("node:fs/promises");
    await mkdir(this.dir, { recursive: true });
    await writeFile(this.path(), snapshot);
  }

  async load(): Promise<Uint8Array | null> {
    try {
      const { readFile } = await import("node:fs/promises");
      return new Uint8Array(await readFile(this.path()));
    } catch {
      return null;
    }
  }

  async clear(): Promise<void> {
    try {
      const { unlink } = await import("node:fs/promises");
      await unlink(this.path());
    } catch {
      /* */
    }
  }
}

/** Prefer OPFS in browser, disk when `dir` given, else memory. */
export async function openDurable(opts: {
  id?: string;
  diskDir?: string;
}): Promise<DurableBackend> {
  if (opts.diskDir) return new DiskDurable(opts.id ?? "default", opts.diskDir);
  const opfs = await OpfsDurable.open(opts.id ?? "default");
  if (opfs) return opfs;
  return new MemoryDurable(opts.id ?? "default");
}

// --- AGIT envelope: magic + u32 LE json_len + json(refs+head) + pack bytes ---

/** Magic bytes `AGIT` for durable rebind blobs. */
export const AGIT_MAGIC = new Uint8Array([0x41, 0x47, 0x49, 0x54]);

export type DurableRefTip = { name: string; hash: string };

/** Versioned metadata inside an AGIT envelope (pack bytes follow the JSON). */
export type DurableEnvelopeMeta = {
  v: 1;
  refs: DurableRefTip[];
  head: string;
};

export type DecodedDurableBlob = {
  meta: DurableEnvelopeMeta;
  pack: Uint8Array;
};

/**
 * Encode pack + refs as a single Uint8Array:
 * `AGIT` | u32le(json_len) | json | pack.
 */
export function encodeDurableBlob(
  meta: DurableEnvelopeMeta,
  pack: Uint8Array,
): Uint8Array {
  const json = new TextEncoder().encode(JSON.stringify(meta));
  const out = new Uint8Array(4 + 4 + json.length + pack.byteLength);
  out.set(AGIT_MAGIC, 0);
  const view = new DataView(out.buffer, out.byteOffset, out.byteLength);
  view.setUint32(4, json.length, true);
  out.set(json, 8);
  out.set(pack, 8 + json.length);
  return out;
}

/**
 * Parse an AGIT envelope. Returns null for legacy/opaque non-AGIT blobs
 * (no rebind — caller may keep bytes at engine level only).
 */
export function decodeDurableBlob(data: Uint8Array): DecodedDurableBlob | null {
  if (!data || data.byteLength < 8) return null;
  if (
    data[0] !== AGIT_MAGIC[0] ||
    data[1] !== AGIT_MAGIC[1] ||
    data[2] !== AGIT_MAGIC[2] ||
    data[3] !== AGIT_MAGIC[3]
  ) {
    return null;
  }
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const jsonLen = view.getUint32(4, true);
  if (jsonLen > data.byteLength - 8) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(
      new TextDecoder().decode(data.subarray(8, 8 + jsonLen)),
    );
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== "object") return null;
  const obj = parsed as Record<string, unknown>;
  if (obj.v !== 1) return null;
  if (!Array.isArray(obj.refs)) return null;
  const refs: DurableRefTip[] = [];
  for (const r of obj.refs) {
    if (!r || typeof r !== "object") return null;
    const name = (r as DurableRefTip).name;
    const hash = (r as DurableRefTip).hash;
    if (typeof name !== "string" || !name) return null;
    if (typeof hash !== "string" || !/^[0-9a-f]{40}$/i.test(hash)) return null;
    refs.push({ name, hash: hash.toLowerCase() });
  }
  const head =
    typeof obj.head === "string" && obj.head
      ? obj.head
      : "refs/heads/main";
  const pack = data.subarray(8 + jsonLen);
  return { meta: { v: 1, refs, head }, pack };
}
