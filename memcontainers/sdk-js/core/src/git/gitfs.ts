/**
 * GitFsDriver — worktree projection into the guest VFS.
 *
 * MountFs Driver that maps engine MEMFS worktree paths plus a synthetic
 * `.git/mc/ctl` control plane for local porcelain. Remotes fail closed here
 * (guest must use host_call `"git"`). Single-writer via bridge.serial; brand
 * symbol enforces one gitfs driver per mount path.
 */

import type { Driver, DriverEntry, DriverError, DriverMeta } from "../types.js";
import type { GitBridge } from "./bridge.js";
import { normalizeRel } from "./bridge.js";

const REMOTE_OPS = new Set(["clone", "fetch", "pull", "push"]);

/**
 * Brand symbol for gitfs drivers (K21). Hosts use this to enforce **one gitfs
 * driver per mount path** (multi-mount allowed with distinct paths; same path
 * still fails closed). Single-writer remains **per engine**.
 */
export const GITFS_DRIVER_KIND = Symbol.for("agentos.gitfs");

export interface GitFsDriverOptions {
  readOnly?: boolean;
  /**
   * Sparse cone: only project relative paths under these prefixes
   * (e.g. `["src/", "docs/"]`). Empty = full tree. Synthetic `.git` always visible.
   */
  sparseCone?: string[];
  /**
   * Host commit identity (K28). Injected into ctl `commit` when args omit name/email.
   * Same policy as {@link GitEngine.run} inject — never invents defaults when unset.
   */
  identity?: { name: string; email: string };
}

/** True when `driver` was produced by {@link createGitFsDriver}. */
export function isGitFsDriver(driver: unknown): boolean {
  return (
    !!driver &&
    typeof driver === "object" &&
    (driver as { [GITFS_DRIVER_KIND]?: boolean })[GITFS_DRIVER_KIND] === true
  );
}

