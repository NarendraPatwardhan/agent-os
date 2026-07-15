// JS persist capability coverage. These tests drive the host-side
// `start/poll/body/close` ABI directly: that is the boundary the bridge calls,
// and it catches codec drift without needing to boot the kernel.

import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PERSIST_GET_ABSENT, PERSIST_GET_PRESENT } from "@mc/contracts/constants";
import {
  DiskPersist,
  PERSIST_OP_DELETE,
  PERSIST_OP_GET,
  PERSIST_OP_LIST,
  PERSIST_OP_PUT,
  decodePersistRequest,
} from "../src/persist.js";
import { type BrowserKv, MemoryKv, OpfsPersist } from "../src/opfs_persist.js";
import type { PersistCapability } from "../src/types.js";

const te = new TextEncoder();
const td = new TextDecoder();

function bytes(s: string): Uint8Array {
  return te.encode(s);
}

function text(b: Uint8Array): string {
  return td.decode(b);
}

function request(
  op: number,
  key: string | Uint8Array,
  value: string | Uint8Array = "",
): Uint8Array {
  const k = typeof key === "string" ? bytes(key) : key;
  const v = typeof value === "string" ? bytes(value) : value;
  const out = new Uint8Array(8 + k.length + v.length);
  const dv = new DataView(out.buffer);
  dv.setUint32(0, op, true);
  dv.setUint32(4, k.length, true);
  out.set(k, 8);
  out.set(v, 8 + k.length);
  return out;
}

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

function assertEq(actual: number, expected: number, msg: string): void {
  if (actual !== expected) throw new Error(`${msg}: ${actual} != ${expected}`);
}

function assertBytes(actual: Uint8Array, expected: Uint8Array, msg: string): void {
  assert(
    actual.length === expected.length,
    `${msg}: length ${actual.length} != ${expected.length}`,
  );
  for (let i = 0; i < actual.length; i++) {
    assert(actual[i] === expected[i], `${msg}: byte ${i} ${actual[i]} != ${expected[i]}`);
  }
}

function concat(chunks: Uint8Array[]): Uint8Array {
  const total = chunks.reduce((n, chunk) => n + chunk.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const chunk of chunks) {
    out.set(chunk, off);
    off += chunk.length;
  }
  return out;
}

function readReady(cap: PersistCapability, handle: number, chunkSize = 3): Uint8Array {
  assert(cap.poll(handle) === 1, `handle ${handle} is not ready`);
  const chunks: Uint8Array[] = [];
  for (;;) {
    const buf = new Uint8Array(chunkSize);
    const n = cap.body(handle, buf);
    assert(n >= 0, `body failed for handle ${handle}`);
    if (n === 0) break;
    chunks.push(buf.slice(0, n));
  }
  cap.close(handle);
  return concat(chunks);
}

async function waitReady(cap: PersistCapability, handle: number): Promise<void> {
  for (let i = 0; i < 50; i++) {
    const poll = cap.poll(handle);
    if (poll === 1) return;
    assert(poll === 0, `handle ${handle} failed while waiting`);
    await Promise.resolve();
  }
  throw new Error(`handle ${handle} did not become ready`);
}

async function drainAsync(
  cap: PersistCapability,
  handle: number,
  chunkSize = 3,
): Promise<Uint8Array> {
  await waitReady(cap, handle);
  return readReady(cap, handle, chunkSize);
}

function parseList(body: Uint8Array): string[] {
  return text(body)
    .split("\0")
    .filter((part) => part.length > 0);
}

function presentBody(value: string): Uint8Array {
  const v = bytes(value);
  const out = new Uint8Array(v.length + 1);
  out[0] = PERSIST_GET_PRESENT;
  out.set(v, 1);
  return out;
}

