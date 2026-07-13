//! /bin/syntax — Tree-sitter runtime as one crash-contained resident service. The C runtime owns
//! parsing; Zig owns bounded state, generation-tagged handles, the generated wire contract, and CLI.
const std = @import("std");
const mc = @import("mc");
const svc = @import("svc");
const sys = @import("sys");
const wire = @import("syntax_zig");
const registry = @import("syntax_registry");
const scanner = @import("scanner.zig");
const c = @cImport({
    @cInclude("tree_sitter/api.h");
});
comptime {
    _ = scanner;
}

const alloc = std.heap.c_allocator;
const SERVICE_NAME = "syntax";
const MAX_SOURCE = 768 * 1024;
const MAX_QUERY = 64 * 1024;
const MAX_DOCUMENTS_PER_SESSION = 16;
const MAX_PAGE_NODES = 512;
const MAX_PAGE_CAPTURES = 256;

const StoredNode = struct {
    handle: u32,
    value: c.TSNode,
};

const Document = struct {
    owner: u32,
    descriptor: *const registry.Descriptor,
    parser: *c.TSParser,
    tree: *c.TSTree,
    source: []u8,
    revision: u32 = 1,
    nodes: std.ArrayList(StoredNode) = .empty,
    next_node_handle: u32 = 1,

    fn deinit(self: *Document) void {
        self.nodes.deinit(alloc);
        c.ts_tree_delete(self.tree);
        c.ts_parser_delete(self.parser);
        alloc.free(self.source);
    }
};
const CompiledQuery = struct {
    owner: u32,
    descriptor: *const registry.Descriptor,
    query: *c.TSQuery,
    fn deinit(self: *CompiledQuery) void {
        c.ts_query_delete(self.query);
    }
};

var documents: std.AutoHashMap(u32, *Document) = undefined;
var queries: std.AutoHashMap(u32, *CompiledQuery) = undefined;
var next_document: u32 = 1;
var next_query: u32 = 1;

pub fn main() void {
    var argbuf: [4096]u8 = undefined;
    var alen: u32 = 0;
    _ = mc.mc_sys_args(mc.addr(&argbuf), argbuf.len, mc.addr(&alen));
    var it = std.mem.splitScalar(u8, argbuf[0..alen], 0);
    _ = it.next();
    const arg1 = it.next() orelse "";
    if (std.mem.eql(u8, arg1, svc.SERVICE_MARKER)) serveLoop() else cli(argbuf[0..alen]);
}

fn serveLoop() void {
    documents = std.AutoHashMap(u32, *Document).init(alloc);
    queries = std.AutoHashMap(u32, *CompiledQuery).init(alloc);
    defer {
        var dit = documents.valueIterator();
        while (dit.next()) |d| {
            d.*.deinit();
            alloc.destroy(d.*);
        }
        documents.deinit();
        var qit = queries.valueIterator();
        while (qit.next()) |q| {
            q.*.deinit();
            alloc.destroy(q.*);
        }
        queries.deinit();
    }
    const reqbuf = alloc.alloc(u8, (1 << 20) + 22) catch exit(1);
    defer alloc.free(reqbuf);
    var server = svc.Server.serve(SERVICE_NAME, reqbuf) catch exit(1);
    while (server.recv()) |req| switch (req.kind) {
        .session_closed => closeSession(req.session),
        .call => dispatch(&server, req),
        else => {},
    };
    exit(0);
}
fn exit(code: i32) noreturn {
    _ = mc.mc_sys_exit(code);
    unreachable;
}

