//! Port of the facade `fsutil.rs` (DESIGN.md §6, 341 LOC in the original): userspace
//! POSIX path conventions layered over `sys/root.zig`. No `std.fs`/`std.Io`/`std.fmt`
//! in the non-test code path (DESIGN.md §11 rule 2/3) -- this file ships in every
//! readwrite-tier box, so it pays the size budget directly.
//!
//! `canonicalize` is the one genuinely tricky algorithm here: a userspace realpath
//! walk over a work-list of path components, splicing a symlink's target components in
//! front of the remaining queue when one is hit (absolute targets clear the resolved
//! prefix and restart from `/`), capped at 40 total hops to break loops. Existence
//! policy governs what happens when a component is missing:
//!   - `.all`    every component (including the final one) must exist -> null if not.
//!   - `.parent` every component except the last must exist; a missing final component
//!               is kept literally (no further symlink resolution is possible on it).
//!   - `.none`   nothing needs to exist; once a component is missing, all remaining
//!               components (including the current one) are appended lexically
//!               (still honoring `.`/`..`) with no further `lstat` calls.

const std = @import("std");
const sys = @import("../sys/root.zig");

const Allocator = std.mem.Allocator;

// ------------------------------------------------------------------ tiny helpers

/// `a ++ b`, no separator (used when `a`/`b` already carries the boundary byte).
fn concat(gpa: Allocator, a: []const u8, b: []const u8) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

/// Renders an absolute path from resolved components (each without slashes), e.g.
/// `["a","b"]` -> `"/a/b"`; empty -> `"/"`.
fn renderAbs(gpa: Allocator, comps: []const []const u8) Allocator.Error![]u8 {
    if (comps.len == 0) return gpa.dupe(u8, "/");
    var total: usize = 0;
    for (comps) |c| total += 1 + c.len;
    const out = try gpa.alloc(u8, total);
    var off: usize = 0;
    for (comps) |c| {
        out[off] = '/';
        off += 1;
        @memcpy(out[off..][0..c.len], c);
        off += c.len;
    }
    return out;
}

// ------------------------------------------------------------------ isDir / exists

pub fn isDir(path: []const u8) bool {
    const st = sys.stat(path) catch return false;
    return st.is_dir;
}

/// Existence of the path entry itself (does not follow a dangling symlink's target --
/// the symlink entry existing is enough).
pub fn exists(path: []const u8) bool {
    _ = sys.lstat(path) catch return false;
    return true;
}

// ------------------------------------------------------------------ basename / join

/// Strip trailing `/` (keep a lone `/`), take the component after the last `/`.
pub fn basename(path: []const u8) []const u8 {
    if (path.len == 0) return "";
    var s = path;
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (std.mem.eql(u8, s, "/")) return "/";
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |idx| return s[idx + 1 ..];
    return s;
}

/// Join two path components with a single `/`. If `b` is itself absolute, it replaces
/// `a` entirely (matches the usual `Path::join` convention). Empty `a` yields `b` as-is.
pub fn join(gpa: Allocator, a: []const u8, b: []const u8) Allocator.Error![]u8 {
    if (b.len > 0 and b[0] == '/') return gpa.dupe(u8, b);
    if (a.len == 0) return gpa.dupe(u8, b);
    if (a[a.len - 1] == '/') return concat(gpa, a, b);
    const out = try gpa.alloc(u8, a.len + 1 + b.len);
    @memcpy(out[0..a.len], a);
    out[a.len] = '/';
    @memcpy(out[a.len + 1 ..], b);
    return out;
}

/// `cp`/`mv`'s into-directory convention: if `dest` is a directory, the effective
/// destination is `dest/basename(src)`; otherwise `dest` itself.
pub fn destIntoDir(gpa: Allocator, dest: []const u8, src: []const u8) Allocator.Error![]const u8 {
    if (isDir(dest)) return join(gpa, dest, basename(src));
    return dest;
}

// ------------------------------------------------------------------ lexicalAbs

fn pushComponentsForward(gpa: Allocator, comps: *std.ArrayListUnmanaged([]const u8), path: []const u8) !void {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |c| {
        if (c.len == 0) continue;
        try comps.append(gpa, try gpa.dupe(u8, c));
    }
}

fn collapseLexical(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    var stack: std.ArrayListUnmanaged([]const u8) = .empty;
    defer stack.deinit(gpa);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            if (stack.items.len > 0) _ = stack.pop();
            continue;
        }
        try stack.append(gpa, comp);
    }
    return renderAbs(gpa, stack.items);
}

/// Reads the current cwd into a stack buffer and strips a trailing NUL if the backend
/// returns one.
fn readCwd(buf: []u8) ?[]const u8 {
    const n = sys.getcwd(buf) catch return null;
    var cwd = buf[0..n];
    if (cwd.len > 0 and cwd[cwd.len - 1] == 0) cwd = cwd[0 .. cwd.len - 1];
    return cwd;
}

