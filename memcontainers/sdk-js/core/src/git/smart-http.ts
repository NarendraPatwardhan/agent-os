/**
 * Host smart-HTTP (browser/JS) — ListRefs + FetchPacks (GIT.md PR9, K16).
 * Server twin is C ge_http_* (fixture transport). No credentials in v1.
 */

export interface RefAdvertisement {
  name: string;
  hash: string;
  peeled?: string;
}

export interface SmartHttpTransport {
  listRefs(url: string): Promise<RefAdvertisement[]>;
  fetchPacks(
    url: string,
    want: string[],
    have: string[],
    depth?: number,
  ): Promise<Uint8Array>;
}

/** In-memory test double (shared algorithm with C fixtures). */
export class FixtureSmartHttp implements SmartHttpTransport {
  private readonly fixtures = new Map<
    string,
    { refs: RefAdvertisement[]; pack: Uint8Array }
  >();

  add(url: string, refs: RefAdvertisement[], pack: Uint8Array): void {
    this.fixtures.set(url, { refs, pack });
  }

  clear(): void {
    this.fixtures.clear();
  }

  async listRefs(url: string): Promise<RefAdvertisement[]> {
    const f = this.fixtures.get(url);
    if (!f) throw new Error(`git: list-refs failed: no fixture for ${url}`);
    return f.refs.map((r) => ({ ...r }));
  }

  async fetchPacks(
    url: string,
    _want: string[],
    _have: string[],
    _depth?: number,
  ): Promise<Uint8Array> {
    const f = this.fixtures.get(url);
    if (!f) throw new Error(`git: upload-pack failed: no fixture for ${url}`);
    return f.pack.slice();
  }
}

/**
 * Public HTTPS smart-HTTP using fetch (browser/Node).
 * Minimal pkt-line info/refs + upload-pack; no credential splice (PR11).
 */
export class FetchSmartHttp implements SmartHttpTransport {
  async listRefs(url: string): Promise<RefAdvertisement[]> {
    const base = url.replace(/\/$/, "");
    const infoUrl = `${base}/info/refs?service=git-upload-pack`;
    const res = await fetch(infoUrl, {
      headers: { "git-protocol": "version=2" },
    });
    if (!res.ok) {
      // Fall back to v1 dumb/smart advertisement
      const res1 = await fetch(`${base}/info/refs?service=git-upload-pack`);
      if (!res1.ok) {
        throw new Error(`git: list-refs failed: HTTP ${res1.status}`);
      }
      const text = await res1.text();
      return parseInfoRefs(text);
    }
    const text = await res.text();
    return parseInfoRefs(text);
  }

  async fetchPacks(
    url: string,
    want: string[],
    have: string[],
    depth?: number,
  ): Promise<Uint8Array> {
    const base = url.replace(/\/$/, "");
    const body = buildUploadPackBody(want, have, depth);
    const res = await fetch(`${base}/git-upload-pack`, {
      method: "POST",
      headers: {
        "content-type": "application/x-git-upload-pack-request",
        accept: "application/x-git-upload-pack-result",
      },
      body,
    });
    if (!res.ok) {
      throw new Error(`git: upload-pack failed: HTTP ${res.status}`);
    }
    const buf = new Uint8Array(await res.arrayBuffer());
    return extractPack(buf);
  }
}

function parseInfoRefs(text: string): RefAdvertisement[] {
  const refs: RefAdvertisement[] = [];
  // Skip service banner lines; accept "hash name" lines (pkt-line or plain).
  for (const raw of text.split("\n")) {
    let line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    // pkt-line: 4 hex length prefix
    if (/^[0-9a-fA-F]{4}/.test(line) && line.length > 4) {
      line = line.slice(4);
    }
    if (line.startsWith("001e") || line.includes("git-upload-pack")) continue;
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

/** Strip sideband / pkt framing when present; otherwise return as-is. */
function extractPack(buf: Uint8Array): Uint8Array {
  // PACK signature
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
