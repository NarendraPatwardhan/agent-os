import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const generatedSymbol = "mc_luau_aot_v1_generated_ir_function";
const packageSymbols = [0, 1, 2].map((id) => `mc_luau_aot_v1_function_${String(id).padStart(8, "0")}`);

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

function backendPackage(snapshot) {
  const api = backend.exports;
  const snapshotPointer = api.mc_luau_backend_v1_alloc(snapshot.length);
  const resultPointer = api.mc_luau_backend_v1_alloc(16);
  if (!snapshotPointer || !resultPointer) throw new Error("backend package allocation failed");
  new Uint8Array(api.memory.buffer, snapshotPointer, snapshot.length).set(snapshot);
  new Uint8Array(api.memory.buffer, resultPointer, 16).fill(0);
  const status = api.mc_luau_backend_v1_compile_package(snapshotPointer, snapshot.length, resultPointer);
  const result = new DataView(api.memory.buffer, resultPointer, 16);
  const dataPointer = result.getUint32(0, true);
  const dataSize = result.getUint32(4, true);
  const resultStatus = result.getUint32(8, true);
  if (status !== 0 || resultStatus !== 0 || !dataPointer || !dataSize)
    throw new Error(`backend package failed with ${status}/${resultStatus}`);
  const object = Buffer.from(new Uint8Array(api.memory.buffer, dataPointer, dataSize));
  api.mc_luau_backend_v1_free(resultPointer);
  api.mc_luau_backend_v1_dealloc(resultPointer, 16);
  api.mc_luau_backend_v1_dealloc(snapshotPointer, snapshot.length);
  return object;
}

function snapshotSection(snapshot, wantedKind) {
  const sectionCount = snapshot.readUInt32LE(204);
  for (let index = 0; index < sectionCount; index++) {
    const descriptor = 224 + index * 32;
    if (snapshot.readUInt16LE(descriptor) !== wantedKind) continue;
    return {
      recordSize: snapshot.readUInt32LE(descriptor + 4),
      offset: Number(snapshot.readBigUInt64LE(descriptor + 8)),
      count: snapshot.readUInt32LE(descriptor + 24),
    };
  }
  throw new Error(`snapshot is missing section ${wantedKind}`);
}

function capturedSnapshotOffsets(snapshot) {
  const protos = snapshotSection(snapshot, 3);
  const functions = snapshotSection(snapshot, 15);
  const blocks = snapshotSection(snapshot, 16);
  const instructions = snapshotSection(snapshot, 17);
  const operands = snapshotSection(snapshot, 18);
  const constants = snapshotSection(snapshot, 19);
  const functionOffset = functions.offset + functions.recordSize;
  return {
    proto2: protos.offset + 2 * protos.recordSize,
    block0: blocks.offset + snapshot.readUInt32LE(functionOffset + 16) * blocks.recordSize,
    instruction(relativeId) {
      return instructions.offset +
        (snapshot.readUInt32LE(functionOffset + 24) + relativeId) * instructions.recordSize;
    },
    operand(instructionId, operandId) {
      const instructionOffset = this.instruction(instructionId);
      return operands.offset +
        (snapshot.readUInt32LE(instructionOffset + 8) + operandId) * operands.recordSize;
    },
    findConstant(kind, bits) {
      const start = snapshot.readUInt32LE(functionOffset + 40);
      const count = snapshot.readUInt32LE(functionOffset + 44);
      for (let id = 0; id < count; id++) {
        const offset = constants.offset + (start + id) * constants.recordSize;
        if (snapshot[offset] === kind && snapshot.readBigUInt64LE(offset + 8) === bits) return id;
      }
      throw new Error(`captured snapshot is missing constant ${kind}/${bits}`);
    },
  };
}

