import assert from "node:assert/strict";
import { ResultBuilder } from "../shared/result.js";
import { validate } from "../tools/validate.js";

function result() {
  const builder = new ResultBuilder({
    id: "schema-test",
    timestamp: new Date().toISOString(),
    runner: "test",
    runtime: "test",
    profile: "smoke",
    system: {},
    artifacts: [],
  });
  builder.sample("boot.ready", "ms", 1, { image: "minimal" });
  return builder.result;
}

assert.doesNotThrow(() => validate(result()));

const detached = result();
detached.measurements[0]!.stats!.count = 2;
assert.throws(() => validate(detached), /must equal raw sample count/);

const negative = result();
negative.measurements[0]!.samples[0] = -1;
assert.throws(() => validate(negative), /finite non-negative/);

const wrongSummary = result();
wrongSummary.measurements[0]!.stats!.p50 = 42;
assert.throws(() => validate(wrongSummary), /does not match the raw samples/);

const unknownUnit = result();
unknownUnit.measurements[0]!.unit = "bananas" as "ms";
assert.throws(() => validate(unknownUnit), /unknown measurement unit/);

const badDimension = result();
(badDimension.measurements[0]!.dimensions as Record<string, unknown>).image = null;
assert.throws(() => validate(badDimension), /expected string, finite number, or boolean/);

console.log("benchmark result validator: OK");
