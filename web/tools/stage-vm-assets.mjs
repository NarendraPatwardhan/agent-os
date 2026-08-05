// Stage the browser VM artifacts and emit the content binding consumed by the app.
// The manifest is intentionally generated in the same action as the copies: a URL
// and its digest cannot describe different Bazel inputs.

import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join } from "node:path";

const args = process.argv.slice(2);
const execroot = process.env.JS_BINARY__EXECROOT ?? process.cwd();

function resolvePath(path) {
  return isAbsolute(path) ? path : join(execroot, path);
}

function usage(message) {
  if (message) console.error(message);
  console.error(
    "usage: stage-vm-assets --manifest <out> " +
      "(--artifact <name> <url> <src> <out> | --image <name> <url> <src> <out>)...",
  );
  process.exit(2);
}

let manifestPath;
const artifacts = {};
const images = {};

for (let index = 0; index < args.length;) {
  const flag = args[index++];
  if (flag === "--manifest") {
    manifestPath = args[index++];
    if (!manifestPath) usage("--manifest requires an output path");
    continue;
  }

  if (flag !== "--artifact" && flag !== "--image") usage(`unknown argument: ${flag}`);
  const name = args[index++];
  const url = args[index++];
  const sourceArg = args[index++];
  const outputArg = args[index++];
  if (!name || !url || !sourceArg || !outputArg) usage(`${flag} requires four values`);

  const source = resolvePath(sourceArg);
  const output = resolvePath(outputArg);
  const bytes = readFileSync(source);
  mkdirSync(dirname(output), { recursive: true });
  copyFileSync(source, output);

  const record = {
    url,
    sha256: createHash("sha256").update(bytes).digest("hex"),
  };
  const target = flag === "--image" ? images : artifacts;
  if (Object.hasOwn(target, name)) usage(`duplicate ${flag.slice(2)} name: ${name}`);
  target[name] = record;
}

if (!manifestPath) usage("missing --manifest");
const output = resolvePath(manifestPath);
mkdirSync(dirname(output), { recursive: true });
writeFileSync(output, `${JSON.stringify({ schema: 1, artifacts, images }, null, 2)}\n`);
