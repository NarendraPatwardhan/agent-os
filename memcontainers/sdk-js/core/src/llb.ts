// `llb` — the build grammar. A small set of composable values forming a
// content-addressed DAG of filesystem ops. Each verb returns an opaque
// `BuildState`; `toDefinition` serializes it to the contract-defined portable
// `Definition`; NOTHING runs until `llb.commit(state).asLayer()/.asSnapshot()`
// triggers the solver (`solve.ts`). The verbs map 1:1 onto the VM build primitives —
// `source` = a flavor/image, `write`/`mkdir`/`rm`/`chmod`/`symlink` = `vm.fs.*`,
// `exec` = `vm.exec`, `merge`/`image` = stacked layers, `diff` = the CoW overlay, `commit` = the
// `commit` primitive. "Primitives, not a frontend": no Dockerfile parser.

import {
  decodeDefinition as decodeContractDefinition,
  encodeDefinition as encodeContractDefinition,
} from "@mc/contracts/llb";
import type {
  BuildOp as ContractBuildOp,
  CopyPath as ContractCopyPath,
  Definition as ContractDefinition,
} from "@mc/contracts/llb";
import type { ContentStore, ExecOptions, ImageConfig, ImageManifest } from "./types.js";
import { commitImage, commitImageWithBuildRecord, commitLayer, commitSnapshot, type SolveOptions } from "./solve.js";
import { defaultStore } from "./store.js";

/** A node in the build DAG (internal — consumers hold an opaque {@link BuildState}). */
export type BuildNode =
  | { readonly op: "source"; readonly ref: string }
  | { readonly op: "layer"; readonly ref: string }
  | { readonly op: "local"; readonly path: string; readonly dest: string }
  | { readonly op: "http"; readonly url: string; readonly dest: string; readonly expectedDigest?: string }
  | { readonly op: "git"; readonly repo: string; readonly ref: string; readonly dest: string }
  | { readonly op: "write"; readonly input: BuildNode; readonly path: string; readonly data: Uint8Array }
  | { readonly op: "mkdir"; readonly input: BuildNode; readonly path: string }
  | { readonly op: "rm"; readonly input: BuildNode; readonly path: string }
  | { readonly op: "chmod"; readonly input: BuildNode; readonly path: string; readonly mode: number }
  | { readonly op: "symlink"; readonly input: BuildNode; readonly target: string; readonly link: string }
  | { readonly op: "exec"; readonly input: BuildNode; readonly cmd: string; readonly opts: ExecOpts }
  | { readonly op: "copy"; readonly dest: BuildNode; readonly src: BuildNode; readonly paths: readonly CopyPath[] }
  | { readonly op: "merge"; readonly a: BuildNode; readonly b: BuildNode }
  | { readonly op: "diff"; readonly lower: BuildNode; readonly upper: BuildNode }
  | { readonly op: "image"; readonly parts: readonly BuildNode[]; readonly config: ImageConfig }
  | { readonly op: "cache"; readonly path: string };

/** Options for an `llb.exec` node. */
export interface ExecOpts extends ExecOptions {
  /** Capability tier to boot the build VM at. Defaults to `read-write`, which can
   *  read inputs, write the overlay, and use scratch, but cannot spawn child tools,
   *  open network, persist, or mount. Use `full` only for steps that need those
   *  authorities; use `isolated` for pure read/compute steps confined to cwd. */
  tier?: ImageConfig["tier"];
  budgetMib?: number;
  fuel?: number;
  /** Run under the deterministic clock/RNG so the layer digest is reproducible —
   *  the node is then cache-SOUND. Default `true`. */
  deterministic?: boolean;
  /** The step makes network egress: cache-UNSAFE, so the solver always re-runs it
   *  and never memoizes the result. Default `false`. */
  net?: boolean;
  /** Persistent cache mounts (`llb.cache(path)`) visible to the command. */
  mounts?: BuildState[];
}

export interface CopyPath {
  readonly from: string;
  readonly to: string;
}

export interface LocalSourceOptions {
  /** Absolute destination directory inside the VM. Defaults to `/`. */
  dest?: string;
}

export interface HttpSourceOptions {
  /** Absolute destination file path inside the VM. */
  dest: string;
  /** Optional expected content digest, formatted as `sha256:<hex>`. */
  sha256?: string;
}

