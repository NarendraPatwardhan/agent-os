---
name: agent-os-typst
description: 'Compile Typst documents to PDF inside AgentOS, and compose PDFs from generated data. Use this skill whenever the task mentions compiling `.typ` to PDF in the VM, generating a PDF report/whitepaper/resume/invoice from a script, `require("typst")`, `/bin/typst`, `typst compile`, the `paper` flavor, the typst resident service, `/usr/share/fonts`, or turning sqlite/xlsx data into a typeset PDF. Prefer the Luau `typst` library over shelling out to `$ typst`; use the CLI only for quick one-shot compiles. (For authoring Typst SYNTAX itself, see the separate `typst` authoring skill — this one is the AgentOS service that runs the compiler.)'
---

# AgentOS Typst

Use the Luau `typst` library to compile Typst source to PDF — shipped as a VFS module by the `paper` flavor (not embedded in the interpreter, unlike `json`). The source of truth is the resident-service contract in `SYSTEMS.md`, the typst guest packaging in `third_party/typst/glue/BUILD.bazel`, and the paper flavor layer that ships `/bin/typst`, `/lib/luau/typst.luau`, and the baseline faces under `/usr/share/fonts`.

## Workflow

1. Use `require("typst")` from a Luau script. It talks to the warm typst service through `sys.svc` and returns PDF bytes.
2. Compile inline source with `typst.compile(source)`, or a `.typ` already in the VFS with `typst.compile_file(path)`.
3. Write the returned bytes wherever you need them: typically `sys.fs.write` to an output path, or hand them to another library.
4. Run scripts with `/bin/luau script.luau`; type-check with `/bin/luau --check script.luau`.

The service keeps ~30 MB of fonts loaded across calls, so the first compile pays the font-load cost once and every later compile reuses it. The CLI `$ typst compile in.typ [out.pdf]` is a thin one-shot client of the same warm service.

## Composition Pattern

Generated data can flow straight into a typeset PDF — build the Typst source from your data, compile, done:

```lua
local sqlite, typst = require("sqlite"), require("typst")
local db = sqlite.open("/var/persist/sales.db")
local lines = { "= Q3 Sales\n\n#table(columns: 2," }
for _, r in ipairs(db:query("SELECT month, revenue FROM sales WHERE quarter = ?", 3)) do
  lines[#lines + 1] = string.format("[%s], [%d],", r.month, r.revenue)
end
lines[#lines + 1] = ")"
local pdf = typst.compile(table.concat(lines, "\n"))   -- sqlite rows -> Typst -> PDF, one script
sys.fs.write("/out/q3.pdf", pdf)
```

## Inline vs. File

```lua
local typst = require("typst")

-- Inline source (self-contained): returns PDF bytes; raises on a compile error with file:line:col.
local pdf = typst.compile([[
  #set page(width: 12cm, height: auto)
  = Hello
  The date is #datetime.today().display().
]])

-- A .typ file in the VFS, with imports/images resolved against its directory (or opts.root):
local report, warnings = typst.compile_file("/work/report.typ", { root = "/work" })
for _, w in ipairs(warnings) do print(w.severity, w.message) end
```

Use inline `compile` for documents you build in the script. Use `compile_file` when the document lives on disk and pulls in `#include`/`#import` or `#image` from sibling files — those resolve against `root`.

## Fonts

The default faces (Linux Libertine, New Computer Modern, DejaVu, …) ship in the `paper` flavor under `/usr/share/fonts` and are scanned once at service startup. To use an extra typeface, drop its `.ttf`/`.otf`/`.ttc` into `/usr/share/fonts` before the service starts (or restart the service) and reference it with `#set text(font: "…")`.

## API Surface

- Module: `typst.compile(source [, opts])` and `typst.compile_file(path [, opts])` both return `(pdf: string, warnings)` — PDF bytes plus the (possibly empty) array of warning diagnostics; `typst.version()` returns the compiler version string.
- Options: `opts.root` sets the import/image resolution root (default `/` for inline, the file's directory for `compile_file`).
- Return discipline: a compilation error raises with the diagnostics formatted `severity: file:line:col: message` (catch with `pcall`); a service-unavailable/transport failure also raises.
- The PDF is a Lua byte string (8-bit clean) — write it with the fs API or pass it on; do not treat it as UTF-8 text.

## Rules

Prefer the Luau library by default. Reach for `$ typst compile` only for quick one-shot compiles at a shell prompt.

Build the Typst source however you like — a string literal, a template, or assembled from data — then compile once. The compiler is the expensive step; assembling the source is cheap.

One typst service instance serializes compiles: a second caller waits while the first compile runs (compiles can take seconds). Keep documents reasonably scoped, and prefer one compile over many tiny ones.

Warm is not durable in the data sense, but it does not need to be: typst has no per-document persistent state. The warm state is the shared font set; a crash just reloads it on the next call. A panicking compile aborts the service instance and the caller gets an error — reconnecting gets a clean instance (crash-only).

## Validation

Use the narrowest real gate that proves the behavior:

- Script type check: `/bin/luau --check script.luau`.
- Script runtime: `/bin/luau script.luau`.
- AgentOS typst/kernel behavior: `bazel test //tests/e2e`.

For PDF-producing scripts, validate the output, not just the exit code: check the bytes start with `%PDF-` and end with `%%EOF`, and re-read any generated file. When a compile is expected to fail, assert on the diagnostics (`pcall` the call and check the message), not just that it errored.

## Boundaries

- `require("typst")` resolves from the VFS cache, embedded libraries, then `package.path`; typst is shipped by the `paper` flavor layer, alongside `/bin/typst` and `/usr/share/fonts`.
- Output is PDF only (v1). SVG/PNG are not produced.
- `@preview` packages need network access and are NOT supported — a document that imports `@preview/...` fails with a package-not-found diagnostic. Vendor what you need into the source or local files instead.
- Inline `source` must fit the service's request buffer (~1 MiB). For a larger document, write it to a `.typ` in the VFS and use `compile_file`.
- The public surface is the Luau library and the CLI. Do not script the low-level `sys.svc` protocol unless you are changing the typst library or service itself.
