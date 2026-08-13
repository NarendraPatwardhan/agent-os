import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

const wasmPath = join(process.env.RUNFILES_DIR, process.env.AGENTOS_GIT_WASM);
const wasmBytes = await readFile(wasmPath);

const module = await WebAssembly.compile(wasmBytes);
assert.deepEqual(WebAssembly.Module.imports(module), []);
const exportNames = WebAssembly.Module.exports(module).map(({ name }) => name).sort();
assert.deepEqual(exportNames, [
  "ao_git_abi_version",
  "ao_git_buffer_alloc",
  "ao_git_buffer_free",
  "ao_git_capabilities",
  "ao_git_execute",
  "ao_git_result_free",
  "ao_git_result_len",
  "ao_git_result_read",
  "ao_git_session_close",
  "ao_git_session_open",
  "memory",
].sort());

const { exports: e } = await WebAssembly.instantiate(module, {});
assert.equal(e.ao_git_abi_version(), 0x0001_0000);
const encoder = new TextEncoder();

function put16(out, offset, value) { new DataView(out.buffer).setUint16(offset, value, true); }
function put32(out, offset, value) { new DataView(out.buffer).setUint32(offset, value, true); }

function copyIn(bytes) {
  const ptr = e.ao_git_buffer_alloc(bytes.length);
  assert.notEqual(ptr, 0);
  new Uint8Array(e.memory.buffer, ptr, bytes.length).set(bytes);
  return ptr;
}

function readResult(handle) {
  assert.notEqual(handle, 0);
  const length = e.ao_git_result_len(handle);
  assert.ok(length >= 20);
  const ptr = e.ao_git_buffer_alloc(length);
  assert.notEqual(ptr, 0);
  assert.equal(e.ao_git_result_read(handle, 0, ptr, length), length);
  const bytes = new Uint8Array(length);
  bytes.set(new Uint8Array(e.memory.buffer, ptr, length));
  assert.equal(e.ao_git_buffer_free(ptr, length), 0);
  assert.equal(e.ao_git_result_free(handle), 0);
  return bytes;
}

function sessionConfig() {
  const root = encoder.encode("");
  const out = new Uint8Array(3 + 2 + 1 + 4 + root.length + 1);
  put16(out, 0, 1);
  out[2] = 1;
  put16(out, 3, 1);
  out[5] = 0;
  put32(out, 6, root.length);
  out.set(root, 10);
  out[10 + root.length] = 0;
  return out;
}

function request(opcode, requestId, payload = new Uint8Array()) {
  const out = new Uint8Array(20 + payload.length);
  out.set(encoder.encode("AOGQ"), 0);
  put16(out, 4, 1);
  put16(out, 6, 0);
  put16(out, 8, opcode);
  put16(out, 10, 0);
  put32(out, 12, requestId);
  put32(out, 16, payload.length);
  out.set(payload, 20);
  return out;
}

function bytesField(bytes) {
  const out = new Uint8Array(4 + bytes.length);
  put32(out, 0, bytes.length);
  out.set(bytes, 4);
  return out;
}

function concat(...parts) {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) { out.set(part, offset); offset += part.length; }
  return out;
}

function u16(value) { const out = new Uint8Array(2); put16(out, 0, value); return out; }
function u32(value) { const out = new Uint8Array(4); put32(out, 0, value); return out; }
function i64(value) { const out = new Uint8Array(8); new DataView(out.buffer).setBigInt64(0, BigInt(value), true); return out; }
function i32(value) { const out = new Uint8Array(4); new DataView(out.buffer).setInt32(0, value, true); return out; }

function fileWrite(path, data) {
  return concat(
    u16(6), Uint8Array.of(1), bytesField(encoder.encode(path)),
    Uint8Array.of(0, 0, 0, 0, 1), bytesField(encoder.encode(data)), Uint8Array.of(0),
  );
}

function signature(name, email, seconds) {
  return concat(u16(4), Uint8Array.of(1), bytesField(encoder.encode(name)), bytesField(encoder.encode(email)), i64(seconds), i32(0));
}

function porcelain({ action, revision, message, paths = [], author, committer }) {
  const sorted = [...paths].sort();
  const map = [u32(sorted.length)];
  for (const path of sorted) map.push(bytesField(encoder.encode(path)), bytesField(new Uint8Array()));
  const optional = value => value === undefined ? Uint8Array.of(0) : concat(Uint8Array.of(1), bytesField(value));
  return concat(
    u16(7), Uint8Array.of(1), u16(action), u32(0),
    optional(revision === undefined ? undefined : encoder.encode(revision)),
    Uint8Array.of(0),
    optional(message === undefined ? undefined : encoder.encode(message)),
    ...map,
    Uint8Array.of(0, 0),
    optional(author), optional(committer),
  );
}

function run(session, frame) {
  const ptr = copyIn(frame);
  const handle = e.ao_git_execute(session, ptr, frame.length);
  assert.equal(e.ao_git_buffer_free(ptr, frame.length), 0);
  return readResult(handle);
}

const config = sessionConfig();
const configPtr = copyIn(config);
const opened = readResult(e.ao_git_session_open(configPtr, config.length));
assert.equal(e.ao_git_buffer_free(configPtr, config.length), 0);
assert.equal(new TextDecoder().decode(opened.subarray(0, 4)), "AOGR");
assert.equal(new DataView(opened.buffer).getUint16(10, true), 0);
assert.equal(new DataView(opened.buffer).getUint16(20, true), 15);
assert.equal(opened[29], 1);
const session = new DataView(opened.buffer).getUint32(30, true);
assert.notEqual(session, 0);

const described = run(session, request(1, 41));
assert.equal(new DataView(described.buffer).getUint16(8, true), 1);
assert.equal(new DataView(described.buffer).getUint16(10, true), 0);
assert.equal(new DataView(described.buffer).getUint32(12, true), 41);
assert.equal(new DataView(described.buffer).getUint16(20, true), 2);
assert.ok(new TextDecoder().decode(described).includes("fdf9124c2aab83b6c3297be4bae8045ada7661f8"));

const initialized = run(session, request(16, 42));
assert.equal(new DataView(initialized.buffer).getUint16(10, true), 0);

assert.equal(new DataView(run(session, request(258, 44, fileWrite("nested/hello.txt", "hello from shared core\n"))).buffer).getUint16(10, true), 0);
const untracked = run(session, request(272, 45));
assert.equal(new DataView(untracked.buffer).getUint16(10, true), 0);
assert.ok(new TextDecoder().decode(untracked).includes("nested/hello.txt"));
assert.equal(new DataView(run(session, request(273, 46, porcelain({ action: 4, paths: ["nested/hello.txt"] }))).buffer).getUint16(10, true), 0);
const sig = signature("Artifact Test", "artifact@example.invalid", 1_700_000_000);
assert.equal(new DataView(run(session, request(275, 47, porcelain({ action: 3, message: "artifact commit", author: sig, committer: sig }))).buffer).getUint16(10, true), 0);
const resolved = run(session, request(277, 48, porcelain({ action: 2, revision: "HEAD" })));
assert.equal(new DataView(resolved.buffer).getUint16(10, true), 0);
assert.equal(new DataView(resolved.buffer).getUint16(20, true), 20);
assert.equal(e.ao_git_session_close(session), 0);
assert.equal(e.ao_git_session_close(session), 1, "stale session handle must fail");
const stale = run(session, request(1, 43));
assert.equal(new DataView(stale.buffer).getUint16(10, true), 2);

console.log(JSON.stringify({ imports: 0, wasm_bytes: wasmBytes.length, lifecycle: true, local_commit: true, stale_handles: true }));
