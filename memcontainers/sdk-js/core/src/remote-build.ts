import { llb, type BuildDefinition, type BuildRef } from "./llb.js";
import type { ContentStore, ImageManifest } from "./types.js";

export interface RemoteBuildOptions {
  endpoint: string;
  token?: string;
  /** Store that owns out-of-line blobs referenced by a prebuilt Definition. */
  store?: ContentStore;
}

export interface RemoteBuildResult {
  definitionDigest: string;
  rootDigest: string;
  kernelDigest: string;
  manifestRef: string;
  image: ImageManifest;
  layers: { digest: string; size: number }[];
}

class RemoteDefinitionStore implements ContentStore {
  private readonly base: string;
  private readonly headers: Record<string, string>;

  constructor(opts: RemoteBuildOptions) {
    this.base = opts.endpoint.replace(/\/$/, "");
    this.headers = opts.token ? { authorization: `Bearer ${opts.token}` } : {};
  }

  async blob(digest: string): Promise<Uint8Array> {
    const response = await fetch(`${this.base}/v1/blobs/${encodeURIComponent(digest)}`, {
      headers: this.headers,
    });
    await requireOk(response, `remote blob ${digest}`);
    return responseBytes(response);
  }

  async putBlob(bytes: Uint8Array): Promise<string> {
    const response = await fetch(`${this.base}/v1/blobs`, {
      method: "POST",
      headers: { ...this.headers, "content-type": "application/octet-stream" },
      body: bytes as BodyInit,
    });
    await requireOk(response, "remote blob upload");
    const body = (await response.json()) as { digest?: unknown };
    if (typeof body.digest !== "string") {
      throw new Error(`remote blob upload returned no digest: ${JSON.stringify(body)}`);
    }
    return body.digest;
  }

  layer(_digest: string): Promise<Uint8Array> {
    return Promise.reject(new Error("remote build client cannot read server layers"));
  }

  put(_tar: Uint8Array): Promise<string> {
    return Promise.reject(new Error("remote build client cannot upload layers directly"));
  }

  manifest(_name: string): Promise<ImageManifest> {
    return Promise.reject(new Error("remote build client cannot read server manifests"));
  }

  putManifest(_name: string, _m: ImageManifest): Promise<void> {
    return Promise.reject(new Error("remote build client cannot write server manifests directly"));
  }
}

function isBuildDefinition(input: BuildRef): input is BuildDefinition {
  const candidate = input as Partial<BuildDefinition>;
  return (
    Array.isArray(candidate.ops) &&
    typeof candidate.root === "number" &&
    typeof candidate.version === "number"
  );
}

async function requireOk(response: Response, action: string): Promise<void> {
  if (response.ok) return;
  throw new Error(`${action} failed: ${response.status} ${await safeText(response)}`);
}

async function safeText(response: Response): Promise<string> {
  try {
    return await response.text();
  } catch {
    return "";
  }
}

async function responseBytes(response: Response): Promise<Uint8Array> {
  return new Uint8Array(await response.arrayBuffer());
}

async function sha256Digest(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", bytes as Uint8Array<ArrayBuffer>),
  );
  let hex = "";
  for (const byte of digest) hex += byte.toString(16).padStart(2, "0");
  return `sha256:${hex}`;
}

function definitionBlobRefs(definition: BuildDefinition): string[] {
  const refs = new Set<string>();
  for (const op of definition.ops) {
    if (op.data_digest) refs.add(op.data_digest);
  }
  return [...refs].sort();
}

async function uploadDefinitionBlobs(
  definition: BuildDefinition,
  localStore: ContentStore | undefined,
  remoteStore: RemoteDefinitionStore,
): Promise<void> {
  for (const digest of definitionBlobRefs(definition)) {
    if (!localStore) {
      try {
        await remoteStore.blob(digest);
        continue;
      } catch {
        throw new Error(
          `remote build Definition references blob ${digest}; pass opts.store so it can be uploaded`,
        );
      }
    }
    const uploaded = await remoteStore.putBlob(await localStore.blob(digest));
    if (uploaded !== digest) {
      throw new Error(`remote blob upload digest mismatch: expected ${digest}, got ${uploaded}`);
    }
  }
}

