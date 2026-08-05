# Luau strict AOT compilation for AgentOS

**Status:** governing architecture, implementation contract, recovery plan, and agent runbook

**Date:** 2026-08-04

**Implementation target:** `feature/luau-aot-compiler` in `agent-os-luau-aot`, created from `develop` at `2be511a`

**Audit-only worktree:** `agent-os-luau-compiler`; preserve until replacement acceptance, then delete

**Supersedes:** the former `LUAU_COMPILATION.md` and `LUAU_COMPILER_DESIGN.md`

**Pinned language implementation:** AgentOS's patched Luau 0.725 target

This is the single source of truth for the Luau compiler project. It deliberately combines product
intent, system architecture, ABI design, Wasm mapping, implementation sequence, verification gates,
recovery guidance, and agent operating instructions. If code, tests, checklists, or prior notes conflict
with this document, this document wins until it is amended with concrete evidence.

---

## 0. The decision in one page

AgentOS will keep `/bin/luau` as the ordinary source and bytecode interpreter for development. It will
also expose an optional host-side compiler capability, `luau-compiler.wasm`, which accepts a closed,
versioned Luau package and emits one standalone AgentOS executable Wasm module.

The compiler pipeline is:

```text
closed source package
  -> validate package and recompute all digests
  -> upstream Luau parser/compiler
  -> upstream Luau bytecode, held only inside the compiler
  -> temporary Proto graph, never executed by the compiler
  -> upstream Luau CodeGen IR
  -> complete AgentOS IR-to-Wasm lowering
  -> relocatable generated-code object
  -> real Luau AOT runtime object/archive + AgentOS glue + WASI adapter
  -> symbol-and-relocation-aware link
  -> one pure-mc executable Wasm module
  -> validate, stamp, attest, install
```

The output is **strict AOT**:

- every reachable Luau function has executable Wasm code;
- ordinary Luau operations happen when the output guest runs, not while the compiler runs;
- the output contains the real Luau value, stack, call, closure, table, string, error, and GC runtime;
- the output contains no Luau bytecode execution loop, bytecode fallback, source compiler, or runtime
  code generator;
- a guard may enter a named AOT slow-path helper, but may not return to a bytecode program counter;
- a Luau closure call dispatches to another compiled Wasm function, never to `luau_execute`;
- the final module imports only the permitted `mc.*` surface and passes the normal AgentOS artifact
  validation, `mc-stamp`, and `mc-attest` gates.

The compiler itself is an optional, zero-import host capability. It does not run as a normal guest and
does not enter the kernel's guest import registry. The produced program does run as an ordinary guest.

The implementation is not complete when constants, loops, tables, strings, JSON, or system calls can
be precomputed. It is complete only when one compiled artifact can be run repeatedly against different
argv, filesystem, and other runtime inputs and exhibit the same observable behavior as `/bin/luau`.

### 0.1 The current feature branch is not the product architecture

The 2026-08-04 audit found that most of the current branch implements a bounded abstract interpreter
inside `codegen_bridge.cpp`. It evaluates user closures, loops, strings, tables, patterns, buffers,
errors, and random operations during compilation, records a result or print plan, and emits a small
purpose-built Wasm guest. Other paths recognize fixed system/JSON recipes or lower a small scalar IR
subset. The emitted `runtime.pack` is a sidecar containing unrelated standalone Wasm fragments; the
kernel executes `artifact.wasm` and never links or loads those fragments into it.

Those paths can make implementation-authored tests green without implementing Luau AOT. They are not
an incremental route to the target and must not remain on the product path.

The salvageable parts are the zero-import compiler shell and close-link proof, host wrappers, framing
scaffolding, upstream CodeGen IR exposure, basic Wasm inspection utilities, and kernel E2E harness
mechanics. The abstract evaluator, recipe planner, fixed-output emitters, fake pack compositor, and
coverage claims based on constant fixtures must be removed or isolated as non-product experiments.
Salvage is performed by deliberately porting reviewed pieces into a fresh worktree from `develop`, not
by continuing implementation on the audited branch.

### 0.2 Active clean-worktree implementation state (2026-08-05)

The replacement implementation lives on `feature/luau-aot-compiler` in the separate
`agent-os-luau-aot` worktree. The audited `agent-os-luau-compiler` worktree remains untouched. The
following foundations are real and checked. The bounded numeric oracle is runnable through the full
guest path, but is not presented as a general-purpose AOT product:

- the exact 0.725 IR enum ledger and wasm32 layout probe fail on pin drift;
- the strict target-runtime source boundary builds a 36-member wasm32 archive with Compiler, Ast,
  Bytecode, CodeGen, `lvmload.cpp`, and `lvmexecute.cpp` excluded;
- the archive and its complete relocation corpus link through the hermetic Emscripten
  `@@emsdk++emscripten_deps+emscripten_bin_linux//:bin/wasm-ld` oracle;
- `FrontendSnapshotV1` is a canonical 21-section, little-endian byte protocol. It carries the pin,
  patchset, frontend contract, IR-enum, and target-layout identities; the closed Proto graph;
  bytecode and immutable Proto metadata; VM constants; source/debug data; optimized upstream IR;
  and the original compiler bytecode as non-executable evidence;
- the pin adapter invokes the target-neutral prefix of upstream `lowerFunction` in its required
  order: `killUnusedBlocks`, `computeCfgInfo`, `constPropInBlockChains`, `createLinearBlocks`,
  `computeCfgBlockEdges`, and `updateUseCounts`. It snapshots before dead-store marking because DSE
  creates lowering-side restore/exit tables that the Zig normalizer must either own or represent
  explicitly. There are no fixture-dependent optimizer switches;
- the host frontend Wasm has zero imports. A real smoke compiles root plus nested function, closes
  the temporary VM, validates every serialized reference in Zig, observes actual `CALL`, `ADD_NUM`,
  and `RETURN` IR, and proves byte-identical output across two fresh states;
- a checked semantic-corpus digest binds the schema, adapter, Zig validator, build recipe, private
  source exposure, and five applied patches to the frontend identity carried in every snapshot;
- syntax errors return an owned structured diagnostic. Loader compound constants that have not yet
  been decoded into `VM_CONSTANT_ITEMS`, including import paths and table/class shapes, fail closed with
  `MC_LUAU_SNAPSHOT_V1_UNSUPPORTED_FRONTEND_VALUE`; they are not silently flattened or evaluated.
- the Zig backend now emits a standard linking-v2 relocatable Wasm object with canonical types,
  imports, functions, code, symbols, padded call sites, and `reloc.CODE` entries. Hermetic Emscripten
  `wasm-ld` accepts it both alone and with the configured 36-object runtime archive;
- the strict runtime now owns the versioned `(lua_State*, AotProto*) -> status` ABI, immutable
  linker-owned Proto metadata, real closure materialization, GC-safe stack publication, generated
  entry dispatch, numeric result commit, teardown, and protected failure crossing. A linked generated
  object executes through ordinary `lua_call` against real `lua_State` instances, rejects a non-number
  through the protected Luau error boundary, and survives full-GC publication checks;
- the frontend and backend are separately instantiable zero-import Wasm capabilities. The backend
  parses and validates `FrontendSnapshotV1`, constructs typed compiler-owned views, allocates upstream
  SSA results to Wasm locals, preserves 16-byte `TValue` copies, and lowers supported bytecode/internal
  blocks through one generic block-ID dispatcher. It does not parse source or execute Luau code;
- the upstream-IR oracle compiles two unrelated source functions: a guarded scalar expression and a
  numeric `for` loop. The backend emits 411-byte and 606-byte relocatable objects, hermetic `wasm-ld`
  links them, and the linked functions execute inputs `1`, `4`, and `7` as `3/9/15` and `1/10/28`.
  Both reject a non-number `TValue`, and observed interrupt counts prove upstream safepoints were not
  erased. The command ledger marks the eleven complete rows and the three deliberately partial rows;
- the numeric-loop source is now a declared Bazel input to the actual zero-import frontend and backend.
  Their deterministic output object is the exact object linked into the 36-object strict runtime; no
  handwritten function body or copied test artifact intervenes. That artifact runs through ordinary
  `lua_call` on real states and matches a separately linked, exact-pinned Luau compiler/interpreter
  oracle for inputs `-3`, `0`, `1`, `4`, `7`, and `12`. The interpreter is test-only and is absent from
  every strict-runtime dependency;
- the same exact generated object now links with a production-shaped Zig entry, the strict runtime,
  and the canonical WASI-to-mc adapter. `mc_program` optimizes, stamps, and attests the final guest;
  `mc-attest` accepts its pure-mc import surface and declared `full` tier. A dedicated `loom_aot`
  image installs that artifact, and the real AgentOS kernel runs six fresh argv-driven processes whose
  stdout matches `/bin/luau` for all six inputs;
- `INTERRUPT` calls a versioned runtime helper instead of becoming a no-op. The helper preserves a
  null callback fast path, invokes an installed callback, reports yielded status, and requires
  generated code to reload `L->base` after a successful callback. Yield continuation/source-pc
  semantics remain explicitly open.

The next slice closes WP2's remaining semantic negative control: compile a real `return 30` root from
upstream IR and prove that the stamped artifact emits no stdout under the kernel. Root chunks currently
expose `FALLBACK_PREPVARARGS`; the backend must normalize the zero-fixed-parameter/no-vararg-use case,
not hide it in the entry wrapper. WP3's central upstream-IR/object/runtime/kernel-differential gate is
proven, while the work package remains open for arithmetic slow-block rejoin and the remaining
scalar/conversion command coverage.

---

## 1. Product aim

### 1.1 User-visible capability

A caller submits a closed Luau package to the host compiler. A successful response contains a final
pure-mc `.wasm` program and reproducible metadata. The host validates the result again, installs it at
an authorized path, and the normal AgentOS execution path launches it.

The promoted program must preserve the normal script-runner contract:

- `arg[0]` and `arg[1..]` have the same meaning as `/bin/luau`;
- top-level varargs match `/bin/luau`;
- stdout, stderr, exit status, VFS behavior, JSON behavior, and permitted `sys` calls match;
- errors and traceback behavior are compatible within the documented source-map limits;
- top-level returned values are discarded; `return 30` is silent and exits successfully;
- a program only prints if it calls `print` or another output-producing API;
- static package `require` resolution is deterministic and cannot escape the package;
- capabilities are declared and enforced by the host/kernel, not guessed from source text.

### 1.2 Why this exists

