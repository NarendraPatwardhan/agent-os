//! encoding.zig — the `encoding` battery (was loom/src/encoding_bindings.cpp; C++ → Zig). base64
//! (standard + url-safe, optional padding) over std.base64, and hex. API:
//! encoding.base64.encode(s [,{url=,pad=}]) -> string; encoding.base64.decode(s) -> string?, err
//! (accepts both alphabets, skips whitespace); encoding.hex.{encode,decode}. third_party/luau/PLAN.md.

const std = @import("std");
const lua = @import("lua.zig");
const c = lua.c;
const State = lua.State;
const alloc = std.heap.c_allocator;

fn lB64Encode(L: ?*State) callconv(.c) c_int {
    var n: usize = 0;
    const s = c.luaL_checklstring(L, 1, &n);
    var url = false;
    var pad = true;
    if (c.lua_type(L, 2) == c.LUA_TTABLE) {
        _ = c.lua_getfield(L, 2, "url");
        url = c.lua_toboolean(L, -1) != 0;
        lua.pop(L, 1);
        _ = c.lua_getfield(L, 2, "pad");
        if (c.lua_type(L, -1) != c.LUA_TNIL) pad = c.lua_toboolean(L, -1) != 0;
        lua.pop(L, 1);
    }
    const enc = if (url)
        (if (pad) std.base64.url_safe.Encoder else std.base64.url_safe_no_pad.Encoder)
    else
        (if (pad) std.base64.standard.Encoder else std.base64.standard_no_pad.Encoder);
    const buf = alloc.alloc(u8, enc.calcSize(n)) catch {
        _ = c.luaL_errorL(L, "base64.encode: out of memory");
        return 0;
    };
    defer alloc.free(buf);
    const out = enc.encode(buf, s[0..n]);
    _ = c.lua_pushlstring(L, out.ptr, out.len);
    return 1;
}

fn b64Fail(L: ?*State) c_int {
    c.lua_pushnil(L);
    _ = c.lua_pushstring(L, "base64: invalid input");
    return 2;
}

fn lB64Decode(L: ?*State) callconv(.c) c_int {
    var n: usize = 0;
    const s = c.luaL_checklstring(L, 1, &n);
    // Normalise to the standard alphabet, drop whitespace, pad to a multiple of 4 — so one strict
    // decoder accepts both alphabets and unpadded input (the C++ behaviour).
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(alloc);
    for (s[0..n]) |ch| {
        const m: u8 = switch (ch) {
            '-' => '+',
            '_' => '/',
            ' ', '\t', '\n', '\r' => continue,
            '=' => continue, // re-pad below
            else => ch,
        };
        clean.append(alloc, m) catch return b64Fail(L);
    }
    while (clean.items.len % 4 != 0) clean.append(alloc, '=') catch return b64Fail(L);
    const dec = std.base64.standard.Decoder;
    const out_len = dec.calcSizeForSlice(clean.items) catch return b64Fail(L);
    const buf = alloc.alloc(u8, out_len) catch return b64Fail(L);
    defer alloc.free(buf);
    dec.decode(buf, clean.items) catch return b64Fail(L);
    _ = c.lua_pushlstring(L, buf.ptr, buf.len);
    c.lua_pushnil(L);
    return 2;
}

const hexchars = "0123456789abcdef";

fn lHexEncode(L: ?*State) callconv(.c) c_int {
    var n: usize = 0;
    const s = c.luaL_checklstring(L, 1, &n);
    const buf = alloc.alloc(u8, n * 2) catch {
        _ = c.luaL_errorL(L, "hex.encode: out of memory");
        return 0;
    };
    defer alloc.free(buf);
    for (s[0..n], 0..) |b, i| {
        buf[i * 2] = hexchars[b >> 4];
        buf[i * 2 + 1] = hexchars[b & 0xf];
    }
    _ = c.lua_pushlstring(L, buf.ptr, buf.len);
    return 1;
}

fn hexVal(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

fn lHexDecode(L: ?*State) callconv(.c) c_int {
    var n: usize = 0;
    const s = c.luaL_checklstring(L, 1, &n);
    if (n % 2 != 0) {
        c.lua_pushnil(L);
        _ = c.lua_pushstring(L, "hex: odd length");
        return 2;
    }
    const buf = alloc.alloc(u8, n / 2) catch {
        c.lua_pushnil(L);
        _ = c.lua_pushstring(L, "hex: out of memory");
        return 2;
    };
    defer alloc.free(buf);
    var i: usize = 0;
    while (i < n) : (i += 2) {
        const hi = hexVal(s[i]) orelse return hexFail(L);
        const lo = hexVal(s[i + 1]) orelse return hexFail(L);
        buf[i / 2] = (hi << 4) | lo;
    }
    _ = c.lua_pushlstring(L, buf.ptr, buf.len);
    c.lua_pushnil(L);
    return 2;
}

fn hexFail(L: ?*State) c_int {
    c.lua_pushnil(L);
    _ = c.lua_pushstring(L, "hex: invalid digit");
    return 2;
}

fn subTable(L: ?*State, name: [*:0]const u8, enc: lua.CFn, dec: lua.CFn) void {
    lua.newtable(L);
    lua.pushcfunction(L, enc, "encode");
    c.lua_setfield(L, -2, "encode");
    lua.pushcfunction(L, dec, "decode");
    c.lua_setfield(L, -2, "decode");
    c.lua_setfield(L, -2, name);
}

pub export fn mc_open_encoding(L: ?*State) c_int {
    lua.newtable(L);
    subTable(L, "base64", &lB64Encode, &lB64Decode);
    subTable(L, "hex", &lHexEncode, &lHexDecode);
    return 1;
}
