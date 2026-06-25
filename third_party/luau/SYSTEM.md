# loom — the Luau domain tools on agent-os

`loom` is the agent-os build of **Luau** as two pure-`mc` WebAssembly guests:

- **`/bin/luau`** — the interpreter / REPL / script runner (Luau VM + Compiler + Ast + Bytecode +
  Common) with the 19 `.luau` batteries embedded.
- **`/bin/luau-analyze`** — the `--check` type checker (the full ~80 kLOC Analysis engine + Config).

Both are CLI **domain tools** (SYSTEMS.md): one `.wasm` each, run from the command line, shipped in
the `loom` flavor pack — never in `base`/`minimal`/`posix`. They are NOT resident library services
(no `mc_service`); that mode — using a domain tool *as a library* — is for sqlite/typst, and the
flavors built on loom (see "CLI now, services later").

Upstream Luau 0.725 (C++) is compiled `zig c++ -target wasm32-wasi`, its wasi imports rewritten to
`mc` by the wasi-adapter, then stamped + attested. The result imports **only `mc`** (0 non-mc
imports) and runs on the kernel's `wasmi` like any other guest.

---

## Provenance: memcontainers' `loom`, and how agent-os diverges

agent-os's loom is a port of **memcontainers' `loom/`** capability (`/mnt/workspace/memcontainers/`):
a *vendored* Luau 0.725, ~13 C++ glue files in `loom/src/`, 19 `.luau` batteries, 4 skills, built by a
raw `xtask` (`build-luau` / `build-luau-analyze`) that linked the adapter, stamped sections, and
spot-checked imports by hand. memcontainers proved the *shape* (Luau-as-a-wasm-guest over an mc
syscall surface). agent-os re-expresses it the agent-os way, and the divergences are the point:

1. **Patches, not vendoring (B3).** memcontainers committed a patched copy of the Luau source.
   agent-os fetches pristine upstream 0.725 via `http_archive` and applies **four in-tree patches**
   (see "Patches"); only the deltas live in the tree. An upstream bump is a URL + sha256 change.

2. **C++ glue → Zig.** memcontainers' `loom/src/` was C++. agent-os rewrote 10 of the modules to Zig
   and kept only the 3 genuinely C++-bound holdouts. Cryptic names (`mc_eh`, `*_compat`,
   `*_bindings`) became what-it-does names. The Zig glue `@cImport`s Luau's Lua **C** API and calls
   `mc_sys_*` directly. (Map below.)

3. **xtask → a Bazel graph.** The raw build became a build graph: `rules_zig` (`zig c++`), the
   `mc_program` Starlark rule (stamp as a build action, attest as a *validation action*, an
   `McProgramInfo` provider), and the contract projection. The graph *is* the build — hermetic,
   incremental, with typed rules instead of shell in an xtask.

