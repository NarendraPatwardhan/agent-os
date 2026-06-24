//! sqlite glue — the resident SERVICE. One binary, two modes (VISION §4.5): spawned with the service
//! marker it runs the warm `svc_serve` loop over per-session `sqlite3*` handles; otherwise it is a
//! thin CLI client over that same service. The Luau library `require("sqlite")` is the default interface.
//!
//! Protocol (JSON both ways, the lib's `json` battery ↔ this loop): a request is
//!   {"op":"open","path":"…"} | {"op":"exec","sql":"…"} | {"op":"query","sql":"…","params":[…]} | {"op":"close"}
//! and a response is {"ok":true,…} or {"ok":false,"error":"…"}. exec → {changes,rowid}; query →
//! {cols:[…],rows:[[…]]} with values typed (INTEGER/REAL→number, TEXT→string, NULL→null, BLOB→string).
//! The DB file (e.g. /var/persist/app.db) is opened by sqlite's stock unix-dotfile VFS over WASI → the
//! wasi-adapter → mc — no custom VFS. SERVICES.md §6.2.

const std = @import("std");
const mc = @import("mc");
const svc = @import("svc");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const alloc = std.heap.c_allocator;
const SERVICE_MARKER = "--mc-serve";
const SERVICE_NAME = "sqlite";

// SQLITE_TRANSIENT (the `(sqlite3_destructor_type)-1` sentinel): tells sqlite to COPY the bound bytes,
// so a temporary buffer (a hex-decoded BLOB param) can be freed right after the bind. @cImport doesn't
// surface the cast macro, so reconstruct the all-ones pointer.
const SQLITE_TRANSIENT: c.sqlite3_destructor_type = @ptrFromInt(std.math.maxInt(usize));

/// Per-session warm state: the open DB handle PLUS the warm PREPARED STATEMENTS (compiled once, run
/// many) keyed by a per-session id. All in this guest's linear memory, so the connection, sqlite's
/// page cache, AND the compiled statements stay warm across calls (and ride a kernel snapshot).
const Session = struct {
    db: ?*c.sqlite3 = null,
    stmts: std.AutoHashMap(u32, *c.sqlite3_stmt),
    next_id: u32 = 1,

    fn create() ?*Session {
        const s = alloc.create(Session) catch return null;
        s.* = .{ .stmts = std.AutoHashMap(u32, *c.sqlite3_stmt).init(alloc) };
        return s;
    }
    /// Finalize every warm statement, close the DB, free the session — the teardown on `close` (and
    /// whenever the kernel evicts a dead client's session and re-`recv`s, the channel having closed).
    fn destroy(self: *Session) void {
        var it = self.stmts.valueIterator();
        while (it.next()) |st| _ = c.sqlite3_finalize(st.*);
        self.stmts.deinit();
        if (self.db) |db| _ = c.sqlite3_close(db);
        alloc.destroy(self);
    }
};

var sessions: std.AutoHashMap(u32, *Session) = undefined;

/// The session state for `id`, created on first use (the first op the kernel routes for a session).
fn sessionFor(id: u32) ?*Session {
    if (sessions.get(id)) |s| return s;
    const s = Session.create() orelse return null;
    sessions.put(id, s) catch {
        s.destroy();
        return null;
    };
    return s;
}

pub fn main() void {
    var argbuf: [4096]u8 = undefined;
    var alen: u32 = 0;
    _ = mc.mc_sys_args(mc.addr(&argbuf), argbuf.len, mc.addr(&alen));
    var it = std.mem.splitScalar(u8, argbuf[0..alen], 0);
    _ = it.next(); // argv[0]
    const arg1 = it.next() orelse "";
    if (std.mem.eql(u8, arg1, SERVICE_MARKER)) {
        serveLoop();
    } else {
        cli(argbuf[0..alen]);
    }
}

fn serveLoop() void {
    sessions = std.AutoHashMap(u32, *Session).init(alloc);
    // 1 MiB request body, plus the kernel's 14-byte svc envelope header.
    const reqbuf = alloc.alloc(u8, (1 << 20) + 14) catch {
        _ = mc.mc_sys_exit(1);
        return;
    };
    var server = svc.Server.serve(SERVICE_NAME, reqbuf) catch {
        _ = mc.mc_sys_exit(1);
        return;
    };
    // Serve typed calls against the warm per-session sqlite3* handles until the channel closes. A
    // session-closed tombstone frees that session's warm state (the open db + its prepared statements)
    // — the kernel can evict only its own per-session bookkeeping, never this guest's heap (codex #1).
    while (server.recv()) |req| {
        switch (req.kind) {
            .session_closed => {
                if (sessions.fetchRemove(req.session)) |kv| kv.value.destroy();
            },
            else => {
                defer closeDelegated(req.handles);
                var resp: std.ArrayList(u8) = .empty;
                defer resp.deinit(alloc);
                handle(req.session, req.blob, req.handles, &resp);
                server.respond(req, 0, resp.items);
            },
        }
    }
    _ = mc.mc_sys_exit(0); // channel closed — nothing more to serve
}

