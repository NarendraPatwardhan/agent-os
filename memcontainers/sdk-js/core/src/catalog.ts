import { defaultCatalogCompiler } from "@mc/host";
import type { CatalogCompiler, RegistryEntry, RegistryGroup } from "@mc/host";
import { mergeToolCatalogBundles } from "./tools.js";
import type { ToolCatalogBundle } from "./tools.js";
import type {
  CatalogFormat,
  CatalogSourceFormat,
  ConnectionDefinition,
  ConnectionSpecSource,
  CreateOptions,
  ToolDefinition,
  ToolPolicyAction,
} from "./types.js";

const enc = (s: string): Uint8Array => new TextEncoder().encode(s);
const dec = (b: Uint8Array): string => new TextDecoder().decode(b);

const sourceBySha = new Map<string, Uint8Array>();
const sourceShaByUrl = new Map<string, string>();
const bundleByKey = new Map<string, Map<string, Uint8Array>>();

interface RefParts {
  integration: string;
  owner: string;
  connection: string;
}

interface SourceBytes {
  bytes: Uint8Array;
  sha: string;
  format: CatalogSourceFormat;
  baseUrl?: string;
  endpoint?: string;
}

interface CompileFilter {
  exact_paths: string[];
  path_prefixes: string[];
  tag_prefixes: string[];
}

interface CompileOpts {
  format: CatalogFormat;
  source_format: CatalogSourceFormat;
  integration: string;
  group?: string;
  filter: CompileFilter;
  base_url?: string | null;
  endpoint?: string | null;
}

export function hostToolDefinitions(tools: CreateOptions["tools"]): ToolDefinition[] {
  return (tools ?? []).filter((tool): tool is ToolDefinition => typeof tool !== "string");
}

export function catalogToolSelectors(tools: CreateOptions["tools"]): string[] {
  return (tools ?? []).filter((tool): tool is string => typeof tool === "string");
}

export async function connectionToolCatalogBundle(
  opts: CreateOptions,
  generation: number,
): Promise<ToolCatalogBundle | null> {
  const connections = opts.connections ?? [];
  if (connections.length === 0) return null;
  const compiler = await defaultCatalogCompiler(opts.catalogCompiler);
  const selectors = catalogToolSelectors(opts.tools);
  const bundles: ToolCatalogBundle[] = [];
  for (const connection of connections) {
    const ref = await compiler.parseRef(connection.ref);
    const registry = await resolveRegistry(compiler, ref.integration, connection);
    const groups = selectedGroups(ref.integration, registry, selectors, connection.tools);
    for (const group of groups) {
      const source = await acquireSource(connection, registry, compiler);
      const compileOpts = resolvedCompileOpts(ref.integration, registry, source, group);
      const entries = await compileCached(compiler, source, compileOpts);
      bundles.push(await bundleFromCompilerEntries(entries, ref, generation));
    }
  }
  if (bundles.length === 0) return null;
  return mergeToolCatalogBundles(bundles, generation);
}

/**
 * Fill each connection's credential-egress `origins` from its curated registry `servers` when the
 * embedder omitted them, so a connection is just `{ ref, auth }`. Best-effort: a connection with
 * explicit `origins`, a custom `spec`, or no resolvable registry entry is returned unchanged (it then
 * fails closed at the splice if still empty — derivation never widens an explicit allowlist). Only
 * curated `servers`/`endpoint` (our constant) are used; a live spec's servers are never trusted here.
 */
export async function deriveConnectionOrigins(opts: CreateOptions): Promise<ConnectionDefinition[]> {
  const connections = opts.connections ?? [];
  const needs = connections.some((c) => !(c.origins && c.origins.length) && !c.spec);
  if (!needs) return connections;
  const compiler = await defaultCatalogCompiler(opts.catalogCompiler);
  return Promise.all(
    connections.map(async (c) => {
      if ((c.origins && c.origins.length) || c.spec) return c;
      try {
        const ref = await compiler.parseRef(c.ref);
        const registry = await resolveRegistry(compiler, ref.integration, c);
        const origins = registryOrigins(registry);
        return origins.length ? { ...c, origins } : c;
      } catch {
        return c;
      }
    }),
  );
}

