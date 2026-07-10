import { useEffect, useRef, useState } from "react";
import * as stylex from "@stylexjs/stylex";
import { mc, resolveCreateOptions } from "@mc/elements";
import type { ConnectionDefinition, McEditor, Vm } from "@mc/elements";
import { styles } from "../styles";
import { useVmSession } from "../useVmSession";
import { runProgram } from "../runProgram";
import { ExampleShell, TerminalPanel, PlayButton, Hint, useArtifacts } from "../panel";
import type { Example } from "../types";

/** Fill every "${key}" placeholder in the template's strings with field values. */
function fill(node: unknown, values: Record<string, string>): unknown {
  if (typeof node === "string") return node.replace(/\$\{(\w+)\}/g, (_, k: string) => values[k] ?? "");
  if (Array.isArray(node)) return node.map((v) => fill(v, values));
  if (node && typeof node === "object")
    return Object.fromEntries(Object.entries(node).map(([k, v]) => [k, fill(v, values)]));
  return node;
}

/** Editable code on a VM booted WITH a declared connection (§5). The optional form
 *  collects user inputs — a credential, an owner/repo, a spec URL — that fill the
 *  connection template and reach the program as `fields.‹key›`. ▶ closes any prior
 *  VM, boots a fresh one via mc.create({ connections }), attaches it to the manual
 *  terminal, and runs the source. The credential goes into the page-side host
 *  registry; the guest only ever sees the tool address and JSON. */
export function ConnectDriver({ example }: { example: Extract<Example, { kind: "connect" }> }) {
  const editorRef = useRef<McEditor>(null);
  const vmRef = useRef<Vm | null>(null);
  const busyRef = useRef(false);
  const artifacts = useArtifacts(example.artifacts);
  const [values, setValues] = useState<Record<string, string>>(() =>
    Object.fromEntries((example.fields ?? []).map((f) => [f.key, f.value ?? ""])),
  );

  const session = useVmSession({
    onReady: (vm, s) =>
      void runProgram(editorRef.current?.source ?? example.code.source, vm, s, values)
        .catch((e) => s.print(e instanceof Error ? e.message : String(e)))
        .then(() => artifacts.collect(vm)),
  });

  // This driver owns its VM (the terminal only attaches) — close it on pill switch.
  useEffect(
    () => () => {
      void vmRef.current?.close().catch(() => {});
    },
    [],
  );

  const play = (): void => {
    if (busyRef.current) return;
    const missing = (example.fields ?? []).filter((f) => !f.optional && !values[f.key]?.trim());
    if (missing.length > 0) {
      session.setLogs([`fill in ${missing.map((f) => f.label).join(", ")} first`]);
      return;
    }
    busyRef.current = true;
    session.close();
    session.clearLogs();
    artifacts.reset();
    void (async () => {
      try {
        await vmRef.current?.close().catch(() => {});
        vmRef.current = null;
        session.print(`declaring ${example.connection.ref} — fetching the spec + compiling the catalog…`);
        const base = await resolveCreateOptions({ image: example.image ?? "loom", net: true });
        const connection = fill(example.connection, values) as ConnectionDefinition;
        // An empty bearer credential means "go anonymous" (APIs with public reads).
        if (connection.auth.kind === "bearer" && !connection.auth.token.trim()) {
          connection.auth = { kind: "none" };
        }
        // ▶ is the embedder's explicit consent for THIS connection, so pre-approve its
        // egress — §9.3's default denies destructive methods (every MCP/GraphQL call is
        // a POST) when no policy and no onPermission handler exist. The governance
        // chapter demos the require_approval + onPermission flow instead.
        const vm = await mc.create({
          ...base,
          connections: [connection],
          policies: [{ owner: "org", pattern: `${example.connection.ref}.*`, action: "approve" }],
        });
        vmRef.current = vm;
        session.clearLogs();
        session.attach(vm);
      } catch (e) {
        session.print(`connection failed — ${e instanceof Error ? e.message : String(e)}`);
      } finally {
        busyRef.current = false;
      }
    })();
  };

  return (
    <ExampleShell
      example={example}
      left={
        <>
          {example.fields && example.fields.length > 0 ? (
            <div {...stylex.props(styles.form)}>
              {example.fields.map((f) => (
                <label key={f.key} {...stylex.props(styles.field)}>
                  <span {...stylex.props(styles.fieldLabel)}>{f.label}</span>
                  <input
                    {...stylex.props(styles.input)}
                    type={f.secret ? "password" : "text"}
                    value={values[f.key] ?? ""}
                    onChange={(e) => setValues((prev) => ({ ...prev, [f.key]: e.target.value }))}
                    placeholder={f.placeholder}
                    spellCheck={false}
                    autoComplete="off"
                  />
                </label>
              ))}
            </div>
          ) : null}
          <div {...stylex.props(styles.codeWrap)}>
            <mc-editor ref={editorRef} {...stylex.props(styles.editor)} value={example.code.source} language="typescript" />
            <PlayButton place="abs" onClick={play} label="Connect and run" />
          </div>
        </>
      }
      terminal={
        <TerminalPanel
          session={session}
          label={`agent · ${example.connection.ref}`}
          hint={<Hint>press ▶ to connect and run</Hint>}
          actions={artifacts.chips}
        />
      }
    />
  );
}
