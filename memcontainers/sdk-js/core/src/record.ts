// Record, don't author. An agent already drives a VM through `vm.fs` mutations
// + `vm.exec` — that stream IS an `llb` trace in disguise. `mc.record` returns a
// VM whose mutating ops run LIVE (the agent sees real results) AND append onto a
// build DAG rooted at `llb.source(image)`. `build()` emits the canonical portable
// Definition, so a recorded session can move across runtimes and replay as a
// reproducible, incrementally-cacheable build (the DAG digest IS the image's
// identity) — no new frontend.

import { mc, Vm } from "./memcontainer.js";
import type { VmFs } from "./memcontainer.js";
import { llb, type BuildDefinition, type BuildState } from "./llb.js";
import type { CreateOptions, ExecOptions } from "./types.js";

export interface Recorder {
  /** The live VM. Its `fs` mutations + `exec` are recorded; reads are pure (ignored). */
  readonly vm: Vm;
  /** The portable Definition accumulated so far. */
  build(): Promise<BuildDefinition>;
}

/** Create a VM that records its `fs` mutations + `exec` calls as an `llb` DAG while
 *  running them live, then emits the canonical contract Definition. `opts.image`
 *  must be a replayable source ref (a flavor name, digest, or `base:latest`);
 *  host-only tools/mounts/custom kernels are rejected until the LLB grammar can
 *  represent them. */
export async function record(opts: CreateOptions = {}): Promise<Recorder> {
  const sourceRef = opts.image === undefined ? "base:latest" : opts.image;
  if (typeof sourceRef !== "string") {
    throw new Error(
      "mc.record: opts.image must be a string source ref (inline images/null are outside the LLB source grammar)",
    );
  }
  if (opts.tools?.length) {
    throw new Error("mc.record: host tools are outside the LLB source grammar");
  }
  if (opts.mounts?.length) {
    throw new Error("mc.record: host mounts are outside the LLB source grammar");
  }
  if (opts.kernel instanceof Uint8Array) {
    throw new Error("mc.record: custom kernels are outside the LLB source grammar");
  }
  if (opts.onPermission) {
    throw new Error("mc.record: permission prompts are outside the LLB source grammar");
  }

  const vm = await mc.create(opts);
  let tip: BuildState = llb.source(sourceRef);
  const networkPermission = opts.permissions?.network;
  const network =
    networkPermission === "deny"
      ? false
      : opts.net === true || networkPermission === "allow" || typeof networkPermission === "object";
  const execOpts = {
    deterministic: opts.deterministic ?? true,
    ...(network ? { net: true } : {}),
  };

  // Reads are pure (not recorded); only mutations + exec advance the DAG.
  const recordedFs: VmFs = {
    ...vm.fs,
    write: (path: string, data: string | Uint8Array) => {
      tip = llb.write(tip, path, data);
      return vm.fs.write(path, data);
    },
    mkdir: (path: string) => {
      tip = llb.mkdir(tip, path);
      return vm.fs.mkdir(path);
    },
    rm: (path: string) => {
      tip = llb.rm(tip, path);
      return vm.fs.rm(path);
    },
    chmod: (path: string, mode: number) => {
      tip = llb.chmod(tip, path, mode);
      return vm.fs.chmod(path, mode);
    },
    symlink: (target: string, link: string) => {
      tip = llb.symlink(tip, target, link);
      return vm.fs.symlink(target, link);
    },
  };

  // A Proxy intercepts `exec` + `fs`; every other member delegates to the real VM
  // (bound to it, so `this` is never the proxy).
  const recordedVm = new Proxy(vm, {
    get(target, prop, _receiver) {
      if (prop === "fs") return recordedFs;
      if (prop === "exec") {
        return (cmd: string, opts: ExecOptions = {}) => {
          tip = llb.exec(tip, cmd, { ...execOpts, ...opts });
          return target.exec(cmd, opts);
        };
      }
      const value = Reflect.get(target, prop, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });

  return {
    vm: recordedVm,
    build: () =>
      opts.store ? llb.toDefinition(tip, { store: opts.store }) : llb.toDefinition(tip),
  };
}
