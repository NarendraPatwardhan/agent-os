const std = @import("std");

pub const magic = "MCLPKG1\x00".*;
pub const version: u16 = 1;
pub const header_size: u16 = 24;
pub const module_record_size: u32 = 24;
pub const max_modules: u32 = 4096;
pub const max_module_name_bytes: u32 = 1024;

pub const Error = error{
    InvalidMagic,
    UnsupportedVersion,
    InvalidHeader,
    ResourceLimit,
    InvalidEntryModule,
    InvalidModuleName,
    NonCanonicalModuleOrder,
    NonCanonicalLayout,
    IntegerOverflow,
};

pub const Module = struct {
    id: u32,
    name: []const u8,
    snapshot: []const u8,
};

pub const Package = struct {
    bytes: []const u8,
    module_count: u32,
    entry_module_id: u32,

    pub fn module(self: Package, id: u32) Error!Module {
        if (id >= self.module_count)
            return Error.InvalidEntryModule;
        const record_offset = try add(header_size, try mul(id, module_record_size));
        const record = self.bytes[record_offset..][0..module_record_size];
        const name_offset = readU32(record, 0);
        const name_size = readU32(record, 4);
        const snapshot_offset = readU32(record, 8);
        const snapshot_size = readU32(record, 12);
        return .{
            .id = id,
            .name = self.bytes[name_offset..][0..name_size],
            .snapshot = self.bytes[snapshot_offset..][0..snapshot_size],
        };
    }

    pub fn moduleByName(self: Package, name: []const u8) ?Module {
        var low: u32 = 0;
        var high = self.module_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const candidate = self.module(middle) catch unreachable;
            switch (std.mem.order(u8, candidate.name, name)) {
                .lt => low = middle + 1,
                .gt => high = middle,
                .eq => return candidate,
            }
        }
        return null;
    }
};

pub fn parse(bytes: []const u8) Error!Package {
    if (bytes.len < header_size)
        return Error.InvalidHeader;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic))
        return Error.InvalidMagic;
    if (readU16(bytes, 8) != version)
        return Error.UnsupportedVersion;
    if (readU16(bytes, 10) != header_size or readU32(bytes, 20) != module_record_size)
        return Error.InvalidHeader;

    const module_count = readU32(bytes, 12);
    const entry_module_id = readU32(bytes, 16);
    if (module_count == 0 or module_count > max_modules)
        return Error.ResourceLimit;
    if (entry_module_id >= module_count)
        return Error.InvalidEntryModule;

    var cursor = try add(header_size, try mul(module_count, module_record_size));
    if (cursor > bytes.len)
        return Error.InvalidHeader;
    var previous_name: ?[]const u8 = null;
    var id: u32 = 0;
    while (id < module_count) : (id += 1) {
        const record_offset = try add(header_size, try mul(id, module_record_size));
        const record = bytes[record_offset..][0..module_record_size];
        if (readU32(record, 16) != 0 or readU32(record, 20) != 0)
            return Error.InvalidHeader;

        const name_offset = readU32(record, 0);
        const name_size = readU32(record, 4);
        const snapshot_offset = readU32(record, 8);
        const snapshot_size = readU32(record, 12);
        if (name_size == 0 or name_size > max_module_name_bytes or snapshot_size == 0 or
            name_offset != cursor)
            return Error.NonCanonicalLayout;
        const name_end = try add(name_offset, name_size);
        if (name_end > bytes.len or snapshot_offset != name_end)
            return Error.NonCanonicalLayout;
        const snapshot_end = try add(snapshot_offset, snapshot_size);
        if (snapshot_end > bytes.len)
            return Error.NonCanonicalLayout;

        const name = bytes[name_offset..name_end];
        if (!validModuleName(name))
            return Error.InvalidModuleName;
        if (previous_name) |previous| {
            if (std.mem.order(u8, previous, name) != .lt)
                return Error.NonCanonicalModuleOrder;
        }
        previous_name = name;
        cursor = snapshot_end;
    }
    if (cursor != bytes.len)
        return Error.NonCanonicalLayout;

    return .{ .bytes = bytes, .module_count = module_count, .entry_module_id = entry_module_id };
}

fn validModuleName(name: []const u8) bool {
    if (name[0] == '/' or name[name.len - 1] == '/' or std.mem.indexOf(u8, name, "..") != null)
        return false;
    for (name) |byte| switch (byte) {
        'a'...'z', '0'...'9', '_', '-', '.', '/' => {},
        else => return false,
    };
    return true;
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn add(lhs: anytype, rhs: anytype) Error!u32 {
    return std.math.add(u32, @intCast(lhs), @intCast(rhs)) catch Error.IntegerOverflow;
}

fn mul(lhs: u32, rhs: u32) Error!u32 {
    return std.math.mul(u32, lhs, rhs) catch Error.IntegerOverflow;
}

test "parses canonical two-module package" {
    const name0 = "counter";
    const snapshot0 = "snapshot-zero";
    const name1 = "main";
    const snapshot1 = "snapshot-one";
    const records_end = header_size + 2 * module_record_size;
    const size = records_end + name0.len + snapshot0.len + name1.len + snapshot1.len;
    var bytes = [_]u8{0} ** size;
    @memcpy(bytes[0..magic.len], &magic);
    std.mem.writeInt(u16, bytes[8..10], version, .little);
    std.mem.writeInt(u16, bytes[10..12], header_size, .little);
    std.mem.writeInt(u32, bytes[12..16], 2, .little);
    std.mem.writeInt(u32, bytes[16..20], 1, .little);
    std.mem.writeInt(u32, bytes[20..24], module_record_size, .little);

    var cursor: u32 = records_end;
    std.mem.writeInt(u32, bytes[24..28], cursor, .little);
    std.mem.writeInt(u32, bytes[28..32], name0.len, .little);
    @memcpy(bytes[cursor..][0..name0.len], name0);
    cursor += name0.len;
    std.mem.writeInt(u32, bytes[32..36], cursor, .little);
    std.mem.writeInt(u32, bytes[36..40], snapshot0.len, .little);
    @memcpy(bytes[cursor..][0..snapshot0.len], snapshot0);
    cursor += snapshot0.len;

    std.mem.writeInt(u32, bytes[48..52], cursor, .little);
    std.mem.writeInt(u32, bytes[52..56], name1.len, .little);
    @memcpy(bytes[cursor..][0..name1.len], name1);
    cursor += name1.len;
    std.mem.writeInt(u32, bytes[56..60], cursor, .little);
    std.mem.writeInt(u32, bytes[60..64], snapshot1.len, .little);
    @memcpy(bytes[cursor..][0..snapshot1.len], snapshot1);

    const package = try parse(&bytes);
    try std.testing.expectEqual(@as(u32, 1), package.entry_module_id);
    try std.testing.expectEqualStrings("counter", (try package.module(0)).name);
    try std.testing.expectEqualStrings("snapshot-one", (try package.module(1)).snapshot);
    try std.testing.expectEqual(@as(u32, 0), package.moduleByName("counter").?.id);
    try std.testing.expect(package.moduleByName("missing") == null);
}
