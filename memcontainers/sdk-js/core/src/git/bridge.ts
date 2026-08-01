/**
 * Emscripten createGitEngineModule bridge over ge_* (GIT.md PR2/PR3).
 * Worktree lives in module MEMFS; gitfs projects it into the guest VFS.
 */

import type { GitRequest, GitResponse } from "./types.js";

export const DEFAULT_WORK_ROOT = "/work";

export type EmscriptenGitModule = {
  UTF8ToString(ptr: number): string;
  stringToUTF8(s: string, ptr: number, max: number): void;
  lengthBytesUTF8(s: string): number;
  _malloc(n: number): number;
  _free(ptr: number): void;
  getValue(ptr: number, type: string): number;
  setValue(ptr: number, value: number, type: string): void;
  HEAPU8: Uint8Array;
  FS: EmscriptenFS;
  _ge_open(rootPtr: number): number;
  _ge_close(eng: number): void;
  _ge_run_json(eng: number, reqPtr: number): number;
  _ge_import_pack(eng: number, ptr: number, len: number, final: number): number;
  _ge_pack_build(
    eng: number,
    oidsJsonPtr: number,
    outPtrPtr: number,
    outLenPtr: number,
  ): number;
  _ge_free(ptr: number): void;
  _ge_version(): number;
  _ge_last_error(eng: number): number;
};

export type EmscriptenFS = {
  mkdir(path: string): void;
  mkdirTree?(path: string): void;
  readdir(path: string): string[];
  stat(path: string): { mode: number; size?: number };
  isDir(mode: number): boolean;
  readFile(path: string, opts?: { encoding?: string }): Uint8Array | string;
  writeFile(path: string, data: Uint8Array | string): void;
  unlink(path: string): void;
  rmdir(path: string): void;
  rename(from: string, to: string): void;
  analyzePath?(path: string): { exists: boolean };
};

export class GitBridge {
  /** Single-writer promise queue for libgit2 + MEMFS worktree access. */
  private queue: Promise<unknown> = Promise.resolve();

  constructor(
    readonly mod: EmscriptenGitModule,
    public eng: number,
    readonly workRoot: string = DEFAULT_WORK_ROOT,
  ) {}

  static async create(
    baseUrl: string,
    opts: { workRoot?: string } = {},
  ): Promise<GitBridge> {
    const root = baseUrl.endsWith("/") ? baseUrl : baseUrl + "/";
    const workRoot = opts.workRoot ?? DEFAULT_WORK_ROOT;
    // Prefer .mjs (always ESM). Fall back to .js when package.json type=module is present.
    const modUrl = await resolveEngineModuleUrl(root);
    const createGitEngineModule = await loadCreate(modUrl);
    const mod = (await createGitEngineModule({
      locateFile: (p: string) => {
        const name = String(p).endsWith(".wasm") ? "git_engine.wasm" : p;
        const url = new URL(name, root).href;
        if (
          typeof process !== "undefined" &&
          process.versions?.node &&
          url.startsWith("file:")
        ) {
          return new URL(url).pathname;
        }
        return url;
      },
    })) as EmscriptenGitModule;

    ensureDir(mod.FS, workRoot);

    const rootPtr = cstr(mod, workRoot);
    const eng = mod._ge_open(rootPtr);
    mod._free(rootPtr);
    if (!eng) {
      throw new Error("ge_open failed (need absolute existing MEMFS dir)");
    }
    return new GitBridge(mod, eng, workRoot);
  }

  /**
   * Shared serial mutex: all engine `run` / `importPack` and gitfs MEMFS ops
   * must go through this so concurrent mount ctl + host_call remotes + eng.run
   * cannot interleave libgit2.
   *
   * Nested `serial` while already inside a `serial` callback deadlocks — call
   * sync {@link run} / {@link importPack} / FS from within an outer serial body.
   */
  serial<T>(fn: () => T | Promise<T>): Promise<T> {
    const run = this.queue.then(fn, fn) as Promise<T>;
    this.queue = run.then(
      () => undefined,
      () => undefined,
    );
    return run;
  }

  version(): string {
    return this.mod.UTF8ToString(this.mod._ge_version()) || "unknown";
  }

  lastError(): string {
    return this.mod.UTF8ToString(this.mod._ge_last_error(this.eng)) || "";
  }

  /** Sync WASM ge_run_json. Callers that may race must wrap with {@link serial}. */
  run(req: GitRequest): GitResponse {
    const json = JSON.stringify({
      op: req.op,
      ...(req.args !== undefined ? { args: req.args } : {}),
    });
    const reqPtr = cstr(this.mod, json);
    const outPtr = this.mod._ge_run_json(this.eng, reqPtr);
    this.mod._free(reqPtr);
    const text = this.mod.UTF8ToString(outPtr);
    this.mod._ge_free(outPtr);
    try {
      return JSON.parse(text) as GitResponse;
    } catch {
      throw new Error(`invalid engine JSON: ${text.slice(0, 200)}`);
    }
  }

  /** Sync WASM ge_import_pack. Callers that may race must wrap with {@link serial}. */
  importPack(chunk: Uint8Array, final = false): void {
    const len = chunk?.byteLength ?? 0;
    let ptr = 0;
    if (len > 0) {
      ptr = this.mod._malloc(len);
      this.mod.HEAPU8.set(chunk, ptr);
    }
    const rc = this.mod._ge_import_pack(this.eng, ptr, len, final ? 1 : 0);
    if (ptr) this.mod._free(ptr);
    if (rc !== 0) {
      throw new Error(this.lastError() || `ge_import_pack failed (${rc})`);
    }
  }

