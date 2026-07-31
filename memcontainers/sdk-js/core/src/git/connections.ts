/**
 * Connection-bound git remotes (GIT.md PR11 / §7.6).
 *
 * Guest never sees secrets. CLI/ctl may pass:
 *   - public `url`, or
 *   - `connection` / `agentos` ref (e.g. github.user.work) resolved on the host.
 *
 * Credential splice happens only in the smart-HTTP transport Authorization (or
 * custom header) — never in Run args or engine config.
 */

import type {
  ConnectionAuth,
  ConnectionDefinition,
  ConnectionPolicyAction,
  ConnectionPolicyRule,
} from "../types.js";

export interface GitRemoteBinding {
  /** Public locator (no secrets). */
  url: string;
  /** Optional connection ref used for credential splice. */
  connectionRef?: string;
  /** Origins allowed for this splice (from connection.origins). */
  origins: string[];
  /** Host-only credential material (never serialized to guest). */
  auth: ConnectionAuth;
  /** Policy action for destructive ops (push). */
  pushAction: ConnectionPolicyAction;
}

export interface ResolveRemoteOptions {
  connections?: ConnectionDefinition[];
  policies?: ConnectionPolicyRule[];
  /**
   * Map remote name → public URL (from engine `remote` config or request).
   * Example: { origin: "https://github.com/org/repo.git" }
   */
  remoteUrls?: Record<string, string>;
  /**
   * Map remote name → connection ref (from `remote.<name>.agentos` convention).
   */
  remoteConnections?: Record<string, string>;
}

/** Resolve Request args to a host-side remote binding. */
export function resolveGitRemote(
  args: Record<string, unknown> | undefined,
  opts: ResolveRemoteOptions = {},
): { ok: true; binding: GitRemoteBinding } | { ok: false; code: number; stderr: string } {
  const a = args ?? {};
  const connections = opts.connections ?? [];
  const policies = opts.policies ?? [];

  let url = String(a.url ?? "");
  let connectionRef =
    typeof a.connection === "string"
      ? a.connection
      : typeof a.agentos === "string"
        ? a.agentos
        : undefined;

  // Named remote without URL: look up public URL / connection from maps.
  const remoteName = typeof a.remote === "string" ? a.remote : undefined;
  if (!url && remoteName) {
    url = opts.remoteUrls?.[remoteName] ?? "";
    if (!connectionRef) connectionRef = opts.remoteConnections?.[remoteName];
  }

  // connection-only: require a connection that carries origin metadata in spec.baseUrl
  // or first origins entry as public locator fallback.
  let conn: ConnectionDefinition | undefined;
  if (connectionRef) {
    conn = connections.find((c) => c.ref === connectionRef);
    if (!conn) {
      return {
        ok: false,
        code: 1,
        stderr: `git: unknown connection ref ${connectionRef}\n`,
      };
    }
    if (!url) {
      const fromSpec =
        conn.spec && "url" in conn.spec && typeof conn.spec.url === "string"
          ? conn.spec.url
          : conn.spec && "baseUrl" in conn.spec && typeof conn.spec.baseUrl === "string"
            ? conn.spec.baseUrl
            : undefined;
      url = fromSpec ?? conn.origins?.[0] ?? "";
    }
  }

  if (!url) {
    return {
      ok: false,
      code: 2,
      stderr: "clone/fetch/push need args.url or args.connection\n",
    };
  }

  let origin: string;
  try {
    origin = new URL(url).origin;
  } catch {
    return { ok: false, code: 1, stderr: "git: bad remote url\n" };
  }

  const origins = conn?.origins?.length
    ? conn.origins
    : connectionRef
      ? []
      : [origin];

  // Exact origin allowlist when connection is bound.
  if (conn?.origins?.length) {
    const allowed = conn.origins.some((o) => o === url || o === origin || url.startsWith(o + "/"));
    if (!allowed) {
      return {
        ok: false,
        code: 1,
        stderr: `git: origin not allowlisted for connection ${conn.ref}: ${url}\n`,
      };
    }
  }

  const pushAction = evaluatePushPolicy(connectionRef ?? "*", policies);

  return {
    ok: true,
    binding: {
      url,
      connectionRef,
      origins: origins.length ? origins : [origin],
      auth: conn?.auth ?? { kind: "none" },
      pushAction,
    },
  };
}

/** Most restrictive matching policy for push (block > require_approval > approve). */
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

/** Glob-ish match: `*`, `integration.*`, `integration.owner.*`, exact. */
export function matchConnectionPattern(pattern: string, ref: string): boolean {
  if (pattern === "*" || pattern === ref) return true;
  if (pattern.endsWith(".*")) {
    const prefix = pattern.slice(0, -2);
    return ref === prefix || ref.startsWith(prefix + ".");
  }
  return false;
}

/** Apply host credential to outbound headers (never logged with secret values). */
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
      // Query splice is applied in URL by transport; marker only.
      out["X-MC-Git-Query-Auth"] = auth.name;
      return out;
    default:
      return out;
  }
}

export function spliceCredentialUrl(url: string, auth: ConnectionAuth): string {
  if (auth.kind !== "query") return url;
  const u = new URL(url);
  u.searchParams.set(auth.name, auth.value);
  return u.toString();
}

/** Redact secrets for stderr / logs. */
export function redactRemoteForLog(binding: GitRemoteBinding): string {
  const cred = binding.auth.kind === "none" ? "anon" : binding.auth.kind;
  const ref = binding.connectionRef ? ` connection=${binding.connectionRef}` : "";
  return `${binding.url}${ref} auth=${cred}`;
}
