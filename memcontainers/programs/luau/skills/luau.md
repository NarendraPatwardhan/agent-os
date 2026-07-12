---
name: memcontainer-luau
description: 'Write, run, debug, and validate Luau scripts and libraries inside memcontainers or from a host agent using a memcontainer VM. Use this skill whenever the task involves `/bin/luau`, `vm.luau`, `vm.luauSession`, `vm.shell({ language: "luau" })`, memcontainer syscalls, `sys.fs`, `sys.proc`, `sys.net`, `sys.host.call`, embedded Luau batteries, agent scripts, JSON tool calls, structured logs, or using Luau to manipulate files such as docx/xlsx/pptx inside the sandbox.'
---

# Memcontainer Luau

Luau is the in-VM agent scripting language for AgentOS. It runs as `/bin/luau`, ships embedded libraries, and sees the kernel through `sys`. The maintained sources are `SYSTEMS.md` section 10.3, `memcontainers/programs/luau/glue/lib/*`, `memcontainers/sdk-js/core/src/memcontainer.ts`, and `memcontainers/tests/e2e/src/loom.rs`.

## Execution Surfaces

From inside a VM, run scripts like ordinary commands:

```sh
/bin/luau script.luau
/bin/luau --check script.luau
```

From the TypeScript host surface, prefer:

```ts
await vm.luau("print(json.encode({ ok = true }))");
const session = vm.luauSession(); // alias for vm.session("luau")
const shell = vm.shell({ language: "luau" });
```

Use `vm.luau(src, args)` for batch scripts, `vm.luauSession()` for framed event streams, and the Luau shell for interactive investigation.

## System API

`sys` returns Lua-style `value, err` pairs. Check errors explicitly when the operation matters.

```lua
local bytes, err = sys.fs.read("/tmp/input.txt")
assert(bytes, err)

local ok, werr = sys.fs.write("/tmp/output.txt", bytes:upper())
assert(ok, werr)
```

Useful namespaces:

- `sys.fs`: read, write, open, close, seek, readdir, stat, mkdir, unlink, rename, symlink, link, chmod, truncate, cwd, and chdir.
- `sys.io`: stdin, stdout, stderr, write, lines, and tty checks.
- `sys.proc`: spawn, wait, run, pipe, dup, pid, ppid, nice, and exit.
- `sys.net`: fetch, get, and websocket access, gated by network capability.
- `sys.host.call`: JSON-marshaled calls to host-registered tools.
- `sys.time`, `sys.rand`, `sys.poll`, `sys.sig`, and `sys.ns` for clocks, entropy, event loops, signals, and per-process namespace work.

Capability failures should surface as in-VM errors such as `EPERM`; do not treat denied host capability as a crash.

## Embedded Libraries

Require embedded modules directly; they need no image staging:

```lua
local json = require("json")
local path = require("path")
local log = require("log")
local http = require("http")
local test = require("test")
```

Common libraries:

- Builtins and globals: `sys`, `json`, `path`, extended `string`, `table`, `os`, `math`, and `buffer`.
- Agent utilities: `url`, `time`, `http`, `log`, `test`, `hash`, `encoding`, and `deflate`.
- Office substrate: `xml`, `zip`, `opc`, `xform`, `units`, `color`, `media`, `chart`, and `calc`.
- Office formats: `docx`, `xlsx`, and `pptx`.

`require` resolves cache, then embedded modules, then VFS `package.path`. Embedded standard libraries win over files in the VFS, so do not try to override them by writing same-named files.

## Agent Script Pattern

Use structured logs when a Luau script is part of an agent session:

```lua
local log = require("log")

log.event({ type = "started", task = "build-report" })
-- do work
log.event({ type = "artifact", path = "/tmp/report.docx" })
```

Use `json` for host-tool payloads:

```lua
local result, err = sys.host.call("lookupCustomer", { id = "cust_123" })
assert(result, err)
```

Keep binary data as strings or `buffer` values depending on the library. The Office stack accepts byte strings for images and package bytes.

## Validation

Use the narrowest real gate that proves the behavior:

- Script type check: `/bin/luau --check script.luau`.
- Luau runtime behavior: `cargo test -p e2e --test luau`.
- Embedded library and Office behavior: `cargo test -p e2e --test luau_libs`.
- Full shell-visible behavior in memcontainers: `cargo xtask e2e`.

For document-producing scripts, validate the produced artifact with the relevant format library, `/bin/unzip -l`, and external real readers when available. Do not claim success from a script exit code alone when the deliverable is a file.

## Boundaries

- Luau runs inside the memcontainer kernel; it should not assume host paths, host file descriptors, or host processes exist.
- Network, persistence, ambient clock, entropy, and namespace effects are capability-gated.
- Use host-side JS/Python only when the user asks for a host workflow or when a real external validator is needed.
- For exact OOXML template preservation, use `opc` and `xml`; the high-level `docx`, `xlsx`, and `pptx` writers rebuild packages.
