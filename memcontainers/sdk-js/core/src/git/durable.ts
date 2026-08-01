/**
 * Durable backends — persist engine worktree/ODB across reload.
 *
 * **Primary form:** a re-openable libgit2 worktree+ODB **directory** on host
 * disk (Node/server) or OPFS (browser). Checkpoint flushes that directory; a
 * second process `ge_open`s / hydrates the same path and sees the same HEAD +
 * worktree files. Prefer {@link HostDirDurable} / `{ durableDir }` when a real
 * directory is available.
 *
 * **Transfer form:** AGIT (pack+refs envelope) for **blob** backends
 * (`MemoryDurable` / `DiskDurable` / `OpfsDurable` snapshot.bin). Used when
 * only opaque bytes can travel (tests, cross-process handoff without a shared
 * path).
 */

// ── Face ────────────────────────────────────────────────────────────────────

/** Blob (AGIT/opaque) vs directory (real worktree root) durability. */
export type DurableKind = "blob" | "directory";

/**
 * Common durable store face.
 *
 * * **blob** — `save`/`load` opaque or AGIT bytes (transfer format).
 * * **directory** — real worktree+`.git` on disk/OPFS; `hostPath` is the root
 *   that a native engine `ge_open`s. Blob save/load are no-ops (null).
 */
export interface DurableBackend {
  readonly id: string;
  /** Default `"blob"` for implementations that omit `kind`. */
  readonly kind?: DurableKind;
  /** Persist durable snapshot bytes (AGIT / opaque). Directory backends: no-op. */
  save(snapshot: Uint8Array): Promise<void>;
  /** Load last blob snapshot; null if none or directory-backed. */
  load(): Promise<Uint8Array | null>;
  /** Drop durable state. */
  clear(): Promise<void>;
  /**
   * Directory backends only: absolute host path of the worktree root
   * (Node/server). Browser OPFS directory backends may omit this.
   */
  readonly hostPath?: string;
  /** Ensure directory exists; return absolute host path when applicable. */
  ensure?(): Promise<string | void>;
  /**
   * Flush engine state into the durable directory.
   * Node: fsync after MEMFS dump (or write-through NODEFS).
   * OPFS: write tree under the OPFS handle.
   */
  sync?(): Promise<void>;
  /**
   * Copy durable tree → Emscripten MEMFS at `workRoot` (when NODEFS is not
   * mounting the host path). No-op for pure blob backends.
   */
  hydrateToMemfs?(
    FS: MemfsLike,
    workRoot: string,
  ): Promise<void>;
  /**
   * Copy MEMFS worktree → durable tree (checkpoint path without NODEFS).
   */
  dumpFromMemfs?(
    FS: MemfsLike,
    workRoot: string,
  ): Promise<void>;
}

/** Minimal Emscripten FS surface used by directory hydrate/dump. */
export type MemfsLike = {
  mkdir(path: string): void;
  mkdirTree?(path: string): void;
  readdir(path: string): string[];
  stat(path: string): { mode: number; size?: number };
  isDir(mode: number): boolean;
  readFile(path: string, opts?: { encoding?: string }): Uint8Array | string;
  writeFile(path: string, data: Uint8Array | string): void;
  unlink(path: string): void;
  rmdir(path: string): void;
  analyzePath?(path: string): { exists: boolean };
};

export function isDirectoryDurable(
  b: DurableBackend | undefined | null,
): b is DurableBackend & { kind: "directory" } {
  return !!b && b.kind === "directory";
}

export function isBlobDurable(b: DurableBackend | undefined | null): boolean {
  return !!b && b.kind !== "directory";
}

// ── Ids + process registry ──────────────────────────────────────────────────

/**
 * Process-scoped MemoryDurable instances.
 * Same `id` via {@link openDurable} reuses one store so snapshot → restore /
 * fork in the same JS process rebinds AGIT without OPFS/disk.
 */
const memoryDurableRegistry = new Map<string, MemoryDurable>();

