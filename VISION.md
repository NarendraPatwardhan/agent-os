# agent-os — Vision & System Design

> **One line.** agent-os is a self-contained Unix that lives inside one WebAssembly module, on a zero-staleness Bazel build graph — memcontainers' design, shipped **Rust-first** by porting the proven kernel, and migrated to **Zig** later on a branch that is gated by Rust↔Zig behavior parity.

> **Status.** This is a design contract, not a record of what exists. It supersedes ad-hoc notes. If a change to the system contradicts a section here, change this document in the same commit. Line numbers drift; the *names* of things do not — search for the cited symbol.

---

## §0 — Purpose, and how to read this

### 0.1 Why this document exists

We have two ancestors:

1. **memcontainers** (`../memcontainers`) — a *mature* Rust system: a wasm microkernel that hosts AI agents, driven by wasmtime (native) and by bun/the browser (JS), running guest programs in an embedded `wasmi` interpreter. It is mature because of a small set of load-bearing decisions: a tiny, frozen ABI defined once and projected everywhere; capabilities that only ever narrow; and a testing rule of **no mocks, ever — only the real kernel through a real host**. Its weakness is the *build*: a 2,384-line `xtask` orchestrator, stale-artifact hazards, hand-staged images, and checked-in vendored libraries.

2. **zmc** (`../zmc`) — an *early* Zig port. It proves the hard part works: a Zig kernel compiled to `wasm32-freestanding`, driven by wasmtime, running guests through **wasmi compiled to wasm and linked in as a C-ABI shim**. It is the *seed and the evidence* for the eventual Zig kernel — not our starting point.

**agent-os is the synthesis, sequenced for low risk.** It keeps memcontainers' system design and discipline; it puts everything on a Bazel build graph (the seam we have wanted since we first wrote `xtask`); and it treats the kernel's implementation language as a **staged decision** rather than a day-one bet:

- **The kernel ships in Rust first**, by *porting* memcontainers rather than rewriting it. That keeps Rust's memory safety, keeps wasmi as a native dependency (no C seam yet), and — critically — lets us **copy proven code instead of authoring it**, which is the fastest path to a stable, green system and the lightest load on the agents building it.
- **Zig enters on day one for the C/C++ shim and build lane.** The C/C++ guests (sqlite, luau) and their glue compile through the hermetic `zig cc` / `zig c++` toolchain, with the glue written in Zig — so `rules_zig` 0.16 is in the graph from the start.
- **The Zig kernel comes later, on a branch**, once Bazel, the contract generators, and the services mechanism are stable. Because both kernels implement the *same* contracts and are driven by the *same* tests, the Zig kernel is validated by **behavior parity against the Rust kernel** — and that parity is a permanent asset, not just a migration tactic.

The code answers *what does this do*. This document answers *why is it shaped this way, what breaks if you change it, and where do you extend it.*

### 0.2 The thesis, and the three pillars

```
   ┏━ THE THESIS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   ┃ agent-os = memcontainers' DESIGN,
   ┃            on a zero-staleness BAZEL graph,
   ┃            shipped RUST-first (ported, not rewritten),
   ┃            migrated to ZIG behind a behavior-PARITY gate.
   ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

   Pillar 1 — DISCIPLINE (from memcontainers)
     • the kernel/host/guest model · the four boundaries (§4.2)
     • single-source-of-truth contracts · no-mocks e2e testing

   Pillar 2 — BAZEL (the orchestration bet — the highest-value, lowest-risk pillar)
     • one build graph, zero staleness (B1)
     • contracts projected to Rust + Zig + TS (B2)
     • vendor less / patch in place (B3) · hermetic toolchains (B4)

   Pillar 3 — STAGED IMPLEMENTATION (Rust now → Zig next, parity always)
     • kernel: RUST first — port memcontainers; safe, and fast to stable
     • Zig from day one for the C/C++ shim + build lane (rules_zig 0.16)
     • Zig kernel later on a branch, gated by Rust↔Zig parity (B7)
```

Read the ordering deliberately: **Bazel and the contracts are the durable, low-risk pillars** — you want them whichever language the kernel is in. The kernel language is staged so that the risky part (a Zig reimplementation) is taken on only after the safe parts are stable, and only behind a gate that proves it matches a known-good implementation.

### 0.3 Scope

**In scope:** the kernel(s), the contracts, the guest userland, the host drivers (Rust + JS), the server, the web SDK, and — centrally — the **Bazel build, the repository layout, and the staged migration** (§7, §8, §11). The build system is a first-class subject because eliminating build pain is a primary reason agent-os exists.

**Out of scope:** product/UX, model selection, and anything memcontainers documents that agent-os inherits unchanged (we cite memcontainers rather than re-deriving it).

### 0.4 How to read this, by role

- *"I want the pitch and the staging"* → §0.2, §2, §3, §11.
- *"I'm porting the Rust kernel into Bazel"* → §5, §7, §8, §11 Phase A.
- *"I'm setting up the build"* → §7 (Bazel), §8 (filetree). This is the heart.
- *"I'm planning the Zig kernel"* → §5.3, §9.6, §11 Phase B.
- *"What can I NOT do"* → §12 (anti-goals).

---

## §1 — Vocabulary

Pin these before reasoning about mechanisms.

| Term | Meaning |
|---|---|
| **kernel** | The OS. Compiles to `wasm32-freestanding`; ships as `kernel.wasm`. Never runs natively (A2). agent-os has **two implementations** of it (see *the two kernels*). |
| **the two kernels** | `kernel/rust` (Phase A — ported from memcontainers; uses `wasmi` as a native Rust crate) and `kernel/zig` (Phase B — a Zig reimplementation; uses `wasmi` via the C-ABI `interpreter` shim). Both build `kernel.wasm`, both implement the same `contracts/`, both pass the same suites. |
| **parity oracle** | A known-good implementation against which another is differentially validated. Two axes: host parity (Rust host ↔ JS host) and **kernel parity** (Rust kernel ↔ Zig kernel). |
| **host** | A *driver* of the kernel: loads `kernel.wasm`, implements the bridge, and ticks. Two families: a Rust host on wasmtime, a JS host for bun/browser. Same kernel binary under both (A3). |
| **guest** | A user program (`/bin/cat`, the shell, an agent) run *inside* the kernel by the embedded `wasmi` interpreter. Any language that targets wasm32 can be a guest. |
| **interpreter shim** | `wasmi` exposed as a `wasm32` staticlib through a small C ABI. Needed **only by `kernel/zig`**; the Rust kernel uses wasmi as an ordinary crate (§5.3). |
| **the four boundaries** | The contracts agent-os freezes and generates: **syscall** (`mc`, guest↔kernel), **bridge** (`env`, kernel↔host), **control** (`mc_ctl_*`, host↔kernel), **wire** (server↔client). See §4.2. |
| **contract** | A language-neutral spec file under `contracts/`. The single source of truth for one boundary. Bazel *projects* it into Rust, Zig, TS, docs, and conformance specs (§6). |
| **projection** | A generated artifact derived from a contract (the Rust bindings, the Zig `extern` block, the TS client). Never hand-edited; drift is a failed `diff_test`. |
| **fuel / tick** | A wasmi execution budget; and one bounded slice of kernel work (`mc_tick`). The host drives the loop; the kernel never blocks the host (§4.4). |
| **capability / tier** | What a task *can do* (an 8-bit set) and the spawn-time dial that selects it; narrows toward the leaves of the process tree (§4.3). |
| **snapshot** | `(linear memory, globals)`. All kernel state lives there, so a host can pause/fork/resume an agent with no kernel help (A8). |
| **resident service** | A long-lived guest that `serve`s a name under `/svc` and answers typed calls with its engine warm — the "tool as a library" mechanism (§4.5). |
| **flavor / layer** | A content-addressed image (base + domain packs) assembled by Bazel `pkg_tar`, not staged by hand. |

---

## §2 — What we learned from the two ancestors

### 2.1 memcontainers — what made it mature (keep all of it)

- **The OS is self-contained.** The agent's entire Unix — fd table, pids, pipes, VFS — lives in wasm linear memory. The host never hands the guest a host OS object. *Containment*, not *redaction*: a different computer, not a filtered view of ours.
- **Two ABIs, never confused, defined once.** `mc` (52 syscalls at ABI 1.3) is guest→kernel; `env` (26 imports) is kernel→host. The syscall surface is a **single macro table in `crates/abi`**; the kernel handlers and the guest `extern` block both *derive* from it, so adding a syscall without a handler is a **compile error**.
- **Capabilities narrow, never grant.** A child's authority = `parent ∩ binary-tier ∩ requested-tier`. 8 capabilities, 4 tiers, default-deny. Small, countable surfaces everywhere.
- **Cooperative, never blocks the host.** A syscall that can't complete records a block reason and yields; the host ticks again. Networking is *host-terminated* (TLS at the host) over a poll bridge — which lets an async JS host drive a synchronous-looking kernel.
- **Deterministic + snapshottable.** The kernel is a pure function of host inputs; the only nondeterminism (clock, entropy) is reachable only with `CAP_AMBIENT`. Snapshot is a property, not a feature.
- **No fake tests.** Every test boots the real `kernel.wasm` in a real host against the real internet. The kernel *cannot* run natively, so there is nothing to unit-test in isolation and nothing to mock. A conformance suite walks each guest's wasm imports against the single-source syscall table.
- **One landmine, documented.** `wasmi` 1.0.9 must run in **eager** compilation mode (lazy translation charges *guest* fuel and corrupts the host on a dry-fuel resume — see `../memcontainers/ctx/WASMI.md`). agent-os inherits this verbatim, for both kernels.

