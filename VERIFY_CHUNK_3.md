# VERIFY_CHUNK_3

Verdict: **PASS**

Hostile verifier for feature/cgit Chunk 3 (D11 stream/chunked pack import + D12 disk pack cache). Tree: `feature/cgit` @ `7a062e9` + dirty working tree (Chunk 3 sources modified, uncommitted). No product code changed by this verifier.

---

## Acceptance matrix

| # | Requirement | Result | Evidence |
|---|-------------|--------|----------|
| 1 | **D11 BEAM**: stream download → chunked `import_pack` with size-cap fail-closed (code + tests) | **PASS** | See A1 |
| 2 | **D11 JS**: stream `fetchPacks` / chunked import (code + tests) | **PASS** | See A2 |
| 3 | **D12 BEAM** disk pack cache (env or `{:disk, dir}`) second clone no second transport | **PASS** | See A3 |
| 4 | **D12 JS** `DiskPackCache` when `MC_GIT_PACK_CACHE` set | **PASS** | See A4 |
| 5 | Credentials never in cache keys | **PASS** | See A5 |
| 6 | Tests run green | **PASS** | See A6 |

All six hold. Chunk 3 verdict is **PASS**.

---

## A1 — D11 BEAM stream download + chunked import + size cap — PASS

**Stream download (product SmartHttp)**

| Path | Proof |
|------|--------|
| `/mnt/workspace/agent-os/agent-os-cgit/server/lib/agent_os/git/smart_http.ex` | Product `fetch_packs/4` → `stream_request_to_file/5` with `:httpc` `stream: {:self, :once}`; running size gate in `stream_body_loop/6` aborts as `:body_too_large` mid-stream (no 64 MiB+1 BEAM buffer); returns `{:ok, {:file, path, pack_offset}}` after `locate_pack_offset/1` |
| Default cap | `@default_max_pack_bytes 64 * 1024 * 1024`; Content-Length pre-check + body accumulate |

**Chunked import_pack**

| Path | Proof |
|------|--------|
| `/mnt/workspace/agent-os/agent-os-cgit/server/lib/agent_os/git/orchestrator.ex` | `apply_pack/3` for binary → `do_import_chunks` (default 1 MiB); for `{:file, path, offset}` → `import_from_device` reading slices into `GitEngine.import_pack/3` with `final` on last |
| `/mnt/workspace/agent-os/agent-os-cgit/server/lib/agent_os/git_engine.ex` | Port frames: pack chunk + pack meta final |

**Engine size gate**

| Path | Proof |
|------|--------|
| `memcontainers/lib/git-engine/src/ge_engine_priv.h` | `GE_PACK_MAX_BYTES (64u * 1024u * 1024u)` |
| `memcontainers/lib/git-engine/src/engine.c` `ge_import_pack` | fail-closed before append when total exceeds cap |

**Tests**

| Path | Assertion |
|------|-----------|
| `server/test/agent_os/git_orchestrator_test.exs` L142–244 | product stream `fetch_packs` body over max → `:body_too_large` (no CL + CL paths) |
| same L246–302 | product stream returns `{:file, path, offset}` at PACK magic |
| `server/test/agent_os/git_engine_pack_test.exs` L150–197 | multi-chunk `import_pack` (64-byte chunks) → worktree README |
| same L201–237 | orch `import_chunk_bytes: 64` clone succeeds |
| same L241+ | file pack_source multi-chunk import |

---

## A2 — D11 JS stream fetchPacks / chunked import — PASS

**Stream fetch**

| Path | Proof |
|------|--------|
| `/mnt/workspace/agent-os/agent-os-cgit/memcontainers/sdk-js/core/src/git/smart-http.ts` | `FetchSmartHttp.fetchPacks` → `readPackFromResponse` with `body.getReader()`, running `maxBytes` (default `DEFAULT_MAX_PACK_BYTES` 64 MiB), Content-Length early reject, `onPackChunk` progressive sink |
| `FetchPacksOptions` | `maxBytes` + `onPackChunk` on product path |

**Chunked import**

| Path | Proof |
|------|--------|
| `/mnt/workspace/agent-os/agent-os-cgit/memcontainers/sdk-js/core/src/git/pack-cache.ts` | `feedPackChunks` / `importPackCached` (1 MiB default slices + size gate); `importPackStream` progressive engine import with running max |
| `/mnt/workspace/agent-os/agent-os-cgit/memcontainers/sdk-js/core/src/git/remote-orchestrator.ts` | `importBinary` → `importPackCached`; `resolvePack` passes `maxBytes` + optional `onPackChunk` into engine for fetch/pull stream-into-engine; clone buffers then chunk-imports |

**Tests**

| Path | Assertion |
|------|-----------|
| `memcontainers/sdk-js/core/test/git_pack_cache.test.ts` | chunked `importPackCached`; stream extract across PACK boundary; stream size gate; CL gate; `importPackStream` multi-chunk + size gate |
| `//memcontainers/sdk-js/core:git_pack_cache_test` | **PASSED** |

