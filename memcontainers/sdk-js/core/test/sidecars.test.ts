import assert from "node:assert/strict";
import {
  SIDECAR_ERROR_CLOSING,
  SIDECAR_ERROR_IDEMPOTENCY_CONFLICT,
  SIDECAR_ERROR_PROVIDER_FAILED,
  SIDECAR_ERROR_TIMEOUT,
  SIDECAR_ERROR_UNSUPPORTED_FORK_POLICY,
  decodeSidecarResult,
  encodeSidecarCreate,
} from "@mc/contracts/sidecar";
import {
  EmbeddedSidecarBackend,
  RemoteVmSidecarBackend,
  SidecarError,
  VmSidecars,
  type SidecarAuthority,
  type SidecarCapability,
  type SidecarCreateRequest,
  type SidecarGrant,
  type SidecarGrantDescriptor,
  type SidecarHost,
  type SidecarInstance,
  type SidecarInvokeRequest,
} from "../src/sidecars.js";

const capability: SidecarCapability = {
  kind: "test.echo",
  version: 1,
  contractDigest: "test-echo-v1",
  placements: ["local"],
  fork: "omit",
  maxInstancesPerVm: 2,
};

const grant: SidecarGrant = {
  kind: capability.kind,
  version: capability.version,
  contractDigest: capability.contractDigest,
  guest: true,
  maxInstances: 2,
  fork: "omit",
  config: new Uint8Array(),
};

const descriptor: SidecarGrantDescriptor = {
  contract: { kind: grant.kind, version: grant.version, digest: grant.contractDigest },
  grant,
  host: "runner",
};

class Authority implements SidecarAuthority {
  creates = 0;
  deletes = 0;
  readonly instances = new Map<string, SidecarInstance>();

  async enable(_name: string, _grant: SidecarGrant): Promise<void> {}
  async disable(_name: string, _destroy?: boolean): Promise<void> {}
  async create(request: SidecarCreateRequest): Promise<SidecarInstance> {
    this.creates += 1;
    const instance: SidecarInstance = {
      id: `sc_instance_${this.creates}`,
      grant: request.grant,
      kind: request.kind,
      generation: 1,
      state: "ready",
      createdAtMs: 1,
      expiresAtMs: 60_001,
      metadata: new Uint8Array(),
    };
    this.instances.set(instance.id, instance);
    return instance;
  }
  async retrieve(id: string): Promise<SidecarInstance> { return this.instances.get(id)!; }
  async list(kind?: string): Promise<SidecarInstance[]> { return [...this.instances.values()].filter((item) => !kind || item.kind === kind); }
  async invoke(request: SidecarInvokeRequest): Promise<Uint8Array> { return request.body.slice(); }
  async delete(id: string): Promise<void> { this.deletes += 1; this.instances.delete(id); }
  async close(): Promise<void> {}
}

async function backend(authority = new Authority()): Promise<{ backend: EmbeddedSidecarBackend; authority: Authority }> {
  const host: SidecarHost = {
    async describe() { return { kinds: [capability] }; },
    async attach() { return authority; },
  };
  return {
    backend: await EmbeddedSidecarBackend.attach({ runner: host }, { echo: descriptor }, "vm_test", "local"),
    authority,
  };
}