fn handle(session: u32, blob: []const u8, handles: []const u32, resp: *std.ArrayList(u8)) void {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, blob, .{}) catch {
        respondError(resp, "invalid request json");
        return;
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            respondError(resp, "request must be a json object");
            return;
        },
    };
    // Protocol version: the library and this service ship together, but a versioned envelope lets the
    // service reject an incompatible client cleanly instead of misreading it (codex #9).
    if (idOfI64(obj, "v") != 1) {
        respondError(resp, "unsupported protocol version (expected v=1)");
        return;
    }
    const op = getStr(obj, "op") orelse {
        respondError(resp, "missing op");
        return;
    };
    if (std.mem.eql(u8, op, "open")) {
        doOpen(session, obj, resp);
    } else if (std.mem.eql(u8, op, "exec")) {
        doExec(session, obj, resp);
    } else if (std.mem.eql(u8, op, "query")) {
        doQuery(session, obj, resp);
    } else if (std.mem.eql(u8, op, "prepare")) {
        doPrepare(session, obj, resp);
    } else if (std.mem.eql(u8, op, "step")) {
        doStep(session, obj, resp);
    } else if (std.mem.eql(u8, op, "finalize")) {
        doFinalize(session, obj, resp);
    } else if (std.mem.eql(u8, op, "import")) {
        doImport(session, obj, handles, resp);
    } else if (std.mem.eql(u8, op, "close")) {
        doClose(session, resp);
    } else {
        respondError(resp, "unknown op");
    }
}

fn closeDelegated(handles: []const u32) void {
    for (handles) |fd| {
        _ = mc.mc_sys_close(@intCast(fd));
    }
}

// ── op handlers ──────────────────────────────────────────────────────────────

fn doOpen(session: u32, obj: std.json.ObjectMap, resp: *std.ArrayList(u8)) void {
    const path = getStr(obj, "path") orelse {
        respondError(resp, "open: missing path");
        return;
    };
    const path_z = alloc.dupeZ(u8, path) catch {
        respondError(resp, "oom");
        return;
    };
    defer alloc.free(path_z);
    const s = sessionFor(session) orelse {
        respondError(resp, "oom");
        return;
    };
    // Re-open: finalize any warm statements (they reference the old db) and close the prior handle.
    if (s.db) |prev| {
        var it = s.stmts.valueIterator();
        while (it.next()) |st| _ = c.sqlite3_finalize(st.*);
        s.stmts.clearRetainingCapacity();
        _ = c.sqlite3_close(prev);
        s.db = null;
    }
    const readonly = if (getStr(obj, "mode")) |m| std.mem.eql(u8, m, "ro") else false;
    const flags: c_int = if (readonly)
        c.SQLITE_OPEN_READONLY
    else
        c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(path_z.ptr, &db, flags, null) != c.SQLITE_OK) {
        respondSqliteError(resp, db);
        _ = c.sqlite3_close(db);
        return;
    }
    s.db = db;
    respondOk(resp);
}

fn doExec(session: u32, obj: std.json.ObjectMap, resp: *std.ArrayList(u8)) void {
    const db = sessionDb(session) orelse {
        respondError(resp, "no open database (call open first)");
        return;
    };
    const sql = getStr(obj, "sql") orelse {
        respondError(resp, "exec: missing sql");
        return;
    };
    const sql_z = alloc.dupeZ(u8, sql) catch {
        respondError(resp, "oom");
        return;
    };
    defer alloc.free(sql_z);
    const has_params = blk: {
        const pv = obj.get("params") orelse break :blk false;
        break :blk switch (pv) {
            .array => |a| a.items.len > 0,
            else => false,
        };
    };
    if (has_params) {
        // Parameterized single statement: prepare + bind + step to completion.
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            respondSqliteError(resp, db);
            return;
        }
        if (stmt == null) {
            respondError(resp, "exec: empty statement");
            return;
        }
        defer _ = c.sqlite3_finalize(stmt);
        if (bindParams(obj, stmt)) |emsg| {
            respondError(resp, emsg);
            return;
        }
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc == c.SQLITE_ROW) continue; // exec discards any rows
            respondSqliteError(resp, db);
            return;
        }
    } else {
        // No params: sqlite3_exec runs one or more statements (migrations, pragmas).
        var errmsg: [*c]u8 = null;
        if (c.sqlite3_exec(db, sql_z.ptr, null, null, &errmsg) != c.SQLITE_OK) {
            respondSqliteError(resp, db);
            if (errmsg != null) c.sqlite3_free(errmsg);
            return;
        }
    }
    resp.appendSlice(alloc, "{\"v\":1,\"ok\":true,\"changes\":") catch return;
    writeI64(resp, c.sqlite3_changes(db));
    resp.appendSlice(alloc, ",\"rowid\":") catch return;
    writeI64(resp, c.sqlite3_last_insert_rowid(db));
    resp.append(alloc, '}') catch return;
}

