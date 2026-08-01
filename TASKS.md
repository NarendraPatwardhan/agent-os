# feature/cgit — TASKS

**Plan:** close all design gaps (implementation-first).  
**Design of record:** `GIT.md`, `docs/git.md`.  
**Branch:** `feature/cgit` @ `dfa3bd1`+  

**Rules:** Status is only **OPEN** or **DONE** (with commit SHA when DONE).  
No “partial”, “foundation”, “honest residual”, “later”.  
Tests prove implementation; green tests alone are not DONE.

**Non-goals (not OPEN work):** full git-core porcelain parity; wasmi guest VCS; gojs/Go NIF; ambient credentials; freestanding wasmtime engine; interactive rebase/bisect/LFS/`git gui`; guest-side receive-pack as a service.

---

## Campaign chunks

| Chunk | Focus | Status |
|-------|--------|--------|
| 0 | Tracker truth | **OPEN** (await V0 PASS) |
| 1 | PR11 server connections | **OPEN** |
| 2 | Single-writer + SSRF + K17 | **OPEN** |
| 3 | Streaming packs + disk cache | **OPEN** |
| 4 | Partial clone + sparse parity + tracking | **OPEN** |
| 5 | Durability + snapshot rebind | **OPEN** |
| 6 | Submodules host-mediated | **OPEN** |
| 7 | Streaming stdout + engine polish | **OPEN** |
| 8 | Acceptance e2e matrix | **OPEN** |
| 9 | Metrics + packaging + GA | **OPEN** |

Verifier artifacts: `VERIFY_CHUNK_N.md` (PASS required before next chunk).

---

## Inventory D1–D41

### P0 — Architecture

| ID | Requirement | Status | Evidence / missing |
|----|-------------|--------|-------------------|
| D1 | Server remotes use connections catalog + splice (PR11) | **OPEN** | attach_git uses parallel `allowed_origins`/`auth` only |
| D2 | Single-writer FIFO per mount includes remote orch (JS) | **OPEN** | Engine serial; remote HTTP can overlap |
| D3 | Redirect policy cannot bypass origin allowlist | **OPEN** | Scheme/size/status gates exist; redirect re-check incomplete |
| D4 | K17: no guest `.git/objects` façade | **OPEN** | gitfs may list/expose objects path misleadingly |
| D5 | Tracker matches code | **OPEN** | This rewrite is Chunk 0; V0 must confirm |

### P1 — PR11 / policy

| ID | Requirement | Status | Evidence / missing |
|----|-------------|--------|-------------------|
| D6 | Connection-ref remotes on server | **OPEN** | No catalog ref → origins/auth resolve on BEAM remotes |
| D7 | Guest body cannot carry secrets | **OPEN** | Needs audit + fail tests product path |
| D8 | Auth kinds parity catalog e2e | **OPEN** | `auth_headers` exists; catalog-shaped e2e missing |
| D9 | clone.apply sets remote + tracking for usable pull | **OPEN** | fetch.apply updates remote-tracking; `branch.*` / `remote.*` config after clone incomplete |
| D10 | Push approval from connection policy both hosts | **OPEN** | Ad-hoc opts exist; policy map incomplete |

### P2 — PR13 packs

| ID | Requirement | Status | Evidence / missing |
|----|-------------|--------|-------------------|
| D11 | Stream download → chunked import_pack | **OPEN** | Whole-body buffer in orch |
| D12 | Disk CA pack cache JS + BEAM | **OPEN** | Process/memory cache; BEAM disk incomplete |
| D13 | Usable monorepo materialization (not filter-only) | **OPEN** | Filter wire only; no complete M7 story |
| D14 | Push haves dual-host production-ready | **DONE** | C `pack.build`/`ge_pack_build` haves (`engine.c`); JS `bridge.packBuild`+orch lease oldHash; BEAM `GitEngine.pack_build/3` haves; tests `abi_fixture_test`, `git_push_test`, orch R48 |
| D15 | Stream stdout beyond out/last | **OPEN** | truncated + out/last only |

### P3 — Durability / snapshot

| ID | Requirement | Status | Evidence / missing |
|----|-------------|--------|-------------------|
| D16 | OPFS/disk reattachable engine store | **OPEN** | AGIT checkpoint rebind only |
| D17 | Snapshot/fork rebinds git durable | **OPEN** | Not wired to snapshot lifecycle |
| D18 | Server durable engine root for named VMs | **OPEN** | Temp roots + cleanup |
| D19 | Snapshot blocked while git host_call inflight | **OPEN** | Not verified for git remotes |

