/**
 * Connection-bound git remotes — credential and origin policy.
 *
 * Guest never sees secrets. CLI may pass public `url` and/or `connection` /
 * `agentos` ref. Credential splice is host-only on engine-emitted HTTP effects.
 *
 * Origin authorization uses `@mc/host` `originAllowed` (canonical http(s)
 * origin equality; empty origins = fail closed via `.some` on empty list).
 *
 * Dual-host semantic table (JS = reference; BEAM host opts must stay equivalent):
 *
 * | Concern                 | JS (this module + effect pump)                  | BEAM (`Git.Public` / `Git.Transport`)           |
 * |-------------------------|-------------------------------------------------|-------------------------------------------------|
 * | Credential source       | `ConnectionDefinition.auth` only                | connection catalog `:auth` (or bare host `:auth`)|
 * | Guest body secrets      | Reject (`token`/`auth`/… keys) — never splice   | Reject same keys (`:guest_secrets_forbidden`)   |
 * | Connection origins      | `connection.origins` (empty = fail closed)      | same on attach_git `connections:`               |
 * | Bare URL origins        | `allowOrigins` on the effect pump               | `:allowed_origins` (when connections empty)     |
 * | Push `approve`          | `policies` → `pushAction: "approve"`            | `policies` → `:approve`                         |
 * | Push `require_approval` | `policies` → `"require_approval"` + callback    | `policies` + `:on_push_approval`                |
 * | Push `block`            | `policies` → `"block"` (most restrictive wins)  | same (`Git push is blocked by policy`)          |
 * | Auth splice             | HTTP effect headers only                         | HTTP effect headers only                         |
 * | Auth kinds (catalog)    | none \| bearer \| header \| basic               | none \| bearer \| header \| basic (query rejected)    |
 * | Userinfo in URL         | Reject                                          | Reject                                          |
 * | Secrets in logs/resp    | `redactRemoteForLog` (kind only)                | `redact_origin` / info refs only / no tokens    |
 */

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
 * Guest host-call arguments must never carry credential material. Host
 * connections catalog + host opts own secrets; keys match BEAM `Git.Public`
 * (dual-host with JS `GUEST_SECRET_ARG_KEYS`).
 */
const GUEST_SECRET_ARG_KEYS = new Set([
  "auth", "authorization", "token", "password", "credential", "credentials", "secret",
]);

function stderrLine(code: string, detail?: string): string {
  return `git: ${code}${detail ? ` ${detail}` : ""}\n`;
}

/** Maximum nesting depth for secret-key scanning; exceeding it fails closed. */
const GUEST_SECRET_SCAN_MAX_DEPTH = 8;
/** Maximum object/array nodes visited; exceeding it fails closed. */
const GUEST_SECRET_SCAN_MAX_NODES = 256;
const MAX_CREDENTIAL_BYTES = 16 * 1024;
const MAX_HEADER_NAME_BYTES = 256;

function fail(code: number, stderr: string): { ok: false; code: number; stderr: string } {
  return { ok: false, code, stderr };
}

/**
 * True when guest args include a secret-bearing key (case-insensitive),
 * recursively through nested maps/objects and arrays, with explicit depth and
 * node-count bounds. Bound exceedance is fail-closed (treated as secrets).
 * Used by resolve + tests — dual-host: BEAM must not splice from guest body either.
 *
 * Does not stringify-and-regex; only object/array keys are inspected.
 */
export function guestArgsCarrySecrets(args: Record<string, unknown> | undefined): boolean {
  if (!args || typeof args !== "object" || Array.isArray(args)) return false;
  return scanGuestValueForSecrets(args, 0, { nodes: 0 }) !== "clean";
}

type GuestSecretScan = "clean" | "secret" | "exceeded";

