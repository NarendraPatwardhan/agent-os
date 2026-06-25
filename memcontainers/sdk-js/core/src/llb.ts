// `llb` — the build grammar. A small set of composable values forming a
// content-addressed DAG of filesystem ops. Each verb returns an opaque
// `BuildState`; NOTHING runs until `llb.commit(state).asLayer()/.asSnapshot()`
// triggers the solver (`solve.ts`). The verbs map 1:1 onto the VM build primitives —
// `source` = a flavor/image, `write` = `vm.fs.write`, `exec` = `vm.exec`,
// `merge`/`image` = stacked layers, `diff` = the CoW overlay, `commit` = the
// `commit` primitive. "Primitives, not a frontend": no Dockerfile parser.

import type { ImageConfig, ImageManifest } from "./types.js";
import { commitImage, commitLayer, commitSnapshot, type SolveOptions } from "./solve.js";

/** A node in the build DAG (internal — consumers hold an opaque {@link BuildState}). */
export type BuildNode =
  | { readonly op: "source"; readonly ref: string }
  | { readonly op: "layer"; readonly ref: string }
  | { readonly op: "write"; readonly input: BuildNode; readonly path: string; readonly data: Uint8Array }
  | { readonly op: "exec"; readonly input: BuildNode; readonly cmd: string; readonly opts: ExecOpts }
  | { readonly op: "merge"; readonly a: BuildNode; readonly b: BuildNode }
  | { readonly op: "diff"; readonly lower: BuildNode; readonly upper: BuildNode }
  | { readonly op: "image"; readonly parts: readonly BuildNode[]; readonly config: ImageConfig }
  | { readonly op: "cache"; readonly path: string };

/** Options for an `llb.exec` node. */
export interface ExecOpts {
  /** Capability tier to boot the build VM at (default `full`, so the command can
   *  spawn tools). `isolated` confines reads to the cwd — most cache-sound, but it
   *  cannot spawn. */
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

/** An opaque handle to a build-DAG node. */
export interface BuildState {
  readonly node: BuildNode;
}

const enc = (s: string): Uint8Array => new TextEncoder().encode(s);
const st = (node: BuildNode): BuildState => ({ node });

export const llb = {
  /** A base image: a flavor name (`"posix"`), a `sha256:` digest, a built-image
   *  name, `"base:latest"`, or a `/net/…` URL — resolved by the solver. */
  source(ref: string): BuildState {
    return st({ op: "source", ref });
  },
  /** A single known layer by `sha256:` digest. */
  layer(ref: string): BuildState {
    return st({ op: "layer", ref });
  },
  /** Add/modify a file (a `FileOp` — `vm.fs.write`). */
  write(input: BuildState, path: string, data: string | Uint8Array): BuildState {
    const bytes = typeof data === "string" ? enc(data) : data.slice();
    return st({ op: "write", input: input.node, path, data: bytes });
  },
  /** Run a command (an `ExecOp` — `vm.exec`). */
  exec(input: BuildState, cmd: string, opts: ExecOpts = {}): BuildState {
    return st({
      op: "exec",
      input: input.node,
      cmd,
      opts: { ...opts, mounts: opts.mounts ? [...opts.mounts] : undefined },
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
  /** Solve `state` and select an output. `asLayer()` → the portable `.tar` layer
   *  the node produced; `asSnapshot()` → the whole-VM memory image (A8,
   *  the warm-reuse cache value). */
  commit(state: BuildState): {
    asLayer(opts?: SolveOptions): Promise<{ digest: string; tar: Uint8Array }>;
    asImage(opts?: SolveOptions): Promise<ImageManifest>;
    asSnapshot(opts?: SolveOptions): Promise<Uint8Array>;
  } {
    return {
      asLayer: (opts) => commitLayer(state.node, opts),
      asImage: (opts) => commitImage(state.node, opts),
      asSnapshot: (opts) => commitSnapshot(state.node, opts),
    };
  },
};
