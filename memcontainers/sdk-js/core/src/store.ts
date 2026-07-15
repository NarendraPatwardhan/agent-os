// Content-addressed store for image layers, generic blobs, manifests, and warm snapshots
// (SYSTEMS.md §11). This module is runtime-neutral: browser callers can import the core SDK without
// resolving `node:*`, and the concrete store is selected by the caller or by `defaultStore()`.
import type { ContentStore, ImageManifest } from "./types.js";

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as Uint8Array<ArrayBuffer>));
  let hex = "";
  for (const b of h) hex += b.toString(16).padStart(2, "0");
  return hex;
}

function digestHex(digest: string): string {
  const match = /^sha256:([0-9a-f]{64})$/.exec(digest);
  if (!match) throw new Error(`invalid sha256 digest "${digest}"`);
  return match[1]!;
}

function manifestName(name: string): string {
  if (!/^[A-Za-z0-9._-]+$/.test(name)) throw new Error(`invalid image manifest name "${name}"`);
  return name;
}

function cloneBytes(bytes: Uint8Array): Uint8Array {
  return bytes.slice();
}

function cloneManifest(manifest: ImageManifest): ImageManifest {
  return JSON.parse(JSON.stringify(manifest)) as ImageManifest;
}

async function nodeFs() {
  return import("node:fs/promises");
}

async function nodeJoin(...parts: string[]): Promise<string> {
  const { join } = await import("node:path");
  return join(...parts);
}

async function opfsWrite(
  handle: FileSystemDirectoryHandle,
  name: string,
  bytes: Uint8Array,
): Promise<void> {
  const file = await handle.getFileHandle(name, { create: true });
  const writable = await file.createWritable();
  try {
    await writable.write(bytes);
  } finally {
    await writable.close();
  }
}

async function opfsRead(handle: FileSystemDirectoryHandle, name: string): Promise<Uint8Array> {
  const file = await (await handle.getFileHandle(name)).getFile();
  return new Uint8Array(await file.arrayBuffer());
}

async function opfsMaybeRead(
  handle: FileSystemDirectoryHandle,
  name: string,
): Promise<Uint8Array | null> {
  try {
    return await opfsRead(handle, name);
  } catch (error) {
    if (error instanceof DOMException && error.name === "NotFoundError") return null;
    throw error;
  }
}

/** An in-memory {@link ContentStore}. Useful for browser/server tests and
 *  short-lived solves where the caller owns persistence. */
export class MemoryContentStore implements ContentStore {
  private readonly layers = new Map<string, Uint8Array>();
  private readonly blobs = new Map<string, Uint8Array>();
  private readonly manifests = new Map<string, ImageManifest>();
  private readonly snapshots = new Map<string, Uint8Array>();
  private readonly snapshotObjects = new Map<string, Uint8Array>();

  async layer(digest: string): Promise<Uint8Array> {
    digestHex(digest);
    const layer = this.layers.get(digest);
    if (!layer) throw new Error(`layer not found: ${digest}`);
    return cloneBytes(layer);
  }

  async put(tar: Uint8Array): Promise<string> {
    const digest = `sha256:${await sha256Hex(tar)}`;
    this.layers.set(digest, cloneBytes(tar));
    return digest;
  }

  async blob(digest: string): Promise<Uint8Array> {
    digestHex(digest);
    const blob = this.blobs.get(digest);
    if (!blob) throw new Error(`blob not found: ${digest}`);
    return cloneBytes(blob);
  }

  async putBlob(bytes: Uint8Array): Promise<string> {
    const digest = `sha256:${await sha256Hex(bytes)}`;
    this.blobs.set(digest, cloneBytes(bytes));
    return digest;
  }

  async manifest(name: string): Promise<ImageManifest> {
    name = manifestName(name);
    const manifest = this.manifests.get(name);
    if (!manifest) throw new Error(`manifest not found: ${name}`);
    return cloneManifest(manifest);
  }

  async putManifest(name: string, m: ImageManifest): Promise<void> {
    this.manifests.set(manifestName(name), cloneManifest(m));
  }

  async snapshot(key: string): Promise<Uint8Array | null> {
    const snapshot = this.snapshots.get(manifestName(key));
    return snapshot ? cloneBytes(snapshot) : null;
  }

  async putSnapshot(key: string, snap: Uint8Array): Promise<void> {
    this.snapshots.set(manifestName(key), cloneBytes(snap));
  }

  async snapshotObject(digest: string): Promise<Uint8Array> {
    digestHex(digest);
    const snapshot = this.snapshotObjects.get(digest);
    if (!snapshot) throw new Error(`snapshot not found: ${digest}`);
    return cloneBytes(snapshot);
  }

