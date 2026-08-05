/**
 * Host smart-HTTP transport — ListRefs + FetchPacks + PushPacks.
 *
 * Browser/JS face of the remotes half of the source plane. Server twin is BEAM
 * `AgentOS.Git.SmartHttp` (OTP `:httpc`). Credentials are spliced only via
 * request headers — never into the URL for product remotes.
 *
 * ## Redirect policy (fail-closed)
 *
 * Product smart-HTTP **never follows redirects**. Every `fetch` uses
 * `redirect: "manual"`, and any 3xx / `opaqueredirect` response is rejected as
 * `redirect not allowed` without reading `Location` or issuing a second request.
 * Open redirect to a non-allowlisted origin is therefore impossible: there is
 * no hop, so no allowlist re-check is required.
 *
 * Dual-host: BEAM sets `:httpc` `autoredirect: false` and classifies 3xx as
 * `:redirect_not_allowed` — same policy surface.
 */

import type { ConnectionAuth } from "../types.js";
import { spliceCredentialHeaders, spliceCredentialUrl } from "./connections.js";
import { MAX_PACK_ZERO_MEANS_DEFAULT, PACK_MAGIC_REQUIRED, stderrLine } from "@mc/contracts/git";
import { DEFAULT_MAX_PACK_BYTES } from "./pack-cache.js";

/** Resolve max pack bytes: 0 → default when contract says so (dual-host with BEAM). */
function resolveHttpMaxBytes(maxBytes: number | undefined): number {
  if (maxBytes === undefined) return DEFAULT_MAX_PACK_BYTES;
  if (maxBytes === 0 && MAX_PACK_ZERO_MEANS_DEFAULT) return DEFAULT_MAX_PACK_BYTES;
  return maxBytes;
}

// ── Types ───────────────────────────────────────────────────────────────────

export interface RefAdvertisement {
  name: string;
  hash: string;
  peeled?: string;
  /** Capabilities advertised on the first v0/v1 ref line. */
  capabilities?: string[];
}

export interface ReceiveStatus {
  ok: boolean;
  message?: string;
}

export interface PushCommand {
  /** old OID or zeros for create */
  oldHash: string;
  /** new OID or zeros for delete */
  newHash: string;
  name: string;
}

/**
 * Options for product {@link FetchSmartHttp.fetchPacks} (streamed body path).
 * Fixture transport ignores these; size gate still applies at import.
 */
export interface FetchPacksOptions {
  /**
   * Max pack bytes after PACK magic (and total body while scanning).
   * Default {@link DEFAULT_MAX_PACK_BYTES} (64 MiB). `0` means default (contracts/git.kdl).
   */
  maxBytes?: number;
  /**
   * Progressive pack sink: each slice is pack-aligned bytes (from `PACK` magic).
   * Used by the orchestrator to feed `engine.importPack` without waiting for the
   * full buffer when the response body is a ReadableStream.
   */
  onPackChunk?: (chunk: Uint8Array) => void | Promise<void>;
}

export interface SmartHttpTransport {
  listRefs(
    url: string,
    auth?: ConnectionAuth,
    service?: "git-upload-pack" | "git-receive-pack",
  ): Promise<RefAdvertisement[]>;
  fetchPacks(
    url: string,
    want: string[],
    have: string[],
    depth?: number,
    auth?: ConnectionAuth,
    /** Partial clone filter (e.g. `blob:none`); optional. */
    filter?: string,
    /** Product stream / size-cap options (ignored by fixtures). */
    opts?: FetchPacksOptions,
  ): Promise<Uint8Array>;
  pushPacks?(
    url: string,
    commands: PushCommand[],
    pack: Uint8Array,
    auth?: ConnectionAuth,
    capabilities?: string[],
  ): Promise<ReceiveStatus>;
}

// ── Fixture transport (tests) ───────────────────────────────────────────────

/** In-memory test double (shared algorithm with C fixtures). */
export class FixtureSmartHttp implements SmartHttpTransport {
  private readonly fixtures = new Map<string, { refs: RefAdvertisement[]; pack: Uint8Array }>();
  lastAuth: ConnectionAuth | undefined;
  lastPush: { url: string; commands: PushCommand[]; packLen: number; pack: Uint8Array } | undefined;
  /** Last fetchPacks args (filter ignored for body; recorded for partial-clone tests). */
  lastFetch:
    | {
        url: string;
        want: string[];
        have: string[];
        depth?: number;
        filter?: string;
      }
    | undefined;
  pushResult: ReceiveStatus = { ok: true };
  /** Transport call counters (pack-cache hit assertions). */
  listRefsCalls = 0;
  fetchPacksCalls = 0;

