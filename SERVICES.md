# SERVICES.md — porting `sqlite` & `typst` as resident `mc` services

> **What this file is.** Standalone, self-contained guidance for porting the two big domain
> engines — **sqlite** and **typst** — into agent-os as **resident services** (the "svc" way):
> pure-`mc` wasm guests, warm between calls, packaged into flavors (`atlas`, `paper`). It folds
> together three threads that have to be understood as one: (1) the proven **WASI→mc build recipe**
> and the **C/C++/Rust gotchas** learned the hard way porting `luau`; (2) the **resident-service
> mechanism** (`svc_*` + `servicefs`); and (3) **size & assets** — the postprocess, and typst's
> ~30 MB of embedded fonts.
>
> **Who reads it.** A human or an agent about to do the port. It assumes you have *not* lived
> through the luau port, so it re-states the load-bearing lessons rather than citing them. An agent
> spawned to do a slice should be able to read *only this file* (plus VISION.md §4.5/§15.7/§16.5 and
> the code it points at) and proceed.
>
> **Hard rule.** This file is **never referenced from code** — not in a BUILD comment, not in a Zig
> `//`, not anywhere. It is meta-guidance, not a spec the code points back at. (Contrast
> `third_party/luau/SYSTEM.md`, which *is* cited from code; this one is invisible to the tree.)
>
> **Status going in.** sqlite and typst are already **proven portable to wasm in Rust** (they build
> and run as WASI tools in memcontainers). This file is not about *whether* they port; it is about
> doing it **the svc way** in agent-os: one binary, two activation modes, warm state, small image.

---

## 0. The mental model in one screen

```
  require("sqlite") ─┐                                  ┌─ one ENGINE, compiled once ─┐
  $ sqlite query …  ─┼─ svc_connect + svc_call ──▶ /svc/sqlite : resident guest ──▶ │ sqlite3*  (warm) │
  (Luau shim / CLI)  ┘   (typed bytes in, bytes out)   (its OWN Store, isolated)     └──────────────────┘

  flavor layer (atlas):  /bin/sqlite  (the one binary)        ← service+CLI, mc_service-stamped
                         /etc/mc-services.json  (name→tier/budget/eager|lazy)
                         /lib/luau/sqlite.luau  (the require() shim)
```

Three things make this worth doing instead of `spawn`-ing the tool per call:

1. **No cold-start tax.** sqlite opens the DB and warms its page cache *once*; typst loads ~30 MB of
   fonts *once*. Subsequent calls reuse warm state in the service's linear memory.
2. **One core, never two codebases.** The CLI (`/bin/sqlite`), the Luau library (`require("sqlite")`),
   and the resident loop are all **clients of the same engine**. The library can never do less than
   the command, and they cannot drift, because there is exactly one implementation.
3. **Warmth snapshots with the VM.** Because the warm DB handle / font set lives in the guest's
   **linear memory**, `vm.snapshot()` captures it. A restored VM comes back with sqlite's connection
   and typst's fonts *already warm*. A host-side process pool — outside the snapshot — cannot do this.
   This is the single property that justifies "service inside the kernel" over "pool outside it."

The cost, stated honestly: a single service **serializes its calls** (one request at a time; a second
caller busy-polls), and warm state is a **cache, not durability** (durable data is written through to
`persistfs`). Both are bounded and documented (§4.6).

---

## 1. The build spine — how any Rust/C WASI tool becomes a pure-`mc` guest

This is the recipe luau proved; sqlite and typst ride the same rails. Internalize it before touching
either engine. **Before any of it, pick the lane (§1.1) — it decides what language you write.**

### 1.1 The two ways in — which language wraps the engine

agent-os has exactly **two language lanes** for a guest, and the engine's own source language picks the
lane. This is the *first* decision, and it determines everything you write afterward:

- **Rust-native lane (the easy way in).** A Rust engine compiles against `//sysroot`, which already
  exposes the `mc_sys_*` wrappers (including the new `svc_*`). The service driver is **Rust** and calls
  the engine's Rust API directly — the same lane as the coreutils boxes. **typst takes this lane** (it
  is Rust, so the way in is direct).
