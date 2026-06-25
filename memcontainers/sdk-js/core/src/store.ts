// Content-addressed store for image layers + manifests (SYSTEMS.md §11). A local-directory
// implementation: committed `.tar` layers keyed by their sha256 digest (`layers/<hex>.tar`) and
// image/flavor manifests by name (`manifests/<name>.json`). A registry/persistfs-backed store is a
// later addition.

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
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

/** A local-directory {@link ContentStore}: `layers/<hex>.tar` + `manifests/
 *  <name>.json`, content-addressed by sha256. */
export class FsContentStore implements ContentStore {
  constructor(private readonly root: string) {}

  private layersDir(): string {
    return join(this.root, "layers");
  }
  private manifestsDir(): string {
    return join(this.root, "manifests");
  }

  async layer(digest: string): Promise<Uint8Array> {
    const hex = digestHex(digest);
    return new Uint8Array(await readFile(join(this.layersDir(), `${hex}.tar`)));
  }

  async put(tar: Uint8Array): Promise<string> {
    const hex = await sha256Hex(tar);
    await mkdir(this.layersDir(), { recursive: true });
    await writeFile(join(this.layersDir(), `${hex}.tar`), tar);
    return `sha256:${hex}`;
  }

  async manifest(name: string): Promise<ImageManifest> {
    name = manifestName(name);
    const raw = await readFile(join(this.manifestsDir(), `${name}.json`), "utf8");
    return JSON.parse(raw) as ImageManifest;
  }

  async putManifest(name: string, m: ImageManifest): Promise<void> {
    name = manifestName(name);
    await mkdir(this.manifestsDir(), { recursive: true });
    await writeFile(join(this.manifestsDir(), `${name}.json`), JSON.stringify(m, null, 2));
  }

  private snapshotsDir(): string {
    return join(this.root, "snapshots");
  }

  async snapshot(key: string): Promise<Uint8Array | null> {
    try {
      return new Uint8Array(await readFile(join(this.snapshotsDir(), `${manifestName(key)}.snap`)));
    } catch {
      return null; // miss
    }
  }

  async putSnapshot(key: string, snap: Uint8Array): Promise<void> {
    await mkdir(this.snapshotsDir(), { recursive: true });
    await writeFile(join(this.snapshotsDir(), `${manifestName(key)}.snap`), snap);
  }
}

/** The default content store: the directory at `$MC_STORE` (with `layers/`, `manifests/`,
 *  `snapshots/`). agent-os has no single fixed flavor-store path (the flavors are bazel artifacts),
 *  so either set `MC_STORE` or pass `mc.create({ store })`. */
export function defaultStore(): ContentStore {
  const root = process.env.MC_STORE;
  if (!root) {
    throw new Error(
      "no content store available: set MC_STORE to a store directory (with layers/ + manifests/), " +
        "or pass mc.create({ store }). agent-os has no fixed default flavor-store path.",
    );
  }
  return new FsContentStore(root);
}
