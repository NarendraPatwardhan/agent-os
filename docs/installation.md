# Installation and imports

AgentOS can be consumed as a self-contained release bundle or through package imports. Both expose
the same `@mc/core` root API.

## Install release artifacts

The installer is served by the AgentOS site. In the commands below, `{domain}` means the origin of
the documentation you are reading; the web reference fills it in automatically.

It downloads `mc-core.mjs`, `kernel.wasm`, `catalog-compiler.wasm`, and one flavor tar:

```sh
curl -fsSL {domain}/install.sh | bash
```

For a non-interactive application install:

```sh
curl -fsSL {domain}/install.sh \
  | AGENTOS_MODE=embedded AGENTOS_IMAGE=loom AGENTOS_DIR=./agent-os bash
```

The standalone bundle has no npm dependency at runtime. It inlines the JavaScript host, generated
contracts, and Zod.

## Import the release bundle

```js
import { readFileSync } from "node:fs";
import { mc } from "./agent-os/mc-core.mjs";

const readBytes = (path) => new Uint8Array(readFileSync(path));

const vm = await mc.create({
  kernel: readBytes("./agent-os/kernel.wasm"),
  image: readBytes("./agent-os/loom.tar"),
});
```

This path is supported by Node.js 22+ and Bun. The runtime selector is `"local"` in both hosts;
`"bun"` is not a runtime name.

## Package imports

When AgentOS is provided as a package dependency, import the public API from `@mc/core`:

```js
import {
  mc,
  llb,
  tool,
  kit,
  z,
  MemoryContentStore,
} from "@mc/core";
import { hostDir, s3, vectorStore } from "@mc/core/drivers";
```

The release bundle contains the `@mc/core` root exports. Driver subpath imports require a package
distribution that includes `@mc/core/drivers`.

## Browser imports

The browser can import a bundled `@mc/core` or `@mc/elements` build. It must fetch artifacts itself:

```js
import { mc } from "@mc/core";

async function bytes(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`artifact ${url}: HTTP ${response.status}`);
  return new Uint8Array(await response.arrayBuffer());
}

const vm = await mc.create({
  runtime: "browser",
  kernel: await bytes("/mc/kernel.wasm"),
  image: await bytes("/mc/loom.tar"),
});
```

`@mc/elements` provides an artifact registry and is documented in
[Browser elements](./browser-elements.md).

## Runtime artifacts

| Artifact | Required when |
|---|---|
| `kernel.wasm` | Running `local` or `browser` without an environment default |
| Flavor tar | Booting an embedded VM from raw bytes |
| `catalog-compiler.wasm` | Compiling connection catalogs or adding host tools in a browser |
| `mc-core.mjs` | Using the standalone release SDK |

The catalog compiler is not guest code and is not part of an image. It is pure host-side WebAssembly
used to project API descriptions and tool definitions into the guest catalog.

## Default artifact loaders

`defaultKernel()` reads the path in `MC_KERNEL_WASM` and returns `Uint8Array`.
`defaultImage()` reads `MC_BASE_IMAGE`. They are used by local defaults and can be called directly:

```js
import { defaultImage, defaultKernel, mc } from "@mc/core";

const vm = await mc.create({
  kernel: await defaultKernel(),
  image: await defaultImage(),
});
```

The browser never consults process environment variables; pass bytes or use the element artifact
registry.

## Environment variables

| Variable | Consumer | Meaning |
|---|---|---|
| `MC_KERNEL_WASM` | `defaultKernel()` | Local path to `kernel.wasm` |
| `MC_BASE_IMAGE` | `defaultImage()` | Local path to the default image tar |
| `MC_CATALOG_COMPILER_WASM` | Catalog compilation | Local path to `catalog-compiler.wasm` |
| `MC_STORE` | `defaultStore()` | Root directory for the filesystem content store |
| `MC_BUILD_CACHE` | Node/Bun LLB platform | Root for persistent build cache mounts |

Explicit options take precedence over environment-backed defaults.

## Always close what you create

```js
const vm = await mc.create(options);
try {
  // Use the VM.
} finally {
  await vm.close();
}
```

This applies to restored and forked VMs too. A remote close disposes the remote VM; it is not merely a
client disconnect.
