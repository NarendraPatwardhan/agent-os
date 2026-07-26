import { writeFile } from "node:fs/promises";
import { mc, type Vm } from "../shared/core.js";
import { parseArgs, ResultBuilder } from "../shared/result.js";
import { monotonicMs, systemMetadata } from "../shared/system.js";
import { validate } from "../tools/validate.js";

function option(argv: string[], name: string): string | undefined {
  const index = argv.indexOf(name);
  if (index < 0) return undefined;
  const value = argv[index + 1];
  if (!value) throw new Error(`${name} requires a value`);
  argv.splice(index, 2);
  return value;
}

function endpointOrigin(value: string): string {
  const url = new URL(value.includes("://") ? value : `https://${value}`);
  const path = url.pathname.replace(/\/+$/u, "");
  if (path !== "" && path !== "/v1") throw new Error("--endpoint path must be empty or /v1");
  if (url.search || url.hash) throw new Error("--endpoint must not contain a query or fragment");
  return url.origin;
}

async function timed<T>(work: () => Promise<T>): Promise<{ value: T; ms: number }> {
  const start = monotonicMs();
  const value = await work();
  return { value, ms: monotonicMs() - start };
}

function id(prefix: string, iteration: number): string {
  return `benchmark-${prefix}-${Date.now()}-${process.pid}-${iteration}`;
}

function operationSample(
  result: ResultBuilder,
  name: string,
  elapsedMs: number,
  networkMeanMs: number,
  dimensions: Record<string, string | number | boolean>,
): void {
  result.sample(name, "ms", Math.max(0, elapsedMs - networkMeanMs), {
    ...dimensions,
    adjustment: "mean-network-round-trip",
    networkMeanMs,
  });
}