/**
 * Stable durable id for a gitfs mount under a VM/session base id.
 * Example: `durableIdForMount("agent", "/workspace/repo")` → `agent:@workspace@repo`.
 */
export function durableIdForMount(baseId: string, mountPath: string): string {
  const base = (baseId || "default").trim() || "default";
  const mount = String(mountPath || "")
    .trim()
    .replace(/\\/g, "/");
  const safeMount = mount
    .replace(/[^A-Za-z0-9._:@+/-]+/g, "_")
    .replace(/\/+/g, "@");
  return `${base}:${safeMount || "@"}`;
}

/** Drop process-local MemoryDurable instances (tests). */
export function clearMemoryDurableRegistry(): void {
  memoryDurableRegistry.clear();
}

/** Sanitize an id for use as a single path segment under a disk root. */
export function safeDurablePathSegment(id: string): string {
  return String(id || "default").replace(/[^A-Za-z0-9._:@+-]+/g, "_") || "default";
}

// ── Blob backends ───────────────────────────────────────────────────────────

/** In-memory durability (tests / default when OPFS unavailable). AGIT blob. */
export class MemoryDurable implements DurableBackend {
  readonly kind = "blob" as const;
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
 * Browser OPFS **blob** store (AGIT transfer). Keyed under
 * `agentos-git/{id}/snapshot.bin`. Prefer {@link OpfsDirDurable} for a
 * re-openable worktree tree under OPFS.
 */
export class OpfsDurable implements DurableBackend {
  readonly kind = "blob" as const;
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

// ── Directory backends ──────────────────────────────────────────────────────

/**
 * Browser OPFS **directory** durable store — worktree tree under
 * `agentos-git/{id}/work/`. Hydrate/dump MEMFS on load/checkpoint so a page
 * refresh reopens the same HEAD + files (where OPFS is available).
 */
export class OpfsDirDurable implements DurableBackend {
  readonly kind = "directory" as const;
  private constructor(
    readonly id: string,
    private readonly work: FileSystemDirectoryHandle,
  ) {}

  static async open(id = "default"): Promise<OpfsDirDurable | null> {
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
      const work = await root.getDirectoryHandle("work", { create: true });
      return new OpfsDirDurable(id, work);
    } catch {
      return null;
    }
  }

  async save(_snapshot: Uint8Array): Promise<void> {
    /* directory is the store */
  }

  async load(): Promise<Uint8Array | null> {
    return null;
  }

  async ensure(): Promise<void> {
    /* handle already created in open() */
  }

  async sync(): Promise<void> {
    /* OPFS writes in dumpFromMemfs are durable on close of writable */
  }

  async clear(): Promise<void> {
    await clearOpfsDir(this.work);
  }

  async hydrateToMemfs(FS: MemfsLike, workRoot: string): Promise<void> {
    ensureMemfsDir(FS, workRoot);
    await opfsTreeToMemfs(this.work, FS, workRoot);
  }

  async dumpFromMemfs(FS: MemfsLike, workRoot: string): Promise<void> {
    await clearOpfsDir(this.work);
    await memfsTreeToOpfs(FS, workRoot, this.work);
  }
}

/**
 * Server / Node disk **blob** store (AGIT transfer). Writes `{dir}/snapshot.bin`.
 * Prefer {@link HostDirDurable} for a re-openable worktree directory.
 */
export class DiskDurable implements DurableBackend {
  readonly kind = "blob" as const;
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

/**
 * Host disk **directory** durable store — the worktree+`.git` **is** the store.
 *
 * Product path:
 * * `GitEngine.load({ durableDir: path })` → {@link HostDirDurable}
 * * Checkpoint dumps MEMFS → this directory (or fsync when NODEFS write-through)
 * * Second process loads the same path and sees the same HEAD + files
 * * Native BEAM `ge_open(path)` reopens the same libgit2 root without AGIT
 */
export class HostDirDurable implements DurableBackend {
  readonly kind = "directory" as const;
  readonly hostPath: string;