The interpreter is a good development tool but is not the desired promoted artifact. A promoted tool
should start as one closed executable, be stampable and attestable like other AgentOS programs, avoid
shipping the source compiler and interpreter, have deterministic provenance, and present no special
runtime installation protocol.

### 1.3 Non-goals for the first production release

- compiling arbitrary runtime source, `load`, or `loadstring`;
- dynamic package discovery or filesystem-backed `require` outside the submitted package;
- debug hooks that force a compiled frame back into bytecode;
- runtime JIT or executable-memory allocation;
- host CPU code generation or upstream x64/A64 machine-code reuse;
- WebAssembly threads, SIMD, exception handling, component model, GC proposal, memory64, or multiple
  memories;
- perfect performance parity with Luau's x64/A64 native CodeGen;
- speculative whole-program evaluation or partial evaluation;
- accepting programs whose reachable IR contains an unmapped operation.

The language subset may be staged, but the supported subset must execute with correct runtime
semantics. A narrow real compiler is progress. A broad compile-time evaluator is not.

---

## 2. Definitions and hard boundaries

### 2.1 Strict AOT

Strict AOT means that no reachable execution path in the output dispatches Luau bytecode. It does not
mean that every language operation is one Wasm instruction. Calls to compiled C++/Zig runtime helpers
are normal AOT implementation techniques.

Allowed:

- direct Wasm arithmetic, comparison, memory access, and structured control flow;
- runtime helper calls for metatables, table lookup, allocation, GC, errors, strings, calls, and
  library functions;
- a compiled-function table and `call_indirect`;
- statically serialized Proto-equivalent metadata, constants, debug names, and source locations;
- prebuilt C++/Zig runtime code compiled to Wasm;
- compile-time constant folding performed by upstream Luau optimizations when the fold is semantically
  valid and not observable.

Forbidden:

- `luau_execute`, `lvmexecute`, or an equivalent opcode-dispatch loop in the output;
- embedding bytecode and resuming it after a guard;
- a helper that takes a bytecode PC and interprets arbitrary opcodes;
- emitting a guest that merely prints or returns a compiler-computed result;
- running the submitted program, its module initializers, or its closures in the compiler;
- treating an external sidecar pack as linked merely because it was returned beside the artifact;
- defining different semantics for promoted programs to make a test pass.

### 2.2 Pure-mc program

A pure-mc program is a valid AgentOS guest module whose imports are exactly within the declared `mc`
tier/capability set, whose memory/function/table/resource limits fit the kernel, whose required exports
are present, and whose stamped/attested metadata agrees with the actual module.

### 2.3 Compiler host versus output guest

These are separate trust and ABI domains.

| Property | Compiler host | Output guest |
|---|---|---|
| Form | `luau-compiler.wasm` | package-specific `.wasm` |
| Imports | zero | declared `mc.*` imports only |
| Placement | optional host capability | normal AgentOS filesystem program |
| Contains parser/compiler | yes | no |
| Contains temporary bytecode/Proto loader | yes | no bytecode loader or bytecode |
| Contains target Luau runtime | only as inert link inputs | linked executable runtime |
| Executes user program | never | yes |
| Kernel guest registry | no | yes, through normal loader |

### 2.4 Runtime pack

In this document, **runtime pack** means a deterministic set of linkable Wasm objects/archives,
symbols, data segments, relocations, ABI metadata, and adapter inputs that become part of the final
artifact. It is a compiler input, normally embedded by digest in the compiler distribution.

A collection of standalone Wasm modules with separate memories and no applied relocations is not a
runtime pack. Returning such a collection as `runtime.pack` does not make it participate in execution.

---

## 3. Existing AgentOS baseline

Implementation agents must begin by verifying these facts against the live tree and pinned Luau
archive. Paths may move; semantics may not be assumed from this snapshot.

### 3.1 Current interpreted Luau path

`/bin/luau` is a real pure-mc guest built from patched Luau 0.725 and AgentOS glue. Its ordinary script
path is approximately:

```text
source bytes
  -> luau_compile
  -> bytecode bytes
  -> luau_load
  -> Closure/Proto graph
  -> lua_pcall
  -> Luau VM bytecode execution
```

The glue opens the Luau standard libraries, installs AgentOS libraries, constructs `arg`, supports
traceback handling, and uses the kernel-mediated trap channel for protected calls. This implementation
is the semantic oracle and the primary source of reusable runtime code.

The compiler does not replace `/bin/luau`. Promotion is an additional path.

### 3.2 Existing error mechanism

AgentOS Wasm does not rely on the Wasm exception proposal. Patched Luau uses `mc_sys_pcall`, the
re-entrant `__mc_pcall_run` export, `mc_sys_set_throw`, and a trap to unwind to the nearest protected
boundary. The AOT runtime must reuse this mechanism or prove a compatible replacement. It must support
ordinary Luau `pcall`/`xpcall` behavior and top-level traceback handling without including the bytecode
executor.

### 3.3 Existing build and artifact path

The live tree already contains the useful machinery that should be reused rather than duplicated:

- patched upstream Luau source and Bazel exposure;
- Zig/C++ wasm32-wasi compilation;
- the WASI-to-mc adapter path;
- the AgentOS guest loader and import registry;
- filesystem insertion/install mechanisms;
- `mc-stamp` and `mc-attest`;
- module limits and Wasmi feature configuration;
- optional host capability precedents;
- JS/Wasmtime host wrappers and E2E test patterns.

Every repository Bazel invocation must use:

```bash
bazel --output_user_root=/mnt/workspace/agent-os/bazel-cache ...
```

### 3.4 Conservative output feature profile

Until a narrower live-tree contract says otherwise, generated programs use:

- wasm32 linear memory;
- exactly one defined memory;
- one function table if indirect compiled calls are needed;
- MVP numeric types plus AgentOS-confirmed bulk-memory, sign-extension, saturating conversion, and
  mutable-global features;
- no imported memory;
- no threads/atomics, SIMD, Wasm EH, GC proposal, memory64, or multi-memory;
- normal `_start`, `memory`, and protected-call exports required by the loader/glue;
- only `mc.*` imports allowed by the selected tier.

The backend must have an explicit feature ledger. Accidentally emitting a Wasm instruction accepted by
one inspection runtime but disabled in Wasmi is a compiler error.

---

## 4. Forensic audit of `feature/luau-compiler`

### 4.1 Snapshot

At the 2026-08-04 audit:

- the worktree was `agent-os-luau-compiler` on `feature/luau-compiler`;
- the merge base with `develop` was `a6c558c`;
- the branch contained 36 commits produced in roughly one day;
- it added about 18,900 lines across 56 files;
- `codegen_bridge.cpp` alone was about 7,500 committed lines and had further uncommitted changes;
- four files had user-owned uncommitted edits: `codegen_bridge.cpp` and three test files.

Those uncommitted edits are not to be discarded by recovery work.

### 4.2 What the branch actually built

There are three unrelated artifact-producing strategies:

1. `ir_wasm_lower.cpp` hand-encodes a small scalar/control-flow Wasm module for one function. It uses
   fixed memory slots and only a tiny subset of Luau IR. Slow arithmetic exits instead of invoking the
   Luau runtime. Its `RETURN` path prints returned values, which contradicts Luau script semantics.
2. `vertical_plan.cpp` plus `vertical_lower.zig` recognizes fixed source/IR recipes such as argv,
   filesystem, and JSON cases, embeds constant paths/data, and emits purpose-built syscall guests.
3. `lc_ir_promote_plan` in `codegen_bridge.cpp` walks upstream IR while abstractly executing the user
   program. It models numbers, strings, booleans, arrays, maps, buffers, closures, multi-results,
   upvalues, patterns, errors, iteration, calls, and random state. It records compiler-known output and
   emits a small plan guest.

`wasm_lower.zig` selects among these strategies. They do not share one value ABI, runtime ABI, function
ABI, heap, GC, table implementation, closure model, or linking model.

### 4.3 Severity-one architectural failures

#### A. The compiler executes the program

The abstract interpreter recursively evaluates closures and bounded loops, mutates modeled tables and
buffers, implements string/pattern functions, simulates protected calls, and advances an invented random
generator. This is precisely what a compiler for a dynamic language must not do as its execution model.

Consequences:

- runtime argv/filesystem/state cannot generally affect the result;
- compiler budgets silently become language limits;
- time, random, errors, metamethods, aliasing, mutation, recursion, and side effects are wrong;
- a successful constant fixture says nothing about generated runtime code;
- every newly simulated library function grows a second, incomplete Luau implementation;
- the implementation effort scales toward writing an interpreter inside the compiler while still not
  producing a runtime.

This path must not be extended.

#### B. There is no Luau target runtime in the artifact

The main emitted guests do not use upstream `TValue`, `lua_State`, `CallInfo`, `Proto`, closure,
upvalue, table, string, allocator, or GC structures. There is no consistent dynamic value
representation across generated functions and runtime helpers. Multi-function compiled dispatch is not
implemented.

Without these pieces, the backend cannot implement ordinary nonconstant Luau programs regardless of
how many fixtures are recognized.

#### C. The runtime pack is not linked

`pack_compose.zig` packages `artifact.wasm` beside standalone `CORE`, `GC`, `TABLE`, `SYS_FS`, and
`JSON` fragment modules. These modules have their own module namespaces and memories. No symbols are
resolved, no function/type/table indices are remapped, no relocations are applied, and their code/data
does not become reachable from `artifact.wasm`.

The kernel executes `artifact.wasm`, not the returned sidecar. Tests that check fragment names or MCRP
bytes prove packaging only.

#### D. Tests encode invented semantics

The E2E suite expects a top-level `return 10 + 20` to print `30`. `/bin/luau` discards top-level return
values. Tests predominantly compile constant programs and verify artifact existence or the precomputed
output, exactly matching the abstract evaluator's strengths. The same artifact is not exercised with
multiple unknown runtime inputs.

Green status therefore validates the implementation's own substitute contract, not Luau promotion.

### 4.4 Severity-two design failures

#### A. Upstream IR is treated as portable and self-contained

Luau CodeGen IR is coupled to the VM. It addresses VM registers and constants, manipulates live
`TValue` fields, reads `lua_State`/`Proto`/closure state, calls a `NativeContext` helper table, and
contains fallback/VM-exit blocks. x64/A64 lowering assumes native entry gates and bytecode PCs.

A Wasm backend must deliberately map or replace these dependencies. Merely walking IR commands and
emitting arithmetic does not create a Luau backend.

#### B. There is no complete command ledger

