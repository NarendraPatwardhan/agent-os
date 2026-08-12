import { mkdirSync } from "node:fs";
import { lstat, readFile, readdir, readlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { hostDir } from "./drivers.js";
import type { BuildState } from "./llb.js";
import type { LocalEntry, LocalSource, SolvePlatform } from "./solve.js";
import type { MountSpec } from "./types.js";

const te = new TextEncoder();

async function sha256hex(data: Uint8Array): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", data as Uint8Array<ArrayBuffer>));
  let s = "";
  for (const b of h) s += b.toString(16).padStart(2, "0");
  return s;
}

function cat(...parts: (string | Uint8Array)[]): Uint8Array {
  const bytes = parts.map((p) => (typeof p === "string" ? te.encode(p) : p));
  const len = bytes.reduce((n, b) => n + b.length + 1, 0);
  const out = new Uint8Array(len);
  let off = 0;
  for (const b of bytes) {
    out.set(b, off);
    off += b.length;
    out[off++] = 0;
  }
  return out;
}


async function scanLocalSource(root: string): Promise<LocalSource> {
  const stat = await lstat(root);
  if (!stat.isDirectory()) throw new Error(`llb.local source must be a directory: ${root}`);
  const entries: LocalEntry[] = [{ kind: "dir", rel: "", mode: localMode(stat.mode) }];

  async function walk(abs: string, rel: string): Promise<void> {
    const names = (await readdir(abs)).sort((a, b) => a.localeCompare(b));
    for (const name of names) {
      if (name.includes("\0") || name === "." || name === "..") {
        throw new Error(`llb.local source contains invalid entry name: ${JSON.stringify(name)}`);
      }
      const childAbs = join(abs, name);
      const childRel = rel ? `${rel}/${name}` : name;
      const childStat = await lstat(childAbs);
      if (childStat.isDirectory()) {
        entries.push({ kind: "dir", rel: childRel, mode: localMode(childStat.mode) });
        await walk(childAbs, childRel);
      } else if (childStat.isFile()) {
        const bytes = new Uint8Array(await readFile(childAbs));
        entries.push({
          kind: "file",
          rel: childRel,
          bytes,
          digest: await sha256hex(bytes),
          mode: localMode(childStat.mode),
        });
      } else if (childStat.isSymbolicLink()) {
        entries.push({ kind: "symlink", rel: childRel, target: await readlink(childAbs) });
      } else {
        throw new Error(`llb.local source contains unsupported file type: ${childAbs}`);
      }
    }
  }

  await walk(root, "");
  const digest = await sha256hex(
    cat(
      "local-source",
      ...entries.map((entry) => {
        switch (entry.kind) {
          case "dir":
            return `dir:${entry.rel}:${entry.mode ?? ""}`;
          case "file":
            return `file:${entry.rel}:${entry.digest}:${entry.mode ?? ""}`;
          case "symlink":
            return `symlink:${entry.rel}:${entry.target}`;
        }
      }),
    ),
  );
  return { digest, entries };
}

function localMode(mode: number): number {
  return mode & 0o7777;
}

async function cacheMounts(mounts: readonly BuildState[]): Promise<MountSpec[]> {
  const root = process.env.MC_BUILD_CACHE ?? join(tmpdir(), "mc-build-cache");
  const specs: MountSpec[] = [];
  for (const m of mounts) {
    if (m.node.op !== "cache") continue;
    const path = m.node.path;
    const dir = join(root, path.replace(/[^A-Za-z0-9._-]/g, "_"));
    mkdirSync(dir, { recursive: true });
    specs.push({ path, driver: hostDir({ root: dir }) });
  }
  return specs;
}

/**
 * Default Node platform: **host git engine** for `llb.git` (SYSTEMS.md §11b).
 * All Git semantics run through the pinned Gitz engine.
 */
export const nodeSolvePlatform: SolvePlatform = {
  localSource: scanLocalSource,
  gitSource: async (repo, ref, dest) => {
    const platform = await nodeSolvePlatformWithEngine({
      allowOrigins: (process.env.MC_GIT_ALLOW_ORIGINS ?? "")
        .split(",")
        .map((origin) => origin.trim())
        .filter(Boolean),
    });
    return platform.gitSource(repo, ref, dest);
  },
  cacheMounts,
};

/**
 * Node solve platform with engine-owned Git remote semantics.
 * Engine tar is resolved via artifacts (`MC_GIT_ENGINE_TAR` / AGENTOS_DIR / cache).
 */
export async function nodeSolvePlatformWithEngine(opts: {
  /** Optional git-engine.tar bytes; otherwise resolved via artifacts. */
  engine?: Uint8Array;
  connections?: import("./types.js").ConnectionDefinition[];
  /** Required for bare remote URLs; empty remains fail-closed. */
  allowOrigins?: string[];
  /** Optional connection binding applied to every llb.git source. */
  connection?: string;
  /** Generic HTTP executor for engine effects. */
  fetch?: typeof globalThis.fetch;
}): Promise<SolvePlatform> {
  const { GitEngine } = await import("./git/engine.js");
  const { createEngineGitSource } = await import("./git/llb-git.js");
  const gitSource = createEngineGitSource(
    () => GitEngine.load({ engine: opts.engine }),
    {
      connections: opts.connections,
      allowOrigins: opts.allowOrigins,
      connection: opts.connection,
      fetch: opts.fetch,
    },
  );
  return {
    localSource: scanLocalSource,
    gitSource,
    cacheMounts,
  };
}

/** Same as {@link nodeSolvePlatform} (engine-first). Kept for call sites. */
export async function defaultNodeSolvePlatform(): Promise<SolvePlatform> {
  return nodeSolvePlatform;
}
