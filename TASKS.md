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
| R5 | **Kill Port → guest EIO e2e** | PR7a acceptance: engine crash fails handles closed | Lifecycle sketched; kill→EIO guest path not product e2e |
| R6 | **gitfs mount + ctl e2e (server)** | Port type-4 mount write → ctl Response on booted VM | Port smoke + attach_git; full guest mount/ctl drain e2e thin |
| R7 | **Ctl drain / `client_token` race e2e** | Close-then-status invariant under MountFs drain | Documented; thin CLI issues open/read; no race acceptance test with tokens |
| R8 | **JS close-then-status mount e2e** | Coherence under real `mc.create` + gitfs | Driver unit tests; full mc e2e sparse |
| R9 | **Remotes GA / graduate `experimentalGitEngine`** | Product flag exit criteria in `docs/git.md` | Criteria written; flag still experimental; remotes not GA |

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
| R19 | **Full patch `diff`** | Agents need real patches, not status-style only | `op_diff` is growable but still reduced / not full unified patch product |
| R20 | **Status porcelain-v1 completeness** | Machine-parseable agent tools | Simplified XY / short format; not full porcelain-v1 |
| R21 | **`log` / `show` bounds + formatting** | Usable history without OOM | Bounded; polish truncation/format still product debt |
| R22 | **Branch delete via thin CLI** | Phase A branch ops | Engine `branch` delete path; CLI create/list only |
| R23 | **Synthetic `.git` coherence** | HEAD/refs/generation stay truthful after checkout/branch | gitfs synthesizes HEAD/refs/ctl; edge cases after remote apply |
| R24 | **JSON args 1 MiB product limit** | GIT.md hard product default | Growable content for write; jmin still crude for nested structures |
| R25 | **`result.truncated` + large stdout path** | GIT.md §5.3: preview + `/.git/mc/out/last` (8 MiB) | Not implemented as product Response contract |
| R26 | **Streaming / host_call large stdout** | When out/last is insufficient | “Later” in design; still wanted for big logs/diffs |

---

## 3. Identity, policy, host integration

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R27 | **Host identity inject (K28 complete)** | Commits use host policy identity, not guest ambient gitconfig | Commit requires name+email args; **no** automatic inject from host/create options / BEAM attach |
| R28 | **JS create-options identity** | `mc.create({ gitAuthor… })` or policy hook | Not wired |
| R29 | **Server attach identity** | Port/orch commits from host policy | Not wired |
| R30 | **Connection catalog on server remotes (full PR11)** | Same connection-ref + credential splice as JS | Host-owned `allowed_origins` / `:auth` on attach; **not** full VM connection catalog → orch splice like tools |
| R31 | **Push approval hook (server)** | PR11 `require_approval` for push | JS has `onPushApproval`; server push rejected entirely |
| R32 | **Bare-URL remotes policy (JS)** | Unbound URL + empty allowOrigins still dials if CAP_NET | Connection-bound is fail-closed; bare URL path still weaker than connection-only product policy |
| R33 | **Redacted orch metrics/logs** | No tokens in logs; origin/status/bytes | Design §observability; not productized counters |

---

## 4. Remotes — clone / fetch / pull

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R34 | **`pull` = fetch + local FF only** | GIT.md: FF fail → `git: not fast-forward` | Pull aliases fetch; **no** local FF merge/checkout step |
| R35 | **Shallow clone defaults productized** | Agents shouldn’t pull full history by accident | `depth` supported in smart-HTTP; product default depth policy unclear / not forced |
| R36 | **Partial clone (filter)** | M7 / large monorepos | Not implemented |
| R37 | **Multi-want fetch / multi-ref import** | Real remotes advertise many refs | `refs.import` single name+hash; comment says full array later |
| R38 | **Tracking-branch config on clone** | Usable `fetch`/`pull` after clone | Remote-tracking updates exist in fetch.apply; branch.* config completeness thin |
| R39 | **Orch golden: fetch / pull / deny-depth** | Dual-host algorithm proof beyond clone | Goldens: clone success/empty/origin_denied only; `fetch_algorithm.json` / `clone_algorithm.json` may be prose-ish |
| R40 | **BEAM DiskPackCache (or shared CA cache)** | Server-side pack dedup across VMs | JS Memory/Disk + process default; BEAM no shared pack cache |
| R41 | **Chunked pack download streaming** | 64 MiB cap without full body buffer | Cap exists; streaming/chunked product path thin |
| R42 | **HTTP redirect / SSRF hardening review** | Multi-tenant server | Origin/scheme/userinfo/size/status gates landed; redirect policy may still need hardening pass |
| R43 | **Auth kinds parity (BEAM vs JS)** | bearer/header/basic as connections allow | Partial; full connection-auth matrix not proven e2e |

---

