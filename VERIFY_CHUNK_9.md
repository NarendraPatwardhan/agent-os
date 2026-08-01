# VERIFY_CHUNK_9

Verdict: **PASS**

Hostile verifier for `feature/cgit` Chunk 9 (metrics duration/bytes/redacted; alerts; L5 NOTICE; discover_executable; experimental stays unless all prior PASS; D41 struck). Tree: `feature/cgit` @ `a5c23de` + dirty working tree. No product code changed by this verifier.

---

## Acceptance matrix

| # | Requirement | Result | Evidence |
|---|-------------|--------|----------|
| 1 | **D35** metrics: duration, pack_bytes, redacted origin | **PASS** | See A1 |
| 2 | **D36** server alerts (allowlist deny + queue depth) | **PASS** | See A2 |
| 3 | **D37** L5 NOTICE gates on ship sets | **PASS** | See A3 |
| 4 | **D38** `discover_executable` prod path | **PASS** | See A4 |
| 5 | **experimental stays** (not graduated while blockers remain) | **PASS** | See A5 |
| 6 | **D41** catalog Face B `git run` struck | **PASS** | See A6 |
| 7 | Tests / gates green | **PASS** | See A7 |

All listed Chunk 9 requirements hold. Verdict **PASS**.

---

## A1 — D35 metrics (duration / bytes / redacted) — PASS

| Host | Module | Labels / counters |
|------|--------|-------------------|
| **BEAM** | `server/lib/agent_os/git/metrics.ex` | `record_remote_result/3`: `last_duration_ms`, `last_pack_bytes`, `last_origin_redacted`, `duration_ms_sum`, `pack_bytes_sum`; op ok/error counters |
| **JS** | `memcontainers/sdk-js/core/src/git/metrics.ts` | same shape; `redactOrigin` strips userinfo/path secrets |
| Wire-up | BEAM `orchestrator.ex` `record_metrics`; JS `remote-orchestrator.ts` | per remote op |

**Tests:** `git_orchestrator_test.exs` D35 (allowlist deny + fixture clone pack_bytes/duration/redacted); JS `git_engine.test` D35 block (recordRemoteResult + redactOrigin).  
**Live log:** `git: allowlist deny origin=https://example.com` (redacted host form, no tokens).

---

## A2 — D36 server alerts — PASS

| Alert | Trigger | Counter | Log |
|-------|---------|---------|-----|
| Allowlist deny | origin policy reject before dial | `allowlist_deny` | `Logger.warning("git: allowlist deny origin=…")` |
| Queue depth | per-mount remote queue **> 32** after enqueue | `queue_depth_warn` | `git: mount queue depth N > 32 mount=…` |

Wiring: `Metrics.observe_queue_depth/2` from `vm.ex` enqueue path; `alert_allowlist_deny/1` from `record_remote_result` when `allowlist_deny?`.

**Tests:** D36 unit observes depth 33 → warn counter; mix_test log shows both warning classes.

---

## A3 — L5 NOTICE (fail-closed ship membership) — PASS

| Gate | Target | Required basenames |
|------|--------|--------------------|
| Server engine ship | `//memcontainers/lib/git-engine:git_engine_server_l5_notices` | NOTICE, COPYING, AUTHORS (+ binary set) |
| Wasm ship | `//memcontainers/lib/git-engine:git_engine_wasm_l5_notices` | NOTICE + COPYING/AUTHORS |
| Package priv ship | `//server:agent_os_git_engine_l5_notices` | NOTICE, COPYING, AUTHORS, git-engine |

Mechanism: `ship_gate.bzl` `assert_ship_files` — **analysis fails** if NOTICE dropped from filegroup (not silent `data =` hope).  
Package tar stages `priv/git-engine` + `priv/third_party/libgit2/{NOTICE,COPYING,AUTHORS}`.

**This run:** all three L5 build_tests **PASSED**.

---

## A4 — D38 discover_executable — PASS

`AgentOS.GitEngine.discover_executable/0` → `default_executable/0` order:

