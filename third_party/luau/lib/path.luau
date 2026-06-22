-- path.luau — POSIX path manipulation ('/'). Pure string ops plus a `glob` that
-- walks the VFS via `sys.fs`. Path *semantics* (separators, normalization,
-- globbing) are a domain of their own, so this is a module rather than more
-- `string` methods (ctx/LUAU.md §7 boundary rule).

local sys = sys
local path = {}

function path.isabs(p)
	return p:sub(1, 1) == "/"
end

-- Join segments, collapsing the seam slashes. Empty segments are skipped.
function path.join(...)
	local acc = ""
	for _, p in ipairs({ ... }) do
		if p ~= "" then
			if acc == "" then
				acc = p
			elseif acc:sub(-1) == "/" then
				acc = acc .. p
			else
				acc = acc .. "/" .. p
			end
		end
	end
	return acc
end

-- Split into (dir, base). "/a/b" → "/a","b"; "b" → ".","b"; "/b" → "/","b".
function path.split(p)
	local dir, base = p:match("^(.*)/([^/]*)$")
	if not dir then
		return ".", p
	end
	if dir == "" then
		dir = "/"
	end
	return dir, base
end

function path.dirname(p)
	local dir = path.split(p)
	return dir
end

-- basename(p [, ext]) — final component, with a trailing `ext` stripped if present.
function path.basename(p, ext)
	local _, base = path.split(p)
	if ext and ext ~= "" and #base > #ext and base:sub(-#ext) == ext then
		base = base:sub(1, #base - #ext)
	end
	return base
end

-- Extension including the dot ("a.tar.gz" → ".gz"), or "" if none. A leading-dot
-- name with no other dot ("/a/.bashrc") has no extension.
function path.ext(p)
	local _, base = path.split(p)
	local dot = base:match("()%.[^%.]*$")
	if not dot or dot == 1 then
		return ""
	end
	return base:sub(dot)
end

-- Lexically normalize: collapse `//`, resolve `.` and `..`, keep a leading `/`.
-- Pure (does not touch the filesystem, so symlinks are not resolved).
function path.normalize(p)
	local abs = path.isabs(p)
	local parts = {}
	for seg in p:gmatch("[^/]+") do
		if seg == "." then
			-- drop
		elseif seg == ".." then
			if #parts > 0 and parts[#parts] ~= ".." then
				parts[#parts] = nil
			elseif not abs then
				parts[#parts + 1] = ".."
			end
		else
			parts[#parts + 1] = seg
		end
	end
	local joined = table.concat(parts, "/")
	if abs then
		return "/" .. joined
	end
	return joined == "" and "." or joined
end

-- Convert one glob segment to an anchored Lua pattern over a single name. `*`
-- matches any run of non-slash; `?` matches one non-slash; everything else is
-- literal.
local function seg_to_pattern(seg)
	local out = { "^" }
	for i = 1, #seg do
		local c = seg:sub(i, i)
		if c == "*" then
			out[#out + 1] = "[^/]*"
		elseif c == "?" then
			out[#out + 1] = "[^/]"
		elseif c:match("%w") then
			out[#out + 1] = c
		else
			out[#out + 1] = "%" .. c
		end
	end
	out[#out + 1] = "$"
	return table.concat(out)
end

-- glob(pattern) → sorted array of matching paths. Supports `*`/`?` per segment by
-- walking the VFS (`sys.fs.readdir`); literal segments descend without a listing.
function path.glob(pattern)
	local abs = path.isabs(pattern)
	local segs = {}
	for s in pattern:gmatch("[^/]+") do
		segs[#segs + 1] = s
	end
	local results = {}

	local function child_of(dir, name)
		if dir == "" then
			return name
		elseif dir == "/" then
			return "/" .. name
		end
		return dir .. "/" .. name
	end

	local function walk(dir, idx)
		if idx > #segs then
			results[#results + 1] = dir
			return
		end
		local seg = segs[idx]
		if not seg:find("[%*%?]") then
			local child = child_of(dir, seg)
			if sys.fs.exists(child) then
				walk(child, idx + 1)
			end
			return
		end
		local listing = sys.fs.readdir(dir == "" and "." or dir)
		if not listing then
			return
		end
		local pat = seg_to_pattern(seg)
		for _, e in ipairs(listing) do
			if e.name:match(pat) then
				walk(child_of(dir, e.name), idx + 1)
			end
		end
	end

	walk(abs and "/" or "", 1)
	table.sort(results)
	return results
end

return path