fn doQuery(session: u32, obj: std.json.ObjectMap, resp: *std.ArrayList(u8)) void {
    const db = sessionDb(session) orelse {
        respondError(resp, "no open database (call open first)");
        return;
    };
    const sql = getStr(obj, "sql") orelse {
        respondError(resp, "query: missing sql");
        return;
    };
    const sql_z = alloc.dupeZ(u8, sql) catch {
        respondError(resp, "oom");
        return;
    };
    defer alloc.free(sql_z);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        respondSqliteError(resp, db);
        return;
    }
    if (stmt == null) {
        resp.appendSlice(alloc, "{\"v\":1,\"ok\":true,\"cols\":[],\"rows\":[]}") catch return;
        return;
    }
    defer _ = c.sqlite3_finalize(stmt);
    if (bindParams(obj, stmt)) |emsg| {
        respondError(resp, emsg);
        return;
    }

    resp.appendSlice(alloc, "{\"v\":1,\"ok\":true,\"cols\":[") catch return;
    const ncol = c.sqlite3_column_count(stmt);
    var ci: c_int = 0;
    while (ci < ncol) : (ci += 1) {
        if (ci > 0) resp.append(alloc, ',') catch return;
        writeJsonCStr(resp, c.sqlite3_column_name(stmt, ci));
    }
    resp.appendSlice(alloc, "],\"rows\":[") catch return;
    var first = true;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) {
            resp.clearRetainingCapacity();
            respondSqliteError(resp, db);
            return;
        }
        if (!first) resp.append(alloc, ',') catch return;
        first = false;
        resp.append(alloc, '[') catch return;
        ci = 0;
        while (ci < ncol) : (ci += 1) {
            if (ci > 0) resp.append(alloc, ',') catch return;
            writeCell(resp, stmt, ci);
        }
        resp.append(alloc, ']') catch return;
    }
    resp.appendSlice(alloc, "]}") catch return;
}

fn doClose(session: u32, resp: *std.ArrayList(u8)) void {
    if (sessions.fetchRemove(session)) |kv| {
        kv.value.destroy();
    }
    respondOk(resp);
}

// ── prepared statements + streaming cursors ────────────────────────────────────
//
// A prepared statement is a warm sqlite3_stmt* kept across calls and keyed by a per-session id;
// `prepare` compiles + stores it (returning the id + the result column names), `step` binds params
// (when given) and pulls up to `max` rows (max ≤ 0 = run to completion), `finalize` drops it. The
// same primitive backs BOTH a re-runnable prepared statement (the lib's `db:prepare` → run/query,
// always `max = 0`) and a streaming cursor (`db:rows`, `max = a page` until `done`).

fn doPrepare(session: u32, obj: std.json.ObjectMap, resp: *std.ArrayList(u8)) void {
    const s = sessions.get(session) orelse {
        respondError(resp, "no open database (call open first)");
        return;
    };
    const db = s.db orelse {
        respondError(resp, "no open database (call open first)");
        return;
    };
    const sql = getStr(obj, "sql") orelse {
        respondError(resp, "prepare: missing sql");
        return;
    };
    const sql_z = alloc.dupeZ(u8, sql) catch {
        respondError(resp, "oom");
        return;
    };
    defer alloc.free(sql_z);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        respondSqliteError(resp, db);
        return;
    }
    if (stmt == null) {
        respondError(resp, "prepare: empty statement");
        return;
    }
    const id = s.next_id;
    s.next_id += 1;
    s.stmts.put(id, stmt.?) catch {
        _ = c.sqlite3_finalize(stmt);
        respondError(resp, "oom");
        return;
    };
    resp.appendSlice(alloc, "{\"v\":1,\"ok\":true,\"id\":") catch return;
    writeI64(resp, @intCast(id));
    resp.appendSlice(alloc, ",\"cols\":[") catch return;
    const ncol = c.sqlite3_column_count(stmt);
    var ci: c_int = 0;
    while (ci < ncol) : (ci += 1) {
        if (ci > 0) resp.append(alloc, ',') catch return;
        writeJsonCStr(resp, c.sqlite3_column_name(stmt, ci));
    }
    resp.appendSlice(alloc, "]}") catch return;
}

