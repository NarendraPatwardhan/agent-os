# AgentOS Git — Host Source Plane

Product surface for interactive and LLB git. Design of record: workspace-root `GIT.md`.

## Thesis

Git is a **host source plane** (libgit2 + thin `ge_*` ABI). Guests see paths and a thin `/bin/git`; the engine never dials the network. Remotes are host-mediated.

| Face | Path |
|------|------|
| SDK | `GitEngine.load` / `experimentalGitEngine` + `registerGitHostCall("git")` |
| gitfs | `asMountDriver()` → MountFs; local ctl at `/.git/mc/ctl` |
| Thin CLI | `//memcontainers/programs/git` — local → ctl; remote → `host_call git` (CAP_NET) |
| Server | BEAM-owned `git-engine` Port (`AgentOS.GitEngine` / `Vm.attach_git`) |
| LLB | `nodeSolvePlatform` → host engine (`MC_GIT_ENGINE_DIR`); **not** system git |

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

- Secrets never in guest, ctl body, or engine args — only host HTTP headers via connection splice.
- Empty connection `origins` → fail closed (no credential egress).
- Ctl remotes refuse; remotes require `CAP_NET` + host_call name `"git"`.
- Push: policy `block` / `require_approval`; read-only mounts reject.

## Bazel targets

- `//memcontainers/lib/git-engine:git_engine_wasm` — emcc module  
- `//memcontainers/lib/git-engine:git-engine` — native Port binary  
- `//memcontainers/programs/git:git` — thin guest CLI  
- Tests: `git_engine_test`, `git_remote_test`, `git_connections_test`, `git_push_test`, `git_pack_cache_test`
