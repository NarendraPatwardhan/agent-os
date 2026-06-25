//! json.zig — the `json` battery (was loom/src/json_bindings.cpp; the C++ → Zig rewrite). C-native
//! JSON encode/decode over the Lua C API: object ↔ string-keyed table, array ↔ 1..n table, JSON
//! null ↔ the json.null sentinel. Expected failure (malformed input) → nil, message; misuse
//! (encoding a function) raises. See third_party/luau/SYSTEM.md / ctx LUAU.md.

const std = @import("std");
const lua = @import("lua.zig");
const c = lua.c;
const State = lua.State;

const alloc = std.heap.c_allocator;
extern fn snprintf(buf: [*]u8, size: usize, fmt: [*:0]const u8, ...) c_int;

// The json.null sentinel: a unique table kept in the registry under a fixed key so encode + decode
// both reach it.
const kNullKey = "mc.json.null";

fn isNull(L: ?*State, idx: c_int) bool {
    const abs = if (idx < 0) c.lua_gettop(L) + idx + 1 else idx;
    _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, kNullKey);
    const eq = c.lua_rawequal(L, abs, -1) != 0;
    lua.pop(L, 1);
    return eq;
}

// ── encode ──────────────────────────────────────────────────────────────────

const EncErr = error{ TooDeep, NonFinite, Unserializable, OutOfMemory };

fn encString(out: *std.ArrayList(u8), s: [*]const u8, n: usize) !void {
    try out.append(alloc, '"');
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ch = s[i];
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            8 => try out.appendSlice(alloc, "\\b"),
            12 => try out.appendSlice(alloc, "\\f"),
            else => {
                if (ch < 0x20) {
                    var buf: [8]u8 = undefined;
                    _ = snprintf(&buf, buf.len, "\\u%04x", @as(c_uint, ch));
                    try out.appendSlice(alloc, std.mem.sliceTo(&buf, 0));
                } else {
                    try out.append(alloc, ch); // UTF-8 bytes pass through
                }
            },
        }
    }
    try out.append(alloc, '"');
}

fn encTable(L: ?*State, out: *std.ArrayList(u8), tidx: c_int, depth: u32) EncErr!void {
    if (depth > 200) return error.TooDeep;
    // Array iff entry-count == array-length AND length > 0 (empty table → {}).
    const n: c_int = @intCast(c.lua_objlen(L, tidx));
    var count: c_int = 0;
    c.lua_pushnil(L);
    while (c.lua_next(L, tidx) != 0) {
        count += 1;
        lua.pop(L, 1);
    }
    if (n > 0 and count == n) {
        try out.append(alloc, '[');
        var i: c_int = 1;
        while (i <= n) : (i += 1) {
            if (i > 1) try out.append(alloc, ',');
            _ = c.lua_rawgeti(L, tidx, i);
            try encValue(L, out, c.lua_gettop(L), depth);
            lua.pop(L, 1);
        }
        try out.append(alloc, ']');
        return;
    }
    try out.append(alloc, '{');
    var first = true;
    c.lua_pushnil(L);
    while (c.lua_next(L, tidx) != 0) {
        const kt = c.lua_type(L, -2);
        if (kt == c.LUA_TSTRING or kt == c.LUA_TNUMBER) {
            if (!first) try out.append(alloc, ',');
            first = false;
            if (kt == c.LUA_TSTRING) {
                var kn: usize = 0;
                const ks = c.lua_tolstring(L, -2, &kn);
                try encString(out, ks, kn);
            } else {
                c.lua_pushvalue(L, -2); // copy: tolstring on the live key corrupts lua_next
                var kn: usize = 0;
                const ks = c.lua_tolstring(L, -1, &kn);
                try encString(out, ks, kn);
                lua.pop(L, 1);
            }
            try out.append(alloc, ':');
            encValue(L, out, c.lua_gettop(L), depth) catch |e| {
                lua.pop(L, 2);
                return e;
            };
        }
        lua.pop(L, 1); // pop value, keep key for the next lua_next
    }
    try out.append(alloc, '}');
}

