# feature/cgit — TASKS

## Residuals (wanted unfinished work — primary backlog)

> Source of truth for open product work. Non-goals are listed only as exclusions below.

**Only product-wanted unfinished work.**  
Does **not** include non-goals (full git-core porcelain parity, wasmi guest VCS, gojs/Go NIF, ambient `~/.git-credentials`, freestanding wasmtime engine, interactive rebase/bisect/LFS/`git gui`/guest `receive-pack` as a service).

Status of tree: after Waves 1–3 (`03bfa22`…`62179fa`). Scaffold + remotes-GA blockers largely closed; **this list is the remaining product backlog**.

Legend: **gap** = missing or stub · **thin** = exists but incomplete · **e2e** = needs real integration proof · **doc** = code/docs drift

---

## 1. End-to-end product acceptance

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R1 | **Guest CAP_NET e2e (JS)** | Prove thin `/bin/git` → kernel CAP_NET → `host_call "git"` → TS orch → worktree | Unit orch + CLI build only; no booted-guest remotes e2e |
| R2 | **Guest CAP_NET e2e (server)** | Same path on BEAM: guest → CAP_NET → Vm demux → BEAM orch → Port apply | Async Vm demux unit + fixture transport; no full guest image path |
| R3 | **CAP_NET deny e2e** | Guest without CAP_NET gets EPERM on remotes | Design requirement; not automated e2e |
| R4 | **Live public HTTPS e2e** (JS + BEAM) | Fixture packs ≠ real smart-HTTP | Fixture `minimal.pack` / FixtureSmartHttp only |
| R5 | **Kill Port → guest EIO e2e** | PR7a acceptance: engine crash fails handles closed | **Partial closed** — Port.close → `:eio` on Run; engine `Process.exit` → Vm detach. Full guest-image EIO e2e still open |
| R6 | **gitfs mount + ctl e2e (server)** | Port type-4 mount write → ctl Response on booted VM | Port smoke + attach_git; full guest mount/ctl drain e2e thin |
| R7 | **Ctl drain / `client_token` race e2e** | Close-then-status invariant under MountFs drain | Documented; thin CLI issues open/read; no race acceptance test with tokens |
| R8 | **JS close-then-status mount e2e** | Coherence under real `mc.create` + gitfs | Driver unit tests; full mc e2e sparse |
| R9 | **Remotes GA / graduate `experimentalGitEngine`** | Product flag exit criteria in `docs/git.md` | Criteria checklist status notes updated; **still experimental** — CAP_NET guest e2e (R1) blocks graduation; remotes not GA |

---

## 2. Local porcelain (engine + thin CLI)

Designed **phase A** surface (GIT.md §3.2 / §11). Engine has more ops than the thin CLI exposes.

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R10 | **Thin CLI: `rm`** | Phase A guest muscle memory | Engine `rm` exists; CLI does not |
| R11 | **Thin CLI: `diff`** | Phase A | Engine `diff` exists; CLI does not |
| R12 | **Thin CLI: `show`** | Phase A | Engine `show` exists; CLI does not |
| R13 | **Thin CLI: `reset` (soft/mixed/hard)** | Phase A | Engine `reset` exists; CLI does not |
| R14 | **Thin CLI: `tag`** | Phase A | Engine `tag` exists; CLI does not |
| R15 | **Thin CLI: `config` (limited keys)** | Phase A | Engine `config` exists; CLI does not |
| R16 | **Thin CLI: `remote` (list/add/remove URL)** | Phase A config until remotes | Engine `remote` exists; CLI does not |
| R17 | **Thin CLI: `switch`** | Phase A alias of checkout | Engine maps `switch`; CLI only documents `checkout` |
| R18 | **Thin CLI: `add -A` / pathspecs** | Real agent workflows | CLI `add <path>` only; engine has `all:true` walk |
| R19 | **Full patch `diff`** | Agents need real patches, not status-style only | **Closed (engine):** `git_diff` + `GIT_DIFF_FORMAT_PATCH`; optional `args.path` filter; large stdout via R25 |
| R20 | **Status porcelain-v1 completeness** | Machine-parseable agent tools | **Closed (subset):** default + `short` emit porcelain-v1 `XY path` / rename `old -> new` (A/M/D/R/T/??/!!/UU) via libgit2 flags; not every git-core porcelain edge |
| R21 | **`log` / `show` bounds + formatting** | Usable history without OOM | Bounded; polish truncation/format still product debt |
| R22 | **Branch delete via thin CLI** | Phase A branch ops | Engine `branch` delete path; CLI create/list only |
| R23 | **Synthetic `.git` coherence** | HEAD/refs/generation stay truthful after checkout/branch | **Partial closed:** Port + JS gitfs HEAD from engine symbolic-ref / branch / rev-parse (not hard-coded master after checkout); refs/generation ok; remote-apply edge residual |
| R24 | **JSON args 1 MiB product limit** | GIT.md hard product default | **Closed (engine):** `GE_REQUEST_MAX_BYTES` 1 MiB fail-closed in `ge_run_json`; write content still separate 16 MiB cap |
| R25 | **`result.truncated` + large stdout path** | GIT.md §5.3: preview + `/.git/mc/out/last` (8 MiB) | **Closed (engine):** `ge_resp_ok_stdout` on status/log/diff/show; never silent truncate |
| R26 | **Streaming / host_call large stdout** | When out/last is insufficient | “Later” in design; still wanted for big logs/diffs (**open**) |

