/**
 * Durable backends — persist engine worktree/ODB across reload.
 *
 * **Primary server form:** a re-openable libgit2 worktree+ODB directory on host
 * disk. Checkpoint replaces that directory atomically; a second process opens
 * the same path and sees the same HEAD and worktree files.
 *
 * **Transfer form:** the AgentOS Git Snapshot full-tree envelope for **blob** backends
 * (`MemoryDurable` / `DiskDurable` / `OpfsDurable` snapshot.bin). Used when
 * only opaque bytes can travel (tests, cross-process handoff without a shared
 * path).
 */

// ── Face ────────────────────────────────────────────────────────────────────

/** Snapshot blob vs directory (real worktree root) durability. */
export type DurableKind = "blob" | "directory";

/**
 * Common durable store face.
 *
 * * **blob** — `save`/`load` AgentOS Git Snapshot bytes.
 * * **directory** — real worktree+`.git` on host disk; `hostPath` is the root
 *   that a native engine opens. Blob save/load are no-ops (null).
 */
export interface DurableBackend {
  readonly id: string;
  /** Default `"blob"` for implementations that omit `kind`. */
  readonly kind?: DurableKind;
  /** Persist AgentOS Git Snapshot bytes. Directory backends: no-op. */
  save(snapshot: Uint8Array): Promise<void>;
  /** Load last blob snapshot; null if none or directory-backed. */
  load(): Promise<Uint8Array | null>;
  /** Drop durable state. */
  clear(): Promise<void>;
  /**
   * Directory backends only: absolute host path of the worktree root.
   */
  readonly hostPath?: string;
  /** Ensure directory exists; return absolute host path when applicable. */
  ensure?(): Promise<string | void>;
  /**
   * Flush engine state into the durable host directory.
   */
  sync?(): Promise<void>;
  /**
   * Copy durable tree → Emscripten MEMFS at `workRoot`. No-op for pure blob
   * backends.
   */
  hydrateToMemfs?(FS: MemfsLike, workRoot: string): Promise<void>;
  /**
   * Copy MEMFS worktree → durable tree for an atomic generation checkpoint.
   */
  dumpFromMemfs?(FS: MemfsLike, workRoot: string): Promise<void>;
}

/** Minimal Emscripten FS surface used by directory hydrate/dump. */
export type MemfsLike = {
  mkdir(path: string): void;
  mkdirTree?(path: string): void;
  readdir(path: string): string[];
  stat(path: string): { mode: number; size?: number };
  lstat?(path: string): { mode: number; size?: number };
  isDir(mode: number): boolean;
  isLink?(mode: number): boolean;
  readlink?(path: string): string;
  symlink?(target: string, link: string): void;
  readFile(path: string, opts?: { encoding?: string }): Uint8Array | string;
  writeFile(path: string, data: Uint8Array | string): void;
  unlink(path: string): void;
  rmdir(path: string): void;
  chmod?(path: string, mode: number): void;
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
 * fork in the same JS process restores a snapshot without OPFS/disk.
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
  const safeMount = mount.replace(/[^A-Za-z0-9._:@+/-]+/g, "_").replace(/\/+/g, "@");
  return `${base}:${safeMount || "@"}`;
}

/** Drop process-local MemoryDurable instances (tests). */
export function clearMemoryDurableRegistry(): void {
  memoryDurableRegistry.clear();
}

/** Sanitize an id for use as a single path segment under a disk root. */
export function safeDurablePathSegment(id: string): string {
  const segment = String(id || "default").replace(/[^A-Za-z0-9._:@+-]+/g, "_") || "default";
  return segment === "." || segment === ".." ? "default" : segment;
}

function isMissingError(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const value = error as { code?: unknown; name?: unknown };
  return value.code === "ENOENT" || value.name === "NotFoundError";
}

let durableTempGeneration = 0;