1. `AGENTOS_GIT_ENGINE`
2. `Application.app_dir(:agent_os, "priv/git-engine")`
3. `:code.priv_dir(:agent_os)/git-engine`
4. `$RELEASE_ROOT` priv layouts
5. CWD / workspace fallbacks

**Test:** `D38 discover_executable prefers AGENTOS_GIT_ENGINE` in `git_orchestrator_test.exs`. Docs: `docs/git.md` discovery section.

---

## A5 — experimental stays — PASS (correct non-graduation)

| Check | Result |
|-------|--------|
| `docs/api-surface.json` `GitEngine` / host_call surface | `"level": "experimental"` |
| `docs/create-options.md` `experimentalGitEngine` | documented **experimental**, default false |
| Graduation | **Not** flipped to stable |

**Why stay is mandatory even after Chunk 7/8:**

- **D32** full golden set still **OPEN** (shallow/auth deny/non-FF missing).
- **D33** dual-host Response schema catalog still **OPEN** (substring checks).
- D5 tracker hygiene residual.

User rule: *experimental stays unless all prior PASS* → residual OPEN IDs remain → flag must stay. **No false GA.**

**Hostile doc inconsistency (not FAIL for experimental rule):**

- `TASKS.md` D34 text claims “criterion 5 now Met” and also still lists D15/D22 among remaining OPEN — mixed.
- `docs/git.md` graduation table still marks criterion **5 CAP_NET e2e** as **Open** and inventories D15/D22/D25–D31 as remaining OPEN, which is **stale** relative to code + VERIFY_CHUNK_7/8.

Stale “Open” is the opposite of false DONE on graduation. Correct product behaviour: keep experimental. D40 inventory list should be scrubbed later (D5).

---

## A6 — D41 catalog Face B struck — PASS

| Evidence | Content |
|----------|---------|
| `GIT.md` Face table | Catalog tool `git run` struck (D41); remotes use host_call `"git"` only |
| Narrative | “never productized”; do not seed catalog with `git run` as product path |

No product reintroduction of catalog Face B found in this verify pass.

---

## A7 — Tests / gates green — PASS

```
//memcontainers/lib/git-engine:git_engine_server_l5_notices   PASSED
//memcontainers/lib/git-engine:git_engine_wasm_l5_notices     PASSED
//server:agent_os_git_engine_l5_notices                       PASSED
//memcontainers/sdk-js/core:git_engine_test                   PASSED  (includes D35)
//server:mix_test                                             PASSED  (D35/D36/D38 + real HTTP + guest)
```

mix_test log shows allowlist deny warnings, queue-depth-33 warning, and D35 counter path exercised.

---

## Hostile residual (not FAIL)

| Item | Severity | Note |
|------|----------|------|
| Graduation checklist / “Remaining OPEN” in `docs/git.md` lag code | D5/D40 hygiene | Lists closed IDs as OPEN; does **not** graduate (good) |
| TASKS D34 “Remaining OPEN: D15, D22…” after inventory DONE | Tracker lie residual | Prefer D5 fix; not Chunk 9 metric FAIL |
| D32/D33 still OPEN | Expected | Blocks real GA; experimental correctly stays |
| JS metrics D35 unit is counter API smoke (orch path also records) | Soft | BEAM orch records on real remote ops |

---

## False-DONE traps checked

| Trap | Outcome |
|------|---------|
| Metrics = counters only, no duration/bytes/redaction | **Rejected** — labels + redaction + tests |
| Alerts = counter without log / never called | **Rejected** — Logger.warning + vm enqueue observe; log proof |
| L5 = NOTICE only as non-gating `data=` | **Rejected** — `assert_ship_files` build_test fails if omitted |
| Graduated experimental while D32/D33 open | **Rejected** — api-surface still experimental |
| D41 “struck” while catalog still ships git run product path | **Rejected** — design text struck; host_call only |
| Claiming Chunk 9 DONE because tests green while experimental flipped | N/A — experimental not flipped |
