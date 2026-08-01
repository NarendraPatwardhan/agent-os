/**
 * Host smart-HTTP (browser/JS) — ListRefs + FetchPacks + PushPacks (GIT.md PR9/PR12).
 * Server twin is BEAM `AgentOS.Git.SmartHttp` (OTP `:httpc`). Credentials spliced
 * only via request headers (PR11) — never into the URL for product remotes.
 *
 * ## Security / D3 redirect policy (fail-closed)
 *
 * Product smart-HTTP **never follows redirects**. Every `fetch` uses
 * `redirect: "manual"`, and any 3xx / `opaqueredirect` response is rejected as
 * `redirect not allowed` without reading `Location` or issuing a second request.
 * Open redirect to a non-allowlisted origin is therefore impossible: there is
 * no hop, so no allowlist re-check is required. (An alternate design would
 * re-validate origin on each hop; product remotes prefer reject-all.)
 *
 * Dual-host: BEAM sets `:httpc` `autoredirect: false` and classifies 3xx as
 * `:redirect_not_allowed` — same policy surface.
 */

import type { ConnectionAuth } from "../types.js";
import { spliceCredentialHeaders, spliceCredentialUrl } from "./connections.js";
import { DEFAULT_MAX_PACK_BYTES } from "./pack-cache.js";

export interface RefAdvertisement {
  name: string;
  hash: string;
  peeled?: string;
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
 * Options for product {@link FetchSmartHttp.fetchPacks} (D11 stream path).
 * Fixture transport ignores these; size gate still applies at import.
 */
export interface FetchPacksOptions {
  /**
   * Max pack bytes after PACK magic (and total body while scanning).
   * Default {@link DEFAULT_MAX_PACK_BYTES} (64 MiB). `0` = unlimited.
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
  listRefs(url: string, auth?: ConnectionAuth): Promise<RefAdvertisement[]>;
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
  ): Promise<ReceiveStatus>;
}

/** In-memory test double (shared algorithm with C fixtures). */
export class FixtureSmartHttp implements SmartHttpTransport {
  private readonly fixtures = new Map<
    string,
    { refs: RefAdvertisement[]; pack: Uint8Array }
  >();
  lastAuth: ConnectionAuth | undefined;
  lastPush:
    | { url: string; commands: PushCommand[]; packLen: number; pack: Uint8Array }
    | undefined;
  /** Last fetchPacks args (filter ignored for body; recorded for R36). */
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

