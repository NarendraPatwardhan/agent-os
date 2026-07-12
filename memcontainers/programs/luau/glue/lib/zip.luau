-- zip.luau — a pure-Luau ZIP reader/writer (STORE + DEFLATE), the container the
-- office/document tier sits on (luau-extensions Ch.03). We own the container
-- rather than shelling out to `unzip` because OPC needs precise control of part
-- ordering and byte-stable, deterministic output (`[Content_Types].xml` first), and
-- because it's just little-endian byte work — exactly what Luau does well. The two
-- genuinely host-specific bits are delegated: DEFLATE to the C `deflate` module and
-- CRC-32 to `hash` (SYSTEMS.md §10.3). `string.pack`/`unpack` give us fixed-width LE
-- records for free (ZIP is little-endian, same as the machine).
--
-- An archive is { entries = { ZipEntry... }, byName = { [name]=ZipEntry } }, kept
-- in order; `:add` appends, and write preserves that order. A ZipEntry is
--   { name, data (UNCOMPRESSED bytes), method="STORE"|"DEFLATE", crc?, comment?,
--     externalAttrs? }
-- `data` is the plaintext both ways; the layer compresses on write, inflates on read.

local deflate = require("deflate")
local hash = require("hash")

local zip = {}

-- ZIP record signatures (PK\x..\x..).
local SIG_LOCAL = "PK\3\4"
local SIG_CENTRAL = "PK\1\2"
local SIG_EOCD = "PK\5\6"
local SIG_EOCD64 = "PK\6\6"
local SIG_EOCD64_LOC = "PK\6\7"

local METHOD_STORE = 0
local METHOD_DEFLATE = 8
local U32_MAX = 0xffffffff

-- A fixed DOS date/time (1980-01-01 00:00:00) so identical inputs produce
-- byte-identical archives — good for diffs, caching, and round-trip tests.
local DOS_TIME = 0
local DOS_DATE = 0x21

-- ===========================================================================
-- Archive construction
-- ===========================================================================

local Archive = {}
Archive.__index = Archive

function zip.new()
	return setmetatable({ entries = {}, byName = {} }, Archive)
end

