# contracts — the four boundaries

This directory is the **single source of truth** for every boundary in agent-os
(VISION §6). None of the kernels, hosts, shims, or clients *is* the truth — the
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
shared with memcontainers (VISION §8.2).

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
   has a handler — drift is a compile error, in both languages (§6.3).
3. Conformance fails until a guest exercises the new syscall (or it carries a
   documented exclusion).

## Status

The `.kdl` files are complete and authoritative. The **projector** is a documented
seed (`codegen/src/projector.rs`); standing it up is Phase A step 3 (VISION §11) —
port the table logic from memcontainers `crates/abi`, then uncomment the
`abi_library()` calls in `BUILD.bazel`. Capability annotations per syscall (§15.4)
are the planned next pass.
