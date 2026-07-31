/** PR13: pack cache digests + size gate + chunked import shape. */

import {
  DEFAULT_MAX_PACK_BYTES,
  MemoryPackCache,
  importPackCached,
} from "../src/git/pack-cache.js";

async function main() {
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

  console.log("git_pack_cache.test SUCCESS");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
