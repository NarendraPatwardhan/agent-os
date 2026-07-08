import path from "node:path";
import { fileURLToPath } from "node:url";

import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
// Named `unplugin` const (has .vite/.rollup/…) — a named import needs no CJS default
// interop, so it types cleanly under NodeNext + verbatimModuleSyntax (a default import
// of this package resolves to the module namespace, which isn't callable).
import { unplugin as stylex } from "@stylexjs/unplugin";

const dirname = path.dirname(fileURLToPath(import.meta.url));
// The design system (instrument) is vendored in-tree here. StyleX has to compile the
// app + these tokens together, so both Vite's resolver and StyleX's own babel resolver
// must agree on one physical path.
const designDir = path.resolve(dirname, "src/instrument");

export default defineConfig({
  plugins: [
    // StyleX enforces `enforce: "pre"` itself, so it always transforms before react().
    stylex.vite({
      // StyleX's babel resolver does NOT read Vite's resolve.alias — mirror the same
      // physical path into its own resolver so `instrument/*` token imports resolve.
      aliases: {
        "instrument/*": [`${designDir}/*`],
        instrument: [path.join(designDir, "index.js")],
      },
      // rootDir = common ancestor of everything compiled together (app + tokens); a stable
      // rootDir keeps cross-file token hashing (className ↔ CSS custom property) consistent.
      unstable_moduleResolution: { type: "commonJS", rootDir: dirname },
      // Dev-server race guard: a virtual CSS collect can precede the defineConsts token
      // transforms; recover instead of throwing "Invalid empty selector". Builds are complete.
      lightningcssOptions: { errorRecovery: true },
    }),
    react(),
  ],
  resolve: {
    // Bazel's node_modules is a symlink farm into the pnpm store; realpathing the HTML
    // entry throws Vite's root off. Kept true — @mc/elements' transitive deps link flat here.
    preserveSymlinks: true,
    alias: [
      { find: /^instrument$/, replacement: path.join(designDir, "index.js") },
      { find: /^instrument\//, replacement: `${designDir}/` },
    ],
  },
  server: {
    port: 5173,
  },
  preview: {
    port: 4173,
  },
});
