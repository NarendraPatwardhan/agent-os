import { mkdirSync } from "node:fs";
import { lstat, mkdtemp, readFile, readdir, readlink, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { hostDir } from "./drivers.js";
import type { BuildState } from "./llb.js";
import type { GitSource, LocalEntry, LocalSource, SolvePlatform } from "./solve.js";
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

function concat(chunks: readonly Uint8Array[]): Uint8Array {
  const out = new Uint8Array(chunks.reduce((n, chunk) => n + chunk.length, 0));
  let off = 0;
  for (const chunk of chunks) {
    out.set(chunk, off);
    off += chunk.length;
  }
  return out;
}

function normalizeVmPath(path: string, field: string): string {
  if (!path.startsWith("/")) throw new Error(`llb.git ${field} must be absolute: ${JSON.stringify(path)}`);
  if (path.includes("\0")) throw new Error(`llb.git ${field} contains NUL`);
  const parts: string[] = [];
  for (const part of path.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") throw new Error(`llb.git ${field} must not contain '..': ${JSON.stringify(path)}`);
    parts.push(part);
  }
  return `/${parts.join("/")}`;
}

async function archiveGitSource(repo: string, ref: string, dest: string): Promise<GitSource> {
  const local = await localGitRepo(repo);
  try {
    const commit = (await gitOutput(["-C", local.repo, "rev-parse", `${ref}^{commit}`])).trim();
    if (!/^[0-9a-f]{40}$/.test(commit)) {
      throw new Error(`llb.git resolved invalid commit for ${repo} ${ref}: ${commit}`);
    }
    const prefix = gitArchivePrefix(dest);
    const tar = await gitBytes(["-C", local.repo, "archive", "--format=tar", `--prefix=${prefix}`, commit]);
    const archiveDigest = `sha256:${await sha256hex(tar)}`;
    return { commit, archiveDigest, tar };
  } finally {
    if (local.cleanup) await local.cleanup();
  }
}

async function localGitRepo(repo: string): Promise<{ repo: string; cleanup?: () => Promise<void> }> {
  const stat = await lstat(repo).catch(() => null);
  if (stat?.isDirectory()) return { repo };

  const dir = await mkdtemp(join(tmpdir(), "mc-llb-git-"));
  const clone = join(dir, "repo");
  await gitBytes(["clone", "--quiet", "--no-checkout", repo, clone]);
  return {
    repo: clone,
    cleanup: () => rm(dir, { recursive: true, force: true }),
  };
}

function gitArchivePrefix(dest: string): string {
  const normalized = normalizeVmPath(dest, "destination");
  if (normalized === "/") return "";
  return `${normalized.slice(1)}/`;
}

async function gitOutput(args: string[]): Promise<string> {
  return new TextDecoder().decode(await gitBytes(args));
}

function gitBytes(args: string[]): Promise<Uint8Array> {
  return new Promise((resolve, reject) => {
    const child = spawn("git", args, { stdio: ["ignore", "pipe", "pipe"] });
    const stdout: Uint8Array[] = [];
    const stderr: Uint8Array[] = [];
    child.stdout.on("data", (chunk: Uint8Array) => stdout.push(chunk.slice()));
    child.stderr.on("data", (chunk: Uint8Array) => stderr.push(chunk.slice()));
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new Error(`git ${args.join(" ")} failed (${code}): ${new TextDecoder().decode(concat(stderr))}`));
        return;
      }
      resolve(concat(stdout));
    });
  });
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

export const nodeSolvePlatform: SolvePlatform = {
  localSource: scanLocalSource,
  gitSource: archiveGitSource,
  cacheMounts,
};