/// Absolute-izes `path` against `sys.getcwd` (if relative) and collapses `.`/`..`
/// lexically -- no symlink following, never fails except on cwd-read failure or OOM.
pub fn lexicalAbs(gpa: Allocator, path: []const u8) !?[]u8 {
    if (path.len > 0 and path[0] == '/') return try collapseLexical(gpa, path);
    var cwd_buf: [4096]u8 = undefined;
    const cwd = readCwd(&cwd_buf) orelse return null;
    var sep_and_path = try gpa.alloc(u8, 1 + path.len);
    defer gpa.free(sep_and_path);
    sep_and_path[0] = '/';
    @memcpy(sep_and_path[1..], path);
    const full = try concat(gpa, cwd, sep_and_path);
    defer gpa.free(full);
    return try collapseLexical(gpa, full);
}

// ------------------------------------------------------------------ canonicalize

pub const Existence = enum { all, parent, none };

fn pushComponentsReversed(gpa: Allocator, queue: *std.ArrayListUnmanaged([]const u8), path: []const u8) !void {
    var tmp: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |c| {
        if (c.len == 0) continue;
        try tmp.append(gpa, try gpa.dupe(u8, c));
    }
    var i = tmp.items.len;
    while (i > 0) {
        i -= 1;
        try queue.append(gpa, tmp.items[i]);
    }
}

/// Userspace symlink resolution (DESIGN.md §6): work-list of path components, splicing
/// a symlink's target components in front of the remaining queue when one is hit (an
/// absolute target clears the resolved-so-far output stack). 40-hop cap breaks loops.
/// Returns `null` on cap-exceeded, a required-but-missing component, or OOM.
pub fn canonicalize(gpa: Allocator, path: []const u8, existence: Existence) ?[]u8 {
    if (path.len == 0) return null;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    var out: std.ArrayListUnmanaged([]const u8) = .empty;

    if (path[0] != '/') {
        var cwd_buf: [4096]u8 = undefined;
        const cwd = readCwd(&cwd_buf) orelse return null;
        pushComponentsForward(a, &out, cwd) catch return null;
    }
    pushComponentsReversed(a, &queue, path) catch return null;

    var hops: usize = 0;
    var giving_up = false;

    while (queue.items.len > 0) {
        const comp = queue.pop().?;
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            if (out.items.len > 0) _ = out.pop();
            continue;
        }
        if (giving_up) {
            out.append(a, comp) catch return null;
            continue;
        }

        out.append(a, comp) catch return null; // speculative -- popped back off below if needed
        const candidate = renderAbs(a, out.items) catch return null;
        const st = sys.lstat(candidate) catch {
            _ = out.pop();
            const is_last = queue.items.len == 0;
            if (existence == .all) return null;
            if (!is_last and existence == .parent) return null;
            out.append(a, comp) catch return null;
            giving_up = true;
            continue;
        };
        if (st.is_symlink) {
            _ = out.pop();
            hops += 1;
            if (hops > 40) return null;
            var linkbuf: [4096]u8 = undefined;
            const n = sys.readlink(candidate, &linkbuf) catch return null;
            const target = linkbuf[0..n];
            if (target.len > 0 and target[0] == '/') out.clearRetainingCapacity();
            pushComponentsReversed(a, &queue, target) catch return null;
            continue;
        }
        // regular entry: already appended to `out` above.
    }

    const result = renderAbs(a, out.items) catch return null;
    return gpa.dupe(u8, result) catch null;
}

// ------------------------------------------------------------------ sameOrDescendant

/// True iff `candidate` is `ancestor` itself or lexically nested under it (both sides
/// absolute-ized lexically, no symlink following). `/` is trivially an ancestor of
/// everything.
pub fn sameOrDescendant(gpa: Allocator, ancestor: []const u8, candidate: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const anc = (lexicalAbs(a, ancestor) catch return false) orelse return false;
    const cand = (lexicalAbs(a, candidate) catch return false) orelse return false;
    if (std.mem.eql(u8, anc, "/")) return true;
    if (std.mem.eql(u8, anc, cand)) return true;
    if (std.mem.startsWith(u8, cand, anc) and cand.len > anc.len and cand[anc.len] == '/') return true;
    return false;
}

// ------------------------------------------------------------------ list (readdir)

/// Directory entry names in raw readdir order (callers sort when they need to).
/// Grows a scratch buffer starting at 1024 bytes, doubling whenever `sys.readdir`
/// reports it may have truncated (return value == buffer length).
pub fn list(gpa: Allocator, path: []const u8) sys.Error![][]const u8 {
    var cap: usize = 1024;
    while (true) {
        const buf = gpa.alloc(u8, cap) catch return error.ENOMEM;
        defer gpa.free(buf);
        const n = try sys.readdir(path, buf);
        if (n == buf.len) {
            cap *= 2;
            continue;
        }
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, buf[0..n], 0);
        while (it.next()) |piece| {
            if (piece.len == 0) continue;
            names.append(gpa, gpa.dupe(u8, piece) catch return error.ENOMEM) catch return error.ENOMEM;
        }
        return names.toOwnedSlice(gpa) catch error.ENOMEM;
    }
}

