# Concepts

AgentOS deliberately uses a small vocabulary. Understanding the distinctions on this page prevents
most lifecycle and security mistakes.

## VM

A VM is one running AgentOS computer. It has WebAssembly memory, a process table, a mounted
filesystem, resident services, an interactive shell, capability state, and an image contract. In
JavaScript it is represented by a `Vm` handle.

The handle is not the machine itself. A local handle owns an in-process kernel host. A remote handle
owns a connection to a server-side VM. Closing the handle disposes the resource it owns.

## Runtime

A runtime says where the kernel is hosted:

| Runtime | Kernel location | Artifact loading |
|---|---|---|
| `local` | Current Node.js or Bun process | Bytes or environment-backed local files |
| `browser` | Current browser page | Browser-fetched bytes or a browser content store |
| `remote` | Served AgentOS endpoint | Server-side image references |

The runtime changes hosting and transport, not the high-level `Vm` API. See the full
[runtime matrix](./runtimes.md).

## Image and flavor

An image is the initial guest filesystem plus a runtime contract. A flavor is a shipped, named image:

| Flavor | Adds | Typical use |
|---|---|---|
| `minimal` | Shell, core services, tools broker | Narrow custom harnesses |
| `posix` | Full coreutils command set | File and text automation |
| `loom` | Luau, analyzers, Office batteries, syntax parsing | Default programmable agent workspace |
| `atlas` | Warm SQLite and vector support over `loom` | Data and retrieval workflows |
| `paper` | Warm Typst and fonts over `loom` | Documents and PDFs |

Images are ordered stacks of content-addressed tar layers. A richer flavor reuses lower layers; it is
not a second kernel or a different client API.

## Layer

A layer is a portable tar diff identified by `sha256:<hex>`. `vm.commit().asLayer()` exports the VM's
mutable filesystem overlay. Layers contain filesystem changes, not running processes or warm service
memory.

Use a layer when the desired result is a reusable filesystem or image input.

## Snapshot

A snapshot is a versioned memory image of the entire VM: kernel state, processes, filesystem state,
resident service warmth, and the image contract. Full snapshots are self-contained. Incremental
snapshots contain pages changed from one full baseline and refer to that baseline by digest.

Use a snapshot when the desired result is resumable execution state.

## Attachment

An attachment is host-owned authority that cannot be serialized into guest memory:

- JavaScript tool handlers
- mount-driver objects
- connection credentials
- permission callbacks
- content-store handles

A snapshot preserves the guest-visible catalog and the guest state that referred to mounts, but it
cannot preserve the JavaScript resources behind either one. Restoration must supply the resources it
intends to use again. Strict restoration validates host-tool and connection entries in the restored
catalog by default; mounts and content-store availability remain explicit caller responsibilities. A
fork carries the source handle's current tools and mounts into a new VM, but it never reuses a remote
identity.

## Capability

A capability is authority granted to guest work. Network access, persistent storage, mounting, and
task tiers are explicit. The host control API remains the trusted operator view: `vm.fs.write()` can
stage an input even when an untrusted guest task is read-only.

Capabilities are narrower than images. An image answers “what programs exist?” A capability answers
“what may this task do?”

## Host tool

A host tool is discoverable and callable inside the VM, but its `run` function executes in the
embedding JavaScript process. The guest receives schemas and an address, not the closure or host
objects captured by it.

Tools are appropriate for application callbacks and narrow privileged operations.

## Connection

A connection describes a credential, its allowed origins, and the API specification that becomes a
tool catalog. Credentials stay at the host boundary. The guest sees a connection reference and tool
schemas; the host splices credentials into an approved outgoing request.

Connections are appropriate for OpenAPI, Microsoft Graph, Google Discovery, GraphQL, and remote MCP
integrations.

## Mount and driver

A mount exposes a host-backed filesystem at an absolute guest path. Its driver implements ordinary
file operations such as `open`, `stat`, and `readdir`. Agent code uses `cat`, `ls`, or `vm.fs`; it does
not receive an S3 client, host path, or vector-database handle.

Use a mount for data that naturally behaves like files. Use a connection for an API with operations.

## Resident service

A resident service is a long-lived program inside the VM, reached through `/svc/<name>`. It can keep a
SQLite connection, parser state, or font engine warm, and that warm state survives a snapshot.
`vm.serviceCall()` is the trusted host-control path to such a service.

## Content store

A content store maps digests and names to layers, arbitrary blobs, image manifests, and optional
snapshot objects. It is what makes named images, LLB caching, incremental snapshots, and portable
build provenance composable.

AgentOS provides memory, filesystem, and OPFS implementations. Applications can implement the same
contract for another durable store.

## Build state and definition

A build state is an in-memory handle to one node in an LLB build DAG. A build definition is the
canonical, portable serialization of that DAG. Definitions contain structured operations, not an
imperative JavaScript callback.

`llb` authors a graph, `record()` derives a graph from live VM operations, and `llb.commit()` solves a
graph into a layer, image, or warm snapshot.

## Determinism

`deterministic: true` replaces the guest's clock and random source with repeatable sources. It does
not make arbitrary network responses deterministic. LLB therefore refuses to cache networked exec
nodes as pure results, even when other inputs are pinned.
