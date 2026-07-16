import {
  SIDECAR_DEFAULT_LEASE_TTL_MS,
  SIDECAR_DEFAULT_RENEW_MS,
  SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS,
  SIDECAR_ERROR_CANCELLED,
  SIDECAR_ERROR_CLOSING,
  SIDECAR_ERROR_CONTRACT_MISMATCH,
  SIDECAR_ERROR_DETACHED,
  SIDECAR_ERROR_GRANT_EXISTS,
  SIDECAR_ERROR_GRANT_MISSING,
  SIDECAR_ERROR_HOST_MISSING,
  SIDECAR_ERROR_IDEMPOTENCY_CONFLICT,
  SIDECAR_ERROR_IN_USE,
  SIDECAR_ERROR_INVALID_REQUEST,
  SIDECAR_ERROR_LIMIT,
  SIDECAR_ERROR_NOT_FOUND,
  SIDECAR_ERROR_NOT_READY,
  SIDECAR_ERROR_PERMISSION_DENIED,
  SIDECAR_ERROR_PROVIDER_FAILED,
  SIDECAR_ERROR_STALE_GENERATION,
  SIDECAR_ERROR_TIMEOUT,
  SIDECAR_ERROR_UNAVAILABLE,
  SIDECAR_ERROR_UNSUPPORTED_FORK_POLICY,
  SIDECAR_CALL_MSG_ID,
  SIDECAR_CREATE_MSG_ID,
  SIDECAR_DELETE_MSG_ID,
  SIDECAR_GET_MSG_ID,
  SIDECAR_LIST_MSG_ID,
  SIDECAR_MAX_GRANTS,
  SIDECAR_MAX_DIGEST_BYTES,
  SIDECAR_MAX_HOSTS,
  SIDECAR_MAX_IDEMPOTENCY_BYTES,
  SIDECAR_MAX_INFLIGHT_PER_INSTANCE,
  SIDECAR_MAX_INFLIGHT_PER_VM,
  SIDECAR_MAX_INSTANCES_PER_GRANT,
  SIDECAR_MAX_INSTANCES_PER_VM,
  SIDECAR_MAX_KIND_BYTES,
  SIDECAR_MAX_NAME_BYTES,
  SIDECAR_MAX_OPERATION_BYTES,
  SIDECAR_MAX_OPERATION_TIMEOUT_MS,
  SIDECAR_MAX_REQUEST_BYTES,
  SIDECAR_MAX_RESULT_BYTES,
  SIDECAR_STATE_ALLOCATING,
  SIDECAR_STATE_CLOSED,
  SIDECAR_STATE_CLOSING,
  SIDECAR_STATE_DETACHED,
  SIDECAR_STATE_FAILED,
  SIDECAR_STATE_READY,
  SIDECAR_STATE_STARTING,
  SIDECAR_STATE_SUSPENDED,
  SIDECAR_WARNING_BUFFER,
  SIDECAR_WARNING_FORK_OMITTED,
  decodeSidecarCreate,
  decodeSidecarCall,
  decodeSidecarDelete,
  decodeSidecarGet,
  decodeSidecarList,
  encodeSidecarInstance,
  encodeSidecarInstances,
  encodeSidecarResult,
  type SidecarCall as WireSidecarCall,
} from "@mc/contracts/sidecar";
import { SIDECAR_SCOPE_HEADER } from "@mc/contracts/wire";

const enc = new TextEncoder();
const SIDECAR_MAX_HTTP_JSON_BYTES = Math.ceil((SIDECAR_MAX_RESULT_BYTES * 4) / 3) + 65_536;

export type SidecarForkPolicy = "omit" | "clone";
export type SidecarPlacement = "local" | "remote";

/** Generated kind modules implement this descriptor. Configuration and operation payloads stay
 * encoded by that kind contract rather than becoming an untyped JSON escape hatch. */
export interface SidecarContractDescriptor {
  readonly kind: string;
  readonly version: number;
  readonly digest: string;
}

export interface SidecarGrant {
  readonly kind: string;
  readonly version: number;
  readonly contractDigest: string;
  readonly guest: boolean;
  readonly maxInstances: number;
  readonly fork: SidecarForkPolicy;
  readonly config: Uint8Array;
}

/** @internal Private attachment key used by typed sidecar descriptors. */
export const GUEST_LAYER: unique symbol = Symbol("mc.sidecar.guest-layer");

export interface SidecarGrantDescriptor {
  readonly contract: SidecarContractDescriptor;
  readonly grant: SidecarGrant;
  /** Private attachment route. Required for embedded VMs and forbidden for remote VMs. */
  readonly host?: string;
  /** @internal Never serialized in the portable grant. */
  readonly [GUEST_LAYER]?: true | Uint8Array;
}

export interface SidecarCapability {
  kind: string;
  version: number;
  contractDigest: string;
  placements: SidecarPlacement[];
  fork: SidecarForkPolicy;
  maxInstancesPerVm: number;
}

export interface SidecarInstance {
  id: string;
  grant: string;
  kind: string;
  generation: number;
  state:
    | "allocating"
    | "starting"
    | "ready"
    | "suspended"
    | "failed"
    | "closing"
    | "closed"
    | "detached";
  createdAtMs: number;
  expiresAtMs: number;
  metadata: Uint8Array;
}

export interface SidecarCreateRequest {
  grant: string;
  kind: string;
  body: Uint8Array;
  idempotencyKey: string;
  timeoutMs?: number;
  signal?: AbortSignal;
}

export interface SidecarInvokeRequest {
  id: string;
  generation: number;
  grant: string;
  kind: string;
  operation: string;
  body: Uint8Array;
  idempotencyKey?: string;
  timeoutMs?: number;
  signal?: AbortSignal;
}

export interface SidecarProviderDescription {
  kinds: SidecarCapability[];
}

export interface SidecarHostContext {
  vmId: string;
  grants: Readonly<Record<string, SidecarGrant>>;
  signal: AbortSignal;
}

export interface SidecarAuthority {
  enable(name: string, grant: SidecarGrant): Promise<void>;
  disable(name: string, destroy?: boolean): Promise<void>;
  create(request: SidecarCreateRequest): Promise<SidecarInstance>;
  retrieve(id: string): Promise<SidecarInstance>;
  list(kind?: string): Promise<SidecarInstance[]>;
  invoke(request: SidecarInvokeRequest): Promise<Uint8Array>;
  delete(id: string): Promise<void>;
  close(): Promise<void>;
}

export interface SidecarHost {
  describe(): Promise<SidecarProviderDescription>;
  attach(context: SidecarHostContext): Promise<SidecarAuthority>;
}

export interface VmWarning {
  code: typeof SIDECAR_WARNING_FORK_OMITTED;
  message: string;
  sidecar?: { kind: string; grant: string; id: string };
}

export class SidecarError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly retryable = false,
    readonly details?: Uint8Array,
  ) {
    super(message);
    this.name = "SidecarError";
  }
}

export interface SidecarBackend {
  capabilities(): Promise<SidecarCapability[]>;
  enable(name: string, descriptor: SidecarGrantDescriptor): Promise<void>;
  disable(name: string, destroy?: boolean): Promise<void>;
  create(request: SidecarCreateRequest): Promise<SidecarInstance>;
  retrieve(id: string): Promise<SidecarInstance>;
  list(kind?: string): Promise<SidecarInstance[]>;
  invoke(request: SidecarInvokeRequest): Promise<Uint8Array>;
  delete(id: string): Promise<void>;
  beginFork?(): Promise<SidecarForkBarrier>;
  close(): Promise<void>;
}

export interface SidecarForkBarrier {
  readonly warnings: VmWarning[];
  release(): void;
}

/** Generic lifecycle surface for the sidecars attached to one VM. Kind-specific modules layer
 * typed conveniences over this object without widening {@link Vm} itself. */
export class VmSidecars {
  private readonly warningBuffer: VmWarning[] = [];
  private readonly warningListeners = new Set<(warning: VmWarning) => void>();

  /** @internal */
  constructor(
    private readonly backend: SidecarBackend,
    private readonly descriptors: Record<string, SidecarGrantDescriptor>,
  ) {}

  capabilities(): Promise<SidecarCapability[]> {
    return this.backend.capabilities();
  }

  async enable(name: string, descriptor: SidecarGrantDescriptor): Promise<void> {
    const owned = ownSidecarDescriptor(descriptor);
    if (owned[GUEST_LAYER] !== undefined) {
      throw new SidecarError(
        SIDECAR_ERROR_INVALID_REQUEST,
        "guest layers are create-time attachments and cannot be enabled on a running VM",
      );
    }
    await this.backend.enable(name, owned);
    this.descriptors[name] = owned;
  }

  async disable(name: string, opts: { destroy?: boolean } = {}): Promise<void> {
    await this.backend.disable(name, opts.destroy ?? false);
    delete this.descriptors[name];
  }

