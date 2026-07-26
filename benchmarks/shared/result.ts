export type ProfileName = "smoke" | "standard" | "stress";
export type Unit =
  | "ns"
  | "us"
  | "ms"
  | "s"
  | "bytes"
  | "bytes_per_second"
  | "ops_per_second"
  | "count"
  | "ratio"
  | "percent"
  | "usd";

export interface Stats {
  count: number;
  p50: number;
  p95: number;
}

export interface Measurement {
  name: string;
  unit: Unit;
  dimensions: Record<string, string | number | boolean>;
  samples: number[];
  failures: { iteration: number; error: string }[];
  stats: Stats | null;
}

export interface BenchmarkResult {
  schema: "agentos.benchmark.v1";
  run: {
    id: string;
    timestamp: string;
    runner: string;
    runtime: string;
    profile: ProfileName;
    system: Record<string, unknown>;
    artifacts: { name: string; sha256: string; bytes: number }[];
    [key: string]: unknown;
  };
  measurements: Measurement[];
  checks: { name: string; ok: boolean; detail?: string }[];
  skips: { name: string; reason: string }[];
  runs?: BenchmarkResult[];
}

export interface Profile {
  name: ProfileName;
  samples: number;
  branches: number;
  fsBytes: number[];
}

const PROFILES: Record<ProfileName, Profile> = {
  smoke: { name: "smoke", samples: 3, branches: 8, fsBytes: [4 * 1024] },
  standard: {
    name: "standard",
    samples: 30,
    branches: 1_000,
    fsBytes: [4 * 1024, 1024 * 1024],
  },
  stress: {
    name: "stress",
    samples: 100,
    branches: 10_000,
    fsBytes: [4 * 1024, 1024 * 1024, 16 * 1024 * 1024],
  },
};

export function profile(name: string | undefined): Profile {
  if (name === undefined) return { ...PROFILES.smoke, fsBytes: [...PROFILES.smoke.fsBytes] };
  if (!(name in PROFILES)) throw new Error(`unknown profile "${name}"`);
  const p = PROFILES[name as ProfileName];
  return { ...p, fsBytes: [...p.fsBytes] };
}

function percentile(sorted: number[], q: number): number {
  return sorted[Math.max(0, Math.ceil(q * sorted.length) - 1)]!;
}

export function statistics(values: readonly number[]): Stats | null {
  if (values.length === 0) return null;
  if (values.some((v) => !Number.isFinite(v) || v < 0))
    throw new Error("measurement samples must be finite and non-negative");
  const sorted = [...values].sort((a, b) => a - b);
  return {
    count: sorted.length,
    p50: percentile(sorted, 0.5),
    p95: percentile(sorted, 0.95),
  };
}

export class ResultBuilder {
  readonly result: BenchmarkResult;
  private readonly byKey = new Map<string, Measurement>();

  constructor(run: BenchmarkResult["run"]) {
    this.result = {
      schema: "agentos.benchmark.v1",
      run,
      measurements: [],
      checks: [],
      skips: [],
    };
  }

  sample(
    name: string,
    unit: Unit,
    value: number,
    dimensions: Record<string, string | number | boolean> = {},
  ): void {
    const m = this.measurement(name, unit, dimensions);
    if (!Number.isFinite(value) || value < 0)
      throw new Error(`${name} produced an invalid sample: ${value}`);
    m.samples.push(value);
    m.stats = statistics(m.samples);
  }

  failure(
    name: string,
    unit: Unit,
    iteration: number,
    error: unknown,
    dimensions: Record<string, string | number | boolean> = {},
  ): void {
    const m = this.measurement(name, unit, dimensions);
    m.failures.push({
      iteration,
      error: error instanceof Error ? error.message : String(error),
    });
  }

  check(name: string, ok: boolean, detail?: string): void {
    this.result.checks.push({ name, ok, ...(detail === undefined ? {} : { detail }) });
  }

  skip(name: string, reason: string): void {
    this.result.skips.push({ name, reason });
  }

  private measurement(
    name: string,
    unit: Unit,
    dimensions: Record<string, string | number | boolean>,
  ): Measurement {
    const key = `${name}\0${unit}\0${JSON.stringify(
      Object.entries(dimensions).sort(([a], [b]) => a.localeCompare(b)),
    )}`;
    let m = this.byKey.get(key);
    if (!m) {
      m = { name, unit, dimensions, samples: [], failures: [], stats: null };
      this.byKey.set(key, m);
      this.result.measurements.push(m);
    }
    return m;
  }
}

export function parseArgs(argv: string[]): {
  profile: Profile;
  output?: string;
  hostCostPerHour?: number;
} {
  let selected = profile(undefined);
  let output: string | undefined;
  let hostCostPerHour: number | undefined;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!;
    const value = argv[i + 1];
    if (arg === "--profile" && value) {
      selected = profile(value);
      i++;
    } else if (arg === "--samples" && value) {
      selected.samples = positiveInt(value, arg);
      i++;
    } else if (arg === "--branches" && value) {
      selected.branches = positiveInt(value, arg);
      i++;
    } else if (arg === "--output" && value) {
      output = value;
      i++;
    } else if (arg === "--host-cost-per-hour" && value) {
      hostCostPerHour = Number(value);
      if (!Number.isFinite(hostCostPerHour) || hostCostPerHour < 0)
        throw new Error(`${arg} must be a non-negative number`);
      i++;
    } else {
      throw new Error(`unknown or incomplete argument: ${arg}`);
    }
  }
  return { profile: selected, output, hostCostPerHour };
}

function positiveInt(value: string, flag: string): number {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1)
    throw new Error(`${flag} must be a positive integer`);
  return parsed;
}