  add(url: string, refs: RefAdvertisement[], pack: Uint8Array): void {
    this.fixtures.set(url, { refs, pack });
  }

  clear(): void {
    this.fixtures.clear();
    this.lastAuth = undefined;
    this.lastPush = undefined;
    this.lastFetch = undefined;
    this.listRefsCalls = 0;
    this.fetchPacksCalls = 0;
  }

  async listRefs(
    url: string,
    auth?: ConnectionAuth,
    _service: "git-upload-pack" | "git-receive-pack" = "git-upload-pack",
  ): Promise<RefAdvertisement[]> {
    this.listRefsCalls += 1;
    this.lastAuth = auth;
    const f = this.fixtures.get(url);
    if (!f) throw new Error(`git: list-refs failed: no fixture for ${url}`);
    return f.refs.map((r) => ({ ...r }));
  }

  async fetchPacks(
    url: string,
    want: string[],
    have: string[],
    depth?: number,
    auth?: ConnectionAuth,
    filter?: string,
    opts?: FetchPacksOptions,
  ): Promise<Uint8Array> {
    this.fetchPacksCalls += 1;
    this.lastAuth = auth;
    // Fixture ignores filter (no partial materialization) but does not break.
    this.lastFetch = { url, want: [...want], have: [...have], depth, filter };
    const f = this.fixtures.get(url);
    if (!f) throw new Error(`git: upload-pack failed: no fixture for ${url}`);
    const pack = f.pack.slice();
    const max = resolveHttpMaxBytes(opts?.maxBytes);
    if (max > 0 && pack.byteLength > max) {
      throw new Error(
        `git: pack ${pack.byteLength} bytes exceeds maxPackBytes ${max} (opt-in higher limit)`,
      );
    }
    if (opts?.onPackChunk && pack.byteLength > 0) {
      await opts.onPackChunk(pack);
    }
    return pack;
  }

  async pushPacks(
    url: string,
    commands: PushCommand[],
    pack: Uint8Array,
    auth?: ConnectionAuth,
    _capabilities?: string[],
  ): Promise<ReceiveStatus> {
    this.lastAuth = auth;
    this.lastPush = {
      url,
      commands: commands.map((c) => ({ ...c })),
      packLen: pack.byteLength,
      pack: pack.slice(),
    };
    return this.pushResult;
  }
}

// ── Fetch transport (product) ───────────────────────────────────────────────

/** Optional `fetch` inject for tests (redirect mock / offline). */
export type FetchImpl = (input: string | URL | Request, init?: RequestInit) => Promise<Response>;

/**
 * Public HTTPS smart-HTTP using fetch (browser/Node) with optional credential splice.
 *
 * Always `redirect: "manual"`; 3xx / opaqueredirect → hard fail (never follow).
 */
export class FetchSmartHttp implements SmartHttpTransport {
  private readonly fetchImpl: FetchImpl;

  constructor(
    private readonly defaultAuth?: ConnectionAuth,
    fetchImpl?: FetchImpl,
  ) {
    this.fetchImpl = fetchImpl ?? ((input, init) => globalThis.fetch(input as RequestInfo, init));
  }

  private headers(auth?: ConnectionAuth): Record<string, string> {
    return spliceCredentialHeaders(auth ?? this.defaultAuth ?? { kind: "none" });
  }

  private url(url: string, auth?: ConnectionAuth): string {
    return spliceCredentialUrl(url, auth ?? this.defaultAuth ?? { kind: "none" });
  }

  /**
   * Product dial: never auto-follow redirects. Reject 3xx / opaqueredirect.
   * Injected `fetchImpl` must honor `redirect: "manual"` (or simulate it).
   */
  private async smartFetch(input: string, init: RequestInit = {}): Promise<Response> {
    const res = await this.fetchImpl(input, {
      ...init,
      // Fail-closed: caller inspects status; browser never follows Location.
      redirect: "manual",
    });
    if (isRedirectResponse(res)) {
      throw new Error(
        `${stderrLine("redirect_not_allowed").trim()} (HTTP ${res.status || "opaque"}; open redirect blocked)`,
      );
    }
    return res;
  }

