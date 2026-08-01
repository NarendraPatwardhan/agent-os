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
| 0 | Tracker truth | **DONE** (`c580f7e`, VERIFY_CHUNK_0.md) |
| 1 | PR11 server connections | **DONE** (VERIFY_CHUNK_1.md) |
| 2 | Single-writer + SSRF + K17 | **DONE** (VERIFY_CHUNK_2.md) |
| 3 | Streaming packs + disk cache | **DONE** (VERIFY_CHUNK_3.md) |
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
| D1 | Server remotes use connections catalog + splice (PR11) | **DONE** | `server/lib/agent_os/git/connections.ex` resolve+splice; `Vm.attach_git(connections:)` product path (no flat allowlist); orch `resolve_binding`/`apply_binding`; compose e2e `PR11 product path: attach_git connections-only → host_call clone via fixture` in `git_orchestrator_test.exs`; JS `git_connections.test.ts` |
| D2 | Single-writer FIFO per mount includes remote orch (JS) | **DONE** | Per-engine `remoteQueue` promise mutex in `remote-orchestrator.ts` `handle()`; test peak concurrent `fetchPacks` ≤ 1 in `git_remote.test.ts`; BEAM per-mount `git_remote_queue` in `vm.ex` |
| D3 | Redirect policy cannot bypass origin allowlist | **DONE** | Dual-host fail-closed reject-all redirects: BEAM `autoredirect: false` + `classify_http_response` → `:redirect_not_allowed` (3xx unit + local `:gen_tcp` 302 open-redirect never followed); JS `FetchSmartHttp` `redirect:"manual"` + `isRedirectResponse` (mock 302 → evil.example fails list/fetch/push, never dials Location). Docs in both module headers. |
| D4 | K17: no guest `.git/objects` façade | **DONE** | `gitfs.ts` `isObjectsPath` + ENOENT; `normalizeRel` collapses `.`/empty segments so `/.git/./objects` and `/.git//objects` cannot hit host ODB (`bridge.ts`); Port `port_mount.c` early ENOENT; tests `git_engine.test.ts` + `port_smoke_test.c` |
| D5 | Tracker matches code | **OPEN** | This rewrite is Chunk 0; V0 must confirm |

### P1 — PR11 / policy

| ID | Requirement | Status | Evidence / missing |
|----|-------------|--------|-------------------|
| D6 | Connection-ref remotes on server | **DONE** | Guest `args.connection`/`agentos` → `Connections.resolve_remote/2`; unknown ref / empty origins fail closed; orch clone with connection-only (no `allowed_origins`); `Vm.git_host_opts` forwards `connections`+`policies` |
| D7 | Guest body cannot carry secrets | **DONE** | JS `guestArgsCarrySecrets` reject; BEAM `guest_args_carry_secrets?` → `:guest_secrets_forbidden`; fail tests both hosts (JS `git_connections.test.ts`, BEAM `guest body with fake token field rejected before dial`) — never splice from guest JSON |
| D8 | Auth kinds parity catalog e2e | **DONE** | BEAM `SmartHttp.auth_headers` none/bearer/header/basic (+ string keys); connection catalog bearer e2e orch+Vm; JS `spliceCredentialHeaders` none/bearer/header/query; catalog connection auth kinds unit + orch fixture path |
| D9 | clone.apply sets remote + tracking for usable pull | **DONE** | Orch post-clone: `remote add origin` + `branch.<name>.remote`/`.merge` + `refs/remotes/origin/*`; resolve fills `url` from `remote.<name>.url` (or remote list) so pull/fetch with `remote:origin` or empty args works. Engine `config get` uses `get_string_buf` (live config). JS `git_remote.test` D9; BEAM `D9 clone sets remote…` in `git_orchestrator_test.exs` |
| D10 | Push approval from connection policy both hosts | **DONE** | JS `evaluatePushPolicy` + orch block/require_approval; BEAM `Connections.evaluate_push_policy` + `policies` on attach_git; tests `push policy block fails before dial`, `require_approval fails closed`, JS `git_push.test.ts` / `git_connections.test.ts` |

### P2 — PR13 packs

