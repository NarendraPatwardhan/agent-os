//! vann — a deterministic vector ANN virtual table for the sqlite resident service.
//!
//! The module intentionally lives inside /bin/sqlite. The kernel ABI, svc protocol, and WASI VFS stay
//! unchanged: SQL is the only public surface. The durable graph is stored in shadow tables in the same
//! database file; this Zig module keeps a warm HNSW cache per sqlite connection and reloads it from the
//! journal-backed shadow state after rollbacks or external commits.

const std = @import("std");
const c = @import("sqlite.zig").c;

const alloc = std.heap.c_allocator;
const SQLITE_TRANSIENT: c.sqlite3_destructor_type = @ptrFromInt(std.math.maxInt(usize));

const FORMAT_VERSION = 1;
const DEFAULT_M: usize = 16;
const DEFAULT_EF_CONSTRUCTION: usize = 96;
const DEFAULT_EF_SEARCH: usize = 64;
const DEFAULT_CACHE_NODES: usize = 65536;
const EXACT_TINY_TABLE = 16;
const VQ_MAGIC = "VQ1\x00";
const VQ_HEADER_LEN: usize = 12;
const NODE_HEADER_ESTIMATE_BYTES: i64 = 64;

const ElemType = enum(u8) {
    f32 = 1,
    int8 = 2,
    bit = 3,
};

const Metric = enum(u8) {
    l2 = 1,
    cosine = 2,
    ip = 3,
    hamming = 4,
};

const ColumnKind = enum {
    vector,
    partition,
    metadata,
    aux,
    hidden_distance,
    hidden_k,
    hidden_ef,
};

const ValueType = enum {
    any,
    integer,
    real,
    text,
    blob,
};

const Column = struct {
    name: []u8,
    kind: ColumnKind,
    value_type: ValueType,

    fn deinit(self: *Column) void {
        alloc.free(self.name);
    }
};

const Config = struct {
    dims: u32 = 0,
    elem_type: ElemType = .f32,
    metric: Metric = .cosine,
    m: usize = DEFAULT_M,
    ef_construction: usize = DEFAULT_EF_CONSTRUCTION,
    ef_search: usize = DEFAULT_EF_SEARCH,
    cache_nodes: usize = DEFAULT_CACHE_NODES,
    vector_col: usize = 0,
    distance_col: usize = 0,
    k_col: usize = 0,
    ef_col: usize = 0,
    visible_cols: usize = 0,
};

const CellTag = enum(u8) {
    null = 0,
    integer = 1,
    real = 2,
    text = 3,
    blob = 4,
};

const Cell = union(CellTag) {
    null: void,
    integer: i64,
    real: f64,
    text: []u8,
    blob: []u8,

    fn clone(self: Cell) !Cell {
        return switch (self) {
            .null => .{ .null = {} },
            .integer => |v| .{ .integer = v },
            .real => |v| .{ .real = v },
            .text => |v| .{ .text = try alloc.dupe(u8, v) },
            .blob => |v| .{ .blob = try alloc.dupe(u8, v) },
        };
    }

    fn deinit(self: *Cell) void {
        switch (self.*) {
            .text => |v| alloc.free(v),
            .blob => |v| alloc.free(v),
            else => {},
        }
        self.* = .{ .null = {} };
    }

    fn result(self: Cell, ctx: ?*c.sqlite3_context) void {
        switch (self) {
            .null => c.sqlite3_result_null(ctx),
            .integer => |v| c.sqlite3_result_int64(ctx, v),
            .real => |v| c.sqlite3_result_double(ctx, v),
            .text => |v| c.sqlite3_result_text(ctx, ptrOrEmpty(v), @intCast(v.len), null),
            .blob => |v| c.sqlite3_result_blob(ctx, ptrOrEmpty(v), @intCast(v.len), null),
        }
    }
};

fn deinitCellSlice(cells: []Cell) void {
    for (cells) |*cell| cell.deinit();
    alloc.free(cells);
}

fn cloneCellSlice(cells: []const Cell) ![]Cell {
    const out = try alloc.alloc(Cell, cells.len);
    for (out) |*cell| cell.* = .{ .null = {} };
    errdefer deinitCellSlice(out);
    for (cells, 0..) |cell, i| out[i] = try cell.clone();
    return out;
}

const VectorValue = struct {
    elem_type: ElemType,
    dims: u32,
    floats: []f32 = &.{},
    bits: []u8 = &.{},
    blob: []u8,

    fn deinit(self: *VectorValue) void {
        if (self.floats.len > 0) alloc.free(self.floats);
        if (self.bits.len > 0) alloc.free(self.bits);
        alloc.free(self.blob);
    }
};

const QuantizedValue = struct {
    values: []i8,
    scale: f32 = 1,
    offset: f32 = 0,

    fn deinit(self: *QuantizedValue) void {
        alloc.free(self.values);
    }
};

const BitText = struct {
    bytes: []u8,
    dims: u32,
};

const Node = struct {
    id: u32,
    rowid: i64,
    level: u8,
    deleted: bool = false,
    part_key: []u8,
    values: []Cell,
    vec_blob: []u8,
    floats: []f32 = &.{},
    bits: []u8 = &.{},
    q: []i8 = &.{},
    q_scale: f32 = 1,
    q_offset: f32 = 0,
    last_used: u64 = 0,
    adj: std.ArrayList(std.ArrayList(u32)),

    fn create(id: u32, rowid: i64, level: u8, part_key: []u8, values: []Cell, vec: VectorValue, q: QuantizedValue, adj_blob: ?[]const u8, transferred: ?*bool) !*Node {
        const n = try alloc.create(Node);
        if (transferred) |flag| flag.* = true;
        n.* = .{
            .id = id,
            .rowid = rowid,
            .level = level,
            .part_key = part_key,
            .values = values,
            .vec_blob = vec.blob,
            .floats = vec.floats,
            .bits = vec.bits,
            .q = q.values,
            .q_scale = q.scale,
            .q_offset = q.offset,
            .adj = .empty,
        };
        errdefer n.deinit();
        if (adj_blob) |blob| {
            try n.readAdj(blob);
        } else {
            var l: usize = 0;
            while (l <= level) : (l += 1) {
                try n.adj.append(alloc, .empty);
            }
        }
        return n;
    }

    fn deinit(self: *Node) void {
        alloc.free(self.part_key);
        for (self.values) |*v| v.deinit();
        alloc.free(self.values);
        alloc.free(self.vec_blob);
        if (self.floats.len > 0) alloc.free(self.floats);
        if (self.bits.len > 0) alloc.free(self.bits);
        if (self.q.len > 0) alloc.free(self.q);
        for (self.adj.items) |*level| level.deinit(alloc);
        self.adj.deinit(alloc);
        alloc.destroy(self);
    }

    fn ensureLevel(self: *Node, level: usize) !void {
        while (self.adj.items.len <= level) {
            try self.adj.append(alloc, .empty);
        }
        if (level > self.level) self.level = @intCast(level);
    }

    fn clone(self: *const Node) !*Node {
        const n = try alloc.create(Node);
        n.* = .{
            .id = self.id,
            .rowid = self.rowid,
            .level = self.level,
            .deleted = self.deleted,
            .part_key = &.{},
            .values = &.{},
            .vec_blob = &.{},
            .floats = &.{},
            .bits = &.{},
            .q = &.{},
            .q_scale = self.q_scale,
            .q_offset = self.q_offset,
            .last_used = self.last_used,
            .adj = .empty,
        };
        errdefer n.deinit();
        n.part_key = try alloc.dupe(u8, self.part_key);
        n.values = try alloc.alloc(Cell, self.values.len);
        for (n.values) |*v| v.* = .{ .null = {} };
        for (self.values, 0..) |cell, i| n.values[i] = try cell.clone();
        n.vec_blob = try alloc.dupe(u8, self.vec_blob);
        n.floats = try alloc.dupe(f32, self.floats);
        n.bits = try alloc.dupe(u8, self.bits);
        n.q = try alloc.dupe(i8, self.q);
        for (self.adj.items) |level| {
            try n.adj.append(alloc, .empty);
            try n.adj.items[n.adj.items.len - 1].appendSlice(alloc, level.items);
        }
        return n;
    }

    fn readAdj(self: *Node, blob: []const u8) !void {
        if (blob.len < 4) return error.MalformedAdjacency;
        var pos: usize = 0;
        const levels = readU32(blob, &pos) orelse return error.MalformedAdjacency;
        var l: usize = 0;
        while (l < levels) : (l += 1) {
            const count = readU32(blob, &pos) orelse return error.MalformedAdjacency;
            var list: std.ArrayList(u32) = .empty;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                try list.append(alloc, readU32(blob, &pos) orelse return error.MalformedAdjacency);
            }
            try self.adj.append(alloc, list);
        }
        while (self.adj.items.len <= self.level) {
            try self.adj.append(alloc, .empty);
        }
    }

    fn writeAdj(self: *const Node) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try writeU32(&out, @intCast(self.adj.items.len));
        for (self.adj.items) |level| {
            try writeU32(&out, @intCast(level.items.len));
            for (level.items) |id| try writeU32(&out, id);
        }
        return try out.toOwnedSlice(alloc);
    }
};

const ConstraintOp = enum(u8) {
    eq,
    gt,
    ge,
    lt,
    le,
    match,
    limit,
};

const PlanConstraint = struct {
    col: i32,
    op: ConstraintOp,
    argv_index: usize,
};

const SearchResult = struct {
    id: u32,
    rowid: i64,
    distance: f64,
};

const Neighbor = struct {
    id: u32,
    distance: f64,
};

const Candidate = struct {
    id: u32,
    distance: f64,
    expanded: bool = false,
};

const QueryFilter = struct {
    col: usize,
    op: ConstraintOp,
    value: Cell,

    fn deinit(self: *QueryFilter) void {
        self.value.deinit();
    }
};

fn deinitFilterList(filters: *std.ArrayList(QueryFilter)) void {
    for (filters.items) |*f| f.deinit();
    filters.deinit(alloc);
    filters.* = .empty;
}

const NodeUndo = struct {
    id: u32,
    prev: ?*Node,
};

const RowMapUndo = struct {
    rowid: i64,
    prev: ?u32,
};

const UndoOp = union(enum) {
    node: NodeUndo,
    row_map: RowMapUndo,
    free_pop: u32,
    free_append: u32,
    nodes_append: u32,

    fn deinit(self: *UndoOp) void {
        switch (self.*) {
            .node => |u| if (u.prev) |n| n.deinit(),
            else => {},
        }
    }
};

const UndoFrame = struct {
    id: c_int,
    undo_len: usize,
    version: i64,
    prng: Xoshiro,
};

