-- pptx.luau — PresentationML (.pptx) read + write (luau-extensions Ch.09 + the
-- shared DrawingML of Ch.06). PresentationML is built directly on DrawingML, so a
-- slide is a shape tree of text boxes / autoshapes. pptx has the LARGEST minimum
-- file: a slide requires a layout requires a master requires a theme. The
-- master/layout/theme are invariant Office boilerplate (a known-good minimal set,
-- validated in real PowerPoint readers); the presentation + slides are generated
-- from the model. Geometry is EMU; DrawingML font size is hundredths-of-a-point.
--
-- Built on opc + zip + xml (SYSTEMS.md section 10.3). v1 covers text boxes + preset-geometry
-- autoshapes with solid fills and styled runs; the slide→layout→master→theme chain
-- + a default theme ship so `new()` decks open. Unknown parts round-trip via opc.

local opc = require("opc")
local xml = require("xml")
local media = require("media")
local chart = require("chart")

local pptx = {}

local NS_A = "http://schemas.openxmlformats.org/drawingml/2006/main"
local NS_R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
local NS_P = "http://schemas.openxmlformats.org/presentationml/2006/main"
local NS_C = "http://schemas.openxmlformats.org/drawingml/2006/chart"
local CHART_URI = "http://schemas.openxmlformats.org/drawingml/2006/chart"
local NS_CORE = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
local NS_DC = "http://purl.org/dc/elements/1.1/"
local NS_DCTERMS = "http://purl.org/dc/terms/"
local NS_XSI = "http://www.w3.org/2001/XMLSchema-instance"
local NS_EXT = "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"

local OD = "application/vnd.openxmlformats-officedocument"
local CT = {
	presentation = OD .. ".presentationml.presentation.main+xml",
	slide = OD .. ".presentationml.slide+xml",
	slideLayout = OD .. ".presentationml.slideLayout+xml",
	slideMaster = OD .. ".presentationml.slideMaster+xml",
	notesSlide = OD .. ".presentationml.notesSlide+xml",
	comments = OD .. ".presentationml.comments+xml",
	commentAuthors = OD .. ".presentationml.commentAuthors+xml",
	theme = OD .. ".theme+xml",
	chart = OD .. ".drawingml.chart+xml",
	spreadsheet = OD .. ".spreadsheetml.sheet",
	core = "application/vnd.openxmlformats-package.core-properties+xml",
	app = OD .. ".extended-properties+xml",
}
local RELT = {
	officeDocument = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument",
	slideMaster = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster",
	slideLayout = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout",
	slide = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide",
	theme = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme",
	image = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
	hyperlink = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
	chart = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart",
	package = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/package",
	notesSlide = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide",
	comments = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments",
	commentAuthors = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/commentAuthors",
	slideRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide",
	core = "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties",
	app = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties",
}

local XMLDECL = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'

-- The slide→layout→master chain is mandatory even for one text box; the master and
-- layouts are built programmatically (render_master / render_layout), the theme is
-- written verbatim.