export interface GitSourceOptions {
  /** Commit, tag, or branch to archive. Pinned commits are cache-sound; mutable refs resolve per solve. */
  ref: string;
  /** Absolute destination directory inside the VM. Defaults to `/`. */
  dest?: string;
}

/** An opaque handle to a build-DAG node. */
export interface BuildState {
  readonly node: BuildNode;
}

export type BuildDefinition = ContractDefinition;
export type BuildRef = BuildState | BuildDefinition;

export interface DefinitionOptions {
  /** Store used for out-of-line write payload bytes. Defaults to {@link defaultStore}. */
  store?: ContentStore;
}

const enc = (s: string): Uint8Array => new TextEncoder().encode(s);
const st = (node: BuildNode): BuildState => ({ node });

const LLB_DEFINITION_VERSION = 1;
const OP_SOURCE = 0;
const OP_LAYER = 1;
const OP_WRITE = 2;
const OP_MKDIR = 3;
const OP_RM = 4;
const OP_CHMOD = 5;
const OP_SYMLINK = 6;
const OP_EXEC = 7;
const OP_COPY = 8;
const OP_MERGE = 9;
const OP_DIFF = 10;
const OP_IMAGE = 11;
const OP_CACHE = 12;
const OP_LOCAL = 13;
const OP_HTTP = 14;
const OP_GIT = 15;

function isBuildDefinition(value: BuildRef): value is BuildDefinition {
  const candidate = value as Partial<BuildDefinition>;
  return Array.isArray(candidate.ops) && typeof candidate.root === "number" && typeof candidate.version === "number";
}

function definitionBlobRefs(definition: BuildDefinition): string[] {
  const refs = new Set<string>();
  for (const op of definition.ops) {
    if (op.data_digest) refs.add(op.data_digest);
  }
  return [...refs].sort();
}

function definitionStore(opts: DefinitionOptions, why: string): ContentStore {
  try {
    return opts.store ?? defaultStore();
  } catch (e) {
    throw new Error(`llb Definition ${why} needs a ContentStore: ${(e as Error).message}`);
  }
}

const emptyOp = (kind: number): ContractBuildOp => ({ kind, parts: [], copy_paths: [], env: {}, mounts: [] });

const inputRef = (index: number): { index: number } => ({ index });

function requireIndex(
  value: number | null | undefined,
  field: string,
  at: number,
  states: BuildState[],
): BuildState {
  if (value === undefined || value === null) throw new Error(`llb Definition op ${at} missing ${field}`);
  if (!Number.isInteger(value) || value < 0 || value >= states.length) {
    throw new Error(`llb Definition op ${at} has invalid ${field} index ${value}`);
  }
  return states[value]!;
}

function requireString(value: string | null | undefined, field: string, at: number): string {
  if (value === undefined || value === null) throw new Error(`llb Definition op ${at} missing ${field}`);
  return value;
}

function validateSourceRef(ref: string, field = "source_ref"): string {
  if (ref === "") throw new Error(`llb ${field} must be a non-empty string`);
  if (ref.includes("\0")) throw new Error(`llb ${field} contains NUL`);
  if (ref.startsWith("/net/") || ref.startsWith("http://") || ref.startsWith("https://")) {
    throw new Error(`llb ${field} must use llb.http() for network sources: ${JSON.stringify(ref)}`);
  }
  return ref;
}

function requireMode(value: number | null | undefined, field: string, at: number): number {
  if (value === undefined || value === null) throw new Error(`llb Definition op ${at} missing ${field}`);
  return validateMode(value, `llb Definition op ${at} ${field}`);
}

function validateMode(mode: number, field = "mode"): number {
  if (!Number.isInteger(mode) || mode < 0 || mode > 0o7777) {
    throw new Error(`${field} must be an integer in 0..0o7777`);
  }
  return mode;
}

function requireCopyPaths(paths: readonly ContractCopyPath[], at: number): CopyPath[] {
  if (!paths.length) throw new Error(`llb Definition op ${at} needs at least one copy path`);
  return paths.map((path) => ({ from: path.src_path, to: path.dest_path }));
}

function imageConfig(op: ContractBuildOp): ImageConfig {
  return {
    ...(op.config_tier ? { tier: op.config_tier as ImageConfig["tier"] } : {}),
    ...(op.config_budget_mib !== undefined && op.config_budget_mib !== null
      ? { budgetMib: op.config_budget_mib }
      : {}),
    ...(op.config_fuel !== undefined && op.config_fuel !== null ? { fuel: op.config_fuel } : {}),
  };
}

