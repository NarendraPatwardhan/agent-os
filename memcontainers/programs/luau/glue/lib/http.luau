-- http.luau — ergonomic HTTP over `sys.net` (ctx/LUAU.md §7.1): JSON bodies, query
-- building, status helpers and retries on top of the raw `sys.net.fetch`. Fails
-- closed — without CAP_NET the syscall returns EPERM, surfaced here as `nil, err`
-- (never a hang). The "fetch" cluster: http + url (query encoding) together.

local sys = sys
local json = require("json")
local url = require("url")
local http = {}

-- Response object: { status, body, ok } plus `:json()`.
local Response = {}
Response.__index = Response

function Response:json()
	return json.decode(self.body)
end

local function make_response(raw)
	return setmetatable({
		status = raw.status,
		body = raw.body,
		ok = raw.status >= 200 and raw.status < 300,
	}, Response)
end

-- Header lookup that tolerates either casing the caller used.
local function has_header(headers, name)
	return headers[name] ~= nil or headers[name:lower()] ~= nil
end

-- http.request(method, url, opts?) → response?, err.
-- opts: { headers = {}, query = {}, body = string|table, json = value,
--         retries = n }. A table `body` (or `json`) is JSON-encoded and gets a
-- default Content-Type.
function http.request(method, target, opts)
	opts = opts or {}

	if opts.query then
		local qs = url.encode_query(opts.query)
		if qs ~= "" then
			target = target .. (target:find("?", 1, true) and "&" or "?") .. qs
		end
	end

	local headers = {}
	if opts.headers then
		for k, v in pairs(opts.headers) do
			headers[k] = v
		end
	end

	local body = opts.body
	local is_json_body = false
	if opts.json ~= nil then
		body, is_json_body = json.encode(opts.json), true
	elseif type(body) == "table" then
		body, is_json_body = json.encode(body), true
	end
	if is_json_body and not has_header(headers, "Content-Type") then
		headers["Content-Type"] = "application/json"
	end

	local attempts = (opts.retries or 0) + 1
	local last_err
	for _ = 1, attempts do
		local raw, err = sys.net.fetch(target, { method = method, headers = headers, body = body })
		if raw then
			return make_response(raw)
		end
		last_err = err
		if err == "EPERM" then
			break -- a missing capability won't heal on retry
		end
	end
	return nil, last_err
end

function http.get(target, opts)
	return http.request("GET", target, opts)
end

function http.post(target, opts)
	return http.request("POST", target, opts)
end

function http.put(target, opts)
	return http.request("PUT", target, opts)
end

function http.delete(target, opts)
	return http.request("DELETE", target, opts)
end

-- http.json(url, opts?) → decoded value?, err. GET (or opts.method) + decode, with
-- a non-2xx status surfaced as an error rather than a body.
function http.json(target, opts)
	opts = opts or {}
	local res, err = http.request(opts.method or "GET", target, opts)
	if not res then
		return nil, err
	end
	if not res.ok then
		return nil, "HTTP " .. tostring(res.status)
	end
	return res:json()
end

return http
