# contracts — the four boundaries

This directory is the **single source of truth** for every boundary in agent-os
(SYSTEMS.md). None of the kernels, hosts, shims, or clients *is* the truth — the
contract is — so they cannot drift.

| File | Boundary | Direction | Module |
|---|---|---|---|
| `syscalls.kdl` | syscall | guest → kernel | `mc` |
| `bridge.kdl` | bridge | kernel → host | `env` |
| `control.kdl` | control | host → kernel | `mc_ctl_*` |
| `wire.kdl` | wire | server ↔ client | — |
| `constants.kdl` | shared | — | errno, tiers, flags, ABI version |

Values are transcribed from the frozen `mc` ABI in memcontainers `crates/abi` and
`crates/wire`. **Do not renumber** — the `mc` surface is a compatibility contract
shared with memcontainers (SYSTEMS.md).

## How a contract becomes code

```
contracts/syscalls.kdl ──(//contracts/codegen:projector)──> mc.gen.rs   (kernel + sysroot)
                                                           ├─> mc.gen.zig  (Zig kernel + C/C++ shims)
                                                           ├─> mc.gen.ts   (TS client)
                                                           └─> mc.gen.md   (docs)
```

`abi_library` (`codegen/defs.bzl`) runs the projector once per language and wires a
`write_source_files` drift gate. A stale checked-in projection is a failed
`diff_test` (B2) — in every language at once.

## Adding or changing a syscall

1. Edit **one line** in `syscalls.kdl` (or bump `abi-version` minor in
   `constants.kdl` for an additive change).
2. `bazel test //...` regenerates every projection. The Rust kernel's exhaustive
   `match` and the Zig kernel's exhaustive `switch` both fail to compile until each
   has a handler — drift is a compile error, in both languages.
3. Conformance fails until a guest exercises the new syscall (or it carries a
   documented exclusion).

## Status — projector live (Phase A step 3 done)

The `.kdl` files are complete and authoritative, and the **projector**
(`codegen/src/projector.rs`) is implemented: a dependency-light KDL reader plus
emitters for Rust, Zig, TS, Markdown, and AsyncAPI. The `abi_library()` calls in
`BUILD.bazel` are live — every boundary is generated into `gen/`, the Rust and Zig
projections are compile-validated by `build_test`, and all are drift-gated by
`diff_test`. Consume them as `//contracts:mc_rust`, `:env_zig`, `:wire_ts`, …

The generated Rust is a `macro_rules!` callback table (memcontainers'
`mc_syscall_table!` pattern, generalized to all four boundaries); the kernel, host,
and sysroot supply their own `$emit` in Step 2, so no ABI is ever hand-written (B2).
TS is generated but compile-validated only when the JS lane lands; capability
annotations per syscall are the planned next pass.
