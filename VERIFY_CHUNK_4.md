# VERIFY_CHUNK_4

Verdict: **PASS**

Hostile verifier for `feature/cgit` Chunk 4 (D13 monorepo cone + D20 BEAM sparse attach + D9 clone tracking + D21 two-mount e2e). Tree: `feature/cgit` @ `f707f8f` + dirty working tree (Chunk 4 sources modified, uncommitted). No product code changed by this verifier.

---

## Acceptance matrix

| # | Requirement | Result | Evidence |
|---|-------------|--------|----------|
| 1 | **D13** shallow+sparse monorepo: cone worktree usable (prune out-of-cone), not filter-only | **PASS** | See A1 |
| 2 | **D20** BEAM `sparse_cone` on `attach_git` | **PASS** | See A2 |
| 3 | **D9** clone sets `remote.origin.url` + branch tracking; pull without re-passing URL | **PASS** | See A3 |
| 4 | **D21** two-mount clone e2e JS and BEAM | **PASS** | See A4 |
| 5 | Tests green for these | **PASS** | See A5 |

All five hold. Chunk 4 verdict is **PASS**.

---

## A1 — D13 shallow + cone sparse (worktree prune, not filter-only) — PASS

**Product path (M7 v1)** = default `depth=1` + cone `sparse-set` + **disk prune** of out-of-cone paths. Optional `filter` remains a separate knob; monorepo usability does **not** depend on promisor/filter alone.

| Path | Proof |
|------|--------|
| `/mnt/workspace/agent-os/agent-os-cgit/server/lib/agent_os/git/orchestrator.ex` `depth_of/1` | Product default shallow: missing/invalid depth → `1`; `depth<=0` → full |
| same `clone/3` | After `configure_clone_remote`, calls `apply_sparse_cone/4` → Port `sparse-set` + checkout |
| `/mnt/workspace/agent-os/agent-os-cgit/memcontainers/lib/git-engine/src/engine_ops_extra.c` `op_sparse_set` | Writes cone sparse-checkout (`/*`, `!/*/`, `/{prefix}/`, `/{prefix}/**`); `core.sparseCheckout` + cone flag; force checkout HEAD; **`cone_prune_walk` removes out-of-cone worktree paths** (libgit2 alone leaves them) |
| same `cone_path_kept` / `cone_prune_walk` | Root-level files kept; directories/files outside cone prefixes `rm -rf`; never enters `.git` |
| JS orch | `GitRemoteOrchestrator.applySparseCone` post-`clone.apply`; inherits `engine.sparseCone` when orch opts omit cone |
| JS gitfs | `asMountDriver({ sparseCone })` projection is defense-in-depth; D13 test also uses **empty cone** full driver and still must not see `other/` (MEMFS prune, not filter-only theater) |

**Tests**

| Path | Assertion |
|------|-----------|
| `server/test/agent_os/git_engine_pack_test.exs` `D13 monorepo multi-path clone+sparse…` | Multi-path pack (`src/in.txt` + `other/out.txt`); clone with `sparse_cone: ["src"]`; `depth==1`; `src/in.txt` present; **`other/` and `other/out.txt` absent on Port worktree**; sparse-checkout written |
| `memcontainers/sdk-js/core/test/git_remote.test.ts` D13 block | Same monorepo pack path; `seenDepth === 1`; full driver readdir hides `other/`; gitfs cone + ENOENT on out-of-cone |

---

## A2 — D20 BEAM `sparse_cone` on `attach_git` — PASS

| Path | Proof |
|------|--------|
| `/mnt/workspace/agent-os/agent-os-cgit/server/lib/agent_os/vm.ex` `attach_git` | Docs + `git_sparse_cone_from_opts/1` accept `:sparse_cone` / `:git_sparse_cone`; stored **per mount** in `git_engines[mount].sparse_cone` |
| same `git_host_opts_for_mount/2` | Injects mount cone into orch opts for remote host_call demux |
| `/mnt/workspace/agent-os/agent-os-cgit/server/lib/agent_os/control_plane.ex` `attach_git/2` | Forwards opts; documents D20 JS parity |
| `/mnt/workspace/agent-os/agent-os-cgit/server/lib/agent_os/git/orchestrator.ex` `apply_sparse_cone/4` | Port `sparse-set` + checkout after clone (JS `applySparseCone` parity) |

**Tests**

| Path | Assertion |
|------|-----------|
| `git_engine_pack_test.exs` `D20 BEAM orch clone with sparse_cone…` | Orch `sparse_cone: ["src","/docs/"]` → sparse-checkout lines + root README kept |
| `git_orchestrator_test.exs` `D20 attach_git sparse_cone → host_call clone…` | `attach_git(sparse_cone: ["src","docs"])`; mount meta `sparse_cone == ["src","docs"]`; host_call clone → Port sparse-checkout exists with `/src/`, `/docs/`, `/*` |

