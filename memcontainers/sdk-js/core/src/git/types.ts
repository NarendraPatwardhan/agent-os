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
   * Optional durable store attached to the engine.
   *
   * * **Directory backends** (`HostDirDurable` / `OpfsDirDurable`, `kind:
   *   "directory"`) — primary product path (D16). Worktree+`.git` is flushed
   *   on checkpoint; load hydrates MEMFS (or mounts host dir) so a second
   *   process reopens the same HEAD + files. Native BEAM `ge_open`s the same
   *   host path without AGIT.
   * * **Blob backends** (AGIT pack+refs) — optional **transfer** format.
   *   Load rebinds via `importPack` + `refs.import` + `clone.apply`.
   *   Legacy non-AGIT opaque bytes attach engine-level only (no rebind).
   */
  durable?: DurableBackend;
  /**
   * Host absolute path for a **directory** durable store (D16 primary).
   * Equivalent to `durable: new HostDirDurable(path, path)`. Preferred over
   * AGIT blob backends when a real worktree directory is available.
   */
  durableDir?: string;
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
