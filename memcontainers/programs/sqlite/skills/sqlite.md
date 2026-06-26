---
name: memcontainer-sqlite
description: 'Use SQLite from Luau inside a memcontainer or from a host agent driving a memcontainer VM. Use this skill when the task mentions sqlite, SQL, .db files, persistent tables, migrations, prepared statements, transactions, streaming rows, BLOBs, vector indexes, semantic memory, RAG, nearest-neighbour search, `/var/persist`, CAP_PERSIST, atlas flavor, `require("sqlite")`, or `/bin/sqlite`. Prefer the Luau `sqlite` library; use the CLI for quick one-shot inspection.'
---

# Memcontainer SQLite

Use the embedded Luau `sqlite` library for database work inside a memcontainer. It talks to the resident SQLite service, keeps connections warm, returns typed Lua values, and supports prepared statements, transactions, streaming cursors, BLOBs, and vector-search helpers.

The `/bin/sqlite` command is useful at a shell prompt for quick inspection and one-shot SQL. Prefer `require("sqlite")` in scripts that read, write, validate, compose artifacts, or maintain agent memory.

## Workflow

1. Use `local sqlite = require("sqlite")` in Luau scripts.
2. Open durable databases under `/var/persist/...` when state must survive reboot; that requires `CAP_PERSIST`.
3. Bind every data value with positional `?` parameters. Do not concatenate values into SQL.
4. Wrap multi-statement writes in `Db:transaction(function(tx) ... end)`.
5. Use `Db:rows()` for large result sets; `Db:query()` materializes all rows.
6. For RAG or semantic memory, create a vector table with `Db:createVectorIndex()` and query it with `Db:vectorSearch()`.
7. Validate behavior from inside the memcontainer with `/bin/luau --check`, `/bin/luau`, and targeted `/bin/sqlite` reads.

## SQL Pattern

```lua
local sqlite = require("sqlite")
local db, err = sqlite.open("/var/persist/app.db")
assert(db, err)

db:exec([[
  CREATE TABLE IF NOT EXISTS notes (
    id INTEGER PRIMARY KEY,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    created INTEGER NOT NULL
  )
]])

db:transaction(function(tx)
  local stmt = tx:prepare("INSERT INTO notes (title, body, created) VALUES (?, ?, ?)")
  stmt:run("plan", "ship the report", os.time())
  stmt:close()
end)

for row in db:rows("SELECT id, title FROM notes WHERE created >= ? ORDER BY created DESC", cutoff) do
  print(row.id, row.title)
end

db:close()
```

Query rows are Lua tables keyed by column name and by 1-based index. `INTEGER` and `REAL` become numbers, `TEXT` becomes a string, `NULL` becomes nil, and `BLOB` becomes a raw byte string. Bind raw BLOB bytes with `sqlite.blob(bytes)`.

`Db:transaction(fn)` commits when the function returns. If the function errors, SQLite rolls back and the error is re-raised. Prepared statements are compiled in the resident service and can be reused with `Stmt:run`, `Stmt:query`, and `Stmt:queryone`.

## Vector Memory Pattern

Use vector tables for agent memory, RAG chunks, deduplication, and scoped nearest-neighbour retrieval. The table is still SQL: vector search can be combined with partition columns, metadata filters, ordering, limits, and ordinary joins.

Partition columns are for hard routing such as tenant, session, user, or corpus. Always include the partition equality filter when the user asks within a specific scope. Metadata columns are for filters such as source, created time, role, language, or document id. Aux columns are returned payloads that are not searched or filtered, such as chunk text or a citation label.

```lua
local sqlite = require("sqlite")
local db = assert(sqlite.open("/var/persist/memory.db"))

db:createVectorIndex("mem", {
  vector = { name = "embedding", type = "float", dims = 768, metric = "cosine" },
  partitions = { "tenant" },
  metadata = {
    { name = "source", type = "text" },
    { name = "created", type = "integer" },
  },
  aux = { "chunk", "uri" },
})

db:exec(
  "INSERT INTO mem(rowid, embedding, tenant, source, created, chunk, uri) VALUES (?, ?, ?, ?, ?, ?, ?)",
  id,
  sqlite.vec.f32(embedding),
  "agent-a",
  "docs",
  created_at,
  chunk_text,
  uri
)

local hits = db:vectorSearch("mem", query_embedding, {
  vector = "embedding",
  type = "f32",
  k = 8,
  partition = { tenant = "agent-a" },
  filter = { source = "docs" },
  filters = { { "created", ">=", cutoff } },
})

for _, hit in ipairs(hits) do
  print(hit.rowid, hit.distance, hit.uri, hit.chunk)
end
```