- **C-API-through-Zig lane (everything not Rust).** A C or C++ engine is reached through its **C API**,
  and the wrapper/driver is **Zig** — the C/C++→Zig glue lane luau established (VISION §0.2). The Zig
  glue `@cImport`s the engine's C header, drives its C functions, and calls `mc_sys_*` through the
  hand-kept `mc.zig` extern shim (pinned to the contract by `//tools/mc-abi-gate`). For a **C++** engine
  the "route to C" is literal: its public API is forced to `extern "C"` (luau's `force_extern_c.h`) so
  the Zig `@cImport` can link it. A **C** engine is already C — `@cImport "sqlite3.h"` directly.
  **sqlite takes this lane.**

The rule, stated so it isn't violated: the driver/glue around a C/C++ engine is **never** a Rust FFI
wrapper — that would be a third, redundant lane. **C/C++ → Zig (via the C API); Rust → Rust.** Because
the `svc_*` syscalls are projected into *both* `mc.gen.rs` and `mc.gen.zig`, each lane gets a thin
`serve_loop` in its own language calling its lane's bindings — a `//sysroot`-based Rust loop, or a
`glue/`-style Zig loop reusing luau's `mc.zig` + adapter scaffolding.

| engine | source | lane | driver / glue | reaches `mc` via |
|---|---|---|---|---|
| luau | C++ | C-API-through-Zig | Zig glue, `@cImport` the Lua C API (forced `extern "C"`) | `mc.zig` extern shim |
| **sqlite** | **C** | **C-API-through-Zig** | **Zig glue, `@cImport "sqlite3.h"`** | `mc.zig` extern shim |
| **typst** | **Rust** | **Rust-native** | **Rust driver, `//sysroot`** | sysroot `mc_sys_*` wrappers |
| coreutils boxes | Rust | Rust-native | Rust, `//sysroot` | sysroot wrappers |

> **Divergence from memcontainers.** memcontainers wrapped the sqlite C amalgamation in a *Rust* crate
> (a `build.rs` + FFI). agent-os reaches the same amalgamation through the **Zig** glue lane instead, to
> keep exactly two lanes and reuse luau's scaffolding. The portability is unchanged — the amalgamation
> still compiles to wasm by `zig cc`; only the wrapper language is Zig, not Rust.

### 1.2 Patches, never a vendored copy (invariant B3)

Upstream source enters via `http_archive(urls, sha256, patches=[…], build_file=…)` in `MODULE.bazel`.
**Only our deltas live in the tree**, as real `.patch` files under `third_party/<tool>/patches/`,
each hunk tagged `// mc PATCH` so it is greppable. Never commit a patched copy of the source.

- **sqlite** is the C **amalgamation** (`sqlite3.c` + `sqlite3.h`, one giant TU). Fetch the
  amalgamation tarball; the patch set is small (a handful of WASI/`mc` accommodations — memcontainers'
  `crates/wasi/sqlite/PATCHES.md` is the inventory to port). Compiled by `zig cc` at `wasm32-wasi`.
- **typst** is a **Rust crate graph** (the `typst` compiler library + `typst-assets`). There is no
  source to patch in the luau sense; the "patch" is a thin **driver crate** you write (the `World`
  impl + the service loop) plus Cargo profile/feature choices. Built by the Rust `wasm32-wasip1`
  toolchain.

> **Gotcha that bites both:** a patch edit does **not** re-apply on the next build — Bazel serves the
> `@<tool>` repo from cache. To actually re-test a patch change you must force a clean re-fetch
> (`bazel clean --expunge` is the blunt instrument; a corrupted-patch build that still "succeeds" is
> the tell that you got the stale cache). Budget for this; it cost real time on luau.

### 1.3 The WASI lane and the adapter (the imports must become only `mc`)

A C or Rust program at `wasm32-wasi` imports `wasi_snapshot_preview1` functions (`fd_write`,
`path_open`, `clock_time_get`, …) for its libc/std runtime. The kernel does **not** speak WASI (A4:
WASI exists only as a guest adapter, never in the kernel). The `//wasi-adapter` (Rust, link-injected)
**defines** those `__imported_wasi_*` functions over `mc_sys_*`, so after linking the guest imports
**only `mc`** (0 non-mc imports). Both engines link the same adapter, exactly as luau does.

**Adapter gotchas you will re-hit (all learned on luau — do not rediscover them):**

- **Root-only preopen.** The adapter advertises **one** preopen, `fd 3 = "/"`, and that is *correct*.
  Advertising a second (`fd 4 = "."`) preopen **breaks std/libc path resolution** — wasi-libc's
  longest-prefix match goes ambiguous and the guest silently fails (empty output). sqlite and typst
  are full libc/std consumers, so this **will** bite if someone "completes" the preopen list. Leave it
  at root.
- **One fd namespace.** The adapter keeps its own fd table for the engine's libc/std IO. Do **not**
  add a *second* path for service file IO; the service's own reads (e.g. typst reading `/usr/share/fonts`,
  sqlite reading its DB file) should go through the same libc/std → adapter → `mc_sys_*` path the engine
  already uses. (luau's bug was a divergent reader; we unified it.)
- The adapter's `fd_filestat_get` must answer for the preopen fd, and `fd_renumber` must work for the
  table fds — both are implemented now; if a guest needs more wasi surface, extend the adapter, never
  the kernel.

### 1.4 Stamp + attest (conformance is a BUILD error, not a runtime check)

A finished guest wasm is **stamped** with the kernel's load-time custom sections and **attested**:

- `mc_program` (the `//third_party/luau:defs.bzl` rule, generalize/reuse it) runs **`//tools/mc-stamp`**
  to append `mc_tier` + `mc_budget` (+ `mc_service`, new — see §3.3), then **`//tools/mc-attest`** as a
  *validation action* that fails the build on a violation. Attestation enforces, from the projected
  contract:
  - **§9.3 import purity** — every import is the `mc` module **and** a *declared syscall*
    (`SYSCALL_NAMES`); a stray wasi import or a typo'd `mc::mc_sys_bogus` fails the build.
  - **§16.4 tier fit** — each imported syscall's cap-floor ⊆ the declared tier's caps. A service that
    needs `CAP_PERSIST` (sqlite's DB file) or `CAP_FS_READ` (typst's fonts) must declare a tier that
    grants it, or the build fails.
- **Resource discipline** (the luau rule, apply it in any binding you write): an OOM or a resource
  limit is a **catchable error**, never a trap, a silent wrong answer, or unbounded growth.
- The hand-kept `extern "mc" fn` surface (if you add one for the new `svc_*` syscalls in a non-Rust
  shim) is pinned to the contract by the **`//tools/mc-abi-gate`** pattern — a drift fails the build.

---

## 2. Language gotchas: C (sqlite) vs Rust (typst) — and why neither needs luau's trap machinery

This is the single most important *simplification* to carry in. luau's hardest, ugliest work was the
**kernel trap-unwind** for C++ exceptions: `wasmi` has no wasm-EH proposal, zig's wasi-libc++ ships no
C++ exception runtime, and Lua `error`/`pcall` plus C++ `throw`/`catch` had to be rerouted through a
kernel re-entry shim (the four patches, `trap.zig`, `error_channel.h`, `analysis_eh_shim.h`,
`__mc_pcall_run`/`__stack_pointer`). **None of that applies to sqlite or typst. Do not cargo-cult it.**

- **sqlite (C) — no C++ EH at all.** sqlite signals failure with **return codes** (`SQLITE_*`) and
  uses `setjmp`/`longjmp` *internally* for OOM recovery. wasi-libc provides `setjmp`/`longjmp` (a wasm
  implementation), and those jumps are **in-guest** — they never cross the kernel boundary, so the
  trap-unwind is irrelevant. sqlite is the *easy* one: a normal C library with an error-code API.
- **typst (Rust) — `panic = abort`.** With `panic = "abort"` there is no unwinding to reroute; a panic
  **aborts the guest**. And that is *exactly the recovery model a service wants*: a panicking typst
  service traps → the task exits → its `SvcServe` fd drops → the channel closes → the in-flight caller
  gets **`EIO`** → the supervisor **re-activates** a clean instance (§4.5, VISION §15.7). **Crash-only
  is the EH story for Rust services.** No EH patches, no shim.

So the per-language posture:

| | luau | sqlite | typst |
|---|---|---|---|
| language | C++ | C | Rust |
| lane (§1.1) | Zig-through-C | **Zig-through-C** | **Rust-native** |
| failure model | C++ EH + Lua pcall | return codes + internal longjmp | `panic = abort` |
| needs kernel trap-unwind? | **yes** (the hard part) | **no** | **no** |
| recovery | re-enter via `__mc_pcall_run` | error codes to caller | **crash-only service restart** |

The lesson: the heavy luau machinery was a property of *embedding a language with exceptions*, not of
"porting a C/C++ engine." sqlite/typst are ordinary libraries; the *only* recovery primitive you need
is the service supervisor.

A couple of smaller C/Rust gotchas that do carry:

- **Variadic / C-ABI edges** (sqlite has a few): a variadic `open()`-style call must be expressed in C,
  not faked with a Zig/Rust extern — but for sqlite you are calling its C API directly, so this is moot;
  just keep the driver thin.
- **`mc_sys_exit` import type** (a luau scar worth knowing): the contract may *say* `noreturn`, but the
  kernel registers exit as `(i32) -> i32`; declaring it `noreturn` changes the wasm import *type* and
  the kernel rejects the guest at spawn (`EINVAL`). If you hand-declare any `mc_sys_*` extern, match the
  kernel's registered signature, and let `//tools/mc-abi-gate` catch drift.

---

## 3. The svc mechanism — a new primitive on plumbing we already have

The resident-service design is memcontainers' `ctx/SERVICES.md`, **adopted by VISION §4.5** with one
deliberate departure (§3.3). The reason it transfers cleanly is that our Rust kernel is a faithful port
that **already contains every piece of plumbing the design reuses** — only `servicefs` + the five
`svc_*` syscalls are missing (that is the work):

| the design reuses… | present in `kernel/rust/src`? |
|---|---|
| `servedfs` channel mechanics (request queue + response map + `closed` + cooperative re-poll) | ✅ (and `mc_sys_serve`/`serve_recv`/`serve_respond` already in `contracts/syscalls.kdl`, `group="service"`) |
| `host_call` readable-result streaming (for a `svc_call` that returns a `ret_fd`) | ✅ |
| `mountfs` registry pattern (for the `ServiceRegistry`) | ✅ |
| the `BuiltinStep::Pending` cooperative re-poll dance | ✅ |
| `GuestFd` + snapshot/restore (warm state in linear memory) | ✅ |
| `servicefs` / `svc_connect` / `svc_call` / … | ❌ — **build this** |

### 3.1 The five syscalls go in the contract, not a macro

memcontainers adds the syscalls to a Rust `mc_syscall_table!` macro. **We add five rows to
`contracts/syscalls.kdl`** — right next to the existing `mc_sys_serve`/`serve_recv`/`serve_respond`
(`group="service"`) — and the projector emits `mc.gen.{rs,zig,ts}`. The contract is the single source of
truth (the whole point of agent-os). Shape (client `connect`/`call`, server `serve`/`recv`/`respond`):

- `svc_connect(name_ptr, name_len, ret_fd)` — open a **session** to `/svc/<name>`, returns a connection fd.
- `svc_call(fd, req_ptr, req_len, handles_ptr, nhandles, ret_fd)` — a typed request + optional delegated
  handles → a **readable `ret_fd`** the caller drains (so a big result — a typst PDF, a sqlite cursor —
  **streams and yields cooperatively** like a `host_call` result).
- `svc_serve(name_ptr, name_len, ret_fd)` — register a name; one per service.
- `svc_recv(fd, buf, buf_len, hbuf, hbuf_len, ret_len)` — receive `[session][req_id][blob]` + delegated
  fd numbers in `hbuf`.
- `svc_respond(fd, session, req_id, status, data_ptr, data_len)` — answer; `session` is explicit because
  one service interleaves responses across many sessions.

Teardown reuses `mc_sys_close`. Bump the ABI **minor** (additive only). The exhaustive `fulfill` match
won't compile until you wire five `fulfill_svc_*` arms — the intended drift guard.

### 3.2 `servicefs` — session-keyed, modeled on our `servedfs`

New `kernel/rust/src/fs/servicefs.rs`, structured like `servedfs.rs` but with the **one real
correction**: route by **session**, not by caller. `servedfs` dedups by `CallerId` on the assumption of
one in-flight request per caller; a *connection* (not a caller) is the unit here — a caller may hold two
sqlite connections — so `inflight` moves to per-session state. The `ServiceRegistry` is a static keyed
`name → Rc<RefCell<ServiceChannel>>`, exactly like the mount registry, so it lives in kernel linear
memory and **is captured by snapshot**. A per-tick maintenance pass evicts sessions whose caller died.

### 3.3 ONE binary, two activation modes (where we depart from SERVICES.md)

memcontainers ships **two** binaries per tool: `/bin/<tool>-svc` (the resident loop) + `/bin/<tool>`
(the thin CLI). **VISION §4.5 rejects this** — it doubles the `/bin` surface and leaks an implementation
mode into the user-visible namespace. agent-os ships **one binary** whose **service-capability is a
property, not a second artifact**:

- the tool is built once (`mc_program` → one `.wasm`);
- an **`mc_service` custom section** is stamped alongside `mc_tier`/`mc_budget` (extend the stamper);
- an `/etc/mc-services.json` entry (name → tier → budget → `eager|lazy`);
- the **kernel chooses the entry point by the contract**: it enters the generated `svc_serve` loop for
  resident mode, or `_start` for a one-shot CLI invocation — *not* by `argv[0]`.

So the "three faces, one core" is: **resident loop** (svc_serve path) · **CLI** (`_start`, which itself
`svc_connect`s + `svc_call`s the warm instance) · **`require("<tool>")` shim**. All three drive the same
engine; there is no `-svc` binary.

### 3.4 Authority handed over, never assumed (handle delegation)

A `svc_call` may carry a few of the **caller's own fd numbers** (`handles_ptr`/`nhandles`). The kernel
clones the backing `Rc` and installs it into the **service's** fd table under fresh numbers (SCM_RIGHTS:
shared object, per-process descriptor). The service gains *exactly* those open objects — no path, no
namespace entry, no capability. Only a delegatable subset (`File`, `PipeRead`, `PipeWrite`) is allowed;
a net/service/serve fd is refused (`EINVAL`) so you cannot launder egress into a callee. Use case:
`$ sqlite import < data.csv` delegates **stdin** to the service, which reads the CSV straight from the
handle without any ambient FS reach.

