# Snapshots, restore, and fork

A snapshot is a portable value representing a complete VM at a quiescent point. It contains guest
memory and guest-visible state, but never JavaScript closures, credentials, drivers, or live host
handles.

## Full snapshots

Full is the default and is self-contained:

```js
const snapshot = await vm.snapshot();
const same = await vm.commit().asSnapshot();
```

The value is a versioned `Uint8Array`. Hosts validate its magic, version, kind, memory length, scratch
layout, worker count, and bounds before using it.

Restore it with the kernel and required host attachments:

```js
const restored = await mc.restore(snapshot, {
  kernel,
  tools,
  mounts,
  connections,
});
```

The restored VM is a new handle. Closing the source does not close the restored VM and vice versa.

## Incremental snapshots

Incremental mode stores only memory pages changed from the VM's full baseline:

```js
const store = new MemoryContentStore();
const vm = await mc.create({ kernel, image, store });

const delta = await vm.snapshot({ mode: "incremental" });
const restored = await mc.restore(delta, { kernel, store });
```

The SDK stores the full baseline as a content-addressed snapshot object and writes its digest into the
delta. An incremental snapshot refers directly to one full object, never to another delta, so restore
work is bounded.

Requirements for embedded incremental capture and restore:

- the VM has a `ContentStore`;
- the store implements `putSnapshotObject()` and `snapshotObject()`; and
- the referenced full object moves with the delta when crossing stores.

Remote incremental snapshots use the server's snapshot-object store. Moving a delta to another server
also requires moving its named baseline.

## Quiescence

Snapshot capture refuses while host egress is in flight. This includes network operations, host calls,
and resident-service calls whose WebAssembly stack is suspended waiting for the host.

```js
if ((await vm.inflightEgress()) !== 0) {
  throw new Error("VM is not ready to snapshot");
}
const snapshot = await vm.snapshot();
```

The count is a diagnostic, not a lock. Capture performs its own authoritative check.

## Attachments

A snapshot can remember that a catalog entry or mount exists, but these values stay host-side:

- tool `run` functions;
- connection credentials;
- mount driver instances;
- permission callbacks;
- remote client transport state.

### Strict restore

Default behavior:

```js
const vm = await mc.restore(snapshot, {
  kernel,
  restoreAttachments: "strict",
  tools,
  connections,
  mounts,
});
```

If restored catalog entries require missing host-tool handlers or connections, restoration rejects
before returning the VM. This avoids a catalog that looks callable but fails only when an agent
eventually uses it.

Strict catalog validation does not prove that every other host resource is present. Re-supply mount
drivers for mounted paths that must remain usable, and supply a content store when an incremental
baseline or named image needs one. These resources are not inferred from snapshot bytes.

### Detached restore

```js
const inspectionVm = await mc.restore(snapshot, {
  kernel,
  restoreAttachments: "detached",
});
```

Use detached mode to inspect files or guest state when the original credentials/handlers are
deliberately unavailable. It does not remove catalog entries or make them callable.

## `vm.fork()`

Fork is snapshot plus restore with the VM's current attachments:

```js
const branch = await vm.fork();

await vm.fs.write("/workspace/choice", "left\n");
await branch.fs.write("/workspace/choice", "right\n");
```

Properties:

- the source keeps running;
- the fork starts from the same machine state;
- later mutations are independent;
- current tools and mounts are reattached;
- caller-owned create options are not mutated or shared as canonical state; and
- remote forks never reuse the source `id`.

`fork()` captures a full snapshot, prioritizing independent, portable branch semantics over a delta
tied to source storage.

## Named remote restore

An explicit remote id is a destination selector:

```js
const replaced = await mc.restore(snapshot, {
  runtime: "remote",
  endpoint,
  token,
  id: "tenant-acme",
});
```

This intentionally restores over that named server identity. `vm.fork()` omits the id and allocates a
new identity.

## Snapshot versus layer

| Need                                         | Use            |
| -------------------------------------------- | -------------- |
| Resume processes and warm services           | Snapshot       |
| Branch the running computer                  | Fork           |
| Reuse filesystem changes as an image input   | Layer          |
| Reproduce how the filesystem was constructed | LLB definition |

Layers and build definitions are covered in [Images and content stores](./images-stores.md) and
[LLB](./llb.md).

## Disposal

Every restore and fork returns an independently owned handle. Close every branch, including branches
created only for comparison or inspection.
