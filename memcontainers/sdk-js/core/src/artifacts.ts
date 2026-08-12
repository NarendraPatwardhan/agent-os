/**
 * Runtime artifacts: resolve kernel / flavor tars / catalog-compiler / git-engine.tar.
 *
 * Order: explicit bytes → env path → $AGENTOS_DIR → cache → optional fetch → fail closed.
 * Git product form is a tar containing the single freestanding Wasm module.
 *
 * Node-only I/O is required lazily so this module can load in the browser (product
 * index re-exports it). Browser callers always pass explicit bytes; resolve* throws
 * if host filesystem resolution is attempted without Node.
 */

function isNode(): boolean {
  return typeof process !== "undefined" && typeof process.versions?.node === "string";
}

/** Node built-ins without static `node:` imports (keeps this module browser-loadable). */
function nodeBuiltin<T = unknown>(id: string): T {
  if (!isNode()) {
    throw new Error(`${id} is only available on Node (artifact resolve needs host FS)`);
  }
  const get = (process as NodeJS.Process & {
    getBuiltinModule?: (id: string) => unknown;
  }).getBuiltinModule;
  if (typeof get !== "function") {
    throw new Error(`process.getBuiltinModule missing; need Node 20.16+ for ${id}`);
  }
  // Accept both "fs" and "node:fs"
  const bare = id.startsWith("node:") ? id.slice("node:".length) : id;
  const mod = get(bare) ?? get(id);
  if (!mod) throw new Error(`builtin ${id} not available`);
  return mod as T;
}

function createHash(algo: string): import("node:crypto").Hash {
  return nodeBuiltin<typeof import("node:crypto")>("crypto").createHash(algo);
}

function existsSync(path: string): boolean {
  return nodeBuiltin<typeof import("node:fs")>("fs").existsSync(path);
}
function mkdirSync(path: string, opts?: { recursive?: boolean }): void {
  nodeBuiltin<typeof import("node:fs")>("fs").mkdirSync(path, opts);
}
function readFileSync(path: string): Buffer;
function readFileSync(path: string, enc: BufferEncoding): string;
function readFileSync(path: string, enc?: BufferEncoding): string | Buffer {
  const fs = nodeBuiltin<typeof import("node:fs")>("fs");
  return enc === undefined ? fs.readFileSync(path) : fs.readFileSync(path, enc);
}
function writeFileSync(path: string, data: string | Uint8Array): void {
  nodeBuiltin<typeof import("node:fs")>("fs").writeFileSync(path, data);
}
function renameSync(from: string, to: string): void {
  nodeBuiltin<typeof import("node:fs")>("fs").renameSync(from, to);
}
function rmSync(path: string, opts?: { recursive?: boolean; force?: boolean }): void {
  nodeBuiltin<typeof import("node:fs")>("fs").rmSync(path, opts);
}
function join(...parts: string[]): string {
  return nodeBuiltin<typeof import("node:path")>("path").join(...parts);
}
function homedir(): string {
  return nodeBuiltin<typeof import("node:os")>("os").homedir();
}

// ── kinds ───────────────────────────────────────────────────────────────────

export type ArtifactKind =
  | "kernel"
  | "catalog-compiler"
  | "git-engine"
  | `image:${string}`;

const FLAVOR_RE = /^(minimal|posix|loom|atlas|paper)$/;

export function imageKind(flavor: string): ArtifactKind {
  const f = flavor.replace(/\.tar$/, "");
  if (!FLAVOR_RE.test(f)) {
    throw new Error(
      `unknown image flavor ${JSON.stringify(flavor)} (expected minimal|posix|loom|atlas|paper)`,
    );
  }
  return `image:${f}`;
}

function assetFileName(kind: ArtifactKind): string {
  if (kind === "kernel") return "kernel.wasm";
  if (kind === "catalog-compiler") return "catalog-compiler.wasm";
  if (kind === "git-engine") return "git-engine.tar";
  if (kind.startsWith("image:")) return `${kind.slice("image:".length)}.tar`;
  throw new Error(`unknown artifact kind ${kind}`);
}

