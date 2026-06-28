<div align="center">
  <img src="./web/public/agentos.svg" alt="agent-os hero" width="270">

  <h1>agent-os</h1>

  <p><strong>A WebAssembly-native computer for AI agents.</strong></p>

  <p>
    <a href="./SYSTEMS.md"><img alt="Design contract: SYSTEMS.md" src="https://img.shields.io/badge/design-SYSTEMS.md-111111"></a>
    <a href="./LICENSE"><img alt="License: BSL 1.1" src="https://img.shields.io/badge/license-BSL%201.1-f5c542"></a>
    <img alt="Runtime: WebAssembly" src="https://img.shields.io/badge/runtime-WebAssembly-654ff0">
    <img alt="Build: Bazel" src="https://img.shields.io/badge/build-Bazel-43a047">
    <img alt="SDK: TypeScript and Bun" src="https://img.shields.io/badge/SDK-TypeScript%20%2B%20Bun-3178c6">
<!-- BEGIN generated:image-size-badges -->
    <br>
    <img alt="Image size: minimal 3.3 MiB" src="https://img.shields.io/static/v1?label=minimal&amp;message=3.3%20MiB&amp;color=2e7d32">
    <img alt="Image size: posix 13.9 MiB" src="https://img.shields.io/static/v1?label=posix&amp;message=13.9%20MiB&amp;color=2e7d32">
    <img alt="Image size: loom 17.9 MiB" src="https://img.shields.io/static/v1?label=loom&amp;message=17.9%20MiB&amp;color=d99a08">
    <img alt="Image size: atlas 18.9 MiB" src="https://img.shields.io/static/v1?label=atlas&amp;message=18.9%20MiB&amp;color=1565c0">
    <img alt="Image size: paper 47.6 MiB" src="https://img.shields.io/static/v1?label=paper&amp;message=47.6%20MiB&amp;color=1565c0">
<!-- END generated:image-size-badges -->
  </p>

  <p>
    <a href="#what-you-can-build">What You Can Build</a> -
    <a href="#client-api">Client API</a> -
    <a href="#images">Images</a> -
    <a href="#build-and-verification">Build and Verification</a>
  </p>
</div>

agent-os gives AI agents a real computer: a contained Unix-like workspace with a
shell, files, network access, tools, data engines, document generation, and a
programmable scripting layer. It runs as WebAssembly, so the whole machine can be
paused, forked, replayed, moved, or restored as a value.

Use it when an agent needs to do actual work, not just call one API at a time.

- Connect an agent to your internal tools and SaaS APIs through one searchable
  tool catalog.
- Let the agent write programs that compose many tool calls in one turn.
- Mount data where the agent can inspect it with ordinary file commands.
- Run analysis in a warm SQLite service and generate PDFs with a warm Typst
  service.
- Build spreadsheet, document, and presentation workflows with the Luau Office
  batteries.
- Keep secrets, host objects, and raw infrastructure handles outside the
  sandbox.
- Snapshot a working agent, fork it into variants, and resume it with its warm
  state intact.

## What You Can Build

| Integration | What it enables |
|---|---|
| Host tools via `vm.tool`, `tool`, `kit` | Expose any app or internal API as searchable in-VM tools with schemas. |
| HTTP/HTTPS and WebSocket egress | Fetch APIs and stream socket traffic through host-gated network access. |
| Credential registry | Inject bearer, header, or query credentials at the host boundary without putting secrets in guest memory. |
| `hostDir` mount | Mount a jailed local directory into the VM as ordinary files. |
| `s3` mount | Read and write S3 buckets through filesystem operations. |
| `vectorStore` mount | Expose retrieval and RAG as `cat /rag/search/<query>`. |
| Luau | Program multi-step tool workflows inside the VM. |
| SQLite / `atlas` | Run warm SQL data processing from the CLI or `require("sqlite")`. |
| Typst / `paper` | Generate warm PDF and document artifacts from the CLI or `require("typst")`. |
| Luau Office batteries | Work with XLSX, DOCX, PPTX, ZIP, OPC, XML, media, and chart helpers. |
| OPFS/IndexedDB persistence | Keep `/var/persist` durable in browser-backed runs. |
| Bun/browser JS host | Embed the same VM in local apps or browser experiences. |
| OpenAPI adapter | Compile REST APIs into tool catalog records. Presets include Stripe, GitHub REST, Vercel, Cloudflare, Neon, OpenAI, Sentry, Exa, Axiom, Asana, Twilio, DigitalOcean, Petstore, Val Town, Resend, and Spotify. |
| Microsoft Graph adapter | Microsoft 365 workflows across profile, mail, calendar, contacts, tasks, Planner, OneDrive, Excel, SharePoint, OneNote, Teams, meetings, users, groups, directory, identity, admin, security, Intune, education, search, and platform services. |
| Google Discovery adapter | Google workflows across Calendar, Gmail, Sheets, Drive, Docs, Slides, Forms, Tasks, People, Photos, Chat, Keep, YouTube, Search Console, Classroom, Admin, Apps Script, BigQuery, and Cloud Resource Manager. |
| GraphQL adapter | GitHub GraphQL, GitLab, Linear, Monday.com, and AniList workflows across repos, issues, merge requests, pipelines, users, projects, teams, cycles, boards, items, anime, and manga. |
| Remote MCP adapter | MCP workflows across DeepWiki, Context7, Browserbase, Firecrawl, Neon, Axiom, Stripe, Linear, Notion, Sentry, Cloudflare, and deterministic Emulate fixtures. |