  async listRefs(
    url: string,
    auth?: ConnectionAuth,
    service: "git-upload-pack" | "git-receive-pack" = "git-upload-pack",
  ): Promise<RefAdvertisement[]> {
    const base = this.url(url, auth).replace(/\/$/, "");
    const hdrs = this.headers(auth);
    const infoUrl = `${base}/info/refs?service=${service}`;
    // Prefer classic v0/v1 advertise (matches BEAM SmartHttp). Optional v2
    // probe is only used when the classic body parses empty — real git-http-backend
    // returns a 200 v2 capability dump when `Git-Protocol: version=2` is set, which
    // is not a ref list.
    let res = await this.smartFetch(infoUrl, { headers: hdrs });
    if (!res.ok) {
      throw new Error(`git: list-refs failed: HTTP ${res.status}`);
    }
    let refs = parseInfoRefs(await res.text());
    if (refs.length === 0 && service === "git-upload-pack") {
      // Some hosts only speak v2 on info/refs; try once, still no redirects.
      res = await this.smartFetch(infoUrl, {
        headers: { ...hdrs, "git-protocol": "version=2" },
      });
      if (res.ok) {
        const v2 = parseInfoRefs(await res.text());
        if (v2.length > 0) refs = v2;
      }
    }
    return refs;
  }

  async fetchPacks(
    url: string,
    want: string[],
    have: string[],
    depth?: number,
    auth?: ConnectionAuth,
    filter?: string,
    opts?: FetchPacksOptions,
  ): Promise<Uint8Array> {
    const base = this.url(url, auth).replace(/\/$/, "");
    const body = buildUploadPackBody(want, have, depth, filter);
    const res = await this.smartFetch(`${base}/git-upload-pack`, {
      method: "POST",
      headers: {
        ...this.headers(auth),
        "content-type": "application/x-git-upload-pack-request",
        accept: "application/x-git-upload-pack-result",
      },
      body,
    });
    if (!res.ok) {
      throw new Error(`git: upload-pack failed: HTTP ${res.status}`);
    }
    const max = resolveHttpMaxBytes(opts?.maxBytes);
    // Stream body when available; size-cap during read; optional pack sink.
    return readPackFromResponse(res, max, opts?.onPackChunk);
  }

  async pushPacks(
    url: string,
    commands: PushCommand[],
    pack: Uint8Array,
    auth?: ConnectionAuth,
    capabilities: string[] = [],
  ): Promise<ReceiveStatus> {
    const base = this.url(url, auth).replace(/\/$/, "");
    const requestedStatus = receiveStatusCapability(capabilities);
    const body = buildReceivePackBody(commands, pack, requestedStatus);
    let res: Response;
    try {
      res = await this.smartFetch(`${base}/git-receive-pack`, {
        method: "POST",
        headers: {
          ...this.headers(auth),
          "content-type": "application/x-git-receive-pack-request",
          accept: "application/x-git-receive-pack-result",
        },
        body,
      });
    } catch (e) {
      if (isRedirectError(e)) {
        return { ok: false, message: String((e as Error).message) };
      }
      throw e;
    }
    if (!res.ok) {
      return { ok: false, message: `HTTP ${res.status}` };
    }
    const text = await res.text();
    return parseReceiveStatus(text, requestedStatus !== undefined);
  }
}

// ── Redirect helpers ────────────────────────────────────────────────────────

/**
 * True when a Response is a redirect hop that product smart-HTTP must not follow.
 * Covers 3xx statuses and browser `opaqueredirect` (status 0) under `redirect: "manual"`.
 */
export function isRedirectResponse(res: { status: number; type?: string }): boolean {
  if (res.type === "opaqueredirect") return true;
  return res.status >= 300 && res.status < 400;
}

function isRedirectError(e: unknown): boolean {
  return e instanceof Error && e.message.includes("redirect not allowed");
}

// ── Protocol parse / build ──────────────────────────────────────────────────

/** Parse smart receive-pack report-status body (pkt-line or plain). */
export function parseReceiveStatus(text: string, required: boolean): ReceiveStatus {
  const lines = decodePktOrPlainLines(text);
  const unpack = lines.find((l) => l.startsWith("unpack "));
  if (unpack && unpack !== "unpack ok") {
    return { ok: false, message: unpack.slice(0, 200) };
  }
  const ng = lines.find((l) => l.startsWith("ng "));
  if (ng) return { ok: false, message: ng.slice(0, 200) };
  if (required && !unpack) {
    return { ok: false, message: "missing report-status" };
  }
  // When report-status was not negotiated, HTTP success is the only receipt.
  return { ok: true, message: "ok" };
}

