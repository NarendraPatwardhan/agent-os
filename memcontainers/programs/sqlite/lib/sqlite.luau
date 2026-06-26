--!strict
--[[
  sqlite.luau — the warm, typed SQLite data layer for agent-os Luau: `require("sqlite")`.

  The ergonomic face of the resident `sqlite` SERVICE. `sqlite.open(path)` holds a WARM connection
  (the service keeps the `sqlite3*` open across calls); `db:query` returns Lua VALUES (typed rows),
  `db:exec` runs statements, `db:transaction` wraps a function atomically. It talks to the service over
  `sys.svc` with a small JSON protocol. Shipped as VFS content by the `atlas` flavor (not embedded in
  the interpreter). The CLI `$ sqlite` is a thin client of the same warm engine. See /skills/sqlite.md.
]]

local json = require("json")

local Db = {}
Db.__index = Db

-- One round-trip to the service: encode the request, call, decode, raise on a transport or app error.
local function call(self, req)
  if not self.fd then
    error("sqlite: database is closed", 2)
  end
  req.v = 1 -- protocol version: the service rejects an unversioned/incompatible request (codex #9)
  local resp, err = sys.svc.call(self.fd, json.encode(req))
  if not resp then
    error("sqlite: " .. tostring(err), 2)
  end
  local r = json.decode(resp)
  if not r.ok then
    -- Surface sqlite's structured extended result code (e.g. 19 = CONSTRAINT) when present; an
    -- application error carries code 0 and just the message.
    local msg = "sqlite: " .. tostring(r.error)
    if r.code and r.code ~= 0 then
      msg = msg .. " (sqlite code " .. tostring(r.code) .. ")"
    end
    error(msg, 2)
  end
  return r
end

-- BLOBs ride the JSON protocol as a tagged hex object {"$blob":"<hex>"} — arbitrary bytes cannot sit
-- in a JSON string. toHex/fromHex convert between a Lua byte string and that hex; decodeCell turns a
-- tagged column value back into the raw bytes (any other value passes through unchanged).
local function toHex(s: string): string
  local out = table.create(#s)
  for i = 1, #s do
    out[i] = string.format("%02x", string.byte(s, i))
  end
  return table.concat(out)
end

local function fromHex(h: string): string
  local out = table.create(#h // 2)
  for i = 1, #h - 1, 2 do
    out[#out + 1] = string.char(tonumber(string.sub(h, i, i + 1), 16) or 0)
  end
  return table.concat(out)
end

local function decodeCell(v)
  if type(v) == "table" and v["$blob"] ~= nil then
    return fromHex(v["$blob"])
  end
  return v
end

-- Build typed row tables from the wire form — `cols` (the column names) + `raw` rows (arrays of
-- values). Each row is keyed BOTH by column name and by 1-based index, with NULL as nil (absent) and
-- BLOBs decoded to byte strings, so reads are `row.name` / `row[i]`. Shared by `query`, `Stmt:query`,
-- and the `rows()` cursor.
local function buildRows(cols, rawRows)
  local rows = {}
  for i, raw in ipairs(rawRows) do
    local row = {}
    for j, name in ipairs(cols) do
      local v = decodeCell(raw[j])
      row[name] = v
      row[j] = v
    end
    rows[i] = row
  end
  return rows
end

local sqlite = {}

--- Open a database (a WARM connection). `opts.mode = "ro"` opens it read-only (no create). Returns a
--- Db handle, or `(nil, err)` if the service is unavailable / the open fails.
function sqlite.open(path: string, opts: { mode: string? }?)
  local fd, err = sys.svc.connect("sqlite")
  if not fd then
    return nil, err
  end
  local self = setmetatable({ fd = fd }, Db)
  local ok, e = pcall(call, self, { op = "open", path = path, mode = opts and opts.mode })
  if not ok then
    pcall(sys.svc.close, fd)
    return nil, tostring(e)
  end
  return self
end

--- Tag `bytes` (a Lua byte string) as a BLOB to bind: `db:exec("… VALUES (?)", sqlite.blob(raw))`.
--- Without it a Lua string binds as TEXT. BLOB columns always read back as plain Lua byte strings.
function sqlite.blob(bytes: string)
  return { ["$blob"] = toHex(bytes) }
end

local function assertIdent(name: string, label: string): string
  if type(name) ~= "string" or not string.match(name, "^[A-Za-z_][A-Za-z0-9_]*$") then
    error("sqlite: invalid " .. label .. " identifier: " .. tostring(name), 3)
  end
  return name
end

local function quoteIdent(name: string): string
  return '"' .. assertIdent(name, "SQL") .. '"'
end

local function normalizeType(t)
  t = t or "text"
  if t == "int" then
    return "integer"
  end
  if t == "float" then
    return "real"
  end
  if t ~= "integer" and t ~= "real" and t ~= "text" and t ~= "blob" then
    error("sqlite: unsupported vector index column type: " .. tostring(t), 3)
  end
  return t
end

local function sortedKeys(map)
  local keys = {}
  for k, _ in pairs(map) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

local function vectorHeader(tag: number, dims: number): string
  return string.pack("<BI4", tag, dims)
end

local function vectorF32(values): string
  local out = table.create(#values + 1)
  out[1] = vectorHeader(1, #values)
  for i, v in ipairs(values) do
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
      error("sqlite: f32 vector values must be finite numbers", 3)
    end
    out[i + 1] = string.pack("<f", v)
  end
  return table.concat(out)
end

local function vectorInt8(values): string
  local out = table.create(#values + 1)
  out[1] = vectorHeader(2, #values)
  for i, v in ipairs(values) do
    if type(v) ~= "number" or math.floor(v) ~= v or v < -128 or v > 127 then
      error("sqlite: int8 vector values must be integers in [-128, 127]", 3)
    end
    if v < 0 then
      v += 256
    end
    out[i + 1] = string.char(v)
  end
  return table.concat(out)
end

local function vectorBit(values): string
  local bytes = {}
  local cur, nbits = 0, 0
  for _, v in ipairs(values) do
    local on = v == true or v == 1
    if on then
      cur += 2 ^ nbits
    elseif v ~= false and v ~= 0 then
      error("sqlite: bit vector values must be booleans or 0/1", 3)
    end
    nbits += 1
    if nbits == 8 then
      bytes[#bytes + 1] = string.char(cur)
      cur, nbits = 0, 0
    end
  end
  if nbits > 0 then
    bytes[#bytes + 1] = string.char(cur)
  end
  return vectorHeader(3, #values) .. table.concat(bytes)
end

sqlite.vec = {}

--- Encode a float32 vector as the tagged BLOB format accepted by `vann`.
function sqlite.vec.f32(values)
  return sqlite.blob(vectorF32(values))
end

--- Encode an int8 vector as the tagged BLOB format accepted by `vann`.
function sqlite.vec.int8(values)
  return sqlite.blob(vectorInt8(values))
end

--- Encode a binary vector as the tagged BLOB format accepted by `vann`.
function sqlite.vec.bit(values)
  return sqlite.blob(vectorBit(values))
end

local function vectorTypeSql(spec): string
  local typ = spec.type or "float"
  local dims = assert(spec.dims, "sqlite: vector index needs vector.dims")
  if typ == "float" or typ == "f32" then
    return "float[" .. tostring(dims) .. "]"
  elseif typ == "int8" then
    return "int8[" .. tostring(dims) .. "]"
  elseif typ == "bit" or typ == "binary" then
    return "bit[" .. tostring(dims) .. "]"
  end
  error("sqlite: unsupported vector type: " .. tostring(typ), 3)
end

local function appendColumn(parts, item, suffix)
  local name, typ
  if type(item) == "string" then
    name, typ = item, "text"
  else
    name, typ = item.name, item.type or "text"
  end
  parts[#parts + 1] = assertIdent(name, "vector index column") .. " " .. normalizeType(typ) .. suffix
end

--- Run a statement with no result rows (DDL, INSERT/UPDATE/DELETE). Positional `?` params bind from
--- the varargs. Returns the rows-affected count. Raises on error.
function Db:exec(sql: string, ...)
  return call(self, { op = "exec", sql = sql, params = { ... } }).changes
end

--- Run a query. Returns an ARRAY of row tables; each row is keyed both by column NAME and by 1-based
--- index, and values are typed: INTEGER/REAL → number, TEXT → string, NULL → nil, BLOB → string (bytes).
function Db:query(sql: string, ...)
  local r = call(self, { op = "query", sql = sql, params = { ... } })
  return buildRows(r.cols, r.rows)
end

--- The first row of a query (a row table), or nil.
function Db:queryone(sql: string, ...)
  return self:query(sql, ...)[1]
end

--- The first column of the first row (a scalar), or nil — handy for `count(*)`, a single lookup, etc.
function Db:queryvalue(sql: string, ...)
  local r = call(self, { op = "query", sql = sql, params = { ... } })
  local first = r.rows[1]
  return first and first[1] or nil
end

--- Create a `vann` vector index virtual table. Example:
--- `db:createVectorIndex("mem", { vector = { name = "embedding", dims = 768, metric = "cosine" },
---   partitions = { "tenant" }, metadata = { { name = "created", type = "integer" } }, aux = { "text" } })`
function Db:createVectorIndex(name: string, spec)
  local vec = spec.vector or {}
  local vecName = vec.name or "embedding"
  local metric = vec.metric or "cosine"
  if metric ~= "cosine" and metric ~= "l2" and metric ~= "ip" and metric ~= "inner-product" and metric ~= "hamming" then
    error("sqlite: unsupported vector metric: " .. tostring(metric), 2)
  end
  local parts = {
    assertIdent(vecName, "vector column") .. " " .. vectorTypeSql(vec) .. " metric=" .. metric,
  }
  for _, item in ipairs(spec.partitions or {}) do
    appendColumn(parts, item, " partition")
  end
  for _, item in ipairs(spec.metadata or {}) do
    appendColumn(parts, item, "")
  end
  for _, item in ipairs(spec.aux or {}) do
    appendColumn(parts, item, " aux")
  end
  if spec.M then
    parts[#parts + 1] = "M=" .. tostring(spec.M)
  end
  if spec.ef_construction then
    parts[#parts + 1] = "ef_construction=" .. tostring(spec.ef_construction)
  end
  if spec.ef_search then
    parts[#parts + 1] = "ef_search=" .. tostring(spec.ef_search)
  end
  if spec.cache_nodes or spec.cacheNodes then
    parts[#parts + 1] = "cache_nodes=" .. tostring(spec.cache_nodes or spec.cacheNodes)
  end
  local exists = if spec.ifNotExists == false then "" else " IF NOT EXISTS"
  local sql = "CREATE VIRTUAL TABLE" .. exists .. " " .. quoteIdent(name) .. " USING vann(" .. table.concat(parts, ", ") .. ")"
  return self:exec(sql)
end

local function normalizeQueryVector(query, opts)
  if type(query) == "table" and query["$blob"] ~= nil then
    return query
  end
  if type(query) == "table" then
    local typ = opts and opts.type or "f32"
    if typ == "float" or typ == "f32" then
      return sqlite.vec.f32(query)
    elseif typ == "int8" then
      return sqlite.vec.int8(query)
    elseif typ == "bit" or typ == "binary" then
      return sqlite.vec.bit(query)
    end
  end
  return query
end

local function addFilter(where, params, filter)
  local col, op, value = filter[1], filter[2] or "=", filter[3]
  if op ~= "=" and op ~= ">" and op ~= ">=" and op ~= "<" and op ~= "<=" then
    error("sqlite: unsupported vector filter op: " .. tostring(op), 3)
  end
  where[#where + 1] = quoteIdent(col) .. " " .. op .. " ?"
  params[#params + 1] = value
end

local function addEqualsMap(where, params, map)
  for _, key in ipairs(sortedKeys(map)) do
    where[#where + 1] = quoteIdent(key) .. " = ?"
    params[#params + 1] = map[key]
  end
end

--- Run a KNN query against a `vann` table. `query` may be `sqlite.vec.f32(...)` or a numeric array.
--- Options: `vector`, `k`, `ef`, `type`, `partition = { tenant = "x" }`, `filter = { source = "docs" }`,
--- `filters = { { "created", ">=", 10 } }`.
function Db:vectorSearch(name: string, query, opts)
  opts = opts or {}
  local vector = opts.vector or "embedding"
  local k = opts.k or 10
  local where = { quoteIdent(vector) .. " MATCH ?", "k = ?" }
  local params = { normalizeQueryVector(query, opts), k }
  if opts.ef then
    where[#where + 1] = "ef = ?"
    params[#params + 1] = opts.ef
  end
  if opts.partition then
    addEqualsMap(where, params, opts.partition)
  end
  if opts.filter then
    addEqualsMap(where, params, opts.filter)
  end
  for _, filter in ipairs(opts.filters or {}) do
    addFilter(where, params, filter)
  end
  local sql = "SELECT rowid, distance, * FROM " .. quoteIdent(name) .. " WHERE " .. table.concat(where, " AND ")
  return self:query(sql, table.unpack(params))
end

local function vectorMeta(self, fnName: string, name: string)
  assertIdent(name, "vector index")
  return json.decode(self:queryvalue("SELECT " .. fnName .. "(?)", name))
end

--- Return table-backed `vann` metadata: format, dims, element type, metric, graph params, version,
--- cache-node cap, node counts, metadata-index rows, resident estimate, total hot payload bytes,
--- and cold full-vector bytes.
function Db:vectorInfo(name: string)
  return vectorMeta(self, "vann_info", name)
end

--- Return `vann` health counters, including dangling graph edges.
function Db:vectorHealth(name: string)
  return vectorMeta(self, "vann_health", name)
end

--- Return the traversal/rescore strategy for a `vann` table.
function Db:vectorQuantization(name: string)
  return vectorMeta(self, "vann_quantization", name)
end

--- Rebuild a `vann` table's durable graph from its stored nodes/vectors. This is a synchronous repair
--- operation; use after health checks report graph-quality problems or after bulk churn.
function Db:vectorRebuild(name: string)
  return vectorMeta(self, "vann_rebuild", name)
end

-- A PREPARED statement: compiled ONCE in the service (warm) and bound + run many — `db:prepare` makes one.
local Stmt = {}
Stmt.__index = Stmt

--- Bind `...` and run the statement to completion (a write: INSERT/UPDATE/DELETE). Returns the
--- rows-affected count.
function Stmt:run(...)
  return call(self.db, { op = "step", id = self.id, params = { ... }, max = 0 }).changes
end

--- Bind `...` and return ALL result rows (typed row tables, keyed by name + index).
function Stmt:query(...)
  local r = call(self.db, { op = "step", id = self.id, params = { ... }, max = 0 })
  return buildRows(self.cols, r.rows)
end

--- The first row of `:query`, or nil.
function Stmt:queryone(...)
  return self:query(...)[1]
end

--- Finalize the statement, freeing the warm compiled statement in the service. Idempotent.
function Stmt:close()
  if self.id then
    pcall(call, self.db, { op = "finalize", id = self.id })
    self.id = nil
  end
end

--- Compile a statement ONCE (kept warm in the service) and bind/run it many times — no re-parse per
--- call, and parameters bind safely (no injection). Returns a Stmt: `:run` (a write → changes),
--- `:query` (rows), `:queryone` (first row), `:close`. Positional `?` params bind from the call args.
function Db:prepare(sql: string)
  local r = call(self, { op = "prepare", sql = sql })
  return setmetatable({ db = self, id = r.id, cols = r.cols }, Stmt)
end

--- A STREAMING cursor: a lazy iterator over a query's rows, pulled from the service a PAGE at a time
--- rather than all at once — for big result sets. `for row in db:rows(sql, ...) do … end`. The cursor
--- finalizes when the iterator is exhausted; an early `break` leaves it for the session teardown
--- (`db:close`), so prefer iterating to the end.
function Db:rows(sql: string, ...)
  local r = call(self, { op = "prepare", sql = sql })
  local id, cols = r.id, r.cols
  local params = { ... }
  local page = {}
  local pi = 0
  local done = false
  local bound = false
  return function()
    while true do
      pi += 1
      if pi <= #page then
        return page[pi]
      end
      if done then
        return nil
      end
      -- Bind only on the FIRST page (params present → the service resets + re-binds); continuation
      -- pages omit params so the cursor advances instead of restarting.
      local req = { op = "step", id = id, max = 64, params = (not bound) and params or nil }
      bound = true
      local s = call(self, req)
      page = buildRows(cols, s.rows)
      pi = 0
      done = s.done
      if done then
        pcall(call, self, { op = "finalize", id = id })
      end
    end
  end
end

--- Run `fn(self)` inside a transaction: BEGIN, then COMMIT on success, or ROLLBACK and re-raise on
--- error. The whole body is atomic.
function Db:transaction(fn)
  self:exec("BEGIN")
  local ok, err = pcall(fn, self)
  if ok then
    self:exec("COMMIT")
  else
    pcall(function()
      self:exec("ROLLBACK")
    end)
    error(err, 0) -- re-raise the original error, unchanged
  end
end

--- End this session's connection. The service keeps the DB warm for other sessions, or drops it if
--- this was the last. Idempotent.
function Db:close()
  if self.fd then
    local fd = self.fd
    pcall(call, self, { op = "close" })
    self.fd = nil
    pcall(sys.svc.close, fd)
  end
end

return sqlite
