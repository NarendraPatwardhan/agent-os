// @mc/core/drivers — host-backed mount drivers. Each
// builder returns a {@link Driver} the kernel's `MountFs` proxies VFS ops to over
// the host-call bridge. Embedded-first; all run in the consumer's process.
//
//   import { s3, hostDir, vectorStore } from "@mc/core/drivers";
//   const vm = await mc.create({ mounts: [{ path: "/mnt/data", driver: s3({ bucket }) }] });

import * as fs from "node:fs/promises";
import * as nodePath from "node:path";

import type { Driver, DriverEntry, DriverError } from "./types.js";

/** Build a {@link DriverError} carrying a POSIX `code` the kernel maps to errno. */
function driverError(code: DriverError["code"], message: string): DriverError {
  const e = new Error(message) as DriverError;
  e.code = code;
  return e;
}

const FS_CODES = ["ENOENT", "EACCES", "EEXIST", "ENOTDIR", "EISDIR", "ENOTEMPTY", "EINVAL"] as const;

/** Map a Node `fs` error to a {@link DriverError} (Node already uses POSIX codes). */
function mapFsError(e: unknown): DriverError {
  const code = (e as NodeJS.ErrnoException | undefined)?.code;
  const out = new Error((e as Error)?.message ?? "filesystem error") as DriverError;
  out.code = (FS_CODES as readonly string[]).includes(code ?? "")
    ? (code as DriverError["code"])
    : undefined;
  return out;
}

// ---------------------------------------------------------------------------
// hostDir — a real local directory, jailed under `root`.
// ---------------------------------------------------------------------------

export interface HostDirOptions {
  /** The real host directory to expose. */
  root: string;
  /** Mount read-only (also enforced kernel-side via the mount flag). */
  readOnly?: boolean;
}

/** A driver backed by a real host directory (`node:fs`). Every mount-relative
 *  path is resolved under `root` and rejected if it escapes (a jailed root). */
export function hostDir(opts: HostDirOptions): Driver {
  const root = nodePath.resolve(opts.root);
  const rootReal = fs.realpath(root);
  const lexical = (rel: string): string => {
    const norm = rel.startsWith("/") ? rel : `/${rel}`;
    const p = nodePath.resolve(root, `.${norm}`);
    if (p !== root && !p.startsWith(root + nodePath.sep)) {
      throw driverError("EACCES", `path escapes mount root: ${rel}`);
    }
    return p;
  };
  const checkInside = async (p: string, rel: string): Promise<void> => {
    const rr = await rootReal;
    if (p !== rr && !p.startsWith(rr + nodePath.sep)) {
      throw driverError("EACCES", `path escapes mount root: ${rel}`);
    }
  };
  const existing = async (rel: string): Promise<string> => {
    const p = lexical(rel);
    const st = await fs.lstat(p);
    if (p !== root && st.isSymbolicLink()) {
      throw driverError("EACCES", `symlink escapes are not exposed by hostDir: ${rel}`);
    }
    await checkInside(await fs.realpath(p), rel);
    return p;
  };
  const parentChecked = async (rel: string): Promise<string> => {
    const p = lexical(rel);
    await checkInside(await fs.realpath(nodePath.dirname(p)), rel);
    return p;
  };
  const writeTarget = async (rel: string): Promise<string> => {
    const p = lexical(rel);
    try {
      const st = await fs.lstat(p);
      if (p !== root && st.isSymbolicLink()) {
        throw driverError("EACCES", `symlink escapes are not exposed by hostDir: ${rel}`);
      }
      await checkInside(await fs.realpath(p), rel);
    } catch (e) {
      if ((e as NodeJS.ErrnoException | undefined)?.code !== "ENOENT") throw e;
      await parentChecked(rel);
    }
    return p;
  };
  return {
    readOnly: opts.readOnly,
    async open(path) {
      try {
        return new Uint8Array(await fs.readFile(await existing(path)));
      } catch (e) {
        throw mapFsError(e);
      }
    },
    async stat(path) {
      try {
        const st = await fs.stat(await existing(path));
        return { kind: st.isDirectory() ? "dir" : "file", size: st.size };
      } catch (e) {
        throw mapFsError(e);
      }
    },
    async readdir(path) {
      try {
        const ents = await fs.readdir(await existing(path), { withFileTypes: true });
        return ents
          .filter((d) => !d.isSymbolicLink())
          .map((d): DriverEntry => ({ name: d.name, kind: d.isDirectory() ? "dir" : "file" }));
      } catch (e) {
        throw mapFsError(e);
      }
    },
    async write(path, data) {
      try {
        await fs.writeFile(await writeTarget(path), data);
      } catch (e) {
        throw mapFsError(e);
      }
    },
    async mkdir(path) {
      try {
        await fs.mkdir(await parentChecked(path));
      } catch (e) {
        throw mapFsError(e);
      }
    },
    async unlink(path) {
      try {
        const p = await parentChecked(path);
        const st = await fs.lstat(p);
        if (st.isDirectory() && !st.isSymbolicLink()) await fs.rmdir(p);
        else await fs.unlink(p);
      } catch (e) {
        throw mapFsError(e);
      }
    },
    async rename(from, to) {
      try {
        await fs.rename(await parentChecked(from), await parentChecked(to));
      } catch (e) {
        throw mapFsError(e);
      }
    },
  };
}

