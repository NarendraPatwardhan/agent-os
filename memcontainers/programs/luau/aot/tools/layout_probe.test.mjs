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

function fieldNames(text) {
  const names = [];
  for (const line of text.split("\n")) {
    const match = line.match(/^LAYOUT_FIELD\(([A-Z0-9_]+),/);
    if (match) names.push(match[1]);
  }
  if (names.length === 0) throw new Error("layout field definition is empty");
  if (new Set(names).size !== names.length) throw new Error("duplicate layout field name");
  return names;
}

const wasmBytes = readFileSync(runfile(process.env.LUAU_AOT_LAYOUT_WASM, "LUAU_AOT_LAYOUT_WASM"));
const fieldText = readFileSync(runfile(process.env.LUAU_AOT_LAYOUT_FIELDS, "LUAU_AOT_LAYOUT_FIELDS"), "utf8");
const expected = JSON.parse(
  readFileSync(runfile(process.env.LUAU_AOT_LAYOUT_MANIFEST, "LUAU_AOT_LAYOUT_MANIFEST"), "utf8"),
);

const module = await WebAssembly.compile(wasmBytes);
const imports = WebAssembly.Module.imports(module);
const importNames = imports.map(({ module, name, kind }) => `${module}.${name}:${kind}`).sort();
const expectedImports = [
  "wasi_snapshot_preview1.args_get:function",
  "wasi_snapshot_preview1.args_sizes_get:function",
  "wasi_snapshot_preview1.proc_exit:function",
];
if (JSON.stringify(importNames) !== JSON.stringify(expectedImports)) {
  throw new Error(`layout probe import surface drifted: ${JSON.stringify(imports)}`);
}

// The exported layout calls never enter `_start`; these exact stubs merely satisfy
// Zig's wasm32-wasi reactor link. Any additional import fails above.
const instance = await WebAssembly.instantiate(module, {
  wasi_snapshot_preview1: {
    args_get: () => 0,
    args_sizes_get: () => 0,
    proc_exit: () => {
      throw new Error("layout probe unexpectedly entered WASI _start");
    },
  },
});
const probe = instance.exports;
if (probe.lc_layout_schema_version() !== 1) throw new Error("unexpected layout probe ABI");

const names = fieldNames(fieldText);
if (probe.lc_layout_value_count() !== names.length) {
  throw new Error(`probe has ${probe.lc_layout_value_count()} values but schema has ${names.length}`);
}

const actualFields = names.map((name, index) => {
  const raw = probe.lc_layout_value(index);
  if (raw === 0xffff_ffff_ffff_ffffn) throw new Error(`probe rejected field ${name}`);
  const value = Number(raw);
  if (!Number.isSafeInteger(value)) throw new Error(`layout value is not a safe integer: ${name}`);
  return { name, value };
});

const canonicalFields = `${JSON.stringify(actualFields)}\n`;
const canonicalHash = createHash("sha256").update(canonicalFields).digest("hex");
const actual = {
  schema_version: 1,
  generator_version: "luau-aot-layout-probe-v1",
  luau_pin: {
    version: "0.725",
    archive_sha256: "e51ead5f541633693d548057e0431927f3036c13b185fdb37fbc3f5a261e6676",
    patch_count: 5,
  },
  target: "wasm32-wasi",
  toolchain: {
    zig_version: "0.16.0",
    mode: "release_small",
    threaded: "single",
    cxx_flags: ["-fno-exceptions", "-fno-rtti"],
  },
  probe_wasm_sha256: createHash("sha256").update(wasmBytes).digest("hex"),
  field_schema_sha256: createHash("sha256").update(fieldText).digest("hex"),
  imports: expectedImports,
  field_count: actualFields.length,
  fields_sha256: canonicalHash,
  fields: actualFields,
};

if (process.argv.includes("--emit")) {
  process.stdout.write(`${JSON.stringify(actual, null, 2)}\n`);
} else if (JSON.stringify(actual) !== JSON.stringify(expected)) {
  throw new Error(
    `checked Luau layout manifest drifted\nexpected=${JSON.stringify(expected)}\nactual=${JSON.stringify(actual)}`,
  );
}

console.log(`verified ${actualFields.length} wasm32 Luau layout facts (${canonicalHash})`);
