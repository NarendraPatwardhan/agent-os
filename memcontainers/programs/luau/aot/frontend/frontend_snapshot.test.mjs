import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

function runfile(relative, variable) {
  if (!relative) throw new Error(`${variable} is not set`);
  if (relative.startsWith("/")) return relative;
  const root = process.env.RUNFILES_DIR;
  if (!root) throw new Error("RUNFILES_DIR is not set");
  return join(root, relative);
}

const contractInputs = [
  "memcontainers/programs/luau/aot/compiler/ir/BUILD.bazel",
  "memcontainers/programs/luau/aot/compiler/ir/frontend_snapshot_v1.zig",
  "memcontainers/programs/luau/aot/frontend/BUILD.bazel",
  "memcontainers/programs/luau/aot/frontend/compiler_error_channel.h",
  "memcontainers/programs/luau/aot/frontend/error_channel.h",
  "memcontainers/programs/luau/aot/frontend/frontend_adapter.cpp",
  "memcontainers/programs/luau/aot/frontend/frontend_fastflags.cpp",
  "memcontainers/programs/luau/aot/frontend/frontend_host.zig",
  "memcontainers/programs/luau/aot/frontend/host_wasi_stubs.c",
  "memcontainers/programs/luau/aot/frontend/trap.h",
  "memcontainers/programs/luau/aot/schema/BUILD.bazel",
  "memcontainers/programs/luau/aot/schema/frontend_snapshot_v1.h",
  "third_party/luau/BUILD.luau.bazel",
  "third_party/luau/BUILD.bazel",
  "third_party/luau/patches/0001-mc-vm.patch",
  "third_party/luau/patches/0002-mc-analysis.patch",
  "third_party/luau/patches/0003-mc-analysis-named-catch.patch",
  "third_party/luau/patches/0004-mc-frontend-nothread.patch",
  "third_party/luau/patches/0005-mc-aot-runtime-dispatch.patch",
].sort();

function frontendContractDigest() {
  const root = process.env.RUNFILES_DIR;
  if (!root) throw new Error("RUNFILES_DIR is not set");
  const hash = createHash("sha256");
  for (const path of contractInputs) {
    hash.update(path);
    hash.update(Buffer.from([0]));
    hash.update(readFileSync(join(root, "_main", path)));
    hash.update(Buffer.from([0xff]));
  }
  return hash.digest("hex");
}

function workspaceFile(path) {
  const root = process.env.RUNFILES_DIR;
  if (!root) throw new Error("RUNFILES_DIR is not set");
  return readFileSync(join(root, "_main", path));
}

function patchsetDigest() {
  const hash = createHash("sha256");
  for (const path of contractInputs.filter((path) => path.startsWith("third_party/luau/patches/")))
    hash.update(workspaceFile(path));
  return hash.digest("hex");
}

function u16(bytes, offset) {
  return bytes.readUInt16LE(offset);
}

function u32(bytes, offset) {
  return bytes.readUInt32LE(offset);
}

function u64(bytes, offset) {
  return Number(bytes.readBigUInt64LE(offset));
}

function parseSnapshot(bytes) {
  if (bytes.subarray(0, 8).toString("binary") !== "MCLUAOT\0") throw new Error("bad snapshot magic");
  if (u16(bytes, 8) !== 1 || u16(bytes, 10) !== 224) throw new Error("bad snapshot version/header");
  if (u32(bytes, 12) !== 1) throw new Error("bad snapshot pipeline flags");
  if (u64(bytes, 16) !== bytes.length) throw new Error("bad snapshot total size");
  if (u32(bytes, 184) !== 1) throw new Error("snapshot is not a single-module frontend unit");

  const protoCount = u32(bytes, 188);
  const irFunctionCount = u32(bytes, 192);
  const stringCount = u32(bytes, 196);
  const rootProto = u32(bytes, 200);
  const sectionCount = u32(bytes, 204);
  if (protoCount !== irFunctionCount || rootProto !== 0) throw new Error("invalid graph header counts");
  if (sectionCount !== 21) throw new Error(`expected all 21 canonical sections, got ${sectionCount}`);

  const sections = new Map();
  let payload = 224 + sectionCount * 32;
  for (let index = 0; index < sectionCount; index++) {
    const at = 224 + index * 32;
    const kind = u16(bytes, at);
    const flags = u16(bytes, at + 2);
    const recordSize = u32(bytes, at + 4);
    const offset = u64(bytes, at + 8);
    const length = u64(bytes, at + 16);
    const count = u32(bytes, at + 24);
    if (kind !== index + 1 || flags !== 0 || u32(bytes, at + 28) !== 0)
      throw new Error(`noncanonical section descriptor ${index}`);
    if (offset !== payload || length !== recordSize * count || offset + length > bytes.length)
      throw new Error(`invalid section range ${kind}`);
    sections.set(kind, { recordSize, offset, length, count });
    payload += length;
  }
  if (payload !== bytes.length) throw new Error("snapshot has trailing or missing bytes");

  if (sections.get(1).count !== stringCount) throw new Error("string header/table count mismatch");
  if (sections.get(3).count !== protoCount) throw new Error("proto header/table count mismatch");
  if (sections.get(15).count !== irFunctionCount) throw new Error("IR header/table count mismatch");

  return { protoCount, irFunctionCount, stringCount, sections };
}

