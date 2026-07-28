import { readFileSync } from "node:fs";
import { join } from "node:path";
import { KernelHostBuilder } from "../src/index.js";
import { SNAPSHOT_HEADER_LEN, SNAPSHOT_PAGE_SIZE, parseSnapshot } from "@mc/contracts/snapshot";
import type { StreamSink } from "../src/index.js";

interface Vector {
  name: string;
  source?: "full" | "incremental";
  mutation: string;
  offset?: number;
  value?: number;
  length?: number;
  error: string;
}
const file = (rel: string | undefined): Uint8Array => {
  if (!rel || !process.env.RUNFILES_DIR) throw new Error("snapshot test must run under bazel");
  return new Uint8Array(readFileSync(join(process.env.RUNFILES_DIR, rel)));
};
function mutate(input: Uint8Array, v: Vector): Uint8Array {
  let bytes = input.slice();
  const dv = new DataView(bytes.buffer);
  switch (v.mutation) {
    case "u32":
      dv.setUint32(v.offset!, v.value!, true);
      break;
    case "zero":
      bytes.fill(0, v.offset!, v.offset! + v.length!);
      break;
    case "byte":
      bytes[v.offset!] = v.value!;
      break;
    case "flip":
      bytes[v.offset!] ^= 0xff;
      break;
    case "append": {
      const next = new Uint8Array(bytes.length + 1);
      next.set(bytes);
      bytes = next;
      break;
    }
    case "truncate":
      bytes = bytes.subarray(0, bytes.length - 1);
      break;
    default:
      throw new Error(`unknown mutation ${v.mutation}`);
  }
  return bytes;
}

const wasm = file(process.env.MC_KERNEL_WASM);
const image = file(process.env.MC_BASE_IMAGE);
const vectors = JSON.parse(
  new TextDecoder().decode(file(process.env.MC_SNAPSHOT_VECTORS)),
) as Vector[];
const discard: StreamSink = { write() {} };
const host = await new KernelHostBuilder(wasm)
  .withBaseImage(image)
  .deterministic()
  .withStdout(discard)
  .build();
const valid = await host.snapshot();
const incremental = await host.snapshotIncremental(valid);
for (const vector of vectors) {
  try {
    const bad = mutate(vector.source === "incremental" ? incremental : valid, vector);
    await new KernelHostBuilder(wasm)
      .deterministic()
      .restore(bad, vector.source === "incremental" ? valid : undefined);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (!message.includes(vector.error)) throw new Error(`${vector.name}: ${message}`);
    continue;
  }
  throw new Error(`${vector.name}: malformed snapshot restored`);
}

const tracked = Uint8Array.from({ length: 4096 }, (_, i) => (i * 31) & 0xff);
host.writeFile("/tmp/tracked", tracked);
const trackedDelta = await host.snapshotIncremental(valid);
const trackedView = parseSnapshot(trackedDelta);
if (trackedView.changedPages <= 0) throw new Error("4-KiB write did not change a snapshot page");
if (trackedView.changedPages >= trackedView.memoryLen / SNAPSHOT_PAGE_SIZE) {
  throw new Error("4-KiB mutation unexpectedly captured every page");
}
if (trackedDelta.length >= SNAPSHOT_HEADER_LEN + trackedView.memoryLen) {
  throw new Error("incremental must be smaller than a full snapshot");
}
const restored = await new KernelHostBuilder(wasm).deterministic().restore(trackedDelta, valid);
if (!restored.readFile("/tmp/tracked").every((byte, i) => byte === tracked[i])) {
  throw new Error("incremental restore did not preserve the 4-KiB mutation");
}
restored.writeFile("/tmp/after-restore", new TextEncoder().encode("second generation"));
const secondGeneration = await restored.snapshotIncremental(valid);
const restoredAgain = await new KernelHostBuilder(wasm)
  .deterministic()
  .restore(secondGeneration, valid);
if (new TextDecoder().decode(restoredAgain.readFile("/tmp/after-restore")) !== "second generation") {
  throw new Error("restored incremental could not produce a second-generation delta");
}

const replacement = new Uint8Array(4096).fill(0xa7);
host.writeFile("/tmp/tracked", replacement);
const badBase = valid.slice();
badBase[SNAPSHOT_HEADER_LEN] ^= 1;
try {
  await host.snapshotIncremental(badBase);
  throw new Error("corrupt incremental baseline was accepted");
} catch (error) {
  if (error instanceof Error && error.message === "corrupt incremental baseline was accepted") {
    throw error;
  }
}
const afterFailure = await host.snapshotIncremental(valid);
const restoredAfterFailure = await new KernelHostBuilder(wasm)
  .deterministic()
  .restore(afterFailure, valid);
if (!restoredAfterFailure.readFile("/tmp/tracked").every((byte) => byte === 0xa7)) {
  throw new Error("rejected incremental attempt lost later writes");
}

const baseLen = parseSnapshot(valid).memoryLen;
const growth = new Uint8Array(baseLen).fill(0x5c);
host.writeFile("/tmp/growth", growth);
const growthDelta = await host.snapshotIncremental(valid);
if (parseSnapshot(growthDelta).memoryLen <= baseLen) {
  throw new Error("large write did not exercise incremental memory growth");
}
const restoredGrowth = await new KernelHostBuilder(wasm)
  .deterministic()
  .restore(growthDelta, valid);
if (!restoredGrowth.readFile("/tmp/growth").every((byte) => byte === 0x5c)) {
  throw new Error("incremental memory-growth restore lost the large file");
}

console.log("shared malformed MCSN v4 vectors and exact incremental tracking passed");
