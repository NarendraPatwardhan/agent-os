// The scripted "type a few commands" hero demo. VM-agnostic: it just needs a byte
// sink — <mc-terminal>.send (which writes the shell's stdin), or any shell.write.

const encoder = new TextEncoder();

// Grounded in the loom image: the shell parses $(), pipes and redirection; awk/wc
// exist in /bin; /etc/profile's first line names the OS ("# AgentOS — …"). Keeps
// output to two short lines (the tool count, then the greeting).
const DEFAULT_SCRIPT: readonly string[] = [
  "os=$(awk 'NR==1 {print $2}' /etc/profile)",
  'echo "greetings from $os" > greetings.md',
  "cat greetings.md",
  "ls /bin | wc -l",
];

/** Where the demo's keystrokes go — one <mc-terminal>.send / shell.write per chunk. */
export type DemoWriter = (data: Uint8Array) => void;

export interface AutoDemoHandle {
  readonly done: Promise<void>;
  cancel(): void;
}

export function runAutoDemo(
  write: DemoWriter,
  script: readonly string[] = DEFAULT_SCRIPT,
): AutoDemoHandle {
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
