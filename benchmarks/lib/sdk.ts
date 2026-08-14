// A repository-local bridge keeps benchmarks out of the publishable pnpm workspace while still
// exercising the public @mc/core surface. The browser server exposes this compiled module and the
// core package's compiled dependency graph at their Bazel runfile paths.
export * from "../../memcontainers/sdk-js/core/src/index.js";