  create(request: SidecarCreateRequest): Promise<SidecarInstance> {
    return this.backend.create(request);
  }
  retrieve(id: string): Promise<SidecarInstance> {
    return this.backend.retrieve(id);
  }
  list(kind?: string): Promise<SidecarInstance[]> {
    return this.backend.list(kind);
  }
  invoke(request: SidecarInvokeRequest): Promise<Uint8Array> {
    return this.backend.invoke(request);
  }
  delete(id: string): Promise<void> {
    return this.backend.delete(id);
  }

  /** Structured non-fatal lifecycle omissions retained in arrival order. */
  warnings(): readonly VmWarning[] {
    return this.warningBuffer.map(ownWarning);
  }

  onWarning(listener: (warning: VmWarning) => void): () => void {
    this.warningListeners.add(listener);
    return () => this.warningListeners.delete(listener);
  }

  /** @internal */
  emit(warnings: readonly VmWarning[]): void {
    for (const warning of warnings) {
      const owned = ownWarning(warning);
      this.warningBuffer.push(owned);
      if (this.warningBuffer.length > SIDECAR_WARNING_BUFFER) this.warningBuffer.shift();
      for (const listener of this.warningListeners) {
        try {
          listener(ownWarning(owned));
        } catch {
          // Observers cannot turn a successful lifecycle operation into a failure.
        }
      }
    }
  }
}

function ownWarning(warning: VmWarning): VmWarning {
  return { ...warning, sidecar: warning.sidecar ? { ...warning.sidecar } : undefined };
}

export function ownSidecarDescriptor(descriptor: SidecarGrantDescriptor): SidecarGrantDescriptor {
  return {
    contract: { ...descriptor.contract },
    grant: { ...descriptor.grant, config: descriptor.grant.config.slice() },
    ...(descriptor.host === undefined ? {} : { host: descriptor.host }),
    ...(descriptor[GUEST_LAYER] === undefined
      ? {}
      : {
          [GUEST_LAYER]:
            descriptor[GUEST_LAYER] === true ? (true as const) : descriptor[GUEST_LAYER].slice(),
        }),
  };
}

export function ownSidecarDescriptors(
  descriptors: Readonly<Record<string, SidecarGrantDescriptor>> | undefined,
): Record<string, SidecarGrantDescriptor> | undefined {
  return descriptors
    ? Object.fromEntries(
        Object.entries(descriptors).map(([name, descriptor]) => [
          name,
          ownSidecarDescriptor(descriptor),
        ]),
      )
    : undefined;
}

export function portableSidecarGrants(
  descriptors: Readonly<Record<string, SidecarGrantDescriptor>> | undefined,
): Record<string, unknown>[] {
  return Object.entries(descriptors ?? {}).map(([name, descriptor]) => {
    validateSidecarDescriptor(name, descriptor, "remote");
    return grantToWire(name, descriptor.grant);
  });
}

export function validateSidecarDescriptor(
  name: string,
  descriptor: SidecarGrantDescriptor,
  runtime: "embedded" | "remote",
): void {
  validateName("grant", name, SIDECAR_MAX_NAME_BYTES);
  const { contract, grant } = descriptor;
  validateName("kind", grant.kind, SIDECAR_MAX_KIND_BYTES, true);
  if (
    contract.kind !== grant.kind ||
    contract.version !== grant.version ||
    contract.digest !== grant.contractDigest
  ) {
    throw new SidecarError(
      SIDECAR_ERROR_CONTRACT_MISMATCH,
      `sidecar grant '${name}' does not match its contract descriptor`,
    );
  }
  if (
    typeof grant.contractDigest !== "string" ||
    enc.encode(grant.contractDigest).length === 0 ||
    enc.encode(grant.contractDigest).length > SIDECAR_MAX_DIGEST_BYTES
  ) {
    throw new SidecarError(
      SIDECAR_ERROR_INVALID_REQUEST,
      `sidecar grant '${name}' has an invalid contract digest`,
    );
  }
  if (!Number.isInteger(grant.version) || grant.version < 1) {
    throw new SidecarError(
      SIDECAR_ERROR_INVALID_REQUEST,
      `sidecar grant '${name}' has an invalid version`,
    );
  }
  if (
    !Number.isInteger(grant.maxInstances) ||
    grant.maxInstances < 1 ||
    grant.maxInstances > SIDECAR_MAX_INSTANCES_PER_GRANT
  ) {
    throw new SidecarError(
      SIDECAR_ERROR_LIMIT,
      `sidecar grant '${name}' maxInstances must be 1..${SIDECAR_MAX_INSTANCES_PER_GRANT}`,
    );
  }
  if (!(grant.config instanceof Uint8Array) || grant.config.length > SIDECAR_MAX_REQUEST_BYTES) {
    throw new SidecarError(
      SIDECAR_ERROR_LIMIT,
      `sidecar grant '${name}' configuration is too large`,
    );
  }
  if (grant.fork !== "omit") {
    throw new SidecarError(
      SIDECAR_ERROR_UNSUPPORTED_FORK_POLICY,
      `sidecar grant '${name}' requests clone semantics that are not implemented`,
    );
  }
  const guestLayer = descriptor[GUEST_LAYER];
  if (guestLayer !== undefined && !grant.guest) {
    throw new SidecarError(
      SIDECAR_ERROR_INVALID_REQUEST,
      `sidecar grant '${name}' provides a guest layer without guest access`,
    );
  }
  if (guestLayer instanceof Uint8Array && guestLayer.length === 0) {
    throw new SidecarError(
      SIDECAR_ERROR_INVALID_REQUEST,
      `sidecar grant '${name}' provides an empty guest layer`,
    );
  }
  if (guestLayer !== undefined && guestLayer !== true && !(guestLayer instanceof Uint8Array)) {
    throw new SidecarError(
      SIDECAR_ERROR_INVALID_REQUEST,
      `sidecar grant '${name}' has an invalid guest layer`,
    );
  }
  if (runtime === "embedded" && guestLayer === true) {
    throw new SidecarError(
      SIDECAR_ERROR_INVALID_REQUEST,
      `embedded sidecar grant '${name}' requires guest layer bytes`,
    );
  }
  if (runtime === "remote" && guestLayer instanceof Uint8Array) {
    throw new SidecarError(
      SIDECAR_ERROR_INVALID_REQUEST,
      `remote sidecar grant '${name}' must delegate its guest layer to the server`,
    );
  }
  if (runtime === "embedded" && descriptor.host === undefined) {
    throw new SidecarError(
      SIDECAR_ERROR_HOST_MISSING,
      `embedded sidecar grant '${name}' requires a host alias`,
    );
  }
  if (runtime === "remote" && descriptor.host !== undefined) {
    throw new SidecarError(
      SIDECAR_ERROR_INVALID_REQUEST,
      `remote sidecar grant '${name}' must not select a host`,
    );
  }
  if (descriptor.host !== undefined)
    validateName("host alias", descriptor.host, SIDECAR_MAX_NAME_BYTES);
}

function validateName(label: string, value: string, max: number, dotted = false): void {
  const bytes = enc.encode(value);
  const pattern = dotted ? /^[a-z][a-z0-9_-]*(?:\.[a-z0-9][a-z0-9_-]*)*$/u : /^[a-z][a-z0-9_-]*$/u;
  if (bytes.length === 0 || bytes.length > max || !pattern.test(value)) {
    throw new SidecarError(
      SIDECAR_ERROR_INVALID_REQUEST,
      `${label} '${value}' is not a valid bounded identifier`,
    );
  }
}

function validateInvoke(request: SidecarInvokeRequest): void {
  if (
    !boundedOpaqueId(request.id) ||
    !Number.isSafeInteger(request.generation) ||
    request.generation < 1
  ) {
    throw new SidecarError(SIDECAR_ERROR_INVALID_REQUEST, "sidecar call has an invalid identity");
  }
  validateName("grant", request.grant, SIDECAR_MAX_NAME_BYTES);
  validateName("kind", request.kind, SIDECAR_MAX_KIND_BYTES, true);
  validateName("operation", request.operation, SIDECAR_MAX_OPERATION_BYTES, true);
  if (!(request.body instanceof Uint8Array) || request.body.length > SIDECAR_MAX_REQUEST_BYTES)
    throw new SidecarError(SIDECAR_ERROR_LIMIT, "sidecar request is too large");
  if (request.idempotencyKey !== undefined) {
    const length = enc.encode(request.idempotencyKey).length;
    if (length === 0 || length > SIDECAR_MAX_IDEMPOTENCY_BYTES) {
      throw new SidecarError(
        SIDECAR_ERROR_INVALID_REQUEST,
        "sidecar idempotency key is outside the contract bounds",
      );
    }
  }
  validateTimeout(request.timeoutMs);
}

interface BoundGrant {
  descriptor: SidecarGrantDescriptor;
  authority: SidecarAuthority;
  capability: SidecarCapability;
}

/** Embedded owner. A host alias is resolved once during attachment; guest calls carry only a grant
 * name and can never choose an endpoint or authority. */
