-- @generated from contracts/browser.kdl by //contracts/codegen:projector — do not edit.
local M = {}
M.PROTOCOL_VERSION = 1
M.BROWSER_KIND = "browser"
M.BROWSER_CONTRACT_DIGEST = "sha256:467c154dc423f6db81ceabce046c3044e2ca7dd780b4fbb3eb3e26fa29f83fca"
M.BROWSER_RUNNER_PROFILE = "browser"
M.BROWSER_VERSION = 1
M.BROWSER_DEFAULT_TIMEOUT_SECONDS = 300
M.BROWSER_MIN_TIMEOUT_SECONDS = 10
M.BROWSER_MAX_TIMEOUT_SECONDS = 300
M.BROWSER_DEFAULT_VIEWPORT_WIDTH = 1280
M.BROWSER_DEFAULT_VIEWPORT_HEIGHT = 720
M.BROWSER_MIN_VIEWPORT_EDGE = 320
M.BROWSER_MAX_VIEWPORT_EDGE = 4096
M.BROWSER_MAX_URL_BYTES = 16384
M.BROWSER_MAX_PAGE_ID_BYTES = 96
M.BROWSER_MAX_SELECTOR_BYTES = 4096
M.BROWSER_MAX_TEXT_BYTES = 1048576
M.BROWSER_MAX_TYPE_DELAY_MS = 1000
M.BROWSER_MAX_PAGES = 32
M.BROWSER_MAX_SCREENSHOT_EDGE = 16384
M.BROWSER_MAX_SCREENSHOT_PIXELS = 16777216
M.BROWSER_WAIT_LOAD = 1
M.BROWSER_WAIT_DOM_CONTENT_LOADED = 2
M.BROWSER_WAIT_NETWORK_IDLE = 3
M.BROWSER_WAIT_COMMIT = 4
M.BROWSER_OP_PAGES_LIST = "pages.list"
M.BROWSER_OP_PAGES_GOTO = "pages.goto"
M.BROWSER_OP_PAGES_TITLE = "pages.title"
M.BROWSER_OP_PAGES_TEXT = "pages.text"
M.BROWSER_OP_PAGES_CLICK = "pages.click"
M.BROWSER_OP_PAGES_FILL = "pages.fill"
M.BROWSER_OP_COMPUTER_SCREENSHOT = "computer.screenshot"
M.BROWSER_OP_COMPUTER_CLICK = "computer.click"
M.BROWSER_OP_COMPUTER_TYPE = "computer.type"
M.BROWSER_OP_COMPUTER_KEY = "computer.key"
M.BROWSER_OP_COMPUTER_SCROLL = "computer.scroll"


local function byte(bytes, at)
  local v = string.byte(bytes, at)
  if v == nil then error("syntax wire: truncated frame", 3) end
  return v
end
local function put_u8(v) return string.char(v % 256) end
local function put_u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function put_u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function put_i32(v) if v < 0 then v = v + 4294967296 end return put_u32(v) end
local function put_i64(v)
  local lo = v % 4294967296
  local hi = math.floor(v / 4294967296)
  if hi < 0 then hi = hi + 4294967296 end
  return put_u32(lo) .. put_u32(hi)
