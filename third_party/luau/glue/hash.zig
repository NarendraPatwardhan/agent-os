//! hash.zig — the `hash` battery (was loom/src/hash_bindings.cpp; C++ → Zig). Content-addressing
//! checksums over Zig's std.crypto / std.hash (no hand-rolled algorithms). API:
//! hash.sha256/sha1/md5(s [, {raw=true}]) -> hex (or raw bytes); hash.crc32(s) -> number.
//! See third_party/luau/PLAN.md.

const std = @import("std");
const lua = @import("lua.zig");
const c = lua.c;
const State = lua.State;

// Push a digest as lowercase hex, or as raw bytes when arg 2 is {raw=true}.
fn pushDigest(L: ?*State, digest: []const u8) void {
    var raw = false;
    if (c.lua_type(L, 2) == c.LUA_TTABLE) {
        _ = c.lua_getfield(L, 2, "raw");
        raw = c.lua_toboolean(L, -1) != 0;
        lua.pop(L, 1);
    }
    if (raw) {
        _ = c.lua_pushlstring(L, digest.ptr, digest.len);
        return;
    }
    const hexchars = "0123456789abcdef";
    var buf: [128]u8 = undefined; // up to a 64-byte digest → 128 hex chars
    for (digest, 0..) |b, i| {
        buf[i * 2] = hexchars[b >> 4];
        buf[i * 2 + 1] = hexchars[b & 0xf];
    }
    _ = c.lua_pushlstring(L, &buf, digest.len * 2);
}

fn input(L: ?*State) []const u8 {
    var n: usize = 0;
    const s = c.luaL_checklstring(L, 1, &n);
    return s[0..n];
}

fn lSha256(L: ?*State) callconv(.c) c_int {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input(L), &d, .{});
    pushDigest(L, &d);
    return 1;
}

fn lSha1(L: ?*State) callconv(.c) c_int {
    var d: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(input(L), &d, .{});
    pushDigest(L, &d);
    return 1;
}

fn lMd5(L: ?*State) callconv(.c) c_int {
    var d: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(input(L), &d, .{});
    pushDigest(L, &d);
    return 1;
}

fn lCrc32(L: ?*State) callconv(.c) c_int {
    c.lua_pushnumber(L, @floatFromInt(std.hash.Crc32.hash(input(L))));
    return 1;
}

pub export fn mc_open_hash(L: ?*State) c_int {
    lua.newtable(L);
    lua.pushcfunction(L, &lSha256, "sha256");
    c.lua_setfield(L, -2, "sha256");
    lua.pushcfunction(L, &lSha1, "sha1");
    c.lua_setfield(L, -2, "sha1");
    lua.pushcfunction(L, &lMd5, "md5");
    c.lua_setfield(L, -2, "md5");
    lua.pushcfunction(L, &lCrc32, "crc32");
    c.lua_setfield(L, -2, "crc32");
    return 1;
}