// ---------------------------------------------------------------------------
// s3 — a real S3 bucket over SigV4-signed `fetch` (no SDK dependency, no mocks).
// ---------------------------------------------------------------------------

export interface S3Options {
  bucket: string;
  region?: string;
  /** Key prefix prepended to every path (a sub-tree of the bucket). */
  prefix?: string;
  /** Static credentials. Omitted → an anonymous client (public-read buckets). */
  credentials?: { accessKeyId: string; secretAccessKey: string; sessionToken?: string };
  readOnly?: boolean;
}

const toHex = (b: Uint8Array): string =>
  Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");

async function sha256Hex(data: Uint8Array | string): Promise<string> {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  return toHex(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as BufferSource)));
}

async function hmac(key: Uint8Array, data: string): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey(
    "raw",
    key as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return new Uint8Array(
    await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(data) as BufferSource),
  );
}

/** Percent-encode per RFC 3986 (AWS canonical form); keeps `/` only when asked. */
function uriEncode(str: string, keepSlash: boolean): string {
  let out = "";
  for (const ch of str) {
    if (/[A-Za-z0-9\-_.~]/.test(ch) || (keepSlash && ch === "/")) out += ch;
    else for (const b of new TextEncoder().encode(ch)) out += `%${b.toString(16).toUpperCase().padStart(2, "0")}`;
  }
  return out;
}

function canonicalQuery(params: Array<[string, string]>): string {
  return params
    .map(([k, v]) => [uriEncode(k, false), uriEncode(v, false)] as const)
    .sort(([ak, av], [bk, bv]) => (ak === bk ? av.localeCompare(bv) : ak.localeCompare(bk)))
    .map(([k, v]) => `${k}=${v}`)
    .join("&");
}

/** Encode an S3 key as a request path: each segment URI-encoded, with a `.` or
 *  `..` segment force-encoded to `%2E`/`%2E%2E`. Without this, `fetch`/`URL`
 *  collapse literal `.`/`..` segments (`/a/./b` → `/a/b`), which both fetches the
 *  wrong object AND breaks the SigV4 signature (the sent path ≠ the signed path).
 *  S3 percent-decodes the key, so `%2E` round-trips to the intended dot. */
function s3KeyPath(key: string): string {
  return key
    .split("/")
    .map((seg) => (seg === "." || seg === ".." ? seg.replace(/\./g, "%2E") : uriEncode(seg, false)))
    .join("/");
}