const BUILD_OP_FIELDS = [
  "kind",
  "source_ref",
  "input",
  "src",
  "dest",
  "a",
  "b",
  "lower",
  "upper",
  "parts",
  "copy_paths",
  "path",
  "local_path",
  "http_url",
  "expected_digest",
  "git_repo",
  "git_ref",
  "dest_path",
  "data_digest",
  "target",
  "link",
  "mode",
  "cmd",
  "cwd",
  "env",
  "stdin",
  "tier",
  "budget_mib",
  "fuel",
  "deterministic",
  "net",
  "mounts",
  "config_tier",
  "config_budget_mib",
  "config_fuel",
] as const satisfies readonly (keyof ContractBuildOp)[];

function opAllowedFields(kind: number): ReadonlySet<keyof ContractBuildOp> | null {
  const fields = (() => {
    switch (kind) {
      case OP_SOURCE:
      case OP_LAYER:
        return ["kind", "source_ref"];
      case OP_LOCAL:
        return ["kind", "local_path", "dest_path"];
      case OP_HTTP:
        return ["kind", "http_url", "dest_path", "expected_digest"];
      case OP_GIT:
        return ["kind", "git_repo", "git_ref", "dest_path"];
      case OP_WRITE:
        return ["kind", "input", "path", "data_digest"];
      case OP_MKDIR:
      case OP_RM:
        return ["kind", "input", "path"];
      case OP_CHMOD:
        return ["kind", "input", "path", "mode"];
      case OP_SYMLINK:
        return ["kind", "input", "target", "link"];
      case OP_EXEC:
        return [
          "kind",
          "input",
          "cmd",
          "cwd",
          "env",
          "stdin",
          "tier",
          "budget_mib",
          "fuel",
          "deterministic",
          "net",
          "mounts",
        ];
      case OP_COPY:
        return ["kind", "dest", "src", "copy_paths"];
      case OP_MERGE:
        return ["kind", "a", "b"];
      case OP_DIFF:
        return ["kind", "lower", "upper"];
      case OP_IMAGE:
        return ["kind", "parts", "config_tier", "config_budget_mib", "config_fuel"];
      case OP_CACHE:
        return ["kind", "path"];
      default:
        return null;
    }
  })();
  return fields ? new Set(fields as (keyof ContractBuildOp)[]) : null;
}

function unusedFieldEmpty(value: unknown): boolean {
  if (value === undefined || value === null) return true;
  if (Array.isArray(value)) return value.length === 0;
  if (typeof value === "object" && value.constructor === Object) return Object.keys(value).length === 0;
  return false;
}

function assertNoUnusedBuildOpFields(op: ContractBuildOp, at: number): void {
  const allowed = opAllowedFields(op.kind);
  if (!allowed) return;
  for (const field of BUILD_OP_FIELDS) {
    if (allowed.has(field)) continue;
    if (!unusedFieldEmpty(op[field])) {
      throw new Error(`llb Definition op ${at} kind ${op.kind} has unused field ${field}`);
    }
  }
}

async function resolveBuildState(input: BuildRef, opts: DefinitionOptions = {}): Promise<BuildState> {
  return isBuildDefinition(input) ? fromDefinition(input, opts) : input;
}

export function encodeDefinition(definition: BuildDefinition): Uint8Array {
  return encodeContractDefinition(definition);
}

export function decodeDefinition(bytes: Uint8Array): BuildDefinition {
  return decodeContractDefinition(bytes);
}

