import * as stylex from "@stylexjs/stylex";
import { text } from "instrument";
import { styles } from "../styles";
import { useVmSession } from "../useVmSession";
import { ExampleShell, TerminalPanel, Hint } from "../panel";
import type { Example } from "../types";

/** An unauthored section: summary (if any) + a placeholder, terminal idle. */
export function ProseDriver({ example }: { example: Extract<Example, { kind: "prose" }> }) {
  const session = useVmSession();
  return (
    <ExampleShell
      example={example}
      left={
        <p {...stylex.props(styles.placeholder, text.body, text.subtle)}>
          Full walkthrough coming — this section is in AgentOS by Example.
        </p>
      }
      terminal={<TerminalPanel session={session} label="agent" hint={<Hint>authored soon</Hint>} />}
    />
  );
}