function expectPackageRejection(snapshot, label) {
  try {
    backendPackage(snapshot);
  } catch {
    return;
  }
  throw new Error(`captured-call mutation was accepted: ${label}`);
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

function linkPackage(object) {
  const directory = mkdtempSync(join(process.env.TEST_TMPDIR || tmpdir(), "luau-aot-package-"));
  const objectPath = join(directory, "package.o");
  const wasmPath = join(directory, "package.wasm");
  writeFileSync(objectPath, object);
  const linked = spawnSync(
    wasmLd,
    [
      "--no-entry",
      "--allow-undefined",
      "--export-memory",
      ...packageSymbols.map((symbol) => `--export=${symbol}`),
      objectPath,
      "-o",
      wasmPath,
    ],
    { encoding: "utf8" },
  );
  if (linked.status !== 0)
    throw new Error(`package wasm-ld failed (${linked.status}): ${linked.stdout}\n${linked.stderr}`);
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
    ["env", "mc_luau_aot_v1_return_one", "function"],
    ["env", "mc_luau_aot_v1_interrupt", "function"],
  ];
  if (name === "loop")
    expectedImports.push(["env", "mc_luau_aot_v1_do_arith", "function"]);
  if (JSON.stringify(moduleImports) !== JSON.stringify(expectedImports))
    throw new Error(`${name}: unexpected generated imports ${JSON.stringify(moduleImports)}`);

  let instance;
  let committed = null;
  let interrupts = 0;
  instance = await WebAssembly.instantiate(module, {
    env: {
      mc_luau_aot_v1_return_one(state, sourceRegister) {
        if (state !== 1024) throw new Error(`${name}: wrong state ${state}`);
        const view = new DataView(instance.exports.memory.buffer);
        const base = view.getUint32(state + 12, true);
        const source = base + sourceRegister * 16;
        if (view.getUint32(source + 12, true) !== 3)
          throw new Error(`${name}: return helper received non-number register ${sourceRegister}`);
        committed = view.getFloat64(source, true);
      },
      mc_luau_aot_v1_interrupt(state, pc) {
        if (state !== 1024 || pc < 0) throw new Error(`${name}: invalid interrupt ${state}/${pc}`);
        interrupts++;
        return 0;
      },
      mc_luau_aot_v1_do_arith() {
        throw new Error(`${name}: bounded numeric fixture unexpectedly entered its arithmetic slow path`);
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

async function executeSilentRoot() {
  const name = "silent-root";
  const source = readFileSync(
    runfile(process.env.LUAU_AOT_SILENT_SOURCE, "LUAU_AOT_SILENT_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@aot/silent_return.luau");
  const object = backendObject(snapshot, 0);
  const module = await WebAssembly.compile(linkObject(object, name));
  const moduleImports = WebAssembly.Module.imports(module).map(({ module, name: importName, kind }) => [module, importName, kind]);
  const expectedImports = [
    ["env", "mc_luau_aot_v1_return_one", "function"],
    ["env", "mc_luau_aot_v1_interrupt", "function"],
  ];
  if (JSON.stringify(moduleImports) !== JSON.stringify(expectedImports))
    throw new Error(`${name}: unexpected generated imports ${JSON.stringify(moduleImports)}`);

  let committed = null;
  let interrupts = 0;
  let instance;
  instance = await WebAssembly.instantiate(module, {
    env: {
      mc_luau_aot_v1_return_one(state, sourceRegister) {
        if (state !== 1024) throw new Error(`${name}: wrong state ${state}`);
        const view = new DataView(instance.exports.memory.buffer);
        const base = view.getUint32(state + 12, true);
        const source = base + sourceRegister * 16;
        if (view.getUint32(source + 12, true) !== 3)
          throw new Error(`${name}: return helper received non-number register ${sourceRegister}`);
        committed = view.getFloat64(source, true);
      },
      mc_luau_aot_v1_interrupt(state, pc) {
        if (state !== 1024 || pc < 0) throw new Error(`${name}: invalid interrupt ${state}/${pc}`);
        interrupts++;
        return 0;
      },
    },
  });
  const state = 1024;
  const base = 2048;
  new DataView(instance.exports.memory.buffer).setUint32(state + 12, base, true);
  const status = instance.exports[generatedSymbol](state, 0);
  if (status !== 0 || committed !== 30 || interrupts === 0)
    throw new Error(`${name}: status=${status}, result=${committed}, interrupts=${interrupts}`);
  return { objectSize: object.length, interrupts };
}

async function executeSlowAdd() {
  const name = "slow-add";
  const source = readFileSync(
    runfile(process.env.LUAU_AOT_SLOW_ADD_SOURCE, "LUAU_AOT_SLOW_ADD_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@aot/slow_add.luau");
  const object = backendObject(snapshot, 1);
  const module = await WebAssembly.compile(linkObject(object, name));
  const moduleImports = WebAssembly.Module.imports(module).map(({ module, name: importName, kind }) => [module, importName, kind]);
  const expectedImports = [
    ["env", "mc_luau_aot_v1_return_one", "function"],
    ["env", "mc_luau_aot_v1_interrupt", "function"],
    ["env", "mc_luau_aot_v1_do_arith", "function"],
  ];
  if (JSON.stringify(moduleImports) !== JSON.stringify(expectedImports))
    throw new Error(`${name}: unexpected generated imports ${JSON.stringify(moduleImports)}`);

  let instance;
  let committed = null;
  let interrupts = 0;
  let helperCalls = 0;
  instance = await WebAssembly.instantiate(module, {
    env: {
      mc_luau_aot_v1_return_one(state, sourceRegister) {
        if (state !== 1024) throw new Error(`${name}: wrong state ${state}`);
        const view = new DataView(instance.exports.memory.buffer);
        const base = view.getUint32(state + 12, true);
        const source = base + sourceRegister * 16;
        if (view.getUint32(source + 12, true) !== 3)
          throw new Error(`${name}: return helper received non-number register ${sourceRegister}`);
        committed = view.getFloat64(source, true);
      },
      mc_luau_aot_v1_interrupt(state, pc) {
        if (state !== 1024 || pc < 0) throw new Error(`${name}: invalid interrupt ${state}/${pc}`);
        interrupts++;
        return 0;
      },
      mc_luau_aot_v1_do_arith(state, destination, lhs, rhs, operation) {
        if (state !== 1024 || destination !== 2 || lhs !== 0 || rhs !== 1 || operation !== 0)
          throw new Error(`${name}: invalid slow helper ABI ${state}/${destination}/${lhs}/${rhs}/${operation}`);
        helperCalls++;
        const view = new DataView(instance.exports.memory.buffer);
        const relocatedBase = 4096;
        view.setFloat64(relocatedBase + destination * 16, 42, true);
        view.setInt32(relocatedBase + destination * 16 + 12, 3, true);
        view.setUint32(state + 12, relocatedBase, true);
      },
    },
  });

  const generated = instance.exports[generatedSymbol];
  const view = new DataView(instance.exports.memory.buffer);
  const state = 1024;
  const base = 2048;

  view.setUint32(state + 12, base, true);
  view.setFloat64(base, 20, true);
  view.setInt32(base + 12, 3, true);
  view.setFloat64(base + 16, 22, true);
  view.setInt32(base + 28, 3, true);
  if (generated(state, 0) !== 0 || committed !== 42 || helperCalls !== 0)
    throw new Error(`${name}: numeric fast path failed: result=${committed}, helpers=${helperCalls}`);

  committed = null;
  view.setUint32(state + 12, base, true);
  view.setInt32(base + 12, 5, true);
  view.setInt32(base + 28, 5, true);
  view.setFloat64(base + 32, -999, true);
  view.setInt32(base + 44, 3, true);
  if (generated(state, 0) !== 0 || committed !== 42 || helperCalls !== 1)
    throw new Error(`${name}: slow rejoin failed: result=${committed}, helpers=${helperCalls}`);
  if (interrupts < 2) throw new Error(`${name}: rejoined paths skipped the shared interrupt block`);

  return { objectSize: object.length, interrupts, helperCalls };
}

async function executeCompiledCallPackage() {
  const name = "compiled-call-package";
  const source = readFileSync(
    runfile(process.env.LUAU_AOT_COMPILED_CALL_SOURCE, "LUAU_AOT_COMPILED_CALL_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@aot/compiled_call.luau");
  const first = backendPackage(snapshot);
  const second = backendPackage(snapshot);
  if (!first.equals(second)) throw new Error(`${name}: package backend is nondeterministic`);

  const module = await WebAssembly.compile(linkPackage(first));
  const moduleImports = WebAssembly.Module.imports(module).map(({ module: importModule, name: importName, kind }) => [importModule, importName, kind]);
  const expectedImports = [
    ["env", "mc_luau_aot_v1_return_one", "function"],
    ["env", "mc_luau_aot_v1_interrupt", "function"],
    ["env", "mc_luau_aot_v1_do_arith", "function"],
    ["env", "mc_luau_aot_v1_dupclosure", "function"],
    ["env", "mc_luau_aot_v1_call_fixed", "function"],
  ];
  if (JSON.stringify(moduleImports) !== JSON.stringify(expectedImports))
    throw new Error(`${name}: unexpected generated imports ${JSON.stringify(moduleImports)}`);

  let instance;
  let returned = null;
  let interrupts = 0;
  let nestedCalls = 0;
  const closureChildren = [];
  const state = 1024;
  const initialBase = 2048;
  const relocatedCallerBase = 4096;
  const childBase = 8192;
  const tvalueSize = 16;
  const writeNumber = (view, base, register, value) => {
    view.setFloat64(base + register * tvalueSize, value, true);
    view.setUint32(base + register * tvalueSize + 12, 3, true);
  };

  instance = await WebAssembly.instantiate(module, {
    env: {
      mc_luau_aot_v1_return_one(returnState, sourceRegister) {
        if (returnState !== state) throw new Error(`${name}: wrong return state ${returnState}`);
        const view = new DataView(instance.exports.memory.buffer);
        const base = view.getUint32(state + 12, true);
        const source = base + sourceRegister * tvalueSize;
        const tag = view.getUint32(source + 12, true);
        returned = tag === 3
          ? { tag, value: view.getFloat64(source, true) }
          : { tag, value: view.getUint32(source, true) };
      },
      mc_luau_aot_v1_interrupt(interruptState, pc) {
        if (interruptState !== state || pc < 0) throw new Error(`${name}: invalid interrupt`);
        interrupts++;
        return 0;
      },
      mc_luau_aot_v1_do_arith() {
        throw new Error(`${name}: numeric package unexpectedly entered arithmetic fallback`);
      },
      mc_luau_aot_v1_dupclosure(closureState, destinationRegister, childProtoId) {
        if (closureState !== state || (childProtoId !== 1 && childProtoId !== 2))
          throw new Error(`${name}: invalid child closure ${closureState}/${childProtoId}`);
        closureChildren.push(childProtoId);
        const view = new DataView(instance.exports.memory.buffer);
        const base = view.getUint32(state + 12, true);
        const destination = base + destinationRegister * tvalueSize;
        view.setUint32(destination, childProtoId, true);
        view.setUint32(destination + 12, 6, true);
      },
      mc_luau_aot_v1_call_fixed(callState, functionRegister, parameterCount, resultCount) {
        if (callState !== state || functionRegister !== 3 || parameterCount !== 2 || resultCount !== 1)
          throw new Error(`${name}: invalid fixed call ABI`);
        const memory = new Uint8Array(instance.exports.memory.buffer);
        const view = new DataView(memory.buffer);
        const callerBase = view.getUint32(state + 12, true);
        const functionSlot = callerBase + functionRegister * tvalueSize;
        if (view.getUint32(functionSlot + 12, true) !== 6 || view.getUint32(functionSlot, true) !== 2)
          throw new Error(`${name}: caller did not materialize child Proto 2`);

        memory.set(memory.subarray(callerBase, callerBase + 6 * tvalueSize), relocatedCallerBase);
        memory.fill(0, childBase, childBase + 3 * tvalueSize);
        memory.set(
          memory.subarray(relocatedCallerBase + 4 * tvalueSize, relocatedCallerBase + 6 * tvalueSize),
          childBase,
        );
        view.setUint32(state + 12, childBase, true);
        returned = null;
        const childStatus = instance.exports[packageSymbols[2]](state, 0);
        if (childStatus !== 0 || returned?.tag !== 3)
          throw new Error(`${name}: nested child failed with ${childStatus}/${JSON.stringify(returned)}`);

        const childResult = returned.value;
        view.setUint32(state + 12, relocatedCallerBase, true);
        writeNumber(view, relocatedCallerBase, functionRegister, childResult);
        nestedCalls++;
        return 0;
      },
    },
  });

  for (const symbol of packageSymbols) {
    if (typeof instance.exports[symbol] !== "function")
      throw new Error(`${name}: missing generated symbol ${symbol}`);
  }

  const view = new DataView(instance.exports.memory.buffer);
  view.setUint32(state + 12, initialBase, true);
  new Uint8Array(instance.exports.memory.buffer, initialBase, tvalueSize).fill(0);
  if (instance.exports[packageSymbols[0]](state, 0) !== 0 || returned?.tag !== 6 || returned.value !== 1)
    throw new Error(`${name}: root did not return child Proto 1 closure: ${JSON.stringify(returned)}`);

  for (const [lhs, rhs, expected] of [[20, 22, 42], [-50, 8, -42], [1234, 5678, 6912]]) {
    new Uint8Array(instance.exports.memory.buffer, initialBase, 6 * tvalueSize).fill(0);
    view.setUint32(state + 12, initialBase, true);
    writeNumber(view, initialBase, 0, lhs);
    writeNumber(view, initialBase, 1, rhs);
    returned = null;
    const status = instance.exports[packageSymbols[1]](state, 0);
    if (status !== 0 || returned?.tag !== 3 || returned.value !== expected)
      throw new Error(`${name}: caller ${lhs}/${rhs} failed with ${status}/${JSON.stringify(returned)}`);
  }
  if (nestedCalls !== 3 || closureChildren.join(",") !== "1,2,2,2" || interrupts < 7)
    throw new Error(`${name}: execution evidence incomplete: calls=${nestedCalls}, closures=${closureChildren}, interrupts=${interrupts}`);
  return { objectSize: first.length, nestedCalls, interrupts };
}

async function executeCapturedCallPackage() {
  const name = "captured-call-package";
  const source = readFileSync(
    runfile(process.env.LUAU_AOT_CAPTURED_CALL_SOURCE, "LUAU_AOT_CAPTURED_CALL_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@aot/captured_call.luau");
  const first = backendPackage(snapshot);
  const second = backendPackage(snapshot);
  if (!first.equals(second)) throw new Error(`${name}: package backend is nondeterministic`);

  {
    const mutated = Buffer.from(snapshot);
    const offsets = capturedSnapshotOffsets(mutated);
    mutated.writeUInt32LE(1, offsets.block0 + 4);
    expectPackageRejection(mutated, "closure cluster crosses its bytecode-block boundary");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = capturedSnapshotOffsets(mutated);
    mutated.writeUInt32LE(offsets.findConstant(2, 1n), offsets.operand(9, 1) + 4);
    expectPackageRejection(mutated, "LCT_REF replaces the sole LCT_VAL capture");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = capturedSnapshotOffsets(mutated);
    mutated.writeUInt32LE(1, offsets.operand(6, 1) + 4);
    expectPackageRejection(mutated, "child upvalue slot is not U0");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = capturedSnapshotOffsets(mutated);
    mutated[offsets.instruction(8)] = 152;
    mutated[offsets.instruction(9)] = 146;
    expectPackageRejection(mutated, "CHECK_GC occurs after the CAPTURE marker");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = capturedSnapshotOffsets(mutated);
    mutated[offsets.proto2 + 29] = 2;
    expectPackageRejection(mutated, "child declares more than one upvalue");
  }

  const module = await WebAssembly.compile(linkPackage(first));
  const moduleImports = WebAssembly.Module.imports(module).map(({ module: importModule, name: importName, kind }) => [importModule, importName, kind]);
  const expectedImports = [
    ["env", "mc_luau_aot_v1_return_one", "function"],
    ["env", "mc_luau_aot_v1_interrupt", "function"],
    ["env", "mc_luau_aot_v1_do_arith", "function"],
    ["env", "mc_luau_aot_v1_dupclosure", "function"],
    ["env", "mc_luau_aot_v1_newclosure_value", "function"],
    ["env", "mc_luau_aot_v1_get_value_upvalue", "function"],
    ["env", "mc_luau_aot_v1_call_fixed", "function"],
  ];
  if (JSON.stringify(moduleImports) !== JSON.stringify(expectedImports))
    throw new Error(`${name}: unexpected generated imports ${JSON.stringify(moduleImports)}`);

  let instance;
  let returned = null;
  let capturedValue = null;
  let interrupts = 0;
  let nestedCalls = 0;
  let captureCount = 0;
  const closureChildren = [];
  const state = 1024;
  const initialBase = 2048;
  const relocatedCallerBase = 4096;
  const childBase = 8192;
  const finalCallerBase = 12288;
  const tvalueSize = 16;
  const writeNumber = (view, base, register, value) => {
    view.setFloat64(base + register * tvalueSize, value, true);
    view.setUint32(base + register * tvalueSize + 12, 3, true);
  };
  const writeClosure = (view, base, register, childProtoId) => {
    view.setUint32(base + register * tvalueSize, childProtoId, true);
    view.setUint32(base + register * tvalueSize + 12, 6, true);
  };

  instance = await WebAssembly.instantiate(module, {
    env: {
      mc_luau_aot_v1_return_one(returnState, sourceRegister) {
        if (returnState !== state) throw new Error(`${name}: wrong return state ${returnState}`);
        const view = new DataView(instance.exports.memory.buffer);
        const base = view.getUint32(state + 12, true);
        const source = base + sourceRegister * tvalueSize;
        const tag = view.getUint32(source + 12, true);
        returned = tag === 3
          ? { tag, value: view.getFloat64(source, true) }
          : { tag, value: view.getUint32(source, true) };
      },
      mc_luau_aot_v1_interrupt(interruptState, pc) {
        if (interruptState !== state || pc < 0) throw new Error(`${name}: invalid interrupt`);
        interrupts++;
        return 0;
      },
      mc_luau_aot_v1_do_arith() {
        throw new Error(`${name}: numeric capture unexpectedly entered arithmetic fallback`);
      },
      mc_luau_aot_v1_dupclosure(closureState, destinationRegister, childProtoId) {
        if (closureState !== state || childProtoId !== 1)
          throw new Error(`${name}: invalid closed child ${closureState}/${childProtoId}`);
        closureChildren.push(childProtoId);
        const view = new DataView(instance.exports.memory.buffer);
        writeClosure(view, view.getUint32(state + 12, true), destinationRegister, childProtoId);
      },
      mc_luau_aot_v1_newclosure_value(closureState, destinationRegister, childProtoId, captureRegister) {
        if (closureState !== state || destinationRegister !== 2 || childProtoId !== 2 || captureRegister !== 0)
          throw new Error(`${name}: invalid value closure ABI`);
        const memory = new Uint8Array(instance.exports.memory.buffer);
        const view = new DataView(memory.buffer);
        const callerBase = view.getUint32(state + 12, true);
        if (view.getUint32(callerBase + captureRegister * tvalueSize + 12, true) !== 3)
          throw new Error(`${name}: value closure did not capture a number`);
        capturedValue = view.getFloat64(callerBase + captureRegister * tvalueSize, true);
        memory.set(memory.subarray(callerBase, callerBase + 5 * tvalueSize), relocatedCallerBase);
        writeClosure(view, relocatedCallerBase, destinationRegister, childProtoId);
        view.setUint32(state + 12, relocatedCallerBase, true);
        closureChildren.push(childProtoId);
        captureCount++;
      },
      mc_luau_aot_v1_get_value_upvalue(upvalueState, destinationRegister, upvalueIndex) {
        if (upvalueState !== state || destinationRegister !== 2 || upvalueIndex !== 0 || capturedValue === null)
          throw new Error(`${name}: invalid value upvalue ABI`);
        const view = new DataView(instance.exports.memory.buffer);
        writeNumber(view, view.getUint32(state + 12, true), destinationRegister, capturedValue);
      },
      mc_luau_aot_v1_call_fixed(callState, functionRegister, parameterCount, resultCount) {
        if (callState !== state || functionRegister !== 3 || parameterCount !== 1 || resultCount !== 1)
          throw new Error(`${name}: invalid fixed call ABI`);
        const memory = new Uint8Array(instance.exports.memory.buffer);
        const view = new DataView(memory.buffer);
        const callerBase = view.getUint32(state + 12, true);
        if (callerBase !== relocatedCallerBase || view.getUint32(callerBase + functionRegister * tvalueSize + 12, true) !== 6 ||
            view.getUint32(callerBase + functionRegister * tvalueSize, true) !== 2)
          throw new Error(`${name}: generated code did not reload/copy the captured closure`);

        memory.set(memory.subarray(callerBase, callerBase + 5 * tvalueSize), finalCallerBase);
        memory.fill(0, childBase, childBase + 3 * tvalueSize);
        memory.set(
          memory.subarray(finalCallerBase + 4 * tvalueSize, finalCallerBase + 5 * tvalueSize),
          childBase,
        );
        view.setUint32(state + 12, childBase, true);
        returned = null;
        const childStatus = instance.exports[packageSymbols[2]](state, 0);
        if (childStatus !== 0 || returned?.tag !== 3)
          throw new Error(`${name}: captured child failed with ${childStatus}/${JSON.stringify(returned)}`);

        const childResult = returned.value;
        view.setUint32(state + 12, finalCallerBase, true);
        writeNumber(view, finalCallerBase, functionRegister, childResult);
        nestedCalls++;
        return 0;
      },
    },
  });

  for (const symbol of packageSymbols) {
    if (typeof instance.exports[symbol] !== "function")
      throw new Error(`${name}: missing generated symbol ${symbol}`);
  }

  const memory = new Uint8Array(instance.exports.memory.buffer);
  const view = new DataView(memory.buffer);
  view.setUint32(state + 12, initialBase, true);
  memory.fill(0, initialBase, initialBase + tvalueSize);
  if (instance.exports[packageSymbols[0]](state, 0) !== 0 || returned?.tag !== 6 || returned.value !== 1)
    throw new Error(`${name}: root did not return child Proto 1 closure: ${JSON.stringify(returned)}`);

  for (const [lhs, rhs, expected] of [[20, 22, 42], [-50, 8, -42], [1234, 5678, 6912]]) {
    memory.fill(0, initialBase, finalCallerBase + 5 * tvalueSize);
    view.setUint32(state + 12, initialBase, true);
    writeNumber(view, initialBase, 0, lhs);
    writeNumber(view, initialBase, 1, rhs);
    capturedValue = null;
    returned = null;
    const status = instance.exports[packageSymbols[1]](state, 0);
    if (status !== 0 || returned?.tag !== 3 || returned.value !== expected)
      throw new Error(`${name}: caller ${lhs}/${rhs} failed with ${status}/${JSON.stringify(returned)}`);
  }
  if (nestedCalls !== 3 || captureCount !== 3 || closureChildren.join(",") !== "1,2,2,2" || interrupts < 7)
    throw new Error(`${name}: execution evidence incomplete: calls=${nestedCalls}, captures=${captureCount}, closures=${closureChildren}, interrupts=${interrupts}`);
  return { objectSize: first.length, nestedCalls, captureCount, interrupts };
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
const silent = await executeSilentRoot();
const slowAdd = await executeSlowAdd();
const compiledCall = await executeCompiledCallPackage();
const capturedCall = await executeCapturedCallPackage();

console.log(
  `frontend -> IR -> relocatable wasm: scalar ${scalar.objectSize} bytes, loop ${loop.objectSize} bytes; ` +
    `silent root ${silent.objectSize} bytes, slow add ${slowAdd.objectSize} bytes; ` +
    `compiled call package ${compiledCall.objectSize} bytes/${compiledCall.nestedCalls} nested calls; ` +
    `captured call package ${capturedCall.objectSize} bytes/${capturedCall.captureCount} captures; ` +
    `interrupt calls ${scalar.interrupts}/${loop.interrupts}/${silent.interrupts}/${slowAdd.interrupts}; ` +
    `slow helpers ${slowAdd.helperCalls}`,
);
