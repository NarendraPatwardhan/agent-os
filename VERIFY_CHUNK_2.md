# VERIFY_CHUNK_2

Verdict: **PASS**

Re-verify after K17 path-alias fix (`normalizeRel` segment collapse). Tree: `feature/cgit` @ `9699ea9` + dirty working tree (Chunk 2 sources modified, uncommitted). No product code changed by this verifier.

---

## Acceptance matrix

| # | Requirement | Result | Evidence |
|---|-------------|--------|----------|
| 1 | **D2** JS remote single-flight: concurrent remotes peak `fetchPacks` ≤ 1 | **PASS** | See A1 |
| 2 | **D3** Redirects fail closed both hosts (no open redirect SSRF) | **PASS** | See A2 |
| 3 | **D4** `.git/objects` not projected, including path aliases `/.git/./objects` and `/.git//objects` | **PASS** | See A3 |
| 4 | **D19** Snapshot refused while git remote host_call inflight JS + BEAM | **PASS** | See A4 |
| 5 | Tests green for the above | **PASS** | See A5 |

All required checks hold. Chunk 2 verdict is **PASS**.

---

## A1 — D2 JS remote single-flight — PASS

**Code still present**

| Path | Proof |
|------|--------|
| `/mnt/workspace/agent-os/agent-os-cgit/memcontainers/sdk-js/core/src/git/remote-orchestrator.ts` | `private remoteQueue: Promise<unknown>` (~L140–145); `handle()` chains `remoteQueue.then(handleUnlocked)` so only one remote (HTTP + apply) runs per orchestrator/engine |

**Test still present**

| Path | Proof |
|------|--------|
| `/mnt/workspace/agent-os/agent-os-cgit/memcontainers/sdk-js/core/test/git_remote.test.ts` ~L442–491 | Delayed `fetchPacks` + two concurrent clones; asserts `peakFetch ≤ 1` |

Executed: `//memcontainers/sdk-js/core:git_remote_test` **PASSED**.

---

## A2 — D3 redirects fail closed both hosts — PASS

**JS (code present)**

| Path | Proof |
|------|--------|
| `/mnt/workspace/agent-os/agent-os-cgit/memcontainers/sdk-js/core/src/git/smart-http.ts` | Module header D3 policy; product dial forces `redirect: "manual"`; 3xx / `opaqueredirect` → `redirect not allowed`; never reads `Location` |
| `/mnt/workspace/agent-os/agent-os-cgit/memcontainers/sdk-js/core/test/git_remote.test.ts` | Mock 302 → evil origin; listRefs/fetchPacks/pushPacks fail closed |

**BEAM (code present)**

| Path | Proof |
|------|--------|
| `/mnt/workspace/agent-os/agent-os-cgit/server/lib/agent_os/git/smart_http.ex` | `:httpc` `autoredirect: false`; 3xx → `:redirect_not_allowed` |
| `/mnt/workspace/agent-os/agent-os-cgit/server/test/agent_os/git_orchestrator_test.exs` | Unit + local-socket open-redirect cases |

Executed: `git_remote_test` **PASSED**. Redirect policy source unchanged and still fail-closed.

---

## A3 — D4 `.git/objects` not projected (canonical + aliases) — PASS

### Prior FAIL (closed)

Hostile V2 found JS projected host ODB via `/.git/./objects` and `/.git//objects` because `normalizeRel` only stripped leading `/` and rejected `..` without collapsing `.` / empty segments. `isObjectsPath` then missed the gate; MEMFS resolved aliases to real ODB.

### Fix (K17 path-alias)

| Path | Proof |
|------|--------|
| `/mnt/workspace/agent-os/agent-os-cgit/memcontainers/sdk-js/core/src/git/bridge.ts` ~L220–239 | `normalizeRel` collapses empty segments and `.`; rejects `..` with `EACCES`. Doc: `/.git/./objects` and `/.git//objects` → `.git/objects` |
| `/mnt/workspace/agent-os/agent-os-cgit/memcontainers/sdk-js/core/src/git/gitfs.ts` | `isObjectsPath` uses `normalizeRel`; open/stat/readdir throw ENOENT on objects prefix; readdir `/.git` lists only HEAD/mc/refs |

