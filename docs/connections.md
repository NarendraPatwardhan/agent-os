# Connections

Connections turn external API descriptions into guest-discoverable tools while keeping credentials at
the host boundary. A connection is not a network tunnel and does not copy its credential into guest
memory.

## Connection definition

```js
const github = {
  ref: "github.org.main",
  auth: { kind: "bearer", token: process.env.GITHUB_TOKEN },
  tools: ["issues"],
};
```

| Field     | Required  | Meaning                                            |
| --------- | --------- | -------------------------------------------------- |
| `ref`     | yes       | `integration.owner.name`; owner is `org` or `user` |
| `auth`    | yes       | Host-side authentication record                    |
| `origins` | sometimes | Absolute origins allowed to receive the credential |
| `spec`    | no        | Custom source or override for the API description  |
| `tools`   | no        | Per-connection tool groups                         |

For a curated integration, origins are derived from the registry's server list when omitted. Passing
origins narrows that list. A custom spec should declare origins explicitly.

## Authentication records

| Kind      | Shape                             | Effect                      |
| --------- | --------------------------------- | --------------------------- |
| Anonymous | `{ kind: "none" }`                | No credential attached      |
| Bearer    | `{ kind: "bearer", token }`       | `Authorization: Bearer ...` |
| Header    | `{ kind: "header", name, value }` | Custom request header       |
| Query     | `{ kind: "query", name, value }`  | Query parameter             |

Authentication is spliced after origin and policy checks. Guest code cannot choose a different
recipient for a registered credential.

## Curated capability with `mc.use()`

```js
const vm = await mc.use("github.issues", token, {
  kernel,
  image,
  catalogCompiler,
});
```

Use this when one credential covers one or more groups from the same integration. It derives a
standard connection and enables network access. See [`mc`](./mc.md#mc-use-capability-credential-options).

## Explicit connections

Use `mc.create()` for multiple integrations or custom configuration:

```js
const vm = await mc.create({
  kernel,
  image,
  catalogCompiler,
  net: true,
  connections: [
    {
      ref: "github.org.main",
      auth: { kind: "bearer", token: githubToken },
    },
    {
      ref: "weather.org.public",
      auth: { kind: "none" },
      origins: ["https://api.open-meteo.com"],
      spec: {
        url: "https://example.com/weather.openapi.yaml",
        format: "openapi",
        sourceFormat: "yaml",
      },
    },
  ],
  tools: ["github/issues", "weather/default"],
});
```

Top-level string entries in `tools` are catalog selectors, not host tool handlers.

## Spec sources

A custom source uses exactly one transport:

```js
{
  (bytes, format, sourceFormat, baseUrl, endpoint);
}
{
  (path, format, sourceFormat, baseUrl, endpoint);
}
{
  (url, format, sourceFormat, baseUrl, endpoint);
}
```

| Field          | Meaning                                           |
| -------------- | ------------------------------------------------- |
| `bytes`        | Already-acquired spec bytes                       |
| `path`         | Node/Bun client path; read by the JavaScript host |
| `url`          | Public or credential-authorized source URL        |
| `format`       | API family                                        |
| `sourceFormat` | `json` or `yaml` for textual specs                |
| `baseUrl`      | Override request server/base URL                  |
| `endpoint`     | Discovery endpoint for GraphQL or MCP             |

Supported formats are `openapi`, `microsoft-graph`, `google-discovery`, `graphql`, and `mcp-remote`.

Remote creation serializes bytes into the create request. A `path` is read by the JavaScript client,
not interpreted as a server filesystem path.

## Live discovery

GraphQL and remote MCP catalogs require host-side discovery:

- GraphQL sends an introspection query.
- Remote MCP performs initialize, initialized notification, and tool-list exchange while preserving
  the MCP session id and handling SSE responses.

Discovery occurs at the host boundary and is compiled into the same catalog representation as static
specifications.

## Catalog compiler

`defaultCatalogCompiler(wasmBytes?)` returns a memoized compiler instance.

```js
const compiler = await defaultCatalogCompiler(catalogCompilerBytes);
const integrations = await compiler.registryList();
const github = await compiler.registryResolve("github");
```

When bytes are provided, instances are cached by artifact digest. Without bytes, local Node/Bun reads
`MC_CATALOG_COMPILER_WASM`. Browser applications can pair `loadCatalogCompiler()` from `@mc/elements`
with this function.

The returned compiler also exposes lower-level validation and compilation operations. Registry listing
and resolution are the stable client use cases; manual catalog mutation should remain behind SDK
operations so catalog compare-and-swap and attachment checks are preserved.

## Registry entry

| Field           | Meaning                              |
| --------------- | ------------------------------------ |
| `id`            | Integration id                       |
| `name`          | Display name                         |
| `kind`          | Supported catalog format             |
| `url`           | Static spec URL, when used           |
| `endpoint`      | Live discovery endpoint, when used   |
| `defaultGroups` | Tool groups selected by default      |
| `groups`        | Named filters                        |
| `servers`       | Curated credential-recipient origins |

## Credential security

The guest catalog stores a connection reference, not the auth record. When an adapter request carries
that reference, the host:

1. resolves the connection;
2. validates the destination origin;
3. evaluates connection policy and approval;
4. attaches the credential; and
5. sends the request.

Direct network access does not gain connection credentials. A connection is therefore more than
`net: true` plus an environment variable.

## Restore

Connection credentials and discovery transports are attachments. Strict restore requires matching
connections for restored catalog entries. Detached restore can expose the catalog for inspection but
does not make absent credentials callable.
