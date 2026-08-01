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
  ): Promise<Uint8Array> {
    this.fetchPacksCalls += 1;
    this.lastAuth = auth;
    // Fixture ignores filter (no partial materialization) but does not break.
    this.lastFetch = { url, want: [...want], have: [...have], depth, filter };
    const f = this.fixtures.get(url);
    if (!f) throw new Error(`git: upload-pack failed: no fixture for ${url}`);
    return f.pack.slice();
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
    let res = await this.smartFetch(infoUrl, {
      headers: { ...hdrs, "git-protocol": "version=2" },
    });
    if (!res.ok) {
      // Retry without git-protocol header (v0/v1 servers) — still no redirects.
      res = await this.smartFetch(`${base}/info/refs?service=git-upload-pack`, {
        headers: hdrs,
      });
      if (!res.ok) {
        throw new Error(`git: list-refs failed: HTTP ${res.status}`);
      }
    }
    return parseInfoRefs(await res.text());
  }

  async fetchPacks(
    url: string,
    want: string[],
    have: string[],
    depth?: number,
    auth?: ConnectionAuth,
    filter?: string,
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
    return extractPack(new Uint8Array(await res.arrayBuffer()));
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
  let s = "";
  for (const c of commands) {
    s += pkt(`${c.oldHash} ${c.newHash} ${c.name}`);
  }
  s += "0000";
  const head = new TextEncoder().encode(s);
  const out = new Uint8Array(head.length + pack.length);
  out.set(head, 0);
  out.set(pack, head.length);
  return out;
}

function extractPack(buf: Uint8Array): Uint8Array {
  for (let i = 0; i + 4 <= buf.length; i++) {
    if (
      buf[i] === 0x50 &&
      buf[i + 1] === 0x41 &&
      buf[i + 2] === 0x43 &&
      buf[i + 3] === 0x4b
    ) {
      return buf.subarray(i);
    }
  }
  return buf;
}
