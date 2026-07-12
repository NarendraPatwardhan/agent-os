# AgentOS — Systems Analysis

> A thorough, ground-truth analysis of AgentOS: what each system *is*, *why* it is shaped the
> way it is, *how* it works, and the invariants it upholds. This document is the single design
> reference for the project. It is self-contained: it defines its own vocabulary, states the
> constitution it is judged against, and cites the code by the *names* of things (line numbers
> drift; the names do not — search for the cited symbol). It is written to be read front-to-back
> by a newcomer and mined section-by-section by someone extending one subsystem.
>
> **Status.** This is a design contract, not a changelog. If a change to the system contradicts a
> section here, the section wins — change the system, or change this document in the same commit
> and say why. The core — the kernel, the contracts, the userland, the warm domain engines — is
> built and green. The Rust kernel, JavaScript host and SDK, browser workbench, and Elixir/OTP control-plane library
> are built and tested. The completed Zig-kernel experiment is archived on `feature/zig`; Rust is the
> sole kernel in `develop`.

---

## 0. Executive summary

AgentOS is **a self-contained Unix that lives inside a single WebAssembly module.** The operating
system — process table, scheduler, virtual filesystem, pipes, networking, inter-process services —
compiles to `wasm32` and runs as one `kernel.wasm`. It hosts *guest* programs (a shell, coreutils, a
Luau interpreter, SQLite, a typst compiler) which are themselves wasm modules, executed inside the
kernel by an embedded `wasmi` interpreter. A thin, untrusted **host** (native via wasmtime, or
JavaScript locally under Node.js or Bun, or in the browser) loads the kernel, supplies a tiny set of effect primitives, and ticks it
forward.

The thesis, in one line: **the agent's entire computer is a portable, deterministic, snapshottable
value.** Because all mutable state lives in linear memory, a host can pause, fork, migrate, or resume
a running agent by copying bytes — no kernel cooperation needed. Because the only nondeterminism
(clock, entropy) is capability-gated, the same inputs produce the same outputs, which makes
record/replay and differential testing exact. Because the kernel speaks exactly one ABI to guests and
one bridge to hosts — both generated from language-neutral contracts — nothing can drift, and any
wasm-targeting language can be a guest.

Three properties make this more than a toy:

1. **Containment, not redaction.** A guest never receives a host object. A kernel file descriptor is
   not a host fd; a kernel pid is not a host process. The guest inhabits a *different computer*, not a
   filtered view of ours.
2. **Capabilities only ever narrow.** Authority is an 8-bit set computed at exec as
   `parent ∩ binary ∩ requested`. A child can never hold more than its parent. Default is deny; egress
   is gated and a denial surfaces as an in-kernel `EPERM`, never a host exception.
3. **Warm tools as libraries.** A heavy engine (SQLite, a type-checker, a document compiler) runs once
   as a *resident service* with its state warm in linear memory; `require("sqlite")` in a script and
   `/bin/sqlite` on the command line are the same binary, never two codebases that drift — and the
   warmth survives a snapshot.

**The synthesis, and why it is shaped this way.** AgentOS is engineered as a deliberate synthesis of
two ancestors, sequenced for low risk (the full argument is §2.4):

- A *mature* Rust wasm-microkernel (the lineage called **memcontainers**) supplies the system design,
  the discipline, and proven implementations: the tiny frozen ABI defined once and projected
  everywhere, the capabilities that only narrow, the no-mocks testing rule, and the network/browser
  edge and domain engines. Its one weakness was the *build* — an imperative orchestrator with
  stale-artifact hazards, hand-staged images, and checked-in vendored libraries.
- An *early* Zig port (the lineage called **zmc**) proves the hard part of a smaller kernel works: a
  Zig kernel compiled to `wasm32`, driving guests through `wasmi` compiled to wasm and linked in as a
  C-ABI shim. It supplied evidence for the later archived experiment, not the shipped kernel.

AgentOS keeps the design, puts *everything* on a zero-staleness Bazel build graph with the ABI lifted
into language-neutral contracts, and ships the proven Rust kernel. Zig remains the C/C++ guest
toolchain and guest-sysroot language. A separate Zig-kernel experiment reached functional parity but
did not replace Rust because its interpreter cost outweighed the binary-size win; §14.3 records that
decision without treating archived source as part of the live tree.

---

## 1. The systems at a glance

AgentOS is built from a small number of countable systems. The rest of this document is roughly one
section per row. Paths are given in the repository's restructured layout (§15): the OS we author lives
under `memcontainers/`, the build machinery under `bazel/`.

| # | System | Role | Where | Status |
|---|---|---|---|---|
| 1 | **Contracts / ABI projector** | The single source of truth for every boundary; generates bindings for every language | `memcontainers/contracts/` | built |
| 2 | **Kernel: process & scheduler** | Tasks, capabilities, tiers, cooperative scheduling, signals, job control | `memcontainers/kernel/rust/src/task/` | built |
| 3 | **Kernel: wasm runtime** | Runs guests in `wasmi`; fuel, budgets, the syscall suspend/resume dance, pcall | `memcontainers/kernel/rust/src/wasm/` | built |
| 4 | **Kernel: VFS & namespaces** | Plan-9 per-process mount tables; the filesystem trait | `memcontainers/kernel/rust/src/vfs/` | built |
| 5 | **Filesystem backends** | memfs, cowfs, overlayfs, tarfs, persistfs, procfs, envfs, devfs, netfs | `memcontainers/kernel/rust/src/fs/` | built |
| 6 | **IPC: pipes** | Ref-counted ring-buffer pipes for real pipelines | `memcontainers/kernel/rust/src/ipc/` | built |
| 7 | **Served filesystems** | A guest can *be* a filesystem (9P-style) over the VFS | `…/src/fs/servedfs.rs` | built |
| 8 | **Resident services** | Warm, typed cross-guest request/response engines under `/svc` | `…/src/fs/servicefs.rs` | built |
| 9 | **Networking** | Host-terminated HTTP/WebSocket; `/net` file tree | `…/src/net/`, `…/src/fs/netfs.rs` | built |
| 10 | **Host-call & proxy** | Opaque host-backed calls; the shared proxy ABI for served/mounted fs | `…/src/host_call.rs`, `…/src/fs/proxy.rs` | built |
| 11 | **Snapshots & determinism** | `(memory)` capture/restore; quiescence; the seal | `…/src/{persist,seal,sync}.rs` + host | built |
| 12 | **Guest sysroot & WASI adapter** | The guest side of the ABI (Rust + Zig); WASI→mc shim | `memcontainers/sysroot/`, `memcontainers/wasi-adapter/` | built |
| 13 | **Conformance & attestation** | Build-time import-purity + tier-fit gates | `memcontainers/conformance/`, `bazel/tools/mc-attest` | built |
| 14 | **Shell** | An OS-agnostic POSIX-ish Zig shell engine driving `/bin/sh` | `memcontainers/shcore/`, `memcontainers/programs/sh/` | built |
| 15 | **Userland `/bin`** | Multicall coreutils, partitioned by tier | `memcontainers/programs/coreutils/` | built |
| 16 | **Luau scripting** | The primary user-facing language; embedded + VFS batteries | `memcontainers/programs/luau/` | built |
| 17 | **Domain engines & adapters** | Heavy engines plus the shared tool-adapter service | `memcontainers/programs/{sqlite,typst,adapters}/`, `memcontainers/lib/parse/` | built |
| 18 | **Images, flavors & packages** | Content-addressed layered images; demand-loaded packages | `memcontainers/images/`, `memcontainers/pkgcore/`, `bazel/tools/mc-roster` | built |
| 19 | **Host (wasmtime)** | Loads `kernel.wasm`, supplies the bridge, ticks, performs effects | `memcontainers/hosts/wasmtime/` | built |
| 20 | **Control, network & browser edge** | Elixir actor-per-VM core, wire contract/client, JS host family, SDK, and web app | `server/`, `memcontainers/hosts/js/`, `memcontainers/sdk-js/`, `web/` | built; served HTTP/WS adapter remains external |
| 21 | **Build & test** | Bazel zero-staleness graph and no-mocks e2e | `MODULE.bazel`, `bazel/`, `memcontainers/tests/` | built |

The implementation spans Rust (kernel and wasmtime host), Zig (shell, coreutils, and guest glue),
TypeScript (JS host, SDK, and browser UI), Elixir (control plane), Luau (scripting batteries), the
language-neutral contracts, and the Bazel graph.

---

## 2. Foundations: the model and its constitution

### 2.1 Three layers, four contracts, one binary

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │ HOST  (a driver, not a participant)                                    │
   │   Rust/wasmtime · JS/local (Node·Bun) · JS/browser ─ all load SAME ┐   │
   └─────────────────────────────┬───────────────────────────────────┐ │   │
            env bridge            │       mc_ctl_* control channel     │ │   │
   ┌─────────────────────────────▼───────────────────────────────────▼─▼─┐ │
   │ kernel.wasm                                                          │ │
   │   scheduler · capabilities · VFS + namespaces · pipes · services·net │ │
   │   runs guests via an embedded wasmi interpreter over the mc syscall  │ │
   │   ABI:   GUEST = /bin/sh, coreutils, luau, sqlite, typst (Rust·Zig·C)│ │
   └──────────────────────────────────────────────────────────────────────┘ │
   SERVED HOST ADAPTER ── wire protocol ──> SDK / clients (TS) ──────────────┘
```

The runtime nesting is **host → kernel.wasm → wasmi → guest.wasm**, with a fourth, kernel-mediated
`pcall` level for C/C++ guests that need non-local exit. Three roles:

- **Host** — *drives* the kernel. It loads `kernel.wasm`, implements a tiny bridge of effect
  primitives, and calls `mc_tick` in a loop. The host is deliberately dumb: it performs effects the
  kernel asks for and never makes policy. The same `kernel.wasm` runs identically under a
  Rust/wasmtime host and a JavaScript host — *two host families, one binary.*
- **Kernel** — *is* the OS. It compiles to `wasm32` and never runs natively, not even for tests. It
  owns the process table, scheduler, VFS, pipes, services, and the syscall surface, and it runs guests
  inside `wasmi`.
- **Guest** — a user program run *inside* the kernel. Any language that targets wasm32 can be a guest;
  today that is Rust (shell, coreutils, typst), C/C++ (Luau), and C (SQLite).

The kernel exposes **four frozen boundaries**, every one generated from a contract:

| Boundary | Module | Direction | Purpose |
|---|---|---|---|
| **syscall** | `mc` | guest → kernel | the `mc_sys_*` calls a guest makes |
| **bridge** | `env` | kernel → host | the only imports the kernel has — terminal, time, net, persist, host-call |
| **control** | `mc_ctl_*` | host → kernel | lifecycle (`mc_init`/`mc_tick`), VFS control, snapshot/quiescence |
| **wire** | — | server ↔ client | the framed protocol an outer server speaks to clients |

### 2.2 First principles (the invariants cited in code)

The system is governed by numbered invariants that appear by name in the source. They are the
constitution; a change that contradicts one is wrong, not clever. Three families: **A** (the OS model,
binding on every kernel implementation), **B** (the build, the staging, the parity discipline), and
**C** (how the code itself is written).

**A-invariants — the OS model:**
- **A1 — Self-contained.** The agent's Unix lives in wasm linear memory; a kernel fd is not a host fd,
  a kernel pid is not a host process.
- **A2 — WASM only.** The kernel compiles to and runs on wasm exclusively. Never native, not even for
  tests.
- **A3 — Two host families, one binary.** Rust and JS hosts load the same `kernel.wasm` and behave
  identically.
- **A4 — The bridge is the only surface.** The kernel imports no symbol outside the `env` bridge — no
  WASI, no bindgen, no Component Model.
- **A5 — No native side effects.** Every observable effect flows through a bridge import; the kernel is
  a pure function of host inputs.
- **A6 — Freestanding.** `no_std` (Rust) / freestanding (Zig); may allocate; depends on no host
  filesystem and no C runtime. A guest pointer is an offset into the guest's own linear memory.
- **A7 — Deterministic by default.** Same host inputs → same host outputs; nondeterminism only via
  `CAP_AMBIENT`.
- **A8 — Snapshottable.** All mutable state is in linear memory; capture it to pause/fork/resume.
- **A9 — Capability-gated egress.** Any bridge import reaching outside is gateable; denial surfaces as
  an in-kernel error, never a host exception. Default-deny.

Derived rules also cited in code: *single source of truth per boundary*, *containment over redaction*,
*everything is a file*, *fail-closed*.

**B-invariants — the build & migration discipline:**
- **B1 — One build graph, zero staleness.** Every artifact is a Bazel target with declared inputs; a
  test `data`-depends on the exact kernel its sources produce. No "did you rebuild?": there is
  `bazel test //...`.
- **B2 — Contracts are language-neutral and projected into every language.** Drift is a failed diff
  test. All projections (Rust kernel, Zig shims, TS client) have a consumer from day one, so the
  projector is exercised across every language immediately.
- **B3 — Vendor less, patch in place.** Third-party source enters via `http_archive` + patches; only
  patch files and Zig glue live in-tree.
