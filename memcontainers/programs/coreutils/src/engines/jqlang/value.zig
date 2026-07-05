//! jq's runtime value model (DESIGN.md-style doc for the jq applet): null/bool/
//! number(f64)/string/array/object. Objects are INSERTION-ORDERED association lists
//! (not a hash map) so that construction order survives `keys_unsorted`, `to_entries`,
//! serialization, etc. -- matching jq/jaq's IndexMap-backed object. Everything is
//! arena-allocated (no frees; `Ctx.gpa` is an arena freed wholesale at process exit --
//! DESIGN.md §5.3), so builders always COPY rather than mutate shared structure,
//! trading a bit of extra allocation for zero aliasing bugs.
//!
//! Total order (used by `sort`/`min`/`max`/`<`/`==`/group_by/unique/object `<`) matches
//! jaq exactly: null < false < true < number < string < array < object; NaN compares
//! less than everything (including itself, so NaN != NaN); objects compare by (len,
//! then sorted-keys, then values-in-that-key-order).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    null,
    boolean: bool,
    number: f64,
    string: []const u8,
    array: []const Value,
    object: []const Entry,

    pub const TRUE: Value = .{ .boolean = true };
    pub const FALSE: Value = .{ .boolean = false };

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .null => "null",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .array => "array",
            .object => "object",
        };
    }

    /// jq truthiness: everything except `null` and `false` is truthy (0, "", [], {}
    /// all count as true).
    pub fn truthy(self: Value) bool {
        return switch (self) {
            .null => false,
            .boolean => |b| b,
            else => true,
        };
    }

    pub fn boolOf(b: bool) Value {
        return .{ .boolean = b };
    }

    pub fn numOf(n: f64) Value {
        return .{ .number = n };
    }

    pub fn strOf(s: []const u8) Value {
        return .{ .string = s };
    }

    fn typeRank(self: Value) u8 {
        return switch (self) {
            .null => 0,
            .boolean => 1,
            .number => 2,
            .string => 3,
            .array => 4,
            .object => 5,
        };
    }

    /// Total order matching jaq's `Ord for Val` (see reference/jaq/jaq-json/src/lib.rs).
    pub fn compare(gpa: Allocator, a: Value, b: Value) std.math.Order {
        const ra = a.typeRank();
        const rb = b.typeRank();
        if (ra != rb) return if (ra < rb) .lt else .gt;
        return switch (a) {
            .null => .eq,
            .boolean => |ab| orderBool(ab, b.boolean),
            .number => |an| compareNum(an, b.number),
            .string => |as_| std.mem.order(u8, as_, b.string),
            .array => |aa| compareArrays(gpa, aa, b.array),
            .object => |ao| compareObjects(gpa, ao, b.object),
        };
    }

    pub fn equal(gpa: Allocator, a: Value, b: Value) bool {
        return compare(gpa, a, b) == .eq;
    }
};

fn orderBool(a: bool, b: bool) std.math.Order {
    if (a == b) return .eq;
    return if (!a) .lt else .gt;
}

/// NaN sorts below everything, including another NaN (so NaN != NaN, matching jaq's
/// `float_cmp`). Negative and positive zero compare equal.
fn compareNum(x: f64, y: f64) std.math.Order {
    if (x == 0 and y == 0) return .eq;
    if (std.math.isNan(x)) return .lt;
    if (std.math.isNan(y)) return .gt;
    if (x < y) return .lt;
    if (x > y) return .gt;
    return .eq;
}

fn compareArrays(gpa: Allocator, a: []const Value, b: []const Value) std.math.Order {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = Value.compare(gpa, a[i], b[i]);
        if (c != .eq) return c;
    }
    return std.math.order(a.len, b.len);
}

fn lessKey(_: void, x: Entry, y: Entry) bool {
    return std.mem.order(u8, x.key, y.key) == .lt;
}

fn compareObjects(gpa: Allocator, a: []const Entry, b: []const Entry) std.math.Order {
    if (a.len == 0 and b.len == 0) return .eq;
    if (a.len == 0) return .lt;
    if (b.len == 0) return .gt;

    const sa = gpa.dupe(Entry, a) catch @panic("OOM");
    const sb = gpa.dupe(Entry, b) catch @panic("OOM");
    std.mem.sort(Entry, sa, {}, lessKey);
    std.mem.sort(Entry, sb, {}, lessKey);

    const n = @min(sa.len, sb.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = std.mem.order(u8, sa[i].key, sb[i].key);
        if (c != .eq) return c;
    }
    if (sa.len != sb.len) return std.math.order(sa.len, sb.len);
    i = 0;
    while (i < n) : (i += 1) {
        const c = Value.compare(gpa, sa[i].value, sb[i].value);
        if (c != .eq) return c;
    }
    return .eq;
}

/// Builds an object value with jq's "set replaces value in place, keeping original
/// insertion position; new key appends" semantics (matches an IndexMap `entry().or_
/// insert()`/assignment, i.e. real jq/jaq object construction and `+` merge).
pub const ObjBuilder = struct {
    gpa: Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(gpa: Allocator) ObjBuilder {
        return .{ .gpa = gpa };
    }

    pub fn set(self: *ObjBuilder, key: []const u8, value: Value) void {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) {
                e.value = value;
                return;
            }
        }
        self.entries.append(self.gpa, .{ .key = key, .value = value }) catch @panic("OOM");
    }

    /// Removes `key` if present, preserving the relative order of the rest.
    pub fn remove(self: *ObjBuilder, key: []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.entries.items[i].key, key)) {
                _ = self.entries.orderedRemove(i);
                return;
            }
        }
    }

    pub fn get(self: *const ObjBuilder, key: []const u8) ?Value {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }

    pub fn finish(self: *ObjBuilder) []const Entry {
        return self.entries.toOwnedSlice(self.gpa) catch @panic("OOM");
    }
};

pub fn objGet(obj: []const Entry, key: []const u8) ?Value {
    for (obj) |e| {
        if (std.mem.eql(u8, e.key, key)) return e.value;
    }
    return null;
}

pub fn emptyObject() Value {
    return .{ .object = &.{} };
}

pub fn emptyArray() Value {
    return .{ .array = &.{} };
}
