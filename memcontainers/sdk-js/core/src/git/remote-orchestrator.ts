/**
 * GitRemoteOrchestrator — host-mediated git remotes (GIT.md §7).
 *
 * ## Role
 *
 * This module is the **JS product twin** of the BEAM / C remote orchestrator.
 * Guests never dial the network. The libgit2 engine stays pure: it only runs
 * local ops, imports pack bytes the host already fetched, and applies ref tips.
 * All smart-HTTP (list-refs, upload-pack, receive-pack) runs here on the host,
 * then packs and tips are handed back into the engine.
 *
 * ## Entry path (CAP_NET + host_call)
 *
 * Product remotes enter via `mc_sys_host_call` name `"git"`, gated by kernel
 * **CAP_NET**. {@link gitHostCallHandler} is the MapHostCall factory: decode
 * Request JSON → demux engine → {@link GitRemoteOrchestrator.handle} → Response
 * JSON. Mount/ctl alone cannot dial; ctl remote ops refuse. Dialing outside
 * host_call also breaks snapshot quiescence (inflight_egress).
 *
 * ## Engine never dials
 *
 * Flow for clone/fetch/pull: resolve public locator + host credentials → origin
 * policy → transport list-refs / fetch packs → content-addressed pack cache →
 * `importPack` / `importPackCached` → engine `refs.import` + `clone.apply` /
 * `fetch.apply`. Push: `push.prepare` → lease list-refs → build pack →
 * transport push → `push.complete`. Credentials splice only in smart-HTTP
 * headers (see {@link resolveGitRemote}); guest body secrets are rejected.
 *
 * ## Multi-mount demux (K21 / R63–R65)
 *
 * One engine per mount path (single-writer). Multi-mount hosts pass a
 * {@link GitEngineMountMap}; each engine gets its own orchestrator instance
 * (its own remote queue). Request `args.mount` / top-level `mount` selects
 * the engine; remounting gitfs at a live path fails closed elsewhere.
 *
 * ## Ops
 *
 * | Op | Host path |
 * |----|-----------|
 * | `clone` | list-refs → pack → init → import → clone.apply → tracking + sparse |
 * | `fetch` | list-refs → pack (stream) → import → fetch.apply |
 * | `pull` | fetch + local FF-only to remote tip |
 * | `push` | prepare → lease → pack → receive-pack → complete |
 * | `submodule` | host-mediated nested clone under super worktree |
 *
 * Dual-host: BEAM orch owns server remotes; this file is the browser/Node
 * reference algorithm — keep semantic tables in `connections.ts` aligned.
 */

import {
  ALGORITHM_STEPS,
  DEFAULT_CLONE_DEPTH,
  DEFAULT_FETCH_DEPTH,
  stderrLine,
} from "@mc/contracts/git";
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
  DEFAULT_MAX_PACK_BYTES,
  importPackCached,
  productDefaultPackCache,
  uploadPackCacheKey,
  type ImportPackOptions,
  type PackCache,
} from "./pack-cache.js";
import {
  recordRemoteResult,
  redactOrigin,
  type RemoteResultMeta,
} from "./metrics.js";

// ---------------------------------------------------------------------------
// Options & module-level helpers
// ---------------------------------------------------------------------------

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
   * Content-addressed pack cache (shared LLB + interactive).
   * Product handlers (`gitHostCallHandler`) default a **fresh** per-handler
   * Memory cache (multi-tenant safer). Opt into process-shared cache via
   * `MC_GIT_PACK_CACHE_SHARED=1` (then Memory, or Disk when `MC_GIT_PACK_CACHE`
   * is set) or pass `packCache: defaultProcessPackCache()` explicitly.
   * Pass `null` to disable. Direct {@link GitRemoteOrchestrator} construction
   * leaves cache off unless set.
   * Keys are public url + wants/haves/depth only — never credentials.
   */
  packCache?: PackCache | null;
  /** Import size limits / chunking for {@link importPackCached}. */
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
  identity?: { name: string; email: string };
  /**
   * When true (or env `MC_GIT_ORCH_TRACE=1`), record algorithm step ids from
   * contracts/git.kdl on the last handle() for dual-host golden comparison.
   */
  traceSteps?: boolean;
}

/**
 * Depth from args. Explicit depth<=0 means full history.
 * When omitted: clone defaults to DEFAULT_CLONE_DEPTH (1); fetch/pull full
 * (DEFAULT_FETCH_DEPTH 0) — contracts/git.kdl dual-host defaults.
 */
function depthOf(
  args: Record<string, unknown>,
  op: "clone" | "fetch" | "pull" = "clone",
): number | undefined {
  if (typeof args.depth === "number" && Number.isFinite(args.depth)) {
    return args.depth > 0 ? Math.floor(args.depth) : undefined;
  }
  if (op === "clone") {
    return DEFAULT_CLONE_DEPTH > 0 ? DEFAULT_CLONE_DEPTH : undefined;
  }
  // fetch/pull: default full history (DEFAULT_FETCH_DEPTH 0)
  return DEFAULT_FETCH_DEPTH > 0 ? DEFAULT_FETCH_DEPTH : undefined;
}

/**
 * Optional partial-clone filter (R36): `blob:none`, `tree:0`, etc.
 * Sent on upload-pack when present. Engine still needs blobs later for
 * materialization — filter only shrinks the initial pack transfer.
 */
