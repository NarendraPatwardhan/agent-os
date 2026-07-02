import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  decodeDirEntries,
  decodeExecOutcome,
  decodeExecRequest,
  decodeFileStat,
  decodeRelayEvent,
  decodeSvcRequest,
  decodeSvcResponse,
  encodeDirEntries,
  encodeExecOutcome,
  encodeExecRequest,
  encodeFileStat,
  encodeRelayEvent,
  encodeSvcRequest,
  encodeSvcResponse,
  WireError,
} from "../../contracts/gen/ctl.gen.js";

type VectorDoc = {
  schema: number;
  positive: Array<{ message: string; description: string; hex: string }>;
  negative: Array<{ message: string; name: string; hex: string; error: string }>;
};

const te = new TextEncoder();

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function runfile(rel: string | undefined, envVar: string): string {
  if (!rel) throw new Error(`${envVar} is not set`);
  const rf = process.env.RUNFILES_DIR;
  if (!rf) throw new Error("RUNFILES_DIR is not set");
  return join(rf, rel);
}

function vectors(): VectorDoc {
  return JSON.parse(readFileSync(runfile(process.env.MC_CONTROL_VECTORS, "MC_CONTROL_VECTORS"), "utf8"));
}

function hex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function bytes(hexString: string): Uint8Array {
  assert(hexString.length % 2 === 0, "hex vector must have an even length");
  const out = new Uint8Array(hexString.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = Number.parseInt(hexString.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function positive(message: string): Uint8Array {
  const found = vectors().positive.find((v) => v.message === message);
  if (!found) throw new Error(`missing positive vector for ${message}`);
  return bytes(found.hex);
}

function assertEqualBytes(actual: Uint8Array, expected: Uint8Array, message: string): void {
  assert(actual.length === expected.length, `${message}: length ${actual.length} !== ${expected.length}`);
  for (let i = 0; i < actual.length; i++) {
    assert(actual[i] === expected[i], `${message}: byte ${i} ${actual[i]} !== ${expected[i]}`);
  }
}

function assertOptionalBytes(actual: Uint8Array | null | undefined, expected: Uint8Array, message: string): void {
  assert(actual !== undefined && actual !== null, `${message}: missing bytes`);
  assertEqualBytes(actual, expected, message);
}

function positiveVectors(): void {
  const exec = {
    cmd: "printf $ALPHA && cat",
    cwd: "/work",
    env: { ZED: "last", ALPHA: "first" },
    stdin: new Uint8Array([112, 97, 121, 108, 111, 97, 100, 10, 0]),
  };
  assert(hex(encodeExecRequest(exec)) === hex(positive("ExecRequest")), "ExecRequest fixture drifted");
  const decodedExec = decodeExecRequest(positive("ExecRequest"));
  assert(decodedExec.cmd === exec.cmd && decodedExec.cwd === exec.cwd, "ExecRequest decoded scalar fields changed");
  assert(decodedExec.env.ALPHA === "first" && decodedExec.env.ZED === "last", "ExecRequest decoded env changed");
  assertOptionalBytes(decodedExec.stdin, exec.stdin, "ExecRequest decoded stdin changed");

  const outcome = { exit_code: 7, stdout: te.encode("out\n"), stderr: te.encode("err\n") };
  assert(hex(encodeExecOutcome(outcome)) === hex(positive("ExecOutcome")), "ExecOutcome fixture drifted");
  const decodedOutcome = decodeExecOutcome(positive("ExecOutcome"));
  assert(decodedOutcome.exit_code === 7, "ExecOutcome exit code changed");
  assertEqualBytes(decodedOutcome.stdout, outcome.stdout, "ExecOutcome stdout changed");
  assertEqualBytes(decodedOutcome.stderr, outcome.stderr, "ExecOutcome stderr changed");

  const stat = { size: 12345, is_dir: false, is_symlink: true, nlink: 2, mode: 0o120777 };
  assert(hex(encodeFileStat(stat)) === hex(positive("FileStat")), "FileStat fixture drifted");
  const decodedStat = decodeFileStat(positive("FileStat"));
  assert(decodedStat.size === 12345 && decodedStat.is_symlink && decodedStat.nlink === 2, "FileStat decoded fields changed");

  const entries = {
    entries: [
      { name: "a.txt", is_dir: false, is_symlink: false },
      { name: "link", is_dir: false, is_symlink: true },
      { name: "sub", is_dir: true, is_symlink: false },
    ],
  };
  assert(hex(encodeDirEntries(entries)) === hex(positive("DirEntries")), "DirEntries fixture drifted");
  const decodedEntries = decodeDirEntries(positive("DirEntries"));
  assert(decodedEntries.entries.length === 3, "DirEntries decoded length changed");
  assert(decodedEntries.entries[1]?.name === "link" && decodedEntries.entries[1]?.is_symlink, "DirEntries symlink changed");

  const svcRequest = { service: "kv", request: te.encode("put\0answer\0forty-two") };
  assert(hex(encodeSvcRequest(svcRequest)) === hex(positive("SvcRequest")), "SvcRequest fixture drifted");
  const decodedSvcRequest = decodeSvcRequest(positive("SvcRequest"));
  assert(decodedSvcRequest.service === "kv", "SvcRequest service changed");
  assertEqualBytes(decodedSvcRequest.request, svcRequest.request, "SvcRequest body changed");

  const svcResponse = { status: 0, body: te.encode("42") };
  assert(hex(encodeSvcResponse(svcResponse)) === hex(positive("SvcResponse")), "SvcResponse fixture drifted");
  const decodedSvcResponse = decodeSvcResponse(positive("SvcResponse"));
  assert(decodedSvcResponse.status === 0, "SvcResponse status changed");
  assertEqualBytes(decodedSvcResponse.body, svcResponse.body, "SvcResponse body changed");

  const relay = {
    kind: "host_call",
    handle: 42,
    name: "tool.exec",
    body: new Uint8Array([0, 1, 2, 255]),
    args_digest: "sha256:0123456789abcdef",
  };
  assert(hex(encodeRelayEvent(relay)) === hex(positive("RelayEvent")), "RelayEvent fixture drifted");
  const decodedRelay = decodeRelayEvent(positive("RelayEvent"));
  assert(decodedRelay.kind === "host_call" && decodedRelay.handle === 42, "RelayEvent scalar fields changed");
  assert(decodedRelay.name === "tool.exec", "RelayEvent name changed");
  assertOptionalBytes(decodedRelay.body, relay.body, "RelayEvent body changed");
  assert(decodedRelay.args_digest === "sha256:0123456789abcdef", "RelayEvent args digest changed");
}

function negativeVectors(): void {
  const expectedMessages: Record<string, string> = {
    WrongMessage: "wrong message id",
    UnsupportedVersion: "unsupported message version",
    NonCanonicalMap: "non-canonical strmap",
    TrailingBytes: "trailing bytes",
  };
  for (const vector of vectors().negative) {
    try {
      if (vector.message === "ExecRequest") {
        decodeExecRequest(bytes(vector.hex));
      } else {
        throw new Error(`unhandled negative vector message ${vector.message}`);
      }
    } catch (error) {
      assert(error instanceof WireError, `${vector.message}:${vector.name}: expected WireError`);
      const expected = expectedMessages[vector.error];
      assert(expected !== undefined, `${vector.message}:${vector.name}: unknown expected error ${vector.error}`);
      assert(
        error.message === expected,
        `${vector.message}:${vector.name}: ${JSON.stringify(error.message)} !== ${JSON.stringify(expected)}`,
      );
      continue;
    }
    throw new Error(`${vector.message}:${vector.name}: decoded unexpectedly`);
  }
}

positiveVectors();
negativeVectors();
console.log("control conformance vectors match Rust/TS generated codecs");
