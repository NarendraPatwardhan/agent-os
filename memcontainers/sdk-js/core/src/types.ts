// Public types for the unified consumer API (`mc` / `vm`).

/** Which backend hosts the kernel. */
export type Runtime = "local" | "browser" | "remote";

/** Declarative permissions. Network egress is gated host-side today; fs/tier
 *  enforcement applies to guests spawned inside the VM (e.g. the internal
 *  agent). The host-driven control channel always acts as the trusted operator. */
export interface Permissions {
  fs?: "allow" | "deny" | { allow: Array<"read" | "write"> };
  network?: "allow" | "deny" | { allow?: string[] };
}

/** Options for {@link mc.create}. */
export interface CreateOptions {
  /** Backend. Default `"local"`. */
  runtime?: Runtime;
  /** Remote endpoint (runtime `"remote"` only). */
  endpoint?: string;
  /** Stable VM id for remote create/restore. Omit on create to let the server assign one. */
  id?: string;
  /** Bearer token (remote). */
  token?: string;
  /** Rootfs image: raw tar bytes (one layer), a flavor name (`"minimal"` /
   *  `"posix"` / `"loom"` / `"paper"` / `"atlas"`), the logical `"base:latest"`, a committed diff-layer digest
   *  (`"sha256:…"` stacked over the default base), a built {@link ImageManifest}
   *  (an ordered layer stack + runtime contract), or `null` for an empty
   *  in-memory fs. Default `"base:latest"`. */
  image?: Uint8Array | string | ImageManifest | null;
  /** Content store backing flavor / digest resolution (committed layers +
   *  manifests). Defaults to `MC_STORE` or the workspace flavor store. */
  store?: ContentStore;
  /** Kernel wasm bytes (embedded). Defaults to the workspace build artifact. */
  kernel?: Uint8Array;
  /** Enable network egress (installs the host net capability). → `CAP_NET`. */
  net?: boolean;
  /** Host-side credential registry. Guest catalogs hold only connection refs; these secret values are
   *  spliced into HTTP requests by the host when a request carries `X-MC-Connection`. For remote
   *  runtime, create sends these definitions to the trusted server host; they still do not enter guest
   *  memory or the tool catalog. */
  connections?: ConnectionDefinition[];
  /** catalog-compiler.wasm bytes (embedded). Defaults to $MC_CATALOG_COMPILER_WASM when a connection
   *  needs host-side catalog compilation. */
  catalogCompiler?: Uint8Array;
  /** Make `/var/persist` durable (embedded backend). In a browser this is backed
   *  by OPFS (IndexedDB fallback) so state survives a page reload; elsewhere it is
   *  in-memory for the VM's lifetime. → `CAP_PERSIST`. */
  persist?: boolean;
  /** Declarative permissions (see {@link Permissions}). */
  permissions?: Permissions;
  /** Embedder-owned egress policy, evaluated at the credential splice before method-based destructive
   *  classification. Policy is **connection-granular**, not per-tool: the splice authorizes a request by
   *  its connection (`integration.owner.connection`), method, and origin — it does not see the catalog
   *  tool address — so patterns match a connection or coarser (`integration.owner.connection.*`,
   *  `integration.*`, `*`). A per-tool pattern like `github.org.main.deleteRepo` is rejected at create. */
  policies?: ConnectionPolicyRule[];
  /** Interactive approval for network egress or destructive connection egress. Call `req.allow()` to
   *  let the operation proceed or `req.reject()` to deny. With no handler, operations that require
   *  approval are denied. */
  onPermission?: (req: PermissionRequest) => void | Promise<void>;
  /** Host-resident tools to register at boot (see {@link tool} / {@link kit}), plus optional
   *  connection tool groups such as `"github/issues"` for host-side catalog compilation. */
  tools?: Array<ToolDefinition | string>;
  /** Restore-time host attachment policy. A snapshot carries guest-visible catalog state, but JS
   *  closures, connection credentials, mounts, and callbacks live in the restoring host process.
   *  `"strict"` (default) refuses to return a VM when restored catalog entries need host attachments
   *  that were not supplied in these options; `"detached"` permits inspection-only restores with those
   *  entries still listed but not necessarily callable. Ignored on fresh create. */
  restoreAttachments?: "strict" | "detached";
  /** Host-backed filesystem mounts to install at boot (see {@link MountSpec} and
   *  the drivers at `@mc/core/drivers`). */
  mounts?: MountSpec[];
  /** Deterministic clock + RNG (for reproducible runs / tests). */
  deterministic?: boolean;
}

export type ConnectionAuth =
  | { kind: "none" }
  | { kind: "bearer"; token: string }
  | { kind: "header"; name: string; value: string }
  | { kind: "query"; name: string; value: string };

