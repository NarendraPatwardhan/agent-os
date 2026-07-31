/** Host git engine SDK (GIT.md host source plane). */

import type { GitEngine } from "./engine.js";
import {
  gitHostCallHandler,
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
} from "./remote-orchestrator.js";
export type { OrchestratorOptions } from "./remote-orchestrator.js";
export {
  FixtureSmartHttp,
  FetchSmartHttp,
  parseReceiveStatus,
} from "./smart-http.js";
export type {
  RefAdvertisement,
  SmartHttpTransport,
  PushCommand,
  ReceiveStatus,
} from "./smart-http.js";
export {
  MemoryDurable,
  OpfsDurable,
  DiskDurable,
  openDurable,
  encodeDurableBlob,
  decodeDurableBlob,
  AGIT_MAGIC,
} from "./durable.js";
export type {
  DurableBackend,
  DurableEnvelopeMeta,
  DurableRefTip,
  DecodedDurableBlob,
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
} from "./connections.js";
export type { GitRemoteBinding, ResolveRemoteOptions } from "./connections.js";
export {
  MemoryPackCache,
  DiskPackCache,
  importPackCached,
  defaultProcessPackCache,
  uploadPackCacheKey,
  DEFAULT_MAX_PACK_BYTES,
} from "./pack-cache.js";
export type { PackCache, ImportPackOptions } from "./pack-cache.js";
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

/** Register MapHostCall name `"git"` → TS orchestrator (PR10a; CAP_NET on guest). */
export function registerGitHostCall(
  tools: {
    register: (
      name: string,
      handler: (args: string) => Promise<string> | string,
    ) => void;
  },
  engine: GitEngine,
  opts?: OrchestratorOptions,
): void {
  tools.register("git", gitHostCallHandler(engine, opts));
}