fn closeSession(session: u32) void {
    var doc_ids: std.ArrayList(u32) = .empty;
    defer doc_ids.deinit(alloc);
    var dit = documents.iterator();
    while (dit.next()) |e| if (e.value_ptr.*.owner == session) doc_ids.append(alloc, e.key_ptr.*) catch {};
    for (doc_ids.items) |id| if (documents.fetchRemove(id)) |e| {
        e.value.deinit();
        alloc.destroy(e.value);
    };
    var query_ids: std.ArrayList(u32) = .empty;
    defer query_ids.deinit(alloc);
    var qit = queries.iterator();
    while (qit.next()) |e| if (e.value_ptr.*.owner == session) query_ids.append(alloc, e.key_ptr.*) catch {};
    for (query_ids.items) |id| if (queries.fetchRemove(id)) |e| {
        e.value.deinit();
        alloc.destroy(e.value);
    };
}
fn messageId(bytes: []const u8) ?u16 {
    if (bytes.len < 3) return null;
    return std.mem.readInt(u16, bytes[0..2], .little);
}
fn dispatch(server: *svc.Server, req: svc.Request) void {
    const id = messageId(req.blob) orelse return sendError(server, req, "malformed_request", "request is shorter than the wire header", null);
    switch (id) {
        wire.LANGUAGES_REQUEST_MSG_ID => languages(server, req),
        wire.OPEN_REQUEST_MSG_ID => open(server, req),
        wire.CLOSE_REQUEST_MSG_ID => close(server, req),
        wire.TREE_REQUEST_MSG_ID => treePage(server, req),
        wire.NODE_REQUEST_MSG_ID => node(server, req),
        wire.CHILDREN_REQUEST_MSG_ID => children(server, req),
        wire.TEXT_REQUEST_MSG_ID => text(server, req),
        wire.DIAGNOSTICS_REQUEST_MSG_ID => diagnostics(server, req),
        wire.QUERY_COMPILE_REQUEST_MSG_ID => compileQuery(server, req),
        wire.QUERY_REQUEST_MSG_ID => runQuery(server, req),
        wire.QUERY_CLOSE_REQUEST_MSG_ID => closeQuery(server, req),
        wire.EDIT_REQUEST_MSG_ID => edit(server, req, false),
        wire.REWRITE_REQUEST_MSG_ID => edit(server, req, true),
        else => sendError(server, req, "unknown_operation", "unknown syntax protocol message", null),
    }
}
fn respond(server: *svc.Server, req: svc.Request, value: anytype) void {
    const bytes = value.encode(alloc) catch return sendError(server, req, "out_of_memory", "response allocation failed", null);
    defer alloc.free(bytes);
    _ = server.respond(req.session, req.req_id, 0, bytes, true);
}
fn sendError(server: *svc.Server, req: svc.Request, code: []const u8, message: []const u8, revision: ?u32) void {
    const value = wire.ErrorResponse{ .code = code, .message = message, .current_revision = revision };
    const bytes = value.encode(alloc) catch {
        _ = server.respond(req.session, req.req_id, svc.EIO, "", true);
        return;
    };
    defer alloc.free(bytes);
    _ = server.respond(req.session, req.req_id, 0, bytes, true);
}
fn ownedDocument(session: u32, id: u32) ?*Document {
    const d = documents.get(id) orelse return null;
    return if (d.owner == session) d else null;
}
fn ownedQuery(session: u32, id: u32) ?*CompiledQuery {
    const q = queries.get(id) orelse return null;
    return if (q.owner == session) q else null;
}
fn sessionDocumentCount(session: u32) usize {
    var n: usize = 0;
    var it = documents.valueIterator();
    while (it.next()) |d| {
        if (d.*.owner == session) n += 1;
    }
    return n;
}
fn languages(server: *svc.Server, req: svc.Request) void {
    _ = wire.LanguagesRequest.decode(alloc, req.blob) catch return sendError(server, req, "malformed_request", "invalid languages request", null);
    var list: std.ArrayList(wire.LanguageDescriptor) = .empty;
    defer list.deinit(alloc);
    for (registry.descriptors) |d| {
        const map = d.semantic;
        list.append(alloc, .{ .name = d.name, .language_version = map.language_version, .grammar_version = map.grammar_version, .grammar_ir_version = map.grammar_ir_version, .vocabulary_version = map.vocabulary_version, .tree_sitter_abi = map.tree_sitter_abi }) catch return sendError(server, req, "out_of_memory", "language list allocation failed", null);
    }
    respond(server, req, wire.LanguagesResponse{ .languages = list.items });
}
fn open(server: *svc.Server, req: svc.Request) void {
    const msg = wire.OpenRequest.decode(alloc, req.blob) catch return sendError(server, req, "malformed_request", "invalid open request", null);
    if (msg.source.len > MAX_SOURCE) return sendError(server, req, "source_too_large", "source exceeds 768 KiB", null);
    if (sessionDocumentCount(req.session) >= MAX_DOCUMENTS_PER_SESSION) return sendError(server, req, "document_limit", "session document limit reached", null);
    const descriptor = registry.descriptor(msg.language) orelse return sendError(server, req, "unknown_language", "language is not installed", null);
    const language = registry.language(c, msg.language) orelse return sendError(server, req, "unknown_language", "language is not installed", null);
    const parser = c.ts_parser_new() orelse return sendError(server, req, "out_of_memory", "parser allocation failed", null);
    if (!c.ts_parser_set_language(parser, language)) {
        c.ts_parser_delete(parser);
        return sendError(server, req, "abi_mismatch", "generated parser ABI is unsupported", null);
    }
    const source = alloc.dupe(u8, msg.source) catch {
        c.ts_parser_delete(parser);
        return sendError(server, req, "out_of_memory", "source allocation failed", null);
    };
    const parsed = c.ts_parser_parse_string(parser, null, @ptrCast(source.ptr), @intCast(source.len)) orelse {
        alloc.free(source);
        c.ts_parser_delete(parser);
        return sendError(server, req, "parse_cancelled", "parse did not produce a tree", null);
    };
    const doc = alloc.create(Document) catch {
        c.ts_tree_delete(parsed);
        alloc.free(source);
        c.ts_parser_delete(parser);
        return sendError(server, req, "out_of_memory", "document allocation failed", null);
    };
    doc.* = .{ .owner = req.session, .descriptor = descriptor, .parser = parser, .tree = parsed, .source = source };
    const id = next_document;
    next_document +%= 1;
    if (next_document == 0) next_document = 1;
    documents.put(id, doc) catch {
        doc.deinit();
        alloc.destroy(doc);
        return sendError(server, req, "out_of_memory", "document table allocation failed", null);
    };
    const root = c.ts_tree_root_node(parsed);
    const summary = summarize(doc, root, null) catch return sendError(server, req, "out_of_memory", "node allocation failed", null);
    var diags = collectDiagnostics(doc) catch return sendError(server, req, "out_of_memory", "diagnostic allocation failed", null);
    defer diags.deinit(alloc);
    respond(server, req, wire.OpenResponse{ .document = id, .revision = doc.revision, .root = summary, .diagnostics = diags.items });
}
fn close(server: *svc.Server, req: svc.Request) void {
    const msg = wire.CloseRequest.decode(alloc, req.blob) catch return sendError(server, req, "malformed_request", "invalid close request", null);
    const doc = ownedDocument(req.session, msg.document) orelse return sendError(server, req, "stale_handle", "document handle is closed or foreign", null);
    _ = documents.remove(msg.document);
    doc.deinit();
    alloc.destroy(doc);
    respond(server, req, wire.CloseResponse{ .reserved = 0 });
}

