-- xform.luau — the bidirectional model⇄XML engine (luau-extensions Ch.05): the
-- reusable machinery the OOXML formats are written in. ONE definition per element
-- maps a typed Luau model to and from XML, so read and write can never drift. It is
-- generic — it knows nothing about a specific format; the format models (docx/xlsx/
-- pptx, the next cut) just *describe* themselves with these combinators.
--
-- Built on the `xml` battery's ordered DOM: an xform's `render`
-- produces an XmlElement (or nil when self-pruned), its `parse` consumes one. The
-- DOM is the v1 sink; the design's direct-to-writer / SAX-streaming sinks are a
-- later optimisation that reuses the *same* xform definitions (only the sink
-- differs). Three guarantees carry over from the design:
--   • No read/write drift — one definition, both directions.
--   • Schema-ordered output — `composite.children` order IS the emit order; the #1
--     cause of "Office must repair this file" is structurally avoided.
--   • Two-phase build — `prepare` allocates/interns cross-references (rIds, shared
--     strings, …) up front; `render` is pure, so part render-order can't affect
--     output and ids in markup / .rels / zip always agree.
--
-- An Xform is a plain table:
--   { tag, localName, prepare?(ctx, model), render(ctx, model)->el?, parse(ctx, el)->model }
-- Combinators close over their spec and produce one. `ctx` is opaque to the engine
-- (threaded down untouched) — a format puts its RenderContext / pools there.

local xml = require("xml")

local xform = {}

-- The local part of a qualified name ("w:val" → "val"); used to match incoming
-- elements/attributes (within a part, prefixes are consistent, local names unique).
local function local_of(tag)
	return tag:match(":(.+)$") or tag
end

-- Find an attribute on `el` by the local part of `attrTag`.
local function find_attr(el, attrTag)
	local ln = local_of(attrTag)
	for _, a in ipairs(el.attributes) do
		if a.name.local_ == ln then
			return a.value
		end
	end
	return nil
end

local function deepcopy(v)
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, val in pairs(v) do
		out[k] = deepcopy(val)
	end
	return out
end

-- ===========================================================================
-- Scalar kinds — the encode/decode at the value boundary (overridable per field)
-- ===========================================================================

local KIND = {
	string = { enc = function(v) return v end, dec = function(s) return s end },
	int = {
		enc = function(v) return tostring(math.floor(v)) end,
		dec = function(s) return math.floor(tonumber(s) or 0) end,
	},
	float = { enc = function(v) return tostring(v) end, dec = function(s) return tonumber(s) end },
	bool = {
		enc = function(v) return v and "true" or "false" end,
		dec = function(s) return s == "true" or s == "1" end,
	},
	enum = { enc = function(v) return v end, dec = function(s) return s end },
}

xform.KIND = KIND

-- ===========================================================================
-- scalar — a leaf element carrying one value as an attribute or as text
-- ===========================================================================

-- scalar{ tag, as="attr"|"text", attr?, kind?, default?, boolStyle? }
--   as="attr" (default): the value lives in attribute `attr` (default "val") of an
--     otherwise-empty element, e.g. <w:jc w:val="center"/>.
--   as="text": the value is the element's text, e.g. <w:t>hello</w:t>.
--   boolStyle="presence": a true bool renders the bare element <w:b/>, false/nil
--     renders nothing (the docx idiom); on parse, the element's presence is `true`.
-- A value equal to `default` (or nil) renders NOTHING (default-elision).
function xform.scalar(spec)
	local kind = spec.kind or "string"
	local codec = KIND[kind]
	-- custom value transforms override the kind codec (e.g. points→half-points)
	local enc = spec.encode or codec.enc
	local dec = spec.decode or codec.dec
	local as = spec.as or "attr"
	local attr = spec.attr or "val"
	local default = spec.default
	local presence = kind == "bool" and spec.boolStyle == "presence"

	return {
		tag = spec.tag,
		localName = local_of(spec.tag),
		render = function(_, value)
			if value == nil or value == default then
				return nil
			end
			if presence then
				return value and xml.element(spec.tag) or nil
			end
			if as == "attr" then
				return xml.element(spec.tag, { [attr] = codec.enc(value) })
			end
			return xml.element(spec.tag, {}, { xml.text(codec.enc(value)) })
		end,
		parse = function(_, el)
			if presence then
				return true
			end
			if as == "attr" then
				local raw = find_attr(el, attr)
				if raw == nil then
					return default
				end
				return codec.dec(raw)
			end
			return codec.dec(xml.textOf(el))
		end,
	}
