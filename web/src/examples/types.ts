// "AgentOS by Example" data model. Each chapter holds a list of `Example`s — a
// discriminated union on `kind`; the driver registry (drivers/index.ts) maps each
// kind to the component that renders it. Adding an example kind = a union member + a
// driver. All behavior lives in the drivers; this file is pure data.

export type IconId =
  | "play"
  | "terminal"
  | "xlsx"
  | "docx"
  | "pptx"
  | "pdf"
  | "sqlite"
  | "tar"
  | "file"
  | "vector"
  | "github"
  | "microsoft"
  | "google"
  | "graphql"
  | "mcp"
  | "stripe"
  | "fork"
  | "snapshot"
  | "cron"
  | "globe"
  | "lock"
  | "key"
  | "mount"
  | "tools"
  | "luau"
  | "build";

export type CodeLanguage = "ts" | "lua" | "sh";
export type ImageName = "minimal" | "posix" | "loom" | "atlas" | "paper";

export type Code = {
  readonly language: CodeLanguage;
  readonly source: string;
};

/** A shipped image flavor (from //memcontainers/images). Each boots in the browser
 *  from its own tar staged at /mc/<id>.tar. */
export type Flavor = {
  readonly id: ImageName;
  /** Human size of the flavor tar. */
  readonly size: string;
  /** What it layers on (base | posix | loom). */
  readonly stacks: string;
  /** One line: what this flavor adds over what it stacks on. */
  readonly has: string;
  /** What it's best used for. */
  readonly bestFor: string;
};

/** A declarative step for the `commands` kind — one real VM operation, no eval.
 *  `type` sends to the shell; `exec` runs a real vm.exec (painted into the terminal
 *  unless echo:false); `write` stages a file; `note` prints to the panel. */
export type Step =
  | { readonly do: "type"; readonly cmd: string }
  | { readonly do: "exec"; readonly cmd: string; readonly echo?: boolean }
  | { readonly do: "write"; readonly path: string; readonly data: string }
  | { readonly do: "note"; readonly text: string };

type Base = {
  /** Short chip label on the tab — also the section heading. */
  readonly id: string;
  readonly label: string;
  /** One or two sentences: what this shows and why. */
  readonly summary?: string;
  /** Up to three short load-bearing facts. */
  readonly notes?: readonly string[];
};

/** An example (a chapter subitem / pill). The `kind` selects its driver. */
export type Example =
  // Editable code; play reboots the VM and runs the whole source (real exec).
  | (Base & { readonly kind: "program"; readonly code: Code; readonly image?: ImageName })
  // Read-only code / step list; play reboots and runs the declarative steps.
  | (Base & { readonly kind: "commands"; readonly steps: readonly Step[]; readonly code?: Code; readonly image?: ImageName })
  // The flavor picker — a span per image, each with a play button that boots it.
  | (Base & { readonly kind: "flavors" })
  // The remote create → connect → kill lifecycle form.
  | (Base & { readonly kind: "remote"; readonly defaultUrl?: string })
  // Placeholder / reading-only (an unauthored section).
  | (Base & { readonly kind: "prose" });

export type ExampleKind = Example["kind"];

export type Chapter = {
  /** URL-hash target — the chapter you jump to. */
  readonly id: string;
  /** Chapter number, "1".."10". */
  readonly num: string;
  readonly title: string;
  /** One sentence — the chapter's thesis. */
  readonly tagline: string;
  /** Example count (shown in the scale) — derived from `examples`. */
  readonly count: number;
  readonly examples: readonly Example[];
};