export class EmbeddedSidecarBackend implements SidecarBackend {
  private readonly grants = new Map<string, BoundGrant>();
  private readonly instances = new Map<string, SidecarInstance>();
  private readonly creates = new Map<
    string,
    { grant: string; kind: string; body: Uint8Array; id: string }
  >();
  private readonly creating = new Map<
    string,
    {
      grant: string;
      kind: string;
      body: Uint8Array;
      authority: SidecarAuthority;
      promise: Promise<SidecarInstance>;
    }
  >();
  private readonly authorities = new Map<string, SidecarAuthority>();
  private readonly abort = new AbortController();
  private accepting = true;
  private inflight = 0;
  private readonly inflightByInstance = new Map<string, number>();
  private readonly drained: Array<() => void> = [];

  private constructor(
    private readonly hosts: Readonly<Record<string, SidecarHost>>,
    private readonly vmId: string,
    private readonly requiredPlacement?: SidecarPlacement,
  ) {}

  static async attach(
    hosts: Readonly<Record<string, SidecarHost>>,
    descriptors: Readonly<Record<string, SidecarGrantDescriptor>>,
    vmId = randomId("local"),
    requiredPlacement?: SidecarPlacement,
  ): Promise<EmbeddedSidecarBackend> {
    if (Object.keys(hosts).length > SIDECAR_MAX_HOSTS)
      throw new SidecarError(SIDECAR_ERROR_LIMIT, "too many sidecar hosts");
    if (Object.keys(descriptors).length > SIDECAR_MAX_GRANTS)
      throw new SidecarError(SIDECAR_ERROR_LIMIT, "too many sidecar grants");
    const backend = new EmbeddedSidecarBackend({ ...hosts }, vmId, requiredPlacement);
    try {
      const grouped = new Map<string, Record<string, SidecarGrant>>();
      const ownedDescriptors: Record<string, SidecarGrantDescriptor> = {};
      for (const alias of Object.keys(hosts)) {
        validateName("host alias", alias, SIDECAR_MAX_NAME_BYTES);
      }
      for (const [name, raw] of Object.entries(descriptors)) {
        const descriptor = ownSidecarDescriptor(raw);
        validateSidecarDescriptor(name, descriptor, "embedded");
        if (!hosts[descriptor.host!])
          throw new SidecarError(
            SIDECAR_ERROR_HOST_MISSING,
            `unknown sidecar host '${descriptor.host}'`,
          );
        const group = grouped.get(descriptor.host!) ?? {};
        group[name] = { ...descriptor.grant, config: descriptor.grant.config.slice() };
        grouped.set(descriptor.host!, group);
        ownedDescriptors[name] = descriptor;
      }
      for (const [alias, grants] of grouped) {
        const host = hosts[alias]!;
        const description = await boundedOperation(
          () => host.describe(),
          SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS,
          backend.abort.signal,
        );
        const capabilities = new Map(
          Object.entries(grants).map(([name, grant]) => [
            name,
            assertCapability(description.kinds, grant, requiredPlacement),
          ]),
        );
        const authority = await boundedOperation(
          (signal) => host.attach({ vmId, grants, signal }),
          SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS,
          backend.abort.signal,
        );
        backend.authorities.set(alias, authority);
        for (const name of Object.keys(grants)) {
          backend.grants.set(name, {
            descriptor: ownSidecarDescriptor(ownedDescriptors[name]!),
            authority,
            capability: capabilities.get(name)!,
          });
        }
      }
      return backend;
    } catch (error) {
      await backend.close();
      throw error;
    }
  }

  async capabilities(): Promise<SidecarCapability[]> {
    const descriptions = await Promise.all(
      Object.values(this.hosts).map((host) =>
        boundedOperation(
          () => host.describe(),
          SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS,
          this.abort.signal,
        ),
      ),
    );
    return descriptions.flatMap((description) => description.kinds.map(ownCapability));
  }

  async enable(name: string, descriptor: SidecarGrantDescriptor): Promise<void> {
    await this.admit(undefined, async () => {
      const owned = ownSidecarDescriptor(descriptor);
      validateSidecarDescriptor(name, owned, "embedded");
      if (this.grants.has(name))
        throw new SidecarError(
          SIDECAR_ERROR_GRANT_EXISTS,
          `sidecar grant '${name}' is already enabled`,
        );
      const host = this.hosts[owned.host!];
      if (!host)
        throw new SidecarError(SIDECAR_ERROR_HOST_MISSING, `unknown sidecar host '${owned.host}'`);
      const description = await boundedOperation(
        () => host.describe(),
        SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS,
        this.abort.signal,
      );
      const capability = assertCapability(description.kinds, owned.grant, this.requiredPlacement);
      let authority = this.authorities.get(owned.host!);
      if (authority) {
        await boundedOperation(
          () => authority!.enable(name, { ...owned.grant, config: owned.grant.config.slice() }),
          SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS,
          this.abort.signal,
        );
      } else {
        authority = await boundedOperation(
          (signal) =>
            host.attach({
              vmId: this.vmId,
              grants: { [name]: { ...owned.grant, config: owned.grant.config.slice() } },
              signal,
            }),
          SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS,
          this.abort.signal,
        );
        if (this.abort.signal.aborted) {
          await authority.close();
          throw new SidecarError(SIDECAR_ERROR_CLOSING, "sidecar admission is closed");
        }
        this.authorities.set(owned.host!, authority);
      }
      this.ensureNotClosed();
      this.grants.set(name, { descriptor: owned, authority, capability });
    });
  }

  async disable(name: string, destroy = false): Promise<void> {
    await this.admit(undefined, async () => {
      const bound = this.grants.get(name);
      if (!bound)
        throw new SidecarError(
          SIDECAR_ERROR_GRANT_MISSING,
          `sidecar grant '${name}' is not enabled`,
        );
      const active = [...this.instances.values()].some(
        (instance) => instance.grant === name && instance.state !== "closed",
      );
      if (active && !destroy)
        throw new SidecarError(
          SIDECAR_ERROR_IN_USE,
          `sidecar grant '${name}' has active instances`,
        );
      await boundedOperation(
        () => bound.authority.disable(name, destroy),
        SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS,
        this.abort.signal,
      );
      this.grants.delete(name);
      if (destroy)
        for (const [id, instance] of this.instances)
          if (instance.grant === name) {
            this.instances.delete(id);
            for (const [key, create] of this.creates)
              if (create.id === id) this.creates.delete(key);
          }
    });
  }

  async create(request: SidecarCreateRequest): Promise<SidecarInstance> {
    return this.admit(undefined, async () => {
      validateCreate(request);
      const owned = { ...request, body: request.body.slice() };
      const bound = this.grants.get(owned.grant);
      if (!bound || bound.descriptor.grant.kind !== owned.kind)
        throw new SidecarError(
          SIDECAR_ERROR_GRANT_MISSING,
          `sidecar grant '${owned.grant}' is unavailable`,
        );
      const prior = this.creates.get(owned.idempotencyKey);
      if (prior) {
        if (
          prior.grant !== owned.grant ||
          prior.kind !== owned.kind ||
          !bytesEqual(prior.body, owned.body)
        ) {
          throw new SidecarError(
            SIDECAR_ERROR_IDEMPOTENCY_CONFLICT,
            "sidecar idempotency key was reused for different create content",
          );
        }
        const instance = this.instances.get(prior.id);
        if (instance) return ownInstance(instance);
        this.creates.delete(owned.idempotencyKey);
      }
      const pending = this.creating.get(owned.idempotencyKey);
      if (pending) {
        if (
          pending.grant !== owned.grant ||
          pending.kind !== owned.kind ||
          !bytesEqual(pending.body, owned.body)
        ) {
          throw new SidecarError(
            SIDECAR_ERROR_IDEMPOTENCY_CONFLICT,
            "sidecar idempotency key was reused for different create content",
          );
        }
        return ownInstance(await pending.promise);
      }

      const promise = this.provision(bound, owned);
      this.creating.set(owned.idempotencyKey, {
        grant: owned.grant,
        kind: owned.kind,
        body: owned.body.slice(),
        authority: bound.authority,
        promise,
      });
      try {
        return ownInstance(await promise);
      } finally {
        this.creating.delete(owned.idempotencyKey);
      }
    });
  }

  async retrieve(id: string): Promise<SidecarInstance> {
    return this.admit(id, async () => {
      if (!boundedOpaqueId(id))
        throw new SidecarError(SIDECAR_ERROR_INVALID_REQUEST, "sidecar id is invalid");
      const known = this.instances.get(id);
      if (!known) throw new SidecarError(SIDECAR_ERROR_NOT_FOUND, `sidecar '${id}' was not found`);
      const bound = this.grants.get(known.grant);
      if (!bound) throw new SidecarError(SIDECAR_ERROR_DETACHED, `sidecar '${id}' is detached`);
      const instance = await boundedOperation(
        () => bound.authority.retrieve(id),
        SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS,
        this.abort.signal,
      );
      this.ensureNotClosed();
      validateInstance(instance, known.grant, known.kind);
      if (instance.id !== id)
        throw new SidecarError(
          SIDECAR_ERROR_PROVIDER_FAILED,
          "sidecar provider changed instance identity",
        );
      this.instances.set(id, ownInstance(instance));
      return ownInstance(instance);
    });
  }

