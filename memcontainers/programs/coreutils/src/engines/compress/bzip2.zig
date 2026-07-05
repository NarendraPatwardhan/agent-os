//! bzip2 decode-only decompressor (M6 compression engines). Ported from the pure-Rust
//! `bzip2-rs` 0.1.2 crate vendored at `reference/crates/bzip2-rs-0.1.2/src/` (`lib.rs`,
//! `header/mod.rs`, `block/mod.rs`, `block/bwt.rs`, `huffman.rs`, `move_to_front.rs`,
//! `bitreader.rs`, `crc.rs`, `decoder/mod.rs`), which is this file's parity oracle.
//! Whole-buffer in, whole-buffer out -- matching how `gzcli.zig`/`std.compress.flate`
//! are used elsewhere in this port (DESIGN.md's "read the whole compressed input into
//! memory, decode into a growable output buffer" compression-engine shape). No
//! `std.fs`, no `std.Io.Threaded`/`std.Io.File` -- just the passed-in allocator and
//! plain slices, so this can ship inside a size-constrained wasm box later.
//!
//! ## Format, in brief
//!
//! `BZh<1-9>` header (block size in 100kB units) followed by one or more blocks, each
//! prefixed by a 48-bit magic (`0x314159265359`, pi's digits) or, for the very last
//! "block", a 48-bit end-of-stream magic (`0x177245385090`, sqrt(pi)'s digits)
//! immediately followed by the 32-bit combined stream CRC. Each real block carries: its
//! own 32-bit CRC, a "randomised" flag (legacy, unsupported -- see below), a 24-bit BWT
//! `origPtr`, a used-symbol bitmap, 2-6 canonical-Huffman tables whose code lengths are
//! delta-coded, an MTF-selector list (itself MTF-coded) picking a table every 50
//! symbols, an MTF+RLE2-coded symbol stream (`RUNA`/`RUNB` bijective-binary run-lengths
//! of post-MTF zero plus literal MTF ranks plus `EOB`), an inverse-BWT pass, and
//! finally bzip2's outer RLE1 stage (any run of 4 identical bytes is followed by a
//! count byte giving 0-251 *additional* repeats).
//!
//! ## Deviations from the reference crate
//!
//! * **Stream concatenation IS supported here**, even though `bzip2-rs`'s `Decoder`
//!   never looks for a second `BZh` header: once it hits the end-of-stream marker,
//!   `self.eof` latches `true` and every later `read()` call returns `Eof` regardless
//!   of what's left in `in_buf` (see `decoder/mod.rs`'s `read`/`write`). Real `bzip2`
//!   output is routinely multistream (`cat a.bz2 b.bz2 > both.bz2` is a documented,
//!   supported idiom the real `bzip2`/`bunzip2` CLI decodes transparently), and it's
//!   cheap to support: after a stream's trailer CRC, round up to the next byte boundary
//!   and try to parse another `BZh` header; if what follows doesn't look like one (or
//!   there's nothing left), stop silently rather than erroring -- matching the real
//!   `bzip2` CLI's lenient treatment of trailing garbage after a complete stream.
//! * **The combined stream CRC IS verified here**, even though `bzip2-rs` reads the
//!   trailing 32-bit CRC and explicitly throws it away (`block/mod.rs`:
//!   `// TODO: check whole stream crc`). We implement the standard bzip2 combining
//!   formula (used by the actual `bzlib.c`, and stated in the task brief this ports
//!   from): `combined = rotl(combined, 1) ^ block_crc`, folded in once per block, and
//!   compare the result against the stream trailer, surfacing a mismatch as
//!   `error.ChecksumMismatch`.
//! * **Randomized blocks are NOT supported**, matching the reference crate exactly: it
//!   reads the one-bit "randomised" flag and unconditionally errors if it's set
//!   (`block/mod.rs`: `"randomised expected to be 'normal'"` -- no derandomization
//!   table is implemented there either). Real encoders haven't set this bit in decades
//!   (it was an experimental early-bzip2 feature that was later removed from the
//!   encoder entirely), so we surface `error.RandomizedBlocksUnsupported` up front
//!   rather than inventing a derandomization table the oracle crate itself lacks.
//! * Huffman decode tables use the classic `limit`/`base`/`perm` canonical-Huffman
//!   construction (the same algorithm the original C `bzlib.c` uses) instead of
//!   porting `huffman.rs`'s 32-bit-fixed-point bit-trie approach. Both build a correct
//!   canonical Huffman decoder from the same code-length array and decode identically
//!   for any conformant bitstream; the array-based form needs no per-symbol tree-node
//!   allocation and is simpler to verify against the bzip2 format's plain-English spec.

const std = @import("std");