fn point(p: c.TSPoint) wire.Point {
    return .{ .row = p.row, .column = p.column };
}
fn range(node_value: c.TSNode) wire.Range {
    return .{ .start_byte = c.ts_node_start_byte(node_value), .end_byte = c.ts_node_end_byte(node_value), .start_point = point(c.ts_node_start_point(node_value)), .end_point = point(c.ts_node_end_point(node_value)) };
}
fn summarize(doc: *Document, node_value: c.TSNode, field_role: ?u32) !wire.NodeSummary {
    const handle = doc.next_node_handle;
    doc.next_node_handle +%= 1;
    if (doc.next_node_handle == 0) doc.next_node_handle = 1;
    try doc.nodes.append(alloc, .{ .handle = handle, .value = node_value });
    const concrete = std.mem.span(c.ts_node_type(node_value));
    const semantic = registry.entry(doc.descriptor.semantic, c.ts_node_symbol(node_value));
    return .{ .handle = handle, .concrete_kind = concrete, .semantic_kind = if (semantic) |entry| entry.semantic_id else null, .field_role = field_role, .range = range(node_value), .named = c.ts_node_is_named(node_value), .missing = c.ts_node_is_missing(node_value), .@"error" = c.ts_node_is_error(node_value), .child_count = c.ts_node_child_count(node_value), .traits = if (semantic) |entry| registry.entryTraits(entry) else &.{} };
}
fn childRole(doc: *const Document, parent: c.TSNode, field_id: u16) ?u32 {
    if (field_id == 0) return null;
    const parent_entry = registry.entry(doc.descriptor.semantic, c.ts_node_symbol(parent)) orelse return null;
    return registry.entryRole(parent_entry, field_id);
}
fn checkedDoc(server: *svc.Server, req: svc.Request, id: u32, revision: u32) ?*Document {
    const doc = ownedDocument(req.session, id) orelse {
        sendError(server, req, "stale_handle", "document handle is closed or foreign", null);
        return null;
    };
    if (doc.revision != revision) {
        sendError(server, req, "revision_mismatch", "document revision is stale", doc.revision);
        return null;
    }
    return doc;
}
fn storedNode(doc: *Document, handle: u32) ?c.TSNode {
    if (handle == 0) return null;
    for (doc.nodes.items) |stored| if (stored.handle == handle) return stored.value;
    return null;
}

