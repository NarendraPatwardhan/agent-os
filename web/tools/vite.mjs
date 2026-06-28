// Bazel entrypoint for Vite. The package itself is a declared rules_js data
// dependency; this wrapper keeps generated node_modules files out of target
// names while preserving Vite's normal CLI argv handling.
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

const require = createRequire(import.meta.url);
const vitePackageJson = require.resolve("vite/package.json");
await import(pathToFileURL(join(dirname(vitePackageJson), "bin/vite.js")).href);