export async function toDefinition(state: BuildState, opts: DefinitionOptions = {}): Promise<BuildDefinition> {
  const indexes = new Map<BuildNode, number>();
  const ops: ContractBuildOp[] = [];

  async function visit(node: BuildNode): Promise<number> {
    const existing = indexes.get(node);
    if (existing !== undefined) return existing;

    let op: ContractBuildOp;
    switch (node.op) {
      case "source":
        op = { ...emptyOp(OP_SOURCE), source_ref: node.ref };
        break;
      case "layer":
        op = { ...emptyOp(OP_LAYER), source_ref: node.ref };
        break;
      case "local":
        op = { ...emptyOp(OP_LOCAL), local_path: node.path, dest_path: node.dest };
        break;
      case "http":
        op = {
          ...emptyOp(OP_HTTP),
          http_url: node.url,
          dest_path: node.dest,
          expected_digest: node.expectedDigest,
        };
        break;
      case "git":
        op = {
          ...emptyOp(OP_GIT),
          git_repo: node.repo,
          git_ref: node.ref,
          dest_path: node.dest,
        };
        break;
      case "write": {
        const input = await visit(node.input);
        const data_digest = await definitionStore(opts, "write payload serialization").putBlob(node.data);
        op = { ...emptyOp(OP_WRITE), input, path: node.path, data_digest };
        break;
      }
      case "mkdir":
        op = { ...emptyOp(OP_MKDIR), input: await visit(node.input), path: node.path };
        break;
      case "rm":
        op = { ...emptyOp(OP_RM), input: await visit(node.input), path: node.path };
        break;
      case "chmod":
        op = { ...emptyOp(OP_CHMOD), input: await visit(node.input), path: node.path, mode: node.mode };
        break;
      case "symlink":
        op = {
          ...emptyOp(OP_SYMLINK),
          input: await visit(node.input),
          target: node.target,
          link: node.link,
        };
        break;
      case "exec": {
        const input = await visit(node.input);
        const mounts = node.opts.mounts ? await Promise.all(node.opts.mounts.map((m) => visit(m.node))) : [];
        const stdin =
          node.opts.stdin === undefined
            ? undefined
            : node.opts.stdin instanceof Uint8Array
              ? node.opts.stdin.slice()
              : enc(node.opts.stdin);
        op = {
          ...emptyOp(OP_EXEC),
          input,
          cmd: node.cmd,
          cwd: node.opts.cwd,
          env: { ...(node.opts.env ?? {}) },
          stdin,
          tier: node.opts.tier,
          budget_mib: node.opts.budgetMib,
          fuel: node.opts.fuel,
          deterministic: node.opts.deterministic,
          net: node.opts.net,
          mounts: mounts.map(inputRef),
        };
        break;
      }
      case "copy":
        op = {
          ...emptyOp(OP_COPY),
          dest: await visit(node.dest),
          src: await visit(node.src),
          copy_paths: node.paths.map((path) => ({ src_path: path.from, dest_path: path.to })),
        };
        break;
      case "merge":
        op = { ...emptyOp(OP_MERGE), a: await visit(node.a), b: await visit(node.b) };
        break;
      case "diff":
        op = { ...emptyOp(OP_DIFF), lower: await visit(node.lower), upper: await visit(node.upper) };
        break;
      case "image": {
        const parts = await Promise.all(node.parts.map(visit));
        op = {
          ...emptyOp(OP_IMAGE),
          parts: parts.map(inputRef),
          config_tier: node.config.tier,
          config_budget_mib: node.config.budgetMib,
          config_fuel: node.config.fuel,
        };
        break;
      }
      case "cache":
        op = { ...emptyOp(OP_CACHE), path: node.path };
        break;
    }

    const index = ops.length;
    ops.push(op);
    indexes.set(node, index);
    return index;
  }

  const root = await visit(state.node);
  return { version: LLB_DEFINITION_VERSION, ops, root };
}

