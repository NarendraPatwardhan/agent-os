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
| 4 | Partial clone + sparse parity + tracking | **DONE** (`662dadd`, VERIFY_CHUNK_4.md) |
| 5 | Durability + snapshot rebind | **DONE** (VERIFY_CHUNK_5.md) |
| 6 | Submodules host-mediated | **DONE** (VERIFY_CHUNK_6.md) |
| 7 | Streaming stdout + engine polish | **DONE** (VERIFY_CHUNK_7.md) |
| 8 | Acceptance e2e matrix | **DONE** (D25–D33; VERIFY_CHUNK_8 + Chunk 10 goldens) |
| 9 | Metrics + packaging + GA | **DONE** (D34–D38, D40–D41; D34 advanced graduation in Chunk 10) |
| 10 | Full golden set + schema catalog + graduate | **DONE** (D32–D34; VERIFY_CHUNK_10.md) |

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
| D5 | Tracker matches code | **DONE** | Tracker rewritten D1–D41; VERIFY_CHUNK_0–9 |

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
| D15 | Stream stdout beyond out/last | **DONE** | stream_path + out/last + readStdoutStream; abi+JS tests |

### P3 — Durability / snapshot

| ID | Requirement | Status | Evidence / missing |
|----|-------------|--------|-------------------|
| D16 | OPFS/disk reattachable engine store | **DONE** | Primary = re-openable libgit2 directory. JS: `HostDirDurable`/`OpfsDirDurable` + hydrate→`ge_open`/`checkpoint` (`durable.ts`, `bridge.ts`, `engine.ts`); `GitEngine.load({ durableDir })`; AGIT transfer optional. BEAM: Port `root:`/`durable_dir`/`durable_id` + `GitEngine.root/1` + `checkpoint/1`. Proof: JS `git_engine.test` D16; BEAM `git_engine_test` D16; D17 e2e HostDir. Docs: `docs/git.md` Durability. |
| D17 | Snapshot/fork rebinds git durable | **DONE** | JS: `CreateOptions.gitDurable` (`types.ts`); `makeEmbedded` per-mount `openDurable` + `bindGitEngines` (`memcontainer.ts`); `EmbeddedBackend.snapshot`/`pinBase` → `checkpointGitEngines` before MCSN (`embedded.ts`); `durableIdForMount` + process MemoryDurable registry (`durable.ts`). gitfs K28 identity inject for ctl commits (`gitfs.ts`). MCSN does not carry ODB. Proof: `git_guest_e2e` phase D17 — commit → snapshot → restore HEAD+worktree; fork rebind (process-memory AGIT by id). Docs: `docs/git.md` D17. BEAM: re-`attach_git` with durable non-temp `:root` (ODB on disk; named-VM default = D18). |
| D18 | Server durable engine root for named VMs | **DONE** | `AgentOS.Git.Durable` — `AGENTOS_GIT_DURABLE_ROOT` / app `:git_durable_root`; layout `{base}/{safe_vm_id}/{mount_slug}/`; `resolve_root/1` for `:root`/`:durable_dir`/`:durable_id`. `GitEngine.start` + `Vm.attach_git(durable_id: \| durable_dir:)` never rm_rf durable roots. Proof: `git_engine_test` named root under env survives stop. Docs: `docs/git.md` Durability. |
| D19 | Snapshot blocked while git host_call inflight | **DONE** | Monorepo host_call pattern: kernel `HostCall::start` → `egress_inc` (`host_call.rs`); JS `MapHostCall` holds slot while orch HTTP+apply (`host_call.ts` + `gitHostCallHandler`); host `ensureSnapshotReady` / `mc_inflight_egress` refuse (`host.ts`, wasmtime `ensure_snapshot_ready`). BEAM second gate: `Vm.ensure_git_remote_quiescent/1` blocks `snapshot`+`commit_layer` while `git_tasks`/`git_remote_queue` non-empty (`server/lib/agent_os/vm.ex`). Tests: JS `git_guest_e2e` phase D19 (slow listRefs → snapshot throws mid-clone); BEAM `D19 snapshot refused while git remote host_call Task is inflight` in `git_orchestrator_test.exs` |

