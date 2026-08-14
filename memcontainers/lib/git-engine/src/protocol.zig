const std = @import("std");
const packp = @import("packp");
const plumbing = @import("plumbing");

pub const AdvertisedHead = struct { hash: plumbing.Hash, target_ref: ?[]u8 };

pub const ParsedUploadResponse = struct {
    pack_offset: usize,
    shallows: []plumbing.Hash,
    has_update: bool,
};

pub fn encodeUploadPackRequest(allocator: std.mem.Allocator, request: *const packp.UploadPackRequest) ![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    errdefer allocating.deinit();
    if (request.upload_request.wants.items.len == 0) return error.EmptyWants;
    sortHashes(request.upload_request.wants.items);
    const caps = try request.upload_request.capabilities.string(allocator);
    defer allocator.free(caps);
    var last = plumbing.ZeroHash;
    for (request.upload_request.wants.items, 0..) |want, i| {
        if (i > 0 and last.eql(want)) continue;
        var hex: [plumbing.MaxHexSize]u8 = undefined;
        const line = if (i == 0 and caps.len > 0)
            try std.fmt.allocPrint(allocator, "want {s} {s}\n", .{ want.string(&hex), caps })
        else
            try std.fmt.allocPrint(allocator, "want {s}\n", .{want.string(&hex)});
        defer allocator.free(line);
        try writePktLine(&allocating.writer, line);
        last = want;
    }
    sortHashes(request.upload_request.shallows.items);
    last = plumbing.ZeroHash;
    for (request.upload_request.shallows.items, 0..) |shallow_hash, i| {
        if (i > 0 and last.eql(shallow_hash)) continue;
        var hex: [plumbing.MaxHexSize]u8 = undefined;
        const line = try std.fmt.allocPrint(allocator, "shallow {s}\n", .{shallow_hash.string(&hex)});
        defer allocator.free(line);
        try writePktLine(&allocating.writer, line);
        last = shallow_hash;
    }
    switch (request.upload_request.depth) {
        .commits => |count| if (count > 0) {
            const line = try std.fmt.allocPrint(allocator, "deepen {d}\n", .{count});
            defer allocator.free(line);
            try writePktLine(&allocating.writer, line);
        },
        else => return error.UnsupportedDepth,
    }
    try allocating.writer.writeAll("0000");
    sortHashes(request.upload_haves.haves.items);
    last = plumbing.ZeroHash;
    for (request.upload_haves.haves.items, 0..) |have, i| {
        if (i > 0 and last.eql(have)) continue;
        var hex: [plumbing.MaxHexSize]u8 = undefined;
        const line = try std.fmt.allocPrint(allocator, "have {s}\n", .{have.string(&hex)});
        defer allocator.free(line);
        try writePktLine(&allocating.writer, line);
        last = have;
    }
    try allocating.writer.writeAll("0009done\n");
    return allocating.toOwnedSlice();
}

pub fn parseUploadResponse(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    existing: []const plumbing.Hash,
    shallow_exchange: bool,
) !ParsedUploadResponse {
    var shallows: std.ArrayList(plumbing.Hash) = .empty;
    errdefer shallows.deinit(allocator);
    try shallows.appendSlice(allocator, existing);
    var unshallows: std.ArrayList(plumbing.Hash) = .empty;
    defer unshallows.deinit(allocator);
    var offset: usize = 0;
    var shallow_phase = shallow_exchange;
    while (offset + 4 <= bytes.len) {
        if (std.mem.eql(u8, bytes[offset..][0..4], "PACK")) break;
        const length = std.fmt.parseInt(usize, bytes[offset..][0..4], 16) catch return error.InvalidUploadResponse;
        offset += 4;
        if (length == 0) {
            shallow_phase = false;
            continue;
        }
        if (length < 4 or offset + length - 4 > bytes.len) return error.InvalidUploadResponse;
        const line = std.mem.trimEnd(u8, bytes[offset .. offset + length - 4], "\r\n");
        offset += length - 4;
        if (shallow_phase and std.mem.startsWith(u8, line, "shallow ")) {
            const hash = try plumbing.parseHash(line[8..]);
            var present = false;
            for (shallows.items) |current| if (current.eql(hash)) {
                present = true;
                break;
            };
            if (!present) try shallows.append(allocator, hash);
            continue;
        }
        if (shallow_phase and std.mem.startsWith(u8, line, "unshallow ")) {
            try unshallows.append(allocator, try plumbing.parseHash(line[10..]));
            continue;
        }
        if (std.mem.eql(u8, line, "NAK") or std.mem.startsWith(u8, line, "ACK ")) continue;
        return error.InvalidUploadResponse;
    }
    if (offset + 4 > bytes.len or !std.mem.eql(u8, bytes[offset..][0..4], "PACK")) return error.MissingPack;
    if (unshallows.items.len > 0) {
        var write: usize = 0;
        outer: for (shallows.items) |hash| {
            for (unshallows.items) |removed| if (hash.eql(removed)) continue :outer;
            shallows.items[write] = hash;
            write += 1;
        }
        shallows.shrinkRetainingCapacity(write);
    }
    return .{
        .pack_offset = offset,
        .shallows = try shallows.toOwnedSlice(allocator),
        .has_update = shallow_exchange,
    };
}

