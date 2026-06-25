---
name: memcontainer-xlsx
description: 'Create, read, edit, recalculate, convert, and validate Microsoft Excel .xlsx spreadsheets from inside a memcontainer or from a host agent using a memcontainer VM. Use this skill whenever the task mentions spreadsheets, Excel, .xlsx, .csv, .tsv, worksheets, formulas, formula errors, charts, tables, filters, freeze panes, data validation, conditional formatting, named ranges, comments, images, or tabular deliverables that should become .xlsx. Prefer the memcontainers Luau `xlsx` library and its `calc` engine over JS/Python spreadsheet libraries; use external readers only as validation when available.'
---

# Memcontainer XLSX

Use the embedded Luau `xlsx` library for workbook work. The source of truth is `loom/lib/xlsx.luau`; supporting formula behavior lives in `loom/lib/calc.luau`. Use `crates/e2e/tests/luau_libs.rs` for current examples and `ctx/LUAU.md` for validation and limitations.

## Workflow

1. Use `require("xlsx")` for new workbooks, normal edits, CSV/TSV conversion, formulas, charts, tables, comments, images, and validation features.
2. Use `require("opc")` plus `require("xml")` for surgical edits to an existing workbook when exact template preservation matters. `Workbook:toBytes()` rebuilds a package.
3. Recalculate formulas when formulas are part of the deliverable.
4. Scan for formula and cell errors before saving or before reporting success.
5. Validate the actual `.xlsx` bytes.
   - In task scripts, load back with `xlsx.load(bytes)` and run `/bin/unzip -l file.xlsx`.
   - For library changes, run `cargo test -p e2e --test luau_libs`.
   - When `OOXML_VENV` is available, run the ignored real-reader tests so openpyxl opens the produced bytes.

## Creation Pattern

```lua
local xlsx = require("xlsx")
local units = require("units")

local wb = xlsx.new({ properties = { core = { creator = "memcontainers", title = "Plan" } } })
local ws = wb:addWorksheet("Forecast", { inlineStrings = true })

ws:setColumns({
  { header = "Month", key = "month", width = 14 },
  { header = "Revenue", key = "revenue", width = 14 },
  { header = "Cost", key = "cost", width = 14 },
  { header = "Margin", key = "margin", width = 14 },
})

ws:addRow({ month = "Jan", revenue = 120, cost = 50 })
ws:addRow({ month = "Feb", revenue = 140, cost = 58 })
ws:setCell("D2", xlsx.formula("B2-C2"))
ws:setCell("D3", xlsx.formula("B3-C3"))
ws:setCell("B4", xlsx.formula("SUM(B2:B3)"))
ws:freezePanes("A2")
ws:setAutoFilter("A1:D3")
ws:addTable({ name = "ForecastTable", ref = "A1:D3" })
ws:addChart({
  type = "col",
  title = "Revenue",
  categories = { "Jan", "Feb" },
  series = { { name = "Revenue", values = { 120, 140 } } },
}, { at = "F2", width = units.emuFromInches(5), height = units.emuFromInches(3) })

wb:recalculate()
assert(#wb:scanErrors() == 0)
assert(wb:save("/tmp/forecast.xlsx"))
```

## Workbook API

- Constructors: `xlsx.number`, `xlsx.string`, `xlsx.boolean`, `xlsx.error`, `xlsx.formula`, `xlsx.date`, and `xlsx.dateSerial`.
- Workbook: `xlsx.new`, `xlsx.load`, `xlsx.open`, `Workbook:addWorksheet`, `Workbook:worksheet`, `Workbook:defineName`, `Workbook:evaluate`, `Workbook:recalculate`, `Workbook:scanErrors`, `Workbook:toBytes`, and `Workbook:save`.
- Worksheet: `setColumns`, `setCell`, `cell`, `addRow`, `mergeCells`, `freezePanes`, `setAutoFilter`, `addDataValidation`, `addConditionalFormat`, `setComment`, `addTable`, `addImage`, `addHyperlink`, `addChart`, `eachRow`, and `iterRows`.
- Conversion: `xlsx.toCSV(ws, opts)` and `xlsx.fromCSV(text, opts)` support CSV/TSV-style delimiters.
- Address helpers: `xlsx.colLetter`, `xlsx.colNumber`, `xlsx.parseRef`, and `xlsx.makeRef`.

## Spreadsheet Rules

Use formulas for derived values so the workbook stays editable. Hardcode source facts, assumptions, and imported data; put calculations in formula cells and call `Workbook:recalculate()` before saving. For financial or planning work, separate assumptions from outputs and use comments for provenance where the source matters:

```lua
ws:setComment("B2", "Source: user-provided pipeline export, 2026-06-16", { author = "Agent" })
```

Use `Workbook:scanErrors()` as a non-negotiable preflight. It catches error-valued cells, formulas with cached error results, and formulas containing broken Excel error literals without needing a full external spreadsheet app.

## Formula Engine

The embedded `calc` engine supports dependency-graph recalculation, incremental dirty recompute, Excel error propagation, dynamic arrays and spilling, and a broad function catalog. Use:

```lua
local report = wb:recalculate()
local later = wb:recalculate({ dirty = { "A1" } })
local value = wb:evaluate("SUM(Forecast!B2:B3)", "Forecast")
```

Cycles resolve to errors rather than looping. Treat `#REF!`, `#DIV/0!`, `#VALUE!`, `#N/A`, `#NAME?`, `#NUM!`, `#NULL!`, and spill errors as blockers unless the user explicitly asked to demonstrate an error.

## Boundaries

- Cell comments emit reader-visible comment data, but the legacy VML note-box presentation layer is omitted.
- Streaming is row iteration plus inline-string write mode, not a constant-memory SAX writer; the kernel filesystem reads and writes whole buffers.
- High-level save rebuilds the package; use `opc`/`xml` for exact package-level edits.
- Visual rendering and thumbnails are out of scope inside the headless wasm kernel.