/** Minimal extraction of repeated `<tag>…</tag>` text bodies from S3's XML. */
function xmlAll(xml: string, tag: string): string[] {
  const re = new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`, "g");
  const out: string[] = [];
  for (let m = re.exec(xml); m; m = re.exec(xml)) out.push(m[1] ?? "");
  return out;
}

const xmlDecode = (s: string): string =>
  s
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'");

/** A driver backed by a real S3 bucket. Reads need no credentials for a
 *  public-read bucket; writes/auth use SigV4 with the supplied credentials. */
export function s3(opts: S3Options): Driver {
  const region = opts.region ?? "us-east-1";
  const host = `${opts.bucket}.s3.${region}.amazonaws.com`;
  const basePrefix = (opts.prefix ?? "").replace(/^\/+|\/+$/g, "");

  // Map a mount-relative path to an S3 key (prefix + path, no leading slash).
  const keyOf = (path: string): string => {
    const rel = path.replace(/^\/+/, "");
    return basePrefix ? (rel ? `${basePrefix}/${rel}` : basePrefix) : rel;
  };

  async function send(
    method: string,
    canonicalUri: string,
    query: string,
    body?: Uint8Array,
    extraHeaders?: Record<string, string>,
  ): Promise<Response> {
    const url = `https://${host}${canonicalUri}${query ? `?${query}` : ""}`;
    // Anonymous public-bucket access must stay a CORS-simple request. Adding the
    // SigV4-only x-amz-* headers here would force a browser preflight even though
    // there is no credential or signature; open-data buckets commonly allow
    // anonymous GET/HEAD but intentionally reject those unnecessary headers.
    if (!opts.credentials) {
      return fetch(url, {
        method,
        ...(extraHeaders ? { headers: extraHeaders } : {}),
        ...(body ? { body: body as BodyInit } : {}),
      });
    }

    const payload = body ?? new Uint8Array(0);
    const payloadHash = await sha256Hex(payload);
    const now = new Date();
    const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, "");
    const dateStamp = amzDate.slice(0, 8);

    const headers: Record<string, string> = {
      host,
      "x-amz-content-sha256": payloadHash,
      "x-amz-date": amzDate,
      ...(extraHeaders ?? {}),
    };
    if (opts.credentials?.sessionToken) headers["x-amz-security-token"] = opts.credentials.sessionToken;

    const signedHeaderNames = Object.keys(headers)
      .map((h) => h.toLowerCase())
      .sort();
    const canonicalHeaders = signedHeaderNames.map((h) => `${h}:${headers[h]}\n`).join("");
    const signedHeaders = signedHeaderNames.join(";");
    const canonicalRequest = [
      method,
      canonicalUri,
      query,
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join("\n");

    if (opts.credentials) {
      const scope = `${dateStamp}/${region}/s3/aws4_request`;
      const stringToSign = [
        "AWS4-HMAC-SHA256",
        amzDate,
        scope,
        await sha256Hex(canonicalRequest),
      ].join("\n");
      const kDate = await hmac(
        new TextEncoder().encode(`AWS4${opts.credentials.secretAccessKey}`),
        dateStamp,
      );
      const kRegion = await hmac(kDate, region);
      const kService = await hmac(kRegion, "s3");
      const signingKey = await hmac(kService, "aws4_request");
      const signature = toHex(await hmac(signingKey, stringToSign));
      headers.authorization =
        `AWS4-HMAC-SHA256 Credential=${opts.credentials.accessKeyId}/${scope}, ` +
        `SignedHeaders=${signedHeaders}, Signature=${signature}`;
    }

    return fetch(url, { method, headers, body: body as BodyInit | undefined });
  }

  const notFound = (path: string) => driverError("ENOENT", `s3: no such object ${path}`);

  return {
    readOnly: opts.readOnly,
    async open(path) {
      const r = await send("GET", `/${s3KeyPath(keyOf(path))}`, "");
      if (r.status === 404) throw notFound(path);
      if (!r.ok) throw new Error(`s3 GET ${path}: ${r.status}`);
      return new Uint8Array(await r.arrayBuffer());
    },
    async stat(path) {
      // The mount root is always a directory — a HEAD on the bucket root (empty
      // key) returns 200 but is NOT an object, so special-case it before probing.
      if (path.replace(/^\/+|\/+$/g, "") === "") return { kind: "dir", size: 0 };
      // A trailing-slash listing tells dir-vs-file apart for prefixes.
      const r = await send("HEAD", `/${s3KeyPath(keyOf(path))}`, "");
      if (r.ok) {
        return { kind: "file", size: Number(r.headers.get("content-length") ?? 0) };
      }
      if (r.status === 404) {
        // Maybe a directory (a key prefix). Probe with a delimited list.
        const prefix = keyOf(path).replace(/\/?$/, "/");
        const q = canonicalQuery([
          ["delimiter", "/"],
          ["list-type", "2"],
          ["max-keys", "1"],
          ["prefix", prefix],
        ]);
        const lr = await send("GET", "/", q);
        const xml = await lr.text();
        if (lr.ok && (xml.includes("<Contents>") || xml.includes("<CommonPrefixes>"))) {
          return { kind: "dir", size: 0 };
        }
        throw notFound(path);
      }
      throw new Error(`s3 HEAD ${path}: ${r.status}`);
    },
    async readdir(path) {
      const raw = keyOf(path);
      const prefix = raw ? raw.replace(/\/?$/, "/") : "";
      const out: DriverEntry[] = [];
      // ListObjectsV2 returns at most 1000 keys per call; follow the continuation
      // token until exhausted so a directory with >1000 children isn't silently
      // truncated.
      let token: string | undefined;
      do {
        const q = canonicalQuery([
          ...(token ? ([["continuation-token", token]] as Array<[string, string]>) : []),
          ["delimiter", "/"],
          ["list-type", "2"],
          ["prefix", prefix],
        ]);
        const r = await send("GET", "/", q);
        const xml = await r.text();
        if (!r.ok) throw new Error(`s3 LIST ${path}: ${r.status}`);
        for (const block of xmlAll(xml, "CommonPrefixes")) {
          const p = xmlDecode(xmlAll(block, "Prefix")[0] ?? "");
          const name = p.slice(prefix.length).replace(/\/$/, "");
          if (name) out.push({ name, kind: "dir" });
        }
        for (const block of xmlAll(xml, "Contents")) {
          const k = xmlDecode(xmlAll(block, "Key")[0] ?? "");
          const name = k.slice(prefix.length);
          if (name && !name.includes("/")) out.push({ name, kind: "file" });
        }
        token =
          xmlAll(xml, "IsTruncated")[0] === "true"
            ? xmlDecode(xmlAll(xml, "NextContinuationToken")[0] ?? "")
            : undefined;
      } while (token);
      return out;
    },
    async write(path, data) {
      const r = await send("PUT", `/${s3KeyPath(keyOf(path))}`, "", data);
      if (!r.ok) throw driverError("EACCES", `s3 PUT ${path}: ${r.status}`);
    },
    async unlink(path) {
      const r = await send("DELETE", `/${s3KeyPath(keyOf(path))}`, "");
      if (!r.ok && r.status !== 404) throw new Error(`s3 DELETE ${path}: ${r.status}`);
    },
    async rename(from, to) {
      // S3 has no rename — CopyObject (a PUT to the destination carrying a signed
      // `x-amz-copy-source` header) then DELETE the source.
      const copySource = `/${opts.bucket}/${s3KeyPath(keyOf(from))}`;
      const cr = await send("PUT", `/${s3KeyPath(keyOf(to))}`, "", undefined, {
        "x-amz-copy-source": copySource,
      });
      if (!cr.ok) throw new Error(`s3 COPY ${from}->${to}: ${cr.status}`);
      const dr = await send("DELETE", `/${s3KeyPath(keyOf(from))}`, "");
      if (!dr.ok && dr.status !== 404) throw new Error(`s3 DELETE ${from}: ${dr.status}`);
    },
  };
}