-- add(name, data, opts?) — append an entry. opts.method = "STORE"|"DEFLATE"
-- (default DEFLATE; the writer falls back to STORE if it wouldn't shrink).
function Archive.add(self, name, data, opts)
	opts = opts or {}
	local entry = {
		name = name,
		data = data,
		method = opts.method or "DEFLATE",
		comment = opts.comment,
		externalAttrs = opts.externalAttrs,
	}
	if self.byName[name] == nil then
		self.entries[#self.entries + 1] = entry
	else
		-- replace in place, preserving position
		for i, e in ipairs(self.entries) do
			if e.name == name then
				self.entries[i] = entry
				break
			end
		end
	end
	self.byName[name] = entry
	return entry
end

function Archive.get(self, name)
	return self.byName[name]
end

-- ===========================================================================
-- Reading
-- ===========================================================================

-- Locate the End Of Central Directory record by scanning backward (it lies within
-- the last 22 + 65535 bytes). Returns its byte offset (1-based) or nil.
local function find_eocd(s)
	local n = #s
	local lo = math.max(1, n - (22 + 65535))
	for p = n - 21, lo, -1 do
		if s:sub(p, p + 3) == SIG_EOCD then
			return p
		end
	end
	return nil
end

-- zip.read(bytes) -> archive | nil, err. Driven from the central directory (the
-- authoritative source of sizes/offsets), so data descriptors need no special case.
function zip.read(bytes)
	if type(bytes) == "buffer" then
		bytes = buffer.tostring(bytes)
	end
	local eocd = find_eocd(bytes)
	if not eocd then
		return nil, "zip/not-a-zip: no end-of-central-directory record"
	end

	-- EOCD: total entries @ +10 (u16), cd size @ +12 (u16... u32), cd offset @ +16.
	local total = string.unpack("<I2", bytes, eocd + 10)
	local cd_size = string.unpack("<I4", bytes, eocd + 12)
	local cd_offset = string.unpack("<I4", bytes, eocd + 16)

	-- ZIP64: a 0xffff/0xffffffff sentinel means the real values live in the
	-- ZIP64 EOCD, reached via the locator immediately before the EOCD.
	if total == 0xffff or cd_offset == U32_MAX or cd_size == U32_MAX then
		local loc = eocd - 20
		if loc >= 1 and bytes:sub(loc, loc + 3) == SIG_EOCD64_LOC then
			local z64 = string.unpack("<I8", bytes, loc + 8) -- offset of ZIP64 EOCD
			local z = z64 + 1 -- 1-based
			if bytes:sub(z, z + 3) == SIG_EOCD64 then
				total = string.unpack("<I8", bytes, z + 32)
				cd_size = string.unpack("<I8", bytes, z + 40)
				cd_offset = string.unpack("<I8", bytes, z + 48)
			end
		end
	end

	local archive = zip.new()
	local pos = cd_offset + 1 -- 1-based
	for _ = 1, total do
		if bytes:sub(pos, pos + 3) ~= SIG_CENTRAL then
			return nil, "zip/corrupt: bad central directory signature"
		end
		local method = string.unpack("<I2", bytes, pos + 10)
		local crc = string.unpack("<I4", bytes, pos + 16)
		local csize = string.unpack("<I4", bytes, pos + 20)
		local usize = string.unpack("<I4", bytes, pos + 24)
		local nlen = string.unpack("<I2", bytes, pos + 28)
		local elen = string.unpack("<I2", bytes, pos + 30)
		local clen = string.unpack("<I2", bytes, pos + 32)
		local lho = string.unpack("<I4", bytes, pos + 42)
		local name = bytes:sub(pos + 46, pos + 46 + nlen - 1)
		local extra = bytes:sub(pos + 46 + nlen, pos + 46 + nlen + elen - 1)
		local comment = clen > 0 and bytes:sub(pos + 46 + nlen + elen, pos + 46 + nlen + elen + clen - 1) or nil

		-- ZIP64 extended information extra field (0x0001): real 64-bit sizes/offset.
		if usize == U32_MAX or csize == U32_MAX or lho == U32_MAX then
			local ep = 1
			while ep + 4 <= #extra do
				local tag = string.unpack("<I2", extra, ep)
				local sz = string.unpack("<I2", extra, ep + 2)
				if tag == 0x0001 then
					local fp = ep + 4
					if usize == U32_MAX then
						usize = string.unpack("<I8", extra, fp)
						fp += 8
					end
					if csize == U32_MAX then
						csize = string.unpack("<I8", extra, fp)
						fp += 8
					end
					if lho == U32_MAX then
						lho = string.unpack("<I8", extra, fp)
					end
					break
				end
				ep += 4 + sz
			end
		end

		-- Seek the local header to skip its (possibly different) name/extra lengths.
		local lp = lho + 1
		if bytes:sub(lp, lp + 3) ~= SIG_LOCAL then
			return nil, "zip/corrupt: bad local header for '" .. name .. "'"
		end
		local lnlen = string.unpack("<I2", bytes, lp + 26)
		local lelen = string.unpack("<I2", bytes, lp + 28)
		local data_start = lp + 30 + lnlen + lelen
		local compressed = bytes:sub(data_start, data_start + csize - 1)

		local data
		if method == METHOD_STORE then
			data = compressed
		elseif method == METHOD_DEFLATE then
			local out, err = deflate.decompress(compressed, usize)
			if not out then
				return nil, "zip/inflate '" .. name .. "': " .. err
			end
			data = out
		else
			return nil, "zip/unsupported-method " .. method .. " for '" .. name .. "'"
		end

		if hash.crc32(data) ~= crc then
			return nil, "zip/bad-crc for '" .. name .. "'"
		end

		archive:add(name, data, {
			method = method == METHOD_STORE and "STORE" or "DEFLATE",
			comment = comment,
		})
		archive.byName[name].crc = crc

		pos = pos + 46 + nlen + elen + clen
	end

	return archive
end

-- ===========================================================================
-- Writing
-- ===========================================================================

-- Decide the stored bytes for one entry: STORE keeps plaintext, DEFLATE compresses
-- but falls back to STORE if that wouldn't shrink (never inflate a part).
local function encode_entry(entry, level)
	local data = entry.data
	if entry.method == "DEFLATE" then
		local packed = deflate.compress(data, level)
		if #packed < #data then
			return METHOD_DEFLATE, packed
		end
	end
	return METHOD_STORE, data
end

-- zip.write(archive, opts?) -> bytes | nil, err. Emits entries in archive order,
-- then the central directory, then the EOCD. Deterministic (fixed mtime, stable
-- order). opts.level forwards a deflate effort hint; opts.perEntry(name)->method
-- overrides the method per entry.
function zip.write(archive, opts)
	opts = opts or {}
	local level = opts.level or 6
	local parts = {}
	local central = {}
	local offset = 0

	for _, entry in ipairs(archive.entries) do
		local method = entry.method
		if opts.perEntry then
			method = opts.perEntry(entry.name) or method
		end
		local crc = hash.crc32(entry.data)
		local usize = #entry.data
		local m, stored = encode_entry({ data = entry.data, method = method }, level)
		local csize = #stored
		if offset > U32_MAX or usize > U32_MAX or csize > U32_MAX then
			return nil, "zip/too-large: entry exceeds 4 GiB (ZIP64 write unsupported)"
		end
		local nlen = #entry.name

		-- Local file header (no data descriptor; sizes are known up front).
		local lh = string.pack(
			"<I4I2I2I2I2I2I4I4I4I2I2",
			0x04034b50, -- signature
			20, -- version needed
			0, -- flags
			m, -- method
			DOS_TIME,
			DOS_DATE,
			crc,
			csize,
			usize,
			nlen,
			0 -- extra length
		)
		parts[#parts + 1] = lh
		parts[#parts + 1] = entry.name
		parts[#parts + 1] = stored

		central[#central + 1] = {
			name = entry.name,
			method = m,
			crc = crc,
			csize = csize,
			usize = usize,
			offset = offset,
			comment = entry.comment,
			externalAttrs = entry.externalAttrs or 0,
		}
		offset = offset + #lh + nlen + csize
	end

	local cd_offset = offset
	local cd = {}
	for _, c in ipairs(central) do
		local clen = c.comment and #c.comment or 0
		local ch = string.pack(
			"<I4I2I2I2I2I2I2I4I4I4I2I2I2I2I2I4I4",
			0x02014b50, -- signature
			20, -- version made by
			20, -- version needed
			0, -- flags
			c.method,
			DOS_TIME,
			DOS_DATE,
			c.crc,
			c.csize,
			c.usize,
			#c.name,
			0, -- extra length
			clen,
			0, -- disk number start
			0, -- internal attrs
			c.externalAttrs,
			c.offset
		)
		cd[#cd + 1] = ch
		cd[#cd + 1] = c.name
		if c.comment then
			cd[#cd + 1] = c.comment
		end
	end
	local cd_bytes = table.concat(cd)
	parts[#parts + 1] = cd_bytes

	local n = #central
	local eocd = string.pack(
		"<I4I2I2I2I2I4I4I2",
		0x06054b50, -- signature
		0, -- disk number
		0, -- disk with cd
		n, -- entries on this disk
		n, -- total entries
		#cd_bytes, -- central directory size
		cd_offset, -- central directory offset
		0 -- comment length
	)
	parts[#parts + 1] = eocd

	return table.concat(parts)
end

return zip
