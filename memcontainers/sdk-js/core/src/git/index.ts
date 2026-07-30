/** Host git engine SDK (GIT.md PR3–PR5). */

export { GitBridge, DEFAULT_WORK_ROOT, normalizeRel } from "./bridge.js";
export { GitEngine } from "./engine.js";
export { createGitFsDriver } from "./gitfs.js";
export type {
  GitRequest,
  GitResponse,
  GitEngineLoadOptions,
  GitEngineCreateOptions,
} from "./types.js";
