# VERIFY_CHUNK_6

Verdict: **PASS**

Hostile verifier for `feature/cgit` Chunk 6 (D23 host-mediated submodule network update, D24 nested worktree projection, dual-host proof). Tree: `feature/cgit` @ `662dadd` + dirty working tree (Chunk 5/6 sources uncommitted). No product code changed by this verifier.

---

## Acceptance matrix

| # | Requirement | Result | Evidence |
|---|-------------|--------|----------|
| 1 | **D23** host-mediated submodule network update (not list-only) | **PASS** | See A1 |
| 2 | **D24** nested worktree visible on guest/host FS after update | **PASS** | See A2 |
| 3 | Dual-host proof | **PASS** | See A3 |
| 4 | Tests green | **PASS** | See A4 |

All four hold. Chunk 6 verdict is **PASS**.

---

## A1 — D23 host-mediated submodule network update (not list-only) — PASS

**List-only is not DONE.** Network update is host orch only; engine never dials.

### Engine (fail-closed purity)

| Piece | Path | Behaviour |
|-------|------|-----------|
| `op:submodule` list/status | `memcontainers/lib/git-engine/src/engine.c` + `engine_ops_extra.c` | Parse `.gitmodules` + optional gitlink hash; no network |
| `op:submodule` update/init/clone via **engine.run** | `engine.c` | **Fail closed** — stderr requires `host_call` + orchestrator |
| `ge_open` nested | `engine.c` | `GIT_REPOSITORY_OPEN_NO_SEARCH` so nested path does not bind parent `.git` |
| `op:gitlink` | engine | Local stage mode 160000 (super setup; no dial) |

### Host orch (network + nested apply)

| Host | Path | Behaviour |
|------|------|-----------|
| **JS** | `memcontainers/sdk-js/core/src/git/remote-orchestrator.ts` `submodule()` | list → origin policy on URL → `listRefs` + pack fetch → `applyNestedClone` via `bridge.openAt` same MEMFS |
| **BEAM** | `server/lib/agent_os/git/orchestrator.ex` `submodule` / `submodule_update` | list → policy → transport list_refs/fetch_packs → nested Port `root: super_root/path` → `clone` apply + optional gitlink checkout |

Flow (both hosts):

```text
host_call "git" { op: "submodule", args: { action: "update" } }
  → engine list (.gitmodules + gitlink)
  → per entry: connection/origin policy on URL
  → ListRefs + FetchPacks (host HTTP only)
  → nested engine at super/<path> → init + import_pack + clone.apply
  → nested files under super worktree (gitfs / host FS)
```

**Not list-only:** tests assert real dials (`listRefsCalls` / `fetchPacksCalls` ≥ 1 JS; atomics dial counter ≥ 2 BEAM) and materialize nested `deps/lib/README`.

---

## A2 — D24 nested worktree visible after update — PASS

| Host | Visibility surface | Proof |
|------|--------------------|-------|
| **JS** | Super MEMFS under nested path + gitfs driver | After orch update: `bridge.FS.readFile(.../deps/lib/README) === "hello\n"`; `asMountDriver().readdir("deps/lib")` has `README`; `open("deps/lib/README")` same content |
| **BEAM** | Host FS under super Port root | `File.exists?(root/deps/lib/README)` and content `"hello\n"`; `File.dir?(root/deps/lib/.git)` (real nested repo, not empty dir theater) |

Nested apply details:

- JS: `GitBridge.openAt` / `importPackAt` / `runAt` on nested eng; `GIT_REPOSITORY_OPEN_NO_SEARCH` prevents parent bind.
- BEAM: nested `GitEngine.start(root: Path.join(super_root, path))` → clone via same orch policy → files land under super root for gitfs projection when mounted.

---

## A3 — Dual-host proof — PASS

| Host | Test | What it proves |
|------|------|----------------|
| **JS** | `memcontainers/sdk-js/core/test/git_remote.test.ts` D23–D24 block | Super `.gitmodules` + gitlink + `minimal.pack` submodule; engine update fail-closed; list has gitlink hash; origin deny; orch update dials + nested README + gitfs |
| **BEAM** | `server/test/agent_os/git_orchestrator_test.exs` `"D23/D24 host-mediated submodule update projects nested worktree"` | Same fixture class; engine fail-closed; list hash; origin deny; orch update dials ≥2; nested README + `.git` on disk |

Both hosts exercise the same product contract: orch network update + nested worktree materialization. Fixture: superproject + gitlink tip + `minimal.pack` → nested `README` = `hello\n`.

---

## A4 — Tests green — PASS

### Bazel (forced re-run, `--nocache_test_results`)

```
//memcontainers/lib/git-engine:abi_fixture_test     PASSED
//memcontainers/sdk-js/core:git_engine_test         PASSED
//memcontainers/sdk-js/core:git_guest_e2e_test      PASSED
//memcontainers/sdk-js/core:git_remote_test         PASSED   ← includes D23–D24
```

### BEAM

```bash
AGENTOS_GIT_ENGINE=<bazel-bin>/memcontainers/lib/git-engine/git-engine \
  MIX_ENV=test mix test test/agent_os/git_orchestrator_test.exs:3124
```

Result: **D23/D24 passed** (nested Port ready on `super/deps/lib`, update ok).

Full `git_engine_test.exs`: **7 passed** (adjacent Port durability; not required for Chunk 6 acceptance but green).

### BEAM / NIF env limits (honest, not soft-close)

- D23/D24 proofs above are **Port + Orchestrator** level with injectable fixture transport — correct product path for host-mediated remotes (K16 HTTPS stays in BEAM orch).
- Full guest-image CAP_NET allow/deny through NIF VM is **D25/D26 OPEN** (out of Chunk 6). Not claimed here.
- Native engine binary required via `AGENTOS_GIT_ENGINE`; available from Bazel `//memcontainers/lib/git-engine:git-engine`.
- Host NIF not required for D23/D24 Port orch tests; `//server:mix_test` hermetic suite stages NIF when run under Bazel elixir transition.

---

## Hostile residual (not FAIL)

| Item | Severity | Note |
|------|----------|------|
| Engine list-only still present | By design | Required purity; orch is the network path; tests fail if update succeeds on engine alone |
| v1 nested update rm_rf nested path | Product choice | Fresh nested worktree each update; files re-materialize under super root |
| No thin CLI `submodule` | Documented | Thin CLI does not expose submodule; host_call orch only |
| Uncommitted tree | Process | Verify on dirty sources; promote after commit |
| Guest CAP_NET full image | Out of scope | D25 OPEN |
