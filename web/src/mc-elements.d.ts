// React JSX typing for the <mc-*> custom elements this app mounts. Framework-agnostic
// element packages don't (and shouldn't) ship React types, so the React binding lives
// here, in the consumer.
//
// Props are set by React as element properties when they exist on the instance
// (label, net, cursor, runtime, image) or as attributes otherwise (line-height,
// replay-history). Custom events (mc-ready, mc-data, mc-output, mc-boot, mc-error)
// are wired via ref + addEventListener, so they are not declared as props here.

import type { DetailedHTMLProps, HTMLAttributes } from "react";
import type { McTerminal, McEditor } from "@mc/elements";

type McTerminalProps = DetailedHTMLProps<HTMLAttributes<McTerminal>, McTerminal> & {
  label?: string;
  net?: boolean;
  cursor?: "bar" | "block" | "underline";
  runtime?: "browser" | "bun" | "remote";
  image?: string;
  manual?: boolean;
  deterministic?: boolean;
  working?: boolean;
  "line-height"?: number;
  "replay-history"?: boolean;
};

type McEditorProps = DetailedHTMLProps<HTMLAttributes<McEditor>, McEditor> & {
  value?: string;
  language?: "javascript" | "typescript" | "plain";
  "read-only"?: boolean;
  "line-wrapping"?: boolean;
};

declare module "react" {
  namespace JSX {
    interface IntrinsicElements {
      "mc-terminal": McTerminalProps;
      "mc-editor": McEditorProps;
    }
  }
}
