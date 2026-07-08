import type { Chapter } from "./types";

// The book's ten chapters (AgentOS by Example). TOC only — the scale nav reads
// num/title/count; the id is the URL-hash jump target.
export const chapters: readonly Chapter[] = [
  { id: "first-contact", num: "1", title: "First Contact", count: 4, tagline: "Three runtimes host the exact same VM surface — learn it once; it moves with you." },
  { id: "agents-computer", num: "2", title: "The Agent's Computer", count: 4, tagline: "Not a bag of remote function calls — a shell, a real filesystem, pipelines, and a workspace." },
  { id: "programming-in-luau", num: "3", title: "Programming in Luau", count: 8, tagline: "Compose many steps — tool calls, data work, documents — in one program, without a model round-trip per step." },
  { id: "producing-artifacts", num: "4", title: "Producing Artifacts", count: 10, tagline: "Warm Office and data engines build real OOXML, PDF, and SQLite bytes inside the VM — no host-side Python." },
  { id: "connecting-tools", num: "5", title: "Connecting Tools & Integrations", count: 12, tagline: "The embedder declares connections; the agent inside only ever sees an address and JSON — the credential never enters the guest." },
  { id: "mounting-data", num: "6", title: "Mounting Data", count: 5, tagline: "Host-backed storage as ordinary files: the agent reads a bucket, a repo, or a retrieval index with cat and ls." },
  { id: "snapshot-fork-layers", num: "7", title: "Snapshot, Fork & Layers", count: 5, tagline: "The whole computer — processes, warm services, filesystem — is a value you can capture, branch, and stack." },
  { id: "reproducible-builds", num: "8", title: "Reproducible Builds", count: 3, tagline: "Driving a VM and building one are the same act — capture the steps and the machine becomes content-addressed." },
  { id: "governance-safety", num: "9", title: "Governance & Safety", count: 5, tagline: "Secrets stay host-side, egress goes through the host, and every capability is a dial the embedder sets." },
  { id: "embedding-in-products", num: "10", title: "Embedding in Products", count: 6, tagline: "The VM is a building block: per-event sandboxes, snapshot handoffs, keyed pools, cron — and this very page." },
];
