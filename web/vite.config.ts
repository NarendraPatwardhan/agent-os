import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  resolve: {
    // Bazel's node_modules are a symlink farm into the pnpm store; realpathing the
    // HTML entry throws Vite's root off. Kept true — so @mc/elements' transitive deps
    // must be declared in this package's package.json (they link flat here).
    preserveSymlinks: true,
  },
  server: {
    port: 5173,
  },
  preview: {
    port: 4173,
  },
});
