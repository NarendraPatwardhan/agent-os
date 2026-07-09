import type { Vm } from "@mc/elements";
import type { VmSession } from "./useVmSession";

/** Run an editable program against the terminal's freshly-booted VM. `mc.create()`
 *  returns a REAL facade over that VM — no fakes:
 *   • `exec(cmd)` runs the real `vm.exec` (real {stdout,stderr,exitCode}) and, unless
 *     `echo:false`, paints `$ cmd` + its stdout into the terminal display.
 *   • `type(cmd)` sends to the interactive shell (looks typed, no structured result).
 *   • `fs` / `luau` delegate to the real VM.
 *   • console.log/error land in the panel below the terminal.
 *  Only the `program` kind uses this `new Function` eval — non-editable demos use the
 *  declarative `runSteps` instead, so the eval surface stays minimal. */
export async function runProgram(source: string, vm: Vm, session: VmSession): Promise<void> {
  // Boot leaves a live `$ ` at the cursor; the first painted exec rides it, every
  // later one paints its own. A `type` hands the prompt back to the real shell.
  let promptAtCursor = true;
  const ctx = {
    exec: async (cmd: string, o?: { echo?: boolean }) => {
      const r = await vm.exec(cmd);
      if (o?.echo !== false) {
        session.echoTerminal(`${promptAtCursor ? "" : "$ "}${cmd}\n`, r.stdout);
        promptAtCursor = false;
      }
      return r;
    },
    type: (cmd: string) => {
      session.send(`${cmd}\n`);
      promptAtCursor = true;
    },
    fs: vm.fs,
    luau: (src: string, args: string[] = []) => vm.luau(src, args),
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
  const fn = new Function("mc", "console", `return (async () => {\n${source}\n})();`) as (
    m: typeof mc,
    c: typeof con,
  ) => Promise<void>;
  await fn(mc, con);
}