  async list(kind?: string): Promise<SidecarInstance[]> {
    return this.admit(undefined, async () => {
      if (kind !== undefined) validateName("kind", kind, SIDECAR_MAX_KIND_BYTES, true);
      const groups = new Map<SidecarAuthority, SidecarInstance[]>();
      for (const bound of this.grants.values()) groups.set(bound.authority, []);
      const authorities = [...groups.keys()];
      const results = await Promise.all(
        authorities.map((authority) =>
          boundedOperation(
            () => authority.list(kind),
            SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS,
            this.abort.signal,
          ),
        ),
      );
      this.ensureNotClosed();
      const seen = new Set<string>();
      for (let index = 0; index < results.length; index += 1)
        for (const instance of results[index]!) {
          const bound = this.grants.get(instance.grant);
          if (!bound || bound.authority !== authorities[index])
            throw new SidecarError(
              SIDECAR_ERROR_PROVIDER_FAILED,
              "sidecar provider returned an instance outside its authority scope",
            );
          validateInstance(instance, instance.grant, bound.descriptor.grant.kind);
          if (seen.has(instance.id))
            throw new SidecarError(
              SIDECAR_ERROR_PROVIDER_FAILED,
              `sidecar providers returned duplicate instance id '${instance.id}'`,
            );
          seen.add(instance.id);
          this.instances.set(instance.id, ownInstance(instance));
        }
      return results.flat().map(ownInstance);
    });
  }

  async invoke(request: SidecarInvokeRequest): Promise<Uint8Array> {
    return this.admit(request.id, async () => {
      validateInvoke(request);
      const owned = { ...request, body: request.body.slice() };
      const bound = this.grants.get(owned.grant);
      if (!bound || bound.descriptor.grant.kind !== owned.kind)
        throw new SidecarError(
          SIDECAR_ERROR_GRANT_MISSING,
          `sidecar grant '${owned.grant}' is unavailable`,
        );
      const known = this.instances.get(owned.id);
      if (!known)
        throw new SidecarError(SIDECAR_ERROR_DETACHED, `sidecar '${owned.id}' is detached`);
      if (known.grant !== owned.grant || known.kind !== owned.kind)
        throw new SidecarError(
          SIDECAR_ERROR_INVALID_REQUEST,
          "sidecar call does not match the bound instance",
        );
      if (known.generation !== owned.generation)
        throw new SidecarError(
          SIDECAR_ERROR_STALE_GENERATION,
          `sidecar '${owned.id}' generation is stale`,
        );
      if (known.state !== "ready")
        throw new SidecarError(SIDECAR_ERROR_NOT_READY, `sidecar '${owned.id}' is not ready`);
      const result = (
        await boundedOperation(
          (signal) => bound.authority.invoke({ ...owned, signal }),
          owned.timeoutMs ?? SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS,
          this.abort.signal,
          owned.signal,
        )
      ).slice();
      if (result.length > SIDECAR_MAX_RESULT_BYTES)
        throw new SidecarError(SIDECAR_ERROR_LIMIT, "sidecar result is too large");
      return result;
    });
  }

  async delete(id: string): Promise<void> {
    await this.admit(id, async () => {
      if (!boundedOpaqueId(id))
        throw new SidecarError(SIDECAR_ERROR_INVALID_REQUEST, "sidecar id is invalid");
      const known = this.instances.get(id);
      if (!known) return;
      const bound = this.grants.get(known.grant);
      if (bound) {
        await boundedOperation(
          () => bound.authority.delete(id),
          SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS,
          this.abort.signal,
        );
      }
      this.instances.delete(id);
      for (const [key, create] of this.creates) if (create.id === id) this.creates.delete(key);
    });
  }

  async beginFork(): Promise<SidecarForkBarrier> {
    if (!this.accepting)
      throw new SidecarError(SIDECAR_ERROR_CLOSING, "sidecar admission is closed");
    this.accepting = false;
    if (this.inflight !== 0) await new Promise<void>((resolve) => this.drained.push(resolve));
    this.ensureNotClosed();
    const warnings = [...this.instances.values()]
      .filter((instance) => instance.state !== "closed")
      .map((instance) => ({
        code: SIDECAR_WARNING_FORK_OMITTED,
        message: `sidecar '${instance.id}' was omitted because its provider does not support independent cloning`,
        sidecar: { kind: instance.kind, grant: instance.grant, id: instance.id },
      }));
    let released = false;
    return {
      warnings,
      release: () => {
        if (released || this.abort.signal.aborted) return;
        released = true;
        this.accepting = true;
      },
    };
  }

  async close(): Promise<void> {
    this.accepting = false;
    this.abort.abort();
    const authorities = [...new Set(this.authorities.values())];
    this.grants.clear();
    this.instances.clear();
    this.creates.clear();
    this.creating.clear();
    this.authorities.clear();
    await Promise.allSettled(
      authorities.map((authority) =>
        boundedOperation(() => authority.close(), SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS),
      ),
    );
  }

  /** Handler installed under the reserved binary-safe `mc.sidecar` binding. */
  async handleGuestCall(body: Uint8Array, signal?: AbortSignal): Promise<Uint8Array> {
    try {
      if (body.length < 3)
        throw new SidecarError(SIDECAR_ERROR_INVALID_REQUEST, "sidecar request is truncated");
      const message = body[0]! | (body[1]! << 8);
      if (message === SIDECAR_CREATE_MSG_ID) {
        const request = decodeSidecarCreate(body);
        this.requireGuestGrant(request.grant, request.kind);
        const instance = await this.create({
          grant: request.grant,
          kind: request.kind,
          body: request.body,
          idempotencyKey: request.idempotency_key,
          timeoutMs: request.timeout_ms,
        });
        return encodeSidecarResult({
          ok: true,
          body: encodeSidecarInstance(instanceToContract(instance)),
        });
      }
      if (message === SIDECAR_CALL_MSG_ID) {
        const call = decodeSidecarCall(body) as WireSidecarCall;
        this.requireGuestGrant(call.grant, call.kind);
        const result = await this.invoke({
          id: call.id,
          generation: call.generation,
          grant: call.grant,
          kind: call.kind,
          operation: call.operation,
          body: call.body,
          idempotencyKey: call.idempotency_key ?? undefined,
          timeoutMs: call.timeout_ms,
          signal,
        });
        return encodeSidecarResult({ ok: true, body: result });
      }
      if (message === SIDECAR_GET_MSG_ID) {
        const request = decodeSidecarGet(body);
        this.requireGuestGrant(request.grant, request.kind);
        const instance = await this.retrieve(request.id);
        assertInstanceRequest(instance, request);
        return encodeSidecarResult({
          ok: true,
          body: encodeSidecarInstance(instanceToContract(instance)),
        });
      }
      if (message === SIDECAR_LIST_MSG_ID) {
        const request = decodeSidecarList(body);
        this.requireGuestGrant(request.grant, request.kind);
        const instances = (await this.list(request.kind)).filter(
          (instance) => instance.grant === request.grant,
        );
        return encodeSidecarResult({
          ok: true,
          body: encodeSidecarInstances({ items: instances.map(instanceToContract) }),
        });
      }
      if (message === SIDECAR_DELETE_MSG_ID) {
        const request = decodeSidecarDelete(body);
        this.requireGuestGrant(request.grant, request.kind);
        const instance = await this.retrieve(request.id);
        assertInstanceRequest(instance, request);
        await this.delete(request.id);
        return encodeSidecarResult({ ok: true, body: new Uint8Array() });
      }
      throw new SidecarError(
        SIDECAR_ERROR_INVALID_REQUEST,
        `unsupported sidecar message ${message}`,
      );
    } catch (error) {
      const sidecar = asSidecarError(error);
      return encodeSidecarResult({
        ok: false,
        body: new Uint8Array(),
        error: {
          code: sidecar.code,
          message: sidecar.message,
          retryable: sidecar.retryable,
          details: sidecar.details,
        },
      });
    }
  }

  private requireGuestGrant(name: string, kind: string): BoundGrant {
    const bound = this.grants.get(name);
    if (!bound || bound.descriptor.grant.kind !== kind)
      throw new SidecarError(SIDECAR_ERROR_GRANT_MISSING, `sidecar grant '${name}' is unavailable`);
    if (!bound.descriptor.grant.guest)
      throw new SidecarError(
        SIDECAR_ERROR_PERMISSION_DENIED,
        `sidecar grant '${name}' is not guest-enabled`,
      );
    return bound;
  }

