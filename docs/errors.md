# Errors and diagnostics

AgentOS distinguishes guest outcomes from host/API failures. Handling that distinction explicitly
produces better retries and prevents leaked VMs.

## Guest command failure

`vm.exec()` and `vm.luau()` resolve normally when the guest process exits nonzero.

```js
const result = await vm.exec("compile-project");
if (result.exitCode !== 0) {
  throw new Error(`compile failed (${result.exitCode}): ${result.stderr}`);
}
```

This preserves ordinary Unix semantics and allows callers to inspect stdout/stderr from failed tools.

LLB exec is different: a nonzero build step rejects the solve because a failed vertex cannot produce
the requested build result.

## SDK and host failure

Promises reject for failures such as:

- unsupported runtime or invalid option combinations;
- missing/corrupt kernel, image, catalog compiler, or snapshot bytes;
- browser artifact requirements;
- content-store misses or malformed digests;
- remote HTTP/WebSocket failures;
- invalid tool, policy, mount, cron, or LLB configuration;
- strict restore with missing attachments;
- snapshot capture during in-flight egress; and
- host driver exceptions.

These errors describe the control operation, not a guest process exit.

## Permission denial

A network or tool-approval denial becomes an ordinary error at the guest boundary. The host must not
trap or expose credentials. Record the `PermissionRequest` and decision in the embedding application if
an audit log is required.

## Driver errors

Custom mount drivers may throw an Error with a supported POSIX `code`. Unknown or uncoded exceptions
map to `EIO`.

See [Mounts and drivers](./mounts-drivers.md#driver-errors).

## Restore errors

Useful categories to preserve in logs:

- malformed or unsupported snapshot header;
- missing incremental baseline digest;
- image/kernel incompatibility;
- missing host tools or connections under strict catalog-attachment mode;
- remote destination or upload failure.

Do not retry a malformed snapshot indefinitely. A missing attachment may be resolved by supplying the
resource; a missing baseline requires retrieving the exact named object. Mount drivers are also
host-owned and may need to be supplied again, but they are not catalog entries and are not covered by
`restoreAttachments` validation.

## Remote diagnostics

Log at least:

- endpoint and VM id, but never tokens or connection credentials;
- HTTP status and operation;
- whether failure happened before or after VM creation;
- WebSocket reconnect state for host tools/mounts/sessions; and
- server request/correlation id when the host provides one.

`memoryBytes() === 0` on a remote VM is an unavailable metric, not an error.

## Status and quiescence

```js
const status = await vm.status();
console.log({
  running: status.running,
  memoryBytes: status.memoryBytes,
  inflightEgress: status.inflightEgress,
});
```

Use status for observation. Do not implement snapshot safety by polling alone; the capture operation
performs the authoritative atomic refusal when work is still in flight.

## Cleanup pattern

```js
let vm;
try {
  vm = await mc.create(options);
  const result = await vm.exec(command);
  if (result.exitCode !== 0) {
    return { ok: false, exitCode: result.exitCode, stderr: result.stderr };
  }
  return { ok: true, stdout: result.stdout };
} finally {
  if (vm) await vm.close().catch((error) => console.error("close failed", error));
}
```

If create rejects, it cleans partial backend construction internally. Once a `Vm` has been returned,
the caller owns close.

## Binary data

Use `stdoutBytes`, `stderrBytes`, `vm.fs.read()`, and raw service responses for binary protocols. A
decoded string can contain replacement characters and should not be re-encoded as if it were the
original artifact.

## Secret hygiene

Never include these in error messages or logs:

- remote Bearer tokens;
- connection auth values;
- S3 secret keys/session tokens;
- full outgoing headers after credential splice; or
- arbitrary guest tool arguments unless application policy permits them.

Permission events intentionally contain host-computed routing facts rather than injected credentials.
