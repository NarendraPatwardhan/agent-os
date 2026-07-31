/**
 * SDK GitEngine — single-writer via GitBridge.serial + optional gitfs driver.
 * Local Run only; remotes go through host_call `"git"` + GitRemoteOrchestrator.
 */

import type { Driver } from "../types.js";
import { GitBridge } from "./bridge.js";
import { createGitFsDriver } from "./gitfs.js";
import type { GitEngineLoadOptions, GitRequest, GitResponse } from "./types.js";

const REMOTE_OPS = new Set(["clone", "fetch", "pull", "push"]);

export class GitEngine {
  constructor(
    readonly bridge: GitBridge,
    readonly readOnly = false,
  ) {}

  static async load(opts: GitEngineLoadOptions): Promise<GitEngine> {
    const bridge = await GitBridge.create(opts.baseUrl, {
      workRoot: opts.workRoot,
    });
    return new GitEngine(bridge, !!opts.readOnly);
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

  /** MountFs driver (worktree + ctl). Coherence: close write then status via open. */
  asMountDriver(opts?: { sparseCone?: string[] }): Driver {
    return createGitFsDriver(this.bridge, {
      readOnly: this.readOnly,
      sparseCone: opts?.sparseCone,
    });
  }

  version(): string {
    return this.bridge.version();
  }

  async close(): Promise<void> {
    this.bridge.close();
  }
}
