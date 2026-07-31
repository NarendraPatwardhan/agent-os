/**
 * Host smart-HTTP (browser/JS) — ListRefs + FetchPacks + PushPacks (GIT.md PR9/PR12).
 * Server twin is C ge_http_*. Credentials spliced only via request headers (PR11).
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
    | { url: string; commands: PushCommand[]; packLen: number }
    | undefined;
  pushResult: ReceiveStatus = { ok: true };

  add(url: string, refs: RefAdvertisement[], pack: Uint8Array): void {
    this.fixtures.set(url, { refs, pack });
  }

  clear(): void {
    this.fixtures.clear();
    this.lastAuth = undefined;
    this.lastPush = undefined;
  }

  async listRefs(url: string, auth?: ConnectionAuth): Promise<RefAdvertisement[]> {
    this.lastAuth = auth;
    const f = this.fixtures.get(url);
    if (!f) throw new Error(`git: list-refs failed: no fixture for ${url}`);
    return f.refs.map((r) => ({ ...r }));
  }

  async fetchPacks(
    url: string,
    _want: string[],
    _have: string[],
    _depth?: number,
    auth?: ConnectionAuth,
  ): Promise<Uint8Array> {
    this.lastAuth = auth;
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
    this.lastPush = { url, commands, packLen: pack.byteLength };
    return this.pushResult;
  }
}

/**
 * Public HTTPS smart-HTTP using fetch (browser/Node) with optional credential splice.
 */
export class FetchSmartHttp implements SmartHttpTransport {
  constructor(private readonly defaultAuth?: ConnectionAuth) {}

  private headers(auth?: ConnectionAuth): Record<string, string> {
    return spliceCredentialHeaders(auth ?? this.defaultAuth ?? { kind: "none" });
  }

  private url(url: string, auth?: ConnectionAuth): string {
    return spliceCredentialUrl(url, auth ?? this.defaultAuth ?? { kind: "none" });
  }

  async listRefs(url: string, auth?: ConnectionAuth): Promise<RefAdvertisement[]> {
    const base = this.url(url, auth).replace(/\/$/, "");
    const hdrs = this.headers(auth);
    const infoUrl = `${base}/info/refs?service=git-upload-pack`;
    let res = await fetch(infoUrl, {
      headers: { ...hdrs, "git-protocol": "version=2" },
    });
    if (!res.ok) {
      res = await fetch(`${base}/info/refs?service=git-upload-pack`, { headers: hdrs });
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
  ): Promise<Uint8Array> {
    const base = this.url(url, auth).replace(/\/$/, "");
    const body = buildUploadPackBody(want, have, depth);
    const res = await fetch(`${base}/git-upload-pack`, {
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
    const res = await fetch(`${base}/git-receive-pack`, {
      method: "POST",
      headers: {
        ...this.headers(auth),
        "content-type": "application/x-git-receive-pack-request",
        accept: "application/x-git-receive-pack-result",
      },
      body,
    });
    if (!res.ok) {
      return { ok: false, message: `HTTP ${res.status}` };
    }
    const text = await res.text();
    return parseReceiveStatus(text);
  }
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

function buildUploadPackBody(
  want: string[],
  have: string[],
  depth?: number,
): Uint8Array {
  let s = "";
  for (const w of want) s += pkt(`want ${w}`);
  if (depth && depth > 0) s += pkt(`deepen ${depth}`);
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