### P4 — Sparse / multi-repo

| ID | Requirement | Status | Evidence / missing |
|----|-------------|--------|-------------------|
| D20 | Sparse cone on BEAM attach = JS | **DONE** | BEAM `attach_git(:sparse_cone/:git_sparse_cone)` stores prefixes per mount; `git_host_opts_for_mount` → orch; post-`clone.apply` Port `sparse-set` (+ checkout) in `orchestrator.ex` (JS `applySparseCone` parity). Gitfs = post-sparse worktree projection. Tests: `git_engine_pack_test` sparse-checkout content; `git_orchestrator_test` `D20 attach_git sparse_cone → host_call clone applies Port sparse-set` |
| D21 | Multi-mount e2e two clones + docs | **DONE** | Product demux + dual clone: JS `git_remote_test` two engines via `gitHostCallHandler`/`args.mount` + real `minimal.pack` worktree isolation + concurrent two-mount clones; BEAM `R65/D21 host_call args.mount two clones into two engines` + `D21 concurrent remotes on two mounts may overlap` (attach_git ×2, separate roots, README hello each, unknown mount no dial). Docs: `docs/git.md` multi-mount section (setup, demux table, concurrency, proof). OTP26 JSON fallback for Bazel orch decode. |
| D22 | Symlink/special file policy | **DONE** | symlink fail-closed explicit; add-all skips |

### P5 — Submodules

| ID | Requirement | Status | Evidence / missing |
|----|-------------|--------|-------------------|
| D23 | Host-mediated submodule network clone/update | **DONE** | Orch `op:submodule` update (JS+BEAM): `.gitmodules` list → origin policy on URL → list-refs/fetch pack → nested engine clone at path. Engine `run(update)` still fail-closed (no dial). Fixture super + gitlink + `minimal.pack`. Tests: `git_remote.test.ts` D23–D24; `git_orchestrator_test.exs` D23/D24. List-only is **not** DONE. |
| D24 | Submodule worktree projection | **DONE** | Nested worktree under super root: JS same-MEMFS `bridge.openAt` + gitfs open/readdir `deps/lib/README`; BEAM nested Port → files on super FS (`deps/lib/README` = `hello\n`). |

### P6 — Acceptance / GA

| ID | Requirement | Status | Evidence / missing |
|----|-------------|--------|-------------------|
| D25 | Server guest CAP_NET e2e full path | **DONE** | git_guest_acceptance_test CAP_NET clone |
| D26 | Server CAP_NET deny e2e | **DONE** | git_guest_acceptance_test CAP_NET deny |
| D27 | Real HTTP clone e2e (git-http-backend or live) | **DONE** | git_real_http_test JS+BEAM git-http-backend clone |
| D28 | Real HTTP push e2e | **DONE** | git_real_http push receive-pack |
| D29 | Port kill → guest EIO booted guest | **DONE** | guest Port kill EIO acceptance |
| D30 | Server gitfs mount+ctl booted guest | **DONE** | guest type-4 ctl acceptance |
| D31 | client_token + generation race acceptance | **DONE** | client_token echo generation |
| D32 | Full golden set dual-host | **DONE** | `shallow_clone_steps` / `auth_deny_steps` / `pull_not_ff_steps` + prior; JS `git_orch_golden_test` + BEAM `OrchGoldenTest` |
| D33 | Dual-host Response schema + stderr catalog tests | **DONE** | `response_schema.json` + dual-host catalog samples (unknown connection, empty pack, origin deny) |
| D34 | Graduate experimentalGitEngine | **DONE** | api-surface → **advanced**; docs/git.md criteria all Met; flag name kept opt-in |

### P7 — Ops / polish