export type CatalogFormat =
  | "openapi"
  | "microsoft-graph"
  | "google-discovery"
  | "graphql"
  | "mcp-remote";

export type CatalogSourceFormat = "json" | "yaml";

export type ConnectionSpecSource =
  | {
      bytes: Uint8Array;
      format?: CatalogFormat;
      sourceFormat?: CatalogSourceFormat;
      baseUrl?: string;
      endpoint?: string;
    }
  | {
      path: string;
      format?: CatalogFormat;
      sourceFormat?: CatalogSourceFormat;
      baseUrl?: string;
      endpoint?: string;
    }
  | {
      url: string;
      format?: CatalogFormat;
      sourceFormat?: CatalogSourceFormat;
      baseUrl?: string;
      endpoint?: string;
    };

export interface ConnectionDefinition {
  /** `integration.owner.name`, where owner is `org` or `user`. */
  ref: string;
  auth: ConnectionAuth;
  /** Absolute `http`/`https` origins allowed to receive this connection's host-side credential.
   *  Optional: when omitted for a curated-registry integration, the host derives it from the registry
   *  entry's `servers`, so the connection is just `{ ref, auth }`. Pass it only to narrow further, or
   *  for a custom (non-registry) `spec`. */
  origins?: string[];
  /** Provided spec bytes/path bypass host fetch; URL overrides the registry's public spec URL. */
  spec?: ConnectionSpecSource;
  /** Per-connection tool group override. Top-level `tools: ["github/issues"]` is also accepted. */
  tools?: string[];
}

export type ConnectionPolicyAction = "approve" | "require_approval" | "block";
export type ConnectionPolicyOwner = "org" | "user";

/** One egress-policy rule. `pattern` matches a **connection**, not a tool: `integration.owner.connection.*`
 *  or a coarser prefix (`integration.owner.*`, `integration.*`, `*`). Across owners the most restrictive
 *  matching action wins; within an owner the first match wins. */
export interface ConnectionPolicyRule {
  owner: ConnectionPolicyOwner;
  pattern: string;
  action: ConnectionPolicyAction;
}

/** A built image: an ordered stack of content-addressed layers plus the
 *  runtime contract (`config`). Produced by stacking `vm.commit().asLayer()`
 *  outputs; booted by `mc.create({ image: manifest })`. */
export interface ImageManifest {
  schema: 1;
  /** Ordered lowest→highest; each `digest` resolves to a `.tar` layer in the store. */
  layers: { digest: string; size: number }[];
  config: ImageConfig;
  /** Portable build provenance for LLB-built images. */
  build?: BuildRecord;
  created?: string;
}

export interface BuildRecord {
  schema: 1;
  /** Canonical encoded `llb.Definition` bytes, plus their content digest. */
  definition: {
    encoding: "mc.llb.definition.v1";
    digest: string;
    bytes: number[];
  };
  /** Canonical digest of the root build graph node. */
  rootDigest: string;
  /** Digest of the `kernel.wasm` bytes used for VM-executing build steps. */
  kernelDigest: string;
  /** Content-store objects needed by the image/provenance bundle. */
  storeRefs: {
    layers: { digest: string; size: number }[];
    blobs: string[];
  };
}

/** The runtime contract carried by an {@link ImageManifest} (SYSTEMS.md §11 — "Docker can't say:
 *  runs deterministically in ≤512 MiB"). Enforced at boot. */
export interface ImageConfig {
  /** Capability tier the VM boots at (intersected with the kernel default). */
  tier?: "full" | "read-write" | "read-only" | "isolated";
  /** Memory ceiling (MiB) enforced per guest via the kernel's `mc_budget`. */
  budgetMib?: number;
  /** Execution-fuel ceiling per guest. */
  fuel?: number;
}

export interface ExecOptions {
  /** Working directory for the command. Relative paths resolve against the VM's current cwd. */
  cwd?: string;
  /** Environment overrides layered on top of the VM's live boot environment. */
  env?: Record<string, string>;
  /** Bytes to expose as fd 0 for the command. Strings are UTF-8 encoded. */
  stdin?: string | Uint8Array;
}

/** A content-addressed store for committed layers, generic blobs (by `sha256:`
 *  digest), and image manifests (by flavor/image name). A local-dir
 *  implementation; a registry/persistfs-backed store is a later addition. */