end

-- ===========================================================================
-- composite — an element with attribute bindings + ordered named children
--             (+ optional heterogeneous direct `content`)
-- ===========================================================================

-- composite{
--   tag,
--   attributes? = { AttrBinding... },   -- ORDERED; AttrBinding = { attr, key, kind?, default?, encode?, decode? }
--   children?   = { Field... },         -- ORDERED == schema order; Field = { key, xform } (key nil ⇒ static/discard)
--   content?    = { key, choices = { { kind, xform }... } },  -- repeated direct children of mixed types
--   new?        = () -> model,          -- seed an empty model on parse
--   keepIfEmpty?= boolean,              -- render even when empty (default: self-prune)
--   prepareSelf?= (ctx, model) -> (),   -- extra phase-1 work for cross-references
-- }
function xform.composite(spec)
	local attrs = spec.attributes or {}
	local children = spec.children or {}
	local content = spec.content

	-- parse dispatch tables
	local byLocal = {}
	for _, field in ipairs(children) do
		if field.xform.localName then
			byLocal[field.xform.localName] = field
		end
	end
	local contentByLocal, contentByKind = {}, {}
	if content then
		for _, choice in ipairs(content.choices) do
			contentByLocal[choice.xform.localName] = choice
			contentByKind[choice.kind] = choice
		end
	end

	return {
		tag = spec.tag,
		localName = local_of(spec.tag),

		prepare = function(ctx, model)
			if model == nil then
				return
			end
			for _, field in ipairs(children) do
				if field.key and field.xform.prepare then
					field.xform.prepare(ctx, model[field.key])
				end
			end
			if content and model[content.key] then
				for _, item in ipairs(model[content.key]) do
					local choice = contentByKind[item.kind]
					if choice and choice.xform.prepare then
						choice.xform.prepare(ctx, item)
					end
				end
			end
			if spec.prepareSelf then
				spec.prepareSelf(ctx, model)
			end
		end,

		render = function(ctx, model)
			if model == nil then
				return nil
			end
			local el = xml.element(spec.tag)
			for _, b in ipairs(attrs) do
				local v = model[b.key]
				if v ~= nil and v ~= b.default then
					local enc = b.encode and b.encode(v) or KIND[b.kind or "string"].enc(v)
					el.attributes[#el.attributes + 1] = { name = xml.name(b.attr), value = enc }
				end
			end
			for _, field in ipairs(children) do
				-- explicit (not `key and model[key] or nil`, which mishandles `false`)
				local value = nil
				if field.key then
					value = model[field.key]
				end
				local childEl = field.xform.render(ctx, value)
				if childEl ~= nil then
					el.children[#el.children + 1] = childEl
				end
			end
			if content and model[content.key] then
				for _, item in ipairs(model[content.key]) do
					local choice = contentByKind[item.kind]
					if choice then
						local childEl = choice.xform.render(ctx, item)
						if childEl ~= nil then
							el.children[#el.children + 1] = childEl
						end
					end
				end
			end
			if not spec.keepIfEmpty and #el.attributes == 0 and #el.children == 0 then
				return nil -- self-prune
			end
			return el
		end,

		parse = function(ctx, el)
			local model = spec.new and spec.new() or {}
			for _, b in ipairs(attrs) do
				local raw = find_attr(el, b.attr)
				if raw ~= nil then
					model[b.key] = b.decode and b.decode(raw) or KIND[b.kind or "string"].dec(raw)
				elseif b.default ~= nil then
					model[b.key] = b.default
				end
			end
			if content then
				model[content.key] = model[content.key] or {}
			end
			for _, child in ipairs(el.children) do
				if child.kind == "element" then
					local field = byLocal[child.name.local_]
					if field then
						if field.key then
							model[field.key] = field.xform.parse(ctx, child)
						end -- key nil ⇒ static/discard
					elseif content then
						local choice = contentByLocal[child.name.local_]
						if choice then
							local item = choice.xform.parse(ctx, child)
							item.kind = item.kind or choice.kind
							local arr = model[content.key]
							arr[#arr + 1] = item
						end
					end
				end
			end
			return model
		end,
	}
end

-- ===========================================================================
-- list — a container element holding repeated homogeneous items
-- ===========================================================================

-- list{ tag, item (xform), countAttr?, keepIfEmpty? }. Model is an array. The
-- container is rendered even when empty (self-closes) unless you compose it as an
-- optional composite child. `countAttr` emits count="N" (xlsx sst/styles want it).
function xform.list(spec)
	return {
		tag = spec.tag,
		localName = local_of(spec.tag),
		prepare = function(ctx, array)
			if array and spec.item.prepare then
				for _, it in ipairs(array) do
					spec.item.prepare(ctx, it)
				end
			end
		end,
		render = function(ctx, array)
			array = array or {}
			local el = xml.element(spec.tag)
			if spec.countAttr then
				el.attributes[#el.attributes + 1] = { name = xml.name(spec.countAttr), value = tostring(#array) }
			end
			for _, it in ipairs(array) do
				local childEl = spec.item.render(ctx, it)
				if childEl ~= nil then
					el.children[#el.children + 1] = childEl
				end
			end
			return el
		end,
		parse = function(ctx, el)
			local array = {}
			for _, child in ipairs(el.children) do
				if child.kind == "element" and child.name.local_ == spec.item.localName then
					array[#array + 1] = spec.item.parse(ctx, child)
				end
			end
			return array
		end,
	}
end

-- ===========================================================================
-- static — invariant boilerplate (rendered as a constant, discarded on parse)
-- ===========================================================================

-- static(literalXml) — for fixed blocks (a boilerplate <a:lstStyle/>, a theme
-- fragment). Parses the literal once and deep-copies it per render (the copy keeps
-- a later tree mutation from aliasing the memoized constant).
function xform.static(literalXml)
	local memo
	local root_local
	do
		local doc = xml.parse(literalXml)
		if doc then
			memo = doc.root
			root_local = doc.root.name.local_
		end
	end
	return {
		tag = nil,
		localName = root_local, -- so a composite can match+discard it on parse
		render = function()
			return memo and deepcopy(memo) or nil
		end,
		parse = function()
			return nil
		end,
	}
end

-- ===========================================================================
-- Interning pool — the two-phase cross-reference primitive (shared strings,
-- styles, media). `intern` dedups by a canonical key and returns a STABLE 0-based
-- index assigned in prepare-walk order (deterministic for a given model).
-- ===========================================================================

function xform.pool()
	local items = {}
	local indexOf = {}
	return {
		items = items,
		intern = function(key, value)
			local existing = indexOf[key]
			if existing ~= nil then
				return existing
			end
			items[#items + 1] = (value == nil) and key or value
			local idx = #items - 1 -- 0-based (OOXML indices are 0-based)
			indexOf[key] = idx
			return idx
		end,
		get = function(idx)
			return items[idx + 1]
		end,
		count = function()
			return #items
		end,
	}
end

-- ===========================================================================
-- Drivers
-- ===========================================================================

-- render(xf, model, ctx?) → XmlElement | nil. Runs phase 1 (prepare) then phase 2
-- (render). `ctx` defaults to an empty table.
function xform.render(xf, model, ctx)
	ctx = ctx or {}
	if xf.prepare then
		xf.prepare(ctx, model)
	end
	return xf.render(ctx, model)
end

-- parse(xf, element, ctx?) → model.
function xform.parse(xf, element, ctx)
	return xf.parse(ctx or {}, element)
end

-- renderDocument(xf, model, ctx?, serializeOpts?) → xml string (with declaration).
function xform.renderDocument(xf, model, ctx, opts)
	local root = xform.render(xf, model, ctx)
	return xml.serialize({ kind = "document", prolog = {}, root = root }, opts)
end

-- parseDocument(xf, xmlString, ctx?) → model | nil, err.
function xform.parseDocument(xf, src, ctx)
	local doc, err = xml.parse(src)
	if not doc then
		return nil, err
	end
	return xform.parse(xf, doc.root, ctx)
end

return xform