### 2.2 memcontainers — what hurt (the build, every time)

The design is clean; the *build* is an imperative orchestrator and good intentions: `cargo test` can run against a **stale** `kernel.wasm`; `build-programs` does `remove_dir_all(rootfs/bin)` and `build-wasi` must follow it; e2e finds heavy guests by hardcoded `../../target/...` paths; two tar implementations must stay byte-identical; third-party C/C++ is checked into the tree and patched in place; `/usr/share/fonts` and `/usr/bin/chromium` leak in; generated files are kept fresh by `--check` flags wired into npm `pretest` strings. **Every one of these is something the Bazel dependency graph removes** (§7.3) — and none of them is a reason to change the *language*. This is precisely why Bazel, not Zig, is the lead pillar.

### 2.3 zmc — what it proves (the seed for Phase B)

zmc is the evidence that the eventual Zig kernel is viable, and the prototype we will mine when we open the Zig branch:

| Proven (reuse in Phase B) | Immature (the Bazel/contracts pillars fix) |
|---|---|
| Zig kernel → `wasm32-freestanding`, driven by wasmtime (same `@cImport` pattern as `bazel-experiments/compile-zig`). | One flat Zig package; no kernel/host/guest/abi boundaries. |
| **wasmi-as-C-shim works e2e** (5 C exports + 2 callbacks): wasmi (Rust) → wasm32 staticlib → linked into the kernel → interprets guests. | ABI is **3 syscalls, triplicated by hand**; no source of truth. |
| **859 KB** kernel.wasm *including* the interpreter (`opt-level=s`, LTO, `panic=abort`). | The `mc_ctl_*` control channel is **untyped**. |
| A real cooperative kernel: VFS, a tick-driven shell, a process table. | No conformance; tests are one assertion script in the host's `main`. |
| Errno table + `(major<<16)|minor` ABI version copied verbatim from memcontainers. | 125 MB blobs checked in; `cargo` shelled out of `build.zig`; hardcoded paths. |

**Read:** in Phase B we keep zmc's wasmi-shim integration and its VFS/scheduler seed, and replace its scaffolding with our contracts + Bazel — but only after Phase A's Rust kernel has set the behavior bar that zmc's successor must match.

---

## §3 — First principles (the constitution)

Three families. **A1–A9** are inherited from memcontainers' R1–R9 (the OS model); non-negotiable, numbers stable to cite in code. **B1–B7** are agent-os's additions (the build, the staging, the parity discipline). **C1** is the authoring discipline every contributor — human or agent — follows when writing the code (§3.3).

### 3.1 A-invariants — the OS model (inherited, unchanged; bind both kernels)

- **A1 — The OS is self-contained.** The agent's Unix lives in wasm linear memory; a kernel fd is not a host fd, a kernel pid is not a host process.
- **A2 — WASM only.** The kernel compiles to and runs on `wasm32-freestanding` exclusively. Never native, not even for tests. (Both the Rust and Zig kernels obey this.)
- **A3 — Two host families, one binary.** A Rust/wasmtime host and a JS host load the *same* `kernel.wasm` and behave identically.
- **A4 — The bridge is the only surface.** The kernel imports no symbol outside the `env` bridge. No WASI, no bindgen, no Component Model.
- **A5 — No native side effects.** Every observable effect flows through a bridge import; the kernel is a pure function of host inputs.
- **A6 — Freestanding.** `no_std` (Rust) / freestanding (Zig); may allocate, depends on no host filesystem and no C runtime.
- **A7 — Deterministic by default.** Same host inputs → same host outputs; nondeterminism only via `CAP_AMBIENT`.
- **A8 — Snapshottable.** All mutable state is in linear memory + globals; capture `(memory, globals)` to pause/fork/resume.
- **A9 — Capability-gated egress.** Any bridge import reaching outside the host is gateable; denial surfaces as an in-kernel error (`EPERM`), never a host exception.

(Inherited derived rules also kept: **single source of truth per boundary**; **containment over redaction**; **everything is a file**; **fail-closed**.)

### 3.2 B-invariants — the agent-os additions

- **B1 — One build graph, zero staleness.** Every artifact — each `kernel.wasm`, every guest, `base.tar`, every generated binding — is a Bazel target with **declared inputs**. The kernel a test runs is *always* the kernel its sources produce, because the test `data`-depends on the kernel target. No `xtask`, no manual `cp`, no `remove_dir_all`, no "did you rebuild?" There is `bazel test //...`.
- **B2 — Contracts are language-neutral and projected into every language.** The four boundaries (§4.2) are data files under `contracts/`. A Bazel-built projector emits the **Rust** bindings, the **Zig** `extern`/dispatch, the **TS** client, the conformance specs, and the docs from the one file. Drift is a failed `diff_test`. (All three language projections have a consumer from day one — Rust kernel, Zig shims, TS client — so the projector is exercised across every language immediately.)
- **B3 — Vendor less, patch in place.** Third-party libraries enter via `http_archive(urls=…, sha256=…, patches=[…])`. Only patch files live in our tree.
- **B4 — Hermetic toolchains.** Rust, Zig (0.16.0, validated in `bazel-experiments`), and Node/bun are pinned Bazel toolchains. No host fonts, no host chromium, no tool from `$PATH`.
- **B5 — Size is a test, and a lever.** The kernel size budget is a `size_test` regardless of language. The Rust kernel meets a baseline budget; the Zig kernel is the lever to push it lower — adopted only when the parity gate (B7) says it earns its place. Per-guest budgets (`mc_budget`) are enforced at exec as in memcontainers.
- **B6 — Real artifacts only.** No mocks; tests drive the real kernel through a real host. Bazel adds what memcontainers lacked: the artifact is **never stale** (B1) and the environment is **hermetic** (B4).
- **B7 — Many implementations, one contract, parity-gated.** A2 says the kernel is wasm; A3 says one binary runs under two hosts. B7 generalizes: **a kernel implementation ships only when it matches the others, bit-for-bit, on the shared e2e + conformance suite.** We start with one kernel (Rust) and add a second (Zig) on a branch; the second is accepted by *parity*, not by inspection. Two implementations of one contract is also a contract-ambiguity detector — anything the spec left underspecified shows up as a parity diff. Parity is permanent infrastructure, not a one-time migration check.

### 3.3 C-invariant — the authoring discipline (for every contributor, human or agent)

- **C1 — Design first; write code that teaches.** This system is built as much by agents as by people, so *how* the code is written is itself load-bearing. Before adding or changing a subsystem, reason from first principles about the qualities that actually bear on *this* change — for agent-os that is almost always some of: **robustness** (never trap the host, never corrupt a snapshot, fail closed), **extensibility** (a new filesystem, syscall, or service should slot in without touching the core — §2.12, §6), **simplicity and small surfaces** (a few countable primitives beat clever ones), and **determinism & testability** (it must stay replayable and parity-checkable — A7/B7). Name the qualities you optimized for and justify the shape against §3 *in the change itself*. Then write it **literately**: code whose names, structure, and comments explain *why* — the alternative weighed, the invariant being upheld, the failure stated before the grant — rather than narrating *what* each line does. The VISION carries the system's global "why"; every file carries its local "why," so the next reader (often another agent) can extend it without re-deriving it. A clever line with no rationale is a defect; a well-named, well-explained boundary is the unit of progress.

> If you reach for a pattern that contradicts §3, the principle wins — escalate, don't bend it silently. The A-, B-, and C-numbers are cited in code; keep them.

---

## §4 — The core model

