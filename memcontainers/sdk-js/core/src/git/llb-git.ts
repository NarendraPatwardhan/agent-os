/**
 * llb.git materialization via GitRemoteOrchestrator (GIT.md PR15).
 * Produces the same GitSource shape as system-git archive without shelling out.
 */

import type { GitEngine } from "./engine.js";
import type { GitBridge } from "./bridge.js";
import { GitRemoteOrchestrator, type OrchestratorOptions } from "./remote-orchestrator.js";
import { defaultProcessPackCache, type PackCache } from "./pack-cache.js";

export interface LlbGitMaterializeOptions extends OrchestratorOptions {
  engine: GitEngine;
  url: string;
  ref?: string;
  dest?: string;
  connection?: string;
  /**
   * Pack cache for repeated solves (R70/R73). Product default is process
   * MemoryPackCache; pass `null` to disable. Callers (solve-node) may override
   * with DiskPackCache via MC_GIT_PACK_CACHE.
   */
  packCache?: PackCache | null;
}

export interface LlbGitMaterializeResult {
  ok: boolean;
  commit?: string;
  stderr?: string;
}

/**
 * Clone into the engine worktree using the shared remote stack (no system git).
 */
export async function materializeLlbGit(
  opts: LlbGitMaterializeOptions,
): Promise<LlbGitMaterializeResult> {
  const { engine, url, ref, dest, connection, packCache, ...orchOpts } = opts;
  // Product LLB path (R70): share interactive object/pack cache by default.
  // `null` disables; undefined → process MemoryPackCache (same as host_call).
  const resolvedCache =
    packCache === null ? undefined : (packCache ?? defaultProcessPackCache());
  const orch = new GitRemoteOrchestrator(engine, {
    ...orchOpts,
    packCache: resolvedCache,
  });

  const args: Record<string, unknown> = { url, depth: 1 };
  if (connection) args.connection = connection;
  if (ref) args.ref = ref;
  // Note: `dest` is only an archive path prefix for LLB layers — not a sparse cone.

  const resp = await orch.handle({ op: "clone", args });
  if (!resp.ok) {
    return { ok: false, stderr: resp.stderr ?? "clone failed" };
  }

  if (ref) {
    const co = await engine.run({ op: "checkout", args: { name: ref } });
    if (!co.ok) {
      // try detach to hash from rev-parse after import
      const rp = await engine.run({ op: "rev-parse", args: { rev: ref } });
      if (!rp.ok) {
        return {
          ok: false,
          stderr: co.stderr ?? `checkout ${ref} failed`,
        };
      }
    }
  }

  const rev = await engine.run({
    op: "rev-parse",
    args: { rev: "HEAD" },
  });
  const commit = rev.ok ? rev.stdout?.trim().split(/\s+/)[0] : undefined;

  return {
    ok: true,
    commit: commit && /^[0-9a-f]{40}$/i.test(commit) ? commit : undefined,
  };
}

/** Walk engine MEMFS worktree into a deterministic ustar archive. */
export function worktreeToTar(
  bridge: GitBridge,
  destPrefix: string,
): Uint8Array {
  const prefix = normalizeDestPrefix(destPrefix);
  const files: { name: string; data: Uint8Array; mode: number; dir: boolean }[] =
    [];

  function walk(abs: string, rel: string): void {
    let names: string[];
    try {
      names = bridge.FS.readdir(abs).filter((n) => n !== "." && n !== "..");
    } catch {
      return;
    }
    names.sort((a, b) => a.localeCompare(b));
    for (const name of names) {
      if (name === ".git") continue;
      const childAbs = `${abs}/${name}`;
      const childRel = rel ? `${rel}/${name}` : name;
      let st: { mode: number; size?: number };
      try {
        st = bridge.FS.stat(childAbs);
      } catch {
        continue;
      }
      if (bridge.FS.isDir(st.mode)) {
        files.push({
          name: childRel + "/",
          data: new Uint8Array(0),
          mode: 0o755,
          dir: true,
        });
        walk(childAbs, childRel);
      } else {
        const data = bridge.FS.readFile(childAbs);
        const bytes =
          data instanceof Uint8Array
            ? data
            : new TextEncoder().encode(String(data));
        files.push({ name: childRel, data: bytes, mode: 0o644, dir: false });
      }
    }
  }

  walk(bridge.workRoot, "");

  const entries = files.map((f) => {
    const name = prefix + f.name;
    return tarEntry(name, f.data, f.mode, f.dir);
  });
  const total = entries.reduce((n, e) => n + e.length, 0) + 1024;
  const out = new Uint8Array(total);
  let off = 0;
  for (const e of entries) {
    out.set(e, off);
    off += e.length;
  }
  // two zero blocks
  return out.subarray(0, off + 1024);
}

