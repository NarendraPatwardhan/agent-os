/**
 * GitEngine — host-facing facade over the WASM bridge.
 *
 * Single-writer via {@link GitBridge.serial}. Local Run only; remotes are
 * host-mediated (`host_call "git"` → {@link GitRemoteOrchestrator}). Optional
 * durable backends and gitfs mount drivers attach here.
 */

import type { Driver } from "../types.js";
import { GitBridge } from "./bridge.js";
import {
  decodeDurableTreeBlob,
  encodeDurableTreeBlob,
  HostDirDurable,
  isDirectoryDurable,
  restoreDurableTreeBlob,
  type DurableBackend,
} from "./durable.js";
import { createGitFsDriver } from "./gitfs.js";
import type { GitEngineLoadOptions, GitIdentity, GitRequest, GitResponse } from "./types.js";

const REMOTE_OPS = new Set(["clone", "fetch", "pull", "push"]);

// ── Helpers ─────────────────────────────────────────────────────────────────

function normalizeIdentity(id: GitIdentity | undefined): GitIdentity | undefined {
  if (!id) return undefined;
  const name = typeof id.name === "string" ? id.name.trim() : "";
  const email = typeof id.email === "string" ? id.email.trim() : "";
  if (!name || !email) return undefined;
  return { name, email };
}

function resolveDurable(opts: GitEngineLoadOptions): DurableBackend | undefined {
  if (opts.durableDir) {
    // durableDir wins — primary product path (re-openable libgit2 root).
    return new HostDirDurable(opts.durableDir, opts.durableDir);
  }
  return opts.durable;
}

// ── GitEngine ───────────────────────────────────────────────────────────────

export class GitEngine {
  private readonly durable: DurableBackend | undefined;
  /** Last AgentOS Git Snapshot bytes produced by checkpoint. */
  private _durableSnapshot: Uint8Array | null = null;
  /** Default cone prefixes for asMountDriver (cone-only, not full sparse parity). */
  private readonly _sparseCone: string[] | undefined;
  /** Host policy identity for commit inject (K28). */
  private readonly identity: GitIdentity | undefined;
  /** Monotonic scope for direct Run response streams. */
  private requestGeneration = 0;

  constructor(
    readonly bridge: GitBridge,
    readonly readOnly = false,
    durable?: DurableBackend,
    sparseCone?: string[],
    identity?: GitIdentity,
  ) {
    this.durable = durable;
    this._sparseCone = sparseCone?.length ? sparseCone : undefined;
    this.identity = normalizeIdentity(identity);
  }

  static async load(opts: GitEngineLoadOptions): Promise<GitEngine> {
    const durable = resolveDurable(opts);
    const { resolveGitEngineBaseUrl } = await import("../artifacts.js");
    const baseUrl = await resolveGitEngineBaseUrl(opts.engine);
    const bridge = await GitBridge.create(baseUrl, {
      workRoot: opts.workRoot,
      durable,
    });
    const engine = new GitEngine(bridge, !!opts.readOnly, durable, opts.sparseCone, opts.identity);
    try {
      // Directory backends hydrate in GitBridge.create; ge_open already sees
      // the restored worktree+odb (or empty dir for first open).
      if (durable && !isDirectoryDurable(durable)) {
        const snap = await durable.load();
        if (snap && snap.byteLength > 0) {
          const tree = decodeDurableTreeBlob(snap);
          if (!tree) throw new Error("durable load: unrecognized or corrupt Git snapshot");
          restoreDurableTreeBlob(tree, bridge.FS, bridge.workRoot);
          bridge.reopen();
          engine._durableSnapshot = snap.slice();
        }
      }
      return engine;
    } catch (error) {
      try {
        bridge.close();
      } catch {
        /* preserve the load failure */
      }
      throw error;
    }
  }

  /**
   * Last durable snapshot bytes produced by
   * {@link checkpoint} / {@link close} on **blob** backends). Directory
   * backends return null — the host path is the store.
   */
  get durableSnapshot(): Uint8Array | null {
    return this._durableSnapshot ? this._durableSnapshot.slice() : null;
  }

  /**
   * Host directory path for directory durable backends (`durableDir` /
   * {@link HostDirDurable}); `undefined` for blob/memory backends.
   */
  get durableDir(): string | undefined {
    if (isDirectoryDurable(this.durable) && this.durable.hostPath) {
      return this.durable.hostPath;
    }
    return undefined;
  }

  /**
   * Cone-mode sparse prefixes configured at load (post-clone `sparse-set` +
   * default gitfs projection). **Cone-only** — not full sparse-checkout parity.
   * Copy returned; `undefined` when no cone was set.
   */
  get sparseCone(): string[] | undefined {
    return this._sparseCone ? [...this._sparseCone] : undefined;
  }

  // ── Durability ────────────────────────────────────────────────────────────

  /**
   * Persist durable state.
   *
   * * **Directory backends** — stage MEMFS worktree+`.git`, fsync, and
   *   atomically swap the complete host-directory generation.
   * * **Blob backends** — serialize the complete live repository snapshot.
   */
  async checkpoint(): Promise<void> {
    if (!this.durable) return;
    if (isDirectoryDurable(this.durable)) {
      await this.bridge.serial(async () => {
        if (typeof this.durable!.dumpFromMemfs === "function") {
          await this.durable!.dumpFromMemfs!(this.bridge.FS, this.bridge.workRoot);
        } else if (typeof this.durable!.sync === "function") {
          await this.durable!.sync!();
        }
      });
      return;
    }
    const data = await this.exportDurableSnapshot();
    const copy = data.slice();
    await this.durable.save(copy);
    this._durableSnapshot = copy;
  }

