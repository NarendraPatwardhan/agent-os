//! sqlite glue — the resident SERVICE. One binary, two modes (SYSTEMS.md): spawned with the service
//! marker it runs the warm `svc_serve` loop over per-session `sqlite3*` handles; otherwise it is a
//! thin CLI client over that same service. The Luau library `require("sqlite")` is the default interface.
//!
//! Protocol (JSON both ways, the lib's `json` battery ↔ this loop): a request is
//!   {"op":"open","path":"…"} | {"op":"exec","sql":"…"} | {"op":"query","sql":"…","params":[…]} | {"op":"close"}
//! and a response is {"ok":true,…} or {"ok":false,"error":"…"}. exec → {changes,rowid}; query →
//! {cols:[…],rows:[[…]]} with values typed (INTEGER/REAL→number, TEXT→string, NULL→null, BLOB→string).
//! The DB file (e.g. /var/persist/app.db) is opened by sqlite's stock unix-dotfile VFS over WASI → the
//! wasi-adapter → mc — no custom VFS. SYSTEMS.md

const std = @import("std");
const mc = @import("mc");
const svc = @import("svc");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const alloc = std.heap.c_allocator;
const SERVICE_NAME = "sqlite";
/// A streamed query flushes its response in chunks of this size (below the kernel's 64 KiB svc-buffer
/// high-water) so a large result drains incrementally — neither the service nor the kernel holds it whole.
const STREAM_FLUSH_BYTES = 32 * 1024;

// SQLITE_TRANSIENT (the `(sqlite3_destructor_type)-1` sentinel): tells sqlite to COPY the bound bytes,
// so a temporary buffer (a hex-decoded BLOB param) can be freed right after the bind. @cImport doesn't
// surface the cast macro, so reconstruct the all-ones pointer.
const SQLITE_TRANSIENT: c.sqlite3_destructor_type = @ptrFromInt(std.math.maxInt(usize));

/// Per-session warm state: the open DB handle PLUS the warm PREPARED STATEMENTS (compiled once, run
/// many) keyed by a per-session id. All in this guest's linear memory, so the connection, sqlite's
/// page cache, AND the compiled statements stay warm across calls (and ride a kernel snapshot).
/// A SELECT being STREAMED to a client incrementally: the prepared statement plus where we are in the
/// JSON being produced. The serve loop pumps chunks into the kernel buffer until it fills (`respond` →
/// EAGAIN), parks the stream here, and resumes it on the `.drain_ready` the kernel delivers once the
/// client drains — so producing a huge result for one slow client never blocks serving everyone else.
const QueryStream = struct {
    stmt: *c.sqlite3_stmt,
    db: *c.sqlite3, // for an error message if a step fails mid-stream
    req_id: u32,
    ncol: c_int,
    tail: []u8, // owned copy of the unparsed SQL tail (outlives the request blob)
    phase: enum { prefix, rows, suffix, done },
    first: bool, // first row? (drives the comma)
    chunk: std.ArrayList(u8), // the chunk being built / parked un-sent across an EAGAIN
    status: i32, // 0 normally; svc.EIO for a mid-stream step error
    is_last: bool, // the built chunk is the final one
    sent_any: bool, // any chunk accepted yet? (a later error can't then send a clean JSON error)

    fn deinit(self: *QueryStream) void {
        _ = c.sqlite3_finalize(self.stmt);
        alloc.free(self.tail);
        self.chunk.deinit(alloc);
        alloc.destroy(self);
    }
};