  constructor(
    readonly id: string,
    hostPath: string,
  ) {
    this.hostPath = hostPath.replace(/\/$/, "") || hostPath;
  }

  /** Absolute normalized path (ensure() resolves). */
  private absPath: string | null = null;

  async ensure(): Promise<string> {
    const { mkdir } = await import("node:fs/promises");
    const { resolve } = await import("node:path");
    const abs = resolve(this.hostPath);
    await mkdir(abs, { recursive: true });
    this.absPath = abs;
    return abs;
  }

  async save(_snapshot: Uint8Array): Promise<void> {
    /* directory is the store — use dumpFromMemfs / sync */
  }

  async load(): Promise<Uint8Array | null> {
    return null;
  }

  async sync(): Promise<void> {
    const abs = this.absPath ?? this.hostPath;
    try {
      const { open, constants } = await import("node:fs/promises");
      // Best-effort directory fsync (Linux); ignore unsupported platforms.
      const fh = await open(abs, constants.O_RDONLY);
      try {
        await fh.sync();
      } catch {
        /* O_DIRECTORY / fsync not supported */
      } finally {
        await fh.close();
      }
    } catch {
      /* */
    }
  }

  async clear(): Promise<void> {
    const { rm } = await import("node:fs/promises");
    const abs = await this.ensure();
    await rm(abs, { recursive: true, force: true });
    const { mkdir } = await import("node:fs/promises");
    await mkdir(abs, { recursive: true });
  }

  async hydrateToMemfs(FS: MemfsLike, workRoot: string): Promise<void> {
    const abs = await this.ensure();
    ensureMemfsDir(FS, workRoot);
    await hostTreeToMemfs(abs, FS, workRoot);
  }