const VTab = struct {
    base: c.sqlite3_vtab,
    db: ?*c.sqlite3,
    schema: []u8,
    name: []u8,
    prefix: []u8,
    columns: []Column,
    config: Config,
    nodes: std.ArrayList(?*Node),
    live_ids: std.AutoHashMap(u32, void),
    row_map: std.AutoHashMap(i64, u32),
    free_ids: std.ArrayList(u32),
    resident_count: usize = 0,
    lru_clock: u64 = 0,
    cache_faults: u64 = 0,
    version: i64 = -1,
    prng: Xoshiro,
    undo: std.ArrayList(UndoOp),
    frames: std.ArrayList(UndoFrame),

    fn create(db: ?*c.sqlite3, schema: []const u8, name: []const u8, columns: []Column, config: Config) !*VTab {
        const t = try alloc.create(VTab);
        t.* = .{
            .base = .{ .pModule = null, .nRef = 0, .zErrMsg = null },
            .db = db,
            .schema = try alloc.dupe(u8, schema),
            .name = try alloc.dupe(u8, name),
            .prefix = try makeShadowPrefix(name),
            .columns = columns,
            .config = config,
            .nodes = .empty,
            .live_ids = std.AutoHashMap(u32, void).init(alloc),
            .row_map = std.AutoHashMap(i64, u32).init(alloc),
            .free_ids = .empty,
            .resident_count = 0,
            .lru_clock = 0,
            .cache_faults = 0,
            .prng = Xoshiro.init(hashSeed(name)),
            .undo = .empty,
            .frames = .empty,
        };
        return t;
    }

    fn deinit(self: *VTab) void {
        self.clearUndoLog();
        self.undo.deinit(alloc);
        self.frames.deinit(alloc);
        self.clearNodes();
        self.nodes.deinit(alloc);
        self.live_ids.deinit();
        self.row_map.deinit();
        self.free_ids.deinit(alloc);
        deinitColumns(self.columns);
        alloc.free(self.schema);
        alloc.free(self.name);
        alloc.free(self.prefix);
        if (self.base.zErrMsg != null) c.sqlite3_free(self.base.zErrMsg);
        alloc.destroy(self);
    }

    fn clearNodes(self: *VTab) void {
        for (self.nodes.items) |maybe| {
            if (maybe) |n| n.deinit();
        }
        self.nodes.clearRetainingCapacity();
        self.live_ids.clearRetainingCapacity();
        self.row_map.clearRetainingCapacity();
        self.free_ids.clearRetainingCapacity();
        self.resident_count = 0;
        self.cache_faults = 0;
    }

    fn clearUndoLog(self: *VTab) void {
        for (self.undo.items) |*op| op.deinit();
        self.undo.clearRetainingCapacity();
        self.frames.clearRetainingCapacity();
    }

    fn beginUndoFrame(self: *VTab, id: c_int) !void {
        try self.frames.append(alloc, .{
            .id = id,
            .undo_len = self.undo.items.len,
            .version = self.version,
            .prng = self.prng,
        });
    }

    fn resetUndoForTransaction(self: *VTab) !void {
        self.clearUndoLog();
        try self.beginUndoFrame(-1);
    }

    fn ensureUndoFrame(self: *VTab) !void {
        if (self.frames.items.len == 0) try self.beginUndoFrame(-1);
    }

    fn currentUndoStart(self: *const VTab) usize {
        if (self.frames.items.len == 0) return 0;
        return self.frames.items[self.frames.items.len - 1].undo_len;
    }

    fn recordNodeBefore(self: *VTab, id: u32) !void {
        try self.ensureUndoFrame();
        const start = self.currentUndoStart();
        for (self.undo.items[start..]) |op| {
            if (op == .node and op.node.id == id) return;
        }
        var prev = if (try self.nodeResident(id)) |n| try n.clone() else null;
        errdefer if (prev) |n| n.deinit();
        try self.undo.append(alloc, .{ .node = .{ .id = id, .prev = prev } });
        prev = null;
    }

    fn recordRowMapBefore(self: *VTab, rowid: i64) !void {
        try self.ensureUndoFrame();
        const start = self.currentUndoStart();
        for (self.undo.items[start..]) |op| {
            if (op == .row_map and op.row_map.rowid == rowid) return;
        }
        try self.undo.append(alloc, .{ .row_map = .{ .rowid = rowid, .prev = self.row_map.get(rowid) } });
    }

    fn recordFreePop(self: *VTab, id: u32) !void {
        try self.ensureUndoFrame();
        try self.undo.append(alloc, .{ .free_pop = id });
    }

    fn recordFreeAppend(self: *VTab, id: u32) !void {
        try self.ensureUndoFrame();
        try self.undo.append(alloc, .{ .free_append = id });
    }

    fn recordNodesAppend(self: *VTab, id: u32) !void {
        try self.ensureUndoFrame();
        try self.undo.append(alloc, .{ .nodes_append = id });
    }

    fn rollbackUndoTo(self: *VTab, undo_len: usize, version: i64, prng: Xoshiro) !void {
        while (self.undo.items.len > undo_len) {
            var op = self.undo.pop().?;
            switch (op) {
                .node => |*u| {
                    if (u.id < self.nodes.items.len) {
                        if (self.nodes.items[u.id]) |cur| {
                            cur.deinit();
                            self.resident_count -|= 1;
                        }
                        self.nodes.items[u.id] = null;
                    } else if (u.prev != null) {
                        while (self.nodes.items.len <= u.id) try self.nodes.append(alloc, null);
                    }
                    if (u.prev) |prev| {
                        try self.live_ids.put(u.id, {});
                        self.touchNode(prev);
                        self.nodes.items[u.id] = prev;
                        self.resident_count += 1;
                        u.prev = null;
                    } else {
                        _ = self.live_ids.remove(u.id);
                    }
                },
                .row_map => |u| {
                    if (u.prev) |id| {
                        try self.row_map.put(u.rowid, id);
                    } else {
                        _ = self.row_map.remove(u.rowid);
                    }
                },
                .free_pop => |id| {
                    try self.free_ids.append(alloc, id);
                },
                .free_append => |id| {
                    self.removeFreeId(id);
                },
                .nodes_append => |id| {
                    _ = self.live_ids.remove(id);
                    if (id < self.nodes.items.len) {
                        if (self.nodes.items[id]) |cur| {
                            cur.deinit();
                            self.resident_count -|= 1;
                            self.nodes.items[id] = null;
                        }
                        if (id + 1 == self.nodes.items.len) _ = self.nodes.pop();
                    }
                },
            }
            op.deinit();
        }
        self.version = version;
        self.prng = prng;
    }

    fn removeFreeId(self: *VTab, id: u32) void {
        var i = self.free_ids.items.len;
        while (i > 0) {
            i -= 1;
            if (self.free_ids.items[i] == id) {
                _ = self.free_ids.swapRemove(i);
                return;
            }
        }
    }

    fn touchNode(self: *VTab, n: *Node) void {
        self.lru_clock +%= 1;
        n.last_used = self.lru_clock;
    }

    fn findFrame(self: *VTab, id: c_int) ?usize {
        var i = self.frames.items.len;
        while (i > 0) {
            i -= 1;
            if (self.frames.items[i].id == id) return i;
        }
        return null;
    }

    fn setError(self: *VTab, msg: []const u8) c_int {
        if (self.base.zErrMsg != null) c.sqlite3_free(self.base.zErrMsg);
        self.base.zErrMsg = sqliteMallocString(msg);
        return c.SQLITE_ERROR;
    }

    fn ensureShadowTables(self: *VTab) !void {
        const meta = try self.shadowName("_meta");
        defer alloc.free(meta);
        const node_table = try self.shadowName("_node");
        defer alloc.free(node_table);
        const vec = try self.shadowName("_vec");
        defer alloc.free(vec);
        const q_meta = try qualifiedName(self.schema, meta);
        defer alloc.free(q_meta);
        const q_node = try qualifiedName(self.schema, node_table);
        defer alloc.free(q_node);
        const q_vec = try qualifiedName(self.schema, vec);
        defer alloc.free(q_vec);
        const meta_sql = try std.fmt.allocPrint(
            alloc,
            "CREATE TABLE IF NOT EXISTS {s}(key TEXT PRIMARY KEY, value BLOB NOT NULL)",
            .{q_meta},
        );
        defer freeQuotedSql(meta_sql);
        try execOwned(self.db, meta_sql);
        const node_sql = try std.fmt.allocPrint(
            alloc,
            "CREATE TABLE IF NOT EXISTS {s}(id INTEGER PRIMARY KEY,rowid INTEGER UNIQUE NOT NULL,level INTEGER NOT NULL,deleted INTEGER NOT NULL DEFAULT 0,part BLOB NOT NULL,vq BLOB NOT NULL,vals BLOB NOT NULL,adj BLOB NOT NULL)",
            .{q_node},
        );
        defer freeQuotedSql(node_sql);
        try execOwned(self.db, node_sql);
        const vec_sql = try std.fmt.allocPrint(
            alloc,
            "CREATE TABLE IF NOT EXISTS {s}(id INTEGER PRIMARY KEY,v BLOB NOT NULL)",
            .{q_vec},
        );
        defer freeQuotedSql(vec_sql);
        try execOwned(self.db, vec_sql);
        try self.ensureMetadataIndexTables();
        try self.metaSetInt("format", FORMAT_VERSION);
        try self.metaSetInt("dims", self.config.dims);
        try self.metaSetInt("elem_type", @intFromEnum(self.config.elem_type));
        try self.metaSetInt("metric", @intFromEnum(self.config.metric));
        try self.metaSetInt("m", self.config.m);
        try self.metaSetInt("ef_construction", self.config.ef_construction);
        try self.metaSetInt("ef_search", self.config.ef_search);
        try self.metaSetInt("cache_nodes", self.config.cache_nodes);
        if ((try self.metaGetInt("version")) == null) try self.metaSetInt("version", 0);
        if ((try self.metaGetBlob("prng")) == null) try self.metaSetBlob("prng", self.prng.bytes()[0..]);
    }

    fn ensureMetadataIndexTables(self: *VTab) !void {
        const idx = try self.shadowName("_idx");
        defer alloc.free(idx);
        const q_idx = try qualifiedName(self.schema, idx);
        defer alloc.free(q_idx);
        const idx_sql = try std.fmt.allocPrint(
            alloc,
            "CREATE TABLE IF NOT EXISTS {s}(id INTEGER NOT NULL,col INTEGER NOT NULL,tag INTEGER NOT NULL,num REAL,text TEXT,blob BLOB,PRIMARY KEY(id,col))",
            .{q_idx},
        );
        defer freeQuotedSql(idx_sql);
        try execOwned(self.db, idx_sql);

        const idx_num_name = try self.shadowName("_idx_num");
        defer alloc.free(idx_num_name);
        const idx_text_name = try self.shadowName("_idx_text");
        defer alloc.free(idx_text_name);
        const idx_blob_name = try self.shadowName("_idx_blob");
        defer alloc.free(idx_blob_name);
        const q_idx_num_name = try qualifiedName(self.schema, idx_num_name);
        defer alloc.free(q_idx_num_name);
        const q_idx_text_name = try qualifiedName(self.schema, idx_text_name);
        defer alloc.free(q_idx_text_name);
        const q_idx_blob_name = try qualifiedName(self.schema, idx_blob_name);
        defer alloc.free(q_idx_blob_name);
        const idx_table = try quoteIdent(idx);
        defer alloc.free(idx_table);
        const idx_num_sql = try std.fmt.allocPrint(alloc, "CREATE INDEX IF NOT EXISTS {s} ON {s}(col,tag,num,id)", .{ q_idx_num_name, idx_table });
        defer freeQuotedSql(idx_num_sql);
        try execOwned(self.db, idx_num_sql);
        const idx_text_sql = try std.fmt.allocPrint(alloc, "CREATE INDEX IF NOT EXISTS {s} ON {s}(col,tag,text,id)", .{ q_idx_text_name, idx_table });
        defer freeQuotedSql(idx_text_sql);
        try execOwned(self.db, idx_text_sql);
        const idx_blob_sql = try std.fmt.allocPrint(alloc, "CREATE INDEX IF NOT EXISTS {s} ON {s}(col,tag,blob,id)", .{ q_idx_blob_name, idx_table });
        defer freeQuotedSql(idx_blob_sql);
        try execOwned(self.db, idx_blob_sql);
    }

    fn loadMeta(self: *VTab) !void {
        if (try self.metaGetInt("dims")) |v| self.config.dims = @intCast(v);
        if (try self.metaGetInt("elem_type")) |v| self.config.elem_type = @enumFromInt(@as(u8, @intCast(v)));
        if (try self.metaGetInt("metric")) |v| self.config.metric = @enumFromInt(@as(u8, @intCast(v)));
        if (try self.metaGetInt("m")) |v| self.config.m = @intCast(v);
        if (try self.metaGetInt("ef_construction")) |v| self.config.ef_construction = @intCast(v);
        if (try self.metaGetInt("ef_search")) |v| self.config.ef_search = @intCast(v);
        if (try self.metaGetInt("cache_nodes")) |v| self.config.cache_nodes = @intCast(@max(v, 0));
        if (try self.metaGetBlob("prng")) |b| {
            defer alloc.free(b);
            self.prng = Xoshiro.fromBytes(b) orelse self.prng;
        }
        self.version = (try self.metaGetInt("version")) orelse 0;
    }

    fn loadNodes(self: *VTab) !void {
        self.clearNodes();
        errdefer self.clearNodes();
        const node_table = try self.shadowName("_node");
        defer alloc.free(node_table);
        const q_node = try qualifiedName(self.schema, node_table);
        defer alloc.free(q_node);
        const sql = try std.fmt.allocPrint(alloc, "SELECT id,rowid,deleted FROM {s} ORDER BY id", .{q_node});
        defer freeQuotedSql(sql);
        var stmt: ?*c.sqlite3_stmt = null;
        const z = try alloc.dupeZ(u8, sql);
        defer alloc.free(z);
        if (c.sqlite3_prepare_v2(self.db, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.Sqlite;
        defer _ = c.sqlite3_finalize(stmt);
        while (true) {
            const step = c.sqlite3_step(stmt);
            if (step == c.SQLITE_DONE) break;
            if (step != c.SQLITE_ROW) return error.Sqlite;
            const id: u32 = @intCast(c.sqlite3_column_int64(stmt, 0));
            const rowid = c.sqlite3_column_int64(stmt, 1);
            while (self.nodes.items.len <= id) try self.nodes.append(alloc, null);
            const deleted = c.sqlite3_column_int(stmt, 2) != 0;
            if (deleted) {
                self.nodes.items[id] = null;
            } else {
                try self.live_ids.put(id, {});
                try self.row_map.put(rowid, id);
            }
        }
        try self.rebuildFreeIdsFromHoles();
        if (self.cacheLimit() > 0) {
            try self.primeResidentNodes(self.cacheLimit());
        }
        try self.trimResidentCache();
    }

    fn primeResidentNodes(self: *VTab, limit: usize) !void {
        if (limit == 0) return;
        const node_table = try self.shadowName("_node");
        defer alloc.free(node_table);
        const q_node = try qualifiedName(self.schema, node_table);
        defer alloc.free(q_node);
        const cold = self.coldFullVectors();
        const sql = if (cold) blk: {
            break :blk try std.fmt.allocPrint(
                alloc,
                "SELECT n.id,n.rowid,n.level,n.deleted,n.part,n.vq,n.vals,n.adj FROM {s} n WHERE n.deleted=0 ORDER BY n.id LIMIT ?",
                .{q_node},
            );
        } else blk: {
            const vec = try self.shadowName("_vec");
            defer alloc.free(vec);
            const q_vec = try qualifiedName(self.schema, vec);
            defer alloc.free(q_vec);
            break :blk try std.fmt.allocPrint(
                alloc,
                "SELECT n.id,n.rowid,n.level,n.deleted,n.part,n.vq,n.vals,n.adj,v.v FROM {s} n JOIN {s} v ON v.id=n.id WHERE n.deleted=0 ORDER BY n.id LIMIT ?",
                .{ q_node, q_vec },
            );
        };
        defer freeQuotedSql(sql);
        var stmt: ?*c.sqlite3_stmt = null;
        const z = try alloc.dupeZ(u8, sql);
        defer alloc.free(z);
        if (c.sqlite3_prepare_v2(self.db, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.Sqlite;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, @intCast(limit)) != c.SQLITE_OK) return error.Sqlite;
        while (true) {
            const step = c.sqlite3_step(stmt);
            if (step == c.SQLITE_DONE) break;
            if (step != c.SQLITE_ROW) return error.Sqlite;
            const id: u32 = @intCast(c.sqlite3_column_int64(stmt, 0));
            if (!self.live_ids.contains(id)) continue;
            while (self.nodes.items.len <= id) try self.nodes.append(alloc, null);
            if (self.nodes.items[id] != null) continue;
            const n = try self.nodeFromStmt(stmt, cold);
            self.nodes.items[id] = n;
            self.resident_count += 1;
        }
    }

    fn loadNodeById(self: *VTab, id: u32) !?*Node {
        const node_table = try self.shadowName("_node");
        defer alloc.free(node_table);
        const q_node = try qualifiedName(self.schema, node_table);
        defer alloc.free(q_node);
        const cold = self.coldFullVectors();
        const sql = if (cold) blk: {
            break :blk try std.fmt.allocPrint(
                alloc,
                "SELECT n.id,n.rowid,n.level,n.deleted,n.part,n.vq,n.vals,n.adj FROM {s} n WHERE n.id=?",
                .{q_node},
            );
        } else blk: {
            const vec = try self.shadowName("_vec");
            defer alloc.free(vec);
            const q_vec = try qualifiedName(self.schema, vec);
            defer alloc.free(q_vec);
            break :blk try std.fmt.allocPrint(
                alloc,
                "SELECT n.id,n.rowid,n.level,n.deleted,n.part,n.vq,n.vals,n.adj,v.v FROM {s} n JOIN {s} v ON v.id=n.id WHERE n.id=?",
                .{ q_node, q_vec },
            );
        };
        defer freeQuotedSql(sql);
        var stmt: ?*c.sqlite3_stmt = null;
        const z = try alloc.dupeZ(u8, sql);
        defer alloc.free(z);
        if (c.sqlite3_prepare_v2(self.db, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.Sqlite;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, id) != c.SQLITE_OK) return error.Sqlite;
        const step = c.sqlite3_step(stmt);
        if (step == c.SQLITE_DONE) return null;
        if (step != c.SQLITE_ROW) return error.Sqlite;
        if (c.sqlite3_column_int(stmt, 3) != 0) return null;
        return try self.nodeFromStmt(stmt, cold);
    }

    fn nodeFromStmt(self: *VTab, stmt: ?*c.sqlite3_stmt, cold: bool) !*Node {
        const id: u32 = @intCast(c.sqlite3_column_int64(stmt, 0));
        const rowid = c.sqlite3_column_int64(stmt, 1);
        const level: u8 = @intCast(c.sqlite3_column_int(stmt, 2));
        const part = try columnBlobCopy(stmt, 4);
        var part_owned = true;
        defer if (part_owned) alloc.free(part);
        const vq_raw = try columnBlobCopy(stmt, 5);
        defer alloc.free(vq_raw);
        const vals_raw = try columnBlobCopy(stmt, 6);
        defer alloc.free(vals_raw);
        const adj_raw = try columnBlobCopy(stmt, 7);
        defer alloc.free(adj_raw);
        var vec_val = VectorValue{ .elem_type = self.config.elem_type, .dims = self.config.dims, .blob = &.{} };
        if (!cold) {
            const vec_raw = try columnBlobCopy(stmt, 8);
            var vec_raw_owned = true;
            defer if (vec_raw_owned) alloc.free(vec_raw);
            vec_val = try decodeVectorBlob(vec_raw, self.config.elem_type, self.config.dims);
            vec_raw_owned = false;
        }
        var vec_owned = true;
        defer if (vec_owned) vec_val.deinit();
        const values = try deserializeCells(vals_raw);
        var values_owned = true;
        defer if (values_owned) deinitCellSlice(values);
        const q_dims: u32 = if (self.config.elem_type == .bit) 0 else self.config.dims;
        var q = try decodeQuantizedBlob(vq_raw, q_dims);
        var q_owned = true;
        defer if (q_owned) q.deinit();
        var transferred = false;
        const n = Node.create(id, rowid, level, part, values, vec_val, q, adj_raw, &transferred) catch |e| {
            if (transferred) {
                part_owned = false;
                values_owned = false;
                vec_owned = false;
                q_owned = false;
            }
            return e;
        };
        part_owned = false;
        values_owned = false;
        vec_owned = false;
        q_owned = false;
        self.touchNode(n);
        return n;
    }

    fn coldFullVectors(self: *const VTab) bool {
        return self.config.elem_type == .f32;
    }

    fn rebuildFreeIdsFromHoles(self: *VTab) !void {
        self.free_ids.clearRetainingCapacity();
        var id: usize = 0;
        while (id < self.nodes.items.len) : (id += 1) {
            if (!self.live_ids.contains(@intCast(id))) try self.free_ids.append(alloc, @intCast(id));
        }
    }

    fn dropColdVectorPayload(self: *const VTab, n: *Node) void {
        if (!self.coldFullVectors()) return;
        if (n.vec_blob.len > 0) {
            alloc.free(n.vec_blob);
            n.vec_blob = &.{};
        }
        if (n.floats.len > 0) {
            alloc.free(n.floats);
            n.floats = &.{};
        }
    }

    fn cacheLimit(self: *const VTab) usize {
        return self.config.cache_nodes;
    }

    fn nodeResident(self: *VTab, id: u32) !?*Node {
        if (!self.live_ids.contains(id)) return null;
        while (self.nodes.items.len <= id) try self.nodes.append(alloc, null);
        if (self.nodes.items[id]) |n| {
            self.touchNode(n);
            return n;
        }
        const n = try self.loadNodeById(id) orelse return null;
        self.nodes.items[id] = n;
        self.resident_count += 1;
        self.cache_faults +%= 1;
        return n;
    }

    fn trimResidentCache(self: *VTab) !void {
        const limit = self.cacheLimit();
        if (limit == 0) return;
        while (self.resident_count > limit) {
            var victim_id: ?usize = null;
            var victim_tick: u64 = std.math.maxInt(u64);
            for (self.nodes.items, 0..) |maybe, id| {
                const n = maybe orelse continue;
                if (n.last_used < victim_tick) {
                    victim_tick = n.last_used;
                    victim_id = id;
                }
            }
            const id = victim_id orelse break;
            if (self.nodes.items[id]) |n| {
                n.deinit();
                self.nodes.items[id] = null;
                self.resident_count -|= 1;
            }
        }
    }

    fn refreshIfNeeded(self: *VTab) void {
        const disk = self.metaGetInt("version") catch return;
        if (disk) |v| {
            if (v != self.version) {
                self.reloadFromDisk() catch return;
            }
        }
    }

    fn reloadFromDisk(self: *VTab) !void {
        try self.loadMeta();
        try self.loadNodes();
    }

    fn bumpVersion(self: *VTab) !void {
        self.version += 1;
        try self.metaSetInt("version", self.version);
        try self.metaSetBlob("prng", self.prng.bytes()[0..]);
    }

    fn shadowName(self: *const VTab, suffix: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ self.prefix, suffix });
    }

    fn metaSetInt(self: *VTab, key: []const u8, value: anytype) !void {
        var buf: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{value});
        try self.metaSetBlob(key, s);
    }

    fn metaSetBlob(self: *VTab, key: []const u8, value: []const u8) !void {
        const meta = try self.shadowName("_meta");
        defer alloc.free(meta);
        const q_meta = try qualifiedName(self.schema, meta);
        defer alloc.free(q_meta);
        const sql = try std.fmt.allocPrint(alloc, "INSERT OR REPLACE INTO {s}(key,value) VALUES(?,?)", .{q_meta});
        defer freeQuotedSql(sql);
        var stmt: ?*c.sqlite3_stmt = null;
        const z = try alloc.dupeZ(u8, sql);
        defer alloc.free(z);
        if (c.sqlite3_prepare_v2(self.db, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.Sqlite;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), SQLITE_TRANSIENT) != c.SQLITE_OK) return error.Sqlite;
        if (c.sqlite3_bind_blob(stmt, 2, ptrOrEmpty(value), @intCast(value.len), SQLITE_TRANSIENT) != c.SQLITE_OK) return error.Sqlite;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.Sqlite;
    }

    fn metaGetInt(self: *VTab, key: []const u8) !?i64 {
        const blob = try self.metaGetBlob(key) orelse return null;
        defer alloc.free(blob);
        return std.fmt.parseInt(i64, blob, 10) catch null;
    }

    fn metaGetBlob(self: *VTab, key: []const u8) !?[]u8 {
        const meta = try self.shadowName("_meta");
        defer alloc.free(meta);
        const q_meta = try qualifiedName(self.schema, meta);
        defer alloc.free(q_meta);
        const sql = try std.fmt.allocPrint(alloc, "SELECT value FROM {s} WHERE key=?", .{q_meta});
        defer freeQuotedSql(sql);
        var stmt: ?*c.sqlite3_stmt = null;
        const z = try alloc.dupeZ(u8, sql);
        defer alloc.free(z);
        if (c.sqlite3_prepare_v2(self.db, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.Sqlite;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), SQLITE_TRANSIENT) != c.SQLITE_OK) return error.Sqlite;
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return try columnBlobCopy(stmt, 0);
    }

    fn allocateId(self: *VTab) !u32 {
        if (self.free_ids.items.len > 0) {
            const id = self.free_ids.items[self.free_ids.items.len - 1];
            try self.recordFreePop(id);
            _ = self.free_ids.pop();
            return id;
        }
        const id: u32 = @intCast(self.nodes.items.len);
        try self.recordNodesAppend(id);
        try self.nodes.append(alloc, null);
        return id;
    }

    fn insertNode(self: *VTab, rowid: i64, values: []Cell, vec: VectorValue) !void {
        var values_owned = true;
        errdefer if (values_owned) deinitCellSlice(values);
        var vec_owned = true;
        var vec_mut = vec;
        errdefer if (vec_owned) vec_mut.deinit();
        var changed_hot = false;
        errdefer if (changed_hot) self.reloadFromDisk() catch self.clearNodes();
        if (self.row_map.get(rowid)) |_| {
            changed_hot = true;
            try self.deleteRow(rowid);
        }
        const id = try self.allocateId();
        changed_hot = true;
        const level = self.sampleLevel();
        const part_key = try self.makePartKey(values);
        var part_key_owned = true;
        errdefer if (part_key_owned) alloc.free(part_key);
        var q = try quantize(vec_mut, self.config.metric);
        var q_owned = true;
        errdefer if (q_owned) q.deinit();
        var transferred = false;
        const n = Node.create(id, rowid, level, part_key, values, vec_mut, q, null, &transferred) catch |e| {
            if (transferred) {
                part_key_owned = false;
                values_owned = false;
                vec_owned = false;
                q_owned = false;
            }
            return e;
        };
        part_key_owned = false;
        values_owned = false;
        vec_owned = false;
        q_owned = false;
        var n_installed = false;
        errdefer if (!n_installed) n.deinit();
        try self.recordNodeBefore(id);
        self.nodes.items[id] = n;
        self.resident_count += 1;
        self.touchNode(n);
        n_installed = true;
        try self.recordRowMapBefore(rowid);
        try self.row_map.put(rowid, id);
        try self.live_ids.put(id, {});
        try self.linkNode(n, true, true);
        try self.persistNode(n);
        self.dropColdVectorPayload(n);
        try self.bumpVersion();
        try self.trimResidentCache();
        changed_hot = false;
    }

    fn updateNodeValuesIfSameVector(self: *VTab, rowid: i64, values: []const Cell, vec: VectorValue) !bool {
        const id = self.row_map.get(rowid) orelse return false;
        const n = self.node(id) orelse return false;
        const part_key = try self.makePartKey(values);
        defer alloc.free(part_key);
        if (!std.mem.eql(u8, n.part_key, part_key)) return false;
        const current_vec = if (n.vec_blob.len > 0) n.vec_blob else try self.fetchVectorBlob(n.id);
        const current_owned = n.vec_blob.len == 0;
        defer if (current_owned) alloc.free(current_vec);
        if (!std.mem.eql(u8, current_vec, vec.blob)) return false;

        const cloned_values = try cloneCellSlice(values);
        var cloned_owned = true;
        errdefer if (cloned_owned) deinitCellSlice(cloned_values);
        try self.recordNodeBefore(id);
        const old_values = n.values;
        n.values = cloned_values;
        cloned_owned = false;
        deinitCellSlice(old_values);
        try self.persistNode(n);
        try self.bumpVersion();
        try self.trimResidentCache();
        return true;
    }

    fn deleteRow(self: *VTab, rowid: i64) !void {
        const id = self.row_map.get(rowid) orelse return;
        const n = self.node(id) orelse return;
        var changed_hot = true;
        errdefer if (changed_hot) self.reloadFromDisk() catch self.clearNodes();
        try self.recordNodeBefore(id);
        try self.repairDelete(n);
        try self.deleteNodeRows(id);
        try self.recordRowMapBefore(rowid);
        _ = self.row_map.remove(rowid);
        self.nodes.items[id] = null;
        _ = self.live_ids.remove(id);
        n.deinit();
        self.resident_count -|= 1;
        try self.recordFreeAppend(id);
        try self.free_ids.append(alloc, id);
        try self.bumpVersion();
        try self.trimResidentCache();
        changed_hot = false;
    }

    fn node(self: *VTab, id: u32) ?*Node {
        const n = (self.nodeResident(id) catch return null) orelse return null;
        if (n.deleted) return null;
        return n;
    }

    fn sampleLevel(self: *VTab) u8 {
        var lvl: u8 = 0;
        while (lvl < 32) : (lvl += 1) {
            if ((self.prng.next() & 0xffff) >= 0x8000) break;
        }
        return lvl;
    }

    fn entryFor(self: *VTab, part_key: []const u8) ?u32 {
        return self.entryForExcept(part_key, null);
    }

    fn entryForExcept(self: *VTab, part_key: []const u8, exclude: ?u32) ?u32 {
        const node_table = self.shadowName("_node") catch return null;
        defer alloc.free(node_table);
        const q_node = qualifiedName(self.schema, node_table) catch return null;
        defer alloc.free(q_node);
        const sql = if (exclude) |_| std.fmt.allocPrint(
            alloc,
            "SELECT id FROM {s} WHERE deleted=0 AND part=? AND id<>? ORDER BY level DESC,id ASC LIMIT 1",
            .{q_node},
        ) catch return null else std.fmt.allocPrint(
            alloc,
            "SELECT id FROM {s} WHERE deleted=0 AND part=? ORDER BY level DESC,id ASC LIMIT 1",
            .{q_node},
        ) catch return null;
        defer freeQuotedSql(sql);
        var stmt: ?*c.sqlite3_stmt = null;
        const z = alloc.dupeZ(u8, sql) catch return null;
        defer alloc.free(z);
        if (c.sqlite3_prepare_v2(self.db, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_blob(stmt, 1, ptrOrEmpty(part_key), @intCast(part_key.len), SQLITE_TRANSIENT) != c.SQLITE_OK) return null;
        if (exclude) |id| {
            if (c.sqlite3_bind_int64(stmt, 2, id) != c.SQLITE_OK) return null;
        }
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return @intCast(c.sqlite3_column_int64(stmt, 0));
    }

    fn linkNode(self: *VTab, n: *Node, persist_neighbors: bool, track_undo: bool) !void {
        const ep_id = self.entryForExcept(n.part_key, n.id) orelse return;
        var ep = ep_id;
        const max_level = self.maxLevelInPartExcept(n.part_key, n.id);
        if (max_level > n.level) {
            var l: i32 = @intCast(max_level);
            while (l > n.level) : (l -= 1) {
                const greedy_result = try self.greedy(n, ep, @intCast(l));
                ep = greedy_result.id;
            }
        }
        var level_i: i32 = @intCast(@min(max_level, n.level));
        while (level_i >= 0) : (level_i -= 1) {
            const found = try self.searchLayerNode(n, ep, @intCast(level_i), self.config.ef_construction);
            defer alloc.free(found);
            const selected = try self.selectNeighbors(found, if (level_i == 0) self.config.m * 2 else self.config.m);
            defer alloc.free(selected);
            try n.ensureLevel(@intCast(level_i));
            for (selected) |nb| {
                try addUnique(&n.adj.items[@intCast(level_i)], nb.id);
                if (self.node(nb.id)) |other| {
                    if (track_undo) try self.recordNodeBefore(other.id);
                    try other.ensureLevel(@intCast(level_i));
                    try addUnique(&other.adj.items[@intCast(level_i)], n.id);
                    try self.pruneNodeLevel(other, @intCast(level_i), if (level_i == 0) self.config.m * 2 else self.config.m);
                    if (persist_neighbors) try self.persistNode(other);
                }
            }
            if (selected.len > 0) ep = selected[0].id;
        }
    }

    fn rebuildGraph(self: *VTab) !usize {
        const ids = try self.liveIdList();
        defer alloc.free(ids);
        var live: usize = 0;
        for (ids) |id| {
            const n = (try self.nodeResident(id)) orelse continue;
            for (n.adj.items) |*level| level.clearRetainingCapacity();
            while (n.adj.items.len <= n.level) try n.adj.append(alloc, .empty);
            n.deleted = true;
            live += 1;
        }
        for (ids) |id| {
            const n = (try self.nodeResident(id)) orelse continue;
            n.deleted = false;
            try self.linkNode(n, false, false);
        }
        for (ids) |id| {
            const n = (try self.nodeResident(id)) orelse continue;
            try self.persistAdjacency(n);
        }
        try self.rebuildMetadataIndex();
        try self.bumpVersion();
        try self.trimResidentCache();
        return live;
    }

    fn maxLevelInPart(self: *VTab, part_key: []const u8) u8 {
        return self.maxLevelInPartExcept(part_key, null);
    }

    fn maxLevelInPartExcept(self: *VTab, part_key: []const u8, exclude: ?u32) u8 {
        const node_table = self.shadowName("_node") catch return 0;
        defer alloc.free(node_table);
        const q_node = qualifiedName(self.schema, node_table) catch return 0;
        defer alloc.free(q_node);
        const sql = if (exclude) |_| std.fmt.allocPrint(
            alloc,
            "SELECT coalesce(max(level),0) FROM {s} WHERE deleted=0 AND part=? AND id<>?",
            .{q_node},
        ) catch return 0 else std.fmt.allocPrint(
            alloc,
            "SELECT coalesce(max(level),0) FROM {s} WHERE deleted=0 AND part=?",
            .{q_node},
        ) catch return 0;
        defer freeQuotedSql(sql);
        var stmt: ?*c.sqlite3_stmt = null;
        const z = alloc.dupeZ(u8, sql) catch return 0;
        defer alloc.free(z);
        if (c.sqlite3_prepare_v2(self.db, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return 0;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_blob(stmt, 1, ptrOrEmpty(part_key), @intCast(part_key.len), SQLITE_TRANSIENT) != c.SQLITE_OK) return 0;
        if (exclude) |id| {
            if (c.sqlite3_bind_int64(stmt, 2, id) != c.SQLITE_OK) return 0;
        }
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
        return @intCast(c.sqlite3_column_int(stmt, 0));
    }

    fn greedy(self: *VTab, target: *Node, start: u32, level: usize) !Neighbor {
        var cur = start;
        var cur_dist = self.distanceNodes(target, cur, false);
        var changed = true;
        while (changed) {
            changed = false;
            const n = self.node(cur) orelse break;
            if (level >= n.adj.items.len) break;
            for (n.adj.items[level].items) |nid| {
                const d = self.distanceNodes(target, nid, false);
                if (d < cur_dist or (d == cur_dist and nid < cur)) {
                    cur = nid;
                    cur_dist = d;
                    changed = true;
                }
            }
        }
        return .{ .id = cur, .distance = cur_dist };
    }

    fn searchLayerNode(self: *VTab, target: *Node, entry: u32, level: usize, ef: usize) ![]Neighbor {
        return self.searchLayer(target.floats, target.bits, target.q, target.q_scale, target.q_offset, target.part_key, entry, level, ef);
    }

    fn searchLayer(self: *VTab, qf: []const f32, qb: []const u8, qq: []const i8, q_scale: f32, q_offset: f32, part_key: []const u8, entry: u32, level: usize, ef: usize) ![]Neighbor {
        var candidates: std.ArrayList(Candidate) = .empty;
        defer candidates.deinit(alloc);
        var best: std.ArrayList(Neighbor) = .empty;
        defer best.deinit(alloc);
        var seen = std.AutoHashMap(u32, void).init(alloc);
        defer seen.deinit();
        const d0 = self.distanceRaw(entry, qf, qb, qq, q_scale, q_offset, false);
        try candidates.append(alloc, .{ .id = entry, .distance = d0 });
        try best.append(alloc, .{ .id = entry, .distance = d0 });
        try seen.put(entry, {});
        while (true) {
            const ci = bestUnexpanded(candidates.items) orelse break;
            const worst = worstDistance(best.items);
            if (candidates.items[ci].distance > worst and best.items.len >= ef) break;
            candidates.items[ci].expanded = true;
            const cur = self.node(candidates.items[ci].id) orelse continue;
            if (level >= cur.adj.items.len) continue;
            for (cur.adj.items[level].items) |nid| {
                if (seen.contains(nid)) continue;
                try seen.put(nid, {});
                const nn = self.node(nid) orelse continue;
                if (!std.mem.eql(u8, nn.part_key, part_key)) continue;
                const d = self.distanceRaw(nid, qf, qb, qq, q_scale, q_offset, false);
                try candidates.append(alloc, .{ .id = nid, .distance = d });
                try insertBounded(&best, .{ .id = nid, .distance = d }, ef);
            }
        }
        return cloneNeighbors(best.items);
    }

    fn pruneNodeLevel(self: *VTab, n: *Node, level: usize, cap: usize) !void {
        if (level >= n.adj.items.len or n.adj.items[level].items.len <= cap) return;
        var all: std.ArrayList(Neighbor) = .empty;
        defer all.deinit(alloc);
        for (n.adj.items[level].items) |id| {
            try all.append(alloc, .{ .id = id, .distance = self.distanceNodes(n, id, false) });
        }
        const selected = try self.selectNeighbors(all.items, cap);
        defer alloc.free(selected);
        n.adj.items[level].clearRetainingCapacity();
        for (selected) |nb| try n.adj.items[level].append(alloc, nb.id);
    }

    fn selectNeighbors(self: *VTab, input: []const Neighbor, cap: usize) ![]Neighbor {
        const sorted = try cloneNeighbors(input);
        sortNeighbors(sorted);
        var out: std.ArrayList(Neighbor) = .empty;
        defer out.deinit(alloc);
        for (sorted) |nb| {
            var diverse = true;
            for (out.items) |sel| {
                const d = self.distanceNodeIds(nb.id, sel.id, false);
                if (d < nb.distance) {
                    diverse = false;
                    break;
                }
            }
            if (diverse or out.items.len == 0) try out.append(alloc, nb);
            if (out.items.len >= cap) break;
        }
        var i: usize = 0;
        while (out.items.len < cap and i < sorted.len) : (i += 1) {
            var exists = false;
            for (out.items) |x| {
                if (x.id == sorted[i].id) exists = true;
            }
            if (!exists) try out.append(alloc, sorted[i]);
        }
        alloc.free(sorted);
        return try out.toOwnedSlice(alloc);
    }

    fn search(self: *VTab, q: VectorValue, filters: []const QueryFilter, k: usize, ef_req: usize) ![]SearchResult {
        self.refreshIfNeeded();
        var q_quant = try quantize(q, self.config.metric);
        defer q_quant.deinit();
        const part_key = try self.queryPartKey(filters);
        defer if (part_key) |key| alloc.free(key);
        if (k == 0) return alloc.alloc(SearchResult, 0);
        if (self.hasMetadataFilters(filters)) {
            if (try self.metadataPrefilterIds(filters)) |ids| {
                defer alloc.free(ids);
                if (ids.len == 0) return alloc.alloc(SearchResult, 0);
                return self.exactSearchIds(q, ids, part_key, filters, k);
            }
            return self.exactSearch(q, part_key, filters, k);
        }
        const total = self.liveCount(part_key, filters);
        if (total == 0) return alloc.alloc(SearchResult, 0);
        if (total <= EXACT_TINY_TABLE or filters.len > 0 and total <= @max(ef_req * 4, 256)) {
            return self.exactSearch(q, part_key, filters, k);
        }
        // If a partitioned table is queried without all partition equality predicates,
        // search every partition exactly. That keeps recall correct for the broad query shape.
        const routed_part = part_key orelse return self.exactSearch(q, null, filters, k);
        const entry = self.entryFor(routed_part) orelse return alloc.alloc(SearchResult, 0);
        var ep = entry;
        var level: i32 = @intCast(self.maxLevelInPart(routed_part));
        while (level > 0) : (level -= 1) {
            const g = try self.greedyRaw(q, q_quant, ep, @intCast(level), routed_part);
            ep = g.id;
        }
        const ef = @max(@max(ef_req, self.config.ef_search), k);
        const neighbors = try self.searchLayer(q.floats, q.bits, q_quant.values, q_quant.scale, q_quant.offset, routed_part, ep, 0, ef);
        defer alloc.free(neighbors);
        var out: std.ArrayList(SearchResult) = .empty;
        defer out.deinit(alloc);
        for (neighbors) |nb| {
            const n = self.node(nb.id) orelse continue;
            if (!self.matchesFilters(n, filters)) continue;
            try insertResultBounded(&out, .{ .id = n.id, .rowid = n.rowid, .distance = try self.exactDistanceRaw(n.id, q.floats, q.bits) }, @max(k, ef));
        }
        if (out.items.len < k and filters.len > 0) {
            const exact = try self.exactSearch(q, part_key, filters, k);
            out.clearRetainingCapacity();
            for (exact) |r| try out.append(alloc, r);
            alloc.free(exact);
        }
        while (out.items.len > k) _ = out.pop();
        const results = try out.toOwnedSlice(alloc);
        try self.trimResidentCache();
        return results;
    }

    fn hasMetadataFilters(self: *VTab, filters: []const QueryFilter) bool {
        for (filters) |f| {
            if (f.col >= self.columns.len) return true;
            if (self.columns[f.col].kind != .partition) return true;
        }
        return false;
    }

    fn greedyRaw(self: *VTab, q: VectorValue, qq: QuantizedValue, start: u32, level: usize, part_key: []const u8) !Neighbor {
        var cur = start;
        var cur_dist = self.distanceRaw(cur, q.floats, q.bits, qq.values, qq.scale, qq.offset, false);
        var changed = true;
        while (changed) {
            changed = false;
            const n = self.node(cur) orelse break;
            if (level >= n.adj.items.len) break;
            for (n.adj.items[level].items) |nid| {
                const nn = self.node(nid) orelse continue;
                if (!std.mem.eql(u8, nn.part_key, part_key)) continue;
                const d = self.distanceRaw(nid, q.floats, q.bits, qq.values, qq.scale, qq.offset, false);
                if (d < cur_dist or (d == cur_dist and nid < cur)) {
                    cur = nid;
                    cur_dist = d;
                    changed = true;
                }
            }
        }
        return .{ .id = cur, .distance = cur_dist };
    }

    fn exactSearch(self: *VTab, q: VectorValue, part_key: ?[]const u8, filters: []const QueryFilter, k: usize) ![]SearchResult {
        var out: std.ArrayList(SearchResult) = .empty;
        defer out.deinit(alloc);
        const node_table = try self.shadowName("_node");
        defer alloc.free(node_table);
        const vec_table = try self.shadowName("_vec");
        defer alloc.free(vec_table);
        const q_node = try qualifiedName(self.schema, node_table);
        defer alloc.free(q_node);
        const q_vec = try qualifiedName(self.schema, vec_table);
        defer alloc.free(q_vec);
        const sql = try std.fmt.allocPrint(
            alloc,
            "SELECT n.id,n.rowid,n.level,n.deleted,n.part,n.vq,n.vals,n.adj,v.v FROM {s} n JOIN {s} v ON v.id=n.id WHERE n.deleted=0 ORDER BY n.id",
            .{ q_node, q_vec },
        );
        defer freeQuotedSql(sql);
        var stmt: ?*c.sqlite3_stmt = null;
        const z = try alloc.dupeZ(u8, sql);
        defer alloc.free(z);
        if (c.sqlite3_prepare_v2(self.db, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.Sqlite;
        defer _ = c.sqlite3_finalize(stmt);
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.Sqlite;
            {
                const n = try self.nodeFromStmt(stmt, false);
                defer n.deinit();
                if (n.deleted or !self.matchesPart(n, part_key)) continue;
                if (!self.matchesFilters(n, filters)) continue;
                try insertResultBounded(&out, .{ .id = n.id, .rowid = n.rowid, .distance = try self.exactDistanceNode(n, q.floats, q.bits) }, k);
            }
        }
        return try out.toOwnedSlice(alloc);
    }

    fn exactSearchIds(self: *VTab, q: VectorValue, ids: []const u32, part_key: ?[]const u8, filters: []const QueryFilter, k: usize) ![]SearchResult {
        var out: std.ArrayList(SearchResult) = .empty;
        defer out.deinit(alloc);
        const node_table = try self.shadowName("_node");
        defer alloc.free(node_table);
        const vec_table = try self.shadowName("_vec");
        defer alloc.free(vec_table);
        const q_node = try qualifiedName(self.schema, node_table);
        defer alloc.free(q_node);
        const q_vec = try qualifiedName(self.schema, vec_table);
        defer alloc.free(q_vec);
        const sql = try std.fmt.allocPrint(
            alloc,
            "SELECT n.id,n.rowid,n.level,n.deleted,n.part,n.vq,n.vals,n.adj,v.v FROM {s} n JOIN {s} v ON v.id=n.id WHERE n.deleted=0 AND n.id=?",
            .{ q_node, q_vec },
        );
        defer freeQuotedSql(sql);
        var stmt: ?*c.sqlite3_stmt = null;
        const z = try alloc.dupeZ(u8, sql);
        defer alloc.free(z);
        if (c.sqlite3_prepare_v2(self.db, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.Sqlite;
        defer _ = c.sqlite3_finalize(stmt);
        for (ids) |id| {
            _ = c.sqlite3_reset(stmt);
            _ = c.sqlite3_clear_bindings(stmt);
            if (c.sqlite3_bind_int64(stmt, 1, id) != c.SQLITE_OK) return error.Sqlite;
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) continue;
            if (rc != c.SQLITE_ROW) return error.Sqlite;
            {
                const n = try self.nodeFromStmt(stmt, false);
                defer n.deinit();
                if (n.deleted or !self.matchesPart(n, part_key)) continue;
                if (!self.matchesFilters(n, filters)) continue;
                try insertResultBounded(&out, .{ .id = n.id, .rowid = n.rowid, .distance = try self.exactDistanceNode(n, q.floats, q.bits) }, k);
            }
        }
        return try out.toOwnedSlice(alloc);
    }

    fn metadataPrefilterIds(self: *VTab, filters: []const QueryFilter) !?[]u32 {
        if (!(try self.metadataIndexUsable())) return null;
        var out: std.AutoHashMap(u32, void) = std.AutoHashMap(u32, void).init(alloc);
        defer out.deinit();
        var initialized = false;
        for (filters) |f| {
            if (f.col >= self.columns.len or self.columns[f.col].kind != .metadata) continue;
            const ids = try self.indexedIdsForFilter(f) orelse return null;
            defer alloc.free(ids);
            if (!initialized) {
                for (ids) |id| try out.put(id, {});
                initialized = true;
                continue;
            }
            var next = std.AutoHashMap(u32, void).init(alloc);
            errdefer next.deinit();
            for (ids) |id| {
                if (out.contains(id)) try next.put(id, {});
            }
            out.deinit();
            out = next;
        }
        if (!initialized) return null;
        var ids = try alloc.alloc(u32, out.count());
        var i: usize = 0;
        var it = out.keyIterator();
        while (it.next()) |id| {
            ids[i] = id.*;
            i += 1;
        }
        sortU32(ids);
        return ids;
    }

    fn indexedIdsForFilter(self: *VTab, f: QueryFilter) !?[]u32 {
        const idx = try self.shadowName("_idx");
        defer alloc.free(idx);
        const q_idx = try qualifiedName(self.schema, idx);
        defer alloc.free(q_idx);
        const pred = indexedPredicateSql(f) orelse return null;
        const sql = try std.fmt.allocPrint(alloc, "SELECT id FROM {s} WHERE col=? AND {s} ORDER BY id", .{ q_idx, pred });
        defer freeQuotedSql(sql);
        var stmt: ?*c.sqlite3_stmt = null;
        const z = try alloc.dupeZ(u8, sql);
        defer alloc.free(z);
        if (c.sqlite3_prepare_v2(self.db, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, @intCast(f.col)) != c.SQLITE_OK) return error.Sqlite;
        try bindIndexedPredicateValue(stmt, f);
        var out: std.ArrayList(u32) = .empty;
        errdefer out.deinit(alloc);
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.Sqlite;
            try out.append(alloc, @intCast(c.sqlite3_column_int64(stmt, 0)));
        }
        return try out.toOwnedSlice(alloc);
    }

    fn metadataIndexUsable(self: *VTab) !bool {
        const metadata_cols = self.metadataColumnCount();
        if (metadata_cols == 0) return false;
        const expected = self.liveNodeCount() * metadata_cols;
        const actual = self.metadataIndexRowCount() catch return false;
        return actual == expected;
    }

    fn metadataColumnCount(self: *const VTab) usize {
        var count: usize = 0;
        for (self.columns) |col| {
            if (col.kind == .metadata) count += 1;
        }
        return count;
    }

    fn liveIdList(self: *VTab) ![]u32 {
        var ids = try alloc.alloc(u32, self.live_ids.count());
        var i: usize = 0;
        var it = self.live_ids.keyIterator();
        while (it.next()) |id| {
            ids[i] = id.*;
            i += 1;
        }
        sortU32(ids);
        return ids;
    }

    fn liveNodeCount(self: *const VTab) usize {
        return self.live_ids.count();
    }

    fn metadataIndexRowCount(self: *VTab) !usize {
        const idx = try self.shadowName("_idx");
        defer alloc.free(idx);
        const q_idx = try qualifiedName(self.schema, idx);
        defer alloc.free(q_idx);
        const sql = try std.fmt.allocPrint(alloc, "SELECT count(*) FROM {s}", .{q_idx});
        defer freeQuotedSql(sql);
        var stmt: ?*c.sqlite3_stmt = null;
        const z = try alloc.dupeZ(u8, sql);
        defer alloc.free(z);
        if (c.sqlite3_prepare_v2(self.db, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.Sqlite;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.Sqlite;
        return @intCast(c.sqlite3_column_int64(stmt, 0));
    }

    fn matchesMetadataFilters(self: *VTab, n: *Node, filters: []const QueryFilter) bool {
        for (filters) |f| {
            if (f.col >= self.columns.len or self.columns[f.col].kind != .metadata) continue;
            if (f.col >= n.values.len) return false;
            if (!cellCompare(n.values[f.col], f.value, f.op)) return false;
        }
        return true;
    }

    fn liveCount(self: *VTab, part_key: ?[]const u8, filters: []const QueryFilter) usize {
        if (self.hasMetadataFilters(filters)) return self.liveCountByScan(part_key, filters);
        const node_table = self.shadowName("_node") catch return self.liveCountByScan(part_key, filters);
        defer alloc.free(node_table);
        const q_node = qualifiedName(self.schema, node_table) catch return self.liveCountByScan(part_key, filters);
        defer alloc.free(q_node);
        const sql = if (part_key != null)
            std.fmt.allocPrint(alloc, "SELECT count(*) FROM {s} WHERE deleted=0 AND part=?", .{q_node}) catch return self.liveCountByScan(part_key, filters)
        else
            std.fmt.allocPrint(alloc, "SELECT count(*) FROM {s} WHERE deleted=0", .{q_node}) catch return self.liveCountByScan(part_key, filters);
        defer freeQuotedSql(sql);
        var stmt: ?*c.sqlite3_stmt = null;
        const z = alloc.dupeZ(u8, sql) catch return self.liveCountByScan(part_key, filters);
        defer alloc.free(z);
        if (c.sqlite3_prepare_v2(self.db, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return self.liveCountByScan(part_key, filters);
        defer _ = c.sqlite3_finalize(stmt);
        if (part_key) |key| {
            if (c.sqlite3_bind_blob(stmt, 1, ptrOrEmpty(key), @intCast(key.len), SQLITE_TRANSIENT) != c.SQLITE_OK) return self.liveCountByScan(part_key, filters);
        }
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return self.liveCountByScan(part_key, filters);
        return @intCast(c.sqlite3_column_int64(stmt, 0));
    }

    fn liveCountByScan(self: *VTab, part_key: ?[]const u8, filters: []const QueryFilter) usize {
        var nlive: usize = 0;
        const node_table = self.shadowName("_node") catch return 0;
        defer alloc.free(node_table);
        const q_node = qualifiedName(self.schema, node_table) catch return 0;
        defer alloc.free(q_node);
        const sql = std.fmt.allocPrint(
            alloc,
            "SELECT n.id,n.rowid,n.level,n.deleted,n.part,n.vq,n.vals,n.adj FROM {s} n WHERE n.deleted=0 ORDER BY n.id",
            .{q_node},
        ) catch return 0;
        defer freeQuotedSql(sql);
        var stmt: ?*c.sqlite3_stmt = null;
        const z = alloc.dupeZ(u8, sql) catch return 0;
        defer alloc.free(z);
        if (c.sqlite3_prepare_v2(self.db, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return 0;
        defer _ = c.sqlite3_finalize(stmt);
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return 0;
            {
                const n = self.nodeFromStmt(stmt, true) catch return 0;
                defer n.deinit();
                if (!n.deleted and self.matchesPart(n, part_key) and self.matchesFilters(n, filters)) nlive += 1;
            }
        }
        return nlive;
    }

    fn matchesPart(self: *VTab, n: *Node, part_key: ?[]const u8) bool {
        _ = self;
        const key = part_key orelse return true;
        return std.mem.eql(u8, n.part_key, key);
    }

    fn matchesFilters(self: *VTab, n: *Node, filters: []const QueryFilter) bool {
        _ = self;
        for (filters) |f| {
            if (f.col >= n.values.len) return false;
            if (!cellCompare(n.values[f.col], f.value, f.op)) return false;
        }
        return true;
    }

    fn queryPartKey(self: *VTab, filters: []const QueryFilter) !?[]u8 {
        var out: std.ArrayList(u8) = .empty;
        var saw_partition = false;
        var complete = true;
        for (self.columns, 0..) |col, i| {
            if (col.kind != .partition) continue;
            saw_partition = true;
            var found: ?Cell = null;
            for (filters) |f| {
                if (f.col == i and f.op == .eq) {
                    found = f.value;
                    break;
                }
            }
            if (found) |cell| {
                try appendCellKey(&out, cell);
            } else {
                complete = false;
            }
        }
        if (!saw_partition) return try out.toOwnedSlice(alloc);
        if (!complete) {
            out.deinit(alloc);
            return null;
        }
        return try out.toOwnedSlice(alloc);
    }

    fn makePartKey(self: *VTab, values: []const Cell) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.columns, 0..) |col, i| {
            if (col.kind == .partition) try appendCellKey(&out, values[i]);
        }
        return out.toOwnedSlice(alloc);
    }

    fn repairDelete(self: *VTab, n: *Node) !void {
        var l: usize = 0;
        while (l < n.adj.items.len) : (l += 1) {
            const peers = try alloc.dupe(u32, n.adj.items[l].items);
            defer alloc.free(peers);
            for (peers) |pid| {
                const p = self.node(pid) orelse continue;
                if (l >= p.adj.items.len) continue;
                try self.recordNodeBefore(p.id);
                removeId(&p.adj.items[l], n.id);
                for (peers) |other| {
                    if (other != pid and self.node(other) != null) try addUnique(&p.adj.items[l], other);
                }
                try self.pruneNodeLevel(p, l, if (l == 0) self.config.m * 2 else self.config.m);
                try self.persistNode(p);
            }
        }
    }

    fn persistNode(self: *VTab, n: *Node) !void {
        const node_table = try self.shadowName("_node");
        defer alloc.free(node_table);
        const vec = try self.shadowName("_vec");
        defer alloc.free(vec);
        const q_node = try qualifiedName(self.schema, node_table);
        defer alloc.free(q_node);
        const q_vec = try qualifiedName(self.schema, vec);
        defer alloc.free(q_vec);
        const vals = try serializeCells(n.values);
        defer alloc.free(vals);
        const adj = try n.writeAdj();
        defer alloc.free(adj);
        const q = try encodeQuantizedBlob(n.q, n.q_scale, n.q_offset);
        defer alloc.free(q);
        const sqln = try std.fmt.allocPrint(
            alloc,
            "INSERT OR REPLACE INTO {s}(id,rowid,level,deleted,part,vq,vals,adj) VALUES(?,?,?,?,?,?,?,?)",
            .{q_node},
        );
        defer freeQuotedSql(sqln);
        var st: ?*c.sqlite3_stmt = null;
        const zn = try alloc.dupeZ(u8, sqln);
        defer alloc.free(zn);
        if (c.sqlite3_prepare_v2(self.db, zn.ptr, -1, &st, null) != c.SQLITE_OK) return error.Sqlite;
        defer _ = c.sqlite3_finalize(st);
        _ = c.sqlite3_bind_int64(st, 1, n.id);
        _ = c.sqlite3_bind_int64(st, 2, n.rowid);
        _ = c.sqlite3_bind_int64(st, 3, n.level);
        _ = c.sqlite3_bind_int64(st, 4, if (n.deleted) 1 else 0);
        _ = c.sqlite3_bind_blob(st, 5, ptrOrEmpty(n.part_key), @intCast(n.part_key.len), SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_blob(st, 6, ptrOrEmpty(q), @intCast(q.len), SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_blob(st, 7, ptrOrEmpty(vals), @intCast(vals.len), SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_blob(st, 8, ptrOrEmpty(adj), @intCast(adj.len), SQLITE_TRANSIENT);
        if (c.sqlite3_step(st) != c.SQLITE_DONE) return error.Sqlite;
        try self.persistMetadataIndex(n);
        if (self.coldFullVectors() and n.vec_blob.len == 0) return;
        const sqlv = try std.fmt.allocPrint(alloc, "INSERT OR REPLACE INTO {s}(id,v) VALUES(?,?)", .{q_vec});
        defer freeQuotedSql(sqlv);
        var sv: ?*c.sqlite3_stmt = null;
        const zv = try alloc.dupeZ(u8, sqlv);
        defer alloc.free(zv);
        if (c.sqlite3_prepare_v2(self.db, zv.ptr, -1, &sv, null) != c.SQLITE_OK) return error.Sqlite;
        defer _ = c.sqlite3_finalize(sv);
        _ = c.sqlite3_bind_int64(sv, 1, n.id);
        _ = c.sqlite3_bind_blob(sv, 2, ptrOrEmpty(n.vec_blob), @intCast(n.vec_blob.len), SQLITE_TRANSIENT);
        if (c.sqlite3_step(sv) != c.SQLITE_DONE) return error.Sqlite;
    }

    fn persistAdjacency(self: *VTab, n: *Node) !void {
        const node_table = try self.shadowName("_node");
        defer alloc.free(node_table);
        const q_node = try qualifiedName(self.schema, node_table);
        defer alloc.free(q_node);
        const adj = try n.writeAdj();
        defer alloc.free(adj);
        const sql = try std.fmt.allocPrint(alloc, "UPDATE {s} SET level=?, adj=? WHERE id=?", .{q_node});
        defer freeQuotedSql(sql);
        var stmt: ?*c.sqlite3_stmt = null;
        const z = try alloc.dupeZ(u8, sql);
        defer alloc.free(z);
        if (c.sqlite3_prepare_v2(self.db, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.Sqlite;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, n.level) != c.SQLITE_OK) return error.Sqlite;
        if (c.sqlite3_bind_blob(stmt, 2, ptrOrEmpty(adj), @intCast(adj.len), SQLITE_TRANSIENT) != c.SQLITE_OK) return error.Sqlite;
        if (c.sqlite3_bind_int64(stmt, 3, n.id) != c.SQLITE_OK) return error.Sqlite;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.Sqlite;
    }

    fn persistMetadataIndex(self: *VTab, n: *Node) !void {
        const idx = try self.shadowName("_idx");
        defer alloc.free(idx);
        const q_idx = try qualifiedName(self.schema, idx);
        defer alloc.free(q_idx);
        const delete_sql = try std.fmt.allocPrint(alloc, "DELETE FROM {s} WHERE id=?", .{q_idx});
        defer freeQuotedSql(delete_sql);
        var del: ?*c.sqlite3_stmt = null;
        const zd = try alloc.dupeZ(u8, delete_sql);
        defer alloc.free(zd);
        if (c.sqlite3_prepare_v2(self.db, zd.ptr, -1, &del, null) != c.SQLITE_OK) return error.Sqlite;
        defer _ = c.sqlite3_finalize(del);
        if (c.sqlite3_bind_int64(del, 1, n.id) != c.SQLITE_OK) return error.Sqlite;
        if (c.sqlite3_step(del) != c.SQLITE_DONE) return error.Sqlite;

        const insert_sql = try std.fmt.allocPrint(alloc, "INSERT INTO {s}(id,col,tag,num,text,blob) VALUES(?,?,?,?,?,?)", .{q_idx});
        defer freeQuotedSql(insert_sql);
        var ins: ?*c.sqlite3_stmt = null;
        const zi = try alloc.dupeZ(u8, insert_sql);
        defer alloc.free(zi);
        if (c.sqlite3_prepare_v2(self.db, zi.ptr, -1, &ins, null) != c.SQLITE_OK) return error.Sqlite;
        defer _ = c.sqlite3_finalize(ins);
        for (self.columns, 0..) |col, i| {
            if (i >= n.values.len) break;
            if (col.kind != .metadata) continue;
            _ = c.sqlite3_reset(ins);
            _ = c.sqlite3_clear_bindings(ins);
            if (c.sqlite3_bind_int64(ins, 1, n.id) != c.SQLITE_OK) return error.Sqlite;
            if (c.sqlite3_bind_int64(ins, 2, @intCast(i)) != c.SQLITE_OK) return error.Sqlite;
            try bindIndexedCell(ins, n.values[i]);
            if (c.sqlite3_step(ins) != c.SQLITE_DONE) return error.Sqlite;
        }
    }

    fn rebuildMetadataIndex(self: *VTab) !void {
        try self.ensureMetadataIndexTables();
        const idx = try self.shadowName("_idx");
        defer alloc.free(idx);
        const q_idx = try qualifiedName(self.schema, idx);
        defer alloc.free(q_idx);
        const delete_sql = try std.fmt.allocPrint(alloc, "DELETE FROM {s}", .{q_idx});
        defer freeQuotedSql(delete_sql);
        try execOwned(self.db, delete_sql);
        const ids = try self.liveIdList();
        defer alloc.free(ids);
        for (ids) |id| {
            const n = (try self.nodeResident(id)) orelse continue;
            if (n.deleted) continue;
            try self.persistMetadataIndex(n);
        }
        try self.trimResidentCache();
    }

    fn fetchVectorBlob(self: *VTab, id: u32) ![]u8 {
        const vec = try self.shadowName("_vec");
        defer alloc.free(vec);
        const q_vec = try qualifiedName(self.schema, vec);
        defer alloc.free(q_vec);
        const sql = try std.fmt.allocPrint(alloc, "SELECT v FROM {s} WHERE id=?", .{q_vec});
        defer freeQuotedSql(sql);
        var stmt: ?*c.sqlite3_stmt = null;
        const z = try alloc.dupeZ(u8, sql);
        defer alloc.free(z);
        if (c.sqlite3_prepare_v2(self.db, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.Sqlite;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, id) != c.SQLITE_OK) return error.Sqlite;
        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_ROW) return error.Sqlite;
        return try columnBlobCopy(stmt, 0);
    }

    fn fetchVectorValue(self: *VTab, id: u32) !VectorValue {
        const blob = try self.fetchVectorBlob(id);
        return decodeVectorBlob(blob, self.config.elem_type, self.config.dims);
    }

    fn deleteNodeRows(self: *VTab, id: u32) !void {
        const node_table = try self.shadowName("_node");
        defer alloc.free(node_table);
        const vec = try self.shadowName("_vec");
        defer alloc.free(vec);
        const idx = try self.shadowName("_idx");
        defer alloc.free(idx);
        const q_node = try qualifiedName(self.schema, node_table);
        defer alloc.free(q_node);
        const q_vec = try qualifiedName(self.schema, vec);
        defer alloc.free(q_vec);
        const q_idx = try qualifiedName(self.schema, idx);
        defer alloc.free(q_idx);
        const sql = try std.fmt.allocPrint(alloc, "DELETE FROM {s} WHERE id={d}; DELETE FROM {s} WHERE id={d}; DELETE FROM {s} WHERE id={d}", .{ q_node, id, q_vec, id, q_idx, id });
        defer freeQuotedSql(sql);
        try execOwned(self.db, sql);
    }

    fn distanceNodes(self: *VTab, a: *Node, b: u32, exact: bool) f64 {
        const nb = self.node(b) orelse return std.math.inf(f64);
        return self.distanceNodePair(a, nb, exact);
    }

    fn distanceNodeIds(self: *VTab, a: u32, b: u32, exact: bool) f64 {
        const na = self.node(a) orelse return std.math.inf(f64);
        const nb = self.node(b) orelse return std.math.inf(f64);
        return self.distanceNodePair(na, nb, exact);
    }

    fn distanceNodePair(self: *VTab, a: *Node, b: *Node, exact: bool) f64 {
        if (!exact and a.q.len == b.q.len and a.q.len > 0) return quantizedDistance(self.config.metric, a.q, a.q_scale, a.q_offset, b.q, b.q_scale, b.q_offset);
        return switch (self.config.metric) {
            .hamming => hamming(a.bits, b.bits),
            .l2 => l2(a.floats, b.floats),
            .cosine => cosineDistance(a.floats, b.floats),
            .ip => innerProductDistance(a.floats, b.floats),
        };
    }

    fn exactDistanceRaw(self: *VTab, id: u32, qf: []const f32, qb: []const u8) !f64 {
        const n = self.node(id) orelse return std.math.inf(f64);
        return try self.exactDistanceNode(n, qf, qb);
    }

    fn exactDistanceNode(self: *VTab, n: *Node, qf: []const f32, qb: []const u8) !f64 {
        if (self.coldFullVectors() and n.floats.len == 0) {
            var vec = try self.fetchVectorValue(n.id);
            defer vec.deinit();
            return switch (self.config.metric) {
                .hamming => hamming(vec.bits, qb),
                .l2 => l2(vec.floats, qf),
                .cosine => cosineDistance(vec.floats, qf),
                .ip => innerProductDistance(vec.floats, qf),
            };
        }
        return switch (self.config.metric) {
            .hamming => hamming(n.bits, qb),
            .l2 => l2(n.floats, qf),
            .cosine => cosineDistance(n.floats, qf),
            .ip => innerProductDistance(n.floats, qf),
        };
    }

    fn distanceRaw(self: *VTab, id: u32, qf: []const f32, qb: []const u8, qq: []const i8, q_scale: f32, q_offset: f32, exact: bool) f64 {
        const n = self.node(id) orelse return std.math.inf(f64);
        if (!exact and n.q.len == qq.len and qq.len > 0) return quantizedDistance(self.config.metric, n.q, n.q_scale, n.q_offset, qq, q_scale, q_offset);
        if (exact) return self.exactDistanceRaw(id, qf, qb) catch std.math.inf(f64);
        return switch (self.config.metric) {
            .hamming => hamming(n.bits, qb),
            .l2 => l2(n.floats, qf),
            .cosine => cosineDistance(n.floats, qf),
            .ip => innerProductDistance(n.floats, qf),
        };
    }
};

const Cursor = struct {
    base: c.sqlite3_vtab_cursor,
    tab: *VTab,
    results: std.ArrayList(SearchResult),
    scan_stmt: ?*c.sqlite3_stmt = null,
    scan_filters: std.ArrayList(QueryFilter),
    scan_node: ?*Node = null,
    pos: usize = 0,

    fn reset(self: *Cursor) void {
        self.results.clearRetainingCapacity();
        self.pos = 0;
        self.clearScan();
    }

    fn clearScan(self: *Cursor) void {
        if (self.scan_node) |n| {
            n.deinit();
            self.scan_node = null;
        }
        if (self.scan_stmt) |stmt| {
            _ = c.sqlite3_finalize(stmt);
            self.scan_stmt = null;
        }
        deinitFilterList(&self.scan_filters);
    }

    fn startScan(self: *Cursor, filters: std.ArrayList(QueryFilter)) !void {
        self.scan_filters = filters;
        errdefer self.clearScan();
        const node_table = try self.tab.shadowName("_node");
        defer alloc.free(node_table);
        const q_node = try qualifiedName(self.tab.schema, node_table);
        defer alloc.free(q_node);
        const sql = try std.fmt.allocPrint(
            alloc,
            "SELECT n.id,n.rowid,n.level,n.deleted,n.part,n.vq,n.vals,n.adj FROM {s} n WHERE n.deleted=0 ORDER BY n.id",
            .{q_node},
        );
        defer freeQuotedSql(sql);
        const z = try alloc.dupeZ(u8, sql);
        defer alloc.free(z);
        if (c.sqlite3_prepare_v2(self.tab.db, z.ptr, -1, &self.scan_stmt, null) != c.SQLITE_OK) return error.Sqlite;
        try self.advanceScan();
    }

    fn advanceScan(self: *Cursor) !void {
        if (self.scan_node) |n| {
            n.deinit();
            self.scan_node = null;
        }
        const stmt = self.scan_stmt orelse return;
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) return;
            if (rc != c.SQLITE_ROW) return error.Sqlite;
            const n = try self.tab.nodeFromStmt(stmt, true);
            if (self.tab.matchesFilters(n, self.scan_filters.items)) {
                self.scan_node = n;
                return;
            }
            n.deinit();
        }
    }

    fn deinit(self: *Cursor) void {
        self.clearScan();
        self.results.deinit(alloc);
        alloc.destroy(self);
    }
};

const Xoshiro = struct {
    s: [4]u64,

    fn init(seed: u64) Xoshiro {
        var sm = SplitMix{ .x = seed };
        return .{ .s = .{ sm.next(), sm.next(), sm.next(), sm.next() } };
    }

    fn fromBytes(raw: []const u8) ?Xoshiro {
        if (raw.len != 32) return null;
        var out: Xoshiro = undefined;
        var pos: usize = 0;
        for (0..4) |i| out.s[i] = readU64(raw, &pos) orelse return null;
        return out;
    }

    fn bytes(self: *const Xoshiro) [32]u8 {
        var out: [32]u8 = undefined;
        var pos: usize = 0;
        for (self.s) |v| {
            std.mem.writeInt(u64, out[pos..][0..8], v, .little);
            pos += 8;
        }
        return out;
    }

    fn next(self: *Xoshiro) u64 {
        const result = std.math.rotl(u64, self.s[1] *% 5, 7) *% 9;
        const t = self.s[1] << 17;
        self.s[2] ^= self.s[0];
        self.s[3] ^= self.s[1];
        self.s[1] ^= self.s[2];
        self.s[0] ^= self.s[3];
        self.s[2] ^= t;
        self.s[3] = std.math.rotl(u64, self.s[3], 45);
        return result;
    }
};

const SplitMix = struct {
    x: u64,

    fn next(self: *SplitMix) u64 {
        self.x +%= 0x9e3779b97f4a7c15;
        var z = self.x;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }
};

pub fn register(db: ?*c.sqlite3) c_int {
    var rc = c.sqlite3_create_module_v2(db, "vann", &module, null, null);
    if (rc != c.SQLITE_OK) return rc;
    const flags = c.SQLITE_UTF8 | c.SQLITE_DETERMINISTIC | c.SQLITE_INNOCUOUS;
    rc = c.sqlite3_create_function(db, "vec_f32", -1, flags, null, vecF32Func, null, null);
    if (rc != c.SQLITE_OK) return rc;
    rc = c.sqlite3_create_function(db, "vec_int8", -1, flags, null, vecInt8Func, null, null);
    if (rc != c.SQLITE_OK) return rc;
    rc = c.sqlite3_create_function(db, "vec_bit", -1, flags, null, vecBitFunc, null, null);
    if (rc != c.SQLITE_OK) return rc;
    rc = c.sqlite3_create_function(db, "vann_info", 1, flags, null, infoFunc, null, null);
    if (rc != c.SQLITE_OK) return rc;
    rc = c.sqlite3_create_function(db, "vann_health", 1, flags, null, healthFunc, null, null);
    if (rc != c.SQLITE_OK) return rc;
    rc = c.sqlite3_create_function(db, "vann_quantization", 1, flags, null, quantFunc, null, null);
    if (rc != c.SQLITE_OK) return rc;
    return c.sqlite3_create_function(db, "vann_rebuild", 1, c.SQLITE_UTF8, null, rebuildFunc, null, null);
}

var module = c.sqlite3_module{
    .iVersion = 4,
    .xCreate = xCreate,
    .xConnect = xConnect,
    .xBestIndex = xBestIndex,
    .xDisconnect = xDisconnect,
    .xDestroy = xDestroy,
    .xOpen = xOpen,
    .xClose = xClose,
    .xFilter = xFilter,
    .xNext = xNext,
    .xEof = xEof,
    .xColumn = xColumn,
    .xRowid = xRowid,
    .xUpdate = xUpdate,
    .xBegin = xBegin,
    .xSync = xSync,
    .xCommit = xCommit,
    .xRollback = xRollback,
    .xFindFunction = null,
    .xRename = xRename,
    .xSavepoint = xSavepoint,
    .xRelease = xRelease,
    .xRollbackTo = xRollbackTo,
    .xShadowName = xShadowName,
    .xIntegrity = xIntegrity,
};

fn xCreate(db: ?*c.sqlite3, aux: ?*anyopaque, argc: c_int, argv: [*c]const [*c]const u8, pp: [*c][*c]c.sqlite3_vtab, pz: [*c][*c]u8) callconv(.c) c_int {
    _ = aux;
    return createOrConnect(db, argc, argv, pp, pz, true);
}

fn xConnect(db: ?*c.sqlite3, aux: ?*anyopaque, argc: c_int, argv: [*c]const [*c]const u8, pp: [*c][*c]c.sqlite3_vtab, pz: [*c][*c]u8) callconv(.c) c_int {
    _ = aux;
    return createOrConnect(db, argc, argv, pp, pz, false);
}

fn createOrConnect(db: ?*c.sqlite3, argc: c_int, argv: [*c]const [*c]const u8, pp: [*c][*c]c.sqlite3_vtab, pz: [*c][*c]u8, create: bool) c_int {
    _ = pz;
    if (argc < 4) return c.SQLITE_ERROR;
    const schema = std.mem.span(argv[1]);
    const name = std.mem.span(argv[2]);
    const parsed = parseDeclaration(argc, argv) catch return c.SQLITE_NOMEM;
    var t = VTab.create(db, schema, name, parsed.columns, parsed.config) catch return c.SQLITE_NOMEM;
    const decl = buildDeclareSql(t.columns) catch {
        t.deinit();
        return c.SQLITE_NOMEM;
    };
    defer alloc.free(decl);
    const decl_z = alloc.dupeZ(u8, decl) catch {
        t.deinit();
        return c.SQLITE_NOMEM;
    };
    defer alloc.free(decl_z);
    if (c.sqlite3_declare_vtab(db, decl_z.ptr) != c.SQLITE_OK) {
        t.deinit();
        return c.SQLITE_ERROR;
    }
    _ = c.sqlite3_vtab_config(db, c.SQLITE_VTAB_CONSTRAINT_SUPPORT, @as(c_int, 1));
    if (create) t.ensureShadowTables() catch {
        t.deinit();
        return c.SQLITE_ERROR;
    };
    t.loadMeta() catch {};
    t.loadNodes() catch {};
    pp.* = &t.base;
    return c.SQLITE_OK;
}

fn xBestIndex(p: ?*c.sqlite3_vtab, info: ?*c.sqlite3_index_info) callconv(.c) c_int {
    const t = tabFromBase(p);
    const idx = info.?;
    var plan_constraints: std.ArrayList(PlanConstraint) = .empty;
    defer plan_constraints.deinit(alloc);
    var argv_index: usize = 1;
    var has_match = false;
    var i: usize = 0;
    while (i < @as(usize, @intCast(idx.nConstraint))) : (i += 1) {
        const con = idx.aConstraint[i];
        if (con.usable == 0) continue;
        const op = mapConstraintOp(con.op) orelse continue;
        const col = con.iColumn;
        var use = false;
        if (op == .match and col == @as(c_int, @intCast(t.config.vector_col))) {
            has_match = true;
            use = true;
        } else if (op == .limit) {
            use = true;
        } else if (col >= 0 and @as(usize, @intCast(col)) < t.columns.len) {
            const k = t.columns[@intCast(col)].kind;
            use = k == .partition or k == .metadata or k == .hidden_k or k == .hidden_ef;
        }
        if (!use) continue;
        idx.aConstraintUsage[i].argvIndex = @intCast(argv_index);
        idx.aConstraintUsage[i].omit = 1;
        plan_constraints.append(alloc, .{ .col = col, .op = op, .argv_index = argv_index }) catch return c.SQLITE_NOMEM;
        argv_index += 1;
    }
    const plan = encodePlan(plan_constraints.items) catch return c.SQLITE_NOMEM;
    defer alloc.free(plan);
    idx.idxStr = sqliteMallocString(plan);
    if (idx.idxStr == null) return c.SQLITE_NOMEM;
    idx.needToFreeIdxStr = 1;
    idx.idxNum = 0;
    idx.estimatedRows = if (has_match) 10 else 1000000;
    idx.estimatedCost = if (has_match) 100.0 else 1000000.0;
    if (has_match and orderByIsDistanceAsc(t, idx)) idx.orderByConsumed = 1;
    return c.SQLITE_OK;
}

fn xDisconnect(p: ?*c.sqlite3_vtab) callconv(.c) c_int {
    tabFromBase(p).deinit();
    return c.SQLITE_OK;
}

fn xDestroy(p: ?*c.sqlite3_vtab) callconv(.c) c_int {
    const t = tabFromBase(p);
    const suffixes = [_][]const u8{ "_meta", "_node", "_vec", "_idx" };
    for (suffixes) |suf| {
        const shadow = t.shadowName(suf) catch continue;
        defer alloc.free(shadow);
        const q_shadow = qualifiedName(t.schema, shadow) catch continue;
        defer alloc.free(q_shadow);
        const sql = std.fmt.allocPrint(alloc, "DROP TABLE IF EXISTS {s}", .{q_shadow}) catch continue;
        defer freeQuotedSql(sql);
        execOwned(t.db, sql) catch {};
    }
    t.deinit();
    return c.SQLITE_OK;
}

fn xOpen(p: ?*c.sqlite3_vtab, pp: [*c][*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const cur = alloc.create(Cursor) catch return c.SQLITE_NOMEM;
    cur.* = .{ .base = .{ .pVtab = p }, .tab = tabFromBase(p), .results = .empty, .scan_filters = .empty };
    pp.* = &cur.base;
    return c.SQLITE_OK;
}

fn xClose(cur: ?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    cursorFromBase(cur).deinit();
    return c.SQLITE_OK;
}

fn xFilter(curp: ?*c.sqlite3_vtab_cursor, idx_num: c_int, idx_str: [*c]const u8, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) c_int {
    _ = idx_num;
    _ = argc;
    const cur = cursorFromBase(curp);
    const t = cur.tab;
    cur.reset();
    const plan_constraints = parsePlan(idx_str) catch return t.setError("vann: malformed query plan");
    defer alloc.free(plan_constraints);
    var q: ?VectorValue = null;
    var filters: std.ArrayList(QueryFilter) = .empty;
    var filters_moved = false;
    defer {
        if (!filters_moved) deinitFilterList(&filters);
        if (q) |*v| v.deinit();
    }
    var k: usize = 10;
    var ef = t.config.ef_search;
    for (plan_constraints) |pc| {
        const v = argv[pc.argv_index - 1];
        if (pc.op == .match) {
            q = decodeSqlValueVector(v, t.config.elem_type, t.config.dims) catch return t.setError("vann: malformed query vector");
            continue;
        }
        if (pc.op == .limit or (pc.col >= 0 and @as(usize, @intCast(pc.col)) == t.config.k_col)) {
            const n = c.sqlite3_value_int64(v);
            if (n > 0) k = @intCast(n);
            continue;
        }
        if (pc.col >= 0 and @as(usize, @intCast(pc.col)) == t.config.ef_col) {
            const n = c.sqlite3_value_int64(v);
            if (n > 0) ef = @intCast(n);
            continue;
        }
        if (pc.col >= 0 and @as(usize, @intCast(pc.col)) < t.columns.len) {
            const cell = cellFromSqlValue(v) catch return c.SQLITE_NOMEM;
            filters.append(alloc, .{ .col = @intCast(pc.col), .op = pc.op, .value = cell }) catch return c.SQLITE_NOMEM;
        }
    }
    if (q) |vec| {
        const res = t.search(vec, filters.items, k, ef) catch return t.setError("vann: search failed");
        defer alloc.free(res);
        for (res) |r| cur.results.append(alloc, r) catch return c.SQLITE_NOMEM;
    } else {
        t.refreshIfNeeded();
        filters_moved = true;
        cur.startScan(filters) catch return t.setError("vann: scan failed");
    }
    return c.SQLITE_OK;
}

fn xNext(cur: ?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const ccur = cursorFromBase(cur);
    if (ccur.scan_stmt != null) {
        ccur.advanceScan() catch return ccur.tab.setError("vann: scan failed");
    } else {
        ccur.pos += 1;
    }
    return c.SQLITE_OK;
}

fn xEof(cur: ?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const ccur = cursorFromBase(cur);
    if (ccur.scan_stmt != null) return if (ccur.scan_node == null) 1 else 0;
    return if (ccur.pos >= ccur.results.items.len) 1 else 0;
}

fn xColumn(curp: ?*c.sqlite3_vtab_cursor, ctx: ?*c.sqlite3_context, col: c_int) callconv(.c) c_int {
    const cur = cursorFromBase(curp);
    const t = cur.tab;
    const col_usize: usize = @intCast(col);
    if (col_usize == t.config.distance_col) {
        const distance = if (cur.scan_stmt != null) 0 else if (cur.pos < cur.results.items.len) cur.results.items[cur.pos].distance else 0;
        c.sqlite3_result_double(ctx, distance);
        return c.SQLITE_OK;
    }
    if (col_usize == t.config.k_col or col_usize == t.config.ef_col) {
        c.sqlite3_result_null(ctx);
        return c.SQLITE_OK;
    }
    const n = if (cur.scan_stmt != null)
        cur.scan_node
    else if (cur.pos < cur.results.items.len)
        t.node(cur.results.items[cur.pos].id)
    else
        null;
    const node = n orelse {
        c.sqlite3_result_null(ctx);
        return c.SQLITE_OK;
    };
    if (col_usize == t.config.vector_col) {
        if (node.vec_blob.len == 0) {
            const blob = t.fetchVectorBlob(node.id) catch return t.setError("vann: vector fetch failed");
            defer alloc.free(blob);
            c.sqlite3_result_blob(ctx, ptrOrEmpty(blob), @intCast(blob.len), SQLITE_TRANSIENT);
        } else {
            c.sqlite3_result_blob(ctx, ptrOrEmpty(node.vec_blob), @intCast(node.vec_blob.len), null);
        }
        return c.SQLITE_OK;
    }
    if (col_usize < node.values.len) node.values[col_usize].result(ctx) else c.sqlite3_result_null(ctx);
    return c.SQLITE_OK;
}

fn xRowid(curp: ?*c.sqlite3_vtab_cursor, rowid: [*c]c.sqlite3_int64) callconv(.c) c_int {
    const cur = cursorFromBase(curp);
    rowid.* = if (cur.scan_stmt != null)
        if (cur.scan_node) |n| n.rowid else 0
    else if (cur.pos < cur.results.items.len)
        cur.results.items[cur.pos].rowid
    else
        0;
    return c.SQLITE_OK;
}

fn xUpdate(p: ?*c.sqlite3_vtab, argc: c_int, argv: [*c]?*c.sqlite3_value, out_rowid: [*c]c.sqlite3_int64) callconv(.c) c_int {
    const t = tabFromBase(p);
    if (argc == 1) {
        const rowid = c.sqlite3_value_int64(argv[0]);
        t.deleteRow(rowid) catch return t.setError("vann: delete failed");
        return c.SQLITE_OK;
    }
    const old_type = c.sqlite3_value_type(argv[0]);
    const new_type = c.sqlite3_value_type(argv[1]);
    const rowid = if (new_type == c.SQLITE_NULL) nextRowid(t) else c.sqlite3_value_int64(argv[1]);
    var values = alloc.alloc(Cell, t.config.visible_cols) catch return c.SQLITE_NOMEM;
    for (values) |*v| v.* = .{ .null = {} };
    var values_owned = true;
    defer if (values_owned) deinitCellSlice(values);
    var vec: ?VectorValue = null;
    var vec_owned = false;
    defer if (vec_owned) {
        if (vec) |*v| v.deinit();
    };
    var i: usize = 0;
    while (i < t.config.visible_cols) : (i += 1) {
        const v = argv[2 + i];
        if (i == t.config.vector_col) {
            vec = decodeSqlValueVector(v, t.config.elem_type, t.config.dims) catch return t.setError("vann: malformed vector");
            vec_owned = true;
        } else {
            values[i] = cellFromSqlValue(v) catch return c.SQLITE_NOMEM;
        }
    }
    if (vec == null) return t.setError("vann: missing vector");
    if (old_type != c.SQLITE_NULL) {
        const old = c.sqlite3_value_int64(argv[0]);
        if (old == rowid) {
            if (t.updateNodeValuesIfSameVector(rowid, values, vec.?) catch {
                t.reloadFromDisk() catch {};
                return t.setError("vann: update failed");
            }) {
                out_rowid.* = rowid;
                return c.SQLITE_OK;
            }
        }
        if (old != rowid) t.deleteRow(old) catch {
            t.reloadFromDisk() catch {};
            return t.setError("vann: update delete failed");
        };
    }
    const insert_vec = vec.?;
    vec = null;
    vec_owned = false;
    values_owned = false;
    t.insertNode(rowid, values, insert_vec) catch {
        t.reloadFromDisk() catch {};
        return t.setError("vann: insert failed");
    };
    out_rowid.* = rowid;
    return c.SQLITE_OK;
}

fn xBegin(p: ?*c.sqlite3_vtab) callconv(.c) c_int {
    const t = tabFromBase(p);
    t.resetUndoForTransaction() catch return c.SQLITE_NOMEM;
    return c.SQLITE_OK;
}

fn xSync(p: ?*c.sqlite3_vtab) callconv(.c) c_int {
    _ = p;
    return c.SQLITE_OK;
}

fn xCommit(p: ?*c.sqlite3_vtab) callconv(.c) c_int {
    const t = tabFromBase(p);
    t.loadMeta() catch {};
    t.clearUndoLog();
    return c.SQLITE_OK;
}

fn xRollback(p: ?*c.sqlite3_vtab) callconv(.c) c_int {
    const t = tabFromBase(p);
    if (t.frames.items.len > 0) {
        const frame = t.frames.items[0];
        t.rollbackUndoTo(frame.undo_len, frame.version, frame.prng) catch {
            t.reloadFromDisk() catch {};
        };
    } else {
        t.reloadFromDisk() catch {};
    }
    t.clearUndoLog();
    return c.SQLITE_OK;
}

fn xSavepoint(p: ?*c.sqlite3_vtab, n: c_int) callconv(.c) c_int {
    const t = tabFromBase(p);
    t.beginUndoFrame(n) catch return c.SQLITE_NOMEM;
    return c.SQLITE_OK;
}

fn xRelease(p: ?*c.sqlite3_vtab, n: c_int) callconv(.c) c_int {
    const t = tabFromBase(p);
    if (t.findFrame(n)) |idx| {
        while (t.frames.items.len > idx) _ = t.frames.pop();
    }
    return c.SQLITE_OK;
}

fn xRollbackTo(p: ?*c.sqlite3_vtab, n: c_int) callconv(.c) c_int {
    const t = tabFromBase(p);
    if (t.findFrame(n)) |idx| {
        const frame = t.frames.items[idx];
        t.rollbackUndoTo(frame.undo_len, frame.version, frame.prng) catch {
            t.reloadFromDisk() catch {};
            return c.SQLITE_ERROR;
        };
        while (t.frames.items.len > idx + 1) _ = t.frames.pop();
    } else {
        t.reloadFromDisk() catch {};
    }
    return c.SQLITE_OK;
}

fn xRename(p: ?*c.sqlite3_vtab, new_name_z: [*c]const u8) callconv(.c) c_int {
    const t = tabFromBase(p);
    const new_name = std.mem.span(new_name_z);
    const suffixes = [_][]const u8{ "_meta", "_node", "_vec", "_idx" };
    const old_prefix = alloc.dupe(u8, t.prefix) catch return c.SQLITE_NOMEM;
    defer alloc.free(old_prefix);
    const new_prefix = makeShadowPrefix(new_name) catch return c.SQLITE_NOMEM;
    for (suffixes) |suf| {
        const old = std.fmt.allocPrint(alloc, "{s}{s}", .{ old_prefix, suf }) catch return c.SQLITE_NOMEM;
        defer alloc.free(old);
        const new = std.fmt.allocPrint(alloc, "{s}{s}", .{ new_prefix, suf }) catch return c.SQLITE_NOMEM;
        defer alloc.free(new);
        const q_old = qualifiedName(t.schema, old) catch return c.SQLITE_NOMEM;
        defer alloc.free(q_old);
        const q_new = quoteIdent(new) catch return c.SQLITE_NOMEM;
        defer alloc.free(q_new);
        const sql = std.fmt.allocPrint(alloc, "ALTER TABLE {s} RENAME TO {s}", .{ q_old, q_new }) catch return c.SQLITE_NOMEM;
        defer freeQuotedSql(sql);
        execOwned(t.db, sql) catch return c.SQLITE_ERROR;
    }
    alloc.free(t.name);
    alloc.free(t.prefix);
    t.name = alloc.dupe(u8, new_name) catch return c.SQLITE_NOMEM;
    t.prefix = new_prefix;
    return c.SQLITE_OK;
}

fn xShadowName(name_z: [*c]const u8) callconv(.c) c_int {
    const name = std.mem.span(name_z);
    return if (std.mem.startsWith(u8, name, "_vann_")) 1 else 0;
}

fn xIntegrity(p: ?*c.sqlite3_vtab, schema_z: [*c]const u8, tab_z: [*c]const u8, flags: c_int, err: [*c][*c]u8) callconv(.c) c_int {
    _ = schema_z;
    _ = tab_z;
    _ = flags;
    const t = tabFromBase(p);
    const ids = t.liveIdList() catch {
        err.* = sqliteMallocString("vann: out of memory");
        return c.SQLITE_NOMEM;
    };
    defer alloc.free(ids);
    for (ids) |node_id| {
        const n = t.node(node_id) orelse continue;
        if (n.deleted) continue;
        for (n.adj.items) |lvl| {
            for (lvl.items) |edge_id| {
                if (t.node(edge_id) == null) {
                    err.* = sqliteMallocString("vann: dangling graph edge");
                    return c.SQLITE_CORRUPT_VTAB;
                }
            }
        }
    }
    t.trimResidentCache() catch {};
    return c.SQLITE_OK;
}

// Scalar functions.

fn vecF32Func(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    vectorConstructor(ctx, argc, argv, .f32);
}

fn vecInt8Func(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    vectorConstructor(ctx, argc, argv, .int8);
}

fn vecBitFunc(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    vectorConstructor(ctx, argc, argv, .bit);
}

fn vectorConstructor(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value, elem: ElemType) void {
    if (argc < 1) {
        resultError(ctx, "vector constructor needs a value");
        return;
    }
    const val = argv[0];
    const blob = constructVectorBlob(val, elem) catch {
        resultError(ctx, "malformed vector");
        return;
    };
    defer alloc.free(blob);
    c.sqlite3_result_blob(ctx, ptrOrEmpty(blob), @intCast(blob.len), SQLITE_TRANSIENT);
}

fn infoFunc(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    const snap = readIntrospection(ctx, argc, argv) catch {
        resultError(ctx, "vann_info: table not found or unreadable");
        return;
    };
    defer snap.deinit();
    const json = std.fmt.allocPrint(
        alloc,
        "{{\"module\":\"vann\",\"format\":{d},\"dims\":{d},\"elem_type\":\"{s}\",\"metric\":\"{s}\",\"M\":{d},\"ef_construction\":{d},\"ef_search\":{d},\"cache_nodes\":{d},\"resident_nodes\":{d},\"version\":{d},\"nodes\":{d},\"live\":{d},\"deleted\":{d},\"max_id\":{d},\"free_slots\":{d},\"metadata_index_rows\":{d},\"resident_bytes\":{d},\"hot_payload_bytes\":{d},\"cold_vector_bytes\":{d}}}",
        .{ snap.format, snap.dims, elemTypeName(snap.elem_type), metricName(snap.metric), snap.m, snap.ef_construction, snap.ef_search, snap.cache_nodes, snap.resident_nodes, snap.version, snap.nodes, snap.live, snap.deleted, snap.max_id, snap.free_slots, snap.metadata_index_rows, snap.resident_bytes, snap.hot_payload_bytes, snap.cold_vector_bytes },
    ) catch {
        resultError(ctx, "vann_info: out of memory");
        return;
    };
    defer alloc.free(json);
    resultText(ctx, json);
}

fn healthFunc(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    const snap = readIntrospection(ctx, argc, argv) catch {
        resultError(ctx, "vann_health: table not found or unreadable");
        return;
    };
    defer snap.deinit();
    const status = if (snap.dangling_edges != 0) "corrupt" else "ok";
    const json = std.fmt.allocPrint(
        alloc,
        "{{\"module\":\"vann\",\"status\":\"{s}\",\"nodes\":{d},\"live\":{d},\"deleted\":{d},\"edges\":{d},\"avg_out_degree\":{d},\"low_degree_nodes\":{d},\"orphan_nodes\":{d},\"dangling_edges\":{d},\"free_slots\":{d}}}",
        .{ status, snap.nodes, snap.live, snap.deleted, snap.edges, snap.avg_out_degree, snap.low_degree_nodes, snap.orphan_nodes, snap.dangling_edges, snap.free_slots },
    ) catch {
        resultError(ctx, "vann_health: out of memory");
        return;
    };
    defer alloc.free(json);
    resultText(ctx, json);
}

fn quantFunc(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    const snap = readIntrospection(ctx, argc, argv) catch {
        resultError(ctx, "vann_quantization: table not found or unreadable");
        return;
    };
    defer snap.deinit();
    const traversal = if (snap.elem_type == .bit)
        "packed-bit-hamming"
    else if (snap.elem_type == .f32)
        switch (snap.metric) {
            .l2 => "scaled-int8-l2-traversal-cold-f32-rescore",
            .cosine => "int8-cosine-traversal-cold-f32-rescore",
            .ip => "scaled-int8-ip-traversal-cold-f32-rescore",
            .hamming => "packed-bit-hamming",
        }
    else switch (snap.metric) {
        .l2 => "int8-l2-traversal-and-rescore",
        .cosine => "int8-cosine-traversal-and-rescore",
        .ip => "int8-ip-traversal-and-rescore",
        .hamming => "packed-bit-hamming",
    };
    const json = std.fmt.allocPrint(
        alloc,
        "{{\"module\":\"vann\",\"elem_type\":\"{s}\",\"metric\":\"{s}\",\"dims\":{d},\"traversal\":\"{s}\"}}",
        .{ elemTypeName(snap.elem_type), metricName(snap.metric), snap.dims, traversal },
    ) catch {
        resultError(ctx, "vann_quantization: out of memory");
        return;
    };
    defer alloc.free(json);
    resultText(ctx, json);
}

fn rebuildFunc(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    if (argc != 1 or c.sqlite3_value_type(argv[0]) == c.SQLITE_NULL) {
        resultError(ctx, "vann_rebuild: table name required");
        return;
    }
    const table = valueText(argv[0]);
    const rebuilt = runRebuild(c.sqlite3_context_db_handle(ctx), table) catch {
        resultError(ctx, "vann_rebuild: failed");
        return;
    };
    const json = std.fmt.allocPrint(alloc, "{{\"module\":\"vann\",\"rebuild\":\"ok\",\"nodes\":{d}}}", .{rebuilt}) catch {
        resultError(ctx, "vann_rebuild: out of memory");
        return;
    };
    defer alloc.free(json);
    resultText(ctx, json);
}

fn runRebuild(db: ?*c.sqlite3, table: []const u8) !usize {
    if (table.len == 0) return error.BadArgs;
    try execOwned(db, "SAVEPOINT vann_rebuild");
    errdefer execOwned(db, "ROLLBACK TO vann_rebuild; RELEASE vann_rebuild") catch {};
    const parsed = try readTableDeclaration(db, table);
    var parsed_owned = true;
    errdefer if (parsed_owned) deinitColumns(parsed.columns);
    var t = try VTab.create(db, "main", table, parsed.columns, parsed.config);
    parsed_owned = false;
    defer t.deinit();
    try t.loadMeta();
    try t.loadNodes();
    const rebuilt = try t.rebuildGraph();
    try execOwned(db, "RELEASE vann_rebuild");
    return rebuilt;
}

const Introspection = struct {
    prefix: []u8,
    format: i64,
    dims: i64,
    elem_type: ElemType,
    metric: Metric,
    m: i64,
    ef_construction: i64,
    ef_search: i64,
    cache_nodes: i64,
    resident_nodes: i64,
    version: i64,
    nodes: i64,
    live: i64,
    deleted: i64,
    max_id: i64,
    free_slots: i64,
    edges: i64,
    avg_out_degree: f64,
    low_degree_nodes: i64,
    orphan_nodes: i64,
    dangling_edges: i64,
    metadata_index_rows: i64,
    resident_bytes: i64,
    hot_payload_bytes: i64,
    cold_vector_bytes: i64,

    fn deinit(self: Introspection) void {
        alloc.free(self.prefix);
    }
};

fn readIntrospection(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) !Introspection {
    if (argc != 1 or c.sqlite3_value_type(argv[0]) == c.SQLITE_NULL) return error.BadArgs;
    const table = valueText(argv[0]);
    if (table.len == 0) return error.BadArgs;
    const prefix = try makeShadowPrefix(table);
    errdefer alloc.free(prefix);
    const db = c.sqlite3_context_db_handle(ctx);
    const m = (try metaGetIntByPrefix(db, prefix, "m")) orelse DEFAULT_M;
    const cache_nodes = (try metaGetIntByPrefix(db, prefix, "cache_nodes")) orelse DEFAULT_CACHE_NODES;
    const counts = try readNodeCounts(db, prefix, m, cache_nodes);
    return .{
        .prefix = prefix,
        .format = (try metaGetIntByPrefix(db, prefix, "format")) orelse FORMAT_VERSION,
        .dims = (try metaGetIntByPrefix(db, prefix, "dims")) orelse 0,
        .elem_type = elemTypeFromInt((try metaGetIntByPrefix(db, prefix, "elem_type")) orelse @intFromEnum(ElemType.f32)),
        .metric = metricFromInt((try metaGetIntByPrefix(db, prefix, "metric")) orelse @intFromEnum(Metric.cosine)),
        .m = m,
        .ef_construction = (try metaGetIntByPrefix(db, prefix, "ef_construction")) orelse DEFAULT_EF_CONSTRUCTION,
        .ef_search = (try metaGetIntByPrefix(db, prefix, "ef_search")) orelse DEFAULT_EF_SEARCH,
        .cache_nodes = cache_nodes,
        .resident_nodes = counts.resident_nodes,
        .version = (try metaGetIntByPrefix(db, prefix, "version")) orelse 0,
        .nodes = counts.nodes,
        .live = counts.live,
        .deleted = counts.deleted,
        .max_id = counts.max_id,
        .free_slots = counts.free_slots,
        .edges = counts.edges,
        .avg_out_degree = counts.avg_out_degree,
        .low_degree_nodes = counts.low_degree_nodes,
        .orphan_nodes = counts.orphan_nodes,
        .dangling_edges = counts.dangling_edges,
        .metadata_index_rows = try readMetadataIndexRows(db, prefix),
        .resident_bytes = counts.resident_bytes,
        .hot_payload_bytes = counts.hot_payload_bytes,
        .cold_vector_bytes = counts.cold_vector_bytes,
    };
}

const NodeCounts = struct {
    nodes: i64,
    live: i64,
    deleted: i64,
    max_id: i64,
    free_slots: i64,
    edges: i64,
    avg_out_degree: f64,
    low_degree_nodes: i64,
    orphan_nodes: i64,
    dangling_edges: i64,
    resident_nodes: i64,
    resident_bytes: i64,
    hot_payload_bytes: i64,
    cold_vector_bytes: i64,
};

fn readMetadataIndexRows(db: ?*c.sqlite3, prefix: []const u8) !i64 {
    const idx = try std.fmt.allocPrint(alloc, "{s}_idx", .{prefix});
    defer alloc.free(idx);
    const q_idx = try quoteIdent(idx);
    defer alloc.free(q_idx);
    const sql = try std.fmt.allocPrint(alloc, "SELECT count(*) FROM {s}", .{q_idx});
    defer alloc.free(sql);
    const z = try alloc.dupeZ(u8, sql);
    defer alloc.free(z);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return 0;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.Sqlite;
    return c.sqlite3_column_int64(stmt, 0);
}

const HealthEdge = struct {
    from: u32,
    to: u32,
};

fn readNodeCounts(db: ?*c.sqlite3, prefix: []const u8, m: i64, cache_nodes: i64) !NodeCounts {
    const node_table = try std.fmt.allocPrint(alloc, "{s}_node", .{prefix});
    defer alloc.free(node_table);
    const q_node = try quoteIdent(node_table);
    defer alloc.free(q_node);
    const sql = try std.fmt.allocPrint(alloc, "SELECT id,deleted,adj,length(part),length(vq),length(vals) FROM {s} ORDER BY id", .{q_node});
    defer alloc.free(sql);
    const z = try alloc.dupeZ(u8, sql);
    defer alloc.free(z);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.Sqlite;
    defer _ = c.sqlite3_finalize(stmt);
    var valid_degrees = std.AutoHashMap(u32, u32).init(alloc);
    defer valid_degrees.deinit();
    var edges = std.ArrayList(HealthEdge).empty;
    defer edges.deinit(alloc);
    var out = NodeCounts{
        .nodes = 0,
        .live = 0,
        .deleted = 0,
        .max_id = -1,
        .free_slots = 0,
        .edges = 0,
        .avg_out_degree = 0,
        .low_degree_nodes = 0,
        .orphan_nodes = 0,
        .dangling_edges = 0,
        .resident_nodes = 0,
        .resident_bytes = 0,
        .hot_payload_bytes = 0,
        .cold_vector_bytes = 0,
    };
    const unlimited_resident = cache_nodes <= 0;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.Sqlite;
        const id: u32 = @intCast(c.sqlite3_column_int64(stmt, 0));
        const deleted = c.sqlite3_column_int(stmt, 1) != 0;
        var node_resident_estimate = false;
        out.max_id = @max(out.max_id, @as(i64, @intCast(id)));
        out.nodes += 1;
        if (deleted) {
            out.deleted += 1;
        } else {
            out.live += 1;
            try valid_degrees.put(id, 0);
            var node_bytes = NODE_HEADER_ESTIMATE_BYTES;
            node_bytes += c.sqlite3_column_int64(stmt, 3);
            node_bytes += c.sqlite3_column_int64(stmt, 4);
            node_bytes += c.sqlite3_column_int64(stmt, 5);
            out.hot_payload_bytes += node_bytes;
            if (unlimited_resident or out.resident_nodes < cache_nodes) {
                out.resident_nodes += 1;
                out.resident_bytes += node_bytes;
                node_resident_estimate = true;
            }
        }
        if (!deleted) {
            const adj = try columnBlobCopy(stmt, 2);
            defer alloc.free(adj);
            out.hot_payload_bytes += @intCast(adj.len);
            if (node_resident_estimate) out.resident_bytes += @intCast(adj.len);
            try collectAdjacencyIds(id, adj, &edges);
        }
    }
    if (out.max_id >= 0) out.free_slots = out.max_id + 1 - out.live;
    for (edges.items) |edge| {
        if (!valid_degrees.contains(edge.to)) {
            out.dangling_edges += 1;
            continue;
        }
        if (valid_degrees.getPtr(edge.from)) |degree| {
            degree.* += 1;
            out.edges += 1;
        }
    }
    if (out.live > 0) out.avg_out_degree = @as(f64, @floatFromInt(out.edges)) / @as(f64, @floatFromInt(out.live));
    const low_threshold: u32 = if (m <= 1) 1 else @intCast(@min(m, 2));
    if (out.live > 1) {
        var it = valid_degrees.valueIterator();
        while (it.next()) |degree| {
            if (degree.* == 0) out.orphan_nodes += 1;
            if (degree.* < low_threshold) out.low_degree_nodes += 1;
        }
    }
    out.cold_vector_bytes = readColdVectorBytes(db, prefix) catch 0;
    return out;
}

fn readColdVectorBytes(db: ?*c.sqlite3, prefix: []const u8) !i64 {
    const vec_table = try std.fmt.allocPrint(alloc, "{s}_vec", .{prefix});
    defer alloc.free(vec_table);
    const q_vec = try quoteIdent(vec_table);
    defer alloc.free(q_vec);
    const sql = try std.fmt.allocPrint(alloc, "SELECT coalesce(sum(length(v)),0) FROM {s}", .{q_vec});
    defer alloc.free(sql);
    const z = try alloc.dupeZ(u8, sql);
    defer alloc.free(z);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.Sqlite;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.Sqlite;
    return c.sqlite3_column_int64(stmt, 0);
}

fn collectAdjacencyIds(from: u32, blob: []const u8, out: *std.ArrayList(HealthEdge)) !void {
    if (blob.len == 0) return;
    var pos: usize = 0;
    const levels = readU32(blob, &pos) orelse return error.MalformedAdjacency;
    var l: usize = 0;
    while (l < levels) : (l += 1) {
        const count = readU32(blob, &pos) orelse return error.MalformedAdjacency;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try out.append(alloc, .{ .from = from, .to = readU32(blob, &pos) orelse return error.MalformedAdjacency });
        }
    }
}

fn metaGetIntByPrefix(db: ?*c.sqlite3, prefix: []const u8, key: []const u8) !?i64 {
    const meta = try std.fmt.allocPrint(alloc, "{s}_meta", .{prefix});
    defer alloc.free(meta);
    const q_meta = try quoteIdent(meta);
    defer alloc.free(q_meta);
    const sql = try std.fmt.allocPrint(alloc, "SELECT value FROM {s} WHERE key=?", .{q_meta});
    defer alloc.free(sql);
    const z = try alloc.dupeZ(u8, sql);
    defer alloc.free(z);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.Sqlite;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), SQLITE_TRANSIENT) != c.SQLITE_OK) return error.Sqlite;
    const rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_DONE) return null;
    if (rc != c.SQLITE_ROW) return error.Sqlite;
    const blob = try columnBlobCopy(stmt, 0);
    defer alloc.free(blob);
    return std.fmt.parseInt(i64, blob, 10) catch null;
}

