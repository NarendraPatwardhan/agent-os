import { useRef } from "react";
import * as stylex from "@stylexjs/stylex";
import type { McEditor } from "@mc/elements";
import { styles } from "../styles";
import { useVmSession } from "../useVmSession";
import { runProgram } from "../runProgram";
import { ExampleShell, TerminalPanel, PlayButton, Hint, useArtifacts } from "../panel";
import type { Example } from "../types";

/** Editable code. The play button reboots the VM and runs the whole (possibly edited)
 *  source against it — real exec output shows in the terminal, console.log in the panel.
 *  Declared `artifacts` the run left on disk become download chips under the terminal. */
export function ProgramDriver({ example }: { example: Extract<Example, { kind: "program" }> }) {
  const editorRef = useRef<McEditor>(null);
  const artifacts = useArtifacts(example.artifacts);

  const session = useVmSession({
    onReady: (vm, s) =>
      runProgram(
        editorRef.current?.source ?? example.code.source,
        vm,
        s,
        {},
        {
          image: example.image ?? "loom",
          seedStore: example.labStore,
        },
      )
        .catch((e) => s.print(e instanceof Error ? e.message : String(e)))
        .then(() => artifacts.collect(vm)),
  });

  const play = (): void => {
    session.clearLogs();
    artifacts.reset();
    session.bootBrowser(example.image ?? "loom", {
      deterministic: example.deterministic,
      net: example.net,
    });
  };

  return (
    <ExampleShell
      example={example}
      left={
        <div {...stylex.props(styles.codeWrap)}>
          <mc-editor
            ref={editorRef}
            {...stylex.props(styles.editor)}
            value={example.code.source}
            language="typescript"
          />
          <PlayButton place="abs" onClick={play} label="Reboot and run" />
        </div>
      }
      terminal={
        <TerminalPanel
          session={session}
          label="agent · live in your browser"
          hint={<Hint>press ▶ to run the program</Hint>}
          actions={artifacts.chips}
        />
      }
    />
  );
}
