/** Host git engine SDK (GIT.md host source plane). */

import {
  gitHostCallHandler,
  type GitHostCallEngines,
  type OrchestratorOptions,
} from "./remote-orchestrator.js";

export { GitBridge, DEFAULT_WORK_ROOT, normalizeRel } from "./bridge.js";
export { GitEngine } from "./engine.js";
export {
  createGitFsDriver,
  isGitFsDriver,
  GITFS_DRIVER_KIND,
} from "./gitfs.js";
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
export {
  MemoryPackCache,
  DiskPackCache,
  importPackCached,
  importPackStream,
  feedPackChunks,
  defaultProcessPackCache,
  createDefaultProcessPackCache,
  processPackCacheDirFromEnv,
  uploadPackCacheKey,
  DEFAULT_MAX_PACK_BYTES,
} from "./pack-cache.js";
export type {
  PackCache,
  ImportPackOptions,
  ImportPackEngine,
} from "./pack-cache.js";
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
export type {
  GitRequest,
  GitResponse,
  GitIdentity,
  GitEngineLoadOptions,
  GitEngineCreateOptions,
} from "./types.js";
export {
  snapshotGitCounters,
  resetGitCounters,
  recordRemoteResult,
  incGitCounter,
} from "./metrics.js";
export type { GitCounterKey } from "./metrics.js";

/**
 * Register MapHostCall name `"git"` → TS orchestrator (PR10a; CAP_NET on guest).
 *
 * Multi-mount (R63–R65): pass a {@link GitHostCallEngines} map so remote bodies
 * with `args.mount` / `mount` demux to the matching engine. Single
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