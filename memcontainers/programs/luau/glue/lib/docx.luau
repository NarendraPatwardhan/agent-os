-- docx.luau — WordprocessingML (.docx) read + write (luau-extensions Ch.07). A
-- declarative tree of typed records mapped through the xform engine: the shared
-- run/paragraph property vocabulary is described once with ordered composite +
-- scalar combinators, so schema order is guaranteed and read/write can't drift.
-- The body wrapper, tables, the section's sectPr, styles.xml, and package assembly
-- are built directly (opc + xml). Defaults (Normal + Heading1-6 + Title) ship so
-- `new()` documents and headings render in Word.

local opc = require("opc")
local xml = require("xml")
local xform = require("xform")
local media = require("media")
local chart = require("chart")

local docx = {}

local NS_W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
local NS_R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
local NS_WP = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
local NS_A = "http://schemas.openxmlformats.org/drawingml/2006/main"
local NS_PIC = "http://schemas.openxmlformats.org/drawingml/2006/picture"
local NS_CORE = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
local NS_DC = "http://purl.org/dc/elements/1.1/"
local NS_DCTERMS = "http://purl.org/dc/terms/"
local NS_XSI = "http://www.w3.org/2001/XMLSchema-instance"
local NS_EXT = "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"

local WML = "application/vnd.openxmlformats-officedocument.wordprocessingml."
local CT = {
	document = WML .. "document.main+xml",
	styles = WML .. "styles+xml",
	numbering = WML .. "numbering+xml",
	header = WML .. "header+xml",
	footer = WML .. "footer+xml",
	footnotes = WML .. "footnotes+xml",
	endnotes = WML .. "endnotes+xml",
	comments = WML .. "comments+xml",
	chart = "application/vnd.openxmlformats-officedocument.drawingml.chart+xml",
	spreadsheet = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
	core = "application/vnd.openxmlformats-package.core-properties+xml",
	app = "application/vnd.openxmlformats-officedocument.extended-properties+xml",
}
local CHART_URI = "http://schemas.openxmlformats.org/drawingml/2006/chart"
local NS_C = "http://schemas.openxmlformats.org/drawingml/2006/chart"
local RELT = {
	officeDocument = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument",
	styles = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles",
	core = "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties",
	app = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties",
	image = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
	hyperlink = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
	chart = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart",
	package = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/package",
	numbering = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering",
	header = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header",
	footer = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer",
	footnotes = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes",
	endnotes = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/endnotes",
	comments = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments",
}
local PIC_URI = "http://schemas.openxmlformats.org/drawingml/2006/picture"

local function doc(root)
	return { kind = "document", prolog = {}, root = root }
end

-- ===========================================================================
-- The xforms for the shared property vocabulary (run + paragraph properties)
-- ===========================================================================

-- w:rFonts carries one font name across ascii/hAnsi/cs (bespoke: multi-attr).
local rFontsXform = {
	tag = "w:rFonts",
	localName = "rFonts",
	render = function(_, font)
		if not font then return nil end
		return xml.element("w:rFonts", { ["w:ascii"] = font, ["w:hAnsi"] = font, ["w:cs"] = font })
	end,
	parse = function(_, el)
		for _, a in ipairs(el.attributes) do
			if a.name.local_ == "ascii" then return a.value end
		end
		return nil
	end,
}

-- w:rPr — run properties, children in schema order (rStyle, rFonts, b, i, strike,
-- color, sz, u). sz is half-points (the model stores points; encode ×2).
local rPrXform = xform.composite({
	tag = "w:rPr",
	children = {
		{ key = "style", xform = xform.scalar({ tag = "w:rStyle", attr = "w:val", kind = "string" }) },
		{ key = "font", xform = rFontsXform },
		{ key = "bold", xform = xform.scalar({ tag = "w:b", kind = "bool", boolStyle = "presence" }) },
		{ key = "italic", xform = xform.scalar({ tag = "w:i", kind = "bool", boolStyle = "presence" }) },
		{ key = "strike", xform = xform.scalar({ tag = "w:strike", kind = "bool", boolStyle = "presence" }) },
		{ key = "color", xform = xform.scalar({ tag = "w:color", attr = "w:val", kind = "string" }) },
		{
			key = "size",
			xform = xform.scalar({
				tag = "w:sz",
				attr = "w:val",
				kind = "int",
				encode = function(pt) return tostring(math.floor(pt * 2)) end,
				decode = function(s) return tonumber(s) / 2 end,
			}),
		},
		{ key = "underline", xform = xform.scalar({ tag = "w:u", attr = "w:val", kind = "string" }) },
	},
})

-- w:t with xml:space="preserve" so significant leading/trailing whitespace survives.
local textXform = {
	tag = "w:t",
	localName = "t",
	render = function(_, text)
		if text == nil then return nil end
		return xml.element("w:t", { ["xml:space"] = "preserve" }, { xml.text(text) })
	end,
	parse = function(_, el)
		return xml.textOf(el)
	end,
}

-- w:r — a run: rPr (self-pruning) + text.
local runXform = xform.composite({
	tag = "w:r",
	new = function() return {} end,
	children = {
		{ key = "properties", xform = rPrXform },
		{ key = "text", xform = textXform },
	},
})

-- w:spacing — paragraph spacing before/after/line (bespoke: multi-attr).
local spacingXform = {
	tag = "w:spacing",
	localName = "spacing",
	render = function(_, sp)
		if not sp then return nil end
		local a = {}
		if sp.before then a["w:before"] = tostring(sp.before) end
		if sp.after then a["w:after"] = tostring(sp.after) end
		if sp.line then a["w:line"] = tostring(sp.line) end
		if next(a) == nil then return nil end
		return xml.element("w:spacing", a)
	end,
	parse = function(_, el)
		local sp = {}
		for _, a in ipairs(el.attributes) do
			sp[a.name.local_] = tonumber(a.value)
		end
		return sp
	end,
}

