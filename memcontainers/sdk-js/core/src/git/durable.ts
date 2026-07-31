/**
 * Durable backends for host git engine (GIT.md PR8a OPFS / PR8b server disk).
 * Engine object DB lives under worktree .git; durability = persist that tree
 * across reload (browser OPFS) or keep Port root on disk (server).
 */

export interface DurableBackend {
  /** Absolute or logical key for the worktree store. */
  readonly id: string;
  /** Persist engine worktree snapshot (opaque bytes or file map). */
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
