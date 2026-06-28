// Bazel entrypoint for TypeScript checks. tsc itself does not produce a stable
// success artifact, so this wrapper writes the declared stamp only after tsc
// exits cleanly.
import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, isAbsolute, join } from "node:path";

const args = process.argv.slice(2);
const stampFlag = args.indexOf("--stamp-out");
const separator = args.indexOf("--");

if (stampFlag < 0 || separator < 0 || stampFlag + 1 >= args.length || separator <= stampFlag) {
  console.error("usage: tsc-check --stamp-out <path> -- <tsc args...>");
  process.exit(2);
}

const stampArg = args[stampFlag + 1];
const execroot = process.env.JS_BINARY__EXECROOT ?? process.cwd();
const stampOut = isAbsolute(stampArg) ? stampArg : join(execroot, stampArg);
const tscArgs = args.slice(separator + 1);
const require = createRequire(import.meta.url);
const typescriptPackageJson = require.resolve("typescript/package.json");
const tsc = join(dirname(typescriptPackageJson), "bin/tsc");
const result = spawnSync(process.execPath, [tsc, ...tscArgs], { stdio: "inherit" });

if (result.error) {
  console.error(result.error.message);
  process.exit(1);
}

if (result.status !== 0) {
  process.exit(result.status ?? 1);
}

mkdirSync(dirname(stampOut), { recursive: true });
writeFileSync(stampOut, "ok\n");
