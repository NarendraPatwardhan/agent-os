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
 * | Remotes         | `remote-orchestrator`, `smart-http`, `connections`   |
 * | Pack / metrics  | `pack-cache`, `metrics`                              |
 * | LLB materialize | `llb-git`                                            |
 *
 * Guest local porcelain goes through gitfs ctl → engine Run.
 * Guest remotes go through host_call `"git"` → orchestrator (CAP_NET).
 */

import {
  gitHostCallHandler,
  type GitHostCallEngines,
  type OrchestratorOptions,
} from "./remote-orchestrator.js";

// ── Engine + WASM bridge ────────────────────────────────────────────────────

export { GitBridge, DEFAULT_WORK_ROOT, normalizeRel } from "./bridge.js";
export { GitEngine } from "./engine.js";
export type {
  GitRequest,
  GitResponse,
  GitResultMeta,
  GitIdentity,
  GitEngineLoadOptions,
} from "./types.js";

// ── Worktree projection (gitfs) ─────────────────────────────────────────────

export {
  createGitFsDriver,
  isGitFsDriver,
  GITFS_DRIVER_KIND,
} from "./gitfs.js";

// ── Remotes (orchestrator + smart-HTTP + connections) ───────────────────────

export {
  GitRemoteOrchestrator,
  gitHostCallHandler,
  normalizeGitEngineMap,
  mountFromGitRequest,
  resolveGitEngineForMount,
} from "./remote-orchestrator.js";
export type {
  OrchestratorOptions,
  GitEngineMountMap,
  GitHostCallEngines,
} from "./remote-orchestrator.js";
export {
  FixtureSmartHttp,
  FetchSmartHttp,
  parseReceiveStatus,
  buildUploadPackBody,
  isRedirectResponse,
  readPackFromResponse,
  indexOfPackMagic,
} from "./smart-http.js";
export type {
  RefAdvertisement,
  SmartHttpTransport,
  PushCommand,
  ReceiveStatus,
  FetchImpl,
  FetchPacksOptions,
} from "./smart-http.js";
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
  OpfsDirDurable,
  DiskDurable,
  HostDirDurable,
  openDurable,
  durableIdForMount,
  clearMemoryDurableRegistry,
  safeDurablePathSegment,
  isDirectoryDurable,
  isBlobDurable,
  encodeDurableBlob,
  decodeDurableBlob,
  AGIT_MAGIC,
} from "./durable.js";
export type {
  DurableBackend,
  DurableKind,
  DurableEnvelopeMeta,
  DurableRefTip,
  DecodedDurableBlob,
  MemfsLike,
} from "./durable.js";

// ── Pack cache + process metrics ────────────────────────────────────────────

export {
  MemoryPackCache,
  DiskPackCache,
  importPackCached,
  importPackStream,
  feedPackChunks,
  defaultProcessPackCache,
  createDefaultProcessPackCache,
  productDefaultPackCache,
  processPackCacheDirFromEnv,
  processPackCacheSharedFromEnv,
  uploadPackCacheKey,
  DEFAULT_MAX_PACK_BYTES,
} from "./pack-cache.js";
export type {
  PackCache,
  ImportPackOptions,
  ImportPackEngine,
} from "./pack-cache.js";
export {
  snapshotGitCounters,
  resetGitCounters,
  recordRemoteResult,
  incGitCounter,
  redactOrigin,
} from "./metrics.js";
export type {
  GitCounterKey,
  GitMetricsSnapshot,
  RemoteResultMeta,
} from "./metrics.js";

// ── LLB git source materialization ──────────────────────────────────────────

export {
  materializeLlbGit,
  worktreeToTar,
  createEngineGitSource,
} from "./llb-git.js";
export type {
  LlbGitMaterializeOptions,
  LlbGitMaterializeResult,
  EngineGitSourceOptions,
} from "./llb-git.js";

/**
 * Register MapHostCall name `"git"` → TS remote orchestrator (CAP_NET on guest).
 *
 * Multi-mount: pass a {@link GitHostCallEngines} map so remote bodies with
 * `args.mount` / `mount` demux to the matching engine. A single
 * {@link GitEngine} remains the common path (default mount).
 */
export function registerGitHostCall(
  tools: {
    register: (
      name: string,
      handler: (args: string) => Promise<string> | string,
    ) => void;
  },
  engineOrMap: GitHostCallEngines,
  opts?: OrchestratorOptions,
): void {
  tools.register("git", gitHostCallHandler(engineOrMap, opts));
}
