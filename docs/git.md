# AgentOS Git — Host Source Plane

**Experimental** product surface for interactive and LLB git. Design of record: workspace-root
`GIT.md`. Tracker / gaps: `TASKS.md`, `CRITICAL_REVIEW.md`. Remotes are **not** GA.
`experimentalGitEngine` stays at **api-surface level experimental** until graduation criteria below
are met — do **not** treat it as stable.

## Thesis

Git is a **host source plane** (libgit2 + thin `ge_*` ABI). Guests see paths and a thin `/bin/git`;
the engine never dials the network. Remotes are host-mediated.

| Face | Path |
|------|------|
| SDK (JS) | `GitEngine.load` / `experimentalGitEngine` + `registerGitHostCall("git")` |
| gitfs | `asMountDriver()` → MountFs; local ctl at `/.git/mc/ctl` |
| Thin CLI | `//memcontainers/programs/git` — reduced surface only (see below) |
| Server engine | BEAM-owned C `git-engine` **Port** — local Run, pack apply, type-4 mount only |
| Server remotes | **BEAM HTTPS + Elixir orch** → Port apply / pack.build (**no Node**, **no C TLS**); **fetch/clone/push** when not read-only |
| LLB (Node) | Host emcc engine first (`MC_GIT_ENGINE_DIR`); **not** ambient system git |

## Agent-facing constraints (product)

These are hard product rules for agents and tools that use host git — not optional polish.

