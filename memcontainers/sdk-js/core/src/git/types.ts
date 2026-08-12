/**
 * Public SDK request/response facade rendered outside the typed engine boundary.
 *
 * These objects are never sent into Wasm. The browser adapter encodes generated
 * binary requests and renders typed responses for SDK callers.
 */

import type { DurableBackend } from "./durable.js";

// ── Run ABI ─────────────────────────────────────────────────────────────────

export interface GitRequest {
  op: string;
  args?: unknown;
}

export interface GitResponse {
  ok: boolean;
  code: number;
  stdout?: string;
  stderr?: string;
  /** Generated typed result projected into the public facade. */
  result?: unknown;
}

// ── Host policy ─────────────────────────────────────────────────────────────

/**
 * Host commit identity (K28). Injected into `commit` when args omit name/email.
 * Never invent Agent/agent@example.com defaults when unset.
 */
export interface GitIdentity {
  name: string;
  email: string;
}

// ── Engine load ─────────────────────────────────────────────────────────────

export interface GitEngineLoadOptions {
  /**
   * Bytes of release `git-engine.tar` (contains only `git_engine.wasm`).
   * When omitted, resolved via the host-artifact cache
   * (`MC_GIT_ENGINE_TAR` / `AGENTOS_DIR` / optional fetch).
   */
  engine?: Uint8Array;
  /** Logical session root. Browser sessions normally use the default empty root. */
  workRoot?: string;
  readOnly?: boolean;
  /**
   * Optional durable store attached to the engine.
   *
   * Stores opaque engine-produced snapshot bytes. JavaScript never interprets
   * repository, index, object database, or worktree state.
   */
  durable?: DurableBackend;
  /**
   * Host policy identity injected into `commit` when args omit name/email (K28).
   * Never synthesizes a default identity when unset.
   */
  identity?: GitIdentity;
}
