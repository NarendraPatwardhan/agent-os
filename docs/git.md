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
| **One gitfs engine per mount path (K21)** | Multi-mount is allowed with **distinct** paths (R63). Each path owns its own engine (single-writer). Remounting gitfs at an already-live path fails closed. |
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
       ├─ connection catalog resolve (PR11) + credential splice
       ├─ smart-HTTP (OTP :httpc / ssl)
       │    ListRefs / FetchPacks / PushPacks (receive-pack)
       └─ Port frames → git-engine
            import_pack, refs.import, clone.apply / fetch.apply,
            pack.build, push.prepare, push.complete
  → Response JSON
```

| Responsibility | Owner |
|----------------|--------|
| TLS, ListRefs, FetchPacks, PushPacks | **BEAM** (`AgentOS.Git.SmartHttp`) |
| Origin / connection policy + credential splice | **BEAM** (`AgentOS.Git.Connections` catalog on `attach_git`) |
| Pack import + apply + packbuilder + local porcelain | **C Port** (`AgentOS.GitEngine`) |
| JS browser/Node remotes | **TS** orch + emcc |
| **Push (server)** | **Supported** when not `read_only` — pack.build + receive-pack + push.complete |

### Product path: connection catalog (PR11)

**Prefer connections over a flat origin allowlist.** Host attaches git with a connection
catalog (same shape as [connections](./connections.md) / JS `ConnectionDefinition`). Origins
and auth live **on the matching connection** — a separate `allowed_origins` is **not** required.

```elixir
# BEAM / ControlPlane product attach (secrets stay host-side)
AgentOS.ControlPlane.attach_git(vm_id,
  connections: [
    %{
      ref: "github.user.work",
      auth: %{kind: :bearer, token: System.fetch_env!("GITHUB_TOKEN")},
      origins: ["https://github.com"]
    }
  ],
  policies: [
    %{pattern: "github.user.*", action: :require_approval}
  ]
)
```

```ts
// JS create options — same catalog cut
mc.create({
  experimentalGitEngine: true,
  connections: [
    { ref: "github.user.work", auth: { kind: "bearer", token }, origins: ["https://github.com"] },
  ],
});
```

Guest / thin CLI remotes name a **public** locator + optional connection ref only:

```json
{"op":"clone","args":{"url":"https://github.com/org/repo.git","connection":"github.user.work"}}
```

| Rule | Behaviour |
|------|-----------|
| **Host catalog** | `attach_git(connections: …)` / JS `connections` — never guest body |
| **Guest may pass** | Public `url`, `connection` / `agentos` ref, `remote` name, mount |
| **Guest must not pass** | Tokens, auth maps, origins, policies — **rejected** (`git: guest body must not include auth secrets`) |
| **Empty `connection.origins`** | Fail closed — no dial, no credential splice to attacker URLs |
| **Unknown connection ref** | Fail closed (`git: unknown connection ref …`) |
| **Bare URL (no connection)** | Requires non-empty host `allowed_origins` match (legacy / fixture). Product attaches with connections only → bare URL fails closed |
| **Push policy** | `policies: [%{pattern, action}]` with `approve` \| `require_approval` \| `block` (most restrictive wins). Stable stderr: `git: push blocked by policy`, `git: push requires approval` |
| **Secrets in responses / info** | Never — `Vm.info` surfaces connection **refs** only |

**Legacy flat allowlist** (`allowed_origins` + optional flat `auth`) still works when
`connections` is empty (fixtures / migration). When `connections` is non-empty, the catalog
wins for remote policy.

Aligns with [connections](./connections.md): credential splice after origin checks; CAP_NET
still required for guest remotes via host_call name `"git"`.

**Server remotes support push** on the BEAM path when the git mount is not read-only:

1. Connection / origin policy + push policy (`block` fails before dial)
2. `push.prepare` (local tips as commands)
3. ListRefs lease (remote `oldHash`)
4. `require_approval` / host approval callback when policy demands it
5. `GitEngine.pack_build/2` (optional `haves:` from lease `old_hash`) → `.git/agentos/push.pack`
   (non-delete must be non-empty `PACK…`; delete-only may be empty)
6. Smart-HTTP `git-receive-pack` + report-status
7. `push.complete` (remote-tracking when remote accepted; skipped for all-zero delete hash)

Read-only mounts reject push with a **stable** stderr (do not paraphrase in callers that match it):

```text
git: push rejected (read-only mount)
```

Empty pack on a non-delete push fails closed (`git: empty pack refused for non-delete push`).
**Delete-ref push** (`args.delete: true | ref | [refs…]`): `newHash` all-zero, empty pack allowed.
**Thin-pack / haves (R48):** packbuilder hides lease old tips so shared history is omitted.
Connection origin policy, max pack size, and no-URL-credentials policy apply to push URLs the
same as fetch/clone. Secrets only in BEAM request headers.

### Monorepo materialization (M7 v1 / D13)

**Product path for large trees:** shallow clone + cone sparse — **not** partial-clone filter alone.

| Step | Behaviour |
|------|-----------|
| **Shallow default** | Product clone/fetch uses `depth=1` unless `args.depth` overrides (`depth<=0` = full history) |
| **Cone sparse** | JS `gitSparseCone` / `gitMounts[].sparseCone` / BEAM `attach_git(sparse_cone: …)` → orch after `clone.apply` runs engine `sparse-set` then `checkout` so the worktree only materializes cone prefixes |
| **gitfs / Port mount** | Guest sees the post-sparse worktree. JS gitfs also projects only cone prefixes (defense in depth). BEAM Port mounts the Port worktree root after sparse-set |

```text
clone (depth=1) → import_pack → refs.import → clone.apply
  → sparse-set(patterns) → checkout(HEAD)   # when cone configured
  → guest/gitfs sees cone paths only
