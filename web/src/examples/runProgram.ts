import {
  defaultCatalogCompiler,
  kit,
  llb as coreLlb,
  loadCatalogCompiler,
  mc as coreMc,
  MemoryContentStore,
  resolveCreateOptions,
  s3,
  tool,
  vectorStore,
  z,
} from "@mc/elements";
import type { CreateOptions, Vm } from "@mc/elements";
import type { VmSession } from "./useVmSession";

type LabOptions = {
  readonly image?: string;
  readonly seedStore?: boolean;
};

type RecordState = { tip: ReturnType<typeof coreLlb.source> };

/** Run editable lab code against real browser VMs. The short `mc.create()` used by
 *  most pills resolves to the terminal's already-booted VM; lifecycle calls with
 *  options (`mc.create({...})`, restore, fork, mounts, commits, and LLB solves)
 *  delegate to the real SDK. This keeps the book-shaped snippets editable without
 *  booting a second invisible machine before every example. */
export async function runProgram(
  source: string,
  vm: Vm,
  session: VmSession,
  fields: Record<string, string> = {},
  lab: LabOptions = {},
): Promise<void> {
  const imageName = lab.image ?? "loom";
  const external = new Set<Vm>();
  let promptAtCursor = true;
  let activeRecord: RecordState | null = null;
  let assets: Awaited<ReturnType<typeof resolveCreateOptions>> | null = null;
  let store: MemoryContentStore | null = null;

  const ensureAssets = async () => {
    assets ??= await resolveCreateOptions({ image: imageName });
    return assets;
  };

  const ensureStore = async (): Promise<MemoryContentStore> => {
    if (store) return store;
    const resolved = await ensureAssets();
    if (!(resolved.image instanceof Uint8Array))
      throw new Error(`could not seed ${imageName} image bytes`);
    store = new MemoryContentStore();
    const digest = await store.put(resolved.image);
    await store.putManifest(imageName, {
      schema: 1,
      layers: [{ digest, size: resolved.image.length }],
      config: {},
    });
    return store;
  };

  if (lab.seedStore) await ensureStore();

  const shQuote = (s: string): string => `'${s.replaceAll("'", "'\\''")}'`;
  const paint = async (real: Vm, cmd: string, echo = true) => {
    const r = await real.exec(cmd);
    if (echo) {
      session.echoTerminal(`${promptAtCursor ? "" : "$ "}${cmd}\n`, r.stdout || r.stderr);
      promptAtCursor = false;
    }
    return r;
  };

  const facade = (real: Vm, recordable = false): any => {
    const record = (): RecordState | null => (recordable ? activeRecord : null);
    const fs = {
      read: (path: string) => real.fs.read(path),
      readText: (path: string) => real.fs.readText(path),
      ls: (path: string) => real.fs.ls(path),
      stat: (path: string) => real.fs.stat(path),
      readlink: (path: string) => real.fs.readlink(path),
      write: (path: string, data: string | Uint8Array) => {
        const r = record();
        if (r) r.tip = coreLlb.write(r.tip, path, data);
        return real.fs.write(path, data);
      },
      mkdir: (path: string) => {
        const r = record();
        if (r) r.tip = coreLlb.mkdir(r.tip, path);
        return real.fs.mkdir(path);
      },
      rm: (path: string) => {
        const r = record();
        if (r) r.tip = coreLlb.rm(r.tip, path);
        return real.fs.rm(path);
      },
      chmod: (path: string, mode: number) => {
        const r = record();
        if (r) r.tip = coreLlb.chmod(r.tip, path, mode);
        return real.fs.chmod(path, mode);
      },
      symlink: (target: string, link: string) => {
        const r = record();
        if (r) r.tip = coreLlb.symlink(r.tip, target, link);
        return real.fs.symlink(target, link);
      },
    };
    return {
      fs,
      exec: async (cmd: string, opts?: { echo?: boolean }) => {
        const r = record();
        if (r) r.tip = coreLlb.exec(r.tip, cmd, { deterministic: true, tier: "full" });
        return paint(real, cmd, opts?.echo !== false);
      },
      type: (cmd: string) => {
        real.shell().write(`${cmd}\n`);
        promptAtCursor = true;
      },
      luau: async (src: string, args: string[] = []) => {
        await fs.write("/tmp/program.luau", src);
        return paint(real, ["luau", "/tmp/program.luau", ...args.map(shQuote)].join(" "));
      },
      luauSession: () => real.luauSession(),
      session: (kind?: string) => real.session(kind),
      tool: (def: Parameters<Vm["tool"]>[0]) => real.tool(def),
      mount: (path: string, driver: Parameters<Vm["mount"]>[1], opts?: { readOnly?: boolean }) =>
        real.mount(path, driver, opts),
      unmount: (path: string) => real.unmount(path),
      snapshot: () => real.snapshot(),
      cron: (...args: Parameters<Vm["cron"]>) => real.cron(...args),
      fork: async () => {
        const next = await real.fork();
        external.add(next);
        return facade(next);
      },
      commit: () => real.commit(),
      status: () => real.status(),
      serviceCall: (name: string, req?: Uint8Array) => real.serviceCall(name, req),
      shell: (opts?: { language?: "sh" | "luau" }) => real.shell(opts),
      close: async () => {
        if (real === vm) return;
        external.delete(real);
        await real.close();
      },
    };
  };

  const current = facade(vm, true);

  const createExternal = async (opts: CreateOptions = {}): Promise<any> => {
    const resolved = await ensureAssets();
    let image = opts.image;
    let selectedStore = opts.store ?? store ?? undefined;
    if (image === undefined) image = resolved.image;
    if (typeof image === "string" && !selectedStore) {
      const other = await resolveCreateOptions({ image });
      image = other.image;
    }
    const real = await coreMc.create({
      ...opts,
      runtime: "browser",
      kernel: resolved.kernel,
      image,
      ...(selectedStore ? { store: selectedStore } : {}),
      ...(resolved.catalogCompiler ? { catalogCompiler: resolved.catalogCompiler } : {}),
    });
    external.add(real);
    return facade(real);
  };

  const restoreExternal = async (snapshot: Uint8Array, opts: CreateOptions = {}): Promise<any> => {
    const resolved = await ensureAssets();
    let image = opts.image;
    const selectedStore = opts.store ?? store ?? undefined;
    if (image === undefined) image = resolved.image;
    const real = await coreMc.restore(snapshot, {
      ...opts,
      runtime: "browser",
      kernel: resolved.kernel,
      image,
      ...(selectedStore ? { store: selectedStore } : {}),
      ...(resolved.catalogCompiler ? { catalogCompiler: resolved.catalogCompiler } : {}),
    });
    external.add(real);
    return facade(real);
  };

  const solveOptions = async () => {
    const resolved = await ensureAssets();
    return { store: await ensureStore(), kernel: resolved.kernel as Uint8Array };
  };
  const labLlb = {
    ...coreLlb,
    commit(input: Parameters<typeof coreLlb.commit>[0]) {
      const pending = coreLlb.commit(input);
      return {
        asLayer: async () => pending.asLayer(await solveOptions()),
        asImage: async () => pending.asImage(await solveOptions()),
        asSnapshot: async () => pending.asSnapshot(await solveOptions()),
      };
    },
  };

  const mc = {
    create: async (opts?: CreateOptions) =>
      !opts || Object.keys(opts).length === 0 ? current : createExternal(opts),
    restore: restoreExternal,
    record: async (opts: CreateOptions = {}) => {
      const sourceRef = typeof opts.image === "string" ? opts.image : imageName;
      activeRecord = { tip: coreLlb.source(sourceRef) };
      return {
        vm: current,
        build: async () => coreLlb.toDefinition(activeRecord!.tip, { store: await ensureStore() }),
      };
    },
    registry: async () => {
      const pending = loadCatalogCompiler();
      if (!pending) throw new Error("catalog-compiler.wasm isn't registered on this page");
      const cc = await defaultCatalogCompiler(await pending);
      return cc.registryList();
    },
  };
  const con = {
    log: (...args: unknown[]) => session.print(args.map(String).join(" ")),
    error: (...args: unknown[]) => session.print(args.map(String).join(" ")),
  };
  const defaultStore = (): MemoryContentStore => {
    if (!store) throw new Error("this example did not request a seeded browser content store");
    return store;
  };

  const fn = new Function(
    "mc",
    "console",
    "tool",
    "kit",
    "z",
    "fields",
    "llb",
    "defaultStore",
    "s3",
    "vectorStore",
    `return (async () => {\n${source}\n})();`,
  ) as (...args: any[]) => Promise<void>;

  try {
    await fn(mc, con, tool, kit, z, fields, labLlb, defaultStore, s3, vectorStore);
  } finally {
    activeRecord = null;
    await Promise.all([...external].map((v) => v.close().catch(() => {})));
  }
}