function durableTempSuffix(): string {
  durableTempGeneration += 1;
  return `${typeof process !== "undefined" ? process.pid : 0}-${Date.now()}-${durableTempGeneration}`;
}

// ── Blob backends ───────────────────────────────────────────────────────────

/** In-memory snapshot durability (tests / default when OPFS is unavailable). */
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
 * Browser OPFS **blob** store (complete repository snapshot). Keyed under
 * `agentos-git/{id}/snapshot.bin`.
 */
export class OpfsDurable implements DurableBackend {
  readonly kind = "blob" as const;
  private constructor(
    readonly id: string,
    private readonly root: FileSystemDirectoryHandle,
  ) {}

  static async open(id = "default"): Promise<OpfsDurable | null> {
    const nav = globalThis.navigator as
      | (Navigator & {
          storage?: { getDirectory?: () => Promise<FileSystemDirectoryHandle> };
        })
      | undefined;
    if (!nav?.storage?.getDirectory) return null;
    const opfs = await nav.storage.getDirectory();
    const agent = await opfs.getDirectoryHandle("agentos-git", { create: true });
    const root = await agent.getDirectoryHandle(safeDurablePathSegment(id), { create: true });
    return new OpfsDurable(id, root);
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
    } catch (error) {
      if (isMissingError(error)) return null;
      throw error;
    }
  }

  async clear(): Promise<void> {
    try {
      await this.root.removeEntry("snapshot.bin");
    } catch (error) {
      if (!isMissingError(error)) throw error;
    }
  }
}

// ── Directory backends ──────────────────────────────────────────────────────

