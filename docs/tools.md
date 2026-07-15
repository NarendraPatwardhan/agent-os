# Host tools

A host tool is described inside the VM but implemented in JavaScript outside it. The guest receives a
catalog address and JSON schemas. The handler closure, application objects, and credentials captured by
that closure remain in the host.

Host tools are attachments. Reattach them when restoring a snapshot; a fork automatically carries the
source VM's current tool definitions.

## `tool(spec)`

`tool()` converts a Zod input schema into a `ToolDefinition` and validates input before calling the
handler.

```js
import { tool, z } from "@mc/core";

const lookupCustomer = tool({
  name: "customer lookup",
  description: "Find a customer by account id.",
  input: z.object({
    accountId: z.string(),
  }),
  output: {
    type: "object",
    properties: {
      name: { type: "string" },
      balance: { type: "number" },
    },
  },
  annotations: { read_only: true },
  async run({ accountId }, context) {
    const audit = await context.fs.readText("/workspace/request-id");
    return { name: accountId, balance: 1250, audit: audit.trim() };
  },
});
```

### Tool spec

| Field         | Required            | Meaning                                                                                            |
| ------------- | ------------------- | -------------------------------------------------------------------------------------------------- |
| `name`        | yes outside `kit()` | Host binding name; also used to derive the default address                                         |
| `description` | no                  | Human/model-facing description                                                                     |
| `input`       | no                  | Zod schema used for validation and JSON Schema projection; raw arguments pass through when omitted |
| `output`      | no                  | JSON Schema for the result                                                                         |
| `annotations` | no                  | Tool-plane metadata such as read-only or approval hints                                            |
| `address`     | no                  | Explicit full catalog address                                                                      |
| `run`         | yes                 | Host-side handler receiving parsed input and context                                               |

The default address is `host.org.main.<normalized-name>`. Whitespace and punctuation in a name become
dot-separated address parts.

If Zod validation fails, the handler is not called. A non-string return is JSON-encoded. A string is
returned as-is.

## `z`

The SDK re-exports Zod as `z` so a standalone `mc-core.mjs` consumer does not need a second runtime
copy solely to define tools.

Use the re-export associated with the SDK bundle:

```js
import { tool, z } from "./agent-os/mc-core.mjs";
```

## Raw `ToolDefinition`

Applications that already have JSON Schema may construct a definition directly:

```js
const definition = {
  name: "weather lookup",
  address: "host.org.main.weather.lookup",
  description: "Return current conditions.",
  input: {
    type: "object",
    properties: { city: { type: "string" } },
    required: ["city"],
  },
  async run(input, context) {
    return { city: input.city, condition: "sunny" };
  },
};
```

### Definition shape

| Field                 | Shape                                |
| --------------------- | ------------------------------------ |
| `name`                | nonempty safe binding string         |
| `address`             | optional catalog address             |
| `description`         | optional string                      |
| `input`               | optional JSON Schema object          |
| `output`              | optional JSON Schema object          |
| `annotations`         | optional JSON object                 |
| `run(input, context)` | sync or async JSON-compatible result |

Names may not begin with `/` or contain control characters. Leading `/` is reserved for raw
host-backed mount handlers.

## Tool context

The handler receives:

```js
{
  fs: vmFilesystemView,
}
```

`context.fs` has the same methods as `vm.fs`. It is useful when tool arguments name guest paths: the
tool can inspect an input or place its result inside the VM without exposing a host path.

## `kit(spec)`

Groups several definitions and returns an array suitable for `tools` or `vm.tool()`.

```js
const customerKit = kit({
  name: "customer",
  description: "Customer operations.",
  tools: {
    lookup: tool({
      name: "",
      input: z.object({ id: z.string() }),
      run: ({ id }) => ({ id }),
    }),
    disable: tool({
      name: "",
      input: z.object({ id: z.string() }),
      annotations: { requires_approval: true },
      run: ({ id }) => ({ disabled: id }),
    }),
  },
});
```

An empty subtool name becomes `<kit name> <object key>`. A subtool description falls back to the kit
description. `kit()` does not register anything; pass the returned list to a VM.

## Register at boot

```js
const vm = await mc.create({
  kernel,
  image,
  catalogCompiler,
  tools: [lookupCustomer, ...customerKit],
});
```

Tool handlers are installed before the VM is returned and the initial catalog is compiled
atomically.

## Register at runtime

```js
await vm.tool(lookupCustomer);
await vm.tool(customerKit);
```

The promise resolves after the live `/svc/tools` catalog accepts the update. Registering the same
binding name replaces that handler. If catalog application fails, the SDK restores prior handlers.

Embedded browser registration needs `catalog-compiler.wasm` supplied through create options or the
`@mc/elements` artifact registry.

## Guest discovery and invocation

From the guest shell:

```sh
tools list
tools describe host.org.main.customer.lookup
tools call host.org.main.customer.lookup '{"accountId":"acme"}'
```

From Luau, use the guest `tools` battery. That guest library is separate from the JavaScript
`tool()` builder documented here.

## Restore and fork

Snapshots contain the guest-visible catalog but not handlers. Strict restore requires definitions
that satisfy the restored catalog. Detached restore allows inspection but does not make missing calls
work.

`vm.fork()` uses the VM's current private registry, including tools added after boot. Mutating the
original create-options array later has no effect.