fn elemTypeFromInt(v: i64) ElemType {
    return switch (v) {
        @intFromEnum(ElemType.int8) => .int8,
        @intFromEnum(ElemType.bit) => .bit,
        else => .f32,
    };
}

fn metricFromInt(v: i64) Metric {
    return switch (v) {
        @intFromEnum(Metric.l2) => .l2,
        @intFromEnum(Metric.ip) => .ip,
        @intFromEnum(Metric.hamming) => .hamming,
        else => .cosine,
    };
}

fn elemTypeName(elem: ElemType) []const u8 {
    return switch (elem) {
        .f32 => "f32",
        .int8 => "int8",
        .bit => "bit",
    };
}

fn metricName(metric: Metric) []const u8 {
    return switch (metric) {
        .l2 => "l2",
        .cosine => "cosine",
        .ip => "ip",
        .hamming => "hamming",
    };
}

// Parsing and declaration.

const ParsedDecl = struct {
    columns: []Column,
    config: Config,
};

fn deinitColumns(columns: []Column) void {
    for (columns) |*col| col.deinit();
    alloc.free(columns);
}

fn parseDeclaration(argc: c_int, argv: [*c]const [*c]const u8) !ParsedDecl {
    var items: std.ArrayList([]const u8) = .empty;
    defer items.deinit(alloc);
    var i: usize = 3;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const raw = std.mem.trim(u8, std.mem.span(argv[i]), " \t\r\n");
        if (raw.len != 0) try items.append(alloc, raw);
    }
    return parseDeclarationItems(items.items);
}

