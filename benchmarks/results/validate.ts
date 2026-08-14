import { readFile } from "node:fs/promises";
import { isAbsolute, resolve } from "node:path";
import { statistics, type BenchmarkResult, type Measurement, type Unit } from "../lib/result.js";

const UNITS = new Set<Unit>([
  "ns",
  "us",
  "ms",
  "s",
  "bytes",
  "bytes_per_second",
  "ops_per_second",
  "count",
  "ratio",
  "percent",
  "usd",
]);

function fail(path: string, message: string): never {
  throw new Error(`${path}: ${message}`);
}

function object(value: unknown, path: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(path, "expected object");
  return value as Record<string, unknown>;
}

function measurement(value: unknown, path: string): Measurement {
  const item = object(value, path);
  if (typeof item.name !== "string" || !/^[a-z0-9_.-]+$/.test(item.name))
    fail(`${path}.name`, "invalid stable measurement name");
  if (typeof item.unit !== "string" || !UNITS.has(item.unit as Unit))
    fail(`${path}.unit`, "unknown measurement unit");
  const dimensions = object(item.dimensions, `${path}.dimensions`);
  for (const [key, dimension] of Object.entries(dimensions)) {
    if (!["string", "number", "boolean"].includes(typeof dimension))
      fail(`${path}.dimensions.${key}`, "expected string, finite number, or boolean");
    if (typeof dimension === "number" && !Number.isFinite(dimension))
      fail(`${path}.dimensions.${key}`, "expected finite number");
  }
  if (!Array.isArray(item.samples)) fail(`${path}.samples`, "expected array");
  for (const [i, sample] of item.samples.entries()) {
    if (typeof sample !== "number" || !Number.isFinite(sample) || sample < 0)
      fail(`${path}.samples[${i}]`, "expected a finite non-negative number");
  }
  if (!Array.isArray(item.failures)) fail(`${path}.failures`, "expected array");
  for (const [i, raw] of item.failures.entries()) {
    const failure = object(raw, `${path}.failures[${i}]`);
    if (!Number.isSafeInteger(failure.iteration) || Number(failure.iteration) < 0)
      fail(`${path}.failures[${i}].iteration`, "expected non-negative integer");
    if (typeof failure.error !== "string") fail(`${path}.failures[${i}].error`, "expected string");
  }
  const stats = item.stats;
  if (item.samples.length === 0 && stats !== null)
    fail(`${path}.stats`, "must be null without successful samples");
  if (item.samples.length > 0) {
    const summary = object(stats, `${path}.stats`);
    if (summary.count !== item.samples.length)
      fail(`${path}.stats.count`, "must equal raw sample count");
    const expected = statistics(item.samples as number[])!;
    for (const field of ["p50", "p95"]) {
      const number = summary[field];
      if (typeof number !== "number" || !Number.isFinite(number) || number < 0)
        fail(`${path}.stats.${field}`, "expected a finite non-negative number");
      const expectedNumber = expected[field as keyof typeof expected];
      const tolerance = Math.max(1e-9, Math.abs(expectedNumber) * 1e-9);
      if (Math.abs(number - expectedNumber) > tolerance)
        fail(`${path}.stats.${field}`, "does not match the raw samples");
    }
  }
  return item as unknown as Measurement;
}

export function validate(value: unknown, path = "$"): asserts value is BenchmarkResult {
  const root = object(value, path);
  if (root.schema !== "agentos.benchmark.v1")
    fail(`${path}.schema`, "expected agentos.benchmark.v1");
  const run = object(root.run, `${path}.run`);
  for (const field of ["id", "timestamp", "runner", "runtime", "profile"]) {
    if (typeof run[field] !== "string" || run[field] === "")
      fail(`${path}.run.${field}`, "expected non-empty string");
  }
  if (Number.isNaN(Date.parse(String(run.timestamp))))
    fail(`${path}.run.timestamp`, "expected ISO-8601 timestamp");
  if (!["smoke", "standard", "stress"].includes(String(run.profile)))
    fail(`${path}.run.profile`, "unknown profile");
  object(run.system, `${path}.run.system`);
  if (!Array.isArray(run.artifacts)) fail(`${path}.run.artifacts`, "expected array");
  for (const [i, raw] of run.artifacts.entries()) {
    const artifact = object(raw, `${path}.run.artifacts[${i}]`);
    if (typeof artifact.name !== "string")
      fail(`${path}.run.artifacts[${i}].name`, "expected string");
    if (typeof artifact.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(artifact.sha256))
      fail(`${path}.run.artifacts[${i}].sha256`, "expected lowercase SHA-256");
    if (!Number.isSafeInteger(artifact.bytes) || Number(artifact.bytes) < 0)
      fail(`${path}.run.artifacts[${i}].bytes`, "expected non-negative integer");
  }
  if (!Array.isArray(root.measurements)) fail(`${path}.measurements`, "expected array");
  root.measurements.forEach((item, i) => measurement(item, `${path}.measurements[${i}]`));
  if (!Array.isArray(root.checks)) fail(`${path}.checks`, "expected array");
  for (const [i, raw] of root.checks.entries()) {
    const check = object(raw, `${path}.checks[${i}]`);
    if (typeof check.name !== "string" || check.name === "")
      fail(`${path}.checks[${i}].name`, "expected non-empty string");
    if (typeof check.ok !== "boolean") fail(`${path}.checks[${i}].ok`, "expected boolean");
    if (check.detail !== undefined && typeof check.detail !== "string")
      fail(`${path}.checks[${i}].detail`, "expected string");
  }
  if (!Array.isArray(root.skips)) fail(`${path}.skips`, "expected array");
  for (const [i, raw] of root.skips.entries()) {
    const skip = object(raw, `${path}.skips[${i}]`);
    if (typeof skip.name !== "string" || skip.name === "")
      fail(`${path}.skips[${i}].name`, "expected non-empty string");
    if (typeof skip.reason !== "string" || skip.reason === "")
      fail(`${path}.skips[${i}].reason`, "expected non-empty string");
  }
  if (root.runs !== undefined) {
    if (!Array.isArray(root.runs)) fail(`${path}.runs`, "expected array");
    root.runs.forEach((run, i) => validate(run, `${path}.runs[${i}]`));
  }
}

export function argumentPath(path: string): string {
  if (isAbsolute(path)) return path;
  return resolve(process.env.BUILD_WORKSPACE_DIRECTORY ?? process.cwd(), path);
}

async function main(): Promise<void> {
  const paths = process.argv.slice(2);
  if (paths.length === 0) throw new Error("usage: validate RESULT.json [...]");
  for (const path of paths) {
    validate(JSON.parse(await readFile(argumentPath(path), "utf8")), path);
    console.error(`valid: ${path}`);
  }
}

if (import.meta.main) await main();