fn encValue(L: ?*State, out: *std.ArrayList(u8), idx: c_int, depth: u32) EncErr!void {
    if (isNull(L, idx)) return out.appendSlice(alloc, "null");
    switch (c.lua_type(L, idx)) {
        c.LUA_TNIL => try out.appendSlice(alloc, "null"),
        c.LUA_TBOOLEAN => try out.appendSlice(alloc, if (c.lua_toboolean(L, idx) != 0) "true" else "false"),
        c.LUA_TNUMBER => {
            const d = c.lua_tonumberx(L, idx, null);
            if (!std.math.isFinite(d)) return error.NonFinite;
            var buf: [40]u8 = undefined;
            if (d == @floor(d) and @abs(d) < 1e15)
                _ = snprintf(&buf, buf.len, "%.0f", d)
            else
                _ = snprintf(&buf, buf.len, "%.14g", d);
            try out.appendSlice(alloc, std.mem.sliceTo(&buf, 0));
        },
        c.LUA_TSTRING => {
            var n: usize = 0;
            const s = c.lua_tolstring(L, idx, &n);
            try encString(out, s, n);
        },
        c.LUA_TTABLE => try encTable(L, out, idx, depth + 1),
        else => return error.Unserializable,
    }
}

fn lJsonEncode(L: ?*State) callconv(.c) c_int {
    c.luaL_checkany(L, 1);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    encValue(L, &out, 1, 0) catch |e| {
        const msg = switch (e) {
            error.TooDeep => "json.encode: nesting too deep",
            error.NonFinite => "json.encode: non-finite number",
            error.OutOfMemory => "json.encode: out of memory",
            else => "json.encode: cannot serialize this value",
        };
        _ = c.luaL_errorL(L, msg);
        return 0;
    };
    _ = c.lua_pushlstring(L, out.items.ptr, out.items.len);
    return 1;
}

// ── decode ──────────────────────────────────────────────────────────────────

const Dec = struct {
    p: [*]const u8,
    end: [*]const u8,
    L: ?*State,
    err: ?[*:0]const u8 = null,
    depth: u32 = 0,
};

fn skipWs(d: *Dec) void {
    while (@intFromPtr(d.p) < @intFromPtr(d.end) and (d.p[0] == ' ' or d.p[0] == '\t' or d.p[0] == '\n' or d.p[0] == '\r')) d.p += 1;
}

fn utf8Encode(out: *std.ArrayList(u8), cp: u32) !void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch return;
    try out.appendSlice(alloc, buf[0..len]);
}

fn hex4(p: [*]const u8) i32 {
    var v: i32 = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const ch = p[i];
        const x: i32 = switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => return -1,
        };
        v = v * 16 + x;
    }
    return v;
}

fn remaining(d: *Dec) usize {
    return @intFromPtr(d.end) - @intFromPtr(d.p);
}

fn decString(d: *Dec) bool {
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(alloc);
    while (@intFromPtr(d.p) < @intFromPtr(d.end)) {
        const ch = d.p[0];
        d.p += 1;
        if (ch == '"') {
            _ = c.lua_pushlstring(d.L, s.items.ptr, s.items.len);
            return true;
        }
        if (ch == '\\') {
            if (@intFromPtr(d.p) >= @intFromPtr(d.end)) break;
            const esc = d.p[0];
            d.p += 1;
            switch (esc) {
                '"' => s.append(alloc, '"') catch return false,
                '\\' => s.append(alloc, '\\') catch return false,
                '/' => s.append(alloc, '/') catch return false,
                'b' => s.append(alloc, 8) catch return false,
                'f' => s.append(alloc, 12) catch return false,
                'n' => s.append(alloc, '\n') catch return false,
                'r' => s.append(alloc, '\r') catch return false,
                't' => s.append(alloc, '\t') catch return false,
                'u' => {
                    if (remaining(d) < 4) {
                        d.err = "json: truncated \\u escape";
                        return false;
                    }
                    var cp = hex4(d.p);
                    if (cp < 0) {
                        d.err = "json: bad \\u escape";
                        return false;
                    }
                    d.p += 4;
                    if (cp >= 0xD800 and cp <= 0xDBFF and remaining(d) >= 6 and d.p[0] == '\\' and d.p[1] == 'u') {
                        const lo = hex4(d.p + 2);
                        if (lo >= 0xDC00 and lo <= 0xDFFF) {
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            d.p += 6;
                        }
                    }
                    utf8Encode(&s, @intCast(cp)) catch return false;
                },
                else => {
                    d.err = "json: invalid escape";
                    return false;
                },
            }
        } else {
            s.append(alloc, ch) catch return false;
        }
    }
    d.err = "json: unterminated string";
    return false;
}

