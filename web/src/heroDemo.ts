import type { Shell } from "@mc/core";

const encoder = new TextEncoder();

const DEFAULT_SCRIPT: readonly string[] = [
  "echo agent-os",
  "ls /bin",
  "cat /etc/profile",
];

export interface AutoDemoHandle {
  readonly done: Promise<void>;
  cancel(): void;
}

export function runAutoDemo(shell: Shell, script: readonly string[] = DEFAULT_SCRIPT): AutoDemoHandle {
  let cancelled = false;
  const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

  const done = (async () => {
    await sleep(700);
    for (const command of script) {
      if (cancelled) return;
      for (const character of command) {
        if (cancelled) return;
        shell.write(encoder.encode(character));
        await sleep(38);
      }
      if (cancelled) return;
      await sleep(220);
      shell.write(encoder.encode("\n"));
      await sleep(700);
    }
  })();

  return {
    done,
    cancel() {
      cancelled = true;
    },
  };
}
