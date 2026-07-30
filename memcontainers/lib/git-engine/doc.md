# Host git engine (GIT.md)

libgit2 + thin C `ge_*` Run ABI for AgentOS host source plane.

| Target | Role |
|--------|------|
| `:git_engine_lib` | Native static library (`ge_open` / `ge_run_json` / `ge_import_pack`) |
| `:libgit_engine` | Shared library packaging |
| `:abi_fixture_test` | Local porcelain + dial refuse (PR1) |
| `:git_engine_wasm` | Emcc `createGitEngineModule` + monorepo `wasm_opt` (PR2) |
| `:git_engine_wasm_size_limit` | Soft gate ≤2 MiB |
| `:smoke_test` | PR0 link smoke (libgit2 1.9.2) |

**Load (JS):**

```js
import createGitEngineModule from "./git_engine.js";
const Module = await createGitEngineModule({
  locateFile: (f) => /* map .wasm to git_engine.wasm or ship git_engine_wasm_bin.wasm */,
});
// Module._ge_open / _ge_run_json / Module.FS
```

No gojs. No freestanding product path. HTTPS/SSH backends off (host-mediated remotes).