  private async admit<T>(instanceId: string | undefined, operation: () => Promise<T>): Promise<T> {
    if (!this.accepting || this.abort.signal.aborted)
      throw new SidecarError(SIDECAR_ERROR_CLOSING, "sidecar admission is closed");
    if (this.inflight >= SIDECAR_MAX_INFLIGHT_PER_VM)
      throw new SidecarError(SIDECAR_ERROR_LIMIT, "sidecar in-flight limit reached");
    if (
      instanceId !== undefined &&
      (this.inflightByInstance.get(instanceId) ?? 0) >= SIDECAR_MAX_INFLIGHT_PER_INSTANCE
    ) {
      throw new SidecarError(
        SIDECAR_ERROR_LIMIT,
        `sidecar '${instanceId}' in-flight limit reached`,
      );
    }
    this.inflight += 1;
    if (instanceId !== undefined)
      this.inflightByInstance.set(instanceId, (this.inflightByInstance.get(instanceId) ?? 0) + 1);
    try {
      return await operation();
    } finally {
      this.inflight -= 1;
      if (instanceId !== undefined) {
        const next = (this.inflightByInstance.get(instanceId) ?? 1) - 1;
        if (next === 0) this.inflightByInstance.delete(instanceId);
        else this.inflightByInstance.set(instanceId, next);
      }
      if (this.inflight === 0) for (const resolve of this.drained.splice(0)) resolve();
    }
  }

  private async provision(
    bound: BoundGrant,
    request: SidecarCreateRequest,
  ): Promise<SidecarInstance> {
    const live = [...this.instances.values()].filter((instance) => instance.state !== "closed");
    const pending = [...this.creating.values()].filter(
      (item) => item.grant === request.grant,
    ).length;
    const pendingKind = [...this.creating.values()].filter(
      (item) => item.kind === request.kind && item.authority === bound.authority,
    ).length;
    const liveKind = live.filter((instance) => {
      const instanceGrant = this.grants.get(instance.grant);
      return instance.kind === request.kind && instanceGrant?.authority === bound.authority;
    }).length;
    if (
      live.length + this.creating.size >= SIDECAR_MAX_INSTANCES_PER_VM ||
      live.filter((instance) => instance.grant === request.grant).length + pending >=
        bound.descriptor.grant.maxInstances ||
      liveKind + pendingKind >= bound.capability.maxInstancesPerVm
    ) {
      throw new SidecarError(SIDECAR_ERROR_LIMIT, "sidecar instance limit reached");
    }
    const instance = await boundedOperation(
      (signal) => bound.authority.create({ ...request, signal }),
      request.timeoutMs ?? SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS,
      this.abort.signal,
      request.signal,
      (late) => this.cleanupRejectedInstance(bound.authority, late),
    );
    if (this.abort.signal.aborted) {
      await this.cleanupRejectedInstance(bound.authority, instance);
      throw new SidecarError(SIDECAR_ERROR_CLOSING, "sidecar admission is closed");
    }
    try {
      validateInstance(instance, request.grant, request.kind);
      if (this.instances.has(instance.id))
        throw new SidecarError(
          SIDECAR_ERROR_PROVIDER_FAILED,
          `sidecar provider reused instance id '${instance.id}'`,
        );
    } catch (error) {
      await this.cleanupRejectedInstance(bound.authority, instance);
      throw error;
    }
    const owned = ownInstance(instance);
    this.instances.set(owned.id, owned);
    this.creates.set(request.idempotencyKey, {
      grant: request.grant,
      kind: request.kind,
      body: request.body.slice(),
      id: owned.id,
    });
    return owned;
  }

  private async cleanupRejectedInstance(
    authority: SidecarAuthority,
    value: unknown,
  ): Promise<void> {
    if (!value || typeof value !== "object") return;
    const id = (value as { id?: unknown }).id;
    if (typeof id !== "string" || !boundedOpaqueId(id) || this.instances.has(id)) return;
    try {
      await authority.delete(id);
    } catch {
      /* authority close is the cleanup backstop */
    }
  }

  private ensureNotClosed(): void {
    if (this.abort.signal.aborted)
      throw new SidecarError(SIDECAR_ERROR_CLOSING, "sidecar admission is closed");
  }
}

export interface RemoteSidecarHostOptions {
  endpoint: string;
  token?: string;
  fetch?: typeof globalThis.fetch;
}

/** @internal — remote VM identity belongs to the VM transport, not its sidecar backend. */
export async function forkRemoteVm(
  endpoint: string,
  token: string | undefined,
  vmId: string,
): Promise<{ id: string; warnings: VmWarning[] }> {
  const headers: Record<string, string> = token
    ? { authorization: `Bearer ${token}`, "content-type": "application/json" }
    : { "content-type": "application/json" };
  const response = await boundedFetch(
    globalThis.fetch,
    `${endpoint.replace(/\/$/u, "")}/v1/vms/${encodeURIComponent(vmId)}/forks`,
    { method: "POST", headers, body: "{}" },
    SIDECAR_MAX_OPERATION_TIMEOUT_MS + 5_000,
  );
  if (!response.ok) throw await httpError(response, `remote VM fork failed: ${response.status}`);
  const body = (await boundedJson(response)) as { vm?: { id?: unknown }; warnings?: unknown[] };
  if (typeof body.vm?.id !== "string")
    throw new SidecarError(SIDECAR_ERROR_PROVIDER_FAILED, "remote VM fork response was malformed");
  if (!Array.isArray(body.warnings))
    throw new SidecarError(SIDECAR_ERROR_PROVIDER_FAILED, "remote VM fork warnings were malformed");
  return { id: body.vm.id, warnings: body.warnings.map(warningFromWire) };
}

/** Connector for embedded VMs. Each attach creates a fresh leased external scope; reusing this
 * connector object never shares a scope, lease, or sidecar identity between VMs. */
export function remoteSidecars(options: RemoteSidecarHostOptions): SidecarHost {
  const base = options.endpoint.replace(/\/$/u, "");
  const fetcher = options.fetch ?? globalThis.fetch;
  const headers: Record<string, string> = options.token
    ? { authorization: `Bearer ${options.token}` }
    : {};
  return {
    async describe() {
      const response = await boundedFetch(fetcher, `${base}/v1/capabilities`, { headers });
      if (!response.ok)
        throw await httpError(response, `sidecar capability discovery failed: ${response.status}`);
      const body = (await boundedJson(response)) as { sidecars?: SidecarCapability[] };
      return { kinds: capabilitiesFromWire(body.sidecars) };
    },
    async attach(context) {
      const grants = Object.entries(context.grants).map(([name, grant]) =>
        grantToWire(name, grant),
      );
      const response = await boundedFetch(fetcher, `${base}/v1/sidecar-scopes`, {
        method: "POST",
        headers: { ...headers, "content-type": "application/json" },
        body: JSON.stringify({
          clientRef: context.vmId,
          grants,
          leaseTtlMs: SIDECAR_DEFAULT_LEASE_TTL_MS,
        }),
        signal: context.signal,
      });
      if (!response.ok)
        throw await httpError(response, `sidecar scope attach failed: ${response.status}`);
      const scope = scopeFromWire(await boundedJson(response));
      return new RemoteScopeAuthority(
        base,
        headers,
        scope.id,
        scope.token,
        fetcher,
        context.signal,
      );
    },
  };
}

class RemoteScopeAuthority implements SidecarAuthority {
  private closed = false;
  private renewTimer?: ReturnType<typeof setTimeout>;
  private renewAbort?: AbortController;
  constructor(
    private readonly base: string,
    private readonly headers: Record<string, string>,
    private readonly scope: string,
    private scopeToken: string,
    private readonly fetcher: typeof globalThis.fetch,
    signal: AbortSignal,
  ) {
    this.scheduleRenewal();
    signal.addEventListener("abort", () => void this.close(), { once: true });
    if (signal.aborted) void this.close();
  }