/**
 * Resolve the embedder's tool policy per connection address (`integration.owner.connection.*`) via the
 * single-source toolcore engine (`cc_validate_policy` + `cc_policy_resolve`), at create — so the egress
 * splice just looks the action up, never re-implementing pattern matching (the JS peer of the Rust
 * host's native `toolcore::policy`). Throws if any rule is invalid. Empty when there are no rules or no
 * connections (the splice then falls back to method-based destructiveness classification).
 */
export async function resolvePolicyByConnection(
  opts: CreateOptions,
): Promise<Map<string, ToolPolicyAction | null>> {
  const map = new Map<string, ToolPolicyAction | null>();
  const rules = opts.policies ?? [];
  const connections = opts.connections ?? [];
  if (rules.length === 0 || connections.length === 0) return map;
  const compiler = await defaultCatalogCompiler(opts.catalogCompiler);
  const rulesJson = JSON.stringify(rules);
  await compiler.validatePolicy(rulesJson);
  for (const connection of connections) {
    const address = `${connection.ref}.*`;
    map.set(address, await compiler.policyResolve(rulesJson, address));
  }
  return map;
}

/** Curated egress origins for a registry entry: explicit `servers`, else the `endpoint`'s origin
 *  (graphql/mcp/microsoft-graph carry the live server in `endpoint`). */
function registryOrigins(registry: RegistryEntry): string[] {
  if (registry.servers && registry.servers.length) return [...registry.servers];
  if (registry.endpoint) {
    try {
      return [new URL(registry.endpoint).origin];
    } catch {
      /* endpoint is not an absolute URL — nothing to derive */
    }
  }
  return [];
}

async function resolveRegistry(
  compiler: CatalogCompiler,
  integration: string,
  connection: ConnectionDefinition,
): Promise<RegistryEntry> {
  const candidates = [integration, `${integration}-rest`, `${integration}-openapi`];
  for (const id of candidates) {
    try {
      return await compiler.registryResolve(id);
    } catch {
      /* try alias */
    }
  }
  const spec = connection.spec;
  if (spec?.format) {
    return {
      id: integration,
      name: integration,
      kind: spec.format,
      ...("url" in spec ? { url: spec.url } : {}),
    };
  }
  throw new Error(`connection '${connection.ref}' does not resolve to a catalog registry entry`);
}

function selectedGroups(
  integration: string,
  registry: RegistryEntry,
  rootSelectors: string[],
  connectionSelectors: readonly string[] | undefined,
): (string | undefined)[] {
  const explicit = [
    ...selectorsForConnection(integration, registry.id, rootSelectors),
    ...selectorsForConnection(integration, registry.id, connectionSelectors ?? []),
  ];
  if (explicit.length > 0) return dedupe(explicit);
  const defaults = registry.defaultGroups ?? [];
  return defaults.length === 0 ? [undefined] : dedupe(defaults);
}

function selectorsForConnection(
  integration: string,
  registryId: string,
  selectors: readonly string[],
): (string | undefined)[] {
  const out: (string | undefined)[] = [];
  for (const raw of selectors) {
    const selector = raw.trim();
    if (!selector) continue;
    const slash = selector.indexOf("/");
    if (slash < 0) {
      if (selector === integration || selector === registryId) out.push(undefined);
      continue;
    }
    const lhs = selector.slice(0, slash);
    const rhs = selector.slice(slash + 1);
    if ((lhs === integration || lhs === registryId) && rhs) out.push(rhs);
  }
  return out;
}

