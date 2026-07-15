import { readFileSync } from "node:fs";
import { join } from "node:path";
import { KernelHostBuilder } from "../src/index.js";
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
console.log("shared malformed MCSN v2 vectors rejected by the JS host");