const Session = struct {
    db: ?*c.sqlite3 = null,
    stmts: std.AutoHashMap(u32, *c.sqlite3_stmt),
    in_progress: ?*QueryStream = null, // an in-flight streaming query (≤1: one call per session at a time)
    next_id: u32 = 1,

    fn create() ?*Session {
        const s = alloc.create(Session) catch return null;
        s.* = .{ .stmts = std.AutoHashMap(u32, *c.sqlite3_stmt).init(alloc) };
        return s;
    }
    /// Finalize every warm statement (and any in-flight stream), close the DB, free the session — the
    /// teardown on `close` (and whenever the kernel evicts a dead client's session and re-`recv`s).
    fn destroy(self: *Session) void {
        if (self.in_progress) |stream| stream.deinit();
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
    if (std.mem.eql(u8, arg1, svc.SERVICE_MARKER)) {
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
            // The client drained a streaming response below the high-water — resume producing for it. The
            // serve loop never blocked on it, so other sessions were served while it drained.
            .drain_ready => {
                if (sessions.get(req.session)) |s| {
                    if (s.in_progress) |stream| {
                        if (stream.req_id == req.req_id) pumpQuery(&server, req.session, s, stream);
                    }
                }
            },
            .call => {
                defer closeDelegated(req.handles);
                var resp: std.ArrayList(u8) = .empty;
                defer resp.deinit(alloc);
                // A streaming op (query) drives its own chunked responses and returns true; every other op
                // builds one bounded answer in `resp` for the serve loop to send in a single chunk.
                if (!handle(&server, req, &resp)) {
                    _ = server.respond(req.session, req.req_id, 0, resp.items, true);
                }
            },
            else => {}, // unknown inbound kind — ignore
        }
    }
    _ = mc.mc_sys_exit(0); // channel closed — nothing more to serve
}

/// Dispatch one call, building its answer into `resp`. Returns `true` only if it ANSWERED the call
/// itself (a streaming op that already sent all its chunks, final included) — then the serve loop must
/// not respond again. Every other op builds `resp` and returns `false` for the serve loop to send.
fn handle(server: *svc.Server, req: svc.Request, resp: *std.ArrayList(u8)) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, req.blob, .{}) catch {
        respondError(resp, "invalid request json");
        return false;
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            respondError(resp, "request must be a json object");
            return false;
        },
    };
    // Protocol version: the library and this service ship together, but a versioned envelope lets the
    // service reject an incompatible client cleanly instead of misreading it (codex #9).
    if (idOfI64(obj, "v") != 1) {
        respondError(resp, "unsupported protocol version (expected v=1)");
        return false;
    }
    const op = getStr(obj, "op") orelse {
        respondError(resp, "missing op");
        return false;
    };
    if (std.mem.eql(u8, op, "open")) {
        doOpen(req.session, obj, resp);
    } else if (std.mem.eql(u8, op, "exec")) {
        doExec(req.session, obj, resp);
    } else if (std.mem.eql(u8, op, "query")) {
        return startQuery(server, req, obj, resp); // streams the result chunk by chunk (async, non-blocking)
    } else if (std.mem.eql(u8, op, "prepare")) {
        doPrepare(req.session, obj, resp);
    } else if (std.mem.eql(u8, op, "step")) {
        doStep(req.session, obj, resp);
    } else if (std.mem.eql(u8, op, "finalize")) {
        doFinalize(req.session, obj, resp);
    } else if (std.mem.eql(u8, op, "import")) {
        doImport(req.session, obj, req.handles, resp);
    } else if (std.mem.eql(u8, op, "close")) {
        doClose(req.session, resp);
    } else {
        respondError(resp, "unknown op");
    }
    return false;
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