async function acquireSource(
  connection: ConnectionDefinition,
  registry: RegistryEntry,
  compiler: CatalogCompiler,
): Promise<SourceBytes> {
  const spec = connection.spec;
  if (spec && "bytes" in spec) {
    return cachedSource(spec.bytes, sourceFormat(spec, undefined), sourceBaseUrl(spec), sourceEndpoint(spec));
  }
  if (spec && "path" in spec) {
    const { readFileSync } = await import("node:fs");
    return cachedSource(
      new Uint8Array(readFileSync(spec.path)),
      sourceFormat(spec, spec.path),
      sourceBaseUrl(spec),
      sourceEndpoint(spec),
    );
  }
  const url = spec && "url" in spec ? spec.url : registry.url;
  // The endpoint a live discovery (graphql/mcp) calls — a provided url, else the registry endpoint/url.
  const endpoint = (spec && "url" in spec ? spec.url : registry.endpoint) ?? url ?? "";
  const discovery = await compiler.discoveryRequest(registry.kind, endpoint);

  if (discovery.protocol === "static") {
    if (!url) throw new Error(`connection '${connection.ref}' requires a provided spec`);
    const cachedSha = sourceShaByUrl.get(url);
    const cached = cachedSha ? sourceBySha.get(cachedSha) : undefined;
    if (cached && cachedSha) {
      return {
        bytes: cached,
        sha: cachedSha,
        format: sourceFormat(spec, url),
        ...(sourceBaseUrl(spec) ? { baseUrl: sourceBaseUrl(spec) } : {}),
        ...(sourceEndpoint(spec) ? { endpoint: sourceEndpoint(spec) } : {}),
      };
    }
    const response = await fetch(url);
    if (!response.ok) throw new Error(`catalog source fetch failed for ${url}: HTTP ${response.status}`);
    const loaded = await cachedSource(
      new Uint8Array(await response.arrayBuffer()),
      sourceFormat(spec, url),
      sourceBaseUrl(spec),
      sourceEndpoint(spec),
    );
    sourceShaByUrl.set(url, loaded.sha);
    return loaded;
  }

  // Live discovery: an authenticated call to the connection endpoint. The credential is applied host-side
  // here (never reaches the guest); the response is the source document for compilation. Discovery
  // egresses the credential, so it honors the same origin allowlist as a tool-call splice (S2): the
  // endpoint must be one of the connection's allowed origins, fail-closed (mirrors the wasmtime host).
  const origins = connection.origins ?? [];
  if (!origins.some((o) => endpoint === o || endpoint.startsWith(`${o}/`))) {
    throw new Error(
      `discovery endpoint '${endpoint}' is not an allowed origin for connection '${connection.ref}'`,
    );
  }
  const bytes =
    discovery.protocol === "graphql"
      ? await graphqlDiscover(discovery, connection.auth)
      : await mcpDiscover(discovery, connection.auth);
  return cachedSource(bytes, "json", sourceBaseUrl(spec), endpoint);
}

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

async function graphqlDiscover(
  discovery: { url: string; body: string },
  auth: ConnectionDefinition["auth"],
): Promise<Uint8Array> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  const url = applyConnectionAuth(auth, discovery.url, headers);
  const res = await fetch(url, { method: "POST", headers, body: discovery.body });
  if (!res.ok) throw new Error(`GraphQL introspection failed: HTTP ${res.status}`);
  return new Uint8Array(await res.arrayBuffer());
}

