// Record, don't author. An agent already drives a VM through `vm.fs.write`
// + `vm.exec` — that stream IS an `llb` trace in disguise. `mc.record` returns a
// VM whose mutating ops run LIVE (the agent sees real results) AND append onto a
// build DAG rooted at `llb.source(image)`. `build()` returns the tip `BuildState`,
// so a recorded session replays as a reproducible, incrementally-cacheable build
// (the DAG digest IS the image's identity) — no new API, no frontend.

import { mc, Vm } from "./memcontainer.js";
import type { VmFs } from "./memcontainer.js";
import { llb, type BuildState } from "./llb.js";
import type { CreateOptions } from "./types.js";

export interface Recorder {
  /** The live VM. Its `fs.write` + `exec` are recorded; reads are pure (ignored). */
  readonly vm: Vm;
  /** The build DAG accumulated so far (the tip node). */
  build(): BuildState;
}

/** Create a VM that records its `fs.write` + `exec` calls as an `llb` DAG while
 *  running them live. `opts.image` must be a replayable source ref (a flavor name,
 *  digest, or `base:latest`); host-only tools/mounts/custom kernels are rejected
 *  until the LLB grammar can represent them. */
export async function record(opts: CreateOptions = {}): Promise<Recorder> {
  const sourceRef = opts.image === undefined ? "base:latest" : opts.image;
  if (typeof sourceRef !== "string") {
    throw new Error("mc.record: opts.image must be a string source ref (inline images/null are not replayable yet)");
  }
  if (opts.tools?.length) {
    throw new Error("mc.record: host tools are not replayable in llb yet");
  }
  if (opts.mounts?.length) {
    throw new Error("mc.record: host mounts are not replayable in llb yet");
  }
  if (opts.kernel instanceof Uint8Array) {
    throw new Error("mc.record: custom kernels are not replayable in llb yet");
  }
  if (opts.runtime && opts.runtime !== "bun") {
    throw new Error("mc.record: only the embedded bun runtime is replayable in llb yet");
  }
  if (opts.onPermission) {
    throw new Error("mc.record: permission prompts are not replayable in llb yet");
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

  // Reads are pure (not recorded); only mutation + exec advance the DAG.
  const recordedFs: VmFs = {
    ...vm.fs,
    write: (path: string, data: string | Uint8Array) => {
      tip = llb.write(tip, path, data);
      return vm.fs.write(path, data);
    },
  };

  // A Proxy intercepts `exec` + `fs`; every other member delegates to the real VM
  // (bound to it, so `this` is never the proxy).
  const recordedVm = new Proxy(vm, {
    get(target, prop, _receiver) {
      if (prop === "fs") return recordedFs;
      if (prop === "exec") {
        return (cmd: string) => {
          tip = llb.exec(tip, cmd, execOpts);
          return target.exec(cmd);
        };
      }
      const value = Reflect.get(target, prop, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });

  return { vm: recordedVm, build: () => tip };
}