- **B4 — Hermetic toolchains.** Rust, Zig, and JavaScript toolchains are pinned in Bazel. No host fonts, no
  host browser, no tool from `$PATH`.
- **B5 — Size is a test and a lever.** Each `kernel.wasm` carries a size budget; per-guest budgets are
  enforced at exec.
- **B6 — Real artifacts only.** No mocks; drive the real kernel through a real host against the real
  internet.
- **B7 — Many implementations, one contract, parity-gated.** A kernel implementation ships only when it
  matches the others bit-for-bit on the shared suite. Two implementations of one contract is also a
  contract-ambiguity detector — anything the spec left underspecified shows up as a parity diff.

**C-invariant — authoring discipline:**
- **C1 — Design first; write code that teaches.** Because the system is built as much by agents as by
  people, *how* the code is written is load-bearing. Before changing a subsystem, reason from first
  principles about the qualities that bear on *this* change — almost always some of robustness (never
  trap the host, never corrupt a snapshot, fail closed), extensibility (a new filesystem, syscall, or
  service slots in without touching the core), small surfaces (a few countable primitives beat clever
  ones), and determinism/testability (it must stay replayable and parity-checkable). Name the qualities
  you optimized for and justify the shape against this constitution *in the change itself*. Then write
  it literately: code whose names, structure, and comments explain the *why* — the alternative weighed,
  the invariant upheld, the failure stated before the grant. This document carries the system's global
  "why"; every file carries its local "why," so the next reader (often another agent) can extend it
  without re-deriving it. A clever line with no rationale is a defect; a well-named, well-explained
  boundary is the unit of progress. If a pattern you reach for contradicts the constitution, the
  principle wins — escalate, do not bend it silently.

### 2.3 The three orthogonal axes of a task

Identity, namespace, and capability are kept strictly separate — conflating them is the classic source
of privilege bugs.

- **Identity** — *who is acting?* A pid (`TaskId = u32`). Not authority.
- **Namespace** — *what can it see?* A Plan-9-style per-process, copy-on-write mount table that forks on
  spawn. Not capability.
- **Capability** — *what can it do?* An 8-bit set plus an optional confinement root, computed at exec as
  `parent ∩ binary ∩ requested`, monotonically narrowing.

### 2.4 The synthesis, and why the kernel remains Rust

The Rust lineage is a battle-tested, memory-safe wasm microkernel with thousands of lines of proven
code. Porting it reused that code, kept `wasmi` as a native Rust crate with no C seam, and reached a
stable, fully-Bazelized system quickly. A later Zig experiment validated the contracts and achieved a
smaller binary, but its interpreter overhead lost on runtime performance. Rust therefore remains the
shipped kernel; the experiment is a completed design probe, not an unfinished migration.

This produces a three-pillar structure, ordered by value and risk:

1. **Discipline** (inherited): the kernel/host/guest model, the four boundaries, single-source-of-truth
   contracts, no-mocks e2e. Kept whole.
2. **Bazel** (the orchestration bet — the highest-value, lowest-risk pillar): one build graph with zero
   staleness, contracts projected to Rust + Zig + TS, vendor-less/patch-in-place, hermetic toolchains.
   This is the durable pillar you want whichever language the kernel is in, and it removes the single
   biggest pain of the lineage — an imperative build with stale-artifact hazards.
3. **Polyglot implementation:** Rust owns the kernel and native host; Zig owns the shell, coreutils,
   guest sysroot, and C/C++ guest-compilation lane; TypeScript owns the second host family and SDK;
   Elixir owns the multi-VM control core. Contracts, not language ownership, join those pieces.

The lineage taught two more things worth stating outright. First, **one landmine**: the embedded
interpreter must run in *eager* compilation mode — lazy translation charges the guest's fuel to
translate a function and corrupts the host on a dry-fuel resume (§4.3). AgentOS inherits this verbatim
in the shipped kernel. Second, the build wounds the Bazel graph deliberately cures: a `cargo test` that runs
against a stale kernel, image staging via `remove_dir_all`, hardcoded `../../target/...` guest paths,
two tar implementations that must stay byte-identical, checked-in vendored C/C++, host fonts and a host
browser leaking in, generated files kept fresh by ad-hoc `--check` flags. Every one of these is
something the Bazel dependency graph removes (§14.1) — and none of them is a reason to change the
kernel's language. That is precisely why Bazel, not Zig, is the lead pillar.

### 2.5 Anti-goals (the things we deliberately will not do)

The constitution is also a list of refusals; each maps to an invariant.

- **No host objects to the agent.** A1; the whole point. A kernel fd is never a host fd.
- **No native kernel build, even for debugging.** A2. Debug by driving the real
  wasm in a host.
- **No WASI / Component-Model / bindgen on the kernel.** A4. WASI exists only as a *guest* adapter that
  translates into `mc`.
- **No hand-written ABI on either side of any boundary.** B2. Edit the contract; let the projector
  generate; drift is a failed test.
- **No checked-in third-party source.** B3. Patches over vendoring; glue in Zig.
- **No manual artifact copying or "rebuild first" steps.** B1. If a test needs a kernel, it
  `data`-depends on it.
- **No mocks, no fakes.** B6. Drive the real kernel through real hosts and real effects.
- **No host-PATH tools or host-system files.** B4.
- **No rewriting what we can port.** The Rust kernel transplants the lineage; do not reimplement proven
  code for novelty.
- **No shipping an alternative kernel by inspection.** B7. Any new implementation must earn its place
  through parity against the shipped kernel.

---

## 3. System 1 — Contracts: the single source of truth

This is the spine. The lineage froze its ABI as a Rust macro, which gave zero drift *within one
language*. AgentOS is polyglot (a Rust kernel and host, Zig guests, TypeScript hosts/clients, and an
Elixir control plane), so the source of truth is lifted **out of any language into data**, and the build *projects*
it into all of them.

### 3.1 The shape

```
memcontainers/contracts/
├── syscalls.kdl   # the `mc` table — one row per syscall
├── bridge.kdl     # the `env` imports the kernel needs from the host
├── control.kdl    # the `mc_ctl_*` host→kernel channel
├── wire.kdl       # the server↔client protocol
├── constants.kdl  # errno, capabilities, tiers, ABI version, the service marker
├── codegen/       # the projector (a dependency-free Rust binary)
├── gen/           # the committed, diff-gated projections
└── spec/          # generated specs (AsyncAPI/OpenAPI/wire-vectors) — diff-tested outputs
```

A contract is written in a small KDL subset. A syscall row, for example, names the **exact wasm import
symbol**, the kernel `Pending` enum variant it maps to, each argument's *kernel storage type*, the
capability floor, and a doc string:

```kdl
syscall "mc_sys_write" variant="Write" group="io" {
    arg "fd" type="i32"; arg "ptr" type="u32"; arg "len" type="u32"; arg "ret_n" type="u32"
    ret "i32"
    doc "..."
}
```

A load-bearing subtlety: **on the wasm wire every argument is an `i32`** and the guest declares it so;
the kernel records it as the richer `type` (`u32` for a guest pointer or length, `i32` for an fd) via a
bit-preserving cast. Every syscall **returns `i32`** — an errno where `0` means success — except `exit`
(`noreturn`) and `pcall` (returns a throw code). Return *values* are written through **out-pointer
arguments** the kernel bounds-checks; 64-bit values are split into lo/hi or passed as a pointer to an
`i64`.

### 3.2 The projector

`memcontainers/contracts/codegen/src/projector.rs` is a dependency-free Rust binary. Invoked
as `projector --module <constants|mc|env|ctl|wire|llb> --lang <rust|zig|ts|elixir|md|asyncapi|openapi>`, it parses a
contract into a tiny KDL node model and walks it with a per-language emitter. Its design choices are
deliberate:

- **Determinism** — no clock, no environment, file-order iteration → byte-identical output every run.
  This is the only way the diff gate can be stable.
- **One parser, many emitters** — adding a language is a new emitter, never a new parser.
- **Host-compilable output** — every table boundary projects to a Rust `macro_rules!` callback table,
  *not* a concrete `extern` block, so the generated file carries no wasm-only attributes and validates
  with an ordinary host build. All Rust projections are `#![no_std]` so they never collide with the
  kernel cdylib's panic handler.

Per language: Rust gets names, callback tables, typed codecs, and a `SYSCALL_CAPS` matrix. Zig gets
descriptor tables, typed codecs, and concrete guest-side `extern "mc" fn` declarations generated from
the syscall rows. TypeScript and Elixir get constants and typed codecs; Markdown gets a reference
table; wire also emits AsyncAPI and OpenAPI YAML.

### 3.3 Typed messages and schema projections

Rows describe callable ABI surfaces. **Messages** describe typed byte payloads that travel over those
surfaces. A `message` node has a stable id, a version, and a closed set of fields (`str`, `bytes`,
`strmap`, integers, booleans, and lists of other messages). The projector emits canonical binary codecs
for Rust, Zig, TypeScript, and Elixir: little-endian numbers, declaration-order fields, explicit
presence bits for optional fields, sorted maps, and fail-closed decoders (`WrongMessage`,
`UnsupportedVersion`, `Truncated`, `TrailingBytes`, `InvalidUtf8`, `InvalidPresence`,
`NonCanonicalMap`). `control.kdl` owns the host-control messages; `llb.kdl` owns the portable build
graph messages.

The REST surface can project a message instead of hand-copying its fields. `schema "Exec"` in `wire.kdl`
derives from `message "ExecRequest"` in `control.kdl`, so the kernel control payload and the REST request
body share one source declaration for `cmd`, `cwd`, `env`, and `stdin`. REST-specific shape differences
are explicit `project` annotations: `cwd` keeps the public `Path` alias, `env` remains optional at the
JSON edge while the binary message carries an empty map, and `stdin` has both UTF-8 text and base64
presentations. The only local fields on the REST `Exec` schema are actual REST-only controls
(`timeoutMs`, `maxTicks`). The OpenAPI projection marks derived properties with
`x-agentos-source-field` and stdin encodings, and the projector rejects a local field that redeclares a
projected source field.

### 3.4 How drift becomes impossible

The build wires four gates, so the contract cannot diverge from any consumer:

1. **`build_test`** compiles each Rust/Zig projection — an invalid generator output fails the build.
2. **`diff_test`** (via `write_source_files`) compares the committed `gen/*.gen.*` against a fresh
   projection — a hand-edit or a stale copy fails.
3. **The kernel consumes the macro table to build an exhaustive `match`** — adding a syscall row makes
   the kernel fail to compile until a handler exists. The same applies to bridge and control tables.
4. **`mc-attest`** (§9.3) enforces, at build time, that every finished guest imports only declared
   syscalls and only those allowed by its stamped capability tier. Zig guest externs are generated
   directly, so there is no second declaration set to compare.

The result: one `.kdl` edit regenerates every projection, and *every* consumer — kernel dispatch, guest
sysroot, WASI adapter, host bridge, attestation matrices — either updates or fails to build. There is
no path by which two sides of a boundary disagree silently. It also keeps alternative implementations
possible: kernels, hosts, shims, servers, and clients consume a contract rather than becoming one.

### 3.5 Versioning

The ABI version is `(major << 16) | minor`, reported by `mc_sys_abi_version`. This worktree is **ABI
1.7** with **57 syscalls**: 1.3 froze a 52-syscall base, 1.4 added the five `svc_*` service calls, 1.5
widened service handle-delegation, 1.6 added the response-chunk `last` flag, and 1.7 added kernel-authored
`caller`/`caller_caps` metadata to the service receive envelope. Additive changes bump the minor; only a
break bumps the major. The wire protocol is versioned separately (`wire-version 2`, after splitting
snapshot restore into upload-ref data and control attachments) — it is the over-the-network `std`
contract, distinct from the in-process `no_std` one.

---

## 4. Systems 2–3 — The kernel

The kernel is single-threaded and cooperative. Nearly all mutable state lives behind `UnsafeCell` with
`unsafe impl Sync` asserted on one invariant: *no two references to a cell's interior are ever live
across a yield*. (An optional threaded build serializes every `task.step()` behind a Big Kernel Lock so
any worker interleaving is equivalent to some serial cooperative schedule.)

### 4.1 The process / task model (`task/`)

A `Task` carries identity (`TaskId = u32`; pid 1 is the login shell, special-cased), a `TaskState`
(`Ready` / `Running` / `Blocked(reason)` / `Zombie`), its three standard streams, cwd, exit code,
capabilities, a confinement root, the cooperative `program` (a `Box<dyn Builtin>`, e.g. a loaded
guest), an fd table for descriptors ≥ 3, a per-process namespace, and job-control fields.