```

**Out of this chunk (not the M7 v1 story):** full promisor remotes, on-demand lazy blob fetch,
missing-object re-fetch after `blob:none` / `tree:0`, and “filter wire only” without worktree
usability. Advertising `filter` on upload-pack is optional wire support — it does **not** replace
shallow + cone sparse for monorepo usability. Servers/fixtures that ignore filter still return a
full pack; the engine still materializes whatever objects arrived.

**Honest limits (cone-only):** multi-pattern prefixes + basic `!path` negation written into
`sparse-checkout` — **not** full git sparse-checkout pattern language. Prefer listing the
directories agents need (`["src", "docs"]`) rather than relying on filter or promisor.

### Partial clone filter (R36)

Clone/fetch accept optional `args.filter` (e.g. `blob:none`, `tree:0`). The host smart-HTTP
upload-pack request advertises the `filter` capability and sends a `filter <spec>` pkt-line.
**Limits:** the engine still materializes what the pack contains — there is no on-demand blob
promisor/fetch for missing objects yet. Servers or fixtures that ignore filter return a full pack
and continue to work. **Do not treat filter as monorepo materialization** — use
[shallow + cone sparse](#monorepo-materialization-m7-v1--d13) above.

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
  // multi-repo (R63–R65): gitMounts: [{ path: "/workspace/a" }, { path: "/workspace/b", sparseCone: ["src"] }],
  // remotes demux with args.mount / mount on host_call "git"
  connections: [{ ref: "github.user.work", auth: { kind: "bearer", token }, origins: ["https://github.com"] }],
});
```

### Multi-mount / `args.mount` (R63–R65 / D21)

Multi-repo is supported when each mount path owns its own engine (K21). Remotes on host_call
`"git"` demux to the engine for that path. Single-writer is **per mount**, not global: two mounts
may run remotes concurrently; two remotes on the **same** mount serialize.

#### Product setup

| Host | How to attach two engines | Default when `mount` omitted |
|------|---------------------------|------------------------------|
| **JS** | `mc.create({ experimentalGitEngine: true, gitMounts: [{ path: "/workspace/a" }, { path: "/workspace/b", sparseCone: ["src"] }], … })` | First `gitMounts` entry |
| **BEAM** | `ControlPlane.attach_git(id, mount_path: "/workspace/a", …)` then again with a **distinct** `mount_path: "/workspace/b"` | Sole engine if only one attached; otherwise first attached (prefer explicit `args.mount`) |

Same path while live fails closed: JS throws on duplicate `gitMounts` path; BEAM returns
`{:error, :git_already_attached}`. Detach one path with BEAM `detach_git(id, mount_path: …)`;
JS closes the VM (all engines).

```ts
// JS product create — two mounts, remotes demux by args.mount
const vm = await mc.create({
  experimentalGitEngine: true,
  gitEngineBaseUrl: new URL("./git-engine/", import.meta.url).href,
  gitMounts: [
    { path: "/workspace/app" },
    { path: "/workspace/lib", sparseCone: ["src"] },
  ],
  connections: [{ ref: "github.user.work", auth: { kind: "bearer", token }, origins: ["https://github.com"] }],
});
// Guest (CAP_NET): host_call "git" body includes mount to select engine
// {"op":"clone","args":{"url":"https://github.com/org/app.git","mount":"/workspace/app"}}
// {"op":"clone","args":{"url":"https://github.com/org/lib.git","mount":"/workspace/lib"}}
```