  /**
   * Sync WASM ge_pack_build — reachable objects for tip OIDs as a packfile.
   * Optional `haves` (remote tips already held) shrinks the pack via revwalk hide.
   * Callers that may race must wrap with {@link serial}.
   */
  packBuild(oids: string[], haves?: string[]): Uint8Array {
    if (!Array.isArray(oids)) {
      throw new Error("packBuild: oids must be an array of 40-hex strings");
    }
    const haveList = Array.isArray(haves)
      ? haves.filter((h) => typeof h === "string" && /^[0-9a-f]{40}$/i.test(h))
      : [];
    const oidsJson =
      haveList.length > 0
        ? JSON.stringify({ oids, haves: haveList })
        : JSON.stringify(oids);
    const jsonPtr = cstr(this.mod, oidsJson);
    // wasm32: pointer + size_t are 4 bytes each (out / out_len slots).
    const outPtrSlot = this.mod._malloc(4);
    const outLenSlot = this.mod._malloc(4);
    this.mod.setValue(outPtrSlot, 0, "i32");
    this.mod.setValue(outLenSlot, 0, "i32");
    const rc = this.mod._ge_pack_build(this.eng, jsonPtr, outPtrSlot, outLenSlot);
    this.mod._free(jsonPtr);
    if (rc !== 0) {
      this.mod._free(outPtrSlot);
      this.mod._free(outLenSlot);
      throw new Error(this.lastError() || `ge_pack_build failed (${rc})`);
    }
    const dataPtr = this.mod.getValue(outPtrSlot, "i32");
    const dataLen = this.mod.getValue(outLenSlot, "i32") >>> 0;
    this.mod._free(outPtrSlot);
    this.mod._free(outLenSlot);
    if (!dataPtr || dataLen === 0) {
      if (dataPtr) this.mod._ge_free(dataPtr);
      throw new Error(this.lastError() || "ge_pack_build returned empty pack");
    }
    const bytes = this.mod.HEAPU8.slice(dataPtr, dataPtr + dataLen);
    this.mod._ge_free(dataPtr);
    if (
      bytes.byteLength < 4 ||
      bytes[0] !== 0x50 ||
      bytes[1] !== 0x41 ||
      bytes[2] !== 0x43 ||
      bytes[3] !== 0x4b
    ) {
      throw new Error("ge_pack_build: pack missing PACK magic");
    }
    return bytes;
  }

  abs(rel: string): string {
    const p = normalizeRel(rel);
    return p ? `${this.workRoot}/${p}` : this.workRoot;
  }

  get FS(): EmscriptenFS {
    return this.mod.FS;
  }

  close(): void {
    if (this.eng) {
      this.mod._ge_close(this.eng);
      this.eng = 0;
    }
  }
}

/**
 * Canonical relative path for gitfs/engine MEMFS.
 * Collapses empty segments and `.`; rejects `..` segments (K17 + path safety).
 * So `/.git/./objects` and `/.git//objects` normalize to `.git/objects`.
 */
export function normalizeRel(path: string): string {
  let p = String(path || "").replace(/\\/g, "/");
  while (p.startsWith("/")) p = p.slice(1);
  if (p === "." || p === "") return "";
  const parts: string[] = [];
  for (const seg of p.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") {
      const err = new Error("path escapes worktree") as Error & { code?: string };
      err.code = "EACCES";
      throw err;
    }
    parts.push(seg);
  }
  return parts.join("/");
}

function ensureDir(FS: EmscriptenFS, path: string): void {
  if (typeof FS.mkdirTree === "function") {
    try {
      FS.mkdirTree(path);
      return;
    } catch {
      /* fall through */
    }
  }
  const parts = path.split("/").filter(Boolean);
  let cur = "";
  for (const part of parts) {
    cur += "/" + part;
    try {
      FS.mkdir(cur);
    } catch {
      /* exists */
    }
  }
}

function cstr(mod: EmscriptenGitModule, s: string): number {
  const n = mod.lengthBytesUTF8(s) + 1;
  const p = mod._malloc(n);
  mod.stringToUTF8(s, p, n);
  return p;
}

async function resolveEngineModuleUrl(root: string): Promise<string> {
  const candidates = ["git_engine.mjs", "git_engine.js"];
  if (typeof process !== "undefined" && process.versions?.node) {
    const { existsSync } = await import("node:fs");
    const { fileURLToPath } = await import("node:url");
    for (const name of candidates) {
      const href = new URL(name, root).href;
      try {
        const p = fileURLToPath(href);
        if (existsSync(p)) return href;
      } catch {
        /* non-file URL */
      }
    }
  }
  return new URL(candidates[0], root).href;
}

async function loadCreate(
  modUrl: string,
): Promise<(opts?: object) => Promise<EmscriptenGitModule>> {
  // emcc EXPORT_ES6 emits `export default createGitEngineModule` — always ESM.
  // Load via .mjs (or .js under type:module) so Node does not treat it as CJS.
  let href = modUrl;
  if (
    !modUrl.startsWith("file:") &&
    !modUrl.startsWith("http:") &&
    !modUrl.startsWith("https:") &&
    !modUrl.startsWith("data:")
  ) {
    const { pathToFileURL } = await import("node:url");
    href = pathToFileURL(modUrl).href;
  }
  const m = (await import(/* @vite-ignore */ href)) as {
    default?: (opts?: object) => Promise<EmscriptenGitModule>;
    createGitEngineModule?: (opts?: object) => Promise<EmscriptenGitModule>;
  };
  const fn = m.default ?? m.createGitEngineModule;
  if (typeof fn === "function") return fn;
  throw new Error(`cannot load createGitEngineModule from ${href}`);
}
