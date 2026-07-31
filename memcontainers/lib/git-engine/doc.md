# Host git engine (GIT.md)

libgit2 + thin C `ge_*` Run ABI for AgentOS host source plane.

| Target | Role |
|--------|------|
| `:git_engine_lib` | Native static library (`ge_open` / `ge_run_json` / `ge_import_pack`) |
| `:git_engine_port_lib` | Port frames, binary MOUNT_OP, C smart-HTTP/orch (PR7–PR10c) |
| `:git-engine` | BEAM-owned Port binary (stdin/stdout length-prefixed frames) |
| `:libgit_engine` | `.so` packaging artifact only — product load path is Port + emcc (PR7d open) |
| `:port_smoke_test` | Run + mount ctl frames (PR7a/b) |
| `:abi_dual_test` | Native golden dual-runner (PR7c; emcc via sdk-js tests) |
| `:abi_fixture_test` | Local porcelain + dial refuse (PR1) |
| `:git_engine_wasm` | Emcc `createGitEngineModule` + monorepo `wasm_opt` + NOTICE (PR2) |
| `:git_engine_wasm_size_limit` | Soft gate ≤2 MiB on optimized `:git_engine.wasm` |
| `:git_engine_wasm_l5_notices` | L5 fail-closed: ship set includes NOTICE/COPYING/AUTHORS |
| `:smoke_test` | PR0 link smoke (libgit2 1.9.2) |

**Port wire** (`u32le length | u8 type | payload`):

| Type | Payload |
|------|---------|
| 1 | JSON Run request → JSON Response |
| 2 | pack chunk → i32 status |
| 3 | pack meta (u8 final) → i32 status |
| 4 | binary MOUNT_OP body → `[i32 status][payload]` |
| 5 | remote orch Request JSON → Response JSON |

**Load (JS):** prefer `git_engine.mjs` (ESM). Elixir: `AgentOS.GitEngine` Port owner; `handle_host_call/3` demuxes name `"git"` and gitfs mount path.

No gojs. No freestanding product path. Remotes are host-mediated (**TS orch on JS**, **BEAM orch on server**); C smart_http/orch is test/fixture only (Port type-5).
