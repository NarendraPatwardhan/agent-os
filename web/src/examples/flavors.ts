import type { Flavor } from "./types";

// The shipped flavors, from //memcontainers/images (BUILD.bazel). Contents and the
// stacking are read off the image graph; sizes are the real flavor-tar sizes.
// base → { minimal | posix } → loom → { atlas | paper }.
export const FLAVORS: readonly Flavor[] = [
  {
    id: "minimal",
    size: "1.2 MB",
    stacks: "base",
    has: "A real shell plus the curated coreutils set — the builtin twins and core file ops (~15 applets), each routed to its least-privilege box.",
    bestFor: "A clean sandbox to build your own harnesses.",
  },
  {
    id: "posix",
    size: "2.3 MB",
    stacks: "base",
    has: "The full coreutils userland — every command, across four per-tier boxes with least-privilege /bin routing.",
    bestFor: "A known environment agents already understand — every standard Unix tool where they expect it.",
  },
  {
    id: "loom",
    size: "6.2 MB",
    stacks: "posix",
    has: "posix plus the Luau pair — /bin/luau (interpreter, with JSON/hash/time/string batteries) and luau-analyze — and the Office skill docs.",
    bestFor: "Programmability: compose steps in Luau and build Office documents. The default browser flavor.",
  },
  {
    id: "atlas",
    size: "7.3 MB",
    stacks: "loom",
    has: 'loom plus a warm SQLite service — /bin/sqlite and require("sqlite"). The first flavor with a resident domain service.',
    bestFor: "Data intelligence: query and analyze over an in-VM SQLite.",
  },
  {
    id: "paper",
    size: "36 MB",
    stacks: "loom",
    has: 'loom plus a warm Typst service — /bin/typst, require("typst") — and the baseline font faces under /usr/share/fonts.',
    bestFor: "Document automation: render Typst to PDF inside the VM.",
  },
];
