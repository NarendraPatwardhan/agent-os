/**
 * Host git source plane — public SDK surface.
 *
 * Layers (import what you need; remotes never dial from the engine):
 *
 * | Role            | Modules                                              |
 * |-----------------|------------------------------------------------------|
 * | Engine          | `engine`, `bridge`, `types`                          |
 * | Worktree (gitfs)| `gitfs`                                              |
 * | Durability      | `durable`                                            |
 * | Remotes         | typed effect pump + `connections`                    |
 * | LLB materialize | `llb-git`                                            |
 *
 * Guest local operations go through host_call `"git"` → engine Run.
 * Guest remotes use the same host call and add the CAP_NET-gated HTTP effect pump.
 */

import {
  gitHostCallHandler,
  type GitHostCallEngines,
  type RemoteEffectPumpOptions,
} from "./remote-effect-pump.js";

// ── Engine + WASM bridge ────────────────────────────────────────────────────

export { GitBridge, DEFAULT_WORK_ROOT } from "./bridge.js";
export { GitEngine } from "./engine.js";
export type {
  GitRequest,
  GitResponse,
  GitIdentity,
  GitEngineLoadOptions,
} from "./types.js";

// ── Worktree projection (gitfs) ─────────────────────────────────────────────

export { createGitFsDriver, isGitFsDriver, GITFS_DRIVER_KIND } from "./gitfs.js";

// ── Remotes (engine-owned Git protocol; host-owned HTTP effects) ────────────

export {
  GitRemoteEffectPump,
  gitHostCallHandler,
  normalizeGitEngineMap,
  mountFromGitRequest,
  resolveGitEngineForMount,
} from "./remote-effect-pump.js";
export type {
  RemoteEffectPumpOptions,
  GitEngineMountMap,
  GitHostCallEngines,
} from "./remote-effect-pump.js";
export {
  resolveGitRemote,
  evaluatePushPolicy,
  matchConnectionPattern,
  originAllowed,
  requestOrigin,
  publicRemoteUrl,
  spliceCredentialHeaders,
  spliceCredentialUrl,
  redactRemoteForLog,
  guestArgsCarrySecrets,
} from "./connections.js";
export type { GitRemoteBinding, ResolveRemoteOptions } from "./connections.js";

// ── Durability ──────────────────────────────────────────────────────────────

export {
  MemoryDurable,
  OpfsDurable,
  DiskDurable,
  openDurable,
  durableIdForMount,
  clearMemoryDurableRegistry,
  safeDurablePathSegment,
  isBlobDurable,
} from "./durable.js";
export type { DurableBackend, DurableKind } from "./durable.js";

// ── LLB git source materialization ──────────────────────────────────────────

export { materializeLlbGit, worktreeToTar, createEngineGitSource } from "./llb-git.js";
export type {
  LlbGitMaterializeOptions,
  LlbGitMaterializeResult,
  EngineGitSourceOptions,
} from "./llb-git.js";

/**
 * Register MapHostCall name `"git"` for local engine operations and remote effects.
 *
 * Multi-mount: pass a {@link GitHostCallEngines} map so remote bodies with
 * `args.mount` / `mount` demux to the matching engine. A single
 * {@link GitEngine} remains the common path (default mount).
 */
export function registerGitHostCall(
  tools: {
    register: (name: string, handler: (args: string) => Promise<string> | string) => void;
  },
  engineOrMap: GitHostCallEngines,
  opts?: RemoteEffectPumpOptions,
): void {
  tools.register("git", gitHostCallHandler(engineOrMap, opts));
}
