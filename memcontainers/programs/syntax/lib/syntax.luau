-- Typed Luau face of the warm /bin/syntax resident service. The binary codec is generated from
-- contracts/syntax.kdl; this file owns only ergonomic objects, paging, and lifetime management.
local wire = require("syntax_wire")

local syntax = {}
local fd = nil

local function connection()
	if fd ~= nil then
		return fd
	end
	local opened, err = sys.svc.connect("syntax")
	if opened == nil then
		error("syntax: service unavailable: " .. tostring(err), 3)
	end
	fd = opened
	return fd
end

local function message_id(bytes)
	if #bytes < 3 then
		error("syntax: malformed service response", 3)
	end
	return string.byte(bytes, 1) + string.byte(bytes, 2) * 256
end

local function call(request, decoder)
	local response, err = sys.svc.call(connection(), request)
	if response == nil then
		error("syntax: transport error: " .. tostring(err), 3)
	end
	if message_id(response) == wire.ERROR_RESPONSE_MSG_ID then
		local failure = wire.decode_ErrorResponse(response)
		local suffix = failure.current_revision
				and (" (current revision " .. failure.current_revision .. ")")
			or ""
		error("syntax: " .. failure.code .. ": " .. failure.message .. suffix, 3)
	end
	return decoder(response)
end

local function range(value)
	if value == nil then
		return nil
	end
	return {
		start_byte = assert(value.start_byte, "range.start_byte is required"),
		end_byte = assert(value.end_byte, "range.end_byte is required"),
		start_point = value.start_point or { row = 0, column = 0 },
		end_point = value.end_point or { row = 0, column = 0 },
	}
end

local Document = {}
Document.__index = Document
local Query = {}
Query.__index = Query

function syntax.languages()
	return call(wire.encode_LanguagesRequest({ reserved = 0 }), wire.decode_LanguagesResponse).languages
end

function syntax.open(language, source, options)
	if type(language) ~= "string" or type(source) ~= "string" then
		error("syntax.open expects language and source strings", 2)
	end
	local response = call(
		wire.encode_OpenRequest({ language = language, source = source }),
		wire.decode_OpenResponse
	)
	return setmetatable({
		handle = response.document,
		revision = response.revision,
		language = language,
		root_node = response.root,
		initial_diagnostics = response.diagnostics,
		closed = false,
		options = options or {},
	}, Document)
end

function syntax.compile_query(language, source, options)
	options = options or {}
	local response = call(
		wire.encode_QueryCompileRequest({
			language = language,
			source = source,
			view = options.view or "concrete",
		}),
		wire.decode_QueryCompileResponse
	)
	return setmetatable({
		handle = response.query,
		language = language,
		closed = false,
		diagnostics = response.diagnostics,
	}, Query)
end

function Query:close()
	if self.closed then
		return
	end
	call(wire.encode_QueryCloseRequest({ query = self.handle }), wire.decode_QueryCloseResponse)
	self.closed = true
end

local function live(doc)
	if doc.closed then
		error("syntax: document is closed", 3)
	end
end

function Document:root()
	live(self)
	return self.root_node
end

function Document:node(handle, options)
	live(self)
	options = options or {}
	return call(
		wire.encode_NodeRequest({
			document = self.handle,
			revision = self.revision,
			node = handle,
			view = options.view or "concrete",
		}),
		wire.decode_NodeResponse
	).node
end

local function paged(fetch)
	local page, index, finished = {}, 1, false
	return function()
		while index > #page do
			if finished then
				return nil
			end
			page, finished = fetch()
			index = 1
		end
		local value = page[index]
		index += 1
		return value
	end
end

function Document:tree(options)
	live(self)
	options = options or {}
	local cursor = nil
	return paged(function()
		local response = call(
			wire.encode_TreeRequest({
				document = self.handle,
				revision = self.revision,
				view = options.view or "concrete",
				max_depth = options.max_depth or 256,
				limit = options.page_size or 256,
				cursor = cursor,
			}),
			wire.decode_TreeResponse
		)
		cursor = response.cursor
		return response.nodes, cursor == nil
	end)
end

function Document:children(node, options)
	live(self)
	options = options or {}
	local cursor = nil
	local handle = type(node) == "table" and node.handle or node
	return paged(function()
		local response = call(
			wire.encode_ChildrenRequest({
				document = self.handle,
				revision = self.revision,
				node = handle,
				view = options.view or "concrete",
				named_only = options.named_only == true,
				limit = options.page_size or 256,
				cursor = cursor,
			}),
			wire.decode_ChildrenResponse
		)
		cursor = response.cursor
		return response.nodes, cursor == nil
	end)
end

function Document:captures(query, options)
	live(self)
	options = options or {}
	if query.closed then
		error("syntax: query is closed", 2)
	end
	if query.language ~= self.language then
		error("syntax: query and document languages differ", 2)
	end
	local cursor = nil
	return paged(function()
		local response = call(
			wire.encode_QueryRequest({
				document = self.handle,
				revision = self.revision,
				query = query.handle,
				range = range(options.range),
				include_text = options.include_text == true,
				limit = options.page_size or 128,
				cursor = cursor,
			}),
			wire.decode_QueryResponse
		)
		cursor = response.cursor
		return response.captures, cursor == nil
	end)
end

function Document:text(selected)
	live(self)
	return call(
		wire.encode_TextRequest({
			document = self.handle,
			revision = self.revision,
			range = range(selected),
		}),
		wire.decode_TextResponse
	).text
end

function Document:diagnostics()
	live(self)
	return call(
		wire.encode_DiagnosticsRequest({ document = self.handle, revision = self.revision }),
		wire.decode_DiagnosticsResponse
	).diagnostics
end

function Document:edit(edits)
	live(self)
	local response = call(
		wire.encode_EditRequest({ document = self.handle, revision = self.revision, edits = edits }),
		wire.decode_EditResponse
	)
	self.revision = response.revision
	self.root_node = self:tree({ page_size = 1 })()
	return response
end

function Document:rewrite(plan)
	live(self)
	if plan.revision ~= nil and plan.revision ~= self.revision then
		error("syntax: local rewrite revision is stale", 2)
	end
	local response = call(
		wire.encode_RewriteRequest({
			document = self.handle,
			revision = self.revision,
			validation = plan.validation or "no_new_errors",
			edits = assert(plan.edits, "rewrite edits are required"),
		}),
		wire.decode_RewriteResponse
	)
	self.revision = response.revision
	self.root_node = self:tree({ page_size = 1 })()
	return response
end

function Document:close()
	if self.closed then
		return
	end
	call(wire.encode_CloseRequest({ document = self.handle }), wire.decode_CloseResponse)
	self.closed = true
end

return syntax
