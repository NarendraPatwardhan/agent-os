-- xlsx.luau — SpreadsheetML (.xlsx) read + write (luau-extensions Ch.08). The
-- format the xform pattern was born in (ExcelJS), so it maps most directly onto our
-- engine. The defining features are the **index-based shared style table**, the
-- **shared-string pool**, and the two-phase build: a first pass interns strings +
-- styles (deduping into stable indices), a second pass emits XML reading those
-- indices — so markup, the indices, and the parts always agree.
--
-- Built on opc + zip + xml + xform.pool (ctx/LUAU.md §7.2). Concrete (non-theme) colors;
-- cell kinds number/string/boolean/date/formula/error/inlineStr. Unknown parts the
-- model doesn't touch round-trip verbatim through `opc`.

local opc = require("opc")
local xml = require("xml")
local media = require("media")
local chart = require("chart")
local calc = require("calc")

local xlsx = {}

local NS_MAIN = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
local NS_R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
local NS_XDR = "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"
local NS_A = "http://schemas.openxmlformats.org/drawingml/2006/main"
local NS_CORE = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
local NS_DC = "http://purl.org/dc/elements/1.1/"
local NS_DCTERMS = "http://purl.org/dc/terms/"
local NS_XSI = "http://www.w3.org/2001/XMLSchema-instance"
local NS_EXT = "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"

local CT = {
	workbook = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml",
	worksheet = "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml",
	sharedStrings = "application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml",
	styles = "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml",
	comments = "application/vnd.openxmlformats-officedocument.spreadsheetml.comments+xml",
	table = "application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml",
	drawing = "application/vnd.openxmlformats-officedocument.drawing+xml",
	chart = "application/vnd.openxmlformats-officedocument.drawingml.chart+xml",
	core = "application/vnd.openxmlformats-package.core-properties+xml",
	app = "application/vnd.openxmlformats-officedocument.extended-properties+xml",
}
local RELT = {
	officeDocument = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument",
	worksheet = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet",
	styles = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles",
	sharedStrings = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings",
	comments = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments",
	table = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/table",
	drawing = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing",
	image = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
	hyperlink = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
	chart = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart",
	core = "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties",
	app = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties",
}

-- ===========================================================================
-- A1 addressing (col letter ↔ number; ref parse; range)
-- ===========================================================================

-- 1 → "A", 26 → "Z", 27 → "AA". 1-based column number → letters.
local function col_letter(n)
	local s = ""
	while n > 0 do
		local r = (n - 1) % 26
		s = string.char(65 + r) .. s
		n = (n - r - 1) // 26
	end
	return s
end
xlsx.colLetter = col_letter

-- "A" → 1, "AA" → 27. Column letters → 1-based number.
local function col_number(letters)
	local n = 0
	for i = 1, #letters do
		n = n * 26 + (string.byte(letters, i) - 64)
	end
	return n
end
xlsx.colNumber = col_number

-- "B3" → 2, 3 (column, row).
local function parse_ref(ref)
	local letters, row = ref:match("^([A-Z]+)(%d+)$")
	return col_number(letters), tonumber(row)
end
xlsx.parseRef = parse_ref

-- (col, row) → "B3".
local function make_ref(c, r)
	return col_letter(c) .. tostring(r)
end
xlsx.makeRef = make_ref

-- ===========================================================================
-- Date ↔ Excel serial (1900 date system: days since 1899-12-30)
-- ===========================================================================

-- Days from 1970-01-01 for a civil (y,m,d) — Howard Hinnant's algorithm.
local function days_from_civil(y, m, d)
	y = (m <= 2) and (y - 1) or y
	local era = ((y >= 0) and y or (y - 399)) // 400
	local yoe = y - era * 400
	local mp = (m > 2) and (m - 3) or (m + 9)
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

local EXCEL_EPOCH = days_from_civil(1899, 12, 30)

-- (y,m,d[,hh,mm,ss]) → Excel serial number.
function xlsx.dateSerial(y, m, d, hh, mm, ss)
	local days = days_from_civil(y, m, d) - EXCEL_EPOCH
	local frac = ((hh or 0) * 3600 + (mm or 0) * 60 + (ss or 0)) / 86400
	return days + frac
end

-- "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM:SS" → serial.
local function iso_to_serial(s)
	local y, m, d, hh, mm, ss = s:match("(%d+)-(%d+)-(%d+)[T ]?(%d*):?(%d*):?(%d*)")
	if not y then
		return nil
	end
	return xlsx.dateSerial(tonumber(y), tonumber(m), tonumber(d), tonumber(hh), tonumber(mm), tonumber(ss))
end

