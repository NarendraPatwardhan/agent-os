# Recording and remote builds

AgentOS supports two ways to obtain a portable build definition:

- author an LLB graph explicitly; or
- drive a live VM and record its mutations.

The resulting definition can be solved locally, in a browser with suitable platform hooks, or by a
conforming remote builder.

## `record(options?)` and `mc.record(options?)`

Both names call the same function.

```js
import { mc } from "@mc/core";

const recorder = await mc.record({
  image: "posix",
  store,
  deterministic: true,
});

try {
  await recorder.vm.fs.mkdir("/opt/app");
  await recorder.vm.fs.write("/opt/app/config.json", JSON.stringify(config));
  await recorder.vm.exec("chmod 600 /opt/app/config.json");

  const definition = await recorder.build();
} finally {
  await recorder.vm.close();
}
```

### What is recorded

| Operation                          | Recorded                                |
| ---------------------------------- | --------------------------------------- |
| `vm.fs.write`                      | yes                                     |
| `vm.fs.mkdir`                      | yes                                     |
| `vm.fs.rm`                         | yes                                     |
| `vm.fs.chmod`                      | yes                                     |
| `vm.fs.symlink`                    | yes                                     |
| `vm.exec`                          | yes                                     |
| filesystem reads/stat/list         | no; they do not mutate the build result |
| snapshots, tools, mounts, sessions | no                                      |

Operations still execute live. The caller sees real results and can make decisions, while the recorder
advances an immutable build-state tip.

### Restrictions

The starting image must be a replayable string reference. Recording rejects:

- inline image bytes or `null` images;
- host tools;
- host mounts;
- custom kernel bytes; and
- permission callbacks.

Those resources cannot be represented in the portable LLB grammar. Rejection is preferable
to returning a definition that silently omits them.

Network enablement and deterministic mode are translated into recorded exec options. Reads used to
decide later mutations are application control flow; only the resulting operations appear in the DAG.

## Recorder shape

| Member    | Meaning                                          |
| --------- | ------------------------------------------------ |
| `vm`      | Live `Vm` proxy with mutation recording          |
| `build()` | Resolve the current tip to a portable definition |

Calling `build()` does not close the VM and does not solve the definition. It snapshots the recorded
graph structure at that point.

## Replay

```js
const image = await llb.commit(definition).asImage({ store, kernel });

const vm = await mc.create({ image, store, kernel });
```

Definitions with out-of-line write blobs need the store that owns those blobs or a store to which they
have been copied.

## `remoteBuild(input, options)`

Sends a build state or definition to a conforming AgentOS build endpoint.

```js
const result = await remoteBuild(definition, {
  endpoint: "https://agentos.example",
  token,
  store,
});
```

### Options

| Field      | Required                   | Meaning                        |
| ---------- | -------------------------- | ------------------------------ |
| `endpoint` | yes                        | Served build API base URL      |
| `token`    | no                         | Bearer token                   |
| `store`    | for local definition blobs | Source of out-of-line payloads |

For a `BuildState`, the client first projects the graph into a canonical definition. For a prebuilt
definition, it finds every referenced payload blob. Missing blobs are uploaded to `/v1/blobs` from the
provided local store. The definition bytes are posted to `/v1/build`.

## Remote build result

| Field              | Meaning                                    |
| ------------------ | ------------------------------------------ |
| `definitionDigest` | Digest of the exact posted canonical bytes |
| `rootDigest`       | Canonical build-root digest                |
| `kernelDigest`     | Kernel artifact used by the server         |
| `manifestRef`      | Server name for the resulting image        |
| `image`            | Returned `ImageManifest` with provenance   |
| `layers`           | Result layer digest/size list              |

The client validates the response rather than trusting descriptive JSON. It checks definition bytes
and digest, digest formatting, manifest naming, root and kernel provenance, layer equality, and blob
references.

## Server requirement

`remoteBuild()` requires an AgentOS build endpoint that implements blob upload, blob reads, and remote
build execution.

## Security and portability

A definition describes filesystem and VM execution steps. Review untrusted definitions as executable
build input. The solver still enforces tiers, budgets, network declarations, path validation, and
artifact digests, but those controls do not turn untrusted build commands into inert data.
