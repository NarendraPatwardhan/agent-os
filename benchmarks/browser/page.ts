import { mc, MemoryContentStore, type Vm } from "../shared/core.js";
import { profile, ResultBuilder } from "../shared/result.js";

declare global {
  interface Window {
    __AGENTOS_BENCHMARK_RESULT__?: unknown;
    __AGENTOS_BENCHMARK_PROGRESS__?: string;
    __AGENTOS_MEMORY_READY__?: boolean;
    __AGENTOS_MEMORY_CLOSE__?: () => Promise<void>;
  }
}

function mark(value: string): void {
  window.__AGENTOS_BENCHMARK_PROGRESS__ = value;
  console.log(`agentos-benchmark: ${value}`);
}

function now(): number {
  return performance.now();
}

async function timed<T>(work: () => Promise<T>): Promise<{ value: T; ms: number }> {
  const start = now();
  const value = await work();
  return { value, ms: now() - start };
}

async function fetchBytes(path: string): Promise<Uint8Array> {
  const response = await fetch(path, { cache: "no-store" });
  if (!response.ok) throw new Error(`${path}: HTTP ${response.status}`);
  return new Uint8Array(await response.arrayBuffer());
}

async function digest(bytes: Uint8Array): Promise<string> {
  const value = new Uint8Array(
    await crypto.subtle.digest("SHA-256", bytes as Uint8Array<ArrayBuffer>),
  );
  return [...value].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function command(
  result: ResultBuilder,
  vm: Vm,
  name: string,
  cmd: string,
  count: number,
  dimensions: Record<string, string | number | boolean>,
): Promise<void> {
  for (let iteration = 0; iteration < count; iteration++) {
    try {
      const measured = await timed(() => vm.exec(cmd));
      if (measured.value.exitCode !== 0)
        throw new Error(`${cmd} exited ${measured.value.exitCode}`);
      result.sample(name, "ms", measured.ms, dimensions);
    } catch (error) {
      result.failure(name, "ms", iteration, error, dimensions);
    }
  }
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
  for (let iteration = 0; iteration < count; iteration++) {
    try {
      const measured = await timed(() => vm.run(program, args));
      if (measured.value.exitCode !== 0)
        throw new Error(`${program} direct exec exited ${measured.value.exitCode}`);
      result.sample(name, "ms", measured.ms, dimensions);
    } catch (error) {
      result.failure(name, "ms", iteration, error, dimensions);
    }
  }
}

async function firstCommandPopulation(
  result: ResultBuilder,
  kernel: Uint8Array,
  image: Uint8Array,
  name: string,
  cmd: string,
  count: number,
  dimensions: Record<string, string | number | boolean>,
): Promise<void> {
  for (let iteration = 0; iteration < count; iteration++) {
    const vm = await mc.create({
      runtime: "browser",
      kernel,
      image,
      deterministic: true,
      store: new MemoryContentStore(),
    });
    try {
      const measured = await timed(() => vm.exec(cmd));
      if (measured.value.exitCode !== 0)
        throw new Error(`${cmd} exited ${measured.value.exitCode}`);
      result.sample(name, "ms", measured.ms, dimensions);
    } catch (error) {
      result.failure(name, "ms", iteration, error, dimensions);
    } finally {
      await vm.close();
    }
  }
}

async function memoryMode(): Promise<void> {
  const [kernel, posix] = await Promise.all([
    fetchBytes("/artifacts/kernel.wasm"),
    fetchBytes("/artifacts/posix.tar"),
  ]);
  const vm = await mc.create({
    runtime: "browser",
    kernel,
    image: posix,
    deterministic: true,
    store: new MemoryContentStore(),
  });
  window.__AGENTOS_MEMORY_CLOSE__ = async () => {
    await vm.close();
    window.__AGENTOS_MEMORY_READY__ = false;
  };
  window.__AGENTOS_MEMORY_READY__ = true;
}

async function residentSuite(
  result: ResultBuilder,
  kernel: Uint8Array,
  image: Uint8Array,
  imageName: "atlas" | "paper",
  service: "sqlite" | "typst",
  samples: number,
): Promise<void> {
  const commandLine =
    service === "sqlite"
      ? `sqlite /tmp/bench.db "CREATE TABLE IF NOT EXISTS t(n INTEGER); INSERT INTO t VALUES (1); SELECT count(*) FROM t"`
      : `printf '= AgentOS benchmark' > /tmp/bench.typ; typst compile /tmp/bench.typ /tmp/bench.pdf`;
  await firstCommandPopulation(
    result,
    kernel,
    image,
    `resident.${service}.first`,
    commandLine,
    samples,
    { image: imageName, host: "browser", temperature: "cold" },
  );

  const store = new MemoryContentStore();
  const vm = await mc.create({
    runtime: "browser",
    kernel,
    image,
    deterministic: true,
    store,
  });
  try {
    const warmup = await vm.exec(commandLine);
    if (warmup.exitCode !== 0) throw new Error(warmup.stderr);
    await command(result, vm, `resident.${service}.warm`, commandLine, samples, {
      image: imageName,
      host: "browser",
      temperature: "warm",
    });
    const snapshot = await vm.snapshot();
    await store.putSnapshotObject!(snapshot);
    for (let iteration = 0; iteration < samples; iteration++) {
      const restored = await mc.restore(snapshot, {
        runtime: "browser",
        kernel,
        deterministic: true,
        store,
      });
      try {
        const measured = await timed(() => restored.exec(commandLine));
        if (measured.value.exitCode !== 0) throw new Error(measured.value.stderr);
        result.sample(`resident.${service}.restored_warm`, "ms", measured.ms, {
          image: imageName,
          host: "browser",
          temperature: "restored-warm",
        });
      } catch (error) {
        result.failure(`resident.${service}.restored_warm`, "ms", iteration, error, {
          image: imageName,
          host: "browser",
          temperature: "restored-warm",
        });
      } finally {
        await restored.close();
      }
    }
  } finally {
    await vm.close();
  }
}

async function main(): Promise<void> {
  const params = new URLSearchParams(location.search);
  if (params.get("mode") === "memory") {
    await memoryMode();
    return;
  }
  const selected = profile(params.get("profile") ?? "smoke");
  const sampleOverride = Number(params.get("samples"));
  const branchOverride = Number(params.get("branches"));
  if (Number.isSafeInteger(sampleOverride) && sampleOverride > 0) selected.samples = sampleOverride;
  if (Number.isSafeInteger(branchOverride) && branchOverride > 0)
    selected.branches = branchOverride;
  const result = new ResultBuilder({
    id: `${Date.now()}-browser`,
    timestamp: new Date().toISOString(),
    runner: "benchmarks/browser/page",
    runtime: navigator.userAgent,
    profile: selected.name,
    sampleCount: selected.samples,
    system: {
      platform: navigator.platform,
      userAgent: navigator.userAgent,
      hardwareConcurrency: navigator.hardwareConcurrency,
      deviceMemoryGiB:
        "deviceMemory" in navigator
          ? (navigator as Navigator & { deviceMemory: number }).deviceMemory
          : null,
      crossOriginIsolated,
    },
    artifacts: [],
    command: location.href,
    semantics: {
      coldStart: "first command on a fresh machine",
    },
  });

  mark("fetch-artifacts");
  const names = ["kernel", "minimal", "posix", "loom", "atlas", "paper"] as const;
  const entries = await Promise.all(
    names.map(async (name) => {
      const extension = name === "kernel" ? "wasm" : "tar";
      const bytes = await fetchBytes(`/artifacts/${name}.${extension}`);
      return [name, bytes] as const;
    }),
  );
  const artifacts = Object.fromEntries(entries) as Record<(typeof names)[number], Uint8Array>;
  result.result.run.artifacts = await Promise.all(
    entries.map(async ([name, bytes]) => ({
      name,
      bytes: bytes.length,
      sha256: await digest(bytes),
    })),
  );

  mark("cold-start-by-image");
  for (const name of names.filter((name) => name !== "kernel")) {
    await firstCommandPopulation(
      result,
      artifacts.kernel,
      artifacts[name],
      "cold_start.shell",
      "true",
      selected.samples,
      { image: name, host: "browser", temperature: "cold" },
    );
  }

  mark("execution-and-state");
  await firstCommandPopulation(
    result,
    artifacts.kernel,
    artifacts.posix,
    "cold_start.process",
    "/bin/echo agentos",
    selected.samples,
    { image: "posix", host: "browser", temperature: "cold" },
  );
  const store = new MemoryContentStore();
  const vm = await mc.create({
    runtime: "browser",
    kernel: artifacts.kernel,
    image: artifacts.posix,
    deterministic: true,
    store,
  });
  try {
    await command(result, vm, "exec.shell_builtin.steady", "true", selected.samples, {
      image: "posix",
      host: "browser",
      temperature: "steady-state",
    });
    await command(
      result,
      vm,
      "exec.external_module.steady",
      "/bin/echo agentos",
      selected.samples,
      { image: "posix", host: "browser", temperature: "steady-state" },
    );
    await directCommand(result, vm, "exec.direct_minimal.steady", "true", [], selected.samples, {
      image: "posix",
      host: "browser",
      temperature: "steady-state",
    });
    await directCommand(
      result,
      vm,
      "exec.direct_external.steady",
      "echo",
      ["agentos"],
      selected.samples,
      { image: "posix", host: "browser", temperature: "steady-state" },
    );
    await command(
      result,
      vm,
      "exec.pipeline.three_stage",
      "printf 'c\\na\\nb\\n' | sort | wc -l",
      selected.samples,
      { image: "posix", host: "browser", temperature: "steady-state", stages: 3 },
    );
    for (const bytes of selected.fsBytes) {
      const payload = new Uint8Array(bytes);
      for (let iteration = 0; iteration < selected.samples; iteration++) {
        const write = await timed(() => vm.fs.write(`/tmp/browser-${bytes}-${iteration}`, payload));
        if (write.ms > 0) {
          result.sample(
            "filesystem.structured_write",
            "bytes_per_second",
            bytes / (write.ms / 1000),
            { image: "posix", host: "browser", bytes },
          );
        } else {
          result.failure(
            "filesystem.structured_write",
            "bytes_per_second",
            iteration,
            new Error("performance timer returned a zero duration"),
            { image: "posix", host: "browser", bytes },
          );
        }
      }
      await vm.fs.write(`/tmp/browser-read-${bytes}`, payload);
      for (let iteration = 0; iteration < selected.samples; iteration++) {
        const read = await timed(() => vm.fs.read(`/tmp/browser-read-${bytes}`));
        if (read.value.length !== bytes) throw new Error("browser structured read was short");
        if (read.ms > 0) {
          result.sample(
            "filesystem.structured_read",
            "bytes_per_second",
            bytes / (read.ms / 1000),
            { image: "posix", host: "browser", bytes },
          );
        } else {
          result.failure(
            "filesystem.structured_read",
            "bytes_per_second",
            iteration,
            new Error("performance timer returned a zero duration"),
            { image: "posix", host: "browser", bytes },
          );
        }
      }
    }
    let full: Uint8Array | undefined;
    for (let iteration = 0; iteration < selected.samples; iteration++) {
      const measured = await timed(() => vm.snapshot());
      full ??= measured.value;
      result.sample("snapshot.full.latency", "ms", measured.ms, {
        image: "posix",
        host: "browser",
      });
      result.sample("snapshot.full.size", "bytes", measured.value.length, {
        image: "posix",
        host: "browser",
      });
    }
    if (!full) throw new Error("full snapshot population was empty");
    await store.putSnapshotObject!(full);
    for (const bytes of selected.fsBytes) {
      for (let iteration = 0; iteration < selected.samples; iteration++) {
        const mutated = await mc.restore(full, {
          runtime: "browser",
          kernel: artifacts.kernel,
          deterministic: true,
          store,
        });
        try {
          await mutated.fs.write(`/tmp/browser-delta-${bytes}-${iteration}`, new Uint8Array(bytes));
          const delta = await timed(() => mutated.snapshot({ mode: "incremental" }));
          result.sample("snapshot.incremental.latency", "ms", delta.ms, {
            image: "posix",
            host: "browser",
            mutationBytes: bytes,
          });
          result.sample("snapshot.incremental.size", "bytes", delta.value.length, {
            image: "posix",
            host: "browser",
            mutationBytes: bytes,
          });
          result.sample(
            "snapshot.incremental.efficiency",
            "ratio",
            delta.value.length / full.length,
            {
              image: "posix",
              host: "browser",
              mutationBytes: bytes,
            },
          );
        } finally {
          await mutated.close();
        }
      }
    }
    for (let iteration = 0; iteration < selected.samples; iteration++) {
      const forked = await timed(() => vm.fork());
      result.sample("machine.fork", "ms", forked.ms, {
        image: "posix",
        host: "browser",
      });
      await forked.value.close();
    }

    for (let iteration = 0; iteration < selected.samples; iteration++) {
      const restored = await timed(() =>
        mc.restore(full, {
          runtime: "browser",
          kernel: artifacts.kernel,
          deterministic: true,
          store,
        }),
      );
      result.sample("snapshot.restore_full", "ms", restored.ms, {
        image: "posix",
        host: "browser",
      });
      await restored.value.close();
    }
  } finally {
    await vm.close();
  }

  mark("resident-services");
  await residentSuite(
    result,
    artifacts.kernel,
    artifacts.atlas,
    "atlas",
    "sqlite",
    selected.samples,
  );
  if (selected.name === "smoke")
    result.skip("resident.typst", "paper compile is excluded from the smoke profile");
  else
    await residentSuite(
      result,
      artifacts.kernel,
      artifacts.paper,
      "paper",
      "typst",
      selected.samples,
    );
  mark("done");
  window.__AGENTOS_BENCHMARK_RESULT__ = result.result;
}

main().catch((error) => {
  window.__AGENTOS_BENCHMARK_RESULT__ = {
    error: error instanceof Error ? error.message : String(error),
    stack: error instanceof Error ? error.stack : undefined,
  };
});
