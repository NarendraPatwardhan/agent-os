---
name: agent-os-sqlite
description: 'Write, query, migrate, stream, validate, and compose SQLite-backed Luau scripts inside agent-os. Use this skill whenever the task mentions sqlite, SQL, .db files, persistent tables, migrations, prepared statements, bound parameters, transactions, streaming cursors, typed query rows, `/var/persist`, CAP_PERSIST, atlas flavor, resident services, `require("sqlite")`, `/bin/sqlite`, `sys.svc`, or exporting database results into xlsx/docx/pptx artifacts. Prefer the Luau `sqlite` library over shelling out to `$ sqlite`; use the CLI only for quick one-shot inspection.'
---

# Agent-OS SQLite

Use the Luau `sqlite` library for database work — shipped as a VFS module by the `atlas` flavor (not embedded in the interpreter, unlike `json`/`xlsx`). The source of truth is the resident-service contract in `SERVICES.md`, the sqlite guest packaging in `third_party/sqlite/BUILD*.bazel`, and the atlas flavor layer that ships `/bin/sqlite` plus `/lib/luau/sqlite.luau`.

## Workflow

1. Use `require("sqlite")` from a Luau script. It talks to the warm sqlite service through `sys.svc` and returns Lua values.
2. Open database files with `sqlite.open(path, opts)`. Use `/var/persist/...` for durable state; it requires `CAP_PERSIST`.
3. Use prepared statements and bound parameters for all data values.
4. Wrap multi-statement writes in `Db:transaction(fn)`.
5. Use `Db:rows()` for large results; `Db:query()` materializes the whole array.
6. Run scripts with `/bin/luau script.luau`; type-check with `/bin/luau --check script.luau`.

The CLI is a thin one-shot client of the same service. It is useful at a shell prompt, but it returns text to parse. The library keeps a warm connection, returns typed Lua values, supports prepared statements, transactions, and streaming cursors, and composes with the other batteries.

## Composition Pattern

SQLite rows can flow directly into another library without shelling out or reparsing text:

```lua
local sqlite, xlsx = require("sqlite"), require("xlsx")
local db = sqlite.open("/var/persist/sales.db")
local wb = xlsx.new(); local ws = wb:addWorksheet("Q3")
for _, r in ipairs(db:query("SELECT month, revenue FROM sales WHERE quarter = ?", 3)) do
  ws:addRow({ r.month, r.revenue })
end
wb:save("/out/q3.xlsx")   -- sqlite -> xlsx, one script: warm connection, typed values, no shell-out.
```

## Database Pattern

```lua
local sqlite = require("sqlite")
local db, err = sqlite.open("/var/persist/app.db")
assert(db, err)
assert(db:exec("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER)"))
local insert = assert(db:prepare("INSERT INTO users (name, age) VALUES (?, ?)"))
local rowid, changes = insert:run("alice", 30)
assert(rowid and changes == 1)
insert:run("bob", 25)
local rows = assert(db:query("SELECT id, name, age FROM users WHERE age > ?", 18))
local me = assert(db:queryone("SELECT * FROM users WHERE id = ?", rowid))
local total = assert(db:queryvalue("SELECT count(*) FROM users"))
print(me.name, total)
db:close()
```

Query results are Lua arrays of row tables. Values are typed: `INTEGER` and `REAL` become numbers, `TEXT` becomes a string, `NULL` becomes nil, and `BLOB` becomes a raw byte string.

## Prepared Statements

Prepared statements are compiled once in the resident service and can be run many times against the warm connection:

```lua
local find = assert(db:prepare("SELECT * FROM users WHERE name = :name"))
local alice = assert(find:queryone({ name = "alice" }))
find:close()
```

Use positional `?` parameters with varargs, or named `:name` parameters with a table. Do not concatenate user values into SQL.

## Transactions And Cursors

`Db:transaction(fn)` commits on success. If the function errors, sqlite rolls back and re-raises the error so callers can catch it with `pcall`.

```lua
db:transaction(function(tx)
  insert:run("carol", 40)
  tx:exec("UPDATE users SET age = age + 1 WHERE name = ?", "alice")
end)
for row in db:rows("SELECT * FROM events ORDER BY ts") do
  handle(row)
end
```

Use `Db:rows()` when a result may be too large to fit comfortably in memory. It is a lazy iterator that pulls pages from the service.

## API Surface

- Module: `sqlite.open(path [, opts])` returns a `Db` (options: `mode = "ro"` or `"rw"`, default read-write); `sqlite.blob(bytes)` tags a Lua byte string to bind as a BLOB.
- `Db`: `exec(sql [, ...])`, `query(sql [, ...])`, `queryone(sql [, ...])`, `queryvalue(sql [, ...])`, `prepare(sql)`, `transaction(fn)`, `rows(sql [, ...])`, and `close()`.
- `Stmt`: `run(...)`, `query(...)`, `queryone(...)`, and `close()`.
- Parameters: positional `?` bind from varargs; named `:name` bind from a table.
- Return discipline: recoverable failures return `(value, err)` pairs like `sys`; misuse raises and can be caught with `pcall`.
- `Stmt:run(...)` returns `(last_insert_rowid, changes)`. `Db:exec(...)` returns `(changes, err)`.

## Rules

Prefer the Luau library by default. Reach for `$ sqlite` only for quick one-shot inspection at a shell prompt.

Use prepared statements for repeated SQL and for every statement that includes values. Bound parameters are safe against injection and faster because compilation stays warm in the service.

Use transactions for migrations, imports, and any write sequence that must be atomic. Keep the body small because one sqlite service instance serializes calls; a second caller waits while the first request runs.

Warm is not durable: the service keeps a warm connection and page cache, but the durable store is the committed database file, usually under `/var/persist`. A crash loses warm state, not committed data; reconnecting gets a clean instance.

## Validation

Use the narrowest real gate that proves the behavior:

- Script type check: `/bin/luau --check script.luau`.
- Script runtime: `/bin/luau script.luau`.
- agent-os sqlite/kernel behavior: `bazel test //tests/e2e`.

For data-producing scripts, validate the data, not just the exit code. Reopen the database, query expected rows and counts, check transaction rollback behavior when it matters, and verify generated artifacts with their format libraries.

## Boundaries

- `require("sqlite")` resolves from the VFS cache, embedded libraries, then `package.path`; sqlite is shipped by the `atlas` flavor layer.
- `/var/persist` needs `CAP_PERSIST`; read-only reference databases can be opened with `sqlite.open(path, { mode = "ro" })`.
- `Db:query()` materializes the full result. Use `Db:rows()` for large tables or unbounded scans.
- BLOB columns read back as raw byte strings (any bytes, round-tripped losslessly) — keep them as bytes, not UTF-8 text. To BIND a BLOB, wrap the bytes with `sqlite.blob(bytes)`; a plain Lua string binds as TEXT.
- The public surface is the Luau library. Do not script the low-level `sys.svc` protocol unless you are changing the sqlite library or service itself.
