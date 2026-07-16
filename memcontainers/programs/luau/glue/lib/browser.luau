local sys = require("sys")
local sidecar = require("_sidecar_wire")
local wire = require("_browser_wire")

local sequence = 0

local function tableValue(name, value)
	if type(value) ~= "table" then
		error(name .. " must be a table", 3)
	end
	return value
end

local function boundedString(name, value, maximum, allowEmpty)
	if type(value) ~= "string" then
		error(name .. " must be a string", 3)
	end
	if (not allowEmpty and value == "") or #value > maximum then
		error(name .. " is empty or too large", 3)
	end
	return value
end

local function integer(name, value, minimum, maximum)
	if type(value) ~= "number" or value % 1 ~= 0 or value < minimum or value > maximum then
		error(name .. " is outside the supported range", 3)
	end
	return value
end

local function optionalBoolean(name, value, fallback)
	if value == nil then
		return fallback
	end
	if type(value) ~= "boolean" then
		error(name .. " must be a boolean", 3)
	end
	return value
end

local function request(bytes)
	local response, err = sys.host.call(sidecar.SIDECAR_HOST_BINDING, bytes)
	if response == nil then
		error("browser: " .. tostring(err), 3)
	end
	local result = sidecar.decode_SidecarResult(response)
	if not result.ok then
		local detail = result.error
		error("browser: " .. (detail and detail.message or "sidecar request failed"), 3)
	end
	return result.body
end

local function list(grant)
	local body = request(sidecar.encode_SidecarList({ grant = grant, kind = wire.BROWSER_KIND }))
	return sidecar.decode_SidecarInstances(body).items
end

local function resolve(grant, id)
	boundedString("browser id", id, sidecar.SIDECAR_MAX_NAME_BYTES, false)
	for _, instance in list(grant) do
		if instance.id == id then
			return instance
		end
	end
	error("browser: instance not found: " .. id, 3)
end

local function invoke(grant, id, operation, body)
	local instance = resolve(grant, id)
	return request(sidecar.encode_SidecarCall({
		id = instance.id,
		generation = instance.generation,
		grant = grant,
		kind = wire.BROWSER_KIND,
		operation = operation,
		body = body,
		timeout_ms = sidecar.SIDECAR_MAX_OPERATION_TIMEOUT_MS,
	}))
end

local waits = {
	load = wire.BROWSER_WAIT_LOAD,
	domcontentloaded = wire.BROWSER_WAIT_DOM_CONTENT_LOADED,
	networkidle = wire.BROWSER_WAIT_NETWORK_IDLE,
	commit = wire.BROWSER_WAIT_COMMIT,
}

local function pageId(options)
	if options == nil then
		return nil
	end
	tableValue("browser options", options)
	if options.pageId == nil then
		return nil
	end
	return boundedString("browser page id", options.pageId, wire.BROWSER_MAX_PAGE_ID_BYTES, false)
end

local function instanceValue(instance)
	local metadata = wire.decode_BrowserMetadata(instance.metadata)
	if metadata.headless ~= true then
		error("browser: host returned invalid metadata", 3)
	end
	tableValue("browser viewport", metadata.viewport)
	integer(
		"browser viewport.width",
		metadata.viewport.width,
		wire.BROWSER_MIN_VIEWPORT_EDGE,
		wire.BROWSER_MAX_VIEWPORT_EDGE
	)
	integer(
		"browser viewport.height",
		metadata.viewport.height,
		wire.BROWSER_MIN_VIEWPORT_EDGE,
		wire.BROWSER_MAX_VIEWPORT_EDGE
	)
	boundedString(
		"browser active page id",
		metadata.active_page_id,
		wire.BROWSER_MAX_PAGE_ID_BYTES,
		false
	)
	return {
		id = instance.id,
		grant = instance.grant,
		state = instance.state,
		generation = instance.generation,
		headless = metadata.headless,
		viewport = metadata.viewport,
		activePageId = metadata.active_page_id,
	}
end

local function pageValue(page)
	boundedString("browser page id", page.id, wire.BROWSER_MAX_PAGE_ID_BYTES, false)
	boundedString("browser page url", page.url, wire.BROWSER_MAX_URL_BYTES, true)
	boundedString("browser page title", page.title, wire.BROWSER_MAX_TEXT_BYTES, true)
	return page
