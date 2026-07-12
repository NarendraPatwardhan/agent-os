---
name: memcontainer-pptx
description: 'Create, read, edit, rearrange, and validate Microsoft PowerPoint .pptx presentations from inside a memcontainer or from a host agent using a memcontainer VM. Use this skill whenever the task mentions decks, slides, presentations, .pptx files, speaker notes, comments, templates, layouts, placeholders, images, charts, tables, bullets, backgrounds, shapes, slide duplication, slide ordering, or any presentation deliverable. Prefer the memcontainers Luau `pptx` library over JS/Python presentation libraries; use external renderers/readers only as validation when available.'
---

# Memcontainer PPTX

Use the embedded Luau `pptx` library for presentation work. The implementation is `memcontainers/programs/luau/glue/lib/pptx.luau`; shared chart and media support lives beside it in `chart.luau` and `media.luau`. Use `web/src/examples/chapters.ts` for current examples and `SYSTEMS.md` section 10.3 for validation and limitations.

## Workflow

1. Use `require("pptx")` for new decks, content edits, layout placeholders, notes, comments, charts, images, shapes, tables, and slide operations.
2. Use `require("opc")` plus `require("xml")` for surgical edits to an existing deck when exact template preservation matters. `Presentation:toBytes()` rebuilds a package.
3. Use layouts for semantic slides; use absolute EMU geometry for deliberate composition.
4. Validate the artifact.
   - In task scripts, load back with `pptx.load(bytes)` and run `/bin/unzip -l file.pptx`.
   - For library changes, run `cargo test -p e2e --test luau_libs`.
   - When `OOXML_VENV` is available, run the ignored real-reader tests so python-pptx opens the produced bytes.
   - If an external renderer is available, render thumbnails for visual QA; do not claim visual proof from XML inspection alone.

## Creation Pattern

```lua
local pptx = require("pptx")
local units = require("units")

local pres = pptx.new({
  slideSize = "16:9",
  properties = { core = { creator = "memcontainers", title = "Quarterly Results" } },
})

local title = pres:addSlide({ layout = "title" })
title:setTitle("Quarterly Results")
title:setBody("Generated in memcontainers")
title:setBackground("1F4E79")

local s = pres:addSlide({ layout = "titleAndContent" })
s:setTitle("Highlights")
s:setBody({
  "Revenue up 12%",
  "Costs down 4%",
  { text = "Expansion pipeline improving", level = 1 },
})
s:addChart({
  type = "col",
  title = "Revenue",
  categories = { "Q1", "Q2", "Q3" },
  series = { { name = "Revenue", values = { 10, 12, 14 } } },
}, {
  x = units.emuFromInches(6.6),
  y = units.emuFromInches(1.5),
  w = units.emuFromInches(5.5),
  h = units.emuFromInches(3.2),
})
s:setNotes("Call out pipeline quality before discussing margin.")

assert(pres:save("/tmp/results.pptx"))
```

## Presentation API

- Deck: `pptx.new`, `pptx.load`, `pptx.open`, `Presentation:addSlide`, `duplicateSlide`, `moveSlide`, `removeSlide`, `toBytes`, and `save`.
- Layouts: `addSlide({ layout = "title" | "titleAndContent" | "blank" })`, `Slide:setTitle`, `Slide:setBody`, and `Slide:placeholder`.
- Text: `Slide:addText(text, opts)` with `runs` for mixed formatting or `paragraphs` for multi-paragraph bodies.
- Lists: `Slide:addBullets(items, opts)` or placeholder bodies with string/item arrays.
- Data and visuals: `Slide:addTable`, `Slide:addChart`, `Slide:addImage`, `Slide:setBackground`.
- Shapes: `Slide:addShape(preset, opts)` and `Slide:addFreeform(geometry, opts)` for DrawingML geometry, line, shadow, rotation, transparency, fill, and text.
- Review: `Slide:setNotes` and `Slide:addComment`.

## Composition Rules

Use `units.emuFromInches`, `units.emuFromCm`, or related helpers for positions and sizes. Keep slide layout stable by setting `x`, `y`, `w`, and `h` explicitly for free-positioned objects.

Prefer these patterns:

- Use built-in placeholders for title and body slides when possible.
- Put at least one visual element on important content slides: chart, table, image, shape, or structured callout.
- Keep tables short enough to read; convert dense data to an `.xlsx` and summarize the finding in the deck.
- Use notes for presenter-only context, not hidden user-facing content.
- Add comments when a slide needs review, open questions, or source verification.

## Existing Decks

Use `pptx.open(path)` or `pptx.load(bytes)` for model-level edits. The reader parses slide order, text boxes, shapes, tables, charts, images, backgrounds, notes, comments, and supported placeholders.

For template-sensitive work, inspect the package and use `opc`/`xml` if exact unmodeled layout/master/theme preservation is required. The high-level writer emits its own theme, master, built-in layouts, and slide parts.

## Boundaries

- High-level save rebuilds the package; it is not an exact template round trip.
- Visual rendering and thumbnail generation are outside the headless wasm kernel. Use optional host-side rendering for final visual QA when appearance matters.
- The library supports common shapes and custom freeform geometry, but it is not a full PowerPoint design engine. Keep compositions explicit and verify in a real reader when polish matters.