### 4.1 Three layers, two interchangeable kernels, four contracts

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │ HOST  (a driver, not a participant)                                    │
   │   Rust/wasmtime  ·  JS/bun  ·  JS/browser   ── all load the SAME ──┐   │
   └─────────────────────────────┬───────────────────────────────────┐ │   │
            env bridge (A4)       │       mc_ctl_* control channel     │ │   │
   ┌─────────────────────────────▼───────────────────────────────────▼─▼─┐ │
   │ kernel.wasm   ── ONE of two interchangeable implementations ──        │ │
   │   ┌─────────────────────────┐        ┌─────────────────────────┐     │ │
   │   │ kernel/rust  (Phase A)  │  ⇄ B7  │ kernel/zig   (Phase B)  │     │ │
   │   │ ported from mc;         │ parity │ Zig reimpl;             │     │ │
   │   │ wasmi = native crate    │        │ wasmi via C-ABI shim    │     │ │
   │   └─────────────────────────┘        └─────────────────────────┘     │ │
   │   both: scheduler · capabilities · VFS+namespaces · pipes · net       │ │
   │   both run guests via wasmi:    mc syscall ABI (A1)                    │ │
   │     GUEST  /bin/sh, cat, agent, luau, sqlite  (Rust · Zig · C/C++)     │ │
   └──────────────────────────────────────────────────────────────────────┘ │
   SERVER  mc-server (Rust/axum) ── wire protocol ──> SDK/clients (TS) ──────┘
```

The runtime nesting is **host wasmtime → kernel.wasm → wasmi → guest.wasm** (a fourth, kernel-mediated `pcall` level handles C/C++ guests that need non-local exit). The two kernel boxes are swappable because they implement the identical four boundaries; B7 keeps them honest.

### 4.2 The four boundaries (agent-os freezes and generates all four)

memcontainers froze two ABIs as source-of-truth (`mc`, `env`) and generated a third (`wire`); its control channel grew organically and zmc's is ad hoc. **agent-os elevates all four to generated contracts** — the biggest structural upgrade over both ancestors, and the thing that makes the two kernels interchangeable.

| Boundary | Module | Direction | Phase-A consumers | Phase-B adds |
|---|---|---|---|---|
| **syscall** | `mc` | guest → kernel | Rust kernel dispatch; Rust sysroot/wasmi registration; **Zig** C/C++-guest shims; conformance | Zig kernel dispatch + Zig sysroot |
| **bridge** | `env` | kernel → host | Rust kernel imports; Rust host; JS host | Zig kernel imports |
| **control** | `mc_ctl_*` | host → kernel | Rust kernel exports; Rust host; JS host | Zig kernel exports |
| **wire** | — | server ↔ client | Rust server; TS client; AsyncAPI/OpenAPI; golden vectors | (unchanged) |

All four become files under `contracts/` projected by one tool (§6). Because none of the kernels, hosts, shims, or clients *is* the source of truth — the contract is — a Rust kernel, a Zig kernel, a Rust shim, a Rust server, and a TS client cannot drift.

### 4.3 The three axes of a task (kept orthogonal)

- **Identity** — *who is acting?* A pid. Not authority.
- **Namespace** — *what can it see?* A Plan 9-style per-process copy-on-write mount table; forks on spawn. Not capability.
- **Capability** — *what can it do?* An 8-bit set + optional confinement root; computed at exec as `parent ∩ binary ∩ requested`, monotonically narrowing. The 4 tiers (`Full`/`ReadWrite`/`ReadOnly`/`Isolated`) are the spawn-time dial; `Isolated` is the only fully deterministic tier.

### 4.4 The hot path: cooperate, never block

`mc_tick` is the heartbeat. A guest syscall is a **resumable dance**: the wasmi host-function for each syscall records the request and traps; the kernel fulfills it against the real VFS/pipes/net, then resumes the guest with the result. A would-block parks on a block reason; fuel exhaustion charges a quantum and re-parks. This composes guest scheduling onto the cooperative model with no scheduler special-casing — and it is exactly what both memcontainers (Rust) and zmc (Zig) already implement, which is *why* parity between the two kernels is achievable.

### 4.5 Resident services: tools as libraries (one binary, two activation modes)

memcontainers' `ctx/SERVICES.md` observes that a heavy tool (sqlite, typst, the type-checker) pays a **cold-start tax** on every invocation. Its fix is the **resident service** — a long-lived guest that `serve`s a name and answers typed request/response calls with its engine warm — exposed so that `require("sqlite")` in a script and `/bin/sqlite` on the command line are **one implementation: "never two codebases that drift, never a library that can do less than the command."** agent-os adopts the principle. The five additive syscalls (`svc_connect`/`svc_call` for clients, `svc_serve`/`svc_recv`/`svc_respond` for servers), routed through a `servicefs` modeled on `servedfs`, become five rows in `contracts/syscalls.kdl` (a generated ABI minor bump, §6); services appear under `/svc/<name>`.

**Where we depart: there is no `/bin/<tool>-svc`.** SERVICES.md ships *two* binaries per tool (`-svc` resident loop + thin CLI). We reject the dual-binary `-svc` convention: it doubles the `/bin` surface and leaks an implementation mode into the user-visible namespace. agent-os ships **one binary per tool** with two *activation modes*, chosen by the system:

- The tool is built once (`mc_program()` → one `.wasm`). Service-capability is a **property, not a second artifact**: a `mc_service` custom section (stamped like `mc_tier`/`mc_budget`, §6) plus an entry in `/etc/mc-services.json` (name, tier, budget, `eager|lazy`).
- Invoked normally, `/bin/sqlite foo.db` is a one-shot CLI.
- The kernel's **service manager** can instead run that *same* binary in resident mode (inetd / socket-activation style): on first `svc_connect("sqlite")` it lazily activates it as a warm server at `/svc/sqlite`; later calls reuse it. `require("sqlite")` is sugar over `svc_connect`.
- The binary distinguishes the modes through the **contract**, not through `argv[0]`: the kernel enters the generated `svc_serve` path for resident mode and `_start` for one-shot.

Services are part of **Phase A** ("the services stuff" we stabilize before the Zig branch). A resident service is still a guest with a tier and a budget (§4.3), still captured by a snapshot (A8), and (see §15.7) can be **crash-only and supervised**. Because services are defined entirely by the `mc`/control contracts, they work identically under both kernels — another reason to land them before Phase B.

---

## §5 — Language strategy (staged)

> **Question:** if Zig is the eventual goal for the kernel, why start in Rust? **Answer:** because we can *port* memcontainers' kernel instead of *rewriting* it. Porting reuses thousands of lines of battle-tested, memory-safe code, keeps the native wasmi integration (no C seam), and gets us to a stable, green, fully-Bazelized system far faster and with far less authoring risk. Zig's wins (size, toolchain unification, freestanding control) are real but secondary, and we capture them on a branch once everything around the kernel is solid — validated by parity, not by faith.

### 5.1 What is written in what, and why — and when

| Component | Language | Phase | Why |
|---|---|---|---|
| **kernel** (`kernel.wasm`) | **Rust → then Zig** | A → B | A: port memcontainers (safe, copyable, fast to stable, wasmi native). B: Zig reimplementation for size/control, gated by parity (B7). |
| **interpreter** (wasmi) | **Rust** | A: native crate dep; B: + C-ABI staticlib | A: the Rust kernel uses wasmi in-process — *no C seam*. B: the same wasmi wrapped behind a C ABI for the Zig kernel (`//interpreter`). |
| **guest sysroot + coreutils** (`/bin`) | **Rust** (ported) | A | Copy memcontainers' `sysroot` + `programs` to reduce authoring load; the guest-language question (Zig/Toybox-via-zig-cc/keep-uutils) is revisited post-stabilization (§13). |
| **shell engine** | **Rust** (ported) | A | Copy `shcore`; natively unit-testable (the one legit native-test home, §9.4). |
| **C/C++ guests + their shims/glue** | **Zig + `zig cc`/`zig c++`** | **A (day one)** | sqlite, luau via `http_archive`+patches, compiled by the hermetic zig toolchain; the compat/glue shims written in **Zig**, not C/C++. This is where Zig enters, and why `rules_zig` 0.16 is in from the start. |
| **WASI→mc adapter** | **Rust** (ported), Zig glue | A | The adapter copies from memcontainers; the per-tool C/C++ compat shims it links into are Zig. |
| **mc-server** | **Rust** | A | axum/tokio, S3, real net; size irrelevant server-side. |
| **Rust host driver** | **Rust** | A | wasmtime's first-class API; shared lib + CLI. |
| **JS host + web SDK** | **TypeScript** | A | Browser/bun is a host family (A3); the in-browser agent UX. |
| **the projector** (contracts → bindings) | **Rust** | A | Reuses memcontainers' table logic; emits Rust/Zig/TS/JSON/docs. |

### 5.2 The build edges, by phase

**Phase A — the Rust kernel has no Zig↔Rust kernel seam** (wasmi is a plain dependency). Zig is present only for the C/C++ guest lane.

```python
# kernel/rust/BUILD.bazel  (Phase A — ported from memcontainers)
rust_shared_library(                       # cdylib → kernel.wasm
    name = "kernel",
    srcs = glob(["src/**/*.rs"]),
    platform = "//platforms:wasm32_freestanding",
    deps = [
        "@crates//:wasmi",                 # NATIVE Rust dep — no C-ABI shim in Phase A
        "//contracts:mc_rust",             # generated mc dispatch + wasmi registration
        "//contracts:env_rust",
        "//contracts:ctl_rust",
    ],
)
```