fn parseDeclarationItems(items: []const []const u8) !ParsedDecl {
    var cols: std.ArrayList(Column) = .empty;
    errdefer {
        for (cols.items) |*col| col.deinit();
        cols.deinit(alloc);
    }
    var cfg = Config{};
    var saw_vector = false;
    for (items) |item| {
        const raw = std.mem.trim(u8, item, " \t\r\n");
        if (raw.len == 0) continue;
        if (std.mem.indexOfScalar(u8, raw, '=') != null and std.mem.indexOfScalar(u8, raw, ' ') == null) {
            try parseOption(raw, &cfg);
            continue;
        }
        var it = std.mem.tokenizeAny(u8, raw, " \t\r\n");
        const name = it.next() orelse continue;
        const typ = it.next() orelse "text";
        var kind: ColumnKind = .metadata;
        var value_type = parseValueType(typ);
        if (std.mem.eql(u8, typ, "partition")) {
            kind = .partition;
            value_type = .text;
        } else if (std.mem.eql(u8, typ, "aux")) {
            kind = .aux;
            value_type = .blob;
        } else if (parseVectorType(typ)) |vt| {
            if (saw_vector) return error.DuplicateVector;
            saw_vector = true;
            kind = .vector;
            cfg.vector_col = cols.items.len;
            cfg.elem_type = vt.elem;
            cfg.dims = vt.dims;
            value_type = .blob;
        }
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "partition")) kind = .partition else if (std.mem.eql(u8, tok, "aux")) kind = .aux else if (std.mem.startsWith(u8, tok, "metric=")) cfg.metric = parseMetric(tok["metric=".len..]) orelse cfg.metric;
        }
        try appendParsedColumn(&cols, name, kind, value_type);
    }
    if (!saw_vector or cfg.dims == 0) return error.MissingVector;
    if (cfg.m == 0 or cfg.ef_construction == 0 or cfg.ef_search == 0) return error.BadOption;
    cfg.visible_cols = cols.items.len;
    cfg.distance_col = cols.items.len;
    try appendParsedColumn(&cols, "distance", .hidden_distance, .real);
    cfg.k_col = cols.items.len;
    try appendParsedColumn(&cols, "k", .hidden_k, .integer);
    cfg.ef_col = cols.items.len;
    try appendParsedColumn(&cols, "ef", .hidden_ef, .integer);
    if (cfg.elem_type == .bit) cfg.metric = .hamming;
    return .{ .columns = try cols.toOwnedSlice(alloc), .config = cfg };
}

