//! Gzip container plumbing on top of `std.compress.flate` (DESIGN.md §7.5). Zig std's
//! `Compress`/`Decompress` already implement the gzip DEFLATE codec and container
//! framing; this module is just the bit the gzip applet actually needs on top:
//!
//! - **Level mapping**: gzip's `-1..-9` (and `--fast`==1, `--best`==9, default 6) map
//!   directly onto `flate.Compress.Options.level_1..level_9` -- verified against
//!   `std/compress/flate/Compress.zig`, whose `level_N` constants are literally named
//!   that way and whose `fastest`/`default`/`best` aliases are `level_1`/`level_6`/
//!   `level_9`.
//! - **Header bytes**: DESIGN.md flagged an open question -- "does std's gzip header
//!   writer allow MTIME=0, no FNAME?" Verified empirically by reading
//!   `flate.Container.header(.gzip)`: it is the fixed 10-byte array
//!   `1f 8b 08 00 00 00 00 00 00 03` -- FLG=0 (no FNAME/FCOMMENT/FEXTRA/FHCRC), all four
//!   MTIME bytes zero, XFL=0, OS=3 (unix). That is *exactly* the reference Rust
//!   wrapper's contract (name/timestamp never stored) with zero extra work on our part:
//!   `flate.Compress.init(.., .gzip, ..)` already writes this header unconditionally.
//!   Ledgered: OS=3 was a documented uncertainty in the design doc ("flate2's GzEncoder
//!   ... OS=3? OS=255?") -- resolved by reading the actual bytes Zig std emits, which is
//!   the only oracle available in this sandbox (no way to run the Rust wrapper). Since
//!   std's own header is fixed and gzip's OS byte is cosmetic (never round-tripped by
//!   any of our own `-l`/`-t`/`-d` paths), byte-for-byte gzip parity beyond "a
//!   conformant gzip member decodable by any gunzip" is out of scope -- see
//!   docs/parity-ledger.md.
//! - **CRC/ISIZE verification on decompress**: `Decompress` parses the gzip trailer into
//!   `container_metadata.gzip.{crc,count}` but (verified by reading
//!   `std/compress/flate/Decompress.zig`) never actually compares them against the
//!   decoded bytes -- `Container.Error.WrongGzipChecksum`/`WrongGzipSize` are declared
//!   but unreachable from std itself. That verification is this module's job.
//!
//! Everything here is whole-buffer in, whole-buffer out (DESIGN.md §8: "Std usage
//! elsewhere is compute-only ... Io-parameterized via reader/writer interfaces we can
//! feed from fixed buffers" -- no fd adapters live here; the gzip applet reads the
//! whole input file into memory and writes the whole result back out in one shot,
//! matching the archive engines' in-memory model).

const std = @import("std");
const flate = std.compress.flate;

pub const Error = error{
    OutOfMemory,
    BadGzipHeader,
    WrongGzipChecksum,
    WrongGzipSize,
    CorruptDeflateStream,
    InputTooLarge,
};

/// A hard decompressed-size ceiling: defuses a maliciously/accidentally huge ISIZE or a
/// decompression bomb turning a tiny file into an unbounded allocation. Generous for any
/// realistic corpus/test fixture.
pub const max_decompressed_len: usize = 512 * 1024 * 1024;

/// Shared with `engines/archive/zipwriter.zig` (zip's DEFLATE method uses the same
/// level tiers, just with a raw rather than gzip container).
pub fn optsForLevel(level: u8) flate.Compress.Options {
    return switch (level) {
        0, 1 => .level_1,
        2 => .level_2,
        3 => .level_3,
        4 => .level_4,
        5 => .level_5,
        6 => .level_6,
        7 => .level_7,
        8 => .level_8,
        else => .level_9, // 9 and anything out of range clamp to the strongest tier
    };
}

/// Compresses `input` into a single gzip member at `level` (1-9; gzip's own clamping
/// rules -- 0 treated as 1, >9 treated as 9 -- are the caller's job if it wants to
/// differ, but this mirrors flate2's clamp too). Returns a `gpa`-owned slice.
pub fn compress(gpa: std.mem.Allocator, input: []const u8, level: u8) Error![]u8 {
    // Compress.init asserts the output writer's buffer capacity exceeds 8 bytes even
    // before anything is written, so the Allocating writer needs an initial reservation
    // rather than starting from its default empty buffer.
    const initial_cap = @max(64, input.len / 2 + 64);
    var out = std.Io.Writer.Allocating.initCapacity(gpa, initial_cap) catch return error.OutOfMemory;
    defer out.deinit();

    var window: [flate.max_window_len]u8 = undefined;
    var comp = flate.Compress.init(&out.writer, &window, .gzip, optsForLevel(level)) catch return error.OutOfMemory;
    comp.writer.writeAll(input) catch return error.OutOfMemory;
    comp.finish() catch return error.OutOfMemory;

    var al = out.toArrayList();
    return al.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

pub const Decompressed = struct {
    data: []u8,

    pub fn free(self: Decompressed, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
    }
};

/// Decompresses a single gzip member from `input`, verifying the trailer CRC32 and
/// ISIZE against the actually-decoded bytes (std's `Decompress` parses the trailer but
/// never checks it -- see the module doc). Returns a `gpa`-owned buffer.
pub fn decompress(gpa: std.mem.Allocator, input: []const u8) Error!Decompressed {
    var in_reader = std.Io.Reader.fixed(input);
    var window: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&in_reader, .gzip, &window);

    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(gpa);
    dec.reader.appendRemaining(gpa, &list, .limited(max_decompressed_len)) catch |e| switch (e) {
        error.StreamTooLong => return error.InputTooLarge,
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed => {
            if (dec.err) |derr| return mapDecompressError(derr);
            return error.CorruptDeflateStream;
        },
    };

    var crc = std.hash.Crc32.init();
    crc.update(list.items);
    const meta = dec.container_metadata.gzip;
    if (crc.final() != meta.crc) return error.WrongGzipChecksum;
    const truncated_len: u32 = @truncate(list.items.len);
    if (truncated_len != meta.count) return error.WrongGzipSize;

    const data = list.toOwnedSlice(gpa) catch return error.OutOfMemory;
    return .{ .data = data };
}

fn mapDecompressError(e: flate.Decompress.Error) Error {
    return switch (e) {
        error.BadGzipHeader => error.BadGzipHeader,
        error.WrongGzipChecksum => error.WrongGzipChecksum,
        error.WrongGzipSize => error.WrongGzipSize,
        else => error.CorruptDeflateStream,
    };
}

/// Reads the gzip trailer's ISIZE field (uncompressed-size-mod-2^32, little-endian, the
/// last 4 bytes of a well-formed member) directly, without running the DEFLATE decoder
/// at all -- `gzip -l`'s fast path. `gz_bytes` must be the complete compressed file (at
/// least 8 bytes: gzip's CRC32+ISIZE trailer).
pub fn isizeFromTrailer(gz_bytes: []const u8) ?u32 {
    if (gz_bytes.len < 8) return null;
    const trailer = gz_bytes[gz_bytes.len - 4 ..];
    return std.mem.readInt(u32, trailer[0..4], .little);
}
