# AgentOS Git — Host Source Plane

Product surface for interactive and LLB git (host source plane). Design of record: worktree
`GIT.md`. Create options: `gitEngine` (default `false`) + `gitEngineBaseUrl`. API surface:
**advanced** (opt-in; not multi-tenant default-on). Tracker: `TASKS.md`.

## Thesis

Git is a **host source plane** (libgit2 + thin `ge_*` ABI). Guests see paths and a thin `/bin/git`;
the engine never dials the network. Remotes are host-mediated.

| Face | Path |
|------|------|
| SDK (JS) | `GitEngine.load` / `gitEngine` + `registerGitHostCall("git")` |
| gitfs | `asMountDriver()` → MountFs; local ctl at `/.git/mc/ctl` |
| Thin CLI | `//memcontainers/programs/git` — reduced surface only (see below) |
| Server engine | BEAM-owned C `git-engine` **Port** — local Run, pack apply, type-4 mount only |
| Server remotes | **BEAM HTTPS + Elixir orch** → Port apply / pack.build (**no Node**, **no C TLS**); **fetch/clone/push** when not read-only |
| LLB (Node) | Host emcc engine first (`MC_GIT_ENGINE_DIR`); **not** ambient system git |

## Agent-facing constraints (product)

These are hard product rules for agents and tools that use host git — not optional polish.

