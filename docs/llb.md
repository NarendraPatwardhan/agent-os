# LLB build graph

`llb` constructs a content-addressed DAG of filesystem and execution operations. Nothing runs while
the graph is authored. Work begins when an output selector on `llb.commit()` is awaited.

```js
import { llb } from "@mc/core";

const base = llb.source("posix");
const configured = llb.write(base, "/etc/app.conf", "mode=worker\n");
const built = llb.exec(configured, "mkdir -p /var/app", {
  deterministic: true,
});

const image = await llb.commit(built).asImage({ store, kernel });
```

## Source nodes

### `llb.source(ref)`

References a flavor, built-image name, layer digest, or `base:latest`. HTTP URLs are rejected; use
`llb.http()` so network input and digest pinning are explicit.

### `llb.layer(digest)`

References exactly one known layer digest.

### `llb.local(path, options?)`

Archives a host build-context directory into `options.dest`, which defaults to `/`.

```js
const source = llb.local("./app", { dest: "/opt/app" });
```

Node/Bun uses the default solve platform. Browser or custom runtimes must provide a `SolvePlatform`
that resolves local sources.

### `llb.http(url, options)`

Fetches one artifact and writes it to the required absolute `options.dest` path.

```js
const source = llb.http("https://example.com/tool.wasm", {
  dest: "/opt/tool.wasm",
  sha256: expectedDigest,
});
```

`sha256` is optional but recommended. A mismatch rejects the solve. The fetched bytes participate in
the node's resolved identity.

### `llb.git(repo, options)`

Archives a git ref into `options.dest`, default `/`.

```js
const source = llb.git("https://github.com/acme/app.git", {
  ref: "0123456789abcdef",
  dest: "/src",
});
```

Pinned commits are cache-sound. Mutable branches are resolved during each solve and their resolved
commit becomes part of the cache key.

## Filesystem nodes

Every filesystem constructor returns a new `BuildState`; it does not mutate the input state.

| Function | Meaning |
|---|---|
| `llb.write(input, path, data)` | Create/truncate a text or byte file |
| `llb.mkdir(input, path)` | Create one directory |
| `llb.rm(input, path)` | Remove a file, symlink, or empty directory |
| `llb.chmod(input, path, mode)` | Set permission bits from `0` through `0o7777` |
| `llb.symlink(input, target, link)` | Create a symbolic link |

Large `write` payloads are stored as blobs when converting the graph to a portable definition.

## `llb.exec(input, command, options?)`

Runs a real VM command while solving.

```js
const compiled = llb.exec(source, "./configure && make install", {
  cwd: "/src",
  env: { PREFIX: "/opt/app" },
  stdin: "yes\n",
  tier: "read-write",
  budgetMib: 512,
  fuel: 100_000_000,
  deterministic: true,
  net: false,
  mounts: [llb.cache("/root/.cache")],
});
```

| Option | Default | Meaning |
|---|---|---|
| `cwd`, `env`, `stdin` | ordinary exec defaults | Included in node identity |
| `tier` | `read-write` | Build-step guest authority |
| `budgetMib` | image/kernel default | Guest memory limit |
| `fuel` | image/kernel default | Execution limit |
| `deterministic` | `true` | Repeatable clock/random source |
| `net` | `false` | Enable network and disable pure-result caching |
| `mounts` | `[]` | Persistent `llb.cache()` states |

A nonzero command exit rejects the solve with exit status and stderr.

## `llb.cache(path)`

Represents a host-backed persistent cache mounted at `path` for an exec node. Cache contents help the
command but are not copied into the output layer unless the command explicitly writes them elsewhere.

The default Node/Bun platform stores caches below `MC_BUILD_CACHE` or its platform temp default.

## Graph composition

### `llb.copy(destination, source, paths)`

Copies exact absolute paths between resolved states:

```js
const combined = llb.copy(runtime, build, [
  { from: "/out/app", to: "/usr/bin/app" },
  { from: "/out/assets", to: "/opt/app/assets" },
]);
```

At least one mapping is required. Parent traversal is rejected.

### `llb.merge(a, b)`

Stacks two resolved layer sets. Shared producer ancestry is deduplicated.

### `llb.diff(lower, upper)`

Produces what `upper` adds over `lower`. When ancestry is not directly subtractable, the solver
materializes both trees and commits their filesystem difference.

### `llb.image(parts, config?)`

Assembles ordered parts and an image runtime contract:

```js
const imageState = llb.image([base, app], {
  tier: "read-only",
  budgetMib: 256,
  fuel: 50_000_000,
});
```

## Portable definitions

### `llb.toDefinition(state, options?)`

Converts a `BuildState` DAG into the canonical versioned definition. `options.store` holds out-of-line
write blobs.

### `llb.fromDefinition(definition, options?)`

Validates and reconstructs a `BuildState`. It rejects unknown versions, invalid indexes, unused
fields, malformed modes, network URLs disguised as sources, and missing write blobs.

### `llb.encodeDefinition(definition)`

Returns canonical contract bytes.

### `llb.decodeDefinition(bytes)`

Decodes canonical bytes into a definition record. Use `fromDefinition()` or `commit()` to perform
semantic graph validation and solving.

## Output selectors

`llb.commit(stateOrDefinition)` returns:

### `asLayer(options?)`

Returns `{ digest, tar }` for the root node's produced layer.

### `asImage(options?)`

Returns an `ImageManifest` with build provenance and store references.

### `asSnapshot(options?)`

Builds an image, optionally performs warm-up directives, waits for zero in-flight egress, and captures
a full VM snapshot. Snapshot results may be memoized by node/warm/kernel identity.

## Solve options

| Field | Meaning |
|---|---|
| `store` | Layer/blob/manifest/snapshot storage; defaults to `defaultStore()` |
| `kernel` | Kernel bytes for VM-executing nodes |
| `warm` | Ordered exec/service warm-up directives before snapshot |
| `onProgress` | Sync or async structured progress callback |
| `platform` | Local/git/cache integration hooks |

Progress events are `started`, `cached`, `completed`, or `failed`, each carrying the node digest and
operation. Failed events also carry an error string.

Warm directives are either:

```js
{ kind: "exec", cmd, cwd, env, stdin }
{ kind: "svc", name, request }
```

## Cache model

Node identity includes resolved inputs, structured arguments, and the kernel digest for VM execution.
`cwd`, environment, stdin, budgets, tiers, and deterministic mode are not omitted from identity.

Networked exec nodes always rerun. A network response is external mutable state and cannot be treated
as a pure cached function merely because the guest clock is deterministic.