function filterOf(args: Record<string, unknown>): string | undefined {
  if (typeof args.filter === "string") {
    const f = args.filter.trim();
    if (f.length > 0 && f.length <= 128 && !/[\r\n\0]/.test(f)) return f;
  }
  return undefined;
}

/** All-zero OID: create/delete lease sentinel on receive-pack commands. */
const ZERO_OID = "0000000000000000000000000000000000000000";

/** Normalize delete target names to full refs (refs/heads/…). */
function deleteRefNames(
  args: Record<string, unknown>,
  prepared: PushCommand[],
): string[] | null {
  const del = args.delete;
  if (del === undefined || del === false || del === null) return null;
  const toFull = (n: string) =>
    n.startsWith("refs/") ? n : `refs/heads/${n.replace(/^heads\//, "")}`;
  if (del === true || del === "true") {
    const names = prepared.map((c) => c.name).filter(Boolean);
    return names.length ? names.map(toFull) : null;
  }
  if (typeof del === "string" && del.trim()) return [toFull(del.trim())];
  if (Array.isArray(del)) {
    const names = del
      .filter((n): n is string => typeof n === "string" && n.trim().length > 0)
      .map((n) => toFull(n.trim()));
    return names.length ? names : null;
  }
  return null;
}

// ---------------------------------------------------------------------------
// GitRemoteOrchestrator — one instance per engine / mount
// ---------------------------------------------------------------------------

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
  /**
   * Per-orchestrator (per-engine / per-mount) remote single-flight queue.
   * Concurrent host_call remotes must not overlap HTTP + apply — matches BEAM
   * one-inflight-remote-per-engine. Local engine.run is already serial via
   * GitBridge; remotes need their own chain so listRefs/fetchPacks cannot race.
   */
  private remoteQueue: Promise<unknown> = Promise.resolve();
  /** Last pack size / origin for in-process metrics (reset each remote op). */
  private metricsPackBytes = 0;
  private metricsOriginRedacted = "";
  private metricsAllowlistDeny = false;
  private readonly traceEnabled: boolean;
  /** Last remote op step ids when {@link OrchestratorOptions.traceSteps} is on. */
  lastTrace: string[] = [];

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
    this.traceEnabled =
      !!opts.traceSteps ||
      (typeof process !== "undefined" &&
        process.env?.MC_GIT_ORCH_TRACE === "1");
    this.onPushApproval = opts.onPushApproval;
    this.buildPushPack = opts.buildPushPack;
    // null = explicitly off; undefined = no cache on direct construction.
    this.packCache = opts.packCache === null ? undefined : (opts.packCache ?? undefined);
    // Prefer explicit orch opts; else inherit engine load-time cone (multi-mount).
    const coneSrc =
      opts.sparseCone !== undefined ? opts.sparseCone : (engine.sparseCone ?? []);
    this.sparseCone = coneSrc
      .map((p) => p.replace(/^\/+/, "").replace(/\/+$/, ""))
      .filter(Boolean);
    this.importPackOpts = {
      cache: this.packCache ?? opts.importPack?.cache,
      maxPackBytes: opts.importPack?.maxPackBytes,
      chunkBytes: opts.importPack?.chunkBytes,
    };
  }

  // --- Pack import & cache -------------------------------------------------

  private maxPackBytes(): number {
    return this.importPackOpts.maxPackBytes === undefined
      ? DEFAULT_MAX_PACK_BYTES
      : this.importPackOpts.maxPackBytes;
  }

  /**
   * Chunked import into the engine (GIT.md §3.3): 64 MiB soft gate +
   * `chunkBytes` slices via {@link importPackCached} — never one giant frame only.
   */
  private async importBinary(pack: Uint8Array): Promise<void> {
    await importPackCached(this.engine, pack, {
      ...this.importPackOpts,
      cache: this.packCache ?? this.importPackOpts.cache,
    });
  }

  /**
   * Resolve pack via download-key index (url+wants+haves+depth[+filter]), else transport.
   * Credentials never enter the key — only public binding.url.
   *
   * Transport path uses streamed body reads with maxPackBytes fail-closed
   * (default 64 MiB). When `streamIntoEngine` is true (fetch/pull — repo already
   * open), pack-aligned slices are piped to `engine.importPack` via
   * `onPackChunk` as the body arrives. Clone keeps `streamIntoEngine` false so
   * download can finish before `init`, then {@link importBinary} chunks in.
   */
  private async resolvePack(
    url: string,
    wants: string[],
    haves: string[],
    depth: number | undefined,
    auth: import("../types.js").ConnectionAuth | undefined,
    filter?: string,
    streamIntoEngine = false,
  ): Promise<
    | { pack: Uint8Array; fromTransport: boolean; imported: boolean }
    | { error: string }
  > {
    const packKey = uploadPackCacheKey({ url, wants, haves, depth, filter });
    if (this.packCache?.getByKey) {
      const dig = await this.packCache.getByKey(packKey);
      if (dig) {
        const hit = await this.packCache.get(dig);
        if (hit) return { pack: hit, fromTransport: false, imported: false };
      }
    }
    const max = this.maxPackBytes();
    try {
      let streamed = false;
      const pack = await this.http.fetchPacks(
        url,
        wants,
        haves,
        depth,
        auth,
        filter,
        {
          maxBytes: max,
          onPackChunk: streamIntoEngine
            ? async (chunk) => {
                streamed = true;
                await this.engine.importPack(chunk, { final: false });
              }
            : undefined,
        },
      );
      if (!pack || pack.byteLength === 0) {
        return { error: stderrLine("empty_pack", "from remote") };
      }
      if (streamed) {
        await this.engine.importPack(new Uint8Array(0), { final: true });
      }
      if (this.packCache) {
        const dig = await this.packCache.put(pack);
        await this.packCache.putKey?.(packKey, dig);
      }
      return { pack, fromTransport: true, imported: streamed };
    } catch (e) {
      return { error: `git: upload-pack failed: ${String(e)}\n` };
    }
  }

  // --- Sparse cone (post-clone) --------------------------------------------

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

  /** Pick advertised tip: exact ref/hash, else HEAD → main/master → first head. */
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

  // --- Queue / single-writer entry -----------------------------------------

  /**
   * Host_call name `"git"` body: Request JSON → Response JSON.
   * Serialized per orchestrator: parallel callers queue FIFO; only one remote
   * (HTTP + apply) runs at a time on this engine/mount.
   */
  async handle(req: GitRequest): Promise<GitResponse> {
    const run = this.remoteQueue.then(
      () => this.handleUnlocked(req),
      () => this.handleUnlocked(req),
    ) as Promise<GitResponse>;
    this.remoteQueue = run.then(
      () => undefined,
      () => undefined,
    );
    return run;
  }

  private async handleUnlocked(req: GitRequest): Promise<GitResponse> {
    const op = String(req.op || "").toLowerCase();
    // Per-op metric labels only (never secrets / tokens).
    this.metricsPackBytes = 0;
    this.metricsOriginRedacted = "";
    this.metricsAllowlistDeny = false;
    this.lastTrace = [];
    const t0 = Date.now();
    let resp: GitResponse;
    if (op === "clone") resp = await this.clone(req);
    else if (op === "fetch") resp = await this.fetch(req, { pull: false });
    else if (op === "pull") resp = await this.fetch(req, { pull: true });
    else if (op === "push") resp = await this.push(req);
    else if (op === "submodule") resp = await this.submodule(req);
    else {
      resp = {
        ok: false,
        code: 2,
        stdout: "",
        stderr: `unknown remote op: ${op}\n`,
      };
    }
    // Catalog step order from contracts/git.kdl when tracing (success path).
    if (this.traceEnabled && resp.ok) {
      const key = op === "pull" ? "fetch" : op;
      const steps = (ALGORITHM_STEPS as Record<string, readonly string[]>)[key];
      if (steps) this.lastTrace = [...steps];
    }
    // In-process counters: duration, pack bytes, redacted origin, allowlist denials.
    if (op === "clone" || op === "fetch" || op === "pull" || op === "push") {
      const meta: RemoteResultMeta = {
        duration_ms: Math.max(0, Date.now() - t0),
        pack_bytes: this.metricsPackBytes,
        origin_redacted: this.metricsOriginRedacted,
        allowlist_deny: this.metricsAllowlistDeny,
      };
      recordRemoteResult(op, !!resp.ok, meta);
    }
    return resp;
  }

  private noteMetricsOrigin(url: string): void {
    if (typeof url === "string" && url) {
      this.metricsOriginRedacted = redactOrigin(url);
    }
  }

  private noteMetricsPack(pack: Uint8Array | ArrayBuffer | null | undefined): void {
    if (!pack) return;
    const n =
      pack instanceof Uint8Array
        ? pack.byteLength
        : pack instanceof ArrayBuffer
          ? pack.byteLength
          : 0;
    if (n > 0) this.metricsPackBytes = n;
  }

  // --- Remote binding resolution & origin policy ---------------------------

  /**
   * Resolve public locator + host credential + pushAction from policies.
   * Guest body secrets (token/auth/…) are rejected in {@link resolveGitRemote}.
   * Dual-host: BEAM must use host-owned auth/opts only — see connections.ts table.
   *
   * When only `remote` (or bare fetch/pull/push after clone) is given, fill
   * `url` / `connection` from engine config (`remote.<name>.url` / `.agentos`)
   * written by {@link configureCloneRemote}.
   */
  private async resolve(req: GitRequest) {
    const op = String(req.op ?? "").toLowerCase();
    const args: Record<string, unknown> = {
      ...((req.args ?? {}) as Record<string, unknown>),
    };
    await this.fillRemoteArgsFromConfig(op, args);
    return resolveGitRemote(args, {
      connections: this.connections,
      policies: this.policies,
      remoteUrls: this.remoteUrls,
      remoteConnections: this.remoteConnections,
    });
  }

  /** config get → trimmed stdout or null. */
  private async configGet(key: string): Promise<string | null> {
    const r = await this.engine.run({
      op: "config",
      args: { action: "get", key },
    });
    if (!r.ok) return null;
    const v = String(r.stdout ?? "").trim();
    return v.length > 0 ? v : null;
  }

  /**
   * After clone, fill empty locator from `remote.<name>.url` (+ optional
   * `remote.<name>.agentos`). For fetch/pull/push with no url/remote/connection,
   * default to `origin` so `git pull` works without re-passing the URL.
   */
  private async fillRemoteArgsFromConfig(
    op: string,
    args: Record<string, unknown>,
  ): Promise<void> {
    const hasUrl = typeof args.url === "string" && args.url.trim().length > 0;
    if (hasUrl) return;

    let remoteName =
      typeof args.remote === "string" && args.remote.trim()
        ? args.remote.trim()
        : undefined;

    if (
      !remoteName &&
      !args.connection &&
      !args.agentos &&
      (op === "fetch" || op === "pull" || op === "push")
    ) {
      remoteName = "origin";
      args.remote = remoteName;
    }
    if (!remoteName) return;

    // Host-provided remoteUrls win; only consult engine config when missing.
    if (!this.remoteUrls[remoteName]) {
      const url = await this.configGet(`remote.${remoteName}.url`);
      if (url) args.url = url;
    }
    if (
      !args.connection &&
      !args.agentos &&
      !this.remoteConnections[remoteName]
    ) {
      const agentos = await this.configGet(`remote.${remoteName}.agentos`);
      if (agentos) args.connection = agentos;
    }
  }

  /**
   * After successful clone.apply — set remote.origin.url (public), optional
   * remote.origin.agentos, branch.<name>.remote + .merge, and remote-tracking
   * ref so subsequent fetch/pull can use tracking without manual setup.
   */
  private async configureCloneRemote(
    binding: { url: string; connectionRef?: string },
    refName: string,
    tipHash: string,
  ): Promise<GitResponse | null> {
    const remoteName = "origin";

    const add = await this.engine.run({
      op: "remote",
      args: { action: "add", name: remoteName, url: binding.url },
    });
    if (!add.ok) {
      // Re-clone / pre-existing remote: force public URL via config.
      const setUrl = await this.engine.run({
        op: "config",
        args: {
          action: "set",
          key: `remote.${remoteName}.url`,
          value: binding.url,
        },
      });
      if (!setUrl.ok) return setUrl;
    }

    if (binding.connectionRef) {
      const agentos = await this.engine.run({
        op: "config",
        args: {
          action: "set",
          key: `remote.${remoteName}.agentos`,
          value: binding.connectionRef,
        },
      });
      if (!agentos.ok) return agentos;
    }

    let short = "main";
    let merge = refName;
    if (refName.startsWith("refs/heads/")) {
      short = refName.slice("refs/heads/".length);
      merge = refName;
    } else if (refName.startsWith("refs/")) {
      const slash = refName.lastIndexOf("/");
      short = slash >= 0 ? refName.slice(slash + 1) : refName;
      merge = refName;
    } else {
      short = refName || "main";
      merge = `refs/heads/${short}`;
    }

    for (const [key, value] of [
      [`branch.${short}.remote`, remoteName],
      [`branch.${short}.merge`, merge],
    ] as const) {
      const cfg = await this.engine.run({
        op: "config",
        args: { action: "set", key, value },
      });
      if (!cfg.ok) return cfg;
    }

    // Remote-tracking tip (parity with fetch.apply) so pull/status see origin/*.
    if (tipHash && /^[0-9a-f]{40}$/i.test(tipHash) && short) {
      const tr = await this.engine.run({
        op: "refs.import",
        args: {
          name: `refs/remotes/${remoteName}/${short}`,
          hash: tipHash,
        },
      });
      if (!tr.ok) return tr;
    }
    return null;
  }

  /**
   * Origin allowlist (R32): bare URL (no connection) requires non-empty
   * `allowOrigins` and a match. Connection-bound remotes already fail closed on
   * empty `connection.origins` in resolveGitRemote; optional allowOrigins
   * further intersects when set.
   */
  private checkOriginPolicy(binding: {
    url: string;
    connectionRef?: string;
  }): GitResponse | null {
    const url = binding.url;
    this.noteMetricsOrigin(url);
    if (binding.connectionRef) {
      if (
        this.allowOrigins.length > 0 &&
        !originAllowed(this.allowOrigins, url)
      ) {
        this.metricsAllowlistDeny = true;
        return {
          ok: false,
          code: 1,
          stdout: "",
          // Catalog prefix only (contracts/git.kdl) — no URL suffix (dual-host parity).
          stderr: stderrLine("origin_not_allowlisted"),
        };
      }
      return null;
    }
    // Bare URL: empty allowOrigins fails closed (product FetchSmartHttp path).
    if (this.allowOrigins.length === 0) {
      this.metricsAllowlistDeny = true;
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: stderrLine("origin_not_allowlisted"),
      };
    }
    if (!originAllowed(this.allowOrigins, url)) {
      this.metricsAllowlistDeny = true;
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: stderrLine("origin_not_allowlisted"),
      };
    }
    return null;
  }

  // --- Ref import helpers (clone / fetch) ----------------------------------

  /**
   * Import all advertised heads (+ primary tip if not a head).
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

  /**
   * After fetch.apply: fast-forward current branch to remote tip (pull only).
   * Diverged histories fail closed with `not fast-forward` (R34).
   */
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
          stderr: stderrLine("not_fast_forward"),
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
          : stderrLine("not_fast_forward"),
      };
    }
    return {
      ok: true,
      code: 0,
      stdout: `Fast-forward to ${tip.name}\n`,
      stderr: "",
    };
  }

  // --- Submodule (host-mediated nested clone) ------------------------------

  /**
   * Host-mediated submodule update (engine purity: no dial from `engine.run`).
   * 1. Parse .gitmodules via engine list
   * 2. For each entry: same connection policy on URL → list-refs + fetch pack
   * 3. Nested ge_open at submodule path under super worktree → init/import/apply
   * 4. Nested files appear in super gitfs (same MEMFS)
   */
  private async submodule(req: GitRequest): Promise<GitResponse> {
    const args = (req.args ?? {}) as Record<string, unknown>;
    let action =
      typeof args.action === "string" && args.action.trim()
        ? args.action.trim().toLowerCase()
        : "update";
    if (action === "list" || action === "status") {
      // Convenience: orch may relay list; engine does the parse.
      return this.engine.run({ op: "submodule", args: { action } });
    }
    if (action !== "update" && action !== "init" && action !== "clone") {
      return {
        ok: false,
        code: 2,
        stdout: "",
        stderr: `git: submodule action not supported via orch: ${action}\n`,
      };
    }

    const list = await this.engine.run({
      op: "submodule",
      args: { action: "list" },
    });
    if (!list.ok) {
      return {
        ok: false,
        code: list.code || 1,
        stdout: "",
        stderr: String(list.stderr || "git: submodule list failed\n"),
      };
    }
    const result = list.result as { submodules?: unknown } | undefined;
    const rawSubs = Array.isArray(result?.submodules) ? result!.submodules! : [];
    type SubEntry = { name?: string; path?: string; url?: string; hash?: string };
    const subs: SubEntry[] = rawSubs.filter(
      (s): s is SubEntry => !!s && typeof s === "object",
    ) as SubEntry[];

    const onlyPath =
      typeof args.path === "string" && args.path.trim()
        ? normalizeSubPath(args.path.trim())
        : undefined;
    if (onlyPath === null) {
      return {
        ok: false,
        code: 2,
        stdout: "",
        stderr: "git: submodule path invalid\n",
      };
    }

    const targets = onlyPath
      ? subs.filter((s) => normalizeSubPath(String(s.path || "")) === onlyPath)
      : subs;

    if (targets.length === 0) {
      return {
        ok: true,
        code: 0,
        stdout: "no submodules to update\n",
        stderr: "",
        result: { updated: [] },
      };
    }

    const updated: string[] = [];
    for (const sub of targets) {
      const path = normalizeSubPath(String(sub.path || ""));
      if (!path) {
        return {
          ok: false,
          code: 1,
          stdout: "",
          stderr: `git: submodule ${JSON.stringify(sub.name || "?")} missing path\n`,
        };
      }
      const url = typeof sub.url === "string" ? sub.url.trim() : "";
      if (!url) {
        return {
          ok: false,
          code: 1,
          stdout: "",
          stderr: `git: submodule ${path} missing url in .gitmodules\n`,
        };
      }

      // Same connection policy as bare clone (origin allowlist / connections).
      const resolved = await this.resolve({
        op: "clone",
        args: { url },
      });
      if (!resolved.ok) {
        return {
          ok: false,
          code: resolved.code,
          stdout: "",
          stderr: `git: submodule ${path}: ${resolved.stderr}`,
        };
      }
      const { binding } = resolved;
      const denied = this.checkOriginPolicy(binding);
      if (denied) {
        return {
          ok: false,
          code: denied.code,
          stdout: "",
          stderr: `git: submodule ${path}: ${denied.stderr}`,
        };
      }

      let refs: RefAdvertisement[];
      try {
        refs = await this.http.listRefs(binding.url, binding.auth);
      } catch (e) {
        return {
          ok: false,
          code: 1,
          stdout: "",
          stderr: `git: submodule ${path}: list-refs failed: ${String(e)}\n`,
        };
      }
      if (!refs.length) {
        return {
          ok: false,
          code: 1,
          stdout: "",
          stderr: `git: submodule ${path}: no refs in advertisement\n`,
        };
      }

      // Prefer gitlink hash when advertised; else default tip.
      const wantHash =
        typeof sub.hash === "string" && /^[0-9a-f]{40}$/i.test(sub.hash)
          ? sub.hash.toLowerCase()
          : undefined;
      let head = this.pickTip(refs, undefined);
      if (wantHash) {
        const byHash = refs.find((r) => r.hash.toLowerCase() === wantHash);
        if (byHash) head = byHash;
        else {
          // Pack may still contain the gitlink commit even if not advertised as tip.
          head = {
            name: "HEAD",
            hash: wantHash,
          };
        }
      }
      if (!head) {
        return {
          ok: false,
          code: 1,
          stdout: "",
          stderr: `git: submodule ${path}: no tip to clone\n`,
        };
      }

      const wants = this.wantOids(refs, head.hash);
      // When cloning a non-advertised gitlink, ensure want includes it.
      if (wantHash && !wants.includes(wantHash)) wants.unshift(wantHash);

      const resolvedPack = await this.resolvePack(
        binding.url,
        wants,
        [],
        1,
        binding.auth,
      );
      if ("error" in resolvedPack) {
        return {
          ok: false,
          code: 1,
          stdout: "",
          stderr: `git: submodule ${path}: ${resolvedPack.error}`,
        };
      }
      const pack = resolvedPack.pack;
      if (pack.byteLength === 0) {
        return {
          ok: false,
          code: 1,
          stdout: "",
          // Compound message; still anchored on contract empty_pack prefix.
          stderr: stderrLine("empty_pack", `from remote (submodule ${path})`),
        };
      }

      const applyErr = await this.applyNestedClone(path, pack, refs, head, wantHash);
      if (applyErr) {
        return {
          ok: false,
          code: applyErr.code || 1,
          stdout: "",
          stderr: `git: submodule ${path}: ${applyErr.stderr || "apply failed\n"}`,
        };
      }
      updated.push(path);
    }

    return {
      ok: true,
      code: 0,
      stdout: `updated ${updated.length} submodule(s)\n`,
      stderr: "",
      result: { updated },
    };
  }

  /**
   * Nested engine under super worktree path: init (if needed) + import + checkout.
   * Holds serial only for apply (network already done). Files land in super MEMFS.
   */
  private async applyNestedClone(
    relPath: string,
    pack: Uint8Array,
    refs: RefAdvertisement[],
    head: RefAdvertisement,
    wantHash?: string,
  ): Promise<GitResponse | null> {
    const bridge = this.engine.bridge;
    const abs = bridge.abs(relPath);
    return bridge.serial(() => {
      let eng = 0;
      try {
        eng = bridge.openAt(abs);
        // ge_open opens existing repo if present; only init when empty.
        const st = bridge.runAt(eng, { op: "status" });
        if (!st.ok) {
          const init = bridge.runAt(eng, { op: "init" });
          if (!init.ok) return init;
        }

        // Chunked import (same 64 MiB gate path as importBinary, but nested eng).
        const chunkSize = 1024 * 1024;
        if (pack.byteLength === 0) {
          return {
            ok: false,
            code: 1,
            stdout: "",
            stderr: stderrLine("empty_pack"),
          };
        }
        for (let off = 0; off < pack.byteLength; off += chunkSize) {
          const slice = pack.subarray(off, Math.min(off + chunkSize, pack.byteLength));
          const final = off + slice.byteLength >= pack.byteLength;
          bridge.importPackAt(eng, slice, final);
        }

        const refName =
          head.name === "HEAD"
            ? refs.find((r) => r.hash === head.hash && r.name.startsWith("refs/"))
                ?.name ?? "refs/heads/master"
            : head.name;

        const imp = bridge.runAt(eng, {
          op: "refs.import",
          args: { name: refName, hash: head.hash },
        });
        if (!imp.ok) return imp;

        // Import other heads (best-effort) for richer nested repo.
        for (const r of refs) {
          if (!r.name.startsWith("refs/heads/") || r.name === refName) continue;
          bridge.runAt(eng, {
            op: "refs.import",
            args: { name: r.name, hash: r.hash },
          });
        }

        const apply = bridge.runAt(eng, {
          op: "clone.apply",
          args: { head: refName },
        });
        if (!apply.ok) return apply;

        // Detach to exact gitlink when provided and differs from branch tip name.
        if (wantHash && wantHash !== head.hash.toLowerCase()) {
          const co = bridge.runAt(eng, {
            op: "checkout",
            args: { name: wantHash },
          });
          if (!co.ok) {
            // Try reset hard to OID.
            const rst = bridge.runAt(eng, {
              op: "reset",
              args: { rev: wantHash, mode: "hard" },
            });
            if (!rst.ok) return rst;
          }
        } else if (wantHash) {
          // Ensure worktree matches gitlink even when hash was used as tip.
          const rev = bridge.runAt(eng, {
            op: "rev-parse",
            args: { rev: "HEAD" },
          });
          const cur = String(rev.stdout || "")
            .trim()
            .split(/\s+/)[0]
            ?.toLowerCase();
          if (cur && cur !== wantHash) {
            const rst = bridge.runAt(eng, {
              op: "reset",
              args: { rev: wantHash, mode: "hard" },
            });
            if (!rst.ok) return rst;
          }
        }

        return null;
      } catch (e) {
        return {
          ok: false,
          code: 1,
          stdout: "",
          stderr: `${String(e)}\n`,
        };
      } finally {
        if (eng) bridge.closeAt(eng);
      }
    });
  }

  // --- Clone ---------------------------------------------------------------

  /**
   * Fresh repo: list-refs → pack (buffered) → init → import → clone.apply →
   * tracking config + optional sparse cone. No re-use of an existing object DB.
   */
  private async clone(req: GitRequest): Promise<GitResponse> {
    const resolved = await this.resolve(req);
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

    const depth = depthOf(args, "clone");
    const filter = filterOf(args);
    const wants = this.wantOids(refs, head.hash);

    const resolvedPack = await this.resolvePack(
      binding.url,
      wants,
      [],
      depth,
      binding.auth,
      filter,
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
    this.noteMetricsPack(pack);

    // Empty pack never short-circuits to ok:true (dual-host with BEAM orch).
    if (pack.byteLength === 0) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: stderrLine("empty_pack", "from remote"),
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

    // Remote + branch tracking so pull works without re-passing URL.
    const trackErr = await this.configureCloneRemote(
      binding,
      refName,
      head.hash,
    );
    if (trackErr) return trackErr;

    const sparseErr = await this.applySparseCone(refName);
    if (sparseErr) return sparseErr;

    return {
      ok: true,
      code: 0,
      stdout: `cloned ${redactRemoteForLog(binding)}\n`,
      stderr: "",
    };
  }

  // --- Fetch / pull --------------------------------------------------------

  /**
   * Incremental path: no re-init. Import packs then `fetch.apply`.
   * Pull = fetch + local FF-only to remote tip (R34).
   */
  private async fetch(
    req: GitRequest,
    opts: { pull?: boolean } = {},
  ): Promise<GitResponse> {
    const pull = !!opts.pull;
    const resolved = await this.resolve(req);
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

    const depth = depthOf(args, "fetch");
    const filter = filterOf(args);
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
    // Stream pack into engine while downloading (repo already exists).
    const resolvedPack = await this.resolvePack(
      binding.url,
      wants,
      have,
      depth,
      binding.auth,
      filter,
      true,
    );
    if ("error" in resolvedPack) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: resolvedPack.error,
      };
    }

    if (!resolvedPack.imported) {
      this.noteMetricsPack(resolvedPack.pack);
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
    }

    const refName =
      tip.name === "HEAD"
        ? refs.find((r) => r.hash === tip.hash && r.name.startsWith("refs/"))
            ?.name ?? tip.name
        : tip.name;

    const impErr = await this.importAllHeads(refs, refName, tip.hash);
    if (impErr) return impErr;

    // Engine requires name+hash on fetch.apply (no silent no-op success).
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

  // --- Push ----------------------------------------------------------------

  /**
   * Push path: `push.prepare` → list-refs lease → build pack → receive-pack →
   * `push.complete`. Honors read-only mounts, policy `block` / `require_approval`,
   * and delete-only empty packs.
   */
  private async push(req: GitRequest): Promise<GitResponse> {
    if (this.readOnly || this.engine.readOnly) {
      return {
        ok: false,
        code: 1,
        stdout: "",
        stderr: stderrLine("push_read_only"),
      };
    }

    const resolved = await this.resolve(req);
    if (!resolved.ok) {
      return { ok: false, code: resolved.code, stdout: "", stderr: resolved.stderr };
    }
    const { binding } = resolved;
    const denied = this.checkOriginPolicy(binding);
    if (denied) return denied;

    // pushAction from ConnectionPolicyRule set (most restrictive wins).
    // block → fail before dial; require_approval gated after prepare has commands.
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
    // args.delete → zero newHash commands + empty pack (delete-only receive-pack).
    const delNames = deleteRefNames(args, commands);
    if (delNames) {
      commands = delNames.map((name) => ({
        oldHash: remoteByName.get(name) ?? ZERO_OID,
        newHash: ZERO_OID,
        name,
      }));
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

    const zeroOid = ZERO_OID;
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
      // Remote lease oldHash tips as haves for thin pack.
      const haves = [
        ...new Set(
          commands
            .map((c) => c.oldHash)
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
        pack = await this.engine.buildPushPack(oids, haves);
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
        stderr: stderrLine("empty_pack", "refused for non-delete push"),
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

// ---------------------------------------------------------------------------
// Multi-mount demux & host_call factory
// ---------------------------------------------------------------------------

/**
 * Multi-engine map for host_call `"git"` demux (K21 / R63–R65).
 * Each mount path owns a distinct {@link GitEngine} (single-writer per engine).
 */
export interface GitEngineMountMap {
  /** Engines keyed by absolute mount path (e.g. `/workspace/repo`). */
  engines: Map<string, GitEngine> | Record<string, GitEngine>;
  /**
   * Used when the request omits `args.mount` / top-level `mount`.
   * Required when more than one engine is registered.
   */
  defaultMount?: string;
}

/** Single engine or multi-mount map for {@link gitHostCallHandler}. */
export type GitHostCallEngines = GitEngine | GitEngineMountMap;

function isGitEngineMountMap(v: GitHostCallEngines): v is GitEngineMountMap {
  return (
    !!v &&
    typeof v === "object" &&
    "engines" in v &&
    (v as GitEngineMountMap).engines != null
  );
}

/** Normalize engines input into a Map + optional default mount. */
export function normalizeGitEngineMap(input: GitHostCallEngines): {
  engines: Map<string, GitEngine>;
  defaultMount: string | undefined;
} {
  if (!isGitEngineMountMap(input)) {
    // Single-engine path: empty key marks "default only" (mount optional).
    const engines = new Map<string, GitEngine>();
    engines.set("", input);
    return { engines, defaultMount: "" };
  }
  const raw = input.engines;
  const engines =
    raw instanceof Map
      ? new Map(raw)
      : new Map(Object.entries(raw as Record<string, GitEngine>));
  let defaultMount = input.defaultMount;
  if (defaultMount === undefined && engines.size === 1) {
    defaultMount = engines.keys().next().value as string;
  }
  return { engines, defaultMount };
}

/**
 * Extract mount path from a remote Request body.
 * Accepts `args.mount` or top-level `mount` (string).
 */
export function mountFromGitRequest(req: GitRequest & { mount?: unknown }): string | undefined {
  const top = req.mount;
  if (typeof top === "string" && top.trim()) return top.trim();
  const args = req.args;
  if (args && typeof args === "object" && !Array.isArray(args)) {
    const m = (args as Record<string, unknown>).mount;
    if (typeof m === "string" && m.trim()) return m.trim();
  }
  return undefined;
}

/**
 * Resolve which engine handles a remote request (R65 demux).
 * Never shares one engine across mounts without going through this lookup.
 */
export function resolveGitEngineForMount(
  req: GitRequest & { mount?: unknown },
  engines: Map<string, GitEngine>,
  defaultMount?: string,
): { engine: GitEngine; mount: string } | { error: string } {
  const requested = mountFromGitRequest(req);

  // Single-engine sentinel (key "") — mount optional; mismatch only if default set.
  if (engines.size === 1 && engines.has("")) {
    const engine = engines.get("")!;
    return { engine, mount: requested ?? defaultMount ?? "" };
  }

  const mount = requested ?? defaultMount;
  if (!mount) {
    const paths = [...engines.keys()].filter(Boolean).join(", ");
    return {
      error: `git: mount required (registered: ${paths || "(none)"})\n`,
    };
  }
  const engine = engines.get(mount);
  if (!engine) {
    const paths = [...engines.keys()].filter(Boolean).join(", ");
    return {
      error: `git: unknown mount ${JSON.stringify(mount)} (registered: ${paths || "(none)"})\n`,
    };
  }
  return { engine, mount };
}

/**
 * MapHostCall handler factory: body is Request JSON → Response JSON string.
 * Product default: **fresh** per-handler Memory pack cache (multi-tenant safer).
 * Opt into process-shared cache with `MC_GIT_PACK_CACHE_SHARED=1` or explicit
 * `packCache: defaultProcessPackCache()` (`null` disables). Direct
 * {@link GitRemoteOrchestrator} does not auto-enable.
 *
 * Multi-mount (K21 / R63–R65): pass {@link GitEngineMountMap}; body may include
 * `args.mount` or top-level `mount` to demux to the matching engine.
 * Each engine gets its own orchestrator instance (single-writer per mount).
 *
 * ## Snapshot quiescence
 *
 * Remotes run **inside** an open `mc_sys_host_call` slot (`MapHostCall`). The
 * kernel increments `inflight_egress` for the live host handle, so
 * `vm.snapshot()` / `commitLayer()` refuse while clone/fetch/push HTTP+apply
 * is mid-flight — same gate as netfs/mountfs host_calls. Do **not** dial
 * remotes outside host_call (ctl refuses; engine must not dial): a silent
 * snapshot during clone would capture an inconsistent engine/worktree.
 */
export function gitHostCallHandler(
  engineOrMap: GitHostCallEngines,
  opts?: OrchestratorOptions,
): (args: string) => Promise<string> {
  const raw = opts?.packCache;
  // undefined → productDefaultPackCache (fresh Memory unless SHARED=1);
  // null → disabled; explicit PackCache → caller owns lifecycle.
  const packCache =
    raw === null ? undefined : (raw ?? productDefaultPackCache());
  const { engines, defaultMount } = normalizeGitEngineMap(engineOrMap);

  // One orchestrator per engine — never share mutable orch state across mounts.
  // Per-engine sparseCone (from GitEngine.load) wins over handler-level default
  // so multi-mount `git.mounts: [{ path, sparse }]` is not filter-only theater.
  const orchByEngine = new Map<GitEngine, GitRemoteOrchestrator>();
  const orchFor = (engine: GitEngine): GitRemoteOrchestrator => {
    let orch = orchByEngine.get(engine);
    if (!orch) {
      const engineCone = engine.sparseCone;
      orch = new GitRemoteOrchestrator(engine, {
        ...opts,
        packCache,
        sparseCone: engineCone ?? opts?.sparseCone,
        // Per-engine RO (not shared anyRo) — multi-mount mixed RO/RW parity with BEAM.
        readOnly: !!engine.readOnly || !!opts?.readOnly,
      });
      orchByEngine.set(engine, orch);
    }
    return orch;
  };

  return async (args: string) => {
    let req: GitRequest & { mount?: unknown };
    try {
      req = JSON.parse(args || "{}") as GitRequest & { mount?: unknown };
    } catch {
      return JSON.stringify({
        ok: false,
        code: 2,
        stdout: "",
        stderr: "invalid JSON",
      });
    }
    const resolved = resolveGitEngineForMount(req, engines, defaultMount);
    if ("error" in resolved) {
      return JSON.stringify({
        ok: false,
        code: 1,
        stdout: "",
        stderr: resolved.error,
      });
    }
    const resp = await orchFor(resolved.engine).handle(req);
    return JSON.stringify(resp);
  };
}

// ---------------------------------------------------------------------------
// Path helpers
// ---------------------------------------------------------------------------

/**
 * Worktree-relative submodule path: no absolute, no `..`, no empty.
 * Returns null when invalid; empty string only for missing input.
 */
function normalizeSubPath(path: string): string | null {
  const p = String(path || "")
    .replace(/\\/g, "/")
    .replace(/^\/+/, "")
    .replace(/\/+$/, "");
  if (!p) return "";
  const parts = p.split("/").filter((s) => s.length > 0 && s !== ".");
  if (parts.some((s) => s === ".." || s === ".git")) return null;
  if (parts.length === 0) return "";
  return parts.join("/");
}