function envPathFor(kind: ArtifactKind): string | undefined {
  if (kind === "kernel") return env("MC_KERNEL_WASM");
  if (kind === "catalog-compiler") return env("MC_CATALOG_COMPILER_WASM");
  if (kind === "git-engine") return env("MC_GIT_ENGINE_TAR");
  if (kind.startsWith("image:")) {
    const flavor = kind.slice("image:".length);
    const base = env("MC_BASE_IMAGE");
    if (base && (base.endsWith(`${flavor}.tar`) || base.endsWith(`/${flavor}.tar`))) return base;
    if (base && flavor === defaultFlavorFromEnv(base)) return base;
    return undefined;
  }
  return undefined;
}

function defaultFlavorFromEnv(basePath: string): string | undefined {
  const m = basePath.match(/(minimal|posix|loom|atlas|paper)\.tar$/);
  return m?.[1];
}

function env(name: string): string | undefined {
  if (typeof process === "undefined") return undefined;
  const v = process.env[name];
  return v && v.trim() ? v.trim() : undefined;
}

function fetchEnabled(): boolean {
  const v = env("MC_ARTIFACT_FETCH");
  return v === "1" || v === "true";
}

export function artifactCacheRoot(): string {
  const explicit = env("MC_ARTIFACT_CACHE");
  if (explicit) return explicit;
  // Bazel/hermetic tests
  const testTmp = env("TEST_TMPDIR");
  if (testTmp) return join(testTmp, "agentos-artifacts");
  const xdg = env("XDG_CACHE_HOME");
  if (xdg) return join(xdg, "agentos", "artifacts");
  return join(homedir(), ".cache", "agentos", "artifacts");
}

function installRoots(): string[] {
  const roots: string[] = [];
  const a = env("AGENTOS_DIR") || env("MC_ARTIFACT_HOME");
  if (a) roots.push(a);
  return roots;
}

