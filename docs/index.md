# Reference index

AgentOS gives an application a complete, isolated computer and exposes that computer through one
JavaScript API. The same `Vm` shape works when the WebAssembly kernel runs in Node.js, Bun, the
browser, or behind a remote AgentOS endpoint.

This reference is for looking things up. If AgentOS by Example answers “what can I build?”, these
pages answer “what does this method accept, return, retain, and require?” Every code sample is plain
JavaScript. TypeScript is optional and is not required to use the SDK.

These are end-user docs for the public JavaScript API. For architecture, implementation details, and
contributor documentation, see [AgentOS on DeepWiki](https://deepwiki.com/NarendraPatwardhan/agent-os).

## Start here

- [Concepts](./concepts.md) defines VM, image, snapshot, layer, attachment, tool, connection, mount,
  content store, and build definition.
- [Installation and imports](./installation.md) explains the release bundle, package imports,
  runtime artifacts, and environment variables.
- [Runtime matrix](./runtimes.md) compares `local`, `browser`, and `remote` without hiding their
  operational differences.
- [`mc`](./mc.md) covers creation, restoration, named remote VMs, capability sugar, and recording.
- [Create options](./create-options.md) is the field-by-field dictionary for `mc.create()` and
  `mc.restore()`.
- [`Vm`](./vm.md) is the index of every VM property and method.

## Core operations

- [Execution and files](./execution-files.md): `vm.exec()`, `vm.autocomplete()`, `vm.luau()`,
  `vm.serviceCall()`, and every `vm.fs` method.
- [Shells, sessions, and services](./shells-sessions.md): byte streams, interactive Luau, framed
  agent events, and resident-service calls.
- [Cron](./cron.md): client-resident schedules, actions, handles, and parser rules.

## Capabilities

- [Host tools](./tools.md): `tool()`, `kit()`, Zod schemas, `ToolDefinition`, and `ToolContext`.
- [Connections](./connections.md): credentials, specs, curated integrations, catalog compilation,
  GraphQL discovery, and remote MCP.
- [Permissions and policy](./permissions.md): network gating, allowlists, approvals, and policy
  precedence.
- [Mounts and drivers](./mounts-drivers.md): the custom driver contract plus `hostDir()`, `s3()`, and
  `vectorStore()`.

## State and builds

- [Snapshots, restore, and fork](./snapshots.md): full and incremental snapshots, attachment
  rehydration, identity, and quiescence.
- [Images and content stores](./images-stores.md): layers, manifests, runtime contracts, storage
  implementations, and digest rules.
- [LLB](./llb.md): every build-graph constructor, definition codec, solver option, cache rule, and
  output selector.
- [Recording and remote builds](./recording-remote-build.md): recording a live VM into an LLB
  definition and sending definitions to a served builder.

## Browser and advanced embedding

- [Browser elements](./browser-elements.md): artifact loading, `<mc-sandbox>`, `<mc-terminal>`,
  `<mc-xterm>`, `<mc-editor>`, events, methods, and CSS hooks.
- [Advanced API](./advanced-api.md): backend adapters, sinks, artifact loaders, the curated registry,
  and exports that are intentionally internal.
- [Errors and diagnostics](./errors.md): which failures throw, which return exit codes, how denials
  surface, and what to log.
- [Symbol index](./symbol-index.md): an alphabetical lookup across `@mc/core`, `@mc/core/drivers`,
  and `@mc/elements`.

## The API boundary

The supported client surface is `@mc/core`, its `@mc/core/drivers` subpath, and `@mc/elements`.
`@mc/host` and `@mc/contracts` are implementation packages. They are used to keep host behavior and
wire values single-source, but applications should not couple themselves to those packages.

The standalone release ships `mc-core.mjs` and runtime artifacts. Package and browser-element setup
is described on the relevant pages.

## One lifecycle rule

Always close a VM that you create or restore:

```js
const vm = await mc.create(options);
try {
  const result = await vm.exec("do-work");
  if (result.exitCode !== 0) throw new Error(result.stderr);
} finally {
  await vm.close();
}
```

An exit code ends a guest command. It does not stop the host run loop, release WebAssembly memory,
remove remote resources, unregister host callbacks, or stop cron jobs. `vm.close()` owns that job.
