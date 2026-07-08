import type { Chapter, Example } from "./types";

const kebab = (s: string): string =>
  s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");

/** A placeholder example (unauthored section) — carries only the tab label. */
const p = (label: string): Example => ({ kind: "prose", id: kebab(label), label });

// Build a chapter from its examples; count is derived from them.
function ch(id: string, num: string, title: string, tagline: string, examples: readonly Example[]): Chapter {
  return { id, num, title, tagline, count: examples.length, examples };
}

// The book's ten chapters. Chapter 1 is authored; the rest carry the full TOC
// (prose placeholders) and get their walkthroughs next.
export const chapters: readonly Chapter[] = [
  ch("first-contact", "1", "First Contact", "Three runtimes host the exact same VM surface — learn it once; it moves with you.", [
    {
      kind: "program",
      id: "boot-a-vm",
      label: "Boot a VM",
      image: "loom",
      summary:
        "One command, one structured result — all in this tab. The machine boots from WebAssembly right here, so its processes and files live entirely on the page, with a real Unix shell on the right.",
      notes: [
        "exec returns { stdout, stderr, exitCode } — a real process exit status, not scraped text",
        "The VM owns real state: stage a file from the host, read it back in the shell",
        "A reboot wipes in-memory state; nothing ever leaves the tab",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.fs.write("/tmp/hello.txt", "hello-agent-os\\n");
console.log("staged /tmp/hello.txt from the host");
await vm.exec("cat /tmp/hello.txt");`,
      },
    },
    {
      kind: "remote",
      id: "remote",
      label: "Remote",
      summary:
        "The same surface over the wire. Point at a served AgentOS host and walk the full lifecycle: create a VM by id, connect to open its shell, then kill it — the page only ever holds a handle; credentials stay on the server.",
      notes: [
        "Create allocates the VM by id (mc.connect(url, key).vm(id)) — nothing boots yet",
        "Connect opens the shell on the right; the same id always returns the same VM",
        "Kill tears it down (vm.close() → DELETE); credentials never enter the page",
      ],
    },
    {
      kind: "flavors",
      id: "images",
      label: "Images",
      summary:
        "An image — a flavor — decides what's inside. They stack from a shared base, smallest to richest; pick the narrowest one that covers the job, then press play to boot it right here.",
      notes: [
        "The tools broker ships in every flavor, so tool discovery works everywhere",
        "A smaller image is a smaller attack surface",
      ],
    },
  ]),
  ch("agents-computer", "2", "The Agent's Computer", "Not a bag of remote function calls — a shell, a real filesystem, pipelines, and a workspace.", [
    p("Pipelines"), p("vm.fs"), p("vm.shell"), p("Determinism"),
  ]),
  ch("programming-in-luau", "3", "Programming in Luau", "Compose many steps — tool calls, data work, documents — in one program, without a model round-trip per step.", [
    p("vm.luau"), p("Sessions"), p("Analyze"), p("sys.*"), p("require(tools)"), p("vm.tool"), p("Kits"), p("Tool → doc"),
  ]),
  ch("producing-artifacts", "4", "Producing Artifacts", "Warm Office and data engines build real OOXML, PDF, and SQLite bytes inside the VM — no host-side Python.", [
    p("XLSX"), p("DOCX"), p("PPTX"), p("Typst PDF"), p("Diagnostics"), p("SQLite"), p("Vector search"), p("Data → PDF"), p("Batteries"), p("CLI twins"),
  ]),
  ch("connecting-tools", "5", "Connecting Tools & Integrations", "The embedder declares connections; the agent inside only ever sees an address and JSON — the credential never enters the guest.", [
    p("The model"), p("mc.use"), p("From the shell"), p("Envelope"), p("GitHub"), p("MS Graph"), p("Google"), p("GraphQL"), p("Remote MCP"), p("Any API"), p("Registry"), p("Capstone"),
  ]),
  ch("mounting-data", "6", "Mounting Data", "Host-backed storage as ordinary files: the agent reads a bucket, a repo, or a retrieval index with cat and ls.", [
    p("Host dir"), p("S3"), p("RAG mount"), p("Custom driver"), p("Mount vs conn"),
  ]),
  ch("snapshot-fork-layers", "7", "Snapshot, Fork & Layers", "The whole computer — processes, warm services, filesystem — is a value you can capture, branch, and stack.", [
    p("Snapshot"), p("Fork"), p("Layers"), p("Custom flavor"), p("Restore modes"),
  ]),
  ch("reproducible-builds", "8", "Reproducible Builds", "Driving a VM and building one are the same act — capture the steps and the machine becomes content-addressed.", [
    p("Record"), p("llb graph"), p("Caching"),
  ]),
  ch("governance-safety", "9", "Governance & Safety", "Secrets stay host-side, egress goes through the host, and every capability is a dial the embedder sets.", [
    p("Tiers"), p("Permissions"), p("Approval"), p("Secret-free"), p("Audit"),
  ]),
  ch("embedding-in-products", "10", "Embedding in Products", "The VM is a building block: per-event sandboxes, snapshot handoffs, keyed pools, cron — and this very page.", [
    p("Webhook"), p("Queue worker"), p("Handoff"), p("VM pool"), p("Cron"), p("Web components"),
  ]),
];