/**
 * Server / Node disk **blob** store (complete repository snapshot). Writes `{dir}/snapshot.bin`.
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
    const { mkdir, open, rename, rm, writeFile } = await import("node:fs/promises");
    await mkdir(this.dir, { recursive: true });
    const next = `${this.path()}.next-${durableTempSuffix()}`;
    try {
      await writeFile(next, snapshot);
      const file = await open(next, "r");
      try {
        await file.sync();
      } finally {
        await file.close();
      }
      await rename(next, this.path());
      const dir = await open(this.dir, "r");
      try {
        await dir.sync();
      } finally {
        await dir.close();
      }
    } catch (error) {
      await rm(next, { force: true });
      throw error;
    }
  }

  async load(): Promise<Uint8Array | null> {
    try {
      const { readFile } = await import("node:fs/promises");
      return new Uint8Array(await readFile(this.path()));
    } catch (error) {
      if (isMissingError(error)) return null;
      throw error;
    }
  }

  async clear(): Promise<void> {
    try {
      const { unlink } = await import("node:fs/promises");
      await unlink(this.path());
    } catch (error) {
      if (!isMissingError(error)) throw error;
    }
  }
}

/**
 * Host disk **directory** durable store — the worktree+`.git` **is** the store.
 *
 * Product path:
 * * `GitEngine.load({ durableDir: path })` → {@link HostDirDurable}
 * * Checkpoint stages MEMFS and atomically swaps a complete generation
 * * Second process loads the same path and sees the same HEAD + files
 * * Native BEAM `ge_open(path)` reopens the same libgit2 root directly
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
    if (!this.hostPath.trim()) throw new Error("durable directory path is empty");
    const { lstat, mkdir } = await import("node:fs/promises");
    const { join, parse, resolve } = await import("node:path");
    const abs = resolve(this.hostPath);
    const root = parse(abs).root;
    if (abs === root) throw new Error("durable directory must not be a filesystem root");
    let current = root;
    for (const part of abs
      .slice(root.length)
      .split(/[\\/]+/)
      .filter(Boolean)) {
      current = join(current, part);
      let st;
      try {
        st = await lstat(current);
      } catch (error) {
        if (!isMissingError(error)) throw error;
        await mkdir(current);
        st = await lstat(current);
      }
      if (st.isSymbolicLink() || !st.isDirectory()) {
        throw new Error(`durable directory has an unsafe path component: ${current}`);
      }
    }
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
    const abs = await this.ensure();
    const { open, constants } = await import("node:fs/promises");
    const fh = await open(abs, constants.O_RDONLY);
    try {
      await fh.sync();
    } finally {
      await fh.close();
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
 * Prefer host **directory** when `diskDir`/`durableDir` is given; otherwise use
 * an atomic OPFS blob in browsers, then a process-scoped memory blob fallback.
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
  /**
   * When true with `diskDir`, use `snapshot.bin` under `{diskDir}/{id}/`
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
  const opfs = await OpfsDurable.open(id);
  if (opfs) return opfs;
  // Process registry: second openDurable({ id }) reuses the same MemoryDurable
  // so restore in the same process sees the prior checkpoint.
  let mem = memoryDurableRegistry.get(id);
  if (!mem) {
    mem = new MemoryDurable(id);
    memoryDurableRegistry.set(id, mem);
  }
  return mem;
}

// ── MEMFS ↔ host tree helpers ───────────────────────────────────────────────

function ensureMemfsDir(FS: MemfsLike, path: string): void {
  if (typeof FS.mkdirTree === "function") {
    try {
      FS.mkdirTree(path);
      return;
    } catch {
      const st = FS.stat(path);
      if (FS.isDir(st.mode)) return;
      throw new Error(`durable tree: path is not a directory: ${path}`);
    }
  }
  const parts = path.split("/").filter(Boolean);
  let cur = "";
  for (const part of parts) {
    cur += "/" + part;
    try {
      FS.mkdir(cur);
    } catch {
      const st = FS.stat(cur);
      if (!FS.isDir(st.mode)) {
        throw new Error(`durable tree: path is not a directory: ${cur}`);
      }
    }
  }
}

function memfsExists(FS: MemfsLike, path: string): boolean {
  if (typeof FS.analyzePath === "function") {
    return !!FS.analyzePath(path).exists;
  }
  try {
    FS.stat(path);
    return true;
  } catch (error) {
    const value = error as { code?: unknown; errno?: unknown };
    if (value?.code === "ENOENT" || value?.errno === 44) return false;
    throw error;
  }
}

function clearMemfsDir(FS: MemfsLike, path: string): void {
  if (!memfsExists(FS, path)) return;
  for (const name of FS.readdir(path)) {
    if (name === "." || name === "..") continue;
    const child = `${path}/${name}`;
    const st = FS.lstat ? FS.lstat(child) : FS.stat(child);
    if (FS.isLink?.(st.mode)) {
      FS.unlink(child);
    } else if (FS.isDir(st.mode)) {
      clearMemfsDir(FS, child);
      FS.rmdir(child);
    } else {
      FS.unlink(child);
    }
  }
}

/** Engine runtime mailboxes/exports are reconstructible and never durable state. */
function isTransientEnginePath(rel: string): boolean {
  return (
    rel === ".git/mc" ||
    rel.startsWith(".git/mc/") ||
    rel === ".git/agentos" ||
    rel.startsWith(".git/agentos/")
  );
}