  private url(path = ""): string {
    return `${this.base}/v1/sidecar-scopes/${encodeURIComponent(this.scope)}${path}`;
  }
  private auth(): Record<string, string> {
    return { ...this.headers, [SIDECAR_SCOPE_HEADER]: this.scopeToken };
  }
  async enable(name: string, grant: SidecarGrant): Promise<void> {
    await this.json(`/grants/${encodeURIComponent(name)}`, "PUT", grantToWire(name, grant));
  }
  async disable(name: string, destroy = false): Promise<void> {
    await this.json(`/grants/${encodeURIComponent(name)}?destroy=${destroy}`, "DELETE");
  }
  async create(request: SidecarCreateRequest): Promise<SidecarInstance> {
    validateCreate(request);
    return instanceFromWire(
      await this.json(
        "/sidecars",
        "POST",
        createToWire(request),
        request.signal,
        request.timeoutMs,
      ),
    );
  }
  async retrieve(id: string): Promise<SidecarInstance> {
    return instanceFromWire(await this.json(`/sidecars/${encodeURIComponent(id)}`, "GET"));
  }
  async list(kind?: string): Promise<SidecarInstance[]> {
    const suffix = kind ? `?kind=${encodeURIComponent(kind)}` : "";
    const body = (await this.json(`/sidecars${suffix}`, "GET")) as { items?: unknown[] };
    return instancesFromWire(body.items);
  }
  async invoke(request: SidecarInvokeRequest): Promise<Uint8Array> {
    validateInvoke(request);
    const body = (await this.json(
      `/sidecars/${encodeURIComponent(request.id)}/operations/${encodeURIComponent(request.operation)}`,
      "POST",
      callToWire(request),
      request.signal,
      request.timeoutMs,
    )) as { ok?: unknown; bodyBase64?: unknown; error?: unknown };
    if (body.ok !== true) throw errorFromWire(body.error);
    return resultBodyFromWire(body.bodyBase64);
  }
  async delete(id: string): Promise<void> {
    await this.json(`/sidecars/${encodeURIComponent(id)}`, "DELETE");
  }
  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    if (this.renewTimer !== undefined) clearTimeout(this.renewTimer);
    this.renewAbort?.abort();
    try {
      await this.json("", "DELETE");
    } catch {
      /* lease expiry is the cleanup backstop */
    }
  }
  private async renew(): Promise<void> {
    if (this.closed) return;
    const abort = new AbortController();
    this.renewAbort = abort;
    try {
      const scope = scopeFromWire(
        await this.json(
          "/renew",
          "POST",
          { leaseTtlMs: SIDECAR_DEFAULT_LEASE_TTL_MS },
          abort.signal,
        ),
      );
      if (scope.id !== this.scope)
        throw new SidecarError(
          SIDECAR_ERROR_PROVIDER_FAILED,
          "sidecar scope renewal changed identity",
        );
      if (!this.closed) this.scopeToken = scope.token;
    } catch {
      // A transient miss is tolerated within the server lease; repeated misses expire and reap the scope.
    } finally {
      if (this.renewAbort === abort) this.renewAbort = undefined;
      this.scheduleRenewal();
    }
  }
  private scheduleRenewal(): void {
    if (this.closed) return;
    this.renewTimer = setTimeout(() => void this.renew(), SIDECAR_DEFAULT_RENEW_MS);
    const timer = this.renewTimer as unknown as { unref?: () => void };
    timer.unref?.();
  }
  private async json(
    path: string,
    method: string,
    body?: unknown,
    signal?: AbortSignal,
    timeoutMs?: number,
  ): Promise<any> {
    if (this.closed && method !== "DELETE")
      throw new SidecarError(SIDECAR_ERROR_CLOSING, "sidecar scope is closed");
    const response = await boundedFetch(
      this.fetcher,
      this.url(path),
      {
        method,
        headers:
          body === undefined ? this.auth() : { ...this.auth(), "content-type": "application/json" },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        ...(signal ? { signal } : {}),
      },
      timeoutMs,
    );
    if (!response.ok)
      throw await httpError(response, `sidecar authority request failed: ${response.status}`);
    return response.status === 204 ? {} : boundedJson(response);
  }
}

/** Sidecar backend for a VM already owned by the served AgentOS host. The client never selects an
 * internal provider or sends an embedded host alias on this path. */
export class RemoteVmSidecarBackend implements SidecarBackend {
  private readonly headers: Record<string, string>;
  constructor(
    private readonly endpoint: string,
    token: string | undefined,
    private readonly vmId: string,
  ) {
    this.headers = token ? { authorization: `Bearer ${token}` } : {};
  }
  private url(path = ""): string {
    return `${this.endpoint.replace(/\/$/u, "")}/v1/vms/${encodeURIComponent(this.vmId)}${path}`;
  }
  async capabilities(): Promise<SidecarCapability[]> {
    const response = await boundedFetch(
      globalThis.fetch,
      `${this.endpoint.replace(/\/$/u, "")}/v1/capabilities`,
      { headers: this.headers },
    );
    if (!response.ok)
      throw await httpError(response, `sidecar capability discovery failed: ${response.status}`);
    const body = (await boundedJson(response)) as { sidecars?: SidecarCapability[] };
    return capabilitiesFromWire(body.sidecars);
  }
  async enable(name: string, descriptor: SidecarGrantDescriptor): Promise<void> {
    const owned = ownSidecarDescriptor(descriptor);
    validateSidecarDescriptor(name, owned, "remote");
    const capabilities = await this.capabilities();
    assertCapability(capabilities, owned.grant);
    await this.json(
      `/sidecar-grants/${encodeURIComponent(name)}`,
      "PUT",
      grantToWire(name, owned.grant),
    );
  }
  async disable(name: string, destroy = false): Promise<void> {
    await this.json(`/sidecar-grants/${encodeURIComponent(name)}?destroy=${destroy}`, "DELETE");
  }
  async create(request: SidecarCreateRequest): Promise<SidecarInstance> {
    validateCreate(request);
    return instanceFromWire(
      await this.json(
        "/sidecars",
        "POST",
        createToWire(request),
        request.signal,
        request.timeoutMs,
      ),
    );
  }
  async retrieve(id: string): Promise<SidecarInstance> {
    return instanceFromWire(await this.json(`/sidecars/${encodeURIComponent(id)}`, "GET"));
  }
  async list(kind?: string): Promise<SidecarInstance[]> {
    const body = (await this.json(
      `/sidecars${kind ? `?kind=${encodeURIComponent(kind)}` : ""}`,
      "GET",
    )) as { items?: unknown[] };
    return instancesFromWire(body.items);
  }
  async invoke(request: SidecarInvokeRequest): Promise<Uint8Array> {
    validateInvoke(request);
    const body = (await this.json(
      `/sidecars/${encodeURIComponent(request.id)}/operations/${encodeURIComponent(request.operation)}`,
      "POST",
      callToWire(request),
      request.signal,
      request.timeoutMs,
    )) as { ok?: unknown; bodyBase64?: unknown; error?: unknown };
    if (body.ok !== true) throw errorFromWire(body.error);
    return resultBodyFromWire(body.bodyBase64);
  }
  async delete(id: string): Promise<void> {
    await this.json(`/sidecars/${encodeURIComponent(id)}`, "DELETE");
  }
  async close(): Promise<void> {}
  private async json(
    path: string,
    method: string,
    body?: unknown,
    signal?: AbortSignal,
    timeoutMs?: number,
  ): Promise<any> {
    const response = await boundedFetch(
      globalThis.fetch,
      this.url(path),
      {
        method,
        headers:
          body === undefined
            ? this.headers
            : { ...this.headers, "content-type": "application/json" },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        ...(signal ? { signal } : {}),
      },
      timeoutMs,
    );
    if (!response.ok)
      throw await httpError(response, `remote sidecar request failed: ${response.status}`);
    return response.status === 204 ? {} : boundedJson(response);
  }
}

function assertCapability(
  capabilities: SidecarCapability[],
  grant: SidecarGrant,
  placement?: SidecarPlacement,
): SidecarCapability {
  const capability = capabilities
    .map(ownCapability)
    .find((candidate) => candidate.kind === grant.kind && candidate.version === grant.version);
  if (!capability || capability.contractDigest !== grant.contractDigest) {
    throw new SidecarError(
      SIDECAR_ERROR_CONTRACT_MISMATCH,
      `sidecar host does not implement ${grant.kind} v${grant.version} with the requested contract digest`,
    );
  }
  if (placement && !capability.placements.includes(placement)) {
    throw new SidecarError(
      SIDECAR_ERROR_UNAVAILABLE,
      `sidecar host cannot place ${grant.kind} ${placement}`,
    );
  }
  if (capability.fork !== grant.fork) {
    throw new SidecarError(
      SIDECAR_ERROR_CONTRACT_MISMATCH,
      `sidecar host does not implement the requested ${grant.fork} fork policy for ${grant.kind}`,
    );
  }
  if (grant.maxInstances > capability.maxInstancesPerVm) {
    throw new SidecarError(
      SIDECAR_ERROR_LIMIT,
      `sidecar grant exceeds the host limit for ${grant.kind}`,
    );
  }
  return capability;
}

function validateCreate(request: SidecarCreateRequest): void {
  validateName("grant", request.grant, SIDECAR_MAX_NAME_BYTES);
  validateName("kind", request.kind, SIDECAR_MAX_KIND_BYTES, true);
  if (!(request.body instanceof Uint8Array) || request.body.length > SIDECAR_MAX_REQUEST_BYTES)
    throw new SidecarError(SIDECAR_ERROR_LIMIT, "sidecar create request is too large");
  const idempotencyBytes = enc.encode(request.idempotencyKey).length;
  if (idempotencyBytes === 0 || idempotencyBytes > SIDECAR_MAX_IDEMPOTENCY_BYTES) {
    throw new SidecarError(
      SIDECAR_ERROR_INVALID_REQUEST,
      "sidecar create requires a bounded idempotency key",
    );
  }
  validateTimeout(request.timeoutMs);
}

function validateTimeout(timeoutMs: number | undefined): void {
  const timeout = timeoutMs ?? SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS;
  if (
    !Number.isSafeInteger(timeout) ||
    timeout <= 0 ||
    timeout > SIDECAR_MAX_OPERATION_TIMEOUT_MS
  ) {
    throw new SidecarError(
      SIDECAR_ERROR_INVALID_REQUEST,
      "sidecar timeout is outside the contract bounds",
    );
  }
}