### 3.5 Warm state, snapshot, crash-only

- **Warm state is heap.** sqlite's `sqlite3*` + page cache, typst's `FontBook` + `World`, live in the
  service's linear memory. Snapshot captures **linear memory only** (not wasm globals/tables), so warm
  state survives a snapshot **iff** it is heap (it is) **and** the service is at a **clean rest point** —
  blocked in `svc_recv`, no live wasm stack — when the snapshot is taken. The service loop idles in
  `svc_recv` precisely to guarantee this. A pure guest↔guest `svc_call` holds no host handle, so it does
  not pin egress and does not block snapshots.
- **Warm ≠ durable.** A crash loses warm state. Durability is **write-through to persistfs**: sqlite's
  DB *file* lives under `/var/persist` (gated on `CAP_PERSIST`); the warm `sqlite3*` is just an open
  handle over it. State the contract so nobody mistakes warmth for persistence.
- **Crash-only (VISION §15.7).** A service trap / over-budget kill drops its `SvcServe` fd → the channel
  closes → every pending/new call resolves to **`EIO`** → a lazy service is **re-activated** on the next
  `svc_connect` (the caller reconnects, gets a clean instance). The callee dies alone; it never unwinds
  into the caller or the kernel. For typst this is the entire panic-recovery story.

### 3.6 The honest limits