/// Begin streaming a SELECT (codex #3 + the async-loop fix). Prepares and binds synchronously (needs the
/// request `obj`); for a statement that yields rows it parks a `QueryStream` on the session and PUMPS the
/// first chunks. Returns `true` — the stream now owns the response — or `false` for a trivial one-shot
/// answer the serve loop sends (a prepare error, an empty statement). The result pages out incrementally
/// as the client drains: never materialized whole, and never blocking the serve loop on a slow client.
fn startQuery(server: *svc.Server, req: svc.Request, obj: std.json.ObjectMap, resp: *std.ArrayList(u8)) bool {
    const s = sessionFor(req.session) orelse {
        respondError(resp, "oom");
        return false;
    };
    // One call per session at a time is the protocol; if a NEW query arrives while one is still streaming
    // (a misbehaving client), abandon the old stream so its stmt/heap can't leak — its unfinished response
    // is reaped by the kernel's drain deadline.
    if (s.in_progress) |old| {
        old.deinit();
        s.in_progress = null;
    }
    const db = s.db orelse {
        respondError(resp, "no open database (call open first)");
        return false;
    };
    const sql = getStr(obj, "sql") orelse {
        respondError(resp, "query: missing sql");
        return false;
    };
    const sql_z = alloc.dupeZ(u8, sql) catch {
        respondError(resp, "oom");
        return false;
    };
    defer alloc.free(sql_z);
    var stmt: ?*c.sqlite3_stmt = null;
    var tail: [*c]const u8 = null;
    if (c.sqlite3_prepare_v2(db, sql_z.ptr, -1, &stmt, &tail) != c.SQLITE_OK) {
        respondSqliteError(resp, db);
        return false;
    }
    // The unparsed remainder after this statement — so the CLI runs a ;-separated script one statement
    // at a time, on sqlite's OWN boundary (a hand-rolled split would mis-handle a ; inside a string).
    const tail_off = @intFromPtr(tail) - @intFromPtr(sql_z.ptr);
    const tail_str: []const u8 = sql_z[@min(tail_off, sql_z.len)..];
    if (stmt == null) {
        // No statement (empty / whitespace / comment-only SQL) — a trivial one-shot answer.
        resp.appendSlice(alloc, "{\"v\":1,\"ok\":true,\"cols\":[],\"rows\":[],\"tail\":") catch return false;
        writeJsonStr(resp, tail_str);
        resp.append(alloc, '}') catch return false;
        return false;
    }
    if (bindParams(obj, stmt)) |emsg| {
        _ = c.sqlite3_finalize(stmt);
        respondError(resp, emsg);
        return false;
    }
    const owned_tail = alloc.dupe(u8, tail_str) catch {
        _ = c.sqlite3_finalize(stmt);
        respondError(resp, "oom");
        return false;
    };
    const stream = alloc.create(QueryStream) catch {
        alloc.free(owned_tail);
        _ = c.sqlite3_finalize(stmt);
        respondError(resp, "oom");
        return false;
    };
    stream.* = .{
        .stmt = stmt.?,
        .db = db,
        .req_id = req.req_id,
        .ncol = c.sqlite3_column_count(stmt),
        .tail = owned_tail,
        .phase = .prefix,
        .first = true,
        .chunk = .empty,
        .status = 0,
        .is_last = false,
        .sent_any = false,
    };
    s.in_progress = stream;
    pumpQuery(server, req.session, s, stream);
    return true;
}

/// Send chunks for `stream` until the kernel buffer fills (`respond` → EAGAIN, so we PARK the un-sent
/// chunk and return — the serve loop resumes us on the next `.drain_ready`) or the result is fully sent
/// (then free the stream). The single-threaded serve loop is NEVER blocked here: a slow client just stops
/// us, and we serve everyone else until it drains.
fn pumpQuery(server: *svc.Server, session: u32, s: *Session, stream: *QueryStream) void {
    while (true) {
        if (stream.chunk.items.len == 0) buildChunk(stream);
        const rc = server.respond(session, stream.req_id, stream.status, stream.chunk.items, stream.is_last);
        if (rc == svc.EAGAIN) return; // buffer full — keep the chunk parked, resume on .drain_ready
        stream.sent_any = true;
        stream.chunk.clearRetainingCapacity();
        if (stream.is_last) {
            finishStream(s, stream);
            return;
        }
    }
}

fn finishStream(s: *Session, stream: *QueryStream) void {
    s.in_progress = null;
    stream.deinit();
}

