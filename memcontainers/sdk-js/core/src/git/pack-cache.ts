/**
 * Content-addressed pack cache for remotes and LLB solves.
 *
 * Credentials are never cached — only pack bytes keyed by sha256 digest.
 * Optional download-key index maps public url+wants+haves → pack digest for
 * dedup across clone/fetch/materialize in the same process (or on disk).
 */

import {
  DEFAULT_MAX_PACK_BYTES as CONTRACT_DEFAULT_MAX_PACK_BYTES,
  MAX_PACK_ZERO_MEANS_DEFAULT,
} from "@mc/contracts/git";

// ── PackCache face ──────────────────────────────────────────────────────────

export interface PackCache {
  get(digest: string): Promise<Uint8Array | null>;
  put(pack: Uint8Array): Promise<string>;
  has(digest: string): Promise<boolean>;
  clear(): Promise<void>;
  /** Optional download-key index (url+want+have+depth → pack digest). */
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

// ── Memory backend ──────────────────────────────────────────────────────────

/** In-memory pack cache (tests / small sessions / process default). */
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

// ── Process-scoped default ──────────────────────────────────────────────────

/**
 * Process-scoped pack cache singleton (opt-in share for single-tenant / LLB).
 * Product host_call handlers do **not** use this by default — see
 * {@link productDefaultPackCache} / `MC_GIT_PACK_CACHE_SHARED`.
 */
let processPackCache: PackCache | undefined;

/**
 * Read `MC_GIT_PACK_CACHE` when available (Node/Bun). Safe in browsers: missing
 * `process` / env → undefined (Memory default). Never throws.
 *
 * Disk path is honored by {@link createDefaultProcessPackCache} /
 * {@link defaultProcessPackCache} (shared opt-in). Multi-tenant product
 * handlers only reach Disk when `MC_GIT_PACK_CACHE_SHARED=1` or the caller
 * passes an explicit `packCache`.
 */
export function processPackCacheDirFromEnv(): string | undefined {
  try {
    const env =
      typeof process !== "undefined" && process?.env
        ? process.env.MC_GIT_PACK_CACHE
        : undefined;
    if (typeof env !== "string") return undefined;
    const dir = env.trim();
    return dir || undefined;
  } catch {
    return undefined;
  }
}

/**
 * Whether product handlers may share a process-scoped pack cache.
 * Opt-in via `MC_GIT_PACK_CACHE_SHARED=1` (multi-tenant safer default is off).
 * Safe in browsers: missing `process` / env → false. Never throws.
 */
export function processPackCacheSharedFromEnv(): boolean {
  try {
    const env =
      typeof process !== "undefined" && process?.env
        ? process.env.MC_GIT_PACK_CACHE_SHARED
        : undefined;
    if (typeof env !== "string") return false;
    const v = env.trim();
    return v === "1" || v.toLowerCase() === "true";
  } catch {
    return false;
  }
}

/**
 * Build a new pack cache instance for process-default / shared use:
 * - {@link DiskPackCache} when `MC_GIT_PACK_CACHE` is a non-empty dir path (Node)
 * - {@link MemoryPackCache} otherwise (browser / unset env)
 *
 * Content-addressed packs only — never credentials. Does **not** return the
 * process singleton — use {@link defaultProcessPackCache} for that.
 */
export function createDefaultProcessPackCache(): PackCache {
  const dir = processPackCacheDirFromEnv();
  if (dir) return new DiskPackCache(dir);
  return new MemoryPackCache();
}

/**
 * Shared process-scoped pack cache singleton. First call pins Memory or Disk
 * based on `MC_GIT_PACK_CACHE` at that moment; later calls reuse the same
 * instance.
 *
 * **Opt-in for multi-tenant product paths** (`gitHostCallHandler` /
 * memcontainer): either set `MC_GIT_PACK_CACHE_SHARED=1`, or pass
 * `packCache: defaultProcessPackCache()` explicitly. Disk via
 * `MC_GIT_PACK_CACHE` remains valid here for single-tenant / shared opt-in.
 *
 * LLB / Node solve (`materializeLlbGit`, `nodeSolvePlatformWithEngine`) still
 * use this by default for repeated in-process solves.
 */
export function defaultProcessPackCache(): PackCache {
  if (!processPackCache) processPackCache = createDefaultProcessPackCache();
  return processPackCache;
}

/**
 * Default pack cache for product host_call handlers (`gitHostCallHandler`):
 * - When `MC_GIT_PACK_CACHE_SHARED=1`: {@link defaultProcessPackCache} (Memory,
 *   or Disk when `MC_GIT_PACK_CACHE` is set — single-tenant / opt-in share).
 * - Otherwise: fresh {@link MemoryPackCache} (no cross-handler / multi-tenant
 *   pack-byte sharing).
 *
 * Pass `packCache: null` to disable; pass an explicit {@link PackCache} (e.g.
 * {@link defaultProcessPackCache}) to override.
 */
export function productDefaultPackCache(): PackCache {
  if (processPackCacheSharedFromEnv()) return defaultProcessPackCache();
  return new MemoryPackCache();
}

/**
 * Stable download-key for upload-pack cache (url + wants + haves + depth + filter).
 * Callers must pass a **public** locator (no userinfo / tokens). Auth is never
 * part of the key — credentials are only used at transport time.
 */
export function uploadPackCacheKey(opts: {
  url: string;
  wants: string[];
  haves?: string[];
  depth?: number;
  /** Partial clone filter; different filters must not share a cache entry. */
  filter?: string;
}): string {
  const wants = opts.wants
    .map((h) => h.toLowerCase())
    .filter(Boolean)
    .sort()
    .join(",");
  const haves = (opts.haves ?? [])
    .map((h) => h.toLowerCase())
    .filter(Boolean)
    .sort()
    .join(",");
  const filter = (opts.filter ?? "").trim();
  return `upload-pack:v1:${opts.url}:${wants}:${haves}:d${opts.depth ?? ""}:f${filter}`;
}

// ── Disk backend ────────────────────────────────────────────────────────────

/**
 * Node disk pack cache under `{dir}/`.
 * - Packs: content-addressed `{dir}/{sha256hex}.pack` (digest without `sha256:` prefix).
 * - Download-key index: `{dir}/keys/{sha256hex(key)}.key` — SHA-256 hex of the full
 *   download-key string (safe filename; dual-host parity with BEAM DiskPackCache).
 *   Old FNV-1a 32-bit key filenames are not migrated (miss is OK).
 */
export class DiskPackCache implements PackCache {
  constructor(private readonly dir: string) {}