  async listRefs(url: string, auth?: ConnectionAuth): Promise<RefAdvertisement[]> {
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
    const max =
      opts?.maxBytes === undefined ? DEFAULT_MAX_PACK_BYTES : opts.maxBytes;
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

/** Optional `fetch` inject for tests (redirect mock / offline). */
export type FetchImpl = (
  input: string | URL | Request,
  init?: RequestInit,
) => Promise<Response>;

/**
 * Public HTTPS smart-HTTP using fetch (browser/Node) with optional credential splice.
 *
 * D3: always `redirect: "manual"`; 3xx / opaqueredirect → hard fail (never follow).
 */
export class FetchSmartHttp implements SmartHttpTransport {
  private readonly fetchImpl: FetchImpl;

  constructor(
    private readonly defaultAuth?: ConnectionAuth,
    fetchImpl?: FetchImpl,
  ) {
    this.fetchImpl =
      fetchImpl ??
      ((input, init) => globalThis.fetch(input as RequestInfo, init));
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
  private async smartFetch(
    input: string,
    init: RequestInit = {},
  ): Promise<Response> {
    const res = await this.fetchImpl(input, {
      ...init,
      // Fail-closed: caller inspects status; browser never follows Location.
      redirect: "manual",
    });
    if (isRedirectResponse(res)) {
      throw new Error(
        `git: redirect not allowed (HTTP ${res.status || "opaque"}; open redirect blocked)`,
      );
    }
    return res;
  }

  async listRefs(url: string, auth?: ConnectionAuth): Promise<RefAdvertisement[]> {
    const base = this.url(url, auth).replace(/\/$/, "");
    const hdrs = this.headers(auth);
    const infoUrl = `${base}/info/refs?service=git-upload-pack`;
    // Prefer classic v0/v1 advertise (matches BEAM SmartHttp). Optional v2
    // probe is only used when the classic body parses empty — real git-http-backend
    // returns a 200 v2 capability dump when `Git-Protocol: version=2` is set, which
    // is not a ref list (D27).
    let res = await this.smartFetch(infoUrl, { headers: hdrs });
    if (!res.ok) {
      throw new Error(`git: list-refs failed: HTTP ${res.status}`);
    }
    let refs = parseInfoRefs(await res.text());
    if (refs.length === 0) {
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
    const max =
      opts?.maxBytes === undefined ? DEFAULT_MAX_PACK_BYTES : opts.maxBytes;
    // D11: stream body when available; size-cap during read; optional pack sink.
    return readPackFromResponse(res, max, opts?.onPackChunk);
  }

  async pushPacks(
    url: string,
    commands: PushCommand[],
    pack: Uint8Array,
    auth?: ConnectionAuth,
  ): Promise<ReceiveStatus> {
    const base = this.url(url, auth).replace(/\/$/, "");
    const body = buildReceivePackBody(commands, pack);
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
    return parseReceiveStatus(text);
  }
}

/**
 * True when a Response is a redirect hop that product smart-HTTP must not follow.
 * Covers 3xx statuses and browser `opaqueredirect` (status 0) under `redirect: "manual"`.
 */
export function isRedirectResponse(res: {
  status: number;
  type?: string;
}): boolean {
  if (res.type === "opaqueredirect") return true;
  return res.status >= 300 && res.status < 400;
}

function isRedirectError(e: unknown): boolean {
  return e instanceof Error && e.message.includes("redirect not allowed");
}

/** Parse smart receive-pack report-status body (pkt-line or plain). */
export function parseReceiveStatus(text: string): ReceiveStatus {
  const lines = decodePktOrPlainLines(text);
  const unpack = lines.find((l) => l.startsWith("unpack "));
  if (unpack && unpack !== "unpack ok") {
    return { ok: false, message: unpack.slice(0, 200) };
  }
  const ng = lines.find((l) => l.startsWith("ng "));
  if (ng) return { ok: false, message: ng.slice(0, 200) };
  // No report-status: treat as ok if no explicit failure markers.
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
  for (const raw of text.split("\n")) {
    let line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    if (/^[0-9a-fA-F]{4}/.test(line) && line.length > 4) line = line.slice(4);
    if (line.includes("git-upload-pack") || line.includes("git-receive-pack")) continue;
    const m = line.match(/^([0-9a-f]{40})\s+(\S+)/i);
    if (!m) continue;
    const name = m[2]!.split("\0")[0]!;
    if (name === "HEAD" || name.startsWith("refs/")) {
      refs.push({ name, hash: m[1]! });
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
 * Optional `filter` (R36 partial clone) is sent after wants when set;
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

function buildReceivePackBody(commands: PushCommand[], pack: Uint8Array): Uint8Array {
  // First command advertises report-status so real git-receive-pack (D28)
  // returns unpack/ok pkt-lines; subsequent commands are bare.
  let s = "";
  for (let i = 0; i < commands.length; i++) {
    const c = commands[i]!;
    if (i === 0) {
      s += pkt(`${c.oldHash} ${c.newHash} ${c.name}\0report-status`);
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

/** Locate first `PACK` magic offset, or -1. */
export function indexOfPackMagic(buf: Uint8Array, from = 0): number {
  for (let i = from; i + 4 <= buf.length; i++) {
    if (
      buf[i] === 0x50 &&
      buf[i + 1] === 0x41 &&
      buf[i + 2] === 0x43 &&
      buf[i + 3] === 0x4b
    ) {
      return i;
    }
  }
  return -1;
}

function extractPack(buf: Uint8Array): Uint8Array {
  const i = indexOfPackMagic(buf);
  return i >= 0 ? buf.subarray(i) : buf;
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
 * Fail-closed body + pack read for upload-pack responses (D11).
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
    return pack.byteLength === raw.byteLength && pack.byteOffset === 0
      ? pack
      : copyBytes(pack);
  }

  const packParts: Uint8Array[] = [];
  let packTotal = 0;
  // Explicit ArrayBufferLike so stream chunk types assign cleanly (TS 5.7+).
  let pending: Uint8Array = new Uint8Array(0);
  let inPack = false;
  /** All response body bytes observed (prefix + pack); fail-closed flood guard. */
  let bodyTotal = 0;

  const exceed = (n: number): Error =>
    new Error(
      `git: pack ${n} bytes exceeds maxPackBytes ${maxBytes} (opt-in higher limit)`,
    );

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
            : concatBytes(
                [pending, value],
                pending.byteLength + value.byteLength,
              );
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
    // No PACK magic — treat entire body as pack (same as extractPack fallback).
    if (pending.byteLength) {
      await pushPack(pending);
    }
  }

  if (packTotal === 0) return new Uint8Array(0);
  return concatBytes(packParts, packTotal);
}