fn doStep(session: u32, obj: std.json.ObjectMap, resp: *std.ArrayList(u8)) void {
    const s = sessions.get(session) orelse {
        respondError(resp, "step: no session");
        return;
    };
    const id = idOf(obj, "id") orelse {
        respondError(resp, "step: missing statement id");
        return;
    };
    const stmt = s.stmts.get(id) orelse {
        respondError(resp, "step: unknown statement");
        return;
    };
    // A fresh run: `params` present → reset + re-bind. (A cursor continuation omits params.)
    if (obj.get("params") != null) {
        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);
        if (bindParams(obj, stmt)) |emsg| {
            respondError(resp, emsg);
            return;
        }
    }
    const max = idOfI64(obj, "max"); // ≤ 0 → step to completion
    const ncol = c.sqlite3_column_count(stmt);
    resp.appendSlice(alloc, "{\"v\":1,\"ok\":true,\"rows\":[") catch return;
    var done = false;
    var count: i64 = 0;
    var first = true;
    while (max <= 0 or count < max) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            if (!first) resp.append(alloc, ',') catch return;
            first = false;
            resp.append(alloc, '[') catch return;
            var ci: c_int = 0;
            while (ci < ncol) : (ci += 1) {
                if (ci > 0) resp.append(alloc, ',') catch return;
                writeCell(resp, stmt, ci);
            }
            resp.append(alloc, ']') catch return;
            count += 1;
        } else if (rc == c.SQLITE_DONE) {
            done = true;
            break;
        } else {
            // A step error (e.g. a constraint violation): discard the partial body, report it with
            // its structured sqlite code (respondSqliteError clears the partial body itself).
            respondSqliteError(resp, s.db);
            _ = c.sqlite3_reset(stmt);
            return;
        }
    }
    resp.appendSlice(alloc, "],\"done\":") catch return;
    resp.appendSlice(alloc, if (done) "true" else "false") catch return;
    resp.appendSlice(alloc, ",\"changes\":") catch return;
    writeI64(resp, if (s.db) |d| c.sqlite3_changes(d) else 0);
    resp.appendSlice(alloc, ",\"rowid\":") catch return;
    writeI64(resp, if (s.db) |d| c.sqlite3_last_insert_rowid(d) else 0);
    resp.append(alloc, '}') catch return;
    if (done) _ = c.sqlite3_reset(stmt); // ready to re-run with new params
}

fn doFinalize(session: u32, obj: std.json.ObjectMap, resp: *std.ArrayList(u8)) void {
    if (sessions.get(session)) |s| {
        if (idOf(obj, "id")) |id| {
            if (s.stmts.fetchRemove(id)) |kv| _ = c.sqlite3_finalize(kv.value);
        }
    }
    respondOk(resp); // idempotent — finalizing an unknown/already-gone statement is fine
}

/// `import`: bulk-load a CSV that the CLI DELEGATED as a handle (SERVICES.md §3.4). The service reads
/// the file straight from `handles[0]` — no path, no namespace, no ambient FS reach — and INSERTs each
/// comma-separated line into `table` (fields bound as text), atomically.
fn doImport(session: u32, obj: std.json.ObjectMap, handles: []const u32, resp: *std.ArrayList(u8)) void {
    const db = sessionDb(session) orelse {
        respondError(resp, "no open database (call open first)");
        return;
    };
    const table = getStr(obj, "table") orelse {
        respondError(resp, "import: missing table");
        return;
    };
    // The table name is interpolated into the INSERT (sqlite cannot bind an identifier), so confine it
    // to an identifier shape — no quotes, no semicolons — to keep it injection-safe.
    for (table) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') {
            respondError(resp, "import: table name must be alphanumeric");
            return;
        }
    }
    if (handles.len == 0) {
        respondError(resp, "import: no delegated input handle");
        return;
    }
    const fd: i32 = @intCast(handles[0]);
    // Slurp the CSV straight from the delegated handle.
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);
    var rbuf: [4096]u8 = undefined;
    while (true) {
        var n: u32 = 0;
        if (mc.mc_sys_read(fd, mc.addr(&rbuf), rbuf.len, mc.addr(&n)) != 0) {
            respondError(resp, "import: read from delegated handle failed");
            return;
        }
        if (n == 0) break;
        data.appendSlice(alloc, rbuf[0..n]) catch {
            respondError(resp, "oom");
            return;
        };
    }
    if (c.sqlite3_exec(db, "BEGIN", null, null, null) != c.SQLITE_OK) {
        respondSqliteError(resp, db);
        return;
    }
    var count: i64 = 0;
    var lines = std.mem.splitScalar(u8, data.items, '\n');
    while (lines.next()) |raw| {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1]; // CRLF → strip CR
        if (line.len == 0) continue;
        if (!importRow(db, table, line)) {
            _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
            respondSqliteError(resp, db);
            return;
        }
        count += 1;
    }
    if (c.sqlite3_exec(db, "COMMIT", null, null, null) != c.SQLITE_OK) {
        respondSqliteError(resp, db);
        return;
    }
    resp.appendSlice(alloc, "{\"v\":1,\"ok\":true,\"changes\":") catch return;
    writeI64(resp, count);
    resp.append(alloc, '}') catch return;
}

