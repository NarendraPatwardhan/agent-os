# Runtime matrix

`mc.create()` accepts `runtime: "local" | "browser" | "remote"`. The returned `Vm` has the same
methods in all three cases, but hosting, artifact resolution, persistence, and ownership differ.

## At a glance

| Behavior | `local` | `browser` | `remote` |
|---|---|---|---|
| Default selector | Yes | No | No |
| Kernel location | Node/Bun process | Browser page | Served host |
| Raw kernel bytes | Accepted | Required | Not sent |
| Raw image tar | Accepted | Accepted | Rejected |
| Named image | Requires store | Requires browser store | Resolved by server |
| Host tools | In process | In page | Relayed over control WebSocket |
| Host mounts | In process | In page | Relayed over control WebSocket |
| `persist: true` | VM-lifetime memory | OPFS, IndexedDB fallback | Rejected by client contract |
| `memoryBytes()` | Measured | Measured | Returns `0` |
| Named VM identity | None | None | `id` or `mc.connect()` key |
| Full snapshot | Local bytes | Browser bytes | Server capture returned as bytes |
| Incremental snapshot | Caller store | Caller browser store | Server snapshot store |

## Local

`local` runs the JavaScript host and `kernel.wasm` in the current Node.js or Bun process. It is the
default when `runtime` is omitted.

```js
const vm = await mc.create({
  runtime: "local",
  kernel,
  image,
  deterministic: true,
});
```

If `kernel` or the default image is omitted, the SDK uses the environment-backed artifact loaders.
Named flavors and digest references need a [content store](./images-stores.md).

`persist: true` installs persistent-filesystem capability, but the local JavaScript implementation is
memory-backed for the lifetime of that VM. Use a content store, snapshot, or exported layer for durable
application state.

## Browser

`browser` uses the same embedded JavaScript host, but there is no host filesystem or process
environment from which to discover artifacts.

```js
const vm = await mc.create({
  runtime: "browser",
  kernel,
  image,
});
```

The core API requires `kernel` bytes. `image` must be raw bytes, `null`, or a reference resolvable by a
browser-readable content store. A bare `"base:latest"` is not enough because the browser has no default
base-file path.

When `persist: true`, `/var/persist` is backed by OPFS with an IndexedDB and then memory fallback.
`OpfsContentStore` separately stores image/build/snapshot objects in OPFS.

See [Browser elements](./browser-elements.md) for URL-based artifact loading and UI lifecycle.

## Remote

`remote` talks to a conforming served AgentOS endpoint over REST plus a per-VM WebSocket.

```js
const vm = await mc.create({
  runtime: "remote",
  endpoint: "https://agentos.example",
  token,
  image: "loom",
});
```

The client sends image names, layer digests, or manifest layer lists. It does not upload a raw image
tar through `mc.create()`. It may upload snapshot bytes when restoring.

`remote` requires an AgentOS endpoint that implements the HTTP and WebSocket control protocol.

Host tool handlers and mount drivers still run in the JavaScript client. The remote VM calls them over
the control socket, so those capabilities require the client process and connection to remain alive.
Credentials supplied in connection definitions are sent to the trusted server host, not into guest
memory.

`persist: true` is rejected: durable remote persistence is a server policy, not a client-side relay.

## `mc.connect()` versus `runtime: "remote"`

Both return a remote `Vm`.

- `mc.create({ runtime: "remote" })` creates a new server VM, optionally at an explicit destination
  `id`, and carries the full creation configuration.
- `mc.connect(endpoint, token).vm(key)` is the concise get-or-create path for a stable named VM.

Closing either handle sends remote disposal. If an application needs disconnect-without-dispose, that
must be a distinct server/client operation; `vm.close()` does not mean detach.

## Portability boundaries

Portable values include image manifests, layers, build definitions, and snapshots. Host attachments
are not portable values. When moving a snapshot between runtimes, supply the destination's kernel,
store, tools, mounts, credentials, and callbacks as required.

The same method name does not promise identical observability. For example, remote `memoryBytes()` is
`0` because remote status does not expose linear-memory size. The method remains present so
runtime selection does not force a different control flow.
