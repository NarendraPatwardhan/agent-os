# `Vm`

`Vm` is the unified handle returned by `mc.create()`, `mc.restore()`, `mc.use()`, `mc.connect()`, and
`vm.fork()`. Obtain it through those factories; do not call its internal constructor.

## Properties

| Property | Shape | Meaning |
|---|---|---|
| `vm.fs` | filesystem object | Trusted host view of the guest filesystem |

Host attachments are deliberately not exposed as mutable option arrays. The VM privately tracks live
tools and mounts so a fork can reattach the current state without sharing caller-owned option objects.

## Complete method index

| Method | Result | Notes |
|---|---|---|
| `exec(command, options?)` | `Promise<ExecResult>` | Run a shell command to completion |
| `luau(source, args?)` | `Promise<ExecResult>` | Run a temporary Luau script |
| `serviceCall(name, request?)` | `Promise<Uint8Array>` | Call a resident service |
| `shell(options?)` | `Shell` | Open an interactive byte stream |
| `session(agentType?)` | `SessionHandle` | Open a framed agent session |
| `luauSession()` | `SessionHandle` | Alias for `session("luau")` |
| `cron(schedule, action, options?)` | `CronHandle` | Start a client-resident schedule |
| `tool(definitionOrList)` | `Promise<void>` | Add or replace live host tools |
| `mount(path, driver, options?)` | `Promise<void>` | Attach a host filesystem |
| `unmount(path)` | `Promise<void>` | Detach a host filesystem |
| `snapshot(options?)` | `Promise<Uint8Array>` | Capture full or incremental VM state |
| `fork()` | `Promise<Vm>` | Create an independent branch |
| `commit()` | selector object | Export a layer or snapshot |
| `status()` | `Promise<VmStatus>` | Read running/memory/egress status |
| `inflightEgress()` | `Promise<number>` | Count host-egress operations |
| `memoryBytes()` | number | Read WebAssembly memory size; remote returns `0` |
| `close()` | `Promise<void>` | Stop jobs and dispose the VM |

## Execution family

`exec`, `luau`, and `serviceCall` are covered with result shapes and error behavior in
[Execution and files](./execution-files.md). `shell`, `session`, and `luauSession` are covered in
[Shells, sessions, and services](./shells-sessions.md).

## `vm.tool(definitionOrList)`

Registers handlers in the host and atomically updates the live in-guest catalog. A matching name
replaces the previous definition. The promise resolves only after the catalog service accepts the new
index.

If catalog application fails, handler registration is rolled back to the previous definitions.
Successfully added tools are inherited by later forks. See [Host tools](./tools.md).

## `vm.mount(path, driver, options?)`

Attaches a driver and records it in the VM's private live attachment state. A later mount at the same
path replaces that recorded attachment.

```js
await vm.mount("/mnt/data", driver, { readOnly: true });
```

Remote mounts are relayed over the per-VM control socket; the JavaScript process must remain connected.
See [Mounts and drivers](./mounts-drivers.md).

## `vm.unmount(path)`

Removes the live mount and its fork attachment record:

```js
await vm.unmount("/mnt/data");
```

Unmounting does not close an application-owned driver object.

## `vm.snapshot(options?)`

```js
const full = await vm.snapshot();
const delta = await vm.snapshot({ mode: "incremental" });
```

Full is the default. Incremental requires content-addressed baseline storage. Snapshotting rejects
while host egress or a service call is in flight. See [Snapshots, restore, and fork](./snapshots.md).

## `vm.fork()`

Captures a full snapshot and restores it as a fresh independent VM with the source VM's current tools
and mounts. The source remains running.

On remote runtimes the fork always gets a different server identity, even when the source was created
with an explicit `id`.

The caller owns both handles and must close both.

## `vm.commit()`

Returns two output selectors:

```js
const { digest, tar } = await vm.commit().asLayer();
const snapshot = await vm.commit().asSnapshot();
```

`asLayer()` exports the mutable filesystem overlay. `asSnapshot()` is equivalent to a full
`vm.snapshot()`. See [Images and content stores](./images-stores.md).

## `vm.status()`

Returns:

| Field | Meaning |
|---|---|
| `running` | False after the embedded kernel exits; remote status is mapped from server state |
| `memoryBytes` | WebAssembly linear-memory bytes, or `0` when unavailable remotely |
| `inflightEgress` | Current host network/host-call/service operations |

Use `status()` when a consistent asynchronous status record is useful. The dedicated memory and
egress methods are convenient fast paths.

## `vm.inflightEgress()`

Returns the current egress count. A nonzero value explains why a snapshot would be unsafe: a host
handle or suspended service call cannot be serialized as guest memory.

## `vm.memoryBytes()`

Returns current WebAssembly linear-memory size synchronously. The remote backend returns `0`, which
means “not observable over this transport,” not “the VM has no memory.”

## `vm.close()`

Stops all cron handles created through this VM and disposes the backend. Embedded close stops the run
loop. Remote close sends VM disposal to the server.

Call it once in `finally`. Close is not a substitute for checking command results, and a successful
command is not a substitute for close.