**Phase B — the Zig kernel adds exactly one new seam**, isolated to itself:

```python
# kernel/zig/BUILD.bazel  (Phase B — the parity-gated branch)
zig_binary(
    name = "kernel",                       # -> kernel.wasm (same contract, different impl)
    main = "src/main.zig",
    target_platform = "//platforms:wasm32_freestanding",
    mode = "release_small",
    linkopts = ["-fno-entry", "-rdynamic"],
    deps = [
        "//interpreter:wasmi_shim",        # wasmi → wasm32 staticlib + C ABI (Zig-only seam)
        "//contracts:mc_zig",
        "//contracts:env_zig",
        "//contracts:ctl_zig",
    ],
)
```

A flag (`--//kernel:impl=rust|zig`) or two aliases select which `kernel.wasm` the rest of the graph consumes; the test matrix (§9.6) builds both.

### 5.3 The interpreter, in both worlds (preserve behavior, not implementation)

wasmi's fuel-metered, **resumable host-trap** API (`call_resumable` / `OutOfFuel` / `HostTrap` / `inv.resume`, plus `StoreLimits` and **eager** compilation) is the linchpin. In **Phase A** it is used directly from Rust, ergonomically and type-safely, exactly as memcontainers does. In **Phase B** the *same* wasmi is wrapped behind a C ABI (zmc's 5-exports-+-2-callbacks), with the resumable/fuel state machine kept **fat on the Rust side of the shim** so the Zig kernel sees a clean verb ("run this guest until it syscalls / blocks / exits"), not raw wasmi. Either way the *observable* behavior — cooperative quantum, `OutOfFuel` re-park, `HostTrap` suspension, per-guest budgets — is fixed by the contract and enforced by parity (B7). The C-seam risk I would otherwise worry about is deferred to Phase B and bounded to one package.

---

## §6 — Contracts as the single source of truth

> A Rust macro gave memcontainers "zero ABI drift" within one language. agent-os is polyglot from day one (Rust kernel, Zig shims, TS client — and a Zig kernel later), so the source of truth is lifted *out of any one language* into data, and Bazel projects it into all of them.

### 6.1 The shape

```
contracts/
├── syscalls.kdl      # the `mc` table: one row per syscall (name, args:i32…, ret, doc, exclusions)
├── bridge.kdl        # the `env` imports + kernel exports
├── control.kdl       # the `mc_ctl_*` host↔kernel channel (typed at last — fixes zmc)
├── wire.kdl          # server↔client messages + REST routes
├── constants.kdl     # errno, capabilities, tiers, ABI version (major<<16|minor)
└── BUILD.bazel       # abi_library() targets — one projection per language per contract
```

### 6.2 The projector and the `abi_library` macro

A single `rust_binary`, `//contracts/codegen:projector`, reads a contract and emits one target language. A Starlark macro wraps it so each projection is a normal target with a drift gate:

```python
# contracts/codegen/defs.bzl  (sketch)
def abi_library(name, contract, langs):
    for lang in langs:                       # "rust", "zig", "ts", "asyncapi", "md"
        native.genrule(
            name = "%s_%s" % (name, lang),
            srcs = [contract],
            outs = ["%s.gen.%s" % (name, _ext(lang))],
            tools = ["//contracts/codegen:projector"],
            cmd = "$(location //contracts/codegen:projector) --lang %s $< > $@" % lang,
        )
        write_source_files(name = "%s_%s_check" % (name, lang), ...)  # B2 drift gate
```

```python
# contracts/BUILD.bazel
abi_library(name = "mc",   contract = "syscalls.kdl", langs = ["rust", "zig", "ts", "md"])
abi_library(name = "env",  contract = "bridge.kdl",   langs = ["rust", "zig", "ts"])
abi_library(name = "ctl",  contract = "control.kdl",  langs = ["rust", "zig", "ts"])
abi_library(name = "wire", contract = "wire.kdl",     langs = ["rust", "ts", "asyncapi"])
```

### 6.3 One source → many sinks (and two kernels)

Adding a syscall is a one-line edit to `syscalls.kdl`. `bazel test //...` then regenerates every projection; the Rust kernel's exhaustive `match` and the Zig kernel's exhaustive `switch` both fail to compile until each has a handler (drift = compile error, in *both* languages); conformance fails until a guest exercises it. The polyglot projector is validated immediately because **Phase A already has a Rust consumer (the kernel), a Zig consumer (the C/C++ guest shims), and a TS consumer (the client)** — so by the time the Zig kernel arrives, the Zig projection it needs is already battle-tested by the shims.

---

## §7 — The build system (Bazel)

> This is why agent-os exists. Every pain point in §2.2 is a thing the dependency graph removes — independent of the kernel's language.

### 7.1 Module & toolchains (`MODULE.bazel`)

```python
module(name = "agent-os")

bazel_dep(name = "rules_rust", version = "…")
bazel_dep(name = "rules_zig",  version = "0.16.0")   # in from day one (C/C++ shim lane)
bazel_dep(name = "rules_js",   version = "…")        # + aspect rules_ts
bazel_dep(name = "aspect_bazel_lib", version = "…")  # write_source_files, diff_test
bazel_dep(name = "rules_pkg",  version = "…")        # pkg_tar for images
bazel_dep(name = "platforms",  version = "1.1.0")

# Rust: host (native) + guest/kernel (wasm32-unknown-unknown / freestanding) targets.
#   crate_universe pins deps from TWO lockfiles, not one: @crates (kernel — wasmi/talc,
#   no_std/wasm32, //kernel/rust:Cargo.lock) and @host_crates (host — wasmtime, std/native,
#   //hosts/wasmtime:Cargo.lock). They MUST stay separate: a single shared Cargo resolution
#   feature-unifies common deps and switches on std features (wasmtime pulls bitflags/std)
#   that break the no_std kernel (duplicate #[panic_handler]).
# Zig 0.16.0 pinned via the custom index (see bazel-experiments/compile-zig-wasm).
zig = use_extension("@rules_zig//zig:extensions.bzl", "zig")
zig.toolchain(zig_version = "0.16.0")

# B3 — vendor less, patch in place (the C/C++ guests + wasmtime):
http_archive(name = "luau",     urls = […], sha256 = "…", patches = ["//third_party/luau:patches/…"])
http_archive(name = "sqlite",   urls = […], sha256 = "…", patches = ["//third_party/sqlite:patches/…"])
# wasmtime is NOT http_archived (so there is no prebuilt libwasmtime.a): it is pinned in
# @host_crates and built from SOURCE via crate_universe (§7.1). That is why host_musl static
# linking buys little and is deferred (§8.1).
```

`.bazelrc` carries the two settings proven in `bazel-experiments`:

```
# No global --platforms: host-side tools build for the autodetected native host; wasm
# targets transition to //platforms:wasm32_freestanding, and the host binary transitions to
# compilation_mode=opt. (host_musl static linking is deferred — §8.1.)
build --sandbox_add_mount_pair=/tmp        # zig cache writable in the sandbox
# (rules_zig 0.16 sets ZIG_GLOBAL_CACHE_DIR on the translate-c action — see the memory note)
```

### 7.2 The artifact graph

```
contracts/*.kdl ──projector──> {mc,env,ctl,wire}.gen.{rs,zig,ts}
       │                               │            │        │
       ▼                               ▼            ▼        ▼
 @crates//:wasmi ─(native dep)─> kernel/rust ──┐  Zig C/C++  //sdk-js:core
 //interpreter (wasm32 +C ABI)─> kernel/zig ───┤  guest      (ts_project)
   (Phase B only)                              │  shims
                                  both emit ── kernel.wasm ──┐
 //programs(Rust) //sysroot //wasi-adapter     │            │
 //third_party/{luau,sqlite} (zig cc + patches)│            │
        └───────────────┬──────────────────────┘            │
                        ▼                                    │
                 //images:base_tar  (pkg_tar — NO manual staging)
                        │                                    │
        ┌───────────────┼───────────────────────┐           │
        ▼               ▼                        ▼           ▼
 //hosts/wasmtime  //tests/e2e (matrix:         //server   //web:app
 (rust lib+cli)     {rust,zig}×{rust-host} +    (rust/axum) (assets are
        ▲           //tests/parity)                          DEPS, not cp)
        └── same kernel.wasm under both hosts (A3); both kernels under the suite (B7) ──┘
```

The load-bearing edge: **`//tests/e2e` `data`-depends on the selected `kernel.wasm`** — the death of the §2.2 staleness class. In Phase B that edge fans out to *both* kernels (§9.6).

### 7.3 Old wound → Bazel cure

