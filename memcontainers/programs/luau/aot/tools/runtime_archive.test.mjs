import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { basename, join } from "node:path";

function runfile(relative, variable) {
  if (!relative) throw new Error(`${variable} is not set`);
  if (relative.startsWith("/")) return relative;
  const root = process.env.RUNFILES_DIR;
  if (!root) throw new Error("RUNFILES_DIR is not set");
  return join(root, relative);
}

function parseDecimal(bytes, label) {
  const text = bytes.toString("ascii").trim();
  if (!/^[0-9]+$/.test(text)) throw new Error(`invalid ar ${label}: ${JSON.stringify(text)}`);
  const value = Number(text);
  if (!Number.isSafeInteger(value)) throw new Error(`ar ${label} is not a safe integer`);
  return value;
}

function gnuName(table, offset) {
  if (!table) throw new Error(`GNU ar name /${offset} has no string table`);
  if (offset >= table.length) throw new Error(`GNU ar name offset ${offset} is out of range`);
  let end = offset;
  while (end < table.length && table[end] !== 0x0a && table[end] !== 0x00) end++;
  let name = table.subarray(offset, end).toString("utf8");
  if (name.endsWith("/")) name = name.slice(0, -1);
  if (!name) throw new Error(`GNU ar name at offset ${offset} is empty`);
  return name;
}

function parseArchive(bytes) {
  const magic = "!<arch>\n";
  if (bytes.subarray(0, magic.length).toString("ascii") !== magic)
    throw new Error("runtime artifact is not a Unix ar archive");

  const members = [];
  let stringTable;
  let offset = magic.length;
  while (offset < bytes.length) {
    if (offset + 60 > bytes.length) throw new Error(`truncated ar header at byte ${offset}`);
    const header = bytes.subarray(offset, offset + 60);
    if (header.subarray(58, 60).toString("ascii") !== "`\n")
      throw new Error(`invalid ar header trailer at byte ${offset}`);

    const rawName = header.subarray(0, 16).toString("ascii").trim();
    const storedSize = parseDecimal(header.subarray(48, 58), "member size");
    const storedStart = offset + 60;
    const storedEnd = storedStart + storedSize;
    if (storedEnd > bytes.length) throw new Error(`truncated ar member ${JSON.stringify(rawName)}`);

    let name = rawName;
    let dataStart = storedStart;
    if (rawName.startsWith("#1/")) {
      const nameLength = parseDecimal(Buffer.from(rawName.slice(3)), "BSD name length");
      if (nameLength > storedSize) throw new Error("BSD ar name is larger than its member");
      name = bytes.subarray(storedStart, storedStart + nameLength).toString("utf8").replace(/\0+$/, "");
      dataStart += nameLength;
    } else if (rawName === "//") {
      stringTable = bytes.subarray(storedStart, storedEnd);
    } else if (/^\/[0-9]+$/.test(rawName)) {
      name = gnuName(stringTable, Number(rawName.slice(1)));
    } else if (name.endsWith("/") && name !== "/" && name !== "/SYM64/") {
      name = name.slice(0, -1);
    }

    const special = rawName === "/" || rawName === "//" || rawName === "/SYM64/" ||
      name === "__.SYMDEF" || name === "__.SYMDEF SORTED";
    if (!special) {
      if (!name) throw new Error(`empty ar member name at byte ${offset}`);
      members.push({ name, data: bytes.subarray(dataStart, storedEnd) });
    }

    offset = storedEnd + (storedSize & 1);
  }
  if (offset !== bytes.length) throw new Error("invalid final ar padding");
  return members;
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalize(value[key])]));
  }
  return value;
}

const archive = readFileSync(runfile(process.env.LUAU_AOT_RUNTIME_ARCHIVE, "LUAU_AOT_RUNTIME_ARCHIVE"));
const manifest = JSON.parse(readFileSync(
  runfile(process.env.LUAU_AOT_RUNTIME_SOURCE_MANIFEST, "LUAU_AOT_RUNTIME_SOURCE_MANIFEST"),
  "utf8",
));
const objectManifest = JSON.parse(readFileSync(
  runfile(process.env.LUAU_AOT_RUNTIME_OBJECT_MANIFEST, "LUAU_AOT_RUNTIME_OBJECT_MANIFEST"),
  "utf8",
));

if (manifest.status !== "archive_built_unlinked")
  throw new Error(`runtime source manifest has non-archive status ${JSON.stringify(manifest.status)}`);
if (manifest.project_adapter?.source !== "src/call_frame.cpp")
  throw new Error("runtime source manifest must name project_adapter.source as src/call_frame.cpp");
if (!Array.isArray(manifest.retained_runtime_sources) || manifest.retained_runtime_sources.length !== 34)
  throw new Error("runtime source manifest must contain the exact 34 retained upstream sources");