4. **Observed conformance → ENFORCED conformance** — the largest improvement. memcontainers verified
   import purity by inspection. agent-os fails the *build* on any drift:
   - **`//tools/mc-attest`** — attestation (every import is a *declared `mc` syscall*, not just the
     `mc` module) **and** tier fit (a syscall's cap-floor ⊆ the declared tier's caps). A
     `read-only` luau that imports `spawn`/`net` does not build.
   - **`//tools/mc-abi-gate`** — pins the hand-written `extern "mc" fn` decls in `mc.zig` to the
     projected contract (`contracts/gen/mc.gen.zig`); a parameter/return drift fails the build.
   - **Section robustness** — `//tools/mc-stamp` is idempotent (never emits a duplicate
     `mc_tier`/`mc_budget`); the **kernel** rejects a duplicate-or-malformed section at load, closing
     a tier-escalation (a corrupt `mc_tier` once silently inherited the parent's privilege).
   - **Trap-unwind export pair** — the kernel rejects a guest that exports exactly one of
     `__mc_pcall_run` / `__stack_pointer` (a half-armed unwind would corrupt the shadow stack).

5. **Resource discipline.** Across every native binding, an OOM or a resource limit is a **catchable
   Lua error**, never a trap, a silent wrong answer, or unbounded growth: the deflate output cap
   (size hint or a 192 MiB ceiling — a decompression bomb can't OOM the guest), the regex match/
   replace OOM, the bounded JSON-number scanner (replacing `strtod`-over-a-slice). The analyzer's
   `-fno-exceptions` aborts are categorized (out-of-memory / time / recursion / normalization / ICE)
   so a rare non-data failure is diagnosable.

6. **One fd namespace.** Guest-explicit file IO goes through a single `mc_sys_*` reader (`fs.zig`);
   wasi-libc is used only for what the C++ Luau core itself does (its own stdio on fd 0/1/2, argv).
   memcontainers' adapter had a second fd table that guest file reads also flowed through.

7. **The contract is the source of truth.** The mc ABI is projected from `contracts/` (KDL →
   `mc.gen.{rs,zig,ts}`); `mc.zig` is gated against it rather than hand-kept in sync by eye.

---

## Architecture

**Build pipeline** (per binary):

```
@luau (upstream 0.725 + 4 patches)  ─┐
third_party/luau/glue/*.zig          ├─ zig c++ → wasm32-wasi  ── //wasi-adapter (link) ──┐
3 C++ holdouts                       ─┘                                                    │
                                                                                          ▼
                                                  mc_program: mc-stamp (mc_tier+mc_budget) → /bin/luau.wasm
                                                              + mc-attest (validation, gates the build)
```

**Runtime layers** (top to bottom):

- **patched Luau C++** — the VM / Compiler / Ast / Analysis. Type errors are *data*
  (`CheckResult.errors`); only ICE/limit conditions ever leave the normal path.
- **Zig glue** — `sys.*`, the batteries loader + the native bindings, the entry. Owns the guest
  surface; calls `mc_sys_*`.
- **wasi-adapter** (`//wasi-adapter`, link-injected) — defines `wasi_snapshot_preview1`'s functions
  over `mc_sys_*`, so the C++ core's libc imports (print, args, stdio) resolve to `mc`. The guest
  ends up importing only `mc`.
- **kernel** (`kernel/rust/src/wasm/mod.rs`) — the load gate (`mc_tier`/`mc_budget` parse +
  validation, the trap-export-pair check) and the trap-unwind that re-enters the guest via
  `__mc_pcall_run`.

---

## Glue: the file map

memcontainers `loom/src/` → `third_party/luau/glue/`. 10 Zig + 3 C++ + `fs.zig` (new):

| role | file | lang |
|---|---|---|
| trap-unwind primitives (`mc_protected_call`/`__mc_pcall_run`, shadow stack) | `trap.zig` / `trap.h` | Zig (+ .h) |
| the mc syscall extern shim (mirrors `contracts/gen/mc.gen.zig`) | `mc.zig` | Zig |
| `sys.*` (fs/io/proc/net/host/time/rand) over `mc_sys_*` | `sys.zig` | Zig |
| the ONE `mc_sys_*` whole-file reader/writer | `fs.zig` | Zig |
| `require` (cache → embedded → VFS) + the embedded batteries | `stdlib.zig` | Zig |
| native bindings — JSON / SHA·CRC / base64·hex / DEFLATE / Pike-VM regex | `json` `hash` `encoding` `deflate` `re`.zig | Zig |
| interpreter entry / REPL / stdin | `entry.zig` | Zig |
| wasi-libc `close()` shim (one stray import) | `wasi_shim.zig` | Zig |
| C++ template error channel over the trap | `error_channel.h` | C++ |
| force-included try/catch + thread shim for Analysis | `analysis_eh_shim.h` | C++ |
| analyzer entry (Luau's virtual `FileResolver`, drives `Frontend`) | `analyze_main.cpp` | C++ |

The 19 batteries live in `glue/lib/*.luau`, `@embedFile`'d by `stdlib.zig` — a **frozen-module** model:
the standard library ships *inside* the interpreter, so `require("time")` works with zero image
staging. `require` resolution is cache → embedded → VFS `package.path`, so a flavor can still layer
extra `.luau` modules into the image filesystem (see below).

---

## The constraint that shapes everything: `-fno-exceptions`

zig's wasm32-wasi libc++ ships no C++ exception runtime, and the kernel's `wasmi` rejects the wasm-EH
proposal. So Luau's `throw`/`catch` sites are rerouted through a **kernel trap-unwind** instead of
C++ EH. This is what the patches do.

**Patches** (`patches/`, applied by the `http_archive`, each tagged `// mc PATCH`):

- **0001 — VM/Parser/Compiler.** Protected calls (`ldo.cpp`) run through the trap-unwind shim;
  `Ast`/`Compiler` `throw`/`catch` become typed error channels (`error_channel.h`) over the trap.
- **0002 — Analysis throws.** The Analysis engine's internal/limit/ICE `throw`s become
  `mc_analysis_abort(<categorized message>)` — a graceful `exit(70)`. Ordinary type errors are
  unaffected (they're data); the **result is never silently wrong** (a throw aborts, never
  mis-continues).
- **0003 — named catches.** The few `catch (X& e)` bodies that the `-fno-exceptions` shim macros
  leave dead are patched to not reference `e`.
- **0004 — Frontend nothread.** The `Frontend`'s `std::mutex`/locks → no-op `mc_nothread` stand-ins
  (the parallel-build path is never taken; luau-analyze checks one file synchronously). The `.h`
  declaration and the `.cpp` uses live together here; 0002 stays purely the throw rewrites.

`analysis_eh_shim.h` is force-included into every Analysis TU: it `#define`s `try`/`catch` to elide
the handlers and supplies the `mc_nothread` types. The one real recovery it elides is
TypeFunctionRuntime's compile-error catch (a type-function *body* hitting a hard compiler limit →
abort instead of a `FailedToCompile` diagnostic), documented and deferred — recovering it would need
Luau's Compiler error path converted to explicit returns, and the path is essentially
input-unreachable.

---

## CLI now, services later

loom ships CLI tools. The flavors that build on it add *programmability*: e.g. a future **`atlas`** =
loom + a sqlite **service** (`mc_service`, called as a library by Lua programs) + data tools, plus an
`atlas`-only Lua library and skill. The binary stays universal (one luau, frozen batteries); the
flavor-specific content — Lua libraries (VFS `.luau` under `package.path`), skills (`.md`), and the
service binaries — is layered per-flavor via `pkg_tar` (SYSTEMS.md section 11), so it is present in `atlas` and absent
in `loom`. (loom's `require` already resolves cache → embedded → VFS, so a layered `/lib/luau/*.luau`
is require-able without rebuilding the interpreter.)

---

## Tests

`//tests/e2e:suite` boots the real kernel and runs the actual memcontainers/web recipes against
`/bin/luau` + `/bin/luau-analyze` over the control exec channel — the batteries demo (require-driven
json/hash/time + string extensions under the fuel budget), a real `.xlsx` generation (deflate +
encoding + the xlsx battery), the Pike-VM regex battery, `sys.fs` round-trips, the typed_ok/typed_bad
type checks, plus adversarial cases: the deflate bomb cap, the JSON number grammar, nested-pcall /
error-in-error trap-unwind stress, and graceful degradation on a pathological-depth type. The tool
gates (`mc-attest`, `mc-abi-gate`, `mc-stamp`) and the kernel/contract tests round out
`bazel test //...`.
