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

/** Boot options for the kinds that self-boot a browser VM (mirrors the terminal's
 *  boot props). `deterministic` pins the clock + seeds the RNG at boot. */
type Boot = {
  readonly image?: ImageName;
  readonly deterministic?: boolean;
  readonly net?: boolean;
};

/** A user input for the `connect` kind (a credential, an owner/repo, a spec URL).
 *  Values reach the program as `fields.‹key›` and fill "${key}" placeholders in the
 *  connection template. */
export type ConnectField = {
  readonly key: string;
  readonly label: string;
  readonly placeholder?: string;
  /** Prefilled value (editable). */
  readonly value?: string;
  /** Render as a password input — for tokens. */
  readonly secret?: boolean;
  /** May be left empty (e.g. a token for an API with anonymous reads — an empty
   *  bearer credential downgrades the connection to auth none). */
  readonly optional?: boolean;
};

/** A serializable connection declaration. Every "${key}" inside a string is
 *  replaced with the matching field value before mc.create — so credentials are
 *  typed by the user, never checked into this file. */
export type ConnectionTemplate = {
  readonly ref: string;
  readonly auth:
    | { readonly kind: "none" }
    | { readonly kind: "bearer"; readonly token: string }
    | { readonly kind: "header"; readonly name: string; readonly value: string }
    | { readonly kind: "query"; readonly name: string; readonly value: string };
  readonly tools?: readonly string[];
  readonly origins?: readonly string[];
  readonly spec?: {
    readonly url: string;
    readonly format: "openapi" | "microsoft-graph" | "google-discovery" | "graphql" | "mcp-remote";
    readonly sourceFormat?: "json" | "yaml";
  };
};

/** An example (a chapter subitem / pill). The `kind` selects its driver. */
export type Example =
  // Editable code; play reboots the VM and runs the whole source (real exec).
  // `artifacts` lists files the program leaves on disk — after a run, each one
  // that exists becomes a download chip under the terminal.
  | (Base &
      Boot & {
        readonly kind: "program";
        readonly code: Code;
        readonly artifacts?: readonly string[];
        /** Seed an in-memory image store so lifecycle/LLB examples can build real
         *  layers and manifests from the flavor this pill booted. */
        readonly labStore?: boolean;
      })
  // Read-only code / step list; play reboots and runs the declarative steps.
  | (Base &
      Boot & { readonly kind: "commands"; readonly steps: readonly Step[]; readonly code?: Code })
  // Editable code run on a VM booted WITH a declared connection; optional fields
  // collect user inputs (credentials, repos, spec URLs) that fill the template and
  // reach the program as `fields.‹key›`.
  | (Base &
      Boot & {
        readonly kind: "connect";
        readonly code: Code;
        readonly connection: ConnectionTemplate;
        readonly fields?: readonly ConnectField[];
        readonly artifacts?: readonly string[];
      })
  // The flavor picker — a span per image, each with a play button that boots it.
  | (Base & { readonly kind: "flavors" })
  // The remote create → connect → kill lifecycle form.
  | (Base & { readonly kind: "remote"; readonly defaultUrl?: string })
  // A browser-selected directory, mounted read-only through a real Driver.
  | (Base & Boot & { readonly kind: "files"; readonly code: Code; readonly mountPath: string })
  // A real anonymous/CORS-enabled S3 bucket mounted through the SDK's SigV4 driver.
  | (Base & Boot & { readonly kind: "s3"; readonly code: Code; readonly mountPath: string })
  // A connection call held at the host boundary until the visitor allows/rejects it.
  | (Base &
      Boot & {
        readonly kind: "approval";
        readonly code: Code;
        readonly connection: ConnectionTemplate;
      })
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