const { canonical_hash: sourceManifestHash, ...sourceManifestBody } = manifest;
const actualSourceManifestHash = createHash("sha256")
  .update(`${JSON.stringify(canonicalize(sourceManifestBody))}\n`)
  .digest("hex");
if (actualSourceManifestHash !== sourceManifestHash)
  throw new Error(`runtime source manifest canonical hash drifted: ${actualSourceManifestHash}`);

const upstreamObjects = manifest.retained_runtime_sources.map((source) => {
  if (!/^VM\/src\/[^/]+\.cpp$/.test(source))
    throw new Error(`invalid retained runtime source ${JSON.stringify(source)}`);
  return `${basename(source, ".cpp")}.o`;
});
const expected = [...upstreamObjects, "call_frame.o", "libluau_aot_runtime_raw_zcu.o"].sort();
if (new Set(expected).size !== expected.length) throw new Error("expected runtime object basenames collide");

const objectMembers = parseArchive(archive).filter(({ name }) => basename(name).endsWith(".o"));
const actual = objectMembers.map(({ name }) => basename(name));
if (new Set(actual).size !== actual.length)
  throw new Error(`duplicate runtime object basename: ${JSON.stringify(actual.sort())}`);
if (JSON.stringify([...actual].sort()) !== JSON.stringify(expected))
  throw new Error(`runtime archive membership drifted\nexpected=${JSON.stringify(expected)}\nactual=${JSON.stringify([...actual].sort())}`);

const forbiddenVm = new Set(["lvmexecute.o", "lvmload.o"]);
const forbiddenFrontendStems = new Set([
  "Allocator", "Ast", "Confusables", "Cst", "Lexer", "Location", "Parser", "PrettyPrinter",
  "BytecodeBuilder", "BytecodeGraph", "BytecodeWire", "StringUtils", "TimeTrace",
  "BuiltinFolding", "Builtins", "Compiler", "ConstantFolding", "CostModel", "TableShape", "Types",
  "ValueTracking", "lcode", "AssemblyBuilderA64", "AssemblyBuilderX64", "BytecodeAnalysis",
  "BytecodeSummary", "CodeAllocator", "CodeBlockUnwind", "CodeGen", "CodeGenA64",
  "CodeGenAssembly", "CodeGenContext", "CodeGenUtils", "CodeGenX64", "EmitBuiltinsX64",
  "EmitCommonX64", "EmitInstructionX64", "IrAnalysis", "IrBuilder", "IrCallWrapperX64", "IrDump",
  "IrLoweringA64", "IrLoweringX64", "IrRegAllocA64", "IrRegAllocX64", "IrTranslateBuiltins",
  "IrTranslation", "IrUtils", "IrValueLocationTracking", "NativeProtoExecData", "NativeState",
  "OptimizeConstProp", "OptimizeDeadStore", "OptimizeFinalX64", "SharedCodeAllocator",
  "UnwindBuilderDwarf2", "UnwindBuilderWin", "lcodegen",
]);
for (const { name, data } of objectMembers) {
  const object = basename(name);
  if (forbiddenVm.has(object)) throw new Error(`forbidden VM object in runtime archive: ${object}`);
  if (forbiddenFrontendStems.has(basename(object, ".o")))
    throw new Error(`forbidden frontend-family object in runtime archive: ${object}`);
  if (data.length < 8 || !data.subarray(0, 8).equals(Buffer.from([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0])))
    throw new Error(`runtime archive member is not a wasm v1 object: ${object}`);
}

const actualDigests = objectMembers.map(({ name, data }) => ({
  name: basename(name),
  sha256: createHash("sha256").update(data).digest("hex"),
})).sort((a, b) => a.name.localeCompare(b.name));
const expectedDigests = objectManifest.members.map(({ name, sha256 }) => ({ name, sha256 }))
  .sort((a, b) => a.name.localeCompare(b.name));
if (JSON.stringify(actualDigests) !== JSON.stringify(expectedDigests))
  throw new Error(`runtime object digest drift\nexpected=${JSON.stringify(expectedDigests)}\nactual=${JSON.stringify(actualDigests)}`);

const canonicalDigest = createHash("sha256")
  .update(actualDigests.map(({ name, sha256 }) => `${name} ${sha256}\n`).join(""))
  .digest("hex");
if (canonicalDigest !== objectManifest.archive?.canonical_member_set_sha256)
  throw new Error(`canonical runtime member-set digest drifted: ${canonicalDigest}`);
if (objectManifest.archive?.member_count !== actual.length)
  throw new Error("runtime object manifest member count drifted");

console.log(`verified strict wasm runtime archive (${actual.length} objects, ${canonicalDigest})`);
