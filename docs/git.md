# AgentOS Git — Host Source Plane

Product surface for interactive and LLB git. Design of record: workspace-root `GIT.md`.

## Thesis

Git is a **host source plane** (libgit2 + thin `ge_*` ABI). Guests see paths and a thin `/bin/git`; the engine never dials the network. Remotes are host-mediated.

| Face | Path |
|------|------|
| SDK (JS) | `GitEngine.load` / `experimentalGitEngine` + `registerGitHostCall("git")` |
| gitfs | `asMountDriver()` → MountFs; local ctl at `/.git/mc/ctl` |
| Thin CLI | `//memcontainers/programs/git` — local → ctl; remote → `host_call git` (CAP_NET) |
| Server engine | BEAM-owned C `git-engine` Port — **local Run, pack apply, type-4 mount only** |
| Server remotes | **BEAM HTTPS + Elixir orch** → Port apply (**no Node**, **no C TLS**) |
| LLB (Node) | Host emcc engine (`MC_GIT_ENGINE_DIR`); **not** system git |

## Server remotes (K16 revised)

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
| JS browser/Node remotes | **TS** orch + emcc (unchanged) |

C fixture smart-HTTP remains for Port unit tests only — not the product server path.

## Create options (JS)

```ts
mc.create({
  experimentalGitEngine: true,
  gitEngineBaseUrl: new URL("./git-engine/", import.meta.url).href,
  // registers host_call "git", mounts gitfs at /workspace/repo
  connections: [{ ref: "github.user.work", auth: { kind: "bearer", token }, origins: ["https://github.com"] }],
});
```

## Env (Node solve)

| Variable | Meaning |
|----------|---------|
| `MC_GIT_ENGINE_DIR` | Dir with `git_engine.mjs` + `git_engine.wasm` (**required** for llb.git) |
| `MC_GIT_PACK_CACHE` | Optional on-disk pack cache dir |
| `MC_GIT_USE_SYSTEM` | Emergency only (`=1`): shell out to system `git` |

## Security rules

- Secrets never in guest, ctl body, or engine args — only host HTTP headers (JS or BEAM splice).
- Empty connection `origins` → fail closed.
- Ctl remotes refuse; remotes require `CAP_NET` + host_call name `"git"`.
- No Node/Bun process on the Elixir control plane for git.

## Bazel / server targets

- `//memcontainers/lib/git-engine:git_engine_wasm` — emcc module  
- `//memcontainers/lib/git-engine:git-engine` — native Port binary (dial-free)  
- `//memcontainers/programs/git:git` — thin guest CLI  
- Elixir: `AgentOS.GitEngine`, `AgentOS.Git.SmartHttp`, `AgentOS.Git.Orchestrator`
