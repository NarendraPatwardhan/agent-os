import { readFileSync, writeFileSync } from "node:fs";

const MAGIC = Buffer.from([0x4d, 0x43, 0x4c, 0x50, 0x4b, 0x47, 0x31, 0x00]);
const HEADER_SIZE = 24;
const RECORD_SIZE = 24;

async function instantiate(path, label) {
  const module = await WebAssembly.compile(readFileSync(path));
  const imports = WebAssembly.Module.imports(module);
  if (imports.length !== 0) throw new Error(`${label} is not zero-import: ${JSON.stringify(imports)}`);
  return WebAssembly.instantiate(module, {});
}

const [frontendPath, backendPath, outputPath, entryName, ...moduleArguments] = process.argv.slice(2);
if (!frontendPath || !backendPath || !outputPath || !entryName || moduleArguments.length < 2)
  throw new Error("usage: static_package_emitter <frontend.wasm> <backend.wasm> <output.o> <entry-name> <name=source.luau>...");

const modules = moduleArguments.map((argument) => {
  const separator = argument.indexOf("=");
  if (separator <= 0 || separator === argument.length - 1)
    throw new Error(`invalid module argument ${JSON.stringify(argument)}`);
  return { name: argument.slice(0, separator), sourcePath: argument.slice(separator + 1) };
}).sort((lhs, rhs) => Buffer.from(lhs.name).compare(Buffer.from(rhs.name)));
if (new Set(modules.map(({ name }) => name)).size !== modules.length)
  throw new Error("duplicate canonical module name");
const entryModuleId = modules.findIndex(({ name }) => name === entryName);
if (entryModuleId < 0) throw new Error(`entry module ${JSON.stringify(entryName)} is not present`);

const frontend = await instantiate(frontendPath, "frontend");
const backend = await instantiate(backendPath, "backend");
const encoder = new TextEncoder();

function compileFrontend(module) {
  const source = readFileSync(module.sourcePath);
  const chunk = encoder.encode(`@aot/${module.name}.luau`);
  const api = frontend.exports;
  api.mc_luau_frontend_v1_init();
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
  const diagnosticPointer = result.getUint32(8, true);
  const diagnosticSize = result.getUint32(12, true);
  const resultStatus = result.getUint32(16, true);
  const diagnostic = diagnosticPointer && diagnosticSize
    ? new TextDecoder().decode(new Uint8Array(api.memory.buffer, diagnosticPointer, diagnosticSize))
    : "";
  if (status !== 0 || resultStatus !== 0)
    throw new Error(`${module.name}: frontend failed with ${status}/${resultStatus}: ${diagnostic}`);
  const snapshot = Buffer.from(new Uint8Array(api.memory.buffer, dataPointer, dataSize));
  api.mc_luau_frontend_snapshot_v1_free(resultPointer);
  api.mc_luau_frontend_v1_dealloc(resultPointer, 20);
  api.mc_luau_frontend_v1_dealloc(chunkPointer, chunk.length);
  api.mc_luau_frontend_v1_dealloc(sourcePointer, source.length);
  return snapshot;
}

function packageFrame() {
  const compiled = modules.map((module) => ({
    name: Buffer.from(module.name),
    snapshot: compileFrontend(module),
  }));
  const totalSize = compiled.reduce(
    (size, module) => size + module.name.length + module.snapshot.length,
    HEADER_SIZE + RECORD_SIZE * compiled.length,
  );
  if (totalSize > 0xffffffff) throw new Error("static package frame exceeds wasm32 limits");
  const frame = Buffer.alloc(totalSize);
  MAGIC.copy(frame, 0);
  frame.writeUInt16LE(1, 8);
  frame.writeUInt16LE(HEADER_SIZE, 10);
  frame.writeUInt32LE(compiled.length, 12);
  frame.writeUInt32LE(entryModuleId, 16);
  frame.writeUInt32LE(RECORD_SIZE, 20);

  let cursor = HEADER_SIZE + RECORD_SIZE * compiled.length;
  for (let id = 0; id < compiled.length; id++) {
    const record = HEADER_SIZE + id * RECORD_SIZE;
    const module = compiled[id];
    frame.writeUInt32LE(cursor, record);
    frame.writeUInt32LE(module.name.length, record + 4);
    module.name.copy(frame, cursor);
    cursor += module.name.length;
    frame.writeUInt32LE(cursor, record + 8);
    frame.writeUInt32LE(module.snapshot.length, record + 12);
    module.snapshot.copy(frame, cursor);
    cursor += module.snapshot.length;
  }
  if (cursor !== frame.length) throw new Error("internal static package frame size mismatch");
  return frame;
}

function compileBackend(frame) {
  const api = backend.exports;
  if (typeof api.mc_luau_backend_v1_compile_static_package !== "function")
    throw new Error("backend does not export static-package compilation");
  const framePointer = api.mc_luau_backend_v1_alloc(frame.length);
  const resultPointer = api.mc_luau_backend_v1_alloc(16);
  if (!framePointer || !resultPointer) throw new Error("backend allocation failed");
  new Uint8Array(api.memory.buffer, framePointer, frame.length).set(frame);
  new Uint8Array(api.memory.buffer, resultPointer, 16).fill(0);
  const status = api.mc_luau_backend_v1_compile_static_package(framePointer, frame.length, resultPointer);
  const result = new DataView(api.memory.buffer, resultPointer, 16);
  const dataPointer = result.getUint32(0, true);
  const dataSize = result.getUint32(4, true);
  const resultStatus = result.getUint32(8, true);
  if (status !== 0 || resultStatus !== 0 || !dataPointer || !dataSize)
    throw new Error(`backend failed with ${status}/${resultStatus}`);
  const object = Buffer.from(new Uint8Array(api.memory.buffer, dataPointer, dataSize));
  api.mc_luau_backend_v1_free(resultPointer);
  api.mc_luau_backend_v1_dealloc(resultPointer, 16);
  api.mc_luau_backend_v1_dealloc(framePointer, frame.length);
  return object;
}

const first = compileBackend(packageFrame());
const second = compileBackend(packageFrame());
if (!first.equals(second)) throw new Error("identical static package produced nondeterministic backend objects");
if (!first.subarray(0, 8).equals(Buffer.from([0, 97, 115, 109, 1, 0, 0, 0])))
  throw new Error("backend output is not a wasm v1 object");
writeFileSync(outputPath, first);