fn treePage(server: *svc.Server, req: svc.Request) void {
    const msg = wire.TreeRequest.decode(alloc, req.blob) catch return sendError(server, req, "malformed_request", "invalid tree request", null);
    const doc = checkedDoc(server, req, msg.document, msg.revision) orelse return;
    const skip: usize = if (msg.cursor) |v| v else 0;
    const limit = @min(@as(usize, msg.limit), MAX_PAGE_NODES);
    var nodes: std.ArrayList(wire.NodeSummary) = .empty;
    defer nodes.deinit(alloc);
    var stack: std.ArrayList(struct { node: c.TSNode, depth: u32 }) = .empty;
    defer stack.deinit(alloc);
    stack.append(alloc, .{ .node = c.ts_tree_root_node(doc.tree), .depth = 0 }) catch return sendError(server, req, "out_of_memory", "tree cursor allocation failed", null);
    var seen: usize = 0;
    while (stack.pop()) |item| {
        if (seen >= skip and nodes.items.len < limit) {
            nodes.append(alloc, summarize(doc, item.node, null) catch return sendError(server, req, "out_of_memory", "node allocation failed", null)) catch return sendError(server, req, "out_of_memory", "page allocation failed", null);
        }
        seen += 1;
        if (nodes.items.len >= limit) break;
        if (item.depth < msg.max_depth) {
            var i = c.ts_node_child_count(item.node);
            while (i > 0) {
                i -= 1;
                stack.append(alloc, .{ .node = c.ts_node_child(item.node, i), .depth = item.depth + 1 }) catch return sendError(server, req, "out_of_memory", "tree stack allocation failed", null);
            }
        }
    }
    const cursor: ?u32 = if (nodes.items.len == limit) @intCast(seen) else null;
    respond(server, req, wire.TreeResponse{ .nodes = nodes.items, .cursor = cursor });
}
fn node(server: *svc.Server, req: svc.Request) void {
    const msg = wire.NodeRequest.decode(alloc, req.blob) catch return sendError(server, req, "malformed_request", "invalid node request", null);
    const doc = checkedDoc(server, req, msg.document, msg.revision) orelse return;
    const value = storedNode(doc, msg.node) orelse return sendError(server, req, "stale_handle", "node handle is stale", doc.revision);
    const summary = summarize(doc, value, null) catch return sendError(server, req, "out_of_memory", "node allocation failed", null);
    respond(server, req, wire.NodeResponse{ .node = summary });
}
fn children(server: *svc.Server, req: svc.Request) void {
    const msg = wire.ChildrenRequest.decode(alloc, req.blob) catch return sendError(server, req, "malformed_request", "invalid children request", null);
    const doc = checkedDoc(server, req, msg.document, msg.revision) orelse return;
    const parent = storedNode(doc, msg.node) orelse return sendError(server, req, "stale_handle", "node handle is stale", doc.revision);
    const start: u32 = msg.cursor orelse 0;
    const limit: u32 = @min(msg.limit, MAX_PAGE_NODES);
    var out: std.ArrayList(wire.NodeSummary) = .empty;
    defer out.deinit(alloc);
    var i: u32 = 0;
    const count = c.ts_node_child_count(parent);
    var cursor = c.ts_tree_cursor_new(parent);
    defer c.ts_tree_cursor_delete(&cursor);
    if (count != 0 and c.ts_tree_cursor_goto_first_child(&cursor)) {
        while (i < count and out.items.len < limit) : (i += 1) {
            const child = c.ts_tree_cursor_current_node(&cursor);
            if (i >= start and (!msg.named_only or c.ts_node_is_named(child))) {
                const role = childRole(doc, parent, c.ts_tree_cursor_current_field_id(&cursor));
                out.append(alloc, summarize(doc, child, role) catch return sendError(server, req, "out_of_memory", "node allocation failed", null)) catch return sendError(server, req, "out_of_memory", "page allocation failed", null);
            }
            if (i + 1 < count and !c.ts_tree_cursor_goto_next_sibling(&cursor)) break;
        }
    }
    respond(server, req, wire.ChildrenResponse{ .nodes = out.items, .cursor = if (i < count) i else null });
}
fn text(server: *svc.Server, req: svc.Request) void {
    const msg = wire.TextRequest.decode(alloc, req.blob) catch return sendError(server, req, "malformed_request", "invalid text request", null);
    const doc = checkedDoc(server, req, msg.document, msg.revision) orelse return;
    var start: usize = 0;
    var end: usize = doc.source.len;
    if (msg.range) |r| {
        start = r.start_byte;
        end = r.end_byte;
    }
    if (start > end or end > doc.source.len) return sendError(server, req, "invalid_range", "text range is outside the source", doc.revision);
    respond(server, req, wire.TextResponse{ .text = doc.source[start..end] });
}
fn collectDiagnostics(doc: *Document) !std.ArrayList(wire.Diagnostic) {
    var out: std.ArrayList(wire.Diagnostic) = .empty;
    const root = c.ts_tree_root_node(doc.tree);
    if (c.ts_node_has_error(root)) try out.append(alloc, .{ .severity = "error", .code = "syntax_error", .message = "tree contains ERROR or MISSING nodes", .range = range(root) });
    return out;
}
fn diagnostics(server: *svc.Server, req: svc.Request) void {
    const msg = wire.DiagnosticsRequest.decode(alloc, req.blob) catch return sendError(server, req, "malformed_request", "invalid diagnostics request", null);
    const doc = checkedDoc(server, req, msg.document, msg.revision) orelse return;
    var values = collectDiagnostics(doc) catch return sendError(server, req, "out_of_memory", "diagnostic allocation failed", null);
    defer values.deinit(alloc);
    respond(server, req, wire.DiagnosticsResponse{ .diagnostics = values.items });
}

