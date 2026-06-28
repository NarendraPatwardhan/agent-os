-- tools.luau — Luau client for the warm /svc/tools broker.
--
-- Search and describe stay inside the VM. Calls return the broker's branchable envelope:
-- { ok = true, data = ... } or { ok = false, err = { code = ..., message = ... } }.

local sys = sys
local json = require("json")

local tools = {}
local conn = nil

local function err(code, message)
	return { ok = false, err = { code = code, message = message } }
end

local function connect()
	if conn then
		return conn
	end
	local fd, e = sys.svc.connect("tools")
	if not fd then
		return nil, e
	end
	conn = fd
	return conn
end

local function request(payload)
	local fd, e = connect()
	if not fd then
		return nil, e
	end
	local encoded, body = pcall(json.encode, payload)
	if not encoded then
		return nil, tostring(body)
	end
	local raw, call_err = sys.svc.call(fd, body)
	if not raw then
		sys.svc.close(fd)
		conn = nil
		return nil, call_err
	end
	local ok, decoded = pcall(json.decode, raw)
	if not ok then
		return nil, tostring(decoded)
	end
	return decoded
end

local function merge(a, b)
	local out = {}
	for k, v in pairs(a) do
		out[k] = v
	end
	if b then
		for k, v in pairs(b) do
			out[k] = v
		end
	end
	return out
end

function tools.search(query, opts)
	local page, e = request(merge({ op = "search", query = query or "" }, opts))
	if not page then
		return nil, e
	end
	return page
end

function tools.describe(address)
	local rec, e = request({ op = "describe", address = address })
	if not rec then
		return nil, e
	end
	if rec.ok == false then
		return nil, rec.err
	end
	return rec
end

function tools.call(address, args)
	local res, e = request({ op = "call", address = address, args = args or {} })
	if not res then
		return err("service_unavailable", tostring(e))
	end
	return res
end

function tools.save(address, args, path)
	local res, e = request({ op = "call", address = address, args = args or {}, output = path })
	if not res then
		return err("service_unavailable", tostring(e))
	end
	return res
end

function tools.list()
	local listing, e = request({ op = "list" })
	if not listing then
		return nil, e
	end
	return listing
end

function tools.gc()
	local res, e = request({ op = "gc" })
	if not res then
		return err("service_unavailable", tostring(e))
	end
	return res
end

local function node(path)
	return setmetatable({}, {
		__index = function(_, seg)
			local child = tostring(seg)
			if path == "" then
				return node(child)
			end
			return node(path .. "." .. child)
		end,
		__call = function(_, args)
			return tools.call(path, args)
		end,
	})
end

return setmetatable(tools, {
	__index = function(_, seg)
		return node(tostring(seg))
	end,
})