async function main(): Promise<void> {
  {
    const authority = new Authority();
    const host: SidecarHost = {
      async describe() { return { kinds: [capability] }; },
      async attach() { return authority; },
    };
    const backend = await EmbeddedSidecarBackend.attach({ runner: host }, {}, "vm_facade", "local");
    const descriptors: Record<string, SidecarGrantDescriptor> = {};
    const sidecars = new VmSidecars(backend, descriptors);
    await sidecars.enable("echo", descriptor);
    assert.equal(descriptors.echo?.host, "runner");
    assert.deepEqual((await sidecars.capabilities()).map((item) => item.kind), ["test.echo"]);
    const instance = await sidecars.create({
      grant: "echo",
      kind: "test.echo",
      body: new Uint8Array(),
      idempotencyKey: "facade-create",
    });
    assert.deepEqual(await sidecars.invoke({
      id: instance.id,
      generation: instance.generation,
      grant: instance.grant,
      kind: instance.kind,
      operation: "echo",
      body: new Uint8Array([4, 2]),
    }), new Uint8Array([4, 2]));
    await sidecars.delete(instance.id);
    await sidecars.disable("echo");
    assert.equal(descriptors.echo, undefined);
    await backend.close();
  }

  {
    const attached = await backend();
    const request = { grant: "echo", kind: "test.echo", body: new Uint8Array([1]), idempotencyKey: "create-1" };
    const first = await attached.backend.create(request);
    const second = await attached.backend.create(request);
    assert.equal(second.id, first.id);
    assert.equal(attached.authority.creates, 1);
    await assert.rejects(
      attached.backend.create({ ...request, body: new Uint8Array([2]) }),
      (error: unknown) => error instanceof SidecarError && error.code === SIDECAR_ERROR_IDEMPOTENCY_CONFLICT,
    );
    const concurrent = { ...request, idempotencyKey: "create-2" };
    const [left, right] = await Promise.all([
      attached.backend.create(concurrent),
      attached.backend.create(concurrent),
    ]);
    assert.equal(left.id, right.id);
    assert.equal(attached.authority.creates, 2);
    await attached.backend.close();
  }

  await assert.rejects(
    EmbeddedSidecarBackend.attach(
      { runner: { async describe() { return { kinds: [{ ...capability, fork: "clone" }] }; }, async attach() { return new Authority(); } } },
      { echo: { ...descriptor, grant: { ...grant, fork: "clone" } } },
    ),
    (error: unknown) => error instanceof SidecarError && error.code === SIDECAR_ERROR_UNSUPPORTED_FORK_POLICY,
  );

  await assert.rejects(
    EmbeddedSidecarBackend.attach(
      { runner: { async describe() { return { kinds: [{ ...capability, placements: ["local", "local"] }] }; }, async attach() { return new Authority(); } } },
      { echo: descriptor },
      "vm_duplicate_placement",
      "local",
    ),
    (error: unknown) => error instanceof SidecarError && error.code === SIDECAR_ERROR_PROVIDER_FAILED,
  );

  {
    let attaches = 0;
    const host: SidecarHost = {
      async describe() { return { kinds: [capability] }; },
      async attach() { attaches += 1; return new Authority(); },
    };
    const attached = await EmbeddedSidecarBackend.attach({ runner: host }, {}, "vm_lazy", "local");
    assert.equal(attaches, 0);
    await attached.enable("echo", descriptor);
    assert.equal(attaches, 1);
    await attached.close();
  }

  {
    const authority = new Authority();
    const host: SidecarHost = {
      async describe() { return { kinds: [capability] }; },
      async attach() { return authority; },
    };
    const right = { ...descriptor, host: "runner" };
    const attached = await EmbeddedSidecarBackend.attach(
      { runner: host },
      { left: descriptor, right },
      "vm_kind_limit",
      "local",
    );
    await attached.create({ grant: "left", kind: "test.echo", body: new Uint8Array(), idempotencyKey: "left-1" });
    await attached.create({ grant: "right", kind: "test.echo", body: new Uint8Array(), idempotencyKey: "right-1" });
    await assert.rejects(
      attached.create({ grant: "right", kind: "test.echo", body: new Uint8Array(), idempotencyKey: "right-2" }),
      SidecarError,
    );
    await attached.close();
  }

  {
    const authority = new Authority();
    authority.create = async (request) => ({
      id: "../escape",
      grant: request.grant,
      kind: request.kind,
      generation: 1,
      state: "ready",
      createdAtMs: 1,
      expiresAtMs: 2,
      metadata: new Uint8Array(),
    });
    const attached = await backend(authority);
    await assert.rejects(
      attached.backend.create({ grant: "echo", kind: "test.echo", body: new Uint8Array(), idempotencyKey: "bad" }),
      SidecarError,
    );
    await attached.backend.close();
  }

  {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = ((_input: RequestInfo | URL, init?: RequestInit) => new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
    })) as typeof globalThis.fetch;
    try {
      const remote = new RemoteVmSidecarBackend("https://sidecars.invalid", undefined, "vm_test");
      await assert.rejects(
        remote.create({ grant: "echo", kind: "test.echo", body: new Uint8Array(), idempotencyKey: "timeout", timeoutMs: 5 }),
        (error: unknown) => error instanceof SidecarError && error.code === SIDECAR_ERROR_TIMEOUT,
      );
    } finally {
      globalThis.fetch = originalFetch;
    }
  }

  {
    const authority = new Authority();
    let cancelled = false;
    authority.invoke = async (request) => new Promise<Uint8Array>((_resolve, reject) => {
      request.signal?.addEventListener("abort", () => {
        cancelled = true;
        reject(new Error("cancelled"));
      }, { once: true });
    });
    const attached = await backend(authority);
    const instance = await attached.backend.create({
      grant: "echo",
      kind: "test.echo",
      body: new Uint8Array(),
      idempotencyKey: "local-timeout",
    });
    await assert.rejects(
      attached.backend.invoke({
        id: instance.id,
        generation: instance.generation,
        grant: instance.grant,
        kind: instance.kind,
        operation: "wait",
        body: new Uint8Array(),
        timeoutMs: 5,
      }),
      (error: unknown) => error instanceof SidecarError && error.code === SIDECAR_ERROR_TIMEOUT,
    );
    assert.equal(cancelled, true);
    const barrier = await attached.backend.beginFork();
    barrier.release();
    await attached.backend.close();
  }

  {
    const authority = new Authority();
    authority.create = async (request) => ({
      id: "sc_invalid_metadata",
      grant: request.grant,
      kind: request.kind,
      generation: 1,
      state: "ready",
      createdAtMs: 1,
      expiresAtMs: 2,
      metadata: "not-bytes" as unknown as Uint8Array,
    });
    const attached = await backend(authority);
    await assert.rejects(
      attached.backend.create({ grant: "echo", kind: "test.echo", body: new Uint8Array(), idempotencyKey: "bad-metadata" }),
      SidecarError,
    );
    assert.equal(authority.deletes, 1);
    await attached.backend.close();
  }

  {
    const authority = new Authority();
    authority.create = async () => { throw new Error("provider-token-must-not-escape"); };
    const attached = await backend(authority);
    const response = decodeSidecarResult(await attached.backend.handleGuestCall(encodeSidecarCreate({
      grant: "echo",
      kind: "test.echo",
      body: new Uint8Array(),
      idempotency_key: "guest-error",
      timeout_ms: 1_000,
    })));
    assert.equal(response.ok, false);
    assert.equal(response.error?.code, SIDECAR_ERROR_PROVIDER_FAILED);
    assert.equal(response.error?.message, "sidecar provider failed");
    await attached.backend.close();
  }

  {
    const authority = new Authority();
    let release!: () => void;
    let started!: () => void;
    const invoked = new Promise<void>((resolve) => { started = resolve; });
    authority.invoke = async (request) => {
      started();
      await new Promise<void>((resolve) => { release = resolve; });
      return request.body.slice();
    };
    const attached = await backend(authority);
    const instance = await attached.backend.create({ grant: "echo", kind: "test.echo", body: new Uint8Array(), idempotencyKey: "fork" });
    const call = attached.backend.invoke({
      id: instance.id,
      generation: instance.generation,
      grant: instance.grant,
      kind: instance.kind,
      operation: "echo",
      body: new Uint8Array([7]),
    });
    await invoked;
    const barrier = attached.backend.beginFork();
    await Promise.resolve();
    await assert.rejects(
      attached.backend.retrieve(instance.id),
      (error: unknown) => error instanceof SidecarError && error.code === SIDECAR_ERROR_CLOSING,
    );
    release();
    assert.deepEqual(await call, new Uint8Array([7]));
    const held = await barrier;
    assert.equal(held.warnings.length, 1);
    held.release();
    assert.equal((await attached.backend.retrieve(instance.id)).id, instance.id);
    await attached.backend.close();
  }

  console.log("SIDECARS OK — embedded ownership, idempotency, fork policy, and provider identity verified.");
}

main().catch((error) => {
  console.error("SIDECARS FAIL:", error);
  process.exit(1);
});