function functionCommands(bytes, parsed, functionId) {
  const functions = parsed.sections.get(15);
  const instructions = parsed.sections.get(17);
  const record = functions.offset + functionId * functions.recordSize;
  if (u32(bytes, record) !== functionId || u32(bytes, record + 4) !== functionId)
    throw new Error(`function/proto identity mismatch for ${functionId}`);
  const blockCount = u32(bytes, record + 20);
  const instructionStart = u32(bytes, record + 24);
  const instructionCount = u32(bytes, record + 28);
  if (blockCount === 0 || instructionCount === 0) throw new Error(`empty IR function ${functionId}`);
  const commands = [];
  for (let index = 0; index < instructionCount; index++) {
    commands.push(bytes[instructions.offset + (instructionStart + index) * instructions.recordSize]);
  }
  return commands;
}

function importPaths(bytes, parsed) {
  const strings = parsed.sections.get(1);
  const stringBytes = parsed.sections.get(2);
  const protos = parsed.sections.get(3);
  const constants = parsed.sections.get(6);
  const constantItems = parsed.sections.get(7);
  const paths = [];

  for (let protoId = 0; protoId < protos.count; protoId++) {
    const proto = protos.offset + protoId * protos.recordSize;
    const constantStart = u32(bytes, proto + 44);
    const constantCount = u32(bytes, proto + 48);
    for (let constantId = 0; constantId < constantCount; constantId++) {
      const constant = constants.offset + (constantStart + constantId) * constants.recordSize;
      if (bytes[constant] !== 6) continue;

      const itemStart = u32(bytes, constant + 4);
      const itemCount = u32(bytes, constant + 8);
      const path = [];
      for (let itemId = 0; itemId < itemCount; itemId++) {
        const item = constantItems.offset + (itemStart + itemId) * constantItems.recordSize;
        const nameConstantId = u32(bytes, item);
        if (u32(bytes, item + 4) !== 0xffffffff || nameConstantId >= constantCount)
          throw new Error("invalid import constant item");
        const nameConstant = constants.offset + (constantStart + nameConstantId) * constants.recordSize;
        if (bytes[nameConstant] !== 4) throw new Error("import component is not a VM string constant");
        const stringId = u32(bytes, nameConstant + 4);
        if (stringId >= strings.count) throw new Error("import component string is out of bounds");
        const string = strings.offset + stringId * strings.recordSize;
        const byteOffset = u64(bytes, string);
        const byteLength = u32(bytes, string + 8);
        path.push(bytes.subarray(stringBytes.offset + byteOffset, stringBytes.offset + byteOffset + byteLength).toString());
      }
      paths.push(path);
    }
  }

  return paths;
}

