<div align="center">
  <img src="./web/public/agent-os.svg" alt="AgentOS" width="270">

  <h1>AgentOS</h1>

  <p><strong>Give the agent its own computer.</strong></p>

  <p>
    A WebAssembly VM with a Unix shell, files, processes, pipes, resident services,
    snapshots, and a host-controlled capability boundary.
  </p>

  <p>
    <a href="https://deepwiki.com/NarendraPatwardhan/agent-os"><img alt="Docs: DeepWiki" src="https://img.shields.io/badge/docs-DeepWiki-111111"></a>
    <a href="./LICENSE"><img alt="License: BSL 1.1" src="https://img.shields.io/badge/license-BSL%201.1-f5c542"></a>
    <img alt="Runtime: WebAssembly" src="https://img.shields.io/badge/runtime-WebAssembly-654ff0">
    <img alt="Build: Bazel" src="https://img.shields.io/badge/build-Bazel-43a047">
    <img alt="SDK: JavaScript" src="https://img.shields.io/badge/SDK-Node.js%20%7C%20Bun%20%7C%20Browser-3178c6">
<!-- BEGIN generated:image-size-badges -->
    <br>
    <img alt="Image size: minimal 1.2 MiB" src="https://img.shields.io/static/v1?label=minimal&amp;message=1.2%20MiB&amp;color=2e7d32">
    <img alt="Image size: posix 2.2 MiB" src="https://img.shields.io/static/v1?label=posix&amp;message=2.2%20MiB&amp;color=2e7d32">
    <img alt="Image size: loom 6.2 MiB" src="https://img.shields.io/static/v1?label=loom&amp;message=6.2%20MiB&amp;color=d99a08">
    <img alt="Image size: atlas 7.2 MiB" src="https://img.shields.io/static/v1?label=atlas&amp;message=7.2%20MiB&amp;color=1565c0">
    <img alt="Image size: paper 35.9 MiB" src="https://img.shields.io/static/v1?label=paper&amp;message=35.9%20MiB&amp;color=1565c0">
<!-- END generated:image-size-badges -->
  </p>

  <p>
    <a href="#install">Install</a> ·
    <a href="#the-client-api">Client API</a> ·
    <a href="#tools-connections-and-mounts">Capabilities</a> ·
    <a href="#images">Images</a> ·
    <a href="#browser-embedding">Browser</a> ·
    <a href="#build-from-source">Build</a>
  </p>

  <p>
    <img src="./docs/agent-os-browser-vm.png" alt="AgentOS running a live shell in the browser" width="980">
  </p>
</div>

AgentOS is a contained computer for agent work, not a wrapper around the host shell. The guest gets
its own filesystem, process table, Unix tools, scripting environment, and warm services. The host
keeps control of network access, credentials, mounts, and tool implementations.

Use it to let an agent:

- inspect files and compose shell pipelines in an isolated workspace;
- write Luau programs that perform several tool calls without model round-trips;
- process data in a warm SQLite service or generate documents with Typst;
- access host functions and SaaS APIs without placing credentials in guest memory;
- snapshot a complete working machine and fork it into independent branches; and
- run the same `Vm` API locally, in a browser, or against a remote AgentOS host.

## Install

The installer downloads a self-contained JavaScript bundle, `kernel.wasm`,
`catalog-compiler.wasm`, and one image from the latest GitHub release:

```sh
curl -fsSL https://raw.githubusercontent.com/NarendraPatwardhan/agent-os/master/install.sh | bash
```

Interactive installation offers two modes:

- `agentic` installs the `loom` image and an AgentOS skill for coding agents;
- `embedded` installs runtime artifacts for an application and defaults to `posix`.

For a non-interactive application install:

```sh
curl -fsSL https://raw.githubusercontent.com/NarendraPatwardhan/agent-os/master/install.sh \
  | AGENTOS_MODE=embedded AGENTOS_IMAGE=loom AGENTOS_DIR=./agent-os bash
```

Node.js 22+ and Bun can load the same release bundle. Create `example.mjs` next to the installed
`agent-os/` directory:

```js
import { readFileSync } from "node:fs";
import { mc } from "./agent-os/mc-core.mjs";

const bytes = (path) => new Uint8Array(readFileSync(path));
const vm = await mc.create({
  kernel: bytes("./agent-os/kernel.wasm"),
  image: bytes("./agent-os/loom.tar"),
  deterministic: true,
});

try {
  await vm.fs.write("/workspace/input.txt", "paid\nfailed\npaid\n");
  const result = await vm.exec("sort /workspace/input.txt | uniq -c | sort -rn");
  if (result.exitCode !== 0) throw new Error(result.stderr);
  process.stdout.write(result.stdout);
} finally {
  await vm.close();
}
```