async function mcpDiscover(
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

async function cachedSource(
  bytes: Uint8Array,
  format: CatalogSourceFormat,
  baseUrl?: string,
  endpoint?: string,
): Promise<SourceBytes> {
  const copy = bytes.slice();
  const sha = await sha256Hex(copy);
  sourceBySha.set(sha, copy);
  return {
    bytes: copy,
    sha,
    format,
    ...(baseUrl ? { baseUrl } : {}),
    ...(endpoint ? { endpoint } : {}),
  };
}

function resolvedCompileOpts(
  integration: string,
  registry: RegistryEntry,
  source: SourceBytes,
  group: string | undefined,
): CompileOpts {
  const registryGroup = group ? registry.groups?.[group] : undefined;
  const filter = filterForGroup(group, registryGroup);
  return dropUndefined({
    format: registry.kind,
    source_format: source.format,
    integration,
    group,
    filter,
    base_url: source.baseUrl ?? registry.endpoint ?? null,
    endpoint: source.endpoint ?? registry.endpoint ?? null,
  });
}

function filterForGroup(group: string | undefined, registryGroup: RegistryGroup | undefined): CompileFilter {
  const f = registryGroup?.filter;
  if (f) {
    return {
      exact_paths: [...(f.exact_paths ?? [])],
      path_prefixes: [...(f.path_prefixes ?? [])],
      tag_prefixes: [...(f.tag_prefixes ?? [])],
    };
  }
  return {
    exact_paths: [],
    path_prefixes: [],
    tag_prefixes: group ? [group] : [],
  };
}

async function compileCached(
  compiler: CatalogCompiler,
  source: SourceBytes,
  opts: CompileOpts,
): Promise<Map<string, Uint8Array>> {
  const canonicalOpts = canonicalJson(opts);
  // The host-computed artifact digest (sha256 of the compiler wasm) is the compiler's identity — it
  // changes whenever the binary does, fully subsuming any in-wasm version string.
  const key = await sha256Text(
    `${compiler.artifactDigest}\0${compiler.bundleSchemaVersion()}\0${source.sha}\0${canonicalOpts}`,
  );
  const cached = bundleByKey.get(key);
  if (cached) return cloneEntries(cached);
  const bundle = await compiler.compile(source.bytes, enc(canonicalOpts));
  bundleByKey.set(key, cloneEntries(bundle.entries));
  return cloneEntries(bundle.entries);
}

async function bundleFromCompilerEntries(
  entries: Map<string, Uint8Array>,
  ref: RefParts,
  generation: number,
): Promise<ToolCatalogBundle> {
  const indexBytes = entries.get("index.json");
  if (!indexBytes) throw new Error("catalog compiler bundle missing index.json");
  const parsed: unknown = JSON.parse(dec(indexBytes));
  if (!isObject(parsed) || !Array.isArray(parsed.tools)) {
    throw new Error("catalog compiler bundle index has invalid shape");
  }
  const tools = parsed.tools.map((tool) => indexTool(tool, ref)).sort((a, b) => a.address.localeCompare(b.address));
  const index = { generation, tools };
  const rewrittenIndexBytes = enc(JSON.stringify(index));
  const records = [...entries.entries()]
    .filter(([path]) => path.startsWith("records/"))
    .map(([path, bytes]) => ({ sha: path.slice("records/".length), bytes }));
  return {
    index,
    indexBytes: rewrittenIndexBytes,
    indexDigest: await sha256Hex(rewrittenIndexBytes),
    records,
  };
}

function indexTool(
  value: unknown,
  ref: RefParts,
): { address: string; integration: string; description: string; sha: string } {
  if (!isObject(value) || typeof value.address !== "string" || typeof value.sha !== "string") {
    throw new Error("catalog compiler bundle index entry has invalid shape");
  }
  return {
    address: rePrefixAddress(value.address, ref),
    integration: ref.integration,
    description: typeof value.description === "string" ? value.description : "",
    sha: value.sha,
  };
}

function rePrefixAddress(address: string, ref: RefParts): string {
  const parts = address.split(".");
  if (parts.length < 4) throw new Error(`catalog compiler emitted invalid tool address '${address}'`);
  return [ref.integration, ref.owner, ref.connection, ...parts.slice(3)].join(".");
}

function sourceFormat(source: ConnectionSpecSource | undefined, pathOrUrl: string | undefined): CatalogSourceFormat {
  if (source?.sourceFormat) return source.sourceFormat;
  return pathOrUrl?.match(/\.ya?ml($|[?#])/i) ? "yaml" : "json";
}

function sourceBaseUrl(source: ConnectionSpecSource | undefined): string | undefined {
  return source?.baseUrl;
}

function sourceEndpoint(source: ConnectionSpecSource | undefined): string | undefined {
  return source?.endpoint;
}

function dropUndefined<T extends Record<string, unknown>>(value: T): T {
  for (const key of Object.keys(value)) {
    if (value[key] === undefined) delete value[key];
  }
  return value;
}

function dedupe<T>(values: T[]): T[] {
  const out: T[] = [];
  for (const value of values) {
    if (!out.includes(value)) out.push(value);
  }
  return out;
}

function cloneEntries(entries: Map<string, Uint8Array>): Map<string, Uint8Array> {
  const out = new Map<string, Uint8Array>();
  for (const [key, value] of entries) out.set(key, value.slice());
  return out;
}

function canonicalJson(value: unknown): string {
  return JSON.stringify(canonical(value));
}

function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (!isObject(value)) return value;
  const out: Record<string, unknown> = {};
  for (const key of Object.keys(value).sort()) out[key] = canonical(value[key]);
  return out;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

async function sha256Text(text: string): Promise<string> {
  return sha256Hex(enc(text));
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await globalThis.crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}
