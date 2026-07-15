-- test.luau — a tiny assertion + describe/it harness so scripts and the batteries
-- self-verify (we author the libs, so the libs need tests). Pure
-- Lua; the only I/O is the summary it prints.

local test = {}

local state = { pass = 0, fail = 0, failures = {}, stack = {} }

local function ctx()
	return table.concat(state.stack, " › ")
end

-- Group related cases; nesting builds the breadcrumb shown on failure.
function test.describe(name, fn)
	state.stack[#state.stack + 1] = name
	fn()
	state.stack[#state.stack] = nil
end

-- Run one case under pcall so a failure is recorded, not fatal.
function test.it(name, fn)
	state.stack[#state.stack + 1] = name
	local ok, err = pcall(fn)
	if ok then
		state.pass = state.pass + 1
	else
		state.fail = state.fail + 1
		state.failures[#state.failures + 1] = ctx() .. " — " .. tostring(err)
	end
	state.stack[#state.stack] = nil
end

-- Structural equality (recurses into tables).
local function deep_eq(a, b)
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in pairs(a) do
		if not deep_eq(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

-- error(.., 2) blames the caller's line, not this frame.
function test.assert(cond, msg)
	if not cond then
		error(msg or "assertion failed", 2)
	end
	return cond
end

function test.eq(a, b, msg)
	if not deep_eq(a, b) then
		error((msg or "values differ") .. ": " .. tostring(a) .. " ~= " .. tostring(b), 2)
	end
end

function test.truthy(v, msg)
	if not v then
		error(msg or "expected a truthy value", 2)
	end
end

function test.falsy(v, msg)
	if v then
		error(msg or "expected a falsy value", 2)
	end
end

-- Assert that `fn` raises.
function test.throws(fn, msg)
	if pcall(fn) then
		error(msg or "expected an error", 2)
	end
end

-- Print the summary and (unless opts.exit == false) set the process exit code so
-- `luau t.luau` fails on a red test. Returns true when everything passed.
function test.run(opts)
	opts = opts or {}
	for _, f in ipairs(state.failures) do
		print("FAIL: " .. f)
	end
	print(string.format("%d passed, %d failed", state.pass, state.fail))
	local ok = state.fail == 0
	if opts.exit ~= false then
		os.exit(ok and 0 or 1)
	end
	return ok
end

return test