export interface ContentStore {
  /** Read a layer's `.tar` bytes by `"sha256:…"` digest. */
  layer(digest: string): Promise<Uint8Array>;
  /** Store a `.tar` layer, returning its `"sha256:…"` digest. */
  put(tar: Uint8Array): Promise<string>;
  /** Read arbitrary content-addressed bytes by `"sha256:…"` digest. */
  blob(digest: string): Promise<Uint8Array>;
  /** Store arbitrary bytes, returning their `"sha256:…"` digest. */
  putBlob(bytes: Uint8Array): Promise<string>;
  /** Read a named manifest (a flavor like `"posix"`, or a built image). */
  manifest(name: string): Promise<ImageManifest>;
  /** Store a named manifest. */
  putManifest(name: string, m: ImageManifest): Promise<void>;
  /** Optional warm-VM snapshot memo (the `llb` solver's `asSnapshot`, SYSTEMS.md §8):
   *  read/write a whole-VM image keyed by a node digest. `null` on a miss. */
  snapshot?(key: string): Promise<Uint8Array | null>;
  putSnapshot?(key: string, snap: Uint8Array): Promise<void>;
}

/** One host-backed mount to install at boot (`mc.create({ mounts: [...] })`) or
 *  at runtime ({@link Vm.mount}). */
export interface MountSpec {
  /** Absolute mount point inside the VM (conventionally under `/mnt/`). */
  path: string;
  /** The driver that backs it (`s3`/`hostDir`/`vectorStore`, or your own). */
  driver: Driver;
  /** Mount read-only (the kernel rejects writes). Defaults to `driver.readOnly`,
   *  else false. A read-only corpus + no `net` = read-but-can't-exfiltrate. */
  readOnly?: boolean;
}

/** A network egress prompt raised to {@link CreateOptions.onPermission}. Resolve it exactly once with
 *  `allow()` or `reject()`. */
export interface NetworkPermissionRequest {
  readonly id: number;
  readonly kind: "network";
  /** The egress host being requested (e.g. `api.example.com`). */
  readonly host: string;
  readonly url: string;
  /** Permit the request; `remember:"session"` skips future prompts for this host. */
  allow(opts?: { remember?: "once" | "session" }): void;
  /** Deny the request (the guest sees an ordinary network/IO error). */
  reject(message?: string): void;
}

/** A destructive connection-egress prompt raised to {@link CreateOptions.onPermission}. The request
 *  carries only host-computed facts from the actual outgoing HTTP request, never catalog text or
 *  host-injected credentials. */
export interface ToolApprovalPermissionRequest {
  readonly id: number;
  readonly kind: "tool_approval";
  readonly connection: string;
  readonly method: string;
  readonly url: string;
  readonly origin: string;
  readonly argsDigest?: string;
  /** Permit the request; `remember:"session"` skips future prompts for the same connection/method/url. */
  allow(opts?: { remember?: "once" | "session" }): void;
  reject(message?: string): void;
}

export type PermissionRequest = NetworkPermissionRequest | ToolApprovalPermissionRequest;

/** A directory entry a {@link Driver} returns from `readdir`. */
export interface DriverEntry {
  name: string;
  kind: "file" | "dir";
}

/** Metadata a {@link Driver} returns from `stat`. */
export interface DriverMeta {
  kind: "file" | "dir";
  /** Size in bytes (0 for a directory). */
  size: number;
}

/** An error a {@link Driver} method may throw to surface a specific POSIX errno
 *  to the guest (e.g. `Object.assign(new Error("missing"), { code: "ENOENT" })`).
 *  An uncoded throw maps to `EIO`. */
export interface DriverError extends Error {
  code?: "ENOENT" | "EACCES" | "EEXIST" | "ENOTDIR" | "EISDIR" | "ENOTEMPTY" | "EINVAL";
}

/** A host-backed mount driver: each method mirrors a VFS op the kernel's
 *  `MountFs` proxies over the host-call bridge. Read ops are required; write ops
 *  are optional (a driver that omits them is implicitly read-only). All methods
 *  are async and binary-safe. Paths are mount-relative and absolute (`/foo/bar`).
 *  Build one with {@link s3} / {@link hostDir} / {@link vectorStore}, or hand-roll. */
export interface Driver {
  /** Read the whole file at `path`. Throw with `.code = "ENOENT"` if absent. */
  open(path: string): Promise<Uint8Array>;
  /** Metadata for `path`. */
  stat(path: string): Promise<DriverMeta>;
  /** List the directory at `path`. */
  readdir(path: string): Promise<DriverEntry[]>;
  /** Write (create/truncate) `path`. Omit to make the mount read-only. */
  write?(path: string, data: Uint8Array): Promise<void>;
  /** Create a directory at `path`. */
  mkdir?(path: string): Promise<void>;
  /** Remove the file or empty directory at `path`. */
  unlink?(path: string): Promise<void>;
  /** Rename `from` to `to` (both mount-relative). */
  rename?(from: string, to: string): Promise<void>;
  /** Force read-only even if write methods exist (e.g. a RAG corpus). */
  readOnly?: boolean;
}