| ID | Requirement | Status | Evidence / missing |
|----|-------------|--------|-------------------|
| D35 | Full metrics (duration, bytes, redacted origin) | **DONE** | metrics duration pack_bytes origin_redacted |
| D36 | Server alerts | **DONE** | allowlist deny + queue depth>32 alerts |
| D37 | L4 NOTICE in release artifacts | **DONE** | L5 NOTICE ship gates |
| D38 | Prod git-engine discovery | **DONE** | GitEngine.discover_executable/0 |
| D39 | log/show polish | **DONE** | log bounds footer + show stream |
| D40 | Docs/skills + root GIT.md sync | **DONE** | docs/git.md metrics discovery graduation |
| D41 | Catalog Face B `git run` | **DONE** | GIT.md: catalog git run struck; host_call only |

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
| Server guest CAP_NET + gitfs acceptance (D25–D26, D29–D31) | `server/test/agent_os/git_guest_acceptance_test.exs`; Vm `drain_git_relay` on tick; `engine.c` client_token + init idempotent; `port_mount.c` root normalize; JS gitfs token echo |
| D17 snapshot/fork git durable rebind (JS) | `CreateOptions.gitDurable`, `memcontainer.ts` makeEmbedded, `embedded.ts` checkpoint, `git_guest_e2e` D17 |
| Submodule host-mediated update + projection (D23/D24); Port product load; LLB engine-first | orch submodule JS+BEAM; `op_gitlink`; docs/git.md; `llb-git.ts` |
| P0 remotes gates | `smart_http.ex` origin/size/status; type-1 dial refuse in `port_handle.c` |

---

## Changelog

| Date | Change |
|------|--------|
| 2026-08-01 | Chunk 8 acceptance: D25/D26/D29/D30/D31 server guest CAP_NET allow/deny, Port kill→EIO, gitfs mount+ctl, client_token+generation; Vm tick git auto-drain; port_mount root fix; init idempotent; `//server:mix_test` green |
| 2026-08-01 | Chunk 8: D27/D28 real HTTP smart-HTTP e2e (`git-http-backend` CGI) dual-host; D32 `push_success_steps` golden; product `report-status` on receive-pack |
| 2026-08-01 | Chunk 10: D32 full golden set (shallow/auth_deny/pull_not_ff); D33 response_schema catalog dual-host; D34 graduate experimental→**advanced** (CAP_NET D25/D26 Met; flag name kept) |
| 2026-08-01 | Chunk 9: D35–D38 metrics/alerts/NOTICE/discovery; D40 docs sync; D41 strike catalog `git run`; D34 deferred until D32/D33 (Chunk 10) |
| 2026-08-01 | Chunk 6: D23/D24 host-mediated submodule update + nested worktree projection (JS+BEAM orch; list-only is not DONE) |
| 2026-08-01 | Chunk 5 D16/D18: directory reopen primary — JS `durableDir`+HostDirDurable hydrate/dump; BEAM `Git.Durable` + `durable_id`/`durable_dir` attach; dual-host second-process tests; D16/D18 **DONE** (D17 already); AGIT remains transfer |
| 2026-08-01 | Chunk 4: monorepo sparse + tracking + multi-mount — D9/D13/D20/D21 **DONE** (`662dadd`, VERIFY_CHUNK_4.md PASS) |
| 2026-08-01 | Docs/coord after Chunk 5/6 agents: durable dir reopen (`HostDirDurable`/`OpfsDirDurable` + AGIT) + submodule host path (JS orch nested apply) in `docs/git.md` + `create-options.md`; D17 **DONE**; D16/D18/D23/D24 **OPEN** with path evidence; Chunk 5/6 rows **OPEN** (no VERIFY); soft status scrubbed; fixed `durable.ts` duplicate registry merge |
| 2026-08-01 | Chunk 1: PR11 server connections catalog — D1/D6/D7/D8/D10 **DONE** (path evidence); product path `connections:` only |
| 2026-07-31 | Chunk 0: replace residual R* soft statuses with D1–D41 OPEN/DONE inventory |