- **Serialization.** One service = one `serve_loop` = one request at a time. A second caller busy-polls
  (the `Pending` re-queue) until the first response lands — the same way every `servedfs` caller already
  waits. Per-service throughput is the cap; pooling is a later phase.
- **Busy-poll cost.** There is no true block; awaiting a call re-polls each scheduler round. Real, but
  the system's existing accepted idiom. (Heavy compiles do **not** monopolize the scheduler — every
  guest preempts per `FUEL_QUANTUM` since the eager-compilation fix; the old single-slice monopoly is
  resolved.)

---

## 4. Size & assets — the postprocess, and typst's 30 MB

### 4.1 The wasi postprocess (deferred until the userland port is "done", then applied)

The size-optimization pass for the wasi guests/boxes, deliberately **deferred** until the userland is
ported so it is one pass over the set that dominates the win (rather than re-tuning per incrementally-
ported tool):

- **`opt-level = "z"`** (aggressive size; the kernel itself runs `s` + LTO + `panic=abort`, line 117 of
  VISION — the boxes go further to `z`),
- **`panic = "abort"`** (no unwinding tables; also the correct service-recovery model, §2),
- **`strip`** the symbols (memcontainers does `-Wl,--strip-debug`; we strip fully).

luau already ships `release_small` via its `zig_configure_binary`, so this pass is really about the Rust
boxes **and typst**. Wire it as a build profile / transition; verify the size with `//tools/size`-style
budgets (B5: size is a test and a lever).

