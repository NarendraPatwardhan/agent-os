/**
 * Connection-bound git remotes (GIT.md PR11 / §7.6).
 *
 * Guest never sees secrets. CLI may pass public `url` and/or `connection` /
 * `agentos` ref. Credential splice is host-only (smart-HTTP headers).
 *
 * Origin authorization mirrors `@mc/host` `originAllowed` (canonical http(s)
 * origin equality; empty origins = fail closed).
 */

import type {
  ConnectionAuth,
  ConnectionDefinition,
  ConnectionPolicyAction,
  ConnectionPolicyRule,
} from "../types.js";

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

function fail(
  code: number,
  stderr: string,
): { ok: false; code: number; stderr: string } {
  return { ok: false, code, stderr };
}

/** Normalize http(s) URL to origin; reject userinfo / non-http(s). */
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

/**
 * Same semantics as `@mc/host` originAllowed: canonical origin equality only.
 * Empty allowlist → deny (fail closed).
 */
export function originAllowed(
  allowedOrigins: readonly string[],
  url: string,
): boolean {
  if (!allowedOrigins.length) return false;
  const target = requestOrigin(url);
  if (target === null) return false;
  return allowedOrigins.some((origin) => requestOrigin(origin) === target);
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

  const remoteName = typeof a.remote === "string" ? a.remote : undefined;
  if (!url && remoteName) {
    url = opts.remoteUrls?.[remoteName] ?? "";
    if (!connectionRef) connectionRef = opts.remoteConnections?.[remoteName];
  }

  let conn: ConnectionDefinition | undefined;
  if (connectionRef) {
    conn = connections.find((c) => c.ref === connectionRef);
    if (!conn) {
      return fail(1, `git: unknown connection ref ${connectionRef}\n`);
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
      return fail(
        1,
        `git: origin not allowlisted for connection ${conn.ref}\n`,
      );
    }
  }

  const origin = requestOrigin(publicUrl)!;
  const origins = conn?.origins?.length ? [...conn.origins] : [origin];

  return {
    ok: true,
    binding: {
      url: publicUrl,
      connectionRef,
      origins,
      auth: conn?.auth ?? { kind: "none" },
      pushAction: evaluatePushPolicy(connectionRef ?? "*", policies),
    },
  };
}

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
      // Prefer not to put secrets in URLs; mark for transport that opts in.
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
