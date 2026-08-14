import { readFile, writeFile } from "node:fs/promises";
import { cpus, hostname, platform } from "node:os";
import type { BenchmarkResult } from "../lib/result.js";
import { argumentPath, validate } from "./validate.js";

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const outputFlag = args.indexOf("--output");
  if (outputFlag < 0 || !args[outputFlag + 1])
    throw new Error("usage: aggregate --output MERGED.json RESULT.json [...]");
  const output = argumentPath(args[outputFlag + 1]!);
  args.splice(outputFlag, 2);
  if (args.length === 0) throw new Error("aggregate needs at least one result");
  const runs: BenchmarkResult[] = [];
  for (const path of args) {
    const parsed: unknown = JSON.parse(await readFile(argumentPath(path), "utf8"));
    validate(parsed, path);
    runs.push(parsed);
  }
  const profiles = new Set(runs.map((run) => run.run.profile));
  if (profiles.size !== 1)
    throw new Error(`cannot aggregate mixed profiles: ${[...profiles].join(", ")}`);
  const aggregate: BenchmarkResult = {
    schema: "agentos.benchmark.v1",
    run: {
      id: `aggregate-${Date.now()}-${process.pid}`,
      timestamp: new Date().toISOString(),
      runner: "benchmarks/results/aggregate",
      runtime: "multi-runtime",
      profile: runs[0]!.run.profile,
      system: {
        hostname: hostname(),
        os: platform(),
        logicalCpus: cpus().length,
        aggregationOnly: true,
      },
      artifacts: [],
      sourceRunIds: runs.map((run) => run.run.id),
    },
    measurements: [],
    checks: [],
    skips: [],
    runs,
  };
  validate(aggregate);
  await writeFile(output, `${JSON.stringify(aggregate, null, 2)}\n`);
  console.error(`wrote ${runs.length} runs to ${output}`);
}

await main();