```elixir
# BEAM — two Ports, two worktree roots
:ok = AgentOS.ControlPlane.attach_git(id, executable: path, mount_path: "/workspace/a", root: root_a, connections: conns)
:ok = AgentOS.ControlPlane.attach_git(id, executable: path, mount_path: "/workspace/b", root: root_b, connections: conns)
# host_call "git" body: {"op":"clone","args":{"url":"…","mount":"/workspace/a"}}
```

#### Demux rules (`args.mount` / top-level `mount`)

| Request | Behaviour |
|---------|-----------|
| `args.mount` or top-level `mount` = registered path | Route to that engine / Port |
| Mount omitted, one engine only | That engine (JS single-engine path; BEAM sole attach) |
| Mount omitted, multi-engine | JS uses `defaultMount` (first `gitMounts` entry); BEAM prefers sole/first — **set mount explicitly** |
| Unknown mount path | Fail closed: `ok:false`, code 1, stderr `git: unknown mount …` — **no network dial** |
| Duplicate path attach | Fail closed (see above) |

Accept either form:

```json
{"op":"clone","args":{"url":"https://example.com/r.git","mount":"/workspace/a"}}
{"op":"clone","mount":"/workspace/b","args":{"url":"https://example.com/r.git"}}
```

#### Concurrency

| Scope | Rule |
|-------|------|
| Same mount | Remote orch FIFO / single-flight (D2) — peak concurrent transport ≤ 1 |
| Distinct mounts | Independent queues — remotes may overlap (D21) |
| Snapshot | Still blocked while **any** git remote host_call is inflight (D19) |

**Never** share one mutable engine or Port across mounts without demux. One engine map / one
`git_engines` table owns the path → engine lookup.

#### Tests / proof

- **JS:** `//memcontainers/sdk-js/core:git_remote_test` — dual clone via `gitHostCallHandler` +
  `args.mount` with `minimal.pack` worktree isolation; concurrent two-engine clones.
- **BEAM:** `AgentOS.Git.OrchestratorTest` — `R65/D21 host_call args.mount two clones into two
  engines` (worktree README per root) + `D21 concurrent remotes on two mounts may overlap`.

## `experimentalGitEngine` graduation criteria (P3.2)

**Do not graduate to stable yet.** Remotes are **not** GA. Keep `docs/api-surface.json` level
`experimental` until **all** of the following hold. Status notes (honest; do not flip the flag
on partial progress):