### 4.2 typst is ~30 MB because it **embeds** its fonts — and that is separable

This is the important one. typst's binary size is dominated by the **default font faces** the
`typst_assets` crate embeds via `include_bytes!` (Linux Libertine, New Computer Modern, DejaVu, …) —
tens of MB of `.ttf`/`.otf`. The engine *code* is a few MB; the rest is fonts.

**The hook to separate them already exists.** typst loads fonts through its `World::book`/`World::font`;
the proven WASI driver's `load_fonts()` loads **the embedded baseline `typst_assets` faces *plus* a
recursive scan of `/usr/share/fonts`** for any `.ttf`/`.otf`/`.ttc` dropped into the VFS. So the
separation is mechanical:

1. **Stop embedding** the `typst_assets` baseline (drop the dependency / disable the embed feature so the
   binary no longer carries the font bytes).
2. **Ship the baseline faces as files** under `/usr/share/fonts` in the **paper flavor's asset layer**
   (a `pkg_tar`). `load_fonts()` finds them via the existing scan.
3. The binary drops from ~30 MB to ~the engine size; the fonts become a **content-addressed layer**.

Why this is the right system design, not a hack:

- **Assets are content, not code.** The same content/code split as the Luau batteries (universal stdlib
  embedded in the interpreter) vs flavor `.luau` libs (VFS layers): *code* is the binary, *assets* are
  layered VFS content. Fonts are assets.
