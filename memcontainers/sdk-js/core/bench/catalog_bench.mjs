// Tool-plane benchmark: measures cold vs warm `mc.create` with a connection catalog (compile + inject),
// hermetically (a bytes spec — no network). Run against the built artifacts:
//
//   MC_KERNEL_WASM=bazel-bin/memcontainers/kernel/rust/kernel.wasm \
//   MC_BASE_IMAGE=bazel-bin/memcontainers/images/base.tar \
//   MC_CATALOG_COMPILER_WASM=bazel-bin/memcontainers/lib/catalog-compiler/catalog-compiler.wasm \
//   MC_GITHUB_FIXTURE=memcontainers/lib/catalog-compiler/data/github_issues.openapi.json \
//   node memcontainers/sdk-js/core/bench/catalog_bench.mjs [iterations]
//
// "cold" = first create (the spec is parsed + compiled + the catalog injected); "warm" = subsequent
// creates (the compiled source is content-addressed + cached, so only inject runs).
//
// Baseline (github issues fixture, embedded JS host): cold ~120 ms (compile + inject), warm ~18 ms p50.
import { readFileSync } from "node:fs";

// Resolve @mc/core in-package by default; MC_CORE_ENTRY points it at built artifacts for a local run.
const { mc } = await import(process.env.MC_CORE_ENTRY ?? "@mc/core");

const iterations = Number(process.argv[2] ?? 12);
const kernel = new Uint8Array(readFileSync(process.env.MC_KERNEL_WASM));
const image = new Uint8Array(readFileSync(process.env.MC_BASE_IMAGE));
const fixture = readFileSync(process.env.MC_GITHUB_FIXTURE);

const createOnce = async () => {
  const t0 = performance.now();
  const vm = await mc.create({
    kernel,
    image,
    deterministic: true,
    net: true,
    permissions: { network: "allow" },
    connections: [
      {
        ref: "github.org.main",
        auth: { kind: "bearer", token: "bench" },
        origins: ["https://api.github.com"],
        spec: { bytes: new Uint8Array(fixture), format: "openapi" },
      },
    ],
    tools: ["github/issues"],
  });
  const elapsed = performance.now() - t0;
  await vm.close();
  return elapsed;
};

const samples = [];
for (let i = 0; i < iterations; i++) samples.push(await createOnce());

const cold = samples[0];
const warm = samples.slice(1).sort((a, b) => a - b);
const p = (xs, q) => xs[Math.min(xs.length - 1, Math.floor(xs.length * q))];
const mean = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length;

console.log(`tool-plane create benchmark (${iterations} iterations, github issues fixture)`);
console.log(`  cold (compile + inject):  ${cold.toFixed(1)} ms`);
console.log(
  `  warm (cached compile):    p50 ${p(warm, 0.5).toFixed(1)} ms, mean ${mean(warm).toFixed(1)} ms, min ${warm[0].toFixed(1)} ms`,
);