async function hostTreeToMemfs(hostRoot: string, FS: MemfsLike, memRoot: string): Promise<void> {
  const { lstat, readFile, readlink, readdir } = await import("node:fs/promises");
  const { join } = await import("node:path");

  async function walk(hostDir: string, memDir: string, rel: string): Promise<void> {
    const entries = await readdir(hostDir, { withFileTypes: true });
    ensureMemfsDir(FS, memDir);
    for (const ent of entries) {
      const h = join(hostDir, ent.name);
      const m = `${memDir}/${ent.name}`;
      const childRel = rel ? `${rel}/${ent.name}` : ent.name;
      if (isTransientEnginePath(childRel)) continue;
      if (ent.isDirectory()) {
        await walk(h, m, childRel);
        const st = await lstat(h);
        if (!st.isDirectory()) throw new Error(`durable tree: unsupported host node ${h}`);
        FS.chmod?.(m, st.mode & 0o777);
      } else if (ent.isFile()) {
        const st = await lstat(h);
        if (!st.isFile()) throw new Error(`durable tree: unsupported host node ${h}`);
        const data = new Uint8Array(await readFile(h));
        ensureMemfsDir(FS, memDir);
        FS.writeFile(m, data);
        FS.chmod?.(m, st.mode & 0o777);
      } else if (ent.isSymbolicLink()) {
        if (!FS.symlink) throw new Error("durable tree: MEMFS symlink support unavailable");
        FS.symlink(await readlink(h), m);
      } else {
        throw new Error(`durable tree: unsupported host node ${h}`);
      }
    }
  }

  // Replace MEMFS worktree contents with host tree.
  if (memfsExists(FS, memRoot)) {
    clearMemfsDir(FS, memRoot);
  }
  ensureMemfsDir(FS, memRoot);
  await walk(hostRoot, memRoot, "");
}

async function memfsTreeToHost(FS: MemfsLike, memRoot: string, hostRoot: string): Promise<void> {
  const { mkdir, rm, rename, open, constants } = await import("node:fs/promises");
  const { dirname, basename, join } = await import("node:path");
  const parent = dirname(hostRoot);
  const stem = basename(hostRoot);
  const suffix = durableTempSuffix();
  const next = join(parent, `.${stem}.next-${suffix}`);
  const prior = join(parent, `.${stem}.prior-${suffix}`);
  await mkdir(parent, { recursive: true });
  await rm(next, { recursive: true, force: true });
  await rm(prior, { recursive: true, force: true });
  await mkdir(next, { recursive: true });
  let movedPrior = false;
  let installedNext = false;
  try {
    await dumpMemfsSequential(FS, memRoot, next);
    try {
      await rename(hostRoot, prior);
      movedPrior = true;
    } catch (error) {
      if (!isMissingError(error)) throw error;
    }
    await rename(next, hostRoot);
    installedNext = true;
    const parentHandle = await open(parent, constants.O_RDONLY);
    try {
      await parentHandle.sync();
    } finally {
      await parentHandle.close();
    }
  } catch (error) {
    await rm(next, { recursive: true, force: true });
    try {
      if (installedNext) await rm(hostRoot, { recursive: true, force: true });
      if (movedPrior) await rename(prior, hostRoot);
    } catch (rollbackError) {
      throw new AggregateError(
        [error, rollbackError],
        "durable tree: checkpoint failed and prior generation could not be restored",
      );
    }
    throw error;
  }
  // The new generation is installed and its parent rename is durable. Failure
  // to reap the old generation must never roll back (or delete) the new one.
  if (movedPrior) await rm(prior, { recursive: true, force: true });
}

async function dumpMemfsSequential(
  FS: MemfsLike,
  memDir: string,
  hostDir: string,
  rel = "",
): Promise<void> {
  const { chmod, mkdir, open, symlink, writeFile } = await import("node:fs/promises");
  const { join } = await import("node:path");
  await mkdir(hostDir, { recursive: true });
  const names = FS.readdir(memDir);
  for (const name of names) {
    if (name === "." || name === "..") continue;
    const m = `${memDir}/${name}`;
    const h = join(hostDir, name);
    const childRel = rel ? `${rel}/${name}` : name;
    if (isTransientEnginePath(childRel)) continue;
    const st = FS.lstat ? FS.lstat(m) : FS.stat(m);
    if (FS.isLink?.(st.mode)) {
      if (!FS.readlink) throw new Error("durable tree: MEMFS readlink support unavailable");
      await symlink(FS.readlink(m), h);
    } else if (FS.isDir(st.mode)) {
      await dumpMemfsSequential(FS, m, h, childRel);
    } else {
      const raw = FS.readFile(m);
      const data =
        typeof raw === "string"
          ? new TextEncoder().encode(raw)
          : raw instanceof Uint8Array
            ? raw
            : new Uint8Array(raw as ArrayBuffer);
      await writeFile(h, data);
      await chmod(h, st.mode & 0o777);
      const file = await open(h, "r");
      try {
        await file.sync();
      } finally {
        await file.close();
      }
    }
  }
  const dirStat = FS.lstat ? FS.lstat(memDir) : FS.stat(memDir);
  const dir = await open(hostDir, "r");
  try {
    await chmod(hostDir, dirStat.mode & 0o777);
    await dir.sync();
  } finally {
    await dir.close();
  }
}