end

local function use(grant)
	boundedString("browser.use grant", grant, sidecar.SIDECAR_MAX_NAME_BYTES, false)
	local api = {}

	function api.create(options)
		options = options or {}
		tableValue("browser.create options", options)
		if options.headless ~= nil and type(options.headless) ~= "boolean" then
			error("browser.create headless must be a boolean", 2)
		end
		if options.headless == false then
			error("browser v1 supports headless sessions only", 2)
		end
		sequence += 1
		local monotonic, clockErr = sys.time.mono()
		if monotonic == nil then
			error("browser: " .. tostring(clockErr), 2)
		end
		local viewport = options.viewport
			or {
				width = wire.BROWSER_DEFAULT_VIEWPORT_WIDTH,
				height = wire.BROWSER_DEFAULT_VIEWPORT_HEIGHT,
			}
		tableValue("browser.create viewport", viewport)
		integer(
			"browser.create viewport.width",
			viewport.width,
			wire.BROWSER_MIN_VIEWPORT_EDGE,
			wire.BROWSER_MAX_VIEWPORT_EDGE
		)
		integer(
			"browser.create viewport.height",
			viewport.height,
			wire.BROWSER_MIN_VIEWPORT_EDGE,
			wire.BROWSER_MAX_VIEWPORT_EDGE
		)
		local timeoutSeconds = options.timeoutSeconds or wire.BROWSER_DEFAULT_TIMEOUT_SECONDS
		integer(
			"browser.create timeoutSeconds",
			timeoutSeconds,
			wire.BROWSER_MIN_TIMEOUT_SECONDS,
			wire.BROWSER_MAX_TIMEOUT_SECONDS
		)
		local encoded = request(sidecar.encode_SidecarCreate({
			grant = grant,
			kind = wire.BROWSER_KIND,
			body = wire.encode_BrowserCreateOptions({
				headless = true,
				timeout_seconds = timeoutSeconds,
				viewport = viewport,
			}),
			idempotency_key = "luau-" .. tostring(monotonic) .. "-" .. tostring(sequence),
			timeout_ms = sidecar.SIDECAR_MAX_OPERATION_TIMEOUT_MS,
		}))
		return instanceValue(sidecar.decode_SidecarInstance(encoded))
	end

	function api.retrieve(id)
		return instanceValue(resolve(grant, id))
	end

	function api.list()
		local out = {}
		for _, instance in list(grant) do
			table.insert(out, instanceValue(instance))
		end
		return out
	end

	function api.delete(id)
		local instance = resolve(grant, id)
		request(sidecar.encode_SidecarDelete({
			id = instance.id,
			generation = instance.generation,
			grant = grant,
			kind = wire.BROWSER_KIND,
		}))
	end

	api.pages = {}
	function api.pages.list(id)
		local pages =
			wire.decode_BrowserPages(invoke(grant, id, wire.BROWSER_OP_PAGES_LIST, "")).items
		for index, page in pages do
			pages[index] = pageValue(page)
		end
		return pages
	end
	function api.pages.goto(id, options)
		tableValue("browser.pages.goto options", options)
		local wait = waits[options.waitUntil or "load"]
		if wait == nil then
			error("browser.pages.goto: invalid waitUntil", 2)
		end
		return pageValue(
			wire.decode_BrowserPage(
				invoke(
					grant,
					id,
					wire.BROWSER_OP_PAGES_GOTO,
					wire.encode_BrowserGotoRequest({
						page_id = pageId(options),
						url = boundedString(
							"browser.pages.goto url",
							options.url,
							wire.BROWSER_MAX_URL_BYTES,
							false
						),
						wait_until = wait,
					})
				)
			)
		)
	end
	function api.pages.title(id, options)
		local value = wire.decode_BrowserString(
			invoke(
				grant,
				id,
				wire.BROWSER_OP_PAGES_TITLE,
				wire.encode_BrowserPageTarget({ page_id = pageId(options) })
			)
		).value
		return boundedString("browser page title", value, wire.BROWSER_MAX_TEXT_BYTES, true)
	end
	function api.pages.text(id, options)
		tableValue("browser.pages.text options", options)
		local value = wire.decode_BrowserString(
			invoke(
				grant,
				id,
				wire.BROWSER_OP_PAGES_TEXT,
				wire.encode_BrowserLocatorRequest({
					page_id = pageId(options),
					selector = boundedString(
						"browser.pages.text selector",
						options.selector,
						wire.BROWSER_MAX_SELECTOR_BYTES,
						false
					),
				})
			)
		).value
		return boundedString("browser page text", value, wire.BROWSER_MAX_TEXT_BYTES, true)
	end
	function api.pages.click(id, options)
		tableValue("browser.pages.click options", options)
		invoke(
			grant,
			id,
			wire.BROWSER_OP_PAGES_CLICK,
			wire.encode_BrowserLocatorRequest({
				page_id = pageId(options),
				selector = boundedString(
					"browser.pages.click selector",
					options.selector,
					wire.BROWSER_MAX_SELECTOR_BYTES,
					false
				),
			})
		)
	end
	function api.pages.fill(id, options)
		tableValue("browser.pages.fill options", options)
		invoke(
			grant,
			id,
			wire.BROWSER_OP_PAGES_FILL,
			wire.encode_BrowserFillRequest({
				page_id = pageId(options),
				selector = boundedString(
					"browser.pages.fill selector",
					options.selector,
					wire.BROWSER_MAX_SELECTOR_BYTES,
					false
				),
				value = boundedString(
					"browser.pages.fill value",
					options.value,
					wire.BROWSER_MAX_TEXT_BYTES,
					true
				),
			})
		)
	end

	api.computer = {}
	function api.computer.screenshot(id, options)
		options = options or {}
		return wire.decode_BrowserBytes(
			invoke(
				grant,
				id,
				wire.BROWSER_OP_COMPUTER_SCREENSHOT,
				wire.encode_BrowserScreenshotRequest({
					page_id = pageId(options),
					full_page = optionalBoolean(
						"browser.computer.screenshot fullPage",
						options.fullPage,
						false
					),
				})
			)
		).value
	end
	function api.computer.click(id, options)
		tableValue("browser.computer.click options", options)
		invoke(
			grant,
			id,
			wire.BROWSER_OP_COMPUTER_CLICK,
			wire.encode_BrowserPointRequest({
				page_id = pageId(options),
				x = integer(
					"browser.computer.click x",
					options.x,
					0,
					wire.BROWSER_MAX_VIEWPORT_EDGE - 1
				),
				y = integer(
					"browser.computer.click y",
					options.y,
					0,
					wire.BROWSER_MAX_VIEWPORT_EDGE - 1
				),
			})
		)
	end
	function api.computer.type(id, options)
		tableValue("browser.computer.type options", options)
		local delayMs = options.delayMs or 0
		integer("browser.computer.type delayMs", delayMs, 0, wire.BROWSER_MAX_TYPE_DELAY_MS)
		invoke(
			grant,
			id,
			wire.BROWSER_OP_COMPUTER_TYPE,
			wire.encode_BrowserTypeRequest({
				page_id = pageId(options),
				text = boundedString(
					"browser.computer.type text",
					options.text,
					wire.BROWSER_MAX_TEXT_BYTES,
					true
				),
				delay_ms = delayMs,
			})
		)
	end
	function api.computer.key(id, options)
		tableValue("browser.computer.key options", options)
		invoke(
			grant,
			id,
			wire.BROWSER_OP_COMPUTER_KEY,
			wire.encode_BrowserKeyRequest({
				page_id = pageId(options),
				key = boundedString(
					"browser.computer.key key",
					options.key,
					wire.BROWSER_MAX_SELECTOR_BYTES,
					false
				),
			})
		)
	end
	function api.computer.scroll(id, options)
		tableValue("browser.computer.scroll options", options)
		invoke(
			grant,
			id,
			wire.BROWSER_OP_COMPUTER_SCROLL,
			wire.encode_BrowserScrollRequest({
				page_id = pageId(options),
				delta_x = integer(
					"browser.computer.scroll deltaX",
					options.deltaX or 0,
					-2147483648,
					2147483647
				),
				delta_y = integer(
					"browser.computer.scroll deltaY",
					options.deltaY or 0,
					-2147483648,
					2147483647
				),
			})
		)
	end

	return api
end

return { use = use }
