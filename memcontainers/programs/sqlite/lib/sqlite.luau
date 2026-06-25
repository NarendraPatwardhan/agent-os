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
