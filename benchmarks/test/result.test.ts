import assert from "node:assert/strict";
import { profile, ResultBuilder, statistics } from "../lib/result.js";

const stats = statistics([5, 1, 3, 2, 4])!;
assert.equal(stats.count, 5);
assert.equal(stats.p50, 3);
assert.equal(stats.p95, 5);

const builder = new ResultBuilder({
  id: "test",
  timestamp: new Date().toISOString(),
  runner: "test",
  runtime: "test",
  profile: "smoke",
  system: {},
  artifacts: [],
});
builder.sample("boot", "ms", 1, { image: "minimal" });
builder.sample("boot", "ms", 2, { image: "loom" });
assert.equal(builder.result.measurements.length, 2);

const first = profile("smoke");
first.samples = 99;
assert.equal(profile("smoke").samples, 3);
assert.equal(profile("stress").branches, 10_000);

assert.throws(() => statistics([-1]));
assert.throws(() => statistics([Number.NaN]));
console.log("benchmark result statistics: OK");
