-- opc.luau — the Open Packaging Conventions layer over `zip` + `xml`: the part /
-- content-type / relationship model that .docx/.xlsx/.pptx (and any OPC package)
-- share (luau-extensions Ch.03 part 2). This is the same for all three formats;
-- only the parts inside differ. The package is the owner of round-trip fidelity:
-- parts it doesn't model stay as bytes and are written back verbatim, and their
-- content-type entries and relationships are preserved (ctx/LUAU.md §7).
--
-- Logical part names are absolute with a leading slash ("/word/document.xml"); the
-- ZIP stores them without it. rIds are local to one .rels part and are allocated
-- max+1 — never renumbered, because markup elsewhere references them by string.

local zip = require("zip")
local xml = require("xml")
local path = require("path")

local opc = {}

local CT_NS = "http://schemas.openxmlformats.org/package/2006/content-types"
local REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
local REL_OFFICE_DOC = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"

-- Format root content-types → format tag (Package.detectFormat).
local FORMAT_BY_CT = {
	["application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"] = "docx",
	["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"] = "xlsx",
	["application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"] = "pptx",
}

-- ===========================================================================
-- Name helpers
-- ===========================================================================

local function abs_name(name)
	if name:sub(1, 1) ~= "/" then
		return "/" .. name
	end
	return name
end

local function zip_name(name) -- absolute logical name → zip entry name
	return (name:gsub("^/", ""))
end

local function ext_of(name)
	local e = path.ext(name)
	return e ~= "" and e:sub(2):lower() or ""
end

-- The .rels part name for a part: "/word/document.xml" → "/word/_rels/document.xml.rels";
-- the package root ("/" or "") → "/_rels/.rels".
local function rels_name_for(partName)
	if partName == "/" or partName == "" then
		return "/_rels/.rels"
	end
	local dir, base = path.split(partName)
	if dir == "/" then
		return "/_rels/" .. base .. ".rels"
	end
	return dir .. "/_rels/" .. base .. ".rels"
end

-- ===========================================================================
-- Content types
-- ===========================================================================

local function content_types_parse(bytes)
	local ct = { defaults = {}, overrides = {} }
	local doc, err = xml.parse(bytes)
	if not doc then
		return nil, "opc/bad-content-types: " .. err.message
	end
	for _, el in ipairs(doc.root.children) do
		if el.kind == "element" then
			if el.name.local_ == "Default" then
				local extn = xml.attr(el, nil, "Extension")
				local ctype = xml.attr(el, nil, "ContentType")
				if extn and ctype then
					ct.defaults[extn:lower()] = ctype
				end
			elseif el.name.local_ == "Override" then
				local pn = xml.attr(el, nil, "PartName")
				local ctype = xml.attr(el, nil, "ContentType")
				if pn and ctype then
					ct.overrides[pn] = ctype
				end
			end
		end
	end
	return ct
end

local function content_types_resolve(ct, partName)
	local o = ct.overrides[partName]
	if o then
		return o
	end
	return ct.defaults[ext_of(partName)]
end