---

## 3. Identity, policy, host integration

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R27 | **Host identity inject (K28 complete)** | Commits use host policy identity, not guest ambient gitconfig | **Closed** — `GitEngine.run` / BEAM `GitEngine` inject when `gitIdentity` / `:identity` configured; never invents Agent@example.com |
| R28 | **JS create-options identity** | `mc.create({ gitAuthor… })` or policy hook | **Closed** — `CreateOptions.gitIdentity` → engine load + registerGitHostCall |
| R29 | **Server attach identity** | Port/orch commits from host policy | **Closed** — `attach_git` / `GitEngine.start` `:identity` / `:git_identity` |
| R30 | **Connection catalog on server remotes (full PR11)** | Same connection-ref + credential splice as JS | Host-owned `allowed_origins` / `:auth` on attach; **not** full VM connection catalog → orch splice like tools |
| R31 | **Push approval hook (server)** | PR11 `require_approval` for push | **Closed** — orch `:require_approval` + `:on_push_approval` / `:push_approval`; default reject; attach_git forwards opts |
| R32 | **Bare-URL remotes policy (JS)** | Unbound URL + empty allowOrigins still dials if CAP_NET | **Closed** — bare URL + empty `allowOrigins` fails closed; connection-bound uses `connection.origins`; fixtures pass explicit allowOrigins |
| R33 | **Redacted orch metrics/logs** | No tokens in logs; origin/status/bytes | Design §observability; not productized counters |

---

## 4. Remotes — clone / fetch / pull

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R34 | **`pull` = fetch + local FF only** | GIT.md: FF fail → `git: not fast-forward` | **Closed** — pull = fetch + `reset` mode `ff-only`; non-FF → `git: not fast-forward` (JS + BEAM) |
| R35 | **Shallow clone defaults productized** | Agents shouldn’t pull full history by accident | **Closed** — product default `depth=1`; `depth<=0` means full history |
| R36 | **Partial clone (filter)** | M7 / large monorepos | Not implemented |
| R37 | **Multi-want fetch / multi-ref import** | Real remotes advertise many refs | **Closed** — multi-want of all `refs/heads/*` + single `refs.import` `args.refs` array (R94) with per-ref loop fallback (JS + BEAM) |
| R38 | **Tracking-branch config on clone** | Usable `fetch`/`pull` after clone | Remote-tracking updates exist in fetch.apply; branch.* config completeness thin |
| R39 | **Orch golden: fetch / pull / deny-depth** | Dual-host algorithm proof beyond clone | **Partial closed** — executable `fetch_success_steps`, `pull_ff_steps`, `push_readonly` (+ existing clone/empty/origin); deny-depth still open |
| R40 | **BEAM DiskPackCache (or shared CA cache)** | Server-side pack dedup across VMs | **Partial closed** — BEAM `AgentOS.Git.PackCache` (Agent, CA + download-key; never auth) + orch wire + second-clone transport counter test; disk/shared-across-nodes residual |
| R41 | **Chunked pack download streaming** | 64 MiB cap without full body buffer | Cap exists; download response still buffered; **push_packs** documents single-buffer body + 64 MiB max (R41 note) |
| R42 | **HTTP redirect / SSRF hardening review** | Multi-tenant server | Origin/scheme/userinfo/size/status gates landed; redirect policy may still need hardening pass |
| R43 | **Auth kinds parity (BEAM vs JS)** | bearer/header/basic as connections allow | **Partial closed** — BEAM `auth_headers/1`: bearer + header + basic (user/pass Base64); unit test no network; full connection-catalog e2e residual |

