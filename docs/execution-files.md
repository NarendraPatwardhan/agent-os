# Execution and files

AgentOS exposes the guest from two complementary host views: commands through `vm.exec()` and direct
file operations through `vm.fs`. Both operate on the same live VM state.

## `vm.exec(command, options?)`

Runs one real shell command to completion.

```js
const result = await vm.exec("sort input.txt | uniq -c | sort -rn", {
  cwd: "/workspace",
  env: { LC_ALL: "C" },
  stdin: "",
});
```

### Options

| Field | Shape | Meaning |
|---|---|---|
| `cwd` | string | Working directory; relative paths resolve against the VM's live cwd |
| `env` | string-to-string object | Overrides layered over the live boot environment |
| `stdin` | string or `Uint8Array` | Bytes presented on file descriptor 0 |

`command` is a shell line, not an argv array. Pipes, redirection, command substitution, `&&`, and
other supported shell syntax are interpreted inside the VM.

### Result

| Field | Shape | Meaning |
|---|---|---|
| `stdout` | string | UTF-8-decoded standard output |
| `stderr` | string | UTF-8-decoded standard error |
| `stdoutBytes` | `Uint8Array` | Original output bytes |
| `stderrBytes` | `Uint8Array` | Original error bytes |
| `exitCode` | number | Real guest process exit status |

Use the byte fields for binary or lossless output. UTF-8 decoding is convenient but cannot preserve
arbitrary byte sequences.

A nonzero exit code does not reject the promise:

```js
const result = await vm.exec("test -f /workspace/result.json");
if (result.exitCode !== 0) {
  console.error(result.stderr);
}
```

SDK, transport, or host failures do reject. See [Errors and diagnostics](./errors.md).

## `vm.luau(source, args?)`

Writes `source` to a unique temporary file and runs `/bin/luau` with safely quoted arguments.

```js
const result = await vm.luau(
  `local json = require("json")
print(json.encode({ value = arg[1] }))`,
  ["hello"],
);
```

The result is the same `ExecResult` as `vm.exec()`. The image must contain `/bin/luau`; use `loom`,
`atlas`, `paper`, or a custom image built on that layer.

This method is the JavaScript API for running Luau. The Luau batteries themselves are a guest API and
are outside this JavaScript reference.

## `vm.serviceCall(name, request?)`

Calls the resident service mounted at `/svc/<name>` through trusted host control.

```js
const request = new TextEncoder().encode('{"op":"status"}');
const response = await vm.serviceCall("tools", request);
```

`request` defaults to an empty byte array. The result is raw bytes; service-specific framing belongs to
that service's protocol. This is an advanced primitive. Prefer a higher-level SDK method when one
exists.

## `vm.fs`

`vm.fs` is the trusted operator filesystem view. Paths refer to the guest namespace. Methods are
asynchronous even when an embedded backend can satisfy some operations synchronously.

### `read(path)`

Returns exact file bytes.

```js
const bytes = await vm.fs.read("/workspace/report.pdf");
```

### `readText(path)`

Reads bytes and decodes them as UTF-8.

```js
const config = await vm.fs.readText("/etc/app.conf");
```

### `write(path, data)`

Creates or truncates a file from a string or byte array.

```js
await vm.fs.write("/workspace/input.json", JSON.stringify(input));
await vm.fs.write("/workspace/blob.bin", bytes);
```

The parent directory must exist.

### `ls(path)`

Returns directory entries:

| Field | Meaning |
|---|---|
| `name` | Basename only |
| `isDir` | Entry is a directory |
| `isSymlink` | Entry itself is a symbolic link |

```js
for (const entry of await vm.fs.ls("/workspace")) {
  console.log(entry.name, entry.isDir, entry.isSymlink);
}
```

### `stat(path)`

Returns lstat-style metadata; a symlink is reported as a symlink instead of being followed.

| Field | Meaning |
|---|---|
| `size` | File size in bytes |
| `isDir` | Path is a directory |
| `isSymlink` | Path is a symbolic link |
| `nlink` | Link count |
| `mode` | POSIX mode bits |

### `readlink(path)`

Returns the stored target text without following it. Relative targets remain relative text.

### `mkdir(path)`

Creates one directory. It does not recursively create missing parents.

### `rm(path)`

Removes a file, symlink, or empty directory. It is not recursive.

### `chmod(path, mode)`

Sets POSIX permission bits:

```js
await vm.fs.chmod("/workspace/private.txt", 0o600);
```

### `symlink(target, link)`

Creates `link` containing the literal `target` text:

```js
await vm.fs.symlink("../shared/data.json", "/workspace/data.json");
```

The argument order matches POSIX `symlink(target, link)`, not `copy(source, destination)`.

## Files and mounted drivers

The same methods traverse host-backed mounts. Reads and writes under a mounted path are proxied to its
driver. Driver errors with recognized POSIX codes are mapped back to guest filesystem errors.

See [Mounts and drivers](./mounts-drivers.md).

## Operator authority

Guest filesystem permissions and task tiers restrict guest code. `vm.fs` is host control and acts as
the trusted operator, allowing an application to stage inputs and harvest outputs around a constrained
guest task.