export async function fromDefinition(definition: BuildDefinition, opts: DefinitionOptions = {}): Promise<BuildState> {
  if (definition.version !== LLB_DEFINITION_VERSION) {
    throw new Error(`unsupported llb Definition version ${definition.version}`);
  }
  if (!Number.isInteger(definition.root) || definition.root < 0 || definition.root >= definition.ops.length) {
    throw new Error(`llb Definition root index ${definition.root} is out of range`);
  }

  const states: BuildState[] = [];
  for (let i = 0; i < definition.ops.length; i++) {
    const op = definition.ops[i]!;
    assertNoUnusedBuildOpFields(op, i);
    let state: BuildState;
    switch (op.kind) {
      case OP_SOURCE:
        state = st({
          op: "source",
          ref: validateSourceRef(requireString(op.source_ref, "source_ref", i), `op ${i} source_ref`),
        });
        break;
      case OP_LAYER:
        state = st({ op: "layer", ref: requireString(op.source_ref, "source_ref", i) });
        break;
      case OP_LOCAL:
        state = st({
          op: "local",
          path: requireString(op.local_path, "local_path", i),
          dest: requireString(op.dest_path, "dest_path", i),
        });
        break;
      case OP_HTTP:
        state = st({
          op: "http",
          url: requireString(op.http_url, "http_url", i),
          dest: requireString(op.dest_path, "dest_path", i),
          ...(op.expected_digest ? { expectedDigest: op.expected_digest } : {}),
        });
        break;
      case OP_GIT:
        state = st({
          op: "git",
          repo: requireString(op.git_repo, "git_repo", i),
          ref: requireString(op.git_ref, "git_ref", i),
          dest: requireString(op.dest_path, "dest_path", i),
        });
        break;
      case OP_WRITE: {
        const data = await definitionStore(opts, "write payload rehydration").blob(
          requireString(op.data_digest, "data_digest", i),
        );
        state = st({
          op: "write",
          input: requireIndex(op.input, "input", i, states).node,
          path: requireString(op.path, "path", i),
          data,
        });
        break;
      }
      case OP_MKDIR:
        state = st({
          op: "mkdir",
          input: requireIndex(op.input, "input", i, states).node,
          path: requireString(op.path, "path", i),
        });
        break;
      case OP_RM:
        state = st({
          op: "rm",
          input: requireIndex(op.input, "input", i, states).node,
          path: requireString(op.path, "path", i),
        });
        break;
      case OP_CHMOD:
        state = st({
          op: "chmod",
          input: requireIndex(op.input, "input", i, states).node,
          path: requireString(op.path, "path", i),
          mode: requireMode(op.mode, "mode", i),
        });
        break;
      case OP_SYMLINK:
        state = st({
          op: "symlink",
          input: requireIndex(op.input, "input", i, states).node,
          target: requireString(op.target, "target", i),
          link: requireString(op.link, "link", i),
        });
        break;
      case OP_EXEC:
        state = st({
          op: "exec",
          input: requireIndex(op.input, "input", i, states).node,
          cmd: requireString(op.cmd, "cmd", i),
          opts: {
            ...(op.cwd ? { cwd: op.cwd } : {}),
            env: { ...op.env },
            ...(op.stdin !== undefined && op.stdin !== null ? { stdin: op.stdin.slice() } : {}),
            ...(op.tier ? { tier: op.tier as ImageConfig["tier"] } : {}),
            ...(op.budget_mib !== undefined && op.budget_mib !== null ? { budgetMib: op.budget_mib } : {}),
            ...(op.fuel !== undefined && op.fuel !== null ? { fuel: op.fuel } : {}),
            ...(op.deterministic !== undefined && op.deterministic !== null
              ? { deterministic: op.deterministic }
              : {}),
            ...(op.net !== undefined && op.net !== null ? { net: op.net } : {}),
            ...(op.mounts.length ? { mounts: op.mounts.map((m) => requireIndex(m.index, "mount", i, states)) } : {}),
          },
        });
        break;
      case OP_COPY:
        state = st({
          op: "copy",
          dest: requireIndex(op.dest, "dest", i, states).node,
          src: requireIndex(op.src, "src", i, states).node,
          paths: requireCopyPaths(op.copy_paths, i),
        });
        break;
      case OP_MERGE:
        state = st({
          op: "merge",
          a: requireIndex(op.a, "a", i, states).node,
          b: requireIndex(op.b, "b", i, states).node,
        });
        break;
      case OP_DIFF:
        state = st({
          op: "diff",
          lower: requireIndex(op.lower, "lower", i, states).node,
          upper: requireIndex(op.upper, "upper", i, states).node,
        });
        break;
      case OP_IMAGE:
        state = st({
          op: "image",
          parts: op.parts.map((p) => requireIndex(p.index, "part", i, states).node),
          config: imageConfig(op),
        });
        break;
      case OP_CACHE:
        state = st({ op: "cache", path: requireString(op.path, "path", i) });
        break;
      default:
        throw new Error(`llb Definition op ${i} has unknown kind ${op.kind}`);
    }
    states.push(state);
  }

  return states[definition.root]!;
}

