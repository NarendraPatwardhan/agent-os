import * as stylex from "@stylexjs/stylex";
import { styles } from "../styles";
import { useVmSession } from "../useVmSession";
import { runSteps } from "../runSteps";
import { ExampleShell, TerminalPanel, PlayButton, Hint } from "../panel";
import type { Example } from "../types";

/** Non-editable demo: shows read-only code (or the step list) with a play button that
 *  reboots the VM and runs the declarative steps (no eval). */
export function CommandsDriver({ example }: { example: Extract<Example, { kind: "commands" }> }) {
  const session = useVmSession({
    onReady: (vm, s) =>
      void runSteps(example.steps, vm, s).catch((e) => s.print(e instanceof Error ? e.message : String(e))),
  });

  const play = (): void => {
    session.clearLogs();
    session.bootBrowser(example.image ?? "loom", { deterministic: example.deterministic });
  };

  return (
    <ExampleShell
      example={example}
      left={
        <div {...stylex.props(styles.codeWrap)}>
          {example.code ? (
            <pre {...stylex.props(styles.code)}>
              <code>{example.code.source}</code>
            </pre>
          ) : (
            <div {...stylex.props(styles.stepList)}>
              {example.steps.map((s, i) => (
                <span key={`${i}-${s.do}`} {...stylex.props(styles.step)}>
                  {s.do === "type" || s.do === "exec" ? (
                    <span {...stylex.props(styles.stepCmd)}>{s.cmd}</span>
                  ) : s.do === "write" ? (
                    `write ${s.path}`
                  ) : (
                    s.text
                  )}
                </span>
              ))}
            </div>
          )}
          <PlayButton place="abs" onClick={play} label="Reboot and run" />
        </div>
      }
      terminal={<TerminalPanel session={session} label="agent · live in your browser" hint={<Hint>press ▶ to run</Hint>} />}
    />
  );
}
