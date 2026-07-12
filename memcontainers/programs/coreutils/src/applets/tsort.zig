//! `tsort` -- DESIGN.md §1: topological sort of a graph described by whitespace-
//! separated token PAIRS `From To` (an edge From->To). Reads one FILE operand
//! (default `-` for stdin). Algorithm T (Knuth, TAOCP vol 1): repeatedly emit a
//! zero-indegree node, decrementing its successors' indegree; the *initial* frontier
//! of zero-indegree nodes is sorted lexicographically by name for determinism, but
//! every later insertion (successors becoming zero-indegree, or a node freed by
//! breaking a cycle edge) is appended to the queue unsorted, in the REVERSE order the
//! successors were first encountered (`reference/.../tsort.rs: run_tsort`) -- this
//! reverse is required to match GNU tsort's output order byte-for-byte.
//!
//! Cycle handling: when no node has indegree 0 but nodes remain, a cycle exists. It is
//! located via an iterative DFS over the *remaining* nodes (again sorted by name to
//! start the search), the loop path is printed to stderr (`tsort: FILE: input contains
//! a loop:` then one `tsort: NODE` line per node on the cycle), one edge of the cycle
//! (the *last* node in the discovered path -> the *first*) is deleted to unstick the
//! graph, and the algorithm continues -- it does not abort. Exit code is 1 if any loop
//! was detected (all remaining nodes still get emitted), 0 otherwise.
//!
//! A token that pairs with itself (`a a`) is a self-loop: verified against the
//! reference (`Graph::add_edge`: `if from != to { ... }`) to be silently dropped (the
//! node still exists, just with no self-edge) rather than treated as an error or a
//! guaranteed cycle.
//!
//! File handling deliberately does NOT go through `textio.streamLines` -- tsort only
//! ever reads a single operand, and its error wording differs from the shared filter
//! convention: an `open()` failure prints just `tsort: <strerror>` (no filename, per
//! the reference's plain `io::Error` bubble-up), while a directory operand prints
//! `tsort: FILE: read error: Is a directory` (checked empirically against the oracle
//! binary, `reference/uutils-coreutils/.../tsort.rs`).

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "tsort",
    .flags = &.{
        cli.flagOpt('w', null, "(no-op, accepted for POSIX compatibility)"),
    },
    // Handled manually below (rather than via `positionals.max`) because tsort's
    // "extra operand" wording/exit-code diverge from the generic cli.zig message.
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
    .help = .{
        .summary = "perform a topological sort",
        .synopsis = &.{"tsort [-w] [FILE]"},
        .description =
        \\Reads a graph as whitespace-separated token pairs "From To" (each pair is one
        \\directed edge) and writes a total order consistent with those edges, one
        \\node per line, using Knuth's Algorithm T: repeatedly emit a zero-indegree
        \\node and decrement its successors' indegree. The initial set of
        \\zero-indegree nodes is sorted lexicographically by name for a deterministic
        \\starting point, but nodes that become zero-indegree later (a node's own
        \\successors, or a node freed by breaking a cycle edge) are queued unsorted --
        \\so the overall output order is not simply "alphabetical, respecting edges".
        \\
        \\If the graph has a cycle, no node ever reaches zero indegree and none would
        \\ever be emitted; tsort instead detects one cycle via a depth-first search
        \\over the remaining nodes, reports it to standard error, breaks one of its
        \\edges to unstick the graph, and continues -- it does not abort, so a cyclic
        \\input still produces a full ordering of every node (with a nonzero exit
        \\status recording that a loop was found). A token paired with itself ("a a")
        \\is a silent no-op -- the node is created but no self-edge is recorded, so it
        \\is never reported as a cycle.
        ,
        .operands = "FILE   the file to read pairs from; \"-\" (the default) means standard input. At most one FILE is accepted.",
        .exit = &.{
            .{ .code = 0, .when = "no loop was detected" },
            .{ .code = 1, .when = "a cycle was detected and broken (the full ordering is still emitted), the input had an odd number of tokens, more than one FILE operand was given, or FILE could not be opened/read" },
        },
        .deviations = &.{
            "Open-error wording is asymmetric: a nonexistent FILE prints \"tsort: <strerror>\" with NO filename, while a FILE that turns out to be a directory prints \"tsort: <FILE>: read error: Is a directory\" (filename included).",
        },
        .examples = &.{
            .{ .cmd = "printf 'a b\\na c\\n' | tsort", .note = "prints a, c, b -- successors of a shared parent are queued in reverse encounter order, not alphabetically" },
            .{ .cmd = "printf 'a b\\nb c\\nc a\\n' | tsort; echo $?", .note = "reports the a-b-c loop on stderr, still prints a, b, c on stdout, and exits 1" },
        },
        .see_also = "sort (no dependency graph; pure ordering).",
    },
};

const NodeIdx = usize;

const VState = enum { opened, closed };

const Node = struct {
    name: []const u8,
    successors: std.ArrayListUnmanaged(NodeIdx) = .empty,
    pred_count: usize = 0,
    removed: bool = false,
};

