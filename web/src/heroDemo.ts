// The scripted "type a few commands" hero demo. VM-agnostic: it just needs a byte
// sink — <mc-terminal>.send (which writes the shell's stdin), or any shell.write.

const encoder = new TextEncoder();

const DEFAULT_SCRIPT: readonly string[] = [
  "echo agent-os",
  "ls /bin",
  "cat /etc/profile",
];

/** Where the demo's keystrokes go — one <mc-terminal>.send / shell.write per chunk. */
export type DemoWriter = (data: Uint8Array) => void;

export interface AutoDemoHandle {
  readonly done: Promise<void>;
  cancel(): void;
}

export function runAutoDemo(write: DemoWriter, script: readonly string[] = DEFAULT_SCRIPT): AutoDemoHandle {
  let cancelled = false;
  const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

  const done = (async () => {
    await sleep(700);
    for (const command of script) {
      if (cancelled) return;
      for (const character of command) {
        if (cancelled) return;
        write(encoder.encode(character));
        await sleep(38);
      }
      if (cancelled) return;
      await sleep(220);
      write(encoder.encode("\n"));
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