**Logic probe (normalizeRel + isObjectsPath mirror):**

| Guest path | normalizeRel | isObjectsPath |
|------------|--------------|---------------|
| `/.git/objects` | `.git/objects` | true |
| `/.git/./objects` | `.git/objects` | true |
| `/.git//objects` | `.git/objects` | true |
| `/.git/./objects/pack` | `.git/objects/pack` | true |
| `/.git//objects/pack` | `.git/objects/pack` | true |
| `foo/../.git/objects` | throws EACCES | (no fall-through) |

### Tests (canonical + aliases)

| Path | Proof |
|------|--------|
| `/mnt/workspace/agent-os/agent-os-cgit/memcontainers/sdk-js/core/test/git_engine.test.ts` ~L236–281 | readdir omits `objects`; stat/open ENOENT for `/.git/objects`, `/.git/objects/pack`, **`/.git/./objects`**, **`/.git//objects`**, **`/.git/./objects/pack`**; readdir ENOENT for alias object dirs |

### Port (still holds)

| Path | Proof |
|------|--------|
| `/mnt/workspace/agent-os/agent-os-cgit/memcontainers/lib/git-engine/src/port_mount.c` | `is_objects_path` → ENOENT; synthetic `.git` readdir omits objects |
| `/mnt/workspace/agent-os/agent-os-cgit/memcontainers/lib/git-engine/src/engine.c` `ge_safe_relpath` | Rejects empty segments, `.`, `..`, consecutive seps — aliases fail closed before ODB access |
| `/mnt/workspace/agent-os/agent-os-cgit/memcontainers/lib/git-engine/port_smoke_test.c` | stat/open `.git/objects` (+ pack) ENOENT; readdir must not list `objects` |

`//memcontainers/lib/git-engine:port_smoke_test` **PASSED**.  
`//memcontainers/sdk-js/core:git_engine_test` **PASSED** (includes alias cases).

**Requirement JS + Port, including non-canonical aliases. D4 PASS.**

---

## A4 — D19 snapshot refused while git remote host_call inflight — PASS

**JS (code still present)**

| Path | Proof |
|------|--------|
| `memcontainers/hosts/js/src/host.ts` ~L1395–1400 | `ensureSnapshotReady` throws when inflight egress > 0 |
| `remote-orchestrator.ts` ~L1057+ | D19 / host_call quiescence contract docs |
| `memcontainers/sdk-js/core/test/git_guest_e2e.test.ts` ~L379–476 | Slow `listRefs`; mid-clone `vm.snapshot()` must throw (`host-egress` / `in flight` / `quiesce`) |

**BEAM (code still present)**

| Path | Proof |
|------|--------|
| `server/lib/agent_os/vm.ex` ~L1681–1692 | `ensure_git_remote_quiescent/1` errors when `git_tasks` / `git_remote_queue` non-empty; used on snapshot/commit_layer |
| `server/test/agent_os/git_orchestrator_test.exs` ~L1078–1169 | D19 inflight snapshot + commit_layer refuse; ok after drain |

---

## A5 — Tests green — PASS

Command:

```text
bazel --output_user_root=/mnt/workspace/agent-os/bazel-cache test \
  //memcontainers/sdk-js/core:git_engine_test \
  //memcontainers/sdk-js/core:git_remote_test \
  //memcontainers/lib/git-engine:port_smoke_test \
  --test_output=errors --cache_test_results=no
```

Result: **3/3 PASSED** (executed, not cache-only).

| Target | Result |
|--------|--------|
| `//memcontainers/lib/git-engine:port_smoke_test` | PASSED |
| `//memcontainers/sdk-js/core:git_engine_test` | PASSED |
| `//memcontainers/sdk-js/core:git_remote_test` | PASSED |

---

## Verdict

**PASS**
