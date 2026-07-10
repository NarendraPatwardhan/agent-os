import type { Chapter, Example } from "./types";

const kebab = (s: string): string =>
  s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");

/** A placeholder example (unauthored section) — carries only the tab label. */
const p = (label: string): Example => ({ kind: "prose", id: kebab(label), label });

// Build a chapter from its examples; count is derived from them.
function ch(id: string, num: string, title: string, tagline: string, examples: readonly Example[]): Chapter {
  return { id, num, title, tagline, count: examples.length, examples };
}

// The book's ten chapters. Chapters 1–5 are authored; the rest carry the full TOC
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
      artifacts: ["/tmp/account-brief.docx"],
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
    {
      kind: "program",
      id: "xlsx",
      label: "XLSX",
      image: "loom",
      artifacts: ["/tmp/revenue.xlsx"],
      summary:
        "The xlsx battery assembles a real workbook inside the VM — headers, rows, and a live formula — then recalculates and validates before saving. The closing ls shows genuine OOXML bytes on disk.",
      notes: [
        "Set values with ws:setCell(ref, value); a formula is a value constructor — xlsx.formula(expr)",
        "wb:scanErrors() is the non-negotiable preflight — it catches #REF!/#DIV/0! before the file ships",
        "Read back with xlsx.open(path) / xlsx.load(bytes)",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.luau(\`
  local xlsx = require("xlsx")

  local wb = xlsx.new()
  local ws = wb:addWorksheet("Revenue")
  ws:setColumns({
    { header = "Customer", key = "customer", width = 20 },
    { header = "ARR",      key = "arr",      width = 14 },
  })
  ws:addRow({ customer = "Acme",   arr = 120000 })
  ws:addRow({ customer = "Globex", arr = 90000 })
  ws:setCell("B4", xlsx.formula("SUM(B2:B3)"))

  wb:recalculate()
  assert(#wb:scanErrors() == 0, "formula errors present")
  assert(wb:save("/tmp/revenue.xlsx"))

  local b4 = ws:cell("B4").value
  print(b4.formula .. " = " .. b4.result.value)
\`);

await vm.exec("ls -la /tmp/revenue.xlsx");`,
      },
    },
    {
      kind: "program",
      id: "docx",
      label: "DOCX",
      image: "loom",
      artifacts: ["/tmp/incident.docx"],
      summary:
        "Word documents are built declaratively: block constructors are docx.* module functions, assembled through docx.new({ children }) — headings, paragraphs, lists, and tables in one pass.",
      notes: [
        "docx.heading(level, text) — level first; docx.list(items, { ordered = ? }) or bullet/numbered",
        "Richer inlines: docx.run / hyperlink / image / chart",
        "The only Document: methods are setHeader/setFooter/acceptRevisions/rejectRevisions/toBytes/save",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.luau(\`
  local docx = require("docx")

  local doc = docx.new({ children = {
    docx.heading(1, "Incident Summary"),
    docx.paragraph("The checkout error rate exceeded threshold for 12 minutes."),
    docx.heading(2, "Actions"),
    docx.list({ "Rolled back the worker", "Purged bad queue messages", "Added an alert" }),
    docx.table({ rows = {
      { cells = { docx.cell("Metric"),   docx.cell("Value") } },
      { cells = { docx.cell("Downtime"), docx.cell("12 min") } },
    } }),
  } })

  assert(doc:save("/tmp/incident.docx"))
  print("saved /tmp/incident.docx")
\`);

await vm.exec("ls -la /tmp/incident.docx");`,
      },
    },
    {
      kind: "program",
      id: "pptx",
      label: "PPTX",
      image: "loom",
      artifacts: ["/tmp/ops.pptx"],
      summary:
        "Decks too: pptx.new picks the slide size, addSlide picks a layout, and each slide takes a title, a body (a string or a list of bullets), and speaker notes.",
      notes: [
        'Layouts: "title" | "titleAndContent" | "blank"; richer slides use addChart/addTable/addImage/addShape',
        "slide:setBody takes a string or a list of bullets; setNotes writes speaker notes",
        "Deck ops: duplicateSlide / moveSlide / removeSlide / save",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.luau(\`
  local pptx = require("pptx")

  local pres = pptx.new({ slideSize = "16:9" })

  local title = pres:addSlide({ layout = "title" })
  title:setTitle("Weekly Ops")
  title:setBody("Generated inside Agent OS")

  local s = pres:addSlide({ layout = "titleAndContent" })
  s:setTitle("Highlights")
  s:setBody({ "Deploys: 12", "Incidents: 1", "Open risks: 3" })
  s:setNotes("Call out the open risks before wrapping.")

  assert(pres:save("/tmp/ops.pptx"))
  print("2 slides saved")
\`);

await vm.exec("ls -la /tmp/ops.pptx");`,
      },
    },
    {
      kind: "program",
      id: "typst-pdf",
      label: "Typst PDF",
      image: "paper",
      artifacts: ["/tmp/review.pdf"],
      summary:
        "The paper image runs a warm Typst service. typst.compile(source) returns (pdfBytes, warnings) and raises on a compile error — it does not return an { ok } table. The closing head shows the real %PDF- magic on disk.",
      notes: [
        "compile / compile_file both return (pdf, warnings); opts.root sets the import/image root",
        "The warm service keeps ~30 MB of fonts hot across calls",
        "Output is PDF only; @preview packages need network and aren't supported — vendor what you need",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.luau(\`
  local typst = require("typst")

  local pdf, warnings = typst.compile([[
    = Quarterly Review
    Revenue is up by *12%*.
  ]])
  print(#warnings .. " warnings")

  sys.fs.write("/tmp/review.pdf", pdf)
  print("wrote " .. #pdf .. " bytes")
\`);

await vm.exec("head -c 5 /tmp/review.pdf");`,
      },
    },
    {
      kind: "program",
      id: "diagnostics",
      label: "Diagnostics",
      image: "paper",
      artifacts: ["/tmp/out.pdf"],
      summary:
        "Because a bad compile raises, catch it with pcall and read the formatted diagnostic — severity: file:line:col: message. Fix the source in the editor (a real heading, no #unknown_fn) and ▶ writes the PDF instead.",
      notes: [
        "A failure surfaces as a raised error carrying the diagnostic — never a silently-empty result",
        "Warnings are non-fatal and come back as the second return value on success",
        "This is the loop an agent runs: compile, read the diagnostic, patch, retry",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.luau(\`
  local typst = require("typst")

  local ok, pdf_or_err = pcall(typst.compile, "= Broken #unknown_fn()")
  if not ok then
    print("compile failed:")
    print(pdf_or_err)
  else
    sys.fs.write("/tmp/out.pdf", pdf_or_err)
    print("wrote /tmp/out.pdf — " .. #pdf_or_err .. " bytes")
  end
\`);`,
      },
    },
    {
      kind: "program",
      id: "sqlite",
      label: "SQLite",
      image: "atlas",
      artifacts: ["/tmp/events.db"],
      summary:
        "The atlas image runs a warm SQLite service. sqlite.open returns (db, err); every value binds with positional ?; transaction(fn) commits on return and rolls back on error; rows() streams a cursor.",
      notes: [
        "db:query materializes; db:rows streams — pick by result size",
        "Durable DBs live under /var/persist (needs CAP_PERSIST); /tmp is per-boot",
        "/bin/sqlite is a shell twin of the same warm service",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.luau(\`
  local sqlite = require("sqlite")
  local db, err = sqlite.open("/tmp/events.db")
  assert(db, err)

  db:exec("CREATE TABLE events (kind TEXT, cents INTEGER)")
  db:transaction(function(tx)
    local stmt = tx:prepare("INSERT INTO events VALUES (?, ?)")
    stmt:run("paid", 1200); stmt:run("refund", -200)
    stmt:close()
  end)

  for row in db:rows("SELECT kind, cents FROM events ORDER BY cents DESC") do
    print(row.kind, row.cents)
  end
  db:close()
\`);`,
      },
    },
    {
      kind: "program",
      id: "vector-search",
      label: "Vector search",
      image: "atlas",
      artifacts: ["/tmp/memory.db"],
      summary:
        "atlas includes a built-in vector engine — a bespoke ANN virtual table called vann (not sqlite-vec). Create an index, insert tagged vectors, and search with partition + metadata filters, all in SQL's house.",
      notes: [
        "spec.vector = { name, type, dims, metric } — the key is dims; the search limit is k",
        "Encode with sqlite.vec.f32/int8/bit; metrics: cosine / l2 / ip / hamming",
        "At the shell it's CREATE VIRTUAL TABLE … USING vann(…) + WHERE embedding MATCH vec_f32('[…]') AND k = 5",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.luau(\`
  local sqlite = require("sqlite")
  local db = assert(sqlite.open("/tmp/memory.db"))

  db:createVectorIndex("mem", {
    vector     = { name = "embedding", type = "float", dims = 3, metric = "cosine" },
    partitions = { "tenant" },
    metadata   = { { name = "source", type = "text" } },
    aux        = { "chunk" },
  })

  db:exec("INSERT INTO mem(rowid, embedding, tenant, source, chunk) VALUES (?, ?, ?, ?, ?)",
    1, sqlite.vec.f32({ 0.1, 0.2, 0.3 }), "acme", "docs", "refund policy")
  db:exec("INSERT INTO mem(rowid, embedding, tenant, source, chunk) VALUES (?, ?, ?, ?, ?)",
    2, sqlite.vec.f32({ 0.9, 0.1, 0.0 }), "acme", "docs", "pricing tiers")

  local hits = db:vectorSearch("mem", { 0.1, 0.2, 0.25 }, {
    type = "f32", k = 2,
    partition = { tenant = "acme" },
    filter    = { source = "docs" },
  })
  for _, hit in ipairs(hits) do print(hit.rowid, hit.distance, hit.chunk) end
\`);`,
      },
    },
    {
      kind: "program",
      id: "data-pdf",
      label: "Data → PDF",
      image: "paper",
      artifacts: ["/tmp/annual.pdf"],
      summary:
        "The engines compose across the boundary: the embedding app computes a year of revenue (compounding growth + seasonality), stages it as a CSV, and one Luau program parses and typesets it. paper ships Typst (not SQLite); the same shape pairs SQLite with Typst on a custom flavor (§7.4) or across a snapshot handoff (§10.3).",
      notes: [
        "Host JS is a first-class data source — compute there, stage with vm.fs.write, refine in-VM",
        "The expensive step — compile — runs once; assembling the source is cheap",
        "Editing tip: the Luau rides in a JS template literal, so \\n escapes are eaten by JS first — use string.char(10) or string.splitlines",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

// Compute a year of revenue on the host: 4% compounding growth + seasonality.
const months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
const rows = ["month,revenue"];
let base = 120000;
months.forEach((m, i) => {
  base *= 1.04;
  const seasonal = 1 + 0.15 * Math.sin(((i + 10) / 12) * 2 * Math.PI);
  rows.push(m + "," + Math.round(base * seasonal));
});
await vm.fs.write("/tmp/revenue.csv", rows.join("\\n") + "\\n");
console.log("host generated " + months.length + " months of revenue");

await vm.luau(\`
  local typst = require("typst")

  local rows = {}
  for i, line in ipairs(string.splitlines(assert(sys.fs.read("/tmp/revenue.csv")))) do
    if i > 1 and #line > 0 then
      local cols = string.split(line, ",")
      rows[#rows + 1] = string.format("[%s], [%s],", cols[1], cols[2])
    end
  end

  local nl = string.char(10)
  local src = "= Annual Revenue" .. nl .. "#table(columns: 2, " .. table.concat(rows, " ") .. ")"
  local pdf = typst.compile(src)
  sys.fs.write("/tmp/annual.pdf", pdf)
  print("typeset " .. #rows .. " rows into " .. #pdf .. " bytes of PDF")
\`);

await vm.exec("ls -la /tmp/annual.pdf");`,
      },
    },
    {
      kind: "program",
      id: "batteries",
      label: "Batteries",
      image: "loom",
      summary:
        "The four headline formats sit on a deep substrate — everything here is require()-able on any loom+ VM with zero staging. The natives run below: content hashing, base64, compression, and path handling, all inside the sandbox.",
      notes: [
        "Native (Zig): json, hash, encoding, deflate — plus the sys global under everything",
        "Office substrate: opc/zip/xml for exact template preservation; calc is the xlsx formula engine; units for twips/EMUs",
        "Agent utilities: http (needs CAP_NET), url, path, time, log, test, color",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.luau(\`
  local hash     = require("hash")
  local encoding = require("encoding")
  local deflate  = require("deflate")
  local path     = require("path")

  print(hash.sha256("agent-os"))
  print(encoding.base64.encode("bytes on the shelf"))

  local packed = deflate.compress(string.rep("agent ", 200))
  print(#packed .. " bytes compressed from 1200")

  print(path.join("/var", "persist", "notes.txt"))
\`);`,
      },
    },
    {
      kind: "program",
      id: "cli-twins",
      label: "CLI twins",
      image: "atlas",
      artifacts: ["/tmp/x.db"],
      summary:
        "Every warm engine has a /bin twin — the same service, reachable from a shell prompt or a pipeline. The CLI creates and sums a table, then require(\"sqlite\") reads the very same rows: shell and script paths agree, and both survive a snapshot.",
      notes: [
        "/bin/sqlite and require(\"sqlite\") are one warm service — one database, two doors",
        "On paper: typst compile in.typ out.pdf; anywhere on loom+: luau script.luau / luau --check",
        "Twins make engines pipeline-able: shell for plumbing, Luau for logic",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.exec(\`sqlite /tmp/x.db "CREATE TABLE t(n); INSERT INTO t VALUES (1),(2)"\`);
await vm.exec(\`sqlite /tmp/x.db "SELECT sum(n) FROM t"\`);

await vm.luau(\`
  local sqlite = require("sqlite")
  local db = assert(sqlite.open("/tmp/x.db"))
  for row in db:rows("SELECT n FROM t") do print("luau sees n = " .. row.n) end
\`);`,
      },
    },
  ]),
  ch("connecting-tools", "5", "Connecting Tools & Integrations", "The embedder declares connections; the agent inside only ever sees an address and JSON — the credential never enters the guest.", [
    {
      kind: "connect",
      id: "the-model",
      label: "The model",
      image: "loom",
      connection: { ref: "deepwiki.org.main", auth: { kind: "none" }, tools: ["deepwiki"] },
      summary:
        "The tool model is a clean split: this page (the embedder) declares the connection — spec, credential, egress policy — and the agent inside only ever sees a tool address and JSON args. ▶ boots a VM with DeepWiki connected; the catalog the guest reads holds refs, never tokens.",
      notes: [
        "Address grammar: ‹integration›.‹owner›.‹connection›.‹tool› — ‹owner›.‹connection› defaults to org.main",
        "‹owner›.‹connection› names the credential + origin allowlist the host resolves at egress",
        "The /tools mirror is exactly what the agent sees — safe to log, diff, or show a reviewer",
      ],
      code: {
        language: "ts",
        source: `// ▶ declared page-side: { ref: "deepwiki.org.main", auth: { kind: "none" } }
const vm = await mc.create();

await vm.exec("tools list");
await vm.exec("cat /tools/deepwiki/org/main/ask_question");`,
      },
    },
    {
      kind: "connect",
      id: "mc-use",
      label: "mc.use",
      image: "loom",
      connection: { ref: "github.org.main", auth: { kind: "bearer", token: "${token}" }, tools: ["github/issues"] },
      fields: [
        { key: "token", label: "GitHub token (optional — empty = anonymous, 60 req/h)", placeholder: "ghp_…", secret: true, optional: true },
      ],
      summary:
        "For a curated integration, mc.use is the one-liner: name the capability (dotted integration.group) and hand over a key — it derives the connection + tool selector, turns on host-gated network, and injects the catalog. ▶ runs the equivalent expanded connection for github.issues so every Chapter 5 example shares one visible connection lifecycle.",
      notes: [
        'The capability must be dotted ("github.issues"); a slash form is rejected',
        "The token goes to the host credential registry, not the guest; origins derive from the curated registry",
        "Anonymous works for public repos; a token raises rate limits and unlocks private repos",
      ],
      code: {
        language: "ts",
        source: `// In an app: mc.use("github.issues", fields.token, { image: "loom" })
// This lab expands that convenience call into the connection shown above.
const vm = await mc.create();

await vm.luau(\`
  local tools = require("tools")
  local issues = tools.call("github.org.main.issues-list-for-repo", {
    path = { owner = "NarendraPatwardhan", repo = "agent-os" },
    query = { per_page = 3, state = "all" },
  })
  assert(issues.ok, issues.err and issues.err.message)
  print(#issues.data .. " issues fetched")
  for _, issue in ipairs(issues.data) do print("#" .. issue.number .. "  " .. issue.title) end
\`);`,
      },
    },
    {
      kind: "connect",
      id: "from-the-shell",
      label: "From the shell",
      image: "loom",
      connection: { ref: "deepwiki.org.main", auth: { kind: "none" }, tools: ["deepwiki"] },
      summary:
        "The tools applet exposes the whole catalog to shell and pipelines: list, ranked search, describe, call. Every call prints the same JSON contract, so ordinary filters can select exactly what the next step needs — here jq turns discovery into addresses and unwraps the tool's text response.",
      notes: [
        "call requires the caller's CAP_NET; discovery (list/search/describe) does not",
        "Large or binary results land under /tmp/tools/results (or --output /path)",
        "The subject here is this very repo — DeepWiki answers from NarendraPatwardhan/agent-os",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.exec("tools search wiki --limit 3 | jq -r '.items[].address'");
await vm.exec(
  \`tools call deepwiki.org.main.ask_question \` +
  \`'{"repoName":"NarendraPatwardhan/agent-os","question":"What is an image flavor? Answer in one sentence."}' \` +
  \`| jq -r '.data.content[0].text'\`
);`,
      },
    },
    {
      kind: "connect",
      id: "envelope",
      label: "Envelope",
      image: "loom",
      connection: { ref: "github.org.main", auth: { kind: "none" }, tools: ["github/issues"] },
      summary:
        "Arguments follow the tool's source, and getting the envelope right is the difference between a call that works and one that 400s. REST splits parameters across the URL path, query string, and body — so OpenAPI/Graph/Discovery tools take { path, query, body }. GraphQL tools take flat variables; MCP tools take flat args.",
      notes: [
        'OpenAPI/Graph/Discovery: {"path":{…},"query":{…},"body":{…}} — mirror of the HTTP request',
        "GraphQL: the operation's variables, flat. MCP: the tool's args, flat",
        "tools describe ‹addr› shows the exact schema — this catalog compiled from GitHub's public spec, no credential",
      ],
      code: {
        language: "ts",
        source: `// GitHub's OpenAPI spec is public — the catalog compiles with auth none.
const vm = await mc.create();

await vm.exec("tools describe github.org.main.issues-create");`,
      },
    },
    {
      kind: "connect",
      id: "github",
      label: "GitHub",
      image: "loom",
      connection: { ref: "github.org.main", auth: { kind: "bearer", token: "${token}" }, tools: ["github/issues"] },
      fields: [
        { key: "token", label: "GitHub token (optional)", placeholder: "ghp_…", secret: true, optional: true },
        { key: "owner", label: "Repo owner", value: "NarendraPatwardhan" },
        { key: "repo", label: "Repo name", value: "agent-os" },
      ],
      summary:
        "The explicit form of the same connection — declare ref + auth + a tool selector when you want a pinned spec or a custom origin. Point the fields at any repo you can read; the structured envelope carries owner/repo in path and paging in query.",
      notes: [
        "The field values reach this program as fields.owner / fields.repo",
        "tools: [\"github/issues\"] narrows the compiled catalog to one group of the 1,000+ operation spec",
        "Writes (issues-create) follow the same shape with a body — they need a token with scope",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.exec(
  \`tools call github.org.main.issues-list-for-repo \` +
  \`'{"path":{"owner":"\${fields.owner}","repo":"\${fields.repo}"},"query":{"per_page":3}}'\`
);`,
      },
    },
    {
      kind: "connect",
      id: "ms-graph",
      label: "MS Graph",
      image: "loom",
      connection: { ref: "microsoft.org.work", auth: { kind: "bearer", token: "${token}" }, tools: ["microsoft/mail"] },
      fields: [{ key: "token", label: "Graph access token (aka.ms/ge → Access token tab)", placeholder: "eyJ…", secret: true }],
      summary:
        "Microsoft Graph is a first-class spec format; microsoft is the whole-Graph bundle and the mail group narrows it to mailbox tools. Graph has no anonymous tier — paste an access token from Graph Explorer. Fair warning: the upstream Graph spec is ~38 MB, so the first boot chews for a while.",
      notes: [
        "The connection here is work, so addresses read microsoft.org.work.‹tool›",
        "tools.describe shows the OData query params ($top, $filter, …)",
        "The token lives page-side only — the guest sees addresses and JSON",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.luau(\`
  local tools = require("tools")
  local messages = tools.call("microsoft.org.work.listMessages", {})
  assert(messages.ok, messages.err and messages.err.message)
  for _, m in ipairs(messages.data.value or {}) do print(m.subject) end
\`);`,
      },
    },
    {
      kind: "connect",
      id: "google",
      label: "Google",
      image: "loom",
      connection: { ref: "google-gmail.org.work", auth: { kind: "bearer", token: "${token}" }, tools: ["google-gmail"] },
      fields: [
        { key: "token", label: "Google OAuth token (developers.google.com/oauthplayground, Gmail scope)", placeholder: "ya29.…", secret: true },
      ],
      summary:
        "Google APIs compile from the google-discovery format — each API is its own integration id (google-gmail, google-sheets, …). Gmail has no anonymous tier — mint a token in the OAuth playground with a Gmail scope, then list your own inbox from inside the sandbox.",
      notes: [
        "The address prefix is the integration id: google-gmail.org.work.gmail-users-messages-list",
        "Discovery tools take the same { path, query, body } envelope as OpenAPI",
        "google is the bundle if you want all of Workspace behind one consent",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.luau(\`
  local tools = require("tools")
  local res = tools.call("google-gmail.org.work.gmail-users-messages-list", {
    path = { userId = "me" }, query = { maxResults = 5 },
  })
  assert(res.ok, res.err and res.err.message)
  print("messages in your inbox page: " .. #(res.data.messages or {}))
\`);`,
      },
    },
    {
      kind: "connect",
      id: "graphql",
      label: "GraphQL",
      image: "loom",
      connection: { ref: "anilist.org.main", auth: { kind: "none" }, tools: ["anilist"] },
      summary:
        "A graphql connection is discovered live — the endpoint is introspected at boot rather than compiled from a static file, and the tools appear as query.‹field› / mutation.‹field›. AniList is public and needs no key: search the schema, then call a query with flat variables.",
      notes: [
        "Introspection runs at create; a schema change upstream is picked up on the next boot",
        "Variables are flat — no { path, query, body } envelope here",
        "anilist ships in the curated registry, so origins are pre-vetted",
      ],
      code: {
        language: "ts",
        source: `// ▶ introspects https://graphql.anilist.co live and compiles query.* tools
const vm = await mc.create();

await vm.luau(\`
  local tools = require("tools")
  for _, hit in ipairs(tools.search("query Media", { limit = 3 }).items) do print(hit.address) end

  local res = tools.call("anilist.org.main.query.Media", { search = "Cowboy Bebop" })
  assert(res.ok, res.err and res.err.message)
  print(require("json").encode(res.data))
\`);`,
      },
    },
    {
      kind: "connect",
      id: "remote-mcp",
      label: "Remote MCP",
      image: "loom",
      connection: { ref: "deepwiki.org.main", auth: { kind: "none" }, tools: ["deepwiki"] },
      summary:
        "An mcp-remote connection speaks the MCP handshake at boot; its tools take flat args. auth none + curated origins makes a public tool — and DeepWiki has an entry for this very repository, so the machine can ask questions about its own source code.",
      notes: [
        "The MCP session (initialize → tools/list) happens at create, host-side",
        "ask_question is LLM-backed — give it ~20s to answer",
        "12 MCP servers ship in the curated registry; deepwiki and context7 are featured",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.luau(\`
  local tools = require("tools")
  local res = tools.call("deepwiki.org.main.ask_question", {
    repoName = "NarendraPatwardhan/agent-os",
    question = "What is an image flavor, and how do layers relate to snapshots?",
  })
  assert(res.ok, res.err and res.err.message)
  print(res.data.content[1].text)
\`);`,
      },
    },
    {
      kind: "connect",
      id: "any-api",
      label: "Any API",
      image: "loom",
      connection: {
        ref: "openmeteo.org.main",
        auth: { kind: "none" },
        origins: ["${origin}"],
        spec: { url: "${specUrl}", format: "openapi", sourceFormat: "yaml" },
      },
      fields: [
        {
          key: "specUrl",
          label: "OpenAPI spec URL",
          value: "https://raw.githubusercontent.com/open-meteo/open-meteo/main/openapi/forecast.yml",
        },
        { key: "origin", label: "Allowed origin", value: "https://api.open-meteo.com" },
      ],
      summary:
        "For an API that isn't in the registry, supply the spec yourself — a URL, bytes, or a pinned file. For a custom spec YOU set the origins: egress anywhere else fails closed. Prefilled with Open-Meteo's public forecast API; swap in your own spec + origin.",
      notes: [
        "Auth kinds: none / bearer / header / query — pick what the API expects",
        "Formats: openapi, microsoft-graph, google-discovery, graphql, mcp-remote",
        "Curated integrations derive origins from the vetted registry; custom specs must name theirs",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.exec("tools search forecast --limit 3 | jq -r '.items[].address'");
await vm.exec(
  \`tools call openmeteo.org.main.get.v1.forecast \` +
  \`'{"query":{"latitude":"52.52","longitude":"13.41","hourly":["temperature_2m"],"forecast_days":1}}' \` +
  \`| jq '{latitude:.data.latitude,longitude:.data.longitude,timezone:.data.timezone,\` +
  \`unit:.data.hourly_units.temperature_2m,time:.data.hourly.time[:6],\` +
  \`temperature_2m:.data.hourly.temperature_2m[:6]}'\`
);`,
      },
    },
    {
      kind: "program",
      id: "registry",
      label: "Registry",
      image: "loom",
      summary:
        "The curated registry the host compiles connections from is readable — enumerate it to build an integration picker. Each entry carries its id, spec kind, source, and the vetted egress origins credentials are pinned to.",
      notes: [
        "mc.registry() reads the same catalog-compiler.wasm this page boots VMs with",
        "Entry kinds: openapi, microsoft-graph, google-discovery, graphql, mcp-remote",
        "servers is the curated origin allowlist — why a tampered upstream spec can't redirect your credential",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

const entries = await mc.registry();
console.log(entries.length + " integrations in the curated registry");

const byKind = {};
for (const e of entries) byKind[e.kind] = (byKind[e.kind] ?? 0) + 1;
for (const [kind, n] of Object.entries(byKind)) console.log(kind + ": " + n);

for (const e of entries.filter((e) => e.kind === "mcp-remote").slice(0, 6)) {
  console.log("· " + e.id + " → " + (e.endpoint ?? ""));
}`,
      },
    },
    {
      kind: "connect",
      id: "capstone",
      label: "Capstone",
      image: "atlas",
      connection: { ref: "deepwiki.org.main", auth: { kind: "none" }, tools: ["deepwiki"] },
      artifacts: ["/tmp/wiki.db"],
      summary:
        "Integrations and engines compose: a public MCP integration feeds SQLite for analysis — no credential anywhere, and the subject is this very repo. One Luau program pulls the wiki structure, lands it in a table, and queries it back; the database is yours to download.",
      notes: [
        "atlas = loom + the warm SQLite service, so tools and sqlite share one program",
        "The same shape works for any integration — swap DeepWiki for Stripe and land invoices instead",
        "Join it with mounted files (§6) or emit a PDF (§4) — same machine",
      ],
      code: {
        language: "ts",
        source: `const vm = await mc.create();

await vm.luau(\`
  local tools  = require("tools")
  local sqlite = require("sqlite")

  local res = tools.call("deepwiki.org.main.read_wiki_structure", {
    repoName = "NarendraPatwardhan/agent-os",
  })
  assert(res.ok, res.err and res.err.message)

  local db = assert(sqlite.open("/tmp/wiki.db"))
  db:exec("CREATE TABLE pages (title TEXT)")
  local stmt = db:prepare("INSERT INTO pages VALUES (?)")
  local n = 0
  for _, line in ipairs(string.splitlines(res.data.content[1].text)) do
    local title = line:match("^%s*%-%s*(.+)")
    if title then stmt:run(title); n += 1 end
  end
  stmt:close()
  print(n .. " wiki pages catalogued")
\`);

await vm.exec(\`sqlite /tmp/wiki.db "SELECT title FROM pages LIMIT 5"\`);`,
      },
    },
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