fn decArray(d: *Dec) bool {
    lua.newtable(d.L);
    var i: c_int = 0;
    skipWs(d);
    if (@intFromPtr(d.p) < @intFromPtr(d.end) and d.p[0] == ']') {
        d.p += 1;
        return true;
    }
    while (true) {
        skipWs(d);
        if (!decValue(d)) return false;
        i += 1;
        c.lua_rawseti(d.L, -2, i);
        skipWs(d);
        if (@intFromPtr(d.p) >= @intFromPtr(d.end)) {
            d.err = "json: unterminated array";
            return false;
        }
        const ch = d.p[0];
        d.p += 1;
        if (ch == ',') continue;
        if (ch == ']') return true;
        d.err = "json: expected ',' or ']'";
        return false;
    }
}

fn decObject(d: *Dec) bool {
    lua.newtable(d.L);
    skipWs(d);
    if (@intFromPtr(d.p) < @intFromPtr(d.end) and d.p[0] == '}') {
        d.p += 1;
        return true;
    }
    while (true) {
        skipWs(d);
        if (@intFromPtr(d.p) >= @intFromPtr(d.end) or d.p[0] != '"') {
            d.err = "json: expected a string key";
            return false;
        }
        d.p += 1;
        if (!decString(d)) return false;
        skipWs(d);
        if (@intFromPtr(d.p) >= @intFromPtr(d.end) or d.p[0] != ':') {
            d.err = "json: expected ':'";
            return false;
        }
        d.p += 1;
        skipWs(d);
        if (!decValue(d)) {
            lua.pop(d.L, 1); // drop the key
            return false;
        }
        c.lua_rawset(d.L, -3);
        skipWs(d);
        if (@intFromPtr(d.p) >= @intFromPtr(d.end)) {
            d.err = "json: unterminated object";
            return false;
        }
        const ch = d.p[0];
        d.p += 1;
        if (ch == ',') continue;
        if (ch == '}') return true;
        d.err = "json: expected ',' or '}'";
        return false;
    }
}

fn decValue(d: *Dec) bool {
    if (d.depth > 200) {
        d.err = "json: nesting too deep";
        return false;
    }
    skipWs(d);
    if (@intFromPtr(d.p) >= @intFromPtr(d.end)) {
        d.err = "json: unexpected end of input";
        return false;
    }
    const ch = d.p[0];
    switch (ch) {
        '"' => {
            d.p += 1;
            return decString(d);
        },
        '{' => {
            d.p += 1;
            d.depth += 1;
            const ok = decObject(d);
            d.depth -= 1;
            return ok;
        },
        '[' => {
            d.p += 1;
            d.depth += 1;
            const ok = decArray(d);
            d.depth -= 1;
            return ok;
        },
        't' => {
            if (remaining(d) >= 4 and std.mem.eql(u8, d.p[0..4], "true")) {
                d.p += 4;
                c.lua_pushboolean(d.L, 1);
                return true;
            }
        },
        'f' => {
            if (remaining(d) >= 5 and std.mem.eql(u8, d.p[0..5], "false")) {
                d.p += 5;
                c.lua_pushboolean(d.L, 0);
                return true;
            }
        },
        'n' => {
            if (remaining(d) >= 4 and std.mem.eql(u8, d.p[0..4], "null")) {
                d.p += 4;
                _ = c.lua_getfield(d.L, c.LUA_REGISTRYINDEX, kNullKey);
                return true;
            }
        },
        else => {
            if (ch == '-' or (ch >= '0' and ch <= '9'))
                return decNumber(d);
        },
    }
    d.err = "json: unexpected token";
    return false;
}

