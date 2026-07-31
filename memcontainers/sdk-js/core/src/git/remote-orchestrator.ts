/**
 * GitRemoteOrchestrator (TS) — GIT.md §7 / PR10a–PR12.
 * Algorithm twin of C orch.c. Engine never dials: ImportPack + apply only.
 */

import type { ConnectionDefinition, ConnectionPolicyRule } from "../types.js";
import type { GitEngine } from "./engine.js";
import type { GitRequest, GitResponse } from "./types.js";
import {
  originAllowed,
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
import {
  defaultProcessPackCache,
  importPackCached,
  uploadPackCacheKey,
  type ImportPackOptions,
  type PackCache,
} from "./pack-cache.js";
import { recordRemoteResult } from "./metrics.js";

export interface OrchestratorOptions extends ResolveRemoteOptions {
  http?: SmartHttpTransport;
  /**
   * Global origin allowlist for **bare URL** remotes (no connection binding).
   * Empty + no connection → fail closed (R32). Connection-bound remotes use
   * `connection.origins` (also fail closed when empty). Fixture tests must pass
   * explicit allowOrigins for bare URLs.
   */
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
  /**
   * Optional pack builder for push. When omitted, non-delete pushes use
   * engine.buildPushPack(newHashes) (libgit2 packbuilder). Delete-only still
   * sends an empty pack.
   */
  buildPushPack?: (engine: GitEngine, commands: PushCommand[]) => Promise<Uint8Array>;
  /**
   * PR13 content-addressed pack cache (shared LLB + interactive).
   * Product handlers (`gitHostCallHandler`) default a process-scoped
   * {@link defaultProcessPackCache}; pass `null` to disable. Direct
   * {@link GitRemoteOrchestrator} construction leaves cache off unless set.
   * Keys are public url + wants/haves/depth only — never credentials.
   */
  packCache?: PackCache | null;
  /** PR13 import limits / chunking. */
  importPack?: ImportPackOptions;
  /**
   * Cone-mode sparse-checkout prefixes applied after clone (engine `sparse-set`).
   * **Cone-only** — not full sparse-checkout pattern parity (no negation beyond
   * the engine's cone template, no non-cone patterns). Also used by gitfs
   * projection when the embedder mounts with the same list.
   */
  sparseCone?: string[];
  /**
   * Host commit identity (K28). Passed through for create-options symmetry;
   * inject lives on {@link GitEngine.run}.
   */
  gitIdentity?: { name: string; email: string };
}

/** Product default: shallow depth=1 unless args override; depth<=0 means full. */
function depthOf(args: Record<string, unknown>): number | undefined {
  if (typeof args.depth === "number" && Number.isFinite(args.depth)) {
    return args.depth > 0 ? Math.floor(args.depth) : undefined;
  }
  return 1;
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
  private readonly packCache?: PackCache;
  private readonly importPackOpts: ImportPackOptions;
  private readonly sparseCone: string[];

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
    // null = explicitly off; undefined = no cache on direct construction.
    this.packCache = opts.packCache === null ? undefined : (opts.packCache ?? undefined);
    this.sparseCone = (opts.sparseCone ?? [])
      .map((p) => p.replace(/^\/+/, "").replace(/\/+$/, ""))
      .filter(Boolean);
    this.importPackOpts = {
      cache: this.packCache ?? opts.importPack?.cache,
      maxPackBytes: opts.importPack?.maxPackBytes,
      chunkBytes: opts.importPack?.chunkBytes,
    };
  }

  private async importBinary(pack: Uint8Array): Promise<void> {
    // Always enforce 64 MiB soft gate + optional chunking/cache (GIT.md §3.3).
    await importPackCached(this.engine, pack, {
      ...this.importPackOpts,
      cache: this.packCache ?? this.importPackOpts.cache,
    });
  }

  /**
   * Resolve pack via download-key index (url+wants+haves+depth), else transport.
   * Credentials never enter the key — only public binding.url.
   */
  private async resolvePack(
    url: string,
    wants: string[],
    haves: string[],
    depth: number | undefined,
    auth: import("../types.js").ConnectionAuth | undefined,
  ): Promise<{ pack: Uint8Array; fromTransport: boolean } | { error: string }> {
    const packKey = uploadPackCacheKey({ url, wants, haves, depth });
    if (this.packCache?.getByKey) {
      const dig = await this.packCache.getByKey(packKey);
      if (dig) {
        const hit = await this.packCache.get(dig);
        if (hit) return { pack: hit, fromTransport: false };
      }
    }
    try {
      const pack = await this.http.fetchPacks(url, wants, haves, depth, auth);
      if (!pack || pack.byteLength === 0) {
        return { error: "git: empty pack from remote\n" };
      }
      if (this.packCache) {
        const dig = await this.packCache.put(pack);
        await this.packCache.putKey?.(packKey, dig);
      }
      return { pack, fromTransport: true };
    } catch (e) {
      return { error: `git: upload-pack failed: ${String(e)}\n` };
    }
  }

  /** After clone.apply: cone sparse-set + checkout (cone-only, not full sparse parity). */
  private async applySparseCone(refName: string): Promise<GitResponse | null> {
    if (!this.sparseCone.length) return null;
    const patterns = this.sparseCone.join("\n");
    const ss = await this.engine.run({
      op: "sparse-set",
      args: { patterns },
    });
    if (!ss.ok) return ss;
    // sparse-set already force-checkouts HEAD into the cone; re-checkout the
    // cloned tip so branch name / worktree stay aligned with clone.apply.
    const co = await this.engine.run({
      op: "checkout",
      args: { name: refName },
    });
    if (!co.ok) {
      // Detached / unborn tip: sparse-set already materialised HEAD; non-fatal.
      const rp = await this.engine.run({
        op: "rev-parse",
        args: { rev: "HEAD" },
      });
      if (!rp.ok) return co;
    }
    return null;
  }

  private pickTip(
    refs: RefAdvertisement[],
    wantRef?: string,
  ): RefAdvertisement | null {
    if (wantRef) {
      const exact =
        refs.find((r) => r.name === wantRef) ||
        refs.find((r) => r.name === `refs/heads/${wantRef}`) ||
        refs.find((r) => r.name === `refs/tags/${wantRef}`) ||
        refs.find((r) => r.hash.toLowerCase() === wantRef.toLowerCase());
      return exact ?? null;
    }
    return (
      refs.find((r) => r.name === "HEAD") ??
      refs.find((r) => r.name.endsWith("/main") || r.name.endsWith("/master")) ??
      refs.find((r) => r.name.startsWith("refs/heads/")) ??
      refs[0] ??
      null
    );
  }

  /** Host_call name "git" body: Request JSON → Response JSON. */
  async handle(req: GitRequest): Promise<GitResponse> {
    const op = String(req.op || "").toLowerCase();
    let resp: GitResponse;
    if (op === "clone") resp = await this.clone(req);
    else if (op === "fetch") resp = await this.fetch(req, { pull: false });
    else if (op === "pull") resp = await this.fetch(req, { pull: true });
    else if (op === "push") resp = await this.push(req);
    else {
      resp = {
        ok: false,
        code: 2,
        stdout: "",
        stderr: `unknown remote op: ${op}\n`,
      };
    }
    // R85–R88: optional in-process counters (redacted; no packs/tokens).
    if (op === "clone" || op === "fetch" || op === "pull" || op === "push") {
      recordRemoteResult(op, !!resp.ok);
    }
    return resp;
  }

  private resolve(req: GitRequest) {
    return resolveGitRemote((req.args ?? {}) as Record<string, unknown>, {
      connections: this.connections,
      policies: this.policies,
      remoteUrls: this.remoteUrls,
      remoteConnections: this.remoteConnections,
    });
  }

  /**
   * R32: bare URL (no connection) requires non-empty allowOrigins and a match.
   * Connection-bound remotes already fail closed on empty connection.origins in
   * resolveGitRemote; optional allowOrigins further intersects when set.
   */
  private checkOriginPolicy(binding: {
    url: string;
    connectionRef?: string;
  }): GitResponse | null {
    const url = binding.url;
    if (binding.connectionRef) {
      if (
        this.allowOrigins.length > 0 &&
        !originAllowed(this.allowOrigins, url)
      ) {
        return {
          ok: false,
          code: 1,
          stdout: "",
          stderr: `git: origin not allowlisted: ${url}\n`,
        };
      }
      return null;
    }
    // Bare URL: empty allowOrigins fails closed (product FetchSmartHttp path).
    if (this.allowOrigins.length === 0) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: `git: origin not allowlisted: ${url}\n`,
      };
    }
    if (!originAllowed(this.allowOrigins, url)) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: `git: origin not allowlisted: ${url}\n`,
      };
    }
    return null;
  }

  /**
   * R37/R94: all advertised heads (+ primary tip if not a head).
   * Prefer one `refs.import` with `args.refs` array; fall back to per-ref loop
   * if the array form fails (older engine / partial multi-want objects).
   */
  private async importAllHeads(
    refs: RefAdvertisement[],
    primaryName: string,
    primaryHash: string,
  ): Promise<GitResponse | null> {
    const toImport = new Map<string, string>();
    for (const r of refs) {
      if (
        r.name.startsWith("refs/heads/") &&
        typeof r.hash === "string" &&
        /^[0-9a-f]{40}$/i.test(r.hash)
      ) {
        toImport.set(r.name, r.hash);
      }
    }
    if (primaryName.startsWith("refs/") && /^[0-9a-f]{40}$/i.test(primaryHash)) {
      toImport.set(primaryName, primaryHash);
    }
    if (!toImport.size && primaryName && primaryHash) {
      toImport.set(primaryName, primaryHash);
    }
    if (!toImport.size) return null;

    const refsArr = [...toImport].map(([name, hash]) => ({ name, hash }));
    const bulk = await this.engine.run({
      op: "refs.import",
      args: { refs: refsArr },
    });
    if (bulk.ok) return null;

    // Loop fallback: primary tip must succeed; other heads best-effort.
    for (const [name, hash] of toImport) {
      const imp = await this.engine.run({
        op: "refs.import",
        args: { name, hash },
      });
      if (!imp.ok) {
        if (name === primaryName) return imp;
      }
    }
    return null;
  }

  /** Unique want OIDs: primary tip + all heads (multi-want fetch). */
  private wantOids(refs: RefAdvertisement[], tipHash: string): string[] {
    const wants = new Set<string>();
    if (/^[0-9a-f]{40}$/i.test(tipHash)) wants.add(tipHash.toLowerCase());
    for (const r of refs) {
      if (
        r.name.startsWith("refs/heads/") &&
        typeof r.hash === "string" &&
        /^[0-9a-f]{40}$/i.test(r.hash)
      ) {
        wants.add(r.hash.toLowerCase());
      }
    }
    return [...wants];
  }

  /** R34: after fetch.apply, FF current branch to remote tip (pull only). */
  private async fastForwardPull(
    tip: RefAdvertisement,
    tipHash: string,
  ): Promise<GitResponse> {
    const head = await this.engine.run({
      op: "rev-parse",
      args: { rev: "HEAD" },
    });
    if (head.ok && head.stdout) {
      const h = head.stdout.trim().split(/\s+/)[0]?.toLowerCase();
      if (h && h === tipHash.toLowerCase()) {
        return {
          ok: true,
          code: 0,
          stdout: "Already up to date.\n",
          stderr: "",
        };
      }
    }
    const ff = await this.engine.run({
      op: "reset",
      args: { rev: tipHash, mode: "ff-only" },
    });
    if (!ff.ok) {
      const err = String(ff.stderr || ff.stdout || "");
      if (err.includes("not fast-forward")) {
        return {
          ok: false,
          code: 1,
          stdout: "",
          stderr: "git: not fast-forward\n",
        };
      }
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: err.includes("git:")
          ? err.endsWith("\n")
            ? err
            : `${err}\n`
          : `git: not fast-forward\n`,
      };
    }
    return {
      ok: true,
      code: 0,
      stdout: `Fast-forward to ${tip.name}\n`,
      stderr: "",
    };
  }

  private async clone(req: GitRequest): Promise<GitResponse> {
    const resolved = this.resolve(req);
    if (!resolved.ok) {
      return { ok: false, code: resolved.code, stdout: "", stderr: resolved.stderr };
    }
    const { binding } = resolved;
    const denied = this.checkOriginPolicy(binding);
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
    const args = (req.args ?? {}) as Record<string, unknown>;
    const wantRef = typeof args.ref === "string" ? args.ref : undefined;
    const head = this.pickTip(refs, wantRef);
    if (!head) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: `git: ref not found: ${wantRef}\n`,
      };
    }

    const depth = depthOf(args);
    const wants = this.wantOids(refs, head.hash);

    const resolvedPack = await this.resolvePack(
      binding.url,
      wants,
      [],
      depth,
      binding.auth,
    );
    if ("error" in resolvedPack) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: resolvedPack.error,
      };
    }
    const pack = resolvedPack.pack;

    // Empty pack never short-circuits to ok:true (dual-host with BEAM orch).
    if (pack.byteLength === 0) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: "git: empty pack from remote\n",
      };
    }

    const init = await this.engine.run({ op: "init" });
    if (!init.ok) return init;

    try {
      await this.importBinary(pack);
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

    const impErr = await this.importAllHeads(refs, refName, head.hash);
    if (impErr) return impErr;

    const apply = await this.engine.run({
      op: "clone.apply",
      args: { head: refName },
    });
    if (!apply.ok) return apply;

    const sparseErr = await this.applySparseCone(refName);
    if (sparseErr) return sparseErr;

    return {
      ok: true,
      code: 0,
      stdout: `cloned ${redactRemoteForLog(binding)}\n`,
      stderr: "",
    };
  }

  private async fetch(
    req: GitRequest,
    opts: { pull?: boolean } = {},
  ): Promise<GitResponse> {
    // Incremental path: no re-init (PR11 critique). Import packs then fetch.apply.
    // Pull = fetch + local FF only (R34).
    const pull = !!opts.pull;
    const resolved = this.resolve(req);
    if (!resolved.ok) {
      return { ok: false, code: resolved.code, stdout: "", stderr: resolved.stderr };
    }
    const { binding } = resolved;
    const denied = this.checkOriginPolicy(binding);
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
    const args = (req.args ?? {}) as Record<string, unknown>;
    const wantRef = typeof args.ref === "string" ? args.ref : undefined;
    const tip = this.pickTip(refs, wantRef);
    if (!tip) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: `git: ref not found: ${wantRef}\n`,
      };
    }

    const depth = depthOf(args);
    // Local haves: tips op when available, else HEAD
    const have: string[] = [];
    const tipsResp = await this.engine.run({ op: "tips" });
    if (tipsResp.ok && tipsResp.result) {
      let tips = tipsResp.result as { name: string; hash: string }[] | string;
      if (typeof tips === "string") {
        try {
          tips = JSON.parse(tips) as { name: string; hash: string }[];
        } catch {
          tips = [];
        }
      }
      if (Array.isArray(tips)) {
        for (const t of tips) {
          if (t.hash && /^[0-9a-f]{40}$/i.test(t.hash)) have.push(t.hash);
        }
      }
    }
    if (!have.length) {
      const head = await this.engine.run({
        op: "rev-parse",
        args: { rev: "HEAD" },
      });
      if (head.ok && head.stdout) {
        const h = head.stdout.trim().split(/\s+/)[0];
        if (h && /^[0-9a-f]{40}$/i.test(h)) have.push(h);
      }
    }

    const wants = this.wantOids(refs, tip.hash);
    const resolvedPack = await this.resolvePack(
      binding.url,
      wants,
      have,
      depth,
      binding.auth,
    );
    if ("error" in resolvedPack) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: resolvedPack.error,
      };
    }

    try {
      await this.importBinary(resolvedPack.pack);
    } catch (e) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: `import_pack: ${String(e)}\n`,
      };
    }

    const refName =
      tip.name === "HEAD"
        ? refs.find((r) => r.hash === tip.hash && r.name.startsWith("refs/"))
            ?.name ?? tip.name
        : tip.name;

    const impErr = await this.importAllHeads(refs, refName, tip.hash);
    if (impErr) return impErr;

    // P0.4: engine requires name+hash (no silent no-op success).
    const fa = await this.engine.run({
      op: "fetch.apply",
      args: {
        name: refName,
        hash: tip.hash,
        remote: typeof args.remote === "string" ? args.remote : "origin",
      },
    });
    if (!fa.ok) return fa;

    if (pull) {
      return this.fastForwardPull(tip, tip.hash);
    }
    return { ok: true, code: 0, stdout: "fetched\n", stderr: "" };
  }

  /** PR12: push.prepare → PushPacks → push.complete. */
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
    const denied = this.checkOriginPolicy(binding);
    if (denied) return denied;

    if (binding.pushAction === "block") {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: `git: push blocked by policy\n`,
      };
    }

    const prep = await this.engine.run({ op: "push.prepare" });
    if (!prep.ok) return prep;

    // Lease: ListRefs before commands (GIT.md §7.3).
    let remoteRefs: RefAdvertisement[] = [];
    try {
      remoteRefs = await this.http.listRefs(binding.url, binding.auth);
    } catch (e) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: `git: list-refs (push lease) failed: ${String(e)}\n`,
      };
    }
    const remoteByName = new Map(remoteRefs.map((r) => [r.name, r.hash]));

    let commands: PushCommand[] = [];
    try {
      let result = prep.result as
        | { commands?: { name: string; hash: string }[] }
        | string
        | undefined;
      if (typeof result === "string") {
        try {
          result = JSON.parse(result) as {
            commands?: { name: string; hash: string }[];
          };
        } catch {
          result = undefined;
        }
      }
      const tips = result?.commands;
      if (Array.isArray(tips) && tips.length) {
        const heads = tips.filter((t) => t.name?.startsWith("refs/heads/"));
        const use = heads.length ? heads : tips;
        commands = use.map((t) => ({
          oldHash:
            remoteByName.get(t.name) ??
            "0000000000000000000000000000000000000000",
          newHash: t.hash,
          name: t.name,
        }));
      }
    } catch {
      /* empty */
    }

    const args = (req.args ?? {}) as Record<string, unknown>;
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

    const zeroOid = "0000000000000000000000000000000000000000";
    const isDeleteOnly = commands.every((c) => c.newHash === zeroOid);
    let pack: Uint8Array;
    if (this.buildPushPack) {
      pack = await this.buildPushPack(this.engine, commands);
    } else if (isDeleteOnly) {
      pack = new Uint8Array(0);
    } else {
      const oids = [
        ...new Set(
          commands
            .map((c) => c.newHash)
            .filter((h) => typeof h === "string" && /^[0-9a-f]{40}$/i.test(h) && h !== zeroOid),
        ),
      ];
      if (!oids.length) {
        return {
          ok: false,
          code: 1,
          stdout: "",
          stderr: "git: push has no new tip oids for pack build\n",
        };
      }
      try {
        pack = await this.engine.buildPushPack(oids);
      } catch (e) {
        return {
          ok: false,
          code: 1,
          stdout: "",
          stderr: `git: pack.build failed: ${String(e)}\n`,
        };
      }
    }
    if (!isDeleteOnly && pack.byteLength === 0) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: "git: empty pack refused for non-delete push\n",
      };
    }
    if (
      !isDeleteOnly &&
      (pack.byteLength < 4 ||
        pack[0] !== 0x50 ||
        pack[1] !== 0x41 ||
        pack[2] !== 0x43 ||
        pack[3] !== 0x4b)
    ) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: "git: push pack missing PACK magic\n",
      };
    }

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

/**
 * MapHostCall handler factory: body is Request JSON bytes.
 * Product default: process-scoped pack cache unless `opts.packCache` is set
 * (`null` disables). Direct {@link GitRemoteOrchestrator} does not auto-enable.
 */
export function gitHostCallHandler(
  engine: GitEngine,
  opts?: OrchestratorOptions,
): (args: string) => Promise<string> {
  const raw = opts?.packCache;
  const packCache =
    raw === null ? undefined : (raw ?? defaultProcessPackCache());
  const orch = new GitRemoteOrchestrator(engine, {
    ...opts,
    packCache,
  });
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
