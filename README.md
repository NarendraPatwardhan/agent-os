# agent-os

A self-contained Unix that lives inside one WebAssembly module, on a zero-staleness
Bazel build graph — [memcontainers](../memcontainers)' design, shipped **Rust-first**
by porting the proven kernel, and migrated to **Zig** later on a branch gated by
Rust↔Zig behavior parity.

The full design contract is **[VISION.md](./VISION.md)** — read it first. This README
is the quickstart and a map of the scaffold.

## Quickstart

```sh
bazel test //...        # builds every artifact and runs every suite, always fresh (B1)
bazel build //tools/smoke:smoke_wasm   # the wasm spine: Zig -> wasm32-freestanding
```

There is no `xtask`, no "did you rebuild?", no manual staging. If a test needs a
kernel, it `data`-depends on the kernel target, so the artifact is never stale.

## Status: bootstrapped skeleton (Phase A, step 1)

This is the **structure**, stood up per VISION §8, not the port. What exists:

- The Bazel module and the validated **wasm32-freestanding** toolchain spine
  (`MODULE.bazel`, `.bazelrc`, `platforms/`, `tools/smoke/` — a real Zig→wasm build
  that proves the toolchain).
- The four boundary **contracts** as the single source of truth (`contracts/*.kdl`),
  populated from the frozen `mc` ABI (52 syscalls at ABI 1.3, the `env` bridge, the
  `mc_ctl_*` control channel, the wire protocol).
- A **package home for every Phase-A component**, each `BUILD.bazel` documenting
  what it will hold, its language, its target world, and the VISION section that
  governs it.

What does **not** exist yet (the next steps, VISION §11 Phase A):

- Step 2 — porting memcontainers' Rust into `kernel/rust`, `sysroot`, `shcore`,
  `programs`, `wasi-adapter`, `hosts/wasmtime`, `server`, `conformance`, `tests/e2e`.
- Step 3 — the `contracts` projector that emits Rust/Zig/TS from the `.kdl` files.
- Step 4 — the C/C++ guest lane (sqlite, luau) via `http_archive` + Zig glue.

## Layout (see VISION §8 for the rationale)

| Path | What | Lang | Target world |
|---|---|---|---|
| `contracts/` | the four boundaries — single source of truth | KDL → Rust/Zig/TS | — |
| `kernel/rust` · `kernel/zig` | the OS, two interchangeable impls (B7) | Rust → Zig | wasm32-freestanding |
| `interpreter/` | wasmi as a wasm32 C-ABI staticlib (Phase B, kernel/zig only) | Rust | wasm32 |
| `sysroot` · `shcore` · `programs` | guest userland (`/bin`, the shell) | Rust (ported) | wasm32-freestanding |
| `third_party/{luau,sqlite}` | C/C++ guests — patches + Zig glue only (B3) | C/C++ + Zig | wasm32 |
| `hosts/wasmtime` · `hosts/js` | the two host families, one binary (A3) | Rust · TS | host · — |
| `server/` · `sdk-js/` · `web/` | mc-server, the `@mc/*` SDK, the browser app | Rust · TS | host · — |
| `conformance/` · `tests/{e2e,parity}` | no-mocks suites + the two-kernel parity grid | Rust | host |
| `platforms/` · `toolchains/` · `images/` · `spec/` | build plumbing, images, generated specs | Starlark | — |

## Naming

`agent-os` names the repo and the build only. The system is `mc`: the `mc` syscall
module, `mc_sys_*`, `mc_ctl_*`, the `env` bridge, `mc-server`, the `@mc/*` npm scope.
Never `agent-os-*` (VISION §8.2).