/// INSERT one CSV line (comma-separated fields, each bound as text) into `table`. `false` on error.
fn importRow(db: ?*c.sqlite3, table: []const u8, line: []const u8) bool {
    var ncols: usize = 1;
    for (line) |ch| {
        if (ch == ',') ncols += 1;
    }
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(alloc);
    sql.appendSlice(alloc, "INSERT INTO ") catch return false;
    sql.appendSlice(alloc, table) catch return false;
    sql.appendSlice(alloc, " VALUES (") catch return false;
    var k: usize = 0;
    while (k < ncols) : (k += 1) {
        sql.appendSlice(alloc, if (k == 0) "?" else ",?") catch return false;
    }
    sql.append(alloc, ')') catch return false;
    const sql_z = alloc.dupeZ(u8, sql.items) catch return false;
    defer alloc.free(sql_z);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) return false;
    defer _ = c.sqlite3_finalize(stmt);
    var fields = std.mem.splitScalar(u8, line, ',');
    var idx: c_int = 1;
    while (fields.next()) |f| : (idx += 1) {
        if (c.sqlite3_bind_text(stmt, idx, f.ptr, @intCast(f.len), SQLITE_TRANSIENT) != c.SQLITE_OK) return false;
    }
    return c.sqlite3_step(stmt) == c.SQLITE_DONE;
}

// ── helpers ──────────────────────────────────────────────────────────────────

fn sessionDb(session: u32) ?*c.sqlite3 {
    const s = sessions.get(session) orelse return null;
    return s.db;
}

/// A non-negative JSON integer field as a `u32` (a statement id); `null` if absent/not an integer.
fn idOf(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |x| if (x >= 0) @intCast(x) else null,
        else => null,
    };
}

/// A JSON integer field as `i64`, defaulting to 0 (used for `step`'s `max` — 0 means "to completion").
fn idOfI64(obj: std.json.ObjectMap, key: []const u8) i64 {
    const v = obj.get(key) orelse return 0;
    return switch (v) {
        .integer => |x| x,
        else => 0,
    };
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Bind positional `?` params from the request's `params` array. Returns an error message (or `null`
/// on success): every `sqlite3_bind_*` result code is checked, the parameter COUNT is validated against
/// the statement, and a malformed value is rejected — rather than silently mis-binding, binding NULL,
/// or leaving params unbound (codex #9).
fn bindParams(obj: std.json.ObjectMap, stmt: ?*c.sqlite3_stmt) ?[]const u8 {
    const expected: usize = @intCast(c.sqlite3_bind_parameter_count(stmt));
    const pv = obj.get("params") orelse {
        return if (expected == 0) null else "missing bind parameters";
    };
    const arr = switch (pv) {
        .array => |a| a,
        // An empty Lua table json-encodes as `{}` (an object, not `[]`), so treat an empty object as
        // "no parameters" — the library's representation of an empty varargs list.
        .object => |o| {
            if (o.count() == 0) {
                return if (expected == 0) null else "missing bind parameters";
            }
            return "params must be an array";
        },
        else => return "params must be an array",
    };
    if (arr.items.len != expected) {
        return "wrong number of bind parameters";
    }
    for (arr.items, 0..) |p, i| {
        const idx: c_int = @intCast(i + 1);
        const rc: c_int = switch (p) {
            .integer => |x| c.sqlite3_bind_int64(stmt, idx, x),
            .float => |x| c.sqlite3_bind_double(stmt, idx, x),
            // SQLITE_STATIC (null destructor): the param string outlives prepare→step→respond
            // (it lives in the parsed request, freed only after the response is built).
            .string => |s| c.sqlite3_bind_text(stmt, idx, s.ptr, @intCast(s.len), null),
            .bool => |b| c.sqlite3_bind_int(stmt, idx, if (b) 1 else 0),
            .null => c.sqlite3_bind_null(stmt, idx),
            // A tagged BLOB param {"$blob":"<hex>"} → the decoded bytes; a malformed tag is an error.
            .object => |o| bindBlob(stmt, idx, o) orelse return "malformed $blob parameter",
            else => return "unsupported bind parameter type",
        };
        if (rc != c.SQLITE_OK) return "bind failed";
    }
    return null;
}

/// Bind a tagged BLOB param — `{"$blob":"<hex>"}` — by hex-decoding into a temp buffer and binding it
/// with SQLITE_TRANSIENT (sqlite copies, so the temp frees immediately). Returns the bind result code,
/// or `null` if the tag is malformed (not a `$blob` string, odd length, or non-hex) so the caller can
/// report an error instead of silently binding NULL (codex #9).
fn bindBlob(stmt: ?*c.sqlite3_stmt, idx: c_int, o: std.json.ObjectMap) ?c_int {
    const bv = o.get("$blob") orelse return null;
    const hex = switch (bv) {
        .string => |st| st,
        else => return null,
    };
    if (hex.len % 2 != 0) return null;
    const n = hex.len / 2;
    const buf = alloc.alloc(u8, n) catch return null;
    defer alloc.free(buf);
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const hi = hexNibble(hex[2 * k]) orelse return null;
        const lo = hexNibble(hex[2 * k + 1]) orelse return null;
        buf[k] = (hi << 4) | lo;
    }
    return c.sqlite3_bind_blob(stmt, idx, buf.ptr, @intCast(n), SQLITE_TRANSIENT);
}