fn scanDigits(d: *Dec) void {
    while (@intFromPtr(d.p) < @intFromPtr(d.end) and d.p[0] >= '0' and d.p[0] <= '9') d.p += 1;
}

// Scan ONE JSON number per the grammar (-? int (. frac)? ([eE] [+-]? exp)?), bounded by d.end, then
// parse the exact token. Never strtod over the raw input — that would accept inf/nan/hex/leading-ws
// and (without a length) scan past the token. std.fmt.parseFloat is JSON-grammar-tight.
fn decNumber(d: *Dec) bool {
    const start = d.p;
    if (d.p[0] == '-') d.p += 1;
    if (@intFromPtr(d.p) >= @intFromPtr(d.end) or d.p[0] < '0' or d.p[0] > '9') {
        d.err = "json: bad number";
        return false;
    }
    scanDigits(d);
    if (@intFromPtr(d.p) < @intFromPtr(d.end) and d.p[0] == '.') {
        d.p += 1;
        if (@intFromPtr(d.p) >= @intFromPtr(d.end) or d.p[0] < '0' or d.p[0] > '9') {
            d.err = "json: bad number";
            return false;
        }
        scanDigits(d);
    }
    if (@intFromPtr(d.p) < @intFromPtr(d.end) and (d.p[0] == 'e' or d.p[0] == 'E')) {
        d.p += 1;
        if (@intFromPtr(d.p) < @intFromPtr(d.end) and (d.p[0] == '+' or d.p[0] == '-')) d.p += 1;
        if (@intFromPtr(d.p) >= @intFromPtr(d.end) or d.p[0] < '0' or d.p[0] > '9') {
            d.err = "json: bad number";
            return false;
        }
        scanDigits(d);
    }
    const tok = start[0..(@intFromPtr(d.p) - @intFromPtr(start))];
    const v = std.fmt.parseFloat(f64, tok) catch {
        d.err = "json: bad number";
        return false;
    };
    c.lua_pushnumber(d.L, v);
    return true;
}

fn lJsonDecode(L: ?*State) callconv(.c) c_int {
    var n: usize = 0;
    const s = c.luaL_checklstring(L, 1, &n);
    var d = Dec{ .p = s, .end = s + n, .L = L };
    if (!decValue(&d)) {
        c.lua_pushnil(L);
        _ = c.lua_pushstring(L, d.err orelse "json: parse error");
        return 2;
    }
    skipWs(&d);
    if (@intFromPtr(d.p) != @intFromPtr(d.end)) {
        lua.pop(L, 1);
        c.lua_pushnil(L);
        _ = c.lua_pushstring(L, "json: trailing garbage after value");
        return 2;
    }
    c.lua_pushnil(L); // err = nil
    return 2;
}

pub export fn mc_open_json(L: ?*State) c_int {
    // json.null: a unique table, in the registry + exposed as json.null.
    lua.newtable(L); // sentinel
    c.lua_pushvalue(L, -1);
    c.lua_setfield(L, c.LUA_REGISTRYINDEX, kNullKey);

    lua.newtable(L); // module [sentinel, json]
    c.lua_pushvalue(L, -2);
    c.lua_setfield(L, -2, "null");
    lua.pushcfunction(L, &lJsonEncode, "encode");
    c.lua_setfield(L, -2, "encode");
    lua.pushcfunction(L, &lJsonDecode, "decode");
    c.lua_setfield(L, -2, "decode");
    c.lua_remove(L, -2); // drop the loose sentinel → [json]
    return 1;
}