pub const Error = error{
    /// Not a bzip2 stream: missing `BZh` signature or unsupported version byte.
    BadMagic,
    /// The header's block-size digit wasn't `1`-`9`.
    UnsupportedBlockSize,
    /// Malformed bitstream: bad block magic, out-of-range Huffman/selector/MTF data,
    /// a block that decodes past its declared size, or the input ends mid-block.
    CorruptData,
    /// A block or whole-stream CRC didn't match.
    ChecksumMismatch,
    /// The block's "randomised" bit was set; real-world encoders never do this and
    /// the reference decoder doesn't implement derandomization either.
    RandomizedBlocksUnsupported,
    OutOfMemory,
};

const BLOCK_MAGIC: u64 = 0x314159265359;
const FINAL_MAGIC: u64 = 0x177245385090;

/// Largest possible Huffman alphabet: up to 256 used byte values plus RUNA/RUNB/EOB.
const MAX_ALPHABET: usize = 258;
/// Headroom above the format's hard cap of 20 bits per Huffman code.
const MAX_CODE_LEN: usize = 24;

/// Decodes a complete (possibly multi-stream-concatenated) bzip2 byte stream. Returns
/// a `gpa`-owned slice of the decompressed bytes.
pub fn decompress(gpa: std.mem.Allocator, input: []const u8) Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    var offset: usize = 0;
    var any_stream = false;

    while (true) {
        if (offset + 4 > input.len) {
            if (!any_stream) return Error.BadMagic;
            break;
        }
        if (input[offset] != 'B' or input[offset + 1] != 'Z' or input[offset + 2] != 'h') {
            if (!any_stream) return Error.BadMagic;
            break;
        }
        const digit = input[offset + 3];
        if (digit < '1' or digit > '9') {
            if (!any_stream) return Error.UnsupportedBlockSize;
            break;
        }
        const max_blocksize: u32 = 100_000 * @as(u32, digit - '0');
        offset += 4;

        var br = BitReader{ .bytes = input[offset..] };
        var combined_crc: u32 = 0;

        while (true) {
            const magic = try br.readBits(u64, 48);
            if (magic == BLOCK_MAGIC) {
                const block_crc = try decodeBlock(gpa, &br, max_blocksize, &out);
                combined_crc = std.math.rotl(u32, combined_crc, @as(u32, 1)) ^ block_crc;
            } else if (magic == FINAL_MAGIC) {
                const stream_crc = try br.readBits(u32, 32);
                if (stream_crc != combined_crc) return Error.ChecksumMismatch;
                break;
            } else {
                return Error.CorruptData;
            }
        }

        any_stream = true;
        offset += (br.bit_pos + 7) / 8;
    }

    return out.toOwnedSlice(gpa);
}

/// MSB-first bit reader over a plain byte slice (mirrors `bitreader.rs`'s `BitReader`,
/// minus its 64-bit "cached" fast path -- correctness and readability over speed, per
/// the task brief).
const BitReader = struct {
    bytes: []const u8,
    bit_pos: usize = 0,

    fn readBit(self: *BitReader) Error!u1 {
        const byte_idx = self.bit_pos >> 3;
        if (byte_idx >= self.bytes.len) return Error.CorruptData;
        const bit_idx: u3 = @intCast(7 - (self.bit_pos & 7));
        const bit: u1 = @intCast((self.bytes[byte_idx] >> bit_idx) & 1);
        self.bit_pos += 1;
        return bit;
    }

    fn readBool(self: *BitReader) Error!bool {
        return (try self.readBit()) == 1;
    }

    fn readBits(self: *BitReader, comptime T: type, n_bits: usize) Error!T {
        var value: T = 0;
        var i: usize = 0;
        while (i < n_bits) : (i += 1) {
            value = (value << 1) | @as(T, try self.readBit());
        }
        return value;
    }
};