Run it with either host runtime:

```sh
node example.mjs
# or
bun example.mjs
```

Always close a VM in `finally`. An exit code describes the guest command; it does not release the
host-side run loop or any registered capabilities.

## The client API

`@mc/core` and the release `mc-core.mjs` bundle expose the same surface:

| API | Purpose |
|---|---|
| `mc.create(options)` | Boot a local, browser, or remote VM. |
| `mc.restore(snapshot, options)` | Resume a whole-VM snapshot with host capabilities reattached. |
| `mc.connect(endpoint, token).vm(id)` | Get or create a named VM through a served AgentOS endpoint. |
| `vm.exec(command, options)` | Run a shell command and receive stdout, stderr, bytes, and the real exit code. |
| `vm.luau(source, args)` | Run a Luau program from a `loom`, `atlas`, or `paper` image. |
| `vm.fs` | Read, write, list, stat, symlink/readlink, chmod, create, and remove guest paths. |
| `vm.shell()` | Open the byte-oriented interactive shell used by terminal clients. |
| `vm.tool()` / `vm.mount()` | Add host-resident tools or host-backed filesystems to a live VM. |
| `vm.snapshot()` / `vm.fork()` | Capture or branch the complete running machine. |
| `vm.commit().asLayer()` | Export the mutable filesystem overlay as a content-addressed tar layer. |
| `vm.status()` / `vm.close()` | Inspect and dispose the VM host lifecycle. |

`vm.exec` accepts `cwd`, `env`, and `stdin` and never hides command failure:

```js
const result = await vm.exec("sha256sum report.pdf", {
  cwd: "/work",
  env: { LC_ALL: "C" },
  stdin: "",
});

console.log(result.exitCode, result.stdout, result.stderr);
```

## Tools, connections, and mounts

AgentOS starts without ambient network, secrets, host directories, or application callbacks. Add
only the authority a workload needs.

### Host tools

A host tool is discoverable inside the VM, but its implementation stays in the embedding process.
Tool registration needs the catalog compiler downloaded by the installer:

```js
import { readFileSync } from "node:fs";
import { mc, tool, z } from "./agent-os/mc-core.mjs";

const bytes = (path) => new Uint8Array(readFileSync(path));
const customers = new Map([["acme", { name: "Acme", balance: 1250 }]]);

const vm = await mc.create({
  kernel: bytes("./agent-os/kernel.wasm"),
  image: bytes("./agent-os/loom.tar"),
  catalogCompiler: bytes("./agent-os/catalog-compiler.wasm"),
  tools: [
    tool({
      name: "customer lookup",
      description: "Find a customer by account id.",
      input: z.object({ accountId: z.string() }),
      run: ({ accountId }) => customers.get(accountId) ?? null,
    }),
  ],
});
```

The guest can discover and call that tool from the shell:

```sh
tools search customer
tools describe host.org.main.customer.lookup
tools call host.org.main.customer.lookup '{"accountId":"acme"}'
```

Or from Luau:

```lua
local tools = require("tools")
local result = tools.call("host.org.main.customer.lookup", { accountId = "acme" })
print(result.ok, result.data.name)
```

### API connections

Connections keep credentials and origin policy at the host boundary. `mc.use` is the concise path
for a curated integration:

```js
const vm = await mc.use("github.issues", process.env.GITHUB_TOKEN, {
  kernel,
  image,
  catalogCompiler,
});
```

For a custom OpenAPI, GraphQL, Microsoft Graph, Google Discovery, or remote MCP source, pass a
`connections` entry to `mc.create`. The guest catalog contains tool schemas and a connection
reference—not the credential itself.

### Host-backed filesystems

Local applications can expose a jailed directory, S3 prefix, vector search, or a custom driver as
ordinary guest files:

```js
import { hostDir, s3 } from "@mc/core/drivers";

const vm = await mc.create({
  kernel,
  image,
  mounts: [
    { path: "/mnt/work", driver: hostDir({ root: "./workspace" }) },
    { path: "/mnt/assets", driver: s3({ bucket: "acme-assets", readOnly: true }) },
  ],
});
```

Drivers run on the host and exchange bytes through the mount contract. The guest never receives a
host file descriptor, S3 client, or raw infrastructure handle.

## Images

Choose the smallest image that contains the workload:

