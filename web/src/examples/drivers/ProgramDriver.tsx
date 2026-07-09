import { useRef } from "react";
import * as stylex from "@stylexjs/stylex";
import type { McEditor } from "@mc/elements";
import { styles } from "../styles";
import { useVmSession } from "../useVmSession";
import { runProgram } from "../runProgram";
import { ExampleShell, TerminalPanel, PlayButton, Hint } from "../panel";
import type { Example } from "../types";

/** Editable code. The play button reboots the VM and runs the whole (possibly edited)
 *  source against it — real exec output shows in the terminal, console.log in the panel. */
export function ProgramDriver({ example }: { example: Extract<Example, { kind: "program" }> }) {
  const editorRef = useRef<McEditor>(null);
  const session = useVmSession({
    onReady: (vm, s) =>
      void runProgram(editorRef.current?.source ?? example.code.source, vm, s).catch((e) =>
        s.print(e instanceof Error ? e.message : String(e)),
      ),
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
          <mc-editor ref={editorRef} {...stylex.props(styles.editor)} value={example.code.source} language="typescript" />
          <PlayButton place="abs" onClick={play} label="Reboot and run" />
        </div>
      }
      terminal={
        <TerminalPanel session={session} label="agent · live in your browser" hint={<Hint>press ▶ to run the program</Hint>} />
      }
    />
  );
}
