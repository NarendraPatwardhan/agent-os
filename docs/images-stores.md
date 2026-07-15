# Images and content stores

Images describe initial filesystem content and its runtime contract. Content stores make layers,
manifests, blobs, and snapshot objects addressable by digest or name.

## Image input forms

`mc.create({ image })` accepts:

| Value              | Meaning                                                    |
| ------------------ | ---------------------------------------------------------- |
| raw `Uint8Array`   | One tar layer                                              |
| flavor/name string | Manifest resolved through a content store or remote server |
| `sha256:<hex>`     | Diff layer stacked over the default embedded base          |
| image manifest     | Explicit ordered layer stack and config                    |
| `"base:latest"`    | Default embedded base image                                |
| `null`             | Empty in-memory root filesystem                            |

Raw tar bytes are embedded-only. Named and digest inputs require a store unless the remote server
resolves them.

## Image manifest

```js
const manifest = {
  schema: 1,
  layers: [
    { digest: baseDigest, size: baseSize },
    { digest: appDigest, size: appSize },
  ],
  config: {
    tier: "read-write",
    budgetMib: 256,
    fuel: 20_000_000,
  },
  created: new Date().toISOString(),
};
```

Layers are ordered lowest to highest. Each digest resolves to a tar object in the store.

### Runtime config

| Field       | Meaning                                          |
| ----------- | ------------------------------------------------ |
| `tier`      | `full`, `read-write`, `read-only`, or `isolated` |
| `budgetMib` | Per-guest memory ceiling                         |
| `fuel`      | Per-guest execution-fuel ceiling                 |

The config is enforced at boot; it is not descriptive metadata that a caller may ignore.

### Build record

LLB-built images may carry:

- canonical encoded definition bytes and digest;
- root build-node digest;
- kernel digest; and
- referenced layer/blob objects.

This lets another system verify how an image was produced without retaining the original JavaScript
`BuildState` object.

## Commit a live VM as a layer

```js
await vm.fs.write("/opt/app/config.json", JSON.stringify(config));
const { digest, tar } = await vm.commit().asLayer();
```

`digest` identifies `tar`. Store it before using the digest as an image input:

```js
const stored = await store.put(tar);
if (stored !== digest) throw new Error("layer digest mismatch");
```

The layer contains the mutable overlay since boot, including deletions encoded by the layer format. It
does not contain running process state.

## Content-store contract

Required layer/blob/manifest methods:

| Method                        | Meaning                                |
| ----------------------------- | -------------------------------------- |
| `layer(digest)`               | Read tar layer bytes                   |
| `put(tar)`                    | Store tar and return SHA-256 digest    |
| `blob(digest)`                | Read arbitrary content-addressed bytes |
| `putBlob(bytes)`              | Store arbitrary bytes                  |
| `manifest(name)`              | Read named image manifest              |
| `putManifest(name, manifest)` | Store named manifest                   |

Optional snapshot methods:

| Method                     | Meaning                                            |
| -------------------------- | -------------------------------------------------- |
| `snapshot(key)`            | Read LLB warm-snapshot memo, or `null`             |
| `putSnapshot(key, bytes)`  | Store LLB warm-snapshot memo                       |
| `snapshotObject(digest)`   | Read full snapshot object for an incremental delta |
| `putSnapshotObject(bytes)` | Store full snapshot by content digest              |

Custom stores should return owned bytes or otherwise prevent callers from mutating stored content.

## `MemoryContentStore`

In-memory implementation for short-lived applications, browser labs, and tests.

```js
const store = new MemoryContentStore();
```

It supports every store operation, including both snapshot families. Data disappears with the store
object/process.

## `FsContentStore`

Node/Bun filesystem implementation rooted at a directory:

```js
const store = new FsContentStore("./.agentos-store");
```

Layers, blobs, manifests, snapshot memos, and snapshot objects are stored under separated subtrees.
Digest and manifest-name validation occurs before path construction.

## `OpfsContentStore`

Browser Origin Private File System implementation:

```js
const store = await OpfsContentStore.open();
```

The static `open()` call obtains the browser storage root. The class supports the full store contract.
It is origin-scoped and subject to browser storage quotas and eviction policy.

## `defaultStore()`

Selects:

1. `FsContentStore(process.env.MC_STORE)` when the variable exists;
2. a lazily-opened OPFS store in a capable browser; or
3. throws if neither storage location is available.

```js
const store = defaultStore();
```

AgentOS does not assume a universal machine-level flavor-store path. Pass an explicit store when an
application owns storage placement.

## Digest and name rules

Content digests use lowercase `sha256:` plus exactly 64 hexadecimal characters. Manifest names accept
letters, digits, dot, underscore, and hyphen. Store implementations reject malformed values before
touching storage.

## Store ownership

VM and LLB operations borrow a store. They do not close or dispose it. A single application store may
serve several VMs and solves, providing cross-run cache reuse.

## Snapshot storage versus guest persistence

These are separate systems:

- `ContentStore` stores image/build/snapshot objects outside the VM.
- `persist: true` gives guest code durable semantics under `/var/persist` where supported.

Enabling one does not imply the other.