// ── AgentOS Git Snapshot blob ───────────────────────────────────────────────

/** Full coding-state blob cap (worktree + index + ODB + sparse metadata). */
const DURABLE_TREE_MAX_BYTES = 64 * 1024 * 1024;
const DURABLE_TREE_MAX_NODES = 100_000;
const DURABLE_TREE_MAX_META_BYTES = 4 * 1024 * 1024;
const DURABLE_TREE_MAX_PATH_BYTES = 4096;
/** Wire magic `AOGS` (AgentOS Git Snapshot). */
export const GIT_SNAPSHOT_MAGIC = new Uint8Array([0x41, 0x4f, 0x47, 0x53]);

type DurableTreeDir = {
  path: string;
  mode: number;
};

type DurableTreeFile = {
  path: string;
  mode: number;
  offset: number;
  length: number;
};

type DurableTreeLink = {
  path: string;
  target: string;
};

export type DecodedDurableTree = {
  dirs: DurableTreeDir[];
  files: DurableTreeFile[];
  links: DurableTreeLink[];
  data: Uint8Array;
};

function safeTreeRelative(path: string): boolean {
  return (
    path.length > 0 &&
    !path.includes("\0") &&
    new TextEncoder().encode(path).byteLength <= DURABLE_TREE_MAX_PATH_BYTES &&
    !path.startsWith("/") &&
    !path.includes("\\") &&
    path.split("/").every((part) => part !== "" && part !== "." && part !== "..")
  );
}

/** Capture durable repository state, excluding reconstructible engine runtime artifacts. */
export function encodeDurableTreeBlob(FS: MemfsLike, root: string): Uint8Array {
  const dirs: DurableTreeDir[] = [];
  const files: DurableTreeFile[] = [];
  const links: DurableTreeLink[] = [];
  const parts: Uint8Array[] = [];
  let total = 0;

  const walk = (abs: string, rel: string, mode = 0o755): void => {
    const names = FS.readdir(abs)
      .filter((n) => n !== "." && n !== "..")
      .sort();
    if (rel) {
      if (dirs.length + files.length + links.length >= DURABLE_TREE_MAX_NODES) {
        throw new Error("durable tree: node-count cap exceeded");
      }
      dirs.push({ path: rel, mode });
    }
    for (const name of names) {
      const childAbs = `${abs}/${name}`;
      const childRel = rel ? `${rel}/${name}` : name;
      if (!safeTreeRelative(childRel)) throw new Error("durable tree: unsafe MEMFS path");
      if (isTransientEnginePath(childRel)) continue;
      const st = FS.lstat ? FS.lstat(childAbs) : FS.stat(childAbs);
      if (FS.isLink?.(st.mode)) {
        if (!FS.readlink) throw new Error("durable tree: MEMFS readlink support unavailable");
        if (dirs.length + files.length + links.length >= DURABLE_TREE_MAX_NODES) {
          throw new Error("durable tree: node-count cap exceeded");
        }
        const target = FS.readlink(childAbs);
        if (target.includes("\0") || new TextEncoder().encode(target).byteLength > 4096) {
          throw new Error("durable tree: invalid symlink target");
        }
        links.push({ path: childRel, target });
        continue;
      }
      if (FS.isDir(st.mode)) {
        walk(childAbs, childRel, st.mode & 0o777);
        continue;
      }
      if (dirs.length + files.length + links.length >= DURABLE_TREE_MAX_NODES) {
        throw new Error("durable tree: node-count cap exceeded");
      }
      const raw = FS.readFile(childAbs);
      const bytes =
        typeof raw === "string"
          ? new TextEncoder().encode(raw)
          : raw instanceof Uint8Array
            ? raw.slice()
            : new Uint8Array(raw as ArrayBuffer).slice();
      if (bytes.byteLength > DURABLE_TREE_MAX_BYTES - total) {
        throw new Error("durable tree: 64 MiB data cap exceeded");
      }
      files.push({
        path: childRel,
        mode: st.mode & 0o777,
        offset: total,
        length: bytes.byteLength,
      });
      parts.push(bytes);
      total += bytes.byteLength;
    }
  };
  walk(root, "");

  const meta = new TextEncoder().encode(JSON.stringify({ v: 1, dirs, files, links }));
  if (meta.byteLength > DURABLE_TREE_MAX_META_BYTES) {
    throw new Error("durable tree: metadata cap exceeded");
  }
  const out = new Uint8Array(8 + meta.byteLength + total);
  out.set(GIT_SNAPSHOT_MAGIC, 0);
  new DataView(out.buffer).setUint32(4, meta.byteLength, true);
  out.set(meta, 8);
  let off = 8 + meta.byteLength;
  for (const bytes of parts) {
    out.set(bytes, off);
    off += bytes.byteLength;
  }
  return out;
}

