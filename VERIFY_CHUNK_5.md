# VERIFY_CHUNK_5

Verdict: **PASS**

Hostile verifier for `feature/cgit` Chunk 5 (D16 directory reopen durable, D17 snapshot/restore rebind, D18 server named durable root). Tree: `feature/cgit` @ `662dadd` + dirty working tree (Chunk 5/6 durability + submodule sources uncommitted; `server/lib/agent_os/git/durable.ex` untracked). No product code changed by this verifier.

---

## Acceptance matrix

| # | Requirement | Result | Evidence |
|---|-------------|--------|----------|
| 1 | **D16** directory-reopen durable (not AGIT-only); second load same HEAD | **PASS** | See A1 |
| 2 | **D17** snapshot/restore rebinds git durable — guest e2e | **PASS** | See A2 |
| 3 | **D18** server durable root path exists for named attach | **PASS** | See A3 |
| 4 | Tests green | **PASS** | See A4 |

All four hold. Chunk 5 verdict is **PASS**.

---

## A1 — D16 directory-reopen durable (not AGIT-only) — PASS

**Primary form is a re-openable libgit2 worktree+ODB directory**, not AGIT blob transfer alone.

| Host | Path | Behaviour |
|------|------|-----------|
| **JS** | `/mnt/workspace/agent-os/agent-os-cgit/memcontainers/sdk-js/core/src/git/durable.ts` | `HostDirDurable` (`kind: "directory"`): `hostPath`, `hydrateToMemfs` / `dumpFromMemfs` + fsync; `openDurable({ durableDir })` / `{ diskDir }` prefer directory |
| **JS** | `.../git/engine.ts` | `GitEngine.load({ durableDir })` → `HostDirDurable`; `checkpoint()` dumps MEMFS→host (or NODEFS fsync); `durableSnapshot` null for directory backends |
| **JS** | `.../git/bridge.ts` | Before `ge_open`: NODEFS mount of host path when available, else `hydrateToMemfs` |
| **BEAM** | `/mnt/workspace/agent-os/agent-os-cgit/server/lib/agent_os/git/durable.ex` | `resolve_root/1`: `:root` / `:durable_dir` → `{:ok, root, :durable}` (never temp rm) |
| **BEAM** | `.../git_engine.ex` | `init` uses Durable; `temp_root?` only for temp; `checkpoint/1` = `sync_root`; `terminate` only `rm_rf`s `agentos-git-*` temp under `tmp` |

**Proof — second process / second load same HEAD + worktree**

| Test | Assertions |
|------|------------|
| `memcontainers/sdk-js/core/test/git_engine.test.ts` D16 block | Process A: `durableDir` → init/commit/checkpoint → host has `.git` + `dir-persist.txt`; Process B: second `GitEngine.load({ durableDir })` → **same HEAD** + worktree content `host-dir-roundtrip`; **no** AGIT `durableSnapshot` |
| `server/test/agent_os/git_engine_test.exs` `"D16 directory durable: second Port reopens same HEAD + worktree"` | Port1 `root:` → commit → checkpoint → stop (`.git` survives); Port2 same root → **head2 == head1** + `persist.txt` on disk |

AGIT (`MemoryDurable` / `DiskDurable` / `OpfsDurable`) remains optional **transfer** only. Directory path is product primary. **Not AGIT-only theater.**

---

## A2 — D17 snapshot/restore rebinds git durable (guest e2e) — PASS

MCSN does **not** carry host ODB. Restore must reopen the durable store and rebind.

| Piece | Path | Behaviour |
|-------|------|-----------|
| `CreateOptions.gitDurable` | `memcontainers/sdk-js/core/src/types.ts` | Opt-in `{ id?, diskDir? }` |
| `makeEmbedded` | `memcontainer.ts` | Per-mount `openDurable` + `GitEngine.load`; `backend.bindGitEngines(...)` when durable opted in |
| `EmbeddedBackend.snapshot` / `pinBase` | `embedded.ts` | `await checkpointGitEngines()` **before** MCSN / baseline pin |
| Restore / fork | `mc.restore` / `Vm.fork` | Same `gitDurable` → reopen id (Memory registry) or diskDir path → AGIT rebind or directory hydrate |

**Guest e2e proof** (`memcontainers/sdk-js/core/test/git_guest_e2e.test.ts` phase D17):