export function sha256Hex(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

function readFileBytes(path: string): Uint8Array {
  return new Uint8Array(readFileSync(path));
}

function ensureDir(path: string): void {
  mkdirSync(path, { recursive: true });
}

const inflight = new Map<string, Promise<Uint8Array>>();

export type ResolveOptions = {
  bytes?: Uint8Array;
};

/** Resolve a single-file runtime artifact to bytes. */
export async function resolveArtifact(
  kind: ArtifactKind,
  opts: ResolveOptions = {},
): Promise<Uint8Array> {
  if (opts.bytes) return opts.bytes.slice();

  const key = `resolve:${kind}`;
  const hit = inflight.get(key);
  if (hit) return (await hit).slice();

  const p = doResolve(kind).finally(() => inflight.delete(key));
  inflight.set(key, p);
  return (await p).slice();
}

async function doResolve(kind: ArtifactKind): Promise<Uint8Array> {
  const tried: string[] = [];
  const name = assetFileName(kind);

  const ep = envPathFor(kind);
  if (ep) {
    tried.push(`env ${envNameFor(kind)}=${ep}`);
    if (existsSync(ep)) return readFileBytes(ep);
    const runfilesRoot = env("RUNFILES_DIR");
    if (runfilesRoot && !isAbsolute(ep)) {
      const runfilesPath = join(runfilesRoot, ep);
      tried.push(`runfiles ${runfilesPath}`);
      if (existsSync(runfilesPath)) return readFileBytes(runfilesPath);
    }
    tried.push(`(missing file)`);
  } else {
    tried.push(`env ${envNameFor(kind)} unset`);
  }

  for (const root of installRoots()) {
    const path = join(root, name);
    tried.push(`install ${path}`);
    if (existsSync(path)) return readFileBytes(path);
  }
  if (installRoots().length === 0) tried.push("AGENTOS_DIR / MC_ARTIFACT_HOME unset");

  const cacheRoot = artifactCacheRoot();
  const version = env("MC_ARTIFACT_VERSION") || "local";
  const keyFile = join(cacheRoot, "keys", `${kind.replace(":", "_")}-${version}`);
  tried.push(`cache key ${keyFile}`);
  if (existsSync(keyFile)) {
    const digest = readFileSync(keyFile, "utf8").trim();
    const blob = join(cacheRoot, "blobs", digest);
    if (existsSync(blob)) return readFileBytes(blob);
  }

  if (fetchEnabled()) {
    tried.push("fetch enabled");
    const bytes = await fetchArtifact(name);
    await publishBlob(kind, bytes, version);
    return bytes;
  }
  tried.push("fetch off (set MC_ARTIFACT_FETCH=1 to allow network)");

  throw new Error(
    `${name} not available (${kind}).\n` +
      `Looked at:\n  - ${tried.join("\n  - ")}\n` +
      `Fix: pass explicit bytes, set ${envNameFor(kind)}, set AGENTOS_DIR, ` +
      `or MC_ARTIFACT_FETCH=1 with MC_ARTIFACT_VERSION / MC_ARTIFACT_SOURCE.`,
  );
}

function isAbsolute(path: string): boolean {
  return nodeBuiltin<typeof import("node:path")>("path").isAbsolute(path);
}

function envNameFor(kind: ArtifactKind): string {
  if (kind === "kernel") return "MC_KERNEL_WASM";
  if (kind === "catalog-compiler") return "MC_CATALOG_COMPILER_WASM";
  if (kind === "git-engine") return "MC_GIT_ENGINE_TAR";
  if (kind.startsWith("image:")) return "MC_BASE_IMAGE (or AGENTOS_DIR/<flavor>.tar)";
  return "MC_ARTIFACT";
}

async function publishBlob(kind: ArtifactKind, bytes: Uint8Array, version: string): Promise<string> {
  const digest = sha256Hex(bytes);
  const cacheRoot = artifactCacheRoot();
  const blobDir = join(cacheRoot, "blobs");
  const keyDir = join(cacheRoot, "keys");
  ensureDir(blobDir);
  ensureDir(keyDir);
  const blobPath = join(blobDir, digest);
  if (!existsSync(blobPath)) {
    const tmp = join(blobDir, `.${digest}.${process.pid}.tmp`);
    writeFileSync(tmp, bytes);
    try {
      renameSync(tmp, blobPath);
    } catch (e) {
      const err = e as NodeJS.ErrnoException;
      if (err?.code !== "EXDEV") throw e;
      writeFileSync(blobPath, bytes);
      try {
        rmSync(tmp, { force: true });
      } catch {
        /* ignore */
      }
    }
  }
  writeFileSync(join(keyDir, `${kind.replace(":", "_")}-${version}`), `${digest}\n`);
  return digest;
}

async function fetchArtifact(name: string): Promise<Uint8Array> {
  const version = env("MC_ARTIFACT_VERSION");
  const source = env("MC_ARTIFACT_SOURCE");
  let base: string;
  if (source) {
    base = source.endsWith("/") ? source : source + "/";
  } else if (version) {
    base = `https://github.com/NarendraPatwardhan/agent-os/releases/download/${version}/`;
  } else {
    base = `https://github.com/NarendraPatwardhan/agent-os/releases/latest/download/`;
  }
  const url = new URL(name, base).href;
  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(`fetch ${url} failed: HTTP ${res.status} ${res.statusText}`);
  }
  const bytes = new Uint8Array(await res.arrayBuffer());

  try {
    const sumsUrl = new URL("SHA256SUMS", base).href;
    const sumsRes = await fetch(sumsUrl);
    if (sumsRes.ok) {
      const text = await sumsRes.text();
      const expect = parseSha256Sums(text).get(name);
      if (expect) {
        const got = sha256Hex(bytes);
        if (got !== expect) {
          throw new Error(
            `SHA256 mismatch for ${name}: got ${got}, expected ${expect} (from ${sumsUrl})`,
          );
        }
      }
    }
  } catch (e) {
    if (e instanceof Error && e.message.includes("SHA256 mismatch")) throw e;
  }
  return bytes;
}

