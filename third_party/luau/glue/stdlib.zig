//! stdlib.zig — Layer 2 (the batteries) + `require` (was loom/src/mc_stdlib.cpp; C++ → Zig). The
//! .luau battery sources are @embedFile'd INTO the binary, so the standard library ships inside the
//! interpreter — `require("time")` works on any VM with zero image staging (frozen modules).
//! `require` resolution is cache → embedded → VFS package.path. See third_party/luau/PLAN.md / §7.

const std = @import("std");
const lua = @import("lua.zig");
const c = lua.c;
const State = lua.State;

// The native modules (json/hash/encoding/deflate), registered into package.loaded below.
extern fn mc_open_json(L: ?*State) c_int;
extern fn mc_open_hash(L: ?*State) c_int;
extern fn mc_open_encoding(L: ?*State) c_int;
extern fn mc_open_deflate(L: ?*State) c_int;

// libc, for the VFS read + the rare prelude-error report (std.posix.write changed in 0.16).
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fread(ptr: [*]u8, size: usize, n: usize, f: ?*anyopaque) usize;
extern fn fclose(f: ?*anyopaque) c_int;
extern fn write(fd: c_int, buf: [*]const u8, len: usize) isize;

const Module = struct { name: [*:0]const u8, src: []const u8 };

// The embedded .luau libraries (everything in third_party/luau/lib except the prelude, which runs at
// startup). Lazy-compiled on first require, so an unused lib's source costs only bytes.
const MODULES = [_]Module{
    .{ .name = "calc", .src = @embedFile("lib/calc.luau") },
    .{ .name = "chart", .src = @embedFile("lib/chart.luau") },
    .{ .name = "color", .src = @embedFile("lib/color.luau") },
    .{ .name = "docx", .src = @embedFile("lib/docx.luau") },
    .{ .name = "http", .src = @embedFile("lib/http.luau") },
    .{ .name = "log", .src = @embedFile("lib/log.luau") },
    .{ .name = "media", .src = @embedFile("lib/media.luau") },
    .{ .name = "opc", .src = @embedFile("lib/opc.luau") },
    .{ .name = "path", .src = @embedFile("lib/path.luau") },
    .{ .name = "pptx", .src = @embedFile("lib/pptx.luau") },
    .{ .name = "test", .src = @embedFile("lib/test.luau") },
    .{ .name = "time", .src = @embedFile("lib/time.luau") },
    .{ .name = "units", .src = @embedFile("lib/units.luau") },
    .{ .name = "url", .src = @embedFile("lib/url.luau") },
    .{ .name = "xform", .src = @embedFile("lib/xform.luau") },
    .{ .name = "xlsx", .src = @embedFile("lib/xlsx.luau") },
    .{ .name = "xml", .src = @embedFile("lib/xml.luau") },
    .{ .name = "zip", .src = @embedFile("lib/zip.luau") },
};
const PRELUDE = @embedFile("lib/prelude.luau");

const alloc = std.heap.c_allocator;

// Compile + load `src` as chunk `name`: leaves the function on the stack on success (returns 0); a
// syntax error leaves the message and returns nonzero.
fn loadChunk(L: ?*State, name: [*:0]const u8, src: [*]const u8, len: usize) c_int {
    var bclen: usize = 0;
    const bc = lua.luau_compile(src, len, null, &bclen);
    const rc = c.luau_load(L, name, bc, bclen, 0);
    std.c.free(bc);
    return rc;
}

fn findEmbedded(name: []const u8) ?[]const u8 {
    for (MODULES) |m| {
        if (std.mem.eql(u8, std.mem.span(m.name), name)) return m.src;
    }
    return null;
}

fn readFile(path: [*:0]const u8, out: *std.ArrayList(u8)) bool {
    const f = fopen(path, "rb") orelse return false;
    defer _ = fclose(f);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        out.appendSlice(alloc, buf[0..n]) catch return false;
    }
    return true;
}

// Resolve a dotted module name against package.path; read the first hit into `out`, leaving a
// NUL-terminated "=<path>" chunkname in `chunk` (the path starts at chunk.items[1]).
fn resolveVfs(L: ?*State, name: []const u8, out: *std.ArrayList(u8), chunk: *std.ArrayList(u8)) bool {
    var frag: std.ArrayList(u8) = .empty;
    defer frag.deinit(alloc);
    for (name) |ch| frag.append(alloc, if (ch == '.') '/' else ch) catch return false;

    lua.getglobal(L, "package");
    _ = c.lua_getfield(L, -1, "path");
    const path = c.lua_tolstring(L, -1, null);
    const templates = if (path != null) std.mem.span(path) else "./?.luau;/lib/luau/?.luau";
    var tcopy: std.ArrayList(u8) = .empty;
    defer tcopy.deinit(alloc);
    tcopy.appendSlice(alloc, templates) catch return false;
    lua.pop(L, 2);

    var it = std.mem.splitScalar(u8, tcopy.items, ';');
    while (it.next()) |tmpl| {
        if (tmpl.len == 0) continue;
        out.clearRetainingCapacity();
        chunk.clearRetainingCapacity();
        chunk.append(alloc, '=') catch return false;
        if (std.mem.indexOfScalar(u8, tmpl, '?')) |q| {
            chunk.appendSlice(alloc, tmpl[0..q]) catch return false;
            chunk.appendSlice(alloc, frag.items) catch return false;
            chunk.appendSlice(alloc, tmpl[q + 1 ..]) catch return false;
        } else {
            chunk.appendSlice(alloc, tmpl) catch return false;
        }
        chunk.append(alloc, 0) catch return false; // NUL for the C path
        if (readFile(@ptrCast(chunk.items.ptr + 1), out)) return true;
    }
    return false;
}

