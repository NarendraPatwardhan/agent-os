import { useRef, useState } from "react";
import * as stylex from "@stylexjs/stylex";
import type { McEditor, Vm } from "@mc/elements";
import { Icon } from "../../Icon";
import { styles } from "../styles";
import { useVmSession } from "../useVmSession";
import { runProgram } from "../runProgram";
import { ExampleShell, TerminalPanel, PlayButton, Hint } from "../panel";
import type { Example, IconId } from "../types";

type Artifact = { readonly path: string; readonly size: number };

const EXT_ICON: Record<string, IconId> = { xlsx: "xlsx", docx: "docx", pptx: "pptx", pdf: "pdf", db: "sqlite" };
const EXT_MIME: Record<string, string> = {
  xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  pdf: "application/pdf",
  db: "application/vnd.sqlite3",
};
const ext = (path: string): string => path.split(".").pop() ?? "";
const basename = (path: string): string => path.split("/").pop() ?? path;
const human = (n: number): string => (n < 1024 ? `${n} B` : `${(n / 1024).toFixed(1)} KB`);

/** Editable code. The play button reboots the VM and runs the whole (possibly edited)
 *  source against it — real exec output shows in the terminal, console.log in the panel.
 *  Declared `artifacts` the run left on disk become download chips under the terminal:
 *  clicking one reads the bytes out of the live VM (vm.fs.read) and saves the file. */
export function ProgramDriver({ example }: { example: Extract<Example, { kind: "program" }> }) {
  const editorRef = useRef<McEditor>(null);
  const vmRef = useRef<Vm | null>(null);
  const [artifacts, setArtifacts] = useState<readonly Artifact[]>([]);

  // Stat each declared path on the still-live VM; only the ones the (possibly
  // edited) program actually produced become chips.
  const collect = async (vm: Vm): Promise<void> => {
    const found: Artifact[] = [];
    for (const path of example.artifacts ?? []) {
      try {
        found.push({ path, size: (await vm.fs.stat(path)).size });
      } catch {
        // not produced this run — no chip
      }
    }
    setArtifacts(found);
  };

  const session = useVmSession({
    onReady: (vm, s) => {
      vmRef.current = vm;
      void runProgram(editorRef.current?.source ?? example.code.source, vm, s)
        .catch((e) => s.print(e instanceof Error ? e.message : String(e)))
        .then(() => collect(vm));
    },
  });

  const play = (): void => {
    session.clearLogs();
    setArtifacts([]);
    session.bootBrowser(example.image ?? "loom", { deterministic: example.deterministic });
  };

  const download = async (artifact: Artifact): Promise<void> => {
    const vm = vmRef.current;
    if (!vm) return;
    const bytes = await vm.fs.read(artifact.path);
    const blob = new Blob([bytes as BlobPart], { type: EXT_MIME[ext(artifact.path)] ?? "application/octet-stream" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = basename(artifact.path);
    link.click();
    URL.revokeObjectURL(url);
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
        <TerminalPanel
          session={session}
          label="agent · live in your browser"
          hint={<Hint>press ▶ to run the program</Hint>}
          actions={
            artifacts.length > 0
              ? artifacts.map((artifact) => (
                  <button
                    key={artifact.path}
                    type="button"
                    {...stylex.props(styles.artifactBtn)}
                    onClick={() => void download(artifact)}
                    title={`Download ${artifact.path}`}
                  >
                    <Icon id={EXT_ICON[ext(artifact.path)] ?? "file"} size={16} />
                    {basename(artifact.path)}
                    <span {...stylex.props(styles.artifactSize)}>{human(artifact.size)}</span>
                  </button>
                ))
              : undefined
          }
        />
      }
    />
  );
}