function normalizeDestPrefix(dest: string): string {
  if (!dest || dest === "/" || dest === ".") return "";
  const p = dest.replace(/^\//, "").replace(/\/?$/, "");
  return p ? p + "/" : "";
}

function tarEntry(
  name: string,
  data: Uint8Array,
  mode: number,
  isDir: boolean,
): Uint8Array {
  const header = new Uint8Array(512);
  const enc = new TextEncoder();
  const nameBytes = enc.encode(name.slice(0, 100));
  header.set(nameBytes, 0);
  writeOctal(header, 100, 8, mode & 0o7777);
  writeOctal(header, 108, 8, 0); // uid
  writeOctal(header, 116, 8, 0); // gid
  writeOctal(header, 124, 12, isDir ? 0 : data.byteLength);
  writeOctal(header, 136, 12, 0); // mtime
  // type
  header[156] = isDir ? 0x35 : 0x30; // '5' or '0'
  // magic
  header.set(enc.encode("ustar\0"), 257);
  header.set(enc.encode("00"), 263);
  // checksum
  for (let i = 148; i < 156; i++) header[i] = 0x20;
  let sum = 0;
  for (let i = 0; i < 512; i++) sum += header[i]!;
  writeOctal(header, 148, 8, sum);

  if (isDir || data.byteLength === 0) return header;
  const pad = (512 - (data.byteLength % 512)) % 512;
  const out = new Uint8Array(512 + data.byteLength + pad);
  out.set(header, 0);
  out.set(data, 512);
  return out;
}

function writeOctal(buf: Uint8Array, off: number, len: number, value: number): void {
  const s = value.toString(8).padStart(len - 1, "0");
  for (let i = 0; i < len - 1; i++) {
    buf[off + i] = s.charCodeAt(i) || 0x30;
  }
  buf[off + len - 1] = 0;
}

async function sha256hex(data: Uint8Array): Promise<string> {
  const h = new Uint8Array(
    await crypto.subtle.digest("SHA-256", data as Uint8Array<ArrayBuffer>),
  );
  let s = "";
  for (const b of h) s += b.toString(16).padStart(2, "0");
  return s;
}

export interface EngineGitSourceOptions extends OrchestratorOptions {
  /** Directory URL of git_engine.mjs/wasm. */
  baseUrl: string;
  /** Pack cache for repeated in-process solves (plumb MemoryPackCache when set). */
  packCache?: PackCache | null;
}

/**
 * SolvePlatform.gitSource implementation using host engine + orchestrator.
 * Falls back is the caller's responsibility (see solve-node).
 * Pass `orchOpts.packCache` (e.g. process MemoryPackCache) so repeated solves
 * dedup upload-pack by public url+wants — credentials never enter the key.
 */
export function createEngineGitSource(
  loadEngine: () => Promise<GitEngine>,
  orchOpts: OrchestratorOptions = {},
): (
  repo: string,
  ref: string,
  dest: string,
) => Promise<{ commit: string; archiveDigest: string; tar: Uint8Array }> {
  return async (repo, ref, dest) => {
    const engine = await loadEngine();
    try {
      const r = await materializeLlbGit({
        engine,
        url: repo,
        ref,
        dest,
        ...orchOpts,
      });
      if (!r.ok || !r.commit) {
        throw new Error(r.stderr ?? "llb.git engine materialize failed");
      }
      const tar = worktreeToTar(engine.bridge, dest);
      const archiveDigest = `sha256:${await sha256hex(tar)}`;
      return { commit: r.commit, archiveDigest, tar };
    } finally {
      await engine.close();
    }
  };
}
