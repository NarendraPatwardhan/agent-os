import { useEffect, useRef, useState } from "react";
import * as stylex from "@stylexjs/stylex";
import { mc, resolveCreateOptions } from "@mc/elements";
import type { ConnectionDefinition, McEditor, PermissionRequest, Vm } from "@mc/elements";
import { ConfirmDialog, ConfirmFacts } from "../../ConfirmDialog";
import { styles } from "../styles";
import { useVmSession } from "../useVmSession";
import { runProgram } from "../runProgram";
import { ExampleShell, TerminalPanel, PlayButton, Hint } from "../panel";
import type { Example } from "../types";

type ToolRequest = Extract<PermissionRequest, { kind: "tool_approval" }>;

export function ApprovalDriver({ example }: { example: Extract<Example, { kind: "approval" }> }) {
  const editorRef = useRef<McEditor>(null);
  const vmRef = useRef<Vm | null>(null);
  const [pending, setPending] = useState<ToolRequest | null>(null);
  const session = useVmSession({
    onReady: (vm, s) =>
      runProgram(
        editorRef.current?.source ?? example.code.source,
        vm,
        s,
        {},
        { image: example.image ?? "loom" },
      ),
  });

  useEffect(() => () => void vmRef.current?.close().catch(() => {}), []);

  const play = (): void => {
    session.close();
    session.clearLogs();
    setPending(null);
    void (async () => {
      try {
        await vmRef.current?.close().catch(() => {});
        const base = await resolveCreateOptions({ image: example.image ?? "loom", net: true });
        const { tools, origins, ...connectionBase } = example.connection;
        const connection: ConnectionDefinition = {
          ...connectionBase,
          ...(tools ? { tools: [...tools] } : {}),
          ...(origins ? { origins: [...origins] } : {}),
        };
        const vm = await mc.create({
          ...base,
          connections: [connection],
          policies: [
            { owner: "org", pattern: `${example.connection.ref}.*`, action: "require_approval" },
          ],
          onPermission: (req) => {
            if (req.kind === "network") {
              req.allow({ remember: "session" });
              return;
            }
            session.print(
              `${req.method} ${req.url} is waiting at the host boundary · args ${req.argsDigest?.slice(0, 16) ?? "n/a"}…`,
            );
            setPending(req);
          },
        });
        vmRef.current = vm;
        session.attach(vm);
      } catch (e) {
        session.print(e instanceof Error ? e.message : String(e));
      }
    })();
  };

  const decide = (allow: boolean): void => {
    const req = pending;
    if (!req) return;
    setPending(null);
    if (allow) {
      session.print(`allowed ${req.method} once · args ${req.argsDigest?.slice(0, 12) ?? "n/a"}…`);
      req.allow({ remember: "once" });
    } else {
      session.print(`rejected ${req.method} before egress`);
      req.reject("rejected in the AgentOS by Example lab");
    }
  };

  return (
    <>
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
            <PlayButton place="abs" onClick={play} label="Boot governed VM and run" />
          </div>
        }
        terminal={
          <TerminalPanel
            session={session}
            label="agent · approval boundary"
            hint={<Hint>press ▶; the request will stop before egress</Hint>}
          />
        }
      />
      <ConfirmDialog
        open={pending != null}
        title={`Allow ${pending?.connection ?? example.connection.ref} request?`}
        description="AgentOS stopped this operation at the host boundary. Review the computed request facts before allowing any network egress."
        confirmLabel="Allow once"
        cancelLabel="Reject request"
        onConfirm={() => decide(true)}
        onCancel={() => decide(false)}
      >
        {pending ? (
          <ConfirmFacts
            facts={[
              { label: "Method", value: pending.method },
              { label: "Origin", value: pending.origin },
              { label: "URL", value: pending.url },
              { label: "Args", value: pending.argsDigest ?? "not supplied" },
            ]}
          />
        ) : null}
      </ConfirmDialog>
    </>
  );
}