fn appendParsedColumn(cols: *std.ArrayList(Column), name: []const u8, kind: ColumnKind, value_type: ValueType) !void {
    const owned = try alloc.dupe(u8, name);
    errdefer alloc.free(owned);
    try cols.append(alloc, .{ .name = owned, .kind = kind, .value_type = value_type });
}

fn readTableDeclaration(db: ?*c.sqlite3, table: []const u8) !ParsedDecl {
    const create_sql = try readCreateSql(db, table);
    defer alloc.free(create_sql);
    return parseDeclarationFromCreateSql(create_sql);
}

fn readCreateSql(db: ?*c.sqlite3, table: []const u8) ![]u8 {
    const sql = "SELECT sql FROM sqlite_schema WHERE type='table' AND name=?";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.Sqlite;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_bind_text(stmt, 1, ptrOrEmpty(table), @intCast(table.len), SQLITE_TRANSIENT) != c.SQLITE_OK) return error.Sqlite;
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.NotFound;
    return columnTextCopy(stmt, 0);
}

fn parseDeclarationFromCreateSql(sql: []const u8) !ParsedDecl {
    const using_pos = indexOfIgnoreCase(sql, "using") orelse return error.BadDeclaration;
    const after_using = sql[using_pos + "using".len ..];
    const vann_rel = indexOfIgnoreCase(after_using, "vann") orelse return error.BadDeclaration;
    const vann_pos = using_pos + "using".len + vann_rel;
    const open_rel = std.mem.indexOfScalar(u8, sql[vann_pos..], '(') orelse return error.BadDeclaration;
    const open = vann_pos + open_rel;
    const close = std.mem.lastIndexOfScalar(u8, sql, ')') orelse return error.BadDeclaration;
    if (close <= open) return error.BadDeclaration;
    const items = try splitVannArgs(sql[open + 1 .. close]);
    defer alloc.free(items);
    return parseDeclarationItems(items);
}