function validateInstance(instance: SidecarInstance, grant: string, kind: string): void {
  const states: SidecarInstance["state"][] = [
    "allocating",
    "starting",
    "ready",
    "suspended",
    "failed",
    "closing",
    "closed",
    "detached",
  ];
  if (
    !instance ||
    typeof instance !== "object" ||
    instance.grant !== grant ||
    instance.kind !== kind ||
    !boundedOpaqueId(instance.id) ||
    !Number.isSafeInteger(instance.generation) ||
    instance.generation < 1 ||
    !states.includes(instance.state) ||
    !Number.isSafeInteger(instance.createdAtMs) ||
    instance.createdAtMs < 0 ||
    !Number.isSafeInteger(instance.expiresAtMs) ||
    instance.expiresAtMs < instance.createdAtMs ||
    !(instance.metadata instanceof Uint8Array) ||
    instance.metadata.length > SIDECAR_MAX_RESULT_BYTES
  ) {
    throw new SidecarError(
      SIDECAR_ERROR_PROVIDER_FAILED,
      "sidecar provider returned an invalid instance binding",
    );
  }
}

function assertInstanceRequest(
  instance: SidecarInstance,
  request: { id: string; generation: number; grant: string; kind: string },
): void {
  if (
    instance.id !== request.id ||
    instance.generation !== request.generation ||
    instance.grant !== request.grant ||
    instance.kind !== request.kind
  ) {
    throw new SidecarError(
      SIDECAR_ERROR_STALE_GENERATION,
      `sidecar '${request.id}' does not match the requested binding`,
    );
  }
}

function instanceToContract(instance: SidecarInstance): {
  id: string;
  grant: string;
  kind: string;
  generation: number;
  state: number;
  created_at_ms: number;
  expires_at_ms: number;
  metadata: Uint8Array;
} {
  const states: Record<SidecarInstance["state"], number> = {
    allocating: SIDECAR_STATE_ALLOCATING,
    starting: SIDECAR_STATE_STARTING,
    ready: SIDECAR_STATE_READY,
    suspended: SIDECAR_STATE_SUSPENDED,
    failed: SIDECAR_STATE_FAILED,
    closing: SIDECAR_STATE_CLOSING,
    closed: SIDECAR_STATE_CLOSED,
    detached: SIDECAR_STATE_DETACHED,
  };
  return {
    id: instance.id,
    grant: instance.grant,
    kind: instance.kind,
    generation: instance.generation,
    state: states[instance.state],
    created_at_ms: instance.createdAtMs,
    expires_at_ms: instance.expiresAtMs,
    metadata: instance.metadata,
  };
}

function ownCapability(value: SidecarCapability): SidecarCapability {
  if (!value || typeof value !== "object")
    throw new SidecarError(SIDECAR_ERROR_PROVIDER_FAILED, "sidecar capability was malformed");
  validateName("kind", value.kind, SIDECAR_MAX_KIND_BYTES, true);
  if (
    !Number.isSafeInteger(value.version) ||
    value.version < 1 ||
    typeof value.contractDigest !== "string" ||
    enc.encode(value.contractDigest).length === 0 ||
    enc.encode(value.contractDigest).length > SIDECAR_MAX_DIGEST_BYTES
  ) {
    throw new SidecarError(
      SIDECAR_ERROR_PROVIDER_FAILED,
      `sidecar capability for '${value.kind}' has an invalid contract identity`,
    );
  }
  if (
    !Array.isArray(value.placements) ||
    value.placements.length === 0 ||
    value.placements.some((item) => item !== "local" && item !== "remote")
  ) {
    throw new SidecarError(
      SIDECAR_ERROR_PROVIDER_FAILED,
      `sidecar capability for '${value.kind}' has invalid placements`,
    );
  }
  if (new Set(value.placements).size !== value.placements.length) {
    throw new SidecarError(
      SIDECAR_ERROR_PROVIDER_FAILED,
      `sidecar capability for '${value.kind}' repeats a placement`,
    );
  }
  if (value.fork !== "omit" && value.fork !== "clone")
    throw new SidecarError(
      SIDECAR_ERROR_PROVIDER_FAILED,
      `sidecar capability for '${value.kind}' has an invalid fork policy`,
    );
  if (
    !Number.isSafeInteger(value.maxInstancesPerVm) ||
    value.maxInstancesPerVm < 1 ||
    value.maxInstancesPerVm > SIDECAR_MAX_INSTANCES_PER_VM
  ) {
    throw new SidecarError(
      SIDECAR_ERROR_PROVIDER_FAILED,
      `sidecar capability for '${value.kind}' has an invalid instance limit`,
    );
  }
  return { ...value, placements: [...new Set(value.placements)] };
}
function ownInstance(value: SidecarInstance): SidecarInstance {
  return { ...value, metadata: value.metadata.slice() };
}
function randomId(prefix: string): string {
  return `${prefix}_${crypto.randomUUID().replace(/-/gu, "")}`;
}
function asSidecarError(error: unknown): SidecarError {
  return error instanceof SidecarError
    ? error
    : new SidecarError(SIDECAR_ERROR_PROVIDER_FAILED, "sidecar provider failed");
}
function errorFromWire(value: unknown): SidecarError {
  const error = value && typeof value === "object" ? (value as Record<string, unknown>) : {};
  const details =
    typeof error.detailsBase64 === "string" ? base64Bytes(error.detailsBase64) : undefined;
  if (details && details.length > SIDECAR_MAX_RESULT_BYTES) {
    throw new SidecarError(SIDECAR_ERROR_LIMIT, "sidecar error details are too large");
  }
  return new SidecarError(
    String(error.code ?? SIDECAR_ERROR_PROVIDER_FAILED),
    String(error.message ?? "sidecar operation failed"),
    error.retryable === true,
    details,
  );
}
function warningFromWire(value: unknown): VmWarning {
  const warning = value && typeof value === "object" ? (value as Record<string, unknown>) : {};
  if (warning.code !== SIDECAR_WARNING_FORK_OMITTED) {
    throw new SidecarError(SIDECAR_ERROR_PROVIDER_FAILED, "sidecar warning response was malformed");
  }
  const code = warning.code;
  if (typeof warning.message !== "string")
    throw new SidecarError(SIDECAR_ERROR_PROVIDER_FAILED, "sidecar warning response was malformed");
  const hasSidecar =
    typeof warning.kind === "string" &&
    typeof warning.grant === "string" &&
    typeof warning.id === "string";
  const hasPartialSidecar =
    warning.kind !== undefined || warning.grant !== undefined || warning.id !== undefined;
  if (hasPartialSidecar && !hasSidecar)
    throw new SidecarError(SIDECAR_ERROR_PROVIDER_FAILED, "sidecar warning binding was malformed");
  return {
    code,
    message: warning.message,
    ...(hasSidecar
      ? {
          sidecar: {
            kind: warning.kind as string,
            grant: warning.grant as string,
            id: warning.id as string,
          },
        }
      : {}),
  };
}
function grantToWire(name: string, grant: SidecarGrant): Record<string, unknown> {
  return {
    name,
    kind: grant.kind,
    version: grant.version,
    contractDigest: grant.contractDigest,
    guest: grant.guest,
    maxInstances: grant.maxInstances,
    fork: grant.fork === "clone" ? 2 : 1,
    configBase64: bytesBase64(grant.config),
  };
}
function createToWire(request: SidecarCreateRequest): Record<string, unknown> {
  return {
    grant: request.grant,
    kind: request.kind,
    bodyBase64: bytesBase64(request.body),
    idempotencyKey: request.idempotencyKey,
    timeoutMs: request.timeoutMs ?? SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS,
  };
}
function callToWire(request: SidecarInvokeRequest): Record<string, unknown> {
  return {
    id: request.id,
    generation: request.generation,
    grant: request.grant,
    kind: request.kind,
    operation: request.operation,
    bodyBase64: bytesBase64(request.body),
    idempotencyKey: request.idempotencyKey,
    timeoutMs: request.timeoutMs ?? SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS,
  };
}
function instanceFromWire(value: unknown): SidecarInstance {
  const item = value && typeof value === "object" ? (value as Record<string, unknown>) : {};
  if (
    typeof item.id !== "string" ||
    typeof item.grant !== "string" ||
    typeof item.kind !== "string" ||
    typeof item.generation !== "number"
  )
    throw new SidecarError(
      SIDECAR_ERROR_PROVIDER_FAILED,
      "sidecar instance response was malformed",
    );
  if (
    typeof item.state !== "number" ||
    typeof item.createdAtMs !== "number" ||
    typeof item.expiresAtMs !== "number" ||
    typeof item.metadataBase64 !== "string"
  ) {
    throw new SidecarError(
      SIDECAR_ERROR_PROVIDER_FAILED,
      "sidecar instance response was malformed",
    );
  }
  const state = new Map<number, SidecarInstance["state"]>([
    [SIDECAR_STATE_ALLOCATING, "allocating"],
    [SIDECAR_STATE_STARTING, "starting"],
    [SIDECAR_STATE_READY, "ready"],
    [SIDECAR_STATE_SUSPENDED, "suspended"],
    [SIDECAR_STATE_FAILED, "failed"],
    [SIDECAR_STATE_CLOSING, "closing"],
    [SIDECAR_STATE_CLOSED, "closed"],
    [SIDECAR_STATE_DETACHED, "detached"],
  ]).get(item.state);
  if (state === undefined)
    throw new SidecarError(
      SIDECAR_ERROR_PROVIDER_FAILED,
      "sidecar instance response had an unknown state",
    );
  const instance = {
    id: item.id,
    grant: item.grant,
    kind: item.kind,
    generation: item.generation,
    state,
    createdAtMs: item.createdAtMs,
    expiresAtMs: item.expiresAtMs,
    metadata: base64Bytes(item.metadataBase64),
  };
  validateInstance(instance, instance.grant, instance.kind);
  return instance;
}
function bytesBase64(bytes: Uint8Array): string {
  const buffer = (globalThis as any).Buffer;
  if (buffer) return buffer.from(bytes).toString("base64");
  let raw = "";
  for (let i = 0; i < bytes.length; i += 0x8000)
    raw += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(raw);
}
function base64Bytes(value: string): Uint8Array {
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(value)) {
    throw new SidecarError(
      SIDECAR_ERROR_PROVIDER_FAILED,
      "sidecar response contained invalid base64",
    );
  }
  const buffer = (globalThis as any).Buffer;
  if (buffer) return new Uint8Array(buffer.from(value, "base64"));
  const raw = atob(value);
  return Uint8Array.from(raw, (char) => char.charCodeAt(0));
}

