-- media.luau — image embedding helpers shared by the office formats (the
-- MediaRegistry of luau-extensions Ch.05). Three concerns: identify an
-- image's content type from its magic bytes, probe its intrinsic pixel size
-- (so the format APIs can auto-size), and a content-addressed registry that
-- dedups identical bytes to ONE media part (docx/xlsx/pptx all hash media).
--
--   media.identify(bytes)   -> ext, contentType
--   media.dimensions(bytes) -> widthPx, heightPx | nil
--   media.registry()        -> { items, add(bytes) -> { index, ext, contentType,
--                                  name, bytes, widthPx, heightPx } }

local hash = require("hash")

local media = {}

-- 96 dpi: the OOXML convention for px → EMU (914400 EMU/inch ÷ 96).
media.EMU_PER_PX = 9525

local function be32(s, pos)
	return string.byte(s, pos) * 0x1000000
		+ string.byte(s, pos + 1) * 0x10000
		+ string.byte(s, pos + 2) * 0x100
		+ string.byte(s, pos + 3)
end

-- identify(bytes) → ext, contentType. Falls back to opaque octet-stream.
function media.identify(bytes)
	if bytes:sub(1, 8) == "\137PNG\r\n\26\n" then
		return "png", "image/png"
	elseif bytes:byte(1) == 0xFF and bytes:byte(2) == 0xD8 then
		return "jpeg", "image/jpeg"
	elseif bytes:sub(1, 4) == "GIF8" then
		return "gif", "image/gif"
	end
	return "bin", "application/octet-stream"
end

-- JPEG: scan segment markers for a Start-Of-Frame (SOFn) and read its size.
local function jpeg_dims(s)
	local i, n = 3, #s -- past the SOI (FFD8)
	while i < n do
		if string.byte(s, i) ~= 0xFF then
			return nil
		end
		local marker = string.byte(s, i + 1)
		if (marker >= 0xD0 and marker <= 0xD9) or marker == 0x01 then
			i += 2 -- standalone marker, no length
		else
			local len = string.byte(s, i + 2) * 256 + string.byte(s, i + 3)
			-- SOF0..SOF15, excluding DHT (C4), JPG (C8), DAC (CC)
			if
				marker >= 0xC0
				and marker <= 0xCF
				and marker ~= 0xC4
				and marker ~= 0xC8
				and marker ~= 0xCC
			then
				local h = string.byte(s, i + 5) * 256 + string.byte(s, i + 6)
				local w = string.byte(s, i + 7) * 256 + string.byte(s, i + 8)
				return w, h
			end
			i += 2 + len
		end
	end
	return nil
end

-- dimensions(bytes) → widthPx, heightPx | nil (for an unrecognised/odd image).
function media.dimensions(bytes)
	local ext = media.identify(bytes)
	if ext == "png" and #bytes >= 24 then
		return be32(bytes, 17), be32(bytes, 21)
	elseif ext == "jpeg" then
		return jpeg_dims(bytes)
	elseif ext == "gif" and #bytes >= 10 then
		return string.byte(bytes, 7) + string.byte(bytes, 8) * 256,
			string.byte(bytes, 9) + string.byte(bytes, 10) * 256
	end
	return nil
end

-- registry() → a content-addressed media set. `add(bytes)` dedups by SHA-1 and
-- returns a stable entry { index, ext, contentType, name="image<N>.<ext>", bytes,
-- widthPx, heightPx }. Indices/names are assigned in first-seen order.
function media.registry()
	local items = {}
	local byKey = {}
	local reg = { items = items }
	function reg.add(bytes)
		local key = hash.sha1(bytes)
		if byKey[key] then
			return byKey[key]
		end
		local ext, contentType = media.identify(bytes)
		local w, h = media.dimensions(bytes)
		local entry = {
			index = #items + 1,
			ext = ext,
			contentType = contentType,
			bytes = bytes,
			widthPx = w,
			heightPx = h,
		}
		entry.name = "image" .. entry.index .. "." .. ext
		items[#items + 1] = entry
		byKey[key] = entry
		return entry
	end
	return reg
end

return media