/// A canonical-Huffman decode table built from a code-length array, using the same
/// `limit`/`base`/`perm` construction as the reference bzip2 C implementation
/// (`bzlib.c`'s `BZ2_hbCreateDecodeTables`) -- see the module doc comment for why this
/// (rather than `huffman.rs`'s bit-trie) was chosen.
const HuffmanTable = struct {
    perm: [MAX_ALPHABET]u16 = undefined,
    perm_len: u16 = 0,
    limit: [MAX_CODE_LEN]i32 = [_]i32{0} ** MAX_CODE_LEN,
    base: [MAX_CODE_LEN]i32 = [_]i32{0} ** MAX_CODE_LEN,
    min_len: u8 = 0,
    max_len: u8 = 0,

    fn build(lengths: []const u8) Error!HuffmanTable {
        var self: HuffmanTable = .{};

        var min_len: u8 = 255;
        var max_len: u8 = 0;
        for (lengths) |l| {
            if (l < 1 or l > 20) return Error.CorruptData;
            if (l < min_len) min_len = l;
            if (l > max_len) max_len = l;
        }
        self.min_len = min_len;
        self.max_len = max_len;

        // perm: symbol indices ordered by ascending code length, ties broken by
        // ascending symbol index (this is the standard canonical-Huffman symbol
        // order -- it's what makes the `base`/`limit` walk below correct).
        var pp: u16 = 0;
        var bl: u8 = min_len;
        while (bl <= max_len) : (bl += 1) {
            for (lengths, 0..) |l, idx| {
                if (l == bl) {
                    self.perm[pp] = @intCast(idx);
                    pp += 1;
                }
            }
        }
        self.perm_len = pp;

        for (lengths) |l| self.base[l + 1] += 1;
        var i: usize = 1;
        while (i < MAX_CODE_LEN) : (i += 1) self.base[i] += self.base[i - 1];

        var vec: i32 = 0;
        bl = min_len;
        while (bl <= max_len) : (bl += 1) {
            vec += self.base[bl + 1] - self.base[bl];
            self.limit[bl] = vec - 1;
            vec <<= 1;
        }
        bl = min_len + 1;
        while (bl <= max_len) : (bl += 1) {
            self.base[bl] = ((self.limit[bl - 1] + 1) << 1) - self.base[bl];
        }

        return self;
    }

    fn decode(self: *const HuffmanTable, br: *BitReader) Error!u16 {
        var n: u8 = self.min_len;
        var code: i32 = @intCast(try br.readBits(u32, n));
        while (true) {
            if (n > self.max_len) return Error.CorruptData;
            if (code <= self.limit[n]) break;
            n += 1;
            code = (code << 1) | @as(i32, try br.readBit());
        }
        const idx = code - self.base[n];
        if (idx < 0 or idx >= @as(i32, self.perm_len)) return Error.CorruptData;
        return self.perm[@intCast(idx)];
    }
};

/// Move-to-front decoder over the full byte alphabet (mirrors `move_to_front.rs`).
/// Used both for the tree-selector list and for the block's literal MTF symbols.
const MoveToFront = struct {
    symbols: [256]u8 = undefined,

    fn init() MoveToFront {
        var self: MoveToFront = .{};
        for (&self.symbols, 0..) |*s, i| s.* = @intCast(i);
        return self;
    }

    fn initFromSymbols(used: []const u8) MoveToFront {
        var self: MoveToFront = .{ .symbols = [_]u8{0} ** 256 };
        @memcpy(self.symbols[0..used.len], used);
        return self;
    }

    fn decode(self: *MoveToFront, n: u8) u8 {
        const b = self.symbols[n];
        var i: usize = n;
        while (i > 0) : (i -= 1) self.symbols[i] = self.symbols[i - 1];
        self.symbols[0] = b;
        return b;
    }

    fn first(self: *const MoveToFront) u8 {
        return self.symbols[0];
    }
};

/// Linear-time inverse Burrows-Wheeler Transform via counting sort + "T-vector"
/// next-pointer construction (mirrors `block/bwt.rs::inverse_bwt`). `tt` holds, per
/// index, a byte value in its low 8 bits; on return each `tt[j]`'s upper bits hold the
/// index of the next element in original-string order, and the returned value is
/// where to start walking from.
fn inverseBwt(tt: []u32, orig_ptr: usize, c: *[256]u32) usize {
    var sum: u32 = 0;
    for (c) |*ci| {
        const old = ci.*;
        ci.* = sum;
        sum += old;
    }

    var i: usize = 0;
    while (i < tt.len) : (i += 1) {
        const b: usize = tt[i] & 0xff;
        tt[c[b]] |= @as(u32, @intCast(i)) << 8;
        c[b] += 1;
    }

    return @intCast(tt[orig_ptr] >> 8);
}

