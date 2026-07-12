//! Codec engine (DESIGN.md §7.4): RFc4648 base16/base32/base32hex/base64/base64url,
//! base2 (both bit orders), Z85, and Base58 -- ported from uutils 0.9.0's
//! `uucore::encoding` + `uu_base32::base_common` (see DESIGN.md §1
//! "base32/base64/basenc"). The oracle
//! (`reference/uutils-coreutils/target/release/coreutils`) is the byte-parity target.
//!
//! Design note (deliberate simplification vs. the Rust source): the Rust side streams
//! input in `unpadded_multiple*1024`-byte chunks to bound memory; nutils applets read
//! the whole operand into memory first (corpus inputs are small, and every output byte
//! sequence is stream-order-invariant for encode, and for decode differs from a
//! whole-buffer approach only in exactly how much partial output is flushed before an
//! `error: invalid input` abort on a very large input -- a distinction irrelevant at
//! corpus scale). This keeps the state machine here linear and easy to verify against
//! the oracle, at the cost of true O(1)-memory streaming for huge inputs. Ledger note:
//! if this ever needs revisiting for multi-GB inputs, see DESIGN.md §2.
//!
//! Both RFC 4648 families (base16/32/32hex/64/64url) share one bit-packing core
//! (`bitsPerChar`); base2lsbf/msbf pack 1 bit per byte with an explicit bit order;
//! Z85 and Base58 are hand-rolled per their own (non-power-of-two) schemes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("../sys/root.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub const Format = enum {
    base16,
    base32,
    base32hex,
    base64,
    base64url,
    base2lsbf,
    base2msbf,
    z85,
    base58,
};

pub const CodecError = error{ InvalidInput, InvalidZ85Input } || Allocator.Error;

pub const DEFAULT_WRAP: usize = 76;

// ============================================================================
// Alphabets (decode alphabet excludes '='; encode adds '=' padding separately).
// ============================================================================

const ALPHA_BASE16 = "0123456789ABCDEF";
const ALPHA_BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
const ALPHA_BASE32HEX = "0123456789ABCDEFGHIJKLMNOPQRSTUV";
const ALPHA_BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const ALPHA_BASE64URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const ALPHA_Z85 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#";
const ALPHA_BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

const RfcSpec = struct { bits: u4, alphabet: []const u8, pad: bool };

fn rfcSpec(format: Format) ?RfcSpec {
    return switch (format) {
        .base16 => .{ .bits = 4, .alphabet = ALPHA_BASE16, .pad = false },
        .base32 => .{ .bits = 5, .alphabet = ALPHA_BASE32, .pad = true },
        .base32hex => .{ .bits = 5, .alphabet = ALPHA_BASE32HEX, .pad = true },
        .base64 => .{ .bits = 6, .alphabet = ALPHA_BASE64, .pad = true },
        .base64url => .{ .bits = 6, .alphabet = ALPHA_BASE64URL, .pad = true },
        else => null,
    };
}

/// Bytes per encode "unpadded" group (uucore's `unpadded_multiple`): input lengths that
/// are a multiple of this produce output with no `=` padding.
pub fn unpaddedMultiple(format: Format) usize {
    return switch (format) {
        .base16, .base2lsbf, .base2msbf => 1,
        .base32, .base32hex => 5,
        .base64, .base64url => 3,
        .z85 => 4,
        .base58 => std.math.maxInt(usize) / 2048, // whole-buffer; never chunk-bounded
    };
}

/// Chars per full decode block (uucore's `valid_decoding_multiple`).
pub fn validDecodingMultiple(format: Format) usize {
    return switch (format) {
        .base16 => 2,
        .base2lsbf, .base2msbf => 8,
        .base32, .base32hex => 8,
        .base64, .base64url => 4,
        .z85 => 5,
        .base58 => 1,
    };
}

/// The accepted alphabet for the "skip \\r\\n, validate every other byte" pass (`=` is
/// always included for formats that pad -- it is a legal in-alphabet byte at any
/// position during the raw scan, matching uutils' `alphabet()` which appends `=`).
pub fn decodeAlphabet(format: Format) []const u8 {
    return switch (format) {
        .base16 => ALPHA_BASE16 ++ "abcdef=",
        .base32 => ALPHA_BASE32 ++ "=",
        .base32hex => ALPHA_BASE32HEX ++ "=",
        .base64 => ALPHA_BASE64 ++ "=",
        .base64url => ALPHA_BASE64URL ++ "=",
        .base2lsbf, .base2msbf => "01",
        .z85 => ALPHA_Z85,
        .base58 => ALPHA_BASE58,
    };
}

