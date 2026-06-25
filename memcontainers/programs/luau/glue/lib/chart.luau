-- chart.luau — DrawingML charts, shared by xlsx/docx/
-- pptx. A chart is `chartN.xml` in the `c:` namespace: a plot area holding one
-- chart-type element (bar/col/line/pie) whose series carry both a formula
-- reference (c:f → where the data lives) AND a cache (strCache/numCache) so the
-- chart renders without recalculation. For pptx/docx the data lives in an
-- EMBEDDED .xlsx — built here by reusing our own xlsx writer, rather
-- than a second hand-rolled spreadsheet generator. For xlsx the data is the host
-- workbook, so no embedding.
--
--   chart.render(model, opts?)        -> a c:chartSpace XmlElement
--   chart.embeddedWorkbook(model)     -> .xlsx bytes (the data, for pptx/docx)
--
-- model = { type="col"|"bar"|"line"|"pie", title?, categories={string…},
--           series={ { name=string, values={number…} }… } }

local xml = require("xml")

local chart = {}

local NS_C = "http://schemas.openxmlformats.org/drawingml/2006/chart"
local NS_A = "http://schemas.openxmlformats.org/drawingml/2006/main"
local NS_R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

-- 1→"A", 2→"B"… (data columns; series N lives in column N+1, categories in A).
local function col_letter(n)
	local s = ""
	while n > 0 do
		local r = (n - 1) % 26
		s = string.char(65 + r) .. s
		n = (n - r - 1) // 26
	end
	return s
end