| Image | Includes | Typical use |
|---|---|---|
| `minimal` | Shell, boot services, minimal core commands, tools broker | Small custom harnesses |
| `posix` | `minimal` plus the full coreutils command set | File and text automation |
| `loom` | `posix` plus Luau, `luau-analyze`, and Office batteries | Programmable agent work |
| `atlas` | `loom` plus the warm SQLite service | Data and retrieval workflows |
| `paper` | `loom` plus the warm Typst service and fonts | PDF and document generation |
| `syntax` | `loom` plus owned Lua/Luau parsers and the `syntax` library | Structural code inspection and safe edits |

Images are layered, capability-stamped build artifacts. Switching images changes guest userland; it
does not change the host API.

The `syntax` image exposes lossless concrete trees and transactional edits through Luau:

```luau
local syntax = require("syntax")
local doc = syntax.open("luau", "local function greet(name: string) return name end")

local names = syntax.compile_query(
  "luau",
  "(local_function_declaration name: (identifier) @name)"
)
for capture in doc:captures(names, { include_text = true }) do
  print(capture.name, capture.text)
end

doc:edit({{ start_byte = 15, old_end_byte = 20, replacement = "hello" }})
```

Grammars are AgentOS-authored and generated at build time; the guest ships only the generated parser
pack, the shared runtime, and the versioned service client.

## Browser embedding

The browser backend runs the same `kernel.wasm` in-process. Fetch and pass artifacts explicitly:

```ts
import { mc } from "@mc/core";

async function bytes(url: string): Promise<Uint8Array> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`failed to fetch ${url}: ${response.status}`);
  return new Uint8Array(await response.arrayBuffer());
}

const vm = await mc.create({
  runtime: "browser",
  kernel: await bytes("/mc/kernel.wasm"),
  image: await bytes("/mc/loom.tar"),
});
```

For UI embedding, `@mc/elements` owns artifact loading and VM lifecycle for `<mc-terminal>`,
`<mc-editor>`, and `<mc-sandbox>`. The repository web app uses this exact setup:

```ts
import { setArtifactSources } from "@mc/elements";
import "@mc/elements";

setArtifactSources({
  kernel: "/mc/kernel.wasm",
  images: { loom: "/mc/loom.tar", atlas: "/mc/atlas.tar" },
  catalogCompiler: "/mc/catalog-compiler.wasm",
});
```

```html
<mc-terminal image="loom" net label="agent · live in your browser"></mc-terminal>
```

See [`web/src/ExamplesShowcase.tsx`](./web/src/ExamplesShowcase.tsx) and
[`web/src/examples/chapters.ts`](./web/src/examples/chapters.ts) for executable examples of the
client API, tools, mounts, snapshots, builds, approval flows, and remote lifecycle.

## Snapshots and reproducible builds

`vm.snapshot()` captures the whole machine—processes, filesystem state, warm services, and linear
memory. `vm.fork()` restores that state into an independent VM, while `vm.commit().asLayer()` exports
only the mutable filesystem overlay:

```js
const snapshot = await vm.snapshot();
const fork = await vm.fork();
const { digest, tar } = await vm.commit().asLayer();
```

For applications with a content store, `mc.record()` captures live `vm.exec` and `vm.fs` mutations
as a portable `llb` definition. `llb` definitions are deterministic DAGs of VM filesystem and
execution steps; a cache hit can restore an already-warm snapshot rather than rebooting and replaying
setup. The browser workbench includes live examples of both authored and recorded builds.

## Build from source

All source artifacts come from Bazel. Build the release-style client set and a chosen image together:

```sh
bazel build \
  //memcontainers/kernel/rust:kernel \
  //memcontainers/images:syntax \
  //memcontainers/lib/catalog-compiler:wasm \
  //memcontainers/sdk-js/core:bundle
```

Outputs:

```text
bazel-bin/memcontainers/kernel/rust/kernel.wasm
bazel-bin/memcontainers/images/syntax.tar
bazel-bin/memcontainers/lib/catalog-compiler/catalog-compiler.wasm
bazel-bin/memcontainers/sdk-js/core/mc-core.mjs
```

Run the live browser workbench or produce its deployable bundle with the actual `web/` graph:

```sh
bazel run //web:dev
bazel build //web:app
```

Useful verification targets:

```sh
bazel test //memcontainers/sdk-js/core:vm_test
bazel test //memcontainers/tests/e2e:core
bazel test //memcontainers/tests/e2e:extended
bazel test //...
```

The repository architecture and invariants are maintained in [SYSTEMS.md](./SYSTEMS.md). Contract
bindings are generated from [`memcontainers/contracts`](./memcontainers/contracts/README.md); do not
hand-copy wire or ABI definitions into a consumer.