const wasmBytes = readFileSync(runfile(process.env.LUAU_AOT_FRONTEND_WASM, "LUAU_AOT_FRONTEND_WASM"));
const module = await WebAssembly.compile(wasmBytes);
const imports = WebAssembly.Module.imports(module);
if (imports.length !== 0) throw new Error(`host compiler is not zero-import: ${JSON.stringify(imports)}`);
const exportNames = WebAssembly.Module.exports(module).map(({ name }) => name).sort();
const expectedExportNames = [
  "_start",
  "mc_luau_frontend_snapshot_v1_compile",
  "mc_luau_frontend_snapshot_v1_free",
  "mc_luau_frontend_snapshot_v1_last_raise_message",
  "mc_luau_frontend_snapshot_v1_last_raise_message_size",
  "mc_luau_frontend_v1_alloc",
  "mc_luau_frontend_v1_dealloc",
  "mc_luau_frontend_v1_init",
  "mc_luau_frontend_v1_validate_snapshot",
  "memory",
].sort();
if (JSON.stringify(exportNames) !== JSON.stringify(expectedExportNames))
  throw new Error(`frontend export surface drifted: ${JSON.stringify(exportNames)}`);

const instance = await WebAssembly.instantiate(module, {});
const api = instance.exports;
for (const name of [
  "memory",
  "mc_luau_frontend_v1_init",
  "mc_luau_frontend_v1_alloc",
  "mc_luau_frontend_v1_dealloc",
  "mc_luau_frontend_v1_validate_snapshot",
  "mc_luau_frontend_snapshot_v1_compile",
  "mc_luau_frontend_snapshot_v1_free",
]) {
  if (!(name in api)) throw new Error(`missing frontend export ${name}`);
}
api.mc_luau_frontend_v1_init();

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function compile(sourceText, chunkText) {
  const source = encoder.encode(sourceText);
  const chunk = encoder.encode(chunkText);
  const sourcePointer = api.mc_luau_frontend_v1_alloc(source.length);
  const chunkPointer = api.mc_luau_frontend_v1_alloc(chunk.length);
  const resultPointer = api.mc_luau_frontend_v1_alloc(20);
  if (!sourcePointer || !chunkPointer || !resultPointer) throw new Error("frontend host allocation failed");

  new Uint8Array(api.memory.buffer, sourcePointer, source.length).set(source);
  new Uint8Array(api.memory.buffer, chunkPointer, chunk.length).set(chunk);
  new Uint8Array(api.memory.buffer, resultPointer, 20).fill(0);
  const returned = api.mc_luau_frontend_snapshot_v1_compile(
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
  const status = result.getUint32(16, true);
  if (status !== returned) throw new Error(`status return/result mismatch: ${returned}/${status}`);

  const snapshot = dataPointer && dataSize
    ? Buffer.from(new Uint8Array(api.memory.buffer, dataPointer, dataSize))
    : Buffer.alloc(0);
  const diagnostic = diagnosticPointer && diagnosticSize
    ? decoder.decode(new Uint8Array(api.memory.buffer, diagnosticPointer, diagnosticSize))
    : "";
  const validation = dataPointer && dataSize
    ? api.mc_luau_frontend_v1_validate_snapshot(dataPointer, dataSize)
    : 0;

  api.mc_luau_frontend_snapshot_v1_free(resultPointer);
  api.mc_luau_frontend_v1_dealloc(resultPointer, 20);
  api.mc_luau_frontend_v1_dealloc(chunkPointer, chunk.length);
  api.mc_luau_frontend_v1_dealloc(sourcePointer, source.length);
  return { status, snapshot, diagnostic, validation };
}

const source = `
local function add(a, b)
    return a + b
end

return add(20, 22)
`;

const first = compile(source, "@frontend/closed-graph.luau");
if (first.status !== 0) throw new Error(`frontend compile failed: ${first.status}: ${first.diagnostic}`);
if (first.validation !== 0) throw new Error(`Zig rejected C++ FrontendSnapshotV1 with code ${first.validation}`);
const contractDigest = frontendContractDigest();
const carriedDigest = first.snapshot.subarray(88, 120).toString("hex");
if (carriedDigest !== contractDigest)
  throw new Error(`frontend contract identity drifted: carried=${carriedDigest} derived=${contractDigest}`);
const layoutIdentity = JSON.parse(workspaceFile("memcontainers/programs/luau/aot/maps/luau_aot_layout.json"));
const irIdentity = JSON.parse(workspaceFile("memcontainers/programs/luau/aot/maps/luau_aot_ir_coverage.json"));
const carriedPin = first.snapshot.subarray(24, 56).toString("hex");
const carriedPatchset = first.snapshot.subarray(56, 88).toString("hex");
const carriedIr = first.snapshot.subarray(120, 152).toString("hex");
const carriedLayout = first.snapshot.subarray(152, 184).toString("hex");
if (carriedPin !== layoutIdentity.luau_pin.archive_sha256) throw new Error("snapshot Luau pin identity drifted");
if (carriedPatchset !== patchsetDigest()) throw new Error("snapshot patchset identity drifted");
if (carriedIr !== irIdentity.input_sha256) throw new Error("snapshot IR enum identity drifted");
if (carriedLayout !== layoutIdentity.fields_sha256) throw new Error("snapshot layout identity drifted");
const parsed = parseSnapshot(first.snapshot);
if (parsed.protoCount !== 2) throw new Error(`expected root + child Proto, got ${parsed.protoCount}`);

const rootCommands = functionCommands(first.snapshot, parsed, 0);
const childCommands = functionCommands(first.snapshot, parsed, 1);
if (!rootCommands.includes(154) || !rootCommands.includes(155))
  throw new Error(`root IR lacks real CALL/RETURN commands: ${JSON.stringify(rootCommands)}`);
if (!childCommands.includes(36) || !childCommands.includes(155))
  throw new Error(`child IR lacks real ADD_NUM/RETURN commands: ${JSON.stringify(childCommands)}`);

const second = compile(source, "@frontend/closed-graph.luau");
if (second.status !== 0) throw new Error(`second frontend compile failed: ${second.diagnostic}`);
if (!first.snapshot.equals(second.snapshot)) throw new Error("identical input produced nondeterministic snapshot bytes");

const invalid = compile("local =", "@frontend/syntax-error.luau");
if (invalid.status !== 2 || invalid.snapshot.length !== 0 || invalid.diagnostic.length === 0)
  throw new Error(`syntax failure was not a structured diagnostic: ${JSON.stringify(invalid)}`);

const compound = compile("local t = { answer = 42 }; return t.answer", "@frontend/compound-constant.luau");
if (compound.status !== 4 || compound.snapshot.length !== 0 || !compound.diagnostic.includes("compound loader constant"))
  throw new Error(`unimplemented compound constants did not fail closed: ${JSON.stringify(compound)}`);

const imported = compile("return math.abs(-42)", "@frontend/import-constant.luau");
if (imported.status !== 0 || imported.validation !== 0)
  throw new Error(`decoded import frontend failed: ${imported.status}: ${imported.diagnostic}`);
const importedParsed = parseSnapshot(imported.snapshot);
if (JSON.stringify(importPaths(imported.snapshot, importedParsed)) !== JSON.stringify([["math", "abs"]]))
  throw new Error(`decoded import path mismatch: ${JSON.stringify(importPaths(imported.snapshot, importedParsed))}`);

const required = compile('return require("./module")', "@frontend/static-require-import.luau");
if (required.status !== 0 || required.validation !== 0)
  throw new Error(`static require import frontend failed: ${required.status}: ${required.diagnostic}`);
const requiredParsed = parseSnapshot(required.snapshot);
if (!functionCommands(required.snapshot, requiredParsed, 0).includes(127))
  throw new Error("decoded require snapshot lacks GET_CACHED_IMPORT");
if (JSON.stringify(importPaths(required.snapshot, requiredParsed)) !== JSON.stringify([["require"]]))
  throw new Error(`static require import path mismatch: ${JSON.stringify(importPaths(required.snapshot, requiredParsed))}`);

const threePartImport = compile("return game.workspace.part", "@frontend/three-part-import.luau");
if (threePartImport.status !== 0 || threePartImport.validation !== 0)
  throw new Error(`three-part import frontend failed: ${threePartImport.status}: ${threePartImport.diagnostic}`);
const threePartParsed = parseSnapshot(threePartImport.snapshot);
if (JSON.stringify(importPaths(threePartImport.snapshot, threePartParsed)) !== JSON.stringify([["game", "workspace", "part"]]))
  throw new Error(`three-part import path mismatch: ${JSON.stringify(importPaths(threePartImport.snapshot, threePartParsed))}`);

console.log(
  `verified zero-import FrontendSnapshotV1: ${parsed.protoCount} protos, ` +
    `${parsed.sections.get(16).count} blocks, ${parsed.sections.get(17).count} instructions, deterministic bytes`,
);
