-- time.luau — clocks, durations and ISO-8601 date math over `sys.time`. A module
-- (not `os` sugar) because instants/durations are a small domain; it also
-- encapsulates the frozen-clock determinism seam so scripts don't each poke
-- `sys.time` (SYSTEMS.md §10.3). Stock `os.time`/`os.date` stay as raw primitives.

local sys = sys
local time = {}

time.SECOND = 1
time.MINUTE = 60
time.HOUR = 3600
time.DAY = 86400

-- now() → seconds since the epoch (float, ms precision). now_ms() → integer ms.
function time.now()
	local ms, err = sys.time.now()
	if not ms then
		return nil, err
	end
	return ms / 1000.0
end

function time.now_ms()
	return sys.time.now()
end

-- A monotonic clock for measuring elapsed time (immune to wall-clock jumps).
function time.mono_ms()
	return sys.time.mono()
end

function time.sleep(ms)
	return sys.time.sleep(ms)
end

-- Seconds elapsed since the wall-clock instant `t0` (as returned by now()).
function time.since(t0)
	local n, err = time.now()
	if not n then
		return nil, err
	end
	return n - t0
end

-- ── civil calendar (Hinnant's algorithms; proleptic Gregorian, UTC) ──────────
-- Valid for the realistic post-epoch range (all inputs non-negative), which is
-- every timestamp an agent will see; pre-1970 is out of scope.

local function idiv(a, b)
	return math.floor(a / b)
end

-- days since 1970-01-01 for the civil date y-m-d.
local function days_from_civil(y, m, d)
	local yy = (m <= 2) and (y - 1) or y
	local era = idiv(yy, 400)
	local yoe = yy - era * 400
	local mp = (m > 2) and (m - 3) or (m + 9)
	local doy = idiv(153 * mp + 2, 5) + d - 1
	local doe = yoe * 365 + idiv(yoe, 4) - idiv(yoe, 100) + doy
	return era * 146097 + doe - 719468
end

-- inverse: days since epoch → y, m, d.
local function civil_from_days(z)
	local zz = z + 719468
	local era = idiv(zz, 146097)
	local doe = zz - era * 146097
	local yoe = idiv(doe - idiv(doe, 1460) + idiv(doe, 36524) - idiv(doe, 146096), 365)
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + idiv(yoe, 4) - idiv(yoe, 100))
	local mp = idiv(5 * doy + 2, 153)
	local d = doy - idiv(153 * mp + 2, 5) + 1
	local m = (mp < 10) and (mp + 3) or (mp - 9)
	return (m <= 2) and (y + 1) or y, m, d
end

-- Break an epoch-seconds instant into a UTC calendar table.
function time.utc(secs)
	if secs == nil then
		secs = time.now()
	end
	secs = math.floor(secs)
	local days = idiv(secs, 86400)
	local rem = secs - days * 86400
	local y, mo, d = civil_from_days(days)
	return {
		year = y,
		month = mo,
		day = d,
		hour = idiv(rem, 3600),
		min = idiv(rem % 3600, 60),
		sec = rem % 60,
	}
end

-- format(secs?, fmt?) → string. Default ISO-8601 UTC; "date"/"time" shortcuts; or
-- a strftime-lite template using %Y %m %d %H %M %S.
function time.format(secs, fmt)
	local t = time.utc(secs)
	if fmt == nil or fmt == "iso" then
		return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ", t.year, t.month, t.day, t.hour, t.min, t.sec)
	elseif fmt == "date" then
		return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
	elseif fmt == "time" then
		return string.format("%02d:%02d:%02d", t.hour, t.min, t.sec)
	end
	local map = {
		Y = string.format("%04d", t.year),
		m = string.format("%02d", t.month),
		d = string.format("%02d", t.day),
		H = string.format("%02d", t.hour),
		M = string.format("%02d", t.min),
		S = string.format("%02d", t.sec),
	}
	return (fmt:gsub("%%(.)", function(c)
		return map[c] or ("%" .. c)
	end))
end

-- parse("YYYY-MM-DD[THH:MM:SS[Z]]") → epoch seconds, or nil, "EINVAL".
function time.parse(s)
	local y, mo, d, hh, mm, ss = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)")
	if not y then
		y, mo, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
		hh, mm, ss = "0", "0", "0"
	end
	if not y then
		return nil, "EINVAL"
	end
	local days = days_from_civil(tonumber(y), tonumber(mo), tonumber(d))
	return days * 86400 + tonumber(hh) * 3600 + tonumber(mm) * 60 + tonumber(ss)
end

return time