fn compileQuery(server: *svc.Server, req: svc.Request) void {
    const msg = wire.QueryCompileRequest.decode(alloc, req.blob) catch return sendError(server, req, "malformed_request", "invalid query request", null);
    if (msg.source.len > MAX_QUERY) return sendError(server, req, "query_too_large", "query exceeds 64 KiB", null);
    const descriptor = registry.descriptor(msg.language) orelse return sendError(server, req, "unknown_language", "language is not installed", null);
    const language = registry.language(c, msg.language) orelse return sendError(server, req, "unknown_language", "language is not installed", null);
    if (!std.mem.eql(u8, msg.view, "concrete") and !std.mem.eql(u8, msg.view, "semantic")) return sendError(server, req, "invalid_view", "view must be concrete or semantic", null);
    if (std.mem.eql(u8, msg.view, "semantic")) return sendError(server, req, "semantic_query_unavailable", "semantic query compiler is not initialized", null);
    var offset: u32 = 0;
    var kind: c.TSQueryError = c.TSQueryErrorNone;
    const q = c.ts_query_new(language, @ptrCast(msg.source.ptr), @intCast(msg.source.len), &offset, &kind) orelse return sendError(server, req, "invalid_query", "Tree-sitter rejected the query", null);
    const value = alloc.create(CompiledQuery) catch {
        c.ts_query_delete(q);
        return sendError(server, req, "out_of_memory", "query allocation failed", null);
    };
    value.* = .{ .owner = req.session, .descriptor = descriptor, .query = q };
    const id = next_query;
    next_query +%= 1;
    if (next_query == 0) next_query = 1;
    queries.put(id, value) catch {
        value.deinit();
        alloc.destroy(value);
        return sendError(server, req, "out_of_memory", "query table allocation failed", null);
    };
    respond(server, req, wire.QueryCompileResponse{ .query = id, .diagnostics = &.{} });
}
fn runQuery(server: *svc.Server, req: svc.Request) void {
    const msg = wire.QueryRequest.decode(alloc, req.blob) catch return sendError(server, req, "malformed_request", "invalid query execution request", null);
    const doc = checkedDoc(server, req, msg.document, msg.revision) orelse return;
    const query = ownedQuery(req.session, msg.query) orelse return sendError(server, req, "stale_handle", "query handle is closed or foreign", null);
    if (doc.descriptor != query.descriptor) return sendError(server, req, "language_mismatch", "query and document languages differ", doc.revision);
    const cursor = c.ts_query_cursor_new() orelse return sendError(server, req, "out_of_memory", "query cursor allocation failed", null);
    defer c.ts_query_cursor_delete(cursor);
    c.ts_query_cursor_exec(cursor, query.query, c.ts_tree_root_node(doc.tree));
    if (msg.range) |r| _ = c.ts_query_cursor_set_byte_range(cursor, r.start_byte, r.end_byte);
    var out: std.ArrayList(wire.Capture) = .empty;
    defer out.deinit(alloc);
    var match: c.TSQueryMatch = undefined;
    var capture_index: u32 = 0;
    var seen: u32 = 0;
    const skip = msg.cursor orelse 0;
    while (out.items.len < @min(@as(usize, msg.limit), MAX_PAGE_CAPTURES) and c.ts_query_cursor_next_capture(cursor, &match, &capture_index)) {
        if (seen < skip) {
            seen += 1;
            continue;
        }
        const capture = match.captures[capture_index];
        var name_len: u32 = 0;
        const name_ptr = c.ts_query_capture_name_for_id(query.query, capture.index, &name_len);
        const name = name_ptr[0..name_len];
        const summary = summarize(doc, capture.node, null) catch return sendError(server, req, "out_of_memory", "capture allocation failed", null);
        const r = range(capture.node);
        const captured_text: ?[]const u8 = if (msg.include_text and r.end_byte <= doc.source.len) doc.source[r.start_byte..r.end_byte] else null;
        out.append(alloc, .{ .name = name, .node = summary, .text = captured_text }) catch return sendError(server, req, "out_of_memory", "capture page allocation failed", null);
        seen += 1;
    }
    respond(server, req, wire.QueryResponse{ .captures = out.items, .cursor = if (out.items.len == @min(@as(usize, msg.limit), MAX_PAGE_CAPTURES)) seen else null });
}
fn closeQuery(server: *svc.Server, req: svc.Request) void {
    const msg = wire.QueryCloseRequest.decode(alloc, req.blob) catch return sendError(server, req, "malformed_request", "invalid query close request", null);
    const q = ownedQuery(req.session, msg.query) orelse return sendError(server, req, "stale_handle", "query handle is closed or foreign", null);
    _ = queries.remove(msg.query);
    q.deinit();
    alloc.destroy(q);
    respond(server, req, wire.QueryCloseResponse{ .reserved = 0 });
}

