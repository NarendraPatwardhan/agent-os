# Mounts and drivers

A mount makes host-backed data appear as ordinary guest files. The driver stays in JavaScript and is
called through the host-call bridge. The guest never receives the host resource itself.

## Mount at boot

```js
const vm = await mc.create({
  kernel,
  image,
  mounts: [{ path: "/mnt/data", driver, readOnly: true }],
});
```

## Mount at runtime

```js
await vm.mount("/mnt/data", driver, { readOnly: true });
await vm.unmount("/mnt/data");
```

Mount paths must be absolute; `/mnt/...` is the convention. `readOnly` defaults to
`driver.readOnly`, then `false`.

The VM records live mounts privately. A fork reattaches mounts present at fork time; a mount removed
with `unmount()` is not inherited. The driver object remains application-owned and is retained by
reference.

## Custom driver contract

Read operations are required:

| Method          | Result                     |
| --------------- | -------------------------- |
| `open(path)`    | Whole file as `Uint8Array` |
| `stat(path)`    | `{ kind: "file"            | "dir", size }` |
| `readdir(path)` | List of `{ name, kind }`   |

Write operations are optional:

| Method              | Meaning                          |
| ------------------- | -------------------------------- |
| `write(path, data)` | Create or truncate a file        |
| `mkdir(path)`       | Create one directory             |
| `unlink(path)`      | Remove a file or empty directory |
| `rename(from, to)`  | Rename within the mount          |

All paths are absolute relative to the mounted root: `/foo/bar`, not the guest's full
`/mnt/data/foo/bar` path.

```js
const files = new Map([["/hello.txt", new TextEncoder().encode("hello\n")]]);

const driver = {
  readOnly: true,
  async open(path) {
    const value = files.get(path);
    if (!value) throw Object.assign(new Error("missing"), { code: "ENOENT" });
    return value.slice();
  },
  async stat(path) {
    if (path === "/") return { kind: "dir", size: 0 };
    const value = files.get(path);
    if (!value) throw Object.assign(new Error("missing"), { code: "ENOENT" });
    return { kind: "file", size: value.length };
  },
  async readdir(path) {
    if (path !== "/") return [];
    return [{ name: "hello.txt", kind: "file" }];
  },
};
```

## Driver errors

Throw an `Error` with one of these `code` values to produce a specific guest errno:

| Code        | Meaning               |
| ----------- | --------------------- |
| `ENOENT`    | Missing path          |
| `EACCES`    | Access denied         |
| `EEXIST`    | Path already exists   |
| `ENOTDIR`   | Expected directory    |
| `EISDIR`    | Expected file         |
| `ENOTEMPTY` | Directory not empty   |
| `EINVAL`    | Invalid argument/path |

An uncoded exception maps to `EIO`. Do not expose cloud SDK errors or host filesystem paths directly
to untrusted guest code.

## `hostDir(options)`

Node/Bun-only driver backed by a jailed host directory.

```js
import { hostDir } from "@mc/core/drivers";

const driver = hostDir({
  root: "./workspace",
  readOnly: false,
});
```

The driver resolves every path under `root`, checks real paths, rejects traversal, and does not expose
symlink escapes. Node filesystem errors with supported codes are mapped to driver errors.

`hostDir` is unavailable in browsers. Use the package import in Node.js or Bun; the standalone
`mc-core.mjs` bundle does not expose it.

## `s3(options)`

Driver backed by an S3 bucket using WebCrypto and SigV4 without a cloud SDK dependency.

```js
import { s3 } from "@mc/core/drivers";

const driver = s3({
  bucket: "acme-assets",
  region: "us-east-1",
  prefix: "tenant/acme",
  credentials: {
    accessKeyId,
    secretAccessKey,
    sessionToken,
  },
  readOnly: true,
});
```

| Option        | Default     | Meaning                           |
| ------------- | ----------- | --------------------------------- |
| `bucket`      | required    | S3 bucket name                    |
| `region`      | `us-east-1` | Signing/endpoint region           |
| `prefix`      | empty       | Key prefix exposed as mount root  |
| `credentials` | anonymous   | Static SigV4 credentials          |
| `readOnly`    | false       | Driver-level read-only preference |

Anonymous requests omit SigV4-only headers so public buckets can remain CORS-simple. Credentialed
requests require the browser/host to reach the bucket endpoint.

## `vectorStore(options)`

Read-mostly retrieval-as-files driver.

| Option                  | Required | Meaning                                                |
| ----------------------- | -------- | ------------------------------------------------------ |
| `embed(query)`          | yes      | Resolve the decoded query to a numeric vector          |
| `search(vector, query)` | yes      | Return the text representation of the matching results |
| `readOnly`              | no       | Driver-level read-only preference; defaults to `true`  |

```js
const driver = vectorStore({
  async embed(query) {
    return embeddings.create(query);
  },
  async search(vector, query) {
    const hits = await index.search(vector);
    return hits.map((hit) => `${hit.score}\t${hit.text}`).join("\n");
  },
});
```

Mounted at `/rag`, opening `/rag/search/<encoded-query>` embeds the decoded query and returns search
output as a newline-terminated file. It is read-only by default.

## Remote mounts

The served VM stores mount metadata, but JavaScript driver methods execute in the client over the
per-VM control WebSocket. If the client disappears, the guest path cannot continue calling that
driver. Use server-resident storage integration when the mount must outlive clients.

## Mount or connection?

Use a mount when the natural interface is hierarchical bytes and metadata. Use a connection when the
natural interface is named API operations with request/response schemas and credential policy.
