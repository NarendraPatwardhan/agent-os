-- xml.luau — a standalone, namespace-aware XML library: an ordered, lossless DOM,
-- a parser (DOM + streaming SAX over one tokenizer), a faithful escaping
-- serializer, and a well-formedness validator. A first-class module:
-- XML is its own domain — agents read/write SVG, RSS, config, and OOXML — and it
-- is the substrate the zip/opc + office tier build on (luau-extensions Ch.04).
--
-- The canonical model keeps children IN DOCUMENT ORDER with a discriminated `kind`
-- (element/text/cdata/comment/pi), because order is significant and only the
-- ordered model round-trips. A lossy `toView` is offered separately, eyes open.
--
-- Node shapes:
--   element  = { kind="element", name=Name, attributes={Attr...}, children={Child...} }
--   text     = { kind="text", value=string, preserve=boolean? }
--   cdata    = { kind="cdata", value=string }
--   comment  = { kind="comment", value=string }
--   pi       = { kind="pi", target=string, value=string }
--   document = { kind="document", declaration=Decl?, prolog={Child...}, root=element }
--   Name     = { prefix=string?, local_=string, uri=string? }
--   Attr     = { name=Name, value=string }

local xml = {}

-- Namespace URIs that are always in scope (XML 1.0 reserved prefixes).
local XML_NS = "http://www.w3.org/XML/1998/namespace"
local XMLNS_NS = "http://www.w3.org/2000/xmlns/"

-- ===========================================================================
-- Names + builders
-- ===========================================================================

-- Parse a qualified name: "w:p" → { prefix="w", local_="p" }; "p" → { local_="p" }.
function xml.name(qualified)
	local prefix, lname = qualified:match("^([^:]+):(.+)$")
	if prefix then
		return { prefix = prefix, local_ = lname }
	end
	return { local_ = qualified }
end

-- Render a Name back to its qualified string ("w:p" / "p").
local function qualify(name)
	if name.prefix then
		return name.prefix .. ":" .. name.local_
	end
	return name.local_
end
xml.qualify = qualify