-- ===========================================================================
-- Cell value constructors (a tagged union — Principle #7)
-- ===========================================================================

function xlsx.number(n) return { kind = "number", value = n } end
function xlsx.string(s) return { kind = "string", value = s } end
function xlsx.boolean(b) return { kind = "boolean", value = b } end
function xlsx.error(code) return { kind = "error", value = code } end
function xlsx.formula(expr, cached) return { kind = "formula", formula = expr, result = cached } end

-- xlsx.date(v): v is a serial number, or an ISO date string.
function xlsx.date(v)
	if type(v) == "string" then
		v = iso_to_serial(v) or 0
	end
	return { kind = "date", value = v }
end

-- Coerce a raw Luau value to a CellValue at the API boundary.
local function coerce(v)
	if v == nil then
		return { kind = "empty" }
	end
	local t = type(v)
	if t == "number" then
		return { kind = "number", value = v }
	elseif t == "string" then
		return { kind = "string", value = v }
	elseif t == "boolean" then
		return { kind = "boolean", value = v }
	elseif t == "table" and v.kind then
		return v
	end
	error("xlsx: cannot store a " .. t .. " in a cell")
end

-- ===========================================================================
-- The index-based style table (fonts/fills/borders/numFmts + cellXfs)
-- ===========================================================================

-- Built-in number-format codes → ids (a subset of 0..49). Custom codes get 164+.
local BUILTIN_NUMFMT = {
	["General"] = 0, ["0"] = 1, ["0.00"] = 2, ["#,##0"] = 3, ["#,##0.00"] = 4,
	["0%"] = 9, ["0.00%"] = 10, ["0.00E+00"] = 11,
	["mm-dd-yy"] = 14, ["d-mmm-yy"] = 15, ["d-mmm"] = 16, ["mmm-yy"] = 17,
	["h:mm AM/PM"] = 18, ["h:mm:ss AM/PM"] = 19, ["h:mm"] = 20, ["h:mm:ss"] = 21,
	["m/d/yy h:mm"] = 22, ["mm:ss"] = 45, ["@"] = 49,
}

local DEFAULT_DATE_FMT = "yyyy-mm-dd" -- a deterministic ISO date format (custom id)

local function canon_color(c)
	if not c then return "-" end
	if c.kind == "theme" then return "t" .. c.slot .. (c.tint or "") end
	return (c.kind or "rgb") .. (c.value or "")
end

local function canon_font(f)
	f = f or {}
	return table.concat({
		f.bold and "b" or "", f.italic and "i" or "", f.underline or "",
		tostring(f.size or 11), f.name or "Calibri", canon_color(f.color),
	}, "|")
end

local function canon_fill(f)
	if not f or f.kind == "none" then return "none" end
	return (f.kind or "solid") .. ":" .. canon_color(f.color)
end

local function canon_border(b)
	if not b then return "-" end
	return (b.style or "thin") .. ":" .. canon_color(b.color)
end

local function canon_align(a)
	if not a then return "-" end
	return (a.horizontal or "") .. ":" .. (a.vertical or "") .. ":" .. (a.wrapText and "w" or "")
end

local function new_style_table()
	local st = {
		fonts = { list = {}, index = {} },
		fills = { list = {}, index = {} },
		borders = { list = {}, index = {} },
		numFmts = { list = {}, index = {}, nextId = 164 }, -- custom codes only
		cellXfs = { list = {}, index = {} },
		dxfs = { list = {}, index = {} }, -- differential formats (conditional formatting)
	}

	local function intern(pool, key, value)
		if pool.index[key] ~= nil then
			return pool.index[key]
		end
		pool.list[#pool.list + 1] = value
		local id = #pool.list - 1
		pool.index[key] = id
		return id
	end

	-- Seed required defaults: font 0; fill 0 (none) + fill 1 (gray125, an Excel
	-- requirement); border 0 (empty); cellXf 0 (all defaults).
	intern(st.fonts, canon_font({}), {})
	intern(st.fills, "none", { kind = "none" })
	intern(st.fills, "gray125", { kind = "gray125" })
	intern(st.borders, "-", {})
	st.cellXfs.list[1] = { numFmtId = 0, fontId = 0, fillId = 0, borderId = 0 }
	st.cellXfs.index["0:0:0:0:-"] = 0

	function st.intern_numfmt(code)
		if not code then return 0 end
		local b = BUILTIN_NUMFMT[code]
		if b then return b end
		if st.numFmts.index[code] ~= nil then return st.numFmts.index[code] end
		local id = st.numFmts.nextId
		st.numFmts.nextId += 1
		st.numFmts.index[code] = id
		st.numFmts.list[#st.numFmts.list + 1] = { id = id, code = code }
		return id
	end

	-- Intern a CellStyle → a cellXf index (a cell's @s). Dedups by canonical
	-- encoding of the typed record, NOT by rendered XML (Ch.05 §5.8).
	function st.intern(style)
		if not style then return 0 end
		local fontId = style.font and intern(st.fonts, canon_font(style.font), style.font) or 0
		local fillId = style.fill and intern(st.fills, canon_fill(style.fill), style.fill) or 0
		local borderId = style.border and intern(st.borders, canon_border(style.border), style.border) or 0
		local numFmtId = st.intern_numfmt(style.numberFormat)
		local align = style.alignment
		local key = numFmtId .. ":" .. fontId .. ":" .. fillId .. ":" .. borderId .. ":" .. canon_align(align)
		if st.cellXfs.index[key] ~= nil then
			return st.cellXfs.index[key]
		end
		st.cellXfs.list[#st.cellXfs.list + 1] = {
			numFmtId = numFmtId, fontId = fontId, fillId = fillId, borderId = borderId, alignment = align,
		}
		local id = #st.cellXfs.list - 1
		st.cellXfs.index[key] = id
		return id
	end

	-- Intern a differential format (a partial style { fill?, font? } used by
	-- conditional formatting) → a 0-based dxfId. Deduped by canonical encoding.
	function st.intern_dxf(dxf)
		if not dxf then return nil end
		local f = dxf.font or {}
		local key = (dxf.fill or "")
			.. "|" .. tostring(f.bold) .. "|" .. tostring(f.italic) .. "|" .. tostring(f.color)
		if st.dxfs.index[key] ~= nil then return st.dxfs.index[key] end
		st.dxfs.list[#st.dxfs.list + 1] = dxf
		local id = #st.dxfs.list - 1
		st.dxfs.index[key] = id
		return id
	end

	return st
end

-- Normalize an rgb string to 8-digit ARGB (prefix opaque alpha if 6-digit).
local function argb8(s)
	s = (s:gsub("^#", "")):upper()
	if #s == 6 then return "FF" .. s end
	return s
end

-- Encode a Color to an xlsx <color .../> element (concrete rgb → 8-digit ARGB).
local function color_el(c)
	if not c then return nil end
	if c.kind == "auto" then
		return xml.element("color", { auto = "1" })
	elseif c.kind == "indexed" then
		return xml.element("color", { indexed = tostring(c.value) })
	elseif c.kind == "argb" then
		return xml.element("color", { rgb = c.value })
	elseif c.kind == "theme" then
		local require_color = require("color")
		return xml.element("color", { theme = tostring(require_color.THEME_INDEX[c.slot] or 1) })
	end
	return xml.element("color", { rgb = "FF" .. (c.value or "000000") })
end

-- styles.xml from the interned style table.
local function render_styles(st)
	local root = xml.element("styleSheet", { xmlns = NS_MAIN })

	if #st.numFmts.list > 0 then
		local nf = xml.element("numFmts", { count = tostring(#st.numFmts.list) })
		for _, e in ipairs(st.numFmts.list) do
			nf.children[#nf.children + 1] =
				xml.element("numFmt", { numFmtId = tostring(e.id), formatCode = e.code })
		end
		root.children[#root.children + 1] = nf
	end

	local fonts = xml.element("fonts", { count = tostring(#st.fonts.list) })
	for _, f in ipairs(st.fonts.list) do
		local fe = xml.element("font")
		if f.bold then fe.children[#fe.children + 1] = xml.element("b") end
		if f.italic then fe.children[#fe.children + 1] = xml.element("i") end
		if f.underline then fe.children[#fe.children + 1] = xml.element("u") end
		fe.children[#fe.children + 1] = xml.element("sz", { val = tostring(f.size or 11) })
		local ce = color_el(f.color)
		if ce then fe.children[#fe.children + 1] = ce end
		fe.children[#fe.children + 1] = xml.element("name", { val = f.name or "Calibri" })
		fonts.children[#fonts.children + 1] = fe
	end
	root.children[#root.children + 1] = fonts

	local fills = xml.element("fills", { count = tostring(#st.fills.list) })
	for _, f in ipairs(st.fills.list) do
		local fe = xml.element("fill")
		if f.kind == "none" then
			fe.children[1] = xml.element("patternFill", { patternType = "none" })
		elseif f.kind == "gray125" then
			fe.children[1] = xml.element("patternFill", { patternType = "gray125" })
		else
			local pf = xml.element("patternFill", { patternType = "solid" })
			local fg = color_el(f.color)
			if fg then
				fg.name = xml.name("fgColor")
				pf.children[1] = fg
			end
			fe.children[1] = pf
		end
		fills.children[#fills.children + 1] = fe
	end
	root.children[#root.children + 1] = fills

	local borders = xml.element("borders", { count = tostring(#st.borders.list) })
	for _, b in ipairs(st.borders.list) do
		local be = xml.element("border")
		for _, side in ipairs({ "left", "right", "top", "bottom", "diagonal" }) do
			if b.style and side ~= "diagonal" then
				local se = xml.element(side, { style = b.style })
				local ce = color_el(b.color)
				if ce then se.children[1] = ce end
				be.children[#be.children + 1] = se
			else
				be.children[#be.children + 1] = xml.element(side)
			end
		end
		borders.children[#borders.children + 1] = be
	end
	root.children[#root.children + 1] = borders

	root.children[#root.children + 1] = xml.element("cellStyleXfs", { count = "1" }, {
		xml.element("xf", { numFmtId = "0", fontId = "0", fillId = "0", borderId = "0" }),
	})

	local cellXfs = xml.element("cellXfs", { count = tostring(#st.cellXfs.list) })
	for _, xf in ipairs(st.cellXfs.list) do
		local attrs = {
			numFmtId = tostring(xf.numFmtId or 0), fontId = tostring(xf.fontId or 0),
			fillId = tostring(xf.fillId or 0), borderId = tostring(xf.borderId or 0), xfId = "0",
		}
		if (xf.numFmtId or 0) ~= 0 then attrs.applyNumberFormat = "1" end
		if (xf.fontId or 0) ~= 0 then attrs.applyFont = "1" end
		if (xf.fillId or 0) ~= 0 then attrs.applyFill = "1" end
		if (xf.borderId or 0) ~= 0 then attrs.applyBorder = "1" end
		local xe = xml.element("xf", attrs)
		if xf.alignment then
			attrs.applyAlignment = "1"
			local a = {}
			if xf.alignment.horizontal then a.horizontal = xf.alignment.horizontal end
			if xf.alignment.vertical then a.vertical = xf.alignment.vertical end
			if xf.alignment.wrapText then a.wrapText = "1" end
			xe.children[1] = xml.element("alignment", a)
		end
		cellXfs.children[#cellXfs.children + 1] = xe
	end
	root.children[#root.children + 1] = cellXfs

	root.children[#root.children + 1] = xml.element("cellStyles", { count = "1" }, {
		xml.element("cellStyle", { name = "Normal", xfId = "0", builtinId = "0" }),
	})

	-- dxfs (differential formats for conditional formatting) — after cellStyles. The
	-- dxf child order is font, numFmt, fill, …; a dxf fill highlight uses bgColor.
	if #st.dxfs.list > 0 then
		local dxfs = xml.element("dxfs", { count = tostring(#st.dxfs.list) })
		for _, d in ipairs(st.dxfs.list) do
			local de = xml.element("dxf")
			if d.font then
				local fe = xml.element("font")
				if d.font.bold then fe.children[#fe.children + 1] = xml.element("b") end
				if d.font.italic then fe.children[#fe.children + 1] = xml.element("i") end
				if d.font.color then fe.children[#fe.children + 1] = xml.element("color", { rgb = argb8(d.font.color) }) end
				de.children[#de.children + 1] = fe
			end
			if d.fill then
				de.children[#de.children + 1] = xml.element("fill", {}, {
					xml.element("patternFill", {}, { xml.element("bgColor", { rgb = argb8(d.fill) }) }),
				})
			end
			dxfs.children[#dxfs.children + 1] = de
		end
		root.children[#root.children + 1] = dxfs
	end
	return root
end

-- ===========================================================================
-- The model (Workbook / Worksheet / Row / Cell) with methods
-- ===========================================================================

local Workbook = {}
Workbook.__index = Workbook
local Worksheet = {}
Worksheet.__index = Worksheet

local function valid_sheet_name(name)
	-- ≤31 chars, none of * ? : / \ [ ], not empty
	if #name == 0 or #name > 31 or name:find("[%*%?:/\\%[%]]") then
		return false
	end
	return true
end

-- xlsx.new(spec?) → Workbook. spec.properties.core = { creator, title, … }.
function xlsx.new(spec)
	spec = spec or {}
	return setmetatable({
		worksheets = {},
		properties = spec.properties or { core = {}, app = {} },
		_nextSheetId = 1,
	}, Workbook)
end

-- addWorksheet(name?, opts?) → Worksheet (appended). Name is validated + made
-- unique. opts.inlineStrings → string cells are written inline (no shared-string
-- pool) — the streaming-friendly write mode (§8.7), avoiding a global pool.
function Workbook.addWorksheet(self, name, opts)
	opts = opts or {}
	name = name or ("Sheet" .. (#self.worksheets + 1))
	assert(valid_sheet_name(name), "xlsx: invalid sheet name '" .. name .. "'")
	for _, ws in ipairs(self.worksheets) do
		assert(ws.name ~= name, "xlsx: duplicate sheet name '" .. name .. "'")
	end
	local ws = setmetatable({
		name = name,
		sheetId = self._nextSheetId,
		columns = nil,
		rows = {}, -- [rownum] = { number, cells = { [col]=Cell } }
		merges = {},
		images = {},
		hyperlinks = {},
		charts = {},
		inlineStrings = opts.inlineStrings or nil,
		_maxCol = 0,
		_maxRow = 0,
	}, Worksheet)
	self._nextSheetId += 1
	self.worksheets[#self.worksheets + 1] = ws
	return ws
end

function Workbook.worksheet(self, name)
	for _, ws in ipairs(self.worksheets) do
		if ws.name == name then return ws end
	end
	return nil
end

-- scanErrors() → an array of error sites across the workbook, WITHOUT evaluating:
--   { sheet, ref, code, kind }  where kind is
--     "value"          — a cell holding an error value (#REF! …),
--     "formula-result" — a formula whose cached result is an error,
--     "formula-ref"    — a formula whose text embeds an error literal (broken ref).
-- (A lightweight static scan; full recalculation is the separate formula engine.)
function Workbook.scanErrors(self)
	local ERR_LITERALS = { "#REF!", "#NAME?", "#DIV/0!", "#VALUE!", "#NUM!", "#NULL!", "#N/A" }
	local out = {}
	for _, ws in ipairs(self.worksheets) do
		for r = 1, ws._maxRow do
			local row = ws.rows[r]
			if row then
				for c = 1, ws._maxCol do
					local cell = row.cells[c]
					local v = cell and cell.value
					if v and v.kind == "error" then
						out[#out + 1] = { sheet = ws.name, ref = cell.ref, code = v.value, kind = "value" }
					elseif v and v.kind == "formula" then
						if v.result and v.result.kind == "error" then
							out[#out + 1] = { sheet = ws.name, ref = cell.ref, code = v.result.value, kind = "formula-result" }
						elseif v.formula then
							for _, ec in ipairs(ERR_LITERALS) do
								if v.formula:find(ec, 1, true) then
									out[#out + 1] = { sheet = ws.name, ref = cell.ref, code = ec, kind = "formula-ref" }
									break
								end
							end
						end
					end
				end
			end
		end
	end
	return out
end

-- defineName(name, ref, opts?) — a defined name (named range). `ref` is a formula
-- like "Sheet1!$A$1:$B$2". opts.sheet (a worksheet name) scopes it locally to that
-- sheet (emitted with localSheetId); omitted → workbook-global.
function Workbook.defineName(self, name, ref, opts)
	opts = opts or {}
	self.definedNames = self.definedNames or {}
	local localSheetId
	if opts.sheet then
		for i, ws in ipairs(self.worksheets) do
			if ws.name == opts.sheet then localSheetId = i - 1 end
		end
	end
	self.definedNames[#self.definedNames + 1] = { name = name, ref = ref, localSheetId = localSheetId }
	return self
end

-- setColumns(defs) — defs[i] = { header?, key?, width?, style? }. A header writes
-- row 1; `key` lets addRow accept keyed objects; width sets the column width.
function Worksheet.setColumns(self, defs)
	self.columns = defs
	self._nextRow = self._nextRow or 1
	local hasHeader = false
	for _, d in ipairs(defs) do
		if d.header then hasHeader = true end
	end
	if hasHeader then
		for i, d in ipairs(defs) do
			if d.header then
				self:setCell(make_ref(i, 1), d.header, d.style)
			end
		end
		self._nextRow = 2
	end
	return self
end

-- setCell(ref, value, style?) — value is a raw Luau value or a CellValue.
function Worksheet.setCell(self, ref, value, style)
	local c, r = parse_ref(ref)
	local row = self.rows[r]
	if not row then
		row = { number = r, cells = {} }
		self.rows[r] = row
	end
	row.cells[c] = { ref = ref, value = coerce(value), style = style }
	if c > self._maxCol then self._maxCol = c end
	if r > self._maxRow then self._maxRow = r end
	return row.cells[c]
end

-- cell(ref) → the Cell (created empty if absent), for fluent styling/value.
function Worksheet.cell(self, ref)
	local c, r = parse_ref(ref)
	local row = self.rows[r]
	if row and row.cells[c] then return row.cells[c] end
	return self:setCell(ref, nil)
end

-- addRow(values) — append a row at the next free row. `values` is an array
-- (positional) or, when columns have keys, a keyed object.
function Worksheet.addRow(self, values)
	local rownum = (self._nextRow or (self._maxRow + 1))
	self._nextRow = rownum + 1
	if values[1] ~= nil or next(values) == nil then
		for i, v in ipairs(values) do
			self:setCell(make_ref(i, rownum), v)
		end
	else
		assert(self.columns, "xlsx: addRow with a keyed object needs setColumns first")
		for i, d in ipairs(self.columns) do
			if d.key and values[d.key] ~= nil then
				self:setCell(make_ref(i, rownum), values[d.key], d.style)
			end
		end
	end
	return self
end

function Worksheet.mergeCells(self, range)
	self.merges[#self.merges + 1] = range
	return self
end

-- freezePanes(ref) — freeze the rows above and columns left of `ref` (Excel's
-- convention: `freezePanes("B2")` freezes row 1 and column A). `ref` is the
-- top-left unfrozen cell; pass nil to clear.
function Worksheet.freezePanes(self, ref)
	self.freeze = ref
	return self
end

-- setAutoFilter(range) — attach an AutoFilter over `range` ("A1:C10").
function Worksheet.setAutoFilter(self, range)
	self.autoFilter = range
	return self
end

-- addDataValidation(opts) — opts: type ("list"|"whole"|"decimal"|"date"|"time"|
-- "textLength"|"custom"), sqref (cell/range), operator? ("between"|"greaterThan"|…),
-- formula1, formula2?, allowBlank? (default true), prompt?/promptTitle?,
-- error?/errorTitle?. A dropdown list uses type="list", formula1='"A,B,C"' or a range.
function Worksheet.addDataValidation(self, opts)
	self.dataValidations = self.dataValidations or {}
	self.dataValidations[#self.dataValidations + 1] = opts
	return self
end

-- addConditionalFormat(opts) — opts: sqref, type ("cellIs"|"expression"|
-- "containsText"|"notContainsText"|"duplicateValues"|…), operator? (cellIs/text),
-- formula / formulas (array) / text, dxf (a partial style { fill?, font? }),
-- priority?. The dxf is interned into styles.xml's <dxfs> at save.
function Worksheet.addConditionalFormat(self, opts)
	self.conditionalFormats = self.conditionalFormats or {}
	self.conditionalFormats[#self.conditionalFormats + 1] = opts
	return self
end

-- setComment(ref, text, opts?) — attach a cell comment/note. opts.author (default
-- "Author"). (The legacy VML note-box is presentation/rendering and is omitted; the
-- comment data is fully present and read by real readers.)
function Worksheet.setComment(self, ref, text, opts)
	opts = opts or {}
	self.comments = self.comments or {}
	self.comments[#self.comments + 1] = { ref = ref, text = text, author = opts.author or "Author" }
	return self
end

-- addTable(opts) — define an Excel table over opts.ref ("A1:C4", header row first).
-- opts.name (unique, no spaces), opts.columns? (header names; derived from the ref's
-- first row when omitted), opts.style?. Column names must match the header cells.
function Worksheet.addTable(self, opts)
	self.tables = self.tables or {}
	local columns = opts.columns
	if not columns then
		columns = {}
		local fromRef = opts.ref:match("^(%a+%d+)")
		local toRef = opts.ref:match(":(%a+%d+)$") or fromRef
		local c0, r0 = parse_ref(fromRef)
		local c1 = parse_ref(toRef)
		local row = self.rows[r0]
		for c = c0, c1 do
			local cell = row and row.cells[c]
			columns[#columns + 1] = (cell and cell.value.kind == "string" and cell.value.value)
				or ("Column" .. (c - c0 + 1))
		end
	end
	self.tables[#self.tables + 1] = { name = opts.name, ref = opts.ref, columns = columns, style = opts.style }
	return self
end

-- addImage(bytes, opts?) — anchor an image. opts.at = a cell ref ("B2") for the
-- top-left corner; width/height in EMU (auto-sized from intrinsic px when omitted).
function Worksheet.addImage(self, bytes, opts)
	opts = opts or {}
	local col, row = 0, 0
	if opts.at then
		local c, r = parse_ref(opts.at)
		col, row = c - 1, r - 1 -- xdr anchors are 0-based
	end
	self.images[#self.images + 1] = { bytes = bytes, col = col, row = row, w = opts.width, h = opts.height }
	return self
end

-- addHyperlink(ref, url) — attach a hyperlink to a cell (or range) `ref`.
function Worksheet.addHyperlink(self, ref, url)
	self.hyperlinks[#self.hyperlinks + 1] = { ref = ref, url = url }
	return self
end

-- addChart(model, opts?) — anchor a chart. model = { type, title?, categories,
-- series={{name,values}…} } referencing THIS sheet's data (lay the data out as
-- categories in column A and series in B, C, …, with names in row 1). opts.at = a
-- cell ref for the top-left corner; width/height in EMU.
function Worksheet.addChart(self, model, opts)
	opts = opts or {}
	local col, row = 5, 0 -- default near column F
	if opts.at then
		local c, r = parse_ref(opts.at)
		col, row = c - 1, r - 1
	end
	self.charts[#self.charts + 1] = {
		model = model, col = col, row = row, w = opts.width or 4572000, h = opts.height or 2743200,
	}
	return self
end

-- eachRow(fn) / cells in row order — read-side iteration.
function Worksheet.eachRow(self, fn)
	for r = 1, self._maxRow do
		if self.rows[r] then fn(self.rows[r], r) end
	end
end

-- iterRows() → a stateless iterator over (rownum, row) for populated rows only:
--   for rnum, row in ws:iterRows() do … end
-- A read-only, bounded-per-step traversal (the row-iterator read mode). Named
-- iterRows (not rows) because `ws.rows` is the row-storage field.
function Worksheet.iterRows(self)
	local r = 0
	return function()
		r += 1
		while r <= self._maxRow do
			if self.rows[r] then return r, self.rows[r] end
			r += 1
		end
		return nil
	end
end

-- ===========================================================================
-- Write
-- ===========================================================================

-- Pure render of one cell, reading the indices `prepare` annotated (`_styleId` /
-- `_ssIndex`). No interning happens here (two-phase build, Ch.05 §5.6).
local function encode_cell(cell, inlineStrings)
	local v = cell.value
	local attrs = { r = cell.ref }
	if cell._styleId and cell._styleId ~= 0 then attrs.s = tostring(cell._styleId) end
	local kind = v.kind

	if kind == "empty" then
		if not attrs.s then return nil end
		return xml.element("c", attrs)
	elseif kind == "number" or kind == "date" then
		return xml.element("c", attrs, { xml.element("v", {}, { xml.text(tostring(v.value)) }) })
	elseif kind == "string" then
		if inlineStrings then
			attrs.t = "inlineStr"
			return xml.element("c", attrs, { xml.element("is", {}, { xml.element("t", {}, { xml.text(v.value) }) }) })
		end
		attrs.t = "s"
		return xml.element("c", attrs, { xml.element("v", {}, { xml.text(tostring(cell._ssIndex)) }) })
	elseif kind == "inlineStr" then
		attrs.t = "inlineStr"
		return xml.element("c", attrs, { xml.element("is", {}, { xml.element("t", {}, { xml.text(v.value) }) }) })
	elseif kind == "boolean" then
		attrs.t = "b"
		return xml.element("c", attrs, { xml.element("v", {}, { xml.text(v.value and "1" or "0") }) })
	elseif kind == "error" then
		attrs.t = "e"
		return xml.element("c", attrs, { xml.element("v", {}, { xml.text(v.value) }) })
	elseif kind == "formula" then
		local kids = { xml.element("f", {}, { xml.text(v.formula) }) }
		if v.result ~= nil then
			local rv = coerce(v.result)
			-- the cached <v> must carry the result's type (t="str"/"b"/"e"); a string
			-- result with no t would be misread as a number
			local rk = rv.kind
			if rk == "string" or rk == "inlineStr" then
				attrs.t = "str"
				kids[#kids + 1] = xml.element("v", {}, { xml.text(rv.value) })
			elseif rk == "boolean" then
				attrs.t = "b"
				kids[#kids + 1] = xml.element("v", {}, { xml.text(rv.value and "1" or "0") })
			elseif rk == "error" then
				attrs.t = "e"
				kids[#kids + 1] = xml.element("v", {}, { xml.text(rv.value) })
			else
				kids[#kids + 1] = xml.element("v", {}, { xml.text(tostring(rv.value)) })
			end
		end
		return xml.element("c", attrs, kids)
	end
	return xml.element("c", attrs)
end

-- The effective style a cell renders with — its own, plus a date format injected
-- for date cells that lack one (so Excel shows a date, not a serial).
local function effective_style(cell)
	local v = cell.value
	if v.kind == "date" then
		local style = cell.style and { numberFormat = cell.style.numberFormat, font = cell.style.font,
			fill = cell.style.fill, border = cell.style.border, alignment = cell.style.alignment } or {}
		style.numberFormat = style.numberFormat or DEFAULT_DATE_FMT
		return style
	end
	return cell.style
end

-- Phase 1: walk a worksheet's cells, interning styles + shared strings into the
-- pools and annotating each cell with its `_styleId` / `_ssIndex`. Pure of XML.
local function prepare_worksheet(ws, st, sst)
	for r = 1, ws._maxRow do
		local row = ws.rows[r]
		if row then
			for c = 1, ws._maxCol do
				local cell = row.cells[c]
				if cell then
					cell._styleId = st.intern(effective_style(cell))
					if cell.value.kind == "string" and not ws.inlineStrings then
						cell._ssIndex = sst.intern(cell.value.value)
					end
				end
			end
		end
	end
	-- intern conditional-formatting dxfs (→ styles.xml <dxfs>; rule reads _dxfId)
	for _, cf in ipairs(ws.conditionalFormats or {}) do
		cf._dxfId = st.intern_dxf(cf.dxf)
	end
end

local function render_worksheet(ws)
	local root = xml.element("worksheet", { xmlns = NS_MAIN, ["xmlns:r"] = NS_R })

	-- dimension (schema order: first)
	if ws._maxRow > 0 then
		root.children[#root.children + 1] =
			xml.element("dimension", { ref = "A1:" .. make_ref(ws._maxCol, ws._maxRow) })
	end

	-- sheetViews (freeze panes) — after dimension, before cols
	if ws.freeze then
		local c, r = parse_ref(ws.freeze)
		local xSplit, ySplit = c - 1, r - 1
		local activePane = (xSplit > 0 and ySplit > 0) and "bottomRight"
			or (ySplit > 0) and "bottomLeft" or "topRight"
		local paneAttrs = { topLeftCell = ws.freeze, activePane = activePane, state = "frozen" }
		if xSplit > 0 then paneAttrs.xSplit = tostring(xSplit) end
		if ySplit > 0 then paneAttrs.ySplit = tostring(ySplit) end
		root.children[#root.children + 1] = xml.element("sheetViews", {}, {
			xml.element("sheetView", { workbookViewId = "0" }, {
				xml.element("pane", paneAttrs),
				xml.element("selection", { pane = activePane, activeCell = ws.freeze, sqref = ws.freeze }),
			}),
		})
	end

	-- cols (before sheetData)
	if ws.columns then
		local cols = xml.element("cols")
		for i, d in ipairs(ws.columns) do
			if d.width then
				cols.children[#cols.children + 1] = xml.element("col", {
					min = tostring(i), max = tostring(i), width = tostring(d.width), customWidth = "1",
				})
			end
		end
		if #cols.children > 0 then root.children[#root.children + 1] = cols end
	end

	-- sheetData
	local sheetData = xml.element("sheetData")
	for r = 1, ws._maxRow do
		local row = ws.rows[r]
		if row then
			local rowEl = xml.element("row", { r = tostring(r) })
			if row.height then rowEl.attributes[#rowEl.attributes + 1] = { name = xml.name("ht"), value = tostring(row.height) } end
			for c = 1, ws._maxCol do
				local cell = row.cells[c]
				if cell then
					local cEl = encode_cell(cell, ws.inlineStrings)
					if cEl then rowEl.children[#rowEl.children + 1] = cEl end
				end
			end
			sheetData.children[#sheetData.children + 1] = rowEl
		end
	end
	root.children[#root.children + 1] = sheetData

	-- autoFilter (after sheetData, before mergeCells)
	if ws.autoFilter then
		root.children[#root.children + 1] = xml.element("autoFilter", { ref = ws.autoFilter })
	end

	-- mergeCells (after sheetData)
	if #ws.merges > 0 then
		local mc = xml.element("mergeCells", { count = tostring(#ws.merges) })
		for _, range in ipairs(ws.merges) do
			mc.children[#mc.children + 1] = xml.element("mergeCell", { ref = range })
		end
		root.children[#root.children + 1] = mc
	end

	-- conditionalFormatting (after mergeCells, before dataValidations); one block per
	-- entry, the rule referencing the interned dxfId from prepare
	for i, cf in ipairs(ws.conditionalFormats or {}) do
		local ruleAttrs = { type = cf.type, priority = tostring(cf.priority or i) }
		if cf._dxfId then ruleAttrs.dxfId = tostring(cf._dxfId) end
		if cf.operator then ruleAttrs.operator = cf.operator end
		if cf.text then ruleAttrs.text = cf.text end
		local rule = xml.element("cfRule", ruleAttrs)
		local formulas = cf.formulas or (cf.formula ~= nil and { cf.formula }) or {}
		for _, f in ipairs(formulas) do
			rule.children[#rule.children + 1] = xml.element("formula", {}, { xml.text(tostring(f)) })
		end
		root.children[#root.children + 1] = xml.element("conditionalFormatting", { sqref = cf.sqref }, { rule })
	end

	-- dataValidations (after conditionalFormatting, before hyperlinks)
	if ws.dataValidations and #ws.dataValidations > 0 then
		local dvs = xml.element("dataValidations", { count = tostring(#ws.dataValidations) })
		for _, dv in ipairs(ws.dataValidations) do
			local a = {
				type = dv.type, sqref = dv.sqref or dv.ref,
				allowBlank = (dv.allowBlank ~= false) and "1" or "0",
				showInputMessage = "1", showErrorMessage = "1",
			}
			if dv.operator then a.operator = dv.operator end
			if dv.promptTitle then a.promptTitle = dv.promptTitle end
			if dv.prompt then a.prompt = dv.prompt end
			if dv.errorTitle then a.errorTitle = dv.errorTitle end
			if dv.error then a.error = dv.error end
			local dvEl = xml.element("dataValidation", a)
			if dv.formula1 then dvEl.children[#dvEl.children + 1] = xml.element("formula1", {}, { xml.text(dv.formula1) }) end
			if dv.formula2 then dvEl.children[#dvEl.children + 1] = xml.element("formula2", {}, { xml.text(dv.formula2) }) end
			dvs.children[#dvs.children + 1] = dvEl
		end
		root.children[#root.children + 1] = dvs
	end

	-- hyperlinks (schema order: after mergeCells; r:id allocated in prepare)
	if #ws.hyperlinks > 0 then
		local hl = xml.element("hyperlinks")
		for _, h in ipairs(ws.hyperlinks) do
			hl.children[#hl.children + 1] = xml.element("hyperlink", { ref = h.ref, ["r:id"] = h._rid })
		end
		root.children[#root.children + 1] = hl
	end

	-- drawing (near the end) — references the worksheet's drawing part
	if ws._drawingRid then
		root.children[#root.children + 1] = xml.element("drawing", { ["r:id"] = ws._drawingRid })
	end

	-- tableParts (schema order: last) — one tablePart per table rel from prepare
	if ws._tableRids and #ws._tableRids > 0 then
		local tp = xml.element("tableParts", { count = tostring(#ws._tableRids) })
		for _, rid in ipairs(ws._tableRids) do
			tp.children[#tp.children + 1] = xml.element("tablePart", { ["r:id"] = rid })
		end
		root.children[#root.children + 1] = tp
	end
	return root
end

-- A worksheet's drawing part (xl/drawings/drawingN.xml): one oneCellAnchor per
-- image, each a:blip referencing the media via the rId allocated in prepare.
local function render_drawing(ws)
	local root = xml.element("xdr:wsDr", { ["xmlns:xdr"] = NS_XDR, ["xmlns:a"] = NS_A, ["xmlns:r"] = NS_R })
	for idx, img in ipairs(ws.images) do
		root.children[#root.children + 1] = xml.element("xdr:oneCellAnchor", {}, {
			xml.element("xdr:from", {}, {
				xml.element("xdr:col", {}, { xml.text(tostring(img.col)) }),
				xml.element("xdr:colOff", {}, { xml.text("0") }),
				xml.element("xdr:row", {}, { xml.text(tostring(img.row)) }),
				xml.element("xdr:rowOff", {}, { xml.text("0") }),
			}),
			xml.element("xdr:ext", { cx = tostring(img.w or 914400), cy = tostring(img.h or 914400) }),
			xml.element("xdr:pic", {}, {
				xml.element("xdr:nvPicPr", {}, {
					xml.element("xdr:cNvPr", { id = tostring(idx + 1), name = "Image " .. idx }),
					xml.element("xdr:cNvPicPr"),
				}),
				xml.element("xdr:blipFill", {}, {
					xml.element("a:blip", { ["r:embed"] = img._rid }),
					xml.element("a:stretch", {}, { xml.element("a:fillRect") }),
				}),
				xml.element("xdr:spPr", {}, {
					xml.element("a:xfrm", {}, {
						xml.element("a:off", { x = "0", y = "0" }),
						xml.element("a:ext", { cx = tostring(img.w or 914400), cy = tostring(img.h or 914400) }),
					}),
					xml.element("a:prstGeom", { prst = "rect" }, { xml.element("a:avLst") }),
				}),
			}),
			xml.element("xdr:clientData"),
		})
	end
	-- charts: a graphicFrame per chart, referencing its chart part by rId
	for idx, ch in ipairs(ws.charts) do
		root.children[#root.children + 1] = xml.element("xdr:oneCellAnchor", {}, {
			xml.element("xdr:from", {}, {
				xml.element("xdr:col", {}, { xml.text(tostring(ch.col)) }),
				xml.element("xdr:colOff", {}, { xml.text("0") }),
				xml.element("xdr:row", {}, { xml.text(tostring(ch.row)) }),
				xml.element("xdr:rowOff", {}, { xml.text("0") }),
			}),
			xml.element("xdr:ext", { cx = tostring(ch.w), cy = tostring(ch.h) }),
			xml.element("xdr:graphicFrame", { macro = "" }, {
				xml.element("xdr:nvGraphicFramePr", {}, {
					xml.element("xdr:cNvPr", { id = tostring(#ws.images + idx + 1), name = "Chart " .. idx }),
					xml.element("xdr:cNvGraphicFramePr"),
				}),
				xml.element("xdr:xfrm", {}, {
					xml.element("a:off", { x = "0", y = "0" }),
					xml.element("a:ext", { cx = tostring(ch.w), cy = tostring(ch.h) }),
				}),
				xml.element("a:graphic", {}, {
					xml.element("a:graphicData", { uri = "http://schemas.openxmlformats.org/drawingml/2006/chart" }, {
						xml.element("c:chart", {
							["xmlns:c"] = "http://schemas.openxmlformats.org/drawingml/2006/chart",
							["xmlns:r"] = NS_R,
							["r:id"] = ch._rid,
						}),
					}),
				}),
			}),
			xml.element("xdr:clientData"),
		})
	end
	return root
end

-- A table part (xl/tables/tableN.xml): the ref + an autoFilter + one tableColumn per
-- header (names MUST match the header row's cell text), with a default table style.
local function render_table(tbl, id)
	local cols = xml.element("tableColumns", { count = tostring(#tbl.columns) })
	for ci, name in ipairs(tbl.columns) do
		cols.children[#cols.children + 1] = xml.element("tableColumn", { id = tostring(ci), name = name })
	end
	return xml.element("table", {
		xmlns = NS_MAIN, id = tostring(id), name = tbl.name, displayName = tbl.name,
		ref = tbl.ref, totalsRowShown = "0",
	}, {
		xml.element("autoFilter", { ref = tbl.ref }),
		cols,
		xml.element("tableStyleInfo", {
			name = tbl.style or "TableStyleMedium2",
			showFirstColumn = "0", showLastColumn = "0", showRowStripes = "1", showColumnStripes = "0",
		}),
	})
end

-- A worksheet's comments part (xl/commentsN.xml): an author list (deduped) + one
-- <comment> per cell note, the text as a single rich run.
local function render_comments(ws)
	local authorIds, authors = {}, {}
	for _, cm in ipairs(ws.comments) do
		local a = cm.author or "Author"
		if authorIds[a] == nil then
			authorIds[a] = #authors
			authors[#authors + 1] = a
		end
	end
	local root = xml.element("comments", { xmlns = NS_MAIN })
	local authorsEl = xml.element("authors")
	for _, a in ipairs(authors) do
		authorsEl.children[#authorsEl.children + 1] = xml.element("author", {}, { xml.text(a) })
	end
	root.children[1] = authorsEl
	local list = xml.element("commentList")
	for _, cm in ipairs(ws.comments) do
		list.children[#list.children + 1] = xml.element("comment",
			{ ref = cm.ref, authorId = tostring(authorIds[cm.author or "Author"]) }, {
				xml.element("text", {}, {
					xml.element("r", {}, { xml.element("t", {}, { xml.text(cm.text or "") }) }),
				}),
			})
	end
	root.children[2] = list
	return root
end

local function doc(root)
	return { kind = "document", prolog = {}, root = root }
end

local function render_shared_strings(sst)
	local root = xml.element("sst", {
		xmlns = NS_MAIN, count = tostring(sst.totalRefs), uniqueCount = tostring(#sst.list),
	})
	for _, s in ipairs(sst.list) do
		-- xml:space="preserve" keeps significant leading/trailing whitespace.
		local t = xml.element("t", {}, { xml.text(s) })
		if s ~= (s:gsub("^%s+", ""):gsub("%s+$", "")) then
			t.attributes[#t.attributes + 1] = { name = xml.name("xml:space"), value = "preserve" }
		end
		root.children[#root.children + 1] = xml.element("si", {}, { t })
	end
	return root
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
	add("dc:subject", core.subject)
	add("dc:creator", core.creator)
	add("cp:keywords", core.keywords)
	add("dc:description", core.description)
	add("cp:lastModifiedBy", core.lastModifiedBy or core.creator)
	return root
end

local function render_app_props()
	return xml.element("Properties", { xmlns = NS_EXT }, {
		xml.element("Application", {}, { xml.text("memcontainers/xlsx") }),
	})
end

-- toBytes() → the .xlsx bytes. Two-phase: a first walk interns strings + styles,
-- the second renders every part reading the interned indices.
function Workbook.toBytes(self)
	local sst = { list = {}, index = {}, totalRefs = 0 }
	function sst.intern(s)
		sst.totalRefs += 1
		if sst.index[s] ~= nil then return sst.index[s] end
		sst.list[#sst.list + 1] = s
		sst.index[s] = #sst.list - 1
		return #sst.list - 1
	end
	local st = new_style_table()

	-- PHASE 1 — prepare: intern styles + strings across every sheet (deterministic,
	-- walk-order indices), so PHASE 2 render is pure and part-render-order can't
	-- affect output (the coupling the two-phase build exists to remove, Ch.05 §5.6).
	for _, ws in ipairs(self.worksheets) do
		prepare_worksheet(ws, st, sst)
	end

	local pkg = opc.new()
	pkg.contentTypes.defaults.rels = "application/vnd.openxmlformats-package.relationships+xml"

	-- workbook rels: worksheets first (their rId must match workbook.xml), then
	-- styles / sharedStrings.
	local wbRels = pkg:relsFor("/xl/workbook.xml")
	local sheetRefs = {}
	local mediaReg = media.registry() -- content-addressed, shared across sheets
	local nChart = 0 -- chart counter across the workbook
	local nTable = 0 -- table counter across the workbook
	for i, ws in ipairs(self.worksheets) do
		local target = "worksheets/sheet" .. i .. ".xml"
		local rid = wbRels:add(RELT.worksheet, target)
		sheetRefs[i] = { rid = rid, target = "/xl/" .. target }

		-- PHASE 1 (images/hyperlinks/charts/comments/tables): allocate the worksheet's
		-- rels — hyperlink externals + a drawing part (whose own rels point at the
		-- media and chart parts) + the comments part + table parts.
		if #ws.hyperlinks > 0 or #ws.images > 0 or #ws.charts > 0
			or (ws.comments and #ws.comments > 0) or (ws.tables and #ws.tables > 0)
		then
			local wsRels = pkg:relsFor(sheetRefs[i].target)
			for _, h in ipairs(ws.hyperlinks) do
				h._rid = wsRels:add(RELT.hyperlink, h.url, "External")
			end
			if #ws.images > 0 or #ws.charts > 0 then
				local drawingName = "drawing" .. i .. ".xml"
				ws._drawingRid = wsRels:add(RELT.drawing, "../drawings/" .. drawingName)
				local drawingRels = pkg:relsFor("/xl/drawings/" .. drawingName)
				for _, img in ipairs(ws.images) do
					local entry = mediaReg.add(img.bytes)
					img._rid = drawingRels:add(RELT.image, "../media/" .. entry.name)
					if not img.w and entry.widthPx then
						img.w = entry.widthPx * media.EMU_PER_PX
						img.h = entry.heightPx * media.EMU_PER_PX
					end
				end
				for ci, ch in ipairs(ws.charts) do
					nChart += 1
					local chartName = "chart" .. nChart .. ".xml"
					ch._rid = drawingRels:add(RELT.chart, "../charts/" .. chartName)
					-- the chart references this worksheet's own cells (no embedded
					-- workbook — the data lives in the host sheet)
					pkg:addPart("/xl/charts/" .. chartName, doc(chart.render(ch.model, { sheet = ws.name })), CT.chart)
				end
				pkg:addPart("/xl/drawings/" .. drawingName, doc(render_drawing(ws)), CT.drawing)
			end
			-- comments part (xl/commentsN.xml) + the worksheet → comments rel
			if ws.comments and #ws.comments > 0 then
				local cName = "comments" .. i .. ".xml"
				wsRels:add(RELT.comments, "../" .. cName)
				pkg:addPart("/xl/" .. cName, doc(render_comments(ws)), CT.comments)
			end
			-- table parts (xl/tables/tableN.xml) + the worksheet → table rels (the
			-- rIds are read back by render_worksheet's <tableParts>)
			if ws.tables and #ws.tables > 0 then
				ws._tableRids = {}
				for _, tbl in ipairs(ws.tables) do
					nTable += 1
					local tName = "table" .. nTable .. ".xml"
					ws._tableRids[#ws._tableRids + 1] = wsRels:add(RELT.table, "../tables/" .. tName)
					pkg:addPart("/xl/tables/" .. tName, doc(render_table(tbl, nTable)), CT.table)
				end
			end
		end
		pkg:addPart(sheetRefs[i].target, doc(render_worksheet(ws)), CT.worksheet)
	end

	-- media parts + their content-type defaults (png/jpeg/gif)
	for _, entry in ipairs(mediaReg.items) do
		pkg.contentTypes.defaults[entry.ext] = entry.contentType
		pkg:addPart("/xl/media/" .. entry.name, entry.bytes)
	end
	wbRels:add(RELT.styles, "styles.xml")
	pkg:addPart("/xl/styles.xml", doc(render_styles(st)), CT.styles)
	if #sst.list > 0 then
		wbRels:add(RELT.sharedStrings, "sharedStrings.xml")
		pkg:addPart("/xl/sharedStrings.xml", doc(render_shared_strings(sst)), CT.sharedStrings)
	end

	-- workbook.xml
	local wbRoot = xml.element("workbook", { xmlns = NS_MAIN, ["xmlns:r"] = NS_R })
	local sheets = xml.element("sheets")
	for i, ws in ipairs(self.worksheets) do
		sheets.children[#sheets.children + 1] = xml.element("sheet", {
			name = ws.name, sheetId = tostring(ws.sheetId), ["r:id"] = sheetRefs[i].rid,
		})
	end
	wbRoot.children[1] = sheets
	-- definedNames (named ranges) — schema order: after sheets
	if self.definedNames and #self.definedNames > 0 then
		local dn = xml.element("definedNames")
		for _, d in ipairs(self.definedNames) do
			local a = { name = d.name }
			if d.localSheetId then a.localSheetId = tostring(d.localSheetId) end
			dn.children[#dn.children + 1] = xml.element("definedName", a, { xml.text(d.ref) })
		end
		wbRoot.children[#wbRoot.children + 1] = dn
	end
	pkg:addPart("/xl/workbook.xml", doc(wbRoot), CT.workbook)

	-- docProps + root rels
	pkg:addPart("/docProps/core.xml", doc(render_core_props(self.properties.core)), CT.core)
	pkg:addPart("/docProps/app.xml", doc(render_app_props()), CT.app)
	local rootRels = pkg:relsFor("/")
	rootRels:add(RELT.officeDocument, "xl/workbook.xml")
	rootRels:add(RELT.core, "docProps/core.xml")
	rootRels:add(RELT.app, "docProps/app.xml")

	return opc.write(pkg)
end

function Workbook.save(self, path)
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

-- Parse styles.xml → { numFmt = {[id]=code}, cellXfs = {[s]=numFmtId} } (enough to
-- classify date vs number on read).
local function parse_styles(el)
	local numFmt = {}
	local nfs = child(el, "numFmts")
	if nfs then
		for _, n in ipairs(children(nfs, "numFmt")) do
			numFmt[tonumber(attr(n, "numFmtId"))] = attr(n, "formatCode")
		end
	end
	local cellXfs = {}
	local xfs = child(el, "cellXfs")
	if xfs then
		local i = 0
		for _, xf in ipairs(children(xfs, "xf")) do
			cellXfs[i] = tonumber(attr(xf, "numFmtId")) or 0
			i += 1
		end
	end
	-- dxfs (differential formats) → list of { fill?, font? } indexed 1-based (dxfId+1)
	local dxfs = {}
	local dxfsEl = child(el, "dxfs")
	if dxfsEl then
		for _, d in ipairs(children(dxfsEl, "dxf")) do
			local dxf = {}
			local fontEl = child(d, "font")
			if fontEl then
				dxf.font = {}
				if child(fontEl, "b") then dxf.font.bold = true end
				if child(fontEl, "i") then dxf.font.italic = true end
				local cEl = child(fontEl, "color")
				if cEl then dxf.font.color = attr(cEl, "rgb") end
			end
			local fillEl = child(d, "fill")
			local pf = fillEl and child(fillEl, "patternFill")
			local bg = pf and child(pf, "bgColor")
			if bg then dxf.fill = attr(bg, "rgb") end
			dxfs[#dxfs + 1] = dxf
		end
	end
	return { numFmt = numFmt, cellXfs = cellXfs, dxfs = dxfs }
end

local function is_date_fmt(code)
	if not code then return false end
	return code:find("[ymdhsYMDHS]") ~= nil and not code:find("[#0]")
end

-- An r:-prefixed attribute value (r:id / r:embed), matched by prefix + local name.
local function r_attr(el, lname)
	for _, a in ipairs(el.attributes) do
		if a.name.prefix == "r" and a.name.local_ == lname then return a.value end
	end
	return nil
end

-- Parse a drawing part → (images, charts). Each anchor holds either an xdr:pic
-- (resolve a:blip r:embed → media bytes) or an xdr:graphicFrame (resolve the
-- c:chart r:id → the chart part → its model).
local function parse_drawing(el, pkg, rels)
	local images, charts = {}, {}
	for _, anchor in ipairs(el.children) do
		if anchor.kind == "element"
			and (anchor.name.local_ == "oneCellAnchor" or anchor.name.local_ == "twoCellAnchor") then
			local from = child(anchor, "from")
			local col = from and tonumber(xml.textOf(child(from, "col")))
			local row = from and tonumber(xml.textOf(child(from, "row")))
			local ext = child(anchor, "ext")
			local w = ext and tonumber(attr(ext, "cx"))
			local h = ext and tonumber(attr(ext, "cy"))
			local pic = child(anchor, "pic")
			local gf = child(anchor, "graphicFrame")
			if pic then
				local img = { col = col, row = row, w = w, h = h }
				local blipFill = child(pic, "blipFill")
				local blip = blipFill and child(blipFill, "blip")
				if blip and rels then
					local part = pkg:getPart(rels:targetOf(r_attr(blip, "embed")) or "")
					if part then img.bytes = part.bytes end
				end
				images[#images + 1] = img
			elseif gf then
				local ch = { col = col, row = row, w = w, h = h }
				local graphic = child(gf, "graphic")
				local gdata = graphic and child(graphic, "graphicData")
				local cchart = gdata and child(gdata, "chart")
				if cchart and rels then
					local part = pkg:getPart(rels:targetOf(r_attr(cchart, "id")) or "")
					if part then
						local cd = xml.parse(part.bytes)
						if cd then ch.model = chart.parse(cd.root) end
					end
				end
				charts[#charts + 1] = ch
			end
		end
	end
	return images, charts
end

local function parse_worksheet(el, sharedStrings, styles, pkg, wsRels)
	local ws = setmetatable({
		name = "", rows = {}, merges = {}, images = {}, hyperlinks = {}, charts = {}, _maxCol = 0, _maxRow = 0,
	}, Worksheet)
	local sheetData = child(el, "sheetData")
	if sheetData then
		for _, rowEl in ipairs(children(sheetData, "row")) do
			local r = tonumber(attr(rowEl, "r"))
			local row = { number = r, cells = {} }
			ws.rows[r] = row
			if r > ws._maxRow then ws._maxRow = r end
			for _, cEl in ipairs(children(rowEl, "c")) do
				local ref = attr(cEl, "r")
				local c = parse_ref(ref)
				local t = attr(cEl, "t")
				local s = tonumber(attr(cEl, "s"))
				local fEl = child(cEl, "f")
				local vEl = child(cEl, "v")
				local value
				if fEl then
					-- the cached result type follows the cell's t (str/b/e), else number
					local result
					if vEl then
						local raw = xml.textOf(vEl)
						if t == "str" then result = { kind = "string", value = raw }
						elseif t == "b" then result = { kind = "boolean", value = raw == "1" }
						elseif t == "e" then result = { kind = "error", value = raw }
						else result = { kind = "number", value = tonumber(raw) } end
					end
					value = { kind = "formula", formula = xml.textOf(fEl), result = result }
				elseif t == "s" then
					value = { kind = "string", value = sharedStrings[tonumber(xml.textOf(vEl)) + 1] or "" }
				elseif t == "inlineStr" then
					local is = child(cEl, "is")
					value = { kind = "string", value = is and xml.textOf(child(is, "t") or is) or "" }
				elseif t == "b" then
					value = { kind = "boolean", value = xml.textOf(vEl) == "1" }
				elseif t == "e" then
					value = { kind = "error", value = xml.textOf(vEl) }
				elseif t == "str" then
					value = { kind = "string", value = vEl and xml.textOf(vEl) or "" }
				else
					local num = vEl and tonumber(xml.textOf(vEl)) or nil
					local code = s and styles.numFmt[styles.cellXfs[s]]
					if num and is_date_fmt(code) then
						value = { kind = "date", value = num }
					else
						value = { kind = "number", value = num }
					end
				end
				row.cells[c] = { ref = ref, value = value, styleId = s }
				if c > ws._maxCol then ws._maxCol = c end
			end
		end
	end
	-- freeze panes (sheetViews → sheetView → pane@topLeftCell)
	local sviews = child(el, "sheetViews")
	local sview = sviews and child(sviews, "sheetView")
	local pane = sview and child(sview, "pane")
	if pane and attr(pane, "state") == "frozen" then
		ws.freeze = attr(pane, "topLeftCell")
	end

	-- autoFilter
	local af = child(el, "autoFilter")
	if af then ws.autoFilter = attr(af, "ref") end

	-- conditional formatting (resolve dxfId → the parsed dxf from styles.xml)
	for _, cfEl in ipairs(children(el, "conditionalFormatting")) do
		local sqref = attr(cfEl, "sqref")
		for _, rule in ipairs(children(cfEl, "cfRule")) do
			local formulas = {}
			for _, f in ipairs(children(rule, "formula")) do
				formulas[#formulas + 1] = xml.textOf(f)
			end
			local dxfId = tonumber(attr(rule, "dxfId"))
			ws.conditionalFormats = ws.conditionalFormats or {}
			ws.conditionalFormats[#ws.conditionalFormats + 1] = {
				sqref = sqref, type = attr(rule, "type"), operator = attr(rule, "operator"),
				text = attr(rule, "text"), priority = tonumber(attr(rule, "priority")),
				formulas = formulas, formula = formulas[1],
				dxf = dxfId ~= nil and styles.dxfs and styles.dxfs[dxfId + 1] or nil,
			}
		end
	end

	-- data validations
	local dvsEl = child(el, "dataValidations")
	if dvsEl then
		ws.dataValidations = {}
		for _, dv in ipairs(children(dvsEl, "dataValidation")) do
			local f1, f2 = child(dv, "formula1"), child(dv, "formula2")
			ws.dataValidations[#ws.dataValidations + 1] = {
				type = attr(dv, "type"), sqref = attr(dv, "sqref"), operator = attr(dv, "operator"),
				formula1 = f1 and xml.textOf(f1) or nil, formula2 = f2 and xml.textOf(f2) or nil,
				allowBlank = attr(dv, "allowBlank") == "1",
			}
		end
	end

	local mc = child(el, "mergeCells")
	if mc then
		for _, m in ipairs(children(mc, "mergeCell")) do
			ws.merges[#ws.merges + 1] = attr(m, "ref")
		end
	end

	-- hyperlinks → resolve r:id to the external target via the worksheet's rels
	local hls = child(el, "hyperlinks")
	if hls then
		for _, h in ipairs(children(hls, "hyperlink")) do
			ws.hyperlinks[#ws.hyperlinks + 1] =
				{ ref = attr(h, "ref"), url = wsRels and wsRels:targetOf(r_attr(h, "id")) }
		end
	end

	-- comments → resolve the comments part (authorId → author name)
	if wsRels and pkg then
		for _, rel in ipairs(wsRels.items) do
			if rel.type == RELT.comments then
				local part = pkg:getPart(wsRels:targetOf(rel.id) or "")
				local cd = part and xml.parse(part.bytes)
				if cd then
					local authors = {}
					local authorsEl = child(cd.root, "authors")
					for _, a in ipairs(authorsEl and children(authorsEl, "author") or {}) do
						authors[#authors + 1] = xml.textOf(a)
					end
					ws.comments = {}
					local listEl = child(cd.root, "commentList")
					for _, c in ipairs(listEl and children(listEl, "comment") or {}) do
						local parts = {}
						local function gather_t(e)
							for _, ch in ipairs(e.children) do
								if ch.kind == "element" then
									if ch.name.local_ == "t" then
										parts[#parts + 1] = xml.textOf(ch)
									else
										gather_t(ch)
									end
								end
							end
						end
						gather_t(c)
						ws.comments[#ws.comments + 1] = {
							ref = attr(c, "ref"), text = table.concat(parts),
							author = authors[(tonumber(attr(c, "authorId")) or 0) + 1],
						}
					end
				end
			end
		end
	end

	-- tableParts → resolve each table part (ref + column names)
	local tpEl = child(el, "tableParts")
	if tpEl and wsRels and pkg then
		ws.tables = {}
		for _, tp in ipairs(children(tpEl, "tablePart")) do
			local part = pkg:getPart(wsRels:targetOf(r_attr(tp, "id")) or "")
			local td = part and xml.parse(part.bytes)
			if td then
				local cols = {}
				local tcs = child(td.root, "tableColumns")
				for _, tc in ipairs(tcs and children(tcs, "tableColumn") or {}) do
					cols[#cols + 1] = attr(tc, "name")
				end
				ws.tables[#ws.tables + 1] =
					{ name = attr(td.root, "name"), ref = attr(td.root, "ref"), columns = cols }
			end
		end
	end

	-- drawing → resolve the drawing part, then its image anchors → media bytes
	local dr = child(el, "drawing")
	if dr and wsRels and pkg then
		local target = wsRels:targetOf(r_attr(dr, "id"))
		local part = target and pkg:getPart(target)
		if part then
			local drawingDoc = xml.parse(part.bytes)
			if drawingDoc then ws.images, ws.charts = parse_drawing(drawingDoc.root, pkg, pkg.rels[target]) end
		end
	end
	return ws
end

-- xlsx.load(bytes) → Workbook | nil, err. Reads the package, resolves the workbook
-- via the officeDocument relationship, then shared strings, styles, and sheets.
function xlsx.load(bytes)
	local pkg, err = opc.read(bytes)
	if not pkg then return nil, err end
	if pkg:detectFormat() ~= "xlsx" then return nil, "xlsx/not-a-workbook" end

	-- the workbook part
	local rootRels = pkg.rels[""]
	local wbName
	for _, rel in ipairs(rootRels.items) do
		if rel.type == RELT.officeDocument then
			wbName = rootRels:targetOf(rel.id)
		end
	end
	local wbPart = pkg:getPart(wbName)
	local wbDoc = assert(xml.parse(wbPart.bytes))
	local wbRels = pkg.rels[wbName] or { items = {}, targetOf = function() return nil end }

	-- shared strings + styles
	local sharedStrings = {}
	local styles = { numFmt = {}, cellXfs = {} }
	for _, rel in ipairs(wbRels.items) do
		local target = wbRels:targetOf(rel.id)
		local part = target and pkg:getPart(target)
		if part and rel.type == RELT.sharedStrings then
			local sstDoc = xml.parse(part.bytes)
			if sstDoc then
				for _, si in ipairs(children(sstDoc.root, "si")) do
					local tEl = child(si, "t")
					sharedStrings[#sharedStrings + 1] = tEl and xml.textOf(tEl) or xml.textOf(si)
				end
			end
		elseif part and rel.type == RELT.styles then
			local stDoc = xml.parse(part.bytes)
			if stDoc then styles = parse_styles(stDoc.root) end
		end
	end

	-- sheets (resolve each sheet's r:id → worksheet part)
	local wb = setmetatable({ worksheets = {}, properties = { core = {}, app = {} }, package = pkg }, Workbook)

	-- defined names (named ranges)
	local dnEl = child(wbDoc.root, "definedNames")
	if dnEl then
		wb.definedNames = {}
		for _, d in ipairs(children(dnEl, "definedName")) do
			local lsi = attr(d, "localSheetId")
			wb.definedNames[#wb.definedNames + 1] = {
				name = attr(d, "name"), ref = xml.textOf(d), localSheetId = lsi and tonumber(lsi) or nil,
			}
		end
	end

	local sheetsEl = child(wbDoc.root, "sheets")
	for _, sheetEl in ipairs(children(sheetsEl, "sheet")) do
		local rid = attr(sheetEl, "id") -- r:id, matched by local name
		local target = wbRels.targetOf and wbRels:targetOf(rid)
		local part = target and pkg:getPart(target)
		if part then
			local wsDoc = assert(xml.parse(part.bytes))
			local ws = parse_worksheet(wsDoc.root, sharedStrings, styles, pkg, pkg.rels[target])
			ws.name = attr(sheetEl, "name") or ""
			ws.sheetId = tonumber(attr(sheetEl, "sheetId"))
			wb.worksheets[#wb.worksheets + 1] = ws
		end
	end
	return wb
end

-- ===========================================================================
-- CSV / TSV conversion
-- ===========================================================================

-- A cell value → its CSV text. Formulas emit their cached result if present, else
-- the "=formula" source; dates emit the serial number (no display formatting here).
local function cell_csv_text(v)
	if not v or v.kind == "empty" then return "" end
	local k = v.kind
	if k == "number" or k == "date" then
		return tostring(v.value)
	elseif k == "string" or k == "inlineStr" then
		return v.value or ""
	elseif k == "boolean" then
		return v.value and "TRUE" or "FALSE"
	elseif k == "error" then
		return v.value or "#ERROR!"
	elseif k == "formula" then
		if v.result ~= nil then
			return tostring(coerce(v.result).value)
		end
		return "=" .. (v.formula or "")
	end
	return ""
end

-- RFC 4180 field quoting: quote when the field contains the delimiter, a quote, or a
-- newline; embedded quotes are doubled.
local function csv_quote(s, delim)
	if s:find('[\r\n"]') or s:find(delim, 1, true) then
		return '"' .. s:gsub('"', '""') .. '"'
	end
	return s
end

-- xlsx.toCSV(ws, opts?) → a CSV/TSV string for one worksheet. opts.delimiter (","),
-- opts.eol ("\n"). Emits maxCol fields per row up to maxRow (trailing empties kept).
function xlsx.toCSV(ws, opts)
	opts = opts or {}
	local delim = opts.delimiter or ","
	local eol = opts.eol or "\n"
	local lines = {}
	for r = 1, ws._maxRow do
		local row = ws.rows[r]
		local fields = {}
		for c = 1, ws._maxCol do
			local cell = row and row.cells[c]
			fields[c] = csv_quote(cell_csv_text(cell and cell.value), delim)
		end
		lines[#lines + 1] = table.concat(fields, delim)
	end
	return table.concat(lines, eol)
end

-- Does the trimmed field look like a plain decimal/scientific number?
local function looks_numeric(s)
	s = s:match("^%s*(.-)%s*$")
	return s ~= "" and (s:match("^%-?%d+$") or s:match("^%-?%d*%.%d+$") or s:match("^%-?%d+%.%d*$")
		or s:match("^%-?%d+%.?%d*[eE][%+%-]?%d+$")) ~= nil
end

-- xlsx.fromCSV(text, opts?) → a Workbook with one sheet of the parsed rows. opts:
-- delimiter (","; pass "\t" for TSV), sheetName ("Sheet1"), parseNumbers (true). A
-- full RFC 4180 parse — quoted fields may contain the delimiter, newlines, and
-- doubled quotes. Non-empty numeric-looking fields become number cells.
function xlsx.fromCSV(text, opts)
	opts = opts or {}
	local delim = opts.delimiter or ","
	local parseNumbers = opts.parseNumbers ~= false
	local rows, row, field = {}, {}, {}
	local inQuotes = false
	local function push_field()
		row[#row + 1] = table.concat(field)
		field = {}
	end
	local function push_row()
		push_field()
		rows[#rows + 1] = row
		row = {}
	end
	local i, n = 1, #text
	while i <= n do
		local ch = text:sub(i, i)
		if inQuotes then
			if ch == '"' then
				if text:sub(i + 1, i + 1) == '"' then
					field[#field + 1] = '"'
					i += 1
				else
					inQuotes = false
				end
			else
				field[#field + 1] = ch
			end
		elseif ch == '"' then
			inQuotes = true
		elseif ch == delim then
			push_field()
		elseif ch == "\n" then
			push_row()
		elseif ch ~= "\r" then
			field[#field + 1] = ch
		end
		i += 1
	end
	if #field > 0 or #row > 0 then push_row() end

	local wb = xlsx.new()
	local ws = wb:addWorksheet(opts.sheetName or "Sheet1")
	for r, rowFields in ipairs(rows) do
		for c, val in ipairs(rowFields) do
			if val ~= "" then
				local v = (parseNumbers and looks_numeric(val)) and tonumber(val) or val
				ws:setCell(make_ref(c, r), v)
			end
		end
	end
	return wb
end

-- ===========================================================================
-- Formula recalculation (the calc engine over the xlsx grid; design Ch.12)
-- ===========================================================================

-- An xlsx CellValue → an engine Value. A formula cell reads its CACHED result (set
-- earlier in topological order during recalc); dates resolve to their serial number.
local function cell_to_engine(cv)
	if not cv then return calc.BLANK end
	local k = cv.kind
	if k == "number" or k == "date" then return cv.value end
	if k == "string" or k == "inlineStr" then return cv.value end
	if k == "boolean" then return cv.value end
	if k == "error" then return calc.ERR[cv.value] or { __err = true, code = cv.value } end
	if k == "formula" then
		if cv.result == nil then return calc.BLANK end
		return cell_to_engine(cv.result)
	end
	return calc.BLANK
end

-- An engine Value → the CellValue to cache as a formula's result (arrays/refs
-- collapse to their top-left scalar; blank → 0, Excel's display for a blank result).
local function engine_to_result(v)
	local u = calc.unwrap(v)
	if type(u) == "table" and u.error then return { kind = "error", value = u.error } end
	if u == nil then return { kind = "number", value = 0 } end
	local t = type(u)
	if t == "number" then return { kind = "number", value = u } end
	if t == "string" then return { kind = "string", value = u } end
	if t == "boolean" then return { kind = "boolean", value = u } end
	return { kind = "number", value = 0 }
end

-- Build the engine resolver context over this workbook's grid. `ctx.sheet` (the
-- current sheet for unqualified refs) is set by the caller per evaluation.
local function make_ctx(self, opts)
	local sheetByName = {}
	for _, ws in ipairs(self.worksheets) do sheetByName[ws.name] = ws end

	local function cell_value(ws, col, row)
		local rowt = ws and ws.rows[row]
		local cell = rowt and rowt.cells[col]
		if not cell then return calc.BLANK end
		return cell_to_engine(cell.value)
	end

	local ctx = { now = opts and opts.now, _sheets = sheetByName }
	function ctx.cell(sheet, col, row)
		return cell_value(sheet and sheetByName[sheet] or sheetByName[ctx.sheet], col, row)
	end
	function ctx.range(sheet, c1, r1, c2, r2)
		local ws = sheet and sheetByName[sheet] or sheetByName[ctx.sheet]
		local maxR, maxC = (ws and ws._maxRow) or 0, (ws and ws._maxCol) or 0
		if maxR > 0 and r2 > maxR then r2 = maxR end -- clamp full-column ranges to data
		if maxC > 0 and c2 > maxC then c2 = maxC end
		if r2 < r1 then r2 = r1 end
		if c2 < c1 then c2 = c1 end
		local data = {}
		for r = r1, r2 do
			local rowd = {}
			for c = c1, c2 do rowd[#rowd + 1] = cell_value(ws, c, r) end
			data[#data + 1] = rowd
		end
		return { __arr = true, data = data, rows = (r2 - r1 + 1), cols = (c2 - c1 + 1) }
	end
	function ctx.name(nm)
		for _, d in ipairs(self.definedNames or {}) do
			if d.name == nm then return d.ref end
		end
		return nil
	end
	return ctx
end

-- evaluate(formula, sheetName?) → the engine Value of a one-off formula against the
-- current grid (no mutation). Use require("calc") to interpret the result.
function Workbook.evaluate(self, formula, sheetName)
	local ctx = make_ctx(self)
	ctx.sheet = sheetName or (self.worksheets[1] and self.worksheets[1].name)
	return calc.eval(formula, ctx)
end

-- recalculate(opts?) → a report { evaluated, errors, cyclic, unsupported }. Parses
-- every formula cell, builds the cross-cell dependency graph, evaluates in
-- topological order (each formula reads its precedents' fresh results), and writes
-- the computed CellValue into each formula cell's `result`. Cycles are detected
-- (never looped) and their cells marked #REF!. opts.now (epoch seconds) feeds the
-- volatile TODAY/NOW.
function Workbook.recalculate(self, opts)
	opts = opts or {}
	local ctx = make_ctx(self, opts)
	local sheetByName = ctx._sheets

	-- collect + parse formula cells (cache the AST on each node)
	local nodes, byKey = {}, {}
	for _, ws in ipairs(self.worksheets) do
		for r = 1, ws._maxRow do
			local rowt = ws.rows[r]
			if rowt then
				for c = 1, ws._maxCol do
					local cell = rowt.cells[c]
					if cell and cell.value.kind == "formula" then
						local ast = calc.parse(cell.value.formula)
						local node = { cell = cell, key = ws.name .. "!" .. c .. "," .. r,
							sheet = ws.name, col = c, row = r, ast = ast }
						nodes[#nodes + 1] = node
						byKey[node.key] = node
					end
				end
			end
		end
	end

	-- dependency edges precedent → dependent (between formula cells) + a `readers`
	-- map (ANY precedent cell key → the formula cells reading it, including inputs)
	-- used for incremental/dirty recalculation.
	local indeg, succ, readers = {}, {}, {}
	for _, node in ipairs(nodes) do indeg[node.key], succ[node.key] = 0, {} end
	for _, node in ipairs(nodes) do
		if node.ast then
			local seen = {}
			local function add_edge(depSheet, c, r)
				local pk = depSheet .. "!" .. c .. "," .. r
				if not seen[pk] then
					seen[pk] = true
					local rl = readers[pk]
					if not rl then rl = {}; readers[pk] = rl end
					rl[#rl + 1] = node.key
					local p = byKey[pk]
					if p and p.key ~= node.key then
						local sl = succ[p.key]
						sl[#sl + 1] = node.key
						indeg[node.key] += 1
					end
				end
			end
			for _, dep in ipairs(calc.deps(node.ast)) do
				local depSheet = dep.sheet or node.sheet
				if dep.kind == "cell" then
					add_edge(depSheet, dep.col, dep.row)
				else
					local ws = sheetByName[depSheet]
					local r2 = math.min(dep.r2, (ws and ws._maxRow) or dep.r2)
					local c2 = math.min(dep.c2, (ws and ws._maxCol) or dep.c2)
					for r = dep.r1, r2 do
						for c = dep.c1, c2 do add_edge(depSheet, c, r) end
					end
				end
			end
		end
	end

	-- Kahn topological order
	local order, queue, qi = {}, {}, 1
	for _, node in ipairs(nodes) do
		if indeg[node.key] == 0 then queue[#queue + 1] = node.key end
	end
	while qi <= #queue do
		local key = queue[qi]; qi += 1
		order[#order + 1] = key
		for _, sk in ipairs(succ[key]) do
			indeg[sk] -= 1
			if indeg[sk] == 0 then queue[#queue + 1] = sk end
		end
	end

	-- incremental / dirty recalc: the affected formula cells are those forward-
	-- reachable from the changed cells (BFS over `readers`). When opts.dirty is
	-- absent, `affected` is nil → every formula is recomputed.
	local affected
	if opts.dirty then
		affected = {}
		local seeds = {}
		for _, d in ipairs(opts.dirty) do
			local sheet, ref = d:match("^(.-)!(.+)$")
			if not ref then
				sheet, ref = (self.worksheets[1] and self.worksheets[1].name), d
			end
			local fromR = ref:match("^(%a+%d+)")
			local toR = ref:match(":(%a+%d+)$")
			if fromR then
				local c1, r1 = parse_ref(fromR)
				local c2, r2 = c1, r1
				if toR then c2, r2 = parse_ref(toR) end
				for rr = math.min(r1, r2), math.max(r1, r2) do
					for cc = math.min(c1, c2), math.max(c1, c2) do
						seeds[#seeds + 1] = sheet .. "!" .. cc .. "," .. rr
					end
				end
			end
		end
		local si = 1
		while si <= #seeds do
			local ck = seeds[si]; si += 1
			if byKey[ck] and not affected[ck] then affected[ck] = true end
			for _, fkey in ipairs(readers[ck] or {}) do
				if not affected[fkey] then
					affected[fkey] = true
					seeds[#seeds + 1] = fkey
				end
			end
		end
	end

	-- evaluate in order, writing each formula cell's cached result. A multi-cell
	-- array result SPILLS into neighbouring cells (dynamic arrays); a collision with
	-- a non-empty cell makes the anchor #SPILL!.
	local report = { evaluated = 0, errors = 0, cyclic = 0, unsupported = 0, spilled = 0 }
	for _, key in ipairs(order) do
	  if not affected or affected[key] then
		local node = byKey[key]
		local ws = sheetByName[node.sheet]
		-- clear this formula's previous spill region (so re-spill is clean; in dirty
		-- mode only affected formulas touch their spills)
		if node.cell._spill then
			for i = 1, node.cell._spill.rows do
				for j = 1, node.cell._spill.cols do
					if not (i == 1 and j == 1) then
						local rr, cc = node.row + i - 1, node.col + j - 1
						local rt = ws.rows[rr]
						if rt and rt.cells[cc] and rt.cells[cc]._spilled then rt.cells[cc] = nil end
					end
				end
			end
			node.cell._spill = nil
		end
		ctx.sheet, ctx.currentRow, ctx.currentCol = node.sheet, node.row, node.col
		local v = node.ast and calc.finalize(calc.evaluate(node.ast, ctx), ctx) or calc.ERR.ERROR
		report.evaluated += 1
		if calc.isArray(v) and (v.rows > 1 or v.cols > 1) then
			local clash = false
			for i = 1, v.rows do
				for j = 1, v.cols do
					if not (i == 1 and j == 1) then
						local rr, cc = node.row + i - 1, node.col + j - 1
						local ex = ws.rows[rr] and ws.rows[rr].cells[cc]
						if ex and not ex._spilled and ex.value.kind ~= "empty" then clash = true end
					end
				end
			end
			if clash then
				node.cell.value.result = { kind = "error", value = "#SPILL!" }
				report.errors += 1
			else
				node.cell.value.result = engine_to_result(v.data[1][1])
				for i = 1, v.rows do
					for j = 1, v.cols do
						if not (i == 1 and j == 1) then
							local rr, cc = node.row + i - 1, node.col + j - 1
							local rowt = ws.rows[rr]
							if not rowt then rowt = { number = rr, cells = {} }; ws.rows[rr] = rowt end
							rowt.cells[cc] = { ref = make_ref(cc, rr), value = engine_to_result(v.data[i][j]), _spilled = true }
							if cc > ws._maxCol then ws._maxCol = cc end
							if rr > ws._maxRow then ws._maxRow = rr end
						end
					end
				end
				node.cell._spill = { rows = v.rows, cols = v.cols }
				report.spilled += 1
			end
		else
			node.cell.value.result = engine_to_result(v)
			if calc.isError(v) then
				report.errors += 1
				if calc.errorCode(v) == "#NAME?" then report.unsupported += 1 end
			end
		end
	  end
	end

	-- cells left with in-degree > 0 are in a cycle → mark #REF! (no iterative calc)
	for _, node in ipairs(nodes) do
		if indeg[node.key] > 0 then
			node.cell.value.result = { kind = "error", value = "#REF!" }
			report.cyclic += 1
		end
	end
	-- when modeled functions changed values, force Excel to honour the cache on open
	self.fullCalcOnLoad = false
	return report
end

-- xlsx.open(path) → Workbook | nil, err.
function xlsx.open(path)
	local sys = sys
	local bytes, err = sys.fs.read(path)
	if not bytes then return nil, err end
	return xlsx.load(bytes)
end

return xlsx