---

## 5. Remotes — push

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R44 | **Server (BEAM) push** | Same remote write path as JS for remote VMs | **Done** — orch push path (prepare → lease → pack → receive-pack → complete); `read_only` still rejects |
| R45 | **BEAM packbuilder** | Build pack for receive-pack without Node | **Done** — `GitEngine.pack_build/2` via Port `pack.build` + `.git/agentos/push.pack` |
| R46 | **BEAM receive-pack smart-HTTP** | Actual push to remotes | **Done** — `SmartHttp.push_packs/4` + report-status parse; fixture records args |
| R47 | **`push.complete` remote-tracking polish** | After successful push | **Done** — orch calls `push.complete` after receive-pack |
| R48 | **JS thin-pack / have negotiation** | Smaller pushes | Full reachable history from tips via packbuilder |
| R49 | **JS push against live receive-pack e2e** | Prove non-fixture push | Fixture + engine packbuilder tests |
| R50 | **Lease rejection paths** | Non-FF remote rejected cleanly | **Done** (server) — list-refs lease + report-status `ng`/`unpack` mapping; live GitHub not required |
| R51 | **Delete-ref push** | Zero newHash commands | Empty pack allowed for delete-only; live e2e residual |

---

## 6. Durability & browser object store

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R52 | **OPFS durable rebind (browser)** | Refresh keeps repo history (rollout phase 6) | **Done (engine path):** `OpfsDurable` stores AGIT pack+refs; `GitEngine.load` rebinds via importPack/refs.import/clone.apply (same path as Memory/Disk). Browser refresh e2e still product residual. |
| R53 | **Disk durable rebind (Node/server-side host)** | Process restart keeps engine state | **Done (engine path):** `DiskDurable` + same AGIT rebind as R52/R54. |
| R54 | **Engine load from durable snapshot** | Open → restore objects/refs/worktree | **Done:** AGIT envelope → pack import + refs + HEAD checkout; legacy non-AGIT attach only. |
| R55 | **Checkpoint = serialize real repo** | Not caller-supplied opaque bytes only | **Done:** default `checkpoint()` / `close` export pack of local tips + refs JSON + HEAD (`AGIT` magic). Explicit bytes override still allowed. |
| R56 | **OPFS/IndexedDB pack ODB** | Content-addressed packs as real object DB (M7) | **Partial:** durable rebind uses pack+refs (ODB-correct snapshot), not a live pack ODB backend for libgit2; pack *cache* helpers remain separate. |
| R57 | **Snapshot / fork reattach of git engine** | Vm snapshot keeps git history coherent | Not first-class |
| R58 | **Server Port worktree durability across VM recycle** | Named remote VMs | Temp roots cleaned; durable server path open |

---

## 7. Sparse / monorepo materialization

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R59 | **Full sparse-checkout pattern language** | Beyond cone prefixes | **Partial closed:** multi-pattern (newline / JSON array) + basic `!path` negation written safely; still **not** full git sparse language (doc’d) |
| R60 | **Partial tree materialization without full history** | Phase B monorepos | Sparse + shallow pieces; not full partial-clone stack |
| R61 | **Sparse on server attach** | Remote VMs with large repos | JS `gitSparseCone`; BEAM attach sparse not equivalent |
| R62 | **LLB `dest` vs sparse cone clarity + tests** | Avoid confusing archive prefix with sparse | Comment only; more product tests wanted |

---

## 8. Multi-repo / multi-mount

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R63 | **Multiple gitfs mounts per VM** | Agents with several checkouts | Designed single-mount; multi-mount wanted for scale |
| R64 | **Multi-Port / multi-engine demux** | One Port per mount or shared demux | Single engine per Vm attach |
| R65 | **`args.mount` on remote host_calls** | Route remotes to the right repo | Not implemented |
| R66 | **Hard fail on second gitfs mount** | Enforce until multi-mount ships (or after policy) | **Closed** — JS `isGitFsDriver` brand + EmbeddedBackend second mount error; BEAM `attach_git` → `{:error, :git_already_attached}` (no second Port) |
| R67 | **Single-writer queue depth metrics / alerts** | N=32 warning in design | Queue exists on BEAM remotes; metrics/alerts not productized |

