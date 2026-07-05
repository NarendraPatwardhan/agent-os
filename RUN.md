# Embedded JS/Bun Runbook

This is the repeatable workflow for booting a Bazel-built memcontainer from JavaScript.
It covers the two useful host surfaces:

- `@mc/core`: public embedded API for `mc.create`, `vm.exec`, `vm.fs`, `vm.status`, and `vm.close`.
- `KernelHostBuilder`: lower-level host API for direct control-channel operations such as
  `writeFile`, `chmod`, `stat`, and byte-oriented `exec`.

All build inputs come from Bazel. Do not invoke language toolchains directly.

## Choose Artifacts

Pick the smallest image that contains the tools your scenario needs:

```text
//memcontainers/images:base      rootfs and boot services
//memcontainers/images:minimal   base plus minimal coreutils
//memcontainers/images:posix     full POSIX-style tool layer
//memcontainers/images:loom      posix plus Luau
//memcontainers/images:atlas     loom plus SQLite service/tooling
//memcontainers/images:paper     loom plus Typst/fonts
```

The common JS workflow also needs a kernel target and the JS host libraries. The examples
below use the current stable Rust kernel target; swap the kernel label and output path when
testing another kernel.

```text
//memcontainers/kernel/rust:kernel
//memcontainers/sdk-js/core:lib
//memcontainers/hosts/js:host
```

If the scenario injects a freshly built guest binary, add that guest target to the same
Bazel build. For example, use the program target that owns the guest you want to mount
into the live VM.

## Build

Build the kernel, chosen image, JS host libraries, and any optional guest binaries in one
Bazel command:

```bash
bazel build \
  //memcontainers/kernel/rust:kernel \
  //memcontainers/images:<image> \
  //memcontainers/sdk-js/core:lib \
  //memcontainers/hosts/js:host \
  //<optional/guest:target>
```

Omit the optional guest line when the flow only boots an image and runs commands already
present in that image.

Common output paths:

```text
bazel-bin/memcontainers/kernel/rust/kernel.wasm
bazel-bin/memcontainers/images/<image>.tar
bazel-bin/memcontainers/sdk-js/core/src/index.js
bazel-bin/memcontainers/hosts/js/src/index.js
```

Guest binaries appear under their target's `bazel-bin/...` package path.

## Public SDK Flow

Use this for ordinary embedded execution: boot an image, run shell commands, write/read
files through the SDK, and close the VM.

Create a temporary script:

```bash
cat >/tmp/mc-embedded-flow.mjs <<'EOF'
import { readFileSync } from "node:fs";

const root = "/mnt/workspace/agent-os/agent-os-zig";
const imageName = "<image>";

const { mc } = await import(`${root}/bazel-bin/memcontainers/sdk-js/core/src/index.js`);

const kernel = new Uint8Array(readFileSync(`${root}/bazel-bin/memcontainers/kernel/rust/kernel.wasm`));
const image = new Uint8Array(readFileSync(`${root}/bazel-bin/memcontainers/images/${imageName}.tar`));

const vm = await mc.create({ kernel, image, deterministic: true });

try {
  const hello = await vm.exec("printf 'hello from vm\\n'");
  if (hello.exitCode !== 0 || hello.stdout !== "hello from vm\n") {
    throw new Error(`exec failed: ${JSON.stringify(hello)}`);
  }

  await vm.fs.write("/tmp/from-host.txt", "host wrote this\n");
  const readBack = await vm.exec("cat /tmp/from-host.txt");
  if (readBack.exitCode !== 0 || readBack.stdout !== "host wrote this\n") {
    throw new Error(`fs roundtrip failed: ${JSON.stringify(readBack)}`);
  }

  console.log(JSON.stringify({
    kernelBytes: kernel.length,
    imageBytes: image.length,
    status: await vm.status(),
  }, null, 2));
} finally {
  await vm.close();
}
EOF
```

Run it:

```bash
bun /tmp/mc-embedded-flow.mjs
```

Expected shape:

```json
{
  "kernelBytes": 123456,
  "imageBytes": 123456,
  "status": {
    "running": true,
    "inflightEgress": 0
  }
}
```

The byte counts are examples; real values depend on the selected artifacts.

## Direct Host Flow

Use the lower-level host when the scenario needs direct VM filesystem/control operations,
especially injecting a guest wasm into the live filesystem before executing it.

Create a temporary script:

```bash
cat >/tmp/mc-direct-host-flow.mjs <<'EOF'
import { readFileSync } from "node:fs";

const root = "/mnt/workspace/agent-os/agent-os-zig";
const imageName = "<image>";
const guestPath = "bazel-bin/<package>/<guest>.wasm";
const mountPath = "/tmp/guest.wasm";

const { KernelHostBuilder } = await import(`${root}/bazel-bin/memcontainers/hosts/js/src/index.js`);
const dec = (bytes) => new TextDecoder().decode(bytes);

const kernel = new Uint8Array(readFileSync(`${root}/bazel-bin/memcontainers/kernel/rust/kernel.wasm`));
const image = new Uint8Array(readFileSync(`${root}/bazel-bin/memcontainers/images/${imageName}.tar`));
const guest = new Uint8Array(readFileSync(`${root}/${guestPath}`));

const host = await new KernelHostBuilder(kernel)
  .withBaseImage(image)
  .deterministic()
  .build();

try {
  host.writeFile(mountPath, guest);
  host.chmod(mountPath, 0o755);

  const stat = host.stat(mountPath);
  if (stat.size !== guest.length) {
    throw new Error(`mounted guest size mismatch: stat=${stat.size} wasm=${guest.length}`);
  }

  const result = await host.exec(`${mountPath} --help`);
  if (result.exitCode !== 0) {
    throw new Error(`guest exec failed: ${JSON.stringify({
      exitCode: result.exitCode,
      stdout: dec(result.stdout),
      stderr: dec(result.stderr),
    })}`);
  }

  console.log(JSON.stringify({
    kernelBytes: kernel.length,
    imageBytes: image.length,
    guestBytes: guest.length,
    mounted: { path: mountPath, size: stat.size, mode: stat.mode },
  }, null, 2));
} finally {
  host.close?.();
}
EOF
```

Run it:

```bash
bun /tmp/mc-direct-host-flow.mjs
```

Change `guestPath`, `mountPath`, and the command passed to `host.exec` for the program
under test.

## Timing A Flow

For startup or regression timing, measure phases inside the script and optionally wrap the
whole process with shell timing:

```bash
time -p bun /tmp/mc-embedded-flow.mjs
```

Inside the script, use `performance.now()` around:

```text
import SDK or host module
read kernel/image/guest artifacts
mc.create(...) or KernelHostBuilder(...).build()
each vm.exec(...) or host.exec(...)
vm.close() or host close
```

This measures a fresh JS process and fresh VM when the script is run from scratch. It does
not drop the host OS page cache and does not rebuild Bazel artifacts.

## Practical Notes

- Keep scripts in `/tmp` unless the script itself is meant to become a checked-in test or
  tool.
- Prefer `@mc/core` for normal embedder behavior. Use `KernelHostBuilder` only when the
  public SDK surface is not enough.
- Always close the VM in `finally` so failed assertions do not leave host state running.
- Use deterministic mode for repeatable smoke and timing runs.
- Treat generated `bazel-bin/...` paths as outputs of the preceding Bazel build, not as
  source files.