---

## A3 — D9 clone remote + tracking; pull without URL — PASS

| Path | Proof |
|------|--------|
| BEAM `orchestrator.ex` `configure_clone_remote/4` | Post-`clone.apply`: `remote add origin` (or config set URL), `branch.<short>.remote` / `.merge`, `refs/remotes/origin/<short>` import |
| BEAM `fill` via `resolve_binding` / config get | Pull/fetch with `remote:origin` or empty args resolve URL from engine `remote.<name>.url` |
| JS `remote-orchestrator.ts` `configureCloneRemote` + `fillRemoteArgsFromConfig` | Same post-clone tracking; empty pull defaults to `origin` |

**Tests**

| Path | Assertion |
|------|-----------|
| `git_orchestrator_test.exs` `D9 clone sets remote.origin.url and branch tracking; pull uses remote name` | After clone: `remote.origin.url`, `branch.main.remote=origin`, `branch.main.merge=refs/heads/main`; pull `remote=origin` and pull `{}` both ok |
| `git_remote.test.ts` D9 block | Same config keys + pull via remote name + empty-args pull |

---

## A4 — D21 two-mount clone e2e JS + BEAM — PASS

| Path | Proof |
|------|--------|
| BEAM `Vm.attach_git` multi-mount | Distinct `mount_path` → independent engines/roots; `try_answer_git_host_call` demux via `args.mount` |
| JS `gitHostCallHandler` + `resolveGitEngineForMount` | Per-mount engines; unknown mount fails closed without dial |
| Docs `docs/git.md` multi-mount section | Setup, demux table, concurrency, proof pointers |

**Tests**

| Path | Assertion |
|------|-----------|
| BEAM `R65/D21 host_call args.mount two clones into two engines` | attach ×2 (`/workspace/a`,`/workspace/b`); clone each via `args.mount` + real `minimal.pack`; README `hello\n` each root; isolation write A ↛ B; unknown mount no dial |
| BEAM `D21 concurrent remotes on two mounts may overlap` | Concurrent clones on two mounts (per-mount single-writer only) |
| JS `git_remote.test.ts` D21 dual clone | `gitHostCallHandler` + two engines + real pack → README isolation; concurrent two-mount clones |

---

## A5 — Tests green — PASS

Executed (this verifier, no product edits):

| Command | Result |
|---------|--------|
| `bazel --output_user_root=/mnt/workspace/agent-os/bazel-cache test //memcontainers/sdk-js/core:git_remote_test --cache_test_results=no` | **PASSED** (`git_remote.test SUCCESS`) |
| `bazel --output_user_root=/mnt/workspace/agent-os/bazel-cache test //server:mix_test --test_arg=test/agent_os/git_orchestrator_test.exs --test_arg=test/agent_os/git_engine_pack_test.exs --cache_test_results=no` | **PASSED** — `103 tests, 0 failures, 2 excluded` (NIF + kernel/posix + `AGENTOS_GIT_ENGINE` staged by Bazel) |

**Env note (not a product FAIL):** bare `cd server && AGENTOS_GIT_ENGINE=… mix test …` without Bazel-staged `priv/libhost_nif.so` fails ControlPlane attach e2e (D20 attach, D21 dual-mount, etc.) with NIF load error, even when wasm/posix runfiles are visible. Hermetic product path is `//server:mix_test` (BUILD wires NIF + git-engine + images + `AGENTOS_GIT_ENGINE`). Non-attach orch/pack cases exercise the Port with `AGENTOS_GIT_ENGINE` alone; attach demux e2e requires the NIF suite.

---

## Hostile angles checked (did not FAIL)

1. **Filter-only theater** — D13 asserts worktree absence of `other/` with full (non-cone) driver / Port `File.exists?`, not only gitfs hide. Engine `cone_prune_walk` is real rm.
2. **Checkout re-materialize** — post-sparse checkout does not leave out-of-cone paths; D13 green on both hosts.
3. **D20 attach not wired** — mount meta stores cone; `git_host_opts_for_mount` injects into orch; attach e2e writes sparse-checkout via host_call clone.
4. **D9 config get dead** — live `config get` + pull without URL works in BEAM + JS tests.
5. **D21 demux fake** — real `minimal.pack` worktree README on both mounts; unknown mount no transport dial; concurrent overlap test present.

---

## Commands to re-verify

```bash
cd /mnt/workspace/agent-os/agent-os-cgit
bazel --output_user_root=/mnt/workspace/agent-os/bazel-cache test \
  //memcontainers/sdk-js/core:git_remote_test \
  //server:mix_test \
  --test_output=errors --cache_test_results=no
# Optional: limit mix files
# --test_arg=test/agent_os/git_orchestrator_test.exs \
# --test_arg=test/agent_os/git_engine_pack_test.exs
```