`sqlite.vec.f32(values)`, `sqlite.vec.int8(values)`, and `sqlite.vec.bit(values)` encode vectors as tagged BLOBs. `Db:vectorSearch()` accepts one of those BLOBs or a numeric array plus `type = "f32" | "int8" | "bit"`.

Keep dimensions fixed for a table. Reject NaN/Inf before insert if embeddings come from an unreliable source. Use `metric = "cosine"` for normalized semantic embeddings, `metric = "l2"` for geometric distance, `metric = "ip"` for inner product scoring, and `metric = "hamming"` for bit vectors. Use small `k` values for interactive retrieval, and set `ef` in `vectorSearch()` only when recall needs a wider candidate search.

## RAG Loop

For retrieval-augmented generation, store one row per chunk with:

- a stable `rowid` if the source system already has ids, otherwise let SQLite allocate one;
- an embedding in the vector column;
- a partition such as tenant, workspace, or corpus;
- metadata needed for filtering and freshness;
- aux payloads such as chunk text, URI, title, and section.

At answer time, embed the question, run `Db:vectorSearch()` with the correct partition and metadata filters, then pass the returned `chunk`, `uri`, `rowid`, and `distance` to the model. Keep source text in aux columns when it is small enough to return directly. Store larger documents in ordinary tables and put document ids in the vector table when chunks need joins.

## CLI Pattern

Use `/bin/sqlite` for quick inspection, migrations, and shell-visible checks. It uses the same SQL surface, including vector tables and vector constructors:

```sql
CREATE VIRTUAL TABLE mem USING vann(
  embedding float[3] metric=cosine,
  tenant text partition,
  source text,
  created integer,
  chunk text aux
);

INSERT INTO mem(rowid, embedding, tenant, source, created, chunk)
VALUES (1, vec_f32('[1,0,0]'), 'agent-a', 'docs', 1710000000, 'First chunk');

SELECT rowid, printf('%.4f', distance) AS d, chunk
FROM mem
WHERE embedding MATCH vec_f32('[0.9,0.1,0]')
  AND k = 5
  AND tenant = 'agent-a'
  AND source = 'docs';
```

At a shell prompt:

```sh
sqlite /var/persist/memory.db "SELECT count(*) FROM mem"
sqlite /var/persist/memory.db "SELECT vann_info('mem')"
sqlite /var/persist/memory.db "SELECT vann_health('mem')"
```

## API Surface

- Module: `sqlite.open(path [, opts])`, `sqlite.blob(bytes)`, `sqlite.vec.f32(values)`, `sqlite.vec.int8(values)`, and `sqlite.vec.bit(values)`.
- `Db`: `exec`, `query`, `queryone`, `queryvalue`, `prepare`, `transaction`, `rows`, `createVectorIndex`, `vectorSearch`, `vectorInfo`, `vectorHealth`, `vectorQuantization`, `vectorRebuild`, and `close`.
- `Stmt`: `run`, `query`, `queryone`, and `close`.
- Parameters: positional `?` bind from varargs.
- Return discipline: `sqlite.open` returns `(db, err)`; query and statement misuse raises and can be caught with `pcall`.

## Validation

Use the narrowest real in-memcontainer check:

- Type check: `/bin/luau --check script.luau`.
- Runtime check: `/bin/luau script.luau`.
- SQL count or sample: `sqlite /var/persist/app.db "SELECT count(*) FROM table_name"`.
- SQL file inspection: `cat query.sql | sqlite /var/persist/app.db`.

For data scripts, reopen the database and query expected rows, counts, and rollback behavior. For vector memory, test with tiny known vectors before loading real embeddings, then verify filtered searches with matching and non-matching partitions or metadata.

Use `db:vectorInfo(name)` to confirm dimensions, counts, resident hot bytes, and cold vector bytes. Use `db:vectorHealth(name)` after bulk loads or heavy churn; if it reports graph damage, run `db:vectorRebuild(name)` and check health again. Use `db:vectorQuantization(name)` when you need to know whether traversal is int8, bit, or f32-rescored.

## Boundaries

- `/var/persist` requires `CAP_PERSIST`; temporary databases can live elsewhere.
- Read-only databases can be opened with `sqlite.open(path, { mode = "ro" })`.
- `Db:query()` materializes the full result; use `Db:rows()` for large scans.
- One resident SQLite service instance serializes calls, so keep transactions tight.
- Vector tables are durable SQL tables with shadow storage; committed rows survive service restart.
- The public surface is the Luau library plus SQL. Do not script the low-level service protocol directly.
