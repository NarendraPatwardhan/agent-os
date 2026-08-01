/** PR13 / D11–D12: pack cache digests + size gate + stream import + disk round-trip. */

import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import {
  DEFAULT_MAX_PACK_BYTES,
  DiskPackCache,
  MemoryPackCache,
  createDefaultProcessPackCache,
  defaultProcessPackCache,
  productDefaultPackCache,
  importPackCached,
  importPackStream,
  processPackCacheDirFromEnv,
  processPackCacheSharedFromEnv,
  uploadPackCacheKey,
} from "../src/git/pack-cache.js";
import {
  indexOfPackMagic,
  readPackFromResponse,
} from "../src/git/smart-http.js";

async function assertMemoryBasics(): Promise<void> {
  const cache = new MemoryPackCache();
  const pack = new Uint8Array([0x50, 0x41, 0x43, 0x4b, 1, 2, 3, 4]);
  const d1 = await cache.put(pack);
  if (!d1.startsWith("sha256:")) throw new Error(d1);
  if (!(await cache.has(d1))) throw new Error("has");
  const hit = await cache.get(d1);
  if (!hit || hit.length !== pack.length) throw new Error("get");

  const chunks: { len: number; final: boolean }[] = [];
  const fakeEngine = {
    async importPack(chunk: Uint8Array, meta?: { final?: boolean }) {
      chunks.push({ len: chunk.byteLength, final: !!meta?.final });
    },
  };
  const r = await importPackCached(fakeEngine, pack, {
    cache,
    chunkBytes: 3,
  });
  if (!r.fromCache) throw new Error("second put should hit cache path on import");
  if (chunks.length < 2) throw new Error(`expected chunked import, got ${JSON.stringify(chunks)}`);
  if (!chunks[chunks.length - 1]!.final) throw new Error("last chunk must final");

  let threw = false;
  try {
    await importPackCached(fakeEngine, new Uint8Array(DEFAULT_MAX_PACK_BYTES + 1), {
      maxPackBytes: DEFAULT_MAX_PACK_BYTES,
    });
  } catch {
    threw = true;
  }
  if (!threw) throw new Error("size gate should throw");

  await cache.putKey("upload-pack:v1:test", d1);
  if ((await cache.getByKey!("upload-pack:v1:test")) !== d1) {
    throw new Error("getByKey mismatch");
  }

  // Download-key: public url + wants + haves + depth — never credentials/token.
  const secret = "super-secret-token-xyz";
  const key = uploadPackCacheKey({
    url: "https://github.com/org/repo.git",
    wants: ["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
    haves: ["cccccccccccccccccccccccccccccccccccccccc"],
    depth: 1,
  });
  if (key.includes(secret)) throw new Error("key must not include credentials");
  if (key.includes("token") || key.includes("Authorization")) {
    throw new Error(`key must not include auth-ish substrings: ${key}`);
  }
  if (!key.startsWith("upload-pack:v1:https://github.com/org/repo.git:")) {
    throw new Error(`key prefix: ${key}`);
  }
  // wants sorted lowercase
  if (!key.includes("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")) {
    throw new Error(`wants order: ${key}`);
  }
  // Same wants different order → same key
  const key2 = uploadPackCacheKey({
    url: "https://github.com/org/repo.git",
    wants: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],
    haves: ["cccccccccccccccccccccccccccccccccccccccc"],
    depth: 1,
  });
  if (key !== key2) throw new Error(`key must be order-stable: ${key} vs ${key2}`);
}

/**
 * D12: DiskPackCache put/get/has/keys survive a second instance on the same dir
 * (process restart / cross-solve CA hit under bazel TEST_TMPDIR or os.tmpdir).
 */