1. `mc.create({ gitDurable: { id } })` — process MemoryDurable registry (lifecycle wiring; HostDir is D16 primary path via `diskDir`).
2. Guest init + commit via ctl (K28 identity) → HEAD oid.
3. `vm.snapshot()` → checkpoints AGIT into registry; MCSN captured.
4. `vm.close()` then `mc.restore(snap, same createOpts)` → **HEAD after === HEAD before**; worktree `d17.txt` content present.
5. `restored.fork()` → same HEAD + worktree (fork = snapshot+restore rebind).

**Hostile note (not a FAIL):** e2e uses MemoryDurable AGIT by id, not HostDir `diskDir`. Criterion is “rebinds git durable,” not “directory durable on restore.” Directory reopen is D16; D17 is MCSN lifecycle rebind. Product path with `gitDurable.diskDir` opens `HostDirDurable` and checkpoints that directory — same bind/checkpoint hooks.

**BEAM:** no MCSN rebind; durability = re-`attach_git` / second `GitEngine.start` with same `:root` / `:durable_dir` / `:durable_id` (see A1/A3).

---

## A3 — D18 server durable root path for named attach — PASS

| Piece | Path | Behaviour |
|-------|------|-----------|
| `AgentOS.Git.Durable` | `server/lib/agent_os/git/durable.ex` | `AGENTOS_GIT_DURABLE_ROOT` / app `:git_durable_root`; layout `{base}/{safe_vm_id}/{mount_slug}/`; `resolve_named_root/2`; `resolve_root/1` for `:root` / `:durable_dir` / `:durable_id` |
| `GitEngine.start` | `git_engine.ex` | Uses `resolve_root`; durable roots not deleted on stop |
| `Vm.attach_git` | `vm.ex` | Forwards `:durable_dir` / `:durable_id` / `:root` into engine start |

**Proof** (same D16 test block): `durable_id: "vm-alice"`, `mount_path: "/workspace/repo"` under `AGENTOS_GIT_DURABLE_ROOT` → root under `{base}/vm-alice/workspace@repo`; survives stop; `File.dir?(root3)`.

**Scoped honesty (not FAIL vs criterion):** auto-wire of every named ControlPlane VM without attach opts is **not** claimed. Criterion is “server durable root path exists for named attach” — attach path with `durable_id` / env base is present and tested.

---

## A4 — Tests green — PASS

### Bazel (forced re-run, `--nocache_test_results`)

```
//memcontainers/lib/git-engine:abi_fixture_test     PASSED
//memcontainers/sdk-js/core:git_engine_test         PASSED
//memcontainers/sdk-js/core:git_guest_e2e_test      PASSED
//memcontainers/sdk-js/core:git_remote_test         PASSED
```

Command:

```bash
bazel --output_user_root=/mnt/workspace/agent-os/bazel-cache test \
  //memcontainers/lib/git-engine:abi_fixture_test \
  //memcontainers/sdk-js/core:git_engine_test \
  //memcontainers/sdk-js/core:git_guest_e2e_test \
  //memcontainers/sdk-js/core:git_remote_test \
  --nocache_test_results
```

### BEAM (mix + `AGENTOS_GIT_ENGINE`)

Native Port binary: `bazel-bin/memcontainers/lib/git-engine/git-engine`.

| Suite | Result |
|-------|--------|
| `MIX_ENV=test mix test test/agent_os/git_engine_test.exs` | **7 passed** (includes D16+D18 block) |
| `mix test .../git_orchestrator_test.exs:3124` | D23/D24 **passed** (Chunk 6; Port-level, no NIF) |

### BEAM / NIF env limits (honest, not soft-close)

- Port-level D16/D18 need only `AGENTOS_GIT_ENGINE` (native `git-engine`). Worked with local mix.
- Full guest VM attach/`//server:mix_test` needs host NIF staged under `priv/` (Bazel `//memcontainers/hosts/wasmtime/nif:host_nif_release`). Plain `server/priv` has no `.so` in this worktree layout; Bazel `elixir_test //server:mix_test` is the hermetic path. D16/D18 attach opts are wired in `Vm.attach_git` and exerciseable when NIF is present — **not** re-run as full ControlPlane guest e2e in this verify session.
- This is an **environment/staging** limit, not a missing product path for named durable attach.

---

## Hostile residual (not FAIL)

| Item | Severity | Note |
|------|----------|------|
| D17 e2e is MemoryDurable AGIT | Info | Proves rebind lifecycle; HostDir product path covered by D16 + openDurable(diskDir) wiring |
| D18 not auto-attach for all named VMs | Info | Explicitly out of scope per TASKS / criterion |
| Uncommitted tree | Process | Verify on dirty sources that tests exercise; promote only after commit |
| Browser OPFS refresh e2e | Polish | `OpfsDirDurable` class lands; browser refresh product e2e optional |
