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
  /**
   * Structured op result. Large-stdout path (D15):
   * `{ truncated: true, stream_path: ".git/mc/out/last", stdout_bytes, … }`.
   * Log bounds (D39): `{ count, max_count, bounded?, more? }`.
   */
  result?: GitResultMeta | unknown;
}

/** Known `result` fields from local porcelain (D15 / D39). */
export interface GitResultMeta {
  truncated?: boolean;
  /** Worktree-relative path to full stdout body (open via gitfs / readStdoutStream). */
  stream_path?: string;
  stdout_bytes?: number;
  stdout_embed_bytes?: number;
  stream_bytes?: number;
  stream_partial?: boolean;
  /** log: entries returned */
  count?: number;
  /** log: effective max_count (clamped to engine hard cap) */
  max_count?: number;
  /** log: hit max_count with more commits, or request was clamped */
  bounded?: boolean;
  more?: boolean;
  [key: string]: unknown;
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
  identity?: GitIdentity;
}