async function assertDiskRoundTrip(): Promise<void> {
  const root =
    process.env.TEST_TMPDIR?.trim() ||
    process.env.TEST_UNDECLARED_OUTPUTS_DIR?.trim() ||
    tmpdir();
  const dir = await mkdtemp(join(root, "mc-pack-cache-"));
  try {
    const pack = new Uint8Array([0x50, 0x41, 0x43, 0x4b, 9, 8, 7, 6, 5]);
    const a = new DiskPackCache(dir);
    const digest = await a.put(pack);
    if (!digest.startsWith("sha256:")) throw new Error(`disk digest: ${digest}`);
    if (!(await a.has(digest))) throw new Error("disk has after put");
    const got = await a.get(digest);
    if (!got || got.length !== pack.length) throw new Error("disk get length");
    for (let i = 0; i < pack.length; i++) {
      if (got[i] !== pack[i]) throw new Error(`disk get byte ${i}`);
    }

    const dlKey = uploadPackCacheKey({
      url: "https://example.com/r.git",
      wants: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
      depth: 1,
    });
    await a.putKey(dlKey, digest);
    if ((await a.getByKey!(dlKey)) !== digest) {
      throw new Error("disk getByKey mismatch");
    }

    // Download-key filenames are SHA-256 hex of the full key string (not FNV-1a).
    const keyFiles = await readdir(join(dir, "keys"));
    if (keyFiles.length !== 1) {
      throw new Error(`expected one key file, got ${JSON.stringify(keyFiles)}`);
    }
    const keyName = keyFiles[0]!;
    if (!/^[0-9a-f]{64}\.key$/.test(keyName)) {
      throw new Error(`key filename must be 64-hex SHA-256: ${keyName}`);
    }
    // Stable path: same key → same filename (putKey again must not create a second file).
    await a.putKey(dlKey, digest);
    const keyFiles2 = await readdir(join(dir, "keys"));
    if (keyFiles2.length !== 1 || keyFiles2[0] !== keyName) {
      throw new Error(`key path must be stable: ${JSON.stringify(keyFiles2)} vs ${keyName}`);
    }
    // Independent compute of expected hex (parity with crypto.subtle SHA-256 of key UTF-8).
    const expectedHex = Array.from(
      new Uint8Array(
        await crypto.subtle.digest(
          "SHA-256",
          new TextEncoder().encode(dlKey) as Uint8Array<ArrayBuffer>,
        ),
      ),
      (b) => b.toString(16).padStart(2, "0"),
    ).join("");
    if (basename(keyName, ".key") !== expectedHex) {
      throw new Error(`key path hex mismatch: ${keyName} want ${expectedHex}.key`);
    }
    // Different key → different path (and miss until put).
    const otherKey = uploadPackCacheKey({
      url: "https://example.com/other.git",
      wants: ["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],
    });
    if ((await a.getByKey!(otherKey)) !== null) {
      throw new Error("different key must miss before putKey");
    }
    await a.putKey(otherKey, digest);
    const keyFiles3 = await readdir(join(dir, "keys"));
    if (keyFiles3.length !== 2) {
      throw new Error(`two keys must produce two files: ${JSON.stringify(keyFiles3)}`);
    }
    if ((await a.getByKey!(otherKey)) !== digest) {
      throw new Error("otherKey putKey/getByKey roundtrip");
    }

    // Fresh instance same dir → durable hit (not process-local memory).
    const b = new DiskPackCache(dir);
    if (!(await b.has(digest))) throw new Error("second instance must has");
    const hit = await b.get(digest);
    if (!hit || hit.length !== pack.length) throw new Error("second instance get");
    if ((await b.getByKey!(dlKey)) !== digest) {
      throw new Error("second instance getByKey");
    }

    // importPackCached with disk cache: first put, second fromCache.
    const fakeEngine = {
      async importPack(_chunk: Uint8Array, _meta?: { final?: boolean }) {
        /* no-op */
      },
    };
    const r1 = await importPackCached(fakeEngine, pack, { cache: a });
    if (!r1.fromCache) throw new Error("import after disk put should fromCache");
    if (r1.digest !== digest) throw new Error("import digest mismatch");

    await b.clear();
    if (await b.has(digest)) throw new Error("clear must remove packs");
    if ((await b.getByKey!(dlKey)) !== null) throw new Error("clear must remove keys");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

/**
 * Factory honors MC_GIT_PACK_CACHE without relying on the process singleton
 * (which may already be pinned Memory by earlier tests in the same process).
 */
async function assertEnvFactory(): Promise<void> {
  const saved = process.env.MC_GIT_PACK_CACHE;
  const root =
    process.env.TEST_TMPDIR?.trim() ||
    process.env.TEST_UNDECLARED_OUTPUTS_DIR?.trim() ||
    tmpdir();
  const dir = await mkdtemp(join(root, "mc-pack-env-"));
  try {
    delete process.env.MC_GIT_PACK_CACHE;
    if (processPackCacheDirFromEnv() !== undefined) {
      throw new Error("processPackCacheDirFromEnv must be undefined when unset");
    }
    const mem = createDefaultProcessPackCache();
    if (!(mem instanceof MemoryPackCache)) {
      throw new Error("createDefaultProcessPackCache without env must be MemoryPackCache");
    }

    process.env.MC_GIT_PACK_CACHE = dir;
    if (processPackCacheDirFromEnv() !== dir) {
      throw new Error(`processPackCacheDirFromEnv: ${processPackCacheDirFromEnv()}`);
    }
    const disk = createDefaultProcessPackCache();
    if (!(disk instanceof DiskPackCache)) {
      throw new Error("createDefaultProcessPackCache with MC_GIT_PACK_CACHE must be DiskPackCache");
    }
    const pack = new Uint8Array([1, 2, 3]);
    const dig = await disk.put(pack);
    if (!(await disk.has(dig))) throw new Error("env DiskPackCache put/has");
  } finally {
    if (saved === undefined) delete process.env.MC_GIT_PACK_CACHE;
    else process.env.MC_GIT_PACK_CACHE = saved;
    await rm(dir, { recursive: true, force: true });
  }
}

/** D11: stream response body → pack extract with size cap + importPackStream. */
async function assertStreamPackPath(): Promise<void> {
  const pack = new Uint8Array([0x50, 0x41, 0x43, 0x4b, 1, 2, 3, 4]);
  if (indexOfPackMagic(pack) !== 0) throw new Error("PACK magic at 0");

  const prefix = new Uint8Array([0x00, 0x00, 0x00, 0x00, 0x4e, 0x41, 0x4b, 0x0a]);
  const bodyWithPrefix = new Uint8Array(prefix.length + pack.length);
  bodyWithPrefix.set(prefix, 0);
  bodyWithPrefix.set(pack, prefix.length);

  const streamChunks: number[] = [];
  const streamBody = new ReadableStream<Uint8Array>({
    start(controller) {
      // Split across PACK boundary: prefix+"PA" | "CK"+rest
      controller.enqueue(bodyWithPrefix.subarray(0, prefix.length + 2));
      controller.enqueue(bodyWithPrefix.subarray(prefix.length + 2));
      controller.close();
    },
  });
  const extracted = await readPackFromResponse(
    {
      body: streamBody,
      headers: { get: () => null },
      arrayBuffer: async () =>
        bodyWithPrefix.buffer.slice(
          bodyWithPrefix.byteOffset,
          bodyWithPrefix.byteOffset + bodyWithPrefix.byteLength,
        ),
    },
    DEFAULT_MAX_PACK_BYTES,
    (c) => {
      streamChunks.push(c.byteLength);
    },
  );
  if (extracted.byteLength !== pack.byteLength) {
    throw new Error(`stream extract len ${extracted.byteLength} want ${pack.byteLength}`);
  }
  for (let i = 0; i < pack.byteLength; i++) {
    if (extracted[i] !== pack[i]) throw new Error(`stream extract byte ${i}`);
  }
  if (!streamChunks.length) throw new Error("onPackChunk must fire for stream path");

  // Fail closed when body exceeds max during stream read.
  let streamThrew = false;
  const bigStream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new Uint8Array(100));
      controller.enqueue(new Uint8Array(100));
      controller.close();
    },
  });
  try {
    await readPackFromResponse(
      {
        body: bigStream,
        headers: { get: () => null },
        arrayBuffer: async () => new ArrayBuffer(0),
      },
      150,
    );
  } catch (e) {
    streamThrew = String(e).includes("exceeds maxPackBytes");
  }
  if (!streamThrew) throw new Error("stream size gate must fail closed");

  // Content-Length early reject
  let clThrew = false;
  try {
    await readPackFromResponse(
      {
        body: null,
        headers: {
          get: (n: string) =>
            n.toLowerCase() === "content-length" ? "999999" : null,
        },
        arrayBuffer: async () => new ArrayBuffer(0),
      },
      1000,
    );
  } catch (e) {
    clThrew = String(e).includes("exceeds maxPackBytes");
  }
  if (!clThrew) throw new Error("content-length gate must fail closed");

  // importPackStream: progressive chunks into engine + size gate
  const streamEngChunks: { len: number; final: boolean }[] = [];
  const streamEng = {
    async importPack(chunk: Uint8Array, meta?: { final?: boolean }) {
      streamEngChunks.push({ len: chunk.byteLength, final: !!meta?.final });
    },
  };
  const streamParts = [pack.subarray(0, 3), pack.subarray(3)];
  const sr = await importPackStream(streamEng, streamParts, { maxPackBytes: 64 });
  if (sr.pack.byteLength !== pack.byteLength) throw new Error("importPackStream pack len");
  if (!streamEngChunks.some((c) => c.final)) throw new Error("importPackStream must final");
  if (streamEngChunks.filter((c) => !c.final).length < 2) {
    throw new Error(
      `importPackStream expected multi-chunk, got ${JSON.stringify(streamEngChunks)}`,
    );
  }
  let streamImportThrew = false;
  try {
    await importPackStream(
      streamEng,
      [new Uint8Array(10), new Uint8Array(10)],
      { maxPackBytes: 15 },
    );
  } catch {
    streamImportThrew = true;
  }
  if (!streamImportThrew) throw new Error("importPackStream size gate");
}

