# agent-os

A self-contained Unix that lives inside one WebAssembly module, on a zero-staleness
Bazel build graph — [memcontainers](../memcontainers)' design, shipped **Rust-first**
by porting the proven kernel, and migrated to **Zig** later on a branch gated by
Rust↔Zig behavior parity.

The full design contract is **[SYSTEMS.md](./SYSTEMS.md)** — read it first. This README
is the quickstart and a map of the scaffold.

## Quickstart

```sh
bazel test //...        # builds every artifact and runs every suite, always fresh (B1)
bazel build //tools/smoke/zig:wasm    # the wasm spine: Zig -> wasm32-freestanding
```

There is no `xtask`, no "did you rebuild?", no manual staging. If a test needs a
kernel, it `data`-depends on the kernel target, so the artifact is never stale.

## Status: bootstrapped skeleton (Phase A, step 1)

This is the **structure** plus the **contract projector** (Phase A steps 1 and 3),
not yet the port. What exists:

- The Bazel module and the validated **wasm32-freestanding** toolchain spine
  (`MODULE.bazel`, `.bazelrc`, `platforms/`, `tools/smoke/` — a real Zig→wasm build
  that proves the toolchain).
- The four boundary **contracts** as the single source of truth (`contracts/*.kdl`),
  populated from the frozen `mc` ABI (52 syscalls at ABI 1.3, the `env` bridge, the
  `mc_ctl_*` control channel, the wire protocol).
- The **projector** (`contracts/codegen`, Step 3): a dependency-light Rust tool that
  reads the `.kdl` and emits Rust, Zig, TS, Markdown, and AsyncAPI. Every boundary is
  generated into `contracts/gen/` and consumable as `//contracts:mc_rust`,
  `:env_zig`, etc. The Rust/Zig projections are compile-validated by `build_test`; all
  are drift-gated by `diff_test` (B2). Add or change a syscall by editing one `.kdl`
  line and running `bazel run //contracts:mc_sync`.
- A **package home for every Phase-A component**, each `BUILD.bazel` documenting
  what it will hold, its language, its target world, and SYSTEMS.md section that
  governs it.

What does **not** exist yet (the next steps, SYSTEMS.md Phase A):

- Step 2 — porting memcontainers' Rust into `kernel/rust`, `sysroot`, `shcore`,
  `programs`, `wasi-adapter`, `hosts/wasmtime`, `server`, `conformance`, `tests/e2e`,
  consuming the generated `//contracts:*_rust` bindings.
- Step 4 — the C/C++ guest lane (sqlite, luau) via `http_archive` + Zig glue.

## Layout (see SYSTEMS.md for the rationale)

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
Never `agent-os-*` (SYSTEMS.md).
