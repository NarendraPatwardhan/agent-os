/**
 * llb.git materialization — build-time source via the host remote stack.
 *
 * Clones through {@link GitRemoteOrchestrator} (same smart-HTTP + pack cache
 * as interactive remotes) and walks the engine worktree into a deterministic
 * ustar archive. No system git, no shell-out.
 */

import type { GitEngine } from "./engine.js";
import type { GitBridge } from "./bridge.js";
import { GitRemoteOrchestrator, type OrchestratorOptions } from "./remote-orchestrator.js";
import { defaultProcessPackCache, type PackCache } from "./pack-cache.js";

// ── Materialize ─────────────────────────────────────────────────────────────

export interface LlbGitMaterializeOptions extends OrchestratorOptions {
  engine: GitEngine;
  url: string;
  ref?: string;
  dest?: string;
  connection?: string;
  /**
   * Pack cache for repeated solves. Product default is process
   * {@link defaultProcessPackCache} (Memory, or Disk when `MC_GIT_PACK_CACHE`
   * is set on Node). Pass `null` to disable.
   */
  packCache?: PackCache | null;
}

export interface LlbGitMaterializeResult {
  ok: boolean;
  commit?: string;
  stderr?: string;
}

/**
 * Local absolute (or file://) git directories for monorepo / fixture sources.
 * Remotes still require http(s) through the orchestrator.
 * Browser / non-Node hosts never treat a url as a local filesystem repo.
 */
export function localGitRepoPath(url: string): string | null {
  if (typeof url !== "string" || !url) return null;
  // node:fs is Node-only — keep this branch out of the browser module graph.
  if (typeof process === "undefined" || typeof process.versions?.node !== "string") {
    return null;
  }
  let path = url;
  if (url.startsWith("file://")) {
    try {
      path = decodeURIComponent(new URL(url).pathname);
    } catch {
      return null;
    }
  }
  // Absolute host path only (no ambient relative CWD lookups).
  if (!path.startsWith("/")) return null;
  try {
    const get = (process as NodeJS.Process & {
      getBuiltinModule?: (id: string) => typeof import("node:fs") | undefined;
    }).getBuiltinModule;
    const fs = get?.("fs");
    if (!fs || !fs.existsSync(path) || !fs.statSync(path).isDirectory()) return null;
  } catch {
    return null;
  }
  return path;
}

/**
 * Clone into the engine worktree using the shared remote stack (no system git).
 * Local absolute directories open as a host durable root (no dial).
 */
export async function materializeLlbGit(
  opts: LlbGitMaterializeOptions,
): Promise<LlbGitMaterializeResult> {
  const { engine, url, ref, dest, connection, packCache, ...orchOpts } = opts;
  // Share interactive CA pack cache by default.
  // `null` disables; undefined → process default (Memory, or Disk via MC_GIT_PACK_CACHE).
  const resolvedCache =
    packCache === null ? undefined : (packCache ?? defaultProcessPackCache());

  const local = localGitRepoPath(url);
  if (!local) {
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
  }
  // Local: engine was loaded with durableDir at the host path by createEngineGitSource.
  // Remote: clone.apply already populated the worktree above.

  if (ref) {
    const co = await engine.run({ op: "checkout", args: { name: ref } });
    if (!co.ok) {
      // try detach to hash from rev-parse after import
      const rp = await engine.run({ op: "rev-parse", args: { rev: ref } });
      if (!rp.ok) {
        return {
          ok: false,
          stderr: co.stderr ?? rp.stderr ?? `checkout ${ref} failed`,
        };
      }
    }
  }

  const rev = await engine.run({
    op: "rev-parse",
    args: { rev: "HEAD" },
  });
  if (!rev.ok) {
    return {
      ok: false,
      stderr: rev.stderr ?? "rev-parse HEAD failed after llb.git materialize",
    };
  }
  const commit = rev.stdout?.trim().split(/\s+/)[0];
  if (!commit || !/^[0-9a-f]{40}$/i.test(commit)) {
    return {
      ok: false,
      stderr: `llb.git materialize produced invalid HEAD: ${JSON.stringify(rev.stdout)}`,
    };
  }

  return {
    ok: true,
    commit,
  };
}

// ── Worktree → tar ──────────────────────────────────────────────────────────

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

// ── SolvePlatform.gitSource ─────────────────────────────────────────────────

export interface EngineGitSourceOptions extends OrchestratorOptions {
  /**
   * Pack cache for repeated in-process solves. Product default is
   * {@link defaultProcessPackCache} (Memory or Disk via `MC_GIT_PACK_CACHE`).
   */
  packCache?: PackCache | null;
}

/**
 * SolvePlatform.gitSource implementation using host engine + orchestrator.
 * Fallback is the caller's responsibility (see solve-node).
 * Pass `orchOpts.packCache` (or rely on process default) so repeated solves
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
    const local = localGitRepoPath(repo);
    // Local absolute git directories (monorepo / fixture): archive with host `git`
    // without dialing. Product remotes stay http(s) + engine orch only.
    if (local) {
      return archiveLocalGitRepo(local, ref, dest);
    }
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

/** Host-local path materialize for llb.git (absolute dir only; no network). */
async function archiveLocalGitRepo(
  repo: string,
  ref: string,
  dest: string,
): Promise<{ commit: string; archiveDigest: string; tar: Uint8Array }> {
  const { spawn } = await import("node:child_process");
  const run = (args: string[]): Promise<Uint8Array> =>
    new Promise((resolve, reject) => {
      const child = spawn("git", args, { stdio: ["ignore", "pipe", "pipe"] });
      const out: Uint8Array[] = [];
      const err: Uint8Array[] = [];
      child.stdout.on("data", (c: Uint8Array) => out.push(c.slice()));
      child.stderr.on("data", (c: Uint8Array) => err.push(c.slice()));
      child.on("error", reject);
      child.on("close", (code) => {
        if (code === 0) {
          const n = out.reduce((a, b) => a + b.length, 0);
          const buf = new Uint8Array(n);
          let o = 0;
          for (const c of out) {
            buf.set(c, o);
            o += c.length;
          }
          resolve(buf);
        } else {
          reject(
            new Error(
              `git ${args.join(" ")} failed: ${new TextDecoder().decode(
                err.reduce((a, b) => {
                  const n = new Uint8Array(a.length + b.length);
                  n.set(a);
                  n.set(b, a.length);
                  return n;
                }, new Uint8Array(0)),
              )}`,
            ),
          );
        }
      });
    });
  const commit = new TextDecoder()
    .decode(await run(["-C", repo, "rev-parse", `${ref}^{commit}`]))
    .trim();
  if (!/^[0-9a-f]{40}$/i.test(commit)) {
    throw new Error(`llb.git local rev-parse invalid: ${JSON.stringify(commit)}`);
  }
  const prefix =
    !dest || dest === "/"
      ? ""
      : `${dest.replace(/^\/+/, "").replace(/\/+$/, "")}/`;
  const tar = await run([
    "-C",
    repo,
    "archive",
    "--format=tar",
    `--prefix=${prefix}`,
    commit,
  ]);
  return {
    commit,
    archiveDigest: `sha256:${await sha256hex(tar)}`,
    tar,
  };
}