const PendingEdit = struct { start: u32, old_end: u32, replacement: []const u8, expected: ?[]const u8 = null };
fn editLess(_: void, a: PendingEdit, b: PendingEdit) bool {
    return a.start < b.start;
}
fn sourcePoint(source: []const u8, offset: u32) c.TSPoint {
    var out = c.TSPoint{ .row = 0, .column = 0 };
    for (source[0..offset]) |byte_value| {
        if (byte_value == '\n') {
            out.row += 1;
            out.column = 0;
        } else out.column += 1;
    }
    return out;
}
fn replacementEnd(start: c.TSPoint, replacement: []const u8) c.TSPoint {
    var out = start;
    for (replacement) |byte_value| {
        if (byte_value == '\n') {
            out.row += 1;
            out.column = 0;
        } else out.column += 1;
    }
    return out;
}
fn applyEdits(server: *svc.Server, req: svc.Request, doc: *Document, pending: []PendingEdit, validation: []const u8, rewrite: bool) void {
    if (pending.len == 0) return sendError(server, req, "empty_edit", "edit transaction must contain at least one change", doc.revision);
    std.mem.sort(PendingEdit, pending, {}, editLess);
    var previous_end: u32 = 0;
    for (pending) |item| {
        if (item.start > item.old_end or item.old_end > doc.source.len) return sendError(server, req, "invalid_range", "edit range is outside the source", doc.revision);
        if (item.start < previous_end) return sendError(server, req, "overlapping_edits", "edit ranges overlap", doc.revision);
        previous_end = item.old_end;
        if (rewrite) {
            const expected = item.expected orelse return sendError(server, req, "missing_digest", "rewrite edit needs expected_sha256", doc.revision);
            if (expected.len != 32) return sendError(server, req, "invalid_digest", "expected_sha256 must be 32 bytes", doc.revision);
            var actual: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(doc.source[item.start..item.old_end], &actual, .{});
            if (!std.mem.eql(u8, &actual, expected)) return sendError(server, req, "digest_mismatch", "source bytes changed since the rewrite was planned", doc.revision);
        }
    }
    var candidate: std.ArrayList(u8) = .empty;
    errdefer candidate.deinit(alloc);
    var cursor: usize = 0;
    for (pending) |item| {
        candidate.appendSlice(alloc, doc.source[cursor..item.start]) catch return sendError(server, req, "out_of_memory", "candidate source allocation failed", doc.revision);
        candidate.appendSlice(alloc, item.replacement) catch return sendError(server, req, "out_of_memory", "candidate source allocation failed", doc.revision);
        cursor = item.old_end;
    }
    candidate.appendSlice(alloc, doc.source[cursor..]) catch return sendError(server, req, "out_of_memory", "candidate source allocation failed", doc.revision);
    if (candidate.items.len > MAX_SOURCE) {
        candidate.deinit(alloc);
        return sendError(server, req, "source_too_large", "edited source exceeds 768 KiB", doc.revision);
    }
    const edited_tree = c.ts_tree_copy(doc.tree) orelse {
        candidate.deinit(alloc);
        return sendError(server, req, "out_of_memory", "tree copy failed", doc.revision);
    };
    defer c.ts_tree_delete(edited_tree);
    var i = pending.len;
    while (i > 0) {
        i -= 1;
        const item = pending[i];
        var input = c.TSInputEdit{ .start_byte = item.start, .old_end_byte = item.old_end, .new_end_byte = item.start + @as(u32, @intCast(item.replacement.len)), .start_point = sourcePoint(doc.source, item.start), .old_end_point = sourcePoint(doc.source, item.old_end), .new_end_point = undefined };
        input.new_end_point = replacementEnd(input.start_point, item.replacement);
        c.ts_tree_edit(edited_tree, &input);
    }
    const new_tree = c.ts_parser_parse_string(doc.parser, edited_tree, @ptrCast(candidate.items.ptr), @intCast(candidate.items.len)) orelse {
        candidate.deinit(alloc);
        return sendError(server, req, "parse_cancelled", "incremental parse was cancelled", doc.revision);
    };
    const has_error = c.ts_node_has_error(c.ts_tree_root_node(new_tree));
    const old_error = c.ts_node_has_error(c.ts_tree_root_node(doc.tree));
    if ((std.mem.eql(u8, validation, "error_free") and has_error) or (std.mem.eql(u8, validation, "no_new_errors") and !old_error and has_error)) {
        c.ts_tree_delete(new_tree);
        candidate.deinit(alloc);
        return sendError(server, req, "validation_failed", "rewrite syntax validation rejected the candidate", doc.revision);
    }
    if (!std.mem.eql(u8, validation, "allow") and !std.mem.eql(u8, validation, "no_new_errors") and !std.mem.eql(u8, validation, "error_free")) {
        c.ts_tree_delete(new_tree);
        candidate.deinit(alloc);
        return sendError(server, req, "invalid_validation", "unknown rewrite validation policy", doc.revision);
    }
    var changed_count: u32 = 0;
    const changed_ptr = c.ts_tree_get_changed_ranges(doc.tree, new_tree, &changed_count);
    defer if (changed_ptr != null) c.free(changed_ptr);
    var changed: std.ArrayList(wire.ChangedRange) = .empty;
    defer changed.deinit(alloc);
    var ci: u32 = 0;
    while (ci < changed_count) : (ci += 1) {
        const r = changed_ptr[ci];
        changed.append(alloc, .{ .range = .{ .start_byte = r.start_byte, .end_byte = r.end_byte, .start_point = point(r.start_point), .end_point = point(r.end_point) } }) catch {
            c.ts_tree_delete(new_tree);
            candidate.deinit(alloc);
            return sendError(server, req, "out_of_memory", "changed-range allocation failed", doc.revision);
        };
    }
    c.ts_tree_delete(doc.tree);
    alloc.free(doc.source);
    doc.tree = new_tree;
    doc.source = candidate.toOwnedSlice(alloc) catch unreachable;
    doc.revision +%= 1;
    if (doc.revision == 0) doc.revision = 1;
    doc.nodes.clearRetainingCapacity();
    var diags = collectDiagnostics(doc) catch return sendError(server, req, "out_of_memory", "diagnostic allocation failed", doc.revision);
    defer diags.deinit(alloc);
    if (rewrite) respond(server, req, wire.RewriteResponse{ .revision = doc.revision, .changed = changed.items, .diagnostics = diags.items }) else respond(server, req, wire.EditResponse{ .revision = doc.revision, .changed = changed.items, .diagnostics = diags.items });
}
fn edit(server: *svc.Server, req: svc.Request, rewrite: bool) void {
    var pending: std.ArrayList(PendingEdit) = .empty;
    defer pending.deinit(alloc);
    if (rewrite) {
        const msg = wire.RewriteRequest.decode(alloc, req.blob) catch return sendError(server, req, "malformed_request", "invalid rewrite request", null);
        defer alloc.free(msg.edits);
        const doc = checkedDoc(server, req, msg.document, msg.revision) orelse return;
        for (msg.edits) |item| pending.append(alloc, .{ .start = item.start_byte, .old_end = item.old_end_byte, .replacement = item.replacement, .expected = item.expected_sha256 }) catch return sendError(server, req, "out_of_memory", "edit list allocation failed", doc.revision);
        applyEdits(server, req, doc, pending.items, msg.validation, true);
    } else {
        const msg = wire.EditRequest.decode(alloc, req.blob) catch return sendError(server, req, "malformed_request", "invalid edit request", null);
        defer alloc.free(msg.edits);
        const doc = checkedDoc(server, req, msg.document, msg.revision) orelse return;
        for (msg.edits) |item| pending.append(alloc, .{ .start = item.start_byte, .old_end = item.old_end_byte, .replacement = item.replacement }) catch return sendError(server, req, "out_of_memory", "edit list allocation failed", doc.revision);
        applyEdits(server, req, doc, pending.items, "allow", false);
    }
}

