type MarkdownSources = Record<string, string>;

const sources = import.meta.glob("../../../docs/*.md", {
  eager: true,
  import: "default",
  query: "?raw",
}) as MarkdownSources;

export type ReferencePage = Readonly<{
  slug: string;
  title: string;
  summary: string;
  group: string;
  source: string;
}>;

type PageDefinition = readonly [slug: string, title: string, summary: string];

const GROUPS: ReadonlyArray<Readonly<{ title: string; pages: ReadonlyArray<PageDefinition> }>> = [
  {
    title: "Start here",
    pages: [
      ["index", "Reference index", "How to use the reference and where each subject lives."],
      ["concepts", "Concepts", "The vocabulary behind VMs, images, snapshots, tools, and mounts."],
      [
        "installation",
        "Installation and imports",
        "Packages, release artifacts, imports, and a first VM.",
      ],
      ["runtimes", "Runtime matrix", "What local, browser, and remote execution each support."],
    ],
  },
  {
    title: "Core API",
    pages: [
      ["mc", "mc", "The top-level factory, restore, connection, and recording API."],
      [
        "create-options",
        "Create options",
        "Every mc.create and mc.restore option, field by field.",
      ],
      ["vm", "Vm", "The complete VM property and method index."],
      [
        "execution-files",
        "Execution and files",
        "Commands, autocomplete, Luau, services, and vm.fs.",
      ],
      ["shells-sessions", "Shells and sessions", "Streaming shells and framed agent sessions."],
      ["cron", "Cron", "Schedules, actions, lifecycle, and parser rules."],
    ],
  },
  {
    title: "Capabilities",
    pages: [
      ["tools", "Host tools", "Typed host functions exposed safely to guest programs."],
      [
        "connections",
        "Connections",
        "External APIs, credentials, discovery, and catalog compilation.",
      ],
      [
        "permissions",
        "Permissions and policy",
        "Network gates, allowlists, approvals, and denials.",
      ],
      [
        "mounts-drivers",
        "Mounts and drivers",
        "The driver contract plus hostDir, S3, and vector stores.",
      ],
      [
        "sidecars",
        "Sidecars",
        "Leased external resources, grants, lifecycle, fork behavior, and host connectors.",
      ],
      [
        "browser-sidecars",
        "Browser sidecars",
        "Typed Chromium sessions, pages, computer input, capture, and lifecycle.",
      ],
    ],
  },
  {
    title: "State and builds",
    pages: [
      [
        "snapshots",
        "Snapshots, restore, and fork",
        "Full and incremental state, portability, and branching.",
      ],
      [
        "images-stores",
        "Images and content stores",
        "Layers, manifests, storage backends, and ownership.",
      ],
      ["llb", "LLB", "Build graphs, solving, cache rules, and definition transport."],
      [
        "recording-remote-build",
        "Recording and remote builds",
        "Turn live work into build graphs and solve remotely.",
      ],
    ],
  },
  {
    title: "Browser and advanced",
    pages: [
      [
        "browser-elements",
        "Browser elements",
        "Custom elements, artifact loading, events, and styling.",
      ],
      ["advanced-api", "Advanced API", "Backends, sinks, loaders, and integration-level exports."],
      [
        "errors",
        "Errors and diagnostics",
        "Thrown errors, exit status, policy denials, and cleanup.",
      ],
      [
        "symbol-index",
        "Symbol index",
        "Alphabetical lookup across every JavaScript runtime export.",
      ],
    ],
  },
];

function sourceFor(slug: string): string {
  const suffix = `/docs/${slug}.md`;
  const entry = Object.entries(sources).find(([path]) => path.endsWith(suffix));
  if (!entry) throw new Error(`Reference source not bundled: ${slug}.md`);
  return entry[1];
}

export const referencePages: ReadonlyArray<ReferencePage> = GROUPS.flatMap((group) =>
  group.pages.map(([slug, title, summary]) => ({
    slug,
    title,
    summary,
    group: group.title,
    source: sourceFor(slug),
  })),
);

export const referenceGroups = GROUPS.map((group) => ({
  title: group.title,
  pages: referencePages.filter((page) => page.group === group.title),
}));

export function referencePage(slug: string): ReferencePage {
  return referencePages.find((page) => page.slug === slug) ?? referencePages[0];
}
