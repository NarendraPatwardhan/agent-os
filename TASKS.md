# feature/cgit — task tracker

**Full critical review (archival report — not a summary):**  
→ **[`CRITICAL_REVIEW.md`](./CRITICAL_REVIEW.md)**  

That file holds the complete review: executive grades, C1–C8 with evidence, H1–H15, medium naming/org, per-layer agent deep-dives, full GIT.md remaining inventory (A–F), deferred lists, and priorities. **Update checkboxes here; do not shrink the report.**

**Branch:** `feature/cgit`  
**Rule:** Parallelize non-overlapping streams; serial only for shared contracts / merge.

Legend: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked

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

## Parallelization plan

| Stream | Touch areas | Depends on |
|--------|-------------|------------|
| **A — C engine** | `memcontainers/lib/git-engine/**` | none |
| **B — Thin CLI** | `memcontainers/programs/git/**` | none |
| **C — TS single-writer** | `sdk-js/core/src/git/{engine,gitfs,bridge}.ts` | none |
| **D — BEAM remotes** | `server/lib/agent_os/git/**`, tests | none |
| **E — Docs** | `CRITICAL_REVIEW.md`, `TASKS.md`, later `GIT.md` | after code P0 |
| **F — Pack fixture** | `testdata/pack/`, server fixtures | A apply + D tests |
| **G — Public API** | `sdk-js/core/src/index.ts`, docs | after C |

**Serial constraints**
- Stream A owns all C; no parallel editors on `engine.c` / `port_handle.c`.
- BEAM empty-pack honesty + origin policy land together (stream D).
- Pack fixture (F) then re-point D/JS success tests at real PACK bytes.
- GIT.md K16/K20 sync after code stabilizes (E last).

---

## P0 — Block remotes GA / multi-tenant server

| ID | Task | Stream | Status | Notes |
|----|------|--------|--------|-------|
| P0.1 | BEAM origin allowlist + scheme/userinfo + max pack + HTTP status fail-closed | D | [x] | `smart_http.ex` + orch pre-dial gate; mix 12 passed |
| P0.2 | Never `ok:true` on empty/non-PACK; remove empty-pack apply skip | D | [x] | empty pack → ok:false; tests assert |
| P0.3 | Real minimal PACK fixture; assert import path | F | [~] | bytes on disk (`testdata/pack/`, `server/test/fixtures/git/`); orch tests use synthetic non-empty PACK — full import→worktree e2e still open |
| P0.4 | `fetch.apply` real or fail closed — no silent success | A | [x] | requires name+hash; remote-tracking + FETCH_HEAD; C tests green; **serial glue:** BEAM+TS orch now pass args |
| P0.5 | Port type-1 = `ge_run_json` only; C orch test/type-5 only | A | [x] | type-1 dial refuse; type-5 test-only |
| P0.6 | Thin CLI remotes **before** `find_git_root` | B | [x] | `main.rs`; git.wasm build OK |
| P0.7 | `ge_free` safe on static OOM; `ge_response_is_static` if claimed | A | [x] | implemented + wasm export |
| P0.8 | One shared serial lock GitEngine + gitfs + importPack | C | [x] | `GitBridge.serial`; all 5 js git tests green |
| P0.9 | K28: no default Agent@example.com; require or host-inject identity | A | [x] | commit requires name+email; host-policy inject still P1/P2 |

---

## P1 — Product honesty

| ID | Task | Status |
|----|------|--------|
| P1.1 | Growable write/stdout; drop spike 64 KiB caps where practical | [ ] |
| P1.2 | Wire durable into load **or** unexport + document deferred | [ ] |
| P1.3 | Narrow `@mc/core` exports; fix `docs/api-surface.json` | [ ] |
| P1.4 | Link `docs/git.md`; document `experimentalGitEngine` create options | [ ] |
| P1.5 | Wasm `size_limit` → optimized artifact; L5 NOTICE CI | [ ] |
| P1.6 | Async BEAM git host_call (Task.Supervisor like sidecars) | [ ] |
| P1.7 | Guest CAP_NET / attach_git demux test | [ ] |
| P1.8 | Import `originAllowed` from `@mc/host` (drop duplicate) | [ ] |

---

## P2 — Designed PR tails

| ID | Task | Status |
|----|------|--------|
| P2.1 | Push packbuilder (JS) or server read-only remotes documented | [ ] |
| P2.2 | Thin CLI phase-A surface or document reduced CLI | [ ] |
| P2.3 | PR7d c-shared load path **or** demote K15 language | [ ] |
| P2.4 | LLB CI requires engine; system-git emergency + red tests | [ ] |
| P2.5 | Sparse + pack cache production wiring | [ ] |
| P2.6 | Server PR11: connection ref + credential splice | [ ] |
| P2.7 | `add all=true` worktree walk | [ ] |
| P2.8 | Shared executable golden orch vectors (TS ↔ BEAM) | [ ] |

---

## P3 — PR16 polish

| ID | Task | Status |
|----|------|--------|
| P3.1 | Single design-of-record `GIT.md`; fix K16/K20/Open-Q#10 contradictions | [ ] |
| P3.2 | Graduate `experimentalGitEngine`; metrics | [ ] |
| P3.3 | Product agent docs (one-mount, no objects façade, ctl flush) | [ ] |
| P3.4 | Status Draft → accurate progress table | [ ] |

---

## Explicitly deferred (not bugs)

See **CRITICAL_REVIEW.md → Remaining work → Explicitly deferred**.  
Full git-core parity, wasmi multi‑MiB VCS, gojs, Go NIF, `.git/objects` façade v1, submodules, composite Rust intercept, multi-mount post-v1, ambient credentials.

---

## Wave 1 status

| Stream | Goal | Code present? | Verified green? |
|--------|------|---------------|-----------------|
| A | P0.4, P0.5, P0.7, P0.9 | yes | C `//memcontainers/lib/git-engine:all` (agent) + recheck abi/port |
| B | P0.6 | yes | `//memcontainers/programs/git:all` build |
| C | P0.8 | yes | all 5 `git_*` js_tests |
| D | P0.1, P0.2 | yes | mix 12 passed (absolute `AGENTOS_GIT_ENGINE`) |
| F | P0.3 pack bytes | partial | fixtures staged; full worktree e2e open |
| E | Full report on disk | **yes** | `CRITICAL_REVIEW.md` + this tracker |
| Serial glue | BEAM/TS `fetch.apply` args after P0.4 | yes | mix + `git_remote_test` recheck |

**Next:** commit Wave 1 (report + P0 code); then P0.3 real pack e2e / P1.

---

## Changelog

| Date | Change |
|------|--------|
| 2026-07-31 | Wave 1 agents landed P0.1–P0.2, P0.4–P0.9 uncommitted; serial glue for `fetch.apply` args; report filed in `CRITICAL_REVIEW.md`. |
| 2026-07-31 | `CRITICAL_REVIEW.md` written (full report). `TASKS.md` is tracker + map into report. |
| 2026-07-31 | Earlier: checklist-only TASKS.md (insufficient — report was not filed). |