-- The default Office theme (clrScheme/fontScheme/fmtScheme) — required so scheme
-- colours resolve; injected at build time by this module.
local THEME_XML = XMLDECL .. [[<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme"><a:themeElements><a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F497D"/></a:dk2><a:lt2><a:srgbClr val="EEECE1"/></a:lt2><a:accent1><a:srgbClr val="4F81BD"/></a:accent1><a:accent2><a:srgbClr val="C0504D"/></a:accent2><a:accent3><a:srgbClr val="9BBB59"/></a:accent3><a:accent4><a:srgbClr val="8064A2"/></a:accent4><a:accent5><a:srgbClr val="4BACC6"/></a:accent5><a:accent6><a:srgbClr val="F79646"/></a:accent6><a:hlink><a:srgbClr val="0000FF"/></a:hlink><a:folHlink><a:srgbClr val="800080"/></a:folHlink></a:clrScheme><a:fontScheme name="Office"><a:majorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/><a:font script="Jpan" typeface="ＭＳ Ｐゴシック"/><a:font script="Hang" typeface="맑은 고딕"/><a:font script="Hans" typeface="宋体"/><a:font script="Hant" typeface="新細明體"/><a:font script="Arab" typeface="Times New Roman"/><a:font script="Hebr" typeface="Times New Roman"/><a:font script="Thai" typeface="Angsana New"/><a:font script="Ethi" typeface="Nyala"/><a:font script="Beng" typeface="Vrinda"/><a:font script="Gujr" typeface="Shruti"/><a:font script="Khmr" typeface="MoolBoran"/><a:font script="Knda" typeface="Tunga"/><a:font script="Guru" typeface="Raavi"/><a:font script="Cans" typeface="Euphemia"/><a:font script="Cher" typeface="Plantagenet Cherokee"/><a:font script="Yiii" typeface="Microsoft Yi Baiti"/><a:font script="Tibt" typeface="Microsoft Himalaya"/><a:font script="Thaa" typeface="MV Boli"/><a:font script="Deva" typeface="Mangal"/><a:font script="Telu" typeface="Gautami"/><a:font script="Taml" typeface="Latha"/><a:font script="Syrc" typeface="Estrangelo Edessa"/><a:font script="Orya" typeface="Kalinga"/><a:font script="Mlym" typeface="Kartika"/><a:font script="Laoo" typeface="DokChampa"/><a:font script="Sinh" typeface="Iskoola Pota"/><a:font script="Mong" typeface="Mongolian Baiti"/><a:font script="Viet" typeface="Times New Roman"/><a:font script="Uigh" typeface="Microsoft Uighur"/><a:font script="Geor" typeface="Sylfaen"/></a:majorFont><a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/><a:font script="Jpan" typeface="ＭＳ Ｐゴシック"/><a:font script="Hang" typeface="맑은 고딕"/><a:font script="Hans" typeface="宋体"/><a:font script="Hant" typeface="新細明體"/><a:font script="Arab" typeface="Arial"/><a:font script="Hebr" typeface="Arial"/><a:font script="Thai" typeface="Cordia New"/><a:font script="Ethi" typeface="Nyala"/><a:font script="Beng" typeface="Vrinda"/><a:font script="Gujr" typeface="Shruti"/><a:font script="Khmr" typeface="DaunPenh"/><a:font script="Knda" typeface="Tunga"/><a:font script="Guru" typeface="Raavi"/><a:font script="Cans" typeface="Euphemia"/><a:font script="Cher" typeface="Plantagenet Cherokee"/><a:font script="Yiii" typeface="Microsoft Yi Baiti"/><a:font script="Tibt" typeface="Microsoft Himalaya"/><a:font script="Thaa" typeface="MV Boli"/><a:font script="Deva" typeface="Mangal"/><a:font script="Telu" typeface="Gautami"/><a:font script="Taml" typeface="Latha"/><a:font script="Syrc" typeface="Estrangelo Edessa"/><a:font script="Orya" typeface="Kalinga"/><a:font script="Mlym" typeface="Kartika"/><a:font script="Laoo" typeface="DokChampa"/><a:font script="Sinh" typeface="Iskoola Pota"/><a:font script="Mong" typeface="Mongolian Baiti"/><a:font script="Viet" typeface="Arial"/><a:font script="Uigh" typeface="Microsoft Uighur"/><a:font script="Geor" typeface="Sylfaen"/></a:minorFont></a:fontScheme><a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:gradFill rotWithShape="1"><a:gsLst><a:gs pos="0"><a:schemeClr val="phClr"><a:tint val="50000"/><a:satMod val="300000"/></a:schemeClr></a:gs><a:gs pos="35000"><a:schemeClr val="phClr"><a:tint val="37000"/><a:satMod val="300000"/></a:schemeClr></a:gs><a:gs pos="100000"><a:schemeClr val="phClr"><a:tint val="15000"/><a:satMod val="350000"/></a:schemeClr></a:gs></a:gsLst><a:lin ang="16200000" scaled="1"/></a:gradFill><a:gradFill rotWithShape="1"><a:gsLst><a:gs pos="0"><a:schemeClr val="phClr"><a:tint val="100000"/><a:shade val="100000"/><a:satMod val="130000"/></a:schemeClr></a:gs><a:gs pos="100000"><a:schemeClr val="phClr"><a:tint val="50000"/><a:shade val="100000"/><a:satMod val="350000"/></a:schemeClr></a:gs></a:gsLst><a:lin ang="16200000" scaled="0"/></a:gradFill></a:fillStyleLst><a:lnStyleLst><a:ln w="9525" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"><a:shade val="95000"/><a:satMod val="105000"/></a:schemeClr></a:solidFill><a:prstDash val="solid"/></a:ln><a:ln w="25400" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln><a:ln w="38100" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst><a:outerShdw blurRad="40000" dist="20000" dir="5400000" rotWithShape="0"><a:srgbClr val="000000"><a:alpha val="38000"/></a:srgbClr></a:outerShdw></a:effectLst></a:effectStyle><a:effectStyle><a:effectLst><a:outerShdw blurRad="40000" dist="23000" dir="5400000" rotWithShape="0"><a:srgbClr val="000000"><a:alpha val="35000"/></a:srgbClr></a:outerShdw></a:effectLst></a:effectStyle><a:effectStyle><a:effectLst><a:outerShdw blurRad="40000" dist="23000" dir="5400000" rotWithShape="0"><a:srgbClr val="000000"><a:alpha val="35000"/></a:srgbClr></a:outerShdw></a:effectLst><a:scene3d><a:camera prst="orthographicFront"><a:rot lat="0" lon="0" rev="0"/></a:camera><a:lightRig rig="threePt" dir="t"><a:rot lat="0" lon="0" rev="1200000"/></a:lightRig></a:scene3d><a:sp3d><a:bevelT w="63500" h="25400"/></a:sp3d></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:gradFill rotWithShape="1"><a:gsLst><a:gs pos="0"><a:schemeClr val="phClr"><a:tint val="40000"/><a:satMod val="350000"/></a:schemeClr></a:gs><a:gs pos="40000"><a:schemeClr val="phClr"><a:tint val="45000"/><a:shade val="99000"/><a:satMod val="350000"/></a:schemeClr></a:gs><a:gs pos="100000"><a:schemeClr val="phClr"><a:shade val="20000"/><a:satMod val="255000"/></a:schemeClr></a:gs></a:gsLst><a:path path="circle"><a:fillToRect l="50000" t="-80000" r="50000" b="180000"/></a:path></a:gradFill><a:gradFill rotWithShape="1"><a:gsLst><a:gs pos="0"><a:schemeClr val="phClr"><a:tint val="80000"/><a:satMod val="300000"/></a:schemeClr></a:gs><a:gs pos="100000"><a:schemeClr val="phClr"><a:shade val="30000"/><a:satMod val="200000"/></a:schemeClr></a:gs></a:gsLst><a:path path="circle"><a:fillToRect l="50000" t="50000" r="50000" b="50000"/></a:path></a:gradFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults><a:spDef><a:spPr/><a:bodyPr/><a:lstStyle/><a:style><a:lnRef idx="1"><a:schemeClr val="accent1"/></a:lnRef><a:fillRef idx="3"><a:schemeClr val="accent1"/></a:fillRef><a:effectRef idx="2"><a:schemeClr val="accent1"/></a:effectRef><a:fontRef idx="minor"><a:schemeClr val="lt1"/></a:fontRef></a:style></a:spDef><a:lnDef><a:spPr/><a:bodyPr/><a:lstStyle/><a:style><a:lnRef idx="2"><a:schemeClr val="accent1"/></a:lnRef><a:fillRef idx="0"><a:schemeClr val="accent1"/></a:fillRef><a:effectRef idx="1"><a:schemeClr val="accent1"/></a:effectRef><a:fontRef idx="minor"><a:schemeClr val="tx1"/></a:fontRef></a:style></a:lnDef></a:objectDefaults><a:extraClrSchemeLst/></a:theme>]]

-- 16:9 / 4:3 slide sizes in EMU.
local SLIDE_SIZES = {
	["16:9"] = { cx = 12192000, cy = 6858000 },
	["4:3"] = { cx = 9144000, cy = 6858000 },
}
local ALIGN = { left = "l", center = "ctr", right = "r", justify = "just" }

-- The built-in slide layouts (a real master→layout chain beyond one blank layout).
-- Each maps a friendly name to its sldLayout `type`, its display name, the part
-- number it occupies (slideLayout<part>.xml), and the placeholder types/positions
-- (EMU) its `title`/`body` slots use. ORDER here = part order = LAYOUT_ORDER.
local PH_POS = {
	title = { x = 457200, y = 274638, w = 8229600, h = 1143000 },
	body = { x = 457200, y = 1600200, w = 8229600, h = 4525963 },
	ctrTitle = { x = 685800, y = 2130425, w = 7772400, h = 1470025 },
	subTitle = { x = 1371600, y = 3886200, w = 6400800, h = 1752600 },
}
local LAYOUT_ORDER = { "title", "titleAndContent", "blank" }
local LAYOUTS = {
	title = {
		name = "Title Slide", type = "title", part = 1,
		title = { type = "ctrTitle", pos = "ctrTitle" },
		body = { type = "subTitle", idx = 1, pos = "subTitle" },
	},
	titleAndContent = {
		name = "Title and Content", type = "obj", part = 2,
		title = { type = "title", pos = "title" },
		body = { type = "body", idx = 1, pos = "body" },
	},
	blank = { name = "Blank", type = "blank", part = 3 },
}
-- sldLayout `type` → our layout key (for round-tripping the layout on load).
local LAYOUT_BY_TYPE = { title = "title", obj = "titleAndContent", blank = "blank" }

local function doc(root)
	return { kind = "document", prolog = {}, root = root }
end

local function hex_of(c)
	if type(c) == "string" then
		return (c:gsub("^#", "")):upper()
	end
	return (c.value or "000000"):upper()
end

-- ===========================================================================
-- Shape + text-body rendering (DrawingML)
-- ===========================================================================

-- a:rPr for one run (size is hundredths-of-a-point), falling back to shape defaults.
local function make_rpr(run, shape)
	local rPr = xml.element("a:rPr", { lang = "en-US" })
	local size = run.size or shape.fontSize
	if size then rPr.attributes[#rPr.attributes + 1] = { name = xml.name("sz"), value = tostring(math.floor(size * 100)) } end
	if run.bold or shape.bold then rPr.attributes[#rPr.attributes + 1] = { name = xml.name("b"), value = "1" } end
	if run.italic then rPr.attributes[#rPr.attributes + 1] = { name = xml.name("i"), value = "1" } end
	local color = run.color or shape.color
	if color then
		rPr.children[#rPr.children + 1] = xml.element("a:solidFill", {}, { xml.element("a:srgbClr", { val = hex_of(color) }) })
	end
	local linkRid = run._linkRid or shape._linkRid
	if linkRid then
		rPr.children[#rPr.children + 1] = xml.element("a:hlinkClick", { ["r:id"] = linkRid })
	end
	return rPr
end

-- One a:p: optional a:pPr (alignment, list level, bullet — buChar / buAutoNum /
-- buNone) then the runs.
local function render_para(para, shape)
	local p = xml.element("a:p")
	local attrs = {}
	local algn = para.align or shape.align
	if algn then attrs.algn = ALIGN[algn] or "l" end
	if para.level then attrs.lvl = tostring(para.level) end
	local bu
	if para.bullet == false then
		bu = xml.element("a:buNone")
	elseif para.numbered then
		bu = xml.element("a:buAutoNum", { type = "arabicPeriod" })
	elseif para.bullet then
		bu = xml.element("a:buChar", { char = (type(para.bullet) == "string" and para.bullet) or "\226\128\162" })
	end
	if next(attrs) ~= nil or bu then
		local pPr = xml.element("a:pPr", attrs)
		if bu then pPr.children[1] = bu end
		p.children[#p.children + 1] = pPr
	end
	local runs = para.runs or { { text = para.text or "" } }
	for _, run in ipairs(runs) do
		p.children[#p.children + 1] = xml.element("a:r", {}, { make_rpr(run, shape), xml.element("a:t", {}, { xml.text(run.text or "") }) })
	end
	return p
end

-- a:txBody — a list of paragraphs (shape.paragraphs) or a single text/runs body.
local function render_txbody(shape)
	local tb = xml.element("p:txBody", {}, { xml.element("a:bodyPr"), xml.element("a:lstStyle") })
	if shape.paragraphs then
		for _, para in ipairs(shape.paragraphs) do
			tb.children[#tb.children + 1] = render_para(para, shape)
		end
	else
		-- a single paragraph from shape.runs, or shape.text as one run
		tb.children[#tb.children + 1] = render_para({ runs = shape.runs or { { text = shape.text or "" } } }, shape)
	end
	return tb
end

-- A picture (p:pic) referencing a media part by the rId allocated in prepare.
local function render_pic(shape, id)
	return xml.element("p:pic", {}, {
		xml.element("p:nvPicPr", {}, {
			xml.element("p:cNvPr", { id = tostring(id), name = "Picture " .. id }),
			xml.element("p:cNvPicPr"),
			xml.element("p:nvPr"),
		}),
		xml.element("p:blipFill", {}, {
			xml.element("a:blip", { ["r:embed"] = shape._rid }),
			xml.element("a:stretch", {}, { xml.element("a:fillRect") }),
		}),
		xml.element("p:spPr", {}, {
			xml.element("a:xfrm", {}, {
				xml.element("a:off", { x = tostring(shape.x or 0), y = tostring(shape.y or 0) }),
				xml.element("a:ext", { cx = tostring(shape.w or 914400), cy = tostring(shape.h or 914400) }),
			}),
			xml.element("a:prstGeom", { prst = "rect" }, { xml.element("a:avLst") }),
		}),
	})
end

-- A chart (p:graphicFrame referencing the chart part by the rId from prepare).
local function render_chart_frame(shape, id)
	return xml.element("p:graphicFrame", {}, {
		xml.element("p:nvGraphicFramePr", {}, {
			xml.element("p:cNvPr", { id = tostring(id), name = "Chart " .. id }),
			xml.element("p:cNvGraphicFramePr"),
			xml.element("p:nvPr"),
		}),
		xml.element("p:xfrm", {}, {
			xml.element("a:off", { x = tostring(shape.x or 0), y = tostring(shape.y or 0) }),
			xml.element("a:ext", { cx = tostring(shape.w or 5486400), cy = tostring(shape.h or 3200400) }),
		}),
		xml.element("a:graphic", {}, {
			xml.element("a:graphicData", { uri = CHART_URI }, {
				xml.element("c:chart", { ["xmlns:c"] = NS_C, ["xmlns:r"] = NS_R, ["r:id"] = shape._chartRid }),
			}),
		}),
	})
end

-- Shape geometry: a preset (a:prstGeom, with optional adjustment handles in a:avLst)
-- or a freeform custom path (a:custGeom). `shape.adjustments` is an array; each entry
-- is a number (→ "adj1", "adj2", …) or { name=, value= }. `shape.geometry` =
-- { w, h, commands = { {op="moveTo"|"lnTo", x, y} | {op="cubicBezTo", pts={…}} |
-- {op="close"} … } }.
local function render_geometry(shape)
	if shape.geometry then
		local g = shape.geometry
		local path = xml.element("a:path", { w = tostring(g.w or shape.w or 0), h = tostring(g.h or shape.h or 0) })
		for _, cmd in ipairs(g.commands or {}) do
			if cmd.op == "moveTo" then
				path.children[#path.children + 1] = xml.element("a:moveTo", {}, { xml.element("a:pt", { x = tostring(cmd.x), y = tostring(cmd.y) }) })
			elseif cmd.op == "lnTo" then
				path.children[#path.children + 1] = xml.element("a:lnTo", {}, { xml.element("a:pt", { x = tostring(cmd.x), y = tostring(cmd.y) }) })
			elseif cmd.op == "cubicBezTo" then
				local e = xml.element("a:cubicBezTo")
				for _, pt in ipairs(cmd.pts or {}) do
					e.children[#e.children + 1] = xml.element("a:pt", { x = tostring(pt.x), y = tostring(pt.y) })
				end
				path.children[#path.children + 1] = e
			elseif cmd.op == "close" then
				path.children[#path.children + 1] = xml.element("a:close")
			end
		end
		return xml.element("a:custGeom", {}, {
			xml.element("a:avLst"), xml.element("a:gdLst"), xml.element("a:ahLst"),
			xml.element("a:rect", { l = "0", t = "0", r = tostring(g.w or 0), b = tostring(g.h or 0) }),
			xml.element("a:pathLst", {}, { path }),
		})
	end
	-- Adjustment guide names follow the OOXML preset convention: a single-handle
	-- preset (e.g. roundRect) names it "adj"; multi-handle presets use adj1, adj2, …
	-- (override per entry with the { name=, value= } form).
	local avLst = xml.element("a:avLst")
	local n = #(shape.adjustments or {})
	for i, a in ipairs(shape.adjustments or {}) do
		local name, val
		if type(a) == "table" then
			name, val = a.name, a.value
		else
			name, val = (n == 1 and "adj" or ("adj" .. i)), a
		end
		avLst.children[#avLst.children + 1] = xml.element("a:gd", { name = name, fmla = "val " .. tostring(val) })
	end
	return xml.element("a:prstGeom", { prst = shape.preset or "rect" }, { avLst })
end

-- A slide background (p:bg): a solid colour or a stretched picture.
local function render_background(bg)
	local bgPr = xml.element("p:bgPr")
	if bg.image then
		bgPr.children[#bgPr.children + 1] = xml.element("a:blipFill", {}, {
			xml.element("a:blip", { ["r:embed"] = bg._rid }),
			xml.element("a:stretch", {}, { xml.element("a:fillRect") }),
		})
	else
		bgPr.children[#bgPr.children + 1] =
			xml.element("a:solidFill", {}, { xml.element("a:srgbClr", { val = hex_of(bg.color or "FFFFFF") }) })
	end
	bgPr.children[#bgPr.children + 1] = xml.element("a:effectLst")
	return xml.element("p:bg", {}, { bgPr })
end

local render_table_frame -- forward (defined just below; used by the dispatch here)

local function render_shape(shape, id)
	if shape.kind == "image" then
		return render_pic(shape, id)
	elseif shape.kind == "chart" then
		return render_chart_frame(shape, id)
	elseif shape.kind == "table" then
		return render_table_frame(shape, id)
	end
	local cNvSpPr = xml.element("p:cNvSpPr")
	if shape.kind == "textbox" then
		cNvSpPr.attributes[1] = { name = xml.name("txBox"), value = "1" }
	end
	-- a placeholder shape carries p:nvPr > p:ph (type + optional idx)
	local nvPr = xml.element("p:nvPr")
	if shape.placeholder then
		local phAttrs = {}
		if shape.placeholder.type then phAttrs.type = shape.placeholder.type end
		if shape.placeholder.idx then phAttrs.idx = tostring(shape.placeholder.idx) end
		nvPr.children[1] = xml.element("p:ph", phAttrs)
	end
	local sp = xml.element("p:sp", {}, {
		xml.element("p:nvSpPr", {}, {
			xml.element("p:cNvPr", { id = tostring(id), name = shape.name or ("Shape " .. id) }),
			cNvSpPr,
			nvPr,
		}),
	})

	-- a:xfrm with optional rotation (degrees → 60000ths, clockwise)
	local xfrmAttrs = {}
	if shape.rotation then xfrmAttrs.rot = tostring(math.floor((shape.rotation % 360) * 60000)) end
	local spPr = xml.element("p:spPr", {}, {
		xml.element("a:xfrm", xfrmAttrs, {
			xml.element("a:off", { x = tostring(shape.x or 0), y = tostring(shape.y or 0) }),
			xml.element("a:ext", { cx = tostring(shape.w or 1828800), cy = tostring(shape.h or 1828800) }),
		}),
		render_geometry(shape),
	})
	-- solid fill, with optional transparency (fillAlpha 0..100 → a:alpha 1000ths)
	if shape.fill then
		local clr = xml.element("a:srgbClr", { val = hex_of(shape.fill) })
		if shape.fillAlpha then
			clr.children[1] = xml.element("a:alpha", { val = tostring(math.floor(shape.fillAlpha * 1000)) })
		end
		spPr.children[#spPr.children + 1] = xml.element("a:solidFill", {}, { clr })
	end
	-- outline: a:ln (width EMU, color, dash)
	if shape.line then
		local ln = xml.element("a:ln")
		if shape.line.width then ln.attributes[1] = { name = xml.name("w"), value = tostring(shape.line.width) } end
		if shape.line.color then
			ln.children[#ln.children + 1] = xml.element("a:solidFill", {}, { xml.element("a:srgbClr", { val = hex_of(shape.line.color) }) })
		end
		if shape.line.dash then ln.children[#ln.children + 1] = xml.element("a:prstDash", { val = shape.line.dash }) end
		spPr.children[#spPr.children + 1] = ln
	end
	-- shadow: a:effectLst > a:outerShdw
	if shape.shadow then
		spPr.children[#spPr.children + 1] = xml.element("a:effectLst", {}, {
			xml.element("a:outerShdw", { blurRad = "40000", dist = "20000", dir = "5400000", rotWithShape = "0" }, {
				xml.element("a:srgbClr", { val = "000000" }, { xml.element("a:alpha", { val = "40000" }) }),
			}),
		})
	end
	sp.children[#sp.children + 1] = spPr
	sp.children[#sp.children + 1] = render_txbody(shape)
	return sp
end

-- A table (p:graphicFrame holding an a:tbl). `rows` is an array of rows, each an
-- array of cells (a string or { text=… }).
function render_table_frame(shape, id)
	local rows = shape.rows
	local ncols = 0
	for _, r in ipairs(rows) do
		ncols = math.max(ncols, #r)
	end
	local tbl = xml.element("a:tbl", {}, {
		xml.element("a:tblPr", { firstRow = "1", bandRow = "1" }, {
			xml.element("a:tableStyleId", {}, { xml.text("{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}") }),
		}),
	})
	local grid = xml.element("a:tblGrid")
	local colW = (shape.w or 5486400) // math.max(1, ncols)
	for _ = 1, ncols do
		grid.children[#grid.children + 1] = xml.element("a:gridCol", { w = tostring(colW) })
	end
	tbl.children[#tbl.children + 1] = grid
	for _, row in ipairs(rows) do
		local tr = xml.element("a:tr", { h = "370840" })
		for ci = 1, ncols do
			local cell = row[ci]
			local text = (type(cell) == "table") and (cell.text or "") or (cell or "")
			tr.children[#tr.children + 1] = xml.element("a:tc", {}, {
				xml.element("a:txBody", {}, {
					xml.element("a:bodyPr"),
					xml.element("a:lstStyle"),
					xml.element("a:p", {}, { xml.element("a:r", {}, {
						xml.element("a:rPr", { lang = "en-US" }),
						xml.element("a:t", {}, { xml.text(text) }),
					}) }),
				}),
				xml.element("a:tcPr"),
			})
		end
		tbl.children[#tbl.children + 1] = tr
	end
	return xml.element("p:graphicFrame", {}, {
		xml.element("p:nvGraphicFramePr", {}, {
			xml.element("p:cNvPr", { id = tostring(id), name = "Table " .. id }),
			xml.element("p:cNvGraphicFramePr"),
			xml.element("p:nvPr"),
		}),
		xml.element("p:xfrm", {}, {
			xml.element("a:off", { x = tostring(shape.x or 0), y = tostring(shape.y or 0) }),
			xml.element("a:ext", { cx = tostring(shape.w or 5486400), cy = tostring(shape.h or 1828800) }),
		}),
		xml.element("a:graphic", {}, {
			xml.element("a:graphicData", { uri = "http://schemas.openxmlformats.org/drawingml/2006/table" }, { tbl }),
		}),
	})
end

-- A notesSlide part carrying the speaker notes in its body placeholder.
local function render_notes_slide(text)
	return xml.element("p:notes", { ["xmlns:a"] = NS_A, ["xmlns:r"] = NS_R, ["xmlns:p"] = NS_P }, {
		xml.element("p:cSld", {}, {
			xml.element("p:spTree", {}, {
				xml.element("p:nvGrpSpPr", {}, {
					xml.element("p:cNvPr", { id = "1", name = "" }),
					xml.element("p:cNvGrpSpPr"),
					xml.element("p:nvPr"),
				}),
				xml.element("p:grpSpPr"),
				xml.element("p:sp", {}, {
					xml.element("p:nvSpPr", {}, {
						xml.element("p:cNvPr", { id = "2", name = "Notes Placeholder 1" }),
						xml.element("p:cNvSpPr", {}, { xml.element("a:spLocks", { noGrp = "1" }) }),
						xml.element("p:nvPr", {}, { xml.element("p:ph", { type = "body", idx = "1" }) }),
					}),
					xml.element("p:spPr"),
					xml.element("p:txBody", {}, {
						xml.element("a:bodyPr"),
						xml.element("a:lstStyle"),
						xml.element("a:p", {}, { xml.element("a:r", {}, {
							xml.element("a:rPr", { lang = "en-US" }),
							xml.element("a:t", {}, { xml.text(text) }),
						}) }),
					}),
				}),
			}),
		}),
	})
end

-- commentAuthors.xml — the deck-wide author list (deduped; id = index-1).
local function render_comment_authors(authors)
	local root = xml.element("p:cmAuthorLst", { ["xmlns:a"] = NS_A, ["xmlns:r"] = NS_R, ["xmlns:p"] = NS_P })
	for i, a in ipairs(authors) do
		root.children[#root.children + 1] = xml.element("p:cmAuthor", {
			id = tostring(i - 1), name = a.name, initials = a.initials or "",
			lastIdx = tostring(a.lastIdx or 1), clrIdx = tostring(i - 1),
		})
	end
	return root
end

-- commentN.xml — one slide's comments (authorId → the deck author index; idx is the
-- author's running comment index, assigned in prepare; p:pos is the anchor).
local function render_slide_comments(comments, authorIds)
	local root = xml.element("p:cmLst", { ["xmlns:a"] = NS_A, ["xmlns:r"] = NS_R, ["xmlns:p"] = NS_P })
	for i, cm in ipairs(comments) do
		local attrs = { authorId = tostring(authorIds[cm.author] or 0), idx = tostring(cm._idx or i) }
		if cm.date then attrs.dt = cm.date end
		root.children[#root.children + 1] = xml.element("p:cm", attrs, {
			xml.element("p:pos", { x = tostring(cm.x or 0), y = tostring(cm.y or 0) }),
			xml.element("p:text", {}, { xml.text(cm.text or "") }),
		})
	end
	return root
end

local function render_slide(slide)
	local tree = xml.element("p:spTree", {}, {
		xml.element("p:nvGrpSpPr", {}, {
			xml.element("p:cNvPr", { id = "1", name = "" }),
			xml.element("p:cNvGrpSpPr"),
			xml.element("p:nvPr"),
		}),
		xml.element("p:grpSpPr"),
	})
	local id = 2
	for _, shape in ipairs(slide.shapes) do
		tree.children[#tree.children + 1] = render_shape(shape, id)
		id += 1
	end
	-- p:bg (if any) precedes p:spTree in p:cSld
	local cSld = xml.element("p:cSld")
	if slide.background then
		cSld.children[#cSld.children + 1] = render_background(slide.background)
	end
	cSld.children[#cSld.children + 1] = tree
	return xml.element("p:sld", { ["xmlns:a"] = NS_A, ["xmlns:r"] = NS_R, ["xmlns:p"] = NS_P }, {
		cSld,
		xml.element("p:clrMapOvr", {}, { xml.element("a:masterClrMapping") }),
	})
end

-- A placeholder shape for a master/layout spTree: identifies the slot (type + idx)
-- and its inherited geometry; carries an empty text body.
local function layout_ph_sp(id, name, phType, phIdx, pos)
	local phAttrs = {}
	if phType then phAttrs.type = phType end
	if phIdx then phAttrs.idx = tostring(phIdx) end
	local spPr = xml.element("p:spPr")
	if pos then
		spPr.children[1] = xml.element("a:xfrm", {}, {
			xml.element("a:off", { x = tostring(pos.x), y = tostring(pos.y) }),
			xml.element("a:ext", { cx = tostring(pos.w), cy = tostring(pos.h) }),
		})
	end
	return xml.element("p:sp", {}, {
		xml.element("p:nvSpPr", {}, {
			xml.element("p:cNvPr", { id = tostring(id), name = name }),
			xml.element("p:cNvSpPr", {}, { xml.element("a:spLocks", { noGrp = "1" }) }),
			xml.element("p:nvPr", {}, { xml.element("p:ph", phAttrs) }),
		}),
		spPr,
		xml.element("p:txBody", {}, { xml.element("a:bodyPr"), xml.element("a:lstStyle"), xml.element("a:p") }),
	})
end

local CLR_MAP = {
	bg1 = "lt1", tx1 = "dk1", bg2 = "lt2", tx2 = "dk2",
	accent1 = "accent1", accent2 = "accent2", accent3 = "accent3",
	accent4 = "accent4", accent5 = "accent5", accent6 = "accent6",
	hlink = "hlink", folHlink = "folHlink",
}

-- The slide master: title + body placeholders (default geometry), the colour map,
-- and the layout-id list (one entry per built-in layout, referencing each layout's
-- rId, supplied by the writer).
local function render_master(layoutRids)
	local tree = xml.element("p:spTree", {}, {
		xml.element("p:nvGrpSpPr", {}, {
			xml.element("p:cNvPr", { id = "1", name = "" }),
			xml.element("p:cNvGrpSpPr"), xml.element("p:nvPr"),
		}),
		xml.element("p:grpSpPr"),
		layout_ph_sp(2, "Title Placeholder 1", "title", nil, PH_POS.title),
		layout_ph_sp(3, "Text Placeholder 2", "body", 1, PH_POS.body),
	})
	local lst = xml.element("p:sldLayoutIdLst")
	for i, key in ipairs(LAYOUT_ORDER) do
		lst.children[#lst.children + 1] =
			xml.element("p:sldLayoutId", { id = tostring(2147483649 + i - 1), ["r:id"] = layoutRids[key] })
	end
	return xml.element("p:sldMaster", { ["xmlns:a"] = NS_A, ["xmlns:r"] = NS_R, ["xmlns:p"] = NS_P }, {
		xml.element("p:cSld", {}, { tree }),
		xml.element("p:clrMap", CLR_MAP),
		lst,
	})
end

-- One slide layout: its placeholder slots (per the layout spec) + colour-map override.
local function render_layout(spec)
	local tree = xml.element("p:spTree", {}, {
		xml.element("p:nvGrpSpPr", {}, {
			xml.element("p:cNvPr", { id = "1", name = "" }),
			xml.element("p:cNvGrpSpPr"), xml.element("p:nvPr"),
		}),
		xml.element("p:grpSpPr"),
	})
	local id = 2
	if spec.title then
		tree.children[#tree.children + 1] = layout_ph_sp(id, "Title " .. id, spec.title.type, spec.title.idx, PH_POS[spec.title.pos])
		id += 1
	end
	if spec.body then
		tree.children[#tree.children + 1] = layout_ph_sp(id, "Placeholder " .. id, spec.body.type, spec.body.idx, PH_POS[spec.body.pos])
		id += 1
	end
	return xml.element("p:sldLayout", { ["xmlns:a"] = NS_A, ["xmlns:r"] = NS_R, ["xmlns:p"] = NS_P, type = spec.type, preserve = "1" }, {
		xml.element("p:cSld", { name = spec.name }, { tree }),
		xml.element("p:clrMapOvr", {}, { xml.element("a:masterClrMapping") }),
	})
end

-- ===========================================================================
-- Model + builders
-- ===========================================================================

local Presentation = {}
Presentation.__index = Presentation
local Slide = {}
Slide.__index = Slide

-- pptx.new(spec?) → Presentation. spec.slideSize = "16:9" | "4:3" | {cx,cy}.
function pptx.new(spec)
	spec = spec or {}
	local size = spec.slideSize or "4:3"
	if type(size) == "string" then size = SLIDE_SIZES[size] or SLIDE_SIZES["4:3"] end
	return setmetatable({
		slides = {},
		slideSize = size,
		properties = spec.properties or { core = {} },
	}, Presentation)
end

-- addSlide(opts?) → Slide (appended). opts.layout selects a slide layout
-- ("title" | "titleAndContent" | "blank"; default "blank").
function Presentation.addSlide(self, opts)
	opts = opts or {}
	local slide = setmetatable({ shapes = {}, layout = opts.layout or "blank" }, Slide)
	self.slides[#self.slides + 1] = slide
	return slide
end

-- Deep copy of a plain-data table (the shape/slide model holds no functions).
local function deep_copy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, val in pairs(v) do
		out[k] = deep_copy(val)
	end
	return out
end

-- duplicateSlide(i) → a deep copy of slide i, inserted right after it. Returns the
-- new Slide. Transient rIds (assigned at save) are not carried over meaningfully —
-- toBytes reassigns them.
function Presentation.duplicateSlide(self, i)
	local src = self.slides[i]
	if not src then error("pptx: duplicateSlide index out of range: " .. tostring(i)) end
	local copy = setmetatable(deep_copy(src), Slide)
	table.insert(self.slides, i + 1, copy)
	return copy
end

-- moveSlide(from, to) — reorder a slide (1-based positions). Returns self.
function Presentation.moveSlide(self, from, to)
	local s = table.remove(self.slides, from)
	if not s then error("pptx: moveSlide from out of range: " .. tostring(from)) end
	to = math.max(1, math.min(to, #self.slides + 1))
	table.insert(self.slides, to, s)
	return self
end

-- removeSlide(i) — delete slide i. Returns the removed Slide.
function Presentation.removeSlide(self, i)
	return table.remove(self.slides, i)
end

-- addText(text, opts?) → the shape. opts: x/y/w/h (EMU), fontSize (pt), bold,
-- color, align ("left"|"center"|"right"), `link` (URL → the text hyperlinks),
-- `runs` for mixed formatting, or `paragraphs` ({ {text/runs, bullet?, numbered?,
-- level?, align?}… }) for multi-paragraph bodies / bullet lists.
function Slide.addText(self, text, opts)
	opts = opts or {}
	local shape = {
		kind = "textbox",
		text = text,
		runs = opts.runs,
		paragraphs = opts.paragraphs,
		link = opts.link,
		x = opts.x, y = opts.y, w = opts.w, h = opts.h,
		fontSize = opts.fontSize, bold = opts.bold, color = opts.color, align = opts.align,
	}
	self.shapes[#self.shapes + 1] = shape
	return shape
end

-- addBullets(items, opts?) → a text box of bulleted paragraphs. `items` is an
-- array of strings or { text=…, level=…, numbered=… }.
function Slide.addBullets(self, items, opts)
	opts = opts or {}
	local paras = {}
	for _, it in ipairs(items) do
		if type(it) == "string" then
			paras[#paras + 1] = { text = it, bullet = not opts.numbered, numbered = opts.numbered }
		else
			paras[#paras + 1] = {
				text = it.text, level = it.level,
				bullet = (it.numbered or opts.numbered) and nil or true,
				numbered = it.numbered or opts.numbered,
			}
		end
	end
	return self:addText(nil, { paragraphs = paras, x = opts.x, y = opts.y, w = opts.w, h = opts.h,
		fontSize = opts.fontSize, color = opts.color })
end

-- addTable(rows, opts?) → a table shape. `rows` is an array of rows, each an array
-- of cells (strings or { text=… }). opts: x/y/w/h (EMU).
function Slide.addTable(self, rows, opts)
	opts = opts or {}
	local shape = { kind = "table", rows = rows, x = opts.x, y = opts.y, w = opts.w, h = opts.h }
	self.shapes[#self.shapes + 1] = shape
	return shape
end

-- setNotes(text) — speaker notes for the slide (a notesSlide part on save).
function Slide.setNotes(self, text)
	self.notes = text
	return self
end

-- addImage(bytes, opts?) → an image shape. opts: x/y (EMU), w/h (EMU; auto-sized
-- from the image's intrinsic pixels @96dpi when omitted). PNG/JPEG/GIF.
function Slide.addImage(self, bytes, opts)
	opts = opts or {}
	local shape = {
		kind = "image",
		bytes = bytes,
		x = opts.x, y = opts.y, w = opts.w, h = opts.h,
	}
	self.shapes[#self.shapes + 1] = shape
	return shape
end

-- addChart(model, opts?) → a chart shape. model = { type="col"|"bar"|"line"|"pie",
-- title?, categories={…}, series={ {name,values}… } }. opts: x/y/w/h (EMU). The
-- chart's data is generated into an embedded workbook on save.
function Slide.addChart(self, model, opts)
	opts = opts or {}
	local shape = {
		kind = "chart",
		model = model,
		x = opts.x, y = opts.y, w = opts.w, h = opts.h,
	}
	self.shapes[#self.shapes + 1] = shape
	return shape
end

-- addShape(preset, opts?) → the shape. preset is a DrawingML geometry ("rect",
-- "roundRect", "ellipse", …). opts as addText, plus: `fill` (a color), `fillAlpha`
-- (0..100 transparency), `line` ({ width=EMU, color, dash="dash"|"dot"|… }),
-- `shadow` (true), `rotation` (degrees, clockwise).
function Slide.addShape(self, preset, opts)
	opts = opts or {}
	local shape = {
		kind = "shape",
		preset = preset,
		text = opts.text,
		runs = opts.runs,
		x = opts.x, y = opts.y, w = opts.w, h = opts.h,
		fill = opts.fill, fillAlpha = opts.fillAlpha, line = opts.line, shadow = opts.shadow,
		rotation = opts.rotation, adjustments = opts.adjustments, geometry = opts.geometry,
		fontSize = opts.fontSize, bold = opts.bold, color = opts.color, align = opts.align,
	}
	self.shapes[#self.shapes + 1] = shape
	return shape
end

-- addFreeform(geometry, opts?) → a custom-geometry shape (convenience over addShape).
-- geometry = { w, h, commands = { … } } (see render_geometry).
function Slide.addFreeform(self, geometry, opts)
	opts = opts or {}
	opts.geometry = geometry
	return self:addShape(nil, opts)
end

-- setBackground(spec) — a slide background. spec is a colour string/table (solid
-- fill) or { color = … } / { image = <bytes> } (a stretched picture).
function Slide.setBackground(self, spec)
	if type(spec) == "string" then
		self.background = { color = spec }
	else
		self.background = spec
	end
	return self
end

-- addComment(text, opts?) — a comment anchored on the slide. opts: author, initials,
-- date (ISO), x/y (EMU anchor). Authors are de-duplicated across the deck on save.
function Slide.addComment(self, text, opts)
	opts = opts or {}
	self.comments = self.comments or {}
	self.comments[#self.comments + 1] = {
		text = text, author = opts.author or "Author", initials = opts.initials,
		date = opts.date, x = opts.x, y = opts.y,
	}
	return self.comments[#self.comments]
end

-- setTitle(text, opts?) — fill the slide layout's title placeholder. Errors if the
-- layout has no title slot (e.g. "blank").
function Slide.setTitle(self, text, opts)
	opts = opts or {}
	local slot = (LAYOUTS[self.layout] or LAYOUTS.blank).title
	if not slot then error("pptx: layout '" .. tostring(self.layout) .. "' has no title placeholder") end
	local pos = PH_POS[slot.pos]
	local shape = {
		kind = "placeholder", placeholder = { type = slot.type, idx = slot.idx },
		text = text, runs = opts.runs,
		x = pos.x, y = pos.y, w = pos.w, h = pos.h,
		fontSize = opts.fontSize, bold = opts.bold, color = opts.color, align = opts.align,
	}
	self.shapes[#self.shapes + 1] = shape
	return shape
end

-- setBody(content, opts?) — fill the layout's body/subtitle placeholder. `content`
-- is a string or an array (bulleted paragraphs; items are strings or { text, level,
-- numbered }). opts.numbered makes a numbered list.
function Slide.setBody(self, content, opts)
	opts = opts or {}
	local slot = (LAYOUTS[self.layout] or LAYOUTS.blank).body
	if not slot then error("pptx: layout '" .. tostring(self.layout) .. "' has no body placeholder") end
	local pos = PH_POS[slot.pos]
	local shape = {
		kind = "placeholder", placeholder = { type = slot.type, idx = slot.idx },
		x = pos.x, y = pos.y, w = pos.w, h = pos.h,
		fontSize = opts.fontSize, color = opts.color,
	}
	if type(content) == "table" then
		local paras = {}
		for _, it in ipairs(content) do
			if type(it) == "string" then
				paras[#paras + 1] = { text = it, bullet = not opts.numbered, numbered = opts.numbered }
			else
				paras[#paras + 1] = {
					text = it.text, level = it.level,
					bullet = (it.numbered or opts.numbered) and nil or true,
					numbered = it.numbered or opts.numbered,
				}
			end
		end
		shape.paragraphs = paras
	else
		shape.text = content
	end
	self.shapes[#self.shapes + 1] = shape
	return shape
end

-- placeholder(type) → the first placeholder shape of the given ph type
-- ("title"/"ctrTitle"/"body"/"subTitle"), or nil.
function Slide.placeholder(self, phType)
	for _, sh in ipairs(self.shapes) do
		if sh.placeholder and sh.placeholder.type == phType then return sh end
	end
	return nil
end

-- ===========================================================================
-- Write
-- ===========================================================================

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
	return root
end

local function render_app_props()
	return xml.element("Properties", { xmlns = NS_EXT }, {
		xml.element("Application", {}, { xml.text("memcontainers/pptx") }),
	})
end

function Presentation.toBytes(self)
	local pkg = opc.new()

	-- theme (verbatim) + master + the built-in layouts (each its own part, all listed
	-- in the master's sldLayoutIdLst)
	pkg:addPart("/ppt/theme/theme1.xml", THEME_XML, CT.theme)
	local masterRels = pkg:relsFor("/ppt/slideMasters/slideMaster1.xml")
	local layoutRids = {}
	for _, key in ipairs(LAYOUT_ORDER) do
		local n = LAYOUTS[key].part
		local lname = "/ppt/slideLayouts/slideLayout" .. n .. ".xml"
		pkg:addPart(lname, doc(render_layout(LAYOUTS[key])), CT.slideLayout)
		pkg:relsFor(lname):add(RELT.slideMaster, "../slideMasters/slideMaster1.xml")
		layoutRids[key] = masterRels:add(RELT.slideLayout, "../slideLayouts/slideLayout" .. n .. ".xml")
	end
	masterRels:add(RELT.theme, "../theme/theme1.xml")
	pkg:addPart("/ppt/slideMasters/slideMaster1.xml", doc(render_master(layoutRids)), CT.slideMaster)

	-- presentation rels: master (rId1), theme (rId2), then slides (rId3…)
	local presRels = pkg:relsFor("/ppt/presentation.xml")
	local masterRid = presRels:add(RELT.slideMaster, "slideMasters/slideMaster1.xml")
	presRels:add(RELT.theme, "theme/theme1.xml")
	local mediaReg = media.registry() -- content-addressed, shared across slides
	local nChart = 0 -- chart/embedding counter across the deck

	-- comment authors, deduped across the deck; each comment gets its per-author idx
	local authorIds, authorList, authorNext = {}, {}, {}
	for _, slide in ipairs(self.slides) do
		for _, cm in ipairs(slide.comments or {}) do
			if authorIds[cm.author] == nil then
				authorIds[cm.author] = #authorList
				authorList[#authorList + 1] = { name = cm.author, initials = cm.initials, lastIdx = 0 }
				authorNext[cm.author] = 0
			end
			authorNext[cm.author] += 1
			cm._idx = authorNext[cm.author]
			authorList[authorIds[cm.author] + 1].lastIdx = authorNext[cm.author]
		end
	end

	local slideRids = {}
	for i, slide in ipairs(self.slides) do
		local target = "slides/slide" .. i .. ".xml"
		slideRids[i] = presRels:add(RELT.slide, target)
		local slideName = "/ppt/slides/slide" .. i .. ".xml"
		local slideRels = pkg:relsFor(slideName)
		local layoutPart = (LAYOUTS[slide.layout] or LAYOUTS.blank).part
		slideRels:add(RELT.slideLayout, "../slideLayouts/slideLayout" .. layoutPart .. ".xml")

		-- PHASE 1 — prepare each shape: register media + allocate image/hyperlink/
		-- chart rels (and build the chart's part + embedded workbook), annotating
		-- the shape with the rIds the pure render will read.
		for _, shape in ipairs(slide.shapes) do
			if shape.kind == "image" then
				local entry = mediaReg.add(shape.bytes)
				shape._rid = slideRels:add(RELT.image, "../media/" .. entry.name)
				if not shape.w and entry.widthPx then
					shape.w = entry.widthPx * media.EMU_PER_PX
					shape.h = entry.heightPx * media.EMU_PER_PX
				end
			elseif shape.kind == "chart" then
				nChart += 1
				local chartName = "/ppt/charts/chart" .. nChart .. ".xml"
				local embedName = "/ppt/embeddings/workbook" .. nChart .. ".xlsx"
				shape._chartRid = slideRels:add(RELT.chart, "../charts/chart" .. nChart .. ".xml")
				local chartRels = pkg:relsFor(chartName)
				local embedRid = chartRels:add(RELT.package, "../embeddings/workbook" .. nChart .. ".xlsx")
				pkg:addPart(chartName, doc(chart.render(shape.model, { externalRid = embedRid })), CT.chart)
				pkg:addPart(embedName, chart.embeddedWorkbook(shape.model), CT.spreadsheet)
			end
			if shape.link then
				shape._linkRid = slideRels:add(RELT.hyperlink, shape.link, "External")
			end
			if shape.runs then
				for _, run in ipairs(shape.runs) do
					if run.link then run._linkRid = slideRels:add(RELT.hyperlink, run.link, "External") end
				end
			end
		end

		-- slide background picture fill → register its media + the slide rel
		if slide.background and slide.background.image then
			local entry = mediaReg.add(slide.background.image)
			slide.background._rid = slideRels:add(RELT.image, "../media/" .. entry.name)
		end

		-- speaker notes → a notesSlide part (slide ↔ notesSlide rels)
		if slide.notes then
			local notesName = "/ppt/notesSlides/notesSlide" .. i .. ".xml"
			slideRels:add(RELT.notesSlide, "../notesSlides/notesSlide" .. i .. ".xml")
			pkg:relsFor(notesName):add(RELT.slideRel, "../slides/slide" .. i .. ".xml")
			pkg:addPart(notesName, doc(render_notes_slide(slide.notes)), CT.notesSlide)
		end

		-- comments → a per-slide comments part (authorId resolved via the deck list)
		if slide.comments and #slide.comments > 0 then
			local cName = "/ppt/comments/comment" .. i .. ".xml"
			slideRels:add(RELT.comments, "../comments/comment" .. i .. ".xml")
			pkg:addPart(cName, doc(render_slide_comments(slide.comments, authorIds)), CT.comments)
		end

		pkg:addPart(slideName, doc(render_slide(slide)), CT.slide)
	end

	-- commentAuthors.xml (deck-wide), only when some slide has comments
	if #authorList > 0 then
		presRels:add(RELT.commentAuthors, "commentAuthors.xml")
		pkg:addPart("/ppt/commentAuthors.xml", doc(render_comment_authors(authorList)), CT.commentAuthors)
	end

	-- media parts + their content-type defaults (png/jpeg/gif)
	for _, entry in ipairs(mediaReg.items) do
		pkg.contentTypes.defaults[entry.ext] = entry.contentType
		pkg:addPart("/ppt/media/" .. entry.name, entry.bytes)
	end

	-- presentation.xml
	local pres = xml.element("p:presentation", { ["xmlns:a"] = NS_A, ["xmlns:r"] = NS_R, ["xmlns:p"] = NS_P })
	pres.children[#pres.children + 1] = xml.element("p:sldMasterIdLst", {}, {
		xml.element("p:sldMasterId", { id = "2147483648", ["r:id"] = masterRid }),
	})
	local sldIdLst = xml.element("p:sldIdLst")
	for i, rid in ipairs(slideRids) do
		sldIdLst.children[#sldIdLst.children + 1] =
			xml.element("p:sldId", { id = tostring(255 + i), ["r:id"] = rid })
	end
	pres.children[#pres.children + 1] = sldIdLst
	pres.children[#pres.children + 1] =
		xml.element("p:sldSz", { cx = tostring(self.slideSize.cx), cy = tostring(self.slideSize.cy) })
	pres.children[#pres.children + 1] = xml.element("p:notesSz", { cx = "6858000", cy = "9144000" })
	pkg:addPart("/ppt/presentation.xml", doc(pres), CT.presentation)

	-- docProps + root rels
	pkg:addPart("/docProps/core.xml", doc(render_core_props(self.properties.core)), CT.core)
	pkg:addPart("/docProps/app.xml", doc(render_app_props()), CT.app)
	local rootRels = pkg:relsFor("/")
	rootRels:add(RELT.officeDocument, "ppt/presentation.xml")
	rootRels:add(RELT.core, "docProps/core.xml")
	rootRels:add(RELT.app, "docProps/app.xml")

	return opc.write(pkg)
end

function Presentation.save(self, path)
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
local function children(el, lname)
	local out = {}
	for _, c in ipairs(el.children) do
		if c.kind == "element" and c.name.local_ == lname then out[#out + 1] = c end
	end
	return out
end
local function attr(el, lname)
	for _, a in ipairs(el.attributes) do
		if a.name.local_ == lname then return a.value end
	end
	return nil
end
-- The r:id relationship reference. A <p:sldId> carries BOTH `id` and `r:id` (same
-- local name "id"), so match the prefixed one specifically.
local function rid_of(el)
	for _, a in ipairs(el.attributes) do
		if a.name.prefix == "r" and a.name.local_ == "id" then return a.value end
	end
	return nil
end

-- Parse an a:custGeom → { w, h, commands = {…} } (the inverse of render_geometry).
local function parse_custgeom(cust)
	local pathLst = child(cust, "pathLst")
	local path = pathLst and child(pathLst, "path")
	local g = { commands = {} }
	if not path then return g end
	g.w, g.h = tonumber(attr(path, "w")), tonumber(attr(path, "h"))
	for _, c in ipairs(path.children) do
		if c.kind == "element" then
			local ln = c.name.local_
			if ln == "moveTo" or ln == "lnTo" then
				local pt = child(c, "pt")
				g.commands[#g.commands + 1] = { op = ln, x = pt and tonumber(attr(pt, "x")), y = pt and tonumber(attr(pt, "y")) }
			elseif ln == "cubicBezTo" then
				local pts = {}
				for _, pe in ipairs(children(c, "pt")) do
					pts[#pts + 1] = { x = tonumber(attr(pe, "x")), y = tonumber(attr(pe, "y")) }
				end
				g.commands[#g.commands + 1] = { op = "cubicBezTo", pts = pts }
			elseif ln == "close" then
				g.commands[#g.commands + 1] = { op = "close" }
			end
		end
	end
	return g
end

-- Parse a shape's a:txBody → concatenated runs (text + per-run formatting +
-- resolved hyperlinks). `rels` resolves a run's a:hlinkClick r:id to its target.
local function parse_shape(sp, rels)
	local shape = { kind = "shape", runs = {} }
	local nvSpPr = child(sp, "nvSpPr")
	if nvSpPr then
		local cNvSpPr = child(nvSpPr, "cNvSpPr")
		if cNvSpPr and attr(cNvSpPr, "txBox") == "1" then shape.kind = "textbox" end
		-- a placeholder shape carries p:nvPr > p:ph (type + idx)
		local nvPr = child(nvSpPr, "nvPr")
		local ph = nvPr and child(nvPr, "ph")
		if ph then
			shape.placeholder = { type = attr(ph, "type") or "body", idx = tonumber(attr(ph, "idx")) }
		end
	end
	local spPr = child(sp, "spPr")
	if spPr then
		local geom = child(spPr, "prstGeom")
		if geom then
			shape.preset = attr(geom, "prst")
			local avLst = child(geom, "avLst")
			local adj = {}
			for _, gd in ipairs(avLst and children(avLst, "gd") or {}) do
				adj[#adj + 1] = { name = attr(gd, "name"), value = tonumber((attr(gd, "fmla") or ""):match("val%s+(%-?%d+)")) }
			end
			if #adj > 0 then shape.adjustments = adj end
		end
		local cust = child(spPr, "custGeom")
		if cust then shape.geometry = parse_custgeom(cust) end
		local xfrm = child(spPr, "xfrm")
		if xfrm then
			local off, ext = child(xfrm, "off"), child(xfrm, "ext")
			if off then shape.x, shape.y = tonumber(attr(off, "x")), tonumber(attr(off, "y")) end
			if ext then shape.w, shape.h = tonumber(attr(ext, "cx")), tonumber(attr(ext, "cy")) end
		end
	end
	local txBody = child(sp, "txBody")
	if txBody then
		local textParts = {}
		for _, p in ipairs(children(txBody, "p")) do
			for _, r in ipairs(children(p, "r")) do
				local t = child(r, "t")
				local run = { text = t and xml.textOf(t) or "" }
				local rPr = child(r, "rPr")
				if rPr then
					if attr(rPr, "b") == "1" then run.bold = true end
					local sz = attr(rPr, "sz")
					if sz then run.size = tonumber(sz) / 100 end
					local hlink = child(rPr, "hlinkClick")
					if hlink and rels then run.link = rels:targetOf(rid_of(hlink)) end
				end
				shape.runs[#shape.runs + 1] = run
				textParts[#textParts + 1] = run.text
			end
		end
		shape.text = table.concat(textParts)
	end
	return shape
end

-- Parse a p:pic → an image shape, resolving a:blip r:embed → the media bytes.
local function parse_pic(pic, pkg, rels)
	local shape = { kind = "image" }
	local spPr = child(pic, "spPr")
	if spPr then
		local xfrm = child(spPr, "xfrm")
		if xfrm then
			local off, ext = child(xfrm, "off"), child(xfrm, "ext")
			if off then shape.x, shape.y = tonumber(attr(off, "x")), tonumber(attr(off, "y")) end
			if ext then shape.w, shape.h = tonumber(attr(ext, "cx")), tonumber(attr(ext, "cy")) end
		end
	end
	local blipFill = child(pic, "blipFill")
	local blip = blipFill and child(blipFill, "blip")
	if blip and rels then
		-- a:blip references the media via r:embed (local name "embed", not "id")
		local embed
		for _, a in ipairs(blip.attributes) do
			if a.name.prefix == "r" and a.name.local_ == "embed" then embed = a.value end
		end
		local target = embed and rels:targetOf(embed)
		local part = target and pkg:getPart(target)
		if part then shape.bytes = part.bytes end
	end
	return shape
end

-- Parse a p:graphicFrame holding a chart → a chart shape (resolve the chart part
-- via its r:id and read the model from the caches).
local function parse_chart_frame(gf, pkg, rels)
	local shape = { kind = "chart" }
	local xfrm = child(gf, "xfrm")
	if xfrm then
		local off, ext = child(xfrm, "off"), child(xfrm, "ext")
		if off then shape.x, shape.y = tonumber(attr(off, "x")), tonumber(attr(off, "y")) end
		if ext then shape.w, shape.h = tonumber(attr(ext, "cx")), tonumber(attr(ext, "cy")) end
	end
	local graphic = child(gf, "graphic")
	local gdata = graphic and child(graphic, "graphicData")
	local cchart = gdata and child(gdata, "chart")
	if cchart and rels then
		local target = rels:targetOf(rid_of(cchart))
		local part = target and pkg:getPart(target)
		if part then
			local chartDoc = xml.parse(part.bytes)
			if chartDoc then shape.model = chart.parse(chartDoc.root) end
		end
	end
	return shape
end

-- Concatenate a table cell's run text (txBody → a:p → a:r → a:t).
local function cell_text(txBody)
	local parts = {}
	for _, p in ipairs(children(txBody, "p")) do
		for _, r in ipairs(children(p, "r")) do
			local t = child(r, "t")
			if t then parts[#parts + 1] = xml.textOf(t) end
		end
	end
	return table.concat(parts)
end

-- Parse a p:graphicFrame holding an a:tbl → a table shape (rows of cell strings).
local function parse_table_frame(gf)
	local shape = { kind = "table", rows = {} }
	local xfrm = child(gf, "xfrm")
	if xfrm then
		local off, ext = child(xfrm, "off"), child(xfrm, "ext")
		if off then shape.x, shape.y = tonumber(attr(off, "x")), tonumber(attr(off, "y")) end
		if ext then shape.w, shape.h = tonumber(attr(ext, "cx")), tonumber(attr(ext, "cy")) end
	end
	local graphic = child(gf, "graphic")
	local gdata = graphic and child(graphic, "graphicData")
	local tbl = gdata and child(gdata, "tbl")
	if tbl then
		for _, tr in ipairs(children(tbl, "tr")) do
			local row = {}
			for _, tc in ipairs(children(tr, "tc")) do
				local txBody = child(tc, "txBody")
				row[#row + 1] = txBody and cell_text(txBody) or ""
			end
			shape.rows[#shape.rows + 1] = row
		end
	end
	return shape
end

-- Parse a slide background (p:cSld > p:bg): a solid colour or a picture fill.
local function parse_background(cSld, pkg, rels)
	local bg = cSld and child(cSld, "bg")
	local bgPr = bg and child(bg, "bgPr")
	if not bgPr then return nil end
	local sf = child(bgPr, "solidFill")
	if sf then
		local clr = child(sf, "srgbClr")
		if clr then return { color = attr(clr, "val") } end
	end
	local bf = child(bgPr, "blipFill")
	local blip = bf and child(bf, "blip")
	if blip and rels then
		local embed
		for _, a in ipairs(blip.attributes) do
			if a.name.prefix == "r" and a.name.local_ == "embed" then embed = a.value end
		end
		local part = embed and pkg:getPart(rels:targetOf(embed) or "")
		if part then return { image = part.bytes } end
	end
	return nil
end

local function parse_slide(el, pkg, rels)
	local slide = setmetatable({ shapes = {} }, Slide)
	local cSld = child(el, "cSld")
	slide.background = parse_background(cSld, pkg, rels)
	local tree = cSld and child(cSld, "spTree")
	if tree then
		for _, c in ipairs(tree.children) do
			if c.kind == "element" and c.name.local_ == "sp" then
				slide.shapes[#slide.shapes + 1] = parse_shape(c, rels)
			elseif c.kind == "element" and c.name.local_ == "pic" then
				slide.shapes[#slide.shapes + 1] = parse_pic(c, pkg, rels)
			elseif c.kind == "element" and c.name.local_ == "graphicFrame" then
				local graphic = child(c, "graphic")
				local gdata = graphic and child(graphic, "graphicData")
				local uri = gdata and attr(gdata, "uri")
				if uri and uri:find("/table") then
					slide.shapes[#slide.shapes + 1] = parse_table_frame(c)
				else
					slide.shapes[#slide.shapes + 1] = parse_chart_frame(c, pkg, rels)
				end
			end
		end
	end
	-- the slide's layout (resolve its rel → the layout part's `type`)
	if rels then
		for _, rel in ipairs(rels.items) do
			if rel.type == RELT.slideLayout then
				local lpart = pkg:getPart(rels:targetOf(rel.id) or "")
				local ld = lpart and xml.parse(lpart.bytes)
				slide.layout = ld and LAYOUT_BY_TYPE[attr(ld.root, "type")] or "blank"
			end
		end
	end
	-- comments part (author name resolved later, in pptx.load, from commentAuthors)
	if rels then
		for _, rel in ipairs(rels.items) do
			if rel.type == RELT.comments then
				local cpart = pkg:getPart(rels:targetOf(rel.id) or "")
				local cd = cpart and xml.parse(cpart.bytes)
				if cd then
					slide.comments = {}
					for _, cm in ipairs(children(cd.root, "cm")) do
						local pos = child(cm, "pos")
						local txt = child(cm, "text")
						slide.comments[#slide.comments + 1] = {
							_authorId = tonumber(attr(cm, "authorId")),
							_idx = tonumber(attr(cm, "idx")),
							date = attr(cm, "dt"),
							x = pos and tonumber(attr(pos, "x")),
							y = pos and tonumber(attr(pos, "y")),
							text = txt and xml.textOf(txt) or "",
						}
					end
				end
			end
		end
	end
	return slide
end

-- pptx.load(bytes) → Presentation | nil, err. Resolves the presentation via the
-- officeDocument rel, then each slide in sldIdLst order; unknown parts stay in opc.
function pptx.load(bytes)
	local pkg, err = opc.read(bytes)
	if not pkg then return nil, err end
	if pkg:detectFormat() ~= "pptx" then return nil, "pptx/not-a-presentation" end

	local rootRels = pkg.rels[""]
	local presName
	for _, rel in ipairs(rootRels.items) do
		if rel.type == RELT.officeDocument then presName = rootRels:targetOf(rel.id) end
	end
	local presDoc = assert(xml.parse(pkg:getPart(presName).bytes))
	local presRels = pkg.rels[presName]

	-- commentAuthors.xml (deck-wide) → id → { name, initials } for resolving comments
	local authorsById = {}
	if presRels then
		for _, rel in ipairs(presRels.items) do
			if rel.type == RELT.commentAuthors then
				local apart = pkg:getPart(presRels:targetOf(rel.id) or "")
				local ad = apart and xml.parse(apart.bytes)
				for _, a in ipairs(ad and children(ad.root, "cmAuthor") or {}) do
					authorsById[attr(a, "id")] = { name = attr(a, "name"), initials = attr(a, "initials") }
				end
			end
		end
	end

	local sldSz = child(presDoc.root, "sldSz")
	local size = sldSz and { cx = tonumber(attr(sldSz, "cx")), cy = tonumber(attr(sldSz, "cy")) }
		or SLIDE_SIZES["4:3"]

	local prs = setmetatable(
		{ slides = {}, slideSize = size, properties = { core = {} }, package = pkg },
		Presentation
	)
	local sldIdLst = child(presDoc.root, "sldIdLst")
	if sldIdLst and presRels then
		for _, sldId in ipairs(children(sldIdLst, "sldId")) do
			local rid = rid_of(sldId)
			local target = presRels:targetOf(rid)
			local part = target and pkg:getPart(target)
			if part then
				local slideDoc = assert(xml.parse(part.bytes))
				local slideRels = pkg.rels[target]
				local sl = parse_slide(slideDoc.root, pkg, slideRels)
				-- speaker notes, if any (slide → notesSlide rel)
				if slideRels then
					for _, rel in ipairs(slideRels.items) do
						if rel.type == RELT.notesSlide then
							local npart = pkg:getPart(slideRels:targetOf(rel.id) or "")
							local nd = npart and xml.parse(npart.bytes)
							local tree = nd and child(child(nd.root, "cSld") or nd.root, "spTree")
							for _, sp in ipairs(tree and children(tree, "sp") or {}) do
								local txt = cell_text(child(sp, "txBody") or sp)
								if txt ~= "" then sl.notes = txt end
							end
						end
					end
				end
				-- resolve comment author names from the deck-wide author list
				for _, cm in ipairs(sl.comments or {}) do
					local a = authorsById[tostring(cm._authorId)]
					if a then
						cm.author = a.name
						cm.initials = cm.initials or a.initials
					end
				end
				prs.slides[#prs.slides + 1] = sl
			end
		end
	end
	return prs
end

function pptx.open(path)
	local sys = sys
	local bytes, err = sys.fs.read(path)
	if not bytes then return nil, err end
	return pptx.load(bytes)
end

return pptx