-- element(name, attrs?, children?) — `name` is a qualified string; `attrs` is a
-- { [qualified]=value } map (normalized to an ordered list: xmlns* first, then
-- the rest sorted for determinism — Luau map order is unspecified). For
-- order-critical attributes, pass a pre-built { Attr... } list instead.
function xml.element(name, attrs, children)
	local attributes = {}
	if attrs and attrs[1] ~= nil then
		-- already an ordered { Attr... } list
		attributes = attrs
	elseif attrs then
		local keys = {}
		for k in pairs(attrs) do
			keys[#keys + 1] = k
		end
		table.sort(keys, function(a, b)
			local an = a == "xmlns" or a:sub(1, 6) == "xmlns:"
			local bn = b == "xmlns" or b:sub(1, 6) == "xmlns:"
			if an ~= bn then
				return an
			end
			return a < b
		end)
		for _, k in ipairs(keys) do
			attributes[#attributes + 1] = { name = xml.name(k), value = attrs[k] }
		end
	end
	return {
		kind = "element",
		name = xml.name(name),
		attributes = attributes,
		children = children or {},
	}
end
xml.el = xml.element

function xml.text(s, preserve)
	return { kind = "text", value = s, preserve = preserve or nil }
end

function xml.cdata(s)
	return { kind = "cdata", value = s }
end

function xml.comment(s)
	return { kind = "comment", value = s }
end

function xml.pi(target, value)
	return { kind = "pi", target = target, value = value or "" }
end

-- ===========================================================================
-- Escaping + entities
-- ===========================================================================

-- Encode a Unicode code point as UTF-8 bytes (numeric character references can
-- name code points beyond ASCII; the output model is an 8-bit string).
local function utf8_encode(cp)
	if cp < 0x80 then
		return string.char(cp)
	elseif cp < 0x800 then
		return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
	elseif cp < 0x10000 then
		return string.char(
			0xE0 + math.floor(cp / 0x1000),
			0x80 + math.floor(cp / 0x40) % 0x40,
			0x80 + cp % 0x40
		)
	else
		return string.char(
			0xF0 + math.floor(cp / 0x40000),
			0x80 + math.floor(cp / 0x1000) % 0x40,
			0x80 + math.floor(cp / 0x40) % 0x40,
			0x80 + cp % 0x40
		)
	end
end

local PREDEFINED = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

-- Resolve the five predefined entities, numeric refs, and any caller-supplied
-- internal DTD entities. Errors (nil, msg) on an unknown/unterminated reference.
local function unescape(s, entities, limits)
	if not s:find("&", 1, true) then
		return s
	end
	local out = {}
	local i, n = 1, #s
	while i <= n do
		local amp = s:find("&", i, true)
		if not amp then
			out[#out + 1] = s:sub(i)
			break
		end
		if amp > i then
			out[#out + 1] = s:sub(i, amp - 1)
		end
		local semi = s:find(";", amp + 1, true)
		if not semi then
			return nil, "unterminated entity reference"
		end
		local ref = s:sub(amp + 1, semi - 1)
		local rep
		if ref:sub(1, 1) == "#" then
			local cp
			if ref:sub(2, 2) == "x" or ref:sub(2, 2) == "X" then
				cp = tonumber(ref:sub(3), 16)
			else
				cp = tonumber(ref:sub(2))
			end
			if not cp then
				return nil, "invalid numeric character reference &" .. ref .. ";"
			end
			rep = utf8_encode(cp)
		elseif PREDEFINED[ref] then
			rep = PREDEFINED[ref]
		elseif entities and entities[ref] then
			rep = entities[ref]
			limits.expansions = limits.expansions + 1
			if limits.expansions > limits.maxExpansions then
				return nil, "entity expansion limit exceeded"
			end
		else
			return nil, "undefined entity &" .. ref .. ";"
		end
		out[#out + 1] = rep
		i = semi + 1
	end
	return table.concat(out)
end

-- Escape text content: &, <, > (and \r, to keep CRLF from round-tripping wrong).
local function escape_text(s)
	return (
		s:gsub("[&<>\r]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ["\r"] = "&#13;" })
	)
end

-- Escape an attribute value: &, <, the quote in use, and whitespace that must
-- survive a round-trip (tab/newline/CR normalize to spaces otherwise).
local function escape_attr(s)
	return (
		s:gsub('[&<"\t\n\r]', {
			["&"] = "&amp;",
			["<"] = "&lt;",
			['"'] = "&quot;",
			["\t"] = "&#9;",
			["\n"] = "&#10;",
			["\r"] = "&#13;",
		})
	)
end

-- ===========================================================================
-- Namespace-aware queries
-- ===========================================================================

-- True iff `name` resolves to {uri, local_}. A nil `uri` matches names with no
-- namespace; a "*" local_ matches any local name in the uri.
function xml.matches(name, uri, local_)
	if name.uri ~= uri then
		return false
	end
	return local_ == "*" or name.local_ == local_
end

-- First direct child element of `el` matching (uri, local_); nil if none.
function xml.find(el, uri, local_)
	for _, child in ipairs(el.children) do
		if child.kind == "element" and xml.matches(child.name, uri, local_) then
			return child
		end
	end
	return nil
end

-- All direct child elements matching (uri, local_), in document order.
function xml.findAll(el, uri, local_)
	local out = {}
	for _, child in ipairs(el.children) do
		if child.kind == "element" and xml.matches(child.name, uri, local_) then
			out[#out + 1] = child
		end
	end
	return out
end

-- Attribute value on `el` by (uri, local_); `uri` nil matches an unprefixed attr.
function xml.attr(el, uri, local_)
	for _, a in ipairs(el.attributes) do
		if a.name.uri == uri and a.name.local_ == local_ then
			return a.value
		end
	end
	return nil
end

-- Concatenated text of an element's direct text/cdata children (a common need).
function xml.textOf(el)
	local out = {}
	for _, child in ipairs(el.children) do
		if child.kind == "text" or child.kind == "cdata" then
			out[#out + 1] = child.value
		end
	end
	return table.concat(out)
end

-- ===========================================================================
-- The tokenizer + SAX driver
-- ===========================================================================

local NAME_STOP = "[%s/>=]" -- a name ends at whitespace, '/', '>' or '='

-- Resolve a prefix against the in-scope namespace stack (top of stack wins). The
-- reserved `xml`/`xmlns` prefixes are always bound; an unprefixed name has no uri
-- unless a default xmlns is in scope (handled by the caller for elements only).
local function resolve_prefix(scopes, prefix)
	if prefix == "xml" then
		return XML_NS
	end
	if prefix == "xmlns" then
		return XMLNS_NS
	end
	for s = #scopes, 1, -1 do
		local uri = scopes[s][prefix]
		if uri ~= nil then
			return uri ~= "" and uri or nil
		end
	end
	return nil
end

-- parseSax(source, handler, opts?) → true | nil, err. One push tokenizer feeding
-- handler callbacks: onOpen(name, attrs, selfClosing), onText(value),
-- onClose(name), onCData(value), onComment(value), onPI(target, value),
-- onDecl(decl). `name`/`attrs[*].name` are resolved Names; prefixes are retained.
function xml.parseSax(source, handler, opts)
	opts = opts or {}
	local src = type(source) == "buffer" and buffer.tostring(source) or source
	local i, n = 1, #src
	local resolveNs = opts.resolveNamespaces ~= false
	local maxDepth = opts.maxDepth or 256
	local entities = {}
	local limits = {
		expansions = 0,
		maxExpansions = (opts.entityLimits and opts.entityLimits.maxEntityExpansions) or 1000,
	}

	-- Namespace scope stack (each entry maps prefix → uri; "" key = default ns).
	local scopes = {}
	-- Open-element name stack (parallel to the non-self-closing depth) so close
	-- tags can be matched against their opening tag.
	local tagstack = {}
	local depth = 0
	local seenRoot = false -- a second element at depth 0 is `xml/multiple-roots`

	local function fail(msg)
		-- Approximate line/col from the byte offset for diagnostics.
		local consumed = src:sub(1, i - 1)
		local _, nl = consumed:gsub("\n", "")
		local line = nl + 1
		local lastnl = consumed:find("\n[^\n]*$")
		local col = lastnl and (i - lastnl) or i
		return nil, { code = msg.code, message = msg.message, line = line, col = col }
	end

	-- Resolve an element/attribute name's uri given the current scopes. Default
	-- namespace applies to elements (`isAttr`=false) but never to attributes.
	local function resolve_name(qualified, isAttr)
		local nm = xml.name(qualified)
		if resolveNs then
			if nm.prefix then
				nm.uri = resolve_prefix(scopes, nm.prefix)
			elseif not isAttr then
				nm.uri = resolve_prefix(scopes, "") -- default namespace
			end
		end
		return nm
	end

	while i <= n do
		local lt = src:find("<", i, true)
		if not lt then
			-- trailing character data
			local rest = src:sub(i)
			if rest:find("%S") and depth == 0 then
				return fail({
					code = "xml/unexpected-eof",
					message = "character data after root element",
				})
			end
			if handler.onText and depth > 0 then
				local v, e = unescape(rest, entities, limits)
				if not v then
					return fail({ code = "xml/invalid-char", message = e })
				end
				handler.onText(v)
			end
			break
		end

		if lt > i then
			local v, e = unescape(src:sub(i, lt - 1), entities, limits)
			if not v then
				return fail({ code = "xml/invalid-char", message = e })
			end
			if depth == 0 then
				if v:find("%S") then
					return fail({
						code = "xml/invalid-char",
						message = "character data outside the root element",
					})
				end
			elseif handler.onText then
				handler.onText(v)
			end
		end
		i = lt

		local c2 = src:sub(i + 1, i + 1)
		if c2 == "/" then
			-- close tag  </name>
			local gt = src:find(">", i + 2, true)
			if not gt then
				return fail({ code = "xml/unexpected-eof", message = "unterminated close tag" })
			end
			local qualified = src:sub(i + 2, gt - 1):match("^%s*([^%s]+)%s*$")
			if not qualified then
				return fail({ code = "xml/invalid-tag", message = "malformed close tag" })
			end
			if tagstack[#tagstack] ~= qualified then
				return fail({
					code = "xml/mismatched-tag",
					message = "</"
						.. qualified
						.. "> does not match <"
						.. (tagstack[#tagstack] or "(none)")
						.. ">",
				})
			end
			local nm = resolve_name(qualified, false)
			if handler.onClose then
				handler.onClose(nm)
			end
			scopes[#scopes] = nil
			tagstack[#tagstack] = nil
			depth -= 1
			i = gt + 1
		elseif c2 == "!" then
			if src:sub(i, i + 3) == "<!--" then
				local close = src:find("-->", i + 4, true)
				if not close then
					return fail({ code = "xml/unexpected-eof", message = "unterminated comment" })
				end
				if opts.preserveComments ~= false and handler.onComment then
					handler.onComment(src:sub(i + 4, close - 1))
				end
				i = close + 3
			elseif src:sub(i, i + 8) == "<![CDATA[" then
				local close = src:find("]]>", i + 9, true)
				if not close then
					return fail({ code = "xml/unexpected-eof", message = "unterminated CDATA" })
				end
				if handler.onCData then
					handler.onCData(src:sub(i + 9, close - 1))
				end
				i = close + 3
			elseif src:sub(i, i + 8):upper() == "<!DOCTYPE" then
				-- Capture internal `<!ENTITY name "value">` defs; reject external.
				local close, j = nil, i + 9
				local depth_bracket = 0
				while j <= n do
					local ch = src:sub(j, j)
					if ch == "[" then
						depth_bracket += 1
					elseif ch == "]" then
						depth_bracket -= 1
					elseif ch == ">" and depth_bracket <= 0 then
						close = j
						break
					end
					j += 1
				end
				if not close then
					return fail({ code = "xml/unexpected-eof", message = "unterminated DOCTYPE" })
				end
				local dtd = src:sub(i, close)
				if dtd:find("SYSTEM") or dtd:find("PUBLIC") then
					return fail({
						code = "xml/invalid-char",
						message = "external DTD/entities are not allowed",
					})
				end
				for name, val in dtd:gmatch('<!ENTITY%s+([%w_%-%.]+)%s+"([^"]*)"%s*>') do
					entities[name] = val
				end
				i = close + 1
			else
				return fail({
					code = "xml/invalid-tag",
					message = "unrecognized markup declaration",
				})
			end
		elseif c2 == "?" then
			local close = src:find("?>", i + 2, true)
			if not close then
				return fail({
					code = "xml/unexpected-eof",
					message = "unterminated processing instruction",
				})
			end
			local body = src:sub(i + 2, close - 1)
			local target = body:match("^([^%s]+)")
			local value = body:sub((target and #target or 0) + 1):match("^%s*(.-)%s*$") or ""
			if target and target:lower() == "xml" then
				if handler.onDecl then
					handler.onDecl({
						version = value:match('version%s*=%s*"([^"]*)"')
							or value:match("version%s*=%s*'([^']*)'"),
						encoding = value:match('encoding%s*=%s*"([^"]*)"')
							or value:match("encoding%s*=%s*'([^']*)'"),
						standalone = (value:match('standalone%s*=%s*"([^"]*)"') == "yes") or nil,
					})
				end
			elseif handler.onPI and opts.preservePIs ~= false then
				handler.onPI(target, value)
			end
			i = close + 2
		else
			-- open tag  <name attrs...> or <name.../>
			local j = i + 1
			local name_end = src:find(NAME_STOP, j)
			if not name_end then
				return fail({ code = "xml/unexpected-eof", message = "unterminated start tag" })
			end
			local qualified = src:sub(j, name_end - 1)
			if qualified == "" then
				return fail({ code = "xml/invalid-tag", message = "empty element name" })
			end
			j = name_end

			-- Scan raw attributes (quote-aware) up to '>' or '/>'.
			local raw_attrs = {}
			local self_closing = false
			while true do
				-- skip whitespace
				local _, ws = src:find("^%s*", j)
				j = ws + 1
				local ch = src:sub(j, j)
				if ch == "" then
					return fail({ code = "xml/unexpected-eof", message = "unterminated start tag" })
				elseif ch == ">" then
					j += 1
					break
				elseif ch == "/" then
					if src:sub(j, j + 1) ~= "/>" then
						return fail({ code = "xml/invalid-tag", message = "expected '/>'" })
					end
					self_closing = true
					j += 2
					break
				end
				-- attribute name
				local aname_end = src:find("[%s=/>]", j)
				if not aname_end then
					return fail({ code = "xml/unexpected-eof", message = "unterminated attribute" })
				end
				local aname = src:sub(j, aname_end - 1)
				j = aname_end
				local _, ws2 = src:find("^%s*", j)
				j = ws2 + 1
				if src:sub(j, j) ~= "=" then
					return fail({
						code = "xml/invalid-attr",
						message = "attribute '" .. aname .. "' has no value",
					})
				end
				j += 1
				local _, ws3 = src:find("^%s*", j)
				j = ws3 + 1
				local quote = src:sub(j, j)
				if quote ~= '"' and quote ~= "'" then
					return fail({
						code = "xml/invalid-attr",
						message = "attribute value must be quoted",
					})
				end
				local vend = src:find(quote, j + 1, true)
				if not vend then
					return fail({
						code = "xml/unexpected-eof",
						message = "unterminated attribute value",
					})
				end
				local avalue, e = unescape(src:sub(j + 1, vend - 1), entities, limits)
				if not avalue then
					return fail({ code = "xml/invalid-attr", message = e })
				end
				raw_attrs[#raw_attrs + 1] = { qname = aname, value = avalue }
				j = vend + 1
			end

			-- Push a namespace scope from this element's xmlns* declarations.
			local scope = {}
			for _, a in ipairs(raw_attrs) do
				if a.qname == "xmlns" then
					scope[""] = a.value
				elseif a.qname:sub(1, 6) == "xmlns:" then
					scope[a.qname:sub(7)] = a.value
				end
			end
			scopes[#scopes + 1] = scope

			-- Detect duplicate attributes (well-formedness).
			local seen = {}
			for _, a in ipairs(raw_attrs) do
				if seen[a.qname] then
					return fail({
						code = "xml/invalid-attr",
						message = "duplicate attribute '" .. a.qname .. "'",
					})
				end
				seen[a.qname] = true
			end

			local attrs = {}
			for _, a in ipairs(raw_attrs) do
				attrs[#attrs + 1] = { name = resolve_name(a.qname, true), value = a.value }
			end
			local nm = resolve_name(qualified, false)

			if depth == 0 then
				if seenRoot then
					return fail({
						code = "xml/multiple-roots",
						message = "more than one root element",
					})
				end
				seenRoot = true
			end

			if handler.onOpen then
				handler.onOpen(nm, attrs, self_closing)
			end
			if self_closing then
				scopes[#scopes] = nil
				if handler.onClose then
					handler.onClose(nm)
				end
			else
				tagstack[#tagstack + 1] = qualified
				depth += 1
				if depth > maxDepth then
					return fail({
						code = "xml/invalid-char",
						message = "maximum nesting depth exceeded",
					})
				end
			end
			i = j
		end
	end

	if depth ~= 0 then
		return fail({
			code = "xml/unexpected-eof",
			message = "unexpected end of input: unclosed elements",
		})
	end
	return true
end

-- ===========================================================================
-- DOM parser (built on the SAX driver — one tokenizer)
-- ===========================================================================

-- parse(source, opts?) → document | nil, err. The ordered DOM. The DOM builder is
-- itself a SaxHandler, proving the abstraction and keeping a single tokenizer.
function xml.parse(source, opts)
	local doc = { kind = "document", prolog = {}, root = nil }
	local stack = {} -- element stack; top is the current parent
	local rootSeen = false

	local function add_child(node)
		if #stack > 0 then
			local parent = stack[#stack]
			parent.children[#parent.children + 1] = node
		elseif not rootSeen then
			doc.prolog[#doc.prolog + 1] = node
		end
		-- nodes after the root are rejected by the tokenizer, so no trailing case
	end

	local coalesce = opts == nil or opts.coalesceText ~= false

	local handler = {
		onDecl = function(decl)
			doc.declaration = decl
		end,
		onOpen = function(name, attrs)
			local el = { kind = "element", name = name, attributes = attrs, children = {} }
			if #stack == 0 then
				if rootSeen then
					return -- guarded by tokenizer; defensive
				end
				doc.root = el
				rootSeen = true
			else
				add_child(el)
			end
			stack[#stack + 1] = el
		end,
		onClose = function()
			stack[#stack] = nil
		end,
		onText = function(value)
			local parent = stack[#stack]
			if not parent then
				return
			end
			local kids = parent.children
			if coalesce and #kids > 0 and kids[#kids].kind == "text" then
				kids[#kids].value ..= value
			else
				kids[#kids + 1] = { kind = "text", value = value }
			end
		end,
		onCData = function(value)
			add_child({ kind = "cdata", value = value })
		end,
		onComment = function(value)
			add_child({ kind = "comment", value = value })
		end,
		onPI = function(target, value)
			add_child({ kind = "pi", target = target, value = value })
		end,
	}

	local ok, err = xml.parseSax(source, handler, opts)
	if not ok then
		return nil, err
	end
	if not doc.root then
		return nil,
			{
				code = "xml/multiple-roots",
				message = "document has no root element",
				line = 1,
				col = 1,
			}
	end
	return doc
end

-- ===========================================================================
-- Serializer
-- ===========================================================================

-- A buffer-backed string builder with lazy tag closing and omit-on-nil attrs.
local function new_writer()
	local parts = {}
	return {
		parts = parts,
		raw = function(self, s)
			parts[#parts + 1] = s
		end,
		build = function(self)
			return table.concat(parts)
		end,
	}
end

local function serialize_node(node, w, opts, indent, depth)
	local kind = node.kind
	if kind == "text" then
		w:raw(escape_text(node.value))
	elseif kind == "cdata" then
		-- A `]]>` inside CDATA must be split across two sections.
		w:raw("<![CDATA[" .. node.value:gsub("]]>", "]]]]><![CDATA[>") .. "]]>")
	elseif kind == "comment" then
		w:raw("<!--" .. node.value .. "-->")
	elseif kind == "pi" then
		w:raw("<?" .. node.target .. (node.value ~= "" and (" " .. node.value) or "") .. "?>")
	elseif kind == "element" then
		w:raw("<" .. qualify(node.name))
		for _, a in ipairs(node.attributes) do
			if a.value ~= nil then
				w:raw(" " .. qualify(a.name) .. '="' .. escape_attr(a.value) .. '"')
			end
		end
		if #node.children == 0 and opts.selfClose ~= false then
			w:raw("/>")
			return
		end
		w:raw(">")

		-- Pretty-print only element-only content; never reflow text/cdata.
		local hasText = false
		for _, c in ipairs(node.children) do
			if c.kind == "text" or c.kind == "cdata" then
				hasText = true
				break
			end
		end
		local pretty = opts.pretty and not hasText and #node.children > 0
		for _, c in ipairs(node.children) do
			if pretty then
				w:raw(opts.newline .. string.rep(indent, depth + 1))
			end
			serialize_node(c, w, opts, indent, depth + 1)
		end
		if pretty then
			w:raw(opts.newline .. string.rep(indent, depth))
		end
		w:raw("</" .. qualify(node.name) .. ">")
	end
end

-- serialize(nodeOrDoc, opts?) → string. Faithful, correctly escaped, namespace
-- prefixes reproduced from each Name; self-closing for empty elements by default.
function xml.serialize(node, opts)
	opts = opts or {}
	opts.newline = opts.newline or "\n"
	local indent = opts.indent or "  "
	local w = new_writer()

	if node.kind == "document" then
		if opts.declaration ~= false then
			local d = node.declaration or {}
			w:raw(
				'<?xml version="'
					.. (d.version or "1.0")
					.. '" encoding="'
					.. (d.encoding or "UTF-8")
					.. '"'
			)
			if d.standalone then
				w:raw(' standalone="yes"')
			end
			w:raw("?>" .. opts.newline)
		end
		for _, c in ipairs(node.prolog or {}) do
			serialize_node(c, w, opts, indent, 0)
			if opts.pretty then
				w:raw(opts.newline)
			end
		end
		serialize_node(node.root, w, opts, indent, 0)
	else
		serialize_node(node, w, opts, indent, 0)
	end
	return w:build()
end

-- ===========================================================================
-- Validator (well-formedness, on top of the tokenizer)
-- ===========================================================================

-- validate(source) → true | nil, err. Reports the first well-formedness error
-- with line/col. Separate from `parse` (never on the hot path); a pre-flight gate.
function xml.validate(source)
	local rootSeen = false
	local handler = {
		onOpen = function()
			rootSeen = true
		end,
	}
	local ok, err = xml.parseSax(source, handler, {})
	if not ok then
		return nil, err
	end
	if not rootSeen then
		return nil, { code = "xml/multiple-roots", message = "no root element", line = 1, col = 1 }
	end
	return true
end

-- ===========================================================================
-- Convenience table view (lossy, opt-in) — never used internally
-- ===========================================================================

-- toView(el, opts?) → table. Collapses the ordered DOM into a plain table for
-- read-mostly access. LOSSY: order across differently-named siblings is dropped;
-- pass `forceArray(path)` to keep collection elements as arrays. Do NOT round-trip.
function xml.toView(el, opts)
	opts = opts or {}
	local attrPrefix = opts.attributePrefix or "@"
	local textKey = opts.textKey or "#text"

	local function convert(element, path)
		local t = {}
		for _, a in ipairs(element.attributes) do
			t[attrPrefix .. qualify(a.name)] = a.value
		end
		local text = {}
		for _, child in ipairs(element.children) do
			if child.kind == "element" then
				local key = qualify(child.name)
				local childPath = path .. "/" .. key
				local value = convert(child, childPath)
				local force = opts.forceArray and opts.forceArray(childPath)
				if t[key] == nil and not force then
					t[key] = value
				else
					if type(t[key]) ~= "table" or t[key].__isArray == nil then
						local existing = t[key]
						t[key] = { __isArray = true }
						if existing ~= nil then
							t[key][1] = existing
						end
					end
					t[key][#t[key] + 1] = value
				end
			elseif child.kind == "text" or child.kind == "cdata" then
				text[#text + 1] = child.value
			end
		end
		-- normalize array markers
		for k, v in pairs(t) do
			if type(v) == "table" and v.__isArray then
				v.__isArray = nil
			end
		end
		local joined = table.concat(text)
		if joined ~= "" then
			if next(t) == nil then
				return joined
			end
			t[textKey] = joined
		end
		return t
	end

	return convert(el, qualify(el.name))
end

return xml
