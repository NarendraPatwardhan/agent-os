# VERIFY_CHUNK_0

Verdict: **PASS**

Re-audit of `TASKS.md` after prior FAIL fixes. Tree at `dfa3bd1`. Hostile read-only audit. No product code changed.

---

## Soft language / status vocabulary — **PASS**

| Check | Result |
|-------|--------|
| Campaign chunk Status column | All ten rows **OPEN** only (no IN PROGRESS / PENDING) |
| Inventory D1–D41 Status column | **OPEN** or **DONE** only (D14 = DONE; rest OPEN) |
| Banned soft words as status language | None (`foundation`, `honest residual`, `later`, `pending`, `in progress` absent as soft status) |

**Notes (not failures):**

- Line 8 quotes the ban list itself — not soft status language.
- Chunk 4 Focus text says **“Partial clone”** — git protocol feature name (filter/partial clone), status still **OPEN**. Not “work is partial.”
- Evidence columns use hard missing lists (`incomplete`, `not wired`, `not built`, `missing …`). Those adjectives are not on the ban list and do not substitute for OPEN/DONE.

Prior FAIL items (campaign `IN PROGRESS`/`PENDING`; D9 “Tracking updates partial”) are gone.

---

## Mandatory spot-checks

### Thin CLI phase A (baseline) — **CONFIRMED present**

Path: `memcontainers/programs/git/src/main.rs`

| Claimed | Proof |
|---------|--------|
| `rm` | `cmd == b"rm"` → `run_rm` |
| `diff` / `show` | `build_request` / `fmt_op_rev` |
| `reset` | `build_reset` (`--soft`/`--mixed`/`--hard`) |
| `tag` | `build_tag` incl. `-d` |
| `config` | `build_config` list/get/set |
| `remote` | `build_remote_cfg` list/add/remove |
| `switch` | `checkout`/`switch` → `fmt_op_name` |
| `add -A` | `run_add` → `{"op":"add","args":{"all":true}}` |
| `branch -d` | `build_branch` delete path |

Help string documents phase A. Baseline table cites this path. **Not a false DONE.**

### D1 OPEN — **CONFIRMED still OPEN**

Server remotes do **not** resolve connections catalog + splice for git.

| Path | Proof |
|------|--------|
| `server/lib/agent_os/vm.ex` `do_attach_git_new/3` | Stores `git_allowed_origins` / auth / transport from opts — no connection ref |
| `server/lib/agent_os/vm.ex` `git_allowed_origins_from_opts/1` | Parallel allowlist only |
| `server/lib/agent_os/git/smart_http.ex` / `orchestrator.ex` | Product remotes gated by `:allowed_origins` |
| Server git path | No `connection_ref` / `connectionRef` / catalog→remote resolve for attach_git remotes |

Boot-time host catalog (`inject_catalog` / net `:connections`) is a separate product surface; it does not wire BEAM git remotes through PR11 catalog refs. D1 evidence (“attach_git uses parallel `allowed_origins`/`auth` only”) is accurate. **Not a false OPEN.**

### D14 DONE — **CONFIRMED**

Push haves dual-host is production-wired with path + test proof.

| Path | Proof |
|------|--------|
| `memcontainers/lib/git-engine/src/engine.c` | `pack_collect_haves`, revwalk hide on haves (R48) |
| `memcontainers/lib/git-engine/abi_fixture_test.c` | `test_pack_build` R48 thin pack with haves |
| `server/lib/agent_os/git_engine.ex` | `pack_build/3` + `opts[:haves]` → `pack.build` JSON |
| `server/lib/agent_os/git/orchestrator.ex` | push: lease old_hash tips as haves → `GitEngine.pack_build(..., haves: haves)` |
| `memcontainers/sdk-js/core/src/git/bridge.ts` | `packBuild(oids, haves?)` |
| `memcontainers/sdk-js/core/src/git/engine.ts` | `buildPushPack` serializes haves |
| `memcontainers/sdk-js/core/test/git_push.test.ts` | R48 haves pack smaller than full |

TASKS D14 evidence column lists paths/symbols + tests (`engine.c`, `bridge.packBuild`, `GitEngine.pack_build/3`, `abi_fixture_test`, `git_push_test`, orch R48). **Not a false DONE.**

---

## Inventory OPEN sample (no false OPEN)

| ID | Spot-check | Holds OPEN? |
|----|------------|-------------|
| D2 | Engine serial ≠ remote HTTP FIFO | yes |
| D3 | Redirect re-check incomplete dual-host | yes |
| D4 | gitfs objects façade risk remains | yes |
| D5 | Tracker truth was FAIL until this PASS; row still OPEN until marked DONE post-V0 | yes (at audit start) |
| D6–D10 | No BEAM connection-ref remotes (see D1) | yes |
| D11–D13 | Whole-body buffer / incomplete disk CA / filter-only | yes |
| D15 | truncated + out/last only | yes |
| D16–D19 | Durability/snapshot gaps as stated | yes |
| D20–D22 | Sparse BEAM parity / multi-mount e2e / special files | yes |
| D23–D24 | Submodule list-only + fail-closed | yes |
| D25–D34 | Acceptance/e2e matrix incomplete as stated | yes |
| D35–D41 | Ops/docs/GA gaps as stated | yes |

---

## Baseline “already implemented” (no regression)

| Area | Result |
|------|--------|
| Thin CLI phase A | Present — see above |
| Patch diff; truncated+out/last; multi-ref import; add-all | Paths in baseline resolve under `git-engine` |
| Host identity; bare-URL fail-closed; pull FF; depth=1 | Orch + engine surfaces present |
| Server push + haves + delete-ref fixture | Orch + tests present |
| AGIT rebind; multi-mount demux; JS CAP_NET e2e | Baseline paths real |
| Submodule list-only; Port product load; LLB engine-first | As claimed |
| P0 remotes gates | `smart_http.ex` origin/size/status; type-1 refuse |

Baseline evidence uses **paths** (not SHA-only). Good form.

---

## False DONE / False OPEN

| Class | Result |
|-------|--------|
| False DONE | **None** — only inventory DONE is D14; code+tests match |
| False OPEN | **None proven** — D1 still missing catalog remotes; sample OPEN rows still real gaps |

---

## Prior FAIL remediation checklist

| Prior mandatory fix | Status |
|---------------------|--------|
| Campaign status OPEN/DONE only | **Fixed** |
| Purge banned soft status words (D9 `partial`, PENDING/IN PROGRESS) | **Fixed** |
| DONE path+proof (not SHA-only) | **Fixed** (D14 + baseline) |
| Thin CLI path in baseline | **Fixed** (`memcontainers/programs/git/src/main.rs`) |
| Keep D1 OPEN | **Held** |
| Keep D14 DONE | **Held** |

---

## Summary

| Check | Result |
|-------|--------|
| Status vocabulary OPEN/DONE only (incl. campaign) | **PASS** |
| Soft language ban | **PASS** |
| Thin CLI phase A exists | **PASS** |
| D1 OPEN (no server catalog remotes on attach_git) | **PASS** (correctly open) |
| D14 DONE (pack haves dual-host) | **PASS** (code + tests) |
| False DONE | none |
| False OPEN | none proven |
| Tracker clean for Chunk 0 | **PASS** |

**Chunk 0 passes.** Tracker truth is clean under the stated rules. Safe to mark campaign chunk 0 and D5 **DONE** (with path+proof pointing at this file / `TASKS.md` rewrite) and proceed to Chunk 1 work under OPEN inventory items (starting with D1/PR11 server connections).
