# Zig Kernel — Interpreter Performance Retrospective

> **RESOLVED (2026-07-08).** The gap this document diagnosed is CLOSED. We replaced wasm3+Asyncify with
> **WAMR** (wasm-micro-runtime) — a natively re-entrant interpreter — as planned in §8. The Zig kernel
> now runs entirely on WAMR: **`core_zig` 81/81, `extended_zig` 32/32, no Asyncify, no wasm3.** On the
> `zz_bench_luau_loop` benchmark, **WAMR at `-O3` = 3001 ms vs wasmi 2938 ms — parity within 2%**
> (from wasm3's 8.5 s / 2.9x, which was hard-capped at 1.3x by the Asyncify tax). The migration went in
> stages (git: WAMR vendored `47f56cb` → runs a guest `7beb531` → resumable suspend proven `f5f3d10` →
> kernel boots, Asyncify deleted `4de2fc9` → full parity `8783f87` → -O3 wasmi parity `f263696`). The
> two things that mattered: WAMR keeps execution state IN MEMORY (re-entrant), so a blocking syscall or
> fuel yield is *save exec_env, return, re-enter* — zero per-op tax; and `-O3` (not `-Os`) on the
> interpreter, since with no instrumentation tax, dispatch codegen is what dominates. **Everything below
> is the historical record of the wasm3 era and the decision to switch — kept for provenance.**

**Status (wasm3 era — historical):**
- **Functional parity with the Rust kernel: ACHIEVED.** `core_zig` 81/81 (+ Group G suspend-across-
  snapshot), `extended_zig` 32/32 (sqlite + typst domain suites), every functional subsystem ported
  (see [§1](#1-what-the-port-achieved)), and the full suspend / resume / snapshot / pcall machinery
  works.
- **Performance parity with the Rust kernel: NOT achieved *[with wasm3 — since resolved via WAMR,
  see the RESOLVED note above]*.** The Zig kernel embeds **wasm3** (a C interpreter) made suspendable
  via **Binaryen Asyncify**. That combination runs the real e2e suites **~2.5–3x slower than the Rust
  kernel** (which embeds **wasmi**): `core` ~5 s (wasmi) vs ~12–16 s (wasm3); `extended` similar. This
  gap is **pervasive across real workloads** (coreutils, shell, luau tool-calls, adapters, sqlite,
  typst) — it is NOT a microbenchmark artifact.

This document records the root cause, the full investigation, why we could not close the gap with
wasm3, and the path forward — so future work starts from evidence, not from scratch. Every experiment
below is reproducible; the perf harness is `zz_bench_luau_loop` in `memcontainers/tests/e2e/src/kernel.rs`
(`#[ignore]`d; run with `--test_arg=--ignored --test_arg=--nocapture`).

---

## 1. What the port achieved

The Zig kernel is a phase-by-phase, parity-gated reimplementation of the Rust microkernel:
- **All syscall groups** — process (spawn/waitpid/kill/signals/pgid), fs-metadata, ambient
  clock/entropy/sleep, net/HTTP/WebSocket/host-call egress, resident services + served/projected
  filesystems, and pcall (C/C++ protected calls with nested suspend).
- **Every fs backend, `vfs`, `ipc`, `task`/`scheduler`, `bridge`, control channel, and service
  registry** — a near 1:1 module map with the Rust kernel. The few Rust modules with no Zig file
  (`io`, `sync`, `shell`, `builtins`) are deliberately *replaced* by cleaner Zig designs (a unified
  `Fd` union, single-threaded cooperative scheduling, an shcore-based rescue shell, guest coreutils),
  not gaps. The only non-ported item is `seal.rs` (a cosmetic provenance/attribution string).
- **Suspend / resume / snapshot** — a blocking syscall or fuel-yield suspends the guest via Asyncify,
  the kernel does other work, and resume continues. Snapshots capture linear memory (the Asyncify
  buffer lives there), so a guest suspended *mid-computation* survives snapshot/restore and resumes
  identically (Group G).

The port is *correct*. The remainder of this document is about *speed*.

---

## 2. The performance gap (measured)

| Workload | wasmi (Rust) | wasm3 (Zig) | ratio |
|---|---|---|---|
| `core` e2e suite | ~5 s | ~12–16 s | ~2.5–3x |
| `extended` e2e suite | (baseline) | similar | ~2.5–3x |
| `zz_bench_luau_loop` (10M-iter `for i=1,N do n=n+1 end`) | ~2.8 s | ~8.5 s (best-effort ~7.1 s) | ~2.5–3x |

The gap is uniform across compute-bound and mixed workloads. It is real and it matters.

---

## 3. Root cause: the Asyncify per-op instrumentation tax

**wasm3 is a recursive, native-C-stack interpreter.** Its execution state (the program counter `_pc`,
value-stack pointer `_sp`, registers) lives on the **native C call stack** and in CPU registers, and it
dispatches op→op by (tail-)calling the next op. This is *why wasm3 is normally one of the fastest
interpreters*: the C compiler's register allocator and calling convention do the work, and hot state
stays in registers.

But a native-stack interpreter cannot pause and resume by itself — its state is on the C stack, which
is destroyed on return. To make it suspendable we use **Binaryen Asyncify**, which instruments every
function that can be *live on the stack across a suspend* with a prologue/epilogue that can spill locals
to a side buffer (unwind) and restore them (rewind).

**The killer:** because any op can be on the native stack when a suspend fires, **every op must be
instrumented.** That prologue/epilogue runs on *every op execution* on the hot path. That per-op tax —
not code generation, not fuel, not the suspends themselves — is the ~2.5–3x. It is the structural cost
of making a native-stack interpreter suspendable.

**Contrast — why wasmi is faster for us:** wasmi is a *re-entrant, loop-based* interpreter. Its wasm
call stack is an explicit heap structure (a `Vec`), not the native C stack. It suspends by simply
*returning* from its interpreter loop and resumes by re-entering it — **zero per-op cost.** That
absence of the Asyncify tax is the entire difference. (Note: wasmi is *not* JITed either — both engines
are pure interpreters under the same wasmtime host. This is not a JIT-vs-interpreter story.)

---

## 4. The full investigation (what we tried, and the result)

All attribution was done with A/B builds (perf/`perf_event_open` was unavailable in the environment;
A/B builds isolate the inlined Asyncify tax more cleanly anyway).

| # | Hypothesis | Experiment | Result |
|---|---|---|---|
| 1 | It's unoptimized codegen | `-O3`, `-flto`, `release_fast` on the wasm3 C | **Flat** (~8.5 s). Confirmed `-O3` reached the compile. Not codegen. |
| 2 | It's fuel metering | Read the fuel patch | Fuel is charged **per call + per loop back-edge**, not per-op. Cheap. Not fuel. |
| 3 | It's the suspend *events* | Huge fuel quantum → the loop never suspends | Still ~8.5 s. The ~25 suspends were negligible; the per-op tax dominates. |
| 4 | The instrumentation can be narrowed | **M2**: instrument nothing | **Boot traps instantly** — the shell's console-block during boot needs it. |
| 5 | At least the arithmetic ops can be un-instrumented | **M3**: uninstrument `op_i32_*` etc. | **Tick traps** — proved *any* op can be live across a suspend; instrumentation is load-bearing. |
| 6 | Tail-call dispatch lets simple ops leave the stack | musttail patch + `-mtail-call` + narrow | **Partial win: 1.32x (9.4 s → 7.1 s)**, all suites green. See [§5](#5-the-tail-call-spike-and-why-it-caps-at-13x). |

The tail-call spike is committed (it is a real, verified improvement). But it hit a hard ceiling.

---

## 5. The tail-call spike, and why it caps at ~1.3x

The idea: if wasm3 dispatches op→op via **wasm tail-calls** (`return_call_indirect`), simple ops don't
accumulate on the native stack — they tail-call away. Then they're never live across a suspend and can
be *un-instrumented*, collapsing the tax.

What we did (all committed):
- Added `third_party/wasm3/patches/0002-musttail-dispatch.patch` — `__attribute__((musttail))` on
  wasm3's `nextOpDirect`/`jumpOpDirect`. (`-mtail-call` alone does **not** emit tail-calls — clang
  won't sibling-call-optimize the dispatch on its own; musttail forces it.)
- Enabled `config.wasm_tail_call(true)` on the wasmtime host.
- Extended `bazel/asyncify.bzl` and turned the no-creep gate into a real artifact check.
- Narrowed the Asyncify instrument set: moved side-effect-free ops (integer/float arithmetic,
  compares, bit ops, shifts, conversions, `op_SetRegister_*`, `op_Select_*`, `op_MemSize`) out of
  instrumentation.

**Two structural walls stopped it at 1.32x:**

1. **Binaryen Asyncify rejects tail-call opcodes as *input*.** So we could not asyncify a module that
   already contained `return_call`. The workaround was to asyncify *first*, then post-process the wasm
   (disassemble → rewrite selected dispatch calls to `return_call_indirect` → reassemble). This is a
   hack, and it constrains what can be rewritten.

2. **Asyncify's rewind is *replay*, not resume-at-pc.** On resume, Asyncify re-enters from the top and
   *replays* frames forward to the suspend point. With tail-call dispatch the ops form a **forward
   chain**, so replay **re-executes** every un-instrumented op in that chain. That is harmless for
   *pure* ops (they recompute the same value) but **corrupts anything with side effects** — the
   slot/value-stack/memory ops, which are the *bulk* of interpreter work. They had to stay
   instrumented (verified: uninstrumenting them corrupts sqlite vector paths). Hence only the
   side-effect-free minority could be freed → 1.32x.

No amount of Binaryen patching fixes wall #2, because it is Asyncify's *replay model* itself, not the
tail-call input rejection. **The asyncify route caps at ~1.3x, full stop.**

---

## 6. Why full parity with Rust is unreachable *with wasm3*

Removing the per-op tax entirely requires that **no** suspend path use Asyncify (any that does forces
every op to stay instrumented). The only alternative to Asyncify's replay is **pc-based re-entrant
suspend**: save `_pc`/`_sp`, unwind by ordinary returns, and resume by re-dispatching at the saved pc
(exactly how wasmi does it).

**That is not implementable in wasm3 without rewriting its execution core.** wasm3's `op_Call` is
*recursive*:

```c
d_m3Op (Call) {
    ...
    m3ret_t r = Call (callPC, sp, _mem, ...);   // a NESTED, RECURSIVE C call into the callee
    ...
    if (LIKELY(not r)) nextOpNoTail ();          // continues AFTER the callee returns
}
```

Every wasm function call nests a real C stack frame and continues *after* it returns. So the C stack
grows with wasm call depth, and a suspend deep in a call tree has a deep C stack that must be preserved
— which is precisely what Asyncify does. pc-based resume would require the C stack to be reconstructible
at an arbitrary pc, i.e. making wasm3 **non-recursive** (an explicit heap call stack / CPS execution
loop). That is *reimplementing wasm3's interpreter core*, at which point it is no longer wasm3.

So: **wasm3 + Asyncify caps at ~1.3x; going further means abandoning Asyncify, which means abandoning
wasm3's recursive design.**

---

## 7. wasm3 (stack-based) vs wasmi (re-entrant): the real trade-off

For a **suspendable, multi-guest, snapshottable** kernel — which is exactly what this is — wasm3's
design has no residual advantage:

| Dimension | wasm3 (recursive, native stack) | wasmi (re-entrant, heap stack) |
|---|---|---|
| Raw dispatch speed | Faster **un-taxed** (its whole reputation) | Slower un-taxed |
| **Speed *with suspend*** | **Slower** — Asyncify tax negates the dispatch edge | **Faster** — zero per-op tax |
| **Memory per guest** | **~1.5 MB**: 512 KB native stack (`STACK_SIZE`) + 1 MB Asyncify spill buffer (`ASYNCIFY_STACK_BYTES`) | **~5–10x less**: bounded heap call stack, no Asyncify buffer |
| Deep-recursion safety | Can overflow the native stack | Heap stack grows bounded |
| Code size | ~64 KB (tiny) | Larger |

wasm3's advantages (fast native dispatch, tiny size) apply only to **non-suspendable** embeddings. We
chose it because it is small C and Asyncify-able — but the Asyncify tax is *structural*, and the
recursive design also costs us **memory** (that 1.5 MB/guest is a real multi-guest cost) and
**robustness**. For our use case a re-entrant engine wins on speed **and** memory **and** robustness.

---

## 8. Decision: adopt WAMR (wasm-micro-runtime)

The re-entrant engine this document called for exists off the shelf. A source analysis of **WAMR**
(bytecodealliance/wasm-micro-runtime, **v2.4.3**) confirms it is the right foundation — it ships the
pieces §6 said we would otherwise have to invent:

- **Re-entrant by construction.** Both interpreters — classic and the faster `fast-interp` — dispatch
  a wasm `CALL` with `goto call_func_from_interp`: they push an in-memory `WASMInterpFrame` (chained
  via `prev_frame`, allocated from the exec_env's wasm stack) and continue ONE dispatch loop. There is
  **no recursive C call per wasm call** (only the multi-module / native-import special cases).
  Execution state lives in memory, not the native C stack — the wasmi model, exactly what §6 requires.
- **Suspend without a per-op tax.** `CHECK_SUSPEND_FLAGS()` — one flag (`exec_env->suspend_flags`)
  checked in the loop — is the yield hook, with **no** per-op instrumentation. The mechanism the
  Asyncify approach fundamentally could not have.
- **Fuel is built in.** `WASM_ENABLE_INSTRUCTION_METERING` + `exec_env->instructions_to_execute` bound
  execution per quantum — our fuel, native to the engine.
- **Snapshottable.** The whole execution state is the `exec_env` + its in-memory `wasm_stack` + the
  guest's linear memory. Allocate the wasm stack from the kernel allocator and snapshot stays
  copy-the-bytes, as today.
- **Small and embeddable.** Interpreter-only footprint ~59 K (comparable to wasm3); threads and shared
  memory default off (matches our single-threaded cooperative model); designed for constrained targets.
- **The freestanding port is bounded.** WAMR has no `wasm32` platform, so we write one — but the
  `os_*` surface is ~20 functions, most trivial on single-threaded wasm: cache/thread/mmap become
  no-ops or malloc-backed, `os_malloc` → the kernel allocator, `os_printf` → the console, time → the
  capability-gated clock. Larger than wasm3's libc shim, still small.

**What this buys us:** suspend becomes *save `exec_env`, return, re-enter* — zero per-op tax, so the
~2.5–3x gap closes (fast-interp is competitive with wasmi). And it **deletes the entire Asyncify
apparatus** — the `asyncify.bzl` transition, the no-creep gate, the musttail patch, the whole §7.4
boundary — the single most delicate, load-bearing part of the current port.

**Migration plan (this branch, `feature/zig`):**
1. **Vendor WAMR, remove wasm3** from the build; write the `wasm32`-freestanding platform layer; get
   WAMR compiling to `wasm32`. *(The kernel is deliberately non-building from here until step 3 — the
   engine swap precedes the driver rewrite.)*
2. **Build the WAMR-based `guest.zig` driver:** the `mc_sys_*` host-import bridge, and resumable
   suspend/resume (a blocking syscall or quantum yield via `suspend_flags` / metering: save exec_env,
   return, re-enter) + the snapshot integration.
3. **Bring `core_zig` + `extended_zig` back to green on WAMR** — now targeting wasmi **parity**, not a
   1.3x ceiling — and delete the Asyncify machinery.

The rejected alternatives (a purpose-built Zig interpreter; wasmi-in-wasm) stay in git history; WAMR
wins on least-new-code for a proven re-entrant engine. The functional work in this branch (syscalls,
fs, services, scheduler, snapshot, control channel) is engine-agnostic and carries over unchanged.

---

## 9. What is in this branch (git history)

- **Phases 1–6** — the full functional port to parity (`core_zig` 81/81, `extended_zig` 32/32).
- **The tail-call spike** — the musttail dispatch patch, `-mtail-call`, the post-Asyncify
  `return_call_indirect` rewrite, the narrowed instrument set, the wasmtime `wasm_tail_call` flag, and
  the no-creep artifact gate. A verified **1.32x** improvement (the Asyncify ceiling), all suites green.
- **This retrospective.**
- **`zz_bench_luau_loop`** — the `#[ignore]`d perf harness, for reproducing the gap in future work.

The remaining ~2x is documented above as a deliberate, understood limitation, not an open bug: it
requires a re-entrant interpreter, which is the next major decision.