fn hexNibble(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

fn writeCell(resp: *std.ArrayList(u8), stmt: ?*c.sqlite3_stmt, col: c_int) void {
    switch (c.sqlite3_column_type(stmt, col)) {
        c.SQLITE_INTEGER => writeI64(resp, c.sqlite3_column_int64(stmt, col)),
        c.SQLITE_FLOAT => writeF64(resp, c.sqlite3_column_double(stmt, col)),
        c.SQLITE_TEXT => {
            const t = c.sqlite3_column_text(stmt, col);
            const len = c.sqlite3_column_bytes(stmt, col);
            if (t == null or len <= 0) {
                resp.appendSlice(alloc, "\"\"") catch {};
            } else {
                writeJsonStr(resp, t[0..@intCast(len)]);
            }
        },
        c.SQLITE_BLOB => {
            // BLOBs are arbitrary bytes (not UTF-8), so they cannot ride a JSON string. Emit a tagged
            // hex object {"$blob":"<hex>"} that round-trips losslessly; the lib decodes it back to a
            // Lua byte string. (Hex, not base64: trivial + dependency-free on the Zig and Luau sides.)
            resp.appendSlice(alloc, "{\"$blob\":\"") catch {};
            const b = c.sqlite3_column_blob(stmt, col);
            const len = c.sqlite3_column_bytes(stmt, col);
            if (b != null and len > 0) {
                const bytes: [*]const u8 = @ptrCast(b);
                writeHex(resp, bytes[0..@intCast(len)]);
            }
            resp.appendSlice(alloc, "\"}") catch {};
        },
        else => resp.appendSlice(alloc, "null") catch {}, // SQLITE_NULL
    }
}

fn writeI64(resp: *std.ArrayList(u8), n: i64) void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
    resp.appendSlice(alloc, s) catch {};
}

fn writeF64(resp: *std.ArrayList(u8), x: f64) void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{x}) catch return;
    resp.appendSlice(alloc, s) catch {};
}

fn writeJsonStr(resp: *std.ArrayList(u8), s: []const u8) void {
    resp.append(alloc, '"') catch return;
    for (s) |ch| {
        switch (ch) {
            '"' => resp.appendSlice(alloc, "\\\"") catch return,
            '\\' => resp.appendSlice(alloc, "\\\\") catch return,
            '\n' => resp.appendSlice(alloc, "\\n") catch return,
            '\r' => resp.appendSlice(alloc, "\\r") catch return,
            '\t' => resp.appendSlice(alloc, "\\t") catch return,
            0...8, 11, 12, 14...31 => {
                var b: [8]u8 = undefined;
                const e = std.fmt.bufPrint(&b, "\\u{x:0>4}", .{ch}) catch return;
                resp.appendSlice(alloc, e) catch return;
            },
            else => resp.append(alloc, ch) catch return,
        }
    }
    resp.append(alloc, '"') catch return;
}

fn writeJsonCStr(resp: *std.ArrayList(u8), cs: [*c]const u8) void {
    if (cs == null) {
        resp.appendSlice(alloc, "null") catch {};
        return;
    }
    writeJsonStr(resp, std.mem.span(cs));
}

/// Append `bytes` as lowercase hex (the BLOB wire form inside `{"$blob":"…"}`).
fn writeHex(resp: *std.ArrayList(u8), bytes: []const u8) void {
    const digits = "0123456789abcdef";
    for (bytes) |byte| {
        resp.append(alloc, digits[byte >> 4]) catch return;
        resp.append(alloc, digits[byte & 0xf]) catch return;
    }
}

fn respondOk(resp: *std.ArrayList(u8)) void {
    resp.clearRetainingCapacity();
    resp.appendSlice(alloc, "{\"v\":1,\"ok\":true}") catch {};
}