function parseSha256Sums(text: string): Map<string, string> {
  const m = new Map<string, string>();
  for (const line of text.split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;
    const match = t.match(/^([0-9a-fA-F]{64})\s+\*?(\S+)\s*$/);
    if (match) m.set(match[2]!, match[1]!.toLowerCase());
  }
  return m;
}

export async function resolveKernel(bytes?: Uint8Array): Promise<Uint8Array> {
  return resolveArtifact("kernel", { bytes });
}

export async function resolveCatalogCompiler(bytes?: Uint8Array): Promise<Uint8Array> {
  return resolveArtifact("catalog-compiler", { bytes });
}

export async function resolveImageTar(flavor: string, bytes?: Uint8Array): Promise<Uint8Array> {
  return resolveArtifact(imageKind(flavor), { bytes });
}

export async function resolveGitEngineTar(bytes?: Uint8Array): Promise<Uint8Array> {
  return resolveArtifact("git-engine", { bytes });
}

/** Resolve and extract the sole browser runtime from git-engine.tar in memory. */
export async function resolveGitEngineWasm(engineTar?: Uint8Array): Promise<Uint8Array> {
  return readTarFile(await resolveGitEngineTar(engineTar), "git_engine.wasm");
}

function readTarFile(tar: Uint8Array, wanted: string): Uint8Array {
  const decoder = new TextDecoder();
  let offset = 0;
  while (offset + 512 <= tar.byteLength) {
    const header = tar.subarray(offset, offset + 512);
    if (header.every((byte) => byte === 0)) break;
    const name = decoder.decode(header.subarray(0, 100)).replace(/\0.*$/, "");
    const sizeText = decoder.decode(header.subarray(124, 136)).replace(/\0.*$/, "").trim();
    if (!/^[0-7]*$/.test(sizeText)) throw new Error("invalid git-engine.tar size field");
    const size = sizeText ? Number.parseInt(sizeText, 8) : 0;
    const start = offset + 512;
    const end = start + size;
    if (!Number.isSafeInteger(size) || end > tar.byteLength) throw new Error("truncated git-engine.tar");
    if (name === wanted) return tar.slice(start, end);
    offset = start + Math.ceil(size / 512) * 512;
  }
  throw new Error(`git-engine.tar missing ${wanted}`);
}

export async function seedArtifactCacheFromDir(
  installDir: string,
  version = "local",
): Promise<void> {
  const names = [
    "kernel.wasm",
    "catalog-compiler.wasm",
    "git-engine.tar",
    "minimal.tar",
    "posix.tar",
    "loom.tar",
    "atlas.tar",
    "paper.tar",
  ] as const;
  for (const name of names) {
    const path = join(installDir, name);
    if (!existsSync(path)) continue;
    const bytes = readFileBytes(path);
    let kind: ArtifactKind;
    if (name === "kernel.wasm") kind = "kernel";
    else if (name === "catalog-compiler.wasm") kind = "catalog-compiler";
    else if (name === "git-engine.tar") kind = "git-engine";
    else kind = imageKind(name.replace(/\.tar$/, ""));
    await publishBlob(kind, bytes, version);
  }
}

/** Kernel.wasm (env → AGENTOS_DIR → cache → optional fetch). */
export async function defaultKernel(): Promise<Uint8Array> {
  return resolveKernel();
}

/** Default image tar: MC_BASE_IMAGE flavor, else posix under install/cache. */
export async function defaultImage(): Promise<Uint8Array> {
  const path = typeof process !== "undefined" ? process.env.MC_BASE_IMAGE?.trim() : undefined;
  if (path) {
    const m = path.match(/(minimal|posix|loom|atlas|paper)\.tar$/);
    if (m) return resolveImageTar(m[1]!);
    if (existsSync(path)) return readFileBytes(path);
    throw new Error(`MC_BASE_IMAGE path not found: ${path}`);
  }
  return resolveImageTar("posix");
}

/** Catalog-compiler.wasm via resolver. */
export async function defaultCatalogCompilerBytes(): Promise<Uint8Array> {
  return resolveCatalogCompiler();
}