const Graph = struct {
    gpa: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    index: std.StringHashMapUnmanaged(NodeIdx) = .empty,

    fn getOrCreate(self: *Graph, name: []const u8) !NodeIdx {
        if (self.index.get(name)) |idx| return idx;
        const dup = try self.gpa.dupe(u8, name);
        const idx = self.nodes.items.len;
        try self.nodes.append(self.gpa, .{ .name = dup });
        try self.index.put(self.gpa, dup, idx);
        return idx;
    }

    /// Mirrors `Graph::add_edge`: the `from` node always exists (already guaranteed by
    /// `getOrCreate`); a self-pair (`from == to`) is a silent no-op, otherwise records
    /// the successor edge and bumps `to`'s indegree.
    fn addEdge(self: *Graph, from: NodeIdx, to: NodeIdx) !void {
        if (from == to) return;
        try self.nodes.items[from].successors.append(self.gpa, to);
        self.nodes.items[to].pred_count += 1;
    }

    /// Removes the first occurrence of `v` from `u`'s successor list and decrements
    /// `v`'s indegree -- mirrors `Graph::remove_edge` (used to break one cycle edge).
    fn removeEdge(self: *Graph, u: NodeIdx, v: NodeIdx) void {
        const succ = &self.nodes.items[u].successors;
        for (succ.items, 0..) |s, i| {
            if (s == v) {
                _ = succ.orderedRemove(i);
                break;
            }
        }
        self.nodes.items[v].pred_count -= 1;
    }
};

fn lessByName(graph: *Graph, a: NodeIdx, b: NodeIdx) bool {
    return std.mem.lessThan(u8, graph.nodes.items[a].name, graph.nodes.items[b].name);
}

fn sortByName(graph: *Graph, idxs: []NodeIdx) void {
    std.mem.sort(NodeIdx, idxs, graph, lessByName);
}

/// FIFO of pending zero-indegree nodes. Implemented as an append-only list with an
/// advancing head cursor (arena-backed, so the "wasted" front slots are harmless).
const Queue = struct {
    items: std.ArrayListUnmanaged(NodeIdx) = .empty,
    head: usize = 0,

    fn pushBack(self: *Queue, gpa: std.mem.Allocator, v: NodeIdx) !void {
        try self.items.append(gpa, v);
    }

    fn popFront(self: *Queue) ?NodeIdx {
        if (self.head >= self.items.items.len) return null;
        const v = self.items.items[self.head];
        self.head += 1;
        return v;
    }
};

fn isWs(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C => true,
        else => false,
    };
}

/// Tokenizes `content` on runs of whitespace and pairs consecutive tokens into edges.
/// Returns `true` if the token count is odd (the trailing lone token has no partner).
fn buildGraph(graph: *Graph, content: []const u8) !bool {
    var i: usize = 0;
    var pending: ?NodeIdx = null;
    while (i < content.len) {
        while (i < content.len and isWs(content[i])) : (i += 1) {}
        if (i >= content.len) break;
        const start = i;
        while (i < content.len and !isWs(content[i])) : (i += 1) {}
        const idx = try graph.getOrCreate(content[start..i]);
        if (pending) |from| {
            try graph.addEdge(from, idx);
            pending = null;
        } else {
            pending = idx;
        }
    }
    return pending != null;
}

const Frame = struct { node: NodeIdx, cursor: usize };

/// Iterative DFS matching `Graph::dfs`'s stack-machine shape exactly: a frame is
/// always pushed for `node` before its (possibly already-`closed`) state is checked,
/// and `visited`/`stack` persist across the outer `detectCycle` loop's calls (a
/// literal port, not just an equivalent algorithm, to keep byte-parity on graphs with
/// leftover unexplored frames from earlier starts).
fn dfs(graph: *Graph, gpa: std.mem.Allocator, node: NodeIdx, visited: *std.AutoHashMapUnmanaged(NodeIdx, VState), stack: *std.ArrayListUnmanaged(Frame)) !bool {
    try stack.append(gpa, .{ .node = node, .cursor = 0 });
    const gop = try visited.getOrPut(gpa, node);
    if (!gop.found_existing) gop.value_ptr.* = .opened;
    if (gop.value_ptr.* == .closed) return false;

    while (stack.items.len > 0) {
        const top = stack.items[stack.items.len - 1];
        stack.items.len -= 1;
        const successors = graph.nodes.items[top.node].successors.items;
        if (top.cursor >= successors.len) {
            const cgop = try visited.getOrPut(gpa, top.node);
            cgop.value_ptr.* = .closed;
            continue;
        }
        const next_node = successors[top.cursor];
        try stack.append(gpa, .{ .node = top.node, .cursor = top.cursor + 1 });
        const ngop = try visited.getOrPut(gpa, next_node);
        if (!ngop.found_existing) {
            ngop.value_ptr.* = .opened;
            try stack.append(gpa, .{ .node = next_node, .cursor = 0 });
        } else if (ngop.value_ptr.* == .opened) {
            try stack.append(gpa, .{ .node = next_node, .cursor = 0 });
            return true;
        }
        // else: already closed, nothing more to do through this edge.
    }
    return false;
}

