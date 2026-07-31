/** Portable Run ABI envelopes (GIT.md K18). */

import type { DurableBackend } from "./durable.js";

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

/** Host commit identity (K28). Never invent Agent/agent@example.com defaults. */
export interface GitIdentity {
  name: string;
  email: string;
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
  /**
   * Default cone prefixes for {@link GitEngine.asMountDriver} when the caller
   * does not pass `sparseCone`. **Cone-only** (prefix projection) — not full
   * sparse-checkout pattern parity.
   */
  sparseCone?: string[];
  /**
   * Optional opaque durable store attached to the engine.
   *
   * deferred: durability not rebinding MEMFS yet — a stored snapshot is loaded
   * into engine-level state only (`GitEngine.durableSnapshot`) and is **not**
   * restored into the worktree. {@link GitEngine.checkpoint} persists
   * caller-supplied (or last-known) opaque bytes; it does not dump MEMFS.
   */
  durable?: DurableBackend;
  /**
   * Host policy identity injected into `commit` when args omit name/email (K28).
   * Never synthesizes a default identity when unset.
   */
  gitIdentity?: GitIdentity;
}

export interface GitEngineCreateOptions {
  /** When true, enable host git engine packaging (PR3+). Default false. */
  experimentalGitEngine?: boolean;
  /** Where to load git_engine.js/wasm from when experimentalGitEngine is set. */
  gitEngineBaseUrl?: string;
  /**
   * Cone-mode sparse prefixes for default gitfs mount / post-clone sparse-set.
   * **Cone-only** — not full sparse-checkout parity. Prefer CreateOptions
   * `gitSparseCone` on the product memcontainer path.
   */
  sparseCone?: string[];
  /**
   * Host commit identity for experimental git engine (K28 inject).
   * Prefer CreateOptions `gitIdentity` on the product memcontainer path.
   */
  gitIdentity?: GitIdentity;
}