## 5. Remotes — push

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R44 | **Server (BEAM) push** | Same remote write path as JS for remote VMs | Stable reject: `git: push not supported on server (fetch/clone only)` |
| R45 | **BEAM packbuilder** | Build pack for receive-pack without Node | Missing; JS uses `ge_pack_build` |
| R46 | **BEAM receive-pack smart-HTTP** | Actual push to remotes | Missing |
| R47 | **`push.complete` remote-tracking polish** | After successful push | Engine op exists; server never reaches it |
| R48 | **JS thin-pack / have negotiation** | Smaller pushes | Full reachable history from tips via packbuilder |
| R49 | **JS push against live receive-pack e2e** | Prove non-fixture push | Fixture + engine packbuilder tests |
| R50 | **Lease rejection paths** | Non-FF remote rejected cleanly | Partial via list-refs lease; more status mapping wanted |
| R51 | **Delete-ref push** | Zero newHash commands | Empty pack allowed for delete-only; live e2e residual |

---

## 6. Durability & browser object store

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R52 | **OPFS durable rebind (browser)** | Refresh keeps repo history (rollout phase 6) | `OpfsDurable` API; **not** rebinding MEMFS/engine ODB |
| R53 | **Disk durable rebind (Node/server-side host)** | Process restart keeps engine state | `DiskDurable` API; same limitation |
| R54 | **Engine load from durable snapshot** | Open → restore objects/refs/worktree | Opaque blob attach only |
| R55 | **Checkpoint = serialize real repo** | Not caller-supplied opaque bytes only | `checkpoint` saves last opaque / explicit bytes |
| R56 | **OPFS/IndexedDB pack ODB** | Content-addressed packs as real object DB (M7) | Pack *cache* helpers; not ODB backend for libgit2 |
| R57 | **Snapshot / fork reattach of git engine** | Vm snapshot keeps git history coherent | Not first-class |
| R58 | **Server Port worktree durability across VM recycle** | Named remote VMs | Temp roots cleaned; durable server path open |

---

## 7. Sparse / monorepo materialization

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R59 | **Full sparse-checkout pattern language** | Beyond cone prefixes | Cone-only (`/*`, `!/*/`, path cones); documented limit |
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
| R66 | **Hard fail on second gitfs mount** | Enforce until multi-mount ships (or after policy) | Docs claim fail-closed; **enforcement not clearly implemented** |
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
| R78 | **Default guest image includes `/bin/git` layer** | Agents get CLI without custom image | Optional `git` program layer; not default image |
| R79 | **Hermetic engine binary discovery on server deploy** | `AGENTOS_GIT_ENGINE` not tribal knowledge | Env/default path residual for prod |
| R80 | **Wasm size headroom monitoring** | Stay ≤2 MiB under feature growth | size_limit green (~0.6 MiB); ongoing |

---

## 12. Dual-host conformance (K20)

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R81 | **Expand executable goldens** | fetch, pull FF fail, push RO (server), push success (JS), shallow, auth deny | 3 goldens (clone ok/empty/origin) |
| R82 | **Byte-identical / schema-identical Response fields** | Agents see same codes/stderr prefixes | Goldens assert substrings; full schema matrix residual |
| R83 | **Native ↔ emcc dual-runner for apply ops** | ABI drift risk | abi_dual / separate runners; strengthen |
| R84 | **Shared stderr prefix catalog as tests** | Stable agent parsing | Informal strings |

---

## 13. Observability, metrics, product polish (PR16)

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R85 | **Engine metrics** | op, duration, code, sizes (no packs/tokens) | Not productized |
| R86 | **Orch metrics** | origin, status, bytes, depth; redacted | Not productized |
| R87 | **Mount queue depth / latency metrics** | Single-writer bottlenecks | Not productized |
| R88 | **Port restart / RPC error counters** | Ops | Partial logs only |
| R89 | **Server alerts** | allowlist denials, OOM, pack timeout, queue depth | Design only |
| R90 | **Graduate experimental flag** | After R1–R9 + policy criteria | Criteria doc only |
| R91 | **Single design-of-record sync** | Workspace-root `GIT.md` vs worktree | Worktree updated; root may lag |
| R92 | **Skills / agent docs beyond `docs/git.md`** | AgentOS agent skill pack if product wants | Product page exists; skills residual |

---

## 14. Engine / substrate quality still wanted

| # | Residual | Why we want it | Current state |
|---|----------|----------------|---------------|
| R93 | **Replace residual jmin crude JSON** | Nested args, arrays, robust decode | Improved alloc paths; still “spike” min parser |
| R94 | **`refs.import` multi-ref array** | One apply for full advertisement | Single name+hash |
| R95 | **Packbuilder tip cap / multi-ref push sets** | >256 tips | Cap fails closed |
| R96 | **`add all` deletions / index sync** | Removed files staged correctly | Worktree-positive walk only |
| R97 | **Symlink / special file policy** | Safe worktrees | Mostly skipped/ignored |
| R98 | **Port mount path safety parity tests** | Same segment rules as engine | `ge_safe_relpath` used; more e2e |
| R99 | **Concurrent JS remotes single-flight** | Match BEAM one-remote queue | Bridge serializes engine; orch HTTP may still overlap — product policy residual |
| R100 | **host_call_close cancel for git remotes** | Guest cancel inflight clone | Residual (noted in async design) |
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
| 2026-07-31 | Residuals R1–R105 promoted to top of TASKS.md; RESIDUALS.md removed |
| 2026-07-31 | Waves 1–3 land P0–P3 scaffold; residual backlog remains |