| ID | Requirement | Status | Evidence / missing |
|----|-------------|--------|-------------------|
| D11 | Stream download → chunked import_pack | **DONE** | BEAM stream→file+chunked import_pack (smart_http.ex, orchestrator.ex); JS stream fetchPacks+importPackStream (smart-http.ts, pack-cache.ts); 64MiB fail-closed tests |
| D12 | Disk CA pack cache JS + BEAM | **DONE** | BEAM PackCache disk {:disk,dir}/AGENTOS_GIT_PACK_CACHE; JS DiskPackCache via MC_GIT_PACK_CACHE in defaultProcessPackCache; credential-free keys; second-clone tests |
| D13 | Usable monorepo materialization (not filter-only) | **DONE** | M7 v1 = shallow `depth=1` + cone sparse (not filter/promisor). JS: `gitSparseCone`/`GitEngine.sparseCone` → orch `applySparseCone` post-`clone.apply` (`sparse-set`+checkout); gitfs cone + engine worktree prune. BEAM: orch `:sparse_cone` post-clone; `attach_git(sparse_cone:)` per-mount → `git_host_opts_for_mount` (D20). Engine `op_sparse_set` prunes out-of-cone worktree (libgit2 checkout alone leaves paths). Docs: `docs/git.md` Monorepo materialization (M7 v1 / D13). Tests: JS `git_remote.test` D13 multi-path pack→clone+sparse (depth=1, MEMFS+gitfs hide `other/`); BEAM `git_engine_pack_test` D13 monorepo multi-path clone+sparse; D20 sparse-checkout + attach e2e |
| D14 | Push haves dual-host production-ready | **DONE** | C `pack.build`/`ge_pack_build` haves (`engine.c`); JS `bridge.packBuild`+orch lease oldHash; BEAM `GitEngine.pack_build/3` haves; tests `abi_fixture_test`, `git_push_test`, orch R48 |
| D15 | Stream stdout beyond out/last | **OPEN** | truncated + out/last only |

### P3 — Durability / snapshot

| ID | Requirement | Status | Evidence / missing |
|----|-------------|--------|-------------------|
| D16 | OPFS/disk reattachable engine store | **OPEN** | AGIT checkpoint rebind only |
| D17 | Snapshot/fork rebinds git durable | **OPEN** | Not wired to snapshot lifecycle |
| D18 | Server durable engine root for named VMs | **OPEN** | Temp roots + cleanup |
| D19 | Snapshot blocked while git host_call inflight | **DONE** | Monorepo host_call pattern: kernel `HostCall::start` → `egress_inc` (`host_call.rs`); JS `MapHostCall` holds slot while orch HTTP+apply (`host_call.ts` + `gitHostCallHandler`); host `ensureSnapshotReady` / `mc_inflight_egress` refuse (`host.ts`, wasmtime `ensure_snapshot_ready`). BEAM second gate: `Vm.ensure_git_remote_quiescent/1` blocks `snapshot`+`commit_layer` while `git_tasks`/`git_remote_queue` non-empty (`server/lib/agent_os/vm.ex`). Tests: JS `git_guest_e2e` phase D19 (slow listRefs → snapshot throws mid-clone); BEAM `D19 snapshot refused while git remote host_call Task is inflight` in `git_orchestrator_test.exs` |

### P4 — Sparse / multi-repo

| ID | Requirement | Status | Evidence / missing |
|----|-------------|--------|-------------------|
| D20 | Sparse cone on BEAM attach = JS | **DONE** | BEAM `attach_git(:sparse_cone/:git_sparse_cone)` stores prefixes per mount; `git_host_opts_for_mount` → orch; post-`clone.apply` Port `sparse-set` (+ checkout) in `orchestrator.ex` (JS `applySparseCone` parity). Gitfs = post-sparse worktree projection. Tests: `git_engine_pack_test` sparse-checkout content; `git_orchestrator_test` `D20 attach_git sparse_cone → host_call clone applies Port sparse-set` |
| D21 | Multi-mount e2e two clones + docs | **DONE** | Product demux + dual clone: JS `git_remote_test` two engines via `gitHostCallHandler`/`args.mount` + real `minimal.pack` worktree isolation + concurrent two-mount clones; BEAM `R65/D21 host_call args.mount two clones into two engines` + `D21 concurrent remotes on two mounts may overlap` (attach_git ×2, separate roots, README hello each, unknown mount no dial). Docs: `docs/git.md` multi-mount section (setup, demux table, concurrency, proof). OTP26 JSON fallback for Bazel orch decode. |
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
| 2026-08-01 | Chunk 1: PR11 server connections catalog — D1/D6/D7/D8/D10 **DONE** (path evidence); product path `connections:` only |
| 2026-07-31 | Chunk 0: replace residual R* soft statuses with D1–D41 OPEN/DONE inventory |
