import { kit, tool, z } from "@mc/elements";
import type { Vm } from "@mc/elements";
import type { VmSession } from "./useVmSession";

/** Run an editable program against the terminal's freshly-booted VM. `mc.create()`
 *  returns a REAL facade over that VM — no fakes:
 *   • `exec(cmd)` runs the real `vm.exec` (real {stdout,stderr,exitCode}) and, unless
 *     `echo:false`, paints `$ cmd` + its stdout into the terminal display.
 *   • `luau(src, args?)` stages the source at /tmp/program.luau and execs `/bin/luau`
 *     on it — the same write-then-exec the SDK's vm.luau does, at a stable painted path.
 *   • `luauSession()` / `tool(def)` / `fs` delegate to the real VM.
 *   • `type(cmd)` sends to the interactive shell (looks typed, no structured result).
 *   • console.log/error land in the panel below the terminal.
 *  The eval scope also carries the SDK's `tool`/`kit`/`z`, so a program can define
 *  typed host tools and register them with `vm.tool`. Only the `program` kind uses
 *  this `new Function` eval — non-editable demos use the declarative `runSteps`
 *  instead, so the eval surface stays minimal. */
export async function runProgram(source: string, vm: Vm, session: VmSession): Promise<void> {
  // Boot leaves a live `$ ` at the cursor; the first painted exec rides it, every
  // later one paints its own. A `type` hands the prompt back to the real shell.
  let promptAtCursor = true;
  const exec = async (cmd: string, o?: { echo?: boolean }) => {
    const r = await vm.exec(cmd);
    if (o?.echo !== false) {
      session.echoTerminal(`${promptAtCursor ? "" : "$ "}${cmd}\n`, r.stdout);
      promptAtCursor = false;
    }
    return r;
  };
  const shQuote = (s: string): string => `'${s.replaceAll("'", "'\\''")}'`;
  const ctx = {
    exec,
    type: (cmd: string) => {
      session.send(`${cmd}\n`);
      promptAtCursor = true;
    },
    fs: vm.fs,
    luau: async (src: string, args: string[] = []) => {
      await vm.fs.write("/tmp/program.luau", src);
      return exec(["luau", "/tmp/program.luau", ...args.map(shQuote)].join(" "));
    },
    luauSession: () => vm.luauSession(),
    tool: (def: Parameters<Vm["tool"]>[0]) => vm.tool(def),
  };
  const mc = {
    create: async () => ctx,
    connect: () => {
      throw new Error("mc.connect isn't available in this in-browser demo");
    },
  };
  const con = {
    log: (...args: unknown[]) => session.print(args.map(String).join(" ")),
    error: (...args: unknown[]) => session.print(args.map(String).join(" ")),
  };
  const fn = new Function(
    "mc",
    "console",
    "tool",
    "kit",
    "z",
    `return (async () => {\n${source}\n})();`,
  ) as (m: typeof mc, c: typeof con, t: typeof tool, k: typeof kit, zz: typeof z) => Promise<void>;
  await fn(mc, con, tool, kit, z);
}