// An APPLICATION error (bad request shape, a missing field, a malformed param): structured `code` 0
// (not a sqlite result code) plus a human message.
fn respondError(resp: *std.ArrayList(u8), msg: []const u8) void {
    resp.clearRetainingCapacity();
    resp.appendSlice(alloc, "{\"v\":1,\"ok\":false,\"code\":0,\"error\":") catch return;
    writeJsonStr(resp, msg);
    resp.append(alloc, '}') catch return;
}

// A SQLITE error: the structured EXTENDED result code (machine-readable — e.g. 19 = CONSTRAINT,
// 5 = BUSY, 2067 = CONSTRAINT_UNIQUE) plus sqlite's own message. `db` holds the most-recent error
// after a failed call; null (no db yet) degrades to code 0 + a generic message.
fn respondSqliteError(resp: *std.ArrayList(u8), db: ?*c.sqlite3) void {
    resp.clearRetainingCapacity();
    resp.appendSlice(alloc, "{\"v\":1,\"ok\":false,\"code\":") catch return;
    writeI64(resp, if (db) |d| @intCast(c.sqlite3_extended_errcode(d)) else 0);
    resp.appendSlice(alloc, ",\"error\":") catch return;
    const msg: [*c]const u8 = if (db) |d| c.sqlite3_errmsg(d) else null;
    if (msg == null) writeJsonStr(resp, "sqlite error") else writeJsonStr(resp, std.mem.span(msg));
    resp.append(alloc, '}') catch return;
}

// ── CLI: the thin-client face (the §3.3 `_start` path) ──────────────────────────
//
// `sqlite <db> <sql>` runs SQL against the WARM resident service and prints rows (TSV); it is a thin
// svc_connect/svc_call CLIENT of the same engine the library and the serve loop drive — "three faces,
// one core" (SERVICES.md §3.3), not a second implementation. `sqlite <db> import <table> <file>`
// bulk-loads a CSV by DELEGATING the open file to the service (SERVICES.md §3.4), which reads it
// straight from the handle with no path of its own.

fn die(msg: []const u8) noreturn {
    var n: u32 = 0;
    _ = mc.mc_sys_write(2, mc.addr(msg.ptr), @intCast(msg.len), mc.addr(&n));
    _ = mc.mc_sys_exit(1);
    unreachable;
}

fn usage() noreturn {
    die("usage: sqlite <db> <sql> | sqlite <db> import <table> <file>\n");
}

fn writeOut(bytes: []const u8) void {
    var n: u32 = 0;
    _ = mc.mc_sys_write(1, mc.addr(bytes.ptr), @intCast(bytes.len), mc.addr(&n));
}

/// One CLI round-trip: send `req` (plus any delegated `handles`) on the connection and return the
/// drained response bytes (caller frees), or `null` on a transport failure.
fn cliCall(conn: i32, req: []const u8, handles: []const i32) ?[]u8 {
    var rfd: u32 = 0;
    const hptr: u32 = if (handles.len == 0) 0 else mc.addr(handles.ptr);
    if (mc.mc_sys_svc_call(conn, mc.addr(req.ptr), @intCast(req.len), hptr, @intCast(handles.len), mc.addr(&rfd)) != 0) {
        return null;
    }
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        var n: u32 = 0;
        if (mc.mc_sys_read(@intCast(rfd), mc.addr(&buf), buf.len, mc.addr(&n)) != 0) {
            out.deinit(alloc);
            _ = mc.mc_sys_close(@intCast(rfd));
            return null;
        }
        if (n == 0) break;
        out.appendSlice(alloc, buf[0..n]) catch {
            out.deinit(alloc);
            _ = mc.mc_sys_close(@intCast(rfd));
            return null;
        };
    }
    _ = mc.mc_sys_close(@intCast(rfd));
    return out.toOwnedSlice(alloc) catch null;
}

/// Send `req` and return the parsed `{ok:true,...}` response (caller `deinit`s it). Dies — printing the
/// service's own message — on a transport failure, a bad response, or an application error.
fn sendAndCheck(conn: i32, req: []const u8, handles: []const i32) std.json.Parsed(std.json.Value) {
    const resp = cliCall(conn, req, handles) orelse die("sqlite: call failed\n");
    defer alloc.free(resp);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp, .{}) catch die("sqlite: bad response\n");
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => die("sqlite: bad response\n"),
    };
    const ok = switch (obj.get("ok") orelse std.json.Value{ .bool = false }) {
        .bool => |b| b,
        else => false,
    };
    if (!ok) {
        const emsg = getStr(obj, "error") orelse "error";
        var line: std.ArrayList(u8) = .empty;
        line.appendSlice(alloc, "sqlite: ") catch {};
        line.appendSlice(alloc, emsg) catch {};
        line.append(alloc, '\n') catch {};
        die(line.items); // noreturn; the line leaks but the process is exiting
    }
    return parsed;
}

