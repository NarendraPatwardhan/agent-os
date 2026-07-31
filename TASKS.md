# feature/cgit — task tracker

**Full critical review (archival report — not a summary):**  
→ **[`CRITICAL_REVIEW.md`](./CRITICAL_REVIEW.md)**  

That file holds the complete pre-fix review baseline. **Update checkboxes here; do not shrink the report.**

**Branch:** `feature/cgit`  
**Orchestrator standard:** no silent success, no soft tests, no doc lies, no dual policy primitives.

Legend: `[ ]` open · `[~]` residual · `[x]` done · `[D]` deferred (not a bug)

---

## Report → tracker map

| Review ID | Task | Status |
|-----------|------|--------|
| C1–C8 | P0.* | [x] |
| H1–H15 | P1/P2 | [x] or [D] |
| GIT.md remaining | P1–P3 | [x] / residual notes |

---

## P0 — Block remotes GA / multi-tenant server

| ID | Task | Status |
|----|------|--------|
| P0.1 | BEAM origin/scheme/size/status fail-closed | [x] |
| P0.2 | Empty/non-PACK never ok:true | [x] |
| P0.3 | Real PACK import → worktree e2e | [x] |
| P0.4 | `fetch.apply` requires name+hash | [x] |
| P0.5 | Port type-1 dial refuse | [x] |
| P0.6 | CLI remotes before git root | [x] |
| P0.7 | `ge_free` static-safe | [x] |
| P0.8 | Shared GitBridge serial lock | [x] |
| P0.9 | K28 identity required | [x] |

---

## P1 — Product honesty

| ID | Task | Status |
|----|------|--------|
| P1.1 | Growable write/stdout | [x] |
| P1.2 | Durable honest (engine-level; MEMFS rebind deferred) | [x] |
| P1.3 | Narrow `@mc/core` exports + api-surface | [x] |
| P1.4 | docs/git + create-options experimental flags | [x] |
| P1.5 | size_limit optimized wasm + L5 NOTICE | [x] |
| P1.6 | Async BEAM git host_call + cancel | [x] |
| P1.7 | Guest CAP_NET demux | [x] foundation (async Vm + goldens); **full guest e2e residual** |
| P1.8 | `originAllowed` from `@mc/host` | [x] |

---

## P2 — Designed PR tails

| ID | Task | Status |
|----|------|--------|
| P2.1 | JS engine packbuilder; server push RO fail-closed | [x] |
| P2.2 | Thin CLI documented reduced surface | [x] |
| P2.3 | c-shared / K15 demoted | [x] |
| P2.4 | LLB engine-first + fail-closed test | [x] |
| P2.5 | Sparse cone + pack cache defaults | [x] |
| P2.6 | Server attach origins/auth host-owned | [x] |
| P2.7 | `add all=true` worktree walk | [x] |
| P2.8 | Executable golden orch vectors TS↔BEAM | [x] |

---

## P3 — PR16 polish

| ID | Task | Status |
|----|------|--------|
| P3.1 | GIT.md K16/K20/K15 honesty | [x] |
| P3.2 | experimental stays; graduation criteria documented | [x] (not graduated) |
| P3.3 | Product agent docs in docs/git.md | [x] |
| P3.4 | Status accurate + TASKS pointer | [x] |

---

## Explicitly deferred (not bugs)

See **CRITICAL_REVIEW.md**. Full git-core parity, wasmi multi‑MiB VCS, gojs, Go NIF, `.git/objects` façade v1, submodules, composite Rust intercept, multi-mount post-v1, ambient credentials, OPFS full ODB, server push packbuilder/receive-pack, full guest CAP_NET e2e, metrics graduation, streaming large stdout.

---

## Wave commits

| Wave | Commit | Scope |
|------|--------|-------|
| 1 | `03bfa22` | P0 + CRITICAL_REVIEW |
| 2 | `c7c04fd` | P1 honesty, pack e2e, docs/build |
| 3 | (pending) | P2.1 packbuilder, P2.5 cache/sparse, P2.8 goldens, BEAM queue |

---

## Residual risks (honest)

1. Full guest CAP_NET e2e (thin `/bin/git` → kernel → host_call) not automated end-to-end.
2. Server push intentionally unsupported; JS push has no thin-pack negotiation (full history).
3. Durable MEMFS rebind not implemented (engine-level opaque only).
4. `experimentalGitEngine` not graduated.
5. Workspace-root `GIT.md` may lag worktree copy.

---

## Changelog

| Date | Change |
|------|--------|
| 2026-07-31 | Wave 3: packbuilder, cache/sparse, goldens, BEAM queue/RO push, agent docs |
| 2026-07-31 | Wave 2 commit `c7c04fd` |
| 2026-07-31 | Wave 1 commit `03bfa22` + full CRITICAL_REVIEW.md |