| memcontainers pain (§2.2) | agent-os cure |
|---|---|
| `cargo test` runs against a stale kernel | `rust_test(data=[//kernel:kernel])` — tests depend on the artifact (B1). |
| `build-wasi` must follow `build-programs` (`remove_dir_all`) | `pkg_tar(srcs=[…])` — the image is a pure function of its inputs; no wipe, no order. |
| `fs::copy` staging into `rootfs/bin` | `pkg_files`/`pkg_tar` assemble in the sandbox; nothing copied into a source tree. |
| hardcoded `../../target/...` guest paths | `data = [//third_party/sqlite:sqlite.wasm, …]` — runfiles, no heuristic. |
| two byte-identical tar implementations | one `pkg_tar` consumed by image **and** tests. |
| checked-in `loom/vendor/luau`, `crates/wasi/sqlite/vendor` | `http_archive(patches=[…])` — only patch files in-tree (B3). |
| C/C++ `// mc PATCH` edits + `-fno-exceptions` glue | the same patches as real `.patch` files; the glue is **Zig**, compiled by hermetic `zig cc`/`c++`. |
| `/usr/share/fonts`, `/usr/bin/chromium`, bare `zig`/`rustc`/`bun` | hermetic toolchains; fonts as data; a pinned browser repo (B4). |
| `wire.gen.ts` freshness via npm `pretest --check` | `write_source_files` + `diff_test` in the graph (B2). |
| size budget as a README aspiration | `size_test` on each `kernel.wasm` (B5). |
| "is my port faithful?" (the new question) | the **two-kernel parity matrix** (B7, §9.6) — a thing memcontainers never had. |

### 7.4 What stays imperative (honestly)

Bazel is the graph, not a scripting language. A few developer conveniences (`bazel run //tools:demo`, `//tools:fmt`) remain thin wrappers, but they orchestrate *nothing about correctness* — every artifact they touch is already a hermetic target. The 2,384-line `xtask` becomes a `BUILD` graph plus a few `bazel run` aliases.

---

## §8 — The repository layout (the filetree)

> Designed so that (a) each boundary has one home, (b) language and target are obvious from the path, (c) every directory is a Bazel package with a clear artifact, (d) third-party source never lives in-tree, and (e) the **two kernels sit side by side** so parity is structural.