- **Dedupe + determinism.** A content-addressed font layer is stored once and shared by every flavor
  that references it; generate it with the fixed image mtime so content-addressing stays stable.
- **It composes with the warm service.** The typst **service** scans `/usr/share/fonts` **once at boot**
  into a warm `FontBook` in linear memory; every compile reuses it; **snapshot captures the warm fonts**.
  So: small binary (no embedded fonts) + a font layer (read once) + warm `FontBook` (fonts loaded once) +
  snapshot (fonts survive restore) all reinforce each other. The font layer is read at boot, not per
  call; the warmth lives in the heap.
- **Tier implication.** The typst service needs `CAP_FS_READ` on `/usr/share/fonts`; declare the tier
  accordingly so attestation (§1.4) passes.

> This generalizes: **any** engine with big embedded assets (templates, ICU data, model weights) should
> separate them into a VFS layer the warm service reads once — never bake megabytes of data into the
> code artifact.

---

## 5. Flavor packaging — `atlas` (sqlite) and `paper` (typst)

A service ships as content in its flavor's `pkg_tar` layer, composed on top of `loom`:

- **`atlas` = loom + sqlite.** Layer: `/bin/sqlite` (the one binary, `mc_service`-stamped) ·
  `/etc/mc-services.json` (`sqlite → tier/budget`, `lazy`) · `/lib/luau/sqlite.luau` (the `require()`
  shim — `sys.svc.connect("/svc/sqlite")` + `:call`). `require("sqlite")` returns a warm connection;
  `$ sqlite query …` hits the same engine.
