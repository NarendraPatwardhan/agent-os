import type { Backend } from "./backend.js";
import type { VmFs } from "./types.js";

const dec = (b: Uint8Array): string => new TextDecoder().decode(b);
const enc = (s: string): Uint8Array => new TextEncoder().encode(s);

export function makeFs(backend: Backend): VmFs {
  return {
    read: (path) => backend.read(path),
    readText: async (path) => dec(await backend.read(path)),
    write: (path, data) => backend.write(path, typeof data === "string" ? enc(data) : data),
    ls: (path) => backend.ls(path),
    stat: (path) => backend.stat(path),
    mkdir: (path) => backend.mkdir(path),
    rm: (path) => backend.rm(path),
    symlink: (target, link) => backend.symlink(target, link),
  };
}