export function decodeDurableTreeBlob(data: Uint8Array): DecodedDurableTree | null {
  if (!data || data.byteLength < 8 || GIT_SNAPSHOT_MAGIC.some((b, i) => data[i] !== b)) return null;
  const metaLen = new DataView(data.buffer, data.byteOffset, data.byteLength).getUint32(4, true);
  if (metaLen > DURABLE_TREE_MAX_META_BYTES || metaLen > data.byteLength - 8) return null;
  let parsed: unknown;
  let metadata: string;
  try {
    metadata = new TextDecoder("utf-8", { fatal: true }).decode(data.subarray(8, 8 + metaLen));
    parsed = JSON.parse(metadata);
  } catch {
    return null;
  }
  // This is a new alpha format: accept only the canonical encoder output. That
  // rejects duplicate keys, alternate key order, and undocumented extensions.
  if (!parsed || typeof parsed !== "object" || JSON.stringify(parsed) !== metadata) return null;
  const obj = parsed as { v?: unknown; dirs?: unknown; files?: unknown; links?: unknown };
  if (
    !hasExactKeys(obj, ["v", "dirs", "files", "links"]) ||
    obj.v !== 1 ||
    !Array.isArray(obj.dirs) ||
    !Array.isArray(obj.files) ||
    !Array.isArray(obj.links)
  )
    return null;
  const rawLinks = obj.links;
  if (
    !Array.isArray(rawLinks) ||
    obj.dirs.length + obj.files.length + rawLinks.length > DURABLE_TREE_MAX_NODES
  ) {
    return null;
  }
  const payload = data.subarray(8 + metaLen);
  if (payload.byteLength > DURABLE_TREE_MAX_BYTES) return null;
  const dirs: DurableTreeDir[] = [];
  const dirPaths = new Set<string>();
  const paths = new Set<string>();
  for (const raw of obj.dirs) {
    if (!raw || typeof raw !== "object") return null;
    const dir = raw as Partial<DurableTreeDir>;
    if (
      !hasExactKeys(dir, ["path", "mode"]) ||
      typeof dir.path !== "string" ||
      !safeTreeRelative(dir.path) ||
      isTransientEnginePath(dir.path) ||
      paths.has(dir.path) ||
      !Number.isInteger(dir.mode) ||
      (dir.mode as number) < 0 ||
      (dir.mode as number) > 0o777
    )
      return null;
    paths.add(dir.path);
    dirPaths.add(dir.path);
    dirs.push(dir as DurableTreeDir);
  }
  const files: DurableTreeFile[] = [];
  let expectedOffset = 0;
  for (const raw of obj.files) {
    if (!raw || typeof raw !== "object") return null;
    const f = raw as Partial<DurableTreeFile>;
    if (
      !hasExactKeys(f, ["path", "mode", "offset", "length"]) ||
      typeof f.path !== "string" ||
      !safeTreeRelative(f.path) ||
      isTransientEnginePath(f.path) ||
      !Number.isInteger(f.mode) ||
      !Number.isInteger(f.offset) ||
      !Number.isInteger(f.length) ||
      (f.mode as number) < 0 ||
      (f.mode as number) > 0o777 ||
      paths.has(f.path as string) ||
      (f.offset as number) !== expectedOffset ||
      (f.length as number) < 0 ||
      (f.offset as number) > payload.byteLength - (f.length as number)
    )
      return null;
    paths.add(f.path as string);
    files.push(f as DurableTreeFile);
    expectedOffset += f.length as number;
  }
  const links: DurableTreeLink[] = [];
  for (const raw of rawLinks) {
    if (!raw || typeof raw !== "object") return null;
    const link = raw as Partial<DurableTreeLink>;
    if (
      !hasExactKeys(link, ["path", "target"]) ||
      typeof link.path !== "string" ||
      !safeTreeRelative(link.path) ||
      isTransientEnginePath(link.path) ||
      paths.has(link.path) ||
      typeof link.target !== "string" ||
      link.target.includes("\0") ||
      new TextEncoder().encode(link.target).byteLength > 4096
    )
      return null;
    paths.add(link.path);
    links.push(link as DurableTreeLink);
  }
  if (expectedOffset !== payload.byteLength) return null;

  const terminalPaths = new Set([
    ...files.map((file) => file.path),
    ...links.map((link) => link.path),
  ]);
  for (const path of paths) {
    let slash = path.lastIndexOf("/");
    while (slash >= 0) {
      const parent = path.slice(0, slash);
      if (terminalPaths.has(parent) || !dirPaths.has(parent)) return null;
      slash = parent.lastIndexOf("/");
    }
  }
  return { dirs, files, links, data: payload };
}

