import { readFileSync } from "node:fs";
import { join } from "node:path";

function runfile(relative) {
  if (!relative) throw new Error("LUAU_AOT_RUNTIME_ORACLE_WASM is not set");
  if (relative.startsWith("/")) return relative;
  if (!process.env.RUNFILES_DIR) throw new Error("RUNFILES_DIR is not set");
  return join(process.env.RUNFILES_DIR, relative);
}

const bytes = readFileSync(runfile(process.env.LUAU_AOT_RUNTIME_ORACLE_WASM));
const module = await WebAssembly.compile(bytes);
const imported = WebAssembly.Module.imports(module);
const imports = {};
let instance;
let throwCode;
for (const item of imported) {
  if (item.kind !== "function") throw new Error(`unexpected non-function import: ${JSON.stringify(item)}`);
  imports[item.module] ??= {};
  if (item.module === "mc" && item.name === "mc_sys_pcall") {
    imports[item.module][item.name] = () => {
      const stackPointer = instance.exports.__stack_pointer.value;
      try {
        instance.exports.__mc_pcall_run();
        return 0;
      } catch (error) {
        if (throwCode === undefined) throw error;
        const code = throwCode;
        throwCode = undefined;
        return code;
      } finally {
        instance.exports.__stack_pointer.value = stackPointer;
      }
    };
  } else if (item.module === "mc" && item.name === "mc_sys_set_throw") {
    imports[item.module][item.name] = (code) => {
      throwCode = code;
      return 0;
    };
  } else {
    imports[item.module][item.name] = (...args) => {
      if (item.module === "wasi_snapshot_preview1" && item.name === "proc_exit")
        throw new Error(`runtime oracle unexpectedly exited with ${args[0]}`);
      return 0;
    };
  }
}

instance = await WebAssembly.instantiate(module, imports);
const {
  mc_luau_aot_v1_oracle_gc_publication: gcPublication,
  mc_luau_aot_v1_oracle_init: init,
  mc_luau_aot_v1_oracle_probe: probe,
  mc_luau_aot_v1_oracle_reject_non_number: rejectNonNumber,
  mc_luau_aot_v1_oracle_run_i32: run,
} = instance.exports;
if (
  typeof gcPublication !== "function" ||
  typeof init !== "function" ||
  typeof probe !== "function" ||
  typeof rejectNonNumber !== "function" ||
  typeof run !== "function"
)
  throw new Error("runtime oracle exports are incomplete");
init();

const gcStatus = gcPublication();
if (gcStatus !== 0) throw new Error(`AOT closure did not survive incremental-GC publication: ${gcStatus}`);

for (const [stage, boundary] of [
  [0, "state construction and teardown"],
  [1, "root closure materialization"],
  [2, "argument push"],
  [3, "AOT call dispatch"],
  [4, "result access"],
]) {
  try {
    const status = probe(stage);
    if (status !== 0) throw new Error(`returned ${status}`);
  } catch (error) {
    throw new Error(`runtime oracle failed at ${boundary}: ${error.stack ?? error}`);
  }
}

const rejectionStatus = rejectNonNumber();
if (rejectionStatus <= 0)
  throw new Error(`non-number input did not cross the protected Luau error boundary: ${rejectionStatus}`);

for (const [input, expected] of [
  [1, 1],
  [4, 10],
  [7, 28],
]) {
  const actual = run(input);
  if (actual !== expected) throw new Error(`real lua_State input ${input}: got ${actual}, expected ${expected}`);
}

console.log("runtime scalar oracle: generated object executed against three real Luau states");