/**
 * Product host_call default: fresh Memory unless MC_GIT_PACK_CACHE_SHARED=1
 * (then process singleton). Disk via MC_GIT_PACK_CACHE only on shared path.
 */
async function assertProductDefaultPackCache(): Promise<void> {
  const savedShared = process.env.MC_GIT_PACK_CACHE_SHARED;
  try {
    delete process.env.MC_GIT_PACK_CACHE_SHARED;
    if (processPackCacheSharedFromEnv()) {
      throw new Error("processPackCacheSharedFromEnv must be false when unset");
    }
    const a = productDefaultPackCache();
    const b = productDefaultPackCache();
    if (!(a instanceof MemoryPackCache) || !(b instanceof MemoryPackCache)) {
      throw new Error("productDefaultPackCache without SHARED must be MemoryPackCache");
    }
    if (a === b) {
      throw new Error(
        "productDefaultPackCache without SHARED must return a fresh instance each call",
      );
    }

    process.env.MC_GIT_PACK_CACHE_SHARED = "1";
    if (!processPackCacheSharedFromEnv()) {
      throw new Error("processPackCacheSharedFromEnv must be true when SHARED=1");
    }
    const sharedA = productDefaultPackCache();
    const sharedB = productDefaultPackCache();
    if (sharedA !== sharedB) {
      throw new Error(
        "productDefaultPackCache with SHARED=1 must use process singleton",
      );
    }
    if (sharedA !== defaultProcessPackCache()) {
      throw new Error(
        "productDefaultPackCache with SHARED=1 must be defaultProcessPackCache()",
      );
    }
  } finally {
    if (savedShared === undefined) delete process.env.MC_GIT_PACK_CACHE_SHARED;
    else process.env.MC_GIT_PACK_CACHE_SHARED = savedShared;
  }
}

async function main() {
  await assertMemoryBasics();

  // Process-scoped singleton (Memory when MC_GIT_PACK_CACHE unset at first call).
  // Explicit callers / LLB / SHARED=1 product path.
  const proc = defaultProcessPackCache();
  if (proc !== defaultProcessPackCache()) {
    throw new Error("defaultProcessPackCache must be process-scoped singleton");
  }
  const dig = await proc.put(new Uint8Array([9, 9, 9]));
  if (!(await proc.has(dig))) throw new Error("process cache put/has");

  await assertProductDefaultPackCache();
  await assertDiskRoundTrip();
  await assertEnvFactory();
  await assertStreamPackPath();

  console.log("git_pack_cache.test SUCCESS");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});