function sameJson(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

function bytesFromJson(value: unknown, field: string): Uint8Array {
  if (!Array.isArray(value)) {
    throw new Error(`remote build ${field} must be a byte array`);
  }
  return Uint8Array.from(
    value.map((byte, index) => {
      if (!Number.isInteger(byte) || byte < 0 || byte > 255) {
        throw new Error(`remote build ${field}[${index}] is not a byte`);
      }
      return byte;
    }),
  );
}

async function validateRemoteBuildResult(
  result: RemoteBuildResult,
  expectedDefinitionBytes: Uint8Array,
  expectedBlobRefs: readonly string[],
): Promise<RemoteBuildResult> {
  const expectedDefinitionDigest = await sha256Digest(expectedDefinitionBytes);
  const digestPattern = /^sha256:[0-9a-f]{64}$/;
  if (result.definitionDigest !== expectedDefinitionDigest) {
    throw new Error(
      `remote build definition digest mismatch: expected ${expectedDefinitionDigest}, got ${result.definitionDigest}`,
    );
  }
  if (!digestPattern.test(result.rootDigest)) {
    throw new Error(
      `remote build returned invalid rootDigest: ${JSON.stringify(result.rootDigest)}`,
    );
  }
  if (!digestPattern.test(result.kernelDigest)) {
    throw new Error(
      `remote build returned invalid kernelDigest: ${JSON.stringify(result.kernelDigest)}`,
    );
  }
  const expectedManifestRef = `node-${result.rootDigest.slice("sha256:".length)}`;
  if (result.manifestRef !== expectedManifestRef) {
    throw new Error(
      `remote build manifestRef mismatch: expected ${expectedManifestRef}, got ${result.manifestRef}`,
    );
  }
  const build = result.image?.build;
  if (!build || build.definition.digest !== expectedDefinitionDigest) {
    throw new Error(
      `remote build provenance definition digest mismatch: expected ${expectedDefinitionDigest}, got ${build?.definition.digest}`,
    );
  }
  const definitionBytes = bytesFromJson(build.definition.bytes, "provenance definition bytes");
  if (!sameBytes(definitionBytes, expectedDefinitionBytes)) {
    throw new Error(
      "remote build provenance definition bytes mismatch: embedded bytes are not the posted Definition",
    );
  }
  const embeddedDefinitionDigest = await sha256Digest(definitionBytes);
  if (embeddedDefinitionDigest !== expectedDefinitionDigest) {
    throw new Error(
      `remote build provenance definition bytes digest mismatch: expected ${expectedDefinitionDigest}, got ${embeddedDefinitionDigest}`,
    );
  }
  if (build.rootDigest !== result.rootDigest) {
    throw new Error(
      `remote build provenance rootDigest mismatch: expected ${result.rootDigest}, got ${build.rootDigest}`,
    );
  }
  if (build.kernelDigest !== result.kernelDigest) {
    throw new Error(
      `remote build provenance kernelDigest mismatch: expected ${result.kernelDigest}, got ${build.kernelDigest}`,
    );
  }
  if (!sameJson(result.layers, result.image.layers)) {
    throw new Error("remote build layers mismatch between top-level result and image manifest");
  }
  if (!sameJson(result.image.layers, build.storeRefs.layers)) {
    throw new Error("remote build layers mismatch between image manifest and build provenance");
  }
  if (!sameJson([...expectedBlobRefs].sort(), [...build.storeRefs.blobs].sort())) {
    throw new Error(
      "remote build blob refs mismatch between posted Definition and build provenance",
    );
  }
  return result;
}

/** Solve a portable LLB definition on a remote AgentOS server.
 *
 * A `BuildState` is first projected to the canonical `llb.Definition`, with large write payloads uploaded
 * out-of-line through `/v1/blobs`. The canonical definition bytes are then posted to `/v1/build`; the
 * client describes the graph, the server materializes it next to its store.
 */
export async function remoteBuild(
  input: BuildRef,
  opts: RemoteBuildOptions,
): Promise<RemoteBuildResult> {
  const store = new RemoteDefinitionStore(opts);
  const definition = isBuildDefinition(input) ? input : await llb.toDefinition(input, { store });
  if (isBuildDefinition(input)) await uploadDefinitionBlobs(definition, opts.store, store);
  const definitionBytes = llb.encodeDefinition(definition);
  const base = opts.endpoint.replace(/\/$/, "");
  const headers: Record<string, string> = {};
  if (opts.token) headers.authorization = `Bearer ${opts.token}`;
  const response = await fetch(`${base}/v1/build`, {
    method: "POST",
    headers: { ...headers, "content-type": "application/octet-stream" },
    body: definitionBytes as BodyInit,
  });
  await requireOk(response, "remote build");
  return validateRemoteBuildResult(
    (await response.json()) as RemoteBuildResult,
    definitionBytes,
    definitionBlobRefs(definition),
  );
}
