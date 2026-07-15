# Advanced API

This page documents supported extension seams for framework and infrastructure authors. It also names
root exports that are not part of the public client API so applications can avoid coupling to them.

## Availability levels

| Level     | Meaning                                                                        |
| --------- | ------------------------------------------------------------------------------ |
| Stable    | Supported client surface                                                       |
| Advanced  | Supported seam for infrastructure authors; requires deeper lifecycle knowledge |
| Internal  | Not public API; may change without notice                                      |
| Re-export | Same value documented at its owning package                                    |

## `Backend`

Advanced transport/host interface behind `Vm`. A backend implements command execution, filesystem
operations, snapshot/layer capture, status, tools, mounts, services, sessions, shell streaming, and
close.

Applications normally use `mc.create()`. Implement a backend only when adding a genuinely new hosting
topology while preserving the same VM semantics.

Important requirements:

- byte-safe stdout/stderr and filesystem transport;
- real exit codes;
- full snapshot validation and quiescence;
- atomic/rollback-safe tool registration at the `Vm` layer;
- mount-driver errno preservation;
- idempotent cleanup; and
- no host trap from malformed guest or remote input.

## `EmbeddedBackend`

Advanced adapter around the JavaScript `KernelHost`. `mc.create({ runtime: "local" | "browser" })`
constructs it with the correct clock, RNG, network, persistence, host-call, image, and snapshot state.

Direct construction bypasses validation and attachment orchestration. Prefer `mc.create()` unless
building SDK infrastructure.

## `RemoteBackend`

Advanced REST/WebSocket adapter. Its constructor accepts:

```js
{
  endpoint,
  token,
  vmId,
  onPermission,
}
```

It expects the VM already to exist. `mc.create()`, `mc.restore()`, and `mc.connect()` perform the
resource-creation step and then construct this adapter.

The backend reconnects its unified socket as needed, but client-resident tools and mounts still depend
on a live JavaScript process.

## `FanoutSink`

Advanced embedded-output sink. It retains output history and broadcasts new byte chunks to subscribed
stream sinks. It underpins the canonical shell/terminal model.

Use `vm.shell()` for application consumption. `FanoutSink` is useful only while constructing a custom
embedded backend.

## Artifact loaders

`defaultKernel()` and `defaultImage()` are stable local helpers documented in
[Installation and imports](./installation.md#default-artifact-loaders). They read the artifact path on
each call and return bytes.

## Catalog registry

`defaultCatalogCompiler()` is the stable registry/compiler loader. Its registry use is documented in
[Connections](./connections.md#catalog-compiler). The lower-level compiler instance also exposes
validation, policy, address, and compilation operations. Do not use those methods to mutate a live VM
around `vm.tool()`.

## `capabilityConnection`

Internal pure helper behind `mc.use()` that returns derived `connections` and `tools` arrays.

Clients should call `mc.use()`. Depending on this helper would promote its intermediate representation
into a public contract and would bypass the network/default-option behavior added by `mc.use()`.

## `startCron`

Internal scheduler constructor. Use `vm.cron()`, which tracks the handle and guarantees that
`vm.close()` stops it. Direct use can escape VM lifecycle ownership.

## `parseSchedule`

Advanced validator/parser. Its returned parsed-record shape is intentionally not a stable exported
type. It may be useful to reject configuration early, but `vm.cron()` already does that synchronously.

## `installContextRoot`

Internal browser hook called by `<mc-sandbox>`. Importing `@mc/elements` and using its components
installs the required context behavior automatically.

## Raw packages outside the client boundary

`@mc/host` exposes kernel-host construction, clocks, RNGs, network capabilities, persistence adapters,
catalog machinery, and raw host calls. `@mc/contracts` exposes generated ABI and wire descriptors.

They are implementation packages, not general client API. `@mc/core` is the boundary that coordinates
them and preserves runtime parity.

## Extending safely

Prefer the narrowest stable seam:

- application callback: `tool()`;
- host-backed data: `Driver` and `vm.mount()`;
- external API: connection definition;
- storage: `ContentStore`;
- UI integration: `VmHost` or custom elements;
- new hosting topology: `Backend` only when the preceding seams cannot express it.
