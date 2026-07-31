/**
 * SDK GitEngine — single-writer via GitBridge.serial + optional gitfs driver.
 * Local Run only; remotes go through host_call `"git"` + GitRemoteOrchestrator.
 */

import type { Driver } from "../types.js";
import { GitBridge } from "./bridge.js";
import type { DurableBackend } from "./durable.js";
import { createGitFsDriver } from "./gitfs.js";
import type { GitEngineLoadOptions, GitRequest, GitResponse } from "./types.js";

const REMOTE_OPS = new Set(["clone", "fetch", "pull", "push"]);

export class GitEngine {
  private readonly durable: DurableBackend | undefined;
  /** Last opaque durable bytes (not a MEMFS worktree image). */
  private _durableSnapshot: Uint8Array | null = null;
  /** Default cone prefixes for asMountDriver (cone-only, not full sparse parity). */
  private readonly sparseCone: string[] | undefined;

  constructor(
    readonly bridge: GitBridge,
    readonly readOnly = false,
    durable?: DurableBackend,
    sparseCone?: string[],
  ) {
    this.durable = durable;
    this.sparseCone = sparseCone?.length ? sparseCone : undefined;
  }

  static async load(opts: GitEngineLoadOptions): Promise<GitEngine> {
    const bridge = await GitBridge.create(opts.baseUrl, {
      workRoot: opts.workRoot,
    });
    const engine = new GitEngine(
      bridge,
      !!opts.readOnly,
      opts.durable,
      opts.sparseCone,
    );
    // deferred: durability not rebinding MEMFS yet — engine-level snapshot only
    if (opts.durable) {
      const snap = await opts.durable.load();
      if (snap) engine._durableSnapshot = snap;
    }
    return engine;
  }

  /**
   * Opaque bytes last loaded from / saved to the attached durable backend.
   * Not applied to the MEMFS worktree (deferred: durability not rebinding MEMFS yet).
   */
  get durableSnapshot(): Uint8Array | null {
    return this._durableSnapshot ? this._durableSnapshot.slice() : null;
  }

  /**
   * Persist opaque bytes to the attached durable backend (no-op if none).
   * Does **not** serialize the MEMFS worktree — pass `snapshot` explicitly, or
   * re-save the last known engine-level snapshot.
   */
  async checkpoint(snapshot?: Uint8Array): Promise<void> {
    if (!this.durable) return;
    const data = snapshot ?? this._durableSnapshot;
    if (!data) return;
    const copy = data.slice();
    await this.durable.save(copy);
    this._durableSnapshot = copy;
  }

  /** Function face: Run({op,args}) → Response. */
  async run(req: GitRequest): Promise<GitResponse> {
    return this.bridge.serial(() => {
      const op = String(req.op || "").toLowerCase();
      if (REMOTE_OPS.has(op)) {
        return {
          ok: false,
          code: 1,
          stdout: "",
          stderr:
            "remotes require host_call git + orchestrator (PR9–PR10); engine must not dial\n",
        };
      }
      return this.bridge.run(req);
    });
  }

  async importPack(
    chunk: Uint8Array,
    meta: { final?: boolean } = {},
  ): Promise<void> {
    return this.bridge.serial(() => {
      this.bridge.importPack(chunk, !!meta.final);
    });
  }

  /**
   * Build a push pack (objects reachable from tip OIDs) via engine packbuilder.
   * Empty oids fail closed. Result always starts with PACK magic.
   */
  async buildPushPack(oids: string[]): Promise<Uint8Array> {
    return this.bridge.serial(() => this.bridge.packBuild(oids));
  }

  /**
   * MountFs driver (worktree + ctl). Coherence: close write then status via open.
   * `sparseCone` overrides load-time default; cone-only projection (not full
   * sparse-checkout parity).
   */
  asMountDriver(opts?: { sparseCone?: string[] }): Driver {
    return createGitFsDriver(this.bridge, {
      readOnly: this.readOnly,
      sparseCone: opts?.sparseCone ?? this.sparseCone,
    });
  }

  version(): string {
    return this.bridge.version();
  }

  async close(): Promise<void> {
    // Persist last known opaque snapshot only (not a MEMFS dump).
    if (this.durable && this._durableSnapshot) {
      await this.durable.save(this._durableSnapshot);
    }
    this.bridge.close();
  }
}