/// Format one typed cell for TSV output.
fn printCell(out: *std.ArrayList(u8), v: std.json.Value) void {
    switch (v) {
        .integer => |x| writeI64(out, x),
        .float => |x| writeF64(out, x),
        .string => |s| out.appendSlice(alloc, s) catch {},
        .object => |o| {
            // A {"$blob":"<hex>"} cell: print the hex (a CLI line can't carry raw bytes).
            if (o.get("$blob")) |bv| switch (bv) {
                .string => |s| out.appendSlice(alloc, s) catch {},
                else => {},
            };
        },
        else => {}, // null / bool → empty cell
    }
}

fn cliOpen(conn: i32, db_path: []const u8) void {
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(alloc);
    req.appendSlice(alloc, "{\"v\":1,\"op\":\"open\",\"path\":") catch die("sqlite: oom\n");
    writeJsonStr(&req, db_path);
    req.append(alloc, '}') catch die("sqlite: oom\n");
    sendAndCheck(conn, req.items, &.{}).deinit();
}

/// Run `sql` and print the result as TSV: a header row of column names, then one row per result.
fn cliQuery(conn: i32, sql: []const u8) void {
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(alloc);
    req.appendSlice(alloc, "{\"v\":1,\"op\":\"query\",\"sql\":") catch die("sqlite: oom\n");
    writeJsonStr(&req, sql);
    req.append(alloc, '}') catch die("sqlite: oom\n");
    const p = sendAndCheck(conn, req.items, &.{});
    defer p.deinit();
    const obj = p.value.object;

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    // A header row of column names — skipped for a statement with no result columns (CREATE/INSERT),
    // which print nothing, so a non-query is silent like the sqlite3 CLI.
    if (obj.get("cols")) |cv| switch (cv) {
        .array => |cols| if (cols.items.len > 0) {
            line.clearRetainingCapacity();
            for (cols.items, 0..) |col, i| {
                if (i > 0) line.append(alloc, '\t') catch {};
                switch (col) {
                    .string => |s| line.appendSlice(alloc, s) catch {},
                    else => {},
                }
            }
            line.append(alloc, '\n') catch {};
            writeOut(line.items);
        },
        else => {},
    };
    if (obj.get("rows")) |rv| switch (rv) {
        .array => |rows| {
            for (rows.items) |row| switch (row) {
                .array => |cells| {
                    line.clearRetainingCapacity();
                    for (cells.items, 0..) |cell, i| {
                        if (i > 0) line.append(alloc, '\t') catch {};
                        printCell(&line, cell);
                    }
                    line.append(alloc, '\n') catch {};
                    writeOut(line.items);
                },
                else => {},
            };
        },
        else => {},
    };
}

/// `sqlite <db> import <table> <file>`: open <file>, DELEGATE the handle to the service, and let it
/// read the CSV straight from the handle (SERVICES.md §3.4). The service never sees the path.
fn cliImport(conn: i32, table: []const u8, file: []const u8) void {
    var fd: u32 = 0;
    if (mc.mc_sys_open(mc.addr(file.ptr), @intCast(file.len), 0, mc.addr(&fd)) != 0) {
        die("sqlite: cannot open import file\n");
    }
    defer _ = mc.mc_sys_close(@intCast(fd));
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(alloc);
    req.appendSlice(alloc, "{\"v\":1,\"op\":\"import\",\"table\":") catch die("sqlite: oom\n");
    writeJsonStr(&req, table);
    req.append(alloc, '}') catch die("sqlite: oom\n");
    const handles = [_]i32{@intCast(fd)};
    const p = sendAndCheck(conn, req.items, &handles);
    defer p.deinit();
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    line.appendSlice(alloc, "imported ") catch {};
    writeI64(&line, idOfI64(p.value.object, "changes"));
    line.appendSlice(alloc, " rows\n") catch {};
    writeOut(line.items);
}

fn cli(args: []const u8) void {
    var it = std.mem.splitScalar(u8, args, 0);
    _ = it.next(); // argv[0]
    const db_path = it.next() orelse usage();
    const arg2 = it.next() orelse usage();

    var conn: u32 = 0;
    if (mc.mc_sys_svc_connect(mc.addr(SERVICE_NAME.ptr), SERVICE_NAME.len, mc.addr(&conn)) != 0) {
        die("sqlite: service unavailable\n");
    }
    cliOpen(@intCast(conn), db_path);

    if (std.mem.eql(u8, arg2, "import")) {
        const table = it.next() orelse usage();
        const file = it.next() orelse usage();
        cliImport(@intCast(conn), table, file);
    } else {
        cliQuery(@intCast(conn), arg2);
    }
    _ = mc.mc_sys_exit(0);
}
