/**
 * GitFsDriver — MountFs Driver projecting engine MEMFS worktree + synthetic .git/ctl.
 * GIT.md §5–6: local porcelain via ctl; remotes fail closed (host_call git only).
 */

import type { Driver, DriverEntry, DriverError, DriverMeta } from "../types.js";
import type { GitBridge } from "./bridge.js";
import { normalizeRel } from "./bridge.js";

const REMOTE_OPS = new Set(["clone", "fetch", "pull", "push"]);

/**
 * Brand symbol for gitfs drivers (K21 / R66). Hosts use this to enforce
 * **one gitfs driver per mount path** (multi-mount allowed with distinct paths;
 * same path still fails closed). Single-writer remains **per engine**.
 */
export const GITFS_DRIVER_KIND = Symbol.for("agentos.gitfs");

export interface GitFsDriverOptions {
  readOnly?: boolean;
  /**
   * PR14 sparse cone: only project relative paths under these prefixes
   * (e.g. `["src/", "docs/"]`). Empty = full tree. Synthetic `.git` always visible.
   */
  sparseCone?: string[];
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
export function createGitFsDriver(
  bridge: GitBridge,
  opts: GitFsDriverOptions = {},
): Driver {
  const readOnly = !!opts.readOnly;
  const cone = (opts.sparseCone ?? [])
    .map((p) => p.replace(/^\/+/, "").replace(/\/?$/, "/"))
    .filter(Boolean);
  let lastResponse = JSON.stringify({
    ok: true,
    code: 0,
    stdout: "",
    stderr: "",
  });
  let generation = 0;

  // Shared with GitEngine.run / importPack via bridge.serial (single-writer).
  const serial = <T>(fn: () => T | Promise<T>): Promise<T> =>
    bridge.serial(fn);

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
   * K17: no guest `.git/objects` façade. Host ODB stays host-side; open/stat/readdir
   * of objects (and any child) fail with ENOENT so the path is not projected.
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

  /**
   * R23: synthetic `.git/HEAD` from engine branch / rev-parse — not hard-coded master
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

  const driver: Driver = {
    readOnly,

    async open(path: string): Promise<Uint8Array> {
      return serial(() => {
        const p = normalizeRel(path);
        if (!inCone(p) && !isGitMeta(p)) throw fsErr("ENOENT", p);
        // K17: no objects façade — do not fall through to host ODB MEMFS.
        if (isObjectsPath(p)) throw fsErr("ENOENT", ".git/objects");
        if (p === ".git/mc/ctl" || p === ".git/mc/out/last") {
          return new TextEncoder().encode(lastResponse);
        }
        if (p === ".git/mc/generation") {
          return new TextEncoder().encode(String(generation) + "\n");
        }
        if (p === ".git/HEAD") {
          return new TextEncoder().encode(syntheticHeadContent());
        }
        if (
          p === ".git" ||
          p === ".git/mc" ||
          p === ".git/mc/out" ||
          p === ".git/refs"
        ) {
          throw fsErr("EISDIR", "is a directory");
        }
        const abs = bridge.abs(p);
        if (!exists(abs)) throw fsErr("ENOENT", p);
        const st = FS().stat(abs);
        if (FS().isDir(st.mode)) throw fsErr("EISDIR", p);
        const data = FS().readFile(abs);
        return data instanceof Uint8Array
          ? data
          : new TextEncoder().encode(String(data));
      });
    },

    async stat(path: string): Promise<DriverMeta> {
      return serial(() => {
        const p = normalizeRel(path);
        if (p === "" || p === ".") {
          return { kind: "dir" as const, size: 0 };
        }
        if (!inCone(p) && !isGitMeta(p)) throw fsErr("ENOENT", p);
        // K17: not listed under .git; not a projected path (ENOENT, not empty dir).
        if (isObjectsPath(p)) throw fsErr("ENOENT", ".git/objects");
        if (
          p === ".git" ||
          p === ".git/mc" ||
          p === ".git/mc/out" ||
          p === ".git/refs"
        ) {
          return { kind: "dir" as const, size: 0 };
        }
        if (p === ".git/mc/ctl" || p === ".git/mc/out/last") {
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
        const abs = bridge.abs(p);
        if (!exists(abs)) throw fsErr("ENOENT", p);
        const st = FS().stat(abs);
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
          const names = FS()
            .readdir(bridge.workRoot)
            .filter((n) => n !== "." && n !== "..");
          const out: DriverEntry[] = names
            .filter((name) => inCone(name) || name === ".git")
            .map((name) => {
              const st = FS().stat(bridge.abs(name));
              return {
                name,
                kind: (FS().isDir(st.mode) ? "dir" : "file") as "dir" | "file",
              };
            });
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
        // K17: objects is not a guest dir (ENOENT even if host ODB exists).
        if (isObjectsPath(p)) throw fsErr("ENOENT", ".git/objects");
        if (p === ".git") {
          // Synthetic only: HEAD + mc (ctl) + refs — never objects (K17).
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
        const abs = bridge.abs(p);
        if (!exists(abs)) throw fsErr("ENOENT", p);
        const st = FS().stat(abs);
        if (!FS().isDir(st.mode)) throw fsErr("ENOTDIR", p);
        return FS()
          .readdir(abs)
          .filter((n) => n !== "." && n !== "..")
          .filter((name) => {
            const child = p ? `${p}/${name}` : name;
            return inCone(child) || isGitMeta(child);
          })
          .map((name) => {
            const s = FS().stat(`${abs}/${name}`);
            return {
              name,
              kind: (FS().isDir(s.mode) ? "dir" : "file") as "dir" | "file",
            };
          });
      });
    },

    async write(path: string, data: Uint8Array): Promise<void> {
      return serial(() => {
        if (readOnly) throw fsErr("EACCES", "read-only mount");
        const p = normalizeRel(path);
        if (!inCone(p) && !isGitMeta(p)) throw fsErr("ENOENT", p);
        // K17: refuse writes into host ODB projection (not present to guest).
        if (isObjectsPath(p)) throw fsErr("ENOENT", ".git/objects");
        const bytes =
          data instanceof Uint8Array
            ? data
            : new TextEncoder().encode(String(data));

        // Ctl: write Request → Run; Response observed on subsequent open/read (MountFs drain).
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
          if (REMOTE_OPS.has(op)) {
            lastResponse = JSON.stringify({
              ok: false,
              code: 1,
              stdout: "",
              stderr: "use host_call git for remotes",
            });
            generation += 1;
            return;
          }
          const resp = bridge.run({ op: req.op || "", args: req.args });
          lastResponse = JSON.stringify(resp);
          generation += 1;
          return;
        }

        if (isGitMeta(path) && p !== ".git/HEAD") {
          if (p.startsWith(".git/mc")) throw fsErr("EACCES", "synthetic path");
        }

        const abs = bridge.abs(p);
        ensureParent(FS(), abs);
        FS().writeFile(abs, bytes);
      });
    },

    async mkdir(path: string): Promise<void> {
      return serial(() => {
        if (readOnly) throw fsErr("EACCES", "read-only mount");
        const p = normalizeRel(path);
        if (!inCone(p) && !isGitMeta(p)) throw fsErr("ENOENT", p);
        if (isObjectsPath(p)) throw fsErr("ENOENT", ".git/objects");
        if (isGitMeta(path) && p !== ".git") {
          if (p.startsWith(".git")) throw fsErr("EACCES", "synthetic .git");
        }
        const abs = bridge.abs(p);
        ensureParent(FS(), abs);
        try {
          FS().mkdir(abs);
        } catch {
          /* EEXIST ok */
        }
      });
    },

    async unlink(path: string): Promise<void> {
      return serial(() => {
        if (readOnly) throw fsErr("EACCES", "read-only mount");
        const p = normalizeRel(path);
        if (!inCone(p) && !isGitMeta(p)) throw fsErr("ENOENT", p);
        if (isGitMeta(path)) throw fsErr("EACCES", "synthetic .git");
        const abs = bridge.abs(p);
        if (!exists(abs)) throw fsErr("ENOENT", p);
        const st = FS().stat(abs);
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
        const a = bridge.abs(from);
        const b = bridge.abs(to);
        if (!exists(a)) throw fsErr("ENOENT", from);
        ensureParent(FS(), b);
        FS().rename(a, b);
      });
    },
  };

  // K21 brand: one gitfs per mount path (multi-path OK; same path fail-closed).
  Object.defineProperty(driver, GITFS_DRIVER_KIND, {
    value: true,
    enumerable: false,
    configurable: false,
    writable: false,
  });
  return driver;
}

function ensureParent(
  FS: GitBridge["FS"],
  abs: string,
): void {
  const parts = abs.split("/").filter(Boolean);
  let cur = "";
  for (let i = 0; i < parts.length - 1; i++) {
    cur += "/" + parts[i];
    try {
      FS.mkdir(cur);
    } catch {
      /* exists */
    }
  }
}
