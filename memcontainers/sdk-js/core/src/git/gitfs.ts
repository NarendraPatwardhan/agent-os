/**
 * GitFsDriver — MountFs Driver projecting engine MEMFS worktree + synthetic .git/ctl.
 * GIT.md §5–6: local porcelain via ctl; remotes fail closed (host_call git only).
 */

import type { Driver, DriverEntry, DriverError, DriverMeta } from "../types.js";
import type { GitBridge } from "./bridge.js";
import { normalizeRel } from "./bridge.js";

const REMOTE_OPS = new Set(["clone", "fetch", "pull", "push"]);

export interface GitFsDriverOptions {
  readOnly?: boolean;
}

/** Build a {@link Driver} for `mc.create({ mounts: [{ path, driver }] })`. */
export function createGitFsDriver(
  bridge: GitBridge,
  opts: GitFsDriverOptions = {},
): Driver {
  const readOnly = !!opts.readOnly;
  let lastResponse = JSON.stringify({
    ok: true,
    code: 0,
    stdout: "",
    stderr: "",
  });
  let generation = 0;
  let chain: Promise<unknown> = Promise.resolve();

  const serial = <T>(fn: () => T | Promise<T>): Promise<T> => {
    const p = chain.then(fn, fn) as Promise<T>;
    chain = p.then(
      () => undefined,
      () => undefined,
    );
    return p;
  };

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

  function exists(abs: string): boolean {
    try {
      FS().stat(abs);
      return true;
    } catch {
      return false;
    }
  }

  function branchNameFromHead(): string {
    try {
      const r = bridge.run({ op: "rev-parse", args: { rev: "HEAD" } });
      void r;
    } catch {
      /* unborn */
    }
    // Reduced: prefer master/main via branch list
    try {
      const br = bridge.run({ op: "branch" });
      const line = (br.stdout || "").split("\n").find((l) => l.startsWith("* "));
      if (line) return line.slice(2).trim() || "master";
    } catch {
      /* */
    }
    return "master";
  }

  return {
    readOnly,

    async open(path: string): Promise<Uint8Array> {
      return serial(async () => {
        const p = normalizeRel(path);
        if (p === ".git/mc/ctl" || p === ".git/mc/out/last") {
          return new TextEncoder().encode(lastResponse);
        }
        if (p === ".git/mc/generation") {
          return new TextEncoder().encode(String(generation) + "\n");
        }
        if (p === ".git/HEAD") {
          const name = branchNameFromHead();
          return new TextEncoder().encode(`ref: refs/heads/${name}\n`);
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
      const p = normalizeRel(path);
      if (p === "" || p === ".") {
        return { kind: "dir", size: 0 };
      }
      if (
        p === ".git" ||
        p === ".git/mc" ||
        p === ".git/mc/out" ||
        p === ".git/refs" ||
        p === ".git/objects"
      ) {
        return { kind: "dir", size: 0 };
      }
      if (p === ".git/mc/ctl" || p === ".git/mc/out/last") {
        return {
          kind: "file",
          size: new TextEncoder().encode(lastResponse).length,
        };
      }
      if (p === ".git/mc/generation") {
        return { kind: "file", size: String(generation).length + 1 };
      }
      if (p === ".git/HEAD") {
        return { kind: "file", size: 32 };
      }
      const abs = bridge.abs(p);
      if (!exists(abs)) throw fsErr("ENOENT", p);
      const st = FS().stat(abs);
      return {
        kind: FS().isDir(st.mode) ? "dir" : "file",
        size: st.size ?? 0,
      };
    },

    async readdir(path: string): Promise<DriverEntry[]> {
      const p = normalizeRel(path);
      if (p === "" || p === ".") {
        const names = FS()
          .readdir(bridge.workRoot)
          .filter((n) => n !== "." && n !== "..");
        const out: DriverEntry[] = names.map((name) => {
          const st = FS().stat(bridge.abs(name));
          return { name, kind: FS().isDir(st.mode) ? "dir" : "file" };
        });
        if (!out.some((e) => e.name === ".git")) {
          out.push({ name: ".git", kind: "dir" });
        }
        return out;
      }
      if (p === ".git") {
        return [
          { name: "HEAD", kind: "file" },
          { name: "mc", kind: "dir" },
          { name: "refs", kind: "dir" },
        ];
      }
      if (p === ".git/mc") {
        return [
          { name: "ctl", kind: "file" },
          { name: "out", kind: "dir" },
          { name: "generation", kind: "file" },
        ];
      }
      if (p === ".git/mc/out") {
        return [{ name: "last", kind: "file" }];
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
        .map((name) => {
          const s = FS().stat(`${abs}/${name}`);
          return { name, kind: FS().isDir(s.mode) ? "dir" : "file" };
        });
    },

    async write(path: string, data: Uint8Array): Promise<void> {
      return serial(async () => {
        if (readOnly) throw fsErr("EACCES", "read-only mount");
        const p = normalizeRel(path);
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
      if (readOnly) throw fsErr("EACCES", "read-only mount");
      const p = normalizeRel(path);
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
    },

    async unlink(path: string): Promise<void> {
      if (readOnly) throw fsErr("EACCES", "read-only mount");
      const p = normalizeRel(path);
      if (isGitMeta(path)) throw fsErr("EACCES", "synthetic .git");
      const abs = bridge.abs(p);
      if (!exists(abs)) throw fsErr("ENOENT", p);
      const st = FS().stat(abs);
      if (FS().isDir(st.mode)) FS().rmdir(abs);
      else FS().unlink(abs);
    },

    async rename(from: string, to: string): Promise<void> {
      if (readOnly) throw fsErr("EACCES", "read-only mount");
      if (isGitMeta(from) || isGitMeta(to)) {
        throw fsErr("EACCES", "synthetic .git");
      }
      const a = bridge.abs(from);
      const b = bridge.abs(to);
      if (!exists(a)) throw fsErr("ENOENT", from);
      ensureParent(FS(), b);
      FS().rename(a, b);
    },
  };
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
