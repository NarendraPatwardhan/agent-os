# Git

Host git is an optional attachment: a libgit2 engine on the host, a gitfs worktree in the guest, and
a reduced `/bin/git`. The guest never receives credentials or a network socket for remotes. Enable it
with the `git` create option — omit the field for no host git.

Architecture for maintainers lives in `SYSTEMS.md` §11b. Field-level create options are also listed
under [Create options](./create-options.md#git).

## Enable at create

```js
const vm = await mc.create({
  kernel,
  image,
  git: true,
  connections: [
    {
      ref: "github.user.work",
      auth: { kind: "bearer", token },
      origins: ["https://github.com"],
    },
  ],
});
```

Presence of `git` turns the feature on. There is no separate boolean flag and no public engine URL.

| Form   | Meaning                                                                                                                            |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| `true` | Enable with a resolved `git-engine.tar` (env, install dir, cache, or optional fetch).                                              |
| object | `GitCreateOptions`: optional `engine` tar bytes, `mounts`, `sparse`, `identity`, `durable`, and test-only `allowOrigins` / `http`. |

Default mount path is `/workspace/repo` unless `git.mounts` overrides it. Commits need author identity
from `git.identity` or per-commit args — AgentOS does not read the host user's gitconfig.

```js
const vm = await mc.create({
  git: {
    identity: { name: "Agent", email: "agent@example.com" },
    sparse: ["src", "docs"],
    // engine: readBytes("./agent-os/git-engine.tar"),
    // durable: { id: "session-1", diskDir: "/var/lib/agentos/git-durable" },
    // mounts: [
    //   { path: "/workspace/app" },
    //   { path: "/workspace/lib", sparse: ["src"] },
    // ],
  },
  connections: [
    {
      ref: "github.user.work",
      auth: { kind: "bearer", token },
      origins: ["https://github.com"],
    },
  ],
});
```

## What the guest sees

| Surface                      | Role                                                                     |
| ---------------------------- | ------------------------------------------------------------------------ |
| Worktree paths               | Ordinary files under the gitfs mount (default `/workspace/repo`)         |
| `/.git/mc/ctl`               | Write-only local-porcelain mailbox; Requests require `args.client_token` |
| `/.git/mc/responses/<token>` | Response for that exact ctl request                                      |
| `/.git/mc/out/<token>`       | Complete stdout when that Response reports truncation                    |
| `/bin/git`                   | Thin pure-mc CLI — reduced surface, not full git-core                    |
| Remotes                      | Only via host_call name `"git"` when the guest has **CAP_NET**           |

There is no synthetic `.git/objects` tree. The object database stays on the host. Symlinks are fail-closed
on explicit paths and skipped on bulk `add -A`.

`clone` has a shared engine reservation: its bound root must be an existing, genuinely empty directory
with no repository, index, or worktree entries. An exclusive control lock closes concurrent
check-then-act races across engine instances; the JS and BEAM orchestrators hold it from before network
I/O through apply and release it on every normal/error exit. A partially mutated clone is not reusable.

### Thin `/bin/git`

Local commands use ctl. Remote commands use host_call `"git"`.

| Class  | Commands                                                                                                                                                                 |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Local  | `init`, `status`, `add`, `rm`, `commit`, `log`, `diff`, `show`, `rev-parse`, `branch`, `checkout` / `switch`, `reset`, `tag`, limited `config`, `remote` list/add/remove |
| Remote | `clone [--depth N] [--filter SPEC]`, `fetch`, `pull`, `push`                                                                                                             |
| Meta   | `version`, `help`                                                                                                                                                        |

Unknown commands fail closed. Out of surface on the thin CLI: interactive rebase, bisect, LFS,
submodule commands, annotated tags, and full git-config language. Sparse cones are configure-time
(`git.sparse` / mounts), not a CLI flag.

## Remotes and credentials

Remotes are host-mediated. Prefer [connections](./connections.md) for origins and auth. The guest may
pass a public URL and an optional connection ref — never tokens.

| Rule                        | Behaviour                                                                            |
| --------------------------- | ------------------------------------------------------------------------------------ |
| Guest remotes               | Require CAP_NET and host_call name `"git"`; ctl remotes refuse                       |
| Host catalog                | `connections` on create / `attach_git` — secrets stay host-side                      |
| Empty `connection.origins`  | Fail closed                                                                          |
| Bare URL without connection | Needs a non-empty host allowlist (fixtures); product attaches usually deny bare URLs |
| Read-only mount             | Push rejected with `git: push rejected (read-only mount)`                            |
| Secrets in responses        | Never; only connection refs are visible                                              |

On JavaScript hosts the orchestrator runs in-process with the emcc engine. On a served control-plane
VM, BEAM owns HTTPS and the orchestrator; the dial-free `git-engine` Port only applies packs and
mount ops. Clone defaults to shallow (`depth=1`) unless overridden.

## Multi-mount

Each distinct mount path owns one engine (single-writer per path). Remotes demux with `args.mount`
(or top-level `mount`).

```js
const vm = await mc.create({
  git: {
    mounts: [{ path: "/workspace/app" }, { path: "/workspace/lib", sparse: ["src"] }],
  },
  connections: [
    {
      ref: "github.user.work",
      auth: { kind: "bearer", token },
      origins: ["https://github.com"],
    },
  ],
});
```

When `mount` is omitted, a single engine is used as-is; with several mounts the first entry is the
default — pass `mount` explicitly for multi-repo remotes. Duplicate paths fail closed. Snapshot is
refused while any git remote host_call is in flight.

## Durability / dir reopen

Kernel snapshots (MCSN) do **not** include the host object database. Repo survival across
snapshot/restore/fork needs an explicit durable store.

```js
const vm = await mc.create({
  git: {
    durable: { id: "agent-session-1", diskDir: "/var/lib/agentos/git-durable" },
  },
});
// vm.snapshot() / pinBase checkpoint the durable store
// mc.restore / fork with the same git.durable reopens and rebinds
```

| Form                      | Meaning                                                        |
| ------------------------- | -------------------------------------------------------------- |
| `durable.diskDir`         | Re-openable host worktree under `{diskDir}/{id}/` (primary)    |
| `durable.id` without disk | Atomic AgentOS Git Snapshot in OPFS, else process-memory by id |
| Omit `durable`            | Ephemeral engines; restore does not rehydrate the ODB          |

On a served host, pass a preserved Port worktree root (or durable id under a configured base) when
reattaching. Advanced direct load: `GitEngine.load({ engine?, durableDir?, durable? })`.

AgentOS Git Snapshots preserve the ODB, refs, HEAD, index, sparse metadata, staged/dirty/untracked files,
empty directories, modes, and symlink identities without following link targets. Runtime ctl streams
and one-shot pack exports are not durable state. JS host-directory checkpoints stage and fsync a
complete generation before atomically replacing the prior one; any copy/checkpoint failure aborts
snapshot or close instead of publishing partial state. Served BEAM Port roots are direct libgit2
directories: checkpoint validates that the root remains present for later reopen but does not pretend
Erlang performed a portable directory fsync.

## Host git-engine.tar resolve (JS)

The product artifact is release **`git-engine.tar`** (mjs + wasm + notices), parallel to `kernel` and
`catalogCompiler`. Resolve order for `mc.create({ git })`, `GitEngine.load`, and `llb.git`:

1. Explicit `engine` bytes
2. `MC_GIT_ENGINE_TAR`
3. `$AGENTOS_DIR/git-engine.tar` or `$MC_ARTIFACT_HOME/git-engine.tar`
4. Host artifact cache (`MC_ARTIFACT_CACHE`, else XDG / `~/.cache/agentos/artifacts`)
5. Optional fetch when `MC_ARTIFACT_FETCH=1`
6. Else fail closed

After `install.sh`, `source agent-os/env.sh` sets the usual paths. Materializing the tar for emcc is
private; there is no public `baseUrl` create option.

| Variable                           | Meaning                                    |
| ---------------------------------- | ------------------------------------------ |
| `MC_GIT_ENGINE_TAR`                | Path to `git-engine.tar`                   |
| `AGENTOS_DIR` / `MC_ARTIFACT_HOME` | Install root that contains the tar         |
| `MC_ARTIFACT_CACHE`                | Blob + materialize cache root              |
| `MC_ARTIFACT_FETCH`                | `=1` / `true` allows network fetch on miss |
| `MC_ARTIFACT_VERSION`              | Cache / fetch key (default `local`)        |

## Pack cache (interactive remotes + LLB)

Pack bytes are content-addressed. Download keys never include credentials. Product handlers use a
**fresh** in-memory cache per handler by default (safer multi-tenant isolation). Set
`MC_GIT_PACK_CACHE_SHARED=1` (and optionally `MC_GIT_PACK_CACHE` for disk) only on single-tenant
workers that intentionally share a process-wide cache. LLB Node solve uses the process pack cache by
default so repeated solves reuse packs.

## LLB

`llb.git` uses the same host remote/apply path as interactive clone. On Node/Bun the engine is
resolved as above; ambient system `git` runs only when `MC_GIT_USE_SYSTEM=1` (exact). Without a
resolved engine and without that hatch, solve fails closed. See [LLB](./llb.md#llb-git-repo-options).

## Agent constraints

| Constraint                     | Meaning                                                                                  |
| ------------------------------ | ---------------------------------------------------------------------------------------- |
| One engine per mount path      | Distinct paths only; remount of a live path fails closed                                 |
| Close ctl writes before status | Unflushed guest buffers are invisible to the engine                                      |
| Remotes need CAP_NET           | Mount/ctl alone cannot dial                                                              |
| Identity on commit             | Supply `git.identity` or commit args                                                     |
| Large stdout                   | Responses preview 2 KiB; `/bin/git` drains the complete token-scoped stream (16 MiB cap) |

`add` follows the engine's Git-compatible reduced rule: bulk `add -A` skips ignored untracked files,
while explicit add of an ignored untracked path fails closed because force-add is not part of the thin
surface. Tracked ignored paths may still be updated. Regular files retain the executable bit in the
index/tree, and `commit` rejects an unchanged tree; there is no public or internal allow-empty caller.

Sparse cone changes require a clean index and worktree, including ignored untracked files, before any
metadata or checkout mutation. The engine checks config, pattern writes, checkout, index updates, and
pruning failures and never prunes after a failed checkout. A failed transition rolls metadata, index
skip bits, and worktree projection back to the prior cone; a rollback failure is reported explicitly
instead of being presented as success.

## Advanced API

| Export                                        | Role                                                              |
| --------------------------------------------- | ----------------------------------------------------------------- |
| `GitEngine`                                   | Direct engine load, `run`, `importPack`, `asMountDriver`, remotes |
| `registerGitHostCall` / `gitHostCallHandler`  | CAP_NET host_call name `"git"`                                    |
| `resolveGitEngineTar`                         | Explicit tar resolve helper                                       |
| `materializeLlbGit` / `createEngineGitSource` | LLB solve helpers                                                 |

These are **advanced** (`docs/api-surface.json`). Prefer `mc.create({ git: true })` in applications.

On a remote runtime, the served host owns Port placement and engine binaries; the client still opts in
with `git` create options and supplies connections as for any other capability.
