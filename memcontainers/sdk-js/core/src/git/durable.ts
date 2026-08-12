/** Opaque browser Git snapshot storage. Snapshot structure belongs exclusively to Zig. */

export type DurableKind = "blob";

export interface DurableBackend {
  readonly id: string;
  readonly kind?: "blob";
  save(snapshot: Uint8Array): Promise<void>;
  load(): Promise<Uint8Array | null>;
  clear(): Promise<void>;
}

const memoryStores = new Map<string, MemoryDurable>();
let temporaryGeneration = 0;

export function isBlobDurable(value: DurableBackend | null | undefined): value is DurableBackend {
  return !!value;
}

export function durableIdForMount(baseId: string, mountPath: string): string {
  const base = (baseId || "default").trim() || "default";
  const mount = String(mountPath || "").trim().replace(/\\/g, "/");
  const safe = mount.replace(/[^A-Za-z0-9._:@+/-]+/g, "_").replace(/\/+/g, "@");
  return `${base}:${safe || "@"}`;
}

export function clearMemoryDurableRegistry(): void { memoryStores.clear(); }

export function safeDurablePathSegment(id: string): string {
  const segment = String(id || "default").replace(/[^A-Za-z0-9._:@+-]+/g, "_") || "default";
  return segment === "." || segment === ".." ? "default" : segment;
}

export class MemoryDurable implements DurableBackend {
  readonly kind = "blob" as const;
  private snapshot: Uint8Array | null = null;
  constructor(readonly id = "memory") {}
  async save(snapshot: Uint8Array): Promise<void> { this.snapshot = snapshot.slice(); }
  async load(): Promise<Uint8Array | null> { return this.snapshot?.slice() ?? null; }
  async clear(): Promise<void> { this.snapshot = null; }
}

export class OpfsDurable implements DurableBackend {
  readonly kind = "blob" as const;
  private constructor(readonly id: string, private readonly root: FileSystemDirectoryHandle) {}

  static async open(id = "default"): Promise<OpfsDurable | null> {
    const storage = globalThis.navigator?.storage as
      | (StorageManager & { getDirectory?: () => Promise<FileSystemDirectoryHandle> })
      | undefined;
    if (!storage?.getDirectory) return null;
    const opfs = await storage.getDirectory();
    const product = await opfs.getDirectoryHandle("agentos-git", { create: true });
    return new OpfsDurable(id, await product.getDirectoryHandle(safeDurablePathSegment(id), { create: true }));
  }

  async save(snapshot: Uint8Array): Promise<void> {
    const next = await this.root.getFileHandle("snapshot.next", { create: true });
    const writer = await next.createWritable();
    await writer.write(snapshot);
    await writer.close();
    // OPFS has no portable rename. The engine snapshot is self-validating, so a
    // torn replacement is rejected on restore instead of interpreted by JS.
    const current = await this.root.getFileHandle("snapshot.bin", { create: true });
    const out = await current.createWritable();
    await out.write(snapshot);
    await out.close();
    await this.root.removeEntry("snapshot.next");
  }

  async load(): Promise<Uint8Array | null> {
    try {
      return new Uint8Array(await (await (await this.root.getFileHandle("snapshot.bin")).getFile()).arrayBuffer());
    } catch (error) {
      if (isMissing(error)) return null;
      throw error;
    }
  }

  async clear(): Promise<void> {
    try { await this.root.removeEntry("snapshot.bin"); } catch (error) { if (!isMissing(error)) throw error; }
  }
}

export class DiskDurable implements DurableBackend {
  readonly kind = "blob" as const;
  constructor(readonly id: string, private readonly directory: string) {}
  private path(): string { return `${this.directory.replace(/\/$/, "")}/snapshot.bin`; }

  async save(snapshot: Uint8Array): Promise<void> {
    const { mkdir, open, rename, rm, writeFile } = await import("node:fs/promises");
    await mkdir(this.directory, { recursive: true });
    const next = `${this.path()}.next-${typeof process === "undefined" ? 0 : process.pid}-${++temporaryGeneration}`;
    try {
      await writeFile(next, snapshot);
      const file = await open(next, "r");
      try { await file.sync(); } finally { await file.close(); }
      await rename(next, this.path());
      const directory = await open(this.directory, "r");
      try { await directory.sync(); } finally { await directory.close(); }
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
      if (isMissing(error)) return null;
      throw error;
    }
  }

  async clear(): Promise<void> {
    try {
      const { unlink } = await import("node:fs/promises");
      await unlink(this.path());
    } catch (error) {
      if (!isMissing(error)) throw error;
    }
  }
}

export async function openDurable(opts: { id?: string; diskDir?: string }): Promise<DurableBackend> {
  const id = opts.id ?? "default";
  if (opts.diskDir) {
    return new DiskDurable(id, `${opts.diskDir.replace(/\/$/, "")}/${safeDurablePathSegment(id)}`);
  }
  const opfs = await OpfsDurable.open(id);
  if (opfs) return opfs;
  let memory = memoryStores.get(id);
  if (!memory) {
    memory = new MemoryDurable(id);
    memoryStores.set(id, memory);
  }
  return memory;
}

function isMissing(error: unknown): boolean {
  const value = error as { code?: unknown; name?: unknown } | undefined;
  return value?.code === "ENOENT" || value?.name === "NotFoundError";
}
