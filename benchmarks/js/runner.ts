import { readFile, writeFile } from "node:fs/promises";
import { arch, cpus } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { mc, MemoryContentStore, type Vm } from "../shared/core.js";
import { parseArgs, ResultBuilder, type Profile } from "../shared/result.js";
import { monotonicMs, sha256, systemMetadata } from "../shared/system.js";

function runfile(rel: string | undefined, name: string): string {
  if (!rel) throw new Error(`${name} is not set; run this target through Bazel`);
  const root = process.env.RUNFILES_DIR;
  if (!root) throw new Error("RUNFILES_DIR is not set; run this target through Bazel");
  return join(root, rel);
}

function git(args: string[]): string | undefined {
  const cwd = process.env.BUILD_WORKSPACE_DIRECTORY;
  if (!cwd) return undefined;
  const result = spawnSync("git", args, { cwd, encoding: "utf8" });
  return result.status === 0 ? result.stdout.trim() : undefined;
}

function elapsed(start: number): number {
  return monotonicMs() - start;
}

async function timed<T>(work: () => Promise<T>): Promise<{ value: T; ms: number }> {
  const start = monotonicMs();
  const value = await work();
  return { value, ms: elapsed(start) };
}

async function recordIterations(
  result: ResultBuilder,
  name: string,
  count: number,
  dimensions: Record<string, string | number | boolean>,
  work: (iteration: number) => Promise<number>,
): Promise<void> {
  for (let iteration = 0; iteration < count; iteration++) {
    try {
      result.sample(name, "ms", await work(iteration), dimensions);
    } catch (error) {
      result.failure(name, "ms", iteration, error, dimensions);
    }
  }
}

async function recordBandwidthIterations(
  result: ResultBuilder,
  name: string,
  count: number,
  bytes: number,
  dimensions: Record<string, string | number | boolean>,
  work: (iteration: number) => Promise<number>,
): Promise<void> {
  for (let iteration = 0; iteration < count; iteration++) {
    try {
      const durationMs = await work(iteration);
      if (durationMs <= 0) throw new Error("monotonic timer returned a zero duration");
      result.sample(name, "bytes_per_second", bytes / (durationMs / 1000), dimensions);
    } catch (error) {
      result.failure(name, "bytes_per_second", iteration, error, dimensions);
    }
  }
}

async function vmCommand(
  result: ResultBuilder,
  vm: Vm,
  name: string,
  command: string,
  count: number,
  dimensions: Record<string, string | number | boolean>,
): Promise<void> {
  await recordIterations(result, name, count, dimensions, async () => {
    const measured = await timed(() => vm.exec(command));
    if (measured.value.exitCode !== 0)
      throw new Error(`${command} exited ${measured.value.exitCode}: ${measured.value.stderr}`);
    return measured.ms;
  });
}

async function directCommand(
  result: ResultBuilder,
  vm: Vm,
  name: string,
  program: string,
  args: readonly string[],
  count: number,
  dimensions: Record<string, string | number | boolean>,
): Promise<void> {
  await recordIterations(result, name, count, dimensions, async () => {
    const measured = await timed(() => vm.run(program, args));
    if (measured.value.exitCode !== 0)
      throw new Error(
        `${program} direct exec exited ${measured.value.exitCode}: ${measured.value.stderr}`,
      );
    return measured.ms;
  });
}

interface Artifact {
  name: string;
  bytes: Uint8Array;
  sha256: string;
}

async function artifact(name: string, env: string): Promise<Artifact> {
  const bytes = new Uint8Array(await readFile(runfile(process.env[env], env)));
  return {
    name,
    bytes,
    sha256: await sha256(bytes),
  };
}

async function firstCommandSuite(
  result: ResultBuilder,
  kernel: Artifact,
  image: Artifact,
  profile: Profile,
  name: string,
  command: string,
  dimensions: Record<string, string | number | boolean>,
): Promise<void> {
  await recordIterations(result, name, profile.samples, dimensions, async () => {
    const vm = await mc.create({
      runtime: "local",
      kernel: kernel.bytes,
      image: image.bytes,
      deterministic: true,
      store: new MemoryContentStore(),
    });
    try {
      const measured = await timed(() => vm.exec(command));
      if (measured.value.exitCode !== 0) throw new Error(measured.value.stderr);
      return measured.ms;
    } finally {
      await vm.close();
    }
  });
}

