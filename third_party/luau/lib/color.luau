-- color.luau — the shared OOXML color model (luau-extensions Ch.06 §6.2). One
-- tagged union serves SpreadsheetML (`rgb`/`theme`/`indexed`/`auto`) and DrawingML
-- (`srgbClr`/`schemeClr`/`sysClr`); each consumer's xform encodes it to its own
-- element. A tagged union (Principle #7), never duck-typed.
--
--   { kind="rgb",     value="RRGGBB" }
--   { kind="argb",    value="AARRGGBB" }     -- xlsx stores alpha-first
--   { kind="theme",   slot=ThemeColorSlot, tint?, shade?, lumMod?, alpha? }
--   { kind="indexed", value=number }          -- legacy xlsx palette index
--   { kind="auto" }

local color = {}

-- Validate + normalize a hex string: strip a leading '#' (with no error — the
-- PptxGenJS lesson), upper-case, require 6 (RGB) or 8 (ARGB) hex digits.
local function norm_hex(s, digits)
	s = s:gsub("^#", ""):upper()
	if not s:match("^%x+$") or #s ~= digits then
		return nil
	end
	return s
end

-- color.rgb("FF0000") / color.rgb("#ff0000") → { kind="rgb", value="FF0000" }.
function color.rgb(hex)
	local v = norm_hex(hex, 6)
	assert(v, "color.rgb: expected 6 hex digits, got " .. tostring(hex))
	return { kind = "rgb", value = v }
end

-- color.argb("FFFF0000") — alpha-first 8-digit (xlsx native).
function color.argb(hex)
	local v = norm_hex(hex, 8)
	assert(v, "color.argb: expected 8 hex digits, got " .. tostring(hex))
	return { kind = "argb", value = v }
end

-- color.theme("accent1", { tint = 0.4 }) — a theme slot with optional modifiers
-- (tint/shade/lumMod/alpha, all 0..1 → encoded as 1000ths-of-% by the consumer).
function color.theme(slot, mods)
	mods = mods or {}
	return {
		kind = "theme",
		slot = slot,
		tint = mods.tint,
		shade = mods.shade,
		lumMod = mods.lumMod,
		alpha = mods.alpha,
	}
end

function color.indexed(n)
	return { kind = "indexed", value = n }
end

color.auto = { kind = "auto" }

-- Theme slot → DrawingML scheme name (dk1/lt1 map to tx1/bg1 in `schemeClr`).
local SCHEME = {
	dk1 = "tx1", lt1 = "bg1", dk2 = "tx2", lt2 = "bg2",
	accent1 = "accent1", accent2 = "accent2", accent3 = "accent3",
	accent4 = "accent4", accent5 = "accent5", accent6 = "accent6",
	hlink = "hlink", folHlink = "folHlink",
}
color.SCHEME = SCHEME

-- Map a theme slot to the xlsx `<color theme="N">` index (the styles.xml order:
-- lt1,dk1,lt2,dk2,accent1..6,hlink,folHlink — note lt/dk are swapped vs DrawingML).
local THEME_INDEX = {
	lt1 = 0, dk1 = 1, lt2 = 2, dk2 = 3,
	accent1 = 4, accent2 = 5, accent3 = 6, accent4 = 7, accent5 = 8, accent6 = 9,
	hlink = 10, folHlink = 11,
}
color.THEME_INDEX = THEME_INDEX

-- A stable canonical string for style dedup (Ch.05 §5.8): same color → same key.
function color.canon(c)
	if not c then return "" end
	if c.kind == "theme" then
		return "theme:" .. c.slot .. ":" .. tostring(c.tint) .. ":" .. tostring(c.shade)
	end
	return c.kind .. ":" .. tostring(c.value)
end

return color
