import { useState } from "react";
import * as stylex from "@stylexjs/stylex";
import { text } from "instrument";
import { styles } from "../styles";
import { FLAVORS } from "../flavors";
import { useVmSession } from "../useVmSession";
import { ExampleShell, TerminalPanel, PlayButton, Hint } from "../panel";
import type { Example, ImageName } from "../types";

/** A span per shipped flavor (contents, size, use). Each play button boots that flavor
 *  per-instance — the terminal's `image` prop selects the tar, no global staging. */
export function FlavorsDriver({ example }: { example: Extract<Example, { kind: "flavors" }> }) {
  const [flavor, setFlavor] = useState<ImageName | null>(null);
  const session = useVmSession({
    onReady: (_vm, s) => s.setLogs([`Booted ${flavor}, check /bin for available programs`]),
  });

  const boot = (id: ImageName): void => {
    setFlavor(id);
    session.clearLogs();
    session.bootBrowser(id);
  };

  return (
    <ExampleShell
      example={example}
      left={
        <div {...stylex.props(styles.flavorList)}>
          {FLAVORS.map((fl) => (
            <div key={fl.id} {...stylex.props(styles.flavorSpan)}>
              <div {...stylex.props(styles.flavorHead)}>
                <span {...stylex.props(styles.flavorName, fl.id === flavor && styles.flavorNameOn)}>
                  {fl.id}
                </span>
                <span {...stylex.props(styles.flavorMeta)}>
                  {fl.size} · on {fl.stacks}
                </span>
                <PlayButton
                  place="right"
                  size={16}
                  onClick={() => boot(fl.id)}
                  label={`Boot ${fl.id}`}
                />
              </div>
              <p {...stylex.props(styles.flavorHas, text.body)}>{fl.has}</p>
              <p {...stylex.props(styles.flavorBest, text.body, text.subtle)}>{fl.bestFor}</p>
            </div>
          ))}
        </div>
      }
      terminal={
        <TerminalPanel
          session={session}
          label={`agent · ${flavor ?? ""}`}
          hint={<Hint>pick an image to boot it</Hint>}
        />
      }
    />
  );
}