| Constraint | Meaning |
|------------|---------|
| **One gitfs engine per mount path (K21)** | Multi-mount is allowed with **distinct** paths (R63). Each path owns its own engine (single-writer). Remounting gitfs at an already-live path fails closed. |
| **No `.git/objects` façade (v1)** | Guests do **not** get a synthetic `.git/objects` tree. Object DB stays host-side; worktree + ctl only. |
| **Unflushed ctl: close write before status** | Ctl Request is written to `/.git/mc/ctl`; Response is read from the out path. Close (or Drop) the write FD **before** reading status / next Response — unflushed guest buffers are invisible to the engine (same class as `hostDir`). |
| **Remotes need CAP_NET + host_call `git`** | Mount/ctl alone cannot dial. Guest remotes go through `mc_sys_host_call` name `"git"` gated by kernel **CAP_NET**. Ctl remote ops refuse. |
| **Opt-in flag + identity on commit** | Opt-in via `gitEngine` (JS; advanced surface). Commits need author identity (`name` / `email` args or engine defaults) — no ambient global gitconfig from the host user. |
| **Server push (not read-only)** | See [Server remotes](#server-remotes-k16--push-honesty) — packbuilder + receive-pack on BEAM when mount is not read-only. |

## Thin CLI surface (honest)

`//memcontainers/programs/git` is a **reduced** pure-mc adapter — **not** full git-core. Unknown
commands fail closed. Phase A maps argv → ctl Request JSON only (engine implements the ops).

| Class | Commands | Path |
|-------|----------|------|
| Local porcelain | `init`, `status`, `add <path…>` / `add -A`/`--all`, `rm <path…>`, `commit -m …`, `log`, `diff`, `show [rev]`, `rev-parse [rev]`, `branch` / `branch <name>` / `branch -d <name>`, `checkout`/`switch <name>`, `reset [--soft\|--mixed\|--hard] [rev]`, `tag [-d] <name>`, `config --list` or `config <key> [value]`, `remote` list/add/remove | Discover `/.git/mc/ctl` under cwd parents; write Request JSON, re-open/read Response (multi-path `add`/`rm` = one round-trip per path) |
| Remotes | `clone <url>`, `fetch [url]`, `pull [url]`, `push [url]` | `host_call` name `"git"` (**CAP_NET**); clone works outside a repo (no root discovery) |
| Meta | `version` / `--version`, `help` / `--help` | stdout/stderr only |

Not supported on the thin CLI (examples): sparse, rebase, submodules, LFS, receive-pack, full
git-config surface, annotated tags, path-limited diff, `reset` modes beyond soft/mixed/hard. Use
SDK / ctl ops where implemented, or expect `unknown or unsupported command`.

## Large stdout / stream path (D15)

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

## Symlink / special-file policy (D22)

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

## log / show bounds (D39)

| Op | Bounds | Signals |
|----|--------|---------|
| `log` | Default `max_count=10`; hard cap **1000** | `result.count`, `result.max_count`, `result.bounded`, optional `result.more`; stable stdout footer `# log: bounded max_count=N count=C more=true` when more commits exist (or request was clamped) |
| `show` | Full commit message (no silent fixed-buffer cut) | Oversized body uses **D15** truncated + `stream_path` |

## Server remotes (K16) + push honesty

Same ownership cut as kernel HTTP egress: **BEAM dials HTTPS**; the guest and the Port child do not.

```text
guest host_call "git"
  → kernel CAP_NET
  → BEAM AgentOS.Git.Orchestrator
       ├─ connection catalog resolve (PR11) + credential splice
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

### Product path: connection catalog (PR11)

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
  gitEngine: true,
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
**Thin-pack / haves (R48):** packbuilder hides lease old tips so shared history is omitted.
Connection origin policy, max pack size, and no-URL-credentials policy apply to push URLs the
same as fetch/clone. Secrets only in BEAM request headers.

### Monorepo materialization (M7 v1 / D13)

**Product path for large trees:** shallow clone + cone sparse — **not** partial-clone filter alone.

| Step | Behaviour |
|------|-----------|
| **Shallow default** | Product clone/fetch uses `depth=1` unless `args.depth` overrides (`depth<=0` = full history) |
| **Cone sparse** | JS `gitSparseCone` / `gitMounts[].sparseCone` / BEAM `attach_git(sparse_cone: …)` → orch after `clone.apply` runs engine `sparse-set` then `checkout` so the worktree only materializes cone prefixes |
| **gitfs / Port mount** | Guest sees the post-sparse worktree. JS gitfs also projects only cone prefixes (defense in depth). BEAM Port mounts the Port worktree root after sparse-set |

```text
clone (depth=1) → import_pack → refs.import → clone.apply
  → sparse-set(patterns) → checkout(HEAD)   # when cone configured
  → guest/gitfs sees cone paths only
```

**Out of this chunk (not the M7 v1 story):** full promisor remotes, on-demand lazy blob fetch,
missing-object re-fetch after `blob:none` / `tree:0`, and “filter wire only” without worktree
usability. Advertising `filter` on upload-pack is optional wire support — it does **not** replace
shallow + cone sparse for monorepo usability. Servers/fixtures that ignore filter still return a
full pack; the engine still materializes whatever objects arrived.

**Honest limits (cone-only):** multi-pattern prefixes + basic `!path` negation written into
`sparse-checkout` — **not** full git sparse-checkout pattern language. Prefer listing the
directories agents need (`["src", "docs"]`) rather than relying on filter or promisor.

### Partial clone filter (R36)

Clone/fetch accept optional `args.filter` (e.g. `blob:none`, `tree:0`). The host smart-HTTP
upload-pack request advertises the `filter` capability and sends a `filter <spec>` pkt-line.
**Limits:** the engine still materializes what the pack contains — there is no on-demand blob
promisor/fetch for missing objects yet. Servers or fixtures that ignore filter return a full pack
and continue to work. **Do not treat filter as monorepo materialization** — use
[shallow + cone sparse](#monorepo-materialization-m7-v1--d13) above.

C `smart_http` / C orchestrator (Port type-5) are **test/fixture only** — not the product server
remote path. Dual-host product orch is **TS (JS) ↔ BEAM (server)** sharing apply-op + algorithm
semantics (K20), not “C orch on server”.

### Executable golden orch vectors (K20 / P2.8 / D32)

Shared JSON under `memcontainers/lib/git-engine/testdata/orch/` (fixture copies:
`server/test/fixtures/git/orch/`; pack paths adjusted to `../minimal.pack` on the server side):

| File | Asserts |
|------|---------|
| `clone_success_steps.json` | fixture pack + tip → `ok:true`, stdout contains `cloned` |
| `shallow_clone_steps.json` | explicit `depth: 1` clone → `ok:true`, stdout contains `cloned` |
| `clone_empty_pack_fail.json` | empty pack → `ok:false`, stderr contains `empty pack` |
| `origin_denied.json` / `auth_deny_steps.json` | wrong allowlist → `ok:false`, stderr contains `not allowlisted` |
| `fetch_success_steps.json` / `pull_ff_steps.json` | fetch/pull success paths |
| `pull_not_ff_steps.json` | diverged local tip (setup init+commit) → pull fails `git: not fast-forward` |
| `push_readonly.json` / `push_success_steps.json` | RO reject + fixture push success |
| `response_schema.json` | D33 catalog: required Response keys + stable stderr prefixes |

Each vector lists logical algorithm steps plus an executable `orchestrator_response` step with
expected `ok` / substring checks. **Both** hosts run them:

- TS: `//memcontainers/sdk-js/core:git_orch_golden_test` (FixtureSmartHttp + wasm engine)
- BEAM: `AgentOS.Git.OrchGoldenTest` (fixture transport + Port)

Prose-only algorithm name lists without assertions are not sufficient.

## Create options (JS)

Opt-in only; documented in [Create options](./create-options.md).

```ts
mc.create({
  gitEngine: true,
  gitEngineBaseUrl: new URL("./git-engine/", import.meta.url).href,
  // registers host_call "git" (process pack cache default), mounts gitfs at /workspace/repo
  // optional cone sparse (multi-pattern; not full sparse language): gitSparseCone: ["src", "docs"],
  // multi-repo (R63–R65): gitMounts: [{ path: "/workspace/a" }, { path: "/workspace/b", sparseCone: ["src"] }],
  // remotes demux with args.mount / mount on host_call "git"
  connections: [{ ref: "github.user.work", auth: { kind: "bearer", token }, origins: ["https://github.com"] }],
});
```

### Multi-mount / `args.mount` (R63–R65 / D21)

Multi-repo is supported when each mount path owns its own engine (K21). Remotes on host_call
`"git"` demux to the engine for that path. Single-writer is **per mount**, not global: two mounts
may run remotes concurrently; two remotes on the **same** mount serialize.

#### Product setup

| Host | How to attach two engines | Default when `mount` omitted |
|------|---------------------------|------------------------------|
| **JS** | `mc.create({ gitEngine: true, gitMounts: [{ path: "/workspace/a" }, { path: "/workspace/b", sparseCone: ["src"] }], … })` | First `gitMounts` entry |
| **BEAM** | `ControlPlane.attach_git(id, mount_path: "/workspace/a", …)` then again with a **distinct** `mount_path: "/workspace/b"` | Sole engine if only one attached; otherwise first attached (prefer explicit `args.mount`) |

Same path while live fails closed: JS throws on duplicate `gitMounts` path; BEAM returns
`{:error, :git_already_attached}`. Detach one path with BEAM `detach_git(id, mount_path: …)`;
JS closes the VM (all engines).

```ts
// JS product create — two mounts, remotes demux by args.mount
const vm = await mc.create({
  gitEngine: true,
  gitEngineBaseUrl: new URL("./git-engine/", import.meta.url).href,
  gitMounts: [
    { path: "/workspace/app" },
    { path: "/workspace/lib", sparseCone: ["src"] },
  ],
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
| Mount omitted, multi-engine | JS uses `defaultMount` (first `gitMounts` entry); BEAM prefers sole/first — **set mount explicitly** |
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
| Same mount | Remote orch FIFO / single-flight (D2) — peak concurrent transport ≤ 1 |
| Distinct mounts | Independent queues — remotes may overlap (D21) |
| Snapshot | Still blocked while **any** git remote host_call is inflight (D19) |

**Never** share one mutable engine or Port across mounts without demux. One engine map / one
`git_engines` table owns the path → engine lookup.

#### Tests / proof

- **JS:** `//memcontainers/sdk-js/core:git_remote_test` — dual clone via `gitHostCallHandler` +
  `args.mount` with `minimal.pack` worktree isolation; concurrent two-engine clones.
- **BEAM:** `AgentOS.Git.OrchestratorTest` — `R65/D21 host_call args.mount two clones into two
  engines` (worktree README per root) + `D21 concurrent remotes on two mounts may overlap`.

## Product readiness (shipped)

Enable with `gitEngine: true` + `gitEngineBaseUrl` (default off). API surface for `GitEngine` /
host_call / LLB git helpers is **advanced** (`docs/api-surface.json`). Not multi-tenant default-on.

| # | Criterion | Status |
|---|-----------|--------|
| 1 | Origin / connection policy — empty origins fail closed; credential splice host-only | **Met** |
| 2 | Pack e2e both hosts (`minimal.pack` + dual-host goldens) | **Met** |
| 3 | Push packbuilder both hosts; RO rejects with stable message | **Met** |
| 4 | Single-writer per engine; one engine per mount path | **Met** |
| 5 | CAP_NET allow + deny e2e (JS + server guest) | **Met** |
| 6 | Orch/engine counters + allowlist/queue log alerts | **Met** |

## Full guest CAP_NET e2e (D25/D26)

- **JS (fixture):** **Met** under `//memcontainers/sdk-js/core:git_guest_e2e_test` — thin
  `/bin/git` on loom → kernel CAP_NET → host_call `"git"` → TS orch + FixtureSmartHttp +
  `minimal.pack` → `/workspace/repo` worktree; CAP_NET deny; gitfs ctl close-then-status.
  Inject transport via create options `gitHttp` / `gitAllowOrigins` (hermetic; not product egress).
- **Server:** **Met** — `server/test/agent_os/git_guest_acceptance_test.exs` D25 (full CAP_NET
  clone via `attach_git` + fixture dials ≥2 + worktree README) and D26 (no CAP_NET → deny, dials
  == 0).

## Durability / dir reopen (PR8 / D16–D18)

**D16** (directory reopen), **D17** (JS snapshot/fork rebind), and **D18** (named durable
roots via `durable_id` + `AGENTOS_GIT_DURABLE_ROOT`) are **DONE**.

### JS — directory reopen (primary) + AGIT blob (transfer)

**Primary durable form** is a re-openable libgit2 worktree+ODB **directory**
(`HostDirDurable` / `OpfsDirDurable`). Checkpoint flushes that directory; a second open of the
same path sees the same HEAD + worktree files. **AGIT** (pack+refs envelope) remains the
**blob** transfer format for `MemoryDurable` / legacy `DiskDurable` / `OpfsDurable`.

| Piece | Path | Behaviour |
|-------|------|-----------|
| `DurableKind` `directory` \| `blob` | `memcontainers/sdk-js/core/src/git/durable.ts` | Directory: `hostPath` / hydrate-dump; blob: AGIT save/load |
| `HostDirDurable` | same | Node host dir is the store; `hydrateToMemfs` / `dumpFromMemfs` + fsync |
| `OpfsDirDurable` | same | OPFS `agentos-git/{id}/work/` tree |
| `MemoryDurable` / `DiskDurable` / `OpfsDurable` | same | AGIT blob; process registry by id for Memory |
| `openDurable({ id, diskDir?, durableDir? })` | same | Prefer `HostDirDurable` when disk path set; else OPFS dir; else OPFS blob; else Memory |
| `durableIdForMount` / `safeDurablePathSegment` | same | Per-mount keys under a VM disk root |
| `GitEngine.load({ durableDir \| durable })` | `engine.ts` | Directory: bridge hydrates then `ge_open`; blob: AGIT rebind |
| Proof (blob) | `git_engine.test.ts` R52–R55 | MemoryDurable HEAD + worktree |
| Proof (dir reopen) | `git_engine.test.ts` D16 | `durableDir` → `.git` on host → second load same HEAD+files |
| Proof (snapshot rebind) | `git_guest_e2e.test.ts` phase D17 | snapshot → restore + fork |

**Dir reopen (JS):**

| Store | Same id / path reopens | Survives process restart |
|-------|------------------------|--------------------------|
| `HostDirDurable` via `gitDurable.diskDir` or `durableDir` | Yes — `{diskDir}/{safeId}/` worktree | Yes |
| `OpfsDirDurable` | Yes — OPFS work tree | Yes (browser OPFS) |
| AGIT blob (`DiskDurable` / `OpfsDurable`) | Yes — `snapshot.bin` | Yes |
| `MemoryDurable` | Yes within one JS process (instance registry) | **No** |

### JS — MCSN snapshot / restore / fork rebind (D17 / K10) — **DONE**

| Piece | Path | Behaviour |
|-------|------|-----------|
| `CreateOptions.gitDurable` | `types.ts` | Opt-in `{ id?, diskDir? }`. Per-mount key = `durableIdForMount(id, path)` |
| `makeEmbedded` | `memcontainer.ts` | Opens durable per mount; `GitEngine.load({ durableDir \| durable })`; `backend.bindGitEngines(...)` |
| `EmbeddedBackend.snapshot` / `pinBase` | `embedded.ts` | `checkpointGitEngines()` before MCSN (empty/unborn skip export) |
| Restore / fork | `mc.restore` / `Vm.fork` | Same `gitDurable` → reopen id/path → directory hydrate or AGIT rebind |
| Proof | `git_guest_e2e.test.ts` phase D17 | commit → snapshot → restore HEAD+worktree; fork rebind |

```ts
const vm = await mc.create({
  gitEngine: true,
  gitEngineBaseUrl: new URL("./git-engine/", import.meta.url).href,
  // Primary: re-openable host worktree dirs under diskDir (D16 path).
  gitDurable: { id: "agent-session-1", diskDir: "/var/lib/agentos/git-durable" },
});
// vm.snapshot() / pinBase → checkpoint durable store (not MCSN ODB)
// mc.restore / fork with the same gitDurable → reopen + rebind
```

Omit `gitDurable` for empty engines on restore (MCSN never carries ODB — A8).

### BEAM — Port worktree root (caller dir survives stop)

BEAM durability is the **on-disk Port root** (same class as `HostDirDurable`). Rebind is
re-`attach_git` / second `GitEngine.start` with the **same durable root**.

| Piece | Path | Behaviour |
|-------|------|-----------|
| Default root | `server/lib/agent_os/git_engine.ex` `init/1` | `System.tmp_dir!/agentos-git-<n>` with `temp_root?=true` → **deleted** on stop |
| Caller `:root` / `:durable_dir` | same + `AgentOS.Git.Durable` | Absolute dir, durable → **never** deleted by the engine |
| `:durable_id` + `AGENTOS_GIT_DURABLE_ROOT` | `server/lib/agent_os/git/durable.ex` | `{base}/{safe_id}/{mount_slug}/` (D18) |
| `GitEngine.root/1` / `checkpoint/1` | `git_engine.ex` | Inspect path; fsync face (writes already on disk) |
| `attach_git(..., root: \| durable_dir: \| durable_id:)` | `server/lib/agent_os/vm.ex` | Forwards into `GitEngine.start` |
| Proof | `server/test/agent_os/git_engine_test.exs` D16 | second Port same root → same HEAD+file; named durable_id under env |

**Dir reopen (BEAM):** pass the **same absolute `root:` / `durable_dir:`** (or the same
`durable_id` under a configured base) on a new `GitEngine.start` / `attach_git` after stop.

### Snapshot honesty (A8)

Kernel MCSN does **not** include the host git ODB. Repo survival requires explicit
`gitDurable` / `durableDir` (JS) or a preserved Port root (BEAM). Snapshot refused while any
git remote host_call is inflight (D19 **DONE**). JS MCSN rebind (D17 **DONE**).

## Submodules (D23–D24) — host-mediated update

**DONE (fixture class).** Network submodule update is **host orch only** — the engine never dials.
List-only on engine is **not** sufficient for D23/D24; orch must fetch packs and materialize nested
worktrees. Thin CLI does **not** expose `submodule`.

### Engine surface (dial-free)

| Op | Behaviour | Evidence |
|----|-----------|----------|
| `list` / `status` / default | Parse `.gitmodules`; include gitlink hash when index has mode 160000 | `engine_ops_extra.c` `op_submodule_list` |
| `update` / `init` / `add` / `clone` via **engine.run** | **Fail closed** — requires host_call + orch | `engine.c` |
| `gitlink` | Local-only stage mode 160000 (fixture/super setup; no network) | `op_gitlink` |

### Host orch path (JS + BEAM)

```text
host_call "git" { op: "submodule", args: { action: "update" } }
  → orch: engine list .gitmodules (+ gitlink hash)
  → for each entry: same connection/origin policy on URL
  → ListRefs + FetchPacks (host HTTP only)
  → nested engine at super_root/<path> → init + import_pack + clone.apply
  → guest sees nested files via superproject gitfs (FS under super worktree)
```

| Host | Orch | Nested apply | Proof |
|------|------|--------------|-------|
| **JS** | `remote-orchestrator.ts` `submodule()` | `bridge.openAt` same MEMFS | `git_remote.test.ts` D23–D24 |
| **BEAM** | `AgentOS.Git.Orchestrator` `submodule` | nested Port `root: super/path` | `git_orchestrator_test.exs` D23/D24 |

Optional `args.path` updates a single submodule. Origin deny on the submodule URL fails closed
before dial (same policy as bare clone). Fixture: superproject `.gitmodules` + `gitlink` +
`minimal.pack` as submodule pack → nested `deps/lib/README` = `hello\n`.

### Multi-repo alternative (DONE — D21)

Sibling multi-mount clone remains valid for independent repos (no nested gitlink):

```text
attach /workspace/app  + host_call clone mount=/workspace/app
attach /workspace/lib  + host_call clone mount=/workspace/lib
```
## Metrics (PR16 / D35–D36)

In-process counters + last-op labels only (not Prometheus). Never store packs, tokens, or
credential material. Origins are **redacted** to `scheme://host[:port]` (no path, query, userinfo).

| Host | API | Counters / labels |
|------|-----|-------------------|
| **BEAM** | `AgentOS.Git.Metrics.snapshot/0` · `reset/0` · `inc/1` · `record_remote_result/3` · `observe_queue_depth/2` | `clone_*` / `fetch_*` / `push_*`, `port_eio`, `rpc_error`, `allowlist_deny`, `queue_depth_warn`; labels: `last_duration_ms`, `last_pack_bytes`, `last_origin_redacted`, `duration_ms_sum`, `pack_bytes_sum`, `queue_depth` (high-water) |
| **JS** | `snapshotGitCounters()` · `resetGitCounters()` · `recordRemoteResult(op, ok, meta?)` · `redactOrigin` | same ok/error counters + `allowlist_deny`; labels: `last_duration_ms`, `last_pack_bytes`, `last_origin_redacted`, sums |

Orch records ok/error + duration/bytes/origin after each remote op. Port death ticks `port_eio` on BEAM.

**Server alerts (D36, `Logger.warning`):**
* origin allowlist deny → `git: allowlist deny origin=…` (+ `allowlist_deny` counter)
* per-mount remote queue depth > **32** → `git: mount queue depth N > 32 mount=…` (+ `queue_depth_warn`)

## Prod git-engine discovery (D38)

BEAM Port binary resolution (`AgentOS.GitEngine.discover_executable/0`), first regular file wins:

1. `AGENTOS_GIT_ENGINE` (tests / explicit override)
2. `Application.app_dir(:agent_os, "priv/git-engine")` (Mix + `mix release` priv)
3. `:code.priv_dir(:agent_os)/git-engine`
4. `$RELEASE_ROOT/priv/git-engine` and `$RELEASE_ROOT/lib/agent_os-*/priv/git-engine`
5. CWD `priv/git-engine` (path-dep / dev package layout)

Release packages stage the binary + libgit2 NOTICE under `priv/` (D37 L4).

## Env (Node solve / LLB)

Default is **engine-first**. `llb.git` / `materializeLlbGit` require the host emcc engine unless the
emergency escape hatch is set. **Only** `MC_GIT_USE_SYSTEM=1` (exact) enables ambient system `git`;
values like `true` / `0` / empty do **not**.

| Variable | Meaning |
|----------|---------|
| `MC_GIT_ENGINE_DIR` | Dir with `git_engine.mjs` + `git_engine.wasm` (**required** for `llb.git` by default) |
| `MC_GIT_ENGINE_BASE_URL` | Alternate URL form of the same dir |
| `MC_GIT_PACK_CACHE` | Optional on-disk pack cache dir (overrides process memory cache) |
| `MC_GIT_USE_SYSTEM` | **Emergency only** (`=1`): shell out to ambient system `git` |

Without `MC_GIT_ENGINE_DIR` / `MC_GIT_ENGINE_BASE_URL` and without `MC_GIT_USE_SYSTEM=1`, solve
**fails closed** (throws; does not silently use system git). Product `materializeLlbGit` /
`nodeSolvePlatformWithEngine` always plumb a **pack cache** by default (process `MemoryPackCache`,
or disk when `MC_GIT_PACK_CACHE` is set) so interactive remotes and LLB share the same CA pack path.

## c-shared / in-process load (K15 / R75) — **decided Port**

**Decision (closed):** product server load remains the BEAM-owned **Port** binary (`git-engine`).
`//memcontainers/lib/git-engine:libgit_engine` (`.so`) is **packaging-only** (license ship set,
optional consumers) — **not** an in-process product load path. PR7d is not a product load path
unless an explicit decision overturns Port. JS hosts continue to use emcc wasm.

## Security rules

- Secrets never in guest, ctl body, or engine args — only host HTTP headers (JS or BEAM splice).
- Empty connection `origins` → fail closed.
- Ctl remotes refuse; remotes require `CAP_NET` + host_call name `"git"`.
- No Node/Bun process on the Elixir control plane for git.
- Surface is **advanced** (opt-in). Not multi-tenant default-on.
- Enable with `gitEngine: true` (default false).
- Stable stderr prefixes are catalogued in `testdata/orch/response_schema.json` (D33).

## Bazel / server targets

- `//memcontainers/lib/git-engine:git_engine_wasm` — emcc module + NOTICE (ship filegroup)
- `//memcontainers/lib/git-engine:git_engine_wasm_size_limit` — ≤2 MiB on optimized `git_engine.wasm`
- `//memcontainers/lib/git-engine:git_engine_wasm_l5_notices` — fail-closed NOTICE/COPYING in wasm ship set
- `//memcontainers/lib/git-engine:git_engine_server_artifacts` — Port binary + `.so` + NOTICE/COPYING
- `//memcontainers/lib/git-engine:git_engine_server_l5_notices` — L5 gate on server ship set
- `//server:agent_os_git_engine_l5_notices` — L5 gate for package priv ship set (D37)
- `//memcontainers/lib/git-engine:git-engine` — native Port binary (dial-free)
- `//memcontainers/lib/git-engine:orch_algorithm_traces` — executable K20 golden JSON
- `//memcontainers/programs/git:git` — thin guest CLI
- `//memcontainers/sdk-js/core:git_orch_golden_test` — TS golden runner
- Elixir: `AgentOS.GitEngine`, `AgentOS.Git.SmartHttp`, `AgentOS.Git.Orchestrator`