- **`paper` = loom + typst.** Layer: `/bin/typst` · `/etc/mc-services.json` (`typst → tier/budget`) ·
  `/lib/luau/typst.luau` · **the font asset layer** at `/usr/share/fonts`. `require("typst").compile(src)`
  returns PDF bytes from a font-warm engine.

`mc-services.json` is **per-flavor**, a fragment merged by the layer stack (§16.5), never a global file.
The shim name must **not** collide with a universal embedded battery (`json`, `path`, …); `sqlite`/`typst`
are not embedded, so they load from the layer (`require` order is cache → embedded → VFS).

---

## 6. The porting playbook

### 6.1 Order: do `sqlite` first (the clean vertical slice), then `typst`

sqlite is the simpler engine (C, error codes, no fonts) and exercises the *whole* svc path end to end.
Land it before typst so the kernel `svc_*` work, `servicefs`, the stamper's `mc_service` section, and the
flavor packaging are all proven before you add typst's size/asset complexity.

### 6.2 sqlite — step by step

1. **Kernel first, language-agnostic.** Add the five `svc_*` rows to `contracts/syscalls.kdl`; regenerate;
   write `kernel/rust/src/fs/servicefs.rs` (session-keyed, modeled on `servedfs`); wire five
   `fulfill_svc_*` arms + the `GuestFd` variants + the `Pending` dance; add the `ServiceRegistry`. Bump
   ABI minor. Prove it with a trivial in-tree **`kv`** service (a warm `BTreeMap`) reached as both
   `$ kv get k` and `require("kv").get(k)` — *that* is P1's exit criterion, no engine yet.
2. **Stamp + manifest.** Extend `//tools/mc-stamp` to append `mc_service`; teach `mc_program` to carry it;
   add the `/etc/mc-services.json` plumbing (lazy activation: first `svc_connect` spawns the binary in
   service mode via the existing `Blocked → re-arm` spawn transparency).
3. **The engine.** Fetch the sqlite amalgamation via `http_archive` + the (small) WASI/`mc` patch set
   (port `crates/wasi/sqlite/PATCHES.md`); `zig cc` to `wasm32-wasi`; link `//wasi-adapter` → pure `mc`.
4. **The service driver — ZIG glue (the luau lane, §1.1), not Rust.** sqlite is C, so `@cImport
   "sqlite3.h"` and write the loop in **Zig**, reusing luau's `mc.zig` extern shim + the wasi-adapter
   link. A thin `serve_loop` opens the DB **once** (warm `sqlite3*` over a `/var/persist` file), then
   `svc_recv` → decode `{op,sql,…}` → drive `sqlite3_prepare`/`sqlite3_step` on the warm handle →
   serialize rows → `svc_respond`. The `_start`/CLI face (the *same* Zig binary) parses argv and
   `svc_connect`s the same instance. Both call the one engine. (Do **not** wrap sqlite in a Rust crate —
   that is the third lane the rule in §1.1 forbids.)
5. **The shim** `/lib/luau/sqlite.luau`: `sys.svc.connect` + `:call(json.encode{op="query",…})`,
   `json.decode` the result.
6. **Tier + attest.** Declare the tier (needs `CAP_PERSIST` for the DB file); `mc-attest` must pass
   (0 non-mc imports, tier fit).
7. **Flavor.** `atlas` `pkg_tar`: the binary + manifest fragment + shim. e2e against the real kernel
   (no mocks): a warm connection answers two queries without re-opening; a forced crash gives the caller
   `EIO` and a reconnect gets a clean instance.

