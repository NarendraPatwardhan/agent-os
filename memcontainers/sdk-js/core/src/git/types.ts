/** Portable Run ABI envelopes (GIT.md K18). */

export interface GitRequest {
  op: string;
  args?: unknown;
}

export interface GitResponse {
  ok: boolean;
  code: number;
  stdout?: string;
  stderr?: string;
  result?: unknown;
}

export interface GitEngineLoadOptions {
  /**
   * Directory URL or filesystem path containing `git_engine.js` + `git_engine.wasm`
   * (Bazel `//memcontainers/lib/git-engine:git_engine_wasm` outputs).
   */
  baseUrl: string;
  /** Override MEMFS worktree root inside the module (default `/work`). */
  workRoot?: string;
  readOnly?: boolean;
}

export interface GitEngineCreateOptions {
  /** When true, enable host git engine packaging (PR3+). Default false. */
  experimentalGitEngine?: boolean;
  /** Where to load git_engine.js/wasm from when experimentalGitEngine is set. */
  gitEngineBaseUrl?: string;
}