function resultBodyFromWire(value: unknown): Uint8Array {
  if (typeof value !== "string") {
    throw new SidecarError(SIDECAR_ERROR_PROVIDER_FAILED, "sidecar result response was malformed");
  }
  const result = base64Bytes(value);
  if (result.length > SIDECAR_MAX_RESULT_BYTES) {
    throw new SidecarError(SIDECAR_ERROR_LIMIT, "sidecar result is too large");
  }
  return result;
}

function boundedOpaqueId(value: string): boolean {
  const length = enc.encode(value).length;
  return length > 0 && length <= SIDECAR_MAX_NAME_BYTES && /^[A-Za-z0-9_-]+$/u.test(value);
}

function bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index += 1)
    if (left[index] !== right[index]) return false;
  return true;
}

async function httpError(response: Response, fallback: string): Promise<SidecarError> {
  const body = (await boundedJson(response).catch(() => undefined)) as
    | { error?: unknown }
    | undefined;
  if (body?.error !== undefined) {
    const error = errorFromWire(body.error);
    return new SidecarError(
      error.code,
      error.message,
      error.retryable || response.status >= 500,
      error.details,
    );
  }
  return new SidecarError(SIDECAR_ERROR_PROVIDER_FAILED, fallback, response.status >= 500);
}

async function boundedJson(response: Response): Promise<unknown> {
  const declared = response.headers.get("content-length");
  if (declared !== null && Number(declared) > SIDECAR_MAX_HTTP_JSON_BYTES) {
    throw new SidecarError(SIDECAR_ERROR_LIMIT, "sidecar response is too large");
  }

  const reader = response.body?.getReader();
  if (!reader) {
    const text = await response.text();
    if (enc.encode(text).length > SIDECAR_MAX_HTTP_JSON_BYTES) {
      throw new SidecarError(SIDECAR_ERROR_LIMIT, "sidecar response is too large");
    }
    try {
      return JSON.parse(text);
    } catch {
      throw new SidecarError(SIDECAR_ERROR_PROVIDER_FAILED, "sidecar response was not valid JSON");
    }
  }

  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > SIDECAR_MAX_HTTP_JSON_BYTES) {
      await reader.cancel();
      throw new SidecarError(SIDECAR_ERROR_LIMIT, "sidecar response is too large");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new SidecarError(SIDECAR_ERROR_PROVIDER_FAILED, "sidecar response was not valid JSON");
  }
}

async function boundedOperation<T>(
  operation: (signal: AbortSignal) => Promise<T>,
  timeoutMs: number,
  closingSignal?: AbortSignal,
  externalSignal?: AbortSignal,
  onLateResult?: (value: T) => void | Promise<void>,
): Promise<T> {
  const controller = new AbortController();
  let timedOut = false;
  let abandoned = false;
  const close = () => controller.abort();
  const cancel = () => controller.abort();
  if (closingSignal?.aborted || externalSignal?.aborted) controller.abort();
  closingSignal?.addEventListener("abort", close, { once: true });
  externalSignal?.addEventListener("abort", cancel, { once: true });
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);
  (timer as unknown as { unref?: () => void }).unref?.();

  const work = Promise.resolve().then(() => operation(controller.signal));
  if (onLateResult) {
    void work.then(
      (value) => {
        if (abandoned) void Promise.resolve(onLateResult(value)).catch(() => undefined);
      },
      () => undefined,
    );
  }

  const cancelled = new Promise<never>((_resolve, reject) => {
    const fail = () => {
      abandoned = true;
      if (timedOut) {
        reject(new SidecarError(SIDECAR_ERROR_TIMEOUT, "sidecar operation timed out", true));
      } else if (closingSignal?.aborted) {
        reject(new SidecarError(SIDECAR_ERROR_CLOSING, "sidecar admission is closed"));
      } else {
        reject(new SidecarError(SIDECAR_ERROR_CANCELLED, "sidecar operation was cancelled"));
      }
    };
    if (controller.signal.aborted) fail();
    else controller.signal.addEventListener("abort", fail, { once: true });
  });

  try {
    return await Promise.race([work, cancelled]);
  } finally {
    clearTimeout(timer);
    closingSignal?.removeEventListener("abort", close);
    externalSignal?.removeEventListener("abort", cancel);
  }
}

async function boundedFetch(
  fetcher: typeof globalThis.fetch,
  input: RequestInfo | URL,
  init: RequestInit = {},
  timeoutMs: number = SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS,
): Promise<Response> {
  const abort = new AbortController();
  const external = init.signal ?? undefined;
  let timedOut = false;
  const cancel = () => abort.abort();
  if (external?.aborted) abort.abort();
  else external?.addEventListener("abort", cancel, { once: true });
  const timer = setTimeout(() => {
    timedOut = true;
    abort.abort();
  }, timeoutMs);
  (timer as unknown as { unref?: () => void }).unref?.();
  try {
    return await fetcher(input, { ...init, signal: abort.signal });
  } catch (error) {
    if (timedOut) throw new SidecarError(SIDECAR_ERROR_TIMEOUT, "sidecar request timed out", true);
    if (external?.aborted)
      throw new SidecarError(SIDECAR_ERROR_CANCELLED, "sidecar request was cancelled");
    throw error;
  } finally {
    clearTimeout(timer);
    external?.removeEventListener("abort", cancel);
  }
}

function capabilitiesFromWire(value: unknown): SidecarCapability[] {
  if (value === undefined) return [];
  if (!Array.isArray(value))
    throw new SidecarError(
      SIDECAR_ERROR_PROVIDER_FAILED,
      "sidecar capability response was malformed",
    );
  return value.map((value) => {
    const item = value && typeof value === "object" ? (value as Record<string, unknown>) : {};
    const fork = item.fork === 1 ? "omit" : item.fork === 2 ? "clone" : undefined;
    if (
      typeof item.kind !== "string" ||
      typeof item.version !== "number" ||
      typeof item.contractDigest !== "string" ||
      !Array.isArray(item.placements) ||
      fork === undefined ||
      typeof item.maxInstancesPerVm !== "number"
    ) {
      throw new SidecarError(
        SIDECAR_ERROR_PROVIDER_FAILED,
        "sidecar capability response was malformed",
      );
    }
    return ownCapability({
      kind: item.kind,
      version: item.version,
      contractDigest: item.contractDigest,
      placements: item.placements as SidecarPlacement[],
      fork,
      maxInstancesPerVm: item.maxInstancesPerVm,
    });
  });
}

function instancesFromWire(value: unknown): SidecarInstance[] {
  if (!Array.isArray(value))
    throw new SidecarError(
      SIDECAR_ERROR_PROVIDER_FAILED,
      "sidecar instance list response was malformed",
    );
  return value.map(instanceFromWire);
}

function scopeFromWire(value: unknown): { id: string; token: string; expiresAtMs: number } {
  const scope = value && typeof value === "object" ? (value as Record<string, unknown>) : {};
  if (
    typeof scope.id !== "string" ||
    enc.encode(scope.id).length === 0 ||
    enc.encode(scope.id).length > SIDECAR_MAX_NAME_BYTES ||
    typeof scope.token !== "string" ||
    enc.encode(scope.token).length === 0 ||
    enc.encode(scope.token).length > SIDECAR_MAX_REQUEST_BYTES ||
    typeof scope.expiresAtMs !== "number" ||
    !Number.isSafeInteger(scope.expiresAtMs) ||
    scope.expiresAtMs <= Date.now()
  ) {
    throw new SidecarError(SIDECAR_ERROR_PROVIDER_FAILED, "sidecar scope response was malformed");
  }
  return { id: scope.id, token: scope.token, expiresAtMs: scope.expiresAtMs };
}

export { SIDECAR_WARNING_BUFFER };
