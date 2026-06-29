// Cross-host policy parity (A3): this test and the Rust
// //memcontainers/hosts/wasmtime:policy_parity_test consume the SAME vector file, so policy.ts and
// policy.rs cannot drift in rule resolution or pattern rejection. The vectors arrive as a bazel
// runfile via env, exactly like the other JS host tests. Unlike Rust (which models owner/action as
// enums), TS validates them at runtime — so this side also exercises the invalid-owner/action rejects.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { ToolPolicySet } from "../src/policy.js";
import type { ToolPolicyRule } from "../src/policy.js";

function runfile(rel: string | undefined, envVar: string): string {
  if (!rel) throw new Error(`${envVar} is not set (this test must run under \`bazel test\`)`);
  const rf = process.env.RUNFILES_DIR;
  if (!rf) throw new Error("RUNFILES_DIR is not set (run under bazel)");
  return join(rf, rel);
}

interface ResolveCase {
  name: string;
  rules: ToolPolicyRule[];
  address: string;
  expect: string | null;
}

interface RejectCase {
  name: string;
  rule: ToolPolicyRule;
}

function main(): void {
  const path = runfile(process.env.MC_POLICY_VECTORS, "MC_POLICY_VECTORS");
  const vectors = JSON.parse(readFileSync(path, "utf8")) as {
    resolve: ResolveCase[];
    reject: RejectCase[];
  };

  for (const c of vectors.resolve) {
    const got = new ToolPolicySet(c.rules).resolve(c.address);
    const want = c.expect ?? null;
    if (got !== want) {
      throw new Error(
        `resolve parity '${c.name}': got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`,
      );
    }
  }

  for (const c of vectors.reject) {
    let threw = false;
    try {
      new ToolPolicySet([c.rule]);
    } catch {
      threw = true;
    }
    if (!threw) throw new Error(`reject parity '${c.name}': construction should have thrown`);
  }

  console.log(
    `POLICY PARITY OK — ${vectors.resolve.length} resolve + ${vectors.reject.length} reject cases agree with policy.rs`,
  );
}

main();
