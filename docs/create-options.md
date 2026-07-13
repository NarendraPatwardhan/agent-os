# Create options

The same options object configures `mc.create()`, `mc.restore()`, and—after excluding connection/tool
fields—`mc.use()`. Applicability and defaults vary by runtime.

## Complete field dictionary

| Field | Values | Default | Meaning |
|---|---|---|---|
| `runtime` | `"local"`, `"browser"`, `"remote"` | `"local"` | Where the kernel is hosted |
| `endpoint` | URL string | none | Required for `remote` |
| `id` | string | server allocated | Explicit remote create/restore destination |
| `token` | string | none | Bearer token sent to the remote endpoint |
| `image` | bytes, name, digest, manifest, or `null` | `"base:latest"` | Initial filesystem/image contract |
| `store` | content-store object | `defaultStore()` where possible | Resolves images, layers, blobs, and snapshot objects |
| `kernel` | `Uint8Array` | `defaultKernel()` locally | Embedded kernel bytes |
| `net` | boolean | `false` | Installs host network capability |
| `connections` | connection records | `[]` | Host credentials and API catalog sources |
| `catalogCompiler` | `Uint8Array` | environment-backed locally | Catalog compiler WebAssembly |
| `persist` | boolean | `false` | Enables `/var/persist` capability/backing |
| `permissions` | permission object | capability defaults | Guest filesystem and network policy |
| `policies` | policy rules | method classification | Connection egress policy |
| `onPermission` | callback | deny prompted operations | Interactive network/tool approval |
| `tools` | tool definitions or selectors | `[]` | Host handlers and connection tool groups |
| `restoreAttachments` | `"strict"`, `"detached"` | `"strict"` | Restore-time attachment validation |
| `mounts` | mount records | `[]` | Host-backed filesystems installed at boot |
| `deterministic` | boolean | `false` | Repeatable guest clock and random source |

## `runtime`

Only `local`, `browser`, and `remote` are accepted. Node.js and Bun both use `local`; the runtime name
describes hosting topology rather than the JavaScript executable.

See [Runtime matrix](./runtimes.md).

## `endpoint`, `id`, and `token`

These fields apply to `remote`.

- `endpoint` is required and is normalized without a trailing slash.
- `token`, when present, becomes the Bearer credential for REST and WebSocket requests.
- `id` selects a stable destination for explicit create or restore. It is intentionally removed by
  `vm.fork()`, so a fork cannot overwrite its source identity.

Secrets in `token` belong to the control-plane connection. API credentials belong in
`connections[].auth`; they have different recipients and policies.

## `image`

Accepted forms:

| Form | Interpretation |
|---|---|
| `Uint8Array` | One raw tar layer; embedded runtimes only |
| `"minimal"`, `"loom"`, etc. | Named manifest resolved by store or server |
| `"base:latest"` | Default embedded base image |
| `"sha256:..."` | One committed diff layer over the default base |
| image manifest object | Ordered layer stack plus runtime config |
| `null` | Empty in-memory root filesystem |

A browser cannot resolve the implicit default without bytes or a browser store. A remote create does
not upload raw tar bytes. See [Images and content stores](./images-stores.md).

## `store`

A store is required for named/digest images outside server-side resolution, LLB solves, and embedded
incremental snapshots. It is held by reference. The VM does not close an application-supplied store.

## `kernel`

Raw `kernel.wasm` bytes for embedded runtimes. Local calls may omit them if `MC_KERNEL_WASM` points to
the artifact. Browser calls must provide them. Remote calls do not send them because the server owns
its kernel.

## `net` and `permissions.network`

Network is enabled when any of these is true:

- `net: true`;
- at least one connection exists;
- `permissions.network` is `"allow"`; or
- `permissions.network` is an allowlist object.

`permissions.network: "deny"` wins over `net: true`. An allowlist object with no hosts enables the
network bridge but prompts for every host. See [Permissions and policy](./permissions.md).

## `connections`

Connection definitions contain a reference, auth record, optional origin narrowing, optional tool
groups, and an optional custom spec source. They are copied as values. Credential strings remain in
the host and are not written into the guest catalog.

Remote creation sends connection definitions to the trusted server host. See
[Connections](./connections.md).

## `catalogCompiler`

Catalog compiler WebAssembly bytes. Embedded host-tool and connection catalog creation needs this
artifact. Local execution can discover it through `MC_CATALOG_COMPILER_WASM`; browsers must register or
pass it explicitly.

## `persist`

Enables the guest persistence capability and `/var/persist` backing:

- browser: OPFS, then IndexedDB, then memory fallback;
- local JavaScript: VM-lifetime memory;
- remote: rejected because persistence must be a server policy.

This is separate from `ContentStore`, which stores images/build objects outside the guest filesystem.

## `permissions`

```js
const permissions = {
  fs: { allow: ["read"] },
  network: { allow: ["api.example.com"] },
};
```

Filesystem policy applies to guest-spawned work. Host control operations such as `vm.fs.write()` are
the trusted operator path. See [Permissions and policy](./permissions.md).

## `policies` and `onPermission`

Policies are connection-granular rules with owner, pattern, and action. `onPermission` receives either
a network request or a destructive connection-egress request and must call `allow()` or `reject()`.

Without a handler, operations classified as requiring approval are denied.

## `tools`

Entries are either:

- host `ToolDefinition` objects; or
- strings such as `"github/issues"` selecting connection tool groups.

The two forms may be mixed. See [Host tools](./tools.md) and [Connections](./connections.md).

## `restoreAttachments`

Only meaningful during restore:

- `strict`: reject if guest-visible catalog entries lack matching host attachments;
- `detached`: return an inspection VM even when those calls may fail.

Snapshots never serialize JavaScript closures or credentials.

## `mounts`

```js
const mounts = [
  { path: "/mnt/work", driver, readOnly: true },
];
```

`readOnly` defaults first to `driver.readOnly`, then `false`. Mount objects are privately copied, but
driver instances are retained by reference. See [Mounts and drivers](./mounts-drivers.md).

## `deterministic`

Pins guest-visible time and randomness to repeatable sources. It is intended for testing and pure
build steps. It does not cache or sanitize external network responses.