/** Result of {@link Vm.exec}: decoded streams + raw bytes + the real exit code. */
export interface ExecResult {
  stdout: string;
  stderr: string;
  stdoutBytes: Uint8Array;
  stderrBytes: Uint8Array;
  exitCode: number;
}

export interface DirEntry {
  name: string;
  isDir: boolean;
  isSymlink: boolean;
}

export interface StatResult {
  size: number;
  isDir: boolean;
  isSymlink: boolean;
  nlink: number;
  mode: number;
}

/** Filesystem ops on a VM — Unix verbs, grouped under `vm.fs` and also exposed
 *  to host tools as `ctx.fs`. */
export interface VmFs {
  /** Read a file as raw bytes. */
  read(path: string): Promise<Uint8Array>;
  /** Read a file as UTF-8 text. */
  readText(path: string): Promise<string>;
  /** Write a file (truncating), from text or bytes. */
  write(path: string, data: string | Uint8Array): Promise<void>;
  /** List a directory. */
  ls(path: string): Promise<DirEntry[]>;
  /** Stat a path (reports the link itself for symlinks). */
  stat(path: string): Promise<StatResult>;
  /** Read the target text of a symbolic link without following it. */
  readlink(path: string): Promise<string>;
  /** Create a directory. */
  mkdir(path: string): Promise<void>;
  /** Remove a file or empty directory. */
  rm(path: string): Promise<void>;
  /** Set POSIX permission bits. */
  chmod(path: string, mode: number): Promise<void>;
  /** Create a symbolic link at `link` pointing at `target` (target text is stored
   *  verbatim — relative targets resolve against the link's directory). */
  symlink(target: string, link: string): Promise<void>;
}

/** A JSON-Schema fragment describing a tool's input (for LLM/agent introspection). */
export type JsonSchema = Record<string, unknown>;

/** Host-tool execution context. The handler still runs host-side, but `ctx.fs`
 *  is the trusted operator view of the VM filesystem, so tools can accept paths
 *  and leave their inputs/outputs inspectable inside the sandbox. */
export interface ToolContext {
  fs: VmFs;
}

/** A host-resident tool a guest can invoke through `/svc/tools`. The `name` is the host-call binding
 *  key; `address` is the optional catalog address exposed to in-VM discovery. The `run` handler
 *  executes host-side and receives parsed JSON args plus a VM context. */
export interface ToolDefinition {
  /** Host-call binding key. Must be non-empty, must not start with `/`, and must not contain control
   *  characters; `/...` is reserved for raw host-backed mount handlers. */
  name: string;
  /** Full catalog address. Defaults to `host.org.main.<normalized name>`. */
  address?: string;
  description?: string;
  /** JSON-Schema for the input args (produced by {@link tool} from a zod schema). */
  input?: JsonSchema;
  /** Optional JSON-Schema for the output value. */
  output?: JsonSchema;
  /** Tool-plane annotations such as requires_approval/read_only. */
  annotations?: Record<string, unknown>;
  /** Receives the parsed JSON args and a host-side VM context; returns a string
   *  or any JSON-able value. */
  run: (input: Record<string, unknown>, ctx: ToolContext) => Promise<unknown> | unknown;
}

/** A framed event from an in-VM agent session (the internal agent loop). The agent
 *  guest emits one JSON object per line on stdout; the host parses them. */
export interface SessionEvent {
  type: string;
  text?: string;
  [key: string]: unknown;
}

/** A handle to an in-VM agent session (returned by {@link Vm.session}). */
export interface SessionHandle {
  /** The session id. */
  readonly id: string;
  /** Prompt the session; resolves with the framed events it emitted. */
  prompt(text: string): Promise<SessionEvent[]>;
  /** Subscribe to the session's framed events. Returns an unsubscribe fn. */
  on(cb: (e: SessionEvent) => void): () => void;
}

/** A lightweight status snapshot for a VM (returned by {@link Vm.status}). */
export interface VmStatus {
  /** False once the kernel has exited (embedded), else true. */
  running: boolean;
  /** WASM linear-memory footprint in bytes (`0` if not measurable, e.g. remote). */
  memoryBytes: number;
  /** Host-egress operations currently in flight. */
  inflightEgress: number;
}

/** An interactive shell view (xterm-style): bytes in, bytes out. */
export interface Shell {
  /** Subscribe to terminal output. Returns an unsubscribe fn. */
  on(cb: (bytes: Uint8Array) => void): () => void;
  /** Send keystrokes / a line (append "\n" yourself). */
  write(data: string | Uint8Array): void;
  /** All terminal bytes emitted so far (boot banner + prior output). */
  history(): Uint8Array;
}
