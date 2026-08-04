import { readFileSync } from "node:fs";
import { join } from "node:path";

function runfile(relative) {
  if (!relative) throw new Error("LUAU_AOT_SCALAR_FIXTURE_WASM is not set");
  if (relative.startsWith("/")) return relative;
  if (!process.env.RUNFILES_DIR) throw new Error("RUNFILES_DIR is not set");
  return join(process.env.RUNFILES_DIR, relative);
}

const bytes = readFileSync(runfile(process.env.LUAU_AOT_SCALAR_FIXTURE_WASM));
const module = await WebAssembly.compile(bytes);
const imports = WebAssembly.Module.imports(module);
if (
  imports.length !== 1 ||
  imports[0].module !== "env" ||
  imports[0].name !== "mc_luau_aot_v1_commit_number" ||
  imports[0].kind !== "function"
) {
  throw new Error(`unexpected scalar fixture imports: ${JSON.stringify(imports)}`);
}

let committed = null;
const instance = await WebAssembly.instantiate(module, {
  env: {
    mc_luau_aot_v1_commit_number(state, value) {
      if (state !== 1024) throw new Error(`commit received wrong state ${state}`);
      committed = value;
    },
  },
});

const { memory, mc_luau_aot_v1_generated_scalar_fixture: generated } = instance.exports;
if (!(memory instanceof WebAssembly.Memory) || typeof generated !== "function")
  throw new Error("linked scalar fixture is missing its exact public surface");

const state = 1024;
const base = 2048;
const view = new DataView(memory.buffer);
view.setUint32(state + 12, base, true); // lua_State::base
view.setUint32(base + 12, 3, true); // TValue::tt = LUA_TNUMBER

for (const [input, expected] of [
  [1, 1],
  [4, 10],
  [7, 28],
]) {
  view.setFloat64(base, input, true);
  committed = null;
  const status = generated(state, 0);
  if (status !== 0 || committed !== expected)
    throw new Error(`input ${input}: status=${status} committed=${committed} expected=${expected}`);
}

view.setUint32(base + 12, 1, true); // boolean is outside the numeric tier
committed = null;
const rejected = generated(state, 0);
if (rejected !== 1 || committed !== null)
  throw new Error(`non-number path did not fail closed: status=${rejected} committed=${committed}`);

console.log("scalar fixture: one linked artifact executed dynamic inputs 1/4/7 and rejected non-number");