The pinned `IrCmd` enum contains roughly 180 commands spanning loads/stores, scalar/vector arithmetic,
control flow, tables, strings, conversions, fast calls, semantic helpers, guards, GC barriers, closures,
calls, returns, iteration, bytecode fallbacks, and optimizer pseudo-operations. The branch has no
generated exhaustiveness manifest showing direct/helper/rewrite/reject handling for every command.

#### C. Source text is used as a security/language policy parser

`policyPermanentReject` scans comments, strings, and identifiers to reject selected names such as
`load`, environment functions, coroutine, metatable, and dynamic `require`. Language and reachability
policy must be enforced using upstream AST/bytecode/IR and package resolution, not a bespoke lexical
scanner. Capability policy must be enforced from the final Wasm imports and signed manifest.

#### D. The request protocol is not fully validated

The implementation skips or ignores important supplied digests/options and does not recompute all file
hashes before compiling. A compiler boundary must reject framing ambiguity, duplicate paths, path
escape, invalid UTF-8 where required, digest mismatch, unknown options, and incompatible ABI versions.

#### E. Denylist checks are cosmetic

Searching an output blob for the bytes `luau_execute` is not proof that interpreter code is absent.
Symbols may be stripped, renamed, compressed, or represented indirectly. Conversely, harmless metadata
could contain the name. The build must prove source/object exclusion and final function reachability,
and tests must exercise the no-fallback runtime contract.

### 4.5 Salvage/rebuild matrix

| Existing work | Decision | Conditions |
|---|---|---|
| zero-import compiler core and close-link recipe | salvage | reverify imports and deterministic build |
| sticky host compiler channel and wrappers | salvage | harden lengths/digests/errors; retain host/guest separation |
| Bazel exposure of upstream CodeGen IR sources | salvage | pin exact source set and add drift ledger |
| IR dump/walk bridge | salvage as spike | remove execution/evaluation; use only to serialize inspected IR |
| Wasm byte encoder utilities | salvage selectively | only after one canonical module builder/object model is chosen |
| kernel E2E harness mechanics | salvage | replace semantic fixtures and artifact assertions |
| compile request framing | rewrite/harden | canonical parsing, digest recomputation, option validation |
| `ir_wasm_lower.cpp` product path | rebuild | it can remain only as a discarded scalar experiment |
| `vertical_plan.cpp` / `vertical_lower.zig` | remove from product | recipe recognition is not lowering |
| abstract `Slot` evaluator and library simulations | remove from product | do not extend or rebrand as optimization |
| MCRP standalone fragment pack | replace | use real objects, symbols, relocations, and one final module |
| phase/coverage tracking based on constant fixtures | retire | replace with semantic, structural, and differential gates |
| tests expecting returned values on stdout | fix immediately | promoted behavior must match `/bin/luau` |

No bulk deletion or reset is implied by this document. Preserve the dirty tree, make an archival commit or
patch if authorized, then perform recovery in reviewable changes.

---

## 5. Reference systems and lessons

Reference projects are evidence and design stimuli, not dependencies to copy blindly. Pin commits in
the implementation notes whenever a lesson becomes a design input.

The architecture audit cloned and read these snapshots under a temporary directory:

