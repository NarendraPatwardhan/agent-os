/**
 * Connection-bound git remotes — credential and origin policy.
 *
 * Guest never sees secrets. CLI may pass public `url` and/or `connection` /
 * `agentos` ref. Credential splice is host-only (smart-HTTP headers).
 *
 * Origin authorization uses `@mc/host` `originAllowed` (canonical http(s)
 * origin equality; empty origins = fail closed via `.some` on empty list).
 *
 * Dual-host semantic table (JS = reference; BEAM host opts must stay equivalent):
 *
 * | Concern                 | JS (this module + orch)                         | BEAM (`AgentOS.Git.Connections` + orch)         |
 * |-------------------------|-------------------------------------------------|-------------------------------------------------|
 * | Credential source       | `ConnectionDefinition.auth` only                | connection catalog `:auth` (or bare host `:auth`)|
 * | Guest body secrets      | Reject (`token`/`auth`/… keys) — never splice   | Reject same keys (`:guest_secrets_forbidden`)   |
 * | Connection origins      | `connection.origins` (empty = fail closed)      | same on attach_git `connections:`               |
 * | Bare URL origins        | `allowOrigins` on orch                          | `:allowed_origins` (when connections empty)     |
 * | Push `approve`          | `policies` → `pushAction: "approve"`            | `policies` → `:approve`                         |
 * | Push `require_approval` | `policies` → `"require_approval"` + callback    | `policies` + `:on_push_approval`                |
 * | Push `block`            | `policies` → `"block"` (most restrictive wins)  | same (`git: push blocked by policy`)            |
 * | Auth splice             | `spliceCredentialHeaders` / `Url` host-only     | `SmartHttp.auth_headers` host-only              |
 * | Auth kinds (catalog)    | none \| bearer \| header \| basic               | none \| bearer \| header \| basic (query rejected)    |
 * | Userinfo in URL         | Reject                                          | Reject                                          |
 * | Secrets in logs/resp    | `redactRemoteForLog` (kind only)                | `redact_url` / info refs only / no tokens       |
 */

import {
  GUEST_SECRET_ARG_KEYS as CONTRACT_GUEST_SECRET_KEYS,
  stderrLine,
} from "@mc/contracts/git";
import { originAllowed } from "@mc/host";
import type {
  ConnectionAuth,
  ConnectionDefinition,
  ConnectionPolicyAction,
  ConnectionPolicyRule,
} from "../types.js";

/** Re-export host primitive so git call sites share one definition with catalog/splice. */
export { originAllowed };

// ── Types ───────────────────────────────────────────────────────────────────

export interface GitRemoteBinding {
  /** Public locator without userinfo (no secrets). */
  url: string;
  connectionRef?: string;
  origins: string[];
  auth: ConnectionAuth;
  pushAction: ConnectionPolicyAction;
}

export interface ResolveRemoteOptions {
  connections?: ConnectionDefinition[];
  policies?: ConnectionPolicyRule[];
  remoteUrls?: Record<string, string>;
  remoteConnections?: Record<string, string>;
}

// ── Guest secret keys (fail closed) — contracts/git.kdl ─────────────────────

/**
 * Guest host_call / ctl args must never carry credential material. Host
 * connections catalog + orch opts own secrets; keys come from contracts/git.kdl
 * (dual-host with BEAM AgentOS.Contracts.Git).
 */
const GUEST_SECRET_ARG_KEYS = new Set(
  CONTRACT_GUEST_SECRET_KEYS.map((k) => k.toLowerCase()),
);

function fail(
  code: number,
  stderr: string,
): { ok: false; code: number; stderr: string } {
  return { ok: false, code, stderr };
}

/**
 * True when guest args include a secret-bearing key (case-insensitive).
 * Used by resolve + tests — dual-host: BEAM must not splice from guest body either.
 */
export function guestArgsCarrySecrets(
  args: Record<string, unknown> | undefined,
): boolean {
  if (!args || typeof args !== "object") return false;
  for (const key of Object.keys(args)) {
    if (GUEST_SECRET_ARG_KEYS.has(key.toLowerCase())) return true;
  }
  return false;
}

// ── URL / origin helpers ────────────────────────────────────────────────────

/**
 * Git-specific public URL origin: http(s) only, no userinfo.
 * Host does not export its private `requestOrigin`; keep this thin wrapper for
 * locator validation (same rules as host parse).
 */
export function requestOrigin(value: string): string | null {
  try {
    const url = new URL(value);
    if (
      (url.protocol !== "http:" && url.protocol !== "https:") ||
      url.username ||
      url.password
    ) {
      return null;
    }
    return url.origin;
  } catch {
    return null;
  }
}

/** Public git locator: http(s) only, no userinfo. Keeps path for repo URLs. */
export function publicRemoteUrl(url: string): string | null {
  try {
    const u = new URL(url);
    if (u.protocol !== "http:" && u.protocol !== "https:") return null;
    if (u.username || u.password) return null;
    u.hash = "";
    // Prefer href without trailing slash on bare origin; keep repo path as-is.
    return u.pathname === "/" || u.pathname === ""
      ? u.origin
      : `${u.origin}${u.pathname}${u.search}`;
  } catch {
    return null;
  }
}

// ── Resolve binding ─────────────────────────────────────────────────────────

