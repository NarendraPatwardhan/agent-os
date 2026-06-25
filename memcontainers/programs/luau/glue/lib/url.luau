-- url.luau — URL parsing/building + percent/query encoding. Needed the moment you
-- have `http` (you can't build a query string safely without it), so it's a
-- first-class module, not buried in `string` ops.

local url = {}

local function to_hex(c)
	return string.format("%%%02X", string.byte(c))
end

-- Percent-encode a single URL component (RFC 3986 unreserved set kept literal).
function url.encode(s)
	return (tostring(s):gsub("[^%w%-%._~]", to_hex))
end

-- Percent-decode (also turns '+' into space, for form bodies).
function url.decode(s)
	s = s:gsub("+", " ")
	return (s:gsub("%%(%x%x)", function(h)
		return string.char(tonumber(h, 16))
	end))
end

-- Build "k=v&k2=v2" from a table. An array value repeats the key
-- (`{tag = {"a","b"}}` → "tag=a&tag=b"). Keys are sorted for determinism.
function url.encode_query(params)
	local keys = {}
	for k in pairs(params) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	local out = {}
	for _, k in ipairs(keys) do
		local v = params[k]
		if type(v) == "table" then
			for _, item in ipairs(v) do
				out[#out + 1] = url.encode(k) .. "=" .. url.encode(item)
			end
		else
			out[#out + 1] = url.encode(k) .. "=" .. url.encode(v)
		end
	end
	return table.concat(out, "&")
end

-- Parse "k=v&k2=v2" → table. A repeated key collects into an array.
function url.decode_query(qs)
	local out = {}
	for pair in qs:gmatch("[^&]+") do
		local k, v = pair:match("^([^=]*)=?(.*)$")
		k, v = url.decode(k), url.decode(v)
		if out[k] == nil then
			out[k] = v
		elseif type(out[k]) == "table" then
			out[k][#out[k] + 1] = v
		else
			out[k] = { out[k], v }
		end
	end
	return out
end

-- Parse into { scheme, host, port, path, query, fragment }. Best-effort; no
-- userinfo. A scheme-relative or path-only input yields just `path` (+ query/frag).
function url.parse(u)
	local out = {}
	local rest = u
	out.scheme = rest:match("^(%a[%w+%-.]*)://")
	if out.scheme then
		rest = rest:sub(#out.scheme + 4)
	end
	local hash = rest:find("#", 1, true)
	if hash then
		out.fragment = rest:sub(hash + 1)
		rest = rest:sub(1, hash - 1)
	end
	local q = rest:find("?", 1, true)
	if q then
		out.query = rest:sub(q + 1)
		rest = rest:sub(1, q - 1)
	end
	if out.scheme then
		local slash = rest:find("/", 1, true)
		local authority
		if slash then
			authority, out.path = rest:sub(1, slash - 1), rest:sub(slash)
		else
			authority, out.path = rest, ""
		end
		out.host, out.port = authority:match("^([^:]*):?(%d*)$")
		if out.port == "" then
			out.port = nil
		end
	else
		out.path = rest
	end
	return out
end

-- Inverse of parse. `query` may be a string or a table (→ encode_query).
function url.build(parts)
	local out = {}
	if parts.scheme then
		out[#out + 1] = parts.scheme .. "://"
		out[#out + 1] = parts.host or ""
		if parts.port then
			out[#out + 1] = ":" .. tostring(parts.port)
		end
	end
	out[#out + 1] = parts.path or ""
	if parts.query then
		local qs = type(parts.query) == "table" and url.encode_query(parts.query) or parts.query
		if qs ~= "" then
			out[#out + 1] = "?" .. qs
		end
	end
	if parts.fragment then
		out[#out + 1] = "#" .. parts.fragment
	end
	return table.concat(out)
end

return url
