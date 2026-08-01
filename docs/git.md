# AgentOS Git — Host Source Plane

Product surface for interactive and LLB git (host source plane). Design of record: worktree
`GIT.md`. Create option: `git: true` or `git: { … }` — **presence enables**; no boolean. Engine tar is resolved (or pass `engine` bytes). API surface: **advanced** (opt-in; not multi-tenant default-on).

## Thesis

Git is a **host source plane** (libgit2 + thin `ge_*` ABI). Guests see paths and a thin `/bin/git`;
the engine never dials the network. Remotes are host-mediated.

| Face | Path |
|------|------|
| SDK (JS) | `GitEngine.load` / `mc.create({ git })` + `registerGitHostCall("git")` / `gitHostCallHandler`; demux helpers `normalizeGitEngineMap`, `mountFromGitRequest`, `resolveGitEngineForMount`; LLB `materializeLlbGit` / `createEngineGitSource`; tar resolve `resolveGitEngineTar` |
| gitfs | `asMountDriver()` → MountFs; local ctl at `/.git/mc/ctl` |
| Thin CLI | Thin guest `/bin/git` — reduced surface only (see below) |
| Server engine | BEAM-owned C `git-engine` **Port** — local Run, pack apply, type-4 mount only |
| Server remotes | **BEAM HTTPS + Elixir orch** → Port apply / pack.build (**no Node**, **no C TLS**); **fetch/clone/push** when not read-only |
| LLB (Node) | Host emcc engine first (resolved `git-engine.tar`); **not** ambient system git |

## Agent-facing constraints (product)

These are hard product rules for agents and tools that use host git — not optional polish.