function decodePktOrPlainLines(text: string): string[] {
  const out: string[] = [];
  let i = 0;
  while (i + 4 <= text.length) {
    const hex = text.slice(i, i + 4);
    if (!/^[0-9a-fA-F]{4}$/.test(hex)) break;
    const n = parseInt(hex, 16);
    if (n === 0) {
      i += 4;
      continue;
    }
    if (n < 4 || i + n > text.length) break;
    const body = text.slice(i + 4, i + n).replace(/\n$/, "");
    if (body) out.push(body);
    i += n;
  }
  if (!out.length) {
    for (const line of text.split("\n")) {
      const t = line.trim();
      if (t) out.push(t);
    }
  }
  return out;
}

function parseInfoRefs(text: string): RefAdvertisement[] {
  const refs: RefAdvertisement[] = [];
  // Smart HTTP advertisements are pkt-line streams. Splitting the raw body on
  // newlines leaves the flush packet (`0000`) attached to the first ref and can
  // silently discard the only advertised branch (and its capabilities).
  for (const raw of decodePktOrPlainLines(text)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    if (line.includes("git-upload-pack") || line.includes("git-receive-pack")) continue;
    const m = line.match(/^([0-9a-f]{40})\s+(.+)$/i);
    if (!m) continue;
    const [name = "", capabilityText = ""] = m[2]!.split("\0", 2);
    if (name === "HEAD" || name.startsWith("refs/")) {
      const capabilities = capabilityText.trim().split(/\s+/).filter(Boolean);
      refs.push({
        name,
        hash: m[1]!,
        ...(capabilities.length ? { capabilities } : {}),
      });
    }
  }
  return refs;
}

function pkt(s: string): string {
  const body = s + "\n";
  const len = (body.length + 4).toString(16).padStart(4, "0");
  return len + body;
}

/**
 * Build git-upload-pack request body (protocol v0/v1 style).
 * Optional `filter` (partial clone) is sent after wants when set;
 * first want advertises the `filter` capability. Servers that ignore
 * filter still return a usable full pack (fixture path).
 */
export function buildUploadPackBody(
  want: string[],
  have: string[],
  depth?: number,
  filter?: string,
): Uint8Array {
  let s = "";
  for (let i = 0; i < want.length; i++) {
    const w = want[i]!;
    if (i === 0 && filter) s += pkt(`want ${w} filter`);
    else s += pkt(`want ${w}`);
  }
  if (depth && depth > 0) s += pkt(`deepen ${depth}`);
  if (filter) s += pkt(`filter ${filter}`);
  s += "0000";
  for (const h of have) s += pkt(`have ${h}`);
  s += pkt("done");
  return new TextEncoder().encode(s);
}

function receiveStatusCapability(advertised: string[]): string | undefined {
  const supported = new Set(advertised);
  return ["report-status-v2", "report-status"].find((capability) => supported.has(capability));
}

function buildReceivePackBody(
  commands: PushCommand[],
  pack: Uint8Array,
  requested: string | undefined,
): Uint8Array {
  let s = "";
  for (let i = 0; i < commands.length; i++) {
    const c = commands[i]!;
    if (i === 0 && requested) {
      s += pkt(`${c.oldHash} ${c.newHash} ${c.name}\0${requested}`);
    } else {
      s += pkt(`${c.oldHash} ${c.newHash} ${c.name}`);
    }
  }
  s += "0000";
  const head = new TextEncoder().encode(s);
  const out = new Uint8Array(head.length + pack.length);
  out.set(head, 0);
  out.set(pack, head.length);
  return out;
}

// ── Pack body extraction ────────────────────────────────────────────────────

/** Locate first `PACK` magic offset, or -1. */
export function indexOfPackMagic(buf: Uint8Array, from = 0): number {
  for (let i = from; i + 4 <= buf.length; i++) {
    if (buf[i] === 0x50 && buf[i + 1] === 0x41 && buf[i + 2] === 0x43 && buf[i + 3] === 0x4b) {
      return i;
    }
  }
  return -1;
}

/**
 * Slice at PACK magic. When PACK_MAGIC_REQUIRED (contracts/git.kdl), missing magic fails.
 * Dual-host: BEAM locate_pack_offset → :no_pack_magic.
 */
function extractPack(buf: Uint8Array): Uint8Array {
  const i = indexOfPackMagic(buf);
  if (i >= 0) return buf.subarray(i);
  if (PACK_MAGIC_REQUIRED) {
    throw new Error("git: no PACK magic in upload-pack body");
  }
  return buf;
}

function concatBytes(parts: Uint8Array[], total: number): Uint8Array {
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.byteLength;
  }
  return out;
}

function copyBytes(src: Uint8Array): Uint8Array {
  const out = new Uint8Array(src.byteLength);
  out.set(src);
  return out as Uint8Array;
}