/// Fill `stream.chunk` with the next piece of the JSON, advancing the phase: the `{… "rows":[` prefix,
/// then rows until a chunk's worth (or the statement is exhausted), then the `],"tail":…}` suffix on the
/// final chunk. A step error mid-stream becomes a clean structured error if nothing has gone out yet,
/// else a transport EIO (already-sent rows can't be retracted) the client surfaces as a failed read.
fn buildChunk(stream: *QueryStream) void {
    if (stream.phase == .prefix) {
        stream.chunk.appendSlice(alloc, "{\"v\":1,\"ok\":true,\"cols\":[") catch {};
        var ci: c_int = 0;
        while (ci < stream.ncol) : (ci += 1) {
            if (ci > 0) stream.chunk.append(alloc, ',') catch {};
            writeJsonCStr(&stream.chunk, c.sqlite3_column_name(stream.stmt, ci));
        }
        stream.chunk.appendSlice(alloc, "],\"rows\":[") catch {};
        stream.phase = .rows;
    }
    if (stream.phase == .rows) {
        while (stream.chunk.items.len < STREAM_FLUSH_BYTES) {
            const rc = c.sqlite3_step(stream.stmt);
            if (rc == c.SQLITE_DONE) {
                stream.phase = .suffix;
                break;
            }
            if (rc != c.SQLITE_ROW) {
                stream.chunk.clearRetainingCapacity();
                if (stream.sent_any) {
                    stream.status = svc.EIO; // partial rows already out — surface a transport failure
                } else {
                    respondSqliteError(&stream.chunk, stream.db); // nothing sent — a clean structured error
                }
                stream.phase = .done;
                stream.is_last = true;
                return;
            }
            if (!stream.first) stream.chunk.append(alloc, ',') catch {};
            stream.first = false;
            stream.chunk.append(alloc, '[') catch {};
            var ci: c_int = 0;
            while (ci < stream.ncol) : (ci += 1) {
                if (ci > 0) stream.chunk.append(alloc, ',') catch {};
                writeCell(&stream.chunk, stream.stmt, ci);
            }
            stream.chunk.append(alloc, ']') catch {};
        }
    }
    if (stream.phase == .suffix) {
        stream.chunk.appendSlice(alloc, "],\"tail\":") catch {};
        writeJsonStr(&stream.chunk, stream.tail);
        stream.chunk.append(alloc, '}') catch {};
        stream.phase = .done;
        stream.is_last = true;
        return;
    }
    stream.is_last = false; // the chunk filled before the statement was exhausted — more rows to come
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

/// `import`: bulk-load a CSV that the CLI DELEGATED as a handle (SYSTEMS.md). The service reads
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
    var pos: usize = 0;
    while (nextCsvRecord(data.items, &pos)) |record| {
        defer freeCsvRecord(record);
        if (record.len == 1 and record[0].len == 0) continue; // a blank line, not a data row
        if (!importRecord(db, table, record)) {
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

/// INSERT one parsed CSV record (each field bound as text) into `table`. `false` on error.
fn importRecord(db: ?*c.sqlite3, table: []const u8, fields: []const []const u8) bool {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(alloc);
    sql.appendSlice(alloc, "INSERT INTO ") catch return false;
    sql.appendSlice(alloc, table) catch return false;
    sql.appendSlice(alloc, " VALUES (") catch return false;
    for (0..fields.len) |k| {
        sql.appendSlice(alloc, if (k == 0) "?" else ",?") catch return false;
    }
    sql.append(alloc, ')') catch return false;
    const sql_z = alloc.dupeZ(u8, sql.items) catch return false;
    defer alloc.free(sql_z);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) return false;
    defer _ = c.sqlite3_finalize(stmt);
    for (fields, 1..) |f, idx| {
        if (c.sqlite3_bind_text(stmt, @intCast(idx), f.ptr, @intCast(f.len), SQLITE_TRANSIENT) != c.SQLITE_OK) return false;
    }
    return c.sqlite3_step(stmt) == c.SQLITE_DONE;
}

/// Parse the next CSV record from `data` at `*pos` (RFC 4180): fields are comma-separated; a field may
/// be "quoted" to contain commas, CRs, and newlines; "" inside a quoted field is a literal ". Each field
/// is heap-owned so quote-unescaping is honored. Returns null at end of input (or on an allocation
/// failure mid-parse); advances `*pos` past the record. Caller frees with `freeCsvRecord`.
fn nextCsvRecord(data: []const u8, pos: *usize) ?[][]u8 {
    if (pos.* >= data.len) return null;
    var fields: std.ArrayList([]u8) = .empty;
    var field: std.ArrayList(u8) = .empty;
    defer field.deinit(alloc);
    var i = pos.*;
    var quoted = false;
    var done = false;
    while (i < data.len and !done) {
        const ch = data[i];
        if (quoted) {
            if (ch == '"') {
                if (i + 1 < data.len and data[i + 1] == '"') {
                    field.append(alloc, '"') catch return abortRecord(&fields);
                    i += 2;
                } else {
                    quoted = false;
                    i += 1;
                }
            } else {
                field.append(alloc, ch) catch return abortRecord(&fields);
                i += 1;
            }
        } else switch (ch) {
            '"' => {
                quoted = true;
                i += 1;
            },
            ',' => {
                fields.append(alloc, alloc.dupe(u8, field.items) catch return abortRecord(&fields)) catch return abortRecord(&fields);
                field.clearRetainingCapacity();
                i += 1;
            },
            '\r' => i += 1, // CRLF: drop the CR
            '\n' => {
                i += 1;
                done = true; // record terminator
            },
            else => {
                field.append(alloc, ch) catch return abortRecord(&fields);
                i += 1;
            },
        }
    }
    fields.append(alloc, alloc.dupe(u8, field.items) catch return abortRecord(&fields)) catch return abortRecord(&fields);
    pos.* = i;
    return fields.toOwnedSlice(alloc) catch return abortRecord(&fields);
}

/// Free the partial fields and report end-of-records on an allocation failure mid-parse.
fn abortRecord(fields: *std.ArrayList([]u8)) ?[][]u8 {
    for (fields.items) |f| alloc.free(f);
    fields.deinit(alloc);
    return null;
}

fn freeCsvRecord(record: [][]u8) void {
    for (record) |f| alloc.free(f);
    alloc.free(record);
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
// one core" (SYSTEMS.md), not a second implementation. `sqlite <db> import <table> <file>`
// bulk-loads a CSV by DELEGATING the open file to the service (SYSTEMS.md), which reads it
// straight from the handle with no path of its own.

fn die(msg: []const u8) noreturn {
    var n: u32 = 0;
    _ = mc.mc_sys_write(2, mc.addr(msg.ptr), @intCast(msg.len), mc.addr(&n));
    _ = mc.mc_sys_exit(1);
    unreachable;
}

fn usage() noreturn {
    die("usage: sqlite <db> [SQL]   (no SQL → a stdin REPL; a SQL arg or a .dot-command runs and exits)\n");
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

// ── the CLI face: sqlite3-like (args or a stdin REPL, | output, dot-commands) ────────────────────────

const Mode = enum { list, csv };

/// CLI rendering state — sqlite3's defaults: list mode (`|` separator), headers off.
const Cli = struct {
    conn: i32,
    headers: bool = false,
    mode: Mode = .list,
};

fn writeErr(bytes: []const u8) void {
    var n: u32 = 0;
    _ = mc.mc_sys_write(2, mc.addr(bytes.ptr), @intCast(bytes.len), mc.addr(&n));
}

/// Append `s` to `out`, RFC-4180 quoted iff it contains a comma, quote, CR, or newline (csv mode).
fn appendCsvField(out: *std.ArrayList(u8), s: []const u8) void {
    if (std.mem.indexOfAny(u8, s, ",\"\r\n") == null) {
        out.appendSlice(alloc, s) catch {};
        return;
    }
    out.append(alloc, '"') catch {};
    for (s) |ch| {
        if (ch == '"') out.append(alloc, '"') catch {};
        out.append(alloc, ch) catch {};
    }
    out.append(alloc, '"') catch {};
}

/// Render one typed cell, appended to `out` raw (list) or CSV-quoted (csv).
fn appendCell(out: *std.ArrayList(u8), mode: Mode, v: std.json.Value) void {
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(alloc);
    switch (v) {
        .integer => |x| writeI64(&tmp, x),
        .float => |x| writeF64(&tmp, x),
        .string => |s| tmp.appendSlice(alloc, s) catch {},
        // A {"$blob":"<hex>"} cell prints its hex (a text line can't carry raw bytes).
        .object => |o| if (o.get("$blob")) |bv| switch (bv) {
            .string => |s| tmp.appendSlice(alloc, s) catch {},
            else => {},
        },
        else => {}, // null / bool → empty cell
    }
    if (mode == .csv) appendCsvField(out, tmp.items) else out.appendSlice(alloc, tmp.items) catch {};
}

fn cliOpen(conn: i32, db_path: []const u8) void {
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(alloc);
    req.appendSlice(alloc, "{\"v\":1,\"op\":\"open\",\"path\":") catch die("sqlite: oom\n");
    writeJsonStr(&req, db_path);
    req.append(alloc, '}') catch die("sqlite: oom\n");
    sendAndCheck(conn, req.items, &.{}).deinit();
}

/// Print one result set in the active mode: a header row iff `.headers on`, then one line per row,
/// columns joined by `|` (list) or `,` (csv). A statement with no result columns prints nothing —
/// silent like sqlite3 for CREATE/INSERT.
fn printResult(self: *Cli, obj: std.json.ObjectMap) void {
    const sep: u8 = if (self.mode == .csv) ',' else '|';
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    const cols: ?std.json.Array = if (obj.get("cols")) |cv| switch (cv) {
        .array => |a| a,
        else => null,
    } else null;
    if (cols) |cs| {
        if (cs.items.len == 0) return; // a non-query statement prints nothing
        if (self.headers) {
            line.clearRetainingCapacity();
            for (cs.items, 0..) |col, i| {
                if (i > 0) line.append(alloc, sep) catch {};
                switch (col) {
                    .string => |s| if (self.mode == .csv) appendCsvField(&line, s) else line.appendSlice(alloc, s) catch {},
                    else => {},
                }
            }
            line.append(alloc, '\n') catch {};
            writeOut(line.items);
        }
    }
    if (obj.get("rows")) |rv| switch (rv) {
        .array => |rows| for (rows.items) |row| switch (row) {
            .array => |cells| {
                line.clearRetainingCapacity();
                for (cells.items, 0..) |cell, i| {
                    if (i > 0) line.append(alloc, sep) catch {};
                    appendCell(&line, self.mode, cell);
                }
                line.append(alloc, '\n') catch {};
                writeOut(line.items);
            },
            else => {},
        },
        else => {},
    };
}

/// Run a (possibly multi-statement) SQL string against the warm service ONE statement at a time: the
/// service runs each statement and returns the unparsed tail (its own boundary), and we print each
/// result set. The service holds the warm db, so the CLI stays a thin client (SYSTEMS.md).
fn runSql(self: *Cli, sql: []const u8) void {
    var remaining: []u8 = alloc.dupe(u8, sql) catch die("sqlite: oom\n");
    while (std.mem.trim(u8, remaining, " \t\r\n").len > 0) {
        var req: std.ArrayList(u8) = .empty;
        req.appendSlice(alloc, "{\"v\":1,\"op\":\"query\",\"sql\":") catch die("sqlite: oom\n");
        writeJsonStr(&req, remaining);
        req.append(alloc, '}') catch die("sqlite: oom\n");
        const p = sendAndCheck(self.conn, req.items, &.{});
        req.deinit(alloc);
        printResult(self, p.value.object);
        // Copy the tail BEFORE freeing p's arena, then advance to it.
        const tail = alloc.dupe(u8, getStr(p.value.object, "tail") orelse "") catch die("sqlite: oom\n");
        p.deinit();
        alloc.free(remaining);
        remaining = tail;
    }
    alloc.free(remaining);
}

/// `.import FILE TABLE`: open FILE, DELEGATE its handle to the service, and let the service read the CSV
/// straight from the handle (SYSTEMS.md) — the service never sees the path. Silent like sqlite3.
fn cliImport(conn: i32, file: []const u8, table: []const u8) void {
    var fd: u32 = 0;
    if (mc.mc_sys_open(mc.addr(file.ptr), @intCast(file.len), 0, mc.addr(&fd)) != 0) {
        writeErr("sqlite: cannot open import file\n");
        return;
    }
    defer _ = mc.mc_sys_close(@intCast(fd));
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(alloc);
    req.appendSlice(alloc, "{\"v\":1,\"op\":\"import\",\"table\":") catch die("sqlite: oom\n");
    writeJsonStr(&req, table);
    req.append(alloc, '}') catch die("sqlite: oom\n");
    const handles = [_]i32{@intCast(fd)};
    sendAndCheck(conn, req.items, &handles).deinit();
}

/// Append `s` as a SQL string literal (`'…'`, embedded `'` doubled).
fn writeSqlStr(out: *std.ArrayList(u8), s: []const u8) void {
    out.append(alloc, '\'') catch {};
    for (s) |ch| {
        if (ch == '\'') out.append(alloc, '\'') catch {};
        out.append(alloc, ch) catch {};
    }
    out.append(alloc, '\'') catch {};
}

const DOT_HELP =
    \\.help            show this help
    \\.tables          list tables
    \\.schema [TABLE]  show CREATE statements
    \\.headers on|off  show column headers (default off)
    \\.mode list|csv   set the output mode (default list, | separated)
    \\.import FILE TBL  load a CSV file into a table
    \\.quit            exit
    \\
;

/// Handle a `.`-prefixed meta-command (sqlite3's shell verbs). Returns false on `.quit`/`.exit`.
fn dotCommand(self: *Cli, line: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const cmd = it.next() orelse return true;
    if (std.mem.eql(u8, cmd, ".quit") or std.mem.eql(u8, cmd, ".exit")) {
        return false;
    } else if (std.mem.eql(u8, cmd, ".help")) {
        writeOut(DOT_HELP);
    } else if (std.mem.eql(u8, cmd, ".tables")) {
        runSql(self, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name");
    } else if (std.mem.eql(u8, cmd, ".schema")) {
        if (it.next()) |t| {
            var q: std.ArrayList(u8) = .empty;
            defer q.deinit(alloc);
            q.appendSlice(alloc, "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name=") catch return true;
            writeSqlStr(&q, t);
            runSql(self, q.items);
        } else {
            runSql(self, "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name");
        }
    } else if (std.mem.eql(u8, cmd, ".headers")) {
        const arg = it.next() orelse "";
        self.headers = std.mem.eql(u8, arg, "on") or std.mem.eql(u8, arg, "1") or std.mem.eql(u8, arg, "yes");
    } else if (std.mem.eql(u8, cmd, ".mode")) {
        const arg = it.next() orelse "";
        if (std.mem.eql(u8, arg, "csv")) {
            self.mode = .csv;
        } else if (std.mem.eql(u8, arg, "list")) {
            self.mode = .list;
        } else {
            writeErr("sqlite: .mode expects list|csv\n");
        }
    } else if (std.mem.eql(u8, cmd, ".import")) {
        const file = it.next();
        const table = it.next();
        if (file == null or table == null) {
            writeErr("sqlite: usage: .import FILE TABLE\n");
        } else {
            cliImport(self.conn, file.?, table.?);
        }
    } else {
        writeErr("sqlite: unknown command (.help for a list)\n");
    }
    return true;
}

/// The interactive face: read SQL + dot-commands from stdin until EOF or `.quit`. A line starting with
/// `.` is a meta-command; other lines accumulate into a statement that runs at its terminating `;`
/// (sqlite3's continue prompt). A trailing un-terminated statement runs at EOF.
fn repl(self: *Cli) void {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    var rbuf: [4096]u8 = undefined;
    while (true) {
        var n: u32 = 0;
        if (mc.mc_sys_read(0, mc.addr(&rbuf), rbuf.len, mc.addr(&n)) != 0) break;
        if (n == 0) break;
        input.appendSlice(alloc, rbuf[0..n]) catch break;
    }
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(alloc);
    var lines = std.mem.splitScalar(u8, input.items, '\n');
    while (lines.next()) |raw| {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (sql.items.len == 0 and trimmed.len > 0 and trimmed[0] == '.') {
            if (!dotCommand(self, trimmed)) return; // .quit
            continue;
        }
        if (trimmed.len == 0 and sql.items.len == 0) continue; // blank line between statements
        sql.appendSlice(alloc, line) catch break;
        sql.append(alloc, '\n') catch break;
        if (std.mem.endsWith(u8, std.mem.trim(u8, sql.items, " \t\r\n"), ";")) {
            runSql(self, sql.items);
            sql.clearRetainingCapacity();
        }
    }
    if (std.mem.trim(u8, sql.items, " \t\r\n").len > 0) runSql(self, sql.items); // trailing, no ;
}

fn cli(args: []const u8) void {
    var it = std.mem.splitScalar(u8, args, 0);
    _ = it.next(); // argv[0]
    const db_path = it.next() orelse usage();

    var conn: u32 = 0;
    if (mc.mc_sys_svc_connect(mc.addr(SERVICE_NAME.ptr), SERVICE_NAME.len, mc.addr(&conn)) != 0) {
        die("sqlite: service unavailable\n");
    }
    var self = Cli{ .conn = @intCast(conn) };
    cliOpen(self.conn, db_path);

    // sqlite3: a SQL (or dot-command) argument runs and exits; with no argument — or an EMPTY one (a
    // trailing argv NUL splits to ""), which is not the same as a present arg — read a stdin REPL.
    const sql_arg = it.next() orelse "";
    if (sql_arg.len > 0) {
        const trimmed = std.mem.trim(u8, sql_arg, " \t");
        if (trimmed.len > 0 and trimmed[0] == '.') {
            _ = dotCommand(&self, trimmed);
        } else {
            runSql(&self, sql_arg);
        }
    } else {
        repl(&self);
    }
    _ = mc.mc_sys_exit(0);
}