export const llb = {
  /** A base image: a flavor name (`"posix"`), a `sha256:` digest, a built-image
   *  name, or `"base:latest"` — resolved by the solver. Use {@link llb.http}
   *  for HTTP(S) build inputs. */
  source(ref: string): BuildState {
    return st({ op: "source", ref: validateSourceRef(ref) });
  },
  /** A single known layer by `sha256:` digest. */
  layer(ref: string): BuildState {
    return st({ op: "layer", ref });
  },
  /** A host build context directory copied into `dest` as a source layer. */
  local(path: string, opts: LocalSourceOptions = {}): BuildState {
    return st({ op: "local", path, dest: opts.dest ?? "/" });
  },
  /** Fetch one HTTP(S) artifact as a source layer. The fetched bytes are written
   *  to `opts.dest`; `opts.sha256`, when supplied, is verified before materialization. */
  http(url: string, opts: HttpSourceOptions): BuildState {
    return st({ op: "http", url, dest: opts.dest, expectedDigest: opts.sha256 });
  },
  /** Archive a git ref as a source layer rooted at `opts.dest`. */
  git(repo: string, opts: GitSourceOptions): BuildState {
    return st({ op: "git", repo, ref: opts.ref, dest: opts.dest ?? "/" });
  },
  /** Add/modify a file (a `FileOp` — `vm.fs.write`). */
  write(input: BuildState, path: string, data: string | Uint8Array): BuildState {
    const bytes = typeof data === "string" ? enc(data) : data.slice();
    return st({ op: "write", input: input.node, path, data: bytes });
  },
  /** Create one directory. */
  mkdir(input: BuildState, path: string): BuildState {
    return st({ op: "mkdir", input: input.node, path });
  },
  /** Remove one file, symlink, or empty directory. */
  rm(input: BuildState, path: string): BuildState {
    return st({ op: "rm", input: input.node, path });
  },
  /** Set POSIX permission bits. */
  chmod(input: BuildState, path: string, mode: number): BuildState {
    return st({ op: "chmod", input: input.node, path, mode: validateMode(mode) });
  },
  /** Create a symbolic link at `link` pointing at `target`. */
  symlink(input: BuildState, target: string, link: string): BuildState {
    return st({ op: "symlink", input: input.node, target, link });
  },
  /** Run a command (an `ExecOp` — `vm.exec`). */
  exec(input: BuildState, cmd: string, opts: ExecOpts = {}): BuildState {
    return st({
      op: "exec",
      input: input.node,
      cmd,
      opts: {
        ...opts,
        stdin: opts.stdin instanceof Uint8Array ? opts.stdin.slice() : opts.stdin,
        mounts: opts.mounts ? [...opts.mounts] : undefined,
      },
    });
  },
  /** Copy paths from one resolved build graph into another. Each mapping places
   *  `from` from `src` at exact path `to` in `dest`. */
  copy(dest: BuildState, src: BuildState, paths: CopyPath[]): BuildState {
    if (paths.length === 0) throw new Error("llb.copy needs at least one path mapping");
    return st({
      op: "copy",
      dest: dest.node,
      src: src.node,
      paths: paths.map((path) => ({ from: path.from, to: path.to })),
    });
  },
  /** Stack two layer sets (a `MergeOp` — nested CoW). */
  merge(a: BuildState, b: BuildState): BuildState {
    return st({ op: "merge", a: a.node, b: b.node });
  },
  /** The layers `upper` adds over `lower` (a `DiffOp` — the CoW overlay IS the diff). */
  diff(lower: BuildState, upper: BuildState): BuildState {
    return st({ op: "diff", lower: lower.node, upper: upper.node });
  },
  /** Assemble an ordered image (layers + runtime `config`) from parts. */
  image(parts: BuildState[], config: ImageConfig = {}): BuildState {
    return st({ op: "image", parts: parts.map((p) => p.node), config: { ...config } });
  },
  /** A persistent cache mount for `exec` (`opts.mounts`), backed by the host. */
  cache(path: string): BuildState {
    return st({ op: "cache", path });
  },
  toDefinition,
  fromDefinition,
  encodeDefinition,
  decodeDefinition,
  /** Solve `state` and select an output. `asLayer()` → the portable `.tar` layer
   *  the node produced; `asSnapshot()` → the whole-VM memory image (A8,
   *  the warm-reuse cache value). */
  commit(state: BuildRef): {
    asLayer(opts?: SolveOptions): Promise<{ digest: string; tar: Uint8Array }>;
    asImage(opts?: SolveOptions): Promise<ImageManifest>;
    asSnapshot(opts?: SolveOptions): Promise<Uint8Array>;
  } {
    return {
      asLayer: async (opts) => commitLayer((await resolveBuildState(state, opts)).node, opts),
      asImage: async (opts) => {
        const resolved = await resolveBuildState(state, opts);
        const definition = isBuildDefinition(state) ? state : await toDefinition(resolved, opts);
        return commitImageWithBuildRecord(
          resolved.node,
          encodeDefinition(definition),
          definitionBlobRefs(definition),
          opts,
        );
      },
      asSnapshot: async (opts) => commitSnapshot((await resolveBuildState(state, opts)).node, opts),
    };
  },
};