  private pathFor(digest: string): string {
    const id = digest.replace(/^sha256:/, "");
    return `${this.dir.replace(/\/$/, "")}/${id}.pack`;
  }

  /** Safe filename path for a download key: SHA-256 hex of the full key string. */
  private async keyPath(key: string): Promise<string> {
    const digest = await sha256hex(new TextEncoder().encode(key));
    const hex = digest.replace(/^sha256:/, "");
    return `${this.dir.replace(/\/$/, "")}/keys/${hex}.key`;
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

  async getByKey(key: string): Promise<string | null> {
    try {
      const { readFile } = await import("node:fs/promises");
      const dig = (await readFile(await this.keyPath(key), "utf8")).trim();
      return dig || null;
    } catch {
      return null;
    }
  }

  async putKey(key: string, digest: string): Promise<void> {
    const { mkdir, writeFile } = await import("node:fs/promises");
    const dir = `${this.dir.replace(/\/$/, "")}/keys`;
    await mkdir(dir, { recursive: true });
    await writeFile(await this.keyPath(key), digest, "utf8");
  }
}

// ── Import helpers ──────────────────────────────────────────────────────────

/** Soft default: refuse packs larger than 64 MiB unless opt-in. From contracts/git.kdl. */
export const DEFAULT_MAX_PACK_BYTES = CONTRACT_DEFAULT_MAX_PACK_BYTES;

export interface ImportPackOptions {
  cache?: PackCache;
  /**
   * Max pack size. Default 64 MiB (contracts/git.kdl).
   * `0` means default (not unlimited) when MAX_PACK_ZERO_MEANS_DEFAULT.
   */
  maxPackBytes?: number;
  /** Chunk size for streaming ImportPack (default 1 MiB). */
  chunkBytes?: number;
}

export type ImportPackEngine = {
  importPack: (
    chunk: Uint8Array,
    meta?: { final?: boolean },
  ) => Promise<void>;
};

function resolveMaxPackBytes(opts: ImportPackOptions): number {
  if (opts.maxPackBytes === undefined) return DEFAULT_MAX_PACK_BYTES;
  if (opts.maxPackBytes === 0 && MAX_PACK_ZERO_MEANS_DEFAULT) {
    return DEFAULT_MAX_PACK_BYTES;
  }
  return opts.maxPackBytes;
}

/**
 * Feed a full pack buffer into the engine in `chunkBytes` slices (final on last).
 * Does not enforce size gate or cache — callers use {@link importPackCached}.
 */
export async function feedPackChunks(
  engine: ImportPackEngine,
  bytes: Uint8Array,
  chunkBytes = 1024 * 1024,
): Promise<void> {
  if (bytes.byteLength === 0) {
    await engine.importPack(new Uint8Array(0), { final: true });
    return;
  }
  const chunk = chunkBytes > 0 ? chunkBytes : bytes.byteLength;
  for (let off = 0; off < bytes.byteLength; off += chunk) {
    const slice = bytes.subarray(off, Math.min(off + chunk, bytes.byteLength));
    const final = off + slice.byteLength >= bytes.byteLength;
    await engine.importPack(slice, { final });
  }
}

/**
 * Import pack with optional cache hit and chunked ge_import_pack streaming.
 * Throws if pack exceeds maxPackBytes (unless maxPackBytes === 0).
 */
export async function importPackCached(
  engine: ImportPackEngine,
  pack: Uint8Array,
  opts: ImportPackOptions = {},
): Promise<{ digest: string; fromCache: boolean }> {
  const max = resolveMaxPackBytes(opts);
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

  await feedPackChunks(engine, bytes, opts.chunkBytes ?? 1024 * 1024);
  return { digest, fromCache };
}

/**
 * Stream pack slices into the engine. Each chunk is appended with
 * `final:false`; an empty final chunk commits. Enforces maxPackBytes on the
 * running total. When `cache` is set, concatenates for content-addressed put
 * after a successful stream (caller must not re-import).
 *
 * Use when download already pipes pack-aligned slices (e.g. FetchSmartHttp
 * `onPackChunk`) so the engine never waits on one giant buffer alone.
 */
export async function importPackStream(
  engine: ImportPackEngine,
  chunks: AsyncIterable<Uint8Array> | Iterable<Uint8Array>,
  opts: ImportPackOptions = {},
): Promise<{ digest: string; fromCache: boolean; pack: Uint8Array }> {
  const max = resolveMaxPackBytes(opts);
  const parts: Uint8Array[] = [];
  let total = 0;

  for await (const chunk of chunks as AsyncIterable<Uint8Array>) {
    if (!chunk || chunk.byteLength === 0) continue;
    if (max > 0 && total > max - chunk.byteLength) {
      throw new Error(
        `git: pack ${total + chunk.byteLength} bytes exceeds maxPackBytes ${max} (opt-in higher limit)`,
      );
    }
    total += chunk.byteLength;
    // Own the bytes — stream buffers may be reused.
    const owned = new Uint8Array(chunk.byteLength);
    owned.set(chunk);
    parts.push(owned);
    await engine.importPack(owned, { final: false });
  }

  await engine.importPack(new Uint8Array(0), { final: true });

  const pack =
    total === 0
      ? new Uint8Array(0)
      : (() => {
          const out = new Uint8Array(total);
          let off = 0;
          for (const p of parts) {
            out.set(p, off);
            off += p.byteLength;
          }
          return out;
        })();

  const cache = opts.cache;
  let digest = "";
  let fromCache = false;
  if (cache && pack.byteLength > 0) {
    digest = await sha256hex(pack);
    const hit = await cache.get(digest);
    if (hit) {
      fromCache = true;
    } else {
      digest = await cache.put(pack);
    }
  } else {
    digest = await sha256hex(pack);
  }
  return { digest, fromCache, pack };
}