---

## 9. Submodules (host-mediated)

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R68 | **`submodule` host-mediated network** | Real multi-repo agent workflows | Explicit later in GIT.md phase C; **not built** |
| R69 | **Submodule apply / worktree projection** | Guest sees submodule paths without dialing | Not built |

---

## 10. LLB / solve convergence

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R70 | **LLB always shares interactive object access** | One substrate, not two stacks | Engine-first materialize; deeper cache identity convergence residual |
| R71 | **CI requires engine for git LLB (no silent system)** | Keep `MC_GIT_USE_SYSTEM` emergency-only | Fail-closed unit test; broader CI matrix residual |
| R72 | **Remove or tightly gate system-git escape in product CI** | Avoid drift | Escape still exists by design; product CI policy residual |
| R73 | **LLB pack cache on disk in CI/solve workers** | Dedup across builds | `MC_GIT_PACK_CACHE` / process memory defaults |
| R74 | **Recorded solve / remote build git path e2e** | Recording + remote builder | Not fully proven for engine git |

---

## 11. Server load path & packaging

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R75 | **c-shared in-process load (PR7d) decision + ship** | Lower latency than Port if wanted | `.so` artifact may exist; **product load is Port only** |
| R76 | **L4: NOTICE adjacent to every ship artifact** | License checklist | L5 analysis gate on filegroup; release tarball placement residual |
| R77 | **Corresponding-source packaging in releases** | Linking exception | Target exists; release pipeline residual |
| R78 | **Default guest image includes `/bin/git` layer** | Agents get CLI without custom image | **Closed for loom+:** `git_layer` on loom (and atlas/paper/svc-test descendants); not on bare base/minimal/posix |
| R79 | **Hermetic engine binary discovery on server deploy** | `AGENTOS_GIT_ENGINE` not tribal knowledge | Env/default path residual for prod |
| R80 | **Wasm size headroom monitoring** | Stay ≤2 MiB under feature growth | size_limit green (~0.6 MiB); ongoing |

---

## 12. Dual-host conformance (K20)

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R81 | **Expand executable goldens** | fetch, pull FF fail, push RO (server), push success (JS), shallow, auth deny | **Partial closed** — 6 executable goldens (clone ok/empty/origin + fetch success + pull FF up-to-date + push RO); shallow/auth-deny/push-success residual |
| R82 | **Byte-identical / schema-identical Response fields** | Agents see same codes/stderr prefixes | Goldens assert substrings; full schema matrix residual |
| R83 | **Native ↔ emcc dual-runner for apply ops** | ABI drift risk | abi_dual / separate runners; strengthen |
| R84 | **Shared stderr prefix catalog as tests** | Stable agent parsing | Informal strings |

---

## 13. Observability, metrics, product polish (PR16)

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R85 | **Engine metrics** | op, duration, code, sizes (no packs/tokens) | **Basic closed** — in-process counters (clone/fetch/push ok/error); no duration/sizes yet |
| R86 | **Orch metrics** | origin, status, bytes, depth; redacted | **Basic closed** — `AgentOS.Git.Metrics` + JS `snapshotGitCounters`; origin/bytes residual |
| R87 | **Mount queue depth / latency metrics** | Single-writer bottlenecks | Not productized |
| R88 | **Port restart / RPC error counters** | Ops | **Basic closed** — `port_eio` + `rpc_error` counters on BEAM |
| R89 | **Server alerts** | allowlist denials, OOM, pack timeout, queue depth | Design only |
| R90 | **Graduate experimental flag** | After R1–R9 + policy criteria | Criteria doc only |
| R91 | **Single design-of-record sync** | Workspace-root `GIT.md` vs worktree | Worktree updated; root may lag |
| R92 | **Skills / agent docs beyond `docs/git.md`** | AgentOS agent skill pack if product wants | Product page exists; skills residual |

---

