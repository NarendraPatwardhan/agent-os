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

function requireFunction(entries, moduleName, name, surface) {
  const match = entries.find((entry) => entry.module === moduleName && entry.name === name);
  if (!match) throw new Error(`${surface} is missing required function ${moduleName}.${name}`);
  if (match.kind !== "function") {
    throw new Error(`${surface} ${moduleName}.${name} has kind ${match.kind}, expected function`);
  }
}

const wasmBytes = readFileSync(
  runfile(process.env.LUAU_AOT_RUNTIME_ORACLE, "LUAU_AOT_RUNTIME_ORACLE"),
);
const manifest = JSON.parse(readFileSync(
  runfile(process.env.LUAU_AOT_RUNTIME_ORACLE_MANIFEST, "LUAU_AOT_RUNTIME_ORACLE_MANIFEST"),
  "utf8",
));
const module = new WebAssembly.Module(wasmBytes);
const imports = WebAssembly.Module.imports(module);
const exports = WebAssembly.Module.exports(module);

for (const entry of imports) {
  if (entry.module !== "env") {
    throw new Error(`raw relocation oracle has non-env import ${entry.module}.${entry.name}`);
  }
}

for (const name of manifest.runtime_contract_imports) {
  requireFunction(imports, "env", name, "import surface");
}

for (const name of manifest.required_exports) {
  const match = exports.find((entry) => entry.name === name);
  if (!match) throw new Error(`export surface is missing required function ${name}`);
  if (match.kind !== "function") {
    throw new Error(`export ${name} has kind ${match.kind}, expected function`);
  }
}

for (const name of manifest.required_global_exports) {
  const match = exports.find((entry) => entry.name === name);
  if (!match) throw new Error(`export surface is missing required global ${name}`);
  if (match.kind !== "global") {
    throw new Error(`export ${name} has kind ${match.kind}, expected global`);
  }
}

const forbidden = manifest.forbidden_symbol_fragments;
for (const entry of [...imports, ...exports]) {
  if (forbidden.some((symbol) => entry.name.includes(symbol))) {
    throw new Error(`forbidden Luau symbol remains in linked oracle: ${entry.name}`);
  }
}

if (exports.some((entry) => entry.name === "_start")) {
  throw new Error("runtime link oracle unexpectedly exports _start");
}

for (const section of manifest.consumed_relocation_sections) {
  if (WebAssembly.Module.customSections(module, section).length !== 0) {
    throw new Error(`wasm-ld did not consume custom section ${section}`);
  }
}

const toolchainImports = imports.map(({ name }) => name)
  .filter((name) => !manifest.runtime_contract_imports.includes(name))
  .sort();
if (JSON.stringify(toolchainImports) !== JSON.stringify(manifest.toolchain_unresolved_imports))
  throw new Error(`toolchain import surface drifted: ${JSON.stringify(toolchainImports)}`);
if (imports.length !== manifest.import_count || exports.length !== manifest.export_count)
  throw new Error(`link oracle surface counts drifted: ${imports.length} imports, ${exports.length} exports`);
const outputHash = createHash("sha256").update(wasmBytes).digest("hex");
if (outputHash !== manifest.output_sha256)
  throw new Error(`link oracle digest drifted: ${outputHash}`);

console.log(`verified runtime link oracle (${imports.length} imports, ${exports.length} exports, ${outputHash})`);