async function executionAndStateSuite(
  result: ResultBuilder,
  kernel: Artifact,
  posix: Artifact,
  profile: Profile,
): Promise<void> {
  const common = { image: posix.name, host: "js" };
  await firstCommandSuite(
    result,
    kernel,
    posix,
    profile,
    "cold_start.process",
    "/bin/echo agentos",
    {
      ...common,
      temperature: "cold",
      module: "coreutils",
    },
  );

  const store = new MemoryContentStore();
  const vm = await mc.create({
    runtime: "local",
    kernel: kernel.bytes,
    image: posix.bytes,
    deterministic: true,
    store,
  });
  try {
    await vmCommand(result, vm, "exec.shell_builtin.steady", "true", profile.samples, {
      ...common,
      temperature: "steady-state",
    });
    await vmCommand(
      result,
      vm,
      "exec.external_module.steady",
      "/bin/echo agentos",
      profile.samples,
      { ...common, temperature: "steady-state", module: "coreutils" },
    );
    await directCommand(result, vm, "exec.direct_minimal.steady", "true", [], profile.samples, {
      ...common,
      temperature: "steady-state",
      module: "coreutils",
    });
    await directCommand(
      result,
      vm,
      "exec.direct_external.steady",
      "echo",
      ["agentos"],
      profile.samples,
      { ...common, temperature: "steady-state", module: "coreutils" },
    );
    await vmCommand(
      result,
      vm,
      "exec.pipeline.three_stage",
      "printf 'c\\na\\nb\\n' | sort | wc -l",
      profile.samples,
      { ...common, temperature: "steady-state", stages: 3 },
    );

    for (const bytes of profile.fsBytes) {
      const payload = new Uint8Array(bytes);
      payload.fill(0x61);
      await recordBandwidthIterations(
        result,
        "filesystem.structured_write",
        profile.samples,
        bytes,
        { ...common, bytes },
        async (iteration) => {
          const path = `/tmp/bench-write-${bytes}-${iteration}`;
          return (await timed(() => vm.fs.write(path, payload))).ms;
        },
      );
      const path = `/tmp/bench-read-${bytes}`;
      await vm.fs.write(path, payload);
      await recordBandwidthIterations(
        result,
        "filesystem.structured_read",
        profile.samples,
        bytes,
        { ...common, bytes },
        async () => {
          const measured = await timed(() => vm.fs.read(path));
          if (measured.value.length !== bytes)
            throw new Error(`short read: ${measured.value.length} != ${bytes}`);
          return measured.ms;
        },
      );
    }

    let full: Uint8Array | undefined;
    for (let iteration = 0; iteration < profile.samples; iteration++) {
      const measured = await timed(() => vm.snapshot());
      full ??= measured.value;
      result.sample("snapshot.full.latency", "ms", measured.ms, common);
      result.sample("snapshot.full.size", "bytes", measured.value.length, common);
    }
    if (!full) throw new Error("full snapshot population was empty");
    await store.putSnapshotObject!(full);

    for (const bytes of profile.fsBytes) {
      for (let iteration = 0; iteration < profile.samples; iteration++) {
        const mutated = await mc.restore(full, {
          runtime: "local",
          kernel: kernel.bytes,
          deterministic: true,
          store,
        });
        try {
          await mutated.fs.write(
            `/tmp/snapshot-mutation-${bytes}-${iteration}`,
            new Uint8Array(bytes),
          );
          const incremental = await timed(() => mutated.snapshot({ mode: "incremental" }));
          result.sample("snapshot.incremental.latency", "ms", incremental.ms, {
            ...common,
            mutationBytes: bytes,
          });
          result.sample("snapshot.incremental.size", "bytes", incremental.value.length, {
            ...common,
            mutationBytes: bytes,
          });
          result.sample(
            "snapshot.incremental.efficiency",
            "ratio",
            incremental.value.length / full.length,
            { ...common, mutationBytes: bytes },
          );
        } finally {
          await mutated.close();
        }
      }
    }

    await recordIterations(
      result,
      "snapshot.restore_full",
      profile.samples,
      { ...common, temperature: "warm" },
      async () => {
        const measured = await timed(() =>
          mc.restore(full, {
            runtime: "local",
            kernel: kernel.bytes,
            deterministic: true,
            store,
          }),
        );
        await measured.value.close();
        return measured.ms;
      },
    );

    await recordIterations(result, "machine.fork", profile.samples, common, async () => {
      const measured = await timed(() => vm.fork());
      await measured.value.close();
      return measured.ms;
    });
  } finally {
    await vm.close();
  }
}

