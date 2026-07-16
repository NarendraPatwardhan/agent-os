# Sidecars

Sidecars are leased external resources owned by one AgentOS VM. They are appropriate when the useful
resource has its own state and lifecycle outside the guest—for example, a browser process or another
isolated machine. They are not tools: a tool is a host function, while a sidecar is an independently
created resource on which typed operations run.

The kernel sees only a grant name and a generated binary protocol. Provider references, endpoints,
credentials, and placement decisions remain in the host. Sidecar state is therefore not part of a VM
snapshot.

## Create-time attachments

`mc.create()` and `mc.restore()` accept two sidecar fields:

| Field          | Purpose                                                                    |
| -------------- | -------------------------------------------------------------------------- |
| `sidecarHosts` | Embedded-only map of private host aliases to `SidecarHost` implementations |
| `sidecars`     | Map of grant names to contract-bound grant descriptors                     |

Typed sidecar helpers may attach a guest layer on a fresh boot. Embedded `local` and `browser` VMs take
the layer bytes from the descriptor; remote VMs take only `guest: true` and let the served AgentOS host
install its configured copy. Host-only grants do not change the filesystem, duplicate layers are not
applied twice, and restores retain the filesystem already captured by the snapshot.

An embedded `local` or `browser` VM requires every descriptor to name a `host` alias. The alias is
resolved during attachment and never enters guest memory. A `remote` VM forbids `sidecarHosts` and
host aliases because its served AgentOS host owns provider placement.

A grant descriptor contains:

| Field                                                 | Meaning                              |
| ----------------------------------------------------- | ------------------------------------ |
| `contract.kind`                                       | Stable sidecar kind name             |
| `contract.version`                                    | Kind protocol version                |
| `contract.digest`                                     | Exact generated kind-contract digest |
| `grant.kind`, `grant.version`, `grant.contractDigest` | Must exactly match `contract`        |
| `grant.guest`                                         | Portable permission for guest calls  |
| `grant.maxInstances`                                  | Per-grant instance ceiling           |
| `grant.fork`                                          | Fork policy; currently `"omit"`      |
| `grant.config`                                        | Kind-defined configuration bytes     |
| `host`                                                | Embedded-only private host alias     |

Descriptors and byte arrays are copied into VM-owned attachment state. Typed helpers keep private guest
layer attachments outside the portable grant and snapshots. Mutating the caller's options after creation
does not change the live VM.

## `vm.sidecars`

Every `Vm` exposes one `VmSidecars` facade:

| Method                     | Result                         | Meaning                                              |
| -------------------------- | ------------------------------ | ---------------------------------------------------- |
| `capabilities()`           | `Promise<SidecarCapability[]>` | Discover kind/version/digest and provider limits     |
| `enable(name, descriptor)` | `Promise<void>`                | Add a validated grant                                |
| `disable(name, options?)`  | `Promise<void>`                | Remove a grant; `destroy` also removes its instances |
| `create(request)`          | `Promise<SidecarInstance>`     | Create one leased instance with an idempotency key   |
| `retrieve(id)`             | `Promise<SidecarInstance>`     | Refresh one instance                                 |
| `list(kind?)`              | `Promise<SidecarInstance[]>`   | List VM-owned instances                              |
| `invoke(request)`          | `Promise<Uint8Array>`          | Run one kind-defined operation                       |
| `delete(id)`               | `Promise<void>`                | Idempotently destroy one instance                    |
| `warnings()`               | warning array                  | Read retained non-fatal lifecycle warnings           |
| `onWarning(listener)`      | unsubscribe function           | Observe new warnings                                 |

Create and invoke requests carry a grant, kind, bounded binary body, and timeout. Calls additionally
carry the instance ID and generation, preventing a stale handle from addressing a replacement
resource. Kind packages should wrap this generic byte-level surface with their generated, typed API.

## Fork, snapshot, and close

`vm.fork()` closes sidecar admission, drains active operations, forks the AgentOS machine, and then
reopens admission. Current sidecars use the `omit` policy: the child receives the same portable grants
but no external instances, and the child VM reports structured `sidecar_fork_omitted` warnings.

Both full and incremental snapshots contain guest memory only. Restoring requires grants and hosts to
be supplied again through the normal create options. `vm.close()` closes the sidecar authority and
cascades best-effort cleanup; provider leases and reconciliation are the crash backstop.

## `SidecarError`

Sidecar lifecycle failures throw `SidecarError`. Its public fields are:

| Field       | Meaning                                                                    |
| ----------- | -------------------------------------------------------------------------- |
| `code`      | Stable contract code such as `sidecar_limit` or `sidecar_stale_generation` |
| `message`   | Human-readable explanation safe for the current API boundary               |
| `retryable` | Whether retrying may succeed without changing the request                  |
| `details`   | Optional kind-defined diagnostic bytes                                     |

Provider exceptions and private diagnostics are normalized before crossing into guest or client
code.

## `remoteSidecars(options)`

`remoteSidecars()` is the advanced connector for an embedded VM whose sidecar authority is served by
another AgentOS host. Options are:

| Field      | Meaning                                                |
| ---------- | ------------------------------------------------------ |
| `endpoint` | Base URL of the sidecar host                           |
| `token`    | Optional Bearer credential for creating a leased scope |
| `fetch`    | Optional Fetch-compatible transport implementation     |

Each host attachment creates a fresh scope. The connector renews its private scope credential and
closes the scope with the VM. Reusing the connector object does not share a scope, lease, or sidecar
identity between VMs.

Do not use this connector with `runtime: "remote"`: the remote VM's server already owns sidecar
placement and accepts only portable grants.