fn splitVannArgs(raw: []const u8) ![][]const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    errdefer items.deinit(alloc);
    var start: usize = 0;
    var bracket_depth: usize = 0;
    for (raw, 0..) |ch, i| {
        switch (ch) {
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            ',' => if (bracket_depth == 0) {
                const item = std.mem.trim(u8, raw[start..i], " \t\r\n");
                if (item.len != 0) try items.append(alloc, item);
                start = i + 1;
            },
            else => {},
        }
    }
    const item = std.mem.trim(u8, raw[start..], " \t\r\n");
    if (item.len != 0) try items.append(alloc, item);
    return items.toOwnedSlice(alloc);
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (asciiEqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |ch, i| {
        if (std.ascii.toLower(ch) != std.ascii.toLower(b[i])) return false;
    }
    return true;
}

const ParsedVectorType = struct { elem: ElemType, dims: u32 };

fn parseVectorType(typ: []const u8) ?ParsedVectorType {
    const open = std.mem.indexOfScalar(u8, typ, '[') orelse return null;
    const close = std.mem.indexOfScalar(u8, typ, ']') orelse return null;
    const base = typ[0..open];
    const dims = std.fmt.parseInt(u32, typ[open + 1 .. close], 10) catch return null;
    const elem: ElemType = if (std.mem.eql(u8, base, "float") or std.mem.eql(u8, base, "f32"))
        .f32
    else if (std.mem.eql(u8, base, "int8"))
        .int8
    else if (std.mem.eql(u8, base, "bit") or std.mem.eql(u8, base, "binary"))
        .bit
    else
        return null;
    return .{ .elem = elem, .dims = dims };
}

