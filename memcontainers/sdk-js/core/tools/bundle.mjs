// Bundle @mc/core into a SINGLE self-contained ESM with rolldown (the repo's bundler — Vite's
// engine, the same one //memcontainers/sdk-js/elements uses). Every npm dependency
// (@mc/host → @mc/contracts, zod) is inlined, so a consumer imports ONE file — no npm install,
// no node_modules. This is the release "js bundle".
//
// Node builtins (node:fs, node:path, …) reached through @mc/core's server-only artifact loaders
// stay EXTERNAL: a Bun/Node consumer provides them natively; a browser consumer never executes
// those paths on the VM boot flow (or its own bundler stubs them, exactly as with @mc/elements).
//
// Invoked by //memcontainers/sdk-js/core:bundle as `node bundle.mjs <input> <outFile>`.

import { rolldown } from "rolldown";

const [input = "src/index.js", outFile = "mc-core.mjs"] = process.argv.slice(2);

const NODE_BUILTINS =
  /^(assert|buffer|child_process|crypto|events|fs|fs\/promises|http|https|module|net|os|path|process|stream|tls|url|util|zlib)$/;
const isExternal = (id) => id.startsWith("node:") || NODE_BUILTINS.test(id);

const bundle = await rolldown({
  input,
  platform: "neutral",
  external: isExternal,
});

await bundle.write({
  file: outFile,
  format: "es",
  inlineDynamicImports: true, // one self-contained file, no code-split chunks
});

await bundle.close();
