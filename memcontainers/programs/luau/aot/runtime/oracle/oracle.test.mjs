import { readFileSync } from "node:fs";
import { join } from "node:path";

function runfile(relative, variable) {
  if (!relative) throw new Error(`${variable} is not set`);
  if (relative.startsWith("/")) return relative;
  if (!process.env.RUNFILES_DIR) throw new Error("RUNFILES_DIR is not set");
  return join(process.env.RUNFILES_DIR, relative);
}

async function instantiateOracle(path, label) {
  const module = await WebAssembly.compile(readFileSync(path));
  const imported = WebAssembly.Module.imports(module);
  const imports = {};
  let instance;
  let throwCode;
  for (const item of imported) {
    if (item.kind !== "function")
      throw new Error(`${label}: unexpected non-function import: ${JSON.stringify(item)}`);
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
          throw new Error(`${label}: unexpectedly exited with ${args[0]}`);
        return 0;
      };
    }
  }
  instance = await WebAssembly.instantiate(module, imports);
  return instance;
}

const runtimeInstance = await instantiateOracle(
  runfile(process.env.LUAU_AOT_RUNTIME_ORACLE_WASM, "LUAU_AOT_RUNTIME_ORACLE_WASM"),
  "AOT runtime oracle",
);
const interpreterInstance = await instantiateOracle(
  runfile(process.env.LUAU_INTERPRETER_ORACLE_WASM, "LUAU_INTERPRETER_ORACLE_WASM"),
  "pinned interpreter oracle",
);
const source = readFileSync(
  runfile(process.env.LUAU_AOT_RUNTIME_ORACLE_SOURCE, "LUAU_AOT_RUNTIME_ORACLE_SOURCE"),
);

const {
  mc_luau_aot_v1_oracle_gc_publication: gcPublication,
  mc_luau_aot_v1_oracle_init: init,
  mc_luau_aot_v1_oracle_probe: probe,
  mc_luau_aot_v1_oracle_reject_non_number: rejectNonNumber,
  mc_luau_aot_v1_oracle_run_i32: run,
} = runtimeInstance.exports;
const {
  mc_luau_interpreter_oracle_init: interpreterInit,
  mc_luau_interpreter_oracle_run_i32: interpreterRun,
  mc_luau_interpreter_oracle_source_buffer: interpreterSourceBuffer,
} = interpreterInstance.exports;
if (
  typeof gcPublication !== "function" ||
  typeof init !== "function" ||
  typeof probe !== "function" ||
  typeof rejectNonNumber !== "function" ||
  typeof run !== "function"
)
  throw new Error("runtime oracle exports are incomplete");
if (
  typeof interpreterInit !== "function" ||
  typeof interpreterRun !== "function" ||
  typeof interpreterSourceBuffer !== "function"
)
  throw new Error("pinned interpreter oracle exports are incomplete");
init();
interpreterInit();
const sourcePointer = interpreterSourceBuffer();
if (!sourcePointer || source.length === 0)
  throw new Error("pinned interpreter oracle source buffer is unavailable");
new Uint8Array(interpreterInstance.exports.memory.buffer, sourcePointer, source.length).set(source);

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

const known = new Map([[1, 1], [4, 10], [7, 28]]);
for (const input of [-3, 0, 1, 4, 7, 12]) {
  const expected = interpreterRun(source.length, input);
  if (known.has(input) && expected !== known.get(input))
    throw new Error(`pinned interpreter oracle ${input}: got ${expected}, expected ${known.get(input)}`);
  const actual = run(input);
  if (actual !== expected)
    throw new Error(`differential mismatch for input ${input}: AOT=${actual}, pinned interpreter=${expected}`);
}

console.log("runtime upstream-IR loop oracle: one generated object matched the pinned interpreter for six real-state inputs");