/// Decodes one block (the bitstream just past its `BLOCK_MAGIC`), appends its final
/// (post-RLE1) bytes to `out`, verifies the block's own CRC, and returns that CRC so
/// the caller can fold it into the whole-stream combined CRC.
fn decodeBlock(
    gpa: std.mem.Allocator,
    br: *BitReader,
    max_blocksize: u32,
    out: *std.ArrayListUnmanaged(u8),
) Error!u32 {
    const expected_crc: u32 = try br.readBits(u32, 32);

    if (try br.readBool()) return Error.RandomizedBlocksUnsupported;

    const orig_ptr: u32 = try br.readBits(u32, 24);

    var range_used: [16]bool = undefined;
    for (&range_used) |*r| r.* = try br.readBool();

    var symbol_map: [256]u8 = undefined;
    var num_symbols: usize = 0;
    for (range_used, 0..) |present, ri| {
        if (!present) continue;
        var si: usize = 0;
        while (si < 16) : (si += 1) {
            if (try br.readBool()) {
                symbol_map[num_symbols] = @intCast(ri * 16 + si);
                num_symbols += 1;
            }
        }
    }
    if (num_symbols == 0) return Error.CorruptData;

    const alphabet_size = num_symbols + 2;

    const num_tables = try br.readBits(u8, 3);
    if (num_tables < 2 or num_tables > 6) return Error.CorruptData;

    const num_selectors = try br.readBits(u16, 15);
    const selectors = try gpa.alloc(u8, num_selectors);
    defer gpa.free(selectors);

    {
        var mtf_sel = MoveToFront.init();
        for (selectors) |*sel| {
            var trees: u8 = 0;
            while (try br.readBool()) {
                trees += 1;
                if (trees >= num_tables) return Error.CorruptData;
            }
            sel.* = mtf_sel.decode(trees);
        }
    }

    var tables: [6]HuffmanTable = undefined;
    var lengths: [MAX_ALPHABET]u8 = undefined;

    var ti: usize = 0;
    while (ti < num_tables) : (ti += 1) {
        var length: i32 = @intCast(try br.readBits(u8, 5));
        var si: usize = 0;
        while (si < alphabet_size) : (si += 1) {
            while (true) {
                if (length < 1 or length > 20) return Error.CorruptData;
                if (!(try br.readBool())) break;
                if (try br.readBool()) {
                    length -= 1;
                } else {
                    length += 1;
                }
            }
            lengths[si] = @intCast(length);
        }
        tables[ti] = try HuffmanTable.build(lengths[0..alphabet_size]);
    }

    if (selectors.len == 0) return Error.CorruptData;
    if (selectors[0] >= num_tables) return Error.CorruptData;
    var current_table: *const HuffmanTable = &tables[selectors[0]];
    var sel_idx: usize = 1;

    const tt = try gpa.alloc(u32, max_blocksize);
    defer gpa.free(tt);
    var tt_len: usize = 0;
    var c: [256]u32 = [_]u32{0} ** 256;

    var mtf2 = MoveToFront.initFromSymbols(symbol_map[0..num_symbols]);

    var decoded_in_group: u32 = 0;
    var repeat: u32 = 0;
    var repeat_power: u32 = 0;
    const eob_symbol: u16 = @intCast(alphabet_size - 1);

    while (true) {
        if (decoded_in_group == 50) {
            if (sel_idx >= selectors.len) return Error.CorruptData;
            if (selectors[sel_idx] >= num_tables) return Error.CorruptData;
            current_table = &tables[selectors[sel_idx]];
            sel_idx += 1;
            decoded_in_group = 0;
        }

        const v = try current_table.decode(br);
        decoded_in_group += 1;

        if (v < 2) {
            if (repeat == 0) repeat_power = 1;
            repeat += repeat_power << @as(u5, @intCast(v));
            repeat_power <<= 1;
            if (repeat > 2 * 1024 * 1024) return Error.CorruptData;
            continue;
        }

        if (repeat > 0) {
            if (repeat > max_blocksize - @as(u32, @intCast(tt_len))) return Error.CorruptData;
            const b: u32 = mtf2.first();
            var k: u32 = 0;
            while (k < repeat) : (k += 1) {
                tt[tt_len] = b;
                tt_len += 1;
            }
            c[b] += repeat;
            repeat = 0;
        }

        if (v == eob_symbol) break;

        const b: u32 = mtf2.decode(@intCast(v - 1));
        if (tt_len >= max_blocksize) return Error.CorruptData;
        tt[tt_len] = b;
        tt_len += 1;
        c[b] += 1;
    }

    if (orig_ptr >= tt_len) return Error.CorruptData;

    var t_pos = inverseBwt(tt[0..tt_len], orig_ptr, &c);

    const block_start = out.items.len;
    var last_byte: i16 = -1;
    var byte_repeats: u8 = 0;
    var repeats_out: u8 = 0;
    var pre_rle_used: usize = 0;

    while (repeats_out > 0 or pre_rle_used < tt_len) {
        if (repeats_out > 0) {
            try out.append(gpa, @intCast(last_byte));
            repeats_out -= 1;
            if (repeats_out == 0) last_byte = -1;
            continue;
        }

        const word = tt[t_pos];
        const b: u8 = @intCast(word & 0xff);
        t_pos = word >> 8;
        pre_rle_used += 1;

        if (byte_repeats == 3) {
            repeats_out = b;
            byte_repeats = 0;
            continue;
        }

        if (last_byte == @as(i16, b)) byte_repeats += 1 else byte_repeats = 0;
        last_byte = b;

        try out.append(gpa, b);
    }

    var hasher = std.hash.crc.Crc32Bzip2.init();
    hasher.update(out.items[block_start..]);
    const actual_crc = hasher.final();
    if (actual_crc != expected_crc) return Error.ChecksumMismatch;

    return actual_crc;
}