fn parseValueType(typ: []const u8) ValueType {
    if (std.mem.eql(u8, typ, "integer") or std.mem.eql(u8, typ, "int")) return .integer;
    if (std.mem.eql(u8, typ, "real") or std.mem.eql(u8, typ, "float")) return .real;
    if (std.mem.eql(u8, typ, "text")) return .text;
    if (std.mem.eql(u8, typ, "blob")) return .blob;
    return .any;
}

fn parseMetric(s: []const u8) ?Metric {
    if (std.mem.eql(u8, s, "l2")) return .l2;
    if (std.mem.eql(u8, s, "cosine")) return .cosine;
    if (std.mem.eql(u8, s, "ip") or std.mem.eql(u8, s, "inner-product")) return .ip;
    if (std.mem.eql(u8, s, "hamming")) return .hamming;
    return null;
}

fn parseOption(raw: []const u8, cfg: *Config) !void {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return;
    const key = raw[0..eq];
    const val = raw[eq + 1 ..];
    if (std.mem.eql(u8, key, "M")) {
        cfg.m = try std.fmt.parseInt(usize, val, 10);
    } else if (std.mem.eql(u8, key, "ef_construction")) {
        cfg.ef_construction = try std.fmt.parseInt(usize, val, 10);
    } else if (std.mem.eql(u8, key, "ef_search")) {
        cfg.ef_search = try std.fmt.parseInt(usize, val, 10);
    } else if (std.mem.eql(u8, key, "cache_nodes")) {
        cfg.cache_nodes = try std.fmt.parseInt(usize, val, 10);
    } else {
        return error.BadOption;
    }
}

fn buildDeclareSql(cols: []const Column) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "CREATE TABLE x(");
    for (cols, 0..) |col, i| {
        if (i > 0) try out.append(alloc, ',');
        try appendQuotedIdent(&out, col.name);
        try out.append(alloc, ' ');
        try out.appendSlice(alloc, switch (col.value_type) {
            .integer => "INTEGER",
            .real => "REAL",
            .text => "TEXT",
            .blob, .any => "BLOB",
        });
        switch (col.kind) {
            .hidden_distance, .hidden_k, .hidden_ef => try out.appendSlice(alloc, " HIDDEN"),
            else => {},
        }
    }
    try out.append(alloc, ')');
    return out.toOwnedSlice(alloc);
}

// Serialization and vector helpers.

fn constructVectorBlob(val: ?*c.sqlite3_value, elem: ElemType) ![]u8 {
    switch (c.sqlite3_value_type(val)) {
        c.SQLITE_BLOB => {
            const src = valueBlob(val);
            if (isTaggedVector(src)) return alloc.dupe(u8, src);
            return tagRawBlob(src, elem);
        },
        c.SQLITE_TEXT => {
            const txt = valueText(val);
            return switch (elem) {
                .f32 => tagFloats(try parseFloatArray(txt)),
                .int8 => tagInt8(try parseInt8Array(txt)),
                .bit => tagBits(try parseBitText(txt)),
            };
        },
        else => return error.MalformedVector,
    }
}

fn decodeSqlValueVector(val: ?*c.sqlite3_value, elem: ElemType, dims: u32) !VectorValue {
    const blob = try constructVectorBlob(val, elem);
    return decodeVectorBlob(blob, elem, dims);
}

fn decodeVectorBlob(blob: []u8, expected: ElemType, dims: u32) !VectorValue {
    var blob_owned = true;
    errdefer if (blob_owned) alloc.free(blob);
    if (blob.len < 5) return error.MalformedVector;
    if (!isTaggedVector(blob)) return error.MalformedVector;
    const elem: ElemType = @enumFromInt(blob[0]);
    if (elem != expected) return error.WrongVectorType;
    var pos: usize = 1;
    const got_dims = readU32(blob, &pos) orelse return error.MalformedVector;
    if (dims != 0 and got_dims != dims) return error.DimensionMismatch;
    switch (elem) {
        .f32 => {
            if (blob.len != 5 + got_dims * 4) return error.MalformedVector;
            const floats = try alloc.alloc(f32, got_dims);
            var floats_owned = true;
            errdefer if (floats_owned) alloc.free(floats);
            var i: usize = 0;
            while (i < got_dims) : (i += 1) {
                const bits = std.mem.readInt(u32, blob[pos..][0..4], .little);
                floats[i] = @bitCast(bits);
                if (!std.math.isFinite(floats[i])) return error.BadFloat;
                pos += 4;
            }
            blob_owned = false;
            floats_owned = false;
            return .{ .elem_type = elem, .dims = got_dims, .floats = floats, .blob = blob };
        },
        .int8 => {
            if (blob.len != 5 + got_dims) return error.MalformedVector;
            const floats = try alloc.alloc(f32, got_dims);
            var floats_owned = true;
            errdefer if (floats_owned) alloc.free(floats);
            for (floats, 0..) |*f, i| f.* = @floatFromInt(@as(i8, @bitCast(blob[pos + i])));
            blob_owned = false;
            floats_owned = false;
            return .{ .elem_type = elem, .dims = got_dims, .floats = floats, .blob = blob };
        },
        .bit => {
            const nbytes = (got_dims + 7) / 8;
            if (blob.len != 5 + nbytes) return error.MalformedVector;
            const bits = try alloc.dupe(u8, blob[pos .. pos + nbytes]);
            blob_owned = false;
            return .{ .elem_type = elem, .dims = got_dims, .bits = bits, .blob = blob };
        },
    }
}

fn tagRawBlob(src: []const u8, elem: ElemType) ![]u8 {
    return switch (elem) {
        .f32 => {
            if (src.len % 4 != 0) return error.MalformedVector;
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(alloc);
            try out.append(alloc, @intFromEnum(ElemType.f32));
            try writeU32(&out, @intCast(src.len / 4));
            try out.appendSlice(alloc, src);
            return out.toOwnedSlice(alloc);
        },
        .int8 => {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(alloc);
            try out.append(alloc, @intFromEnum(ElemType.int8));
            try writeU32(&out, @intCast(src.len));
            try out.appendSlice(alloc, src);
            return out.toOwnedSlice(alloc);
        },
        .bit => {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(alloc);
            try out.append(alloc, @intFromEnum(ElemType.bit));
            try writeU32(&out, @intCast(src.len * 8));
            try out.appendSlice(alloc, src);
            return out.toOwnedSlice(alloc);
        },
    };
}

fn tagFloats(vals: []f32) ![]u8 {
    defer alloc.free(vals);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, @intFromEnum(ElemType.f32));
    try writeU32(&out, @intCast(vals.len));
    for (vals) |v| {
        const bits: u32 = @bitCast(v);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, bits, .little);
        try out.appendSlice(alloc, &b);
    }
    return out.toOwnedSlice(alloc);
}

fn tagInt8(vals: []i8) ![]u8 {
    defer alloc.free(vals);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, @intFromEnum(ElemType.int8));
    try writeU32(&out, @intCast(vals.len));
    for (vals) |v| try out.append(alloc, @bitCast(v));
    return out.toOwnedSlice(alloc);
}

fn tagBits(bits: BitText) ![]u8 {
    defer alloc.free(bits.bytes);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, @intFromEnum(ElemType.bit));
    try writeU32(&out, bits.dims);
    try out.appendSlice(alloc, bits.bytes);
    return out.toOwnedSlice(alloc);
}

fn parseFloatArray(s: []const u8) ![]f32 {
    var out: std.ArrayList(f32) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (std.ascii.isWhitespace(s[i]) or s[i] == '[' or s[i] == ',')) i += 1;
        if (i >= s.len or s[i] == ']') break;
        const start = i;
        while (i < s.len and !(std.ascii.isWhitespace(s[i]) or s[i] == ',' or s[i] == ']')) i += 1;
        const v = try std.fmt.parseFloat(f32, s[start..i]);
        if (!std.math.isFinite(v)) return error.BadFloat;
        try out.append(alloc, v);
    }
    return out.toOwnedSlice(alloc);
}

fn parseInt8Array(s: []const u8) ![]i8 {
    var out: std.ArrayList(i8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (std.ascii.isWhitespace(s[i]) or s[i] == '[' or s[i] == ',')) i += 1;
        if (i >= s.len or s[i] == ']') break;
        const start = i;
        while (i < s.len and !(std.ascii.isWhitespace(s[i]) or s[i] == ',' or s[i] == ']')) i += 1;
        try out.append(alloc, try std.fmt.parseInt(i8, s[start..i], 10));
    }
    return out.toOwnedSlice(alloc);
}

fn parseBitText(s: []const u8) !BitText {
    var bits: std.ArrayList(u8) = .empty;
    errdefer bits.deinit(alloc);
    var cur: u8 = 0;
    var n: u3 = 0;
    var dims: u32 = 0;
    for (s) |ch| {
        if (ch != '0' and ch != '1') continue;
        dims += 1;
        if (ch == '1') cur |= (@as(u8, 1) << n);
        n += 1;
        if (n == 8) {
            try bits.append(alloc, cur);
            cur = 0;
            n = 0;
        }
    }
    if (n != 0) try bits.append(alloc, cur);
    return .{ .bytes = try bits.toOwnedSlice(alloc), .dims = dims };
}

fn isTaggedVector(blob: []const u8) bool {
    if (blob.len < 5) return false;
    return blob[0] == @intFromEnum(ElemType.f32) or blob[0] == @intFromEnum(ElemType.int8) or blob[0] == @intFromEnum(ElemType.bit);
}

fn quantize(vec: VectorValue, metric: Metric) !QuantizedValue {
    if (vec.elem_type == .bit) return .{ .values = try alloc.alloc(i8, 0) };
    var q = try alloc.alloc(i8, vec.floats.len);
    errdefer alloc.free(q);
    if (metric == .cosine) {
        var norm: f64 = 0;
        for (vec.floats) |v| norm += @as(f64, v) * @as(f64, v);
        norm = @sqrt(norm);
        if (norm == 0) return error.ZeroCosineVector;
        for (vec.floats, 0..) |v, i| q[i] = clampI8((@as(f64, v) / norm) * 127.0);
        return .{ .values = q };
    }
    if (vec.elem_type == .int8) {
        for (vec.floats, 0..) |v, i| q[i] = clampI8(@as(f64, v));
        return .{ .values = q };
    }

    var min_v: f32 = vec.floats[0];
    var max_v: f32 = vec.floats[0];
    for (vec.floats[1..]) |v| {
        if (v < min_v) min_v = v;
        if (v > max_v) max_v = v;
    }
    if (min_v == max_v) {
        @memset(q, 0);
        return .{ .values = q, .scale = 1, .offset = min_v };
    }
    const offset: f32 = (min_v + max_v) / 2.0;
    const scale: f32 = (max_v - min_v) / 254.0;
    if (scale == 0 or !std.math.isFinite(scale)) {
        @memset(q, 0);
        return .{ .values = q, .scale = 1, .offset = offset };
    }
    for (vec.floats, 0..) |v, i| {
        q[i] = clampI8((@as(f64, v) - @as(f64, offset)) / @as(f64, scale));
    }
    return .{ .values = q, .scale = scale, .offset = offset };
}

fn encodeQuantizedBlob(q: []const i8, scale: f32, offset: f32) ![]u8 {
    var out = try alloc.alloc(u8, VQ_HEADER_LEN + q.len);
    @memcpy(out[0..4], VQ_MAGIC[0..4]);
    std.mem.writeInt(u32, out[4..8], @bitCast(scale), .little);
    std.mem.writeInt(u32, out[8..12], @bitCast(offset), .little);
    for (q, 0..) |v, i| out[VQ_HEADER_LEN + i] = @bitCast(v);
    return out;
}

fn decodeQuantizedBlob(blob: []const u8, dims: u32) !QuantizedValue {
    if (blob.len >= VQ_HEADER_LEN and std.mem.eql(u8, blob[0..4], VQ_MAGIC[0..4])) {
        const expected = VQ_HEADER_LEN + @as(usize, @intCast(dims));
        if (dims != 0 and blob.len != expected) return error.MalformedQuantizedVector;
        const scale: f32 = @bitCast(std.mem.readInt(u32, blob[4..8], .little));
        const offset: f32 = @bitCast(std.mem.readInt(u32, blob[8..12], .little));
        if (!std.math.isFinite(scale) or !std.math.isFinite(offset)) return error.MalformedQuantizedVector;
        var out = try alloc.alloc(i8, blob.len - VQ_HEADER_LEN);
        for (blob[VQ_HEADER_LEN..], 0..) |v, i| out[i] = @bitCast(v);
        return .{ .values = out, .scale = scale, .offset = offset };
    }
    if (dims != 0 and blob.len != dims) return error.MalformedQuantizedVector;
    var out = try alloc.alloc(i8, blob.len);
    for (blob, 0..) |v, i| out[i] = @bitCast(v);
    return .{ .values = out };
}

fn clampI8(x: f64) i8 {
    const y = @max(-127.0, @min(127.0, x));
    return @intFromFloat(@round(y));
}

