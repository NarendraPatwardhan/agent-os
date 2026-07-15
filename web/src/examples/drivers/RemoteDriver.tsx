import * as stylex from "@stylexjs/stylex";
import { styles } from "../styles";
import { useVmSession } from "../useVmSession";
import { useRemoteLifecycle } from "../useRemoteLifecycle";
import { ExampleShell, TerminalPanel, PlayIcon, Hint } from "../panel";
import type { Example } from "../types";

/** The remote create → connect → kill lifecycle. The base-URL field (with a shown
 *  "/v1" suffix), a password key, and a VM id; connect attaches to the terminal. */
export function RemoteDriver({ example }: { example: Extract<Example, { kind: "remote" }> }) {
  const session = useVmSession();
  const r = useRemoteLifecycle(session, example.defaultUrl);
  const pageOrigin = typeof window === "undefined" ? "" : window.location.origin;

  return (
    <ExampleShell
      example={example}
      left={
        <div {...stylex.props(styles.form)}>
          <label {...stylex.props(styles.field)}>
            <span {...stylex.props(styles.fieldLabel)}>AgentOS base URL</span>
            <span {...stylex.props(styles.urlGroup)}>
              <input
                {...stylex.props(styles.inputBare)}
                value={r.url}
                onChange={(e) => r.setUrl(e.target.value)}
                disabled={r.locked}
                spellCheck={false}
                placeholder={pageOrigin}
              />
              <span {...stylex.props(styles.urlSuffix)}>/v1</span>
            </span>
          </label>
          <label {...stylex.props(styles.field)}>
            <span {...stylex.props(styles.fieldLabel)}>API key</span>
            <input
              {...stylex.props(styles.input)}
              type="password"
              value={r.apiKey}
              onChange={(e) => r.setApiKey(e.target.value)}
              disabled={r.locked}
              placeholder="sk-…"
              autoComplete="off"
            />
          </label>
          <label {...stylex.props(styles.field)}>
            <span {...stylex.props(styles.fieldLabel)}>VM identifier</span>
            <span {...stylex.props(styles.fieldRow)}>
              <input
                {...stylex.props(styles.input)}
                value={r.vmId}
                onChange={(e) => r.setVmId(e.target.value)}
                disabled={r.locked}
                spellCheck={false}
              />
              <button
                type="button"
                {...stylex.props(styles.regenBtn)}
                onClick={r.regenId}
                disabled={r.locked}
                aria-label="Regenerate id"
                title="Regenerate"
              >
                ⟳
              </button>
            </span>
          </label>
          <button
            type="button"
            {...stylex.props(styles.primaryBtn)}
            onClick={r.create}
            disabled={r.busy || r.locked || !r.url}
          >
            {r.vm ? "VM created" : "Create VM"}
          </button>
        </div>
      }
      terminal={
        <TerminalPanel
          session={session}
          label={`remote · ${r.vmId}`}
          hint={<Hint>create a VM, then connect</Hint>}
          actions={
            <>
              <button
                type="button"
                {...stylex.props(styles.connectBtn)}
                onClick={r.connect}
                disabled={!r.vm || r.connected}
              >
                <PlayIcon size={16} />
                Connect
              </button>
              <button
                type="button"
                {...stylex.props(styles.killBtn)}
                onClick={r.kill}
                disabled={!r.vm}
              >
                Kill VM
              </button>
            </>
          }
        />
      }
    />
  );
}
