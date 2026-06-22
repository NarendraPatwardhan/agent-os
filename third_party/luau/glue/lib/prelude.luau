-- prelude.luau — builtin extensions (ctx/LUAU.md §7, "extend the builtins, don't
-- shadow them"). Run ONCE at VM startup on the (unsandboxed) entry state, before
-- any user script, so additions to `string`/`table`/`os` are visible everywhere —
-- exactly how Luau itself adds `string.split`. These hang off the existing tables
-- (no new globals); the string metatable's `__index = string` makes every
-- `string.*` addition callable as a method too (`s:trim()`).
--
-- The boundary rule: an operation *on* a string/table goes here; a new abstraction
-- (a compiled regex, a URL) earns its own module. So `trim`/`split` live on
-- `string`, but `re`/`url` are modules.

local string = string
local table = table
local os = os
local sys = sys

-- ── string: operations on a string ──────────────────────────────────────────

function string.ltrim(s)
	return (s:gsub("^%s+", ""))
end

function string.rtrim(s)
	return (s:gsub("%s+$", ""))
end

function string.trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function string.startswith(s, prefix)
	return s:sub(1, #prefix) == prefix
end

function string.endswith(s, suffix)
	return #suffix == 0 or s:sub(-#suffix) == suffix
end

-- Plain (non-pattern) substring test — what an agent means by "contains".
function string.contains(s, sub)
	return s:find(sub, 1, true) ~= nil
end

-- Left-pad `s` to `width` using `pad` (repeated/truncated; default a space).
function string.padstart(s, width, pad)
	pad = pad or " "
	local need = width - #s
	if need <= 0 or #pad == 0 then
		return s
	end
	return pad:rep(math.ceil(need / #pad)):sub(1, need) .. s
end

function string.padend(s, width, pad)
	pad = pad or " "
	local need = width - #s
	if need <= 0 or #pad == 0 then
		return s
	end
	return s .. pad:rep(math.ceil(need / #pad)):sub(1, need)
end

-- Split into lines on \n, dropping a trailing \r (CRLF) — like Python's
-- str.splitlines(). Empty input → no lines.
function string.splitlines(s)
	if s == "" then
		return {}
	end
	local out = {}
	local subject = (s:sub(-1) == "\n") and s or (s .. "\n")
	for line in subject:gmatch("(.-)\n") do
		out[#out + 1] = (line:gsub("\r$", ""))
	end
	return out
end

-- ── table: operations on a table ────────────────────────────────────────────
-- (Luau already adds find/clone/create/freeze/clear; these are the functional
-- helpers an agent reaches for.)

function table.map(t, f)
	local out = {}
	for i, v in ipairs(t) do
		out[i] = f(v, i)
	end
	return out
end

function table.filter(t, pred)
	local out = {}
	for i, v in ipairs(t) do
		if pred(v, i) then
			out[#out + 1] = v
		end
	end
	return out
end

function table.reduce(t, f, acc)
	for i, v in ipairs(t) do
		acc = f(acc, v, i)
	end
	return acc
end

function table.keys(t)
	local out = {}
	for k in pairs(t) do
		out[#out + 1] = k
	end
	return out
end

function table.values(t)
	local out = {}
	for _, v in pairs(t) do
		out[#out + 1] = v
	end
	return out
end

-- 1-based slice; negative indices count from the end (Lua `string.sub` style).
function table.slice(t, i, j)
	local n = #t
	i = i or 1
	j = j or n
	if i < 0 then
		i = n + i + 1
	end
	if j < 0 then
		j = n + j + 1
	end
	local out = {}
	for k = i, j do
		out[#out + 1] = t[k]
	end
	return out
end

-- Reverse the array part in place; returns `t` for chaining (like table.sort).
function table.reverse(t)
	local n = #t
	for i = 1, math.floor(n / 2) do
		t[i], t[n - i + 1] = t[n - i + 1], t[i]
	end
	return t
end

-- Cycle-safe deep copy.
function table.deepcopy(t, seen)
	if type(t) ~= "table" then
		return t
	end
	seen = seen or {}
	if seen[t] then
		return seen[t]
	end
	local out = {}
	seen[t] = out
	for k, v in pairs(t) do
		out[k] = table.deepcopy(v, seen)
	end
	return out
end

-- ── os: process + environment front door over `sys` ─────────────────────────
-- Stock Luau `os` (time/clock/date/difftime) stays as the raw primitive; these
-- add the process/environment surface (Luau's stock os is sandbox-stubbed). The
-- `time` MODULE is the canonical rich clock API — these are the thin escape hatch.

function os.run(cmd)
	return sys.proc.run(cmd)
end

function os.spawn(opts)
	return sys.proc.spawn(opts)
end

function os.exit(code)
	return sys.proc.exit(code)
end

function os.args()
	return sys.args()
end

function os.getcwd()
	return sys.fs.cwd()
end

function os.chdir(p)
	return sys.fs.chdir(p)
end

-- Environment variables live as files under `/env` (the kernel's envfs); a missing
-- var is a normal answer (→ nil), not an error.
function os.env(name)
	return sys.fs.read("/env/" .. name)
end

function os.setenv(name, value)
	return sys.fs.write("/env/" .. name, value)
end

function os.environ()
	local out = {}
	local ents = sys.fs.readdir("/env")
	if ents then
		for _, e in ipairs(ents) do
			out[e.name] = sys.fs.read("/env/" .. e.name)
		end
	end
	return out
end
