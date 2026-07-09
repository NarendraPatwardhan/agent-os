import type { Vm } from "@mc/elements";
import type { VmSession } from "./useVmSession";
import type { Step } from "./types";

/** Run a declarative step list against the booted VM — no eval. Each step maps to one
 *  real VM operation: `type` sends to the shell; `exec` runs a real `vm.exec` and paints
 *  it into the terminal; `write` stages a file host-side; `note` prints to the panel. */
export async function runSteps(steps: readonly Step[], vm: Vm, session: VmSession): Promise<void> {
  // Boot leaves a live `$ ` at the cursor; the first painted exec rides it, every
  // later one paints its own. A `type` hands the prompt back to the real shell.
  let promptAtCursor = true;
  for (const step of steps) {
    switch (step.do) {
      case "type": {
        // Wait for the prompt to come back before the next step — typed bytes queue
        // in the shell, but their echo would interleave with the running command's
        // output. Subscribe first so a fast command can't win the race.
        const back = session.promptReturn();
        session.send(`${step.cmd}\n`);
        await back;
        promptAtCursor = true;
        break;
      }
      case "exec": {
        const r = await vm.exec(step.cmd);
        if (step.echo !== false) {
          session.echoTerminal(`${promptAtCursor ? "" : "$ "}${step.cmd}\n`, r.stdout);
          promptAtCursor = false;
        }
        break;
      }
      case "write":
        await vm.fs.write(step.path, step.data);
        break;
      case "note":
        session.print(step.text);
        break;
    }
  }
}