// require(name) — cache → embedded → VFS; caches the result in package.loaded.
fn lRequire(L: ?*State) callconv(.c) c_int {
    const cname = c.luaL_checklstring(L, 1, null);
    const name = std.mem.span(cname);

    lua.getglobal(L, "package");
    _ = c.lua_getfield(L, -1, "loaded"); // [package, loaded]
    _ = c.lua_getfield(L, -1, cname); // [package, loaded, cached?]
    if (!lua.isnil(L, -1)) return 1; // already loaded
    lua.pop(L, 1); // [package, loaded]

    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(alloc);
    var chunk: std.ArrayList(u8) = .empty;
    defer chunk.deinit(alloc);

    if (findEmbedded(name)) |emb| {
        src.appendSlice(alloc, emb) catch {};
        chunk.appendSlice(alloc, "=[builtin ") catch {};
        chunk.appendSlice(alloc, name) catch {};
        chunk.appendSlice(alloc, "]\x00") catch {};
    } else if (!resolveVfs(L, name, &src, &chunk)) {
        _ = c.luaL_errorL(L, "module '%s' not found", cname);
        return 0;
    }

    if (loadChunk(L, @ptrCast(chunk.items.ptr), src.items.ptr, src.items.len) != 0)
        _ = c.lua_error(L); // the compile-error message is on the stack
    c.lua_call(L, 0, 1); // run the chunk → module result  [package, loaded, mod]
    if (lua.isnil(L, -1)) { // a module returning nothing → cache `true`
        lua.pop(L, 1);
        c.lua_pushboolean(L, 1);
    }
    c.lua_pushvalue(L, -1); // [package, loaded, mod, mod]
    c.lua_setfield(L, -3, cname); // loaded[name] = mod
    return 1;
}

fn regC(L: ?*State, name: [*:0]const u8, open: *const fn (?*State) callconv(.c) c_int) void {
    lua.getglobal(L, "package");
    _ = c.lua_getfield(L, -1, "loaded");
    _ = open(L); // pushes the module table
    c.lua_setfield(L, -2, name);
    lua.pop(L, 2);
}

pub export fn mc_open_stdlib(L: ?*State) void {
    // package = { loaded = {}, path = "…" }
    lua.newtable(L);
    lua.newtable(L);
    c.lua_setfield(L, -2, "loaded");
    _ = c.lua_pushstring(L, "./?.luau;/lib/luau/?.luau;/lib/luau/?/init.luau");
    c.lua_setfield(L, -2, "path");
    lua.setglobal(L, "package");

    lua.pushcfunction(L, &lRequire, "require");
    lua.setglobal(L, "require");

    regC(L, "json", &mc_open_json);
    regC(L, "hash", &mc_open_hash);
    regC(L, "encoding", &mc_open_encoding);
    regC(L, "deflate", &mc_open_deflate);

    // Make `sys` require-able too (a global now that sys.zig is real).
    lua.getglobal(L, "package");
    _ = c.lua_getfield(L, -1, "loaded");
    lua.getglobal(L, "sys");
    c.lua_setfield(L, -2, "sys");
    lua.pop(L, 2);

    // Run the builtin-extension prelude (string :trim/etc., table helpers, os.* over sys). Under
    // pcall so a build bug is a loud message, not silent corruption.
    if (loadChunk(L, "=[builtin prelude]", PRELUDE.ptr, PRELUDE.len) != 0 or c.lua_pcall(L, 0, 0, 0) != 0) {
        const msg = c.lua_tolstring(L, -1, null);
        const m = if (msg != null) std.mem.span(msg) else "(unknown)";
        _ = write(2, "luau: stdlib prelude failed: ", 28);
        _ = write(2, m.ptr, m.len);
        _ = write(2, "\n", 1);
        lua.pop(L, 1);
    }

    // Always-on globals: json (C) + path (embedded).
    lua.getglobal(L, "package");
    _ = c.lua_getfield(L, -1, "loaded");
    _ = c.lua_getfield(L, -1, "json");
    lua.setglobal(L, "json");
    lua.pop(L, 2);

    lua.getglobal(L, "require");
    _ = c.lua_pushstring(L, "path");
    if (c.lua_pcall(L, 1, 1, 0) == 0) lua.setglobal(L, "path") else lua.pop(L, 1);
}
