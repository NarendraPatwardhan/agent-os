# feature/cgit — task tracker

**Full critical review (archival report — not a summary):**  
→ **[`CRITICAL_REVIEW.md`](./CRITICAL_REVIEW.md)**  

That file holds the complete review: executive grades, C1–C8 with evidence, H1–H15, medium naming/org, per-layer agent deep-dives, full GIT.md remaining inventory (A–F), deferred lists, and priorities. **Update checkboxes here; do not shrink the report.**

**Branch:** `feature/cgit`  
**Rule:** Parallelize non-overlapping streams; serial only for shared contracts / merge.  
**Orchestrator standard:** no silent success, no soft tests, no doc lies, no dual policy primitives.

Legend: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked · `[D]` deferred (not a bug)

---

## Report → tracker map

| Review ID | One-line | Task |
|-----------|----------|------|
| C1 | BEAM SSRF / no origin policy | P0.1 |
| C2 | Empty-pack false green | P0.2, P0.3 |
| C3 | `fetch.apply` no-op success | P0.4 |
| C4 | Port type-1 → C fixture orch | P0.5 |
| C5 | Dual TS serial queues | P0.8 |
| C6 | CLI clone before git root | P0.6 |
| C7 | `ge_free` static OOM | P0.7 |
| C8 | K28 invented identity | P0.9 |
| H1–H15 | See CRITICAL_REVIEW.md | P1 / P2 |
| GIT.md remaining / deferred | § Remaining work in review | P1–P3 + Deferred |

---

## P0 — Block remotes GA / multi-tenant server

| ID | Task | Status | Notes |
|----|------|--------|-------|
| P0.1 | BEAM origin allowlist + scheme/userinfo + max pack + HTTP status fail-closed | [x] | `smart_http.ex` + orch |
| P0.2 | Never `ok:true` on empty/non-PACK; remove empty-pack apply skip | [x] | tests assert fail |
| P0.3 | Real minimal PACK fixture; import → worktree e2e | [x] | pack dir fix + `git_engine_pack_test.exs` → README |
| P0.4 | `fetch.apply` real or fail closed — no silent success | [x] | name+hash + remote-tracking |
| P0.5 | Port type-1 = `ge_run_json` only; C orch test/type-5 only | [x] | dial refuse |
| P0.6 | Thin CLI remotes **before** `find_git_root` | [x] | `main.rs` |
| P0.7 | `ge_free` safe on static OOM; `ge_response_is_static` | [x] | wasm export |
| P0.8 | One shared serial lock GitEngine + gitfs + importPack | [x] | `GitBridge.serial` |
| P0.9 | K28: no default Agent@example.com; require identity | [x] | commit requires name+email |

---

## P1 — Product honesty

| ID | Task | Status | Notes |
|----|------|--------|-------|
| P1.1 | Growable write/stdout; drop spike 64 KiB caps | [x] | `jmin_get_string_alloc` + heap status/log/diff/show |
| P1.2 | Wire durable into load **or** unexport + document deferred | [x] | engine-level only; classes off public barrel; MEMFS rebind deferred |
| P1.3 | Narrow `@mc/core` exports; fix `docs/api-surface.json` | [x] | product face only |
| P1.4 | Link `docs/git.md`; document `experimentalGitEngine` | [x] | index + create-options |
| P1.5 | Wasm `size_limit` → optimized artifact; L5 NOTICE CI | [x] | `:git_engine.wasm` + `assert_ship_files` |
| P1.6 | Async BEAM git host_call (Task.Supervisor) | [x] | remotes async; mount sync; cancel on detach |
| P1.7 | Guest CAP_NET / attach_git demux test | [~] | async claim + fixture transport under Vm; full guest e2e residual |
| P1.8 | Import `originAllowed` from `@mc/host` (drop duplicate) | [x] | connections + legacy orch allowlist |

---

## P2 — Designed PR tails

| ID | Task | Status | Notes |
|----|------|--------|-------|
| P2.1 | Push packbuilder (JS) or server read-only remotes documented | [ ] | server stub + injectible `buildPushPack`; need real or honest RO |
| P2.2 | Thin CLI phase-A surface or document reduced CLI | [x] | docs/git.md reduced surface |
| P2.3 | PR7d c-shared load path **or** demote K15 language | [x] | demoted in GIT.md/docs |
| P2.4 | LLB CI requires engine; system-git emergency + red tests | [x] | fail-closed test + docs |
| P2.5 | Sparse + pack cache production wiring | [ ] | APIs exist; wire defaults |
| P2.6 | Server PR11: connection ref + credential splice | [x] | attach_git allow_origins/auth host-owned |
| P2.7 | `add all=true` worktree walk | [x] | recursive stage |
| P2.8 | Shared executable golden orch vectors (TS ↔ BEAM) | [ ] | step prose remains |

---

## P3 — PR16 polish

| ID | Task | Status | Notes |
|----|------|--------|-------|
| P3.1 | Single design-of-record `GIT.md`; fix K16/K20 contradictions | [x] | worktree GIT.md |
| P3.2 | Graduate `experimentalGitEngine`; metrics | [ ] | stay experimental until remotes GA criteria |
| P3.3 | Product agent docs (one-mount, no objects façade, ctl flush) | [ ] | |
| P3.4 | Status Draft → accurate progress table | [x] | Implementing + TASKS pointer |

---

## Explicitly deferred (not bugs)

See **CRITICAL_REVIEW.md → Remaining work → Explicitly deferred**.  
Full git-core parity, wasmi multi‑MiB VCS, gojs, Go NIF, `.git/objects` façade v1, submodules, composite Rust intercept, multi-mount post-v1, ambient credentials, OPFS full ODB, streaming large stdout, catalog `git run`.

---

## Wave status

| Wave | Goal | Verified |
|------|------|----------|
| 1 | P0.1–P0.9 (+ report) | C/JS/mix; commit `03bfa22` |
| 2 | P1.1–P1.6, P1.8, P0.3 e2e, docs/build, P2.2–P2.4, P2.6–P2.7, P3.1/P3.4 | C + JS git_* + mix 16; path-safety residual fixed |
| 3 | P2.1, P2.5, P2.8, P1.7 tighten, P3.2–P3.3 | in progress |

### Orchestrator residual fixes (post Wave 2 agents)
- `op_branch_create` inverted `safe_relpath` / `strstr` logic → fail closed only
- `port_mount` `normalize_rel` uses `ge_safe_relpath` (not `strstr ..`)
- TS `checkLegacyAllowlist` uses `originAllowed` (host primitive)

---

## Changelog

| Date | Change |
|------|--------|
| 2026-07-31 | Wave 2 agents + serial polish; pack indexer path fix; async Vm remotes; docs/build honesty |
| 2026-07-31 | Wave 1 commit `03bfa22` P0 hardening + CRITICAL_REVIEW.md |
| 2026-07-31 | Full CRITICAL_REVIEW.md filed; TASKS is tracker only |