-- A cached string reference: <c:strRef><c:f>…</c:f><c:strCache>…</c:strCache></c:strRef>.
local function str_ref(f, strings)
	local cache = xml.element("c:strCache", {}, { xml.element("c:ptCount", { val = tostring(#strings) }) })
	for i, s in ipairs(strings) do
		cache.children[#cache.children + 1] =
			xml.element("c:pt", { idx = tostring(i - 1) }, { xml.element("c:v", {}, { xml.text(tostring(s)) }) })
	end
	return xml.element("c:strRef", {}, { xml.element("c:f", {}, { xml.text(f) }), cache })
end

-- A cached numeric reference for series values.
local function num_ref(f, numbers)
	local cache = xml.element("c:numCache", {}, {
		xml.element("c:formatCode", {}, { xml.text("General") }),
		xml.element("c:ptCount", { val = tostring(#numbers) }),
	})
	for i, n in ipairs(numbers) do
		cache.children[#cache.children + 1] =
			xml.element("c:pt", { idx = tostring(i - 1) }, { xml.element("c:v", {}, { xml.text(tostring(n)) }) })
	end
	return xml.element("c:numRef", {}, { xml.element("c:f", {}, { xml.text(f) }), cache })
end

local function axis(tag, id, crossId, pos)
	return xml.element(tag, {}, {
		xml.element("c:axId", { val = id }),
		xml.element("c:scaling", {}, { xml.element("c:orientation", { val = "minMax" }) }),
		xml.element("c:delete", { val = "0" }),
		xml.element("c:axPos", { val = pos }),
		xml.element("c:crossAx", { val = crossId }),
	})
end

local function title_el(text)
	return xml.element("c:title", {}, {
		xml.element("c:tx", {}, {
			xml.element("c:rich", {}, {
				xml.element("a:bodyPr"),
				xml.element("a:lstStyle"),
				xml.element("a:p", {}, { xml.element("a:r", {}, { xml.element("a:t", {}, { xml.text(text) }) }) }),
			}),
		}),
		xml.element("c:overlay", { val = "0" }),
	})
end

-- chart.render(model, opts?) → c:chartSpace. opts.sheet = the sheet name the c:f
-- formulas reference (default "Sheet1"); opts.externalRid = an r:id for an
-- <c:externalData> link to the embedded workbook (pptx/docx).
function chart.render(model, opts)
	opts = opts or {}
	local sheet = opts.sheet or "Sheet1"
	local typ = model.type or "col"
	local n = #model.categories
	local AX1, AX2 = "111111111", "222222222"

	local typeEl
	if typ == "pie" then
		typeEl = xml.element("c:pieChart", {}, { xml.element("c:varyColors", { val = "1" }) })
	elseif typ == "line" then
		typeEl = xml.element("c:lineChart", {}, { xml.element("c:grouping", { val = "standard" }) })
	else
		typeEl = xml.element("c:barChart", {}, {
			xml.element("c:barDir", { val = (typ == "bar") and "bar" or "col" }),
			xml.element("c:grouping", { val = "clustered" }),
		})
	end

	for si, ser in ipairs(model.series) do
		local colL = col_letter(si + 1) -- B, C, …
		typeEl.children[#typeEl.children + 1] = xml.element("c:ser", {}, {
			xml.element("c:idx", { val = tostring(si - 1) }),
			xml.element("c:order", { val = tostring(si - 1) }),
			xml.element("c:tx", {}, { str_ref(sheet .. "!$" .. colL .. "$1", { ser.name or ("Series " .. si) }) }),
			xml.element("c:cat", {}, { str_ref(sheet .. "!$A$2:$A$" .. (n + 1), model.categories) }),
			xml.element("c:val", {}, { num_ref(sheet .. "!$" .. colL .. "$2:$" .. colL .. "$" .. (n + 1), ser.values) }),
		})
	end
	if typ == "pie" then
		typeEl.children[#typeEl.children + 1] = xml.element("c:firstSliceAng", { val = "0" })
	else
		typeEl.children[#typeEl.children + 1] = xml.element("c:axId", { val = AX1 })
		typeEl.children[#typeEl.children + 1] = xml.element("c:axId", { val = AX2 })
	end

	local plotArea = xml.element("c:plotArea", {}, { xml.element("c:layout"), typeEl })
	if typ ~= "pie" then
		plotArea.children[#plotArea.children + 1] = axis("c:catAx", AX1, AX2, "b")
		plotArea.children[#plotArea.children + 1] = axis("c:valAx", AX2, AX1, "l")
	end

	local cChart = xml.element("c:chart")
	if model.title then
		cChart.children[#cChart.children + 1] = title_el(model.title)
		cChart.children[#cChart.children + 1] = xml.element("c:autoTitleDeleted", { val = "0" })
	else
		cChart.children[#cChart.children + 1] = xml.element("c:autoTitleDeleted", { val = "1" })
	end
	cChart.children[#cChart.children + 1] = plotArea
	cChart.children[#cChart.children + 1] = xml.element("c:plotVisOnly", { val = "1" })
	cChart.children[#cChart.children + 1] = xml.element("c:dispBlanksAs", { val = "gap" })

	local space = xml.element("c:chartSpace", { ["xmlns:c"] = NS_C, ["xmlns:a"] = NS_A, ["xmlns:r"] = NS_R }, { cChart })
	if opts.externalRid then
		space.children[#space.children + 1] = xml.element("c:externalData", { ["r:id"] = opts.externalRid }, {
			xml.element("c:autoUpdate", { val = "0" }),
		})
	end
	return space
end

-- chart.embeddedWorkbook(model) → .xlsx bytes laying the data out as the c:f
-- formulas expect: row 1 = [blank, series names…], rows 2.. = [category, values…].
function chart.embeddedWorkbook(model)
	local xlsx = require("xlsx")
	local wb = xlsx.new()
	local ws = wb:addWorksheet("Sheet1")
	for si, ser in ipairs(model.series) do
		ws:setCell(col_letter(si + 1) .. "1", ser.name or ("Series " .. si))
	end
	for i, cat in ipairs(model.categories) do
		ws:setCell("A" .. (i + 1), cat)
		for si, ser in ipairs(model.series) do
			ws:setCell(col_letter(si + 1) .. (i + 1), ser.values[i])
		end
	end
	return wb:toBytes()
end

-- ---------------------------------------------------------------------------
-- Read: a c:chartSpace → the model (type, title, categories, series), pulled from
-- the caches (the source of truth for display).
-- ---------------------------------------------------------------------------

local function child(el, lname)
	for _, c in ipairs(el.children or {}) do
		if c.kind == "element" and c.name.local_ == lname then return c end
	end
	return nil
end
local function children(el, lname)
	local out = {}
	for _, c in ipairs(el.children or {}) do
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

-- Pull a ref's cached points (strCache/numCache) in idx order → an array.
local function cache_points(ref, cacheTag)
	local cache = ref and child(ref, cacheTag)
	if not cache then return {} end
	local out = {}
	for _, pt in ipairs(children(cache, "pt")) do
		out[tonumber(attr(pt, "idx")) + 1] = xml.textOf(child(pt, "v"))
	end
	return out
end

function chart.parse(space)
	local cChart = child(space, "chart")
	local plotArea = cChart and child(cChart, "plotArea")
	if not plotArea then return nil end
	local model = { categories = {}, series = {} }

	local typeEl, typ
	for _, t in ipairs({ "barChart", "lineChart", "pieChart" }) do
		local e = child(plotArea, t)
		if e then
			typeEl = e
			typ = t
			break
		end
	end
	if typ == "barChart" then
		local dir = child(typeEl, "barDir")
		model.type = (dir and attr(dir, "val") == "bar") and "bar" or "col"
	elseif typ == "lineChart" then
		model.type = "line"
	elseif typ == "pieChart" then
		model.type = "pie"
	end

	local title = cChart and child(cChart, "title")
	if title then
		local t = title
		for _, lname in ipairs({ "tx", "rich", "p", "r", "t" }) do
			t = t and child(t, lname)
		end
		if t then model.title = xml.textOf(t) end
	end

	if typeEl then
		for i, ser in ipairs(children(typeEl, "ser")) do
			local nameRef = child(child(ser, "tx") or ser, "strRef")
			local name = nameRef and cache_points(nameRef, "strCache")[1]
			local valRef = child(child(ser, "val") or ser, "numRef")
			local vals = {}
			for j, v in ipairs(cache_points(valRef, "numCache")) do
				vals[j] = tonumber(v)
			end
			model.series[i] = { name = name, values = vals }
			if i == 1 then
				local catRef = child(child(ser, "cat") or ser, "strRef")
				model.categories = cache_points(catRef, "strCache")
			end
		end
	end
	return model
end

chart.colLetter = col_letter

return chart
