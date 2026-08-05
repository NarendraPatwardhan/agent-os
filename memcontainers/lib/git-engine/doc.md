# Host git engine

libgit2 + thin C `ge_*` Run ABI for the AgentOS host source plane.
Product surface: `docs/git.md`. Architecture: `SYSTEMS.md` §11b.

| Target                          | Role                                                                      |
| ------------------------------- | ------------------------------------------------------------------------- |
| `:git_engine_lib`               | Native static library (`ge_open` / Run validation / local Run / pack I/O) |
| `:git_engine_port_lib`          | Port frames + binary MOUNT_OP                                             |
| `:git-engine`                   | BEAM-owned Port binary (stdin/stdout length-prefixed frames)              |
| `:libgit_engine`                | `.so` packaging artifact only — product load path is Port + emcc          |
| `:port_frame_test`              | Run + mount ctl frames + kill-closed                                      |
| `:abi_dual_test`                | Native golden dual-runner (emcc via sdk-js tests)                         |
| `:abi_fixture_test`             | Local porcelain + dial refuse                                             |
| `:git_engine_wasm`              | Emcc `createGitEngineModule` + monorepo `wasm_opt` + NOTICE               |
| `:git_engine_wasm_size_limit`   | Soft gate ≤2 MiB on optimized `:git_engine.wasm`                          |
| `:git_engine_wasm_l5_notices`   | Fail-closed: wasm ship set includes NOTICE/COPYING/AUTHORS                |
| `:git_engine_server_artifacts`  | Port binary + `.so` + NOTICE/COPYING                                      |
| `:git_engine_server_l5_notices` | Fail-closed: server ship set includes NOTICE/COPYING/AUTHORS + git-engine |

**Port wire** (`u32le length | u8 type | payload`):

| Type | Payload                                        |
| ---- | ---------------------------------------------- |
| 1    | JSON Run request → JSON Response               |
| 2    | pack chunk → i32 status                        |
| 3    | pack meta (u8 final) → i32 status              |
| 4    | binary MOUNT_OP body → `[i32 status][payload]` |
| 5    | abort incomplete pack import → i32 status      |

**Load (JS):** prefer `git_engine.mjs` (ESM). Elixir: `AgentOS.GitEngine` Port owner; demuxes name `"git"` and gitfs mount path.

Remotes are host-mediated: **TS orch (JS)** and **BEAM HTTPS orch (server)** → Port apply
(types 1–5).

### Large stdout

Embed limit **2 KiB** (`GE_STDOUT_MAX_BYTES`). Overflow requires a valid
`args.client_token` and returns `result.truncated=true` with
`result.stream_path=".git/mc/out/<client_token>"`; the complete body is written under the
worktree (cap **16 MiB**). Unscoped stream aliases do not exist.
Hosts: open that path via gitfs / Port mount, or JS `GitEngine.readStdoutStream`.

### Symlinks

Explicit `write` / `add` of a symlink or special file **fails closed**. `add all=true` **skips**
symlinks/specials. Never follows links for staging.

### log bounds

Default `max_count=10`, hard cap `GE_LOG_MAX_COUNT` (1000). When more commits remain,
`result.bounded=true` and a stable stdout footer `# log: bounded max_count=…`.
