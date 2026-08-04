import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const generatedSymbol = "mc_luau_aot_v1_generated_ir_function";

function runfile(relative, variable) {
  if (!relative) throw new Error(`${variable} is not set`);
  if (relative.startsWith("/")) return relative;
  if (!process.env.RUNFILES_DIR) throw new Error("RUNFILES_DIR is not set");
  return join(process.env.RUNFILES_DIR, relative);
}

async function instantiateZeroImport(path, label) {
  const module = await WebAssembly.compile(readFileSync(path));
  const imports = WebAssembly.Module.imports(module);
  if (imports.length !== 0) throw new Error(`${label} is not zero-import: ${JSON.stringify(imports)}`);
  return WebAssembly.instantiate(module, {});
}

const frontend = await instantiateZeroImport(
  runfile(process.env.LUAU_AOT_FRONTEND_WASM, "LUAU_AOT_FRONTEND_WASM"),
  "frontend",
);
const backend = await instantiateZeroImport(
  runfile(process.env.LUAU_AOT_BACKEND_WASM, "LUAU_AOT_BACKEND_WASM"),
  "backend",
);
const wasmLd = runfile(process.env.LUAU_AOT_WASM_LD, "LUAU_AOT_WASM_LD");

const encoder = new TextEncoder();

function frontendSnapshot(sourceText, chunkText) {
  const api = frontend.exports;
  api.mc_luau_frontend_v1_init();
  const source = encoder.encode(sourceText);
  const chunk = encoder.encode(chunkText);
  const sourcePointer = api.mc_luau_frontend_v1_alloc(source.length);
  const chunkPointer = api.mc_luau_frontend_v1_alloc(chunk.length);
  const resultPointer = api.mc_luau_frontend_v1_alloc(20);
  if (!sourcePointer || !chunkPointer || !resultPointer) throw new Error("frontend allocation failed");

  new Uint8Array(api.memory.buffer, sourcePointer, source.length).set(source);
  new Uint8Array(api.memory.buffer, chunkPointer, chunk.length).set(chunk);
  new Uint8Array(api.memory.buffer, resultPointer, 20).fill(0);
  const status = api.mc_luau_frontend_snapshot_v1_compile(
    sourcePointer,
    source.length,
    chunkPointer,
    chunk.length,
    resultPointer,
  );
  const result = new DataView(api.memory.buffer, resultPointer, 20);
  const dataPointer = result.getUint32(0, true);
  const dataSize = result.getUint32(4, true);
  const resultStatus = result.getUint32(16, true);
  if (status !== 0 || resultStatus !== 0) throw new Error(`frontend failed with ${status}/${resultStatus}`);
  const snapshot = Buffer.from(new Uint8Array(api.memory.buffer, dataPointer, dataSize));

  api.mc_luau_frontend_snapshot_v1_free(resultPointer);
  api.mc_luau_frontend_v1_dealloc(resultPointer, 20);
  api.mc_luau_frontend_v1_dealloc(chunkPointer, chunk.length);
  api.mc_luau_frontend_v1_dealloc(sourcePointer, source.length);
  return snapshot;
}

function backendObject(snapshot, functionId) {
  const api = backend.exports;
  const snapshotPointer = api.mc_luau_backend_v1_alloc(snapshot.length);
  const resultPointer = api.mc_luau_backend_v1_alloc(16);
  if (!snapshotPointer || !resultPointer) throw new Error("backend allocation failed");
  new Uint8Array(api.memory.buffer, snapshotPointer, snapshot.length).set(snapshot);
  new Uint8Array(api.memory.buffer, resultPointer, 16).fill(0);
  const status = api.mc_luau_backend_v1_compile(snapshotPointer, snapshot.length, functionId, resultPointer);
  const result = new DataView(api.memory.buffer, resultPointer, 16);
  const dataPointer = result.getUint32(0, true);
  const dataSize = result.getUint32(4, true);
  const resultStatus = result.getUint32(8, true);
  if (status !== 0 || resultStatus !== 0 || !dataPointer || !dataSize)
    throw new Error(`backend failed with ${status}/${resultStatus}`);
  const object = Buffer.from(new Uint8Array(api.memory.buffer, dataPointer, dataSize));
  api.mc_luau_backend_v1_free(resultPointer);
  api.mc_luau_backend_v1_dealloc(resultPointer, 16);
  api.mc_luau_backend_v1_dealloc(snapshotPointer, snapshot.length);
  return object;
}

