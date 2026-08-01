/**
 * P2.8 — executable K20 orch goldens (shared JSON with BEAM).
 * Loads testdata/orch/*.json and drives FixtureSmartHttp + GitRemoteOrchestrator.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import {
  FixtureSmartHttp,
  GitEngine,
  GitRemoteOrchestrator,
} from "../src/git/index.js";

interface GoldenRef {
  name: string;
  hash?: string;
  hash_from?: string;
}

interface GoldenFixture {
  url: string;
  allowed_origins: string[];
  refs: GoldenRef[];
  pack?: string;
  pack_from?: string;
  /** When true, orchestrator rejects push (R81). */
  read_only?: boolean;
  /** Local engine ops before orch steps (D32 push_success). */
  setup?: { op: string; args?: Record<string, unknown> }[];
}

interface StepExpect {
  ok: boolean;
  code?: number;
  stdout_contains?: string[];
  stderr_contains?: string[];
  stdout_not_contains?: string[];
  stderr_not_contains?: string[];
}

interface GoldenStep {
  id: string;
  ok?: boolean;
  op?: string;
  args?: Record<string, unknown>;
  expect?: StepExpect;
  error_contains?: string[];
  notes?: string;
}

interface Golden {
  name: string;
  version: number;
  fixture: GoldenFixture;
  steps: GoldenStep[];
}

const GOLDEN_NAMES = [
  "clone_success_steps.json",
  "clone_empty_pack_fail.json",
  "origin_denied.json",
  "fetch_success_steps.json",
  "pull_ff_steps.json",
  "push_readonly.json",
  "push_success_steps.json",
] as const;

function engineDir(): string {
  const jsRel = process.env.MC_GIT_ENGINE_JS || "";
  const rf = process.env.RUNFILES_DIR;
  const candidates = [
    jsRel && rf ? join(rf, jsRel) : "",
    jsRel && rf ? join(rf, "_main", jsRel) : "",
    jsRel,
    join(process.cwd(), "bazel-bin/memcontainers/lib/git-engine/git_engine.mjs"),
  ];
  for (const c of candidates) {
    if (c && existsSync(c)) return dirname(c);
    if (c && existsSync(join(c, "git_engine.mjs"))) return c;
  }
  throw new Error(`engine dir not found (MC_GIT_ENGINE_JS=${jsRel})`);
}

function orchDir(): string {
  const env = process.env.MC_GIT_ORCH_GOLDEN_DIR || "";
  const rf = process.env.RUNFILES_DIR;
  const candidates = [
    env,
    env && rf ? join(rf, env) : "",
    env && rf ? join(rf, "_main", env) : "",
    // genrule outs under this package (rules_js bin layout)
    rf ? join(rf, "memcontainers/sdk-js/core/testdata/orch") : "",
    rf ? join(rf, "_main/memcontainers/sdk-js/core/testdata/orch") : "",
    // SSoT under git-engine (dev / non-runfiles)
    rf ? join(rf, "memcontainers/lib/git-engine/testdata/orch") : "",
    rf ? join(rf, "_main/memcontainers/lib/git-engine/testdata/orch") : "",
    join(process.cwd(), "memcontainers/lib/git-engine/testdata/orch"),
    join(process.cwd(), "memcontainers/sdk-js/core/testdata/orch"),
    resolve(
      dirname(new URL(import.meta.url).pathname),
      "../../../lib/git-engine/testdata/orch",
    ),
  ];
  for (const c of candidates) {
    if (c && existsSync(join(c, "clone_success_steps.json"))) return c;
  }
  throw new Error(
    `orch golden dir not found (MC_GIT_ORCH_GOLDEN_DIR=${env}, RUNFILES_DIR=${rf})`,
  );
}

function readText(path: string): string {
  return readFileSync(path, "utf8");
}

function readBytes(path: string): Uint8Array {
  return new Uint8Array(readFileSync(path));
}

function resolveBesideGolden(goldenPath: string, rel: string): string {
  return resolve(dirname(goldenPath), rel);
}

function loadFixturePack(
  goldenPath: string,
  fixture: GoldenFixture,
): Uint8Array {
  if (typeof fixture.pack === "string") {
    return new TextEncoder().encode(fixture.pack);
  }
  if (fixture.pack_from) {
    return readBytes(resolveBesideGolden(goldenPath, fixture.pack_from));
  }
  return new Uint8Array(0);
}

