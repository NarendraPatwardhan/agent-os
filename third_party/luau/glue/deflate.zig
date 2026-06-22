//! deflate.zig — the `deflate` battery (was loom/src/deflate_bindings.cpp; C++ → Zig). RAW DEFLATE
//! (RFC 1951, no zlib/gzip wrapper) over Zig's std.compress.flate — the codec the `zip`/`opc` libs
//! use for OOXML (xlsx/docx/pptx) method-8 entries. API: deflate.compress(s [,level]) -> bytes;
//! deflate.decompress(s [,hint]) -> bytes?, err. See third_party/luau/PLAN.md.

const std = @import("std");
const lua = @import("lua.zig");
const c = lua.c;
const State = lua.State;
const flate = std.compress.flate;
const alloc = std.heap.c_allocator;

fn optsForLevel(level: i64) flate.Compress.Options {
    return switch (level) {
        0, 1 => flate.Compress.Options.level_1,
        2 => flate.Compress.Options.level_2,
        3 => flate.Compress.Options.level_3,
        4 => flate.Compress.Options.level_4,
        5 => flate.Compress.Options.level_5,
        6 => flate.Compress.Options.level_6,
        7 => flate.Compress.Options.level_7,
        8 => flate.Compress.Options.level_8,
        else => flate.Compress.Options.level_9,
    };
}

fn lCompress(L: ?*State) callconv(.c) c_int {
    var n: usize = 0;
    const s = c.luaL_checklstring(L, 1, &n);
    const level = c.luaL_optinteger(L, 2, 6);

    // RAW deflate can expand slightly on incompressible input; size the sink generously.
    const cap = n + n / 4 + 256;
    const out = alloc.alloc(u8, cap) catch {
        _ = c.luaL_errorL(L, "deflate.compress: out of memory");
        return 0;
    };
    defer alloc.free(out);
    const window = alloc.alloc(u8, flate.max_window_len) catch {
        _ = c.luaL_errorL(L, "deflate.compress: out of memory");
        return 0;
    };
    defer alloc.free(window);

    var w: std.Io.Writer = .fixed(out);
    var comp = flate.Compress.init(&w, window, .raw, optsForLevel(level)) catch {
        _ = c.luaL_errorL(L, "deflate.compress: init failed");
        return 0;
    };
    comp.writer.writeAll(s[0..n]) catch {
        _ = c.luaL_errorL(L, "deflate.compress: write failed");
        return 0;
    };
    comp.finish() catch {
        _ = c.luaL_errorL(L, "deflate.compress: finish failed");
        return 0;
    };
    const compressed = w.buffered();
    _ = c.lua_pushlstring(L, compressed.ptr, compressed.len);
    return 1;
}

fn lDecompress(L: ?*State) callconv(.c) c_int {
    var n: usize = 0;
    const s = c.luaL_checklstring(L, 1, &n);

    var r: std.Io.Reader = .fixed(s[0..n]);
    const window = alloc.alloc(u8, flate.max_window_len) catch {
        c.lua_pushnil(L);
        _ = c.lua_pushstring(L, "deflate: out of memory");
        return 2;
    };
    defer alloc.free(window);
    var dec = flate.Decompress.init(&r, .raw, window);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var tmp: [8192]u8 = undefined;
    while (true) {
        const got = dec.reader.readSliceShort(&tmp) catch {
            c.lua_pushnil(L);
            _ = c.lua_pushstring(L, "deflate: corrupt stream");
            return 2;
        };
        if (got == 0) break;
        out.appendSlice(alloc, tmp[0..got]) catch {
            c.lua_pushnil(L);
            _ = c.lua_pushstring(L, "deflate: out of memory");
            return 2;
        };
    }
    _ = c.lua_pushlstring(L, out.items.ptr, out.items.len);
    c.lua_pushnil(L);
    return 2;
}

pub export fn mc_open_deflate(L: ?*State) c_int {
    lua.newtable(L);
    lua.pushcfunction(L, &lCompress, "compress");
    c.lua_setfield(L, -2, "compress");
    lua.pushcfunction(L, &lDecompress, "decompress");
    c.lua_setfield(L, -2, "decompress");
    return 1;
}
