/**
 * llb.git materialization — build-time source via the host remote stack.
 *
 * Clones through the engine-owned remote state machine and walks its typed
 * mount face into a deterministic
 * ustar archive. No shell-out.
 */

import type { GitEngine } from "./engine.js";
import { GitRemoteEffectPump, type RemoteEffectPumpOptions } from "./remote-effect-pump.js";

// ── Materialize ─────────────────────────────────────────────────────────────

export interface LlbGitMaterializeOptions extends RemoteEffectPumpOptions {
  engine: GitEngine;
  url: string;
  ref?: string;
  dest?: string;
  connection?: string;
}

export interface LlbGitMaterializeResult {
  ok: boolean;
  commit?: string;
  stderr?: string;
}

/**
 * Clone into the engine worktree using its remote state machine.
 */
export async function materializeLlbGit(
  opts: LlbGitMaterializeOptions,
): Promise<LlbGitMaterializeResult> {
  const { engine, url, ref, dest, connection, ...effectOptions } = opts;

  const pump = new GitRemoteEffectPump(engine, {
    ...effectOptions,
  });

  const args: Record<string, unknown> = { url, depth: 1 };
  if (connection) args.connection = connection;
  if (ref) args.ref = ref;
  // `dest` is only an archive path prefix for LLB layers.

  const resp = await pump.handle({ op: "clone", args });
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

/** Walk the engine's typed worktree face into a deterministic ustar archive. */
export async function worktreeToTar(
  engine: GitEngine,
  destPrefix: string,
): Promise<Uint8Array> {
  const prefix = normalizeDestPrefix(destPrefix);
  const files: { name: string; data: Uint8Array; mode: number; dir: boolean }[] =
    [];

  async function walk(rel: string): Promise<void> {
    const listing = await engine.fileReadDir(rel);
    for (const entry of [...listing.entries].sort((a, b) => a.name.localeCompare(b.name))) {
      const name = entry.name;
      if (name === ".git") continue;
      const childRel = rel ? `${rel}/${name}` : name;
      if ((entry.mode & 0o170000) === 0o040000) {
        files.push({
          name: childRel + "/",
          data: new Uint8Array(0),
          mode: entry.mode & 0o777,
          dir: true,
        });
        await walk(childRel);
      } else {
        files.push({
          name: childRel,
          data: await engine.fileRead(childRel),
          mode: entry.mode & 0o777,
          dir: false,
        });
      }
    }
  }

  await walk("");

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

export interface EngineGitSourceOptions extends RemoteEffectPumpOptions {
  /** Optional host-owned connection binding used for every source request. */
  connection?: string;
}

/**
 * SolvePlatform.gitSource implementation using the engine and HTTP effect pump.
 */
export function createEngineGitSource(
  loadEngine: () => Promise<GitEngine>,
  effectOptions: EngineGitSourceOptions = {},
): (
  repo: string,
  ref: string,
  dest: string,
) => Promise<{ commit: string; archiveDigest: string; tar: Uint8Array }> {
  return async (repo, ref, dest) => {
    const { connection, ...pumpOptions } = effectOptions;
    const engine = await loadEngine();
    try {
      const r = await materializeLlbGit({
        engine,
        url: repo,
        ref,
        dest,
        connection,
        ...pumpOptions,
      });
      if (!r.ok || !r.commit) {
        throw new Error(r.stderr ?? "llb.git engine materialize failed");
      }
      const tar = await worktreeToTar(engine, dest);
      const archiveDigest = `sha256:${await sha256hex(tar)}`;
      return { commit: r.commit, archiveDigest, tar };
    } finally {
      await engine.close();
    }
  };
}