end
local function put_bool(v) return put_u8(v and 1 or 0) end
local function put_bytes(v) return put_u32(#v) .. v end
local function put_strmap(values)
  local keys = {}
  for k in values do table.insert(keys, k) end
  table.sort(keys)
  local out = { put_u32(#keys) }
  for _, k in keys do table.insert(out, put_bytes(k)); table.insert(out, put_bytes(values[k])) end
  return table.concat(out)
end
local function put_list(values, encoder)
  local out = { put_u32(#values) }
  for _, value in values do table.insert(out, put_bytes(encoder(value))) end
  return table.concat(out)
end
local function need(bytes, off, n)
  if off + n - 1 > #bytes then error("syntax wire: truncated frame", 3) end
  return string.sub(bytes, off, off + n - 1), off + n
end
local function read_u8(bytes, off) return byte(bytes, off), off + 1 end
local function read_u16(bytes, off)
  return byte(bytes, off) + byte(bytes, off + 1) * 256, off + 2
end
local function read_u32(bytes, off)
  return byte(bytes, off) + byte(bytes, off + 1) * 256 + byte(bytes, off + 2) * 65536 + byte(bytes, off + 3) * 16777216, off + 4
end
local function read_i32(bytes, off)
  local v; v, off = read_u32(bytes, off)
  if v >= 2147483648 then v = v - 4294967296 end
  return v, off
end
local function read_i64(bytes, off)
  local lo, hi; lo, off = read_u32(bytes, off); hi, off = read_u32(bytes, off)
  local v = lo + hi * 4294967296
  if hi >= 2147483648 then v = v - 18446744073709551616 end
  return v, off
end
local function read_bool(bytes, off)
  local v; v, off = read_u8(bytes, off)
  if v ~= 0 and v ~= 1 then error("syntax wire: invalid bool", 3) end
  return v == 1, off
end
local function read_bytes(bytes, off)
  local n; n, off = read_u32(bytes, off)
  return need(bytes, off, n)
end
local function read_strmap(bytes, off)
  local n; n, off = read_u32(bytes, off)
  local out, prev = {}, nil
  for _ = 1, n do
    local k, v; k, off = read_bytes(bytes, off); v, off = read_bytes(bytes, off)
    if prev ~= nil and prev >= k then error("syntax wire: non-canonical map", 3) end
    out[k], prev = v, k
  end
  return out, off
end
local function read_message(bytes, off, decoder)
  local frame; frame, off = read_bytes(bytes, off)
  return decoder(frame), off
end
local function read_list(bytes, off, decoder)
  local n; n, off = read_u32(bytes, off)
  local out = {}
  for i = 1, n do out[i], off = read_message(bytes, off, decoder) end
  return out, off
end
local function header(bytes, expected)
  local id, off = read_u16(bytes, 1)
  local version
  version, off = read_u8(bytes, off)
  if id ~= expected then error("syntax wire: wrong message", 3) end
  if version ~= 1 then error("syntax wire: unsupported version", 3) end
  return off
end
local function finish(bytes, off)
  if off ~= #bytes + 1 then error("syntax wire: trailing bytes", 3) end
end

M.BROWSER_VIEWPORT_MSG_ID = 1
M.BROWSER_VIEWPORT_VERSION = 1
function M.encode_BrowserViewport(msg)
  local out = { put_u16(M.BROWSER_VIEWPORT_MSG_ID), put_u8(M.BROWSER_VIEWPORT_VERSION), put_u32(msg.width), put_u32(msg.height) }
  return table.concat(out)
end
function M.decode_BrowserViewport(bytes)
  local off = header(bytes, M.BROWSER_VIEWPORT_MSG_ID)
  local out = {}
  out.width, off = read_u32(bytes, off)
  out.height, off = read_u32(bytes, off)
  finish(bytes, off)
  return out
end

M.BROWSER_CREATE_OPTIONS_MSG_ID = 2
M.BROWSER_CREATE_OPTIONS_VERSION = 1
function M.encode_BrowserCreateOptions(msg)
  local out = { put_u16(M.BROWSER_CREATE_OPTIONS_MSG_ID), put_u8(M.BROWSER_CREATE_OPTIONS_VERSION), put_bool(msg.headless), put_u32(msg.timeout_seconds), msg.viewport == nil and put_u8(0) or (put_u8(1) .. put_bytes(M.encode_BrowserViewport(msg.viewport))) }
  return table.concat(out)
end
function M.decode_BrowserCreateOptions(bytes)
  local off = header(bytes, M.BROWSER_CREATE_OPTIONS_MSG_ID)
  local out = {}
  out.headless, off = read_bool(bytes, off)
  out.timeout_seconds, off = read_u32(bytes, off)
  local has_viewport; has_viewport, off = read_u8(bytes, off)
  if has_viewport == 1 then out.viewport, off = read_message(bytes, off, M.decode_BrowserViewport) elseif has_viewport ~= 0 then error("syntax wire: invalid optional", 2) end
  finish(bytes, off)
  return out
end

M.BROWSER_METADATA_MSG_ID = 3
M.BROWSER_METADATA_VERSION = 1
function M.encode_BrowserMetadata(msg)
  local out = { put_u16(M.BROWSER_METADATA_MSG_ID), put_u8(M.BROWSER_METADATA_VERSION), put_bool(msg.headless), put_bytes(M.encode_BrowserViewport(msg.viewport)), put_bytes(msg.active_page_id) }
  return table.concat(out)
end
function M.decode_BrowserMetadata(bytes)
  local off = header(bytes, M.BROWSER_METADATA_MSG_ID)
  local out = {}
  out.headless, off = read_bool(bytes, off)
  out.viewport, off = read_message(bytes, off, M.decode_BrowserViewport)
  out.active_page_id, off = read_bytes(bytes, off)
  finish(bytes, off)
  return out
end

M.BROWSER_PAGE_MSG_ID = 4
M.BROWSER_PAGE_VERSION = 1
function M.encode_BrowserPage(msg)
  local out = { put_u16(M.BROWSER_PAGE_MSG_ID), put_u8(M.BROWSER_PAGE_VERSION), put_bytes(msg.id), put_bytes(msg.url), put_bytes(msg.title) }
  return table.concat(out)
end
function M.decode_BrowserPage(bytes)
  local off = header(bytes, M.BROWSER_PAGE_MSG_ID)
  local out = {}
  out.id, off = read_bytes(bytes, off)
  out.url, off = read_bytes(bytes, off)
  out.title, off = read_bytes(bytes, off)
  finish(bytes, off)
  return out
end

M.BROWSER_PAGES_MSG_ID = 5
M.BROWSER_PAGES_VERSION = 1
function M.encode_BrowserPages(msg)
  local out = { put_u16(M.BROWSER_PAGES_MSG_ID), put_u8(M.BROWSER_PAGES_VERSION), put_list(msg.items, M.encode_BrowserPage) }
  return table.concat(out)
end
function M.decode_BrowserPages(bytes)
  local off = header(bytes, M.BROWSER_PAGES_MSG_ID)
  local out = {}
  out.items, off = read_list(bytes, off, M.decode_BrowserPage)
  finish(bytes, off)
  return out
end

M.BROWSER_PAGE_TARGET_MSG_ID = 6
M.BROWSER_PAGE_TARGET_VERSION = 1
function M.encode_BrowserPageTarget(msg)
  local out = { put_u16(M.BROWSER_PAGE_TARGET_MSG_ID), put_u8(M.BROWSER_PAGE_TARGET_VERSION), msg.page_id == nil and put_u8(0) or (put_u8(1) .. put_bytes(msg.page_id)) }
  return table.concat(out)
end
function M.decode_BrowserPageTarget(bytes)
  local off = header(bytes, M.BROWSER_PAGE_TARGET_MSG_ID)
  local out = {}
  local has_page_id; has_page_id, off = read_u8(bytes, off)
  if has_page_id == 1 then out.page_id, off = read_bytes(bytes, off) elseif has_page_id ~= 0 then error("syntax wire: invalid optional", 2) end
  finish(bytes, off)
  return out
end

M.BROWSER_GOTO_REQUEST_MSG_ID = 7
M.BROWSER_GOTO_REQUEST_VERSION = 1
function M.encode_BrowserGotoRequest(msg)
  local out = { put_u16(M.BROWSER_GOTO_REQUEST_MSG_ID), put_u8(M.BROWSER_GOTO_REQUEST_VERSION), msg.page_id == nil and put_u8(0) or (put_u8(1) .. put_bytes(msg.page_id)), put_bytes(msg.url), put_u32(msg.wait_until) }
  return table.concat(out)
end
function M.decode_BrowserGotoRequest(bytes)
  local off = header(bytes, M.BROWSER_GOTO_REQUEST_MSG_ID)
  local out = {}
  local has_page_id; has_page_id, off = read_u8(bytes, off)
  if has_page_id == 1 then out.page_id, off = read_bytes(bytes, off) elseif has_page_id ~= 0 then error("syntax wire: invalid optional", 2) end
  out.url, off = read_bytes(bytes, off)
  out.wait_until, off = read_u32(bytes, off)
  finish(bytes, off)
  return out
end

M.BROWSER_LOCATOR_REQUEST_MSG_ID = 8
M.BROWSER_LOCATOR_REQUEST_VERSION = 1
function M.encode_BrowserLocatorRequest(msg)
  local out = { put_u16(M.BROWSER_LOCATOR_REQUEST_MSG_ID), put_u8(M.BROWSER_LOCATOR_REQUEST_VERSION), msg.page_id == nil and put_u8(0) or (put_u8(1) .. put_bytes(msg.page_id)), put_bytes(msg.selector) }
  return table.concat(out)
end
function M.decode_BrowserLocatorRequest(bytes)
  local off = header(bytes, M.BROWSER_LOCATOR_REQUEST_MSG_ID)
  local out = {}
  local has_page_id; has_page_id, off = read_u8(bytes, off)
  if has_page_id == 1 then out.page_id, off = read_bytes(bytes, off) elseif has_page_id ~= 0 then error("syntax wire: invalid optional", 2) end
  out.selector, off = read_bytes(bytes, off)
  finish(bytes, off)
  return out
end

M.BROWSER_FILL_REQUEST_MSG_ID = 9
M.BROWSER_FILL_REQUEST_VERSION = 1
function M.encode_BrowserFillRequest(msg)
  local out = { put_u16(M.BROWSER_FILL_REQUEST_MSG_ID), put_u8(M.BROWSER_FILL_REQUEST_VERSION), msg.page_id == nil and put_u8(0) or (put_u8(1) .. put_bytes(msg.page_id)), put_bytes(msg.selector), put_bytes(msg.value) }
  return table.concat(out)
end
function M.decode_BrowserFillRequest(bytes)
  local off = header(bytes, M.BROWSER_FILL_REQUEST_MSG_ID)
  local out = {}
  local has_page_id; has_page_id, off = read_u8(bytes, off)
  if has_page_id == 1 then out.page_id, off = read_bytes(bytes, off) elseif has_page_id ~= 0 then error("syntax wire: invalid optional", 2) end
  out.selector, off = read_bytes(bytes, off)
  out.value, off = read_bytes(bytes, off)
  finish(bytes, off)
  return out
end

M.BROWSER_POINT_REQUEST_MSG_ID = 10
M.BROWSER_POINT_REQUEST_VERSION = 1
function M.encode_BrowserPointRequest(msg)
  local out = { put_u16(M.BROWSER_POINT_REQUEST_MSG_ID), put_u8(M.BROWSER_POINT_REQUEST_VERSION), msg.page_id == nil and put_u8(0) or (put_u8(1) .. put_bytes(msg.page_id)), put_u32(msg.x), put_u32(msg.y) }
  return table.concat(out)
end
function M.decode_BrowserPointRequest(bytes)
  local off = header(bytes, M.BROWSER_POINT_REQUEST_MSG_ID)
  local out = {}
  local has_page_id; has_page_id, off = read_u8(bytes, off)
  if has_page_id == 1 then out.page_id, off = read_bytes(bytes, off) elseif has_page_id ~= 0 then error("syntax wire: invalid optional", 2) end
  out.x, off = read_u32(bytes, off)
  out.y, off = read_u32(bytes, off)
  finish(bytes, off)
  return out
end

M.BROWSER_TYPE_REQUEST_MSG_ID = 11
M.BROWSER_TYPE_REQUEST_VERSION = 1
function M.encode_BrowserTypeRequest(msg)
  local out = { put_u16(M.BROWSER_TYPE_REQUEST_MSG_ID), put_u8(M.BROWSER_TYPE_REQUEST_VERSION), msg.page_id == nil and put_u8(0) or (put_u8(1) .. put_bytes(msg.page_id)), put_bytes(msg.text), put_u32(msg.delay_ms) }
  return table.concat(out)
end
function M.decode_BrowserTypeRequest(bytes)
  local off = header(bytes, M.BROWSER_TYPE_REQUEST_MSG_ID)
  local out = {}
  local has_page_id; has_page_id, off = read_u8(bytes, off)
  if has_page_id == 1 then out.page_id, off = read_bytes(bytes, off) elseif has_page_id ~= 0 then error("syntax wire: invalid optional", 2) end
  out.text, off = read_bytes(bytes, off)
  out.delay_ms, off = read_u32(bytes, off)
  finish(bytes, off)
  return out
end

M.BROWSER_KEY_REQUEST_MSG_ID = 12
M.BROWSER_KEY_REQUEST_VERSION = 1
function M.encode_BrowserKeyRequest(msg)
  local out = { put_u16(M.BROWSER_KEY_REQUEST_MSG_ID), put_u8(M.BROWSER_KEY_REQUEST_VERSION), msg.page_id == nil and put_u8(0) or (put_u8(1) .. put_bytes(msg.page_id)), put_bytes(msg.key) }
  return table.concat(out)
end
function M.decode_BrowserKeyRequest(bytes)
  local off = header(bytes, M.BROWSER_KEY_REQUEST_MSG_ID)
  local out = {}
  local has_page_id; has_page_id, off = read_u8(bytes, off)
  if has_page_id == 1 then out.page_id, off = read_bytes(bytes, off) elseif has_page_id ~= 0 then error("syntax wire: invalid optional", 2) end
  out.key, off = read_bytes(bytes, off)
  finish(bytes, off)
  return out
end

M.BROWSER_SCROLL_REQUEST_MSG_ID = 13
M.BROWSER_SCROLL_REQUEST_VERSION = 1
function M.encode_BrowserScrollRequest(msg)
  local out = { put_u16(M.BROWSER_SCROLL_REQUEST_MSG_ID), put_u8(M.BROWSER_SCROLL_REQUEST_VERSION), msg.page_id == nil and put_u8(0) or (put_u8(1) .. put_bytes(msg.page_id)), put_i32(msg.delta_x), put_i32(msg.delta_y) }
  return table.concat(out)
end
function M.decode_BrowserScrollRequest(bytes)
  local off = header(bytes, M.BROWSER_SCROLL_REQUEST_MSG_ID)
  local out = {}
  local has_page_id; has_page_id, off = read_u8(bytes, off)
  if has_page_id == 1 then out.page_id, off = read_bytes(bytes, off) elseif has_page_id ~= 0 then error("syntax wire: invalid optional", 2) end
  out.delta_x, off = read_i32(bytes, off)
  out.delta_y, off = read_i32(bytes, off)
  finish(bytes, off)
  return out
end

M.BROWSER_SCREENSHOT_REQUEST_MSG_ID = 14
M.BROWSER_SCREENSHOT_REQUEST_VERSION = 1
function M.encode_BrowserScreenshotRequest(msg)
  local out = { put_u16(M.BROWSER_SCREENSHOT_REQUEST_MSG_ID), put_u8(M.BROWSER_SCREENSHOT_REQUEST_VERSION), msg.page_id == nil and put_u8(0) or (put_u8(1) .. put_bytes(msg.page_id)), put_bool(msg.full_page) }
  return table.concat(out)
end
function M.decode_BrowserScreenshotRequest(bytes)
  local off = header(bytes, M.BROWSER_SCREENSHOT_REQUEST_MSG_ID)
  local out = {}
  local has_page_id; has_page_id, off = read_u8(bytes, off)
  if has_page_id == 1 then out.page_id, off = read_bytes(bytes, off) elseif has_page_id ~= 0 then error("syntax wire: invalid optional", 2) end
  out.full_page, off = read_bool(bytes, off)
  finish(bytes, off)
  return out
end

M.BROWSER_STRING_MSG_ID = 15
M.BROWSER_STRING_VERSION = 1
function M.encode_BrowserString(msg)
  local out = { put_u16(M.BROWSER_STRING_MSG_ID), put_u8(M.BROWSER_STRING_VERSION), put_bytes(msg.value) }
  return table.concat(out)
end
function M.decode_BrowserString(bytes)
  local off = header(bytes, M.BROWSER_STRING_MSG_ID)
  local out = {}
  out.value, off = read_bytes(bytes, off)
  finish(bytes, off)
  return out
end

M.BROWSER_BYTES_MSG_ID = 16
M.BROWSER_BYTES_VERSION = 1
function M.encode_BrowserBytes(msg)
  local out = { put_u16(M.BROWSER_BYTES_MSG_ID), put_u8(M.BROWSER_BYTES_VERSION), put_bytes(msg.value) }
  return table.concat(out)
end
function M.decode_BrowserBytes(bytes)
  local off = header(bytes, M.BROWSER_BYTES_MSG_ID)
  local out = {}
  out.value, off = read_bytes(bytes, off)
  finish(bytes, off)
  return out
end

return M