function loadRefs(
  goldenPath: string,
  fixture: GoldenFixture,
): { name: string; hash: string }[] {
  return fixture.refs.map((r) => {
    let hash = r.hash ?? "";
    if (r.hash_from) {
      hash = readText(resolveBesideGolden(goldenPath, r.hash_from)).trim();
    }
    if (!hash) throw new Error(`golden ref ${r.name} missing hash`);
    return { name: r.name, hash };
  });
}

function assertContains(hay: string, needles: string[] | undefined, label: string) {
  if (!needles) return;
  for (const n of needles) {
    if (!hay.includes(n)) {
      throw new Error(`${label}: expected to contain ${JSON.stringify(n)}; got ${JSON.stringify(hay)}`);
    }
  }
}

function assertNotContains(hay: string, needles: string[] | undefined, label: string) {
  if (!needles) return;
  for (const n of needles) {
    if (hay.includes(n)) {
      throw new Error(`${label}: must not contain ${JSON.stringify(n)}; got ${JSON.stringify(hay)}`);
    }
  }
}

async function runGolden(dir: string, engBase: string, name: string): Promise<void> {
  const goldenPath = join(dir, name);
  if (!existsSync(goldenPath)) throw new Error(`missing golden ${goldenPath}`);
  const golden = JSON.parse(readText(goldenPath)) as Golden;
  const fixture = golden.fixture;
  const pack = loadFixturePack(goldenPath, fixture);
  const refs = loadRefs(goldenPath, fixture);

  const eng = await GitEngine.load({ baseUrl: engBase });
  const http = new FixtureSmartHttp();
  http.add(fixture.url, refs, pack);

  // Optional local setup (init/commit) before remote orch steps.
  for (const step of fixture.setup ?? []) {
    const r = await eng.run({ op: step.op, args: step.args ?? {} });
    if (r.ok === false) {
      throw new Error(
        `${name}: setup op ${step.op} failed: ${JSON.stringify(r)}`,
      );
    }
  }

  const orch = new GitRemoteOrchestrator(eng, {
    http,
    allowOrigins: fixture.allowed_origins,
    readOnly: !!fixture.read_only,
  });

  const execSteps = golden.steps.filter((s) => s.op && s.expect);
  if (execSteps.length === 0) {
    throw new Error(`${name}: no executable orchestrator_response step`);
  }

  for (const step of execSteps) {
    const resp = await orch.handle({
      op: step.op!,
      args: step.args ?? {},
    });
    const exp = step.expect!;
    if (resp.ok !== exp.ok) {
      throw new Error(
        `${name}/${step.id}: ok expected ${exp.ok}, got ${resp.ok}: ${JSON.stringify(resp)}`,
      );
    }
    if (exp.code !== undefined && resp.code !== exp.code) {
      throw new Error(
        `${name}/${step.id}: code expected ${exp.code}, got ${resp.code}`,
      );
    }
    const stdout = String(resp.stdout ?? "");
    const stderr = String(resp.stderr ?? "");
    assertContains(stdout, exp.stdout_contains, `${name}/${step.id} stdout`);
    assertContains(stderr, exp.stderr_contains, `${name}/${step.id} stderr`);
    assertNotContains(stdout, exp.stdout_not_contains, `${name}/${step.id} stdout`);
    assertNotContains(stderr, exp.stderr_not_contains, `${name}/${step.id} stderr`);
  }

  // Algorithm step ids must be present (documentation + dual-host contract).
  if (!golden.steps.some((s) => s.id === "orchestrator_response")) {
    throw new Error(`${name}: missing orchestrator_response step`);
  }

  await eng.close();
  console.log(`  ${name}: OK (${golden.steps.length} steps)`);
}

async function main() {
  const dir = orchDir();
  const engDir = engineDir();
  const baseUrl = pathToFileURL(engDir.endsWith("/") ? engDir : engDir + "/").href;
  console.log(`git_orch_golden: orch=${dir}`);

  for (const name of GOLDEN_NAMES) {
    await runGolden(dir, baseUrl, name);
  }

  console.log("git_orch_golden.test SUCCESS");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
