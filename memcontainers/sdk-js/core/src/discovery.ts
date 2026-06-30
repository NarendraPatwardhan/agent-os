// Live-discovery transport: authenticated host-side egress that fetches a connection's source document
// for graphql/mcp integrations — a single GraphQL introspection POST, or the remote-MCP
// initialize → notifications/initialized → tools/list handshake. The compiler builds the request bodies
// single-source (`cc_discovery_request`); this module is pure transport: it applies the credential
// host-side (never in the guest), threads the MCP session header, and lifts the JSON out of an SSE stream.

import type { ConnectionDefinition } from "./types.js";

/** Apply a connection credential to an outbound discovery request, host-side. Returns the (possibly
 *  query-augmented) URL; mutates `headers` for bearer/header auth. */
function applyConnectionAuth(
  auth: ConnectionDefinition["auth"],
  url: string,
  headers: Record<string, string>,
): string {
  switch (auth.kind) {
    case "bearer":
      headers["authorization"] = `Bearer ${auth.token}`;
      return url;
    case "header":
      headers[auth.name.toLowerCase()] = auth.value;
      return url;
    case "query": {
      const u = new URL(url);
      u.searchParams.set(auth.name, auth.value);
      return u.toString();
    }
    default:
      return url;
  }
}

export async function graphqlDiscover(
  discovery: { url: string; body: string },
  auth: ConnectionDefinition["auth"],
): Promise<Uint8Array> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  const url = applyConnectionAuth(auth, discovery.url, headers);
  const res = await fetch(url, { method: "POST", headers, body: discovery.body });
  if (!res.ok) throw new Error(`GraphQL introspection failed: HTTP ${res.status}`);
  return new Uint8Array(await res.arrayBuffer());
}

export async function mcpDiscover(
  discovery: { url: string; initialize: string; initialized: string; list: string },
  auth: ConnectionDefinition["auth"],
): Promise<Uint8Array> {
  const headers = (): Record<string, string> => ({
    "content-type": "application/json",
    accept: "application/json, text/event-stream",
  });
  const post = async (body: string, session?: string): Promise<Response> => {
    const h = headers();
    if (session) h["mcp-session-id"] = session;
    const url = applyConnectionAuth(auth, discovery.url, h);
    return fetch(url, { method: "POST", headers: h, body });
  };
  const initRes = await post(discovery.initialize);
  if (!initRes.ok) throw new Error(`MCP initialize failed: HTTP ${initRes.status}`);
  await initRes.arrayBuffer();
  const session = initRes.headers.get("mcp-session-id") ?? undefined;
  // notifications/initialized has no JSON-RPC reply, but a transport/HTTP failure means the server never
  // reached the initialized state — surface it rather than letting tools/list fail confusingly later.
  const initializedRes = await post(discovery.initialized, session);
  if (!initializedRes.ok) {
    throw new Error(`MCP notifications/initialized failed: HTTP ${initializedRes.status}`);
  }
  await initializedRes.arrayBuffer();
  const listRes = await post(discovery.list, session);
  if (!listRes.ok) throw new Error(`MCP tools/list failed: HTTP ${listRes.status}`);
  return extractDiscoveryJson(listRes.headers.get("content-type") ?? "", await listRes.text());
}

/** Streamable-HTTP MCP may answer as SSE: events are blank-line separated, and one event's `data:` lines
 *  join with "\n". Return the JSON-RPC RESPONSE frame (the one carrying `result`/`error`), skipping any
 *  notification frames (which carry `method`) — concatenating every `data:` line would corrupt the JSON.
 *  A plain-JSON (non-SSE) body is returned as-is. */
function extractDiscoveryJson(contentType: string, text: string): Uint8Array {
  const enc = new TextEncoder();
  if (!contentType.includes("text/event-stream")) return enc.encode(text);
  const frames = text
    .split(/\r?\n\r?\n/)
    .map((block) =>
      block
        .split(/\r?\n/)
        .filter((line) => line.startsWith("data:"))
        .map((line) => line.replace(/^data:[ \t]?/, ""))
        .join("\n"),
    )
    .filter((data) => data.length > 0);
  for (const data of frames) {
    try {
      const msg = JSON.parse(data) as Record<string, unknown>;
      if ("result" in msg || "error" in msg) return enc.encode(data);
    } catch {
      /* skip a non-JSON frame (e.g. a partial or comment) */
    }
  }
  return enc.encode(frames[frames.length - 1] ?? text);
}