| Project | Audited revision | Role |
|---|---|---|
| [Qcode/lua-wasm](https://github.com/Qcode/lua-wasm) | `bed0377c79d94811f6ab681041c79340fa5b1293` | dynamic value/stack/closure/table baseline |
| [serprex/luwa](https://github.com/serprex/luwa) | `8e4852e13e56b7ece875360e31bc01a128c762ed` | object heap, re-entrant state, and GC topology |
| [AngelOnFira/weblings](https://github.com/AngelOnFira/weblings) | `d0cd7a9f3af7d8249b3948ac0e19d2afc0d01633` | end-to-end compiler/object/link workflow |
| [AngelOnFira/rust `riw-wasm20`](https://github.com/AngelOnFira/rust/tree/riw-wasm20) | `cc6954e02cb99b83a66805a51717c6920915113a` | `clif2wasm` entity mapping and `riwl` narrow linker |

The temporary clones are not repository inputs. Agents should refresh or recreate them when exact
source evidence is needed and record any new revision used.

### 5.1 `Qcode/lua-wasm`

This educational Lua-to-Wasm compiler demonstrates the minimum structural work that a dynamic language
backend cannot avoid: a tagged value layout, VM stack/frame convention, runtime objects, closure/static
links, a function table and indirect calls, tables, allocator/collector, and multiple returns. Its Lua
subset and representation are not Luau-compatible, but its architecture makes a useful falsification
point: generated functions operate on runtime values instead of compiler-known results.

### 5.2 `serprex/luwa`

This WIP Lua/Wasm runtime makes object layout, allocator, re-entrant VM/coroutine state, function/table/
string representation, and compacting GC central. The lesson is not to import its code; the lesson is
that runtime topology dominates a dynamic-language Wasm implementation.

### 5.3 Weblings, `clif2wasm`, and `riwl`

The Weblings toolchain maps a real compiler IR to relocatable Wasm objects and then links those objects.
The relevant map includes types/signatures, functions, blocks/block parameters, direct and indirect
calls, one memory, stack pointer/shadow stack, table entries, data addresses, runtime libcalls, symbols,
archives, relocations, init functions, and entity-index remapping.

`riwl` is valuable because it defines a deliberately narrow supported object/linking universe, rejects
unsupported relocation models, and compares its output behavior with the established `wasm-ld` path.
AgentOS should follow that method: inventory the exact object corpus, use `wasm-ld` as the correctness
oracle, then implement only the required in-compiler linker subset.

### 5.4 Upstream Luau x64/A64 CodeGen

The upstream lowerers are the semantic guide for each IR command. They are not a reusable machine-code
backend for Wasm. They show:

- how generated code finds `L->base`, current closure, constants, and Proto metadata;
- which operations are direct machine instructions;
- which guards enter slow/fallback blocks;
- which operations call `NativeContext` helpers;
- how calls, returns, varargs, iteration, interrupts, GC checks, and barriers work;
- where bytecode-PC coupling must be removed for strict AOT.

For every Wasm lowering, agents must cite the corresponding x64/A64 lowering and runtime helper or
explain why Wasm requires a different semantic implementation.

---

## 6. Target architecture

```text
                                  HOST DOMAIN

  canonical request frame
          |
          v
  +-------------------------- luau-compiler.wasm --------------------------+
  | bounds/path/digest/ABI validation                                      |
  | package graph + static require resolver                                |
  | upstream parser/compiler -> temporary bytecode                         |
  | temporary lua_State + luau_load -> Proto graph (never called)          |
  | upstream BytecodeAnalysis + IrBuilder + optimizers                     |
  | exhaustive IrCmd classifier/lowerer                                    |
  | generated-code relocatable Wasm object                                 |
  | embedded runtime object pack + symbol/relocation-aware linker          |
  | Wasm validation + deterministic metadata                               |
  +------------------------------------------------------------------------+
          |
          v
  response: final artifact.wasm + meta + diagnostics
          |
  host revalidation -> stamp/attest -> authorized install

                                  GUEST DOMAIN

  +----------------------- one pure-mc Wasm module ------------------------+
  | _start / AgentOS glue                                                  |
  | real Luau state, values, tables, strings, closures, errors, GC         |
  | compiled Luau function table                                           |
  | generated function bodies                                              |
  | static constants/proto metadata/module registry/source map             |
  | linked libc/WASI adapter and permitted mc imports                       |
  | no parser, compiler, bytecode loader, bytecode VM, or runtime codegen   |
  +------------------------------------------------------------------------+
```

### 6.1 One backend, not parallel recipe engines

Every supported program goes through the same value ABI, function ABI, runtime, generated module
builder, object format, and linker. Optimization tiers may choose different code shapes, but they may
not switch to a semantic simulator or a purpose-built syscall template.

### 6.2 Closed world

The compiler receives every Luau module that the program may load. Static `require` edges resolve to a
canonical package module ID. Dynamic `require`, source loading, and environment mutation are rejected
when the upstream representation proves they are reachable. Unknown reachability is conservatively
rejected for the strict tier.

Native C/Zig libraries shipped in the AOT runtime are closed runtime dependencies, not Luau source
modules.

### 6.3 Compile-time and runtime separation

The compiler may:

- parse and type/bytecode compile source;
- load bytecode into a temporary state to materialize immutable Proto/constant metadata;
- run upstream compiler optimization passes;
- fold operations under upstream-proven language rules;
- serialize metadata and generated code;
- link and validate Wasm objects.

The compiler may not:

- call the root closure;
- invoke a submitted function;
- run a module initializer;
- read guest argv/VFS/time/random state as a proxy for runtime;
- simulate `print`, `sys`, JSON, mutation, errors, or library calls to determine output;
- impose a loop-trip/recursion budget by evaluating the program.

This boundary should be mechanically enforced: the compiler build exposes Proto construction and IR
translation APIs but does not link or expose an entry that executes a Proto.

### 6.4 Language ownership and dependency boundaries

Most **new AgentOS-owned compiler implementation** belongs in Zig. This is not a line-count rule over
the final binary: the target runtime deliberately reuses a substantial body of upstream Luau C++. It is
an ownership rule for the code this project designs and must maintain.

| Language | Owns | Must not own |
|---|---|---|
| Zig | compiler driver, request/package validation, static module graph, normalized IR model, CFG lowering, Wasm object builder, runtime-pack parser, production linker, final validator, deterministic metadata, AgentOS entry/glue | a second implementation of Luau values/tables/strings/GC or source semantics |
| C++ | a thin pin-specific adapter to upstream Luau parser/compiler/Proto/CodeGen IR; generated wasm32 layout probe; narrowly named AOT runtime helpers/refactors derived from upstream VM semantics | request framing, package policy, general Wasm emission, object linking, artifact packaging, or a monolithic product backend |
| existing Zig glue | `_start`, `arg`, AgentOS libraries, syscall bindings, trap-backed protected-call integration | Luau VM internals already implemented upstream |
| Rust | existing kernel/loader/attestation integration only when the guest contract genuinely changes | the compiler/backend/linker merely because Rust Wasm crates exist |
| TypeScript/JavaScript | host adapter, install API, and host-level tests | compilation semantics or artifact construction |

The clean boundary is a coarse, versioned snapshot rather than hundreds of cross-language calls:

```text
Zig validates package and selects modules
    |
    v
extern "C" pin adapter (C++)
    source -> upstream bytecode -> temporary Proto -> upstream optimized IR
    |
    v
FrontendSnapshotV1 bytes
    strings/constants/protos/upvalues/source locations/blocks/instructions/decoded operands
    no raw host pointers, no C++ containers, no execution
    |
    v
Zig validates snapshot -> normalized AOT IR -> Wasm object -> link -> validate
```

Boundary rules:

- C++ owns every include of Luau private CodeGen/VM headers used by the compiler frontend adapter.
- Zig never dereferences `Proto*`, `lua_State*`, `IrFunction*`, or a C++ container returned by the
  adapter. The adapter serializes stable IDs and data into `FrontendSnapshotV1`.
- The adapter has a small C ABI: compile/extract, retrieve diagnostic, and free. It does not call back
  into Zig once per IR instruction.
- The snapshot schema carries a version, Luau pin, layout digest, lengths, and checked offsets. Zig
  rejects unknown versions, malformed references, duplicate IDs, and pin/layout mismatch.
- Upstream-dependent decoding belongs in the adapter; target-dependent normalization and lowering
  belong in Zig. For example, the adapter may decode operands from a fallback bytecode location, but
  Zig decides how the decoded operation becomes an AOT slow path.
- Generated Wasm references only a versioned, unmangled runtime symbol surface such as
  `mc_luau_aot_v1_*`. It never depends on C++ mangled names or in-memory compiler objects.
- Runtime helpers may operate on real `lua_State`/`TValue` objects inside the final guest. That is a
  generated-code-to-runtime ABI, not permission to expose those objects across the compiler's Zig/C++
  design boundary.
- The target runtime continues to reuse upstream table/string/function/error/GC code. Rewriting those
  subsystems in Zig would repeat the audited branch's core mistake in a different language.

Recommended source topology:

```text
memcontainers/programs/luau/aot/
  schema/                 versioned frontend snapshot and runtime ABI definitions
  frontend/               small C++ Luau-pin adapter only
  compiler/
    driver.zig            orchestration; intentionally small
    request.zig           framing, digests, canonical package validation
    package.zig           closed module graph and policy
    ir/                    snapshot decoder, normalized AOT IR, coverage ledger
    lower/                 CFG and command-family lowering
    wasm/                  module/object model and deterministic encoder
    link/                  object/archive inventory and narrow production linker
    artifact.zig          final validation, reports, response framing
  runtime/
    include/               versioned generated-code/runtime C ABI
    src/                   narrow C++ AOT semantic helpers and upstream refactors
    glue/                  Zig entrypoint, AgentOS libraries, protected-call glue
  tools/                   layout/IR/object/link-map generators
  test/                    unit, oracle-link, structural, differential, kernel E2E
```

The driver must remain boring. Complex behavior lives behind typed modules with one responsibility;
neither a new multi-thousand-line `codegen_bridge.cpp` nor an equivalent `compiler.zig` is acceptable.

---

## 7. The Luau runtime contract

### 7.1 Reuse upstream representation

The output runtime uses the pinned Luau VM's actual Wasm32 layout, not an invented shadow model. At a
minimum this covers:

- `TValue` and all tag constants;
- `lua_State`, `global_State`, stack and `CallInfo`;
- `Proto`-equivalent immutable metadata;
- `Closure`, `UpVal`, and capture state;
- `TString`, string interning, and hashing;
- `LuaTable`, node/array layout, metatables, readonly/safe-env state;
- `Udata`, buffers, threads where supported, and their tags;
- GC headers, colors/lists/barriers, allocator state, and collection steps;
- standard library C closures and AgentOS Zig/C ABI glue.

Do not hardcode host-size assumptions. Generate a checked layout manifest with `sizeof`, `alignof`, and
`offsetof` values using the exact wasm32 toolchain/configuration. The same manifest digest is embedded
in the compiler and runtime pack. A mismatch is a build or compile error.

### 7.2 Runtime-only source boundary

Create an explicit Bazel source set for the target AOT runtime. It should include the state, object,
table, string, function, GC, API, auxiliary, library, error, and semantic helper implementation needed
by generated code. It must exclude:

- Luau Ast, Compiler, Bytecode writer, and Analysis libraries;
- CodeGen and runtime machine-code allocation;
- `luau_compile` and source parsing;
- `luau_load` and runtime bytecode deserialization unless a non-bytecode metadata loader is separately
  justified;
- `lvmexecute.cpp` and every bytecode dispatch entry;
- dead interpreter fallback bodies.

Some useful semantics currently live in files coupled to interpreter fallback functions. Refactor the
pinned upstream patch surface into named AOT runtime helpers, with tests against the unmodified
interpreter behavior. Do not link the entire executor for convenience.

### 7.3 AOT metadata instead of executable bytecode

Generated code still needs constants, child-function relationships, debug names, upvalue descriptors,
parameter/vararg information, maximum stack size, line/source mapping, and cache slots. Serialize a
compact immutable `AotProto` graph containing only these fields.

`AotProto` must not contain an executable bytecode array. If upstream helpers currently accept
`Proto*`, either:

1. construct a compatible runtime `Proto` with `code == null` and route every generated operation away
   from code/PC-dependent helpers; or
2. define an explicit `AotProto` and adapt/refactor helpers to it.

Option 2 gives a stronger type boundary and is preferred once the first oracle works. A temporary
compatible Proto is acceptable only with assertions proving no runtime bytecode dereference.

### 7.4 Value and stack ABI

The canonical representation is the actual Luau `TValue` in linear memory. Generated code uses byte
offsets from the wasm32 layout manifest. SSA values may temporarily live as Wasm locals, but every
observable/safepoint boundary must have a correct materialized stack state.

Required invariants:

- `L->base`, `L->top`, and current `CallInfo` agree before a helper that can allocate, error, call Lua,
  invoke a metamethod, yield, or trigger GC;
- live collectable values are visible to the collector at safepoints;
- tags and payloads are updated in the same order as the upstream lowering requires;
- write barriers run for object/table/upvalue mutations;
- stack growth updates cached addresses after reallocation;
- `savedpc` becomes an AOT source-location ID, never a bytecode resume pointer;
- multiple returns and `LUA_MULTRET` use the same stack/result convention as Luau;
- top-level results are discarded by `_start`.

### 7.5 Generated function ABI

Correctness-first ABI:

```text
aot_function(lua_State* L, AotProto* proto) -> AotStatus
```

All generated Luau functions share one Wasm function type and occupy a deterministic table. `AotProto`
contains the table index. The exact return encoding is frozen only after the call/pcall prototype, but
must distinguish normal return, yielded/continuation states if supported, and protected error transfer
without conflating a Luau return value with a process exit code.

At function entry, generated code obtains the current base, closure, constants, and frame metadata from
`L`/`AotProto`. It does not take host-language parameters for arbitrary Luau values.

### 7.6 Calls

`CALL` must implement three real runtime cases:

1. **compiled Luau closure:** construct/update `CallInfo`, adjust arguments/varargs/top, then
   `call_indirect` the target AOT table entry;
2. **C/Zig closure:** invoke the linked Luau C-function wrapper and perform normal result movement;
3. **callable via `__call`:** invoke the upstream semantic helper, then dispatch the resolved closure.

No case may fall into bytecode execution. Because the package is closed, every reachable Luau Proto
must have a compiled table entry. Missing entries are link/compile failures, not runtime fallback.

### 7.7 Return

`RETURN` closes required upvalues, moves the requested results according to the caller's expected result
count, restores `CallInfo`/base/top, and transfers control to the compiled caller or AOT entry gate.
It does not print. It does not translate a returned number into process status. The runner's root call
uses zero requested results, matching current `/bin/luau` behavior.

### 7.8 Errors, `pcall`, and traps

Runtime errors must preserve catchability:

- named runtime helpers use the patched Luau error path;
- protected boundaries use the AgentOS trap-backed pcall mechanism;
- all GC/root/frame state is materialized before an operation can raise;
- a caught error resumes the compiled protected caller, never the VM;
- an uncaught error reaches the root traceback handler and produces compatible stderr/status;
- source maps translate AOT location IDs into module/line information.

The first error milestone must cover an error raised inside a nested compiled closure, caught by
`pcall`, plus an uncaught equivalent, using the same compiled artifact.

### 7.9 GC and allocation

Use the real Luau allocator and collector before claiming tables, strings, closures, buffers, or
long-lived programs. A bump allocator fragment is not a substitute.

Every allocation-capable lowering is labeled as a safepoint in the command ledger. The backend emits
root materialization, invokes the runtime helper, refreshes base/top-derived addresses, and maintains
barriers. Stress tests run with a deliberately tiny GC threshold and compare results against the
interpreter.

---

## 8. The complete IR-to-Wasm map

### 8.1 Why the map is a prerequisite

The pinned Luau IR has approximately 180 commands and multiple operand/block kinds. The enum changes
across Luau versions. A handwritten checklist will drift. Before more feature lowering, add a generator
that reads/compiles against the pin and emits `ir_coverage.json` with one row per `IrCmd` and one row per
IR block/operand kind.

Required fields:

```json
{
  "pin": "luau-0.725+agentos-patches",
  "command": "DO_ARITH",
  "class": "runtime_helper",
  "wasm_features": [],
  "runtime_symbols": ["mc_luau_aot_doarith"],
  "may_allocate": true,
  "may_raise": true,
  "may_call_luau": true,
  "safepoint": true,
  "rejoins": true,
  "oracle": "IrLoweringX64.cpp:DO_ARITH + lvmutils.cpp",
  "tests": ["..."],
  "status": "implemented"
}
```

The backend build uses an exhaustive switch with warnings-as-errors. `unknown`, an unclassified new
enum member, or a reachable `unsupported` row fails compilation. An unreachable command may be
rejected only with a reproducible IR fixture/proof and remains visible in the ledger.

### 8.2 Lowering classes

Every command belongs to exactly one class:

| Class | Meaning |
|---|---|
| `direct` | emitted as ordinary Wasm operations with no observable slow semantics |
| `layout` | direct memory operation using checked Luau wasm32 offsets |
| `control` | structured block/branch lowering with explicit predecessor/value mapping |
| `runtime_helper` | calls a named AOT runtime semantic helper |
| `guard_slowpath` | fast check branches to compiled slow path and then rejoins |
| `call_protocol` | participates in Luau call/return/vararg/continuation ABI |
| `gc_protocol` | safepoint, barrier, allocation, or collector protocol |
| `compile_only` | optimizer marker removed before code emission |
| `rewrite_required` | upstream PC/VM fallback must be converted to explicit AOT IR/helper call |
| `unsupported` | compile-time diagnostic for the current tier; never silently ignored |

### 8.3 Initial command-family map

This table is the architectural classification. The generated ledger is the exact per-enum contract.

| IR family | Representative commands | Required Wasm/AOT treatment |
|---|---|---|
| no-op/markers | `NOP`, `SUBSTITUTE`, `MARK_USED`, `MARK_DEAD` | eliminate; assert none affect final semantics |
| TValue loads | `LOAD_TAG`, `LOAD_POINTER`, `LOAD_DOUBLE`, `LOAD_INT`, `LOAD_INT64`, `LOAD_FLOAT`, `LOAD_TVALUE`, `LOAD_ENV` | layout loads from real VM stack/constant/env objects |
| address formation | `GET_ARR_ADDR`, `GET_SLOT_NODE_ADDR`, `GET_HASH_NODE_ADDR`, `GET_CLOSURE_UPVAL_ADDR` | checked i32 address math using runtime layouts/cache metadata |
| TValue stores | `STORE_TAG`, `STORE_EXTRA`, `STORE_POINTER`, `STORE_DOUBLE`, `STORE_INT`, `STORE_INT64`, `STORE_VECTOR`, `STORE_TVALUE`, `STORE_SPLIT_TVALUE` | layout stores; barrier obligations come from surrounding IR/ledger |
| integer/i64 math | add/sub/mul/div/idiv/rem/mod, shifts, rotates, counts | direct Wasm where exact Luau overflow/division rules agree; explicit guards otherwise |
| number/float math | add/sub/mul/div/idiv/mod/min/max/unm/floor/ceil/round/sqrt/abs/sign | direct Wasm or linked libm; NaN and signed-zero differential tests mandatory |
| vectors | add/sub/mul/div/idiv/min/max/floor/ceil/abs/dot/extract/tag | scalarized first; optional SIMD is out of scope |
| select/conversion | `SELECT_*`, int/uint/float/num/vector conversions, truncate/sign extend | direct with Luau-specific range/NaN guards |
| truth/equality/compare | `NOT_ANY`, `CMP_*`, tag/split comparisons | direct fast path; metamethod/string/general equality via helper where IR requests it |
| control flow | `JUMP`, conditional jumps, numeric-loop condition, slot-match | CFG-to-structured-Wasm transform or dispatcher only as a temporary oracle; preserve block arguments |
| table/string lengths | `TABLE_LEN`, `STRING_LEN` | layout fast path with semantic slow path where required |
| tables | `NEW_TABLE`, `DUP_TABLE`, `TABLE_SETNUM`, `TRY_NUM_TO_INDEX`, slot/node checks | real `luaH_*`, allocation, caches, readonly/metatable rules, barriers |
| userdata/buffer | `NEW_USERDATA`, buffer-length/tag checks | runtime helpers and capability/tier gating |
| stack adjustment | `ADJUST_STACK_TO_REG`, `ADJUST_STACK_TO_TOP` | update real `L->top`; refresh cached base after allocating calls |
| fast builtins | `FASTCALL`, `INVOKE_FASTCALL`, `CHECK_FASTCALL_RES` | direct builtin lowering when mapped; otherwise call linked `luauF_table` equivalent and compiled fallback |
| semantic slow ops | `DO_ARITH`, `DO_LEN`, `GET_TABLE`, `SET_TABLE`, `GET_CACHED_IMPORT`, `CONCAT`, `GET_UPVALUE`, `SET_UPVALUE` | named runtime helpers from actual Luau semantics; may raise/allocate/call metamethods |
| guards | tag/truth/readonly/metatable/safe-env/array/slot/node/buffer/userdata/compare checks | branch to an AOT slow block or current-tier rejection; never VM exit |
| interrupts | `INTERRUPT` | kernel/runtime interrupt/fuel hook with materialized state; no bytecode PC |
| GC | `CHECK_GC`, `BARRIER_OBJ`, `BARRIER_TABLE_BACK`, `BARRIER_TABLE_FORWARD` | real collector and barriers; ledger marks safepoints |
| source state | `SET_SAVEDPC`, `COVERAGE` | use AOT location/coverage IDs, not bytecode pointers |
| closures/upvalues | `CLOSE_UPVALS`, `CAPTURE`, `NEWCLOSURE`, duplicate closure path | real Closure/UpVal allocation and child AotProto/table index |
| lists/varargs | `SETLIST`, prep/get-varargs fallbacks | decoded AOT helpers using frame metadata; no instruction decoding |
| calls/returns | `CALL`, `RETURN` | compiled-function ABI and C-closure bridge |
| generic iteration | `FORGLOOP`, `FORGLOOP_FALLBACK`, `FORGPREP_XNEXT_FALLBACK`, fallback prep | real iterator semantics, metamethod/call path, compiled continuation |
| full opcode fallbacks | global/tableks/namecall/dupclosure and similar `FALLBACK_*` | rewrite during compiler IR normalization into explicit operands + named AOT helper; runtime must not receive a bytecode PC |

### 8.4 Block mapping

The upstream IR distinguishes ordinary, fallback, and exit/synchronization blocks. The Wasm backend
normalizes them before low-level emission:

- ordinary blocks become structured Wasm blocks/loops/ifs or entries in a correctness-first CFG
  dispatcher;
- fallback blocks become explicit AOT slow paths with materialized VM state and a defined rejoin;
- VM-exit edges are forbidden in strict output and must either be rewritten or produce a precise
  compile error naming function, source location, command, and missing map row;
- exit-sync state becomes explicit stack/source synchronization before a helper or return;
- block parameters/SSA values have a deterministic local/spill assignment;
- irreducible CFG handling is specified and tested, not accidentally flattened.

A dispatcher loop is acceptable for the first oracle if it executes runtime values and real helpers.
It is not acceptable if it evaluates the program during compilation. Structured lowering can replace it
after semantic gates are green.

### 8.5 Upstream fallback conversion

Commands such as `FALLBACK_GETGLOBAL` currently correspond to helpers that accept a bytecode `pc` and
decode operands. Strict AOT adds a normalization pass in the compiler:

```text
FALLBACK_GETGLOBAL(pc, Rn, Kn)
  -> AOT_GETGLOBAL(location_id, destination_slot, constant_id, cache_id)
```

The AOT helper receives decoded IDs/addresses. It performs the exact lookup/cache/metatable semantics
and returns to generated code. The target runtime contains no arbitrary instruction decoder. Apply the
same method to set-global, table-ks, namecall, list, vararg, duplicate closure, and generic-for fallback
families.

---

## 9. Wasm module and object map

### 9.1 Final module entities

The linker must account for every Wasm index space:

| Entity | Contract |
|---|---|
| types | canonicalize identical function signatures; remap all references |
| imports | union only required `mc.*` functions; deterministic order; reject conflicts |
| functions | runtime, glue, generated functions, init, `_start`; remap calls/ref.func |
| table | one deterministic table for AOT/C indirect calls where needed; apply element relocations |
| memory | exactly one defined wasm32 memory; merge object data/BSS/heap/stack regions |
| globals | stack/heap bases and runtime globals; remap initializers/relocations |
| exports | `memory`, `_start`, protected-call exports, allowed diagnostics; reject accidental internals |
| elements | compiled-function and C-function table entries with stable metadata linkage |
| data | runtime constants, package strings/constants, AotProto graph, source map, static modules |
| start/init | deterministic ordered constructors before `_start`; no duplicate start ambiguity |
| custom | producers/build ID/AgentOS metadata/source map; strip or canonicalize nondeterministic data |

### 9.2 Generated object contract

The backend first emits a standard relocatable Wasm object wherever practical. It defines generated
function symbols and package data, and references a versioned `mc_luau_aot_*` runtime symbol surface.
The object includes standard linking/relocation sections understood by the oracle linker.

Do not invent a compressed/custom pack format until this object links and runs through `wasm-ld`.

### 9.3 Runtime object corpus inventory

Before implementing the production in-Wasm linker, build the target runtime with the exact Zig/C++
toolchain and collect every input object/archive. Generate a checked inventory containing:

- object/archive digest and producer flags;
- sections and index counts;
- symbols, binding, visibility, undefined/defined status;
- relocation type, source section, target symbol, addend, and count;
- COMDAT groups;
- init functions and priorities;
- table/data alignment requirements;
- TLS/PIC/shared-memory requirements;
- unsupported features.

The expected initial universe should be deliberately narrow: static non-PIC wasm32 objects, one memory,
one table, ordinary function/data/global/table-index relocations, deterministic archives, no dynamic
linking, TLS, shared memory, or COMDAT complexity unless the corpus proves it is needed.

### 9.4 Oracle and production linker

Two paths are required:

1. **Oracle path:** build/test infrastructure invokes the established `wasm-ld` pipeline on the
   generated object and runtime archive. This establishes correct symbol and relocation behavior.
2. **Production path:** the zero-import compiler embeds a digest-pinned normalized runtime pack and a
   narrow linker derived from the proven object universe. Its output is compared structurally and
   behaviorally with the oracle.

The production linker must:

- parse all accepted object/linking/relocation sections with bounds checks;
- implement archive extraction based on unresolved symbols;
- resolve strong/weak/local symbols deterministically;
- reject duplicate/conflicting definitions;
- canonicalize/remap types and all index spaces;
- lay out data/BSS/stack/heap with checked arithmetic and alignment;
- allocate and relocate table slots;
- apply each inventoried relocation type with overflow checks;
- order constructors deterministically;
- dead-strip only with proven reachability roots;
- emit canonical section/order/metadata;
- produce actionable diagnostics for unsupported objects/relocations.

`riwl` is a methodological starting point, not a drop-in assumption. The AgentOS corpus and final mc
adapter path are authoritative.

### 9.5 Runtime pack generation

The runtime pack is generated at repository build time, not synthesized from demo Wasm modules during a
compile request. It contains:

- normalized runtime objects/archive;
- AgentOS Luau glue and selected standard libraries;
- WASI adapter/link inputs required to reach pure-mc;
- symbol/relocation/entity inventory;
- wasm32 layout manifest;
- runtime ABI version and Luau pin;
- source/object digests and license metadata;
- linker conformance corpus and expected hashes.

Its digest is embedded in `luau-compiler.wasm` and copied to compile metadata. Compiler/runtime ABI
mismatch is a hard error.

---

## 10. Compiler request/response contract

### 10.1 Transport properties

The host call is deterministic, length-delimited, bounded, and versioned. No field is ignored. Unknown
required fields/options fail closed. Allocations and integer arithmetic are checked before use.

The exact binary encoding may retain compatible work already present, but the semantic request is:

```text
CompileRequestV1 {
  abi_version
  request_id
  compiler_pin
  runtime_pack_digest
  package_manifest_digest
  entry_module
  ordered files[] { canonical_path, content_digest, content_bytes }
  declared module graph or resolver mode
  output tier
  declared mc capabilities/import ceiling
  optimization/debug/source-map options
  compile resource budgets
}
```

Validation order:

1. frame magic/version/total length;
2. count and size ceilings with checked arithmetic;
3. UTF-8 and canonical path rules;
4. unique, sorted canonical paths; no absolute paths, `..`, NUL, or aliases;
5. recompute each content digest;
6. recompute canonical package manifest digest;
7. compiler/runtime pin agreement;
8. recognize every option and tier;
9. resolve the closed module graph;
10. AST/bytecode/IR policy checks;
11. compile/lower/link/validate;
12. inspect final imports against the declared ceiling.

### 10.2 Response

```text
CompileResponseV1 {
  status
  request_id
  compiler_build_digest
  runtime_pack_digest
  package_manifest_digest
  artifact_digest
  artifact_wasm
  canonical metadata
  diagnostics[]
}
```

There is no execution-relevant `runtime.pack` sidecar in the response. The runtime is already linked
into `artifact_wasm`. Optional diagnostic maps may be returned separately but are not required for
execution.

### 10.3 Error model

Errors are stable categories with module/path/source range and underlying command/symbol/relocation where
applicable:

- malformed request;
- digest or pin mismatch;
- package/module resolution failure;
- Luau parse/compile error;
- prohibited dynamic feature;
- reachable unsupported IR command/block;
- runtime ABI/layout mismatch;
- object/link/symbol/relocation error;
- final Wasm validation/feature/import error;
- compiler resource limit;
- internal compiler error.

An unsupported program is not silently sent through a different compiler or interpreter path.

---

## 11. Package and language policy

### 11.1 Static modules

The entry module and all `require` dependencies are provided in the request. The resolver canonicalizes
module IDs, constructs the graph, diagnoses missing/duplicate/cyclic initialization according to Luau's
actual rules, and assigns deterministic module table indices.

Module initializer functions are compiled like all other Luau functions and run lazily/once at guest
runtime. They are never run during compilation.

### 11.2 Prohibited dynamic features

Reachable source compilation/loading and nonstatic module lookup are out of scope. Enforce this from the
upstream AST/bytecode/IR and resolved call/import graph. Do not reject harmless strings or comments and
do not miss aliases because a token scanner did not recognize them.

For features whose reachability cannot yet be proven, strict tier rejects the package with a diagnostic
that identifies the ambiguous operation. Later tiers may add conservative whole-program analysis, but
never source-text heuristics as the authority.

### 11.3 Capabilities

The package manifest declares an allowed mc capability/import ceiling. The runtime/library selection
and final linked imports must be a subset. The host rechecks the final module and applies normal stamp/
attest policy.

Do not infer security authority from seeing `sys.fs` in source. Alias/metatable/dynamic behavior makes
that unsound. Static analysis may minimize a runtime pack as an optimization, but enforcement remains
final-artifact based.

---

## 12. Determinism, limits, and security

### 12.1 Deterministic compilation

Given identical request bytes, compiler build, and runtime pack, output bytes and metadata must be
identical. Control:

- file/module/symbol/type/function/data ordering;
- map/set iteration order;
- archive member selection;
- hash seeds used by the compiler/linker;
- timestamps, paths, producers sections, and build IDs;
- source-map path normalization;
- NaN canonicalization only where language semantics permit;
- compression settings if compression is later introduced.

Node and Wasmtime hosts must return byte-identical output for the same request.

### 12.2 Compiler budgets

Bound request bytes, file/module count, source length, AST/bytecode/IR size, function count, CFG size,
recursion in compiler algorithms, object/archive counts, symbols, relocations, output sections, output
bytes, and total compiler fuel/time/memory.

These are compiler resource limits, not simulated runtime loop or recursion limits. A source loop with a
billion runtime iterations may compile quickly and then be constrained by normal guest fuel.

### 12.3 Untrusted input

Treat source, request framing, object metadata selected by a request, and all integer lengths as
untrusted. Fuzz:

- frame parser and canonicalizer;
- package graph/resolver;
- Luau error-channel integration;
- IR serialization/normalization;
- Wasm object parser and linker;
- final module validator.

The compiler must fail cleanly without leaving sticky channel state corrupt for the next request.

---

## 13. Evidence required from every artifact

A passing functional fixture is insufficient. Each promoted artifact acceptance report contains:

- compiler, Luau pin, runtime pack, request, package, and artifact digests;
- final Wasm validation result and feature list;
- exact import/export/memory/table summary;
- linked symbol reachability report rooted at `_start` and protected-call exports;
- proof that forbidden source/object sets were not linked;
- proof that no bytecode data section or interpreter dispatch table is present;
- generated-function count versus reachable AotProto count;
- IR coverage rows exercised and any unsupported rows;
- runtime helper and relocation types used;
- `mc-stamp` and `mc-attest` output;
- same-artifact multi-input runtime results;
- differential result against `/bin/luau`;
- Node/Wasmtime byte-determinism result;
- exact Bazel commands used.

Source-set exclusion plus link-map reachability is the primary no-interpreter proof. String denylisting
may remain as a cheap tripwire but never as the evidence.

---

## 14. Verification strategy

### 14.1 The anti-specialization rule

Every semantic milestone compiles an artifact once, then executes that same byte sequence with at least
three materially different runtime inputs. The test records one artifact digest across all runs.

Inputs should include values unavailable to the compiler: argv, VFS contents, stdin, or a kernel-
provided deterministic service response. Recompiling for each expected output invalidates the test.

### 14.2 Differential oracle

For every supported fixture, run:

```text
same source package + same argv/VFS/capabilities
  -> /bin/luau
  -> promoted artifact
compare stdout, stderr class/text policy, exit status, VFS effects, and returned library values
```

When exact traceback addresses differ, compare a normalized documented form. Any intentional semantic
difference requires an explicit amendment to this document, not a test-local expectation.

### 14.3 Strong falsification fixtures

The first three mandatory tests are:

1. **Dynamic scalar/control:** compile once; read `arg[1]`, parse a number, run branches and a loop whose
   trip count depends on it, call a nested closure, print the result. Run at least `0`, `7`, and `23`.
2. **Dynamic table/string/GC:** compile once; read a VFS file whose contents differ per run, split/parse
   it into a table, mutate/iterate/concatenate under a tiny GC threshold, and print/write a result.
3. **Error/call boundary:** compile once; choose via argv whether a nested compiled closure returns,
   raises inside `pcall`, or raises uncaught. Verify result/error/traceback behavior.

Also mandatory: a module containing only `return 30` emits no stdout and exits zero.

These fixtures are intentionally hostile to compile-time evaluation and fixed recipe emitters.

### 14.4 Test layers

| Layer | Purpose |
|---|---|
| unit | request parser, paths/digests, layout manifest, CFG transform, Wasm encoding, relocation application |
| generated ledger | every pinned `IrCmd` classified; implemented rows have direct tests |
| runtime unit | TValue/stack/call/table/string/closure/error/GC helpers compiled for wasm32 |
| linker conformance | production linker versus `wasm-ld` over actual and synthetic object corpus |
| structural artifact | imports/exports/features/symbols/reachability/no-bytecode/no-interpreter |
| semantic E2E | same artifact, multiple runtime inputs under AgentOS kernel |
| differential | `/bin/luau` versus promoted artifact |
| determinism | repeated compile and cross-host byte equality |
| fuzz/property | framing, package, IR normalization, object/linking, selected semantic programs |
| performance | compile size/time, artifact size, startup, hot loops after correctness gates |

### 14.5 Invalid tests

The following do not close a product milestone by themselves:

- artifact begins with Wasm magic;
- compile call returns success;
- output contains an MCRP fragment name;
- a constant-only program prints its expected value;
- a compiler-time evaluator reports broad library coverage;
- a Wasm runtime other than AgentOS can instantiate a reduced fixture;
- a denylist string is absent;
- tests pass only after changing expected semantics away from `/bin/luau`.

---

## 15. Implementation work packages and gates

Work packages are sequential unless the prerequisite column explicitly allows parallelism. Agents do
not claim later language coverage while an earlier runtime/linking gate is open.

### WP0 — Preserve the audit branch and create a clean implementation worktree

**Goal:** retain evidence and useful scaffolding while starting the replacement from current `develop`.

Tasks:

- record current HEAD, merge base, status, diff stats, and untracked files;
- preserve the current worktree and all user-owned dirty edits exactly as audit/reference material;
- from the bare repo, create a new lowercase kebab-case `feature/*` branch from current `develop` and a
  separate worktree for the replacement;
- copy or reimplement salvageable pieces only after line-by-line review; do not bulk cherry-pick the
  false semantic-emitter/coverage commits;
- establish the new worktree's README/tracking state from this document;
- add regression tests for the discovered false contracts, including silent top-level return;
- identify every salvaged piece, source commit/file, owner, and reason in a salvage ledger.

Gate:

- no user change lost;
- the audited worktree remains untouched and available for comparison;
- the replacement worktree is based on `develop`, not on `feature/luau-compiler`;
- product Bazel graph has one declared future backend path;
- old tests cannot report product completion.

### WP1 — Produce the machine-readable maps

**Goal:** remove architectural unknowns before more compiler features.

Tasks:

- generate the exact wasm32 Luau layout manifest;
- generate complete `IrCmd`, operand-kind, and block-kind coverage ledgers;
- annotate x64/A64 oracle sites and runtime dependencies;
- build an initial AOT runtime source boundary and forbidden-source list;
- compile the runtime object/archive with the canonical toolchain;
- inventory objects, symbols, relocations, tables, data, init functions, and features;
- document the existing AgentOS adapter/link sequence;
- add small checked tools that fail on pin drift.

Gate:

- every enum member is present in the ledger;
- every runtime object and relocation is known;
- open rows are explicit; no code claims unsupported families.

### WP2 — Build a real runtime/link oracle

**Goal:** execute one nonconstant compiled function against the real Luau runtime, linked by `wasm-ld`.

**Current state:** the runtime ABI, real-state execution, GC publication, protected failure path, and
standard-linker archive integration are proven. A declared Luau source file now passes through the
zero-import frontend and backend, and the exact emitted relocatable object is linked into the strict
runtime. It executes through `lua_call` on real states and matches a separate exact-pinned interpreter
artifact for six dynamic inputs. A production-shaped `_start` receives argv through the canonical
adapter, the optimized/stamped/attested artifact installs in a dedicated image, and the real AgentOS
kernel observes same-artifact stdout matching `/bin/luau` across those six inputs. The mandatory silent
top-level `return 30` artifact remains gate-open.

Tasks:

- create runtime-only state/init/stdlib/glue target without bytecode executor;
- define `AotProto`, layout/version checks, and the uniform function ABI;
- implement a minimal `_start` that creates state, opens selected libraries, constructs runtime argv,
  installs root closure metadata, protected-calls compiled root, and discards results;
- manually or mechanically emit one generated Wasm object using real `TValue` stack slots;
- link object + runtime + adapter with the established toolchain;
- run one artifact against at least three argv values in the kernel.

The function must branch/loop on runtime argv. A constant arithmetic demo does not pass.

Gate:

- same artifact digest, three runtime outputs matching `/bin/luau`;
- `return 30` is silent;
- final import/feature/stamp/attest gates pass;
- no interpreter/compiler source in link map.

### WP3 — Canonical Wasm object builder and scalar CFG lowering

**Goal:** replace manual fixture emission with the one production code-generation model.

**Current state:** the production object builder and upstream-snapshot-driven numeric fast tier are
implemented. A generic CFG dispatcher lowers real scalar branches and loops; complete rows are `NOP`,
`LOAD_TAG`, `LOAD_DOUBLE`, `LOAD_TVALUE`, `STORE_TAG`, `STORE_DOUBLE`, `STORE_TVALUE`, `ADD_NUM`,
`JUMP`, `JUMP_CMP_NUM`, and `MARK_USED`. `CHECK_TAG`, `INTERRUPT`, and `RETURN` are deliberately partial
and named as such in the ledger. Slow-block rejoin, additional scalar operations/conversions, and the
remaining command-level differential matrix remain. The exact upstream-IR-generated loop object already
passes the real-runtime/pinned-interpreter differential gate.

Tasks:

- implement types/functions/locals/blocks/branches/calls/memory references/data/symbols/relocations;
- normalize upstream IR blocks and allocate SSA values to locals/spills;
- lower loads/stores, tags, scalar arithmetic, conversions, comparisons, guards, and loops;
- implement AOT slow-block rejoin for type guards and arithmetic semantics;
- produce diagnostics for every reachable unmapped command;
- update ledger rows and direct differential tests.

Gate:

- mandatory dynamic scalar/control fixture is generated from upstream IR, not hand-authored;
- generated object links through `wasm-ld` and passes structural evidence;
- no source pattern or compiler-time execution path selects output behavior.

### WP4 — Calls, closures, upvalues, varargs, and modules

**Goal:** make the closed Proto graph executable.

Tasks:

- deterministic AotProto/function-table assignment;
- real `CALL` and `RETURN` protocol;
- C/Zig closure bridge and callable/metamethod path;
- closure allocation, captures, open/closed upvalues, barriers;
- fixed and multi-return results, varargs, stack growth;
- static module registry, lazy once-only initialization, cycles per oracle behavior;
- source locations across compiled calls.

Gate:

- nested/recursive closures depend on runtime input;
- multi-results/varargs differential suite passes;
- two-module and cycle/error fixtures pass;
- number of reachable AotProto nodes equals generated function coverage.

### WP5 — Errors and protected execution

**Goal:** remove bytecode execution from every error/call continuation.

Tasks:

- integrate patched trap-backed error path with compiled frames;
- implement protected call/return continuation metadata;
- materialize roots/frames at raising helpers;
- top-level traceback/source map;
- interrupt/fuel hook behavior;
- nested `pcall`/`xpcall` and metamethod errors.

Gate:

- mandatory error/call falsification fixture passes from one artifact;
- no caught path enters the VM;
- sticky compiler/guest pcall state recovers across repeated calls.

### WP6 — Tables, strings, iteration, allocation, and GC

**Goal:** implement dynamic heap semantics through the real runtime.

Tasks:

- table fast paths, cache slots, generic slow paths, readonly/metatables;
- strings, concatenation, lengths, equality/order and selected library functions;
- numeric and generic iteration;
- allocations, collector steps, roots, stack relocation, barriers;
- duplicate/new closures, userdata/buffers only when tier permits;
- adversarial aliasing and mutation differentials.

Gate:

- mandatory VFS/table/string/GC fixture passes under tiny GC threshold;
- stress corpus runs repeated collections without corruption;
- all exercised helpers appear in link and ledger evidence.

### WP7 — AgentOS libraries and full first vertical

**Goal:** promote a useful AgentOS tool, not a language microbenchmark.

The first full vertical compiles once and, at runtime:

1. reads argv to choose paths/mode;
2. reads different JSON/VFS content across runs;
3. parses it through the real linked library;
4. builds and mutates Luau tables;
5. calls at least two compiled closures across modules;
6. conditionally catches a runtime error;
7. writes a derived output through `sys.fs`;
8. returns silently from the root.

Gate:

- same artifact works over at least three VFS/argv scenarios;
- behavior matches `/bin/luau` and filesystem diffs match;
- final imports are within declared capabilities and pass attestation.

### WP8 — Production zero-import linker

**Goal:** produce the same accepted artifact inside `luau-compiler.wasm` without host subprocesses.

Tasks:

- implement the inventoried object/archive/linker subset;
- embed/digest/version the normalized runtime pack;
- differential link corpus against `wasm-ld`;
- canonical deterministic output;
- bounds/fuzz/error diagnostics;
- integrate final validation before returning response.

Gate:

- all prior semantic artifacts build through both linkers and behave identically;
- structural differences are explained/canonicalized;
- actual runtime object corpus has no unsupported relocation;
- malformed corpus/request fuzzing fails safely.

### WP9 — Host install/product integration

**Goal:** ship the optional compiler capability safely.

Tasks:

- finalize Node and Wasmtime wrappers around the same ABI;
- host-side result validation, stamp/attest, and authorized atomic install;
- cache key based on compiler/runtime/package/options/capability digests;
- observability for compile time, sizes, failure category, and artifact provenance;
- documentation and rollback/disable behavior when compiler host is absent.

Gate:

- byte-identical cross-host compile;
- real compile-install-exec E2E under AgentOS;
- absence of compiler capability leaves interpreted development path unaffected.

### WP10 — Breadth and optimization

Only after WP0-WP9 gates:

- expand ledger coverage by semantic family;
- improve structured CFG lowering/register allocation;
- dead-strip runtime functions/data using real link reachability;
- specialize helpers while preserving slow paths;
- reduce metadata/runtime size;
- benchmark compile time, artifact size, startup, and hot execution;
- consider a more compact prelinked runtime pack only with oracle equivalence.

Performance work may not reintroduce program execution in the compiler.

---

## 16. Branch recovery sequence

The current branch is an audit-only research spike. No further product implementation occurs in
`agent-os-luau-compiler`. All replacement work occurs in a separate worktree on a new feature branch
created from current `develop`.

Required sequence:

1. preserve the exact dirty state and record the audit snapshot;
2. stop adding abstract-evaluator coverage;
3. land this document as the sole governing contract;
4. from the bare repo, create a new feature branch/worktree from `develop`;
5. build WP1 maps in that new worktree before porting implementation;
6. port only reviewed compiler-shell/host/IR-inspection pieces and record each in the salvage ledger;
7. build the WP2 runtime/link oracle in the new worktree;
8. continue through the acceptance gates without merging the old feature branch;
9. after the replacement succeeds and its evidence no longer depends on the audit worktree, remove
   `agent-os-luau-compiler` with `git worktree remove` from the bare repo and delete its feature branch;
10. merge the replacement upward `feature -> develop -> master` only under the repository's normal
    promotion and release rules.

Deleting the audit worktree/branch is intentionally deferred until success. It is not an early cleanup
step and must preserve or explicitly retire its dirty user-owned changes first.

---

## 17. Agent orchestration contract

### 17.1 Authority

Agents must read this entire document, the live `AGENTS.md`/repo instructions, relevant source files,
and current git status before acting. This document authorizes analysis and scoped implementation only
when the user/driver assigns a work package. It does not authorize destructive cleanup, branch reset,
merge, push, or loss of dirty work.

### 17.2 Assignment shape

Assign one bounded deliverable, normally one ledger family/runtime protocol/linker component, with exact
prerequisites and gates. Never assign “finish coverage”, “make tests green”, or “implement more Luau”.

Each task prompt states:

- worktree and branch;
- dirty-tree ownership warning;
- governing document path and required sections;
- exact files/reference implementations to inspect;
- allowed edit scope;
- forbidden shortcuts;
- expected artifact/evidence;
- exact Bazel command pattern with shared cache;
- what must be reported rather than improvised.

### 17.3 Mandatory agent loop

1. inspect status/diff and restate the semantic gate;
2. trace upstream Luau oracle and AgentOS runtime path;
3. update or validate the relevant map/ledger row;
4. implement the smallest runtime-real vertical;
5. run targeted unit and differential tests;
6. inspect the produced Wasm/link map, not only test status;
7. run the same artifact with multiple runtime inputs;
8. run repository-required broader checks in proportion to risk;
9. report exact changes, commands, results, remaining unsupported rows, and dirty status;
10. stop if the task requires a new architecture decision.

### 17.4 Forbidden agent behavior

- adding source/IR special cases for a fixture;
- evaluating user functions in the compiler;
- implementing Luau standard libraries a second time in the compiler;
- changing expected semantics to fit output;
- marking coverage from artifact existence;
- declaring a runtime pack linked without symbol/relocation evidence;
- using a new Bazel output root;
- discarding/reformatting unrelated dirty changes;
- broad rewrites without preserving a bisectable semantic vertical;
- hiding an unsupported IR command behind an exit-success/fixed-output path.

### 17.5 Handoff format

Every implementation agent returns:

```text
Outcome:
Semantic gate closed:
Files changed:
Upstream oracle references:
IR/runtime/link ledger rows changed:
Artifact digest(s):
Import/export/feature summary:
Interpreter exclusion evidence:
Same-artifact runtime input matrix:
Differential results:
Exact commands and results:
Uncommitted status:
Open risks / unsupported commands:
Recommended next bounded task:
```

“Tests pass” without this evidence is an incomplete handoff.

### 17.6 Architect, doer, and reviewer roles

The primary driver owns system architecture, work-package boundaries, design amendments, integration,
the most difficult cross-boundary implementation, and final acceptance. In particular, the primary
driver personally owns the frontend snapshot schema, normalized AOT IR, generated-function/runtime ABI,
fallback-removal design, object/link architecture, first real vertical, integration review, and every
decision in Appendix E. The architect is not merely a task dispatcher.

Use `gpt-5.6-sol` at low reasoning effort for moderate, well-bounded work whose architecture is already
decided: source/object inventories, ledger generators, isolated helper families with named upstream
oracles, unit/property tests, fixture minimization, structural inspection tools, and focused review of
an existing diff. Give concurrent agents disjoint files or read-only tasks; shared-worktree edits must
not race.

Use Grok only for easy or mechanical work: repetitive Bazel/source-list updates, schema-derived switch
boilerplate, table/fixture transcription, straightforward test-porting, formatting, and exact changes
whose shape is already specified. Grok is not asked to design the system, choose among evidence-gated
decisions, create work-package sequences, reinterpret the product contract, or perform open-ended
refactors. If a Grok task encounters an architectural gap, it stops and reports the gap.

An implementation doer may inspect the live tree, trace a named upstream oracle, implement an assigned
ledger row/helper/linker component, and run the prescribed checks. The primary driver reads every diff,
checks it against this document and the live runtime, and reruns the decisive gates.

Bounded independent code review may be used against an already-decided contract. Its job is to attempt
to falsify:

- runtime rather than compile-time execution;
- absence of bytecode dispatch/fallback;
- real runtime pack participation;
- call/error/GC correctness;
- same-artifact multi-input behavior;
- test agreement with `/bin/luau`;
- complete mapping and honest unsupported rows.

Reviewers do not invent a replacement architecture. They may fix small scoped issues only when
explicitly authorized. The primary driver vets every diff and reruns the checks the doer/reviewer could
not.

### 17.7 Grok bounded-implementation prompt template

```text
Work in /mnt/workspace/agent-os/agent-os-luau-aot on feature/luau-aot-compiler.
Read the assigned sections of LUAU_COMPILATION.md; it is governing.
The primary driver has already created a clean checkpoint commit. Inspect git status and HEAD.

Assigned work package: <WP and bounded deliverable>.
Semantic gate: <observable runtime property>.
Required upstream oracle: <files/symbols>.
Allowed edit scope: <paths>.
Forbidden: compile-time execution, fixture recipes, bytecode fallback, fake pack,
source-token policy, altered Luau semantics, new Bazel output root.

Before editing, report the current path from source -> IR -> Wasm -> runtime helper ->
linked artifact and identify every unknown. Then implement only the bounded deliverable.
Do not redesign the architecture or select an open design decision. If the assigned work
cannot be completed under the governing contract, stop and report the exact conflict.
Run all Bazel commands with
--output_user_root=/mnt/workspace/agent-os/bazel-cache immediately after bazel.
Compile once and run the same artifact against the specified runtime input matrix.
Return the mandatory handoff format from section 17.5.
```

### 17.8 Commit and delegation discipline

Commits are architectural control points, not end-of-day cleanup.

Mandatory commit boundaries:

- commit the governing architecture and language/ABI decision before implementation delegation;
- before every Grok invocation, the implementation worktree must have a reviewed checkpoint commit and
  no unexplained tracked changes;
- commit after every accepted important or significant change: schema/ABI decisions, runtime protocol,
  backend family, linker behavior, completed semantic vertical, work-package gate, or substantial
  refactor;
- commit accepted delegated work after the primary driver reviews the diff and reruns the decisive
  checks; do not stack another delegation task on uncommitted agent output;
- commit before switching implementation engines on the same area so attribution and rollback remain
  exact;
- never mix unrelated cleanup or artifacts into a milestone commit.

Before a checkpoint or milestone commit:

1. inspect `git status --short` and the complete intended diff;
2. run the targeted semantic/structural checks appropriate to the change;
3. stage only the cohesive intended paths;
4. run `git diff --cached --check`;
5. inspect the staged diff/stat and commit with an outcome-oriented message;
6. verify the new HEAD and post-commit status;
7. record any known failing broader gate in the handoff and commit message/body when material.

The pre-Grok checkpoint is mandatory even when the next task is tiny. If the current state cannot form a
coherent checkpoint, Grok is not used. After Grok, the primary driver either rejects/reverts its diff or
reviews, verifies, and commits the accepted result before proceeding.

No commit rule authorizes push, merge, reset, or deletion. Those remain separate user/workflow actions.
The audited `agent-os-luau-compiler` dirty worktree is never used as a checkpoint source.

### 17.9 Daily control report

The driver maintains a short factual report:

| Field | Required content |
|---|---|
| current WP/gate | one semantic outcome, not percent complete |
| last accepted artifact | digest and source/runtime/compiler pins |
| same-artifact inputs | count and results |
| IR ledger | implemented/rewrite/unsupported counts |
| runtime | call/error/GC status |
| linker | object corpus and relocation coverage |
| structural proof | imports/features/interpreter exclusion |
| tests | targeted/differential/full results |
| dirty tree | exact status and ownership |
| blocker | one concrete decision/evidence gap |

Do not report percent complete from fixture counts. A project can have many green fixtures and zero
working runtime architecture.

---

## 18. Acceptance criteria

### 18.1 First credible compiler milestone

The project has a credible compiler—not a product release—when WP2 and WP3 pass:

- upstream Luau source becomes upstream IR;
- the backend emits a relocatable object with real runtime value/stack operations;
- `wasm-ld` links it to the runtime-only Luau target;
- the same final artifact processes multiple runtime inputs correctly;
- top-level returns are silent;
- final structure proves no compiler/interpreter linkage;
- unsupported IR is diagnosed honestly.

### 18.2 First production milestone

The product is ready for controlled use when:

- WP0-WP9 gates pass;
- the first full AgentOS vertical passes same-artifact and differential tests;
- the compiler is zero-import and deterministic across supported hosts;
- the production linker is conformant for the complete runtime object corpus;
- every reachable function has compiled code;
- no bytecode, interpreter dispatch, runtime codegen, or source compiler is reachable/present;
- artifacts pass final Wasm, mc import, stamp, attest, and kernel execution gates;
- package/capability/security/resource contracts are fuzzed and documented;
- the feature is merged progressively through `develop`, not directly to `master`.

### 18.3 Definition of failure

Stop and re-evaluate if any of these appears:

- another growing abstract value/library evaluator in the compiler;
- fixture-specific Wasm emission;
- a second unrelated backend selected by source shape;
- a runtime sidecar that is not linked into the executable;
- tests that recompile for each runtime value;
- output semantics diverging from `/bin/luau` without an approved contract change;
- an unmapped IR command silently ignored or routed to bytecode;
- “coverage” rising while call/error/GC/link gates remain open.

---

## Appendix A — Required live-tree reading map

Before implementation, locate current equivalents of:

- `third_party/luau/SYSTEM.md`;
- `third_party/luau/BUILD.luau.bazel` and Luau patch files;
- `memcontainers/programs/luau/glue/entry.zig`, `lua.zig`, `trap.zig`, `sys.zig`, `stdlib.zig`;
- upstream `CodeGen/include/Luau/IrData.h`, `IrBuilder.h`, `NativeProtoExecData.h`;
- upstream `CodeGen/src/IrTranslation.cpp`, `IrTranslateBuiltins.cpp`, `IrLoweringX64.cpp`,
  `IrLoweringA64.cpp`, `NativeState.h`, `NativeState.cpp`, and call/return emitters;
- upstream `VM/src/lobject.h`, `lstate.h`, `lvmutils.cpp`, `lvmload.cpp`, table/string/function/GC/
  error sources, and `lvmexecute.cpp` only as a behavior/refactoring oracle;
- compiler host precedent and sticky channel implementation;
- kernel guest loader/import registry/limits/Wasmi config;
- `wasi-adapter`, `mc-stamp`, and `mc-attest`;
- the live feature worktree's compile pipeline, lowerers, pack, host wrappers, and tests.

Agents must resolve upstream sources through Bazel's pinned external repo rather than browsing a newer
Luau version and assuming it matches.

## Appendix B — Map artifacts that belong in the repository

Names may adjust to local conventions, but these artifacts must exist and be generated/checked:

```text
luau_aot_layout.json             sizeof/alignof/offsetof/tag values for wasm32 pin
luau_aot_ir_coverage.json        every IrCmd/block/operand lowering classification
luau_aot_runtime_symbols.json    versioned generated-code -> runtime symbol ABI
luau_aot_runtime_objects.json    object/archive/section/symbol/relocation inventory
luau_aot_forbidden_link.json     forbidden source/object/symbol/reachability policy
luau_aot_wasm_features.json      permitted/emitted feature matrix
luau_aot_link_conformance.json   corpus digests and production-vs-wasm-ld results
luau_aot_artifact_report.json    per-artifact structural and semantic evidence
```

Generated files carry the Luau pin, toolchain digest, generator version, and canonical hash. CI fails
when regeneration changes them without review.

## Appendix C — Minimum linker relocation checklist

Do not implement from this generic list alone; the actual object inventory is authoritative. Expect to
investigate at least:

- function index LEB relocations;
- type index LEB relocations;
- global index LEB relocations;
- table index/function offset relocations;
- memory address LEB/SLEB/I32 relocations and addends;
- section/data offsets and alignment;
- references from code, data, elements, and init arrays;
- archive extraction and weak/strong resolution;
- debug/custom section policy.

Each accepted relocation has positive, overflow, malformed, undefined-symbol, and differential tests.

## Appendix D — Semantic corpus progression

The corpus expands only after the relevant runtime protocol exists:

1. dynamic argv number, branches, loops, numeric edge cases;
2. nested calls, recursion, fixed/multiple results, varargs;
3. closures, open/closed upvalues, mutation;
4. errors, nested pcall/xpcall, traceback;
5. strings, concat, patterns through real library calls;
6. tables, array/hash transitions, iteration, metamethods, readonly;
7. GC pressure across all prior cases;
8. static requires, module state, cycles/errors;
9. AgentOS `sys`, VFS, JSON, buffers under declared capabilities;
10. representative real tools.

For each source, prefer values supplied at runtime and run one artifact over multiple inputs.

## Appendix E — Design decisions that remain evidence-gated

The following are intentionally not frozen without prototypes:

- compatible `Proto` versus distinct `AotProto` after the oracle;
- exact `AotStatus` and continuation encoding;
- CFG dispatcher versus structured transform for the first correct backend;
- precise protected-call continuation representation;
- whether the production linker consumes standard objects directly or a normalized prelinked pack;
- initial standard-library subset and artifact-size budget;
- source-map/coverage format;
- safe dead-stripping granularity.

Agents must prototype against the gates, report evidence, and ask the driver to amend this document.
They must not make these choices implicitly across thousands of lines of code.
