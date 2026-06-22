# Porting `loom` (Luau) to agent-os

Reference plan for bringing memcontainers' `loom/` capability (a vendored Luau 0.725 build with C++
glue, 19 `.luau` batteries, 4 skills) into agent-os the agent-os way. Source of truth:
`/mnt/workspace/memcontainers/loom/` + `loom/PATCHES.md` + `crates/e2e/tests/luau{,_libs}.rs`.

## What we're building

Two guest wasm binaries from **upstream Luau 0.725** (C++):

- **`luau`** — interpreter / REPL / script-runner (VM + Compiler + Ast + Bytecode + Common) +
  the 19 `.luau` batteries embedded.
- **`luau-analyze`** — the `--check` type checker (+ the ~80 kLOC Analysis engine + Config), no
  batteries.

Both are **one-binary domain tools** (VISION §16.5): built once → one `.wasm`, service-capability
stamped as an `mc_service` custom section + an `/etc/mc-services.json` fragment carried by the
`loom` flavor pack — never in `base`/`minimal`/`posix`.

## Decisions (locked)

1. **Build target = `wasm32-wasi` + the wasi-adapter.** `zig c++ -target wasm32-wasi` gives
   wasi-libc + wasi-libc++, which Luau's C++ runtime needs (`strtod`/`snprintf`/`qsort`/math for
   `lua_Number`↔string, `operator new`→`malloc`). The pure-compute libc makes no imports; the
   wasi-adapter rewrites only the *syscall* imports to `mc`. This is what memcontainers proved.
   (The `BUILD.luau.bazel` sketch's `wasm32_freestanding` is wrong — no libc — and is corrected
   here.)
