import type { Chapter, Example } from "./types";

const kebab = (s: string): string =>
  s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");

/** A placeholder example (unauthored section) — carries only the tab label. */
const p = (label: string): Example => ({ kind: "prose", id: kebab(label), label });

// Build a chapter from its examples; count is derived from them.
function ch(id: string, num: string, title: string, tagline: string, examples: readonly Example[]): Chapter {
  return { id, num, title, tagline, count: examples.length, examples };
}

// The book's ten chapters. Chapters 1–3 are authored; the rest carry the full TOC
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
    {
      kind: "program",
      id: "pipelines",
      label: "Pipelines",
      image: "posix",
      summary:
        "The posix image carries the full coreutils set. Stage an event log from the host, then summarize it the Unix way — sort | uniq -c | sort -rn. No bespoke summarize API: the agent composes pipes like any Unix user.",
      notes: [
        "exec runs a real shell — pipes, ;, and exit codes all behave",
        "posix stacks coreutils onto minimal; pick it for file & text automation",
        "Edit the log lines or the pipeline and press ▶ again — it's your machine",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.fs.write("/workspace/events.log", "paid\\nfailed\\npaid\\nrefunded\\n");
console.log("staged /workspace/events.log from the host");
await vm.exec("sort /workspace/events.log | uniq -c | sort -rn");`,
      },
    },
    {
      kind: "program",
      id: "vm-fs",
      label: "vm.fs",
      image: "posix",
      summary:
        "vm.fs is the whole Unix verb set from the host, not just read/write. Build a small tree, stat it host-side, then check the same files at the shell — one filesystem, two views.",
      notes: [
        "Surface: read, readText, write, ls, stat, readlink, mkdir, rm, chmod, symlink",
        "stat reports the link itself for symlinks (isSymlink)",
        "The trusted operator view — host tools receive it as ctx.fs to stage inputs and harvest outputs",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.fs.mkdir("/work");
await vm.fs.write("/work/a.txt", "alpha");
await vm.fs.symlink("/work/a.txt", "/work/link");

for (const e of await vm.fs.ls("/work")) {
  const st = await vm.fs.stat("/work/" + e.name);
  console.log(e.name, st.isSymlink ? "→ symlink" : st.size + "b");
}

await vm.fs.chmod("/work/a.txt", 0o600);
await vm.fs.rm("/work/link");
await vm.exec("ls -la /work");`,
      },
    },
    {
      kind: "commands",
      id: "vm-shell",
      label: "vm.shell",
      image: "loom",
      summary:
        "The terminal on the right isn't a picture of the API — it is the API. vm.shell() returns a raw byte pipe: on streams bytes out, write sends keystrokes in. Press ▶ to send these keystrokes programmatically, then type into the same shell yourself.",
      notes: [
        "Shell is { on(cb), write(data), history() } — an xterm-style byte pipe, not line-buffered streams",
        '{ language: "luau" } opens the /bin/luau REPL instead of sh',
        "history() replays every byte emitted so far — how this terminal restores its scrollback",
      ],
      code: {
        language: "ts",
        source: `const shell = vm.shell({ language: "sh" });

shell.on((bytes) => term.write(bytes));  // bytes out — drawn by this terminal
shell.write("ls /skills\\n");             // keystrokes in — what ▶ sends
shell.write("luau -e 'print(1 + 2)'\\n");`,
      },
      steps: [
        { do: "type", cmd: "ls /skills" },
        { do: "type", cmd: "luau -e 'print(1 + 2)'" },
      ],
    },
    {
      kind: "program",
      id: "determinism",
      label: "Determinism",
      image: "posix",
      deterministic: true,
      summary:
        "▶ boots this VM with deterministic: true — the clock is pinned and entropy is seeded. The time never ticks, and every reboot replays the same run byte-for-byte: press ▶ twice and watch the \"random\" number come back identical. That's what makes a build step's output digest trustworthy.",
      notes: [
        "Wall-clock and entropy are capabilities the host dials, not ambient facts",
        "Determinism means the run replays — same boot, same steps, same bytes — not that entropy repeats within a run",
        "For full determinism — no ambient network or persistence — boot the isolated tier",
      ],
      code: {
        language: "ts",
        source: `// ▶ booted this machine with { deterministic: true }
const vm = await mc.create();

const t1 = await vm.exec("date +%s");
const t2 = await vm.exec("date +%s");
console.log(t1.stdout === t2.stdout
  ? "clock pinned at " + t1.stdout.trim() + " — it never ticks"
  : "clock ticked — this run was not deterministic");

const draw = await vm.exec("shuf -i 1-99999 -n 1");
console.log("seeded shuffle: " + draw.stdout.trim() +
  " — press \\u25b6 to replay the run and draw it again");`,
      },
    },
  ]),
  ch("programming-in-luau", "3", "Programming in Luau", "Compose many steps — tool calls, data work, documents — in one program, without a model round-trip per step.", [
    {
      kind: "program",
      id: "vm-luau",
      label: "vm.luau",
      image: "loom",
      summary:
        "vm.luau stages the source in a file and runs it under /bin/luau — multi-line programs and embedded quotes, no escaping. It returns the same structured ExecResult as exec, so a printed JSON line is data the host can parse.",
      notes: [
        "require resolves cache → embedded modules → VFS package.path; embedded batteries like json can't be shadowed",
        "Returns { stdout, stderr, exitCode } — print() is the program's data channel back to the host",
        "Luau ships on loom and up — it's the programmability layer",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

const result = await vm.luau(\`
  local json = require("json")
  local rows = { { name = "Ada", score = 99 }, { name = "Grace", score = 97 } }
  print(json.encode(rows))
\`);

console.log("exit " + result.exitCode + " — stdout is JSON the host can parse");`,
      },
    },
    {
      kind: "program",
      id: "sessions",
      label: "Sessions",
      image: "loom",
      summary:
        "vm.luauSession() keeps a resident interpreter. Each prompt(src) runs Luau and streams the framed events it emits via the log battery — the shape an embedding app tails to show live progress. vm.luau is the one-shot batch counterpart; a session is the streaming one.",
      notes: [
        "session.on(cb) fires per event as it arrives; prompt() resolves with the full event list",
        "log.event({ … }) emits the record verbatim (+ a timestamp); level helpers like log.info emit { level, msg, time }",
        "Warm means successive prompts skip interpreter startup",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

const session = vm.luauSession();
session.on((e) => console.log("event:", e.type ?? e.level, e.text ?? e.msg ?? ""));

const events = await session.prompt(\`
  local log = require("log")
  log.event({ type = "progress", pct = 50 })
  log.info("halfway")
  log.event({ type = "done" })
\`);
console.log(events.length + " framed events streamed to the host");`,
      },
    },
    {
      kind: "program",
      id: "analyze",
      label: "Analyze",
      image: "loom",
      summary:
        "loom ships luau-analyze, so untrusted or generated scripts can be type-checked before they run. The gate below only execs the script when the static pass comes back clean — break the types in the editor (say total: string) and ▶: analysis blocks execution.",
      notes: [
        "A nonzero luau-analyze exit means diagnostics — the script never runs",
        "In-VM, luau --check does the same at the shell",
        "Gating generated code on a static pass is cheap insurance before giving it a machine",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.fs.write("/tmp/task.luau", \`
  local total: number = 0
  for _, value in ipairs({ 1, 2, 3 }) do
    total += value
  end
  print(total)
\`);

const check = await vm.exec("luau-analyze /tmp/task.luau");
if (check.exitCode !== 0) throw new Error(check.stderr || check.stdout);
await vm.exec("luau /tmp/task.luau");`,
      },
    },
    {
      kind: "program",
      id: "sys",
      label: "sys.*",
      image: "loom",
      summary:
        "Inside Luau the kernel is reachable through the sys global — the primitive under every battery. Calls return Lua-style value, err pairs. Here a program reads a host-staged file with sys.fs, transforms it, and counts matches by spawning a real grep with sys.proc.",
      notes: [
        "Namespaces: sys.fs, sys.proc, sys.net (capability-gated), sys.host.call, sys.svc, sys.time, sys.rand",
        "sys.proc.run takes an argv table (or a sh -c string) and returns { out, code }",
        "A denied capability surfaces as an in-VM error (value, err) — not a crash",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.fs.write("/tmp/input.txt", "warn: disk full\\nerror: net down\\nok\\nerror: retry\\n");

await vm.luau(\`
  local bytes, err = sys.fs.read("/tmp/input.txt")
  assert(bytes, err)
  sys.fs.write("/tmp/output.txt", bytes:upper())

  local res = sys.proc.run({ "grep", "-c", "ERROR", "/tmp/output.txt" })
  print("ERROR lines: " .. res.out)
\`);

await vm.exec("cat /tmp/output.txt");`,
      },
    },
    {
      kind: "program",
      id: "require-tools",
      label: "require(tools)",
      image: "loom",
      summary:
        "require(\"tools\") is the in-VM client for the /svc/tools catalog broker. The program below registers a host tool from this page, then a Luau script discovers it by ranked search and calls it — no address hard-coded in any prompt.",
      notes: [
        "tools.search(q, opts) returns { items = { { address, description, … } } } — schemas are disclosed on demand",
        "Every call returns { ok = true, data = … } or { ok = false, err = { code, message } }",
        "The broker ships in every image, even minimal — discovery works everywhere",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.tool(tool({
  name: "customer lookup",
  description: "Find customer metadata by account id.",
  input: z.object({ accountId: z.string() }),
  run: ({ accountId }) => ({ name: "Acme Corp", health: "green", accountId }),
}));

await vm.luau(\`
  local tools = require("tools")

  local page = tools.search("customer", { limit = 5 })
  for _, hit in ipairs(page.items) do print("found: " .. hit.address) end

  local res = tools.call("host.org.main.customer.lookup", { accountId = "acme" })
  assert(res.ok, res.err and res.err.message)
  print(res.data.name .. " is " .. res.data.health)
\`);`,
      },
    },
    {
      kind: "program",
      id: "vm-tool",
      label: "vm.tool",
      image: "loom",
      summary:
        "Your own functions are first-class tools. tool() takes a zod schema — validated before the handler runs — and vm.tool registers it at host.org.main.‹name›. The closure runs host-side, in this very page; the guest only ever sees the address and JSON. The second call below sends a wrong-typed arg to prove the schema gate.",
      notes: [
        "The handler receives parsed args + a ctx whose ctx.fs is the VM filesystem — tools can take and leave files",
        "Bad args are rejected by the schema before your code runs",
        "Also register at boot with mc.create({ tools: [ … ] })",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.tool(tool({
  name: "temperature read",
  description: "Read a sensor by id.",
  input: z.object({ sensorId: z.string() }),
  run: ({ sensorId }) => ({ sensorId, celsius: 21.5 }), // runs host-side, in this page
}));

await vm.exec(\`tools call host.org.main.temperature.read '{"sensorId":"lab-1"}'\`);
await vm.exec(\`tools call host.org.main.temperature.read '{"sensorId":42}'\`); // schema rejects`,
      },
    },
    {
      kind: "program",
      id: "kits",
      label: "Kits",
      image: "loom",
      summary:
        "kit() bundles related tools under one name — each subtool registers as ‹kit› ‹cmd› and lands at host.org.main.‹kit›.‹cmd›, so related capabilities share a namespace and surface together in discovery.",
      notes: [
        "kit() returns a ToolDefinition[] — pass it straight to vm.tool or create({ tools })",
        "Each subtool is its own schema-validated tool; the kit provides the shared leading name",
        "tools search ‹kit› surfaces the whole family, ranked",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.tool(kit({
  name: "crm",
  tools: {
    lookup: tool({ description: "Look up an account", input: z.object({ id: z.string() }),
                   run: ({ id }) => ({ id, name: "Acme Corp", tier: "enterprise" }) }),
    notes:  tool({ description: "List account notes", input: z.object({ id: z.string() }),
                   run: () => ["renewal due in 30d", "asked about SSO"] }),
  },
}));

await vm.exec("tools search crm");
await vm.exec(\`tools call host.org.main.crm.lookup '{"id":"acme"}'\`);`,
      },
    },
    {
      kind: "program",
      id: "tool-doc",
      label: "Tool → doc",
      image: "loom",
      summary:
        "The capstone: one Luau program calls a host tool through the dotted proxy, then turns the result into a real .docx with the docx battery — no round-trip between the steps, no host-side Python. The closing ls shows the bytes on disk.",
      notes: [
        "tools.host.org.main.‹name› is sugar for tools.call with the same address",
        "docx blocks are module functions — docx.heading(level, text) — assembled via docx.new({ children })",
        "The whole flow is one program: tool call → document → saved artifact",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.tool(tool({
  name: "customer lookup",
  description: "Find customer metadata by account id.",
  input: z.object({ accountId: z.string() }),
  run: () => ({ name: "Acme Corp", health: "green" }),
}));

await vm.luau(\`
  local tools = require("tools")
  local docx  = require("docx")

  local customer = tools.host.org.main.customer.lookup({ accountId = "acme" })
  assert(customer.ok, customer.err and customer.err.message)

  local doc = docx.new({ children = {
    docx.heading(1, "Account Brief: " .. customer.data.name),
    docx.paragraph("Health: " .. customer.data.health),
  } })
  assert(doc:save("/tmp/account-brief.docx"))
  print("saved /tmp/account-brief.docx")
\`);

await vm.exec("ls -la /tmp/account-brief.docx");`,
      },
    },
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