// ---------------------------------------------------------------------------
// vectorStore — retrieval-as-a-file (RAG: `cat /rag/search/<q>`).
// ---------------------------------------------------------------------------

export interface VectorStoreOptions {
  /** Embed a query string into a vector (a real embedding API). */
  embed: (query: string) => Promise<number[]>;
  /** Search the index with a query vector; return formatted result lines. */
  search: (vector: number[], query: string) => Promise<string>;
  readOnly?: boolean;
}

/** A read-mostly driver exposing retrieval as files: `open("/search/<q>")` embeds
 *  `<q>` and returns the formatted hits. Mount it at e.g. `/rag` and the agent
 *  runs `cat '/rag/search/<question>'`. */
export function vectorStore(opts: VectorStoreOptions): Driver {
  return {
    readOnly: opts.readOnly ?? true,
    async open(path) {
      const m = /^\/?search\/(.+)$/.exec(path);
      if (!m?.[1]) throw driverError("ENOENT", `vectorStore: ${path} (expected /search/<query>)`);
      let query: string;
      try {
        query = decodeURIComponent(m[1]);
      } catch {
        throw driverError("EINVAL", `vectorStore: malformed query ${path}`);
      }
      const vector = await opts.embed(query);
      const text = await opts.search(vector, query);
      return new TextEncoder().encode(text.endsWith("\n") ? text : `${text}\n`);
    },
    async stat(path) {
      // `/` and `/search` are directories; everything under `/search/` is a file.
      if (path === "/" || path === "/search" || path === "search") return { kind: "dir", size: 0 };
      return { kind: "file", size: 0 };
    },
    async readdir(path) {
      if (path === "/" || path === "") return [{ name: "search", kind: "dir" }];
      return [];
    },
  };
}