-- Regenerate [Content_Types].xml deterministically: defaults (sorted), then
-- overrides (sorted) — always the FIRST entry in the archive on write.
local function content_types_serialize(ct)
	local root = xml.element("Types", { xmlns = CT_NS })
	local exts = {}
	for e in pairs(ct.defaults) do
		exts[#exts + 1] = e
	end
	table.sort(exts)
	for _, e in ipairs(exts) do
		root.children[#root.children + 1] =
			xml.element("Default", { Extension = e, ContentType = ct.defaults[e] })
	end
	local parts = {}
	for p in pairs(ct.overrides) do
		parts[#parts + 1] = p
	end
	table.sort(parts)
	for _, p in ipairs(parts) do
		root.children[#root.children + 1] =
			xml.element("Override", { PartName = p, ContentType = ct.overrides[p] })
	end
	return xml.serialize({ kind = "document", prolog = {}, root = root })
end

-- ===========================================================================
-- Relationships
-- ===========================================================================

local Rels = {}
Rels.__index = Rels

local function rels_new(sourcePart)
	return setmetatable({ sourcePart = sourcePart or "", items = {}, byId = {} }, Rels)
end

local function rels_parse(sourcePart, bytes)
	local r = rels_new(sourcePart)
	local doc, err = xml.parse(bytes)
	if not doc then
		return nil, "opc/bad-rels: " .. err.message
	end
	for _, el in ipairs(doc.root.children) do
		if el.kind == "element" and el.name.local_ == "Relationship" then
			local rel = {
				id = xml.attr(el, nil, "Id"),
				type = xml.attr(el, nil, "Type"),
				target = xml.attr(el, nil, "Target"),
				mode = xml.attr(el, nil, "TargetMode") or "Internal",
			}
			r.items[#r.items + 1] = rel
			r.byId[rel.id] = rel
		end
	end
	return r
end

-- add(relType, target, mode?) → new rId. Allocation appends max(existing)+1; we
-- never renumber, because markup references ids by string.
function Rels.add(self, relType, target, mode)
	local maxId = 0
	for _, rel in ipairs(self.items) do
		local num = tonumber(rel.id:match("^rId(%d+)$"))
		if num and num > maxId then
			maxId = num
		end
	end
	local id = "rId" .. (maxId + 1)
	local rel = { id = id, type = relType, target = target, mode = mode or "Internal" }
	self.items[#self.items + 1] = rel
	self.byId[id] = rel
	return id
end

function Rels.find(self, id)
	return self.byId[id]
end

-- The absolute part name a relationship points at (Internal only). Targets are
-- relative to the SOURCE part's folder; External targets are returned as-is.
function Rels.targetOf(self, id)
	local rel = self.byId[id]
	if not rel then
		return nil
	end
	if rel.mode == "External" then
		return rel.target
	end
	if rel.target:sub(1, 1) == "/" then
		return rel.target
	end
	local dir = self.sourcePart == "" and "/" or path.dirname(self.sourcePart)
	return path.normalize(path.join(dir, rel.target))
end

local function rels_serialize(r)
	local root = xml.element("Relationships", { xmlns = REL_NS })
	for _, rel in ipairs(r.items) do
		local attrs = { Id = rel.id, Type = rel.type, Target = rel.target }
		if rel.mode == "External" then
			attrs.TargetMode = "External"
		end
		root.children[#root.children + 1] = xml.element("Relationship", attrs)
	end
	return xml.serialize({ kind = "document", prolog = {}, root = root })
end

opc.relationships = { new = rels_new, parse = rels_parse }

-- ===========================================================================
-- Package
-- ===========================================================================

local Package = {}
Package.__index = Package

-- opc.new() → an empty package: just [Content_Types] with the two universal
-- defaults (rels, xml) and an empty root .rels. Formats add parts on top.
function opc.new()
	local pkg = setmetatable({
		parts = {}, -- [absName] = { name, contentType, bytes?, xml? }
		order = {}, -- absolute names, in write order
		contentTypes = {
			defaults = {
				rels = "application/vnd.openxmlformats-package.relationships+xml",
				xml = "application/xml",
			},
			overrides = {},
		},
		rels = {}, -- [absPartName] = Rels (sourcePart "" for the package root)
	}, Package)
	pkg.rels[""] = rels_new("")
	return pkg
end

-- Add (or replace) a part. `contentType` registers an Override unless it's already
-- covered by a Default for the extension. Returns the part.
function Package.addPart(self, name, content, contentType)
	name = abs_name(name)
	local part = { name = name, contentType = contentType }
	if type(content) == "table" and content.kind then
		part.xml = content -- an xml document/element
	else
		part.bytes = content
	end
	if self.parts[name] == nil then
		self.order[#self.order + 1] = name
	end
	self.parts[name] = part
	if contentType then
		local ext = ext_of(name)
		if self.contentTypes.defaults[ext] ~= contentType then
			self.contentTypes.overrides[name] = contentType
		end
	end
	return part
end

function Package.getPart(self, name)
	return self.parts[abs_name(name)]
end

-- The relationship set for a part (root rels for "" / "/"). Created on demand.
function Package.relsFor(self, partName)
	local key = (partName == "/" or partName == nil) and "" or abs_name(partName)
	if not self.rels[key] then
		self.rels[key] = rels_new(key)
	end
	return self.rels[key]
end

-- The package format, by following the root officeDocument relationship to its
-- target part and reading that part's content type.
function Package.detectFormat(self)
	local root = self.rels[""]
	if not root then
		return "unknown"
	end
	for _, rel in ipairs(root.items) do
		if rel.type == REL_OFFICE_DOC then
			local target = abs_name(rel.target)
			local ct = content_types_resolve(self.contentTypes, target)
			return ct and FORMAT_BY_CT[ct] or "unknown"
		end
	end
	return "unknown"
end

-- opc.read(bytes) → package | nil, err. Wraps every zip entry as a Part; XML parts
-- start as bytes and are parsed on demand by the format layer. [Content_Types].xml
-- and the root .rels are parsed eagerly; per-part .rels parse lazily via relsFor.
function opc.read(bytes)
	local archive, err = zip.read(bytes)
	if not archive then
		return nil, err
	end

	local ctEntry = archive.byName["[Content_Types].xml"]
	if not ctEntry then
		return nil, "opc/not-a-package: missing [Content_Types].xml"
	end
	local ct, cterr = content_types_parse(ctEntry.data)
	if not ct then
		return nil, cterr
	end

	local pkg = setmetatable({
		parts = {},
		order = {},
		contentTypes = ct,
		rels = {},
	}, Package)

	for _, entry in ipairs(archive.entries) do
		local name = entry.name
		if name ~= "[Content_Types].xml" then
			local abs = abs_name(name)
			if name:match("_rels/[^/]*%.rels$") then
				-- a relationships part: parse it and key it by its OWNER part
				local source
				if name == "_rels/.rels" then
					source = ""
				else
					-- "word/_rels/document.xml.rels" → owner "/word/document.xml"
					local dir = name:gsub("_rels/[^/]*$", "")
					local base = name:match("_rels/(.*)%.rels$")
					source = abs_name(dir .. base)
				end
				local r, rerr = rels_parse(source, entry.data)
				if not r then
					return nil, rerr
				end
				pkg.rels[source] = r
			else
				pkg.order[#pkg.order + 1] = abs
				pkg.parts[abs] = {
					name = abs,
					contentType = content_types_resolve(ct, abs),
					bytes = entry.data,
				}
			end
		end
	end
	if not pkg.rels[""] then
		pkg.rels[""] = rels_new("")
	end
	return pkg
end

-- opc.write(package) → bytes. Regenerates [Content_Types].xml (first entry) and
-- every .rels, serializes modeled XML parts, keeps unknown parts verbatim, then
-- zips. Modeled parts whose `.xml` was set are serialized; others pass through.
function opc.write(pkg)
	local archive = zip.new()
	-- [Content_Types].xml MUST be first and is regenerated from the current map.
	archive:add("[Content_Types].xml", content_types_serialize(pkg.contentTypes))

	-- Relationship parts (root + per-part), only when non-empty.
	local relKeys = {}
	for k in pairs(pkg.rels) do
		relKeys[#relKeys + 1] = k
	end
	table.sort(relKeys)
	for _, key in ipairs(relKeys) do
		local r = pkg.rels[key]
		if #r.items > 0 then
			local relsName = zip_name(rels_name_for(key == "" and "/" or key))
			archive:add(relsName, rels_serialize(r))
		end
	end

	-- Parts, in preserved order.
	for _, name in ipairs(pkg.order) do
		local part = pkg.parts[name]
		if part then
			local data
			if part.xml then
				data = xml.serialize(
					part.xml.kind == "document" and part.xml
						or { kind = "document", prolog = {}, root = part.xml }
				)
			else
				data = part.bytes or ""
			end
			archive:add(zip_name(name), data)
		end
	end

	return zip.write(archive)
end

return opc
