# AgentOS Git — Host Source Plane

**Experimental** product surface for interactive and LLB git. Design of record: workspace-root
`GIT.md`. Tracker / gaps: `TASKS.md`, `CRITICAL_REVIEW.md`. Remotes are **not** GA.

## Thesis

Git is a **host source plane** (libgit2 + thin `ge_*` ABI). Guests see paths and a thin `/bin/git`;
the engine never dials the network. Remotes are host-mediated.

| Face | Path |
|------|------|
| SDK (JS) | `GitEngine.load` / `experimentalGitEngine` + `registerGitHostCall("git")` |
| gitfs | `asMountDriver()` → MountFs; local ctl at `/.git/mc/ctl` |
| Thin CLI | `//memcontainers/programs/git` — reduced surface only (see below) |
| Server engine | BEAM-owned C `git-engine` **Port** — local Run, pack apply, type-4 mount only |
| Server remotes | **BEAM HTTPS + Elixir orch** → Port apply (**no Node**, **no C TLS**) |
| LLB (Node) | Host emcc engine first (`MC_GIT_ENGINE_DIR`); **not** ambient system git |

## Thin CLI surface (honest)

`//memcontainers/programs/git` is a **reduced** pure-mc adapter — **not** full git-core. Unknown
commands fail closed.

| Class | Commands | Path |
|-------|----------|------|
| Local porcelain | `init`, `status`, `add <path>`, `commit -m …`, `log`, `rev-parse [rev]`, `branch` / `branch <name>`, `checkout <name>` | Discover `/.git/mc/ctl` under cwd parents; write Request JSON, re-open/read Response |
| Remotes | `clone <url>`, `fetch [url]`, `pull [url]`, `push [url]` | `host_call` name `"git"` (**CAP_NET**); clone works outside a repo |
| Meta | `version` / `--version`, `help` / `--help` | stdout/stderr only |

Not supported on the thin CLI (examples): `rm`, `diff`, `show`, `reset`, `tag`, `config`, `remote`,
`switch`, sparse, rebase, submodules, LFS, receive-pack. Use SDK / ctl ops where implemented, or
expect `unknown or unsupported command`.

## Server remotes (K16)

Same ownership cut as kernel HTTP egress: **BEAM dials HTTPS**; the guest and the Port child do not.

```text
guest host_call "git"
  → kernel CAP_NET
  → BEAM AgentOS.Git.Orchestrator
       ├─ smart-HTTP (OTP :httpc / ssl) + connection credential splice
       └─ Port frames → git-engine (import_pack, refs.import, clone.apply, …)
  → Response JSON
```

| Responsibility | Owner |
|----------------|--------|
| TLS, ListRefs, FetchPacks, PushPacks | **BEAM** (`AgentOS.Git.SmartHttp`) |
| Origin / connection policy | **BEAM** (connections catalog) |
| Pack import + apply + local porcelain | **C Port** (`AgentOS.GitEngine`) |
| JS browser/Node remotes | **TS** orch + emcc |

C `smart_http` / C orchestrator (Port type-5) are **test/fixture only** — not the product server
remote path. Dual-host product orch is **TS (JS) ↔ BEAM (server)** sharing apply-op + algorithm
semantics (K20), not “C orch on server”.

## Create options (JS)

Opt-in only; documented in [Create options](./create-options.md).

```ts
mc.create({
  experimentalGitEngine: true,
  gitEngineBaseUrl: new URL("./git-engine/", import.meta.url).href,
  // registers host_call "git", mounts gitfs at /workspace/repo
  connections: [{ ref: "github.user.work", auth: { kind: "bearer", token }, origins: ["https://github.com"] }],
});
```

## Env (Node solve / LLB)

Default is **engine-first**. `llb.git` / `materializeLlbGit` require the host emcc engine unless the
emergency escape hatch is set.

| Variable | Meaning |
|----------|---------|
| `MC_GIT_ENGINE_DIR` | Dir with `git_engine.mjs` + `git_engine.wasm` (**required** for `llb.git` by default) |
| `MC_GIT_ENGINE_BASE_URL` | Alternate URL form of the same dir |
| `MC_GIT_PACK_CACHE` | Optional on-disk pack cache dir |
| `MC_GIT_USE_SYSTEM` | **Emergency only** (`=1`): shell out to ambient system `git` |

Without `MC_GIT_ENGINE_DIR` / `MC_GIT_ENGINE_BASE_URL` and without `MC_GIT_USE_SYSTEM=1`, solve
**fails closed** (throws; does not silently use system git).

## c-shared / in-process load (K15)

`//memcontainers/lib/git-engine:libgit_engine` may produce a `.so` packaging artifact. The **product**
server load path remains the BEAM-owned **Port** binary (`git-engine`) for engine Run/apply/mount,
plus emcc wasm on JS hosts. In-process c-shared host load is **not** operationalized (PR7d open) —
not an “immediately after MVP” product path until that lands.

## Security rules

- Secrets never in guest, ctl body, or engine args — only host HTTP headers (JS or BEAM splice).
- Empty connection `origins` → fail closed.
- Ctl remotes refuse; remotes require `CAP_NET` + host_call name `"git"`.
- No Node/Bun process on the Elixir control plane for git.
- Do not treat remotes or the experimental flag as multi-tenant GA.

## Bazel / server targets

- `//memcontainers/lib/git-engine:git_engine_wasm` — emcc module + NOTICE (ship filegroup)
- `//memcontainers/lib/git-engine:git_engine_wasm_size_limit` — ≤2 MiB on optimized `git_engine.wasm`
- `//memcontainers/lib/git-engine:git_engine_wasm_l5_notices` — fail-closed NOTICE/COPYING in ship set
- `//memcontainers/lib/git-engine:git-engine` — native Port binary (dial-free)
- `//memcontainers/programs/git:git` — thin guest CLI
- Elixir: `AgentOS.GitEngine`, `AgentOS.Git.SmartHttp`, `AgentOS.Git.Orchestrator`
