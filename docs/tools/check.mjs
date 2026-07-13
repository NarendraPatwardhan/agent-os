import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const docs = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repo = resolve(docs, "..");
const markdownFiles = readdirSync(docs).filter((name) => name.endsWith(".md")).sort();
const failures = [];

function fail(message) {
  failures.push(message);
}

function slugify(value) {
  return value
    .toLowerCase()
    .replace(/`([^`]+)`/g, "$1")
    .replace(/[<>]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

function withoutImports(source) {
  const kept = [];
  let inImport = false;
  for (const line of source.split(/\r?\n/)) {
    if (!inImport && /^\s*import\b/.test(line)) {
      inImport = !line.includes(";");
      continue;
    }
    if (inImport) {
      if (line.includes(";")) inImport = false;
      continue;
    }
    kept.push(line);
  }
  return kept.join("\n");
}

const documents = new Map();
for (const name of markdownFiles) {
  const text = readFileSync(join(docs, name), "utf8");
  const anchors = new Set(
    text
      .split(/\r?\n/)
      .filter((line) => /^#{1,6}\s+/.test(line))
      .map((line) => slugify(line.replace(/^#{1,6}\s+/, ""))),
  );
  documents.set(name, { text, anchors });
  if (!/^#\s+\S/m.test(text)) fail(`${name}: missing level-one title`);

  const fence = /```js\s*\n([\s\S]*?)```/g;
  for (let match = fence.exec(text); match; match = fence.exec(text)) {
    const body = withoutImports(match[1]);
    try {
      // Reference snippets are intentionally contextual, so compile rather than
      // execute them. Wrapping permits top-level await while rejecting TS syntax.
      Function(`return async function __agentos_doc_snippet__() {\n${body}\n}`);
    } catch (error) {
      try {
        // A shape example may intentionally be a bare object expression, which
        // is ambiguous with a labelled block when placed in a function body.
        Function(`return (${body}\n)`);
      } catch {
        const line = text.slice(0, match.index).split(/\r?\n/).length;
        fail(`${name}:${line}: invalid JavaScript fence: ${error.message}`);
      }
    }
  }
}

for (const [name, { text }] of documents) {
  const link = /\[[^\]]+\]\(([^)]+)\)/g;
  for (let match = link.exec(text); match; match = link.exec(text)) {
    const target = match[1];
    if (/^(https?:|mailto:)/.test(target)) continue;
    const [rawPath, rawAnchor] = target.split("#", 2);
    const targetName = rawPath ? normalize(join(dirname(name), rawPath)) : name;
    const targetDoc = documents.get(targetName);
    if (!targetDoc) {
      fail(`${name}: broken local link ${target}`);
      continue;
    }
    if (rawAnchor && !targetDoc.anchors.has(rawAnchor)) {
      fail(`${name}: missing anchor #${rawAnchor} in ${targetName}`);
    }
  }
}

function exportedNames(path, directFunctions = false) {
  const source = readFileSync(path, "utf8");
  const names = new Set();
  if (directFunctions) {
    for (const match of source.matchAll(/^export\s+(?:async\s+)?(?:function|class|const)\s+([A-Za-z_$][\w$]*)/gm)) {
      names.add(match[1]);
    }
    return names;
  }
  for (const match of source.matchAll(/^export\s+\{([\s\S]*?)\}\s+from\s+/gm)) {
    for (const part of match[1].split(",")) {
      const clean = part.replace(/\/\/.*$/gm, "").trim();
      if (!clean || clean.startsWith("type ")) continue;
      names.add(clean.split(/\s+as\s+/).at(-1).trim());
    }
  }
  return names;
}

const actual = {
  "@mc/core": exportedNames(join(repo, "memcontainers/sdk-js/core/src/index.ts")),
  "@mc/core/drivers": exportedNames(join(repo, "memcontainers/sdk-js/core/src/drivers.ts"), true),
  "@mc/elements": exportedNames(join(repo, "memcontainers/sdk-js/elements/src/index.ts")),
};
const manifest = JSON.parse(readFileSync(join(docs, "api-surface.json"), "utf8"));

function namedBody(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start + startMarker.length);
  if (start < 0 || end < 0) throw new Error(`could not locate ${startMarker}`);
  return source.slice(start + startMarker.length, end);
}

function declaredMethods(body) {
  const methods = new Set();
  for (const match of body.matchAll(/^  (?:async )?([a-zA-Z_$][\w$]*)\s*\(/gm)) {
    if (match[1] !== "constructor") methods.add(match[1]);
  }
  for (const match of body.matchAll(/^  ([a-zA-Z_$][\w$]*),\s*$/gm)) methods.add(match[1]);
  return methods;
}

const memcontainerSource = readFileSync(join(repo, "memcontainers/sdk-js/core/src/memcontainer.ts"), "utf8");
const typeSource = readFileSync(join(repo, "memcontainers/sdk-js/core/src/types.ts"), "utf8");
const llbSource = readFileSync(join(repo, "memcontainers/sdk-js/core/src/llb.ts"), "utf8");
const actualSurfaces = {
  mc: declaredMethods(namedBody(memcontainerSource, "export const mc = {", "\n};")),
  Vm: declaredMethods(namedBody(memcontainerSource, "export class Vm {", "\n}\n\n/** Resolve")),
  "vm.fs": declaredMethods(namedBody(typeSource, "export interface VmFs {", "\n}")),
  llb: declaredMethods(namedBody(llbSource, "export const llb = {", "\n};")),
};

for (const [surface, definition] of Object.entries(manifest.surfaces)) {
  try {
    if (!statSync(join(repo, definition.source)).isFile()) fail(`${surface}: missing source ${definition.source}`);
  } catch {
    fail(`${surface}: missing source ${definition.source}`);
  }
  const classified = new Set(definition.members);
  const actualMembers = actualSurfaces[surface] ?? new Set();
  for (const member of actualMembers) {
    if (!classified.has(member)) fail(`${surface}: public member ${member} is not classified in api-surface.json`);
  }
  for (const member of classified) {
    if (!actualMembers.has(member)) fail(`${surface}: stale member ${member} in api-surface.json`);
  }
  const document = documents.get(definition.doc);
  if (!document) {
    fail(`${surface}: missing document ${definition.doc}`);
    continue;
  }
  for (const member of classified) {
    if (!document.text.includes(`\`${member}`) && !document.text.includes(`\`${surface}.${member}`)) {
      fail(`${surface}.${member}: not named in ${definition.doc}`);
    }
  }
}

for (const [pkg, exports] of Object.entries(manifest.packages)) {
  const classified = new Set(exports.map((entry) => entry.name));
  for (const name of actual[pkg] ?? []) {
    if (!classified.has(name)) fail(`${pkg}: exported value ${name} is not classified in api-surface.json`);
  }
  for (const entry of exports) {
    if (!(actual[pkg] ?? new Set()).has(entry.name)) fail(`${pkg}: stale manifest entry ${entry.name}`);
    const target = join(docs, entry.doc);
    if (!statSync(target).isFile()) fail(`${pkg}.${entry.name}: missing document ${entry.doc}`);
  }
}

if (failures.length) {
  console.error(failures.map((failure) => `- ${failure}`).join("\n"));
  process.exit(1);
}

console.log(`DOCS OK — ${markdownFiles.length} pages; links, JS fences, and exported values verified.`);