```
agent-os/
├── MODULE.bazel                  # rules_rust + rules_zig(0.16) + rules_js + pkg; toolchains;
│                                 #   http_archive(luau, sqlite, wasmtime) WITH patches (B3)
├── MODULE.bazel.lock
├── .bazelrc                      # platforms; sandbox /tmp mount; zig translate-c cache (B4)
├── .bazelversion
├── BUILD.bazel                   # root aliases: //:kernel (-> rust|zig), //:server, //:e2e, //:web
├── VISION.md                     # this document
├── README.md                     # quickstart: `bazel test //...`
│
├── platforms/                    # :wasm32_freestanding (kernels/guests), :wasm32_unknown
│   └── BUILD.bazel               #   (rust→wasm), :wasm32_wasi (converted tools), :host_musl
│
├── toolchains/                   # hermetic toolchains (B4)
│   ├── BUILD.bazel
│   └── zig_cc/                   #   zig as the C/C++ cross-compiler for sqlite/luau (day one)
│
├── contracts/                    # ★ THE FOUR BOUNDARIES — single source of truth (§6, B2)
│   ├── syscalls.kdl  bridge.kdl  control.kdl  wire.kdl  constants.kdl
│   ├── BUILD.bazel               #   abi_library() → {rust,zig,ts,asyncapi,md} per contract
│   └── codegen/
│       ├── BUILD.bazel           #   rust_binary :projector
│       ├── src/projector.rs      #   reads a contract, emits one language (reuses mc's table logic)
│       └── defs.bzl              #   abi_library() macro + write_source_files drift gate
│
├── kernel/                       # ★ the OS — TWO interchangeable implementations (B7)
│   ├── rust/                     #   Phase A: ported from memcontainers; wasmi = native crate
│   │   ├── BUILD.bazel           #     rust_shared_library → kernel.wasm; deps //contracts:*_rust
│   │   └── src/                  #     sched/ vfs/ ipc/ net guest/ bridge syscall (mostly copied)
│   └── zig/                      #   Phase B (branch→main): Zig reimpl; wasmi via //interpreter
│       ├── BUILD.bazel           #     zig_binary(wasm32_freestanding, release_small) + size_test
│       └── src/                  #     main.zig sched/ vfs/ ipc/ guest/{runtime,pcall,shim}.zig …
│
├── interpreter/                  # wasmi → wasm32 staticlib + C ABI — consumed by kernel/zig ONLY
│   ├── BUILD.bazel               #   rust_static_library(platform=//platforms:wasm32_unknown)
│   ├── Cargo.toml                #   wasmi = "=1.0.9" (eager mode — the §2.1 landmine)
│   └── src/{lib.rs, mc_register.gen.rs}   #   mc registration generated ← contracts/syscalls.kdl
│
├── sysroot/                      # guest sysroot (Rust, ported): safe `mc` wrappers, _start, sections
├── shcore/                       # OS-agnostic shell engine (Rust, ported; native-testable — §9.4)
├── programs/                     # the guest /bin (Rust, ported: uutils-based + tools)
│   ├── BUILD.bazel               #   mc_program() macro per tool; fixtures/ (dev-only)
│   └── …                         #   (coreutils language revisited post-stabilization — §13)
│
├── lib/                          # shared support libs — freestanding-clean (no -lc, no std.os/posix)
│   └── stdx/                     #   (Phase B) cherry-picked from ZML's stdx (Apache-2.0, Zig 0.16):
│       ├── BUILD.bazel           #     BoundedArray, intrusive no-alloc SPSC/MPSC queue, SegmentedList,
│       └── *.zig                 #     meta+signature, crypto MacWriter. Re-verify vs latest ZML.
│
├── wasi-adapter/                 # WASI(preview1) → mc shim (Rust, ported); C/C++ compat shims in Zig
│   └── BUILD.bazel               #   the link-injection/trampoline conversion as a custom rule
│
├── third_party/                  # ★ vendor LESS — only patches + Zig glue live here (B3)
│   ├── luau/
│   │   ├── BUILD.luau.bazel      #   zig c++ build of the patched archive → luau.wasm
│   │   ├── glue/                 #   mc_runtime, sys_bindings, compat — written in ZIG
│   │   └── patches/*.patch       #   the // mc PATCH set
│   └── sqlite/
│       ├── BUILD.sqlite.bazel    #   zig cc → sqlite.wasm; stamps mc_tier/mc_budget/mc_service
│       ├── glue/                 #   wasi_compat — ZIG
│       └── patches/*.patch
│
├── hosts/
│   ├── wasmtime/                 #   Rust host: lib + CLI, embeds wasmtime; deps //contracts:{env,ctl}_rust
│   │   └── src/{lib.rs,main.rs,net.rs,persist.rs,host_call.rs,terminal.rs}
│   └── js/                       #   TS host for bun/browser; deps //contracts:{env,ctl}_ts
│       └── src/{host.ts,bridge.ts,memory.ts,net.ts,persist.ts}
│
├── server/                       # mc-server (Rust/axum/tokio); deps //hosts/wasmtime, //contracts:wire_rust
│   └── src/{main.rs,store.rs,quota.rs}
│
├── sdk-js/                       # the TS libraries — published under the @mc/* scope (§8.2)
│   ├── core/  agent/  elements/  #   @mc/core (Vm API), @mc/agent, @mc/elements (<mc-*>)
│   └── BUILD.bazel files         #   ts_project; core deps //hosts/js + //contracts:wire_ts
│
├── web/                          # browser app + real-browser e2e (assets are DEPS, not cp)
│   └── src/, cdp/                #   CDP scripts → //web:cdp_test (hermetic chromium)
│
├── conformance/                  # ABI coverage gate (import-section oracle from contracts)
│   └── BUILD.bazel               #   rust_test deps //contracts:mc_rust, data //images:base_tar
│
├── tests/
│   ├── e2e/                      # ★ the e2e suite (Rust host) — runs against EACH kernel (§9.6)
│   │   └── src/{boot,pipes,net,persist,control,snapshot,services,sqlite,luau}.rs
│   └── parity/                   #   parity grid: {rust,zig} kernel × {rust,js} host (§9.2/§9.6)
│
├── images/                       # base + flavor images via pkg_tar (no staging)
│   └── BUILD.bazel
│
└── spec/                         # GENERATED specs (asyncapi/openapi/wire-vectors) — diff-tested outputs
    └── BUILD.bazel
```

### 8.1 Why this layout (the rules behind it)

- **One boundary, one home.** `contracts/` is the only place the four ABIs are *defined*; every other reference is a generated `*.gen.*` file.
- **Target is visible in the path + the `platform`.** `kernel/*` and `programs/` are `wasm32_freestanding`; `interpreter/` is `wasm32_unknown`; `hosts/wasmtime` and `server/` build for the native host, always opt (release wasmtime, so e2e isn't crawling) — `host_musl` static linking is deferred since wasmtime is built from source, not a prebuilt `libwasmtime.a` (§7.1, hosts/wasmtime/defs.bzl). No "excluded from default-members" footnotes.
- **The two kernels sit side by side.** `kernel/rust` and `kernel/zig` are sibling packages producing the same artifact; the parity matrix (§9.6) tests both. The C-ABI `interpreter` exists only for `kernel/zig`; the Rust kernel takes `wasmi` as a plain crate dep — so the C seam is visible, isolated, and Phase-B-only.
- **Third-party is patches-only, glue is Zig.** `third_party/<lib>/{patches,glue}` + a `BUILD.<lib>.bazel`; upstream source is an `http_archive`, the compat/glue shims are Zig compiled by `zig cc`/`c++`.
- **Generated artifacts are outputs, not commits.** `base.tar`, the `*.gen.*` bindings, `spec/*` are build outputs; `write_source_files` keeps an editor-visible copy honest via `diff_test`.
- **Shared utilities are vendored, freestanding-clean, and re-checked at manifest time.** `lib/stdx` (a Phase-B convenience for the Zig kernel) is seeded by cherry-picking [ZML](https://github.com/zml/zml)'s `stdx` (Apache-2.0 — keep a `NOTICE`): the freestanding-safe primitives the Zig kernel/guests actually need — no-alloc `BoundedArray`, intrusive SPSC/MPSC `queue`, `SegmentedList`, comptime `meta`/`signature`, the `crypto` MAC-writer. It links **no libc** and imports no `std.os`/`std.posix` (a CI grep enforces this); the host-leaning modules (`Io`, `process`, `time`, `flags`, `json`, `fmt`) are deliberately *not* pulled in. ZML is our reference Bazel+Zig repo and moves fast, so **the exact cherry-pick is re-verified against the latest ZML when we manifest the lib**, not frozen to today's snapshot.

### 8.2 Naming & namespacing — `mc-*`, never `agent-os-*`

`agent-os` names the **repository and the build**; it is *not* a prefix. The running system's identity is **`mc`**, inherited from memcontainers and frozen into the ABI itself (`mc` is the syscall import module; calls are `mc_sys_*`, control exports `mc_ctl_*`, custom sections `mc_tier`/`mc_budget`/`mc_service`). Namespace by **domain and lineage, not by repo name**:

- **Do not** prefix anything with `agent-os-` — no `agent-os-server`, no `@agent-os/core`, no `agent-os-tool`.
- **Binaries / services:** `mc-server`, `mc-tool`; resident services at `/svc/<name>` with `/etc/mc-services.json` (§4.5).
- **JS packages:** the `@mc/*` scope — `@mc/core`, `@mc/agent`, `@mc/elements`, `@mc/host`. Components are `<mc-*>`.
- **Frozen ABI surface (do not rename):** the `mc` syscall module, `mc_sys_*`, `mc_ctl_*`, the `env` bridge — a compatibility contract shared with memcontainers (and the thing that lets memcontainers act as a third parity cross-check).
- **Bazel labels need no prefix:** the package path *is* the namespace (`//kernel/rust`, `//contracts:mc_zig`). `module(name = "agent-os")` is the single place the project name appears.

---

## §9 — Testing discipline

> memcontainers' rule, kept and made hermetic: **no mocks; drive the real kernel through a real host.** agent-os adds two things memcontainers lacked — the artifact is **never stale** (B1) and the environment is **hermetic** (B4) — and one thing it could never have had with a single implementation: **two-kernel parity** (B7).

### 9.1 The shape of a test

A test boots the real `kernel.wasm` in `hosts/wasmtime` with capture sinks and `.deterministic()` (fixed clock + seeded rng), runs commands, and asserts on **real stdout/stderr bytes and real exit codes**. Network tests hit the **real internet**. Because a kernel trap surfaces as an error from the host builder, *booting is itself a test*.

### 9.2 Parity is now a grid

memcontainers proved A3 with host parity (Rust host ↔ JS host driving the same `kernel.wasm`). agent-os has a **second axis**: kernel parity (Rust kernel ↔ Zig kernel under the same suite). The two compose into a grid:

```
                 Rust host          JS host
   Rust kernel   ✓ (Phase A)        ✓ (Phase A)
   Zig kernel    ✓ (Phase B)        ✓ (Phase B)
```

Every cell runs the identical suite against real artifacts; any disagreement is a bug in a host, a kernel, or an *underspecified contract* — all three worth catching.

### 9.3 Conformance from the contract

`conformance/` derives the syscall surface from `//contracts:mc_rust` and walks every guest's wasm import section: no guest imports an undeclared `mc::` symbol (safety), and every declared syscall is imported by ≥1 guest or carries a documented exclusion (coverage). The interpreter additionally gets **behavioral vectors** (fuel exhaustion → re-park, host-trap → suspend/resume, budget enforcement) so the Phase-B Zig kernel — and any future interpreter swap — is provably equivalent.

### 9.4 The one place native unit tests are legitimate

`shcore/` (the OS-agnostic shell engine) is pure logic and may have native unit tests — it is *not* the kernel. Everywhere else, A2 means there is no native build to unit-test.

### 9.5 The whole story is `bazel test //...`

One command: regenerates and diff-tests every contract projection (B2); builds the kernel(s), guests, and images; runs e2e + parity + conformance against fresh artifacts (B1); checks each kernel's size budget (B5).

### 9.6 Two-kernel parity (the Phase-B acceptance gate)

When `kernel/zig` comes up, the e2e and conformance suites are parameterized over the kernel target — `//tests/e2e` runs once against `//kernel/rust:kernel` and once against `//kernel/zig:kernel` (a Bazel test matrix). **The Zig kernel is accepted only when it matches the Rust kernel across the entire suite** — and, via §15.1/§15.2, on recorded replay-snapshot hashes and differential fuzzing (now with the Rust kernel as the oracle). This is what makes the migration safe: we are not trusting a fresh reimplementation, we are proving it equal to a known-good one before it can become the default. The Rust kernel then remains as a permanent parity oracle (cheap insurance, and a perpetual contract-ambiguity detector) — or is retired if maintenance outweighs the value (§13).

---

## §10 — Size & determinism discipline

- **Size is a test, and the Zig kernel is the lever (B5).** Each `kernel.wasm` carries a `size_test`. The Rust kernel sets the baseline; the Zig kernel exists to push it lower (zmc landed 859 KB *with* the interpreter, though that figure will rise as it reaches parity — realistically a ~20–30% structural edge over the Rust kernel, mostly from Zig's leaner freestanding baseline avoiding `core::fmt`/panic-fmt bloat). The lever is pulled only behind the parity gate.
- **Determinism is structural (A7/A8).** All mutable state is in linear memory + globals; clock/entropy are `CAP_AMBIENT`-gated; an `Isolated` guest is fully replayable; a snapshot is `(memory, globals)`. The deterministic image tar (fixed mtime/uid/gid) is one `pkg_tar`. Determinism is also what makes the parity grid (§9.2) and replay testing (§15.1) cheap and exact.

---

## §11 — Phasing: Rust now, Zig next, parity always

Something is runnable and green at the end of every phase.

### Phase A — Bazelize + transplant (get to a stable, green graph)

1. **Stand up the Bazel module.** rules_rust + **rules_zig 0.16** + rules_js + rules_pkg + aspect_bazel_lib; hermetic toolchains; `http_archive`+patches for luau/sqlite/wasmtime.
2. **Port memcontainers' Rust into the graph — edited, not rewritten.** `kernel/rust` (wasmi as a native crate), `sysroot`, `shcore`, `programs`, `wasi-adapter`, `hosts/wasmtime`, `server`, `conformance`, `tests/e2e`. Each becomes a Bazel target with declared inputs (B1). This is the "reduce the load on the agents" step: we move battle-tested code, we don't author a kernel from scratch.
3. **Stand up `contracts/` + the projector.** Generate Rust + Zig + TS from day one — Rust kernel, Zig C/C++ shims, and TS client are all consumers immediately, so the projector is exercised across every language before the Zig kernel needs it.
4. **Bring Zig in for the C/C++ shim + build lane.** sqlite/luau via `http_archive`+patches built with `zig cc`/`c++`; their glue/compat shims written in **Zig** (rules_zig 0.16). This is the only new authoring in Phase A, and it is where Zig earns its keep first (toolchain unification).
5. **Green the suites and land the mechanisms.** e2e + conformance + Rust-host↔JS-host parity all pass; the resident-services mechanism (§4.5) and the generators are stable. **This is the definition of "stable" that gates Phase B.**

### Phase B — the Zig kernel branch (the size/control win, de-risked)

6. **Branch `kernel/zig`.** Reimplement the kernel in Zig against the *unchanged* `contracts/`, mining zmc for the wasmi-shim integration and the VFS/scheduler seed. Bring up `interpreter/` (wasmi → wasm32 staticlib + C ABI) — the only new seam, isolated to this kernel.
7. **Run the parity matrix.** The same e2e + conformance suites run against **both** `//kernel/rust:kernel.wasm` and `//kernel/zig:kernel.wasm` (§9.6). Two-kernel behavior parity is the acceptance gate (B7); replay (§15.1) and differential fuzzing (§15.2) use the Rust kernel as oracle.
8. **Flip the default when it earns it.** When the Zig kernel reaches parity *and* the tighter size budget, make it the default `//:kernel`. Keep the Rust kernel as a permanent parity oracle, or retire it (§13).

memcontainers runs throughout and shares the contracts, so a memcontainers guest passing agent-os conformance is a *third* cross-check.

---

## §12 — Anti-goals

- **❌ No host objects to the agent.** A1; the whole point. A kernel fd is never a host fd.
- **❌ No native kernel build, even for debugging.** A2 — for *both* kernels. Debug by driving the real wasm in a host.
- **❌ No WASI/Component-Model/bindgen on the kernel.** A4. WASI exists only as a *guest* adapter that translates into `mc`.
- **❌ No hand-written ABI on either side of any boundary.** B2. Edit the contract; let the projector generate; drift is a failed test.
- **❌ No checked-in third-party source.** B3. Patches over vendoring; glue in Zig.
- **❌ No manual artifact copying or "rebuild first" steps.** B1. If a test needs a kernel, it `data`-depends on it.
- **❌ No mocks, no fakes.** B6. The real kernel, a real host, the real internet — now also *two* real kernels.
- **❌ No host-PATH tools or host-system files.** B4.
- **❌ No rewriting what we can port.** Phase A transplants memcontainers' Rust; we do not reimplement proven code for novelty. Zig replaces it only on a branch, only behind parity.
- **❌ No second wasm interpreter "just for Zig."** §5.3. The same wasmi backs both kernels (native crate for Rust, C-ABI staticlib for Zig); we do not fork the execution model.
- **❌ No shipping a kernel by inspection.** B7. A kernel implementation ships only when parity says it matches the others.

---

## §13 — Open questions

1. **Contract format.** KDL vs RON vs a small Rust DSL for `contracts/*`. Leaning KDL + a Rust projector.
2. **Guest userland — settled.** All of `/bin` is Rust in one `wasm32-wasi` multicall crate compiled per-tier (§16.3): uutils' `uu_*` used **as-is**, third-party crates (ripgrep, `jaq`, …) for the external tools, hand-written `uumain`s for the rest — all parsing flags + help through the `clap`/`uucore` a box links anyway, all converted WASI→mc by the `//wasi-adapter`. So **GNU-flag fidelity** is largely *inherited* (uutils tracks GNU; the hand-written tools use clap to match), not re-litigated per tool; the only judgement left is which handful of tools to hand-write versus take from `uu_*`. C/C++/Zig stays for the heavy *domain* tools alone (sqlite/luau/typst/duckdb).
3. **Do we keep the Rust kernel forever?** As a parity oracle it's cheap insurance and a contract-ambiguity detector; as a maintained second implementation it's real cost. Likely keep it through Zig-kernel maturity, then decide.
4. **WASI conversion's fixpoint relink** as a hermetic Bazel custom rule (explicit intermediate outputs).
5. **Interpreter longevity.** Pin wasmi 1.0.9 (eager-mode landmine) indefinitely, or budget for a hardened fork? Behavioral vectors (§9.3) are the insurance for either.
6. **Capability-request channel** for a fully-denied agent — a structured channel, never an ambient grant.
7. **Server tenancy/eviction** for many concurrent kernels.

---

## §14 — Appendix

### 14.1 The four boundaries at a glance

| Boundary | Module | Dir of truth | Generated into |
|---|---|---|---|
| syscall | `mc` | `contracts/syscalls.kdl` | Rust kernel + sysroot + wasmi registration; Zig kernel + guest shims; conformance; docs |
| bridge | `env` | `contracts/bridge.kdl` | Rust kernel imports; Zig kernel imports; Rust host; JS host |
| control | `mc_ctl_*` | `contracts/control.kdl` | Rust/Zig kernel exports; Rust host; JS host |
| wire | — | `contracts/wire.kdl` | Rust server; TS client; AsyncAPI/OpenAPI; golden vectors |

### 14.2 memcontainers → agent-os mapping

| memcontainers | agent-os | change |
|---|---|---|
| `crates/abi` (Rust macro) | `contracts/` (data) + `//contracts/codegen:projector` | source of truth lifted out of Rust; projects to Rust+Zig+TS (B2) |
| `crates/kernel` (Rust→wasm) | `kernel/rust` (Phase A, ported) **+** `kernel/zig` (Phase B, parity-gated) | two implementations, one contract (B7) |
| `wasmi` (Cargo dep) | native crate for `kernel/rust`; `interpreter/` (C-ABI staticlib) for `kernel/zig` | C seam isolated to the Zig kernel |
| `crates/sysroot`,`shcore`,`programs` | `sysroot/`,`shcore/`,`programs/` (Rust, ported) | copied to reduce load; language revisited later (§13) |
| `loom/vendor/*` C/C++ glue | `third_party/*/glue` in **Zig** + `patches` | vendor→patch (B3); glue C/C++→Zig (zig cc/c++) |
| `crates/host` + `packages/host` | `hosts/wasmtime` + `hosts/js` | unchanged roles (A3) |
| `crates/mc-server`,`wire` | `server/` + `contracts/wire.kdl` | Rust kept; wire becomes a contract |
| `xtask` (2,384 lines) | the `BUILD` graph + a few `bazel run` aliases | imperative orchestration → dependency graph (B1) |
| (nothing — single impl) | the **two-kernel parity matrix** | the new safety net the staged plan buys (B7) |

### 14.3 Bazel rules we rely on

`rules_rust` (rust_library/rust_binary/rust_shared_library/rust_static_library/rust_test, `crate_universe` for deps from two separate lockfiles — `@crates` for the kernel/wasmi, `@host_crates` for the host/wasmtime, kept apart so std feature-unification can't break the no_std kernel), `rules_zig` 0.16 (zig_binary/zig_library/zig_test, the `wasm32-freestanding` transition + `zig cc`/`c++` toolchain — validated in `bazel-experiments`), `rules_js`/`rules_ts` (ts_project), `rules_pkg` (pkg_tar), `aspect_bazel_lib` (write_source_files + diff_test for §6), `http_archive` with `patches=` (B3), hermetic toolchains for rust/zig/node + a pinned browser for `web/` CDP tests.

---

## §15 — Improvements beyond the brief (proposed)

> These fall outside the axes originally scoped (structure, Bazel, Zig, vendoring, the four boundaries, testing, tools-as-libraries). Each is leverage the invariants already paid for. **(ABI-shaped)** ones are cheapest to settle before the contract freeze. Several are *amplified* by the two-kernel plan.

### 15.1 Deterministic record / replay
The kernel is pure (A5/A7) and snapshottable (A8): record the ordered bridge-input transcript + the final `(memory, globals)` hash as a golden; a `replay_test` re-feeds it and diffs the hash. A whole regression class for nearly free, and the ideal bug report. **With two kernels, the same recording replays against both — a free, exact parity check.**

### 15.2 Differential fuzzing
Determinism makes fuzzing honest: fuzz the syscall/bridge stream; every crash is reproducible from its seed. Oracles: (a) the kernel must never trap the host; (b) **differential parity** across the grid (§9.2) — host↔host *and* **Rust-kernel↔Zig-kernel** must produce identical snapshots. This is the single strongest tool for accepting the Phase-B kernel.

### 15.3 Generated observability — a tracepoint per syscall, from the contract **(ABI-shaped)**
Every call already flows through generated dispatch (§6). Emit, from the same contract, an optional tracepoint per call into a linear-memory ring buffer, drained via `mc_ctl_trace`. Uniform, zero-maintenance tracing — and a per-syscall trace is a precise *parity-diff localizer* when two kernels disagree. Decide the record shape before the freeze.

### 15.4 A generated capability audit, and an attestable kernel
Annotate each syscall row with its required capability; project a **capability × syscall matrix** as a diff-tested artifact. With Bazel's content-addressing, each `kernel.wasm` hash is stable and reproducible, so we can **attest** a kernel (sign + SLSA provenance) and bind it to its capability surface and conformance report — per implementation.

### 15.5 A self-describing kernel: `/sys/abi` and `/sys/contracts`
Expose the ABI version, syscall surface, and capability matrix as files under `/sys`, generated from `contracts/`. A guest — or an agent reasoning about its own sandbox — introspects by reading a file. Identical under both kernels by construction.

### 15.6 Deterministic fault injection at the bridge
Because the host implements every effect, it can deterministically inject real failures (`ENOSPC`, dropped connections, clock skew, fuel starvation) keyed to the replay seed — reproducible chaos, no mocks. Ship as capability wrappers (`FaultyNet`, `FaultyPersist`).

### 15.7 Crash-only, supervised resident services
A resident service (§4.5) keeps all state in linear memory, so a fault is recovered by **restarting from a clean snapshot** (A8) under a kernel supervisor (restart policy in `/etc/mc-services.json`). Crash-only + snapshot turns "sqlite panicked" into a sub-millisecond warm restart, invisible to a caller mid-`svc_call`.

### 15.8 A zero-copy bulk data plane **(ABI-shaped)**
The bridge passes `(ptr, len)` and the host copies. For RAG corpora, model tensors, and large file I/O, generate an **iovec / shared-buffer** convention from the contract to avoid the double copy. It is an ABI shape — design it into the bridge before the freeze.

> None of these change an invariant; each is leverage the invariants already bought. Settle the **(ABI-shaped)** ones (15.3, 15.8) and the capability annotations behind 15.4 *now*, while the contract is still soft.

---

## §16 — The guest userland: `sysroot`, a multicall `/bin`, and flavor layering

> Settled by mapping memcontainers' as-built userland (`sysroot` + `programs` + `images/flavors`) against this document. The kernel boundary is frozen; these are the *userland* shapes — what `/bin` is, how a flavor is assembled, where a service lives — fixed now, before ~55 programs are ported against them. Each is a departure *from* memcontainers, justified by this document, not a copy of it.

### 16.1 Flavors are products, layered by content

A **flavor** is a content-addressed image (§7.3, §10) *and* a product surface. The hierarchy:

| flavor | layers | for |
|---|---|---|
| **minimal** | `sh`, the integral builtins, `pkgfsd`, `agent`, `mc-tool` | building your own harness — complete control |
| **posix** | minimal + coreutils | a shell for agents; common cases (e.g. RAG) |
| **loom** | posix + `luau` + `luau-analyze` | programmability |
| **paper** | loom + `kreuzenberg` + `typst` | the document domain |
| **atlas** | loom + `sqlite` + `duckdb` | the data domain |

Each flavor is the **base plus domain packs**, assembled by `pkg_tar`, never staged by hand — this is precisely the death of memcontainers' 2,384-line `xtask` and its build wounds (§7.3). The packs are **shared by content**: loom's `luau` layers are byte-identical inputs to paper and atlas, so Bazel builds and stores them once and both flavors reference the same hash.

### 16.2 `sysroot`: generate the boundary, port the comfort

The guest's `mc` import block is **generated** from `contracts/syscalls.kdl` — a guest `$emit` on the same `mc_syscall_table!` the kernel's dispatch derives from, so a guest can never import a syscall the kernel doesn't serve (drift = compile error, B2). On top sits a **ported, hand-written** safe-wrapper skin (`read`/`write_all`/`open`/`spawn`/… as `Result<T, errno>`), plus the `entry!`/`declare_tier!`/`declare_budget!` macros and the panic handler.

We **deliberately do not generate the wrappers.** The generated externs already catch drift; the wrappers are a stable, frozen-ABI ergonomic layer, and generating them would demand rich per-argument metadata (out-pointer vs buffer vs path vs scalar) in the contract for no benefit the externs don't already buy. **Generate the boundary; port the comfort** — generating-for-its-own-sake is complexity the invariants don't ask for.

### 16.3 `/bin` is a per-tier multicall — one Rust crate, routed like uutils, converted to mc

memcontainers ships its hand-written Rust coreutils as **55 separate `.wasm`** (a ~19 MB layer) AND, separately, collapses its uutils tools into per-tier WASI multicalls (`mcbox-ro`/`mcbox-rw`: one binary, `argv[0]` dispatch over `uu_*::uumain`, an `mc_applets` roster). agent-os unifies both into **exactly four binaries** — `mcbox-{isolated,readonly,readwrite,full}` — by leaning on the fact that the *whole* coreutil set is Rust.

**One crate, four boxes, uniform routing.** `/bin` is one `coreutils` crate compiled four times (`rust_binary` over one `srcs` glob, differing only by cumulative `cfg` features `tier_full ⊃ tier_readwrite ⊃ tier_readonly ⊃ tier_isolated`). It builds for **`wasm32-wasi`**, because the tools it reuses are `std`. Its `main` is a uutils-style multicall: `basename(argv[0])` (or `argv[1]`) selects an applet and calls its `uumain(args) -> i32` — the *same* signature for every applet, whatever its origin. Three origins, one route:

- **hand-written** (`cat`, the "from programs" tools): our own `uumain`, parsing flags + emitting `--help` via **`clap`/`uucore`**, doing I/O through `//sysroot` + the facade (§16.2);
- **external-crate** (`grep` → ripgrep's `grep-searcher`, `jq` → `jaq`, …): a thin `uumain` over a third-party Rust crate;
- **uutils** (`base64` → `uu_base64`; the ~25 `uu_*` applets): `uu_<name>::uumain`, used **as-is** — never reimplemented.

**Reuse what is already linked.** A box links `clap` + `uucore` once regardless (every `uu_*` needs them), so the hand-written tools **reuse** them for flag-parsing and help rather than carry a parallel hand-rolled CLI — there is no second arg parser in `/bin`. The *only* hand-written-specific code is the facade — `fsutil` (tree walks), `textio` (line/chunked I/O), `spool` (`/scratch` spill) — the mc-shaped helpers uucore does not give, written over `//sysroot`.

**WASI→mc, once per box.** Being `std`, the crate's `uucore`/`clap`/ripgrep code emits `wasi_snapshot_preview1` imports; the hand-written tools' `//sysroot` calls are already `mc`. The `//wasi-adapter` (§13.4 — ported from memcontainers, **pure Rust, no C/Zig glue, because the coreutils are all Rust**) rewrites a box's WASI imports to `mc_sys_*`, so the shipped `box.wasm` imports **only `mc`**. That is exactly what makes §16.4 attestation hold: an applet is cfg-gated to the lowest tier whose `tier_caps` (§15.4) cover the syscalls it ends up importing, and a box's `mc` imports — the union of its applets' — must be ⊆ `tier_caps(tier)`, checked at build (a `readonly` box compiling in a write applet fails). The registration macro builds the `mc_applets` roster + the `mc_tier` stamp from the same cfg list, so code, roster, and the generated `/bin` symlinks cannot disagree; `/bin/cat`, `/bin/echo`, … are tar symlinks into their tier's box.

The wins: **four binaries, not 55+**; `clap`/`uucore`/regex link once per box; a session cranelift-compiles **≤4 distinct guest modules**, not dozens (a boot-time size/speed lever, B5-adjacent). The big *domain* tools (`luau`/`sqlite`/`typst`/…) stay one-binary services (§16.5), never multicalled.

### 16.4 Capability attestation at build (drift = build error)

A program **declares** its tier (`declare_tier!` → `mc_tier`), but nothing checks that its *actual* syscalls fit. The `mc_program`/`mcbox` rules **attest** it: walk the binary's wasm `mc` imports against the tier's allowed syscalls (the capability × syscall matrix of §15.4) and **fail the build** if a `read-only` applet imports a write syscall. This extends conformance (§9.3) from *imports ⊆ declared syscalls* to *imports ⊆ the tier's syscalls* — capability drift caught at `bazel build`, an enforcement of the default-deny axiom (A9) at authoring time, not just at exec.

### 16.5 Services are a per-flavor property, not a POSIX one

The resident-service mechanism (§4.5) exists for the **domain tools that pay a cold-start tax** — `luau`, `kreuzenberg`/`typst`, `sqlite`/`duckdb` — not for `cat`. So service-capability is a **per-flavor** concern: the `mc_service` custom section plus an `/etc/mc-services.json` **carried by the domain pack** (loom's, paper's, atlas's), never by minimal or posix. One binary, two activation modes — the kernel enters the generated `svc_serve` path for resident mode and `_start` for one-shot — composed into a flavor by the same `pkg_tar` layering as the tool itself. `mc-services.json` is therefore not one global file but a per-flavor fragment, merged by the layer stack.

---

> **Closing.** memcontainers proved the design and the discipline; zmc proved a Zig kernel is viable and smaller. agent-os sequences the bet: put everything on a zero-staleness Bazel graph with language-neutral contracts, ship the kernel **Rust-first by porting** what already works, bring **Zig in immediately for the C/C++ shim lane**, and migrate the kernel to **Zig on a branch that must prove behavior parity** against the Rust one before it can win. The payoff is that "is it correct, and is it fresh?" is answered by `bazel test //...` — and "is the rewrite faithful?" is answered by a parity grid, not by hope. Keep this document honest: if the system changes, change the relevant § in the same commit.