## 14. Engine / substrate quality still wanted

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R93 | **Replace residual jmin crude JSON** | Nested args, arrays, robust decode | **Partial closed:** array walk + object-scoped string get + 1 MiB request cap; full JSON library still out of scope |
| R94 | **`refs.import` multi-ref array** | One apply for full advertisement | **Closed:** engine `args.refs` + TS/BEAM orch single bulk import with loop fallback |
| R95 | **Packbuilder tip cap / multi-ref push sets** | >256 tips | Cap fails closed |
| R96 | **`add all` deletions / index sync** | Removed files staged correctly | **Closed:** `all:true` stages index removals for missing worktree paths |
| R97 | **Symlink / special file policy** | Safe worktrees | Mostly skipped/ignored |
| R98 | **Port mount path safety parity tests** | Same segment rules as engine | `ge_safe_relpath` used; more e2e |
| R99 | **Concurrent JS remotes single-flight** | Match BEAM one-remote queue | Bridge serializes engine; orch HTTP may still overlap — product policy residual |
| R100 | **host_call_close cancel for git remotes** | Guest cancel inflight clone | **Closed** — Vm answers `host_call_close` for name `"git"`: kill Task / drop queue (sidecar mirror) |
| R101 | **Synthetic `.git/objects` listing lies** | gitfs may list empty `objects` dir class | Confirm product honesty (no façade content) |

---

## 15. Optional / lower priority but still wanted by design

| # | Residual | Notes |
|---|----------|-------|
| R102 | **Catalog tool Face B (`git run`)** | Optional tools-catalog face; host_call remains required |
| R103 | **Composite Rust intercept for `/repo` + `git`** | Design alternative; only if product needs kernel-side intercept |
| R104 | **`.git/objects` guest façade** | Explicitly not current surface; only if product later needs on-disk-git tools inside guest |
| R105 | **Cap bits on mount for remotes** | Design says not required; only if policy wants mount-scoped net |

---

## Suggested sequencing (wanted only)

1. **Acceptance:** R1–R9 (guest CAP_NET e2e both hosts, live HTTPS optional gate, Port EIO, graduate criteria).  
2. **Agent daily driver:** R10–R27 (CLI phase A, patch diff, host identity inject).  
3. **Remotes complete:** R34–R51 (pull FF, multi-ref, server push stack, thin-pack).  
4. **Durability:** R52–R58.  
5. **Scale:** R59–R69 (sparse depth, multi-mount, submodules).  
6. **LLB/ops:** R70–R90.

---

## Explicitly not on this list

- Full git-core / every porcelain command  
- wasmi multi‑MiB in-guest VCS  
- gojs / Go NIF / product go-git  
- Ambient host git credentials  
- Freestanding zig/wasmtime engine as product path  
- Interactive rebase, bisect, LFS, `git gui`, guest-side `receive-pack` server  

---

*Generated from GIT.md, docs/git.md, CRITICAL_REVIEW findings, and post-Wave-3 code. Update as residuals close; do not mark non-goals here.*


---

## Closed scaffold work (Waves 1–3) — not residual

Remotes-GA blockers and honesty scaffolding landed in:

| Commit | Scope |
|--------|-------|
| `03bfa22` | P0 hardening + CRITICAL_REVIEW |
| `c7c04fd` | Wave 2 product honesty |
| `62179fa` | Wave 3 packbuilder, cache/sparse, goldens, BEAM queue |

Archival pre-fix findings: [`CRITICAL_REVIEW.md`](./CRITICAL_REVIEW.md) (baseline `020cc8b`; do not shrink).

### P0–P3 checklist (closed)

All P0.1–P0.9, P1.1–P1.8, P2.1–P2.8, P3.1–P3.4 marked done as **scaffold honesty** — see residual list above for remaining product completeness (especially partials: durable rebind, server push, guest CAP_NET e2e, CLI phase A, experimental graduation).

### Non-goals (excluded from residuals)

Full git-core porcelain parity · wasmi guest VCS · gojs/Go NIF · ambient `~/.git-credentials` · freestanding wasmtime engine · interactive rebase/bisect/LFS/`git gui` · guest-side receive-pack service.

---

## Changelog

| Date | Change |
|------|--------|
| 2026-07-31 | R40 BEAM PackCache + orch wire; R37/R94 orch multi-ref array; R43 basic/bearer/header unit; R41 push_packs buffer note |
| 2026-07-31 | Residuals R1–R105 promoted to top of TASKS.md; RESIDUALS.md removed |
| 2026-07-31 | Waves 1–3 land P0–P3 scaffold; residual backlog remains |
