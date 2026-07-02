import {
  decodeExecRequest,
  decodeRelayEvent,
  encodeExecRequest,
  encodeRelayEvent,
  WireError as ControlWireError,
} from "../gen/ctl.gen.js";
import {
  decodeDefinition,
  decodeNodeDigest,
  encodeDefinition,
  encodeNodeDigest,
  WireError as LlbWireError,
  type BuildOp,
  type Definition,
  type NodeDigest,
} from "../gen/llb.gen.js";

const te = new TextEncoder();

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function assertBytes(actual: Uint8Array | null | undefined, expected: Uint8Array, message: string): void {
  assert(actual !== undefined && actual !== null, `${message}: missing bytes`);
  assert(actual.length === expected.length, `${message}: length ${actual.length} !== ${expected.length}`);
  for (let i = 0; i < expected.length; i++) {
    assert(actual[i] === expected[i], `${message}: byte ${i} ${actual[i]} !== ${expected[i]}`);
  }
}

function assertEqualBytes(actual: Uint8Array, expected: Uint8Array, message: string): void {
  assertBytes(actual, expected, message);
}

function assertThrowsWire(
  fn: () => unknown,
  WireError: typeof ControlWireError | typeof LlbWireError,
  message: string,
): void {
  try {
    fn();
  } catch (error) {
    assert(error instanceof WireError, `${message}: expected ${WireError.name}, got ${(error as Error).name}`);
    return;
  }
  throw new Error(`${message}: expected throw`);
}

function u8(out: number[], value: number): void {
  out.push(value & 0xff);
}

function u16(out: number[], value: number): void {
  out.push(value & 0xff, (value >>> 8) & 0xff);
}

function u32(out: number[], value: number): void {
  out.push(value & 0xff, (value >>> 8) & 0xff, (value >>> 16) & 0xff, (value >>> 24) & 0xff);
}

function bytes(out: number[], value: Uint8Array): void {
  u32(out, value.length);
  out.push(...value);
}

function str(out: number[], value: string): void {
  bytes(out, te.encode(value));
}

function nonCanonicalExecRequestFrame(): Uint8Array {
  const out: number[] = [];
  u16(out, 1);
  u8(out, 1);
  str(out, "env");
  u8(out, 0);
  u32(out, 2);
  str(out, "z");
  str(out, "last");
  str(out, "a");
  str(out, "first");
  u8(out, 0);
  return Uint8Array.from(out);
}

function emptyBuildOp(kind: number): BuildOp {
  return { kind, parts: [], copy_paths: [], env: {}, mounts: [] };
}

function controlCodecs(): void {
  const unsorted = encodeExecRequest({
    cmd: "cat",
    cwd: "/tmp",
    env: { ZED: "z", ALPHA: "a" },
    stdin: new Uint8Array(),
  });
  const sorted = encodeExecRequest({
    cmd: "cat",
    cwd: "/tmp",
    env: { ALPHA: "a", ZED: "z" },
    stdin: new Uint8Array(),
  });
  assertEqualBytes(unsorted, sorted, "ExecRequest env map must encode canonically");

  const exec = decodeExecRequest(unsorted);
  assert(exec.cmd === "cat", "ExecRequest cmd changed");
  assert(exec.cwd === "/tmp", "ExecRequest cwd changed");
  assert(exec.env.ALPHA === "a" && exec.env.ZED === "z", "ExecRequest env changed");
  assertBytes(exec.stdin, new Uint8Array(), "ExecRequest empty stdin must stay present");

  assertThrowsWire(() => decodeExecRequest(Uint8Array.from([2, 0, 1])), ControlWireError, "wrong control message id");
  assertThrowsWire(() => decodeExecRequest(Uint8Array.from([1, 0, 2])), ControlWireError, "wrong control version");
  assertThrowsWire(() => decodeExecRequest(unsorted.slice(0, unsorted.length - 1)), ControlWireError, "truncated control frame");
  assertThrowsWire(
    () => decodeExecRequest(Uint8Array.from([...unsorted, 0])),
    ControlWireError,
    "trailing control bytes",
  );
  assertThrowsWire(
    () => decodeExecRequest(nonCanonicalExecRequestFrame()),
    ControlWireError,
    "non-canonical control strmap",
  );

  const relay = decodeRelayEvent(
    encodeRelayEvent({
      kind: "tool_approval",
      handle: 7,
      connection: "github",
      method: "POST",
      url: "https://api.example.test/repos",
      origin: "https://api.example.test",
    }),
  );
  assert(relay.kind === "tool_approval", "RelayEvent kind changed");
  assert(relay.handle === 7, "RelayEvent handle changed");
  assert(relay.args_digest === undefined, "RelayEvent absent args_digest must stay absent");

  const hostCall = decodeRelayEvent(
    encodeRelayEvent({ kind: "host_call", handle: 8, name: "empty", body: new Uint8Array() }),
  );
  assert(hostCall.name === "empty", "RelayEvent host_call name changed");
  assertBytes(hostCall.body, new Uint8Array(), "RelayEvent empty body must stay present");
}

function llbCodecs(): void {
  const source = { ...emptyBuildOp(0), source_ref: "base:latest" };
  const exec = {
    ...emptyBuildOp(7),
    input: 0,
    cmd: "printf $VALUE",
    cwd: "/work",
    env: { ZED: "z", ALPHA: "a" },
    stdin: new Uint8Array(),
    deterministic: true,
    tier: "read-write",
  };
  const definition: Definition = { version: 1, ops: [source, exec], root: 1 };
  const encoded = encodeDefinition(definition);
  const decoded = decodeDefinition(encoded);
  const reencoded = encodeDefinition(decoded);
  assertEqualBytes(reencoded, encoded, "Definition encode/decode must be canonical");
  assert(decoded.ops[1]?.cmd === "printf $VALUE", "Definition nested BuildOp changed");
  assertBytes(decoded.ops[1]?.stdin, new Uint8Array(), "Definition empty stdin must stay present");

  const unsortedDigest: NodeDigest = {
    op: exec,
    edges: [
      { role: "input", digest: "sha256:bbbb" },
      { role: "mount", digest: "sha256:aaaa" },
    ],
    resolved: { z: "last", a: "first" },
    layers: [{ digest: "sha256:cccc", size: 12, producer: "node-1" }],
    kernel_digest: "sha256:kernel",
  };
  const sortedDigest: NodeDigest = {
    ...unsortedDigest,
    op: { ...exec, env: { ALPHA: "a", ZED: "z" } },
    resolved: { a: "first", z: "last" },
  };
  assertEqualBytes(
    encodeNodeDigest(unsortedDigest),
    encodeNodeDigest(sortedDigest),
    "NodeDigest maps must encode canonically",
  );
  const digest = decodeNodeDigest(encodeNodeDigest(unsortedDigest));
  assert(digest.edges.length === 2, "NodeDigest edges list changed");
  assert(digest.layers[0]?.producer === "node-1", "NodeDigest layer list changed");

  assertThrowsWire(() => decodeDefinition(Uint8Array.from([8, 0, 1])), LlbWireError, "wrong LLB message id");
  assertThrowsWire(() => decodeDefinition(Uint8Array.from([3, 0, 2])), LlbWireError, "wrong LLB version");
  assertThrowsWire(() => decodeDefinition(encoded.slice(0, encoded.length - 1)), LlbWireError, "truncated LLB frame");
  assertThrowsWire(() => decodeDefinition(Uint8Array.from([...encoded, 0])), LlbWireError, "trailing LLB bytes");
}

controlCodecs();
llbCodecs();
console.log("contracts generated message codecs are canonical and fail closed");