### 6.3 typst — step by step (adds size & assets)

1. **Reuse the kernel/svc machinery** sqlite proved (no new kernel work beyond a tier that grants
   `CAP_FS_READ` on `/usr/share/fonts`).
2. **Separate the fonts (§4.2).** Build typst **without** the embedded `typst_assets` baseline; ship those
   faces as a content-addressed `/usr/share/fonts` layer. Confirm the driver's `load_fonts()` finds them
   via the recursive scan (the World impl is the one from the proven WASI port — keep it).
3. **Build + adapter.** Rust `wasm32-wasip1`; link `//wasi-adapter` → pure `mc`. Apply the **postprocess**
   (`opt-level=z`, `panic=abort`, `strip`) — this is where it matters most; check the size budget.
4. **The service driver — RUST (the native lane, §1.1).** typst is Rust, so the driver is a Rust
   `serve_loop` over `//sysroot`, calling typst's Rust compile API directly (the easy way in — no glue
   language). Build the `World` + scan fonts **once** (warm `FontBook`/`World`), then `svc_recv` →
   compile source → stream the PDF bytes back via the `ret_fd` (the `host_call`-style streaming so a big
   PDF yields cooperatively). A panic aborts the guest → crash-only restart (§3.5) — no EH handling.
5. **Shim + flavor.** `/lib/luau/typst.luau` (`compile(src) → PDF bytes`); `paper` `pkg_tar` = the binary
   + manifest + shim + the font layer. e2e: a compile reuses warm fonts (the second compile is fast); the
   binary is small and the fonts live in their own layer.

---

## 7. Pitfalls & pre-flight checklist

- [ ] **Pick the lane first (§1.1):** Rust engine → Rust driver over `//sysroot` (typst); C/C++ engine →
      **Zig glue** via the C API (sqlite = `@cImport "sqlite3.h"`, reusing luau's `mc.zig` + adapter).
      Never a Rust FFI wrapper around a C engine — that's the forbidden third lane.
- [ ] **Don't reach for luau's trap-unwind.** sqlite (C, error codes) and typst (Rust, `panic=abort` +
      crash-only) need none of `trap.zig` / `error_channel.h` / `analysis_eh_shim.h` / `__mc_pcall_run`.
- [ ] **Leave the adapter at one preopen (`/`).** A second `"."` preopen breaks std/libc path resolution.
- [ ] **Route service file IO through the engine's libc/std → adapter path.** No second fd namespace.
- [ ] **Five `svc_*` rows in `contracts/syscalls.kdl`**, projected — never a per-language macro.
- [ ] **`servicefs` is session-keyed**, not caller-keyed (the one real change from `servedfs`).
- [ ] **ONE binary, two activation modes** — `mc_service` section + `/etc/mc-services.json`, not a `-svc`
      binary, not `argv[0]` dispatch.
- [ ] **Quiesce-clean snapshots:** the service idles in `svc_recv`; warm state is heap.
- [ ] **Warm ≠ durable:** write durable data through to `persistfs`.
- [ ] **typst: separate the fonts** into a `/usr/share/fonts` layer; do not ship a 30 MB binary.
- [ ] **Apply the postprocess** (`opt-level=z`, `panic=abort`, `strip`) and check the size budget.
- [ ] **0 non-mc imports + tier fit** — `mc-attest` must pass; declare `CAP_PERSIST` (sqlite) /
      `CAP_FS_READ` (typst fonts) in the tier.
- [ ] **A patch change needs a clean re-fetch** to take effect (`@<tool>` is cached).
- [ ] **This file is never referenced from code.**

> **Phasing (mirror SERVICES.md's plan, agent-os-targeted):** P1 the `kv` vertical slice (all faces, warm
> state, crash→EIO) → P2 handle delegation → P3 streaming/cursor → P4 multi-session → P5 lazy activation +
> supervision → **P6 sqlite-as-service, then typst-as-service (fonts separated, postprocess applied)**.
> Land sqlite end-to-end before typst.
