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
  runfile(process.env.LUAU_AOT_SLOW_ARITH_ORACLE_WASM, "LUAU_AOT_SLOW_ARITH_ORACLE_WASM"),
  "strict AOT slow-arithmetic oracle",
);
const interpreter = await instantiateOracle(
  runfile(process.env.LUAU_INTERPRETER_ORACLE_WASM, "LUAU_INTERPRETER_ORACLE_WASM"),
  "pinned interpreter oracle",
);
const source = readFileSync(
  runfile(process.env.LUAU_AOT_SLOW_ARITH_ORACLE_SOURCE, "LUAU_AOT_SLOW_ARITH_ORACLE_SOURCE"),
);

const aotInit = aot.exports.mc_luau_aot_v1_slow_arith_oracle_init;
const aotRun = aot.exports.mc_luau_aot_v1_slow_arith_oracle_run;
const interpreterInit = interpreter.exports.mc_luau_interpreter_oracle_init;
const interpreterRun = interpreter.exports.mc_luau_interpreter_oracle_run_add_strings;
const interpreterSourceBuffer = interpreter.exports.mc_luau_interpreter_oracle_source_buffer;
if ([aotInit, aotRun, interpreterInit, interpreterRun, interpreterSourceBuffer].some((item) => typeof item !== "function"))
  throw new Error("slow-arithmetic differential exports are incomplete");

aotInit();
interpreterInit();
const sourcePointer = interpreterSourceBuffer();
if (!sourcePointer || source.length === 0)
  throw new Error("pinned interpreter source buffer is unavailable");
new Uint8Array(interpreter.exports.memory.buffer, sourcePointer, source.length).set(source);

for (const [lhs, rhs] of [
  [-50, 8],
  [0, 0],
  [20, 22],
  [7, -3],
  [1234, 5678],
]) {
  const expected = interpreterRun(source.length, lhs, rhs);
  if (expected !== lhs + rhs)
    throw new Error(`pinned interpreter string add ${lhs}/${rhs}: got ${expected}, expected ${lhs + rhs}`);
  const actual = aotRun(lhs, rhs);
  if (actual !== expected)
    throw new Error(`slow arithmetic differential ${lhs}/${rhs}: AOT=${actual}, pinned interpreter=${expected}`);
}

console.log("strict AOT DO_ARITH fallback rejoined compiled code and matched five pinned-interpreter string additions");
