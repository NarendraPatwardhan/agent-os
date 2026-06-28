//! sqlite resident-service e2e (Phase 6): the `require("sqlite")` library on the `atlas` flavor — a
//! warm connection, typed rows, parameterized writes, transactions, and the headline sqlite→xlsx
//! composition (values flowing across libraries, which the shell-out CLI can't do). All driven through
//! the real shell on the real kernel (B6, no mocks): the kernel activates sqlite from its
//! /etc/services.d fragment, and luau reaches it over sys.svc.

use crate::boot_atlas;

/// Warm connection + typed rows + parameterized writes: open, create, two parameterized inserts, a
/// parameterized ordered query (typed values back), and a scalar count — all over one warm session.
#[test]
fn sqlite_library_warm_typed_and_params() {
    let mut s = boot_atlas();
    s.host
        .write_file(
            "/tmp/t.luau",
            br#"local sqlite = require("sqlite")
local db = assert(sqlite.open("/tmp/app.db"))
db:exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
db:exec("INSERT INTO users (name, age) VALUES (?, ?)", "alice", 30)
db:exec("INSERT INTO users (name, age) VALUES (?, ?)", "bob", 25)
local rows = db:query("SELECT name, age FROM users WHERE age > ? ORDER BY age", 20)
print(#rows, rows[1].name, rows[1].age, rows[2].name, rows[2].age)
print(db:queryvalue("SELECT count(*) FROM users"))
db:close()
"#,
        )
        .expect("write t.luau");
    assert_eq!(
        s.run_for_output("luau /tmp/t.luau"),
        "2\tbob\t25\talice\t30\r\n2\r\n"
    );
}

/// Async result streaming (codex #3 + the non-blocking serve loop): a wide 3000-row SELECT (~210 KiB) far
/// exceeds the kernel's 64 KiB high-water, so the service streams it in chunks — producing until the
/// buffer fills (`respond` → EAGAIN), then resuming on the `DrainReady` the kernel delivers as the client
/// drains, NEVER blocking the single-threaded serve loop on one client. The library reassembles the
/// stream whole and in order: 3000 rows, first n=1, last n=3000, the wide TEXT column intact (60 chars).
#[test]
fn sqlite_streams_a_large_query_result() {
    let mut s = boot_atlas();
    s.host
        .write_file(
            "/tmp/big.luau",
            br#"local sqlite = require("sqlite")
local db = assert(sqlite.open("/tmp/big.db"))
db:exec("CREATE TABLE t (n INTEGER, pad TEXT)")
db:exec("WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n < 3000) INSERT INTO t SELECT n, printf('%060d', n) FROM r")
local rows = db:query("SELECT n, pad FROM t")
print(#rows, rows[1].n, rows[#rows].n, #rows[#rows].pad)
db:close()
"#,
        )
        .expect("write big.luau");
    assert_eq!(
        s.run_for_output("luau /tmp/big.luau"),
        "3000\t1\t3000\t60\r\n"
    );
}

/// `db:transaction` is atomic: the committing transaction adds two rows; the erroring one rolls back
/// (its insert is undone) and re-raises (the outer pcall catches it).
#[test]
fn sqlite_transaction_commits_and_rolls_back() {
    let mut s = boot_atlas();
    s.host
        .write_file(
            "/tmp/tx.luau",
            br#"local sqlite = require("sqlite")
local db = assert(sqlite.open("/tmp/tx.db"))
db:exec("CREATE TABLE t (n INTEGER)")
db:transaction(function(tx)
  tx:exec("INSERT INTO t VALUES (1)")
  tx:exec("INSERT INTO t VALUES (2)")
end)
local ok = pcall(function()
  db:transaction(function(tx)
    tx:exec("INSERT INTO t VALUES (3)")
    error("boom")
  end)
end)
print(tostring(ok), db:queryvalue("SELECT count(*) FROM t"))
db:close()
"#,
        )
        .expect("write tx.luau");
    // pcall caught the re-raised error (false); only the committed 2 rows survive (the 3 rolled back).
    assert_eq!(s.run_for_output("luau /tmp/tx.luau"), "false\t2\r\n");
}

/// The headline: query sqlite → write xlsx in ONE script. Values flow from the database straight into
/// a real workbook — no shell-out, no text re-parsing. The produced .xlsx is a real zip on disk.
#[test]
fn sqlite_composes_with_xlsx() {
    let mut s = boot_atlas();
    s.host
        .write_file(
            "/tmp/c.luau",
            br#"local sqlite, xlsx = require("sqlite"), require("xlsx")
local db = assert(sqlite.open("/tmp/sales.db"))
db:exec("CREATE TABLE sales (month TEXT, revenue INTEGER)")
db:exec("INSERT INTO sales VALUES ('Jan', 120), ('Feb', 140)")
local wb = xlsx.new()
local ws = wb:addWorksheet("Q1")
for _, r in ipairs(db:query("SELECT month, revenue FROM sales ORDER BY month")) do
  ws:addRow({ r.month, r.revenue })
end
assert(wb:save("/tmp/q1.xlsx"))
print("ok " .. tostring(db:queryvalue("SELECT count(*) FROM sales")))
db:close()
"#,
        )
        .expect("write c.luau");
    assert_eq!(s.run_for_output("luau /tmp/c.luau"), "ok 2\r\n");
    // The workbook is real, not just claimed — a non-trivial OOXML zip (PK magic).
    let bytes = s.host.read_file("/tmp/q1.xlsx").expect("xlsx written");
    assert!(
        bytes.len() > 100,
        "xlsx should be a real workbook, got {} bytes",
        bytes.len()
    );
    assert_eq!(&bytes[..2], b"PK", "xlsx must be a zip (PK magic)");
}

/// `/svc` reflects LAZY activation: sqlite is absent from the listing until a client connects, then
/// present — and it stays (the warm service outlives the client that triggered it).
#[test]
fn sqlite_appears_in_svc_only_after_first_use() {
    let mut s = boot_atlas();
    assert_eq!(
        s.run_for_output("ls /svc"),
        "",
        "sqlite is lazy — nothing is registered until it is used"
    );
    s.host
        .write_file(
            "/tmp/touch.luau",
            br#"local db = assert(require("sqlite").open("/tmp/x.db")); db:close()"#,
        )
        .expect("write touch.luau");
    let _ = s.run_for_output("luau /tmp/touch.luau");
    assert_eq!(
        s.run_for_output("ls /svc"),
        "sqlite\r\n",
        "now a live, listed service"
    );
}

/// Prepared statements (compiled once, bound + run many) and a STREAMING cursor (rows pulled a page
/// at a time via a lazy iterator). The prepared `find` is re-run with different params; the cursor
/// sums all 100 rows across multiple 64-row pages.
#[test]
fn sqlite_prepared_statements_and_streaming_cursor() {
    let mut s = boot_atlas();
    s.host
        .write_file(
            "/tmp/p.luau",
            br#"local sqlite = require("sqlite")
local db = assert(sqlite.open("/tmp/p.db"))
db:exec("CREATE TABLE n (v INTEGER)")
local ins = db:prepare("INSERT INTO n (v) VALUES (?)")
for i = 1, 100 do ins:run(i) end
ins:close()
local find = db:prepare("SELECT v FROM n WHERE v > ? ORDER BY v")
print(#find:query(95), find:queryone(98).v)  -- re-run the warm statement with different params
find:close()
local sum, count = 0, 0
for row in db:rows("SELECT v FROM n ORDER BY v") do  -- streaming cursor over 100 rows (pages of 64)
  sum, count = sum + row.v, count + 1
end
print(count, sum)
db:close()
"#,
        )
        .expect("write p.luau");
    // find:query(95) → {96..100} = 5 rows; queryone(98).v → 99. Cursor: 100 rows, sum(1..100) = 5050.
    assert_eq!(
        s.run_for_output("luau /tmp/p.luau"),
        "5\t99\r\n100\t5050\r\n"
    );
}

/// BLOBs round-trip as RAW BYTES, not corrupted by JSON text encoding: a non-UTF-8 blob (NUL, 0xFF,
/// 0x80) bound via `sqlite.blob()` reads back byte-identical — the wire carries a tagged hex object,
/// not an escaped JSON string.
#[test]
fn sqlite_blobs_round_trip_as_binary() {
    let mut s = boot_atlas();
    s.host
        .write_file(
            "/tmp/b.luau",
            br#"local sqlite = require("sqlite")
local db = assert(sqlite.open("/tmp/b.db"))
db:exec("CREATE TABLE b (k TEXT, v BLOB)")
local raw = string.char(0, 255, 128, 10, 0, 200)  -- non-UTF-8 bytes, incl. NUL
db:exec("INSERT INTO b (k, v) VALUES (?, ?)", "x", sqlite.blob(raw))
local got = db:queryone("SELECT v FROM b WHERE k = ?", "x").v
print(#got, tostring(got == raw), string.byte(got, 2), string.byte(got, 3))
db:close()
"#,
        )
        .expect("write b.luau");
    // 6 bytes, byte-identical (got == raw), byte[2] = 255, byte[3] = 128.
    assert_eq!(
        s.run_for_output("luau /tmp/b.luau"),
        "6\ttrue\t255\t128\r\n"
    );
}

/// `vann` vector indexes are exposed through the Luau sqlite library: agents can create a typed
/// vector table, bind tagged vector BLOBs, combine KNN with partition/metadata filters, and get typed
/// rows back with exact distances ordered by nearest neighbour.
#[test]
fn sqlite_vector_index_luau_api_searches_and_filters() {
    let mut s = boot_atlas();
    s.host
        .write_file(
            "/tmp/vec.luau",
            br#"local sqlite = require("sqlite")
local db = assert(sqlite.open("/tmp/vec.db"))
db:createVectorIndex("mem", {
  vector = { name = "embedding", type = "float", dims = 3, metric = "l2" },
  partitions = { "tenant" },
  metadata = { { name = "source", type = "text" }, { name = "created", type = "integer" } },
  aux = { "title" },
  M = 4,
  ef_construction = 16,
  ef_search = 16,
})
db:exec("INSERT INTO mem(rowid, embedding, tenant, source, created, title) VALUES (?, ?, ?, ?, ?, ?)", 1, sqlite.vec.f32({0, 0, 0}), "a", "docs", 10, "origin")
db:exec("INSERT INTO mem(rowid, embedding, tenant, source, created, title) VALUES (?, ?, ?, ?, ?, ?)", 2, sqlite.vec.f32({1, 0, 0}), "a", "docs", 20, "unit-x")
db:exec("INSERT INTO mem(rowid, embedding, tenant, source, created, title) VALUES (?, ?, ?, ?, ?, ?)", 3, sqlite.vec.f32({0, 0, 1}), "a", "notes", 30, "unit-z")
db:exec("INSERT INTO mem(rowid, embedding, tenant, source, created, title) VALUES (?, ?, ?, ?, ?, ?)", 4, sqlite.vec.f32({0, 1, 0}), "b", "docs", 40, "beta")
local rows = db:vectorSearch("mem", {0.05, 0, 0}, {
  vector = "embedding",
  type = "f32",
  k = 2,
  partition = { tenant = "a" },
  filter = { source = "docs" },
})
print(#rows, rows[1].rowid, rows[1].title, rows[2].rowid)
print(tostring(rows[1].distance <= rows[2].distance), math.floor(rows[1].distance * 1000 + 0.5))
local all = db:vectorSearch("mem", sqlite.vec.f32({0, 1, 0}), {
  vector = "embedding",
  k = 3,
  filter = { source = "docs" },
})
print(#all, all[1].rowid, all[1].title)
local recent = db:vectorSearch("mem", sqlite.vec.f32({0, 1, 0}), {
  vector = "embedding",
  k = 3,
  filter = { source = "docs" },
  filters = { { "created", ">=", 30 } },
})
print(#recent, recent[1].rowid, recent[1].title)
db:exec("DELETE FROM mem WHERE rowid = ?", 1)
local after = db:vectorSearch("mem", {0.05, 0, 0}, {
  vector = "embedding",
  type = "f32",
  k = 2,
  partition = { tenant = "a" },
  filter = { source = "docs" },
})
print(#after, after[1].rowid)
db:exec("BEGIN")
db:exec("INSERT INTO mem(rowid, embedding, tenant, source, created, title) VALUES (?, ?, ?, ?, ?, ?)", 5, sqlite.vec.f32({0, 0, 0}), "a", "docs", 50, "rolled-back")
db:exec("ROLLBACK")
local rolled = db:vectorSearch("mem", {0, 0, 0}, {
  vector = "embedding",
  type = "f32",
  k = 2,
  partition = { tenant = "a" },
  filter = { source = "docs" },
})
print(#rolled, rolled[1].rowid)
db:exec("SAVEPOINT vec_sp")
db:exec("INSERT INTO mem(rowid, embedding, tenant, source, created, title) VALUES (?, ?, ?, ?, ?, ?)", 6, sqlite.vec.f32({0, 0, 0}), "a", "docs", 60, "savepoint")
db:exec("ROLLBACK TO vec_sp")
db:exec("RELEASE vec_sp")
local saved = db:vectorSearch("mem", {0, 0, 0}, {
  vector = "embedding",
  type = "f32",
  k = 2,
  partition = { tenant = "a" },
  filter = { source = "docs" },
})
print(#saved, saved[1].rowid)
local bad_update = pcall(function()
  db:exec("UPDATE mem SET embedding = ? WHERE rowid = ?", sqlite.vec.f32({1, 2}), 2)
end)
local still = db:vectorSearch("mem", {1, 0, 0}, {
  vector = "embedding",
  type = "f32",
  k = 1,
  partition = { tenant = "a" },
  filter = { source = "docs" },
})
print(tostring(bad_update), still[1].rowid)
local info = db:vectorInfo("mem")
local health = db:vectorHealth("mem")
local quant = db:vectorQuantization("mem")
print(info.dims, info.metadata_index_rows, info.resident_bytes > 0, info.hot_payload_bytes >= info.resident_bytes, info.cold_vector_bytes > 0, health.status, quant.metric)
print(info.partition_count, info.metadata_columns, info.metadata_index_rows == info.metadata_index_expected_rows, tostring(info.metadata_index_healthy), info.metadata_prefilter_min_ids <= info.metadata_prefilter_max_ids, health.graph_quality >= 0 and health.graph_quality <= 1, health.low_degree_ratio >= 0, health.recall_sample_size >= 0, health.recall_at_1_estimate >= 0 and health.recall_at_1_estimate <= 1, tostring(health.metadata_index_healthy))
db:createVectorIndex("graph", {
  vector = { name = "embedding", type = "float", dims = 2, metric = "l2" },
  M = 4,
  ef_construction = 24,
  ef_search = 24,
})
for i = 1, 24 do
  db:exec("INSERT INTO graph(rowid, embedding) VALUES (?, ?)", i, sqlite.vec.f32({i, 0}))
end
local graph = db:vectorSearch("graph", {20.2, 0}, {
  vector = "embedding",
  type = "f32",
  k = 3,
})
print(#graph, graph[1].rowid, graph[2].rowid, graph[3].rowid)
db:close()
"#,
        )
        .expect("write vec.luau");
    assert_eq!(
        s.run_for_output("luau /tmp/vec.luau"),
        "2\t1\torigin\t2\r\ntrue\t3\r\n3\t4\tbeta\r\n1\t4\tbeta\r\n1\t2\r\n1\t2\r\n1\t2\r\nfalse\t2\r\n3\t6\ttrue\ttrue\ttrue\tok\tl2\r\n2\t2\ttrue\ttrue\ttrue\ttrue\ttrue\ttrue\ttrue\ttrue\r\n3\t20\t21\t19\r\n"
    );
}

#[test]
fn sqlite_vector_low_selectivity_metadata_filter_streams_exact() {
    let mut s = boot_atlas();
    s.host
        .write_file(
            "/tmp/selectivity.luau",
            br#"local sqlite = require("sqlite")
local db = assert(sqlite.open("/tmp/selectivity.db"))
db:createVectorIndex("sel", {
  vector = { name = "embedding", type = "float", dims = 2, metric = "l2" },
  metadata = { { name = "tag", type = "text" } },
  aux = { "label" },
  M = 4,
  ef_construction = 24,
  ef_search = 16,
})
for i = 1, 300 do
  db:exec("INSERT INTO sel(rowid, embedding, tag, label) VALUES (?, ?, ?, ?)", i, sqlite.vec.f32({i, 0}), "bulk", "r" .. tostring(i))
end
local info = db:vectorInfo("sel")
local health = db:vectorHealth("sel")
local hits = db:vectorSearch("sel", {299.1, 0}, {
  vector = "embedding",
  type = "f32",
  k = 3,
  filter = { tag = "bulk" },
})
print(info.metadata_index_healthy, info.metadata_index_rows == 300, info.metadata_prefilter_min_ids, info.metadata_prefilter_max_ids, health.metadata_index_healthy, health.recall_sample_size > 0, health.recall_at_1_estimate >= 0 and health.recall_at_1_estimate <= 1)
print(#hits, hits[1].rowid, hits[2].rowid, hits[3].rowid)
db:close()
"#,
        )
        .expect("write selectivity.luau");
    assert_eq!(
        s.run_for_output("luau /tmp/selectivity.luau"),
        "true\ttrue\t256\t4096\ttrue\ttrue\ttrue\r\n3\t299\t300\t298\r\n"
    );
}

/// Direct SQL can use the same module without the wrapper: VEC-style `tenant partition` declarations,
/// `vec_f32('[...]')` scalar constructors, hidden `k`, and metadata/partition filters all go through
/// the virtual table planner.
#[test]
fn sqlite_vector_index_raw_sql_uses_vann_module() {
    let mut s = boot_atlas();
    s.host
        .write_file(
            "/tmp/rawvec.sql",
            b"CREATE VIRTUAL TABLE raw USING vann(embedding float[2] metric=l2, tenant partition, label text aux, M=4, ef_construction=16);\n\
INSERT INTO raw(rowid, embedding, tenant, label) VALUES (10, vec_f32('[0,0]'), 'a', 'zero');\n\
INSERT INTO raw(rowid, embedding, tenant, label) VALUES (11, vec_f32('[1,0]'), 'a', 'one');\n\
INSERT INTO raw(rowid, embedding, tenant, label) VALUES (12, vec_f32('[0,1]'), 'b', 'other');\n\
SELECT rowid, label, printf('%.2f', distance) FROM raw WHERE embedding MATCH vec_f32('[0.1,0]') AND k = 2 AND tenant = 'a';\n\
SELECT rowid FROM raw WHERE embedding MATCH vec_f32('[0.1,0]') AND k = 2 AND tenant = 'a' ORDER BY rowid DESC;\n\
SELECT instr(vann_info('raw'), '\"dims\":2') > 0;\n\
SELECT instr(vann_health('raw'), '\"status\":\"ok\"') > 0;\n\
CREATE VIRTUAL TABLE bits USING vann(embedding bit[3], label text aux, M=4, ef_construction=16);\n\
INSERT INTO bits(rowid, embedding, label) VALUES (21, vec_bit('101'), 'one');\n\
INSERT INTO bits(rowid, embedding, label) VALUES (22, vec_bit('001'), 'two');\n\
SELECT rowid, label, printf('%.0f', distance) FROM bits WHERE embedding MATCH vec_bit('100') AND k = 2;\n\
SELECT instr(vann_quantization('bits'), 'packed-bit-hamming') > 0;\n",
        )
        .expect("write rawvec.sql");
    assert_eq!(
        s.run_for_output("cat /tmp/rawvec.sql | sqlite /tmp/rawvec.db"),
        "10|zero|0.01\r\n11|one|0.81\r\n11\r\n10\r\n1\r\n1\r\n21|one|1\r\n22|two|2\r\n1\r\n"
    );
}

#[test]
fn sqlite_vector_updates_metadata_without_reembedding() {
    let mut s = boot_atlas();
    s.host
        .write_file(
            "/tmp/updatevec.sql",
            b"CREATE VIRTUAL TABLE upd USING vann(embedding float[2] metric=l2, tenant partition, source text, title text aux, M=4, ef_construction=16);\n\
INSERT INTO upd(rowid, embedding, tenant, source, title) VALUES (1, vec_f32('[0,0]'), 'a', 'docs', 'one');\n\
INSERT INTO upd(rowid, embedding, tenant, source, title) VALUES (2, vec_f32('[1,0]'), 'a', 'docs', 'two');\n\
UPDATE upd SET source='web', title='two-web' WHERE rowid=2;\n\
SELECT rowid, title, source FROM upd WHERE embedding MATCH vec_f32('[1,0]') AND k = 1 AND source = 'web';\n\
SELECT count(*) FROM upd WHERE source = 'docs';\n\
UPDATE upd SET tenant='b' WHERE rowid=2;\n\
SELECT rowid, title FROM upd WHERE embedding MATCH vec_f32('[1,0]') AND k = 2 AND tenant = 'a';\n\
SELECT rowid, title FROM upd WHERE embedding MATCH vec_f32('[1,0]') AND k = 1 AND tenant = 'b';\n",
        )
        .expect("write updatevec.sql");
    assert_eq!(
        s.run_for_output("cat /tmp/updatevec.sql | sqlite /tmp/updatevec.db"),
        "2|two-web|web\r\n1\r\n1|one\r\n2|two-web\r\n"
    );
}

#[test]
fn sqlite_vector_rejects_invalid_declarations_and_vectors() {
    let mut s = boot_atlas();
    s.host
        .write_file(
            "/tmp/badvec.luau",
            br#"
local sqlite = require("sqlite")
local db = assert(sqlite.open("/tmp/badvec.db"))
local bad_dims = pcall(function()
  db:exec("CREATE VIRTUAL TABLE bad_dims USING vann(embedding float[0])")
end)
local bad_m = pcall(function()
  db:exec("CREATE VIRTUAL TABLE bad_m USING vann(embedding float[2], M=0)")
end)
local bad_ef = pcall(function()
  db:exec("CREATE VIRTUAL TABLE bad_ef USING vann(embedding float[2], ef_search=0)")
end)
local bad_option = pcall(function()
  db:exec("CREATE VIRTUAL TABLE bad_option USING vann(embedding float[2], surprise=1)")
end)
db:createVectorIndex("good", {
  vector = { name = "embedding", type = "float", dims = 2, metric = "cosine" },
})
local bad_nan = pcall(function()
  db:exec("INSERT INTO good(rowid, embedding) VALUES (1, vec_f32('[nan,1]'))")
end)
local bad_zero = pcall(function()
  db:exec("INSERT INTO good(rowid, embedding) VALUES (2, vec_f32('[0,0]'))")
end)
print(tostring(bad_dims), tostring(bad_m), tostring(bad_ef), tostring(bad_option), tostring(bad_nan), tostring(bad_zero))
db:close()
"#,
        )
        .expect("write badvec.luau");
    assert_eq!(
        s.run_for_output("luau /tmp/badvec.luau"),
        "false\tfalse\tfalse\tfalse\tfalse\tfalse\r\n"
    );
}

#[test]
fn sqlite_vector_cosine_cold_start_fetches_full_vectors_from_shadow_table() {
    let mut s = boot_atlas();
    assert_eq!(
        s.run_for_output("sqlite /tmp/coldvec.db \"CREATE VIRTUAL TABLE cold USING vann(embedding float[3] metric=cosine, label text aux, M=4, ef_construction=16); INSERT INTO cold(rowid, embedding, label) VALUES (31, vec_f32('[1,0,0]'), 'x'); INSERT INTO cold(rowid, embedding, label) VALUES (32, vec_f32('[0,1,0]'), 'y'); SELECT instr(vann_quantization('cold'), 'cold-f32-rescore') > 0\""),
        "1\r\n"
    );
    assert_eq!(
        s.run_for_output("sqlite /tmp/coldvec.db \"SELECT rowid, length(embedding), label, printf('%.2f', distance) FROM cold WHERE embedding MATCH vec_f32('[1,0,0]') AND k = 2; SELECT instr(vann_quantization('cold'), 'cold-f32-rescore') > 0\""),
        "31|17|x|0.00\r\n32|17|y|1.00\r\n1\r\n"
    );
    assert_eq!(
        s.run_for_output("sqlite /tmp/coldl2.db \"CREATE VIRTUAL TABLE cold USING vann(embedding float[2] metric=l2, label text aux, M=4, ef_construction=16); INSERT INTO cold(rowid, embedding, label) VALUES (41, vec_f32('[0,0]'), 'a'); INSERT INTO cold(rowid, embedding, label) VALUES (42, vec_f32('[2,0]'), 'b'); SELECT instr(vann_quantization('cold'), 'scaled-int8-l2-traversal-cold-f32-rescore') > 0\""),
        "1\r\n"
    );
    assert_eq!(
        s.run_for_output("sqlite /tmp/coldl2.db \"SELECT rowid, length(embedding), label, printf('%.2f', distance) FROM cold WHERE embedding MATCH vec_f32('[1.9,0]') AND k = 2; SELECT instr(vann_quantization('cold'), 'scaled-int8-l2-traversal-cold-f32-rescore') > 0\""),
        "42|13|b|0.01\r\n41|13|a|3.61\r\n1\r\n"
    );
}

#[test]
fn sqlite_vector_cache_cap_faults_nodes_after_cold_reopen() {
    let mut s = boot_atlas();
    s.host
        .write_file(
            "/tmp/cachevec.sql",
            b"CREATE VIRTUAL TABLE spill USING vann(embedding float[2] metric=l2, tag text, label text aux, M=4, ef_construction=24, ef_search=24, cache_nodes=2);\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (1, vec_f32('[0,0]'), 'keep', 'p1');\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (2, vec_f32('[1,0]'), 'keep', 'p2');\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (3, vec_f32('[2,0]'), 'keep', 'p3');\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (4, vec_f32('[3,0]'), 'keep', 'p4');\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (5, vec_f32('[4,0]'), 'keep', 'p5');\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (6, vec_f32('[5,0]'), 'keep', 'p6');\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (7, vec_f32('[6,0]'), 'keep', 'p7');\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (8, vec_f32('[7,0]'), 'keep', 'p8');\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (9, vec_f32('[8,0]'), 'keep', 'p9');\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (10, vec_f32('[9,0]'), 'keep', 'p10');\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (11, vec_f32('[10,0]'), 'keep', 'p11');\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (12, vec_f32('[11,0]'), 'keep', 'p12');\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (13, vec_f32('[12,0]'), 'keep', 'p13');\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (14, vec_f32('[13,0]'), 'keep', 'p14');\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (15, vec_f32('[14,0]'), 'keep', 'p15');\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (16, vec_f32('[15,0]'), 'keep', 'p16');\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (17, vec_f32('[16,0]'), 'keep', 'p17');\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (18, vec_f32('[17,0]'), 'keep', 'p18');\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (19, vec_f32('[18,0]'), 'keep', 'p19');\n\
INSERT INTO spill(rowid, embedding, tag, label) VALUES (20, vec_f32('[19,0]'), 'keep', 'p20');\n\
SELECT instr(vann_info('spill'), '\"cache_nodes\":2') > 0, instr(vann_info('spill'), '\"resident_nodes\":2') > 0, instr(vann_info('spill'), '\"hot_payload_bytes\"') > 0;\n",
        )
        .expect("write cachevec.sql");
    assert_eq!(
        s.run_for_output("cat /tmp/cachevec.sql | sqlite /tmp/cachevec.db"),
        "1|1|1\r\n"
    );
    assert_eq!(
        s.run_for_output("sqlite /tmp/cachevec.db \"SELECT count(*), min(rowid), max(rowid) FROM spill WHERE tag = 'keep'; SELECT rowid, label, length(embedding) FROM spill WHERE rowid = 20\""),
        "20|1|20\r\n20|p20|13\r\n"
    );
    assert_eq!(
        s.run_for_output("sqlite /tmp/cachevec.db \"SELECT rowid, label, printf('%.2f', distance) FROM spill WHERE embedding MATCH vec_f32('[19.2,0]') AND k = 1 AND ef = 64\""),
        "20|p20|0.04\r\n"
    );
    assert_eq!(
        s.run_for_output("sqlite /tmp/cachevec.db \"SELECT rowid, label, printf('%.2f', distance) FROM spill WHERE embedding MATCH vec_f32('[19.2,0]') AND k = 1 AND tag = 'keep'\""),
        "20|p20|0.04\r\n"
    );
}

#[test]
fn sqlite_vector_reuses_deleted_internal_ids_after_cold_start() {
    let mut s = boot_atlas();
    assert_eq!(
        s.run_for_output("sqlite /tmp/reusevec.db \"CREATE VIRTUAL TABLE reuse USING vann(embedding float[2] metric=l2, label text aux, M=4, ef_construction=16); INSERT INTO reuse(rowid, embedding, label) VALUES (1, vec_f32('[0,0]'), 'a'); INSERT INTO reuse(rowid, embedding, label) VALUES (2, vec_f32('[1,0]'), 'b'); INSERT INTO reuse(rowid, embedding, label) VALUES (3, vec_f32('[2,0]'), 'c'); DELETE FROM reuse WHERE rowid = 2; SELECT instr(vann_info('reuse'), char(34) || 'free_slots' || char(34) || ':1') > 0\""),
        "1\r\n"
    );
    assert_eq!(
        s.run_for_output("sqlite /tmp/reusevec.db \"INSERT INTO reuse(rowid, embedding, label) VALUES (4, vec_f32('[3,0]'), 'd'); SELECT instr(vann_info('reuse'), char(34) || 'max_id' || char(34) || ':2') > 0, instr(vann_info('reuse'), char(34) || 'free_slots' || char(34) || ':0') > 0; SELECT rowid FROM reuse WHERE embedding MATCH vec_f32('[3,0]') AND k = 1\""),
        "1|1\r\n4\r\n"
    );
}

#[test]
fn sqlite_vector_savepoint_rollback_restores_hot_graph_state() {
    let mut s = boot_atlas();
    s.host
        .write_file(
            "/tmp/undo_vec.luau",
            br#"local sqlite = require("sqlite")
local db = assert(sqlite.open("/tmp/undovec.db"))
db:createVectorIndex("undo", {
  vector = { name = "embedding", type = "float", dims = 2, metric = "l2" },
  aux = { "label" },
  M = 4,
  ef_construction = 16,
})
db:exec("INSERT INTO undo(rowid, embedding, label) VALUES (?, ?, ?)", 1, sqlite.vec.f32({1, 0}), "one")
db:exec("INSERT INTO undo(rowid, embedding, label) VALUES (?, ?, ?)", 2, sqlite.vec.f32({2, 0}), "two")
db:exec("BEGIN")
db:exec("DELETE FROM undo WHERE rowid = ?", 1)
db:exec("INSERT INTO undo(rowid, embedding, label) VALUES (?, ?, ?)", 3, sqlite.vec.f32({3, 0}), "three")
db:exec("SAVEPOINT vec_undo")
db:exec("DELETE FROM undo WHERE rowid = ?", 3)
db:exec("INSERT INTO undo(rowid, embedding, label) VALUES (?, ?, ?)", 4, sqlite.vec.f32({4, 0}), "four")
local mid = db:vectorSearch("undo", {4, 0}, { vector = "embedding", type = "f32", k = 1 })[1]
db:exec("ROLLBACK TO vec_undo")
local rolled = db:vectorSearch("undo", {3, 0}, { vector = "embedding", type = "f32", k = 2 })
db:exec("RELEASE vec_undo")
db:exec("COMMIT")
local final = db:vectorSearch("undo", {3, 0}, { vector = "embedding", type = "f32", k = 2 })
local info = db:vectorInfo("undo")
print(mid.rowid, rolled[1].rowid, rolled[1].label, rolled[2].rowid, final[1].rowid, info.live, info.free_slots)
db:close()
"#,
        )
        .expect("write undo_vec.luau");
    assert_eq!(
        s.run_for_output("luau /tmp/undo_vec.luau"),
        "4\t3\tthree\t2\t3\t2\t0\r\n"
    );
}

#[test]
fn sqlite_vector_rebuild_repairs_degraded_shadow_graph() {
    let mut s = boot_atlas();
    s.host
        .write_file(
            "/tmp/rebuild.luau",
            br#"local sqlite = require("sqlite")
local db = assert(sqlite.open("/tmp/rebuildvec.db"))
db:createVectorIndex("repair", {
  vector = { name = "embedding", type = "float", dims = 2, metric = "l2" },
  metadata = { { name = "tag", type = "text" } },
  aux = { "label" },
  M = 4,
  ef_construction = 16,
})
for i = 1, 4 do
  local tag = if i == 4 then "keep" else "skip"
  db:exec("INSERT INTO repair(rowid, embedding, tag, label) VALUES (?, ?, ?, ?)", i, sqlite.vec.f32({i, 0}), tag, "n" .. tostring(i))
end
local before = db:vectorHealth("repair")
local node_shadow = assert(db:queryvalue("SELECT name FROM sqlite_schema WHERE name GLOB '_vann_repair*_node'"))
local idx_shadow = assert(db:queryvalue("SELECT name FROM sqlite_schema WHERE name GLOB '_vann_repair*_idx'"))
local empty_adj = string.char(1, 0, 0, 0, 0, 0, 0, 0)
db:exec('UPDATE "' .. node_shadow .. '" SET adj = ?', sqlite.blob(empty_adj))
db:exec('DELETE FROM "' .. idx_shadow .. '"')
local broken = db:vectorHealth("repair")
local stale_hit = db:vectorSearch("repair", {4, 0}, { vector = "embedding", type = "f32", k = 1, filter = { tag = "keep" } })[1]
local stale_info = db:vectorInfo("repair")
local rebuilt = db:vectorRebuild("repair")
local after = db:vectorHealth("repair")
local info = db:vectorInfo("repair")
local hit = db:vectorSearch("repair", {4, 0}, { vector = "embedding", type = "f32", k = 1, filter = { tag = "keep" } })[1]
print(before.orphan_nodes, broken.orphan_nodes, stale_hit.rowid, stale_info.metadata_index_rows, rebuilt.rebuild, rebuilt.nodes, after.orphan_nodes, info.metadata_index_rows, hit.rowid)
db:close()
"#,
        )
        .expect("write rebuild.luau");
    assert_eq!(
        s.run_for_output("luau /tmp/rebuild.luau"),
        "0\t4\t4\t0\tok\t4\t0\t4\t4\r\n"
    );
}

/// The CLI face (#10): `$ sqlite <db> <sql>` is a thin svc_connect/svc_call client of the SAME warm
/// service the library drives — "three faces, one core" (SYSTEMS.md), not "use the library".
/// Three separate processes share one warm instance; the table persists in the file across them, and a
/// The CLI is sqlite3-like: a multi-statement script runs each statement (the service splits on its own
/// boundary), CREATE/INSERT are silent, and a SELECT prints pipe-separated rows with NO header by
/// default (sqlite3's "list" mode).
#[test]
fn sqlite_cli_runs_sql_over_the_warm_service() {
    let mut s = boot_atlas();
    // One invocation, three statements: the two non-queries are silent; the SELECT prints | rows.
    assert_eq!(
        s.run_for_output("sqlite /tmp/cli.db \"CREATE TABLE t (n INTEGER, s TEXT); INSERT INTO t VALUES (1,'a'),(2,'b'); SELECT n,s FROM t ORDER BY n\""),
        "1|a\r\n2|b\r\n"
    );
    // The default output is list mode: | separator, no header.
    assert_eq!(
        s.run_for_output("sqlite /tmp/cli.db \"SELECT n, s FROM t ORDER BY n\""),
        "1|a\r\n2|b\r\n"
    );
}

/// The CLI is also a stdin REPL with sqlite3 dot-commands: piped statements run; `.headers on` adds a
/// header row; `.tables` lists user tables; `.mode csv` switches to comma-separated output. The
/// interactive face of "one binary, three modes" (SYSTEMS.md).
#[test]
fn sqlite_cli_repl_and_dot_commands() {
    let mut s = boot_atlas();
    let _ = s.run_for_output(
        "sqlite /tmp/r.db \"CREATE TABLE kv (k TEXT, v INTEGER); INSERT INTO kv VALUES ('x',1),('y',2)\"",
    );
    // A piped script: a dot-command turns on headers, then a query.
    s.host
        .write_file(
            "/tmp/q.sql",
            b".headers on\nSELECT k, v FROM kv ORDER BY k;\n",
        )
        .expect("write q.sql");
    assert_eq!(
        s.run_for_output("cat /tmp/q.sql | sqlite /tmp/r.db"),
        "k|v\r\nx|1\r\ny|2\r\n"
    );
    // .tables lists user tables.
    s.host
        .write_file("/tmp/t.sql", b".tables\n")
        .expect("write t.sql");
    assert_eq!(
        s.run_for_output("cat /tmp/t.sql | sqlite /tmp/r.db"),
        "kv\r\n"
    );
    // .mode csv switches the separator to a comma.
    s.host
        .write_file(
            "/tmp/c.sql",
            b".mode csv\nSELECT k, v FROM kv ORDER BY k;\n",
        )
        .expect("write c.sql");
    assert_eq!(
        s.run_for_output("cat /tmp/c.sql | sqlite /tmp/r.db"),
        "x,1\r\ny,2\r\n"
    );
}

/// Handle delegation (#2; SYSTEMS.md) + a real CSV parser (#4): `.import FILE TABLE` opens the CSV
/// and DELEGATES the handle to the service, which reads it straight from the handle — no path, no
/// namespace reach. The parser is RFC-4180, so a quoted field with an embedded comma stays ONE value
/// and a doubled "" unescapes to a literal quote — a naive comma/newline split would mangle both.
#[test]
fn sqlite_cli_imports_via_a_delegated_handle() {
    let mut s = boot_atlas();
    s.host
        .write_file(
            "/tmp/data.csv",
            b"1,alice,\"Smith, Bob\"\n2,bob,\"say \"\"hi\"\"\"\n",
        )
        .expect("write csv");
    let _ = s.run_for_output(
        "sqlite /tmp/imp.db \"CREATE TABLE people (id INTEGER, name TEXT, note TEXT)\"",
    );
    // .import is silent like sqlite3; the rows land via the delegated handle.
    assert_eq!(
        s.run_for_output("sqlite /tmp/imp.db \".import /tmp/data.csv people\""),
        ""
    );
    assert_eq!(
        s.run_for_output("sqlite /tmp/imp.db \"SELECT count(*) FROM people\""),
        "2\r\n"
    );
    // The quoted comma survived as ONE field; the "" unescaped to a literal quote.
    assert_eq!(
        s.run_for_output("sqlite /tmp/imp.db \"SELECT note FROM people WHERE id=1\""),
        "Smith, Bob\r\n"
    );
    assert_eq!(
        s.run_for_output("sqlite /tmp/imp.db \"SELECT note FROM people WHERE id=2\""),
        "say \"hi\"\r\n"
    );
}

/// Structured error codes (#9): a sqlite error surfaces its EXTENDED result code, not just a string —
/// a duplicate primary key raises a CONSTRAINT error the library reports with its `(sqlite code …)`.
#[test]
fn sqlite_reports_a_structured_error_code() {
    let mut s = boot_atlas();
    s.host
        .write_file(
            "/tmp/e.luau",
            br#"local sqlite = require("sqlite")
local db = assert(sqlite.open("/tmp/e.db"))
db:exec("CREATE TABLE u (id INTEGER PRIMARY KEY)")
db:exec("INSERT INTO u VALUES (1)")
local ok, err = pcall(function() db:exec("INSERT INTO u VALUES (1)") end)
print(tostring(ok), err)
db:close()
"#,
        )
        .expect("write e.luau");
    let out = s.run_for_output("luau /tmp/e.luau");
    assert!(
        out.contains("false"),
        "the pcall should catch the constraint error: {out}"
    );
    assert!(
        out.contains("sqlite code"),
        "the error must carry a structured code: {out}"
    );
}

/// Per-session cleanup on client death (#1): a client opens a db (a warm session) and DIES mid-session
/// without `db:close()`. The kernel delivers a session-closed tombstone so the service frees that
/// session's `sqlite3*` — and keeps serving: a second client opens the same db and reads the committed
/// data back. The service survives the abrupt death rather than leaking or wedging.
#[test]
fn sqlite_survives_a_client_dying_mid_session() {
    let mut s = boot_atlas();
    s.host
        .write_file(
            "/tmp/d.luau",
            br#"local sqlite = require("sqlite")
local db = assert(sqlite.open("/tmp/d.db"))
db:exec("CREATE TABLE t (n INTEGER)")
db:exec("INSERT INTO t VALUES (42)")
error("boom mid-session")
"#,
        )
        .expect("write d.luau");
    let _ = s.run_for_output("luau /tmp/d.luau"); // opens a session, then traps without closing it
    s.host
        .write_file(
            "/tmp/d2.luau",
            br#"local db = assert(require("sqlite").open("/tmp/d.db"))
print(db:queryvalue("SELECT n FROM t"))
db:close()
"#,
        )
        .expect("write d2.luau");
    assert_eq!(s.run_for_output("luau /tmp/d2.luau"), "42\r\n");
}