---

## A3 — D12 BEAM disk pack cache — PASS

**Code**

| Path | Proof |
|------|--------|
| `/mnt/workspace/agent-os/agent-os-cgit/server/lib/agent_os/git/pack_cache.ex` | `:disk` backend; `start_disk/1`; `disk_cache/1`; `AGENTOS_GIT_PACK_CACHE` env; layout `{dir}/{sha256hex}.pack` + `keys/{fnv1a}.key` (JS parity) |
| `/mnt/workspace/agent-os/agent-os-cgit/server/lib/agent_os/git/orchestrator.ex` | `pack_cache_of/1`: pid / `:default` / `:disk` / `{:disk, dir}` / bare dir; download-key hit skips `SmartHttp.fetch_packs` |

**Tests**

| Path | Assertion |
|------|-----------|
| `git_orchestrator_test.exs` L1171–1286 | `pack_cache: {:disk, dir}` — first clone fetch_count=1; second clone fetch_count stays 1; fresh Agent on same dir still hits |
| same L1289–1378 | `pack_cache: :disk` + `AGENTOS_GIT_PACK_CACHE` — second clone no re-fetch; CA `.pack` file present under env dir |

---

## A4 — D12 JS DiskPackCache when MC_GIT_PACK_CACHE set — PASS

**Code**

| Path | Proof |
|------|--------|
| `/mnt/workspace/agent-os/agent-os-cgit/memcontainers/sdk-js/core/src/git/pack-cache.ts` | `DiskPackCache` class; `processPackCacheDirFromEnv()` reads `MC_GIT_PACK_CACHE`; `createDefaultProcessPackCache()` → Disk when set, Memory otherwise; `defaultProcessPackCache()` process singleton |

**Tests**

| Path | Assertion |
|------|-----------|
| `git_pack_cache.test.ts` `assertDiskRoundTrip` | put/get/has/keys survive second `DiskPackCache` instance on same dir |
| `assertEnvFactory` | unset → Memory; `MC_GIT_PACK_CACHE=dir` → `DiskPackCache` |
| `//memcontainers/sdk-js/core:git_pack_cache_test` | **PASSED** |

---

## A5 — Credentials never in cache keys — PASS

**Code**

| Host | Key shape | Auth exclusion |
|------|-----------|----------------|
| BEAM `PackCache.upload_pack_cache_key/5` | `upload-pack:v1:#{url}:wants:haves:d…:f…` | Moduledoc + function doc: never credentials/userinfo; auth only SmartHttp headers |
| JS `uploadPackCacheKey` | same v1 shape | Doc: public locator only; auth at transport |

**Tests**

| Path | Assertion |
|------|-----------|
| BEAM `git_orchestrator_test.exs` L1040–1068 | key stable, no secret/Authorization/Bearer |
| BEAM L1071–1167 | bearer token on both clones; pack_key/digest never contain secret; second clone no second fetch |
| JS `git_pack_cache.test.ts` | key must not include secret/token/Authorization |
| JS `git_remote.test.ts` L215–263 | download-key hit; secret not in key/digest; second clone `fetchPacksCalls` stays 1 |

---

## A6 — Tests green — PASS

**Bazel (forced re-run, no cache)**

```
//memcontainers/sdk-js/core:git_remote_test      PASSED
//memcontainers/sdk-js/core:git_pack_cache_test PASSED
//memcontainers/sdk-js/core:git_push_test       PASSED
```

Command:

```bash
bazel --output_user_root=/mnt/workspace/agent-os/bazel-cache test \
  //memcontainers/sdk-js/core:git_remote_test \
  //memcontainers/sdk-js/core:git_pack_cache_test \
  //memcontainers/sdk-js/core:git_push_test \
  --test_output=all --nocache_test_results
```

**Mix orch + pack**

```bash
export AGENTOS_GIT_ENGINE=/mnt/workspace/agent-os/agent-os-cgit/bazel-bin/memcontainers/lib/git-engine/git-engine
# after clearing stale /tmp agentos-git-*/pack-* dirs that collide with unique_integer
mix test test/agent_os/git_orchestrator_test.exs test/agent_os/git_engine_pack_test.exs
# Result: 57 passed (serial and default max_cases)
```

Note (non-blocking): unclean `/tmp` leftovers from prior runs can make git-engine auto-open an existing `.git` (`ge_create` open_ext) so a later `init` reports `repository already open`. Product D11/D12 paths are not the cause; fresh tmp → full green.

---

## Hostile notes (not blockers)

1. JS clone path does not stream into the engine mid-download (`streamIntoEngine` false for clone); product still streams the HTTP body with a size cap and then chunk-imports — meets D11 as specified (stream fetch + chunked import).
2. BEAM product download streams to a temp file (disk), not zero-copy into the Port; size-cap fail-closed and chunked Port import are still implemented and tested.
3. Mix suite needs `AGENTOS_GIT_ENGINE` (or bazel `//server:mix_test` runfiles); bare `mix test` without the binary fails closed before exercising orch/pack.