**Capabilities** are a `u8` bitset — exactly eight bits, by design (a ninth "is the moment to ask
whether it is genuinely new authority"). The values are projected from `constants.kdl`, never
hand-written:

| Bit | Capability | Gates |
|---|---|---|
| 1 | `CAP_FS_READ` | reading the filesystem |
| 2 | `CAP_FS_WRITE` | writing the filesystem |
| 4 | `CAP_SPAWN` | spawning processes, sending signals |
| 8 | `CAP_NET` | network egress and host-calls |
| 16 | `CAP_PERSIST` | access to `/var/persist` |
| 32 | `CAP_AMBIENT` | clock, entropy, observing namespace mutation |
| 64 | `CAP_SCRATCH` | a private `/scratch` tmpfs to spill into |
| 128 | `CAP_MOUNT` | mount/bind/unmount, serving a subtree |

Capabilities are the kernel's *policy* layer: a privileged syscall checks the bit and returns `EPERM` if
absent. They compose with — they do not replace — the host's capability gate. The cardinal invariant:
**capabilities only ever narrow down the process tree.**

**Tiers** are the spawn-time dial that selects a capability ceiling: `Full`, `ReadWrite`, `ReadOnly`,
`Isolated` (plus `Inherit`). A binary declares its tier in an `mc_tier` custom section; a parent may
request one at spawn. `Tier::caps()` is generated from the contract, so the kernel and every guest-side
projection use identical ceilings:

- `Full` = all eight bits.
- `ReadWrite` = `FS_READ | FS_WRITE | AMBIENT | SCRATCH`.
- `ReadOnly` = `FS_READ | AMBIENT | SCRATCH` (so `date`, `shuf`, and spill-to-scratch work).
- `Isolated` = `FS_READ` only — and it is **the sole fully deterministic tier**, because a writable
  scratch would re-introduce clock-derived mtimes, and it withholds ambient clock/entropy. `Isolated`
  also confines the task to a root subtree it cannot escape.

The policy point is `exec_policy`: `caps = parent ∩ binary ∩ requested`; an absent tier means "inherit";
the confine root is the parent's, tightened to cwd if the tier confines.

**Signals** are deliberately simple — there are no async handlers; *disposition* is the whole model. A
task has a pending-signal bitset and an ignored bitset. Delivery marks the signal pending and applies it
immediately *unless the target is mid-step* (terminating a task under its own feet is unsafe), in which
case it is applied at the next step boundary. The disposition engine handles `SIGKILL` (unconditional,
exit `128+signo`), `SIGCONT`, `SIGINT`/`SIGTERM`/`SIGHUP` (terminate by default, but an *ignored*
interrupting signal is left pending so a blocked syscall returns `EINTR`), `SIGTSTP` (stop), and
`SIGCHLD` (dropped). A subtle inheritance carve-out resets `SIGINT`/`SIGTSTP` to default in children so
Ctrl-C and Ctrl-Z reach foreground jobs even though the login shell ignores them on itself.

**Process groups & job control** are real: a child starts in its parent's group; the shell puts a job
into its own group and `tcsetpgrp`s the foreground. **`waitpid`** finds a reapable zombie or a
freshly-stopped child (reported once), returns `ECHILD` with no matching child, honors `WNOHANG`, and
blocks on a `WaitChild` reason otherwise. On exit a task's children **reparent to pid 1** so a
session-wide SIGHUP reaches detached grandchildren; `kill_task` closes all fd-owning objects *before* the
ordinary exit path so a killed server cannot keep pipes or sessions alive until reaped, and the guest's
linear memory is freed at exit (not reap), so a crashed server's clients fail fast instead of hanging.

### 4.2 The cooperative scheduler (`task/scheduler.rs`)

State: a `ready` queue, a `blocked` map keyed by `BlockReason`, a `zombies` list, the task map (boxed for
stable addresses), and the pipe pool (boxed because block reasons hold raw pipe pointers). `BlockReason`
is small: `PipeRead`, `PipeWrite`, `WaitChild`.

A *step* is driven by the pipeline driver, not the scheduler itself: pop a ready task (skipping stopped
ones, bounded so an all-stopped queue terminates), process its pending signals, apply a
cooperative-`nice` skip check, run `task.step()`, and dispatch the returned `BuiltinStep` — `Exit` (close
streams, free program, reap), `BlockedOnStdin/Stdout` (park on the pipe behind the stream, or requeue if
it is a terminal/file), `Pending` (made no progress — requeue), or `BlockedOn(reason)` (park).

Waking is mostly event-driven: at the top of each tick, pipe blockers are woken when the pipe has
data/space or the peer closed; `WaitChild` waiters are woken by `exit_task` and the signal engine rather
than polled. Prioritization is POSIX `nice` done *relatively*: a task above the minimum ready-nice burns
skip credits before stepping, so a niced job yields CPU without starving — and signals are processed
before the skip, so a `SIGKILL` still lands promptly.

### 4.3 The wasm runtime (`wasm/`)

This is how a guest actually runs. A `GuestRuntime` (created once at boot, captured in snapshots) holds
one `wasmi` `Engine`, **one** reusable `Linker` with the `mc_sys_*` host functions registered once, and a
**permanent** module cache.

**Engine configuration** is the load-bearing detail. Fuel metering is on (execution is bounded and
resumable) and compilation mode is **eager**. The eager setting is not an optimization — it is a
correctness requirement and the system's single documented landmine: the embedded interpreter's default
lazy translation charges the *guest's* fuel to translate a function on first call, and if a fuel slice
runs dry mid-translation, resuming that path corrupts the host (a SIGSEGV or a bogus integer conversion
inside the sandbox). Eager translation moves all translation out of the fuel-metered path, so even heavy
guests run on the normal cooperative quantum with no special-casing. The cost — translating the whole
module once at load — is paid back by the cache.

**The module cache is permanent by design.** `wasmi` keeps translated code in an engine-wide arena that
is never freed for the engine's lifetime. Re-translating a program on every spawn would pile duplicate
code into the engine and grow kernel memory without bound. So each distinct program is compiled exactly
once, keyed by a content hash, and the cache is never evicted — evicting frees nothing and recompiling
would only re-leak.

**Budgets.** A `Budget` is `{ mem_bytes, fuel, table }`. The default is 16 MiB / 50 billion fuel / 10k
table entries; the hard ceiling is 1 GiB / 4 trillion / 1M. A guest may declare a budget in an
`mc_budget` custom section; the effective budget is `min(declared|default, vm_ceiling, hard)`, where the
VM ceiling is set once at boot from the image manifest — "the thing Docker can't say: *runs
deterministically in ≤ N MiB.*" Exhausting the lifetime fuel kills the guest with exit 137.

**The syscall suspend/resume dance** is the heart of the cooperative model. Every `mc_sys_*` host
function is *thin*: it records `Pending::Variant{ args }` into the guest's store and returns a host
error. `wasmi` surfaces that as a resumable host-trap, suspending the guest. The kernel's `step()` then
fulfills the request against the real VFS / pipes / net and resumes the guest with the result. The
`Pending` enum is *generated from the same syscall table* the host functions are, so the exhaustive
`fulfill` match cannot compile until a new syscall has a handler — drift is impossible. A would-block
syscall maps to a `BlockedOn*` park; fuel exhaustion charges a quantum (2,000,000 instructions) and
re-parks; an in-flight host operation maps to `Pending`. This composes guest scheduling onto the
cooperative model with **no scheduler special-casing** — a guest is just another cooperative task. It is
this resumable-host-trap shape that keeps scheduling policy outside guest implementations.

**`pcall` / the trap-unwind shim.** C/C++ guests that need non-local exit (today only Luau, because
`wasmi` has no exception proposal and the Zig wasi-libc++ ships no EH runtime) opt into a kernel-mediated
mechanism by exporting both `__mc_pcall_run` and `__stack_pointer` (all-or-nothing, enforced at load — a
half-armed shim would corrupt the shadow stack). On `mc_sys_pcall` the kernel parks the caller and runs
the guest's dispatcher as a fresh nested call; when the child traps after recording a throw code, the
kernel distinguishes an intentional throw (catchable) from a genuine fault (a crash), restores the
shadow-stack pointer, and resumes the parent with the code. SQLite (return codes), and a Rust service
(`panic = abort` + crash-only restart), need none of this — the heavy machinery is a property of
*embedding a language with exceptions*, not of porting a C/C++ engine (§10.4 develops this).

---

## 5. Systems 4–5 — The virtual filesystem

"Everything is a file" is literal here: processes, the environment, devices, the network, and services
are all file trees. Two traits and a namespace make it composable.

### 5.1 The VFS abstraction (`vfs/traits.rs`)

Two traits carry the contract. **`FileHandle`** is an open file — `read`/`write`/`seek`/`stat`, with
`truncate` defaulting to "not implemented" so read-only backends opt out, and `poll_readable`/
`poll_writable` defaulting to true (overridden only by in-flight-resource handles like the network).
**`FileSystem`** is a mountable backend — `open`, a *synchronous* `stat` (it must never yield, because
path resolution depends on it), `readdir`/`mkdir`/`unlink`/`rename`, default-not-implemented
`symlink`/`link`/`readlink`/`set_mode`/`set_times`, and `commit_layer()` (only the copy-on-write fs
overrides it).

The vocabulary is precise: `NodeType` is `File`/`Dir`/`Symlink`; a symlink's reported size is its
target-text length, and **following is the namespace's job, never a filesystem's** — every backend has
lstat semantics. `FsError` distinguishes `PermissionDenied` (a capability/mount denial → `EPERM`) from
`AccessDenied` (a file *mode* bit → `EACCES`), `CrossDevice` (rename across mounts → `EXDEV`),
`WouldBlock` (retry-after-yield, used only by in-flight backends), and `Loop` (symlink depth → `ELOOP`).
`Metadata` carries node type, size, link count, a 9-bit mode (only the owner triad is ever enforced — a
single subject), and millisecond timestamps. A `CallerId` (the acting task id) is threaded into mutating
ops so identity-aware filesystems can check who acts *without the VFS layer depending on the task layer*.

### 5.2 Namespaces (`vfs/namespace.rs`)

A `Namespace` is a cheap, cloneable, Plan-9-style *view*. The mount table is an `Rc<BTreeMap<…>>` shared
with the parent on fork by a pointer copy; a `bind` or `unmount` does copy-on-write via `make_mut`, so it
affects only the acting task. Crucially, the *filesystems* are shared `Rc<RefCell<…>>` while the *view*
is per-task: `/tmp`'s contents are the same for everyone, but what is mounted where is private. Each
delegated operation clones the target `Rc` and borrows it, so **no table borrow is ever held across a
filesystem call.**

Path resolution is a two-step: `canonicalize` then `resolve`. `canonicalize` is the kernel's **only**
symlink-following site and the only place `..` is collapsed — a work-list algorithm that splices a
symlink's target in front of the remainder, caps at 40 hops (`ELOOP`), and enforces owner-execute search
permission on each intermediate directory *before* lstat'ing the next component, so a symlink inside a
no-search directory cannot be followed to bypass mode bits. There is no TOCTOU window: check and use both
run synchronously under the kernel lock with no yield between. `resolve` then does longest-prefix mount
matching (a sub-mount requires an exact match or a `/` continuation, so `/devfoo` is not routed to a
`/dev` mount).

Capability gating lives at the syscall layer, reading namespace state: a write requires the mount's
declared `write_cap` (almost always `CAP_FS_WRITE`, but the per-task `/scratch` tmpfs uses `CAP_SCRATCH`
so a read-only tool can spill without write-anywhere authority); any access under `/var/persist`
additionally requires `CAP_PERSIST`; mount/bind/unmount require `CAP_MOUNT`; an isolated task cannot
escape its confine root. Mode enforcement (the `EACCES` layer) is AND-ed on top: owner read/write on the
node, owner write on the parent for create, owner read+execute on a directory for readdir.

### 5.3 The filesystem backends (`fs/`)

Each backend is a small, single-purpose system. Boot mounts a stack at `/` plus the synthetic trees.

- **memfs** — the in-memory writable substrate (root fallback, `/tmp`, `/scratch`, and the overlay layer
  inside the CoW fs). A real inode model: paths map many-to-one to inodes, so a hard link adds a name and
  bumps `nlink`, and a *rename re-keys paths only* — inodes never move, so an open fd survives a rename.
  It is the only backend tracking a real link count, and the only one implementing
  `set_mode`/`set_times`/`link`. Read access bumps atime with relatime semantics (and never under
  `noatime`).
- **persistfs** — capability-backed persistence at `/var/persist`. The agent-visible shape of durability:
  shell `cat`/`echo` and a wasm `open`/`write` both persist across kernel restarts through one
  mechanism — the host KV store — with *no host path or handle ever visible*. It is a flat whole-value KV
  (the key is the slash-stripped path; directories are implicit prefixes with marker keys). A handle
  buffers the whole value at open (probing the store up front so a denied write fails at open, not
  silently at flush) and commits on `Drop` — `Drop` is the universal flush hook, since the trait has no
  `close`.
- **cowfs** — copy-on-write over a read-only base: the writable top of the root stack. A read-only base
  (a tar image or an overlay union) plus a writable memfs overlay plus a tombstone set. Reads prefer the
  overlay unless tombstoned; opening a base file for write *copies it up* (carrying its mode and
  timestamps); deletes add a tombstone. Its inverse of tar is **`commit_layer`**: a walk of the
  overlay's own tree (not the merged view, so the layer is exactly the diff since boot) emits a
  POSIX-ustar tar, with shared inodes becoming tar hard-links and each tombstone becoming an OCI `.wh.`
  whiteout.
- **overlayfs** — a read-only union of N tar layers, the substrate for image flavors. Layers stack
  lowest-to-highest; a higher entry shadows a lower one and an OCI whiteout removes a subtree below it.
  All mutation is refused — the wrapping cowfs provides the writable top.
- **tarfs** — the read-only base image. It indexes a tar (or gzip) blob into an entry map at
  construction, parsing POSIX-ustar headers, resolving hard links to shared byte ranges, and reading
  directly from the shared blob. Its header parser is the *exact byte-for-byte inverse* of cowfs's tar
  writer — that round-trip is the persistence story for the root image.
- **procfs** — a synthetic read-only view of kernel state at `/proc`: `uptime`, `mounts` (rendered from
  the *caller's* namespace), and `/proc/[pid]/{cmdline,status,cwd,ctl}`. The one writable file is
  `/proc/[pid]/ctl`, the signal-free Plan-9 control plane — writing `kill`/`stop`/`cont` acts
  immediately, and you may control only yourself or a descendant (pid 1 may control anything).
- **envfs** — the environment as files at `/env`, per-task (POSIX): a child inherits a copy, so a
  transient `FOO=bar cmd` reaches only that command. A host control-channel write to `/env/X` targets the
  *boot* environment that later-exec'd agents clone.
- **devfs** — `/dev/null`, `/dev/zero`, `/dev/random` (host entropy), and `/dev/cons` (the Plan-9
  console).
- **netfs** — the network as a file tree at `/net` (§7.3).
- **toolsfs** — a read-only catalog view at `/tools`, mounted globally by base. `/svc/tools` remains the
  broker and catalog mutator; toolsfs reparses the checkpoint catalog and exposes only progressive
  browse/describe files, so it creates no egress path.

---

## 6. System 6 — Pipes (`ipc/`)

Pipes back real multi-process pipelines. A `RingBuffer` is a fixed 64 KiB ring (capacity is 64 KiB − 1;
one slot is always empty to disambiguate full from empty). A `Pipe` adds **reference-counted** reader and
writer ends — not booleans — because a write end may be held by several fds at once (the shell holds one
and hands a duplicate to a spawned child). An end is "closed" — and the peer sees EOF or a broken pipe —
only when the *last* holder releases it. Pipes live in the scheduler's boxed pool so their heap address
is stable for the raw pointers that block reasons and I/O sinks hold; the scheduler outlives every
referencing task and reaps a pipe only when it is closed on both ends with nobody parked on it. The I/O
sinks apply ONLCR (`\n` → `\r\n`) **only** on the terminal path — files and pipes stay pure LF — and the
console pipe is recognized by pointer identity so `isatty(0)` is true for the live prompt but not for
`cat | foo`.

---

## 7. Systems 7–10 — IPC, services, and networking

The unifying idea, the deepest Plan-9 inheritance: a guest can *be* a server — of a filesystem subtree,
or of a typed service — and because all the rendezvous state lives in kernel linear memory, it is
captured by a snapshot. That last property is what justifies "a service inside the kernel" over "a
process pool outside it."

### 7.1 Served filesystems (`fs/servedfs.rs`)

A guest with `CAP_MOUNT` calls `mc_sys_serve(path)` to become the server for a subtree; the kernel mounts
a `ServedFs` there and hands back a control fd. When another task opens a path under the mount, the served
fs enqueues a request, returns `WouldBlock` (the requester's syscall yields), and the server loop receives
it (`serve_recv`), handles it, and responds (`serve_respond`); the requester's next tick collects the
answer. The whole VFS surface rides this one dance via an `op` code. Dedup is by `CallerId` — a
cooperative guest runs one syscall at a time, so a yield-retry is idempotent. The server can only ever
return *bytes*, never a host object. This is the structural template the resident-service system refines.

### 7.2 Resident services (`fs/servicefs.rs`) — "tools as libraries"

A heavy engine (SQLite, a type-checker, a document compiler) pays a cold-start tax on every invocation —
SQLite opens the DB and warms its page cache; typst loads tens of MB of fonts. The fix is a **resident
service**: a long-lived guest that serves a name under `/svc` and answers typed request/response calls
with its engine warm. Three things make this worth doing over spawning the tool per call:

1. **No cold-start tax** — subsequent calls reuse warm state in the service's linear memory.
2. **One core, never two codebases** — the CLI, the `require("…")` library, and the resident loop are all
   clients of the *same* engine binary. The library can never do less than the command, and they cannot
   drift, because there is exactly one implementation.
3. **Warmth snapshots with the VM** — because the warm handle lives in linear memory, a snapshot captures
   it; a restored VM comes back with the connection already warm. A host-side process pool, outside the
   snapshot, cannot do this. This is the single property that justifies a service *inside* the kernel.

The lifecycle:

- **Registration** (`svc_serve`): the kernel authorizes serving a name *only for the task it activated to
  serve it* — serve-authority is the **activation grant**, not a blanket capability — so no guest can
  squat a name. One server per name.
- **Activation**: services are declared by composable `/etc/services.d/<name>.json` fragments
  (`binary`, optional `eager`); the tier is taken from the binary's stamped `mc_tier`, never the
  fragment, so a fragment can never widen privilege. Lazy services (the default) spawn on first connect; a supervisor state
  machine tracks `Activating`/`Failed` with exponential backoff so a crash-looping service is retried
  ever more rarely rather than respawned every connect. A binary is resolved by exact absolute path and
  checked to actually claim the name it is being activated under.
- **Connection** (`svc_connect`): mints a *session*, returns a connection fd. Routing is by
  `(session, req_id)`, **not by caller**, because one client may hold several concurrent sessions to one
  service (a script with two DB handles) — a caller-keyed map could not express that. This is the one
  real correction over the served-fs template, which dedups by caller on the assumption of one in-flight
  request per caller. The request envelope still carries kernel-supplied `caller` and `caller_caps`
  metadata from the `svc_call` task so a service can distinguish ordinary guest calls from the host control
  channel (`SYSTEM_CALLER`) and enforce operation-level authority without trusting the request body.
- **Call** (`svc_call`): a typed request blob plus optional delegated handles → a *readable result fd*
  the caller drains. Like a host-call, the call itself does not block — the client streams the response,
  yielding while the server computes, so a large result (a SQLite cursor, a PDF) never materializes
  whole.
- **Receive / respond** (`svc_recv` / `svc_respond`): the server loop receives an inbound, optionally
  installs delegated handles, computes, and responds in chunks. Backpressure is real: if the undrained
  buffer crosses a high-water mark the server is parked until the client drains; only a delivered
  `(session, req_id)` may be answered.

The envelope is
`[kind:u8][nhandles:u8][session:u32][req_id:u32][caller:u32][caller_caps:u32][blob_len:u32][blob…]`, with
delegated fd numbers in a parallel buffer; `kind` is *call* or *session-closed tombstone*. The blob is
**opaque** — the service and its library define the wire format; the kernel never reads it. Only the response
`status` is kernel-interpreted (`0` = body follows, non-zero = an errno surfaced to the client's read;
application errors ride *inside* the body). `caller_caps` is kernel-authored call-time authority metadata; a
service that performs privileged work on behalf of callers must check it instead of relying on its own binary
tier.

**Handle delegation** is the SCM_RIGHTS analogue: a call may carry a few of the caller's own fd numbers;
the kernel clones the backing object into the service's table under fresh numbers. Only
`File`/`PipeRead`/`PipeWrite` may delegate — a net or service fd is refused, so a caller cannot launder
egress into a callee. The use case: `sqlite import < data.csv` delegates stdin so the service reads the
CSV with no ambient FS reach.

**Crash-only** is the recovery model: a trap or over-budget kill drops the service's control fd → the
channel closes → every pending and new call resolves to `EIO` → a lazy service is re-activated on the
next connect. The callee dies alone; it never unwinds into the caller or the kernel. Warm is *not*
durable — durable data is written through to `/var/persist`; warm state is a cache. And `/svc` is itself a
readable directory: `ls /svc` lists known services and `cat /svc/<name>` reports
`ready`/`activating`/`failed`, so a wedged service is visible.

**The "three faces, one core" model.** The same binary is the resident loop (entered when the kernel
spawns it with a service marker as `argv[1]`), the CLI (`_start`, which itself connects to and calls the
warm instance), and the `require("…")` library shim. This deliberately departs from the older "two
binaries per tool" (`<tool>-svc` resident loop plus a thin CLI) convention: that doubles the `/bin`
surface and leaks an implementation mode into the user-visible namespace. AgentOS ships **one binary
with two activation modes**, chosen by the kernel from the contract (the `svc_serve` path vs `_start`),
not by `argv[0]`. Service-capability is therefore a *property, not a second artifact*: an `mc_service`
custom section (stamped like `mc_tier`/`mc_budget`) plus an `/etc/services.d/<name>.json` fragment.

### 7.3 Networking (`net/`, `fs/netfs.rs`)

The kernel never speaks TLS or opens sockets — the **host** performs all HTTP/WebSocket work, including
TLS, through the bridge. This keeps the kernel `no_std` and identical under the wasmtime and browser
hosts (a browser host *cannot* open raw sockets), so the surface is deliberately HTTP and WebSocket,
never raw TCP. The raw host handle is a kernel↔host secret that never reaches a guest; the owning types
close it on `Drop` and bounds-check every cross-bridge buffer.

HTTP is a poll→head→body state machine gated on `CAP_NET`: a request blob (`METHOD URL\n headers\n\n
body`) starts a host fetch, a poll returns nothing until the head arrives, then the body streams —
composing with the cooperative scheduler one poll per tick. 4xx/5xx are delivered as real responses; only
transport failures error. WebSockets are bidirectional with a one-message receive buffer so `poll` can
report readiness without consuming. The same plumbing is also exposed as a Plan-9 file tree at
`/net/{http,https,ws,wss}/<host>/<path>`: *opening a path is connecting*. Scheme directories are
searchable but never enumerable — netfs must not leak reachable hosts.

### 7.4 Host-call and the proxy substrate (`host_call.rs`, `fs/proxy.rs`)

A `host_call` routes an opaque blob to a host-registered handler (the tool broker, a host-backed mount
driver) and returns a readable result fd — the same poll→body→EOF state machine as the network, gated by
`CAP_NET` and default-deny. The **proxy substrate** holds the shared decoders for the two proxying
filesystems (served fs, answered by a guest; mount fs, answered by a host driver): the fixed 44-byte stat
record and the typed readdir payload they must agree on. It rejects path-escapes (no `.`/`..`/embedded
slashes in a returned name) and owns the metadata cache that makes a synchronous `stat` possible over an
inherently asynchronous server.

---

## 8. System 11 — Snapshots, determinism, and the seal

Snapshot/restore is a *host* operation built on A8. The host dumps the kernel's entire linear memory —
the scheduler with every guest's `wasmi` store, the heap, the VFS, the module cache — behind a small
header, and rebuilds a fresh instance *without* calling `mc_init`: the booted state *is* the image. A
restored VM gets fresh capabilities and sinks (it never shares the original's host handles), and two
restores from one snapshot fork into independent VMs.

The kernel exposes only what the host cannot infer: **`mc_inflight_egress`**, the count of live
HTTP/WebSocket/host-call handles plus resident-service calls mid-flight. The host **refuses to snapshot
while it is non-zero** — an open connection's raw host handle would not survive a restore, and a service
between receive and respond has a live wasm stack a snapshot would lose. So a snapshot is always taken at
a quiescent boundary, which is why the service loop idles in `svc_recv` (no live stack) and warm state
survives. A separate `commit_layer` serializes the live copy-on-write overlay into a content-addressed tar
for image stacking, under the same egress guard.

Determinism is structural: all mutable state is in linear memory; the only nondeterminism is the clock and
entropy, both `CAP_AMBIENT`-gated. The host's deterministic mode pins a fixed clock and a seeded
SplitMix64 RNG, so a run is byte-for-byte replayable and record/replay testing is exact.

The **seal** (`seal.rs`) is a small provenance system: an attribution line stored XOR-obfuscated with an
LCG keystream (so it does not appear under `strings`) and gated by a compile-time checksum, printed first
thing at boot — and suppressed if the ciphertext was patched out of a stolen binary. It raises the cost of
stripping attribution from a binary; it does not claim to be unbreakable against someone with the source.

---

## 9. Systems 12–13 — The guest ABI: sysroot, WASI adapter, conformance

### 9.1 The sysroot

The guest side of the syscall ABI, in two languages. The **`mc` import block is generated** from the same
syscall table the kernel's dispatch derives from, so a guest can never import a syscall the kernel does
not serve. On top sits a **hand-written, deliberately not generated** safe-wrapper skin
(`read`/`write_all`/`open`/`spawn`/… returning `Result<T, errno>`), plus the
`entry!`/`declare_tier!`/`declare_budget!` macros. The philosophy: *generate the boundary, port the
comfort* — the generated externs already catch drift, and generating the ergonomic wrappers would demand
rich per-argument metadata for no benefit. Load-time metadata (tier/budget/service) is no longer in
source; it is declared in the build and stamped post-link, so the build graph is its single source.

The Zig sysroot is the counterpart for the C/C++ guest lane. Zig comptime cannot synthesize callable
function declarations, so the projector writes concrete `pub extern "mc" fn` declarations into
`gen/mc.gen.zig`; `memcontainers/sysroot/zig:mc` compiles and re-exports that generated module. Unused
externs are dropped by the linker, so each guest imports only the syscalls it references. `svc.zig` is
the resident-service serve-loop scaffolding (serve/recv/respond plus envelope decoding) reused by Zig
services. The service marker is a projected constant shared by the kernel and every service.

A scar encoded in the generator: the contract may describe a call as logically `noreturn` (for example
`exit`), but the kernel registers every syscall with an `i32` return. The generated Zig declaration
therefore keeps that wire type; changing it would alter the wasm import signature and make spawn fail
with `EINVAL`.

### 9.2 The WASI adapter

To reuse the `wasm32-wasi` tool ecosystem (uutils, ripgrep, SQLite, typst) without teaching the kernel a
second ABI, the WASI adapter *defines* the `wasi_snapshot_preview1` functions (≈70 of them) over
`mc_sys_*`, and the build **link-injects** it so its definitions override wasi-libc's imports. The
converted module then imports **only `mc`** and is indistinguishable from a hand-written guest. Because
the adapter is linked *into* the tool, it runs in the tool's own linear memory — a WASI pointer is a real
address, so there is no marshalling.

A hard-won rule, learned the hard way and never to be rediscovered: the adapter advertises **exactly one
preopen**, `fd 3 = "/"`. Advertising a second (`"."`) preopen breaks wasi-libc's longest-prefix path
resolution and the guest silently fails (empty output). There is one fd namespace; service file I/O goes
through the same libc → adapter → `mc_sys_*` path the engine already uses — never a second reader. A
trampoline fixpoint relink iterates until the box imports only `mc`, then attestation fails the build if
the imports exceed the declared tier.

### 9.3 Conformance & attestation

Conformance is a *build error*, not a runtime check. **`mc-attest`** walks a finished guest's wasm import
section and fails the build on (a) any non-`mc` import or unknown syscall name (import purity), (b) a
syscall whose capability floor is not covered by the declared tier (tier-fit — a read-only box importing a
write syscall fails), and (c) a `svc_serve` importer that lacks a grammar-valid `mc_service` section. No
capabilities are hardcoded — it reads only the projected `SYSCALL_CAPS` and `tier_caps`, so a contract
rename cannot silently pass. The broader conformance gate derives the syscall surface from the contract and checks
that no guest imports an undeclared symbol and every declared syscall is exercised by ≥ 1 guest or carries
a documented exclusion. The interpreter additionally gets *behavioral vectors* (fuel exhaustion → re-park,
host-trap → suspend/resume, budget enforcement) so a future kernel — or any interpreter swap — is provably
equivalent.

`//memcontainers/conformance:conformance` is that broader gate. It walks the real shipped image tarballs
(`minimal`, `posix`, `svc_test`, `atlas`, `paper`) and reads every embedded wasm module with the shared
`wasm-imports` oracle, failing on any non-`mc` function import, undeclared syscall import, uncovered
declared syscall without a documented exclusion, or stale exclusion whose syscall is now covered. It also
pins the typed host-control messages as language-neutral vectors (`control_vectors.json`) consumed by both
the Rust and TypeScript generated codecs: `ExecRequest`/`ExecOutcome`, `FileStat`, `DirEntries`,
`SvcRequest`/`SvcResponse`, and `RelayEvent`, including malformed frames. Finally, it boots the real Rust
kernel under the wasmtime host for runtime vectors over typed exec/stat/readdir/service calls, fuel
re-parking, pcall trap unwind/resume, and fuel-ceiling termination.

---

## 10. Systems 14–17 — The userland

### 10.1 The shell (`shcore/`, `programs/sh`)

`shcore` is the canonical Zig OS-agnostic POSIX-ish shell core behind `/bin/sh`. It uses a pure
front-end (lex → parse → expand/glob/arith) plus a blocking tree-walking executor, decoupled from the
world by a single `ShellOs` boundary. The pure layers touch no syscalls; the guest `programs/sh`
package binds that boundary to `sysroot/zig` and ships the full-tier `/bin/sh` wasm. The lexer does
maximal-munch operators, quotes, all the substitutions, and here-docs, and deliberately does *not*
classify keywords (POSIX recognizes them only by grammar position, so the parser upgrades a bare word
in command position). The AST keeps words unexpanded because expansion is runtime-dependent.

`shcore` is not the process layer: the guest adapter binds `ShellOs` to real VFS/task/scheduler
operations through the sysroot, and `/bin/sh` still depends on `mc_sys_spawn`/`mc_sys_waitpid`/job-control
syscalls. Shell-core verification proves the shell engine; kernel e2e proves the adapter and process
syscalls.

The seam is illustrative of the whole system: **every `ShellOs` method blocks**, and the executor is
straight-line code — it relies on the kernel turning a blocking syscall into cooperative suspension, so
there is no async coloring. There is **no `fork`**: `spawn` loads a new program image, and subshells and
command substitution run in-process via snapshot/restore of the interpreter state, with `$(...)`
capturing into an in-memory buffer pointed at a virtual negative fd that cannot collide with a real one.
Pipelines stream external commands through real pipes while running builtins/functions as in-process
subshells writing to a temp file between stages (avoiding deadlock on a full pipe with no reader). Job
control is real: setpgid, foreground-pgid, SIGTSTP-driven stop, `fg`/`bg`. The builtin set is the
expected POSIX one plus `test`/`[`.

### 10.2 The userland `/bin` (`programs/coreutils`)

`/bin` is a Zig **multicall** userland derived from nutils. `main.zig` dispatches on the `argv[0]`
basename, and every applet accepts the same `*Ctx` boundary. The source compiles directly against the
generated Zig mc sysroot: it has no WASI import layer and no applet-local syscall declarations.

`registry_data.zig` is the one applet roster. `registry.zig` pairs each row with its implementation,
while `bazel/coreutils.bzl` reads the same data to stamp the `mc_applets` section and build image
symlinks. The graph produces full and minimal boxes at each capability tier
(`isolated`, `read-only`, `read-write`, `full`), so the code present in a box, its declared ceiling, and
the commands linked into an image stay aligned.

Applets own CLI policy; reusable algorithms live under `core/` and `engines/`—the shared option parser,
text and filesystem facades, bounded spool, regex/glob/hash/archive/date/sort engines, and jq/awk/sed
sub-languages. Native tests exercise pure logic, while real-artifact e2e boots the boxes through the
kernel. [`programs/coreutils/DESIGN.md`](memcontainers/programs/coreutils/DESIGN.md) records the
subsystem-level implementation decisions cited by source comments and is explicitly subordinate to
this contract.

### 10.3 Luau (`programs/luau`) — the primary scripting language

Luau is built from pristine upstream plus a small in-tree patch set, compiled with `zig c++` to
`wasm32-wasi`, WASI-rewritten to pure `mc`, and shipped in the `loom` flavor and up as `/bin/luau` (VM +
compiler) and `/bin/luau-analyze` (the type checker). It is the user-facing language; `require("…")` is
the default interface to everything, including SQLite and typst. The patches reroute Luau's `error`/`pcall`
and the analyzer's throws through the kernel trap-unwind shim (the EH machinery of §4.3), and turn an
analysis abort into a graceful exit so a result is never silently wrong.

The library model is a clean *code vs content* split. Eighteen `.luau` **batteries** (`json`-adjacent
helpers, `http`, `path`, `xlsx`, `docx`, `pptx`, `chart`, `zip`, …) are `@embedFile`'d into the binary and
lazy-compiled on first `require`, so an unused library costs only bytes and works with zero image staging;
native modules (`json`, `hash`, `encoding`, `deflate`, `re`) are registered at startup. `require`
resolution is **cache → embedded → VFS `package.path`**: embedded always wins, so a flavor cannot shadow a
builtin, but a flavor *can* layer extra `/lib/luau/*.luau` into the image that become require-able with no
interpreter rebuild. The `sys` surface over `mc_sys_*` (`sys.fs`, `sys.io`, `sys.proc`, `sys.net`,
`sys.host`, `sys.time`) returns `value, err` pairs, and the higher batteries compose (`xlsx` requires
`opc`, `xml`, `media`, `chart`, …). A recurring discipline: an out-of-memory or resource limit is always a
catchable Lua error, never a trap or a truncated result.

### 10.4 Domain engines: SQLite and typst — and the two build lanes

The heavy domain engines are the canonical resident-service case: each is one binary with two activation
modes, warm in a flavor, reached as both a CLI and a `require()` library. They share the §7.2 mechanism
and differ only in **language lane** and what "warm" buys. The two lanes are a load-bearing decision — the
engine's own source language picks the lane, and the lane decides everything you write:

- **Rust-native lane (the easy way in).** A Rust engine compiles against `//memcontainers/sysroot`, which
  already exposes the `mc_sys_*` wrappers (including `svc_*`). The service driver is **Rust** and calls
  the engine's Rust API directly — the same lane as the coreutils boxes. **typst takes this lane.**
- **C-API-through-Zig lane (everything not Rust).** A C or C++ engine is reached through its **C API**,
  and the wrapper/driver is **Zig** — the C/C++→Zig glue lane Luau established. The Zig glue `@cImport`s
  the engine's C header, drives its C functions, and calls `mc_sys_*` through the hand-kept `mc.zig`
  extern shim. For a C++ engine the "route to C" is literal (its public API is forced to `extern "C"`);
  a C engine is already C. **SQLite takes this lane.** The rule, stated so it is not violated: the driver
  around a C/C++ engine is **never** a Rust FFI wrapper — that would be a redundant third lane. C/C++ →
  Zig (via the C API); Rust → Rust.

**The simplification that both engines share: neither needs Luau's trap machinery.** Luau's hardest work
was the kernel trap-unwind for C++ exceptions. SQLite signals failure with **return codes** and uses
`setjmp`/`longjmp` *internally* for OOM recovery — those jumps are in-guest and never cross the kernel
boundary. typst is built `panic = abort`: there is no unwinding to reroute; a panic **aborts the guest**,
and that is *exactly the recovery model a service wants* — a panicking service traps → the task exits →
its serve fd drops → the in-flight caller gets `EIO` → the supervisor re-activates a clean instance.
**Crash-only is the EH story for a Rust service.** The heavy machinery was a property of embedding a
language with exceptions, not of porting a C/C++ engine.

**SQLite** is the data engine, shipped in the `atlas` flavor. It is compiled via `zig cc` to `wasm32-wasi`
with WASI mode, single-threaded, no extension loading, no double-quoted strings — using the built-in
unix-dotfile VFS so all file I/O rides WASI → the adapter → `mc_sys_*` with *no custom VFS*. (A C
`close()` shim is force-linked because Zig's bundled libc would otherwise import `fd_close` directly,
bypassing the adapter.) The resident mode (`svc_serve("sqlite")`) holds a warm `sqlite3*` and a
prepared-statement cache across calls, speaks a small JSON protocol
(`open`/`exec`/`query`/`prepare`/`step`/`finalize`/`import`/`close`), and streams result rows in chunks;
the CLI connects to that same warm service. It is stamped `full` (it needs `CAP_PERSIST` for a
`/var/persist` DB). `require("sqlite")` is the typed, warm face.

**typst** is the document engine, shipped in the `paper` flavor (`paper = loom + typst`). It is the genuine
Rust typst compiler (the `typst` + `typst-pdf` crates) built to `wasm32-wasi` and WASI-rewritten to pure
`mc` — the **Rust-native service lane**, so the service loop is Rust over the sysroot rather than Zig
glue. A small `World` implementation satisfies typst's source/font/clock interface over the VFS;
compilation is source-path-in, PDF-bytes-out, and a large PDF streams back over the service's readable
result fd (yielding cooperatively while the compile runs). Two engineering details that matter and
generalize: a **64 MiB shadow stack** is linked (`-z stack-size`) because typst's deeply recursive layout
passes would otherwise scribble linear memory — wasm has no stack guard page — and the build is
**SIMD-free** (`wasmi` has no `v128`).

The standout property is the **content/code split for assets**. typst's binary would otherwise be
dominated by tens of MB of embedded default fonts. Instead the fonts are separated into a content-
addressed `/usr/share/fonts` layer that the service scans **once at boot** into a warm `FontBook`; the
binary stays small, the font layer is shared by content, and — because the warm `FontBook` lives in linear
memory — a snapshot captures the loaded fonts, so a restored VM compiles at warm speed immediately. The
engine declares `CAP_FS_READ` (to scan the font layer and read sources) in its tier. The lesson is
general: *any* engine with large embedded assets (templates, ICU data, model weights) should layer them as
VFS content a warm service reads once — never bake megabytes of data into the code artifact. It is the
same content/code split as the Luau batteries (universal stdlib embedded in the interpreter) versus a
flavor's `.luau` libs (VFS layers): code is the binary, assets are layered VFS content.

---

## 11. System 18 — Images, flavors, and packages

A **flavor** is a content-addressed image *and* a product surface — a base plus domain packs, assembled by
`pkg_tar` (never staged by hand), with fixed owner and mtime so the tar bytes are a pure function of
inputs. The hierarchy stacks:

| Flavor | Adds | For |
|---|---|---|
| **minimal** | `sh`, the integral builtins, `pkgfsd`, `agent`, `tools` | building your own harness |
| **posix** | + coreutils | a shell for agents (e.g. RAG) |
| **loom** | + Luau + the analyzer | programmability |
| **paper** | + a document compiler (typst) | the document domain |
| **atlas** | + SQLite | the data domain |

Packs are **shared by content**: loom's Luau layer is a byte-identical input to paper and atlas, so Bazel
builds and stores it once and both flavors reference the same hash. `/bin` symlinks are generated by a
tool that reads each box's applet roster and points each name at the *lowest-privilege* box that provides
it — least-privilege dispatch, and `/bin` cannot drift from actual dispatch. Service install paths and
`/etc/services.d/<name>.json` fragments are generated from the stamped `mc_service` section of each
binary, so the install path, the fragment, and the artifact cannot disagree. Service fragments compose
through the layer stack, never as one global file — because services are a property of the layer that
pays the cold-start tax. Base provides the lazy `tools` broker, the lazy `adapters` service, and the
read-only `/tools` catalog tree so every image inherits the tool plane; domain packs add their own
service fragments. A flavor's
`require()` shim name must
not collide with a universal embedded battery; `sqlite`/`typst` are not embedded, so they load from the
layer (`require` order is cache → embedded → VFS).

The tool catalog is a sharded, lazily-loaded tree, not a monolith. `/etc/tools/catalog/` holds `index.json`
(one entry per tool — `address`, `integration`, `description`, and the content `sha` of its shard), the
content-addressed `records/<sha>` shards (each a connection-agnostic payload: input/output schema,
annotations, and the `/svc/adapters invoke` request template — never an address, description, or
connection reference), and an `index.sha256` digest sidecar. `/svc/tools` loads only the index at
activation and hydrates a single shard per `describe`/`call` (digest-verified, LRU-cached, fail-soft),
composing the record from the index entry ⊕ shard; `search`/`list` serve from the index alone. So
cold-start cost is O(index), independent of catalog size — a multi-thousand-tool catalog activates by
parsing a ~hundred-KiB index, and a `call` reads one ~KiB shard. The tree plus its digest is the single
source of truth; the in-memory index/shard cache is keyed by that digest, so a changed digest triggers a
reload and `/svc/tools` and `/tools` can never disagree. Mutation is host-control only: `catalog.apply`
(`caller == SYSTEM_CALLER`) writes the shards, then commits the index by an atomic single-file rename of
`index.json` (immutable shards make the rename the only ordering point). The commit is a **compare-and-swap
on the content digest**, not a counter: the caller passes the digest it edited against, and `apply` is
rejected if the live digest has moved (lost-update protection) and is a no-op if the incoming digest already
matches (idempotent — a retried or duplicate apply is free). A monotonic generation rides along for
observability only; correctness is the digest. The warm state snapshots with the VM. `/tools/<integration>/<owner>/<connection>/<tool>` is the file-tree discovery
face built from the same index, serving each leaf as its shard. `call`/`call_alias` require the caller's
kernel-stamped `CAP_NET`; discovery, `/tools`, and artifact cleanup stay unprivileged.

Catalogs are compiled **on the host, ahead of the request path** — not in the guest. `memcontainers/lib/
catalog-compiler` builds to a pure-compute `catalog-compiler.wasm` (zero imports) that both hosts
instantiate outside the VM — the Rust host via Cranelift, the JS host via `WebAssembly` — at native-class
speed, so the one normalizer never forks into a second implementation. It wraps `memcontainers/lib/parse`
(OpenAPI, Microsoft Graph workload filters with a generic path/tag subset filter, Google Discovery, GraphQL,
remote MCP) plus the curated executor-derived registry, and emits framed, content-addressed,
**connection-agnostic** bundles: a bundle is a pure function of `(spec, group)`, so it is reused across every
owner and connection. On `create`, the host resolves each declared connection ref to a registry integration
and tool groups (explicit selectors like `github/issues`, else sensible defaults), acquires the spec (a
caller-provided document, or a public fetch cached by content hash), compiles (the bundle cached by the
compiler-wasm artifact digest + bundle-schema version + source hash + options), re-prefixes the placeholder
addresses to the connection ref — touching only the index — and injects the sharded tree. A connection-driven
`create` therefore performs no in-guest compile and no registry round-trip; what was a ~19 s in-VM `wasmi`
compile plus a ~20 s reparse becomes a sub-second host compile (cached) and a tiny index load. The guest
`/svc/adapters` keeps `invoke` (the runtime HTTP path) and a non-default, elevation-gated `compile` fallback
that emits the same sharded tree through the shared `lib/parse/bundle` emitter from a *provided* source —
live discovery (GraphQL introspection, the remote-MCP handshake) is host-only, so the in-guest fallback can
never drift from the host's discovery protocol; registry resolution and the default compile path are host-side. `invoke` expands tool args into an `mc_http_request` blob, and the broker
supplies `X-MC-Connection: <integration>.<owner>.<connection>` derived from the tool address — shards carry
no connection reference.

The credential **and authorization** boundary is the host egress splice — the one point a `CAP_NET` guest
cannot route around. Secret-bearing connections declare the absolute `http`/`https` origins allowed to
receive the credential; the host normalizes the request origin and splices bearer/header/query credentials
only on an exact origin match, failing closed otherwise — even when a `CAP_NET` guest crafts an
`mc_http_request` directly — so the secret never enters guest memory. Destructive-action approval is enforced
at that same splice, before the credential is attached, for every connection-marked request alike
(`tools.call`, a direct `/svc/adapters invoke`, or a raw `mc_http_request`). The host classifies
destructiveness from the actual outgoing request (a non-idempotent method by default), evaluates the
embedder's `ConnectionPolicySet` (`block` → fail closed, `approve` → send, `require_approval` → prompt;
no match → the method classification), and on a prompt raises a typed `tool_approval` permission frame
carrying **host-computed** facts (connection, method, URL, origin, args digest) — never a guest-supplied
description. A lying catalog can therefore neither suppress a prompt nor spoof what is approved: **catalog
content is not a trust boundary**, and `requires_approval` annotations are descriptive hints only. Policy is
**connection-granular**: the splice keys on `integration.owner.connection` (resolved against
`integration.owner.connection.*`), never the tool address, so a rule matches a connection or coarser — a
per-tool pattern cannot be expressed and is rejected at construction. Both
host families (the Rust/wasmtime host driving the Elixir control plane, and the JS host) implement this
identically; `/svc/tools` and the host each gate on the caller's `CAP_NET`.

A connection is one embedder concept — `ConnectionDefinition {ref, auth, origins}` in the wire contract and
the JS SDK — but it decomposes into two host-side facets, each single-sourced, so the differing type names
are facets and not aliases for one record. The **egress facet** (the credential plus the absolute origins
allowed to receive it) lives once in the net's `ConnectionRegistry`; both the splice gate and live discovery
read the credential from there and nowhere else. The **catalog facet** — `CatalogConnection {ref, spec,
tools}`, the discovery/spec input that compiles into tool shards — carries no credential and no transport
identity at all; it recovers its egress origins by looking the ref up in that same registry. The credential
therefore exists in exactly one place, and a catalog can neither leak nor override it by construction.

`pkgcore` is the pure logic for `pkgfsd`, a demand-load package daemon: a dependency-free SHA-256, a
tab-separated catalog parser, and path/URL helpers. Packages are addressed by content hash, fetched from a
registry over `/net` on a miss, verified against their hash, and cached under `/var/persist/pkg/<sha>` —
the content-addressed layer model extended to on-demand tools.

---

## 12. System 19 — The host (wasmtime)

The host is the only *kernel driver* in the core (`memcontainers/hosts/wasmtime/`, ~2,800 LoC). Its job is
to load `kernel.wasm`, provide the `env` bridge, and pump `mc_tick` — and to do so *without ever making
policy*. It owns both boundaries it touches, both generated from contracts: the `env` bridge host side and
the `mc_ctl_*` control export lookups. A new bridge import emits a registration call to a nonexistent
handler — drift is a compile error on the host too.

The bridge imports the host must provide are the system's complete set of effect primitives: terminal
I/O, time (`CAP_AMBIENT`), entropy (`CAP_AMBIENT`), HTTP (request/poll/body/close), WebSocket
(connect/send/recv/close), host-call (start/poll/body/close), persistence (get/put/delete/list), an
optional threading set, and lifecycle (`yield`/`exit`/`log`/boot). The control exports the host calls are
lifecycle (`mc_init`/`mc_tick`/`mc_input`/`mc_resize`), a scratch-buffer VFS control channel, exec jobs,
host-control service calls (`mc_ctl_svc_call_start`/`poll`/`close`), and snapshot/quiescence. Host-control
service calls are the trusted mutation path for resident services such as `/svc/tools`: the kernel stamps
them as `SYSTEM_CALLER` with full caps and returns a bounded `[status][len][body]` result in the scratch
buffer. Every export is looked up as an `Option` because the host loads the kernel at runtime and cannot
know which exports a given artifact carries.

The control channel has two generated layers. The export signatures (`mc_ctl_*`) are the fixed ABI over
the shared scratch buffer; structured payloads inside that buffer are generated `message` codecs from
`control.kdl`. `ExecRequest` is the canonical exec request: `cmd` still means `/bin/sh -c`, but `cwd`,
`env`, and `stdin` are kernel-owned spawn facts, not strings the host rewrites into shell. The result is
`ExecOutcome` with raw captured stdout/stderr bytes and the real exit code. Filesystem inspection returns
`FileStat` and `DirEntries`; host-control resident-service calls use `SvcRequest`/`SvcResponse`; BEAM
egress uses `RelayEvent`. This is deliberately the same model as the syscall table: adding a payload
field updates the binary codec, OpenAPI projection, Rust host, JS host, Elixir edge, and conformance
vectors from one contract edit, or the build fails.

How effects are actually performed off-guest, all composing with the cooperative poll model:

- **Network/TLS** — the denied capability returns `-1` everywhere (the real policy gate, not a mock); the
  real one does genuine HTTP over rustls and WebSocket over a relay thread, using a buffer-then-poll model
  (a request runs on a thread into a slot; poll returns nothing until done, then the head, then the body
  streams). An async variant exists for a future multi-tenant server.
- **Persistence** — each key is a hex-encoded flat filename (no path traversal), `put` is atomic via
  temp+rename, and `get`/`list` return the *full* length so the kernel can resize and retry when its probe
  buffer was too small.
- **Host-call** — handlers run synchronously in `start`, split UTF-8 tool calls from binary-safe
  mount-driver calls.
- **Terminal** — best-effort raw mode with a panic hook that restores the terminal before a trap surfaces.

Determinism knobs live here: a `FixedClock` and a seeded RNG installed by the `deterministic()` builder
give byte-for-byte replayable runs; capabilities default to deny. The memory-safety invariant is strict:
the host never trusts a guest pointer — it validates every `[ptr, ptr+len)` range against current memory
*before* allocating a buffer sized by the untrusted length. And the two output paths are deliberately not
interchangeable: the TTY applies ONLCR (real CRLF), while the control-channel exec pipe is raw LF.

---

## 13. System 20 — The network and browser edge

The kernel and its Rust host are enough to run an agent locally. The rest of the edge has three built
pieces: a JavaScript host that runs the same `kernel.wasm` under Node.js, Bun, and browsers; a unified
client SDK plus web components; and an Elixir/OTP control-plane library that owns native wasmtime VMs
through a NIF. The **wire** contract and TypeScript remote client define the served boundary, but this
repository does not ship the Phoenix/HTTP/WebSocket adapter around the OTP library. A deployment adds
that adapter without becoming another kernel host.

### 13.1 The Elixir/OTP control plane — one owner per VM

`server/` is an Elixir library, not an axum server. `AgentOS.ControlPlane` addresses VMs by
`{namespace, key}` through a `Registry` and starts them under a `DynamicSupervisor`.
`AgentOS.Vm` is one GenServer per VM. It is the sole owner of the NIF resource wrapping the existing
Rust `KernelHost`, so mailbox serialization enforces the single-owner rule around each wasmtime store.

The facade exposes boot/restore, synchronous and structured exec, shell input/scrollback, filesystem
operations, resident-service calls, snapshot/commit, status, mounts, and relay queues for HTTP,
WebSocket, host-call, persistence, and tool-approval effects. The NIF runs blocking host work on dirty
schedulers. Idle VMs do no background ticking; the owner advances a kernel only when commanded.

This package deliberately stops below transport. It contains no router, listener, bearer-token parser,
quota store, eviction sweeper, or snapshot object store. A Phoenix or other host application may map
the projected wire/REST contract onto `AgentOS.ControlPlane`, define tenancy and persistence policy,
and relay effects. Those deployment concerns must not be claimed as built by this repository until an
actual adapter and its end-to-end tests land.

### 13.2 The wire protocol

`wire` is to the network what the syscall contract is to the kernel: the single place the served
client protocol is written. It projects the TypeScript client descriptors plus OpenAPI and AsyncAPI
specifications. The Elixir control-plane library currently consumes the projected control and LLB
messages; a future served adapter must consume the wire projection rather than transcribe it. A frame is
`[kind:u8][seq:u64 LE][body]`; control kinds carry JSON, but the
two highest-volume paths — terminal I/O and host-call/mount bulk — carry **length-prefixed raw binary,
never base64**. Message kinds are grouped by concern: handshake (`HELLO`/`WELCOME`, the latter carrying a
terminal byte offset to resume from), shell (`SHELL_IN`/`SHELL_OUT`), host-call relay
(`HOST_CALL`/`HOST_RESULT`), sessions (`SESSION_START`/`EVENT`/`END`), and permissions
(`PERMISSION_REQUEST`/`RESPONSE`). The server stamps a monotonic sequence on every outbound frame. The
wire version is bumped independently of the syscall ABI, and a server accepts only its own major.

### 13.3 The JavaScript host family — two hosts, one binary

The JS host is a byte-for-byte behavioral mirror of the Rust host: it implements the same `env` bridge over
web APIs (`fetch`, `WebSocket`, `crypto`, `node:fs`/OPFS) and runs the same tick loop, so the *same*
`kernel.wasm` + `base.tar` run unchanged in local Node.js, Bun, and browser runtimes, with no native addon and no server. The
async-drives-synchronous trick needs **no Asyncify, no `SharedArrayBuffer`, no `Atomics.wait`** — exactly
because the network bridge is poll-based (a `fetch` is kicked off and drained *between* ticks) and the run
loop yields a macrotask on idle ticks so the event loop can advance I/O. The host terminates TLS, so the
kernel only ever sees plaintext. Persistence in the browser solves the sync-bridge/async-storage mismatch
with a write-behind cache over OPFS → IndexedDB → memory. One JS-specific hazard is handled explicitly:
`WebAssembly.Memory.grow` detaches the backing buffer, so the memory view is re-derived on every access
(what wasmtime hides behind `data_mut`, the JS host does by hand). The snapshot format is identical to the
Rust host's, and a parity test boots the *same* artifacts the Rust e2e suite uses and asserts identical
output — A3 enforced, not asserted.

### 13.4 The `@mc/*` SDK and the web app

The SDK is the `@mc/*` scope. `@mc/core` is the unified `Vm` API over a pluggable backend — `exec`, a
`vm.fs` file API, `snapshot`/`fork`/`restore`, `commit` (as a layer or a snapshot), `mount`, host-resident
`tool`s, framed `session`s, and an interactive `shell` — with three interchangeable backends behind one
interface: an **embedded** backend (the JS host in-process), a **remote** backend (REST + per-VM WebSocket
to a conforming served host), and an auto-reconnecting unified socket. Its wire client consumes the
generated `wire` descriptors. `@mc/elements` is the integration package for embedding AgentOS into applications
without hand-wiring VM boot, context propagation, terminal/editor surfaces, artifact loading, or remote
connection setup; its `<mc-*>` elements resolve a `Vm` from an ancestor sandbox element or boot their own.
The **web app** embeds live VMs in the browser: the hero is a real shell, and the example workbench
drives the same API across images, shell/files, Luau, tools/connections, mounts, snapshots/builds,
permissions, automation, and remote lifecycle. Bazel stages the kernel, every shipped flavor, and the
catalog compiler under `/mc/`; flavors are fetched lazily. Browser tests boot real artifacts and verify
the JS host, OPFS persistence, SDK behavior, and the component lifecycle.

### 13.5 The portable build plane

The SDK also owns a build plane: a content-addressed image algebra for constructing VM images without an
imperative "build script" hidden beside the graph. The grammar lives in `llb.kdl` and projects into the
same canonical `message` codec family as control: a portable `Definition` is a DAG of `source`, `layer`,
`write`, `mkdir`, `rm`, `chmod`, `symlink`, `copy`, `exec`, `merge`, `diff`, `image`, and `cache` nodes.
`@mc/core` records or authors that DAG, serializes it with `toDefinition`, round-trips it with
`fromDefinition`, and hashes each vertex over the kernel digest, resolved inputs, and full structured
arguments. For `exec`, those arguments include the same `{cmd,cwd,env,stdin}` facts carried by
`ExecRequest`; the build cache cannot ignore cwd/env/stdin without changing the digest.

`solve` materializes a `Definition` by booting real VMs, applying each node, and committing real image
layers or snapshots. Shared vertices are registered as in-flight promises before they await, so concurrent
branches build once. Provenance is algebraic: layers carry producers, `merge` deduplicates by producer,
`diff` subtracts ancestry and materializes only when trees are disjoint, and image config merges
explicitly. A node is cacheable only when its output is a pure function of `(kernel, resolved inputs,
args)`; warm snapshots wait for zero inflight egress before capture. The store is content-addressed
across layer tarballs, blobs, manifests, and snapshots, with host-directory, in-memory, OPFS, and server
backends behind the same interface.

The same definition solves in every runtime. `solve-node.ts` is the Node.js/Bun platform backend; the
browser path uses OPFS and is verified in headless Chromium. The remote client can target a conforming
served host with build and raw-blob endpoints; that transport is not implemented by `server/`. Build records attach
`{definition, rootDigest, kernelDigest, storeRefs}` to the resulting image, so provenance is portable and
attestable rather than an in-memory `BuildState`.

### 13.6 The tool plane — one decision core, derived connections, live discovery

The two host families must make *identical* tool-plane decisions, so the decision logic is **single-source
by construction, not by parity test**. A `no_std` crate, `toolcore`, holds every consequential choice —
egress policy resolution (owner/action precedence, connection-granular patterns), tool-address + binding
validation, the discovery-request builder, and connection-reference parsing. The Rust host links it
natively; the JS host calls the *same* code compiled into `catalog-compiler.wasm` (`cc_policy_resolve`,
`cc_validate_address`, `cc_discovery_request`). Neither host re-implements any of it, so the wasmtime host
and the JS host cannot diverge — A3 enforced at the type level, upstream of the parity test.

A connection is just `{ ref, auth }`. The host **derives** the credential-egress origin allowlist from the
curated registry's `servers` field — *our* constant, never read from the live spec — so a user names only
the capability and the key, and a tampered upstream spec can never redirect a credential (it can at most
produce malformed tool shapes, which fail safely). This is why specs are fetched-and-cached rather than
vendored: the credential-tamper-safety that vendoring would buy is already provided by curated origins, so
the catalog source does not need to live in the repo. A connection with `auth: none` + origins is a
**public tool**: the host strips the connection marker and gates on origin alone, no credential attached.

Spec acquisition is kind-driven and single-source (`cc_discovery_request` describes it; the host is pure
transport). The three static-document kinds — `openapi`, `microsoft-graph` (the MS Graph OpenAPI), and
`google-discovery` (a Google discovery doc) — fetch their spec, differing only in the compiler front-end
that normalizes it. `graphql`/`mcp-remote`
integrations are **discovered live**: the host issues a GraphQL introspection query, or the remote-MCP
`initialize → notifications/initialized → tools/list` handshake (threading `Mcp-Session-Id`, parsing SSE),
as authenticated egress — the credential is applied host-side and never reaches the guest — then compiles
the response into the catalog. Compilation itself is the host-instantiated `catalog-compiler.wasm` (a pure,
zero-import module) producing the sharded, content-addressed bundle of §11. The capability surface bottoms
out in `mc.use("github.issues", token)`: it derives `{ ref: "github.org.main", auth }` and the
`github/issues` selector and creates a VM in one call.

---

## 14. System 21 — Build, testing, and the migration

### 14.1 Bazel — the zero-staleness graph

The build is a first-class subject because eliminating build pain is a primary reason AgentOS exists.
Every artifact — each `kernel.wasm`, every guest, every image, every generated binding — is a Bazel target
with declared inputs. The load-bearing edge: a test **`data`-depends** on the exact kernel its sources
produce, so "did you rebuild?" is structurally impossible. Rust deps come from two separate lockfiles kept
deliberately apart (a `no_std`/wasm32 set for the kernel, a native set for the host) so std
feature-unification can't break the `no_std` kernel. Zig is in the graph from day one for the C/C++ guest
lane via a hermetic `zig cc`/`c++` toolchain. Third-party source enters via `http_archive` + patches; only
patches and Zig glue live in-tree. The whole story is one command: `bazel test //...` regenerates and
diff-tests every projection, builds the kernel and guests and images, runs the suites against fresh
artifacts, and checks the size budget.

Every wound of an imperative build becomes a graph edge: a `cargo test` against a stale kernel becomes
`rust_test(data=[//…/kernel:kernel])`; image staging via `remove_dir_all` becomes `pkg_tar` (a pure
function of inputs, no wipe, no order); hardcoded `../../target/...` guest paths become runfiles; two
byte-identical tar implementations become one `pkg_tar` consumed by both the image and the tests;
checked-in vendored C/C++ becomes `http_archive(patches=[…])` with the glue in Zig; generated-file
freshness becomes `write_source_files` + `diff_test`; the size budget becomes a real `size_limit` test; and
cross-host behavior becomes a parity test over the same artifacts. The thing that stays imperative is honest and
small: a few `bazel run` developer conveniences that orchestrate nothing about correctness.

### 14.2 Testing — no mocks, real artifacts

The testing rule, inherited and made hermetic: **no mocks; drive the real `kernel.wasm` in a real host
against the real internet.** A test boots the kernel with capture sinks and a fixed clock/seeded RNG, runs
commands, and asserts on real stdout/stderr bytes and real exit codes — and because a kernel trap surfaces
as an error from the host, *booting is itself a test.* The e2e suite lives in two targets that share one
harness: `//memcontainers/tests/e2e:core` (the fast invariants — boot, line discipline, the shell, the
coreutils, the kernel control channel, the flavors, the resident-service primitives, the Luau loom boot;
sub-second) and `//memcontainers/tests/e2e:extended` (the heavy domain services, SQLite and typst, whose
real compiles and queries run for millions of fuel slices and boot the large `atlas`/`paper` images). The
split lets CI gate the fast invariants without paying the domain compiles. The one legitimate native-test
home is `shcore`, because it is pure logic, not the kernel. Conformance walks each guest's imports against
the contract. Two designed-in amplifiers leverage determinism: record/replay (record the bridge-input
transcript and a final memory hash; a replay diffs the hash) and differential fuzzing (every crash
reproducible from a seed).

### 14.3 The Zig-kernel experiment — completed and archived

The Zig port reached functional parity with the Rust kernel on its branch at roughly half the binary
size, but carried a workload-dependent runtime penalty. Asyncified wasm3 and re-entrant WAMR removed
different sources of overhead without removing the underlying interpreter-dispatch cost. The size win
did not justify that performance tradeoff for the shipped runtime.

The decision is closed for `develop`: `memcontainers/kernel/rust` is the only kernel implementation in
this tree, and Bazel has no kernel selector or parity matrix. The experiment, benchmarks, and
retrospective remain on `feature/zig`. Zig is still a first-class hermetic toolchain for the shell,
coreutils, sysroot, and C/C++ guest lane; archiving the kernel port did not remove those roles.

Any future alternative kernel starts as a new proposal against the unchanged language-neutral
contracts and must prove behavioral parity before it can affect the default. Until then, documentation
and build labels must describe the single Rust kernel that actually ships.

---

## 15. The repository layout

The tree is organized so that the build is visible from the outside and the OS we author is gathered in one
place. The root is a thin Bazel/deps/docs shell; the system lives under `memcontainers/`; the build
machinery lives under `bazel/`. The rules behind it: one boundary has one home; language and target are
obvious from the path; every directory is a Bazel package with a clear artifact; third-party source never
lives in-tree (only patches and glue do); and the things that are *consumers* of the OS (the server, the
web app) sit outside the core.

```
agent-os/                      ← the repository root: a Bazel/deps/docs shell
├── MODULE.bazel               # rules_rust + rules_zig + rules_js + rules_pkg; toolchains;
│                              #   http_archive(luau, sqlite, …) WITH patches (B3); the crate universes
├── BUILD.bazel                # shared TS workspace config + generated README badge target
├── SYSTEMS.md  README.md      # this document; the quickstart
│
├── bazel/                     # ★ the build machinery
│   ├── BUILD.bazel            #   makes bazel/ a package so the rules load as //bazel:<rule>.bzl
│   ├── release_wasm.bzl       #   the size/opt wasm transition (opt + panic=abort + LTO)
│   ├── wasm32_build_test.bzl  #   the wasm32 build-test rule
│   ├── mc_box.bzl             #   the wasi→mc conversion (mc_box / mc_wasi_program)
│   ├── mc_program.bzl         #   stamp + attest a guest (mc_program / mc_service_layer / cc_*)
│   ├── rust_e2e_test.bzl      #   the always-RELEASE-host e2e macro (core + extended)
│   └── tools/                 #   the mc build-graph executables:
│       ├── mc-stamp           #     append mc_tier/mc_budget/mc_service custom sections
│       ├── mc-attest          #     import-purity + tier-fit gate (a build error)
│       ├── mc-roster          #     least-privilege /bin symlink generation
│       ├── mc-svc-manifest    #     generate /etc/services.d fragments from stamped sections
│       ├── size               #     the size_limit budget rule
│       ├── wasi-trampoline / wasm-imports / smoke   #     the conversion + import-audit helpers
│
├── platforms/                 # wasm32 platforms; toolchains are registered in MODULE.bazel (B4)
│
├── third_party/               # ★ vendor LESS — only the dep fetch + patches live here (B3)
│   ├── luau/  sqlite/          #   build definitions and patches for fetched upstream source
│   │                          #   The SERVICE GLUE for these tools lives under memcontainers/programs/.
│
├── server/                    # Elixir/OTP VM control-plane library over the wasmtime NIF
├── web/                       # browser workbench; live VMs and executable SDK examples
│
└── memcontainers/             # ★ the OS we author
    ├── contracts/             #   THE FOUR BOUNDARIES — single source of truth
    │   ├── *.kdl  codegen/     #     the contracts + the projector
    │   ├── gen/  spec/         #     committed projections + generated specs (diff-gated)
    ├── kernel/rust/           #   the OS; wasmi is a native crate → kernel.wasm
    ├── sysroot/               #   the guest side of the ABI (Rust + Zig wrappers)
    ├── wasi-adapter/          #   WASI(preview1) → mc link-injected shim
    ├── shcore/                #   the OS-agnostic Zig shell engine
    ├── pkgcore/               #   pure logic for pkgfsd (sha256, catalog, path/url)
    ├── lib/                   #   shared support libs (catalog compiler, json, parse, stdx)
    ├── programs/              #   the guest userland AND the service glue
    │   ├── coreutils/         #     the per-tier multicall /bin
    │   ├── sh/  pkgfsd/  tools/  examples/    #     the rest of /bin + the example services
    │   ├── luau/              #     the Luau glue (Zig), batteries (.luau), skills
    │   ├── sqlite/            #     the SQLite service glue (Zig), require() lib, skill
    │   └── typst/             #     the typst service glue (Rust), fonts extractor, lib, skill
    ├── hosts/                 #   the two embedding LIBRARIES
    │   ├── wasmtime/          #     the Rust host (lib + CLI)
    │   └── js/                #     TS host for local Node.js/Bun and browser runtimes
    ├── sdk-js/                #   the @mc/{core,elements} TypeScript libraries
    ├── images/                #   base + flavor images via pkg_tar (no staging)
    ├── conformance/           #   the ABI coverage gate
    └── tests/                 #   real-artifact e2e suites (:core + :extended)
```

Two placement decisions encode design judgments. **The service glue lives under `programs/`, the dep under
`third_party/`.** For SQLite, Luau, and typst the upstream source is a pure dependency
(`third_party/<tool>/` = the `http_archive` build file + patches), while the AgentOS code that turns it
into a warm service — the Zig or Rust serve loop, the `require()` library, the skill, the font extractor —
is *our* program, so it sits with the other programs under `memcontainers/programs/<tool>/`. **The server
and the web app sit at the root, outside the core.** They are consumers of the OS (the server embeds the
wasmtime host; the web app embeds the JS host), parallel to how a deployment is not part of a kernel — the
two *hosts* (the embedding libraries) are `memcontainers/hosts/{wasmtime,js}`; the Elixir control plane
is not another host implementation.
The build rules and the mc tooling are centralized under `bazel/` (the cross-cutting Starlark rules and the
build-graph executables), while the three domain-specific `defs.bzl` files that only one package uses stay
with their package (the contracts codegen, the wasmtime host transition, the size budget).

**Naming.** **AgentOS** is the public product name. `agent-os` is the *repository and distribution
slug*; it is not a runtime prefix. The running system's identity is **`mc`**, frozen into the ABI itself —
the `mc` syscall module, `mc_sys_*`, `mc_ctl_*`, the `env` bridge, and the
`mc_tier`/`mc_budget`/`mc_service` custom sections — and carried through to binaries
(`tools`), services (`/svc/<name>`), and the JS scope (`@mc/*`, with `<mc-*>` elements).
Nothing in the runtime or ABI is prefixed `agent-os-`; Bazel labels need no prefix because the package
path *is* the namespace (`//memcontainers/kernel/rust`, `//memcontainers/contracts:mc_zig`).
`module(name = "agent-os")` is the canonical build identity. Platform forms follow their native
conventions: Elixir modules use `AgentOS.*`, the OTP app and paths use `agent_os`, environment variables
use `AGENTOS_*`, and stable protocol extensions use `x-agentos-*`.

---

## 16. Cross-cutting properties and the leverage the invariants buy

### 16.1 The load-bearing properties

These are the properties that distinguish AgentOS, each enforced by multiple systems at once:

1. **Containment.** A guest's entire computer — fds, pids, the VFS, the network as files — lives in linear
   memory and is built from kernel objects, never host objects. The host's raw handles are a kernel↔host
   secret; the proxy decoders reject path-escapes; netfs refuses to enumerate hosts. The agent inhabits a
   *different machine*, not a filtered view of ours.
2. **Monotonic capability narrowing, enforced twice.** Authority is `parent ∩ binary ∩ requested` at exec,
   checked as an in-kernel `EPERM` at every privileged syscall — *and* checked again at build time by
   attestation (a tool that imports more than its tier allows fails to compile). Default is deny; egress is
   gated; an `Isolated` task is fully confined and fully deterministic.
3. **Snapshottability as a free consequence of design.** Because all mutable state is in linear memory and
   the only nondeterminism is capability-gated, a snapshot is a memory copy, a restore is "the booted state
   *is* the image," and warmth (a SQLite connection, a font set) rides along — gated only by an
   inflight-egress quiesce so no raw host handle is captured.
4. **One ABI, generated, un-driftable.** Four boundaries live in language-neutral contracts and project
   into every consumer; a mismatch is a failed diff test, a failed build test, an attestation error, or a
   non-exhaustive-match compile error. This is what lets any wasm language be a guest and two kernel
   implementations be interchangeable.
5. **Tools as warm libraries, one core.** A heavy engine runs once as a resident service; its CLI, its
   `require()` library, and its serve loop are one binary, so they cannot drift and the library can never
   do less than the command — and crash-only supervision turns a panic into a warm restart invisible to a
   caller mid-call.
6. **Cooperative concurrency without async coloring.** A blocking syscall becomes a cooperative suspension
   via `wasmi`'s resumable host-trap, so guest code (the shell, a service loop) is written as straight-line
   blocking code, fuel-metered so nothing monopolizes the scheduler.

### 16.2 Leverage the invariants already bought

Several capabilities fall out of the invariants for nearly free; each is leverage, not new machinery.
The ones marked **(ABI-shaped)** are cheapest to settle
while the contract is still soft.

- **Deterministic record / replay.** The kernel is pure and snapshottable: record the ordered
  bridge-input transcript plus the final memory hash as a golden; a replay re-feeds it and diffs the hash.
  A whole regression class for nearly free, and the ideal bug report.
- **Differential fuzzing.** Determinism makes fuzzing honest: fuzz the syscall/bridge stream; every crash
  is reproducible from its seed. The kernel must never trap the host, and both host families must produce
  identical snapshots from identical inputs.
- **Generated observability (ABI-shaped).** Every call already flows through generated dispatch. Emit, from
  the same contract, an optional tracepoint per call into a linear-memory ring buffer drained via a control
  call — uniform, zero-maintenance tracing, and a precise cross-host diff localizer.
- **A generated capability audit, and an attestable kernel.** Project the capability × syscall matrix as a
  diff-tested artifact; with content-addressed `kernel.wasm` hashes, a kernel can be signed and bound to
  its capability surface and conformance report, per implementation.
- **A self-describing kernel.** Expose the ABI version, syscall surface, and capability matrix as files
  under `/sys`, generated from the contracts. An agent reasoning about its own sandbox introspects by
  reading a file; every host observes the same contract-derived view.
- **Deterministic fault injection at the bridge.** Because the host implements every effect, it can
  deterministically inject real failures (`ENOSPC`, dropped connections, clock skew, fuel starvation) keyed
  to a replay seed — reproducible chaos, no mocks.
- **A zero-copy bulk data plane (ABI-shaped).** The bridge passes `(ptr, len)` and the host copies. For RAG
  corpora, model tensors, and large file I/O, an iovec / shared-buffer convention generated from the
  contract avoids the double copy. It is an ABI shape — design it in before the freeze.

---

## 17. Implementation status

| Area | Status |
|---|---|
| Contracts + projector (Rust/Zig/TS/MD/AsyncAPI) | Built; 57 syscalls at ABI 1.7 |
| Rust kernel (scheduler, wasm runtime, VFS, filesystems, pipes, services, net, snapshots) | Built |
| Guest sysroot (Rust + Zig), WASI adapter, conformance/attestation | Built |
| Shell, multicall coreutils, Luau (+ batteries) | Built |
| Domain engines: SQLite (`atlas`) and typst (`paper`) | Built |
| Images/flavors (minimal→atlas/paper), `pkgfsd`, the stamping/roster tools | Built |
| Rust/wasmtime host (bridge, control, snapshot/restore, deterministic mode) | Built |
| Elixir/OTP actor-per-VM control plane over the wasmtime NIF | Built; transport/deployment adapter is outside this repository |
| Wire contract + TypeScript remote client | Built; requires a conforming served host |
| JS host family, `@mc/{core,elements}` SDK, web app | Built and tested with real browser artifacts |
| Zig-kernel experiment | Archived on `feature/zig`; not present in `develop` (§14.3) |

The one-line summary: **the OS core, both embedding host families, the SDK/browser workbench, and the
Elixir VM-control library are built and green on one generated ABI; an HTTP/WebSocket deployment around
the control plane is a separate integration, and the Zig-kernel experiment is archived.**

---

## 18. Open questions

These are the live decisions; each is bounded by the invariants and most are insured by determinism and
real-artifact conformance tests.

1. **Interpreter longevity.** Pin the eager-mode `wasmi` indefinitely, or budget for a hardened fork? The
   behavioral vectors (§9.3) are the insurance for either.
2. **A capability-request channel** for a fully-denied agent — a structured channel, never an ambient
   grant.
3. **Served-host policy and transport** — tenancy, authentication, quota/eviction, snapshot storage, and
   the HTTP/WebSocket adapter around the built actor-per-VM core.
4. **The two ABI-shaped levers** (generated tracepoints, the zero-copy data plane) and the capability-audit
   annotations are cheapest to settle while the contract is still soft.

---

## 19. Glossary

- **kernel** — the OS; compiles to and runs only on wasm; the shipped implementation is Rust and the
  artifact is `kernel.wasm`.
- **host** — a driver that loads the kernel, supplies the bridge, and ticks it. Two families, one binary:
  Rust/wasmtime and JS (local Node.js/Bun and browser), behaviorally identical and parity-tested. The
  Elixir control plane is a consumer of the wasmtime host, not another host.
- **guest** — a user program run inside the kernel by the embedded `wasmi` interpreter.
- **the four boundaries** — syscall (`mc`), bridge (`env`), control (`mc_ctl_*`), wire — each a contract,
  each projected into every consuming language.
- **capability / tier** — an 8-bit authority set, and the spawn-time dial (`Full`/`ReadWrite`/`ReadOnly`/
  `Isolated`) that selects its ceiling; narrows toward the leaves of the process tree.
- **fuel / tick** — a `wasmi` execution budget (2,000,000 instructions/quantum) and one bounded slice of
  kernel work; the host drives the loop and the kernel never blocks it.
- **snapshot** — the kernel's linear memory captured by the host; pause/fork/resume with no kernel
  cooperation, taken only at an inflight-egress-quiescent boundary.
- **resident service** — a long-lived guest that serves a name under `/svc` and answers typed calls with
  its engine warm; one binary, two activation modes (the `svc_serve` loop and the `_start` CLI), reached
  also as a `require()` library.
- **served filesystem** — a guest that *is* a filesystem subtree over the VFS (9P-style).
- **flavor / layer** — a content-addressed image (base + domain packs) assembled by `pkg_tar`, shared by
  content across flavors.
- **the two lanes** — how a domain engine reaches `mc`: Rust engines drive `mc` natively through the Rust
  sysroot (typst); C/C++ engines are reached through their C API by a Zig glue driver (SQLite, Luau).
- **parity oracle** — a known-good implementation a second one is differentially validated against (the
  Rust host is the oracle for the JS host).
- **the landmine** — the embedded `wasmi` must run in eager compilation mode; lazy translation charges
  guest fuel and corrupts the host on a dry-fuel resume.
- **mc** — the system's identity, frozen into the ABI: the `mc` syscall module, `mc_sys_*`, `mc_ctl_*`, the
  `env` bridge and the `@mc/*` scope. (`agent-os` is the repository and distribution slug.)