export function resolveGitRemote(
  args: Record<string, unknown> | undefined,
  opts: ResolveRemoteOptions = {},
): { ok: true; binding: GitRemoteBinding } | { ok: false; code: number; stderr: string } {
  const a = args ?? {};
  const connections = opts.connections ?? [];
  const policies = opts.policies ?? [];

  // Guest body cannot carry auth secrets — reject, never splice from args.
  if (guestArgsCarrySecrets(a)) {
    return fail(1, stderrLine("guest_auth_secrets", "(use connection ref)"));
  }

  let url = String(a.url ?? "");
  let connectionRef =
    typeof a.connection === "string"
      ? a.connection
      : typeof a.agentos === "string"
        ? a.agentos
        : undefined;

  const remoteName = typeof a.remote === "string" ? a.remote : undefined;
  if (!url && remoteName) {
    url = opts.remoteUrls?.[remoteName] ?? "";
    if (!connectionRef) connectionRef = opts.remoteConnections?.[remoteName];
  }

  let conn: ConnectionDefinition | undefined;
  if (connectionRef) {
    conn = connections.find((c) => c.ref === connectionRef);
    if (!conn) {
      return fail(1, stderrLine("unknown_connection", connectionRef));
    }
    if (!url) {
      const fromSpec =
        conn.spec && "url" in conn.spec && typeof conn.spec.url === "string"
          ? conn.spec.url
          : conn.spec &&
              "baseUrl" in conn.spec &&
              typeof conn.spec.baseUrl === "string"
            ? conn.spec.baseUrl
            : undefined;
      url = fromSpec ?? "";
    }
  }

  if (!url) {
    return fail(2, "clone/fetch/push need args.url or args.connection\n");
  }

  // Reject embedded credentials in the public locator.
  if (requestOrigin(url) === null) {
    return fail(
      1,
      "git: remote url must be http(s) without embedded credentials\n",
    );
  }

  const publicUrl = publicRemoteUrl(url);
  if (!publicUrl) {
    return fail(1, "git: bad remote url\n");
  }

  // Connection-bound: empty origins = fail closed; must match allowlist before auth.
  if (connectionRef && conn) {
    const allowed = conn.origins ?? [];
    if (!allowed.length || !originAllowed(allowed, publicUrl)) {
      // Prefix from git.kdl; optional detail after prefix is dual-host OK for connection ref.
      return fail(1, stderrLine("origin_not_allowlisted", `for connection ${conn.ref}`));
    }
  }

  const auth: ConnectionAuth = conn?.auth ?? { kind: "none" };
  // Dual-host (git.kdl): query auth puts secrets in URLs — reject for remotes.
  if (auth.kind === "query") {
    return fail(1, stderrLine("query_auth_unsupported"));
  }

  const origin = requestOrigin(publicUrl)!;
  const origins = conn?.origins?.length ? [...conn.origins] : [origin];

  return {
    ok: true,
    binding: {
      url: publicUrl,
      connectionRef,
      origins,
      auth,
      pushAction: evaluatePushPolicy(connectionRef ?? "*", policies),
    },
  };
}

// ── Push policy ─────────────────────────────────────────────────────────────

export function evaluatePushPolicy(
  connectionRef: string,
  policies: ConnectionPolicyRule[],
): ConnectionPolicyAction {
  if (!policies.length) return "approve";
  let worst: ConnectionPolicyAction = "approve";
  for (const rule of policies) {
    if (!matchConnectionPattern(rule.pattern, connectionRef)) continue;
    worst = moreRestrictive(worst, rule.action);
  }
  return worst;
}

function moreRestrictive(
  a: ConnectionPolicyAction,
  b: ConnectionPolicyAction,
): ConnectionPolicyAction {
  const rank = { approve: 0, require_approval: 1, block: 2 };
  return rank[b] > rank[a] ? b : a;
}

export function matchConnectionPattern(pattern: string, ref: string): boolean {
  if (pattern === "*" || pattern === ref) return true;
  if (pattern.endsWith(".*")) {
    const prefix = pattern.slice(0, -2);
    return ref === prefix || ref.startsWith(prefix + ".");
  }
  return false;
}

// ── Credential splice (host-only) ───────────────────────────────────────────

export function spliceCredentialHeaders(
  auth: ConnectionAuth,
  headers: Record<string, string> = {},
): Record<string, string> {
  const out = { ...headers };
  switch (auth.kind) {
    case "none":
      return out;
    case "bearer":
      out.Authorization = `Bearer ${auth.token}`;
      return out;
    case "header":
      out[auth.name] = auth.value;
      return out;
    case "query":
      // Rejected for product remotes (contracts/git.kdl dual-host) — secrets must
      // not live in URLs. resolveGitRemote fails closed before dial.
      return out;
    default:
      return out;
  }
}

/**
 * Product remotes do not splice secrets into URLs (dual-host with BEAM).
 * Returns `url` unchanged; query auth is rejected at resolve time.
 */
export function spliceCredentialUrl(url: string, _auth: ConnectionAuth): string {
  return url;
}

// ── Logging ─────────────────────────────────────────────────────────────────

export function redactRemoteForLog(binding: GitRemoteBinding): string {
  const cred = binding.auth.kind === "none" ? "anon" : binding.auth.kind;
  const ref = binding.connectionRef ? ` connection=${binding.connectionRef}` : "";
  // Never log full URL with query secrets; origin + path only.
  let loc = binding.url;
  try {
    const u = new URL(binding.url);
    loc = `${u.origin}${u.pathname}`;
  } catch {
    /* */
  }
  return `${loc}${ref} auth=${cred}`;
}