| Constraint | Meaning |
|------------|---------|
| **One gitfs mount per VM (K21)** | v1 allows at most one gitfs driver mount per VM. A second `vm.mount` of gitfs fails closed on the host. |
| **No `.git/objects` façade (v1)** | Guests do **not** get a synthetic `.git/objects` tree. Object DB stays host-side; worktree + ctl only. |
| **Unflushed ctl: close write before status** | Ctl Request is written to `/.git/mc/ctl`; Response is read from the out path. Close (or Drop) the write FD **before** reading status / next Response — unflushed guest buffers are invisible to the engine (same class as `hostDir`). |
| **Remotes need CAP_NET + host_call `git`** | Mount/ctl alone cannot dial. Guest remotes go through `mc_sys_host_call` name `"git"` gated by kernel **CAP_NET**. Ctl remote ops refuse. |
| **Experimental flag + identity on commit** | Opt-in via `experimentalGitEngine` (JS). Commits need author identity (`name` / `email` args or engine defaults) — no ambient global gitconfig from the host user. |
| **Server push (not read-only)** | See [Server remotes](#server-remotes-k16--push-honesty) — packbuilder + receive-pack on BEAM when mount is not read-only. |

## Thin CLI surface (honest)

`//memcontainers/programs/git` is a **reduced** pure-mc adapter — **not** full git-core. Unknown
commands fail closed. Phase A maps argv → ctl Request JSON only (engine implements the ops).

| Class | Commands | Path |
|-------|----------|------|
| Local porcelain | `init`, `status`, `add <path…>` / `add -A`/`--all`, `rm <path…>`, `commit -m …`, `log`, `diff`, `show [rev]`, `rev-parse [rev]`, `branch` / `branch <name>` / `branch -d <name>`, `checkout`/`switch <name>`, `reset [--soft\|--mixed\|--hard] [rev]`, `tag [-d] <name>`, `config --list` or `config <key> [value]`, `remote` list/add/remove | Discover `/.git/mc/ctl` under cwd parents; write Request JSON, re-open/read Response (multi-path `add`/`rm` = one round-trip per path) |
| Remotes | `clone <url>`, `fetch [url]`, `pull [url]`, `push [url]` | `host_call` name `"git"` (**CAP_NET**); clone works outside a repo (no root discovery) |
| Meta | `version` / `--version`, `help` / `--help` | stdout/stderr only |

Not supported on the thin CLI (examples): sparse, rebase, submodules, LFS, receive-pack, full
git-config surface, annotated tags, path-limited diff, `reset` modes beyond soft/mixed/hard. Use
SDK / ctl ops where implemented, or expect `unknown or unsupported command`.

## Server remotes (K16) + push honesty

Same ownership cut as kernel HTTP egress: **BEAM dials HTTPS**; the guest and the Port child do not.

```text
guest host_call "git"
  → kernel CAP_NET
  → BEAM AgentOS.Git.Orchestrator
       ├─ smart-HTTP (OTP :httpc / ssl) + connection credential splice
       │    ListRefs / FetchPacks / PushPacks (receive-pack)
       └─ Port frames → git-engine
            import_pack, refs.import, clone.apply / fetch.apply,
            pack.build, push.prepare, push.complete
  → Response JSON
```

| Responsibility | Owner |
|----------------|--------|
| TLS, ListRefs, FetchPacks, PushPacks | **BEAM** (`AgentOS.Git.SmartHttp`) |
| Origin / connection policy | **BEAM** (connections catalog) |
| Pack import + apply + packbuilder + local porcelain | **C Port** (`AgentOS.GitEngine`) |
| JS browser/Node remotes | **TS** orch + emcc |
| **Push (server)** | **Supported** when not `read_only` — pack.build + receive-pack + push.complete |

**Server remotes support push** on the BEAM path when the git mount is not read-only:

1. `push.prepare` (local tips as commands)
2. ListRefs lease (remote `oldHash`)
3. `GitEngine.pack_build/2` → `.git/agentos/push.pack` (non-delete must be non-empty `PACK…`)
4. Smart-HTTP `git-receive-pack` + report-status
5. `push.complete` (remote-tracking when remote accepted)

Read-only mounts reject push with a **stable** stderr (do not paraphrase in callers that match it):

```text
git: push rejected (read-only mount)
```

Empty pack on a non-delete push fails closed (`git: empty pack refused for non-delete push`).
Origin allowlist, max pack size, and no-URL-credentials policy apply to push URLs the same as
fetch/clone. Secrets only in BEAM request headers.

C `smart_http` / C orchestrator (Port type-5) are **test/fixture only** — not the product server
remote path. Dual-host product orch is **TS (JS) ↔ BEAM (server)** sharing apply-op + algorithm
semantics (K20), not “C orch on server”.

### Executable golden orch vectors (K20 / P2.8)

Shared JSON under `memcontainers/lib/git-engine/testdata/orch/` (fixture copies:
`server/test/fixtures/git/orch/`):

| File | Asserts |
|------|---------|
| `clone_success_steps.json` | fixture pack + tip → `ok:true`, stdout contains `cloned` |
| `clone_empty_pack_fail.json` | empty pack → `ok:false`, stderr contains `empty pack` |
| `origin_denied.json` | wrong allowlist → `ok:false`, stderr contains `not allowlisted` |

Each vector lists logical algorithm steps plus an executable `orchestrator_response` step with
expected `ok` / substring checks. **Both** hosts run them:

- TS: `//memcontainers/sdk-js/core:git_orch_golden_test` (FixtureSmartHttp + wasm engine)
- BEAM: `AgentOS.Git.OrchGoldenTest` (fixture transport + Port)

Prose-only algorithm name lists without assertions are not sufficient.

## Create options (JS)

Opt-in only; documented in [Create options](./create-options.md).

```ts
mc.create({
  experimentalGitEngine: true,
  gitEngineBaseUrl: new URL("./git-engine/", import.meta.url).href,
  // registers host_call "git" (process pack cache default), mounts gitfs at /workspace/repo
  // optional cone sparse (multi-pattern; not full sparse language): gitSparseCone: ["src", "docs"],
  connections: [{ ref: "github.user.work", auth: { kind: "bearer", token }, origins: ["https://github.com"] }],
});
```

## `experimentalGitEngine` graduation criteria (P3.2)

**Do not graduate to stable yet.** Remotes are **not** GA. Keep `docs/api-surface.json` level
`experimental` until **all** of the following hold. Status notes (honest; do not flip the flag
on partial progress):

| # | Criterion | Status |
|---|-----------|--------|
| 1 | **Origin / connection policy** — empty origins fail closed; credential splice host-only; no secrets in guest/ctl/engine args | **Met in unit/fixture** — bare-URL + empty `allowOrigins` fail closed (JS); dual-host policy tests green; must stay green |
| 2 | **Pack e2e** — pack import → refs → clone/fetch apply on **both** JS wasm and BEAM Port (`minimal.pack` + golden orch vectors) | **Met (fixture class)** — abi/pack fixtures + `clone_success_steps` / empty-pack / origin_denied goldens on TS + BEAM; live public HTTPS still residual (R4) |
| 3 | **Push or explicit RO** — packbuilder path on each product host **or** documented RO with stable reject | **Met** — JS + BEAM pack.build + receive-pack push when not read-only; RO mounts reject with stable `git: push rejected (read-only mount)` |
| 4 | **Single-writer** — one engine queue per gitfs mount; K21 one-mount | **Partial** — bridge/Port serialise engine ops; multi-mount hard-fail enforcement still thin (R66) |
| 5 | **CAP_NET e2e** — guest without CAP_NET → EPERM; with CAP_NET + allowlist → shallow clone/fetch on JS **and** server attach | **Open (R1–R3)** — unit demux + fixture transport only; **no** booted-guest CAP_NET e2e on either host |
| 6 | **Metrics / observability** — engine/orch failure counters (PR16), not silent false-green | **Open (R85–R89)** — design only |

**Blocker for graduation:** criterion **5** (guest CAP_NET e2e). Identity inject (K28), shallow
default `depth=1`, and push server path are **not** substitutes for guest remotes e2e.

Until **all** rows are met (especially R1): flag stays experimental; docs and api-surface must
**not** claim GA remotes.

## Residual: full guest CAP_NET e2e (P1.7)

Unit demux for host_call name `"git"` is covered (async claim + fixture transport under `Vm` /
`attach_git`). **Full guest CAP_NET e2e** (thin `/bin/git` inside a booted guest image through
kernel CAP_NET to orch) remains **residual** — not a substitute for the unit path above.

## Env (Node solve / LLB)

Default is **engine-first**. `llb.git` / `materializeLlbGit` require the host emcc engine unless the
emergency escape hatch is set.

| Variable | Meaning |
|----------|---------|
| `MC_GIT_ENGINE_DIR` | Dir with `git_engine.mjs` + `git_engine.wasm` (**required** for `llb.git` by default) |
| `MC_GIT_ENGINE_BASE_URL` | Alternate URL form of the same dir |
| `MC_GIT_PACK_CACHE` | Optional on-disk pack cache dir |
| `MC_GIT_USE_SYSTEM` | **Emergency only** (`=1`): shell out to ambient system `git` |

Without `MC_GIT_ENGINE_DIR` / `MC_GIT_ENGINE_BASE_URL` and without `MC_GIT_USE_SYSTEM=1`, solve
**fails closed** (throws; does not silently use system git).

## c-shared / in-process load (K15)

`//memcontainers/lib/git-engine:libgit_engine` may produce a `.so` packaging artifact. The **product**
server load path remains the BEAM-owned **Port** binary (`git-engine`) for engine Run/apply/mount,
plus emcc wasm on JS hosts. In-process c-shared host load is **not** operationalized (PR7d open) —
not an “immediately after MVP” product path until that lands.

## Security rules

- Secrets never in guest, ctl body, or engine args — only host HTTP headers (JS or BEAM splice).
- Empty connection `origins` → fail closed.
- Ctl remotes refuse; remotes require `CAP_NET` + host_call name `"git"`.
- No Node/Bun process on the Elixir control plane for git.
- Do not treat remotes or the experimental flag as multi-tenant GA.
- Server push is rejected with a stable message (see above).

## Bazel / server targets

- `//memcontainers/lib/git-engine:git_engine_wasm` — emcc module + NOTICE (ship filegroup)
- `//memcontainers/lib/git-engine:git_engine_wasm_size_limit` — ≤2 MiB on optimized `git_engine.wasm`
- `//memcontainers/lib/git-engine:git_engine_wasm_l5_notices` — fail-closed NOTICE/COPYING in ship set
- `//memcontainers/lib/git-engine:git-engine` — native Port binary (dial-free)
- `//memcontainers/lib/git-engine:orch_algorithm_traces` — executable K20 golden JSON
- `//memcontainers/programs/git:git` — thin guest CLI
- `//memcontainers/sdk-js/core:git_orch_golden_test` — TS golden runner
- Elixir: `AgentOS.GitEngine`, `AgentOS.Git.SmartHttp`, `AgentOS.Git.Orchestrator`