-- w:tabs — a list of tab stops, each w:tab val(alignment)+pos(twips)+optional
-- leader (bespoke: a list of child elements). align defaults to "left".
local tabsXform = {
	tag = "w:tabs",
	localName = "tabs",
	render = function(_, tabs)
		if not tabs or #tabs == 0 then return nil end
		local el = xml.element("w:tabs")
		for _, t in ipairs(tabs) do
			local a = { ["w:val"] = t.align or "left", ["w:pos"] = tostring(t.pos or 0) }
			if t.leader then a["w:leader"] = t.leader end
			el.children[#el.children + 1] = xml.element("w:tab", a)
		end
		return el
	end,
	parse = function(_, el)
		local tabs = {}
		for _, c in ipairs(el.children) do
			if c.kind == "element" and c.name.local_ == "tab" then
				local t = {}
				for _, a in ipairs(c.attributes) do
					if a.name.local_ == "val" then t.align = a.value end
					if a.name.local_ == "pos" then t.pos = tonumber(a.value) end
					if a.name.local_ == "leader" then t.leader = a.value end
				end
				tabs[#tabs + 1] = t
			end
		end
		return tabs
	end,
}

-- w:numPr — the list reference: ilvl + numId (bespoke: two child elements).
-- numId 1 = the bullet definition, numId 2 = the decimal definition (numbering.xml).
local numPrXform = {
	tag = "w:numPr",
	localName = "numPr",
	render = function(_, num)
		if not num then return nil end
		return xml.element("w:numPr", {}, {
			xml.element("w:ilvl", { ["w:val"] = tostring(num.level or 0) }),
			xml.element("w:numId", { ["w:val"] = tostring(num.ordered and 2 or 1) }),
		})
	end,
	parse = function(_, el)
		local num = {}
		for _, c in ipairs(el.children) do
			if c.kind == "element" then
				local v
				for _, a in ipairs(c.attributes) do
					if a.name.local_ == "val" then v = a.value end
				end
				if c.name.local_ == "ilvl" then num.level = tonumber(v) end
				if c.name.local_ == "numId" then num.ordered = (v == "2") end
			end
		end
		return num
	end,
}

-- w:pPr — paragraph properties (pStyle, numPr, spacing, jc) in schema order.
local pPrXform = xform.composite({
	tag = "w:pPr",
	children = {
		{ key = "style", xform = xform.scalar({ tag = "w:pStyle", attr = "w:val", kind = "string" }) },
		{ key = "numbering", xform = numPrXform },
		{ key = "tabs", xform = tabsXform },
		{ key = "spacing", xform = spacingXform },
		{ key = "alignment", xform = xform.scalar({ tag = "w:jc", attr = "w:val", kind = "string" }) },
	},
})

-- A paragraph's inline content is heterogeneous — text runs, images, hyperlinks —
-- and an image is *also* a w:r, so the generic content dispatch can't tell them
-- apart on parse. The run PROPERTIES still go through the xform engine (rPrXform);
-- only the paragraph's child iteration is bespoke.

-- An inline image: a run wrapping a w:drawing/wp:inline. Reads the rId, size, and
-- nonvisual id the prepare pass annotated (img._rid / width/height / _docId).
local function render_image_run(img)
	local w, h = tostring(img.width or 914400), tostring(img.height or 914400)
	local id = tostring(img._docId or 1)
	local pic = xml.element("pic:pic", {}, {
		xml.element("pic:nvPicPr", {}, {
			xml.element("pic:cNvPr", { id = id, name = "image" .. id }),
			xml.element("pic:cNvPicPr"),
		}),
		xml.element("pic:blipFill", {}, {
			xml.element("a:blip", { ["r:embed"] = img._rid }),
			xml.element("a:stretch", {}, { xml.element("a:fillRect") }),
		}),
		xml.element("pic:spPr", {}, {
			xml.element("a:xfrm", {}, {
				xml.element("a:off", { x = "0", y = "0" }),
				xml.element("a:ext", { cx = w, cy = h }),
			}),
			xml.element("a:prstGeom", { prst = "rect" }, { xml.element("a:avLst") }),
		}),
	})
	local inline = xml.element("wp:inline", { distT = "0", distB = "0", distL = "0", distR = "0" }, {
		xml.element("wp:extent", { cx = w, cy = h }),
		xml.element("wp:effectExtent", { l = "0", t = "0", r = "0", b = "0" }),
		xml.element("wp:docPr", { id = id, name = "Picture " .. id }),
		xml.element("wp:cNvGraphicFramePr", {}, { xml.element("a:graphicFrameLocks", { noChangeAspect = "1" }) }),
		xml.element("a:graphic", {}, { xml.element("a:graphicData", { uri = PIC_URI }, { pic }) }),
	})
	return xml.element("w:r", {}, { xml.element("w:drawing", {}, { inline }) })
end

-- An inline chart: a run wrapping a w:drawing whose graphicData is a c:chart
-- referencing the chart part by the rId from prepare.
local function render_chart_run(ch)
	local w, h = tostring(ch.width or 5486400), tostring(ch.height or 3200400)
	local id = tostring(ch._docId or 1)
	local inline = xml.element("wp:inline", { distT = "0", distB = "0", distL = "0", distR = "0" }, {
		xml.element("wp:extent", { cx = w, cy = h }),
		xml.element("wp:effectExtent", { l = "0", t = "0", r = "0", b = "0" }),
		xml.element("wp:docPr", { id = id, name = "Chart " .. id }),
		xml.element("wp:cNvGraphicFramePr"),
		xml.element("a:graphic", {}, {
			xml.element("a:graphicData", { uri = CHART_URI }, {
				xml.element("c:chart", { ["xmlns:c"] = NS_C, ["xmlns:r"] = NS_R, ["r:id"] = ch._rid }),
			}),
		}),
	})
	return xml.element("w:r", {}, { xml.element("w:drawing", {}, { inline }) })
end

-- A w:hyperlink wrapping its runs. An external link carries r:id (rel allocated in
-- prepare); an internal link to a bookmark carries w:anchor (no rel).
local function render_hyperlink(hl)
	local el = xml.element("w:hyperlink", hl.anchor and { ["w:anchor"] = hl.anchor } or { ["r:id"] = hl._rid })
	for _, run in ipairs(hl.children or {}) do
		local r = runXform.render({}, run)
		if r then el.children[#el.children + 1] = r end
	end
	return el
end

-- A bookmarked span → bookmarkStart (id+name), the wrapped runs, bookmarkEnd (id).
-- prepare assigns node._id. Returns a LIST of sibling elements.
local function render_bookmark(node)
	local id = tostring(node._id)
	local out = { xml.element("w:bookmarkStart", { ["w:id"] = id, ["w:name"] = node.name }) }
	for _, run in ipairs(node.children or {}) do
		local r = runXform.render({}, run)
		if r then out[#out + 1] = r end
	end
	out[#out + 1] = xml.element("w:bookmarkEnd", { ["w:id"] = id })
	return out
end

-- A note reference (footnote or endnote): a superscripted run carrying
-- w:footnoteReference / w:endnoteReference. The body lives in the notes part;
-- prepare assigns node._id (≥ 1). `which` = "footnote" | "endnote".
local function render_note_ref(node, which)
	local style = (which == "endnote") and "EndnoteReference" or "FootnoteReference"
	return xml.element("w:r", {}, {
		xml.element("w:rPr", {}, {
			xml.element("w:rStyle", { ["w:val"] = style }),
			xml.element("w:vertAlign", { ["w:val"] = "superscript" }),
		}),
		xml.element("w:" .. which .. "Reference", { ["w:id"] = tostring(node._id) }),
	})
end

-- A tracked insertion / deletion wrapping its runs. Insertion runs are normal
-- (w:t); deletion runs carry w:delText instead. prepare assigns node._id.
local function render_revision(node)
	local tag = (node.kind == "deletion") and "w:del" or "w:ins"
	local attrs = { ["w:id"] = tostring(node._id), ["w:author"] = node.author or "Author" }
	if node.date then attrs["w:date"] = node.date end
	local el = xml.element(tag, attrs)
	for _, run in ipairs(node.children or {}) do
		if node.kind == "deletion" then
			local r = xml.element("w:r")
			local rPr = rPrXform.render({}, run.properties)
			if rPr then r.children[#r.children + 1] = rPr end
			r.children[#r.children + 1] = xml.element("w:delText", { ["xml:space"] = "preserve" }, { xml.text(run.text or "") })
			el.children[#el.children + 1] = r
		else
			local r = runXform.render({}, run)
			if r then el.children[#el.children + 1] = r end
		end
	end
	return el
end

-- A commented run-cluster → commentRangeStart, the wrapped runs, commentRangeEnd,
-- then the reference run. The comment text lives in comments.xml; prepare assigns
-- node.comment._id (≥ 0). Returns a LIST of sibling elements (no single wrapper).
local function render_commented(node)
	local id = tostring(node.comment._id)
	local out = { xml.element("w:commentRangeStart", { ["w:id"] = id }) }
	for _, run in ipairs(node.children or {}) do
		local r = runXform.render({}, run)
		if r then out[#out + 1] = r end
	end
	out[#out + 1] = xml.element("w:commentRangeEnd", { ["w:id"] = id })
	out[#out + 1] = xml.element("w:r", {}, {
		xml.element("w:rPr", {}, { xml.element("w:rStyle", { ["w:val"] = "CommentReference" }) }),
		xml.element("w:commentReference", { ["w:id"] = id }),
	})
	return out
end

-- Render a paragraph: pPr (self-pruning) then inline content. A w:p always
-- renders (blank lines matter).
local function render_paragraph(para)
	local p = xml.element("w:p")
	local pPr = pPrXform.render({}, para.properties)
	if pPr then p.children[#p.children + 1] = pPr end
	for _, child in ipairs(para.children or {}) do
		if child.kind == "image" then
			p.children[#p.children + 1] = render_image_run(child)
		elseif child.kind == "chart" then
			p.children[#p.children + 1] = render_chart_run(child)
		elseif child.kind == "hyperlink" then
			p.children[#p.children + 1] = render_hyperlink(child)
		elseif child.kind == "footnote" then
			p.children[#p.children + 1] = render_note_ref(child, "footnote")
		elseif child.kind == "endnote" then
			p.children[#p.children + 1] = render_note_ref(child, "endnote")
		elseif child.kind == "insertion" or child.kind == "deletion" then
			p.children[#p.children + 1] = render_revision(child)
		elseif child.kind == "tab" then
			p.children[#p.children + 1] = xml.element("w:r", {}, { xml.element("w:tab") })
		elseif child.kind == "commented" then
			for _, e in ipairs(render_commented(child)) do
				p.children[#p.children + 1] = e
			end
		elseif child.kind == "bookmark" then
			for _, e in ipairs(render_bookmark(child)) do
				p.children[#p.children + 1] = e
			end
		else
			local el = runXform.render({}, child)
			if el then p.children[#p.children + 1] = el end
		end
	end
	return p
end

-- ===========================================================================
-- Tables (bespoke — nested but regular)
-- ===========================================================================

local render_block -- forward (block ↔ table mutual recursion)

local function render_cell(cell)
	local tc = xml.element("w:tc")
	for _, block in ipairs(cell.children or {}) do
		tc.children[#tc.children + 1] = render_block(block)
	end
	if #tc.children == 0 then
		tc.children[1] = xml.element("w:p") -- a cell must contain at least one paragraph
	end
	return tc
end

local function render_row(row)
	local tr = xml.element("w:tr")
	for _, cell in ipairs(row.cells) do
		tr.children[#tr.children + 1] = render_cell(cell)
	end
	return tr
end

local function render_table(tbl)
	local ncols = 0
	for _, row in ipairs(tbl.rows) do
		ncols = math.max(ncols, #row.cells)
	end
	local t = xml.element("w:tbl")

	local borders = xml.element("w:tblBorders")
	for _, side in ipairs({ "top", "left", "bottom", "right", "insideH", "insideV" }) do
		borders.children[#borders.children + 1] =
			xml.element("w:" .. side, { ["w:val"] = "single", ["w:sz"] = "4", ["w:space"] = "0", ["w:color"] = "auto" })
	end
	t.children[1] = xml.element("w:tblPr", {}, {
		xml.element("w:tblW", { ["w:w"] = "0", ["w:type"] = "auto" }),
		borders,
	})

	local grid = xml.element("w:tblGrid")
	for _ = 1, ncols do
		grid.children[#grid.children + 1] = xml.element("w:gridCol", { ["w:w"] = "2880" })
	end
	t.children[2] = grid

	for _, row in ipairs(tbl.rows) do
		t.children[#t.children + 1] = render_row(row)
	end
	return t
end

-- A table-of-contents field paragraph. A complex field (begin → instrText → separate
-- → placeholder result → end) that Word/LibreOffice repaginates on open. `levels`
-- (e.g. "1-3") feeds the TOC switch; `placeholder` is the pre-population text.
local function render_toc(toc)
	local instr = string.format(' TOC \\o "%s" \\h \\z \\u ', toc.levels or "1-3")
	local function fld(t) return xml.element("w:r", {}, { xml.element("w:fldChar", { ["w:fldCharType"] = t }) }) end
	return xml.element("w:p", {}, {
		xml.element("w:pPr", {}, { xml.element("w:pStyle", { ["w:val"] = "TOC" }) }),
		fld("begin"),
		xml.element("w:r", {}, { xml.element("w:instrText", { ["xml:space"] = "preserve" }, { xml.text(instr) }) }),
		fld("separate"),
		xml.element("w:r", {}, { xml.element("w:t", {}, { xml.text(toc.placeholder or "Right-click to update field.") }) }),
		fld("end"),
	})
end

-- render one block (paragraph, table or TOC field) → an element.
function render_block(block)
	if block.kind == "table" then
		return render_table(block)
	elseif block.kind == "toc" then
		return render_toc(block)
	end
	return render_paragraph(block)
end

-- ===========================================================================
-- Builders (declarative constructors — the primary API)
-- ===========================================================================

local RUN_PROP_KEYS = { "bold", "italic", "strike", "underline", "color", "size", "font", "style" }

-- docx.run("text") or docx.run({ text=…, bold=true, size=12, color="FF0000", … }).
function docx.run(s)
	if type(s) == "string" then
		return { kind = "run", text = s }
	end
	local props = {}
	for _, k in ipairs(RUN_PROP_KEYS) do
		if s[k] ~= nil then props[k] = s[k] end
	end
	return { kind = "run", text = s.text, properties = next(props) and props or nil }
end

-- Normalize inline content (string | a single run | an array of runs) → a run array.
local function runs_of(content)
	if type(content) == "string" then
		return { docx.run(content) }
	elseif content.kind == "run" then
		return { content }
	end
	return content
end

-- docx.paragraph("text") or docx.paragraph({ alignment="center", style=…, spacing=…,
-- children={ docx.run(...), ... } }).
function docx.paragraph(spec)
	if type(spec) == "string" then
		return { kind = "paragraph", children = { docx.run(spec) } }
	end
	local props = {}
	if spec.style then props.style = spec.style end
	if spec.alignment then props.alignment = spec.alignment end
	if spec.spacing then props.spacing = spec.spacing end
	if spec.tabs then props.tabs = spec.tabs end
	return {
		kind = "paragraph",
		properties = next(props) and props or nil,
		children = spec.children or {},
	}
end

-- docx.heading(1, "Title") → a paragraph styled Heading1 (level 0/"Title" → Title).
function docx.heading(level, text)
	local style = (level == 0 or level == "Title") and "Title" or ("Heading" .. tostring(level))
	return { kind = "paragraph", properties = { style = style }, children = { docx.run(text) } }
end

-- docx.image(bytes, opts?) → inline-image content for a paragraph. opts.width/
-- height in EMU (auto-sized from the image's intrinsic pixels @96dpi if omitted).
function docx.image(bytes, opts)
	opts = opts or {}
	return { kind = "image", bytes = bytes, width = opts.width, height = opts.height }
end

-- docx.chart(model, opts?) → inline-chart content for a paragraph. model =
-- { type, title?, categories, series={{name,values}…} }; opts.width/height in EMU.
function docx.chart(model, opts)
	opts = opts or {}
	return { kind = "chart", model = model, width = opts.width, height = opts.height }
end

-- docx.hyperlink(target, content) → a hyperlink run-cluster for a paragraph.
-- `target` is an external URL string, or { anchor = "bookmarkName" } for an internal
-- link. `content` is a string, a single run, or an array of runs.
function docx.hyperlink(target, content)
	local runs = runs_of(content)
	if type(target) == "table" and target.anchor then
		return { kind = "hyperlink", anchor = target.anchor, children = runs }
	end
	return { kind = "hyperlink", url = target, children = runs }
end

-- docx.link(anchor, content) → an internal hyperlink to a bookmark (convenience).
function docx.link(anchor, content)
	return { kind = "hyperlink", anchor = anchor, children = runs_of(content) }
end

-- docx.bookmark(name, content?) → a bookmarked span wrapping `content` runs (or an
-- empty anchor point if content is omitted). Link to it with docx.link(name, …).
function docx.bookmark(name, content)
	return { kind = "bookmark", name = name, children = content and runs_of(content) or {} }
end

-- docx.tab() → a tab character (a run holding w:tab); pair with paragraph `tabs`.
function docx.tab()
	return { kind = "tab" }
end

-- docx.tableOfContents(opts?) → a TOC field block. opts.levels (e.g. "1-3"),
-- opts.placeholder (the result text shown until the reader updates the field).
function docx.tableOfContents(opts)
	opts = opts or {}
	return { kind = "toc", levels = opts.levels, placeholder = opts.placeholder }
end

-- docx.insertion(content, opts?) / docx.deletion(content, opts?) → a tracked change
-- wrapping `content` runs. opts = { author?, date? }. Apply/strip with the document
-- Document:acceptRevisions() / :rejectRevisions().
function docx.insertion(content, opts)
	opts = opts or {}
	return { kind = "insertion", children = runs_of(content), author = opts.author, date = opts.date }
end
function docx.deletion(content, opts)
	opts = opts or {}
	return { kind = "deletion", children = runs_of(content), author = opts.author, date = opts.date }
end

-- docx.endnote(content) → an endnote-reference for a paragraph (mirrors footnote).
function docx.endnote(content)
	local blocks
	if type(content) == "string" then
		blocks = { docx.paragraph(content) }
	elseif content.kind then
		blocks = { content }
	else
		blocks = content
	end
	return { kind = "endnote", content = blocks }
end

-- docx.footnote(content) → a footnote-reference for a paragraph. `content` is the
-- note body: a string, a paragraph block, or an array of blocks.
function docx.footnote(content)
	local blocks
	if type(content) == "string" then
		blocks = { docx.paragraph(content) }
	elseif content.kind then
		blocks = { content }
	else
		blocks = content
	end
	return { kind = "footnote", content = blocks }
end

-- docx.comment(content, comment) → a commented run-cluster for a paragraph.
-- `content` is the commented text (string / run / array of runs); `comment` is the
-- note text (string) or { text, author?, initials?, date? }.
function docx.comment(content, comment)
	local runs
	if type(content) == "string" then
		runs = { docx.run(content) }
	elseif content.kind == "run" then
		runs = { content }
	else
		runs = content
	end
	if type(comment) == "string" then
		comment = { text = comment }
	end
	return { kind = "commented", children = runs, comment = comment or {} }
end

-- docx.cell("text") or docx.cell({ children = { block, … } }).
function docx.cell(content)
	if type(content) == "string" then
		return { children = { docx.paragraph(content) } }
	end
	if content.children then
		return content
	end
	return { children = { content } }
end

-- docx.table({ rows = { { cells = { docx.cell("a"), docx.cell("b") } }, … } }).
function docx.table(spec)
	return { kind = "table", rows = spec.rows }
end

-- docx.bullet(text, level?) / docx.numbered(text, level?) → a single list
-- paragraph (style ListParagraph + a numPr referencing the bullet/decimal list).
function docx.bullet(text, level)
	return { kind = "paragraph", properties = { style = "ListParagraph", numbering = { ordered = false, level = level or 0 } }, children = { docx.run(text) } }
end
function docx.numbered(text, level)
	return { kind = "paragraph", properties = { style = "ListParagraph", numbering = { ordered = true, level = level or 0 } }, children = { docx.run(text) } }
end

-- docx.list(items, opts?) → an ARRAY of list paragraphs. items[i] is a string or
-- { text=…, level=… }. opts.ordered → a numbered list. The array can be placed
-- directly in `children` (arrays are flattened).
function docx.list(items, opts)
	opts = opts or {}
	local out = {}
	for _, it in ipairs(items) do
		local text = (type(it) == "table") and it.text or it
		local level = (type(it) == "table") and it.level or 0
		out[#out + 1] = opts.ordered and docx.numbered(text, level) or docx.bullet(text, level)
	end
	return out
end

-- ===========================================================================
-- styles.xml (defaults) + sectPr + docProps
-- ===========================================================================

-- A built-in heading: id, display name, half-point size, before-spacing twips.
local HEADINGS = {
	{ id = "Title", name = "Title", sz = 56, before = 0 },
	{ id = "Heading1", name = "heading 1", sz = 32, before = 240 },
	{ id = "Heading2", name = "heading 2", sz = 28, before = 200 },
	{ id = "Heading3", name = "heading 3", sz = 26, before = 200 },
	{ id = "Heading4", name = "heading 4", sz = 24, before = 200 },
	{ id = "Heading5", name = "heading 5", sz = 22, before = 200 },
	{ id = "Heading6", name = "heading 6", sz = 20, before = 200 },
}

local function render_styles()
	local root = xml.element("w:styles", { ["xmlns:w"] = NS_W })
	root.children[#root.children + 1] = xml.element("w:docDefaults", {}, {
		xml.element("w:rPrDefault", {}, { xml.element("w:rPr", {}, {
			xml.element("w:rFonts", { ["w:ascii"] = "Calibri", ["w:hAnsi"] = "Calibri", ["w:cs"] = "Calibri" }),
			xml.element("w:sz", { ["w:val"] = "22" }),
		}) }),
		xml.element("w:pPrDefault"),
	})
	-- Normal (the default paragraph style)
	root.children[#root.children + 1] = xml.element("w:style", { ["w:type"] = "paragraph", ["w:default"] = "1", ["w:styleId"] = "Normal" }, {
		xml.element("w:name", { ["w:val"] = "Normal" }),
	})
	for _, h in ipairs(HEADINGS) do
		root.children[#root.children + 1] = xml.element("w:style", { ["w:type"] = "paragraph", ["w:styleId"] = h.id }, {
			xml.element("w:name", { ["w:val"] = h.name }),
			xml.element("w:basedOn", { ["w:val"] = "Normal" }),
			xml.element("w:pPr", {}, {
				xml.element("w:keepNext"),
				xml.element("w:spacing", { ["w:before"] = tostring(h.before), ["w:after"] = "0" }),
			}),
			xml.element("w:rPr", {}, {
				xml.element("w:b"),
				xml.element("w:sz", { ["w:val"] = tostring(h.sz) }),
			}),
		})
	end
	-- ListParagraph (used by bulleted / numbered lists)
	root.children[#root.children + 1] = xml.element("w:style", { ["w:type"] = "paragraph", ["w:styleId"] = "ListParagraph" }, {
		xml.element("w:name", { ["w:val"] = "List Paragraph" }),
		xml.element("w:basedOn", { ["w:val"] = "Normal" }),
		xml.element("w:pPr", {}, { xml.element("w:ind", { ["w:left"] = "720" }) }),
	})
	-- footnote / comment styles (character refs + their body paragraph styles)
	local function char_style(id, name)
		return xml.element("w:style", { ["w:type"] = "character", ["w:styleId"] = id }, {
			xml.element("w:name", { ["w:val"] = name }),
		})
	end
	local function body_style(id, name)
		return xml.element("w:style", { ["w:type"] = "paragraph", ["w:styleId"] = id }, {
			xml.element("w:name", { ["w:val"] = name }),
			xml.element("w:basedOn", { ["w:val"] = "Normal" }),
		})
	end
	root.children[#root.children + 1] = char_style("FootnoteReference", "footnote reference")
	root.children[#root.children + 1] = char_style("EndnoteReference", "endnote reference")
	root.children[#root.children + 1] = char_style("CommentReference", "annotation reference")
	root.children[#root.children + 1] = body_style("FootnoteText", "footnote text")
	root.children[#root.children + 1] = body_style("EndnoteText", "endnote text")
	root.children[#root.children + 1] = body_style("CommentText", "annotation text")
	root.children[#root.children + 1] = body_style("TOC", "TOC Heading")
	return root
end

-- numbering.xml — two multi-level abstract lists (bullet = abstractNumId 0,
-- decimal = 1) and their num instances (numId 1 → bullet, numId 2 → decimal).
local function render_numbering()
	local root = xml.element("w:numbering", { ["xmlns:w"] = NS_W })
	local function abstract_list(id, fmt, levelText)
		local abs = xml.element("w:abstractNum", { ["w:abstractNumId"] = tostring(id) })
		for lvl = 0, 2 do
			abs.children[#abs.children + 1] = xml.element("w:lvl", { ["w:ilvl"] = tostring(lvl) }, {
				xml.element("w:start", { ["w:val"] = "1" }),
				xml.element("w:numFmt", { ["w:val"] = fmt }),
				xml.element("w:lvlText", { ["w:val"] = levelText(lvl) }),
				xml.element("w:lvlJc", { ["w:val"] = "left" }),
				xml.element("w:pPr", {}, {
					xml.element("w:ind", { ["w:left"] = tostring(720 * (lvl + 1)), ["w:hanging"] = "360" }),
				}),
			})
		end
		return abs
	end
	local bullets = { "\226\151\143", "\226\151\139", "\226\150\170" } -- ● ○ ▪
	root.children[#root.children + 1] = abstract_list(0, "bullet", function(lvl) return bullets[lvl + 1] or "\226\128\162" end)
	root.children[#root.children + 1] = abstract_list(1, "decimal", function(lvl) return "%" .. (lvl + 1) .. "." end)
	root.children[#root.children + 1] = xml.element("w:num", { ["w:numId"] = "1" }, { xml.element("w:abstractNumId", { ["w:val"] = "0" }) })
	root.children[#root.children + 1] = xml.element("w:num", { ["w:numId"] = "2" }, { xml.element("w:abstractNumId", { ["w:val"] = "1" }) })
	return root
end

-- footnotes.xml / endnotes.xml — the reserved separator/continuation notes (ids -1,
-- 0) then one w:footnote|w:endnote per registered note (._id ≥ 1). The first body
-- paragraph leads with the ref mark + the *Text style; bodies are paragraphs of
-- runs. `which` = "footnote" | "endnote" selects every element/style name.
local function render_notes(notes, which)
	local item, mark = "w:" .. which, "w:" .. which .. "Ref"
	local textStyle = (which == "endnote") and "EndnoteText" or "FootnoteText"
	local refStyle = (which == "endnote") and "EndnoteReference" or "FootnoteReference"
	local root = xml.element("w:" .. which .. "s", { ["xmlns:w"] = NS_W })
	local function reserved(kind, id)
		root.children[#root.children + 1] = xml.element(item, { ["w:type"] = kind, ["w:id"] = id }, {
			xml.element("w:p", {}, { xml.element("w:r", {}, { xml.element("w:" .. kind) }) }),
		})
	end
	reserved("separator", "-1")
	reserved("continuationSeparator", "0")
	for _, fn in ipairs(notes) do
		local note = xml.element(item, { ["w:id"] = tostring(fn._id) })
		for i, block in ipairs(fn.content or {}) do
			local p = xml.element("w:p", {}, {
				xml.element("w:pPr", {}, { xml.element("w:pStyle", { ["w:val"] = textStyle }) }),
			})
			if i == 1 then
				p.children[#p.children + 1] = xml.element("w:r", {}, {
					xml.element("w:rPr", {}, { xml.element("w:rStyle", { ["w:val"] = refStyle }) }),
					xml.element(mark),
				})
			end
			for _, run in ipairs(block.children or {}) do
				local r = runXform.render({}, run)
				if r then p.children[#p.children + 1] = r end
			end
			note.children[#note.children + 1] = p
		end
		root.children[#root.children + 1] = note
	end
	return root
end

-- comments.xml — one w:comment per registered comment (cm._id ≥ 0). The body is a
-- CommentText paragraph leading with the annotation-ref mark then the comment text.
local function render_comments(comments)
	local root = xml.element("w:comments", { ["xmlns:w"] = NS_W })
	for _, cm in ipairs(comments) do
		local attrs = { ["w:id"] = tostring(cm._id), ["w:author"] = cm.author or "Author" }
		if cm.initials then attrs["w:initials"] = cm.initials end
		if cm.date then attrs["w:date"] = cm.date end
		root.children[#root.children + 1] = xml.element("w:comment", attrs, {
			xml.element("w:p", {}, {
				xml.element("w:pPr", {}, { xml.element("w:pStyle", { ["w:val"] = "CommentText" }) }),
				xml.element("w:r", {}, {
					xml.element("w:rPr", {}, { xml.element("w:rStyle", { ["w:val"] = "CommentReference" }) }),
					xml.element("w:annotationRef"),
				}),
				xml.element("w:r", {}, {
					xml.element("w:t", { ["xml:space"] = "preserve" }, { xml.text(cm.text or "") }),
				}),
			}),
		})
	end
	return root
end

-- Normalize header/footer content (string | block | array of blocks) → blocks.
local function to_blocks(content)
	if type(content) == "string" then
		return { docx.paragraph(content) }
	elseif content.kind then
		return { content }
	end
	return content
end

-- A header (w:hdr) or footer (w:ftr) part. `pageNumbers` appends a centred PAGE
-- field paragraph (used for footers).
local function render_hf(tag, content, pageNumbers)
	local root = xml.element(tag, { ["xmlns:w"] = NS_W, ["xmlns:r"] = NS_R })
	for _, block in ipairs(to_blocks(content or {})) do
		root.children[#root.children + 1] = render_block(block)
	end
	if pageNumbers then
		root.children[#root.children + 1] = xml.element("w:p", {}, {
			xml.element("w:pPr", {}, { xml.element("w:jc", { ["w:val"] = "center" }) }),
			xml.element("w:fldSimple", { ["w:instr"] = " PAGE " }, {
				xml.element("w:r", {}, { xml.element("w:t", {}, { xml.text("1") }) }),
			}),
		})
	end
	return root
end

-- sectPr — header/footer references (schema-first), then page size + margins.
local function render_sectPr(section, headerRid, footerRid)
	local page = (section and section.properties and section.properties.page) or {}
	local size = page.size or { w = 12240, h = 15840 } -- US Letter, twips
	local m = page.margin or { top = 1440, right = 1440, bottom = 1440, left = 1440 }
	local sp = xml.element("w:sectPr")
	if headerRid then
		sp.children[#sp.children + 1] = xml.element("w:headerReference", { ["w:type"] = "default", ["r:id"] = headerRid })
	end
	if footerRid then
		sp.children[#sp.children + 1] = xml.element("w:footerReference", { ["w:type"] = "default", ["r:id"] = footerRid })
	end
	sp.children[#sp.children + 1] = xml.element("w:pgSz", { ["w:w"] = tostring(size.w), ["w:h"] = tostring(size.h) })
	sp.children[#sp.children + 1] = xml.element("w:pgMar", {
		["w:top"] = tostring(m.top), ["w:right"] = tostring(m.right),
		["w:bottom"] = tostring(m.bottom), ["w:left"] = tostring(m.left),
	})
	-- multi-column layout (w:cols comes after pgMar in CT_SectPr order)
	local cols = section and section.properties and section.properties.columns
	if cols then
		local a = { ["w:num"] = tostring(cols.num or 1), ["w:space"] = tostring(cols.space or 708) }
		if cols.equalWidth ~= false then a["w:equalWidth"] = "1" end
		sp.children[#sp.children + 1] = xml.element("w:cols", a)
	end
	return sp
end

local function render_core_props(core)
	core = core or {}
	local root = xml.element("cp:coreProperties", {
		["xmlns:cp"] = NS_CORE, ["xmlns:dc"] = NS_DC, ["xmlns:dcterms"] = NS_DCTERMS, ["xmlns:xsi"] = NS_XSI,
	})
	local function add(tag, val)
		if val then root.children[#root.children + 1] = xml.element(tag, {}, { xml.text(val) }) end
	end
	add("dc:title", core.title)
	add("dc:creator", core.creator)
	add("cp:lastModifiedBy", core.lastModifiedBy or core.creator)
	add("dc:description", core.description)
	return root
end

local function render_app_props()
	return xml.element("Properties", { xmlns = NS_EXT }, {
		xml.element("Application", {}, { xml.text("memcontainers/docx") }),
	})
end

-- ===========================================================================
-- Document model + write
-- ===========================================================================

local Document = {}
Document.__index = Document

-- docx.new(spec?) → Document. spec.sections = { { properties?, children={block…} } },
-- or spec.children for a single default section.
function docx.new(spec)
	spec = spec or {}
	local sections = spec.sections
	if not sections then
		sections = { { children = spec.children or {} } }
	end
	return setmetatable({
		sections = sections,
		properties = spec.properties or { core = {} },
		header = spec.header,
		footer = spec.footer,
		pageNumbers = spec.pageNumbers,
	}, Document)
end

-- Document.setHeader(content) / setFooter(content): content = string | block | {block…}.
function Document.setHeader(self, content)
	self.header = content
	return self
end

function Document.setFooter(self, content)
	self.footer = content
	return self
end

-- Expand array-blocks (e.g. docx.list returns an array of paragraphs) into a flat
-- block list. Idempotent (a real block has `.kind`; an array does not).
local function flatten_blocks(blocks)
	local out = {}
	for _, b in ipairs(blocks or {}) do
		if b.kind then
			out[#out + 1] = b
		else
			for _, sub in ipairs(b) do
				out[#out + 1] = sub
			end
		end
	end
	return out
end

-- Resolve tracked changes in the model. accept → keep insertions (as plain runs),
-- drop deletions; reject → drop insertions, keep deletions. Recurses into tables.
local function resolve_revisions(blocks, accept)
	for _, block in ipairs(blocks or {}) do
		if block.kind == "table" then
			for _, row in ipairs(block.rows or {}) do
				for _, cell in ipairs(row.cells or {}) do
					resolve_revisions(cell.children, accept)
				end
			end
		elseif block.children then
			local out = {}
			for _, child in ipairs(block.children) do
				if child.kind == "insertion" or child.kind == "deletion" then
					local keep = (child.kind == "insertion") == accept
					if keep then
						for _, r in ipairs(child.children or {}) do
							out[#out + 1] = r
						end
					end
				else
					out[#out + 1] = child
				end
			end
			block.children = out
		end
	end
end

-- Document:acceptRevisions() / :rejectRevisions() rewrite the model in place so a
-- subsequent toBytes() carries no w:ins/w:del. Return self (chainable).
function Document.acceptRevisions(self)
	for _, section in ipairs(self.sections) do
		section.children = flatten_blocks(section.children)
		resolve_revisions(section.children, true)
	end
	return self
end
function Document.rejectRevisions(self)
	for _, section in ipairs(self.sections) do
		section.children = flatten_blocks(section.children)
		resolve_revisions(section.children, false)
	end
	return self
end

-- PHASE 1 — prepare: walk the inline content of every paragraph (including table
-- cells) for images / hyperlinks / footnotes / endnotes / comments / revisions /
-- bookmarks, registering media and allocating rels + ids, so render is pure.
local function prepare_blocks(blocks, ctx)
	for _, block in ipairs(blocks or {}) do
		if block.kind == "table" then
			for _, row in ipairs(block.rows or {}) do
				for _, cell in ipairs(row.cells or {}) do
					prepare_blocks(cell.children, ctx)
				end
			end
		else -- paragraph
			for _, child in ipairs(block.children or {}) do
				if child.kind == "image" then
					local entry = ctx.mediaReg.add(child.bytes)
					child._rid = ctx.docRels:add(RELT.image, "media/" .. entry.name)
					child._docId = ctx.idGen()
					if not child.width and entry.widthPx then
						child.width = entry.widthPx * media.EMU_PER_PX
						child.height = entry.heightPx * media.EMU_PER_PX
					end
				elseif child.kind == "chart" then
					ctx.charts[#ctx.charts + 1] = child
					child._rid = ctx.docRels:add(RELT.chart, "charts/chart" .. #ctx.charts .. ".xml")
					child._docId = ctx.idGen()
					child._n = #ctx.charts
				elseif child.kind == "hyperlink" then
					-- only an external link needs a rel; an internal w:anchor link does not
					if child.url then
						child._rid = ctx.docRels:add(RELT.hyperlink, child.url, "External")
					end
				elseif child.kind == "footnote" then
					ctx.footnotes[#ctx.footnotes + 1] = child
					child._id = #ctx.footnotes -- ids 1, 2, … (−1/0 reserved)
				elseif child.kind == "endnote" then
					ctx.endnotes[#ctx.endnotes + 1] = child
					child._id = #ctx.endnotes -- ids 1, 2, … (−1/0 reserved)
				elseif child.kind == "commented" then
					ctx.comments[#ctx.comments + 1] = child.comment
					child.comment._id = #ctx.comments - 1 -- ids 0, 1, …
				elseif child.kind == "insertion" or child.kind == "deletion" then
					ctx.revId += 1
					child._id = ctx.revId
				elseif child.kind == "bookmark" then
					ctx.bmId += 1
					child._id = ctx.bmId
				end
			end
		end
	end
end

function Document.toBytes(self)
	local pkg = opc.new()
	local docRels = pkg:relsFor("/word/document.xml")
	docRels:add(RELT.styles, "styles.xml")

	-- PHASE 1: allocate media/hyperlink/chart rels + footnote/comment ids.
	local mediaReg = media.registry()
	local nextId = 0
	local ctx = {
		docRels = docRels,
		mediaReg = mediaReg,
		charts = {},
		footnotes = {},
		endnotes = {},
		comments = {},
		revId = 0,
		bmId = 0,
		idGen = function()
			nextId += 1
			return nextId
		end,
	}
	-- flatten any array-blocks (docx.list) so prepare + render see plain blocks
	for _, section in ipairs(self.sections) do
		section.children = flatten_blocks(section.children)
	end
	for _, section in ipairs(self.sections) do
		prepare_blocks(section.children, ctx)
	end
	local charts = ctx.charts

	-- numbering.xml, only if a paragraph uses a list (w:numPr)
	local hasLists = false
	local function scan(blocks)
		for _, b in ipairs(blocks) do
			if b.kind == "table" then
				for _, row in ipairs(b.rows or {}) do
					for _, cell in ipairs(row.cells or {}) do
						scan(cell.children or {})
					end
				end
			elseif b.properties and b.properties.numbering then
				hasLists = true
			end
		end
	end
	for _, section in ipairs(self.sections) do
		scan(section.children)
	end
	if hasLists then
		docRels:add(RELT.numbering, "numbering.xml")
		pkg:addPart("/word/numbering.xml", doc(render_numbering()), CT.numbering)
	end

	-- footnotes.xml / endnotes.xml / comments.xml, only when referenced
	if #ctx.footnotes > 0 then
		docRels:add(RELT.footnotes, "footnotes.xml")
		pkg:addPart("/word/footnotes.xml", doc(render_notes(ctx.footnotes, "footnote")), CT.footnotes)
	end
	if #ctx.endnotes > 0 then
		docRels:add(RELT.endnotes, "endnotes.xml")
		pkg:addPart("/word/endnotes.xml", doc(render_notes(ctx.endnotes, "endnote")), CT.endnotes)
	end
	if #ctx.comments > 0 then
		docRels:add(RELT.comments, "comments.xml")
		pkg:addPart("/word/comments.xml", doc(render_comments(ctx.comments)), CT.comments)
	end

	-- header / footer parts (a footer with pageNumbers gets the PAGE field even
	-- when no footer content was supplied).
	local headerRid, footerRid
	if self.header then
		headerRid = docRels:add(RELT.header, "header1.xml")
		pkg:addPart("/word/header1.xml", doc(render_hf("w:hdr", self.header, false)), CT.header)
	end
	if self.footer or self.pageNumbers then
		footerRid = docRels:add(RELT.footer, "footer1.xml")
		pkg:addPart("/word/footer1.xml", doc(render_hf("w:ftr", self.footer or {}, self.pageNumbers)), CT.footer)
	end

	-- PHASE 2: render (pure — reads the allocated rIds).
	local body = xml.element("w:body")
	for _, section in ipairs(self.sections) do
		for _, block in ipairs(section.children or {}) do
			body.children[#body.children + 1] = render_block(block)
		end
	end
	-- the last section's sectPr is a direct child of w:body
	body.children[#body.children + 1] = render_sectPr(self.sections[#self.sections], headerRid, footerRid)
	local root = xml.element("w:document", {
		["xmlns:w"] = NS_W, ["xmlns:r"] = NS_R, ["xmlns:wp"] = NS_WP, ["xmlns:a"] = NS_A, ["xmlns:pic"] = NS_PIC,
	}, { body })

	pkg:addPart("/word/document.xml", doc(root), CT.document)
	pkg:addPart("/word/styles.xml", doc(render_styles()), CT.styles)

	-- media parts + their content-type defaults (png/jpeg/gif)
	for _, entry in ipairs(mediaReg.items) do
		pkg.contentTypes.defaults[entry.ext] = entry.contentType
		pkg:addPart("/word/media/" .. entry.name, entry.bytes)
	end

	-- chart parts + their embedded data workbooks (the chart references the
	-- embedded xlsx via c:externalData → built by reusing our own xlsx writer)
	for _, ch in ipairs(charts) do
		local chartName = "/word/charts/chart" .. ch._n .. ".xml"
		local chartRels = pkg:relsFor(chartName)
		local embedRid = chartRels:add(RELT.package, "../embeddings/workbook" .. ch._n .. ".xlsx")
		pkg:addPart(chartName, doc(chart.render(ch.model, { externalRid = embedRid })), CT.chart)
		pkg:addPart("/word/embeddings/workbook" .. ch._n .. ".xlsx", chart.embeddedWorkbook(ch.model), CT.spreadsheet)
	end

	pkg:addPart("/docProps/core.xml", doc(render_core_props(self.properties.core)), CT.core)
	pkg:addPart("/docProps/app.xml", doc(render_app_props()), CT.app)
	local rootRels = pkg:relsFor("/")
	rootRels:add(RELT.officeDocument, "word/document.xml")
	rootRels:add(RELT.core, "docProps/core.xml")
	rootRels:add(RELT.app, "docProps/app.xml")

	return opc.write(pkg)
end

function Document.save(self, path)
	local sys = sys
	return sys.fs.write(path, self:toBytes())
end

-- ===========================================================================
-- Read
-- ===========================================================================

local function child(el, lname)
	for _, c in ipairs(el.children) do
		if c.kind == "element" and c.name.local_ == lname then return c end
	end
	return nil
end
local function attr(el, lname)
	for _, a in ipairs(el.attributes) do
		if a.name.local_ == lname then return a.value end
	end
	return nil
end

-- First descendant element with local name `lname` (depth-first).
local function find_desc(el, lname)
	for _, c in ipairs(el.children or {}) do
		if c.kind == "element" then
			if c.name.local_ == lname then return c end
			local d = find_desc(c, lname)
			if d then return d end
		end
	end
	return nil
end

local function r_attr(el, lname)
	for _, a in ipairs(el.attributes) do
		if a.name.prefix == "r" and a.name.local_ == lname then return a.value end
	end
	return nil
end

local parse_table -- forward (paragraph cells ↔ table)

-- Parse a w:p into a paragraph model: pPr, then inline content (text runs / inline
-- images via w:drawing / w:hyperlink / footnote refs / commented spans). `rels`
-- resolves image r:embed + link r:id; `ctx` (optional) supplies the parsed
-- comments/footnotes parts so refs can be reconstructed into model nodes.
-- Parse a w:r → a run model, reading either w:t or (in a deletion) w:delText.
local function parse_run(r)
	local run = runXform.parse({}, r)
	run.kind = "run"
	if run.text == nil then
		local dt = child(r, "delText")
		if dt then run.text = xml.textOf(dt) end
	end
	return run
end

local function parse_paragraph(el, pkg, rels, ctx)
	-- A TOC field paragraph (a run carrying ` TOC … ` instrText) → a toc block.
	for _, c in ipairs(el.children) do
		if c.kind == "element" and c.name.local_ == "r" then
			local it = child(c, "instrText")
			if it and xml.textOf(it):find("TOC") then
				return { kind = "toc", levels = xml.textOf(it):match('\\o%s+"([^"]+)"') }
			end
		end
	end

	local para = { kind = "paragraph", children = {} }
	-- commentRangeStart/End and bookmarkStart/End wrap runs into a commented /
	-- bookmark node; one stack handles (well-nested) ranges. emit() routes into the
	-- innermost open range, else the paragraph itself.
	local stack = {}
	local function emit(item)
		local dst = (#stack > 0) and stack[#stack].buf or para.children
		dst[#dst + 1] = item
	end
	local function close_range()
		local top = table.remove(stack)
		if not top then return end
		if top.t == "bookmark" then
			emit({ kind = "bookmark", name = top.name, children = top.buf, _id = tonumber(top.id) })
		else
			local def = ctx and ctx.comments and ctx.comments[top.id]
			emit({ kind = "commented", children = top.buf, comment = def or { _id = tonumber(top.id) } })
		end
	end
	for _, c in ipairs(el.children) do
		if c.kind == "element" then
			local ln = c.name.local_
			if ln == "pPr" then
				para.properties = pPrXform.parse({}, c)
			elseif ln == "commentRangeStart" then
				stack[#stack + 1] = { t = "comment", id = attr(c, "id"), buf = {} }
			elseif ln == "bookmarkStart" then
				stack[#stack + 1] = { t = "bookmark", id = attr(c, "id"), name = attr(c, "name"), buf = {} }
			elseif ln == "commentRangeEnd" or ln == "bookmarkEnd" then
				close_range()
			elseif ln == "ins" or ln == "del" then
				local node = {
					kind = (ln == "ins") and "insertion" or "deletion",
					children = {}, _id = tonumber(attr(c, "id")),
					author = attr(c, "author"), date = attr(c, "date"),
				}
				for _, r in ipairs(c.children) do
					if r.kind == "element" and r.name.local_ == "r" then
						node.children[#node.children + 1] = parse_run(r)
					end
				end
				emit(node)
			elseif ln == "r" then
				local fnref = find_desc(c, "footnoteReference")
				local enref = find_desc(c, "endnoteReference")
				if child(c, "tab") then
					emit({ kind = "tab" })
				elseif fnref then
					local id = attr(fnref, "id")
					local def = ctx and ctx.footnotes and ctx.footnotes[id]
					emit({ kind = "footnote", _id = tonumber(id), content = def and def.content, text = def and def.text })
				elseif enref then
					local id = attr(enref, "id")
					local def = ctx and ctx.endnotes and ctx.endnotes[id]
					emit({ kind = "endnote", _id = tonumber(id), content = def and def.content, text = def and def.text })
				elseif find_desc(c, "commentReference") then
					-- the trailing reference marker run — its range was already emitted
				else
					local drawing = find_desc(c, "drawing")
					local cchart = drawing and find_desc(drawing, "chart")
					if cchart then
						-- an inline chart run: resolve the chart part → model
						local item = { kind = "chart" }
						local extent = find_desc(drawing, "extent")
						if extent then
							item.width = tonumber(attr(extent, "cx"))
							item.height = tonumber(attr(extent, "cy"))
						end
						if rels then
							local part = pkg:getPart(rels:targetOf(r_attr(cchart, "id")) or "")
							if part then
								local cd = xml.parse(part.bytes)
								if cd then item.model = chart.parse(cd.root) end
							end
						end
						emit(item)
					elseif drawing then
						local img = { kind = "image" }
						local extent = find_desc(drawing, "extent") -- wp:extent
						if extent then
							img.width = tonumber(attr(extent, "cx"))
							img.height = tonumber(attr(extent, "cy"))
						end
						local blip = find_desc(drawing, "blip")
						if blip and rels then
							local target = rels:targetOf(r_attr(blip, "embed"))
							local part = target and pkg:getPart(target)
							if part then img.bytes = part.bytes end
						end
						emit(img)
					else
						emit(parse_run(c))
					end
				end
			elseif ln == "hyperlink" then
				local hl = { kind = "hyperlink", children = {} }
				local anchor = attr(c, "anchor")
				if anchor then
					hl.anchor = anchor
				elseif rels then
					hl.url = rels:targetOf(r_attr(c, "id"))
				end
				for _, r in ipairs(c.children) do
					if r.kind == "element" and r.name.local_ == "r" then
						hl.children[#hl.children + 1] = parse_run(r)
					end
				end
				emit(hl)
			end
		end
	end
	return para
end

function parse_table(el, pkg, rels, ctx)
	local rows = {}
	for _, tr in ipairs(el.children) do
		if tr.kind == "element" and tr.name.local_ == "tr" then
			local cells = {}
			for _, tc in ipairs(tr.children) do
				if tc.kind == "element" and tc.name.local_ == "tc" then
					local blocks = {}
					for _, b in ipairs(tc.children) do
						if b.kind == "element" and b.name.local_ == "p" then
							blocks[#blocks + 1] = parse_paragraph(b, pkg, rels, ctx)
						elseif b.kind == "element" and b.name.local_ == "tbl" then
							blocks[#blocks + 1] = parse_table(b, pkg, rels, ctx)
						end
					end
					cells[#cells + 1] = { children = blocks }
				end
			end
			rows[#rows + 1] = { cells = cells }
		end
	end
	return { kind = "table", rows = rows }
end

local function parse_sectPr(el)
	local props = {}
	local pgSz = child(el, "pgSz")
	if pgSz then
		props.page = { size = { w = tonumber(attr(pgSz, "w")), h = tonumber(attr(pgSz, "h")) } }
	end
	local pgMar = child(el, "pgMar")
	if pgMar then
		props.page = props.page or {}
		props.page.margin = {
			top = tonumber(attr(pgMar, "top")), right = tonumber(attr(pgMar, "right")),
			bottom = tonumber(attr(pgMar, "bottom")), left = tonumber(attr(pgMar, "left")),
		}
	end
	local cols = child(el, "cols")
	if cols then
		local ew = attr(cols, "equalWidth")
		props.columns = {
			num = tonumber(attr(cols, "num")) or 1,
			space = tonumber(attr(cols, "space")),
			equalWidth = ew ~= "0" and ew ~= "false",
		}
	end
	return props
end

-- Parse a header/footer part (w:hdr | w:ftr) into a block list. A bare PAGE field
-- (footer page numbers) is dropped from content but flagged via the second return.
local function parse_hf(pkg, partName)
	local part = pkg:getPart(partName)
	if not part then return nil, false end
	local root = assert(xml.parse(part.bytes)).root
	local hfRels = pkg.rels[partName]
	local blocks, pageNumbers = {}, false
	for _, c in ipairs(root.children) do
		if c.kind == "element" then
			if c.name.local_ == "p" then
				if child(c, "fldSimple") and (attr(child(c, "fldSimple"), "instr") or ""):find("PAGE") then
					pageNumbers = true
				else
					blocks[#blocks + 1] = parse_paragraph(c, pkg, hfRels)
				end
			elseif c.name.local_ == "tbl" then
				blocks[#blocks + 1] = parse_table(c, pkg, hfRels)
			end
		end
	end
	return blocks, pageNumbers
end

-- The text of an element = its text runs concatenated (drops the leading
-- annotation/footnote mark, which carries no w:t). Returns clean text-run blocks.
local function parse_note_body(el, pkg, container)
	local parts, blocks = {}, {}
	for _, b in ipairs(el.children) do
		if b.kind == "element" and b.name.local_ == "p" then
			local pp = parse_paragraph(b, pkg, nil)
			local cp = { kind = "paragraph", children = {} }
			for _, r in ipairs(pp.children) do
				if r.kind == "run" and r.text ~= nil then
					cp.children[#cp.children + 1] = r
					parts[#parts + 1] = r.text
				end
			end
			blocks[#blocks + 1] = cp
		end
	end
	container.content = blocks
	container.text = table.concat(parts)
end

-- comments.xml → ({ [id]=def }, { def… }); def = { _id, author, initials, date, text }.
local function parse_comments(pkg, partName)
	local part = pkg:getPart(partName)
	if not part then return {}, {} end
	local root = assert(xml.parse(part.bytes)).root
	local byId, list = {}, {}
	for _, c in ipairs(root.children) do
		if c.kind == "element" and c.name.local_ == "comment" then
			local def = {
				_id = tonumber(attr(c, "id")),
				author = attr(c, "author"),
				initials = attr(c, "initials"),
				date = attr(c, "date"),
			}
			parse_note_body(c, pkg, def)
			byId[attr(c, "id")] = def
			list[#list + 1] = def
		end
	end
	return byId, list
end

-- footnotes.xml / endnotes.xml → ({ [id]=def }, { def… }); the reserved separator
-- notes are skipped. `which` = "footnote" | "endnote" selects the item element name.
local function parse_notes(pkg, partName, which)
	local part = pkg:getPart(partName)
	if not part then return {}, {} end
	local root = assert(xml.parse(part.bytes)).root
	local byId, list = {}, {}
	for _, c in ipairs(root.children) do
		if c.kind == "element" and c.name.local_ == which then
			local typ = attr(c, "type")
			if typ ~= "separator" and typ ~= "continuationSeparator" then
				local def = { _id = tonumber(attr(c, "id")) }
				parse_note_body(c, pkg, def)
				byId[attr(c, "id")] = def
				list[#list + 1] = def
			end
		end
	end
	return byId, list
end

-- docx.load(bytes) → Document | nil, err. Parses word/document.xml back into the
-- model (one section; runs/paragraphs/tables); unknown parts stay in the package.
function docx.load(bytes)
	local pkg, err = opc.read(bytes)
	if not pkg then return nil, err end
	if pkg:detectFormat() ~= "docx" then return nil, "docx/not-a-document" end

	local rootRels = pkg.rels[""]
	local docName
	for _, rel in ipairs(rootRels.items) do
		if rel.type == RELT.officeDocument then docName = rootRels:targetOf(rel.id) end
	end
	local docDoc = assert(xml.parse(pkg:getPart(docName).bytes))
	local docRels = pkg.rels[docName]
	local body = child(docDoc.root, "body")

	-- comments.xml / footnotes.xml / endnotes.xml (parsed first so body refs resolve)
	local ctx = { comments = {}, footnotes = {}, endnotes = {} }
	local commentList, footnoteList, endnoteList = {}, {}, {}
	for _, rel in ipairs(docRels.items) do
		if rel.type == RELT.comments then
			ctx.comments, commentList = parse_comments(pkg, docRels:targetOf(rel.id))
		elseif rel.type == RELT.footnotes then
			ctx.footnotes, footnoteList = parse_notes(pkg, docRels:targetOf(rel.id), "footnote")
		elseif rel.type == RELT.endnotes then
			ctx.endnotes, endnoteList = parse_notes(pkg, docRels:targetOf(rel.id), "endnote")
		end
	end

	local section = { children = {} }
	if body then
		for _, c in ipairs(body.children) do
			if c.kind == "element" then
				if c.name.local_ == "p" then
					section.children[#section.children + 1] = parse_paragraph(c, pkg, docRels, ctx)
				elseif c.name.local_ == "tbl" then
					section.children[#section.children + 1] = parse_table(c, pkg, docRels, ctx)
				elseif c.name.local_ == "sectPr" then
					section.properties = parse_sectPr(c)
				end
			end
		end
	end
	-- header / footer parts (read back into the model + the pageNumbers flag)
	local header, footer, pageNumbers
	for _, rel in ipairs(docRels.items) do
		if rel.type == RELT.header then
			header = parse_hf(pkg, docRels:targetOf(rel.id))
		elseif rel.type == RELT.footer then
			local blocks, hasPage = parse_hf(pkg, docRels:targetOf(rel.id))
			footer, pageNumbers = blocks, hasPage
		end
	end

	return setmetatable({
		sections = { section }, properties = { core = {} }, package = pkg,
		header = header, footer = footer, pageNumbers = pageNumbers,
		comments = commentList, footnotes = footnoteList, endnotes = endnoteList,
	}, Document)
end

function docx.open(path)
	local sys = sys
	local bytes, err = sys.fs.read(path)
	if not bytes then return nil, err end
	return docx.load(bytes)
end

return docx