| # | Criterion | Status |
|---|-----------|--------|
| 1 | **Origin / connection policy** — empty origins fail closed; credential splice host-only; no secrets in guest/ctl/engine args | **Met in unit/fixture** — connection catalog product path (JS + BEAM `attach_git connections:`); bare-URL / empty origins fail closed; guest secret keys rejected both hosts; dual-host policy tests green |
| 2 | **Pack e2e** — pack import → refs → clone/fetch apply on **both** JS wasm and BEAM Port (`minimal.pack` + golden orch vectors) | **Met (fixture class)** — abi/pack fixtures + `clone_success_steps` / empty-pack / origin_denied goldens on TS + BEAM; live public HTTPS still residual (R4) |
| 3 | **Push or explicit RO** — packbuilder path on each product host **or** documented RO with stable reject | **Met** — JS + BEAM pack.build + receive-pack push when not read-only; RO mounts reject with stable `git: push rejected (read-only mount)` |
| 4 | **Single-writer** — one engine queue per gitfs mount; K21 one engine per path | **Met (foundation)** — bridge/Port serialise per engine; multi-mount demux + same-path fail-closed (R63–R66) |
| 5 | **CAP_NET e2e** — guest without CAP_NET → EPERM; with CAP_NET + allowlist → shallow clone/fetch on JS **and** server attach | **Partial** — **JS closed (fixture):** `//memcontainers/sdk-js/core:git_guest_e2e_test` boots loom + `/bin/git` through CAP_NET → MapHostCall `"git"` → FixtureSmartHttp/`minimal.pack` (R1) and CAP_NET deny (R3). **Server full guest-image path still open (R2)**; live HTTPS still R4 |
| 6 | **Metrics / observability** — engine/orch failure counters (PR16), not silent false-green | **Partial (R85–R88 basic)** — in-process counters exist (see [Metrics](#metrics-pr16)); R89 alerts still open |

**Blocker for graduation:** criterion **5** still needs **server** guest CAP_NET e2e (R2) in addition to
the JS fixture path. Identity inject (K28), shallow default `depth=1`, push server path, and basic
metrics are **not** substitutes. Live public HTTPS (R4) remains optional product proof, not a
fixture substitute. **Do not graduate** `experimentalGitEngine` while R2/R4/R9 criteria remain open.

Until **all** rows are met: flag stays experimental; docs and api-surface must **not** claim GA remotes.

## Residual: full guest CAP_NET e2e (P1.7)

- **JS (fixture class):** closed under `//memcontainers/sdk-js/core:git_guest_e2e_test` — thin
  `/bin/git` on loom → kernel CAP_NET → host_call `"git"` → TS orch + FixtureSmartHttp +
  `minimal.pack` → `/workspace/repo` worktree; CAP_NET deny (R3) + gitfs ctl close-then-status (R8).
  Inject transport via create options `gitHttp` / `gitAllowOrigins` (hermetic; not product egress).
- **Server:** unit demux + fixture transport under `Vm` / `attach_git` remain; **full guest-image**
  CAP_NET path is still residual (R2).

## Submodules (R68–R69) — honest surface

**Network submodule ops are not implemented.** The engine never dials; submodule clone/update/init/add
will be host-mediated later (planned: `host_call` name `"git"` with a recursive flag + apply into
worktree projection). Until then:

| Op | Behaviour |
|----|-----------|
| `{"op":"submodule"}` or `action: "list"` / `"status"` | **List-only** — parse worktree `.gitmodules` (no network); returns `result.submodules` JSON array of `{name,path,url}`. Missing file → empty list. |
| `action: "update"` / `"init"` / `"add"` / `"clone"` / other | **Fail closed** with stderr stating host-mediated design; **does not** clone or project submodule trees |

Thin CLI does **not** expose `submodule`. Do **not** claim multi-repo submodule network workflows work.

## Metrics (PR16)

Basic in-process counters only (not Prometheus). Never store packs, tokens, or credential material.

| Host | API | Counters |
|------|-----|----------|
| **BEAM** | `AgentOS.Git.Metrics.snapshot/0` · `reset/0` · `inc/1` | `clone_ok` / `clone_error`, `fetch_ok` / `fetch_error` (includes pull), `push_ok` / `push_error`, `port_eio`, `rpc_error` |
| **JS** | `snapshotGitCounters()` · `resetGitCounters()` · `incGitCounter` | `clone_ok` / `clone_error`, `fetch_ok` / `fetch_error`, `push_ok` / `push_error` |

Orch records ok/error after each remote op. Port death ticks `port_eio` on BEAM. **Not yet productized:**
duration/size histograms, origin/bytes labels, mount-queue depth, server alerts (R89).

## Env (Node solve / LLB)

Default is **engine-first**. `llb.git` / `materializeLlbGit` require the host emcc engine unless the
emergency escape hatch is set. **Only** `MC_GIT_USE_SYSTEM=1` (exact) enables ambient system `git`;
values like `true` / `0` / empty do **not**.

| Variable | Meaning |
|----------|---------|
| `MC_GIT_ENGINE_DIR` | Dir with `git_engine.mjs` + `git_engine.wasm` (**required** for `llb.git` by default) |
| `MC_GIT_ENGINE_BASE_URL` | Alternate URL form of the same dir |
| `MC_GIT_PACK_CACHE` | Optional on-disk pack cache dir (overrides process memory cache) |
| `MC_GIT_USE_SYSTEM` | **Emergency only** (`=1`): shell out to ambient system `git` |

Without `MC_GIT_ENGINE_DIR` / `MC_GIT_ENGINE_BASE_URL` and without `MC_GIT_USE_SYSTEM=1`, solve
**fails closed** (throws; does not silently use system git). Product `materializeLlbGit` /
`nodeSolvePlatformWithEngine` always plumb a **pack cache** by default (process `MemoryPackCache`,
or disk when `MC_GIT_PACK_CACHE` is set) so interactive remotes and LLB share the same CA pack path.

## c-shared / in-process load (K15 / R75) — **decided Port**

**Decision (closed residual R75):** product server load remains the BEAM-owned **Port** binary
(`git-engine`). `//memcontainers/lib/git-engine:libgit_engine` (`.so`) is **packaging-only** (license
ship set, optional consumers) — **not** an in-process product load path. PR7d is **not** reopened
for product latency work unless a future explicit decision overturns this. JS hosts continue to use
emcc wasm.

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