| Constraint | Meaning |
|------------|---------|
| **One gitfs engine per mount path** | Multi-mount is allowed with **distinct** paths. Each path owns its own engine (single-writer). Remounting gitfs at an already-live path fails closed. |
| **No `.git/objects` façade (v1)** | Guests do **not** get a synthetic `.git/objects` tree. Object DB stays host-side; worktree + ctl only. |
| **Unflushed ctl: close write before status** | Ctl Request is written to `/.git/mc/ctl`; Response is read from the out path. Close (or Drop) the write FD **before** reading status / next Response — unflushed guest buffers are invisible to the engine (same class as `hostDir`). |
| **Remotes need CAP_NET + host_call `git`** | Mount/ctl alone cannot dial. Guest remotes go through `mc_sys_host_call` name `"git"` gated by kernel **CAP_NET**. Ctl remote ops refuse. |
| **Opt-in + identity on commit** | Opt-in via `git` create option (JS; advanced surface). Commits need author identity (`name` / `email` args or `git.identity`) — no ambient global gitconfig from the host user. |
| **Server push (not read-only)** | See [Server remotes](#server-remotes) — packbuilder + receive-pack on BEAM when mount is not read-only. |

## Thin CLI surface

The guest thin CLI is a pure-mc adapter over the host engine surface — **not** full
git-core. Unknown commands fail closed. Local argv maps to ctl Request JSON; remotes use
`host_call` name `"git"`.

| Class | Commands | Path |
|-------|----------|------|
| Local porcelain | `init`, `status`, `add <path…>` / `add -A`/`--all`, `rm <path…>`, `commit -m …`, `log`, `diff [--cached\|--staged] [path…]` (full unified patch), `show [rev]`, `rev-parse [rev]`, `branch` / `branch <name>` / `branch -d <name>`, `checkout`/`switch <name>`, `reset [--soft\|--mixed\|--hard] [rev]`, `tag [-d] <name>`, `config --list` or `config <key> [value]`, `remote` list/add/remove | Discover `/.git/mc/ctl` under cwd parents; write Request JSON, re-open/read Response (multi-path `add`/`rm` = one round-trip per path; `diff` sends `path` or `paths[]` in one request) |
| Remotes | `clone [--depth N] [--filter SPEC] <url>`, `fetch [url]`, `pull [url]`, `push [url]` | `host_call` name `"git"` (**CAP_NET**); clone works outside a repo (no root discovery) |
| Meta | `version` / `--version`, `help` / `--help` | stdout/stderr only |

Out of surface (examples): interactive rebase, bisect, LFS, submodules on the thin CLI, full
git-config, annotated tags. Sparse cone is create/`attach_git` configuration, not a thin-CLI
flag. Unknown commands → `unknown or unsupported command`.

## Large stdout / stream path

When a local op produces more than **1 MiB** of stdout (product embed limit), the engine never
silently drops data:

| Field | Meaning |
|-------|---------|
| `stdout` | Preview only (first 1 MiB) |
| `result.truncated` | `true` |
| `result.stream_path` | `".git/mc/out/last"` (worktree-relative) |
| `result.stdout_bytes` | Full body length before embed cut |
| `result.stream_bytes` | Bytes written to the stream file (≤ **8 MiB**) |
| `result.stream_partial` | `true` if full body > 8 MiB (prefix only on disk) |

**How to read the full body:**

1. **gitfs / guest:** open `/.git/mc/out/last` (or `/.git/mc/out/stream` alias) after the Response.
2. **JS host API:** `await engine.readStdoutStream(resp)` — reads the stream file via the bridge FS.
3. **Native / abi:** file at `{worktree}/.git/mc/out/last`.

`/.git/mc/ctl` always returns the last **Response JSON** (drain protocol). When a stream file is
present, `out/last` serves that **raw stdout body** instead of the Response alias.

## Symlink / special-file policy

**Choice: fail closed** for explicit paths — never follow or materialize symlink targets.

| Op | Symlink / special | Behaviour |
|----|-------------------|-----------|
| `write` path is a symlink | Fail | `write: path is a symlink (not supported; fail closed)` |
| `add` path is a symlink | Fail | `add: path is a symlink (not supported; fail closed)` |
| `add` path is non-regular special | Fail | clear error; no stage |
| `add` with `all=true` | Skip | Symlinks and specials are **skipped** (walk continues) so monorepo bulk stage still works |
| Durable hydrate / dump | Skip | Same skip class as `add all` |

Rationale: following a worktree symlink can escape the engine root; materializing remote targets is
out of surface for v1. Guests that need link content should copy to a regular file first.

## log / show bounds

| Op | Bounds | Signals |
|----|--------|---------|
| `log` | Default `max_count=10`; hard cap **1000** | `result.count`, `result.max_count`, `result.bounded`, optional `result.more`; stable stdout footer `# log: bounded max_count=N count=C more=true` when more commits exist (or request was clamped) |
| `show` | Full commit message (no silent fixed-buffer cut) | Oversized body uses the large-stdout path: truncated embed + `stream_path` |

## Server remotes

Same ownership cut as kernel HTTP egress: **BEAM dials HTTPS**; the guest and the Port child do not.

```text
guest host_call "git"
  → kernel CAP_NET
  → BEAM AgentOS.Git.Orchestrator
       ├─ connection catalog resolve + credential splice
       ├─ smart-HTTP (OTP :httpc / ssl)
       │    ListRefs / FetchPacks / PushPacks (receive-pack)
       └─ Port frames → git-engine
            import_pack, refs.import, clone.apply / fetch.apply,
            pack.build, push.prepare, push.complete
  → Response JSON
```

| Responsibility | Owner |
|----------------|--------|
| TLS, ListRefs, FetchPacks, PushPacks | **BEAM** (`AgentOS.Git.SmartHttp`) |
| Origin / connection policy + credential splice | **BEAM** (`AgentOS.Git.Connections` catalog on `attach_git`) |
| Pack import + apply + packbuilder + local porcelain | **C Port** (`AgentOS.GitEngine`) |
| JS browser/Node remotes | **TS** orch + emcc |
| **Push (server)** | **Supported** when not `read_only` — pack.build + receive-pack + push.complete |

### Product path: connection catalog

**Prefer connections over a flat origin allowlist.** Host attaches git with a connection
catalog (same shape as [connections](./connections.md) / JS `ConnectionDefinition`). Origins
and auth live **on the matching connection** — a separate `allowed_origins` is **not** required.

```elixir
# BEAM / ControlPlane product attach (secrets stay host-side)
AgentOS.ControlPlane.attach_git(vm_id,
  connections: [
    %{
      ref: "github.user.work",
      auth: %{kind: :bearer, token: System.fetch_env!("GITHUB_TOKEN")},
      origins: ["https://github.com"]
    }
  ],
  policies: [
    %{pattern: "github.user.*", action: :require_approval}
  ]
)
```

```ts
// JS create options — same catalog cut
mc.create({
  git: true, // or { identity, mounts, engine?: tarBytes, … }
  connections: [
    { ref: "github.user.work", auth: { kind: "bearer", token }, origins: ["https://github.com"] },
  ],
});
```

Guest / thin CLI remotes name a **public** locator + optional connection ref only:

```json
{"op":"clone","args":{"url":"https://github.com/org/repo.git","connection":"github.user.work"}}
```

| Rule | Behaviour |
|------|-----------|
| **Host catalog** | `attach_git(connections: …)` / JS `connections` — never guest body |
| **Guest may pass** | Public `url`, `connection` / `agentos` ref, `remote` name, mount |
| **Guest must not pass** | Tokens, auth maps, origins, policies — **rejected** (`git: guest body must not include auth secrets`) |
| **Empty `connection.origins`** | Fail closed — no dial, no credential splice to attacker URLs |
| **Unknown connection ref** | Fail closed (`git: unknown connection ref …`) |
| **Bare URL (no connection)** | Requires non-empty host `allowed_origins` match (legacy / fixture). Product attaches with connections only → bare URL fails closed |
| **Push policy** | `policies: [%{pattern, action}]` with `approve` \| `require_approval` \| `block` (most restrictive wins). Stable stderr: `git: push blocked by policy`, `git: push requires approval` |
| **Secrets in responses / info** | Never — `Vm.info` surfaces connection **refs** only |

**Legacy flat allowlist** (`allowed_origins` + optional flat `auth`) still works when
`connections` is empty (fixtures / migration). When `connections` is non-empty, the catalog
wins for remote policy.

Aligns with [connections](./connections.md): credential splice after origin checks; CAP_NET
still required for guest remotes via host_call name `"git"`.

### Push

**Server remotes support push** on the BEAM path when the git mount is not read-only:

1. Connection / origin policy + push policy (`block` fails before dial)
2. `push.prepare` (local tips as commands)
3. ListRefs lease (remote `oldHash`)
4. `require_approval` / host approval callback when policy demands it
5. `GitEngine.pack_build/2` (optional `haves:` from lease `old_hash`) → `.git/agentos/push.pack`
   (non-delete must be non-empty `PACK…`; delete-only may be empty)
6. Smart-HTTP `git-receive-pack` + report-status
7. `push.complete` (remote-tracking when remote accepted; skipped for all-zero delete hash)

Read-only mounts reject push with a **stable** stderr (do not paraphrase in callers that match it):

```text
git: push rejected (read-only mount)
```

Empty pack on a non-delete push fails closed (`git: empty pack refused for non-delete push`).
**Delete-ref push** (`args.delete: true | ref | [refs…]`): `newHash` all-zero, empty pack allowed.
**Thin-pack / haves:** packbuilder hides lease old tips so shared history is omitted.
Connection origin policy, max pack size, and no-URL-credentials policy apply to push URLs the
same as fetch/clone. Secrets only in BEAM request headers.

### Monorepo materialization

**Product stack for large trees** (all three compose; configure what you need):

| Layer | Role |
|-------|------|
| **Shallow history** | Product **clone** default `depth=1` (`args.depth` / thin CLI `--depth N`; `depth<=0` = full). **Fetch/pull** default full history when depth omitted (`contracts/git.kdl`) |
| **Cone sparse worktree** | JS `git.sparse` / `git.mounts[].sparse` / BEAM `attach_git(sparse_cone: …)` → after `clone.apply`, engine `sparse-set` + checkout so only cone prefixes land on disk; gitfs projects the same cone |
| **Optional pack filter** | `args.filter` / thin CLI `--filter SPEC` (e.g. `blob:none`) on upload-pack — shrinks the **initial** pack when the server supports filter |

```text
clone (depth=1, optional filter) → import_pack → refs.import → clone.apply
  → sparse-set(patterns) → checkout(HEAD)   # when cone configured
  → guest/gitfs sees cone paths only
```

Cone patterns are multi-prefix lists with basic `!path` negation written into `sparse-checkout`
(cone mode). Prefer listing the directories agents need (`["src", "docs"]`).

**Out of surface for monorepo agents:** full git sparse-checkout pattern language, promisor
remotes, and on-demand lazy re-fetch of missing objects after a filtered pack. Filter alone does
not project a usable monorepo worktree — pair it with cone sparse when agents need paths. Servers
or fixtures that ignore `filter` return a full pack; the engine materializes whatever arrived.

### Pack filter

Clone/fetch accept optional `args.filter` (e.g. `blob:none`, `tree:0`). Host smart-HTTP advertises
the `filter` capability and sends a `filter <spec>` pkt-line. Thin CLI:
`git clone --filter=blob:none <url>` (compose with `--depth`). Part of the monorepo stack above —
not a separate incomplete feature.

Dual-host remotes are **TS orch (JS) ↔ BEAM orch (server)**; the Port applies packs/refs
and never dials.

### Dual-host remote contract

TS and BEAM each implement remote orch. **Decisions** are single-sourced:

| Layer | Location |
|-------|----------|
| Contract | `memcontainers/contracts/git.kdl` → `gen/git.gen.ts` / `AgentOS.Contracts.Git` |
| Executable goldens | **Only** `memcontainers/lib/git-engine/fixtures/orch/*.json` (no second copy) |

| Decision | Contract default |
|----------|------------------|
| Redirect | never follow (`redirect_never`) |
| Empty origins | deny |
| Guest secret keys | reject before dial |
| Clone depth when omitted | `1` |
| Fetch/pull depth when omitted | full (`0`) |
| `maxPackBytes: 0` | means **default 64 MiB**, not unlimited |
| PACK magic | required |
| Origin deny stderr | prefix `git: origin not allowlisted` (no URL suffix) |

### Dual-host executable goldens

| File | Asserts |
|------|---------|
| `clone_success_steps.json` | fixture pack + tip → `ok:true`, stdout contains `cloned` |
| `shallow_clone_steps.json` | explicit `depth: 1` clone → `ok:true`, stdout contains `cloned` |
| `clone_empty_pack_fail.json` | empty pack → `ok:false`, stderr contains `empty pack` |
| `origin_denied.json` / `auth_deny_steps.json` | wrong allowlist → `ok:false`, stderr contains `not allowlisted` |
| `fetch_success_steps.json` / `pull_ff_steps.json` | fetch/pull success paths |
| `pull_not_ff_steps.json` | diverged local tip (setup init+commit) → pull fails `git: not fast-forward` |
| `push_readonly.json` / `push_success_steps.json` | RO reject + fixture push success |
| `origin_deny_prefix.json` | origin deny catalog prefix only (no URL in stderr) |
| `guest_secret_reject.json` | guest `token` in body fails before dial |
| `query_auth_reject.json` | connection auth kind `query` rejected dual-host |
| `response_schema.json` | required Response keys + stable stderr prefixes (subset of `git.kdl`) |

**Both** hosts run the same tree:

- TS: `//memcontainers/sdk-js/core:git_orch_golden_test`
- BEAM: `AgentOS.Git.OrchGoldenTest` (data → `//memcontainers/lib/git-engine:orch_algorithm_traces`)

Prose-only algorithm name lists without assertions are not sufficient.

## Create options (JS)

Opt-in by presence of `git`; documented in [Create options](./create-options.md).
There is no public `baseUrl` — the host resolves **`git-engine.tar`** bytes (or you pass
`engine` bytes explicitly). Materializing the emcc `git_engine.mjs` / `.wasm` pair is private.

```ts
// Minimal — resolves git-engine.tar (env / install dir / cache / optional fetch)
mc.create({
  git: true,
  connections: [{ ref: "github.user.work", auth: { kind: "bearer", token }, origins: ["https://github.com"] }],
});

// Full object form
mc.create({
  git: {
    // optional engine: Uint8Array — override bytes of git-engine.tar
    sparse: ["src", "docs"],
    mounts: [{ path: "/workspace/a" }, { path: "/workspace/b", sparse: ["src"] }],
  },
  connections: [{ ref: "github.user.work", auth: { kind: "bearer", token }, origins: ["https://github.com"] }],
});
```

### Multi-mount / `args.mount`

Multi-repo is supported when each mount path owns its own engine. Remotes on host_call
`"git"` demux to the engine for that path. Single-writer is **per mount**, not global: two mounts
may run remotes concurrently; two remotes on the **same** mount serialize.

#### Product setup

| Host | How to attach two engines | Default when `mount` omitted |
|------|---------------------------|------------------------------|
| **JS** | `mc.create({ git: { mounts: [{ path: "/workspace/a" }, { path: "/workspace/b", sparse: ["src"] }] } })` | First `git.mounts` entry |
| **BEAM** | `ControlPlane.attach_git(id, mount_path: "/workspace/a", …)` then again with a **distinct** `mount_path: "/workspace/b"` | Sole engine if only one attached; otherwise first attached (prefer explicit `args.mount`) |

Same path while live fails closed: JS throws on duplicate `git.mounts` path; BEAM returns
`{:error, :git_already_attached}`. Detach one path with BEAM `detach_git(id, mount_path: …)`;
JS closes the VM (all engines).

```ts
// JS product create — two mounts, remotes demux by args.mount
const vm = await mc.create({
  git: {
    mounts: [
      { path: "/workspace/app" },
      { path: "/workspace/lib", sparse: ["src"] },
    ],
  },
  connections: [{ ref: "github.user.work", auth: { kind: "bearer", token }, origins: ["https://github.com"] }],
});
// Guest (CAP_NET): host_call "git" body includes mount to select engine
// {"op":"clone","args":{"url":"https://github.com/org/app.git","mount":"/workspace/app"}}
// {"op":"clone","args":{"url":"https://github.com/org/lib.git","mount":"/workspace/lib"}}
```

```elixir
# BEAM — two Ports, two worktree roots
:ok = AgentOS.ControlPlane.attach_git(id, executable: path, mount_path: "/workspace/a", root: root_a, connections: conns)
:ok = AgentOS.ControlPlane.attach_git(id, executable: path, mount_path: "/workspace/b", root: root_b, connections: conns)
# host_call "git" body: {"op":"clone","args":{"url":"…","mount":"/workspace/a"}}
```

#### Demux rules (`args.mount` / top-level `mount`)

| Request | Behaviour |
|---------|-----------|
| `args.mount` or top-level `mount` = registered path | Route to that engine / Port |
| Mount omitted, one engine only | That engine (JS single-engine path; BEAM sole attach) |
| Mount omitted, multi-engine | JS uses `defaultMount` (first `git.mounts` entry); BEAM prefers sole/first — **set mount explicitly** |
| Unknown mount path | Fail closed: `ok:false`, code 1, stderr `git: unknown mount …` — **no network dial** |
| Duplicate path attach | Fail closed (see above) |

Accept either form:

```json
{"op":"clone","args":{"url":"https://example.com/r.git","mount":"/workspace/a"}}
{"op":"clone","mount":"/workspace/b","args":{"url":"https://example.com/r.git"}}
```

#### Concurrency

| Scope | Rule |
|-------|------|
| Same mount | Remote orch FIFO / single-flight — peak concurrent transport ≤ 1 |
| Distinct mounts | Independent queues — remotes may overlap |
| Snapshot | Still blocked while **any** git remote host_call is inflight |

**Never** share one mutable engine or Port across mounts without demux. One engine map / one
`git_engines` table owns the path → engine lookup.

## Durability / dir reopen

Directory reopen, JS snapshot/fork rebind, and named durable roots via `durable_id` +
`AGENTOS_GIT_DURABLE_ROOT` are product-supported.

### JS — directory reopen (primary) + AGIT blob (transfer)

**Primary durable form** is a re-openable libgit2 worktree+ODB **directory**
(`HostDirDurable` / `OpfsDirDurable`). Checkpoint flushes that directory; a second open of the
same path sees the same HEAD + worktree files. **AGIT** (pack+refs envelope) remains the
**blob** transfer format for `MemoryDurable` / legacy `DiskDurable` / `OpfsDurable`.

| Piece | Behaviour |
|-------|-----------|
| `DurableKind` `directory` \| `blob` | Directory: `hostPath` / hydrate-dump; blob: AGIT save/load |
| `HostDirDurable` | Node host dir is the store; `hydrateToMemfs` / `dumpFromMemfs` + fsync |
| `OpfsDirDurable` | OPFS `agentos-git/{id}/work/` tree |
| `MemoryDurable` / `DiskDurable` / `OpfsDurable` | AGIT blob; process registry by id for Memory |
| `openDurable({ id, diskDir?, durableDir? })` | Prefer `HostDirDurable` when disk path set; else OPFS dir; else OPFS blob; else Memory |
| `durableIdForMount` / `safeDurablePathSegment` | Per-mount keys under a VM disk root |
| `GitEngine.load({ engine?, durableDir \| durable })` | Tar resolved if `engine` omitted; directory: bridge hydrates then `ge_open`; blob: AGIT rebind |

**Dir reopen (JS):**

| Store | Same id / path reopens | Survives process restart |
|-------|------------------------|--------------------------|
| `HostDirDurable` via `git.durable.diskDir` or `durableDir` | Yes — `{diskDir}/{safeId}/` worktree | Yes |
| `OpfsDirDurable` | Yes — OPFS work tree | Yes (browser OPFS) |
| AGIT blob (`DiskDurable` / `OpfsDurable`) | Yes — `snapshot.bin` | Yes |
| `MemoryDurable` | Yes within one JS process (instance registry) | **No** |

### JS — MCSN snapshot / restore / fork rebind

| Piece | Behaviour |
|-------|-----------|
| `CreateOptions.git.durable` | Opt-in `{ id?, diskDir? }`. Per-mount key = `durableIdForMount(id, path)` |
| `makeEmbedded` | Opens durable per mount; `GitEngine.load({ engine?, durableDir \| durable })`; `backend.bindGitEngines(...)` |
| `EmbeddedBackend.snapshot` / `pinBase` | `checkpointGitEngines()` before MCSN (empty/unborn skip export) |
| Restore / fork | `mc.restore` / `Vm.fork` — same `git.durable` → reopen id/path → directory hydrate or AGIT rebind |

```ts
const vm = await mc.create({
  git: {
    // Primary: re-openable host worktree dirs under diskDir.
    durable: { id: "agent-session-1", diskDir: "/var/lib/agentos/git-durable" },
  },
});
// vm.snapshot() / pinBase → checkpoint durable store (not MCSN ODB)
// mc.restore / fork with the same git.durable → reopen + rebind
```

Omit `git.durable` for empty engines on restore (MCSN never carries ODB).

### BEAM — Port worktree root (caller dir survives stop)

BEAM durability is the **on-disk Port root** (same class as `HostDirDurable`). Rebind is
re-`attach_git` / second `GitEngine.start` with the **same durable root**.

| Piece | Behaviour |
|-------|-----------|
| Default root | `System.tmp_dir!/agentos-git-<n>` with `temp_root?=true` → **deleted** on stop |
| Caller `:root` / `:durable_dir` | Absolute dir, durable → **never** deleted by the engine |
| `:durable_id` + `AGENTOS_GIT_DURABLE_ROOT` | `{base}/{safe_id}/{mount_slug}/` |
| `GitEngine.root/1` / `checkpoint/1` | Inspect path; fsync face (writes already on disk) |
| `attach_git(..., root: \| durable_dir: \| durable_id:)` | Forwards into `GitEngine.start` |

**Dir reopen (BEAM):** pass the **same absolute `root:` / `durable_dir:`** (or the same
`durable_id` under a configured base) on a new `GitEngine.start` / `attach_git` after stop.

### Snapshot durability

Kernel MCSN does **not** include the host git ODB. Repo survival requires explicit
`git.durable` / `durableDir` (JS) or a preserved Port root (BEAM). Snapshot refused while any
git remote host_call is inflight. JS MCSN rebind uses the durable backend path.

## Submodules — host-mediated update

Network submodule update is **host orch only** — the engine never dials. List-only on the engine
is **not** sufficient for update; orch must fetch packs and materialize nested worktrees. Thin
CLI does **not** expose `submodule`.

### Engine surface (dial-free)

| Op | Behaviour |
|----|-----------|
| `list` / `status` / default | Parse `.gitmodules`; include gitlink hash when index has mode 160000 |
| `update` / `init` / `add` / `clone` via **engine.run** | **Fail closed** — requires host_call + orch |
| `gitlink` | Local-only stage mode 160000 (fixture/super setup; no network) |

### Host orch path (JS + BEAM)

```text
host_call "git" { op: "submodule", args: { action: "update" } }
  → orch: engine list .gitmodules (+ gitlink hash)
  → for each entry: same connection/origin policy on URL
  → ListRefs + FetchPacks (host HTTP only)
  → nested engine at super_root/<path> → init + import_pack + clone.apply
  → guest sees nested files via superproject gitfs (FS under super worktree)
```

| Host | Orch | Nested apply |
|------|------|--------------|
| **JS** | `remote-orchestrator.ts` `submodule()` | `bridge.openAt` same MEMFS |
| **BEAM** | `AgentOS.Git.Orchestrator` `submodule` | nested Port `root: super/path` |

Optional `args.path` updates a single submodule. Origin deny on the submodule URL fails closed
before dial (same policy as bare clone). Fixture: superproject `.gitmodules` + `gitlink` +
`minimal.pack` as submodule pack → nested `deps/lib/README` = `hello\n`.

### Multi-repo alternative

Sibling multi-mount clone remains valid for independent repos (no nested gitlink):

```text
attach /workspace/app  + host_call clone mount=/workspace/app
attach /workspace/lib  + host_call clone mount=/workspace/lib
```

## Metrics

In-process counters + last-op labels only (not Prometheus). Never store packs, tokens, or
credential material. Origins are **redacted** to `scheme://host[:port]` (no path, query, userinfo).

| Host | API | Counters / labels |
|------|-----|-------------------|
| **BEAM** | `AgentOS.Git.Metrics.snapshot/0` · `reset/0` · `inc/1` · `record_remote_result/3` · `observe_queue_depth/2` | `clone_*` / `fetch_*` / `push_*`, `port_eio`, `rpc_error`, `allowlist_deny`, `queue_depth_warn`; labels: `last_duration_ms`, `last_pack_bytes`, `last_origin_redacted`, `duration_ms_sum`, `pack_bytes_sum`, `queue_depth` (high-water) |
| **JS** | `snapshotGitCounters()` · `resetGitCounters()` · `recordRemoteResult(op, ok, meta?)` · `redactOrigin` | same ok/error counters + `allowlist_deny`; labels: `last_duration_ms`, `last_pack_bytes`, `last_origin_redacted`, sums |

Orch records ok/error + duration/bytes/origin after each remote op. Port death ticks `port_eio` on BEAM.

**Server alerts (`Logger.warning`):**
* origin allowlist deny → `git: allowlist deny origin=…` (+ `allowlist_deny` counter)
* per-mount remote queue depth > **32** → `git: mount queue depth N > 32 mount=…` (+ `queue_depth_warn`)

## Prod git-engine discovery

BEAM Port binary resolution (`AgentOS.GitEngine.discover_executable/0`), first regular file wins:

1. `AGENTOS_GIT_ENGINE` (tests / explicit override)
2. `Application.app_dir(:agent_os, "priv/git-engine")` (Mix + `mix release` priv)
3. `:code.priv_dir(:agent_os)/git-engine`
4. `$RELEASE_ROOT/priv/git-engine` and `$RELEASE_ROOT/lib/agent_os-*/priv/git-engine`
5. CWD `priv/git-engine` (path-dep / dev package layout)

Release packages stage the binary + libgit2 NOTICE under `priv/`.

## Pack cache (interactive remotes + LLB)

Content-addressed pack bytes only (keyed by sha256 of the pack). Download-key index is
public `url + wants + haves + depth + filter` — **never** credentials / userinfo / auth
headers. Same layout dual-host: Memory maps or Disk `{dir}/{sha256hex}.pack` +
`{dir}/keys/{sha256hex(key)}.key`.

### Product default (multi-tenant safer)

Product host_call handlers enable a pack cache by default, but **do not** use a
process-global shared cache unless opted in:

| Host | Product entry | Default (no env) | Shared opt-in |
|------|---------------|------------------|---------------|
| **JS** | `gitHostCallHandler` / `mc.create({ git })` | Fresh per-handler `MemoryPackCache` (`productDefaultPackCache`) | `MC_GIT_PACK_CACHE_SHARED=1` → process singleton (`defaultProcessPackCache`); Disk when `MC_GIT_PACK_CACHE` is also set |
| **BEAM** | VM `attach_git` host_call path (`pack_cache: :default`) | Fresh per-remote-Task Memory Agent (`product_default_cache/0`) | `AGENTOS_GIT_PACK_CACHE_SHARED=1` → process singleton (Disk when `AGENTOS_GIT_PACK_CACHE` is also set). Disk env alone does **not** enable product share (JS parity). |

Direct orchestrator construction (JS `new GitRemoteOrchestrator` / BEAM `Orchestrator.run`
without `:pack_cache`) leaves cache **off** unless the caller passes one. Pass `null` /
`false` / omit on product paths only when intentionally disabling.

**Multi-tenant:** must **not** set `*_PACK_CACHE_SHARED` or point `*_PACK_CACHE` at a
directory shared across tenants — pack digests are content-addressed public objects, but
download-key hits and cache residency must not cross tenant boundaries. Prefer the product
default (fresh Memory per handler / remote Task).

**Single-tenant / dedicated worker:** may set:

| Goal | JS | BEAM |
|------|----|------|
| Share Memory across remotes in one process | `MC_GIT_PACK_CACHE_SHARED=1` | `AGENTOS_GIT_PACK_CACHE_SHARED=1` |
| Durable on-disk CA cache (product path) | `MC_GIT_PACK_CACHE=/var/cache/…` **and** `MC_GIT_PACK_CACHE_SHARED=1` | `AGENTOS_GIT_PACK_CACHE=/var/cache/…` **and** `AGENTOS_GIT_PACK_CACHE_SHARED=1` |
| Explicit process singleton in code | `packCache: defaultProcessPackCache()` | `pack_cache: :process` / `:shared` or `PackCache.default_process_cache()` |
| Explicit dir | `new DiskPackCache(dir)` / `packCacheDir` | `pack_cache: {:disk, dir}` |

LLB / Node solve (`materializeLlbGit`, `nodeSolvePlatformWithEngine`) still use the process
singleton by default (`defaultProcessPackCache` — Memory, or Disk via `MC_GIT_PACK_CACHE`)
so repeated in-process solves share packs with interactive remotes when SHARED/disk is
configured for the product handler as well.

## Host git-engine.tar resolve (JS)

Product form is release **`git-engine.tar`** bytes (contains `git_engine.mjs` + `git_engine.wasm` +
notices). Parallel to `kernel` / `catalogCompiler`. Resolve order for
`mc.create({ git })` / `GitEngine.load` / `llb.git`:

1. Explicit `engine` bytes (create option or `GitEngine.load({ engine })`)
2. `MC_GIT_ENGINE_TAR` path
3. `$AGENTOS_DIR/git-engine.tar` or `$MC_ARTIFACT_HOME/git-engine.tar`
4. Host artifact cache (`MC_ARTIFACT_CACHE`, else XDG / `~/.cache/agentos/artifacts`)
5. Optional network fetch when `MC_ARTIFACT_FETCH=1` (versioned via `MC_ARTIFACT_VERSION` /
   `MC_ARTIFACT_SOURCE`)
6. Else **fail closed**

Materialize of the tar into a cache dir for emcc is **private** — there is no public `baseUrl`
create option. After `install.sh`, `source agent-os/env.sh` sets `AGENTOS_DIR` and
`MC_GIT_ENGINE_TAR`.

| Variable | Host | Meaning |
|----------|------|---------|
| `MC_GIT_ENGINE_TAR` | JS | Path to `git-engine.tar` |
| `AGENTOS_DIR` / `MC_ARTIFACT_HOME` | JS | Install root containing `git-engine.tar` (and other artifacts) |
| `MC_ARTIFACT_CACHE` | JS | Host artifact cache root (tar blobs + materialized engine dirs) |
| `MC_ARTIFACT_FETCH` | JS | `=1` / `true`: allow network fetch when local resolve misses |
| `MC_ARTIFACT_VERSION` | JS | Cache / fetch key version (default `local`) |
| `MC_ARTIFACT_SOURCE` | JS | Optional fetch base URL override |

## Env (Node solve / LLB + dual-host pack cache)

Default is **engine-first**. `llb.git` / `materializeLlbGit` require a resolved host emcc engine
unless the emergency escape hatch is set. **Only** `MC_GIT_USE_SYSTEM=1` (exact) enables ambient
system `git`; values like `true` / `0` / empty do **not**.

| Variable | Host | Meaning |
|----------|------|---------|
| `MC_GIT_ENGINE_TAR` | JS | Path to `git-engine.tar` (**required** for `llb.git` by default, or resolve via `AGENTOS_DIR` / cache / fetch) |
| `MC_GIT_PACK_CACHE` | JS | Optional on-disk pack cache dir (used by process singleton / LLB; with product handlers only when SHARED) |
| `MC_GIT_PACK_CACHE_SHARED` | JS | `=1` / `true`: product handlers use process-scoped pack cache (Memory or Disk) |
| `MC_GIT_USE_SYSTEM` | JS | **Emergency only** (`=1`): shell out to ambient system `git` |
| `AGENTOS_GIT_PACK_CACHE` | BEAM | Optional on-disk pack cache dir (mirrors `MC_GIT_PACK_CACHE`; single-tenant dedicated dir) |
| `AGENTOS_GIT_PACK_CACHE_SHARED` | BEAM | `=1` / `true`: product default uses process-scoped pack cache (mirrors `MC_GIT_PACK_CACHE_SHARED`) |

Without a resolved `git-engine.tar` and without `MC_GIT_USE_SYSTEM=1`, solve **fails closed**
(throws; does not silently use system git).

## Server load path

**Product server load is the BEAM-owned Port binary (`git-engine`).** The shared library
(`libgit_engine` `.so`) is packaging-only (license ship set, optional consumers) — **not** an
in-process product load path. JS hosts continue to use emcc wasm.

## Security rules

- Secrets never in guest, ctl body, or engine args — only host HTTP headers (JS or BEAM splice).
- Empty connection `origins` → fail closed.
- Ctl remotes refuse; remotes require `CAP_NET` + host_call name `"git"`.
- No Node/Bun process on the Elixir control plane for git.
- Surface is **advanced** (opt-in). Not multi-tenant default-on.
- Enable with `git: true` (omit = off).
- Stable stderr prefixes are catalogued in `fixtures/orch/response_schema.json`.

## Acceptance coverage

Enable with `git: true` or `git: { … }` (omit = off). API surface for `GitEngine` /
host_call / LLB git helpers is **advanced** (`docs/api-surface.json`). Not multi-tenant default-on.

Coverage spans connection/origin policy (empty origins fail closed; credential splice host-only),
dual-host pack e2e and push (including read-only reject with stable message), single-writer per
mount path, CAP_NET allow/deny, orch counters, and multi-mount remote demux.

| Area | Packages / tests |
|------|------------------|
| Dual-host orch goldens | `//memcontainers/sdk-js/core:git_orch_golden_test`; `AgentOS.Git.OrchGoldenTest` |
| Guest remotes + CAP_NET | `//memcontainers/sdk-js/core:git_guest_e2e_test`; `server/test/agent_os/git_guest_acceptance_test.exs` |
| Multi-mount demux | `//memcontainers/sdk-js/core:git_remote_test`; `AgentOS.Git.OrchestratorTest` |
| Engine durability | `git_engine.test.ts` (dir reopen, MemoryDurable); BEAM `git_engine_test.exs` |
| Submodule orch | `git_remote.test.ts`; `git_orchestrator_test.exs` |

## Implementation map

Internal module paths and Bazel targets for maintainers. Prefer the product sections above for
behaviour; this map is for navigation only.

### Key modules

| Area | Location |
|------|----------|
| JS durable stores | `memcontainers/sdk-js/core/src/git/durable.ts` |
| JS engine load | `memcontainers/sdk-js/core/src/git/engine.ts` |
| JS create / MCSN rebind | `types.ts`, `memcontainer.ts`, `embedded.ts` |
| BEAM Port | `server/lib/agent_os/git_engine.ex` |
| BEAM durable roots | `server/lib/agent_os/git/durable.ex` |
| BEAM attach | `server/lib/agent_os/vm.ex` |
| JS submodule orch | `remote-orchestrator.ts` |
| BEAM submodule orch | `AgentOS.Git.Orchestrator` |

### Bazel / server targets

- `//memcontainers/lib/git-engine:git_engine_wasm` — emcc module + NOTICE (ship filegroup)
- `//memcontainers/lib/git-engine:git_engine_wasm_size_limit` — ≤2 MiB on optimized `git_engine.wasm`
- `//memcontainers/lib/git-engine:git_engine_wasm_l5_notices` — fail-closed NOTICE/COPYING in wasm ship set
- `//memcontainers/lib/git-engine:git_engine_server_artifacts` — Port binary + `.so` + NOTICE/COPYING
- `//memcontainers/lib/git-engine:git_engine_server_l5_notices` — L5 gate on server ship set
- `//server:agent_os_git_engine_l5_notices` — L5 gate for package priv ship set
- `//memcontainers/lib/git-engine:git-engine` — native Port binary (dial-free)
- `//memcontainers/lib/git-engine:orch_algorithm_traces` — dual-host executable golden JSON
- `//memcontainers/programs/git:git` — thin guest CLI
- `//memcontainers/sdk-js/core:git_orch_golden_test` — TS golden runner
- Elixir: `AgentOS.GitEngine`, `AgentOS.Git.SmartHttp`, `AgentOS.Git.Orchestrator`