  async putSnapshotObject(snapshot: Uint8Array): Promise<string> {
    const digest = `sha256:${await sha256Hex(snapshot)}`;
    this.snapshotObjects.set(digest, cloneBytes(snapshot));
    return digest;
  }
}

/** A local-directory {@link ContentStore}: `layers/<hex>.tar` + `manifests/
 *  <name>.json`, content-addressed by sha256. */
export class FsContentStore implements ContentStore {
  constructor(private readonly root: string) {}

  private layersDir(): string {
    return `${this.root}/layers`;
  }
  private blobsDir(): string {
    return `${this.root}/blobs`;
  }
  private manifestsDir(): string {
    return `${this.root}/manifests`;
  }

  async layer(digest: string): Promise<Uint8Array> {
    const hex = digestHex(digest);
    const { readFile } = await nodeFs();
    return new Uint8Array(await readFile(await nodeJoin(this.layersDir(), `${hex}.tar`)));
  }

  async put(tar: Uint8Array): Promise<string> {
    const hex = await sha256Hex(tar);
    const { mkdir, writeFile } = await nodeFs();
    await mkdir(this.layersDir(), { recursive: true });
    await writeFile(await nodeJoin(this.layersDir(), `${hex}.tar`), tar);
    return `sha256:${hex}`;
  }

  async blob(digest: string): Promise<Uint8Array> {
    const hex = digestHex(digest);
    const { readFile } = await nodeFs();
    return new Uint8Array(await readFile(await nodeJoin(this.blobsDir(), hex)));
  }

  async putBlob(bytes: Uint8Array): Promise<string> {
    const hex = await sha256Hex(bytes);
    const { mkdir, writeFile } = await nodeFs();
    await mkdir(this.blobsDir(), { recursive: true });
    await writeFile(await nodeJoin(this.blobsDir(), hex), bytes);
    return `sha256:${hex}`;
  }

  async manifest(name: string): Promise<ImageManifest> {
    name = manifestName(name);
    const { readFile } = await nodeFs();
    const raw = await readFile(await nodeJoin(this.manifestsDir(), `${name}.json`), "utf8");
    return JSON.parse(raw) as ImageManifest;
  }

  async putManifest(name: string, m: ImageManifest): Promise<void> {
    name = manifestName(name);
    const { mkdir, writeFile } = await nodeFs();
    await mkdir(this.manifestsDir(), { recursive: true });
    await writeFile(
      await nodeJoin(this.manifestsDir(), `${name}.json`),
      JSON.stringify(m, null, 2),
    );
  }

  private snapshotsDir(): string {
    return `${this.root}/snapshots`;
  }

  async snapshot(key: string): Promise<Uint8Array | null> {
    try {
      const { readFile } = await nodeFs();
      return new Uint8Array(
        await readFile(await nodeJoin(this.snapshotsDir(), `${manifestName(key)}.snap`)),
      );
    } catch {
      return null; // miss
    }
  }

  async putSnapshot(key: string, snap: Uint8Array): Promise<void> {
    const { mkdir, writeFile } = await nodeFs();
    await mkdir(this.snapshotsDir(), { recursive: true });
    await writeFile(await nodeJoin(this.snapshotsDir(), `${manifestName(key)}.snap`), snap);
  }

  async snapshotObject(digest: string): Promise<Uint8Array> {
    const { readFile } = await nodeFs();
    return new Uint8Array(
      await readFile(await nodeJoin(this.snapshotsDir(), `${digestHex(digest)}.mcsn`)),
    );
  }

  async putSnapshotObject(snapshot: Uint8Array): Promise<string> {
    const digest = `sha256:${await sha256Hex(snapshot)}`;
    const { mkdir, writeFile } = await nodeFs();
    await mkdir(this.snapshotsDir(), { recursive: true });
    await writeFile(await nodeJoin(this.snapshotsDir(), `${digestHex(digest)}.mcsn`), snapshot);
    return digest;
  }
}

/** An Origin Private File System backed {@link ContentStore}. Browser solves use this for persistent
 *  layers/blobs/manifests/snapshots without any `node:*` dependency. */
export class OpfsContentStore implements ContentStore {
  private constructor(private readonly root: FileSystemDirectoryHandle) {}

  static async open(name = "mc-store"): Promise<OpfsContentStore> {
    if (typeof navigator === "undefined" || !navigator.storage?.getDirectory) {
      throw new Error("OPFS is not available in this runtime");
    }
    const opfs = await navigator.storage.getDirectory();
    const root = await opfs.getDirectoryHandle(name, { create: true });
    return new OpfsContentStore(root);
  }

  private dir(name: string): Promise<FileSystemDirectoryHandle> {
    return this.root.getDirectoryHandle(name, { create: true });
  }