  async dumpFromMemfs(FS: MemfsLike, workRoot: string): Promise<void> {
    const abs = await this.ensure();
    await memfsTreeToHost(FS, workRoot, abs);
    await this.sync();
  }
}

// ── Factory ─────────────────────────────────────────────────────────────────

/**
 * Prefer host **directory** when `diskDir`/`durableDir` given; else OPFS
 * directory (browser); else OPFS blob; else process-scoped memory blob.
 *
 * When `diskDir` is set, the worktree root is `{diskDir}/{safeId}/` so multiple
 * mounts under one VM share a disk root without clobbering (matches
 * memcontainer `git.durable.diskDir` layout).
 */
export async function openDurable(opts: {
  id?: string;
  diskDir?: string;
  /**
   * Exact host worktree directory (no id suffix). Prefer this for a single
   * engine `GitEngine.load({ durableDir })` path.
   */
  durableDir?: string;
  /** Prefer directory OPFS over blob snapshot.bin when true (default true). */
  preferDirectory?: boolean;
  /**
   * When true with `diskDir`, use AGIT `snapshot.bin` under `{diskDir}/{id}/`
   * instead of a re-openable worktree directory.
   */
  blobOnDisk?: boolean;
}): Promise<DurableBackend> {
  const id = opts.id ?? "default";
  if (opts.durableDir) {
    return new HostDirDurable(id, opts.durableDir);
  }
  if (opts.diskDir) {
    const baseDir = opts.diskDir.replace(/\/$/, "");
    const dir = `${baseDir}/${safeDurablePathSegment(id)}`;
    if (opts.blobOnDisk) {
      return new DiskDurable(id, dir);
    }
    return new HostDirDurable(id, dir);
  }
  const preferDir = opts.preferDirectory !== false;
  if (preferDir) {
    const opfsDir = await OpfsDirDurable.open(id);
    if (opfsDir) return opfsDir;
  }
  const opfs = await OpfsDurable.open(id);
  if (opfs) return opfs;
  // Process registry: second openDurable({ id }) reuses the same MemoryDurable
  // so AGIT rebind after "restore" in the same process sees prior checkpoint.
  let mem = memoryDurableRegistry.get(id);
  if (!mem) {
    mem = new MemoryDurable(id);
    memoryDurableRegistry.set(id, mem);
  }
  return mem;
}

// ── MEMFS ↔ host / OPFS tree helpers ────────────────────────────────────────

function ensureMemfsDir(FS: MemfsLike, path: string): void {
  if (typeof FS.mkdirTree === "function") {
    try {
      FS.mkdirTree(path);
      return;
    } catch {
      /* fall through */
    }
  }
  const parts = path.split("/").filter(Boolean);
  let cur = "";
  for (const part of parts) {
    cur += "/" + part;
    try {
      FS.mkdir(cur);
    } catch {
      /* exists */
    }
  }
}

function memfsExists(FS: MemfsLike, path: string): boolean {
  if (typeof FS.analyzePath === "function") {
    try {
      return !!FS.analyzePath(path).exists;
    } catch {
      /* */
    }
  }
  try {
    FS.stat(path);
    return true;
  } catch {
    return false;
  }
}

function clearMemfsDir(FS: MemfsLike, path: string): void {
  if (!memfsExists(FS, path)) return;
  let names: string[];
  try {
    names = FS.readdir(path);
  } catch {
    return;
  }
  for (const name of names) {
    if (name === "." || name === "..") continue;
    const child = `${path}/${name}`;
    try {
      const st = FS.stat(child);
      if (FS.isDir(st.mode)) {
        clearMemfsDir(FS, child);
        try {
          FS.rmdir(child);
        } catch {
          /* */
        }
      } else {
        try {
          FS.unlink(child);
        } catch {
          /* */
        }
      }
    } catch {
      /* */
    }
  }
}

async function hostTreeToMemfs(
  hostRoot: string,
  FS: MemfsLike,
  memRoot: string,
): Promise<void> {
  const { readdir, readFile, stat } = await import("node:fs/promises");
  const { join } = await import("node:path");

  async function walk(hostDir: string, memDir: string): Promise<void> {
    let entries;
    try {
      entries = await readdir(hostDir, { withFileTypes: true });
    } catch {
      return;
    }
    ensureMemfsDir(FS, memDir);
    for (const ent of entries) {
      const h = join(hostDir, ent.name);
      const m = `${memDir}/${ent.name}`;
      if (ent.isDirectory()) {
        await walk(h, m);
      } else if (ent.isFile()) {
        try {
          const st = await stat(h);
          if (!st.isFile()) continue;
          const data = new Uint8Array(await readFile(h));
          ensureMemfsDir(FS, memDir);
          FS.writeFile(m, data);
        } catch {
          /* skip unreadable */
        }
      }
      /* Skip symlinks/specials on hydrate (same as add all=true).
       * Explicit engine add/write of a symlink path fails closed. */
    }
  }

  // Replace MEMFS worktree contents with host tree.
  if (memfsExists(FS, memRoot)) {
    clearMemfsDir(FS, memRoot);
  }
  ensureMemfsDir(FS, memRoot);
  await walk(hostRoot, memRoot);
}

async function memfsTreeToHost(
  FS: MemfsLike,
  memRoot: string,
  hostRoot: string,
): Promise<void> {
  const { mkdir, rm, readdir } = await import("node:fs/promises");
  const { join } = await import("node:path");

  // Clear host root contents (keep root dir) then dump MEMFS tree.
  try {
    const existing = await readdir(hostRoot, { withFileTypes: true });
    for (const ent of existing) {
      await rm(join(hostRoot, ent.name), { recursive: true, force: true });
    }
  } catch {
    await mkdir(hostRoot, { recursive: true });
  }

  await mkdir(hostRoot, { recursive: true });
  await dumpMemfsSequential(FS, memRoot, hostRoot);
}

async function dumpMemfsSequential(
  FS: MemfsLike,
  memDir: string,
  hostDir: string,
): Promise<void> {
  const { mkdir, writeFile } = await import("node:fs/promises");
  const { join } = await import("node:path");
  await mkdir(hostDir, { recursive: true });
  let names: string[];
  try {
    names = FS.readdir(memDir);
  } catch {
    return;
  }
  for (const name of names) {
    if (name === "." || name === "..") continue;
    const m = `${memDir}/${name}`;
    const h = join(hostDir, name);
    try {
      const st = FS.stat(m);
      if (FS.isDir(st.mode)) {
        await dumpMemfsSequential(FS, m, h);
      } else {
        const raw = FS.readFile(m);
        const data =
          typeof raw === "string"
            ? new TextEncoder().encode(raw)
            : raw instanceof Uint8Array
              ? raw
              : new Uint8Array(raw as ArrayBuffer);
        await writeFile(h, data);
      }
    } catch {
      /* */
    }
  }
}

async function clearOpfsDir(dir: FileSystemDirectoryHandle): Promise<void> {
  // FileSystemDirectoryHandle async iterator
  const toRemove: { name: string; kind: string }[] = [];
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const anyDir = dir as any;
  if (typeof anyDir.values === "function") {
    for await (const entry of anyDir.values()) {
      toRemove.push({ name: entry.name, kind: entry.kind });
    }
  } else if (typeof anyDir.entries === "function") {
    for await (const [name, entry] of anyDir.entries()) {
      toRemove.push({ name, kind: entry.kind });
    }
  }
  for (const e of toRemove) {
    try {
      await dir.removeEntry(e.name, { recursive: true });
    } catch {
      try {
        await dir.removeEntry(e.name);
      } catch {
        /* */
      }
    }
  }
}

async function opfsTreeToMemfs(
  dir: FileSystemDirectoryHandle,
  FS: MemfsLike,
  memDir: string,
): Promise<void> {
  ensureMemfsDir(FS, memDir);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const anyDir = dir as any;
  const entries: { name: string; handle: FileSystemHandle }[] = [];
  if (typeof anyDir.values === "function") {
    for await (const entry of anyDir.values()) {
      entries.push({ name: entry.name, handle: entry });
    }
  } else if (typeof anyDir.entries === "function") {
    for await (const [name, handle] of anyDir.entries()) {
      entries.push({ name, handle });
    }
  }
  for (const { name, handle } of entries) {
    const m = `${memDir}/${name}`;
    if (handle.kind === "directory") {
      const sub = await dir.getDirectoryHandle(name);
      await opfsTreeToMemfs(sub, FS, m);
    } else if (handle.kind === "file") {
      const fh = await dir.getFileHandle(name);
      const file = await fh.getFile();
      const data = new Uint8Array(await file.arrayBuffer());
      ensureMemfsDir(FS, memDir);
      FS.writeFile(m, data);
    }
  }
}

async function memfsTreeToOpfs(
  FS: MemfsLike,
  memDir: string,
  dir: FileSystemDirectoryHandle,
): Promise<void> {
  let names: string[];
  try {
    names = FS.readdir(memDir);
  } catch {
    return;
  }
  for (const name of names) {
    if (name === "." || name === "..") continue;
    const m = `${memDir}/${name}`;
    try {
      const st = FS.stat(m);
      if (FS.isDir(st.mode)) {
        const sub = await dir.getDirectoryHandle(name, { create: true });
        await memfsTreeToOpfs(FS, m, sub);
      } else {
        const raw = FS.readFile(m);
        const data =
          typeof raw === "string"
            ? new TextEncoder().encode(raw)
            : raw instanceof Uint8Array
              ? raw
              : new Uint8Array(raw as ArrayBuffer);
        const fh = await dir.getFileHandle(name, { create: true });
        const w = await fh.createWritable();
        await w.write(data);
        await w.close();
      }
    } catch {
      /* */
    }
  }
}

// ── AGIT envelope ───────────────────────────────────────────────────────────
// Layout: magic `AGIT` | u32 LE json_len | json(refs+head) | pack bytes

/** Magic bytes `AGIT` for durable rebind blobs (optional transfer format). */
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
 * Parse an AGIT envelope. Returns null for opaque non-AGIT blobs
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