### P4 — Sparse / multi-repo

| ID | Requirement | Status | Evidence / missing |
|----|-------------|--------|-------------------|
| D20 | Sparse cone on BEAM attach = JS | **OPEN** | JS `gitSparseCone`; BEAM not equivalent |
| D21 | Multi-mount e2e two clones + docs | **OPEN** | Demux code landed; product e2e/docs incomplete |
| D22 | Symlink/special file policy | **OPEN** | Mostly skipped |

### P5 — Submodules

| ID | Requirement | Status | Evidence / missing |
|----|-------------|--------|-------------------|
| D23 | Host-mediated submodule network clone/update | **OPEN** | List-only + fail-closed |
| D24 | Submodule worktree projection | **OPEN** | Not built |

### P6 — Acceptance / GA

| ID | Requirement | Status | Evidence / missing |
|----|-------------|--------|-------------------|
| D25 | Server guest CAP_NET e2e full path | **OPEN** | Host demux + fixture; not full guest image |
| D26 | Server CAP_NET deny e2e | **OPEN** | JS deny done in git_guest_e2e |
| D27 | Real HTTP clone e2e (git-http-backend or live) | **OPEN** | FixtureSmartHttp only |
| D28 | Real HTTP push e2e | **OPEN** | Fixture receive-pack only |
| D29 | Port kill → guest EIO booted guest | **OPEN** | Unit Port/Vm only |
| D30 | Server gitfs mount+ctl booted guest | **OPEN** | Port unit only |
| D31 | client_token + generation race acceptance | **OPEN** | Not implemented |
| D32 | Full golden set dual-host | **OPEN** | 6 goldens; missing push success/shallow/auth deny/non-FF |
| D33 | Dual-host Response schema + stderr catalog tests | **OPEN** | Substring checks only |
| D34 | Graduate experimentalGitEngine | **OPEN** | Still experimental |

### P7 — Ops / polish

| ID | Requirement | Status | Evidence / missing |
|----|-------------|--------|-------------------|
| D35 | Full metrics (duration, bytes, redacted origin) | **OPEN** | Basic counters only |
| D36 | Server alerts | **OPEN** | Not wired |
| D37 | L4 NOTICE in release artifacts | **OPEN** | L5 filegroup gate only |
| D38 | Prod git-engine discovery | **OPEN** | AGENTOS_GIT_ENGINE tribal |
| D39 | log/show polish | **OPEN** | Bounded but thin |
| D40 | Docs/skills + root GIT.md sync | **OPEN** | Drift remains |
| D41 | Catalog Face B `git run` | **OPEN** | Implement or strike from GIT.md |

---

## Already implemented (not open) — audit baseline

These product paths exist (do not re-open unless verifier finds regression). Evidence is **paths**, not vibes:

| Area | Evidence |
|------|----------|
| Thin CLI phase A | `memcontainers/programs/git/src/main.rs` — rm/diff/show/reset/tag/config/remote/switch/add -A/branch -d |
| Patch diff; truncated+out/last; multi-ref import; add-all deletions | `memcontainers/lib/git-engine/src/engine.c`, `engine_ops_extra.c`, `abi_fixture_test.c` |
| Host identity; bare-URL fail-closed; pull FF; depth=1 | `sdk-js/core/src/git/engine.ts`, `remote-orchestrator.ts`, `server/.../git_engine.ex`, orch |
| Server push + haves + delete-ref fixture | `server/.../orchestrator.ex`, `smart_http.ex`, `GitEngine.pack_build` |
| AGIT rebind; multi-mount demux; JS guest CAP_NET fixture e2e | `durable.ts`, `vm.ex` git_engines, `git_guest_e2e.test.ts` |
| Submodule list-only; Port product load; LLB engine-first | `engine_ops_extra.c` submodule; docs/git.md; `llb-git.ts` |
| P0 remotes gates | `smart_http.ex` origin/size/status; type-1 dial refuse in `port_handle.c` |

---

## Changelog

| Date | Change |
|------|--------|
| 2026-07-31 | Chunk 0: replace residual R* soft statuses with D1–D41 OPEN/DONE inventory |
