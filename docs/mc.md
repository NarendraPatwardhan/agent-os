# `mc`

`mc` is the supported entry point for obtaining a `Vm`. Do not construct `Vm` directly; its exported
class exists so values can be identified and typed, while its constructor is an internal backend seam.

```js
import { mc } from "@mc/core";
```

## Method summary

| Method | Result | Purpose |
|---|---|---|
| `mc.create(options?)` | `Promise<Vm>` | Create a fresh VM |
| `mc.restore(snapshot, options?)` | `Promise<Vm>` | Restore a full or incremental snapshot |
| `mc.use(capability, credential, options?)` | `Promise<Vm>` | Create a VM with one curated integration |
| `mc.connect(endpoint, token?).vm(key)` | `Promise<Vm>` | Get or create a named remote VM |
| `mc.record(options?)` | `Promise<Recorder>` | Drive a live VM while recording an LLB definition |

## `mc.create(options?)`

Creates and boots a fresh VM. The default runtime is `local`.

```js
const vm = await mc.create({
  kernel,
  image,
  deterministic: true,
});
```

The promise resolves only after the backend and boot catalog are ready. If construction fails after a
backend has been allocated, the SDK closes that partial backend before rejecting.

Options are copied before the first asynchronous operation. Reusing or later mutating the caller's
options object does not couple VMs together. Opaque resources such as content stores, driver objects,
callbacks, and large byte buffers remain referenced rather than deep-cloned.

See [Create options](./create-options.md) for every field and [Runtime matrix](./runtimes.md) for
runtime-specific restrictions.

## `mc.restore(snapshot, options?)`

Restores a snapshot into a new VM handle.

```js
const restored = await mc.restore(snapshot, {
  kernel,
  store,
  tools,
  mounts,
});
```

`snapshot` must be a `Uint8Array` containing the versioned AgentOS snapshot format. An incremental
snapshot also requires access to the full baseline object it names.

Restoration is strict about host attachments by default. If the snapshot's guest catalog refers to a
host tool or connection but the matching handler or credential is absent, the promise rejects instead
of returning a deceptively half-attached VM. Use `restoreAttachments: "detached"` only for
inspection-oriented recovery where calls are not expected to work.

On a remote runtime, an explicit `options.id` selects the destination VM to replace. Without it, the
server allocates a new identity.

See [Snapshots, restore, and fork](./snapshots.md).

## `mc.use(capability, credential, options?)`

Creates a VM with one or more tool groups from the same curated integration.

```js
const vm = await mc.use("github.issues", process.env.GITHUB_TOKEN, {
  kernel,
  image,
  catalogCompiler,
});
```

The capability format is `integration.group`. A list is accepted when every item shares one
integration:

```js
const vm = await mc.use(
  ["github.issues", "github.repositories"],
  { kind: "bearer", token },
  options,
);
```

The helper derives:

- connection ref `<integration>.org.main`;
- a connection auth record from the credential;
- tool selectors `<integration>/<group>`;
- `net: true` unless explicitly supplied; and
- `permissions.network: "allow"` unless overridden.

A string credential means bearer authentication. For header, query, anonymous, multiple-integration,
or custom-spec configurations, use `mc.create({ connections, tools })` instead.

See [Connections](./connections.md).

## `mc.connect(endpoint, token?).vm(key)`

Returns a small named-VM client. Calling `.vm(key)` POSTs a get-or-create request and returns a remote
`Vm` bound to the server's resulting id.

```js
const pool = mc.connect("https://agentos.example", token);
const tenantVm = await pool.vm("tenant-acme");
```

This path does not accept image, permissions, tools, or mounts at construction. Use remote
`mc.create()` when creation needs those options. Runtime tools and mounts may still be attached later
with `vm.tool()` and `vm.mount()` if the served host supports the control socket.

The returned handle owns remote disposal: `await tenantVm.close()` deletes the named VM.

## `mc.record(options?)`

This is the same function as the named `record` export. It creates a live VM and returns:

```js
const recorder = await mc.record({ image: "posix", store });
const vm = recorder.vm;

await vm.fs.write("/etc/app.conf", "mode=worker\n");
await vm.exec("mkdir -p /var/app");

const definition = await recorder.build();
await vm.close();
```

Mutating filesystem operations and `exec` are appended to an LLB graph while still running normally.
Reads are not recorded. See [Recording and remote builds](./recording-remote-build.md) for restrictions
and replay.

## Failures

All methods except `connect()` return promises and reject on configuration, artifact, transport, boot,
catalog, or attachment failure. `connect()` itself only creates a lightweight client; its `.vm()` call
performs network work and can reject.

Once a VM exists, guest command failure is represented by `ExecResult.exitCode`, not by rejection. See
[Errors and diagnostics](./errors.md).