/** Build a {@link Driver} for `mc.create({ mounts: [{ path, driver }] })`. */
export function createGitFsDriver(bridge: GitBridge, opts: GitFsDriverOptions = {}): Driver {
  const readOnly = !!opts.readOnly;
  const cone = (opts.sparseCone ?? [])
    .map((p) => p.replace(/^\/+/, "").replace(/\/?$/, "/"))
    .filter(Boolean);
  const identity =
    opts.identity &&
    typeof opts.identity.name === "string" &&
    opts.identity.name.trim() &&
    typeof opts.identity.email === "string" &&
    opts.identity.email.trim()
      ? { name: opts.identity.name.trim(), email: opts.identity.email.trim() }
      : undefined;
  let lastResponse = JSON.stringify({
    ok: true,
    code: 0,
    stdout: "",
    stderr: "",
  });
  let generation = 0;

  // Shared with GitEngine.run / importPack via bridge.serial (single-writer).
  const serial = <T>(fn: () => T | Promise<T>): Promise<T> => bridge.serial(fn);

  const FS = () => bridge.FS;

  function fsErr(code: DriverError["code"], msg: string): DriverError {
    const e = new Error(msg) as DriverError;
    e.code = code;
    return e;
  }

  function isGitMeta(path: string): boolean {
    const p = normalizeRel(path);
    return p === ".git" || p.startsWith(".git/");
  }

  /**
   * No guest `.git/objects` façade (K17). Host ODB stays host-side; open/stat/
   * readdir of objects (and any child) fail with ENOENT so the path is not projected.
   */
  function isObjectsPath(path: string): boolean {
    const p = normalizeRel(path);
    return p === ".git/objects" || p.startsWith(".git/objects/");
  }

  function inCone(path: string): boolean {
    if (!cone.length) return true;
    const p = normalizeRel(path);
    if (!p || isGitMeta(p)) return true;
    return cone.some((c) => p === c.slice(0, -1) || p.startsWith(c));
  }

  function exists(abs: string): boolean {
    try {
      FS().stat(abs);
      return true;
    } catch {
      return false;
    }
  }

  /** Resolve an existing worktree path while rejecting symlinks in every
   * component. Emscripten maps lstat/isLink to MEMFS and NODEFS alike. */
  function safeExisting(path: string): string {
    const p = normalizeRel(path);
    let cur = bridge.workRoot;
    const parts = p.split("/").filter(Boolean);
    for (let i = 0; i < parts.length; i++) {
      cur += `/${parts[i]}`;
      let st: { mode: number; size?: number };
      try {
        st = FS().lstat(cur);
      } catch {
        throw fsErr("ENOENT", p);
      }
      if (FS().isLink(st.mode)) {
        throw fsErr("EACCES", `symlink path component: ${p}`);
      }
      if (i + 1 < parts.length && !FS().isDir(st.mode)) {
        throw fsErr("ENOTDIR", p);
      }
    }
    return cur;
  }

  /** Resolve a create target. Missing parent directories are created beneath
   * workRoot; every component that already exists must be a non-link. */
  function safeCreateTarget(path: string): string {
    const p = normalizeRel(path);
    const parts = p.split("/").filter(Boolean);
    if (!parts.length) throw fsErr("EACCES", "mount root is not a create target");
    let cur = bridge.workRoot;
    for (let i = 0; i < parts.length; i++) {
      cur += `/${parts[i]}`;
      let st: { mode: number; size?: number } | undefined;
      try {
        st = FS().lstat(cur);
      } catch {
        st = undefined;
      }
      if (!st) {
        if (i + 1 < parts.length) {
          try {
            FS().mkdir(cur);
          } catch {
            throw fsErr("EACCES", `cannot create safe parent: ${p}`);
          }
        }
        continue;
      }
      if (FS().isLink(st.mode)) {
        throw fsErr("EACCES", `symlink path component: ${p}`);
      }
      if (i + 1 < parts.length && !FS().isDir(st.mode)) {
        throw fsErr("ENOTDIR", p);
      }
    }
    return cur;
  }

  function safeDirEntries(path: string): DriverEntry[] {
    const abs = path ? safeExisting(path) : bridge.workRoot;
    const entries: DriverEntry[] = [];
    for (const name of FS().readdir(abs)) {
      if (name === "." || name === "..") continue;
      const child = path ? `${path}/${name}` : name;
      if (!inCone(child) || isGitMeta(child)) continue;
      try {
        const childAbs = safeExisting(child);
        const st = FS().lstat(childAbs);
        entries.push({
          name,
          kind: (FS().isDir(st.mode) ? "dir" : "file") as "dir" | "file",
        });
      } catch (e) {
        if ((e as DriverError).code !== "EACCES") throw e;
        // Symlinks are intentionally not projected into the guest namespace.
      }
    }
    return entries;
  }

  /**
   * Synthetic `.git/HEAD` from engine branch / rev-parse — not hard-coded master
   * after checkout/clone. Detached → raw OID; unborn only falls back to master.
   * Must run inside bridge.serial (uses sync bridge.run).
   */
  function syntheticHeadContent(): string {
    try {
      const br = bridge.run({ op: "branch" });
      const line = (br.stdout || "").split("\n").find((l) => l.startsWith("* "));
      if (line) {
        const name = line.slice(2).trim();
        // Detached: "* (HEAD detached at abc…)" — fall through to rev-parse
        if (name && !name.startsWith("(")) {
          return `ref: refs/heads/${name}\n`;
        }
      }
    } catch {
      /* */
    }
    try {
      const r = bridge.run({ op: "rev-parse", args: { rev: "HEAD" } });
      if (r.ok && r.stdout?.trim()) {
        const s = r.stdout.trim().split(/\s+/)[0] ?? "";
        if (/^[0-9a-f]{40}$/i.test(s)) return `${s}\n`; // detached
        if (s) return `ref: refs/heads/${s}\n`;
      }
    } catch {
      /* unborn */
    }
    return "ref: refs/heads/master\n";
  }

  // ── Driver face ───────────────────────────────────────────────────────────

  const driver: Driver = {
    readOnly,

    async open(path: string): Promise<Uint8Array> {
      return serial(() => {
        const p = normalizeRel(path);
        if (!inCone(p) && !isGitMeta(p)) throw fsErr("ENOENT", p);
        // No objects façade — do not fall through to host ODB MEMFS.
        if (isObjectsPath(p)) throw fsErr("ENOENT", ".git/objects");
        // Ctl always returns last Response JSON (drain protocol).
        if (p === ".git/mc/ctl") {
          return new TextEncoder().encode(lastResponse);
        }
        // out/last (and out/stream alias) serve full stdout body when the
        // engine wrote a stream file after result.truncated; else Response JSON.
        if (p === ".git/mc/out/last" || p === ".git/mc/out/stream") {
          const streamRel = p === ".git/mc/out/stream" ? ".git/mc/out/last" : p;
          const streamAbs = bridge.abs(streamRel);
          if (exists(streamAbs)) {
            try {
              const st = FS().stat(streamAbs);
              if (!FS().isDir(st.mode)) {
                const data = FS().readFile(streamAbs);
                return data instanceof Uint8Array ? data : new TextEncoder().encode(String(data));
              }
            } catch {
              /* fall through to Response alias */
            }
          }
          return new TextEncoder().encode(lastResponse);
        }
        if (p === ".git/mc/generation") {
          return new TextEncoder().encode(String(generation) + "\n");
        }
        if (p === ".git/HEAD") {
          return new TextEncoder().encode(syntheticHeadContent());
        }
        if (p === ".git" || p === ".git/mc" || p === ".git/mc/out" || p === ".git/refs") {
          throw fsErr("EISDIR", "is a directory");
        }
        const abs = safeExisting(p);
        const st = FS().lstat(abs);
        if (FS().isDir(st.mode)) throw fsErr("EISDIR", p);
        const data = FS().readFile(abs);
        return data instanceof Uint8Array ? data : new TextEncoder().encode(String(data));
      });
    },

    async stat(path: string): Promise<DriverMeta> {
      return serial(() => {
        const p = normalizeRel(path);
        if (p === "" || p === ".") {
          return { kind: "dir" as const, size: 0 };
        }
        if (!inCone(p) && !isGitMeta(p)) throw fsErr("ENOENT", p);
        // Not listed under .git; not a projected path (ENOENT, not empty dir).
        if (isObjectsPath(p)) throw fsErr("ENOENT", ".git/objects");
        if (p === ".git" || p === ".git/mc" || p === ".git/mc/out" || p === ".git/refs") {
          return { kind: "dir" as const, size: 0 };
        }
        if (p === ".git/mc/ctl") {
          return {
            kind: "file" as const,
            size: new TextEncoder().encode(lastResponse).length,
          };
        }
        if (p === ".git/mc/out/last" || p === ".git/mc/out/stream") {
          const streamRel = p === ".git/mc/out/stream" ? ".git/mc/out/last" : p;
          const streamAbs = bridge.abs(streamRel);
          if (exists(streamAbs)) {
            try {
              const st = FS().stat(streamAbs);
              if (!FS().isDir(st.mode)) {
                return { kind: "file" as const, size: st.size ?? 0 };
              }
            } catch {
              /* fall through */
            }
          }
          return {
            kind: "file" as const,
            size: new TextEncoder().encode(lastResponse).length,
          };
        }
        if (p === ".git/mc/generation") {
          return { kind: "file" as const, size: String(generation).length + 1 };
        }
        if (p === ".git/HEAD") {
          return { kind: "file" as const, size: 32 };
        }
        const abs = safeExisting(p);
        const st = FS().lstat(abs);
        return {
          kind: (FS().isDir(st.mode) ? "dir" : "file") as "dir" | "file",
          size: st.size ?? 0,
        };
      });
    },

    async readdir(path: string): Promise<DriverEntry[]> {
      return serial(() => {
        const p = normalizeRel(path);
        if (p === "" || p === ".") {
          const out = safeDirEntries("");
          if (!out.some((e) => e.name === ".git")) {
            out.push({ name: ".git", kind: "dir" });
          }
          // Cone top-level dirs that may not exist yet on MEMFS
          for (const c of cone) {
            const top = c.split("/").filter(Boolean)[0];
            if (top && !out.some((e) => e.name === top)) {
              out.push({ name: top, kind: "dir" });
            }
          }
          return out;
        }
        if (!inCone(p) && !isGitMeta(p)) throw fsErr("ENOENT", p);
        // objects is not a guest dir (ENOENT even if host ODB exists).
        if (isObjectsPath(p)) throw fsErr("ENOENT", ".git/objects");
        if (p === ".git") {
          // Synthetic only: HEAD + mc (ctl) + refs — never objects.
          return [
            { name: "HEAD", kind: "file" as const },
            { name: "mc", kind: "dir" as const },
            { name: "refs", kind: "dir" as const },
          ];
        }
        if (p === ".git/mc") {
          return [
            { name: "ctl", kind: "file" as const },
            { name: "out", kind: "dir" as const },
            { name: "generation", kind: "file" as const },
          ];
        }
        if (p === ".git/mc/out") {
          return [{ name: "last", kind: "file" as const }];
        }
        if (p === ".git/refs") {
          return [];
        }
        const abs = safeExisting(p);
        const st = FS().lstat(abs);
        if (!FS().isDir(st.mode)) throw fsErr("ENOTDIR", p);
        return safeDirEntries(p);
      });
    },

    async write(path: string, data: Uint8Array): Promise<void> {
      return serial(() => {
        if (readOnly) throw fsErr("EACCES", "read-only mount");
        const p = normalizeRel(path);
        if (!inCone(p) && !isGitMeta(p)) throw fsErr("ENOENT", p);
        // Refuse writes into host ODB projection (not present to guest).
        if (isObjectsPath(p)) throw fsErr("ENOENT", ".git/objects");
        const bytes = data instanceof Uint8Array ? data : new TextEncoder().encode(String(data));

        // Ctl: write Request → Run; Response observed on subsequent open/read
        // (MountFs drain protocol).
        if (p === ".git/mc/ctl") {
          let req: { op?: string; args?: unknown };
          try {
            req = JSON.parse(new TextDecoder().decode(bytes)) as {
              op?: string;
              args?: unknown;
            };
          } catch {
            lastResponse = JSON.stringify({
              ok: false,
              code: 2,
              stdout: "",
              stderr: "invalid JSON",
            });
            generation += 1;
            return;
          }
          const op = String(req.op || "").toLowerCase();
          // Optional args.client_token echoed in result.client_token (race detect).
          const clientToken = (() => {
            if (
              req.args &&
              typeof req.args === "object" &&
              !Array.isArray(req.args) &&
              typeof (req.args as { client_token?: unknown }).client_token === "string"
            ) {
              return String((req.args as { client_token: string }).client_token);
            }
            return "";
          })();
          const withToken = (resp: Record<string, unknown>): Record<string, unknown> => {
            if (!clientToken) return resp;
            const result =
              resp.result && typeof resp.result === "object" && !Array.isArray(resp.result)
                ? { ...(resp.result as Record<string, unknown>), client_token: clientToken }
                : { client_token: clientToken };
            return { ...resp, result };
          };
          if (REMOTE_OPS.has(op)) {
            lastResponse = JSON.stringify(
              withToken({
                ok: false,
                code: 1,
                stdout: "",
                stderr: "use host_call git for remotes",
              }),
            );
            generation += 1;
            return;
          }
          // K28: inject host identity into commit when ctl args omit name/email.
          let runReq: { op: string; args?: unknown } = {
            op: req.op || "",
            args: req.args,
          };
          if (identity && op === "commit") {
            const base =
              req.args && typeof req.args === "object" && !Array.isArray(req.args)
                ? { ...(req.args as Record<string, unknown>) }
                : {};
            const name =
              typeof base.name === "string" && base.name.trim() ? base.name : identity.name;
            const email =
              typeof base.email === "string" && base.email.trim() ? base.email : identity.email;
            runReq = { op: req.op || "commit", args: { ...base, name, email } };
          }
          const resp = bridge.run(runReq) as unknown as Record<string, unknown>;
          lastResponse = JSON.stringify(withToken(resp));
          generation += 1;
          return;
        }

        // Port parity: only `.git/mc/ctl` is a guest write surface under `.git/`.
        // All other git meta (HEAD, refs, config, out/*, generation, …) → EACCES.
        // K17 objects already returned ENOENT above.
        if (isGitMeta(p)) {
          throw fsErr("EACCES", "synthetic .git");
        }

        const abs = safeCreateTarget(p);
        FS().writeFile(abs, bytes);
      });
    },

    async mkdir(path: string): Promise<void> {
      return serial(() => {
        if (readOnly) throw fsErr("EACCES", "read-only mount");
        const p = normalizeRel(path);
        if (!inCone(p) && !isGitMeta(p)) throw fsErr("ENOENT", p);
        if (isObjectsPath(p)) throw fsErr("ENOENT", ".git/objects");
        // Port parity: no guest mkdir under synthetic `.git` (incl. `.git` itself).
        if (isGitMeta(p)) throw fsErr("EACCES", "synthetic .git");
        const abs = safeCreateTarget(p);
        try {
          FS().mkdir(abs);
        } catch {
          const st = FS().lstat(abs);
          if (!FS().isDir(st.mode) || FS().isLink(st.mode)) {
            throw fsErr("EEXIST", p);
          }
        }
      });
    },

    async unlink(path: string): Promise<void> {
      return serial(() => {
        if (readOnly) throw fsErr("EACCES", "read-only mount");
        const p = normalizeRel(path);
        if (!inCone(p) && !isGitMeta(p)) throw fsErr("ENOENT", p);
        // K17 before meta EACCES so objects stay ENOENT for all ops.
        if (isObjectsPath(p)) throw fsErr("ENOENT", ".git/objects");
        if (isGitMeta(p)) throw fsErr("EACCES", "synthetic .git");
        const abs = safeExisting(p);
        const st = FS().lstat(abs);
        if (FS().isDir(st.mode)) FS().rmdir(abs);
        else FS().unlink(abs);
      });
    },

    async rename(from: string, to: string): Promise<void> {
      return serial(() => {
        if (readOnly) throw fsErr("EACCES", "read-only mount");
        const fp = normalizeRel(from);
        const tp = normalizeRel(to);
        if ((!inCone(fp) && !isGitMeta(fp)) || (!inCone(tp) && !isGitMeta(tp))) {
          throw fsErr("ENOENT", from);
        }
        if (isObjectsPath(fp) || isObjectsPath(tp)) {
          throw fsErr("ENOENT", ".git/objects");
        }
        if (isGitMeta(from) || isGitMeta(to)) {
          throw fsErr("EACCES", "synthetic .git");
        }
        const a = safeExisting(fp);
        const b = safeCreateTarget(tp);
        FS().rename(a, b);
      });
    },
  };

  // Brand: one gitfs per mount path (multi-path OK; same path fail-closed).
  Object.defineProperty(driver, GITFS_DRIVER_KIND, {
    value: true,
    enumerable: false,
    configurable: false,
    writable: false,
  });
  return driver;
}
