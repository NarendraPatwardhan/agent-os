/**
 * GitRemoteOrchestrator (TS) — GIT.md §7 / PR10a.
 * Algorithm twin of C orch.c; golden traces in testdata/orch/*.json.
 * Engine never dials: only ImportPack + apply ops.
 */

import type { GitEngine } from "./engine.js";
import type { GitRequest, GitResponse } from "./types.js";
import {
  FetchSmartHttp,
  type RefAdvertisement,
  type SmartHttpTransport,
} from "./smart-http.js";

export interface OrchestratorOptions {
  http?: SmartHttpTransport;
  /** Origin allowlist exact-match (public URLs). Empty = allow fixture/any for tests. */
  allowOrigins?: string[];
}

export class GitRemoteOrchestrator {
  private readonly http: SmartHttpTransport;
  private readonly allowOrigins: string[];

  constructor(
    private readonly engine: GitEngine,
    opts: OrchestratorOptions = {},
  ) {
    this.http = opts.http ?? new FetchSmartHttp();
    this.allowOrigins = opts.allowOrigins ?? [];
  }

  /** Host_call name "git" body: Request JSON → Response JSON. */
  async handle(req: GitRequest): Promise<GitResponse> {
    const op = String(req.op || "").toLowerCase();
    if (op === "clone") return this.clone(req);
    if (op === "fetch" || op === "pull") return this.fetch(req);
    if (op === "push") {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: "push requires PR12 / approval path\n",
      };
    }
    return {
      ok: false,
      code: 2,
      stdout: "",
      stderr: `unknown remote op: ${op}\n`,
    };
  }

  private urlOf(req: GitRequest): string {
    const args = (req.args ?? {}) as Record<string, unknown>;
    return String(args.url ?? args.remote ?? "");
  }

  private checkOrigin(url: string): GitResponse | null {
    if (!url) {
      return {
        ok: false,
        code: 2,
        stdout: "",
        stderr: "clone/fetch need args.url\n",
      };
    }
    if (this.allowOrigins.length === 0) return null;
    try {
      const u = new URL(url);
      const ok = this.allowOrigins.some((o) => o === url || o === u.origin);
      if (!ok) {
        return {
          ok: false,
          code: 1,
          stdout: "",
          stderr: `git: origin not allowlisted: ${url}\n`,
        };
      }
    } catch {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: `git: bad remote url\n`,
      };
    }
    return null;
  }

  private async clone(req: GitRequest): Promise<GitResponse> {
    const url = this.urlOf(req);
    const denied = this.checkOrigin(url);
    if (denied) return denied;

    let refs: RefAdvertisement[];
    try {
      refs = await this.http.listRefs(url);
    } catch (e) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: `git: list-refs failed: ${String(e)}\n`,
      };
    }
    if (!refs.length) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: "git: no refs in advertisement\n",
      };
    }
    const head =
      refs.find((r) => r.name === "HEAD") ??
      refs.find((r) => r.name.endsWith("/main") || r.name.endsWith("/master")) ??
      refs[0]!;

    const args = (req.args ?? {}) as Record<string, unknown>;
    const depth = typeof args.depth === "number" ? args.depth : undefined;

    let pack: Uint8Array;
    try {
      pack = await this.http.fetchPacks(url, [head.hash], [], depth);
    } catch (e) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: `git: upload-pack failed: ${String(e)}\n`,
      };
    }

    // Ensure repo + import binary pack
    const init = await this.engine.run({ op: "init" });
    if (!init.ok) return init;

    try {
      if (pack.byteLength > 0) {
        await this.engine.importPack(pack, { final: false });
      }
      await this.engine.importPack(new Uint8Array(0), { final: true });
    } catch (e) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: `import_pack: ${String(e)}\n`,
      };
    }

    const refName =
      head.name === "HEAD"
        ? refs.find((r) => r.hash === head.hash && r.name.startsWith("refs/"))
            ?.name ?? "refs/heads/master"
        : head.name;

    const imp = await this.engine.run({
      op: "refs.import",
      args: { name: refName, hash: head.hash },
    });
    if (!imp.ok) return imp;

    const apply = await this.engine.run({
      op: "clone.apply",
      args: { head: refName },
    });
    if (!apply.ok) return apply;

    return {
      ok: true,
      code: 0,
      stdout: `cloned ${url}\n`,
      stderr: "",
    };
  }

  private async fetch(req: GitRequest): Promise<GitResponse> {
    // Same path as clone for fixture MVP; list local have via tips later.
    const r = await this.clone({ ...req, op: "clone" });
    if (!r.ok) return r;
    const fa = await this.engine.run({ op: "fetch.apply" });
    if (!fa.ok) return fa;
    return { ok: true, code: 0, stdout: "fetched\n", stderr: "" };
  }
}

/** MapHostCall handler factory: body is Request JSON bytes. */
export function gitHostCallHandler(
  engine: GitEngine,
  opts?: OrchestratorOptions,
): (args: string) => Promise<string> {
  const orch = new GitRemoteOrchestrator(engine, opts);
  return async (args: string) => {
    let req: GitRequest;
    try {
      req = JSON.parse(args || "{}") as GitRequest;
    } catch {
      return JSON.stringify({
        ok: false,
        code: 2,
        stdout: "",
        stderr: "invalid JSON",
      });
    }
    const resp = await orch.handle(req);
    return JSON.stringify(resp);
  };
}
