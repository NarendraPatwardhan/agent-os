import { useRef, useState } from "react";
import * as stylex from "@stylexjs/stylex";
import type { McEditor } from "@mc/elements";
import { styles } from "../styles";
import { useVmSession } from "../useVmSession";
import { runProgram } from "../runProgram";
import { ExampleShell, TerminalPanel, PlayButton, Hint } from "../panel";
import type { Example } from "../types";

export function S3Driver({ example }: { example: Extract<Example, { kind: "s3" }> }) {
  const editorRef = useRef<McEditor>(null);
  const [bucket, setBucket] = useState("noaa-cors-pds");
  const [region, setRegion] = useState("us-east-1");
  const [prefix, setPrefix] = useState("");
  const session = useVmSession({
    onReady: (vm, s) =>
      runProgram(
        editorRef.current?.source ?? example.code.source,
        vm,
        s,
        { bucket, region, prefix },
        { image: example.image ?? "posix" },
      ),
  });

  const play = (): void => {
    if (!bucket.trim()) {
      session.setLogs(["enter a public, browser-CORS-enabled S3 bucket first"]);
      return;
    }
    session.clearLogs();
    session.bootBrowser(example.image ?? "posix", { net: true, deterministic: example.deterministic });
  };

  return (
    <ExampleShell
      example={example}
      left={
        <>
          <div {...stylex.props(styles.form)}>
            <label {...stylex.props(styles.field)}>
              <span {...stylex.props(styles.fieldLabel)}>Public S3 bucket (CORS enabled)</span>
              <input {...stylex.props(styles.input)} value={bucket} onChange={(e) => setBucket(e.target.value)} placeholder="my-public-bucket" />
            </label>
            <label {...stylex.props(styles.field)}>
              <span {...stylex.props(styles.fieldLabel)}>Region</span>
              <input {...stylex.props(styles.input)} value={region} onChange={(e) => setRegion(e.target.value)} />
            </label>
            <label {...stylex.props(styles.field)}>
              <span {...stylex.props(styles.fieldLabel)}>Prefix (optional)</span>
              <input {...stylex.props(styles.input)} value={prefix} onChange={(e) => setPrefix(e.target.value)} placeholder="jobs/123" />
            </label>
          </div>
          <div {...stylex.props(styles.codeWrap)}>
            <mc-editor ref={editorRef} {...stylex.props(styles.editor)} value={example.code.source} language="typescript" />
            <PlayButton place="abs" onClick={play} label="Mount S3 and run" />
          </div>
        </>
      }
      terminal={<TerminalPanel session={session} label={`agent · s3://${bucket}`} hint={<Hint>configure a bucket, then press ▶</Hint>} />}
    />
  );
}