function hasExactKeys(value: object, expected: string[]): boolean {
  const keys = Object.keys(value);
  return keys.length === expected.length && expected.every((key, index) => keys[index] === key);
}

export function restoreDurableTreeBlob(
  decoded: DecodedDurableTree,
  FS: MemfsLike,
  root: string,
): void {
  clearMemfsDir(FS, root);
  ensureMemfsDir(FS, root);
  for (const dir of [...decoded.dirs].sort((a, b) => a.path.length - b.path.length)) {
    ensureMemfsDir(FS, `${root}/${dir.path}`);
  }
  for (const file of decoded.files) {
    const slash = file.path.lastIndexOf("/");
    if (slash >= 0) ensureMemfsDir(FS, `${root}/${file.path.slice(0, slash)}`);
    const abs = `${root}/${file.path}`;
    FS.writeFile(abs, decoded.data.subarray(file.offset, file.offset + file.length));
    FS.chmod?.(abs, file.mode);
  }
  for (const link of decoded.links) {
    if (!FS.symlink) throw new Error("durable tree: MEMFS symlink support unavailable");
    const slash = link.path.lastIndexOf("/");
    if (slash >= 0) ensureMemfsDir(FS, `${root}/${link.path.slice(0, slash)}`);
    FS.symlink(link.target, `${root}/${link.path}`);
  }
  for (const dir of [...decoded.dirs].sort((a, b) => b.path.length - a.path.length)) {
    FS.chmod?.(`${root}/${dir.path}`, dir.mode);
  }
}