pub fn advertisementSupportsCapability(bytes: []const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset + 4 <= bytes.len) {
        const length = std.fmt.parseInt(usize, bytes[offset..][0..4], 16) catch return false;
        offset += 4;
        if (length == 0) continue;
        if (length < 4 or offset + length - 4 > bytes.len) return false;
        const line = bytes[offset .. offset + length - 4];
        offset += length - 4;
        const nul = std.mem.indexOfScalar(u8, line, 0) orelse continue;
        var capabilities = std.mem.splitScalar(u8, std.mem.trimEnd(u8, line[nul + 1 ..], "\r\n"), ' ');
        while (capabilities.next()) |capability| {
            const name = if (std.mem.indexOfScalar(u8, capability, '=')) |at| capability[0..at] else capability;
            if (std.mem.eql(u8, name, wanted)) return true;
        }
        return false;
    }
    return false;
}

pub fn parseAdvertisedHead(allocator: std.mem.Allocator, bytes: []const u8) !AdvertisedHead {
    var offset: usize = 0;
    var head_hash: ?plumbing.Hash = null;
    var first_hash: ?plumbing.Hash = null;
    var target_ref: ?[]u8 = null;
    errdefer if (target_ref) |name| allocator.free(name);
    while (offset + 4 <= bytes.len) {
        const length = std.fmt.parseInt(usize, bytes[offset..][0..4], 16) catch return error.InvalidAdvertisement;
        offset += 4;
        if (length == 0) continue;
        if (length < 4 or offset + length - 4 > bytes.len) return error.InvalidAdvertisement;
        var line = bytes[offset .. offset + length - 4];
        offset += length - 4;
        line = std.mem.trimEnd(u8, line, "\r\n");
        if (std.mem.startsWith(u8, line, "# service=")) continue;
        if (line.len < 42 or line[40] != ' ') continue;
        const hash = try plumbing.parseHash(line[0..40]);
        const nul = std.mem.indexOfScalar(u8, line, 0);
        const ref_end = nul orelse line.len;
        const ref_name = line[41..ref_end];
        if (first_hash == null) first_hash = hash;
        if (std.mem.eql(u8, ref_name, "HEAD")) head_hash = hash;
        if (nul) |at| {
            const caps = line[at + 1 ..];
            var words = std.mem.splitScalar(u8, caps, ' ');
            while (words.next()) |word| if (std.mem.startsWith(u8, word, "symref=HEAD:")) {
                target_ref = try allocator.dupe(u8, word[12..]);
                break;
            };
        }
    }
    return .{
        .hash = head_hash orelse first_hash orelse return error.EmptyAdvertisement,
        .target_ref = target_ref,
    };
}

pub fn findAdvertisedRef(bytes: []const u8, wanted: []const u8) !plumbing.Hash {
    var offset: usize = 0;
    while (offset + 4 <= bytes.len) {
        const length = std.fmt.parseInt(usize, bytes[offset..][0..4], 16) catch return error.InvalidAdvertisement;
        offset += 4;
        if (length == 0) continue;
        if (length < 4 or offset + length - 4 > bytes.len) return error.InvalidAdvertisement;
        var line = std.mem.trimEnd(u8, bytes[offset .. offset + length - 4], "\r\n");
        offset += length - 4;
        if (line.len < 42 or line[40] != ' ') continue;
        if (std.mem.indexOfScalar(u8, line, 0)) |nul| line = line[0..nul];
        if (std.mem.eql(u8, line[41..], wanted)) return plumbing.parseHash(line[0..40]);
    }
    return error.ReferenceNotFound;
}

pub fn encodeReceivePackRequest(
    allocator: std.mem.Allocator,
    old_hash: plumbing.Hash,
    new_hash: plumbing.Hash,
    name: []const u8,
    pack: []const u8,
) ![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    errdefer allocating.deinit();
    var old_hex: [plumbing.MaxHexSize]u8 = undefined;
    var new_hex: [plumbing.MaxHexSize]u8 = undefined;
    const command = try std.fmt.allocPrint(allocator, "{s} {s} {s}\x00report-status", .{
        old_hash.string(&old_hex),
        new_hash.string(&new_hex),
        name,
    });
    defer allocator.free(command);
    try writePktLine(&allocating.writer, command);
    try allocating.writer.writeAll("0000");
    try allocating.writer.writeAll(pack);
    return allocating.toOwnedSlice();
}

fn writePktLine(writer: *std.Io.Writer, payload: []const u8) !void {
    if (payload.len > 65516) return error.PayloadTooLong;
    var header: [4]u8 = undefined;
    const digits = "0123456789abcdef";
    const length: u16 = @intCast(payload.len + 4);
    header[0] = digits[(length >> 12) & 0xf];
    header[1] = digits[(length >> 8) & 0xf];
    header[2] = digits[(length >> 4) & 0xf];
    header[3] = digits[length & 0xf];
    try writer.writeAll(&header);
    try writer.writeAll(payload);
}

fn sortHashes(hashes: []plumbing.Hash) void {
    std.mem.sort(plumbing.Hash, hashes, {}, struct {
        fn less(_: void, left: plumbing.Hash, right: plumbing.Hash) bool {
            return std.mem.order(u8, &left.bytes, &right.bytes) == .lt;
        }
    }.less);
}
