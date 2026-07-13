//! Shared Lua-family external scanner. Each generated parser gets its ABI-named wrappers, while the
//! state machine itself remains one implementation. Long-bracket delimiter depth is serialized so
//! incremental parsing can resume without rescanning the prefix.
const std = @import("std");
const c = @cImport({
    @cInclude("parser.h");
});

const LONG_STRING_START = 0;
const LONG_STRING_CONTENT = 1;
const LONG_STRING_END = 2;
const LONG_COMMENT = 3;

const Scanner = struct { equals: u8 = 0, in_string: bool = false };
const alloc = std.heap.c_allocator;

fn advance(lexer: *c.TSLexer) void {
    lexer.advance.?(lexer, false);
}
fn opener(lexer: *c.TSLexer) ?u8 {
    if (lexer.lookahead != '[') return null;
    advance(lexer);
    var equals: u8 = 0;
    while (lexer.lookahead == '=') {
        if (equals == 255) return null;
        equals += 1;
        advance(lexer);
    }
    if (lexer.lookahead != '[') return null;
    advance(lexer);
    return equals;
}
fn closer(lexer: *c.TSLexer, equals: u8) bool {
    if (lexer.lookahead != ']') return false;
    advance(lexer);
    var seen: u8 = 0;
    while (seen < equals and lexer.lookahead == '=') : (seen += 1) advance(lexer);
    if (seen != equals or lexer.lookahead != ']') return false;
    advance(lexer);
    return true;
}
fn scan(scanner: *Scanner, lexer: *c.TSLexer, valid: [*]const bool) bool {
    if (valid[LONG_COMMENT] and lexer.lookahead == '-') {
        advance(lexer);
        if (lexer.lookahead != '-') return false;
        advance(lexer);
        const eq = opener(lexer) orelse return false;
        while (lexer.lookahead != 0) {
            if (closer(lexer, eq)) {
                lexer.result_symbol = LONG_COMMENT;
                return true;
            }
            advance(lexer);
        }
        lexer.result_symbol = LONG_COMMENT;
        return true;
    }
    if (valid[LONG_STRING_START] and !scanner.in_string) {
        const eq = opener(lexer) orelse return false;
        scanner.equals = eq;
        scanner.in_string = true;
        lexer.result_symbol = LONG_STRING_START;
        return true;
    }
    if (scanner.in_string and valid[LONG_STRING_END] and closer(lexer, scanner.equals)) {
        scanner.in_string = false;
        lexer.result_symbol = LONG_STRING_END;
        return true;
    }
    if (scanner.in_string and valid[LONG_STRING_CONTENT]) {
        var consumed = false;
        while (lexer.lookahead != 0) {
            lexer.mark_end.?(lexer);
            if (closer(lexer, scanner.equals)) break;
            advance(lexer);
            consumed = true;
        }
        if (consumed) {
            lexer.result_symbol = LONG_STRING_CONTENT;
            return true;
        }
    }
    return false;
}
fn create() ?*anyopaque {
    const value = alloc.create(Scanner) catch return null;
    value.* = Scanner{};
    return value;
}
fn destroy(payload: ?*anyopaque) void {
    if (payload) |p| alloc.destroy(@as(*Scanner, @ptrCast(@alignCast(p))));
}
fn serialize(payload: ?*anyopaque, buffer: [*c]u8) c_uint {
    const s = @as(*Scanner, @ptrCast(@alignCast(payload.?)));
    buffer[0] = s.equals;
    buffer[1] = @intFromBool(s.in_string);
    return 2;
}
fn deserialize(payload: ?*anyopaque, buffer: [*c]const u8, length: c_uint) void {
    const s = @as(*Scanner, @ptrCast(@alignCast(payload.?)));
    s.* = Scanner{};
    if (length >= 2) {
        s.equals = buffer[0];
        s.in_string = buffer[1] != 0;
    }
}

fn exportScanner(comptime prefix: []const u8) type {
    _ = prefix;
    return struct {};
}
comptime {
    _ = exportScanner("lua");
}

pub export fn tree_sitter_lua_external_scanner_create() ?*anyopaque {
    return create();
}
pub export fn tree_sitter_lua_external_scanner_destroy(p: ?*anyopaque) void {
    destroy(p);
}
pub export fn tree_sitter_lua_external_scanner_scan(p: ?*anyopaque, l: *c.TSLexer, v: [*]const bool) bool {
    return scan(@ptrCast(@alignCast(p.?)), l, v);
}
pub export fn tree_sitter_lua_external_scanner_serialize(p: ?*anyopaque, b: [*c]u8) c_uint {
    return serialize(p, b);
}
pub export fn tree_sitter_lua_external_scanner_deserialize(p: ?*anyopaque, b: [*c]const u8, n: c_uint) void {
    deserialize(p, b, n);
}
pub export fn tree_sitter_luau_external_scanner_create() ?*anyopaque {
    return create();
}
pub export fn tree_sitter_luau_external_scanner_destroy(p: ?*anyopaque) void {
    destroy(p);
}
pub export fn tree_sitter_luau_external_scanner_scan(p: ?*anyopaque, l: *c.TSLexer, v: [*]const bool) bool {
    return scan(@ptrCast(@alignCast(p.?)), l, v);
}
pub export fn tree_sitter_luau_external_scanner_serialize(p: ?*anyopaque, b: [*c]u8) c_uint {
    return serialize(p, b);
}
pub export fn tree_sitter_luau_external_scanner_deserialize(p: ?*anyopaque, b: [*c]const u8, n: c_uint) void {
    deserialize(p, b, n);
}
