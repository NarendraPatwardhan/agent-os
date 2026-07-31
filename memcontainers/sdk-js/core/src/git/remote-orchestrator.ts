/**
 * GitRemoteOrchestrator (TS) — GIT.md §7 / PR10a–PR12.
 * Algorithm twin of C orch.c. Engine never dials: ImportPack + apply only.
 */

import type { ConnectionDefinition, ConnectionPolicyRule } from "../types.js";
import type { GitEngine } from "./engine.js";
import type { GitRequest, GitResponse } from "./types.js";
import {
  redactRemoteForLog,
  resolveGitRemote,
  type ResolveRemoteOptions,
} from "./connections.js";
import {
  FetchSmartHttp,
  type PushCommand,
  type RefAdvertisement,
  type SmartHttpTransport,
} from "./smart-http.js";

export interface OrchestratorOptions extends ResolveRemoteOptions {
  http?: SmartHttpTransport;
  /** Legacy global origin allowlist (in addition to connection.origins). */
  allowOrigins?: string[];
  /** Read-only mount: reject push. */
  readOnly?: boolean;
  /**
   * Called when policy is require_approval for push. Return true to proceed.
   * Default: reject (fail closed).
   */
  onPushApproval?: (ctx: {
    url: string;
    connectionRef?: string;
    commands: PushCommand[];
  }) => boolean | Promise<boolean>;
  /** Optional pack builder for push (host-side). Default empty pack. */
  buildPushPack?: (engine: GitEngine, commands: PushCommand[]) => Promise<Uint8Array>;
}

export class GitRemoteOrchestrator {
  private readonly http: SmartHttpTransport;
  private readonly allowOrigins: string[];
  private readonly connections: ConnectionDefinition[];
  private readonly policies: ConnectionPolicyRule[];
  private readonly remoteUrls: Record<string, string>;
  private readonly remoteConnections: Record<string, string>;
  private readonly readOnly: boolean;
  private readonly onPushApproval?: OrchestratorOptions["onPushApproval"];
  private readonly buildPushPack?: OrchestratorOptions["buildPushPack"];

  constructor(
    private readonly engine: GitEngine,
    opts: OrchestratorOptions = {},
  ) {
    this.http = opts.http ?? new FetchSmartHttp();
    this.allowOrigins = opts.allowOrigins ?? [];
    this.connections = opts.connections ?? [];
    this.policies = opts.policies ?? [];
    this.remoteUrls = opts.remoteUrls ?? {};
    this.remoteConnections = opts.remoteConnections ?? {};
    this.readOnly = !!opts.readOnly;
    this.onPushApproval = opts.onPushApproval;
    this.buildPushPack = opts.buildPushPack;
  }

  /** Host_call name "git" body: Request JSON → Response JSON. */
  async handle(req: GitRequest): Promise<GitResponse> {
    const op = String(req.op || "").toLowerCase();
    if (op === "clone") return this.clone(req);
    if (op === "fetch" || op === "pull") return this.fetch(req);
    if (op === "push") return this.push(req);
    return {
      ok: false,
      code: 2,
      stdout: "",
      stderr: `unknown remote op: ${op}\n`,
    };
  }

  private resolve(req: GitRequest) {
    return resolveGitRemote((req.args ?? {}) as Record<string, unknown>, {
      connections: this.connections,
      policies: this.policies,
      remoteUrls: this.remoteUrls,
      remoteConnections: this.remoteConnections,
    });
  }

  private checkLegacyAllowlist(url: string): GitResponse | null {
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
      return { ok: false, code: 1, stdout: "", stderr: "git: bad remote url\n" };
    }
    return null;
  }

  private async clone(req: GitRequest): Promise<GitResponse> {
    const resolved = this.resolve(req);
    if (!resolved.ok) {
      return { ok: false, code: resolved.code, stdout: "", stderr: resolved.stderr };
    }
    const { binding } = resolved;
    const denied = this.checkLegacyAllowlist(binding.url);
    if (denied) return denied;

    let refs: RefAdvertisement[];
    try {
      refs = await this.http.listRefs(binding.url, binding.auth);
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
      pack = await this.http.fetchPacks(
        binding.url,
        [head.hash],
        [],
        depth,
        binding.auth,
      );
    } catch (e) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: `git: upload-pack failed: ${String(e)}\n`,
      };
    }

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
      stdout: `cloned ${redactRemoteForLog(binding)}\n`,
      stderr: "",
    };
  }

  private async fetch(req: GitRequest): Promise<GitResponse> {
    const r = await this.clone({ ...req, op: "clone" });
    if (!r.ok) return r;
    const fa = await this.engine.run({ op: "fetch.apply" });
    if (!fa.ok) return fa;
    return { ok: true, code: 0, stdout: "fetched\n", stderr: "" };
  }

  /** PR12: push.prepare → host pack stream + PushPacks → push.complete. */
  private async push(req: GitRequest): Promise<GitResponse> {
    if (this.readOnly || this.engine.readOnly) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: "git: push rejected (read-only mount)\n",
      };
    }

    const resolved = this.resolve(req);
    if (!resolved.ok) {
      return { ok: false, code: resolved.code, stdout: "", stderr: resolved.stderr };
    }
    const { binding } = resolved;
    const denied = this.checkLegacyAllowlist(binding.url);
    if (denied) return denied;

    if (binding.pushAction === "block") {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: `git: push blocked by policy for ${binding.connectionRef ?? binding.url}\n`,
      };
    }

    const prep = await this.engine.run({ op: "push.prepare" });
    if (!prep.ok) return prep;

    let commands: PushCommand[] = [];
    try {
      const result = prep.result as { commands?: { name: string; hash: string }[] } | undefined;
      const tips = result?.commands;
      if (Array.isArray(tips) && tips.length) {
        commands = tips.map((t) => ({
          oldHash: "0000000000000000000000000000000000000000",
          newHash: t.hash,
          name: t.name,
        }));
      }
    } catch {
      /* empty */
    }

    // Allow explicit args.commands override
    const args = (req.args ?? {}) as Record<string, unknown>;
    if (Array.isArray(args.commands)) {
      commands = args.commands as PushCommand[];
    }
    if (!commands.length) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: "git: push.prepare produced no commands\n",
      };
    }

    if (binding.pushAction === "require_approval") {
      const allow = this.onPushApproval
        ? await this.onPushApproval({
            url: binding.url,
            connectionRef: binding.connectionRef,
            commands,
          })
        : false;
      if (!allow) {
        return {
          ok: false,
          code: 1,
          stdout: "",
          stderr: "git: push requires approval\n",
        };
      }
    }

    if (!this.http.pushPacks) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: "git: transport does not support push\n",
      };
    }

    const pack = this.buildPushPack
      ? await this.buildPushPack(this.engine, commands)
      : new Uint8Array(0);

    let status;
    try {
      status = await this.http.pushPacks(binding.url, commands, pack, binding.auth);
    } catch (e) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: `git: receive-pack failed: ${String(e)}\n`,
      };
    }

    const complete = await this.engine.run({
      op: "push.complete",
      args: {
        ok: status.ok,
        remote: String(args.remote ?? "origin"),
        branch: commands[0]?.name.replace(/^refs\/heads\//, "") ?? "master",
        hash: commands[0]?.newHash ?? "",
      },
    });
    if (!status.ok) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: `git: remote rejected push: ${status.message ?? "unknown"}\n`,
      };
    }
    if (!complete.ok) return complete;

    return {
      ok: true,
      code: 0,
      stdout: `pushed to ${redactRemoteForLog(binding)}\n`,
      stderr: "",
    };
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
