/** Host git engine SDK (GIT.md PR3–PR10). */

import type { GitEngine } from "./engine.js";
import {
  gitHostCallHandler,
  type OrchestratorOptions,
} from "./remote-orchestrator.js";

export { GitBridge, DEFAULT_WORK_ROOT, normalizeRel } from "./bridge.js";
export { GitEngine } from "./engine.js";
export { createGitFsDriver } from "./gitfs.js";
export {
  GitRemoteOrchestrator,
  gitHostCallHandler,
} from "./remote-orchestrator.js";
export type { OrchestratorOptions } from "./remote-orchestrator.js";
export {
  FixtureSmartHttp,
  FetchSmartHttp,
} from "./smart-http.js";
export type {
  RefAdvertisement,
  SmartHttpTransport,
} from "./smart-http.js";
export {
  MemoryDurable,
  OpfsDurable,
  DiskDurable,
  openDurable,
} from "./durable.js";
export type { DurableBackend } from "./durable.js";
export type {
  GitRequest,
  GitResponse,
  GitEngineLoadOptions,
  GitEngineCreateOptions,
} from "./types.js";

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