2. **Both binaries together** — `luau` and `luau-analyze` land in one pass (the full `loom` flavor).
3. **Three C++ holdouts; everything else → Zig** (see the glue table). The holdouts are genuinely
   C++-bound (a template, `#define try/catch`, Luau's C++ virtual interfaces).

## The constraint that shapes everything

The guest is `-fno-exceptions -fno-rtti`, FORCED: zig's wasm32-wasi libc++ ships no C++ exception
runtime (`__cxa_throw` undefined at link), and the kernel's wasmi rejects the wasm-EH proposal. So
Luau's handful of `throw`/`catch` sites are rerouted through a **kernel trap-unwind**. Those edits
become the http_archive patch set (memcontainers tags each with `// mc PATCH`, so they're greppable):

- VM `ldo.cpp` — protected calls run through the trap-unwind shim (`trap.zig` here).
- `Ast/src/Parser.cpp`, `Compiler/src/Compiler.cpp` — `throw`/`catch` → typed error channels
  (`error_channel.h`) over the trap.
- `Analysis/*` — a force-included shim (`analysis_eh_shim.h`) neutralizes try/catch + stubs
  threading; the few real `throw`s → `mc_analysis_abort` (graceful exit). Luau type errors are
  DATA (`CheckResult.errors`), not thrown, so ordinary checking is intact; only ICE/resource-limit
  paths degrade.

## Glue: rename + Zig/C++ split

memcontainers' `loom/src/` → agent-os `third_party/luau/glue/`. Cryptic `mc_eh`/`*_compat`/
`*_bindings` names dropped for what-it-does names.

| memcontainers | role | agent-os | new name |
|---|---|---|---|
| `mc_runtime.{h,cpp}` | trap-unwind primitives (`mc_protected_call`/`mc_raise`/`__mc_pcall_run`, shadow-stack) | **Zig** (+ `.h` for C++) | `trap.zig` / `trap.h` |
| `sys_bindings.cpp` | `sys.*` lib over `mc_sys_*` + Lua C API | **Zig** | `sys.zig` |
| `mc_stdlib.{h,cpp}` | `require` loader + battery installer (`@embedFile` the `.luau`) | **Zig** | `stdlib.zig` |
| `json_bindings.cpp` | JSON codec + Lua C API | **Zig** | `json.zig` |
| `hash_bindings.cpp` | SHA256/SHA1/MD5/CRC32 | **Zig** | `hash.zig` |
| `re_bindings.cpp` | Pike-VM regex (linear-time) | **Zig** | `re.zig` |
| `encoding_bindings.cpp` | base64/hex | **Zig** | `encoding.zig` |
| `deflate_bindings.cpp` | DEFLATE (puff, no zlib) | **Zig** | `deflate.zig` |
| `luau_cli.cpp` | interpreter entry / REPL | **Zig** | `entry.zig` |
| `luau_compat.cpp` | wasi-libc `close()` override (one stray import) | **Zig** | `wasi_libc_shim.zig` |
| `mc_eh.h` | C++ **template** error channel over the trap | **C++** | `error_channel.h` |
| `mc_analysis_compat.h` | force-included try/catch + thread shim for Analysis | **C++** | `analysis_eh_shim.h` |
| `luau_analyze.cpp` | analyzer entry (`Frontend`/`FileResolver`) | **C++** | `analyze_main.cpp` |

The Zig glue `@cImport`s Luau's Lua **C** API (`lua.h`/`lualib.h`/`luacode.h`, all C) from `@luau`,
and calls `mc_sys_*` (a thin `extern` shim over `contracts/gen/mc.gen.zig`). The 3 C++ holdouts:
`error_channel.h` is a C++ template included into patched Luau; `analysis_eh_shim.h` is preprocessor;
`analyze_main.cpp` implements Luau's C++ virtual `FileResolver` and drives `Frontend` — none
expressible in Zig.

## Build order

**Phase 1 — Source: fetch + patch + toolchain.**
- Extract the `// mc PATCH` edits (diff memcontainers' `loom/vendor/luau/` against upstream 0.725)
  → `third_party/luau/patches/` (`0001-mc-vm.patch` for VM/Parser/Compiler; `0002-mc-analysis.patch`
  for Analysis). Only patches in-tree (B3) — never the source.
- `MODULE.bazel`: the `http_archive(name="luau", urls=[github 0.725 tarball], sha256, strip_prefix,
  patches, patch_tool="patch", patch_args=["-p1"], build_file="//third_party/luau:BUILD.luau.bazel")`.
- Register a `wasm32-wasi` zig toolchain in `platforms/` (only freestanding is registered today).

**Phase 2 — Glue → Zig** in `third_party/luau/glue/` (10 Zig + 3 C++, per the table). The Zig glue
imports the mc syscall extern shim + `@cImport`s the Lua C API.

**Phase 3 — Assets.** 19 `.luau` → `third_party/luau/lib/*.luau`, embedded via `@embedFile` in
`stdlib.zig` (removes the `mc_lib_embed.h` codegen). 4 skills → `skills/*.md`.

**Phase 4 — Build** `BUILD.luau.bazel` (`zig_binary` / `zig_configure_binary`, target wasm32-wasi):
- `luau` = Luau VM/Compiler/Ast/Bytecode/Common (cppsrcs from `@luau`) + the C++ holdouts + the Zig
  glue → link the `//wasi-adapter` staticlib + wasi-emulated libs → stamp `mc_tier`/`mc_budget`/
  `mc_service` → verify **mc-only** imports (`//tools/wasm-imports` + `//tools/mc-attest`).
- `luau-analyze` = + Config/Analysis + `analyze_main.cpp` + `-include analysis_eh_shim.h`, no
  batteries, budget per memcontainers (256 MiB / 400B fuel).
- Likely a new `mc_program()` macro (a zig c++ binary + adapter staticlib link + post-link section
  stamp + import verify), analogous to `mc_box()` but not the Rust trampoline path.

**Phase 5 — Flavor** `images/BUILD.bazel`: `loom = posix + luau_pack + luau_analyze_pack` (+ the
`/etc/mc-services.json` fragment), per VISION §16.1 layering. (Future: `paper`, `atlas` stack on
`loom`.)

**Phase 6 — e2e.** Port `luau.rs` + `luau_libs.rs` into a `loom` group in the suite — boot loom,
stage `/bin/luau`, run `.luau` scripts, assert. Gate the OOXML gold-standard tests (openpyxl /
python-docx) behind an env flag, as memcontainers does.

## Unknowns to resolve during build (bounded, not blockers)

- **The `mc_program` build rule** — rules_zig knobs to link the adapter `.o`/`.a` into a zig c++
  binary, post-link section-stamping, and the import verifier. memcontainers did this in raw
  `xtask`; agent-os does it via `rules_zig`.
- **mc syscalls into Zig glue** — `mc.gen.zig` is *descriptor data*; the glue needs callable
  `extern` decls for `mc_sys_*`. Add a thin generated/hand `extern` shim (or reuse the env bridge).
- **The wasi-adapter staticlib as a link input** to a zig c++ binary (vs the Rust rlib→`.o` path
  `mc_box` uses).

## References

- memcontainers: `loom/` (lib/, skills/, src/, PATCHES.md), `xtask/src/main.rs` (`build-luau`,
  `build-luau-analyze`), `crates/e2e/tests/luau{,_libs}.rs`.
- agent-os patterns: the sed vendor-and-patch (`MODULE.bazel` `uutils_sed`, `third_party/sed/`);
  `wasi-adapter/defs.bzl` (`mc_box`); `contracts/codegen/` (KDL → `.gen.zig`); `platforms/`
  (the zig toolchains); VISION.md §16.1/§16.5 (flavors + domain tools).