function linkObject(object, name) {
  const directory = mkdtempSync(join(process.env.TEST_TMPDIR || tmpdir(), `luau-aot-${name}-`));
  const objectPath = join(directory, `${name}.o`);
  const wasmPath = join(directory, `${name}.wasm`);
  writeFileSync(objectPath, object);
  const linked = spawnSync(
    wasmLd,
    [
      "--no-entry",
      "--allow-undefined",
      "--export-memory",
      `--export=${generatedSymbol}`,
      objectPath,
      "-o",
      wasmPath,
    ],
    { encoding: "utf8" },
  );
  if (linked.status !== 0)
    throw new Error(`wasm-ld failed (${linked.status}): ${linked.stdout}\n${linked.stderr}`);
  const bytes = readFileSync(wasmPath);
  rmSync(directory, { recursive: true, force: true });
  return bytes;
}

async function executeCase(name, source, inputs) {
  const snapshot = frontendSnapshot(source, `@aot/${name}.luau`);
  const object = backendObject(snapshot, 1);
  if (!object.subarray(0, 8).equals(Buffer.from([0, 97, 115, 109, 1, 0, 0, 0])))
    throw new Error(`${name}: backend did not emit a wasm32 object`);
  const module = await WebAssembly.compile(linkObject(object, name));
  const moduleImports = WebAssembly.Module.imports(module).map(({ module, name: importName, kind }) => [module, importName, kind]);
  const expectedImports = [
    ["env", "mc_luau_aot_v1_commit_number", "function"],
    ["env", "mc_luau_aot_v1_interrupt", "function"],
  ];
  if (JSON.stringify(moduleImports) !== JSON.stringify(expectedImports))
    throw new Error(`${name}: unexpected generated imports ${JSON.stringify(moduleImports)}`);

  let instance;
  let committed = null;
  let interrupts = 0;
  instance = await WebAssembly.instantiate(module, {
    env: {
      mc_luau_aot_v1_commit_number(state, value) {
        if (state !== 1024) throw new Error(`${name}: wrong state ${state}`);
        committed = value;
      },
      mc_luau_aot_v1_interrupt(state, pc) {
        if (state !== 1024 || pc < 0) throw new Error(`${name}: invalid interrupt ${state}/${pc}`);
        interrupts++;
        return 0;
      },
    },
  });
  const generated = instance.exports[generatedSymbol];
  const memory = instance.exports.memory;
  if (typeof generated !== "function" || !(memory instanceof WebAssembly.Memory))
    throw new Error(`${name}: linked generated surface is incomplete`);

  const state = 1024;
  const base = 2048;
  const view = new DataView(memory.buffer);
  view.setUint32(state + 12, base, true);
  for (const [input, expected] of inputs) {
    new Uint8Array(memory.buffer, base, 16 * 8).fill(0);
    view.setFloat64(base, input, true);
    view.setUint32(base + 12, 3, true);
    committed = null;
    const status = generated(state, 0);
    if (status !== 0 || committed !== expected)
      throw new Error(`${name}(${input}): status=${status}, result=${committed}, expected=${expected}`);
  }

  view.setUint32(base + 12, 1, true);
  committed = null;
  const rejected = generated(state, 0);
  if (rejected !== 1 || committed !== null)
    throw new Error(`${name}: non-number path did not fail closed: ${rejected}/${committed}`);
  if (interrupts === 0) throw new Error(`${name}: upstream INTERRUPT instructions were erased`);
  return { objectSize: object.length, interrupts };
}

const scalar = await executeCase(
  "scalar",
  "return function(n) return n * 2 + 1 end",
  [
    [1, 3],
    [4, 9],
    [7, 15],
  ],
);
const loop = await executeCase(
  "loop",
  "return function(n) local sum = 0 for i = 1, n do sum += i end return sum end",
  [
    [1, 1],
    [4, 10],
    [7, 28],
  ],
);

console.log(
  `frontend -> IR -> relocatable wasm: scalar ${scalar.objectSize} bytes, loop ${loop.objectSize} bytes; ` +
    `interrupt calls ${scalar.interrupts}/${loop.interrupts}`,
);