function scanGuestValueForSecrets(
  value: unknown,
  depth: number,
  counter: { nodes: number },
): GuestSecretScan {
  if (depth > GUEST_SECRET_SCAN_MAX_DEPTH) return "exceeded";
  if (value === null || value === undefined) return "clean";
  if (typeof value !== "object") return "clean";

  if (Array.isArray(value)) {
    for (const item of value) {
      counter.nodes += 1;
      if (counter.nodes > GUEST_SECRET_SCAN_MAX_NODES) return "exceeded";
      const r = scanGuestValueForSecrets(item, depth + 1, counter);
      if (r !== "clean") return r;
    }
    return "clean";
  }

  // Plain object / map — keys only; never regex body text.
  for (const [key, child] of Object.entries(value as Record<string, unknown>)) {
    counter.nodes += 1;
    if (counter.nodes > GUEST_SECRET_SCAN_MAX_NODES) return "exceeded";
    if (GUEST_SECRET_ARG_KEYS.has(key.toLowerCase())) return "secret";
    const r = scanGuestValueForSecrets(child, depth + 1, counter);
    if (r !== "clean") return r;
  }
  return "clean";
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
    if ((url.protocol !== "http:" && url.protocol !== "https:") || url.username || url.password) {
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
          : conn.spec && "baseUrl" in conn.spec && typeof conn.spec.baseUrl === "string"
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
    return fail(1, "git: remote url must be http(s) without embedded credentials\n");
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

  const auth: unknown = conn?.auth ?? { kind: "none" };
  if (!validConnectionAuth(auth)) {
    return fail(1, stderrLine("invalid_auth"));
  }
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
  const left = rank[a];
  const right = rank[b];
  if (left === undefined || right === undefined) return "block";
  return right > left ? b : a;
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
  if (!validConnectionAuth(auth)) {
    throw new Error(stderrLine("invalid_auth").trim());
  }
  const out = { ...headers };
  switch (auth.kind) {
    case "none":
      return out;
    case "bearer":
      putCredentialHeader(out, "Authorization", `Bearer ${auth.token}`);
      return out;
    case "header":
      putCredentialHeader(out, auth.name, auth.value);
      return out;
    case "basic": {
      putCredentialHeader(
        out,
        "Authorization",
        `Basic ${base64Utf8(`${auth.username}:${auth.password}`)}`,
      );
      return out;
    }
    case "query":
      // Rejected for product remotes (contracts/git.kdl dual-host) — secrets must
      // not live in URLs. resolveGitRemote fails closed before dial.
      return out;
    default:
      return out;
  }
}

function validConnectionAuth(value: unknown): value is ConnectionAuth {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const auth = value as Record<string, unknown>;
  switch (auth.kind) {
    case "none":
      return hasExactAuthKeys(auth, ["kind"]);
    case "bearer":
      return hasExactAuthKeys(auth, ["kind", "token"]) && validSecret(auth.token);
    case "header":
      return (
        hasExactAuthKeys(auth, ["kind", "name", "value"]) &&
        validHeaderName(auth.name) &&
        validSecret(auth.value)
      );
    case "basic":
      return (
        hasExactAuthKeys(auth, ["kind", "username", "password"]) &&
        validSecret(auth.username) &&
        validSecret(auth.password) &&
        !(auth.username as string).includes(":")
      );
    case "query":
      return (
        hasExactAuthKeys(auth, ["kind", "name", "value"]) &&
        validHeaderName(auth.name) &&
        validSecret(auth.value)
      );
    default:
      return false;
  }
}

function hasExactAuthKeys(value: Record<string, unknown>, expected: string[]): boolean {
  const keys = Object.keys(value);
  return keys.length === expected.length && expected.every((key) => keys.includes(key));
}

function validSecret(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    new TextEncoder().encode(value).byteLength <= MAX_CREDENTIAL_BYTES &&
    !/[\u0000-\u001f\u007f]/u.test(value)
  );
}

function validHeaderName(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length <= MAX_HEADER_NAME_BYTES &&
    /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(value)
  );
}

function putCredentialHeader(headers: Record<string, string>, name: string, value: string): void {
  if (Object.keys(headers).some((existing) => existing.toLowerCase() === name.toLowerCase())) {
    throw new Error(`git: credential header conflicts with existing ${name} header`);
  }
  headers[name] = value;
}

/** Browser/worker/Node-neutral UTF-8 base64 (no Buffer dependency). */
function base64Utf8(value: string): string {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const bytes = new TextEncoder().encode(value);
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i]!;
    const hasB = i + 1 < bytes.length;
    const hasC = i + 2 < bytes.length;
    const b = hasB ? bytes[i + 1]! : 0;
    const c = hasC ? bytes[i + 2]! : 0;
    const n = (a << 16) | (b << 8) | c;
    out += alphabet[(n >>> 18) & 63];
    out += alphabet[(n >>> 12) & 63];
    out += hasB ? alphabet[(n >>> 6) & 63] : "=";
    out += hasC ? alphabet[n & 63] : "=";
  }
  return out;
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