pub fn freeList(gpa: Allocator, names: [][]const u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

// ------------------------------------------------------------------ copy / remove / mkdir_p

/// Whole-file copy, 4 KiB loop, truncate-or-create destination.
pub fn copyFile(src: []const u8, dst: []const u8) sys.Error!void {
    const in = try sys.open(src, .{ .read = true });
    defer sys.close(in);
    const out = try sys.open(dst, .{ .write = true, .create = true, .trunc = true });
    defer sys.close(out);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try sys.read(in, &buf);
        if (n == 0) break;
        try sys.writeAll(out, buf[0..n]);
    }
}

/// Recursive copy. `follow = false` recreates symlinks as symlinks (reads the target,
/// unlinks any existing `dst`, then `symlink`s); `follow = true` (== `copyRecursive`)
/// copies the symlink's target contents instead.
pub fn copyTree(gpa: Allocator, src: []const u8, dst: []const u8, follow: bool) sys.Error!void {
    const st = if (follow) try sys.stat(src) else try sys.lstat(src);
    if (st.is_symlink) {
        var buf: [4096]u8 = undefined;
        const n = try sys.readlink(src, &buf);
        const target = buf[0..n];
        sys.unlink(dst) catch {};
        try sys.symlink(target, dst);
        return;
    }
    if (st.is_dir) {
        sys.mkdir(dst) catch |e| if (e != error.EEXIST) return e;
        const names = try list(gpa, src);
        defer freeList(gpa, names);
        for (names) |name| {
            const s = join(gpa, src, name) catch return error.ENOMEM;
            defer gpa.free(s);
            const d = join(gpa, dst, name) catch return error.ENOMEM;
            defer gpa.free(d);
            try copyTree(gpa, s, d, follow);
        }
        return;
    }
    try copyFile(src, dst);
}

pub fn copyRecursive(gpa: Allocator, src: []const u8, dst: []const u8) sys.Error!void {
    return copyTree(gpa, src, dst, true);
}

/// Post-order recursive remove. `sys.unlink` removes empty directories too (kernel
/// convention, DESIGN.md §4.1), so the post-order walk just needs to empty each
/// directory before unlinking it.
pub fn removeRecursive(gpa: Allocator, path: []const u8) sys.Error!void {
    const st = try sys.lstat(path);
    if (st.is_dir and !st.is_symlink) {
        const names = try list(gpa, path);
        defer freeList(gpa, names);
        for (names) |name| {
            const child = join(gpa, path, name) catch return error.ENOMEM;
            defer gpa.free(child);
            try removeRecursive(gpa, child);
        }
    }
    try sys.unlink(path);
}

/// `mkdir -p`: creates every leading directory component, ignoring `EEXIST` at each
/// step; preserves whether `path` was absolute or relative.
pub fn mkdirP(path: []const u8) sys.Error!void {
    if (path.len == 0) return;
    var i: usize = if (path[0] == '/') 1 else 0;
    while (true) {
        if (i >= path.len) {
            sys.mkdir(path) catch |e| if (e != error.EEXIST) return e;
            return;
        }
        if (path[i] == '/') {
            sys.mkdir(path[0..i]) catch |e| if (e != error.EEXIST) return e;
        }
        i += 1;
    }
}

// ------------------------------------------------------------------ preserveMeta

/// Best-effort metadata copy: mode is always copied; atime/mtime only when
/// `with_times`. Symlinks are skipped entirely (their own metadata is meaningless to
/// copy onto a target). Both `chmod`/`utimes` failures are swallowed -- this mirrors
/// `cp -p`/`mv`'s EXDEV fallback, neither of which treats a metadata-copy failure as
/// fatal.
pub fn preserveMeta(gpa: Allocator, src: []const u8, dst: []const u8, with_times: bool) void {
    const st = sys.lstat(src) catch return;
    if (st.is_symlink) return;
    sys.chmod(dst, st.mode) catch {};
    if (with_times) sys.utimes(dst, .{ .atime_ms = st.atime_ms, .mtime_ms = st.mtime_ms }) catch {};
    if (st.is_dir) {
        const names = list(gpa, src) catch return;
        defer freeList(gpa, names);
        for (names) |name| {
            const s = join(gpa, src, name) catch continue;
            defer gpa.free(s);
            const d = join(gpa, dst, name) catch continue;
            defer gpa.free(d);
            preserveMeta(gpa, s, d, with_times);
        }
    }
}