async function residentSuite(
  result: ResultBuilder,
  kernel: Artifact,
  image: Artifact,
  service: "sqlite" | "typst",
  profile: Profile,
): Promise<void> {
  const store = new MemoryContentStore();
  const command =
    service === "sqlite"
      ? `sqlite /tmp/bench.db "CREATE TABLE IF NOT EXISTS t(n INTEGER); INSERT INTO t VALUES (1); SELECT count(*) FROM t"`
      : `printf '= AgentOS benchmark' > /tmp/bench.typ; typst compile /tmp/bench.typ /tmp/bench.pdf`;
  await firstCommandSuite(result, kernel, image, profile, `resident.${service}.first`, command, {
    image: image.name,
    temperature: "cold",
    host: "js",
  });

  const vm = await mc.create({
    runtime: "local",
    kernel: kernel.bytes,
    image: image.bytes,
    deterministic: true,
    store,
  });
  try {
    const warmup = await vm.exec(command);
    if (warmup.exitCode !== 0) throw new Error(warmup.stderr);
    await vmCommand(result, vm, `resident.${service}.warm`, command, profile.samples, {
      image: image.name,
      temperature: "warm",
      host: "js",
    });
    const warmSnapshot = await vm.snapshot();
    await store.putSnapshotObject!(warmSnapshot);
    for (let iteration = 0; iteration < profile.samples; iteration++) {
      const restored = await mc.restore(warmSnapshot, {
        runtime: "local",
        kernel: kernel.bytes,
        deterministic: true,
        store,
      });
      try {
        const measured = await timed(() => restored.exec(command));
        if (measured.value.exitCode !== 0) throw new Error(measured.value.stderr);
        result.sample(`resident.${service}.restored_warm`, "ms", measured.ms, {
          image: image.name,
          temperature: "restored-warm",
          host: "js",
        });
      } catch (error) {
        result.failure(`resident.${service}.restored_warm`, "ms", iteration, error, {
          image: image.name,
          temperature: "restored-warm",
          host: "js",
        });
      } finally {
        await restored.close();
      }
    }
  } finally {
    await vm.close();
  }
}

async function deterministicSuite(
  result: ResultBuilder,
  kernel: Artifact,
  posix: Artifact,
  repetitions: number,
): Promise<void> {
  const digests: string[] = [];
  const outputs: string[] = [];
  for (let i = 0; i < repetitions; i++) {
    const vm = await mc.create({
      runtime: "local",
      kernel: kernel.bytes,
      image: posix.bytes,
      deterministic: true,
      store: new MemoryContentStore(),
    });
    try {
      const execution = await vm.exec("printf deterministic-agentos");
      outputs.push(execution.stdout);
      digests.push(await sha256(await vm.snapshot()));
    } finally {
      await vm.close();
    }
  }
  const matching = outputs.filter(
    (value, index) => value === outputs[0] && digests[index] === digests[0],
  ).length;
  const matches = matching === repetitions;
  result.check(
    "deterministic.replay",
    matches,
    `${new Set(outputs).size} output variants, ${new Set(digests).size} snapshot variants`,
  );
  result.sample("deterministic.replay_rate", "percent", (matching / repetitions) * 100, {
    repetitions,
    host: "js",
  });
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const [kernel, minimal, posix, loom, atlas, paper] = await Promise.all([
    artifact("kernel.wasm", "MC_KERNEL_WASM"),
    artifact("minimal", "MC_MINIMAL_IMAGE"),
    artifact("posix", "MC_POSIX_IMAGE"),
    artifact("loom", "MC_LOOM_IMAGE"),
    artifact("atlas", "MC_ATLAS_IMAGE"),
    artifact("paper", "MC_PAPER_IMAGE"),
  ]);
  const artifacts = [kernel, minimal, posix, loom, atlas, paper];
  const commit = git(["rev-parse", "HEAD"]) ?? "unknown";
  const dirty = git(["status", "--porcelain"]) !== "";
  const result = new ResultBuilder({
    id: `${Date.now()}-${process.pid}`,
    timestamp: new Date().toISOString(),
    runner: "benchmarks/js/runner",
    runtime: `@mc/core embedded JS / ${process.release.name} ${process.version}`,
    profile: args.profile.name,
    sampleCount: args.profile.samples,
    system: {
      ...(await systemMetadata()),
      architecture: arch(),
      logicalCpus: cpus().length,
    },
    artifacts: artifacts.map((item) => ({
      name: item.name,
      sha256: item.sha256,
      bytes: item.bytes.length,
    })),
    git: { commit, dirty },
    command: process.argv,
    semantics: {
      coldStart: "first command on a fresh machine",
    },
  });

  for (const image of [minimal, posix, loom, atlas, paper]) {
    await firstCommandSuite(result, kernel, image, args.profile, "cold_start.shell", "true", {
      image: image.name,
      host: "js",
      temperature: "cold",
    });
  }

  await executionAndStateSuite(result, kernel, posix, args.profile);
  await residentSuite(result, kernel, atlas, "sqlite", args.profile);
  if (args.profile.name === "smoke") {
    result.skip("resident.typst", "paper compile is intentionally excluded from the smoke profile");
  } else {
    await residentSuite(result, kernel, paper, "typst", args.profile);
  }
  await deterministicSuite(result, kernel, posix, args.profile.samples);
  const json = `${JSON.stringify(result.result, null, 2)}\n`;
  if (args.output) await writeFile(args.output, json);
  else process.stdout.write(json);
}

await main();