fn writeOut(fd: i32, bytes: []const u8) void {
    var written: u32 = 0;
    _ = mc.mc_sys_write(fd, mc.addr(bytes.ptr), @intCast(bytes.len), mc.addr(&written));
}
fn cliUsage() noreturn {
    writeOut(2, "usage: syntax languages | syntax {parse|check} LANGUAGE FILE | syntax query LANGUAGE FILE QUERY\n");
    exit(2);
}
fn cliCall(conn: i32, bytes: []const u8) ?[]u8 {
    var result_fd: u32 = 0;
    if (mc.mc_sys_svc_call(conn, mc.addr(bytes.ptr), @intCast(bytes.len), 0, 0, mc.addr(&result_fd)) != 0) return null;
    var out: std.ArrayList(u8) = .empty;
    var buffer: [4096]u8 = undefined;
    while (true) {
        var count: u32 = 0;
        if (mc.mc_sys_read(@intCast(result_fd), mc.addr(&buffer), buffer.len, mc.addr(&count)) != 0) {
            out.deinit(alloc);
            _ = mc.mc_sys_close(@intCast(result_fd));
            return null;
        }
        if (count == 0) break;
        out.appendSlice(alloc, buffer[0..count]) catch {
            out.deinit(alloc);
            _ = mc.mc_sys_close(@intCast(result_fd));
            return null;
        };
    }
    _ = mc.mc_sys_close(@intCast(result_fd));
    return out.toOwnedSlice(alloc) catch null;
}
fn cliResponse(conn: i32, request: anytype) []u8 {
    const encoded = request.encode(alloc) catch {
        writeOut(2, "syntax: cannot encode request\n");
        exit(1);
    };
    defer alloc.free(encoded);
    const response = cliCall(conn, encoded) orelse {
        writeOut(2, "syntax: service call failed\n");
        exit(1);
    };
    if (messageId(response) == wire.ERROR_RESPONSE_MSG_ID) {
        const failure = wire.ErrorResponse.decode(alloc, response) catch {
            writeOut(2, "syntax: malformed error response\n");
            exit(1);
        };
        const line = std.fmt.allocPrint(alloc, "syntax: {s}: {s}\n", .{ failure.code, failure.message }) catch exit(1);
        writeOut(2, line);
        exit(1);
    }
    return response;
}
fn cliSource(path: []const u8) []const u8 {
    return switch (sys.readFileAlloc(alloc, path)) {
        .ok => |source| source,
        .err => {
            writeOut(2, "syntax: cannot read source file\n");
            exit(1);
        },
    };
}
const CliOpen = struct { value: wire.OpenResponse, backing: []u8 };
fn cliOpen(conn: i32, language: []const u8, path: []const u8) CliOpen {
    const source = cliSource(path);
    defer alloc.free(source);
    const bytes = cliResponse(conn, wire.OpenRequest{ .language = language, .source = source });
    const value = wire.OpenResponse.decode(alloc, bytes) catch {
        alloc.free(bytes);
        writeOut(2, "syntax: malformed open response\n");
        exit(1);
    };
    return .{ .value = value, .backing = bytes };
}
fn cli(args: []const u8) void {
    var words = std.mem.splitScalar(u8, args, 0);
    _ = words.next();
    const operation = words.next() orelse cliUsage();
    var conn_value: u32 = 0;
    if (mc.mc_sys_svc_connect(mc.addr(SERVICE_NAME.ptr), SERVICE_NAME.len, mc.addr(&conn_value)) != 0) {
        writeOut(2, "syntax: service unavailable\n");
        exit(1);
    }
    const conn: i32 = @intCast(conn_value);
    if (std.mem.eql(u8, operation, "languages")) {
        const bytes = cliResponse(conn, wire.LanguagesRequest{ .reserved = 0 });
        defer alloc.free(bytes);
        const response = wire.LanguagesResponse.decode(alloc, bytes) catch exit(1);
        for (response.languages) |language| {
            const line = std.fmt.allocPrint(alloc, "{s}\t{s}\n", .{ language.name, language.language_version }) catch exit(1);
            defer alloc.free(line);
            writeOut(1, line);
        }
        exit(0);
    }
    const language = words.next() orelse cliUsage();
    const path = words.next() orelse cliUsage();
    const opened_response = cliOpen(conn, language, path);
    defer alloc.free(opened_response.backing);
    const opened = opened_response.value;
    if (std.mem.eql(u8, operation, "parse")) {
        const line = std.fmt.allocPrint(alloc, "{s}\t{d}:{d}\n", .{ opened.root.concrete_kind, opened.root.range.start_byte, opened.root.range.end_byte }) catch exit(1);
        writeOut(1, line);
        exit(0);
    }
    if (std.mem.eql(u8, operation, "check")) {
        for (opened.diagnostics) |diagnostic| {
            const line = std.fmt.allocPrint(alloc, "{s}\t{s}\t{s}\n", .{ diagnostic.severity, diagnostic.code, diagnostic.message }) catch exit(1);
            writeOut(1, line);
        }
        exit(if (opened.diagnostics.len == 0) 0 else 1);
    }
    if (std.mem.eql(u8, operation, "query")) {
        const query_source = words.next() orelse cliUsage();
        var bytes = cliResponse(conn, wire.QueryCompileRequest{ .language = language, .source = query_source, .view = "concrete" });
        const compiled = wire.QueryCompileResponse.decode(alloc, bytes) catch exit(1);
        alloc.free(bytes);
        bytes = cliResponse(conn, wire.QueryRequest{ .document = opened.document, .revision = opened.revision, .query = compiled.query, .range = null, .include_text = true, .limit = MAX_PAGE_CAPTURES, .cursor = null });
        const matches = wire.QueryResponse.decode(alloc, bytes) catch exit(1);
        for (matches.captures) |capture| {
            const line = std.fmt.allocPrint(alloc, "{s}\t{s}\n", .{ capture.name, capture.text orelse "" }) catch exit(1);
            writeOut(1, line);
        }
        exit(0);
    }
    cliUsage();
}