  async layer(digest: string): Promise<Uint8Array> {
    const hex = digestHex(digest);
    return opfsRead(await this.dir("layers"), `${hex}.tar`);
  }

  async put(tar: Uint8Array): Promise<string> {
    const digest = `sha256:${await sha256Hex(tar)}`;
    await opfsWrite(await this.dir("layers"), `${digestHex(digest)}.tar`, tar);
    return digest;
  }

  async blob(digest: string): Promise<Uint8Array> {
    return opfsRead(await this.dir("blobs"), digestHex(digest));
  }

  async putBlob(bytes: Uint8Array): Promise<string> {
    const digest = `sha256:${await sha256Hex(bytes)}`;
    await opfsWrite(await this.dir("blobs"), digestHex(digest), bytes);
    return digest;
  }

  async manifest(name: string): Promise<ImageManifest> {
    name = manifestName(name);
    const raw = await opfsRead(await this.dir("manifests"), `${name}.json`);
    return JSON.parse(new TextDecoder().decode(raw)) as ImageManifest;
  }

  async putManifest(name: string, m: ImageManifest): Promise<void> {
    name = manifestName(name);
    await opfsWrite(
      await this.dir("manifests"),
      `${name}.json`,
      new TextEncoder().encode(JSON.stringify(m, null, 2)),
    );
  }

  async snapshot(key: string): Promise<Uint8Array | null> {
    return opfsMaybeRead(await this.dir("snapshots"), `${manifestName(key)}.snap`);
  }

  async putSnapshot(key: string, snap: Uint8Array): Promise<void> {
    await opfsWrite(await this.dir("snapshots"), `${manifestName(key)}.snap`, snap);
  }

  async snapshotObject(digest: string): Promise<Uint8Array> {
    return opfsRead(await this.dir("snapshot-objects"), `${digestHex(digest)}.mcsn`);
  }

  async putSnapshotObject(snapshot: Uint8Array): Promise<string> {
    const digest = `sha256:${await sha256Hex(snapshot)}`;
    await opfsWrite(await this.dir("snapshot-objects"), `${digestHex(digest)}.mcsn`, snapshot);
    return digest;
  }
}

class LazyContentStore implements ContentStore {
  private inner: Promise<ContentStore> | null = null;

  constructor(private readonly open: () => Promise<ContentStore>) {}

  private store(): Promise<ContentStore> {
    if (!this.inner) this.inner = this.open();
    return this.inner;
  }

  async layer(digest: string): Promise<Uint8Array> {
    return (await this.store()).layer(digest);
  }

  async put(tar: Uint8Array): Promise<string> {
    return (await this.store()).put(tar);
  }

  async blob(digest: string): Promise<Uint8Array> {
    return (await this.store()).blob(digest);
  }

  async putBlob(bytes: Uint8Array): Promise<string> {
    return (await this.store()).putBlob(bytes);
  }

  async manifest(name: string): Promise<ImageManifest> {
    return (await this.store()).manifest(name);
  }

  async putManifest(name: string, m: ImageManifest): Promise<void> {
    return (await this.store()).putManifest(name, m);
  }

  async snapshot(key: string): Promise<Uint8Array | null> {
    const store = await this.store();
    return store.snapshot ? store.snapshot(key) : null;
  }

  async putSnapshot(key: string, snap: Uint8Array): Promise<void> {
    const store = await this.store();
    if (!store.putSnapshot) throw new Error("default content store does not support snapshots");
    return store.putSnapshot(key, snap);
  }

  async snapshotObject(digest: string): Promise<Uint8Array> {
    const store = await this.store();
    if (!store.snapshotObject)
      throw new Error("default content store does not support snapshot objects");
    return store.snapshotObject(digest);
  }

  async putSnapshotObject(snapshot: Uint8Array): Promise<string> {
    const store = await this.store();
    if (!store.putSnapshotObject)
      throw new Error("default content store does not support snapshot objects");
    return store.putSnapshotObject(snapshot);
  }
}

function envStoreRoot(): string | undefined {
  return typeof process === "undefined" ? undefined : process.env.MC_STORE;
}

function hasOpfs(): boolean {
  return typeof navigator !== "undefined" && Boolean(navigator.storage?.getDirectory);
}

/** The default content store: `$MC_STORE` on Node/Bun, OPFS in browsers. AgentOS has no single fixed
 *  flavor-store path, so callers may still pass an explicit `store` when they need a named image store. */
export function defaultStore(): ContentStore {
  const root = envStoreRoot();
  if (root) return new FsContentStore(root);
  if (hasOpfs()) return new LazyContentStore(() => OpfsContentStore.open());
  throw new Error(
    "no content store available: set MC_STORE, pass mc.create/llb.commit({ store }), or use a browser with OPFS.",
  );
}