/**
 * Fail-closed body + pack read for upload-pack responses.
 *
 * - Prefers `response.body` stream when present (no single giant arrayBuffer).
 * - Caps **pack** size (bytes from `PACK` magic) at `maxBytes` (`0` = unlimited).
 * - Also caps pre-PACK prefix so a non-pack flood cannot grow unbounded.
 * - When `onPackChunk` is set, emits pack-aligned slices as they arrive so the
 *   orchestrator can call `engine.importPack` incrementally.
 */
export async function readPackFromResponse(
  res: {
    body?: ReadableStream<Uint8Array> | null;
    arrayBuffer: () => Promise<ArrayBuffer>;
    headers?: { get(name: string): string | null };
  },
  maxBytes: number,
  onPackChunk?: (chunk: Uint8Array) => void | Promise<void>,
): Promise<Uint8Array> {
  const declared = res.headers?.get?.("content-length");
  if (declared != null && maxBytes > 0) {
    const n = Number(declared);
    if (Number.isFinite(n) && n > maxBytes) {
      throw new Error(
        `git: pack ${n} bytes exceeds maxPackBytes ${maxBytes} (opt-in higher limit)`,
      );
    }
  }

  const reader = res.body?.getReader?.();
  if (!reader) {
    // No stream (or polyfill without body): bounded one-shot buffer.
    const raw = new Uint8Array(await res.arrayBuffer());
    if (maxBytes > 0 && raw.byteLength > maxBytes) {
      throw new Error(
        `git: pack ${raw.byteLength} bytes exceeds maxPackBytes ${maxBytes} (opt-in higher limit)`,
      );
    }
    const pack = extractPack(raw);
    if (maxBytes > 0 && pack.byteLength > maxBytes) {
      throw new Error(
        `git: pack ${pack.byteLength} bytes exceeds maxPackBytes ${maxBytes} (opt-in higher limit)`,
      );
    }
    if (onPackChunk && pack.byteLength > 0) {
      await onPackChunk(pack);
    }
    return pack.byteLength === raw.byteLength && pack.byteOffset === 0 ? pack : copyBytes(pack);
  }

  const packParts: Uint8Array[] = [];
  let packTotal = 0;
  // Explicit ArrayBufferLike so stream chunk types assign cleanly (TS 5.7+).
  let pending: Uint8Array = new Uint8Array(0);
  let inPack = false;
  /** All response body bytes observed (prefix + pack); fail-closed flood guard. */
  let bodyTotal = 0;

  const exceed = (n: number): Error =>
    new Error(`git: pack ${n} bytes exceeds maxPackBytes ${maxBytes} (opt-in higher limit)`);

  const pushPack = async (slice: Uint8Array): Promise<void> => {
    if (!slice.byteLength) return;
    if (maxBytes > 0 && packTotal > maxBytes - slice.byteLength) {
      await reader.cancel().catch(() => undefined);
      throw exceed(packTotal + slice.byteLength);
    }
    const owned = copyBytes(slice);
    packParts.push(owned);
    packTotal += owned.byteLength;
    if (onPackChunk) await onPackChunk(owned);
  };

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value || value.byteLength === 0) continue;

      bodyTotal += value.byteLength;
      // Cap total body as well as pack: non-pack flood cannot grow unbounded.
      if (maxBytes > 0 && bodyTotal > maxBytes) {
        await reader.cancel().catch(() => undefined);
        throw exceed(bodyTotal);
      }

      if (!inPack) {
        const joined =
          pending.byteLength === 0
            ? value
            : concatBytes([pending, value], pending.byteLength + value.byteLength);
        const idx = indexOfPackMagic(joined);
        if (idx < 0) {
          // Keep last 3 bytes for PACK magic spanning chunk boundaries.
          pending =
            joined.byteLength > 3
              ? copyBytes(joined.subarray(joined.byteLength - 3))
              : copyBytes(joined);
          continue;
        }
        inPack = true;
        pending = new Uint8Array(0);
        await pushPack(joined.subarray(idx));
      } else {
        await pushPack(value);
      }
    }
  } catch (e) {
    await reader.cancel().catch(() => undefined);
    throw e;
  }

  if (!inPack) {
    // Dual-host with BEAM :no_pack_magic — never soft-accept non-PACK bodies.
    if (PACK_MAGIC_REQUIRED) {
      throw new Error("git: no PACK magic in upload-pack body");
    }
    if (pending.byteLength) {
      await pushPack(pending);
    }
  }

  if (packTotal === 0) return new Uint8Array(0);
  return concatBytes(packParts, packTotal);
}