## Why It Is Different

### The agent has a computer

Most tool platforms expose a bag of remote function calls. agent-os gives the
agent an operating system. The agent can use a shell, write Luau, inspect files,
run pipelines, store intermediate artifacts, and call tools from code.

### Tools are discoverable at runtime

The `/svc/tools` broker owns a warm catalog. The `/tools` filesystem exposes the
same catalog as ordinary files. The Luau `tools` battery gives agents
`search`, `describe`, `call`, and dotted calls like
`tools.stripe.org.main.createCustomer(...)`.

This keeps prompts small while still giving the agent access to broad tool
surfaces.

### Heavy engines stay warm

SQLite, Typst, adapters, and the tool broker run as resident services inside the
VM. They pay their startup cost once, then serve CLI calls, Luau calls, and tool
calls through the same implementation.

### Snapshots preserve useful state

The VM's mutable state lives in WebAssembly linear memory: processes, services,
filesystem state, loaded modules, and warm handles. A snapshot captures the
computer, not just a log. Restoring it brings the agent back with its workspace
and warm services ready.

### The host stays in control

Secrets live in host-side credential registries. Host-backed mounts proxy bytes,
not handles. Network egress goes through the host. Tool calls can validate input
schemas before dispatch. The guest gets useful capabilities without receiving
the raw authority behind them.

## Client API

The SDK exposes one `Vm` surface:

```ts
import { mc, tool } from "@mc/core";
import { hostDir, s3, vectorStore } from "@mc/core/drivers";
import { z } from "zod";

const vm = await mc.create({
  runtime: "bun",
  image: "loom",
  net: true,
  deterministic: true,
  mounts: [
    { path: "/workspace", driver: hostDir({ root: "./workspace" }) },
    { path: "/assets", driver: s3({ bucket: "acme-assets", readOnly: true }) },
    { path: "/rag", driver: vectorStore({ embed, search }) },
  ],
  tools: [
    tool({
      name: "customer lookup",
      description: "Find a customer by account id.",
      input: z.object({ accountId: z.string() }),
      run: async ({ accountId }) => crm.lookup(accountId),
    }),
  ],
});

await vm.fs.write("/tmp/task.txt", "Find unpaid invoices and draft a report.");

const result = await vm.luau(`
local tools = require("tools")
local customer = tools.host.org.main.customer.lookup({ accountId = "acme" })
print(customer.ok and "ready" or customer.err.message)
`);

const snapshot = await vm.snapshot();
const fork = await vm.fork();
```

Core operations:

| Surface | What it enables |
|---|---|
| `vm.exec(cmd)` | Run shell commands and pipelines inside the VM. |
| `vm.luau(src)` | Run multi-step agent programs without model round-trips. |
| `vm.fs` | Read, write, list, stat, remove, and symlink VM files. |
| `vm.tool(...)` | Register host-resident tools into the live in-VM catalog. |
| `vm.mount(...)` | Expose host-backed storage or retrieval systems as files. |
| `vm.snapshot()` / `vm.fork()` | Capture, restore, and branch an agent workspace. |
| `vm.commit().asLayer()` | Turn VM changes into a reusable image layer. |
| `vm.shell()` | Attach an interactive shell or Luau REPL. |
| `vm.cron(...)` | Schedule recurring actions against a live VM. |

## Images

Choose the image that matches the job:

| Image | Includes | Best for |
|---|---|---|
| `minimal` | Shell, core builtins, package daemon, tools broker | Small custom harnesses |
| `posix` | `minimal` plus the full coreutils command set | File and text automation |
| `loom` | `posix` plus Luau and `luau-analyze` | Programmable agents |
| `atlas` | `loom` plus warm SQLite and `require("sqlite")` | Data workflows |
| `paper` | `loom` plus warm Typst and `require("typst")` | PDF and document workflows |

## Integration Model

agent-os supports integrations in four complementary ways:

1. Host tools: define a typed tool in application code and expose it through
   `/svc/tools`.
2. API adapters: compile OpenAPI, Microsoft Graph, or Google Discovery sources
   into ordinary tool catalog records.
3. Host-backed mounts: expose local directories, S3 buckets, vector retrieval,
   or a custom driver as a filesystem tree.
4. In-VM engines: use Luau, SQLite, Typst, shell tools, and Office batteries to
   transform data and generate artifacts.

These paths compose. An agent can call Google Sheets, write rows into SQLite,
join them with files mounted from S3, generate a PDF in Typst, and return the
artifact from one program.

## Build and Verification

The project is built as a Bazel graph. Generated contracts, kernel artifacts,
guest programs, images, SDK packages, and end-to-end tests all declare their
inputs, so tests run against the artifacts produced by the current source tree.

Useful commands:

```sh
bazel test //memcontainers/tests/e2e:core
bazel test //memcontainers/tests/e2e:extended
bazel test //memcontainers/sdk-js/core:vm_test
bazel test //...
```

The design contract for contributors is [SYSTEMS.md](./SYSTEMS.md).