  // ── Local Run ─────────────────────────────────────────────────────────────

  /** Function face: Run({op,args}) → Response. Remotes fail closed here. */
  async run(req: GitRequest): Promise<GitResponse> {
    return this.bridge.serial(() => {
      const op = String(req.op || "").toLowerCase();
      if (REMOTE_OPS.has(op)) {
        return {
          ok: false,
          code: 1,
          stdout: "",
          stderr: "remotes require host_call git + orchestrator (PR9–PR10); engine must not dial\n",
        };
      }
      return this.bridge.run(this.injectClientToken(this.injectCommitIdentity(req)));
    });
  }

  /**
   * Read full stdout body after a truncated Response.
   *
   * When `result.truncated` and `result.stream_path` are set, returns the body
   * written under the engine worktree (≤16 MiB). Returns `null` when the
   * response does not name a stream or the stream file is missing.
   */
  async readStdoutStream(resp: GitResponse): Promise<Uint8Array | null> {
    return this.bridge.serial(() => {
      const r = resp;
      const meta =
        r?.result && typeof r.result === "object" && !Array.isArray(r.result)
          ? (r.result as Record<string, unknown>)
          : null;
      const pathFromResult =
        meta && typeof meta.stream_path === "string" ? meta.stream_path.replace(/^\/+/, "") : null;
      if (!pathFromResult || !/^\.git\/mc\/out\/[A-Za-z0-9_-]{1,127}$/.test(pathFromResult)) {
        return null;
      }
      const rel = pathFromResult;
      const abs = this.bridge.abs(rel);
      try {
        const st = this.bridge.FS.lstat(abs);
        if (this.bridge.FS.isLink(st.mode) || this.bridge.FS.isDir(st.mode)) return null;
        if ((st.size ?? 0) > 16 * 1024 * 1024) return null;
        const data = this.bridge.FS.readFile(abs);
        const bytes = data instanceof Uint8Array ? data : new TextEncoder().encode(String(data));
        return bytes.byteLength <= 16 * 1024 * 1024 ? bytes : null;
      } catch (error) {
        const value = error as { code?: unknown; errno?: unknown };
        if (value?.code === "ENOENT" || value?.errno === 44) return null;
        throw error;
      }
    });
  }

  /**
   * K28: when host identity is configured and commit args omit name/email,
   * inject them. Never invents a default identity when unset.
   */
  private injectCommitIdentity(req: GitRequest): GitRequest {
    if (!this.identity) return req;
    const op = String(req.op || "").toLowerCase();
    if (op !== "commit") return req;
    if (req.args !== undefined && (typeof req.args !== "object" || Array.isArray(req.args))) {
      return req;
    }
    const args = { ...((req.args ?? {}) as Record<string, unknown>) };
    if (!Object.prototype.hasOwnProperty.call(args, "name")) args.name = this.identity.name;
    if (!Object.prototype.hasOwnProperty.call(args, "email")) args.email = this.identity.email;
    return { ...req, args };
  }

  /** Every native Run gets a private scope; explicit tokens are validated by C. */
  private injectClientToken(req: GitRequest): GitRequest {
    if (req.args !== undefined && (typeof req.args !== "object" || Array.isArray(req.args))) {
      return req;
    }
    const args = { ...((req.args ?? {}) as Record<string, unknown>) };
    if (Object.prototype.hasOwnProperty.call(args, "client_token")) return { ...req, args };
    args.client_token = `sdk-${++this.requestGeneration}`;
    return { ...req, args };
  }

  // ── Pack I/O ──────────────────────────────────────────────────────────────

  async importPack(chunk: Uint8Array, meta: { final?: boolean } = {}): Promise<void> {
    return this.bridge.serial(() => {
      this.bridge.importPack(chunk, !!meta.final);
    });
  }

  async abortImportPack(): Promise<void> {
    return this.bridge.serial(() => this.bridge.abortImportPack());
  }

  /**
   * Build a push pack (objects reachable from tip OIDs) via engine packbuilder.
   * Optional `haves` are remote tip OIDs already present (lease oldHash) — objects
   * reachable only from them are omitted (thin-pack / have negotiation).
   * Empty oids fail closed. Result always starts with PACK magic.
   */
  async buildPushPack(oids: string[], haves?: string[]): Promise<Uint8Array> {
    return this.bridge.serial(() => this.bridge.packBuild(oids, haves));
  }

  // ── Mount / lifecycle ─────────────────────────────────────────────────────

  /**
   * MountFs driver (worktree + ctl). Coherence: close write then status via open.
   * `sparseCone` overrides load-time default; cone-only projection (not full
   * sparse-checkout parity).
   */
  asMountDriver(opts?: { sparseCone?: string[] }): Driver {
    return createGitFsDriver(this.bridge, {
      readOnly: this.readOnly,
      sparseCone: opts?.sparseCone ?? this._sparseCone,
      identity: this.identity,
    });
  }

  version(): string {
    return this.bridge.version();
  }

  async close(): Promise<void> {
    try {
      if (this.durable) await this.checkpoint();
    } finally {
      this.bridge.close();
    }
  }

  // ── Snapshot export (blob durability) ─────────────────────────────────────

  /**
   * Serialize the complete coding state: ODB, refs, HEAD, index, sparse files,
   * staged/dirty/untracked worktree content, empty directories, and modes.
   */
  private async exportDurableSnapshot(): Promise<Uint8Array> {
    return this.bridge.serial(() => {
      return encodeDurableTreeBlob(this.bridge.FS, this.bridge.workRoot);
    });
  }
}
