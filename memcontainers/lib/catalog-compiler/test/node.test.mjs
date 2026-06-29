import { readFileSync } from "node:fs";
import { join } from "node:path";

function runfile(rel, envVar) {
  if (!rel) throw new Error(`${envVar} is not set`);
  const root = process.env.RUNFILES_DIR;
  if (!root) throw new Error("RUNFILES_DIR is not set");
  return join(root, rel);
}

function unpack(pair) {
  const raw = BigInt.asUintN(64, pair);
  return [Number(raw & 0xffff_ffffn), Number(raw >> 32n)];
}

function writeBytes(exports, bytes) {
  const ptr = exports.cc_alloc(bytes.length);
  new Uint8Array(exports.memory.buffer, ptr, bytes.length).set(bytes);
  return ptr;
}

function readReturn(exports, pair) {
  const [ptr, len] = unpack(pair);
  const bytes = new Uint8Array(exports.memory.buffer, ptr, len).slice();
  exports.cc_free(ptr, len);
  return bytes;
}

const wasm = readFileSync(runfile(process.env.MC_CATALOG_COMPILER_WASM, "MC_CATALOG_COMPILER_WASM"));
const source = readFileSync(runfile(process.env.MC_GITHUB_FIXTURE, "MC_GITHUB_FIXTURE"));
const opts = readFileSync(runfile(process.env.MC_GITHUB_OPTS, "MC_GITHUB_OPTS"));

const mod = await WebAssembly.compile(wasm);
const imports = WebAssembly.Module.imports(mod);
if (imports.length !== 0) {
  throw new Error(`catalog compiler imported host symbols: ${JSON.stringify(imports)}`);
}
const instance = await WebAssembly.instantiate(mod, {});
const e = instance.exports;
if (e.cc_bundle_schema_version() !== 1) {
  throw new Error("unexpected bundle schema version");
}

const srcPtr = writeBytes(e, source);
const optsPtr = writeBytes(e, opts);
const out = readReturn(e, e.cc_compile(srcPtr, source.length, optsPtr, opts.length));
e.cc_free(srcPtr, source.length);
e.cc_free(optsPtr, opts.length);

const text = new TextDecoder().decode(out);
if (!text.includes("index.json") || !text.includes("records/")) {
  throw new Error("framed bundle did not contain index and records entries");
}
if (text.includes("connection_ref")) {
  throw new Error("connection_ref leaked into compiler bundle");
}

console.log("catalog compiler instantiated under Node WebAssembly and emitted a sharded bundle");