fn serializeCells(cells: []const Cell) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try writeU32(&out, @intCast(cells.len));
    for (cells) |cell| {
        switch (cell) {
            .null => try out.append(alloc, @intFromEnum(CellTag.null)),
            .integer => |v| {
                try out.append(alloc, @intFromEnum(CellTag.integer));
                try writeI64(&out, v);
            },
            .real => |v| {
                try out.append(alloc, @intFromEnum(CellTag.real));
                try writeF64(&out, v);
            },
            .text => |v| {
                try out.append(alloc, @intFromEnum(CellTag.text));
                try writeU32(&out, @intCast(v.len));
                try out.appendSlice(alloc, v);
            },
            .blob => |v| {
                try out.append(alloc, @intFromEnum(CellTag.blob));
                try writeU32(&out, @intCast(v.len));
                try out.appendSlice(alloc, v);
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

fn deserializeCells(blob: []const u8) ![]Cell {
    var pos: usize = 0;
    const n = readU32(blob, &pos) orelse return error.MalformedCells;
    var cells = try alloc.alloc(Cell, n);
    for (cells) |*c0| c0.* = .{ .null = {} };
    errdefer deinitCellSlice(cells);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (pos >= blob.len) return error.MalformedCells;
        if (blob[pos] > @intFromEnum(CellTag.blob)) return error.MalformedCells;
        const tag: CellTag = @enumFromInt(blob[pos]);
        pos += 1;
        cells[i] = switch (tag) {
            .null => .{ .null = {} },
            .integer => .{ .integer = readI64(blob, &pos) orelse return error.MalformedCells },
            .real => .{ .real = readF64(blob, &pos) orelse return error.MalformedCells },
            .text => blk: {
                const len = readU32(blob, &pos) orelse return error.MalformedCells;
                if (pos + len > blob.len) return error.MalformedCells;
                defer pos += len;
                break :blk .{ .text = try alloc.dupe(u8, blob[pos .. pos + len]) };
            },
            .blob => blk: {
                const len = readU32(blob, &pos) orelse return error.MalformedCells;
                if (pos + len > blob.len) return error.MalformedCells;
                defer pos += len;
                break :blk .{ .blob = try alloc.dupe(u8, blob[pos .. pos + len]) };
            },
        };
    }
    return cells;
}

// Distance kernels.

fn l2(a: []const f32, b: []const f32) f64 {
    var sum: f64 = 0;
    for (a, b) |x, y| {
        const d = @as(f64, x) - @as(f64, y);
        sum += d * d;
    }
    return sum;
}

fn cosineDistance(a: []const f32, b: []const f32) f64 {
    var dot: f64 = 0;
    var an: f64 = 0;
    var bn: f64 = 0;
    for (a, b) |x, y| {
        dot += @as(f64, x) * @as(f64, y);
        an += @as(f64, x) * @as(f64, x);
        bn += @as(f64, y) * @as(f64, y);
    }
    if (an == 0 or bn == 0) return std.math.inf(f64);
    return 1.0 - dot / (@sqrt(an) * @sqrt(bn));
}

fn innerProductDistance(a: []const f32, b: []const f32) f64 {
    var dot: f64 = 0;
    for (a, b) |x, y| dot += @as(f64, x) * @as(f64, y);
    return -dot;
}

fn int8L2(a: []const i8, b: []const i8) f64 {
    var sum: f64 = 0;
    for (a, b) |x, y| {
        const d = @as(i32, x) - @as(i32, y);
        sum += @floatFromInt(d * d);
    }
    return sum;
}

fn quantizedDistance(metric: Metric, a: []const i8, a_scale: f32, a_offset: f32, b: []const i8, b_scale: f32, b_offset: f32) f64 {
    return switch (metric) {
        .l2 => quantizedL2(a, a_scale, a_offset, b, b_scale, b_offset),
        .cosine => int8CosineDistance(a, b),
        .ip => quantizedInnerProductDistance(a, a_scale, a_offset, b, b_scale, b_offset),
        .hamming => int8L2(a, b),
    };
}

fn quantizedL2(a: []const i8, a_scale: f32, a_offset: f32, b: []const i8, b_scale: f32, b_offset: f32) f64 {
    var sum: f64 = 0;
    for (a, b) |x, y| {
        const xf = dequantizeI8(x, a_scale, a_offset);
        const yf = dequantizeI8(y, b_scale, b_offset);
        const d = xf - yf;
        sum += d * d;
    }
    return sum;
}

fn quantizedInnerProductDistance(a: []const i8, a_scale: f32, a_offset: f32, b: []const i8, b_scale: f32, b_offset: f32) f64 {
    var dot: f64 = 0;
    for (a, b) |x, y| dot += dequantizeI8(x, a_scale, a_offset) * dequantizeI8(y, b_scale, b_offset);
    return -dot;
}

fn dequantizeI8(v: i8, scale: f32, offset: f32) f64 {
    return @as(f64, offset) + @as(f64, scale) * @as(f64, @floatFromInt(v));
}

fn int8Distance(metric: Metric, a: []const i8, b: []const i8) f64 {
    return switch (metric) {
        .l2 => int8L2(a, b),
        .cosine => int8CosineDistance(a, b),
        .ip => int8InnerProductDistance(a, b),
        .hamming => int8L2(a, b),
    };
}

fn int8CosineDistance(a: []const i8, b: []const i8) f64 {
    var dot: f64 = 0;
    var an: f64 = 0;
    var bn: f64 = 0;
    for (a, b) |x, y| {
        const xf: f64 = @floatFromInt(x);
        const yf: f64 = @floatFromInt(y);
        dot += xf * yf;
        an += xf * xf;
        bn += yf * yf;
    }
    if (an == 0 or bn == 0) return std.math.inf(f64);
    return 1.0 - dot / (@sqrt(an) * @sqrt(bn));
}

fn int8InnerProductDistance(a: []const i8, b: []const i8) f64 {
    var dot: f64 = 0;
    for (a, b) |x, y| dot += @as(f64, @floatFromInt(x)) * @as(f64, @floatFromInt(y));
    return -dot;
}

fn hamming(a: []const u8, b: []const u8) f64 {
    var n: u32 = 0;
    for (a, b) |x, y| n += @popCount(x ^ y);
    return @floatFromInt(n);
}

// Small collections.

fn bestUnexpanded(items: []const Candidate) ?usize {
    var best: ?usize = null;
    for (items, 0..) |cnd, i| {
        if (cnd.expanded) continue;
        if (best == null or cnd.distance < items[best.?].distance or (cnd.distance == items[best.?].distance and cnd.id < items[best.?].id)) best = i;
    }
    return best;
}

fn worstDistance(items: []const Neighbor) f64 {
    var w: f64 = -std.math.inf(f64);
    for (items) |n| w = @max(w, n.distance);
    return w;
}

fn insertBounded(list: *std.ArrayList(Neighbor), item: Neighbor, cap: usize) !void {
    try list.append(alloc, item);
    sortNeighbors(list.items);
    while (list.items.len > cap) _ = list.pop();
}

fn insertResultBounded(list: *std.ArrayList(SearchResult), item: SearchResult, cap: usize) !void {
    try list.append(alloc, item);
    var i: usize = list.items.len - 1;
    while (i > 0) : (i -= 1) {
        const prev = list.items[i - 1];
        const cur = list.items[i];
        if (prev.distance < cur.distance or (prev.distance == cur.distance and prev.rowid <= cur.rowid)) break;
        list.items[i - 1] = cur;
        list.items[i] = prev;
    }
    while (list.items.len > cap) _ = list.pop();
}

fn sortNeighbors(items: []Neighbor) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and (items[j].distance < items[j - 1].distance or (items[j].distance == items[j - 1].distance and items[j].id < items[j - 1].id))) : (j -= 1) {
            const tmp = items[j - 1];
            items[j - 1] = items[j];
            items[j] = tmp;
        }
    }
}

fn sortU32(items: []u32) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and items[j] < items[j - 1]) : (j -= 1) {
            const tmp = items[j - 1];
            items[j - 1] = items[j];
            items[j] = tmp;
        }
    }
}

fn cloneNeighbors(items: []const Neighbor) ![]Neighbor {
    const out = try alloc.alloc(Neighbor, items.len);
    @memcpy(out, items);
    return out;
}

fn addUnique(list: *std.ArrayList(u32), id: u32) !void {
    for (list.items) |x| if (x == id) return;
    try list.append(alloc, id);
}

fn removeId(list: *std.ArrayList(u32), id: u32) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (list.items[i] == id) {
            _ = list.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

// SQLite value helpers.

fn cellFromSqlValue(v: ?*c.sqlite3_value) !Cell {
    return switch (c.sqlite3_value_type(v)) {
        c.SQLITE_INTEGER => .{ .integer = c.sqlite3_value_int64(v) },
        c.SQLITE_FLOAT => .{ .real = c.sqlite3_value_double(v) },
        c.SQLITE_TEXT => .{ .text = try alloc.dupe(u8, valueText(v)) },
        c.SQLITE_BLOB => .{ .blob = try alloc.dupe(u8, valueBlob(v)) },
        else => .{ .null = {} },
    };
}

fn valueText(v: ?*c.sqlite3_value) []const u8 {
    const p = c.sqlite3_value_text(v);
    const n = c.sqlite3_value_bytes(v);
    if (p == null or n <= 0) return "";
    return p[0..@intCast(n)];
}

fn valueBlob(v: ?*c.sqlite3_value) []const u8 {
    const p = c.sqlite3_value_blob(v);
    const n = c.sqlite3_value_bytes(v);
    if (p == null or n <= 0) return "";
    const bytes: [*]const u8 = @ptrCast(p);
    return bytes[0..@intCast(n)];
}

fn columnBlobCopy(stmt: ?*c.sqlite3_stmt, col: c_int) ![]u8 {
    const p = c.sqlite3_column_blob(stmt, col);
    const n = c.sqlite3_column_bytes(stmt, col);
    if (p == null or n <= 0) return alloc.dupe(u8, "");
    const bytes: [*]const u8 = @ptrCast(p);
    return alloc.dupe(u8, bytes[0..@intCast(n)]);
}

fn columnTextCopy(stmt: ?*c.sqlite3_stmt, col: c_int) ![]u8 {
    const p = c.sqlite3_column_text(stmt, col);
    const n = c.sqlite3_column_bytes(stmt, col);
    if (p == null or n <= 0) return alloc.dupe(u8, "");
    return alloc.dupe(u8, p[0..@intCast(n)]);
}

fn ptrOrEmpty(v: []const u8) [*c]const u8 {
    return if (v.len == 0) "" else @ptrCast(v.ptr);
}

fn bindIndexedCell(stmt: ?*c.sqlite3_stmt, cell: Cell) !void {
    switch (cell) {
        .null => {
            if (c.sqlite3_bind_int64(stmt, 3, @intFromEnum(CellTag.null)) != c.SQLITE_OK) return error.Sqlite;
        },
        .integer => |v| {
            if (c.sqlite3_bind_int64(stmt, 3, @intFromEnum(CellTag.integer)) != c.SQLITE_OK) return error.Sqlite;
            if (c.sqlite3_bind_double(stmt, 4, @floatFromInt(v)) != c.SQLITE_OK) return error.Sqlite;
        },
        .real => |v| {
            if (c.sqlite3_bind_int64(stmt, 3, @intFromEnum(CellTag.real)) != c.SQLITE_OK) return error.Sqlite;
            if (c.sqlite3_bind_double(stmt, 4, v) != c.SQLITE_OK) return error.Sqlite;
        },
        .text => |v| {
            if (c.sqlite3_bind_int64(stmt, 3, @intFromEnum(CellTag.text)) != c.SQLITE_OK) return error.Sqlite;
            if (c.sqlite3_bind_text(stmt, 5, ptrOrEmpty(v), @intCast(v.len), SQLITE_TRANSIENT) != c.SQLITE_OK) return error.Sqlite;
        },
        .blob => |v| {
            if (c.sqlite3_bind_int64(stmt, 3, @intFromEnum(CellTag.blob)) != c.SQLITE_OK) return error.Sqlite;
            if (c.sqlite3_bind_blob(stmt, 6, ptrOrEmpty(v), @intCast(v.len), SQLITE_TRANSIENT) != c.SQLITE_OK) return error.Sqlite;
        },
    }
}

fn indexedPredicateSql(f: QueryFilter) ?[]const u8 {
    return switch (f.value) {
        .null => if (f.op == .eq) "tag=0" else null,
        .integer, .real => switch (f.op) {
            .eq => "(tag=1 OR tag=2) AND num = ?",
            .gt => "(tag=1 OR tag=2) AND num > ?",
            .ge => "(tag=1 OR tag=2) AND num >= ?",
            .lt => "(tag=1 OR tag=2) AND num < ?",
            .le => "(tag=1 OR tag=2) AND num <= ?",
            else => null,
        },
        .text => if (f.op == .eq) "tag=3 AND text = ?" else null,
        .blob => if (f.op == .eq) "tag=4 AND blob = ?" else null,
    };
}

fn bindIndexedPredicateValue(stmt: ?*c.sqlite3_stmt, f: QueryFilter) !void {
    switch (f.value) {
        .null => {},
        .integer => |v| {
            if (c.sqlite3_bind_double(stmt, 2, @floatFromInt(v)) != c.SQLITE_OK) return error.Sqlite;
        },
        .real => |v| {
            if (c.sqlite3_bind_double(stmt, 2, v) != c.SQLITE_OK) return error.Sqlite;
        },
        .text => |v| {
            if (c.sqlite3_bind_text(stmt, 2, ptrOrEmpty(v), @intCast(v.len), SQLITE_TRANSIENT) != c.SQLITE_OK) return error.Sqlite;
        },
        .blob => |v| {
            if (c.sqlite3_bind_blob(stmt, 2, ptrOrEmpty(v), @intCast(v.len), SQLITE_TRANSIENT) != c.SQLITE_OK) return error.Sqlite;
        },
    }
}

// Comparison/filtering.

fn cellCompare(left: Cell, right: Cell, op: ConstraintOp) bool {
    if (op == .eq) return cellEq(left, right);
    const lnum = cellNumber(left) orelse return false;
    const rnum = cellNumber(right) orelse return false;
    return switch (op) {
        .gt => lnum > rnum,
        .ge => lnum >= rnum,
        .lt => lnum < rnum,
        .le => lnum <= rnum,
        else => false,
    };
}

fn cellEq(a: Cell, b: Cell) bool {
    return switch (a) {
        .null => b == .null,
        .integer => |x| if (cellNumber(b)) |y| @as(f64, @floatFromInt(x)) == y else false,
        .real => |x| if (cellNumber(b)) |y| x == y else false,
        .text => |x| switch (b) {
            .text => |y| std.mem.eql(u8, x, y),
            else => false,
        },
        .blob => |x| switch (b) {
            .blob => |y| std.mem.eql(u8, x, y),
            else => false,
        },
    };
}

fn cellNumber(c0: Cell) ?f64 {
    return switch (c0) {
        .integer => |v| @floatFromInt(v),
        .real => |v| v,
        else => null,
    };
}

fn appendCellKey(out: *std.ArrayList(u8), cell: Cell) !void {
    switch (cell) {
        .null => try out.append(alloc, 0),
        .integer => |v| {
            try out.append(alloc, 1);
            try writeI64(out, v);
        },
        .real => |v| {
            try out.append(alloc, 2);
            try writeF64(out, v);
        },
        .text => |v| {
            try out.append(alloc, 3);
            try writeU32(out, @intCast(v.len));
            try out.appendSlice(alloc, v);
        },
        .blob => |v| {
            try out.append(alloc, 4);
            try writeU32(out, @intCast(v.len));
            try out.appendSlice(alloc, v);
        },
    }
}

// SQL/string helpers.

fn execOwned(db: ?*c.sqlite3, sql: []const u8) !void {
    const z = try alloc.dupeZ(u8, sql);
    defer alloc.free(z);
    var errmsg: [*c]u8 = null;
    if (c.sqlite3_exec(db, z.ptr, null, null, &errmsg) != c.SQLITE_OK) {
        if (errmsg != null) c.sqlite3_free(errmsg);
        return error.Sqlite;
    }
}

fn freeQuotedSql(sql: []u8) void {
    alloc.free(sql);
}

fn qualifiedName(schema: []const u8, table: []const u8) ![]u8 {
    const q_schema = try quoteIdent(schema);
    defer alloc.free(q_schema);
    const q_table = try quoteIdent(table);
    defer alloc.free(q_table);
    return std.fmt.allocPrint(alloc, "{s}.{s}", .{ q_schema, q_table });
}

fn quoteIdent(s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try appendQuotedIdent(&out, s);
    return out.toOwnedSlice(alloc);
}

fn appendQuotedIdent(out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |ch| {
        if (ch == '"') try out.append(alloc, '"');
        try out.append(alloc, ch);
    }
    try out.append(alloc, '"');
}

fn makeShadowPrefix(name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "_vann_");
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_') try out.append(alloc, ch) else try out.append(alloc, '_');
    }
    var buf: [32]u8 = undefined;
    const suffix = try std.fmt.bufPrint(&buf, "_{d}", .{hashSeed(name)});
    try out.appendSlice(alloc, suffix);
    return out.toOwnedSlice(alloc);
}

fn hashSeed(s: []const u8) u64 {
    var h: u64 = 1469598103934665603;
    for (s) |ch| {
        h ^= ch;
        h *%= 1099511628211;
    }
    return h;
}

fn sqliteMallocString(msg: []const u8) [*c]u8 {
    const p = c.sqlite3_malloc(@intCast(msg.len + 1));
    if (p == null) return null;
    const bytes: [*]u8 = @ptrCast(p);
    @memcpy(bytes[0..msg.len], msg);
    bytes[msg.len] = 0;
    return @ptrCast(bytes);
}

fn resultError(ctx: ?*c.sqlite3_context, msg: []const u8) void {
    c.sqlite3_result_error(ctx, msg.ptr, @intCast(msg.len));
}

fn resultText(ctx: ?*c.sqlite3_context, msg: []const u8) void {
    c.sqlite3_result_text(ctx, ptrOrEmpty(msg), @intCast(msg.len), SQLITE_TRANSIENT);
}

fn nextRowid(t: *VTab) i64 {
    var max: i64 = 0;
    var it = t.row_map.keyIterator();
    while (it.next()) |rowid| {
        if (rowid.* > max) max = rowid.*;
    }
    return max + 1;
}

fn mapConstraintOp(op: u8) ?ConstraintOp {
    return switch (op) {
        c.SQLITE_INDEX_CONSTRAINT_EQ => .eq,
        c.SQLITE_INDEX_CONSTRAINT_GT => .gt,
        c.SQLITE_INDEX_CONSTRAINT_GE => .ge,
        c.SQLITE_INDEX_CONSTRAINT_LT => .lt,
        c.SQLITE_INDEX_CONSTRAINT_LE => .le,
        c.SQLITE_INDEX_CONSTRAINT_MATCH => .match,
        c.SQLITE_INDEX_CONSTRAINT_LIMIT => .limit,
        else => null,
    };
}

fn constraintOpFromOrdinal(v: u8) ?ConstraintOp {
    return switch (v) {
        @intFromEnum(ConstraintOp.eq) => .eq,
        @intFromEnum(ConstraintOp.gt) => .gt,
        @intFromEnum(ConstraintOp.ge) => .ge,
        @intFromEnum(ConstraintOp.lt) => .lt,
        @intFromEnum(ConstraintOp.le) => .le,
        @intFromEnum(ConstraintOp.match) => .match,
        @intFromEnum(ConstraintOp.limit) => .limit,
        else => null,
    };
}

fn encodePlan(plan: []const PlanConstraint) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (plan) |pc| {
        var buf: [96]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d},{d},{d};", .{ pc.col, @intFromEnum(pc.op), pc.argv_index });
        try out.appendSlice(alloc, s);
    }
    return out.toOwnedSlice(alloc);
}

fn parsePlan(raw_z: [*c]const u8) ![]PlanConstraint {
    var out: std.ArrayList(PlanConstraint) = .empty;
    errdefer out.deinit(alloc);
    if (raw_z == null) return out.toOwnedSlice(alloc);
    const raw = std.mem.span(raw_z);
    var items = std.mem.splitScalar(u8, raw, ';');
    while (items.next()) |item| {
        if (item.len == 0) continue;
        var fields = std.mem.splitScalar(u8, item, ',');
        const col_s = fields.next() orelse return error.MalformedPlan;
        const op_s = fields.next() orelse return error.MalformedPlan;
        const argv_s = fields.next() orelse return error.MalformedPlan;
        if (fields.next() != null) return error.MalformedPlan;
        const op_i = try std.fmt.parseInt(u8, op_s, 10);
        const op = constraintOpFromOrdinal(op_i) orelse return error.MalformedPlan;
        try out.append(alloc, .{
            .col = try std.fmt.parseInt(i32, col_s, 10),
            .op = op,
            .argv_index = try std.fmt.parseInt(usize, argv_s, 10),
        });
    }
    return out.toOwnedSlice(alloc);
}

fn orderByIsDistanceAsc(t: *VTab, idx: *c.sqlite3_index_info) bool {
    if (idx.nOrderBy != 1 or idx.aOrderBy == null) return false;
    const ob = idx.aOrderBy[0];
    return ob.desc == 0 and ob.iColumn == @as(c_int, @intCast(t.config.distance_col));
}

fn tabFromBase(p: ?*c.sqlite3_vtab) *VTab {
    const tab: *VTab = @alignCast(@fieldParentPtr("base", p.?));
    return tab;
}

fn cursorFromBase(p: ?*c.sqlite3_vtab_cursor) *Cursor {
    const cursor: *Cursor = @alignCast(@fieldParentPtr("base", p.?));
    return cursor;
}

fn readU32(buf: []const u8, pos: *usize) ?u32 {
    if (pos.* + 4 > buf.len) return null;
    defer pos.* += 4;
    return std.mem.readInt(u32, buf[pos.*..][0..4], .little);
}

fn readU64(buf: []const u8, pos: *usize) ?u64 {
    if (pos.* + 8 > buf.len) return null;
    defer pos.* += 8;
    return std.mem.readInt(u64, buf[pos.*..][0..8], .little);
}

fn readI64(buf: []const u8, pos: *usize) ?i64 {
    const v = readU64(buf, pos) orelse return null;
    return @bitCast(v);
}

fn readF64(buf: []const u8, pos: *usize) ?f64 {
    const v = readU64(buf, pos) orelse return null;
    return @bitCast(v);
}

fn writeU32(out: *std.ArrayList(u8), value: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, value, .little);
    try out.appendSlice(alloc, &b);
}

fn writeI64(out: *std.ArrayList(u8), value: i64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, @bitCast(value), .little);
    try out.appendSlice(alloc, &b);
}

fn writeF64(out: *std.ArrayList(u8), value: f64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, @bitCast(value), .little);
    try out.appendSlice(alloc, &b);
}