/// Finds the cycle among the still-`remaining` nodes and returns it as a slice of node
/// indices in path order (the node the back-edge points back to, through to the node
/// whose successor closes the loop) -- mirrors `Graph::detect_cycle`.
fn detectCycle(graph: *Graph, gpa: std.mem.Allocator) ![]NodeIdx {
    var nodes: std.ArrayListUnmanaged(NodeIdx) = .empty;
    for (graph.nodes.items, 0..) |n, i| {
        if (!n.removed) try nodes.append(gpa, i);
    }
    sortByName(graph, nodes.items);

    var visited: std.AutoHashMapUnmanaged(NodeIdx, VState) = .empty;
    var stack: std.ArrayListUnmanaged(Frame) = .empty;
    for (nodes.items) |node| {
        if (try dfs(graph, gpa, node, &visited, &stack)) {
            const marker = stack.pop().?;
            const loop_entry = marker.node;
            var result: std.ArrayListUnmanaged(NodeIdx) = .empty;
            var found = false;
            for (stack.items) |f| {
                if (!found) {
                    if (f.node != loop_entry) continue;
                    found = true;
                }
                try result.append(gpa, f.node);
            }
            return result.toOwnedSlice(gpa);
        }
    }
    unreachable; // only called when the caller has already established a cycle exists
}

fn breakOneCycle(graph: *Graph, gpa: std.mem.Allocator, queue: *Queue, ctx: *Ctx, file: []const u8) !void {
    const cycle = try detectCycle(graph, gpa);
    ctx.errPrint("tsort: {s}: input contains a loop:\n", .{file});
    for (cycle) |idx| ctx.errPrint("tsort: {s}\n", .{graph.nodes.items[idx].name});
    const u = cycle[cycle.len - 1];
    const v = cycle[0];
    graph.removeEdge(u, v);
    if (graph.nodes.items[v].pred_count == 0) try queue.pushBack(gpa, v);
}

/// Algorithm T. Returns whether at least one cycle was found and broken along the way.
fn runTsort(graph: *Graph, gpa: std.mem.Allocator, out: *textio.BufOut, ctx: *Ctx, file: []const u8) !bool {
    var queue: Queue = .{};
    var initial: std.ArrayListUnmanaged(NodeIdx) = .empty;
    for (graph.nodes.items, 0..) |n, i| {
        if (n.pred_count == 0) try initial.append(gpa, i);
    }
    sortByName(graph, initial.items);
    for (initial.items) |i| try queue.pushBack(gpa, i);

    var had_loop = false;
    var remaining: usize = graph.nodes.items.len;
    while (remaining > 0) {
        var v: NodeIdx = undefined;
        while (true) {
            if (queue.popFront()) |x| {
                v = x;
                break;
            }
            had_loop = true;
            try breakOneCycle(graph, gpa, &queue, ctx, file);
        }
        try out.line(graph.nodes.items[v].name);
        graph.nodes.items[v].removed = true;
        remaining -= 1;
        const succ = graph.nodes.items[v].successors.items;
        var k = succ.len;
        while (k > 0) {
            k -= 1;
            const s = succ[k];
            graph.nodes.items[s].pred_count -= 1;
            if (graph.nodes.items[s].pred_count == 0) try queue.pushBack(gpa, s);
        }
    }
    return had_loop;
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    const pos = m.positionalSlice();
    if (pos.len > 1) {
        ctx.errPrint("tsort: extra operand '{s}'\nTry 'tsort --help' for more information.\n", .{pos[1]});
        return 1;
    }
    const file: []const u8 = if (pos.len == 1) pos[0] else "-";

    const is_stdin = std.mem.eql(u8, file, "-");
    const fd = if (is_stdin) ctx.stdin else sys.open(file, .{ .read = true }) catch |e| {
        ctx.errPrint("tsort: {s}\n", .{sys.strerror(sys.toErrno(e))});
        return 1;
    };
    defer if (!is_stdin) sys.close(fd);

    const content = textio.readAll(ctx.gpa, fd) catch |e| {
        if (e == error.EISDIR) {
            ctx.errPrint("tsort: {s}: read error: Is a directory\n", .{file});
        } else {
            ctx.errPrint("tsort: {s}: {s}\n", .{ file, sys.strerror(sys.toErrno(e)) });
        }
        return 1;
    };

    var graph = Graph{ .gpa = ctx.gpa };
    const odd = buildGraph(&graph, content) catch {
        ctx.errPrint("tsort: out of memory\n", .{});
        return 1;
    };
    if (odd) {
        ctx.errPrint("tsort: {s}: input contains an odd number of tokens\n", .{file});
        return 1;
    }

    var out = textio.BufOut.init(ctx.stdout);
    const had_loop = runTsort(&graph, ctx.gpa, &out, ctx, file) catch {
        ctx.errPrint("tsort: out of memory\n", .{});
        return 1;
    };
    out.finish() catch {};
    return if (had_loop) 1 else 0;
}
