--!strict
--[[
  typst.luau — compile Typst to PDF from AgentOS Luau: `require("typst")`.

  The ergonomic face of the resident `typst` SERVICE. `typst.compile(source)` sends `.typ` source to the
  warm service — which keeps ~30 MB of fonts loaded across calls (SYSTEMS.md) — and returns the PDF
  bytes; `typst.compile_file(path)` compiles a `.typ` already in the VFS. It talks to the service over
  `sys.svc` with a small JSON request and a length-framed binary response. Shipped as VFS content by the
  `paper` flavor (not embedded in the interpreter). The CLI `$ typst compile` is a thin client of the
  same warm engine. See /skills/typst.md.

  Returns PDF bytes as a Lua byte string, so a result flows straight into other artifacts (e.g. attach a
  typst-rendered report alongside an xlsx/sqlite export) without touching disk.
]]

local json = require("json")

-- One round-trip to the typst service: connect, send the request, drain the framed response, decode the
-- header. Returns (header, body). Raises on a transport failure. The connection is per-call — typst keeps
-- NO per-session state (the warm fonts are service-wide), so there is no handle to hold.
local function request(req)
	local fd, cerr = sys.svc.connect("typst")
	if not fd then
		error("typst: service unavailable: " .. tostring(cerr), 3)
	end
	req.v = 1 -- protocol version: the service rejects an unversioned/incompatible request
	local resp, err = sys.svc.call(fd, json.encode(req))
	pcall(sys.svc.close, fd)
	if not resp then
		error("typst: " .. tostring(err), 3)
	end
	-- Decode the frame: [u32 LE header_len][header JSON][body…]. Read the u32 by bytes (binary-safe; the
	-- body is arbitrary PDF bytes, so a text decode would not do).
	if #resp < 4 then
		error("typst: malformed response from service", 3)
	end
	local b1, b2, b3, b4 = string.byte(resp, 1, 4)
	local hlen = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
	local header = json.decode(string.sub(resp, 5, 4 + hlen))
	local body = string.sub(resp, 5 + hlen)
	return header, body
end

-- Format a failed header's diagnostics into a multi-line `severity: file:line:col: message` error string.
local function formatErrors(header): string
	local parts = {}
	for _, d in ipairs(header.diagnostics or {}) do
		local loc = ""
		if d.file then
			loc = tostring(d.file)
			if d.line then
				loc = loc .. ":" .. tostring(d.line)
			end
			if d.col then
				loc = loc .. ":" .. tostring(d.col)
			end
			loc = loc .. ": "
		end
		table.insert(parts, tostring(d.severity or "error") .. ": " .. loc .. tostring(d.message))
		for _, hint in ipairs(d.hints or {}) do
			table.insert(parts, "  hint: " .. tostring(hint))
		end
	end
	return table.concat(parts, "\n")
end

local typst = {}

--- Compile inline Typst `source` to PDF bytes. `opts.root` sets the import/image resolution root for
--- `#image`/`#include` (default "/"). Returns `(pdf: string, warnings)` — `warnings` is the (possibly
--- empty) array of warning diagnostics. Raises on a compilation error, with the diagnostics formatted
--- `file:line:col: message`.
function typst.compile(source: string, opts: { root: string? }?)
	local header, body = request({ op = "compile", source = source, root = opts and opts.root })
	if not header.ok then
		error("typst: compilation failed\n" .. formatErrors(header), 2)
	end
	return body, header.diagnostics or {}
end

--- Compile a `.typ` FILE already in the VFS to PDF bytes. Imports/images resolve against `opts.root`
--- (default: the file's directory). Returns `(pdf, warnings)`. Raises on a compilation error.
function typst.compile_file(path: string, opts: { root: string? }?)
	local header, body = request({ op = "compile", main = path, root = opts and opts.root })
	if not header.ok then
		error("typst: compilation failed\n" .. formatErrors(header), 2)
	end
	return body, header.diagnostics or {}
end

--- The embedded Typst compiler version (e.g. "0.14.2").
function typst.version(): string
	local _, body = request({ op = "version" })
	return body
end

return typst