function operationFailure(
  result: ResultBuilder,
  name: string,
  iteration: number,
  error: unknown,
  dimensions: Record<string, string | number | boolean>,
): void {
  result.failure(name, "ms", iteration, error, dimensions);
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const endpointOption = option(argv, "--endpoint");
  if (!endpointOption) throw new Error("--endpoint is required for the remote benchmark");
  const endpoint = endpointOrigin(endpointOption);
  const parsed = parseArgs(argv);
  const token = process.env.AGENTOS_BENCHMARK_TOKEN;
  const image = process.env.AGENTOS_BENCHMARK_IMAGE ?? "posix";
  const headers: Record<string, string> = {
    "content-type": "application/json",
    ...(token ? { authorization: `Bearer ${token}` } : {}),
  };
  const result = new ResultBuilder({
    id: `${Date.now()}-${process.pid}-remote`,
    timestamp: new Date().toISOString(),
    runner: "benchmarks/remote/runner",
    runtime: "@mc/core remote backend",
    profile: parsed.profile.name,
    sampleCount: parsed.profile.samples,
    system: await systemMetadata(),
    artifacts: [],
    endpointOrigin: new URL(endpoint).origin,
    image,
    command: process.argv,
    hostCostPerHour: parsed.hostCostPerHour,
  });

  const networkProbeUrl = `${endpoint}/healthz`;
  const probe = async (): Promise<number> => {
    const measured = await timed(async () => {
      const response = await fetch(networkProbeUrl, { headers });
      await response.arrayBuffer();
      if (!response.ok) throw new Error(`network probe HTTP ${response.status}`);
    });
    return measured.ms;
  };
  await probe();
  const networkSamples: number[] = [];
  for (let iteration = 0; iteration < parsed.profile.samples; iteration++) {
    try {
      const elapsedMs = await probe();
      networkSamples.push(elapsedMs);
      result.sample("transport.network_round_trip", "ms", elapsedMs, {
        host: "remote",
        route: "/healthz",
        temperature: "warm",
      });
    } catch (error) {
      result.failure("transport.network_round_trip", "ms", iteration, error, {
        host: "remote",
        route: "/healthz",
        temperature: "warm",
      });
    }
  }
  if (networkSamples.length === 0) throw new Error("all network round-trip probes failed");
  const networkMeanMs =
    networkSamples.reduce((sum, elapsedMs) => sum + elapsedMs, 0) / networkSamples.length;
  result.result.run.networkAdjustment = {
    method: "subtract arithmetic mean of /healthz round trips",
    samples: networkSamples.length,
    meanMs: networkMeanMs,
  };

  for (let iteration = 0; iteration < parsed.profile.samples; iteration++) {
    let vm: Vm | undefined;
    try {
      try {
        const measured = await timed(() =>
          mc.create({
            runtime: "remote",
            endpoint,
            token,
            id: id("create", iteration),
            image,
            deterministic: true,
          }),
        );
        vm = measured.value;
        operationSample(result, "remote.create.latency", measured.ms, networkMeanMs, {
          image,
          host: "remote",
          temperature: "cold",
        });
      } catch (error) {
        operationFailure(result, "remote.create.latency", iteration, error, {
          image,
          host: "remote",
          temperature: "cold",
        });
        continue;
      }

      try {
        const firstExec = await timed(() => vm!.exec("true"));
        if (firstExec.value.exitCode !== 0) throw new Error(firstExec.value.stderr);
        operationSample(result, "cold_start.shell", firstExec.ms, networkMeanMs, {
          image,
          host: "remote",
          temperature: "cold",
        });
      } catch (error) {
        operationFailure(result, "cold_start.shell", iteration, error, {
          image,
          host: "remote",
          temperature: "cold",
        });
      }
    } finally {
      await vm?.close();
    }
  }

  const vmId = id("work", 0);
  const vm = await mc.create({
    runtime: "remote",
    endpoint,
    token,
    id: vmId,
    image,
    deterministic: true,
  });
  try {
    const warmup = await vm.exec("true");
    if (warmup.exitCode !== 0) throw new Error(warmup.stderr);

    for (let iteration = 0; iteration < parsed.profile.samples; iteration++) {
      try {
        const measured = await timed(() => vm.run("true"));
        if (measured.value.exitCode !== 0) throw new Error(measured.value.stderr);
        operationSample(result, "exec.direct_minimal.steady", measured.ms, networkMeanMs, {
          image,
          host: "remote",
          temperature: "steady-state",
        });
      } catch (error) {
        operationFailure(result, "exec.direct_minimal.steady", iteration, error, {
          image,
          host: "remote",
          temperature: "steady-state",
        });
      }
    }

    for (let iteration = 0; iteration < parsed.profile.samples; iteration++) {
      try {
        const measured = await timed(() => vm.exec("/bin/echo agentos"));
        if (measured.value.exitCode !== 0) throw new Error(measured.value.stderr);
        operationSample(result, "exec.external_module.steady", measured.ms, networkMeanMs, {
          image,
          host: "remote",
          temperature: "steady-state",
        });
      } catch (error) {
        operationFailure(result, "exec.external_module.steady", iteration, error, {
          image,
          host: "remote",
          temperature: "steady-state",
        });
      }
    }

    for (let iteration = 0; iteration < parsed.profile.samples; iteration++) {
      try {
        const measured = await timed(() => vm.run("echo", ["agentos"]));
        if (measured.value.exitCode !== 0) throw new Error(measured.value.stderr);
        operationSample(result, "exec.direct_external.steady", measured.ms, networkMeanMs, {
          image,
          host: "remote",
          temperature: "steady-state",
        });
      } catch (error) {
        operationFailure(result, "exec.direct_external.steady", iteration, error, {
          image,
          host: "remote",
          temperature: "steady-state",
        });
      }
    }

    for (let iteration = 0; iteration < parsed.profile.samples; iteration++) {
      try {
        const snapshot = await timed(() => vm.snapshot());
        operationSample(result, "snapshot.full.latency", snapshot.ms, networkMeanMs, {
          image,
          host: "remote",
        });
        result.sample("snapshot.full.size", "bytes", snapshot.value.length, {
          image,
          host: "remote",
        });
      } catch (error) {
        operationFailure(result, "snapshot.full.latency", iteration, error, {
          image,
          host: "remote",
        });
      }
    }
    for (let iteration = 0; iteration < parsed.profile.samples; iteration++) {
      let child: Vm | undefined;
      try {
        const forked = await timed(() => vm.fork());
        child = forked.value;
        operationSample(result, "machine.fork", forked.ms, networkMeanMs, {
          image,
          host: "remote",
        });
      } catch (error) {
        operationFailure(result, "machine.fork", iteration, error, { image, host: "remote" });
      } finally {
        await child?.close();
      }
    }

    const execSamples =
      result.result.measurements.find(
        (measurement) => measurement.name === "exec.external_module.steady",
      )?.samples ?? [];
    const totalMs = execSamples.reduce((sum, value) => sum + value, 0);
    if (totalMs > 0) {
      const episodesPerSecond = execSamples.length / (totalMs / 1000);
      result.sample("economics.episodes_per_second", "ops_per_second", episodesPerSecond, {
        episode: "remote-echo-exec",
        utilization: "measured-serial-client",
      });
      if (parsed.hostCostPerHour !== undefined) {
        result.sample(
          "economics.cost_per_million_episodes",
          "usd",
          (1_000_000 / episodesPerSecond / 3600) * parsed.hostCostPerHour,
          {
            episode: "remote-echo-exec",
            hostCostPerHour: parsed.hostCostPerHour,
            formula: "1e6/episodes_per_second/3600*host_cost_per_hour",
          },
        );
      }
    }
  } finally {
    await vm.close();
  }

  validate(result.result);
  const json = `${JSON.stringify(result.result, null, 2)}\n`;
  if (parsed.output) await writeFile(parsed.output, json);
  else process.stdout.write(json);
}

await main();
