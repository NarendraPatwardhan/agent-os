/**
 * Content-addressed pack cache (GIT.md PR13 / K29).
 * Credentials are never cached — only pack bytes keyed by sha256.
 */

export interface PackCache {
  get(digest: string): Promise<Uint8Array | null>;
  put(pack: Uint8Array): Promise<string>;
  has(digest: string): Promise<boolean>;
  clear(): Promise<void>;
  /** Optional download-key index (url+want+have+depth → pack digest) for K29 dedup. */
  getByKey?(key: string): Promise<string | null>;
  putKey?(key: string, digest: string): Promise<void>;
}

async function sha256hex(data: Uint8Array): Promise<string> {
  const h = new Uint8Array(
    await crypto.subtle.digest("SHA-256", data as Uint8Array<ArrayBuffer>),
  );
  let s = "sha256:";
  for (const b of h) s += b.toString(16).padStart(2, "0");
  return s;
}

/** In-memory pack cache (tests / small sessions). */
export class MemoryPackCache implements PackCache {
  private readonly map = new Map<string, Uint8Array>();
  private readonly keys = new Map<string, string>();

  async get(digest: string): Promise<Uint8Array | null> {
    const v = this.map.get(digest);
    return v ? v.slice() : null;
  }

  async put(pack: Uint8Array): Promise<string> {
    const digest = await sha256hex(pack);
    if (!this.map.has(digest)) this.map.set(digest, pack.slice());
    return digest;
  }

  async has(digest: string): Promise<boolean> {
    return this.map.has(digest);
  }

  async clear(): Promise<void> {
    this.map.clear();
    this.keys.clear();
  }

  async getByKey(key: string): Promise<string | null> {
    return this.keys.get(key) ?? null;
  }

  async putKey(key: string, digest: string): Promise<void> {
    this.keys.set(key, digest);
  }
}

/** Node disk pack cache under `{dir}/{digest without prefix}`. */
export class DiskPackCache implements PackCache {
  constructor(private readonly dir: string) {}

  private pathFor(digest: string): string {
    const id = digest.replace(/^sha256:/, "");
    return `${this.dir.replace(/\/$/, "")}/${id}.pack`;
  }

  async get(digest: string): Promise<Uint8Array | null> {
    try {
      const { readFile } = await import("node:fs/promises");
      return new Uint8Array(await readFile(this.pathFor(digest)));
    } catch {
      return null;
    }
  }

  async put(pack: Uint8Array): Promise<string> {
    const digest = await sha256hex(pack);
    const { mkdir, writeFile, access } = await import("node:fs/promises");
    await mkdir(this.dir, { recursive: true });
    const p = this.pathFor(digest);
    try {
      await access(p);
    } catch {
      await writeFile(p, pack);
    }
    return digest;
  }

  async has(digest: string): Promise<boolean> {
    try {
      const { access } = await import("node:fs/promises");
      await access(this.pathFor(digest));
      return true;
    } catch {
      return false;
    }
  }

  async clear(): Promise<void> {
    try {
      const { rm } = await import("node:fs/promises");
      await rm(this.dir, { recursive: true, force: true });
    } catch {
      /* */
    }
  }
}

/** Soft default: refuse packs larger than 64 MiB unless opt-in. */
export const DEFAULT_MAX_PACK_BYTES = 64 * 1024 * 1024;

export interface ImportPackOptions {
  cache?: PackCache;
  /** Max pack size; 0 = unlimited. Default 64 MiB. */
  maxPackBytes?: number;
  /** Chunk size for streaming ImportPack (default 1 MiB). */
  chunkBytes?: number;
}

/**
 * Import pack with optional cache hit and chunked ge_import_pack streaming.
 * Throws if pack exceeds maxPackBytes (unless maxPackBytes === 0).
 */
export async function importPackCached(
  engine: {
    importPack: (
      chunk: Uint8Array,
      meta?: { final?: boolean },
    ) => Promise<void>;
  },
  pack: Uint8Array,
  opts: ImportPackOptions = {},
): Promise<{ digest: string; fromCache: boolean }> {
  const max =
    opts.maxPackBytes === undefined
      ? DEFAULT_MAX_PACK_BYTES
      : opts.maxPackBytes;
  if (max > 0 && pack.byteLength > max) {
    throw new Error(
      `git: pack ${pack.byteLength} bytes exceeds maxPackBytes ${max} (opt-in higher limit)`,
    );
  }

  const cache = opts.cache;
  let digest = "";
  let fromCache = false;
  let bytes = pack;

  if (cache) {
    digest = await sha256hex(pack);
    const hit = await cache.get(digest);
    if (hit) {
      bytes = hit;
      fromCache = true;
    } else {
      digest = await cache.put(pack);
    }
  } else {
    digest = await sha256hex(pack);
  }

  const chunk = opts.chunkBytes ?? 1024 * 1024;
  if (bytes.byteLength === 0) {
    await engine.importPack(new Uint8Array(0), { final: true });
    return { digest, fromCache };
  }
  for (let off = 0; off < bytes.byteLength; off += chunk) {
    const slice = bytes.subarray(off, Math.min(off + chunk, bytes.byteLength));
    const final = off + slice.byteLength >= bytes.byteLength;
    await engine.importPack(slice, { final });
  }
  return { digest, fromCache };
}
