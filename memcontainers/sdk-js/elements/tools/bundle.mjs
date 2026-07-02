// Bundle @mc/elements into a code-split ESM dist/ with rolldown (the repo's bundler —
// Vite 8's engine). Every npm dependency (lit, @lit/context, xterm, codemirror,
// @mc/core → @mc/host/@mc/contracts/zod) is inlined, so a consumer depends only on
// @mc/elements instead of re-declaring the whole transitive closure.
//
// Two things are deliberately NOT inlined:
//   - Node builtins (node:fs, node:path, …) reached through @mc/core's server-only
//     paths stay external. They are never executed on the browser VM boot path; a
//     consuming bundler stubs them for the browser exactly as before.
//   - The dynamic import in <mc-editor> stays its own chunk (rolldown splits on it),
//     so CodeMirror only downloads on pages that actually mount an editor.
//
// Invoked by //memcontainers/sdk-js/elements:bundle as `node bundle.mjs <input> <outDir>`,
// mirroring how //web runs vite through tools/vite.mjs.

import { rolldown } from "rolldown";

const [input = "src/index.js", outDir = "dist"] = process.argv.slice(2);

const NODE_BUILTINS =
  /^(assert|buffer|child_process|crypto|events|fs|fs\/promises|http|https|module|net|os|path|process|stream|tls|url|util|zlib)$/;
const isExternal = (id) => id.startsWith("node:") || NODE_BUILTINS.test(id);

const bundle = await rolldown({
  input,
  platform: "browser",
  external: isExternal,
});

await bundle.write({
  dir: outDir,
  format: "es",
  entryFileNames: "index.js",
  chunkFileNames: "[name]-[hash].js",
  // Keep the byte-for-byte design-token CSS out of JS; it ships separately as
  // @mc/elements/styles.css.
});

await bundle.close();
