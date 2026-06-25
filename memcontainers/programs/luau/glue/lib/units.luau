-- units.luau — OOXML measurement units + converters (luau-extensions Ch.06 /
-- appendix A). The anti-pattern this kills is magnitude-guessing ("a number < 100
-- means inches"): every format API is typed to the NATIVE unit it serializes, and
-- conversion happens exactly once, here, at the boundary. A bare number always
-- means the same unit for a given parameter.
--
--   1 in = 914400 EMU = 1440 twip = 72 pt = 144 half-pt = 96 px@96dpi
--   1 pt = 12700 EMU = 20 twip = 2 half-pt ;  1 px@96 = 9525 EMU

local units = {}

local function round(n)
	return math.floor(n + 0.5)
end

-- → EMU (DrawingML geometry / pptx; image extents in docx/xlsx)
function units.emuFromInches(n) return round(n * 914400) end
function units.emuFromCm(n) return round(n * 360000) end
function units.emuFromMm(n) return round(n * 36000) end
function units.emuFromPt(n) return round(n * 12700) end
function units.emuFromPx(n) return round(n * 9525) end -- @96dpi

-- → twips (docx page/margins/indents/spacing; 1440/inch)
function units.twipFromInches(n) return math.floor(n * 1440) end
function units.twipFromCm(n) return math.floor(n * 566.929) end
function units.twipFromPt(n) return math.floor(n * 20) end

-- fonts / borders
function units.halfPtFromPt(n) return round(n * 2) end -- docx font size (w:sz)
function units.eighthPtFromPt(n) return round(n * 8) end -- docx border thickness
function units.hundredthFromPt(n) return round(n * 100) end -- DrawingML font size (a:rPr@sz)

-- DrawingML angles: 60000ths of a degree, positive = clockwise
function units.angle60000(deg) return round((deg % 360) * 60000) end

-- A `Measure` = a number in the parameter's native unit, OR { n=number, unit=… },
-- OR a string like "2.5cm". The factor table converts any named unit to EMU/twip.
local PER_INCH = { ["in"] = 1, cm = 2.54, mm = 25.4, pt = 72, px = 96, emu = 914400, twip = 1440 }

local function parse_measure(m)
	if type(m) == "number" then
		return m, nil -- native unit (the caller's `native` converter handles it)
	end
	if type(m) == "string" then
		local n, u = m:match("^%s*(-?[%d%.]+)%s*(%a+)%s*$")
		return tonumber(n), u
	end
	if type(m) == "table" then
		return m.n, m.unit
	end
	return nil, nil
end

-- Convert a Measure to EMU (`native` = the unit a bare number is in, default "emu").
function units.toEmu(m, native)
	local n, u = parse_measure(m)
	u = u or native or "emu"
	if not n then return 0 end
	return round(n * 914400 / PER_INCH[u])
end

-- Convert a Measure to twips (native default "twip").
function units.toTwip(m, native)
	local n, u = parse_measure(m)
	u = u or native or "twip"
	if not n then return 0 end
	return math.floor(n * 1440 / PER_INCH[u])
end

-- Ergonomic Measure constructors (re-exported at the format API surface).
function units.Inches(n) return { n = n, unit = "in" } end
function units.Cm(n) return { n = n, unit = "cm" } end
function units.Mm(n) return { n = n, unit = "mm" } end
function units.Pt(n) return { n = n, unit = "pt" } end
function units.Px(n) return { n = n, unit = "px" } end
function units.Emu(n) return { n = n, unit = "emu" } end

return units