fn buildRevTable(alphabet: []const u8) [256]i16 {
    var t: [256]i16 = [_]i16{-1} ** 256;
    for (alphabet, 0..) |c, i| t[c] = @intCast(i);
    return t;
}

fn buildAcceptTable(alphabet: []const u8) [256]bool {
    var t: [256]bool = [_]bool{false} ** 256;
    for (alphabet) |c| t[c] = true;
    return t;
}

// ============================================================================
// Generic RFC 4648 bit-packing encode/decode (MSB-first within the byte stream, the
// standard convention shared by base16/32/32hex/64/64url).
// ============================================================================

fn charsPerBlock(bits: u4) usize {
    return switch (bits) {
        4 => 2,
        5 => 8,
        6 => 4,
        else => unreachable,
    };
}

fn rfcEncode(gpa: Allocator, spec: RfcSpec, input: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(gpa);
    var acc: u64 = 0;
    var acc_bits: u6 = 0;
    const mask: u64 = (@as(u64, 1) << spec.bits) - 1;
    for (input) |byte| {
        acc = (acc << 8) | byte;
        acc_bits += 8;
        while (acc_bits >= spec.bits) {
            const shift: u6 = acc_bits - spec.bits;
            const idx: usize = @intCast((acc >> shift) & mask);
            try out.append(gpa, spec.alphabet[idx]);
            acc_bits -= spec.bits;
        }
        if (acc_bits > 0) acc &= (@as(u64, 1) << acc_bits) - 1;
    }
    if (acc_bits > 0) {
        const idx: usize = @intCast((acc << (spec.bits - acc_bits)) & mask);
        try out.append(gpa, spec.alphabet[idx]);
    }
    if (spec.pad) {
        const cpb = charsPerBlock(spec.bits);
        const rem = out.items.len % cpb;
        if (rem != 0) {
            var i: usize = rem;
            while (i < cpb) : (i += 1) try out.append(gpa, '=');
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Decodes a run of alphabet characters (== NOT present -- caller strips it) that is
/// already known to be a whole number of decode blocks (or the accepted RFC4648
/// unpadded tail). Returns `error.InvalidInput` if trailing bits beyond the last whole
/// byte are non-zero (GNU/data-encoding reject non-canonical padding bits -- verified
/// against the oracle: e.g. `printf aGVsbG | base64 -d` errors because the dangling 4
/// bits are `0110`, not zero, while `aGVsbA` with the same length succeeds).
fn rfcDecode(gpa: Allocator, spec: RfcSpec, rev: *const [256]i16, chars: []const u8) CodecError![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(gpa);
    var acc: u64 = 0;
    var acc_bits: u6 = 0;
    for (chars) |c| {
        const v = rev[c];
        std.debug.assert(v >= 0);
        acc = (acc << spec.bits) | @as(u64, @intCast(v));
        acc_bits += spec.bits;
        if (acc_bits >= 8) {
            const shift: u6 = acc_bits - 8;
            try out.append(gpa, @intCast((acc >> shift) & 0xff));
            acc_bits -= 8;
            acc &= (@as(u64, 1) << acc_bits) - 1;
        }
    }
    if (acc_bits > 0 and acc != 0) return CodecError.InvalidInput;
    return out.toOwnedSlice(gpa);
}

// ============================================================================
// base2lsbf/msbf: 1 bit per input byte, whole bytes (no cross-byte bit order
// ambiguity since 8 bits divides evenly with no remainder).
// ============================================================================

fn base2Encode(gpa: Allocator, input: []const u8, lsbf: bool) ![]u8 {
    var out = try gpa.alloc(u8, input.len * 8);
    for (input, 0..) |byte, i| {
        var bit_i: usize = 0;
        while (bit_i < 8) : (bit_i += 1) {
            const shift: u3 = if (lsbf) @intCast(bit_i) else @intCast(7 - bit_i);
            out[i * 8 + bit_i] = if ((byte >> shift) & 1 == 1) '1' else '0';
        }
    }
    return out;
}

fn base2Decode(gpa: Allocator, chars: []const u8, lsbf: bool) ![]u8 {
    std.debug.assert(chars.len % 8 == 0);
    var out = try gpa.alloc(u8, chars.len / 8);
    var byte_i: usize = 0;
    while (byte_i < out.len) : (byte_i += 1) {
        var b: u8 = 0;
        var bit_i: usize = 0;
        while (bit_i < 8) : (bit_i += 1) {
            const bit: u8 = if (chars[byte_i * 8 + bit_i] == '1') 1 else 0;
            const shift: u3 = if (lsbf) @intCast(bit_i) else @intCast(7 - bit_i);
            b |= bit << shift;
        }
        out[byte_i] = b;
    }
    return out;
}

// ============================================================================
// Z85 (ZeroMQ RFC 32): 4-byte groups <-> 5-char groups, base-85 big-endian.
// ============================================================================

fn z85Encode(gpa: Allocator, input: []const u8) CodecError![]u8 {
    if (input.len % 4 != 0) return CodecError.InvalidZ85Input;
    var out = try gpa.alloc(u8, (input.len / 4) * 5);
    var gi: usize = 0;
    while (gi < input.len) : (gi += 4) {
        var value: u32 = 0;
        value = (value << 8) | input[gi];
        value = (value << 8) | input[gi + 1];
        value = (value << 8) | input[gi + 2];
        value = (value << 8) | input[gi + 3];
        const oi = (gi / 4) * 5;
        var j: usize = 0;
        var v = value;
        var digits: [5]u8 = undefined;
        while (j < 5) : (j += 1) {
            digits[4 - j] = ALPHA_Z85[v % 85];
            v /= 85;
        }
        @memcpy(out[oi..][0..5], &digits);
    }
    return out;
}

fn z85Decode(gpa: Allocator, rev: *const [256]i16, chars: []const u8) CodecError![]u8 {
    if (chars.len % 5 != 0) return CodecError.InvalidInput;
    var out = try gpa.alloc(u8, (chars.len / 5) * 4);
    var gi: usize = 0;
    while (gi < chars.len) : (gi += 5) {
        var value: u64 = 0;
        var j: usize = 0;
        while (j < 5) : (j += 1) {
            const v = rev[chars[gi + j]];
            if (v < 0) return CodecError.InvalidInput;
            value = value * 85 + @as(u64, @intCast(v));
        }
        if (value > std.math.maxInt(u32)) return CodecError.InvalidInput;
        const oi = (gi / 5) * 4;
        out[oi] = @intCast((value >> 24) & 0xff);
        out[oi + 1] = @intCast((value >> 16) & 0xff);
        out[oi + 2] = @intCast((value >> 8) & 0xff);
        out[oi + 3] = @intCast(value & 0xff);
    }
    return out;
}

// ============================================================================
// Base58 (Bitcoin alphabet): whole-buffer big-integer base conversion, u32-limb
// bignum (little-endian limbs), with leading-zero-byte <-> leading-'1' preservation.
// ============================================================================

fn base58Encode(gpa: Allocator, input: []const u8) ![]u8 {
    if (input.len == 0) return gpa.alloc(u8, 0);
    var leading_zeros: usize = 0;
    while (leading_zeros < input.len and input[leading_zeros] == 0) leading_zeros += 1;
    const trimmed = input[leading_zeros..];
    if (trimmed.len == 0) {
        const out = try gpa.alloc(u8, leading_zeros);
        @memset(out, '1');
        return out;
    }

    var num = std.ArrayListUnmanaged(u32).empty;
    defer num.deinit(gpa);
    for (trimmed) |byte| {
        var carry: u64 = byte;
        for (num.items) |*limb| {
            const tmp = @as(u64, limb.*) * 256 + carry;
            limb.* = @truncate(tmp);
            carry = tmp >> 32;
        }
        if (carry > 0) try num.append(gpa, @truncate(carry));
    }

    var digits = std.ArrayListUnmanaged(u8).empty;
    defer digits.deinit(gpa);
    while (num.items.len > 0) {
        var carry: u64 = 0;
        var all_zero = true;
        var i: usize = num.items.len;
        while (i > 0) {
            i -= 1;
            const tmp = carry * (@as(u64, 1) << 32) + num.items[i];
            num.items[i] = @truncate(tmp / 58);
            carry = tmp % 58;
            if (num.items[i] != 0) all_zero = false;
        }
        try digits.append(gpa, ALPHA_BASE58[@intCast(carry)]);
        if (all_zero) break;
        while (num.items.len > 1 and num.items[num.items.len - 1] == 0) _ = num.pop();
    }

    var out = try gpa.alloc(u8, leading_zeros + digits.items.len);
    @memset(out[0..leading_zeros], '1');
    for (digits.items, 0..) |d, i| out[leading_zeros + digits.items.len - 1 - i] = d;
    return out;
}

fn base58Decode(gpa: Allocator, rev: *const [256]i16, chars: []const u8) CodecError![]u8 {
    if (chars.len == 0) return gpa.alloc(u8, 0);
    var leading_ones: usize = 0;
    while (leading_ones < chars.len and chars[leading_ones] == '1') leading_ones += 1;
    const trimmed = chars[leading_ones..];
    if (trimmed.len == 0) {
        const out = try gpa.alloc(u8, leading_ones);
        @memset(out, 0);
        return out;
    }

    var num = std.ArrayListUnmanaged(u32).empty;
    defer num.deinit(gpa);
    try num.append(gpa, 0);
    for (trimmed) |c| {
        const digit = rev[c];
        if (digit < 0) return CodecError.InvalidInput;
        var carry: u64 = @intCast(digit);
        for (num.items) |*limb| {
            const tmp = @as(u64, limb.*) * 58 + carry;
            limb.* = @truncate(tmp);
            carry = tmp >> 32;
        }
        if (carry > 0) try num.append(gpa, @truncate(carry));
    }

    var bytes = std.ArrayListUnmanaged(u8).empty;
    defer bytes.deinit(gpa);
    for (num.items) |limb| {
        try bytes.append(gpa, @truncate(limb));
        try bytes.append(gpa, @truncate(limb >> 8));
        try bytes.append(gpa, @truncate(limb >> 16));
        try bytes.append(gpa, @truncate(limb >> 24));
    }
    while (bytes.items.len > 1 and bytes.items[bytes.items.len - 1] == 0) _ = bytes.pop();

    var out = try gpa.alloc(u8, leading_ones + bytes.items.len);
    @memset(out[0..leading_ones], 0);
    for (bytes.items, 0..) |b, i| out[leading_ones + bytes.items.len - 1 - i] = b;
    return out;
}

// ============================================================================
// Public encode/decode entry points.
// ============================================================================

/// Encodes `input`, no line wrapping applied (callers wrap via `wrapAlloc`).
pub fn encodeAlloc(gpa: Allocator, format: Format, input: []const u8) CodecError![]u8 {
    if (rfcSpec(format)) |spec| return rfcEncode(gpa, spec, input);
    return switch (format) {
        .base2lsbf => base2Encode(gpa, input, true),
        .base2msbf => base2Encode(gpa, input, false),
        .z85 => z85Encode(gpa, input),
        .base58 => base58Encode(gpa, input),
        else => unreachable,
    };
}

pub const DecodeOutcome = struct {
    /// Bytes to write to stdout regardless of `invalid` (GNU flushes whatever was
    /// already decodable before reporting an error).
    bytes: []u8,
    /// If true, the caller must print `error: invalid input` to stderr and return
    /// exit 1 after writing `bytes`.
    invalid: bool,
};

/// Decodes `input`: strips `\r`/`\n`, validates every other byte against the format's
/// alphabet (skipping non-alphabet bytes when `ignore_garbage`, else stopping and
/// reporting `invalid = true`), then decodes as much of the accepted prefix as
/// possible. Base32/base32hex additionally apply uutils' `pad_remainder` tail handling
/// (RFC 4648 unpadded tails of length 2/4/5/7 are accepted silently; other lengths are
/// trimmed to the nearest accepted length, the trimmed prefix is still decoded and
/// written, and `invalid` is set).
pub fn decodeAlloc(gpa: Allocator, format: Format, input: []const u8, ignore_garbage: bool) CodecError!DecodeOutcome {
    const accept = comptime blk: {
        var tables: [9][256]bool = undefined;
        for (@typeInfo(Format).@"enum".fields, 0..) |f, i| {
            tables[i] = buildAcceptTable(decodeAlphabet(@enumFromInt(f.value)));
        }
        break :blk tables;
    };
    const accept_table = &accept[@intFromEnum(format)];

    var chars = std.ArrayListUnmanaged(u8).empty;
    defer chars.deinit(gpa);
    var invalid = false;
    for (input) |b| {
        if (b == '\n' or b == '\r') continue;
        if (accept_table[b]) {
            try chars.append(gpa, b);
        } else if (ignore_garbage) {
            continue;
        } else {
            invalid = true;
            break;
        }
    }

    return decodeCharsAlloc(gpa, format, chars.items, invalid);
}

fn decodeCharsAlloc(gpa: Allocator, format: Format, chars: []u8, hit_invalid_byte: bool) CodecError!DecodeOutcome {
    switch (format) {
        .base32, .base32hex => return decodeBase32Family(gpa, format, chars, hit_invalid_byte),
        .base58 => {
            const rev = comptime buildRevTable(ALPHA_BASE58);
            // Base58 has no padding/remainder concept (valid_decoding_multiple == 1);
            // any prefix decodes. On a mid-stream invalid byte, nothing gets flushed
            // early at corpus scale (see module doc), matching the oracle for small
            // inputs.
            if (hit_invalid_byte) return .{ .bytes = try gpa.alloc(u8, 0), .invalid = true };
            const bytes = try base58Decode(gpa, &rev, chars);
            return .{ .bytes = bytes, .invalid = false };
        },
        .z85 => {
            const rev = comptime buildRevTable(ALPHA_Z85);
            if (hit_invalid_byte) return .{ .bytes = try gpa.alloc(u8, 0), .invalid = true };
            const bytes = z85Decode(gpa, &rev, chars) catch {
                return .{ .bytes = try gpa.alloc(u8, 0), .invalid = true };
            };
            return .{ .bytes = bytes, .invalid = false };
        },
        .base2lsbf, .base2msbf => {
            const usable = chars.len - (chars.len % 8);
            const bytes = try base2Decode(gpa, chars[0..usable], format == .base2lsbf);
            const bad = hit_invalid_byte or usable != chars.len;
            return .{ .bytes = bytes, .invalid = bad };
        },
        .base16 => {
            const rev = comptime buildRevTable(ALPHA_BASE16 ++ "abcdef");
            const spec = rfcSpec(format).?;
            const usable = chars.len - (chars.len % 2);
            const bytes = rfcDecode(gpa, spec, &rev, upperize(chars[0..usable])) catch {
                return .{ .bytes = try gpa.alloc(u8, 0), .invalid = true };
            };
            const bad = hit_invalid_byte or usable != chars.len;
            return .{ .bytes = bytes, .invalid = bad };
        },
        .base64, .base64url => return decodeBase64Family(gpa, format, chars, hit_invalid_byte),
    }
}

/// base16's alphabet accepts lowercase on decode but the RFC4648 lookup table above is
/// built from the uppercase alphabet; fold lowercase hex digits up before indexing.
fn upperize(chars: []u8) []const u8 {
    // Safe to mutate: `chars` here is always our own freshly-collected `chars.items`
    // buffer, never the caller's `input`.
    for (chars) |*c| {
        if (c.* >= 'a' and c.* <= 'f') c.* -= 32;
    }
    return chars;
}

const VALID_BASE32_REMAINDERS = [_]usize{ 2, 4, 5, 7 };

fn decodeBase32Family(gpa: Allocator, format: Format, chars: []const u8, hit_invalid_byte: bool) CodecError!DecodeOutcome {
    const spec = rfcSpec(format).?;
    const rev_table = comptime blk: {
        var tables: [2][256]i16 = undefined;
        tables[0] = buildRevTable(ALPHA_BASE32);
        tables[1] = buildRevTable(ALPHA_BASE32HEX);
        break :blk tables;
    };
    const rev = if (format == .base32) &rev_table[0] else &rev_table[1];

    // Strip any '=' the accept-scan let through (they're part of the alphabet table
    // only so a trailing `=` isn't treated as garbage); real padding chars carry no
    // information for the bit-packer.
    var stripped = std.ArrayListUnmanaged(u8).empty;
    defer stripped.deinit(gpa);
    for (chars) |c| {
        if (c != '=') try stripped.append(gpa, c);
    }
    const cs = stripped.items;

    if (hit_invalid_byte) {
        // Only whole 8-char blocks already accumulated get flushed before the error
        // (Base32Wrapper opts into partial-decode flushing in the Rust source).
        const usable = cs.len - (cs.len % 8);
        const bytes = rfcDecode(gpa, spec, rev, cs[0..usable]) catch return .{ .bytes = try gpa.alloc(u8, 0), .invalid = true };
        return .{ .bytes = bytes, .invalid = true };
    }

    const rem = cs.len % 8;
    if (rem == 0) {
        const bytes = rfcDecode(gpa, spec, rev, cs) catch return .{ .bytes = try gpa.alloc(u8, 0), .invalid = true };
        return .{ .bytes = bytes, .invalid = false };
    }

    // Trim the tail down to the nearest RFC4648-legal unpadded remainder length
    // (uucore's `pad_remainder`): {7,5,4,2} are accepted as-is; {1,3,6} get trimmed
    // further (down to 0 in the worst case) and flagged invalid, but whatever full
    // blocks (plus the trimmed legal tail) decode to IS still written.
    var take = cs.len - rem;
    var tail_len = rem;
    var trimmed = false;
    while (tail_len > 0 and !containsUsize(&VALID_BASE32_REMAINDERS, tail_len)) {
        tail_len -= 1;
        trimmed = true;
    }
    if (tail_len == 0) {
        // No legal tail at all: only the whole-block prefix decodes.
        const bytes = rfcDecode(gpa, spec, rev, cs[0..take]) catch return .{ .bytes = try gpa.alloc(u8, 0), .invalid = true };
        return .{ .bytes = bytes, .invalid = true };
    }
    take += tail_len;
    const bytes = rfcDecode(gpa, spec, rev, cs[0..take]) catch return .{ .bytes = try gpa.alloc(u8, 0), .invalid = true };
    return .{ .bytes = bytes, .invalid = trimmed };
}

fn containsUsize(hay: []const usize, needle: usize) bool {
    for (hay) |h| if (h == needle) return true;
    return false;
}

fn decodeBase64Family(gpa: Allocator, format: Format, chars: []const u8, hit_invalid_byte: bool) CodecError!DecodeOutcome {
    const spec = rfcSpec(format).?;
    const rev_table = comptime blk: {
        var tables: [2][256]i16 = undefined;
        tables[0] = buildRevTable(ALPHA_BASE64);
        tables[1] = buildRevTable(ALPHA_BASE64URL);
        break :blk tables;
    };
    const rev = if (format == .base64) &rev_table[0] else &rev_table[1];

    var stripped = std.ArrayListUnmanaged(u8).empty;
    defer stripped.deinit(gpa);
    for (chars) |c| {
        if (c != '=') try stripped.append(gpa, c);
    }
    const cs = stripped.items;

    if (hit_invalid_byte) {
        const usable = cs.len - (cs.len % 4);
        const bytes = rfcDecode(gpa, spec, rev, cs[0..usable]) catch return .{ .bytes = try gpa.alloc(u8, 0), .invalid = true };
        return .{ .bytes = bytes, .invalid = true };
    }

    // base64/base64url require an exact multiple of 4 chars once padding is
    // stripped -- a remainder of 1 is never decodable and 2/3 are only decodable
    // when the source truly ended there (no partial-block leniency the way base32
    // has); this matches the oracle (`aGVsbG8` (7, mod4=3) OK, arbitrary internal
    // mod4=2/3 truncations are format errors caught by trailing-bit validation in
    // `rfcDecode`).
    if (cs.len % 4 == 1) {
        const usable = cs.len - 1;
        const bytes = rfcDecode(gpa, spec, rev, cs[0..usable]) catch return .{ .bytes = try gpa.alloc(u8, 0), .invalid = true };
        return .{ .bytes = bytes, .invalid = true };
    }
    const bytes = rfcDecode(gpa, spec, rev, cs) catch return .{ .bytes = try gpa.alloc(u8, 0), .invalid = true };
    return .{ .bytes = bytes, .invalid = false };
}

// ============================================================================
// Line wrapping (uucore's manual wrap -- applies to ALL formats' encode output,
// default 76 cols, `-w 0` disables). See module doc for the exact trailing-newline
// rules, verified against the oracle.
// ============================================================================

/// Returns the final byte sequence to write for encoded output: `encoded` with a `\n`
/// inserted every `wrap_cols` characters (`null` => default 76) and a trailing `\n`
/// UNLESS `wrap_cols == 0` (wrapping disabled: GNU emits no trailing newline at all in
/// that mode) or `encoded.len == 0` (nothing at all is written for empty input).
pub fn wrapAlloc(gpa: Allocator, encoded: []const u8, wrap_cols: ?usize) ![]u8 {
    if (encoded.len == 0) return gpa.alloc(u8, 0);
    const cols = wrap_cols orelse DEFAULT_WRAP;
    if (cols == 0) return gpa.dupe(u8, encoded);

    const lines = (encoded.len + cols - 1) / cols;
    var out = try gpa.alloc(u8, encoded.len + lines);
    var i: usize = 0;
    var o: usize = 0;
    while (i < encoded.len) {
        const take = @min(cols, encoded.len - i);
        @memcpy(out[o..][0..take], encoded[i..][0..take]);
        o += take;
        out[o] = '\n';
        o += 1;
        i += take;
    }
    std.debug.assert(o == out.len);
    return out;
}

// ============================================================================ tests

// ============================================================================
// Shared CLI I/O orchestration for base32/base64/basenc (DESIGN.md §3: "nothing
// imports an applet", so the identical body of uucore's `base_common::handle_input`
// lives here rather than being duplicated three times or having one applet import
// another). Each applet owns its own `cli.Spec` (their flag sets differ slightly --
// basenc adds format selectors) and passes in the already-parsed options.
// ============================================================================

/// Opens `filename` (or stdin when `null`/`-`), reads it fully, encodes or decodes per
/// `format`, applies wrapping on encode, and writes the result to `ctx.stdout`. Returns
/// the process exit code. `prog` is used verbatim in error messages (`{prog}: ...`).
pub fn runBaseIO(
    ctx: *Ctx,
    prog: []const u8,
    format: Format,
    decode: bool,
    ignore_garbage: bool,
    wrap_cols: ?usize,
    filename: ?[]const u8,
) u8 {
    const is_stdin = filename == null or std.mem.eql(u8, filename.?, "-");

    var fd: sys.Fd = ctx.stdin;
    if (!is_stdin) {
        _ = sys.stat(filename.?) catch {
            ctx.errPrint("{s}: {s}: No such file or directory\n", .{ prog, filename.? });
            return 1;
        };
        fd = sys.open(filename.?, .{ .read = true }) catch |e| {
            ctx.errPrint("{s}: {s}: {s}\n", .{ prog, filename.?, sys.strerror(sys.toErrno(e)) });
            return 1;
        };
    }
    defer if (!is_stdin) sys.close(fd);

    const input = textio.readAll(ctx.gpa, fd) catch |e| {
        ctx.errPrint("{s}: read error: {s}\n", .{ prog, sys.strerror(sys.toErrno(e)) });
        return 1;
    };

    if (decode) {
        const outcome = decodeAlloc(ctx.gpa, format, input, ignore_garbage) catch {
            ctx.errPrint("{s}: error: invalid input\n", .{prog});
            return 1;
        };
        ctx.outWrite(outcome.bytes) catch {};
        if (outcome.invalid) {
            ctx.errPrint("{s}: error: invalid input\n", .{prog});
            return 1;
        }
        return 0;
    }

    const encoded = encodeAlloc(ctx.gpa, format, input) catch |e| {
        // Z85 has its own encode-time length message (verified against the oracle:
        // `basenc --z85` on a length not a multiple of 4).
        if (e == CodecError.InvalidZ85Input) {
            ctx.errPrint("{s}: error: invalid input (length must be multiple of 4 characters)\n", .{prog});
        } else {
            ctx.errPrint("{s}: error: invalid input\n", .{prog});
        }
        return 1;
    };
    const wrapped = wrapAlloc(ctx.gpa, encoded, wrap_cols) catch {
        ctx.errPrint("{s}: error\n", .{prog});
        return 1;
    };
    ctx.outWrite(wrapped) catch {};
    return 0;
}
