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

const aot = await instantiateOracle(
  runfile(process.env.LUAU_AOT_COMPILED_CALL_ORACLE_WASM, "LUAU_AOT_COMPILED_CALL_ORACLE_WASM"),
  "strict AOT compiled-call oracle",
);
const interpreter = await instantiateOracle(
  runfile(process.env.LUAU_INTERPRETER_ORACLE_WASM, "LUAU_INTERPRETER_ORACLE_WASM"),
  "pinned interpreter oracle",
);
const source = readFileSync(
  runfile(process.env.LUAU_AOT_COMPILED_CALL_ORACLE_SOURCE, "LUAU_AOT_COMPILED_CALL_ORACLE_SOURCE"),
);

const aotInit = aot.exports.mc_luau_aot_v1_compiled_call_oracle_init;
const aotRun = aot.exports.mc_luau_aot_v1_compiled_call_oracle_run;
const interpreterInit = interpreter.exports.mc_luau_interpreter_oracle_init;
const interpreterRun = interpreter.exports.mc_luau_interpreter_oracle_run_add_strings;
const interpreterSourceBuffer = interpreter.exports.mc_luau_interpreter_oracle_source_buffer;
if ([aotInit, aotRun, interpreterInit, interpreterRun, interpreterSourceBuffer].some((item) => typeof item !== "function"))
  throw new Error("compiled-call differential exports are incomplete");

aotInit();
interpreterInit();
const sourcePointer = interpreterSourceBuffer();
new Uint8Array(interpreter.exports.memory.buffer, sourcePointer, source.length).set(source);

for (const [lhs, rhs] of [[-50, 8], [0, 0], [20, 22], [7, -3], [1234, 5678]]) {
  const expected = interpreterRun(source.length, lhs, rhs);
  const actual = aotRun(lhs, rhs);
  if (expected !== lhs + rhs || actual !== expected)
    throw new Error(`compiled-call differential ${lhs}/${rhs}: AOT=${actual}, interpreter=${expected}`);
}

console.log("strict AOT published three Protos, materialized two closures, nested CALL/RETURN, and matched five interpreter cases");