function deferred<T>(): {
  promise: Promise<T>;
  resolve: (value: T | PromiseLike<T>) => void;
  reject: (reason?: unknown) => void;
} {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

class ControlledKv implements BrowserKv {
  readonly puts: Array<{ hexKey: string; value: string; gate: ReturnType<typeof deferred<void>> }> =
    [];
  readonly deletes: Array<{ hexKey: string; gate: ReturnType<typeof deferred<void>> }> = [];

  constructor(private readonly initial = new Map<string, Uint8Array>()) {}

  async load(): Promise<Map<string, Uint8Array>> {
    return new Map(this.initial);
  }

  async put(hexKey: string, value: Uint8Array): Promise<void> {
    const gate = deferred<void>();
    this.puts.push({ hexKey, value: text(value), gate });
    await gate.promise;
    this.initial.set(hexKey, value.slice());
  }

  async delete(hexKey: string): Promise<void> {
    const gate = deferred<void>();
    this.deletes.push({ hexKey, gate });
    await gate.promise;
    this.initial.delete(hexKey);
  }
}

async function testCodec(): Promise<void> {
  const req = request(PERSIST_OP_PUT, "alpha", "payload");
  const decoded = decodePersistRequest(req);
  assert(decoded !== null, "valid persist request did not decode");
  assert(decoded.op === PERSIST_OP_PUT, "decoded op mismatch");
  assert(text(decoded.key) === "alpha", "decoded key mismatch");
  assert(text(decoded.value) === "payload", "decoded value mismatch");

  assert(decodePersistRequest(new Uint8Array([1, 2, 3])) === null, "short request decoded");
  const bad = request(PERSIST_OP_GET, "x");
  new DataView(bad.buffer).setUint32(4, 100, true);
  assert(decodePersistRequest(bad) === null, "oversized key request decoded");
}

async function testDiskPersist(): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), "mc-js-persist-"));
  try {
    const cap = new DiskPersist(dir);
    assert(cap.start(new Uint8Array([0])) === -1, "malformed disk request should be refused");

    const absent = readReady(cap, cap.start(request(PERSIST_OP_GET, "dir/a")));
    assertBytes(absent, new Uint8Array([PERSIST_GET_ABSENT]), "disk absent body");

    const putA = cap.start(request(PERSIST_OP_PUT, "dir/a", "one"));
    assert(putA > 0, "disk PUT did not return a handle");
    assertBytes(readReady(cap, putA), new Uint8Array(0), "disk PUT body");

    const putB = cap.start(request(PERSIST_OP_PUT, "dir/b", "two"));
    assertBytes(readReady(cap, putB), new Uint8Array(0), "disk second PUT body");

    assertBytes(
      readReady(cap, cap.start(request(PERSIST_OP_GET, "dir/a")), 2),
      presentBody("one"),
      "disk GET body",
    );
    const listed = parseList(readReady(cap, cap.start(request(PERSIST_OP_LIST, "dir/"))));
    assert(
      JSON.stringify(listed) === JSON.stringify(["dir/a", "dir/b"]),
      `disk LIST mismatch: ${listed}`,
    );

    assertBytes(
      readReady(cap, cap.start(request(PERSIST_OP_DELETE, "dir/a"))),
      new Uint8Array(0),
      "disk DELETE body",
    );
    const deleted = readReady(cap, cap.start(request(PERSIST_OP_GET, "dir/a")));
    assertBytes(deleted, new Uint8Array([PERSIST_GET_ABSENT]), "disk deleted body");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

async function testOpfsDurabilityAndOrdering(): Promise<void> {
  const initial = new Map<string, Uint8Array>([["6b", bytes("old")]]);
  const kv = new ControlledKv(initial);
  const cap = await OpfsPersist.open(kv);

  const first = cap.start(request(PERSIST_OP_PUT, "k", "one"));
  const second = cap.start(request(PERSIST_OP_PUT, "k", "two"));
  assert(cap.poll(first) === 0, "first browser PUT should be pending before backing settles");
  assert(cap.poll(second) === 0, "second browser PUT should wait behind first mutation");
  assert(cap.body(first, new Uint8Array(1)) === -1, "pending browser PUT body should fail");

  await Promise.resolve();
  assertEq(kv.puts.length, 1, "expected only first PUT to start");
  assert(kv.puts[0].value === "one", "first started PUT value mismatch");

  const during = await drainAsync(cap, cap.start(request(PERSIST_OP_GET, "k")));
  assertBytes(during, presentBody("old"), "browser cache published before durable write");

  kv.puts[0].gate.resolve();
  await waitReady(cap, first);
  assertEq(kv.puts.length, 2, "second PUT did not start after first settled");
  assert(kv.puts[1].value === "two", "second started PUT value mismatch");
  kv.puts[1].gate.resolve();

  assertBytes(readReady(cap, first), new Uint8Array(0), "first browser PUT body");
  await waitReady(cap, second);
  assertBytes(readReady(cap, second), new Uint8Array(0), "second browser PUT body");

  const after = await drainAsync(cap, cap.start(request(PERSIST_OP_GET, "k")));
  assertBytes(after, presentBody("two"), "browser GET after durable writes");
}

async function testMemoryKvReload(): Promise<void> {
  const backing = new MemoryKv();
  const first = await OpfsPersist.open(backing);
  const put = first.start(request(PERSIST_OP_PUT, "reload", "survives"));
  assertBytes(await drainAsync(first, put), new Uint8Array(0), "memory-backed browser PUT body");

  const second = await OpfsPersist.open(backing);
  const got = await drainAsync(second, second.start(request(PERSIST_OP_GET, "reload")));
  assertBytes(got, presentBody("survives"), "memory backing reload");
}

async function main(): Promise<void> {
  await testCodec();
  await testDiskPersist();
  await testOpfsDurabilityAndOrdering();
  await testMemoryKvReload();
  console.log("PERSIST OK — JS codec, DiskPersist, and OpfsPersist durability/ordering verified.");
}

main().catch((e) => {
  console.error("PERSIST FAIL:", e instanceof Error ? (e.stack ?? e.message) : e);
  process.exit(1);
});
