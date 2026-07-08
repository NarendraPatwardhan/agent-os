import type { Vm } from "@mc/elements";
import type { VmSession } from "./useVmSession";
import type { Step } from "./types";

/** Run a declarative step list against the booted VM — no eval. Each step maps to one
 *  real VM operation: `type` sends to the shell; `exec` runs a real `vm.exec` and paints
 *  it into the terminal; `write` stages a file host-side; `note` prints to the panel. */
export async function runSteps(steps: readonly Step[], vm: Vm, session: VmSession): Promise<void> {
  for (const step of steps) {
    switch (step.do) {
      case "type":
        session.send(`${step.cmd}\n`);
        break;
      case "exec": {
        const r = await vm.exec(step.cmd);
        // Paint after the shell's `$ ` prompt (no extra prompt of our own).
        if (step.echo !== false) session.echoTerminal(`${step.cmd}\n`, r.stdout);
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
