//! sqlite resident-service e2e (Phase 6): the `require("sqlite")` library on the `atlas` flavor — a
//! warm connection, typed rows, parameterized writes, transactions, and the headline sqlite→xlsx
//! composition (values flowing across libraries, which the shell-out CLI can't do). All driven through
//! the real shell on the real kernel (B6, no mocks): the kernel activates the sqlite service from
//! /etc/services.json at boot, and luau reaches it over sys.svc.

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
    assert_eq!(s.run_for_output("luau /tmp/big.luau"), "3000\t1\t3000\t60\r\n");
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
    assert_eq!(s.run_for_output("ls /svc"), "sqlite\r\n", "now a live, listed service");
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
    assert_eq!(s.run_for_output("luau /tmp/p.luau"), "5\t99\r\n100\t5050\r\n");
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
    assert_eq!(s.run_for_output("luau /tmp/b.luau"), "6\ttrue\t255\t128\r\n");
}

/// The CLI face (#10): `$ sqlite <db> <sql>` is a thin svc_connect/svc_call client of the SAME warm
/// service the library drives — "three faces, one core" (SERVICES.md §3.3), not "use the library".
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
/// interactive face of "one binary, three modes" (SERVICES.md §3.3).
#[test]
fn sqlite_cli_repl_and_dot_commands() {
    let mut s = boot_atlas();
    let _ = s.run_for_output(
        "sqlite /tmp/r.db \"CREATE TABLE kv (k TEXT, v INTEGER); INSERT INTO kv VALUES ('x',1),('y',2)\"",
    );
    // A piped script: a dot-command turns on headers, then a query.
    s.host
        .write_file("/tmp/q.sql", b".headers on\nSELECT k, v FROM kv ORDER BY k;\n")
        .expect("write q.sql");
    assert_eq!(s.run_for_output("cat /tmp/q.sql | sqlite /tmp/r.db"), "k|v\r\nx|1\r\ny|2\r\n");
    // .tables lists user tables.
    s.host.write_file("/tmp/t.sql", b".tables\n").expect("write t.sql");
    assert_eq!(s.run_for_output("cat /tmp/t.sql | sqlite /tmp/r.db"), "kv\r\n");
    // .mode csv switches the separator to a comma.
    s.host
        .write_file("/tmp/c.sql", b".mode csv\nSELECT k, v FROM kv ORDER BY k;\n")
        .expect("write c.sql");
    assert_eq!(s.run_for_output("cat /tmp/c.sql | sqlite /tmp/r.db"), "x,1\r\ny,2\r\n");
}

/// Handle delegation (#2; SERVICES.md §3.4) + a real CSV parser (#4): `.import FILE TABLE` opens the CSV
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
    assert_eq!(s.run_for_output("sqlite /tmp/imp.db \".import /tmp/data.csv people\""), "");
    assert_eq!(s.run_for_output("sqlite /tmp/imp.db \"SELECT count(*) FROM people\""), "2\r\n");
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
    assert!(out.contains("false"), "the pcall should catch the constraint error: {out}");
    assert!(out.contains("sqlite code"), "the error must carry a structured code: {out}");
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
