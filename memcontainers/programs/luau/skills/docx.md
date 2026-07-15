---
name: memcontainer-docx
description: "Create, read, edit, and validate Microsoft Word .docx files from inside a memcontainer or from a host agent using a memcontainer VM. Use this skill whenever the task mentions Word documents, .docx files, reports, memos, letters, templates, headings, tables of contents, comments, footnotes, endnotes, tracked changes, page numbers, headers, footers, bookmarks, hyperlinks, images, charts, or any document deliverable that should be produced as .docx. Prefer the memcontainers Luau `docx` library over JavaScript/Python document libraries, and use external readers only as validation when available."
---

# Memcontainer DOCX

Use the embedded Luau Office stack, not host-side JS/Python generation, unless the task explicitly asks for a host workflow. The implementation is `memcontainers/programs/luau/glue/lib/docx.luau`; use `memcontainers/tests/e2e/src/loom.rs` and `web/src/examples/chapters.ts` for proven examples, and `SYSTEMS.md` section 10.3 for capability boundaries.

## Workflow

1. Decide whether the job is model-level or package-level.
   - Use `require("docx")` for new documents and normal content edits.
   - Use `require("opc")` plus `require("xml")` for surgical edits to an existing template when exact unknown-part preservation matters. `Document:toBytes()` rebuilds a package.
2. Build or load the document in Luau.
3. Save with `Document:save(path)` or return `Document:toBytes()`.
4. Validate the artifact, not just the script.
   - In a task script, at minimum load it back with `docx.load(bytes)` and run `/bin/unzip -l file.docx`.
   - For library changes, run `cargo test -p e2e --test luau_libs`.
   - When `OOXML_VENV` is available, run the ignored real-reader tests so python-docx opens the produced bytes.

## Creation Pattern

```lua
local docx = require("docx")
local units = require("units")

local d = docx.new({
  properties = { core = { creator = "memcontainers", title = "Report" } },
  pageNumbers = true,
  header = "Confidential",
  footer = "Generated in memcontainers",
  sections = {{
    properties = {
      page = {
        size = { w = units.twipFromInches(8.5), h = units.twipFromInches(11) },
        margin = {
          top = units.twipFromInches(1),
          right = units.twipFromInches(1),
          bottom = units.twipFromInches(1),
          left = units.twipFromInches(1),
        },
      },
    },
    children = {
      docx.heading(1, "Quarterly Report"),
      docx.paragraph({ alignment = "center", children = {
        docx.run("Revenue "),
        docx.run({ text = "improved", bold = true, color = "008000" }),
      }}),
      docx.table({ rows = {
        { cells = { docx.cell("Metric"), docx.cell("Value") } },
        { cells = { docx.cell("ARR"), docx.cell("$12.4M") } },
      }}),
    },
  }},
})

assert(d:save("/tmp/report.docx"))
```

Use `units` for twips and EMUs. Do not guess magnitudes for page sizes, margins, images, or charts.

## Content API

- Text: `docx.run`, `docx.paragraph`, and `docx.heading`.
- Tables: `docx.table({ rows = { { cells = { docx.cell(...) } } } })`.
- Lists: `docx.bullet`, `docx.numbered`, or `docx.list(items, { ordered = true })`. Do not fake bullets with literal bullet characters.
- Images: `docx.image(bytes, { width = emu, height = emu })`; width and height can be omitted for PNG/JPEG/GIF with intrinsic dimensions.
- Charts: `docx.chart({ type, title, categories, series }, { width, height })`.
- Links: `docx.hyperlink(url, content)`, `docx.bookmark(name, content)`, and `docx.link(name, content)`.
- References and review: `docx.footnote`, `docx.endnote`, `docx.comment`, `docx.tableOfContents`, `docx.insertion`, `docx.deletion`, `Document:acceptRevisions()`, and `Document:rejectRevisions()`.
- Sections: pass `sections = { { properties = { columns = ..., page = ... }, children = ... } }` for page setup and columns.

## Existing Documents

Use `docx.open(path)` or `docx.load(bytes)` when the high-level model covers the intended edit. The reader parses sections, paragraphs, runs, tables, comments, footnotes, endnotes, headers, footers, images, hyperlinks, bookmarks, TOC fields, and revisions that the library models.

For a heavily styled template, inspect before editing:

```lua
local docx = require("docx")
local d = assert(docx.open("/tmp/template.docx"))
for _, block in ipairs(d.sections[1].children) do
  -- inspect block.kind, block.children, block.properties
end
```

If preserving every unmodeled style, custom XML part, macro-adjacent relationship, or vendor extension is part of success, operate at the OPC/XML layer instead of rebuilding through `Document:toBytes()`.

## Boundaries

- TOC fields are emitted, but a Word-compatible reader may need to update fields to render page numbers.
- High-level save rebuilds the package; it is not an exact binary/template round trip.
- Visual rendering and thumbnails are out of scope inside the headless wasm kernel. Use external rendering only as an optional QA step outside the memcontainer.
