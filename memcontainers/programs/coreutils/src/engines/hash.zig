//! Digest engine (DESIGN.md §7.3): wraps Zig std for MD5/SHA1/SHA2/SHA3/SHAKE/BLAKE3,
//! hand-writes SM3 (~200 lines, GB/T 32905-2016) and BLAKE2b (RFC 7693, needed at
//! runtime-configurable output length for b2sum/cksum `-l`, which std's comptime-generic
//! `Blake2b(out_bits)` cannot give us), plus the legacy GNU `cksum`/`sum` sums (CRC with
//! length postfix, CRC32B, BSD rotate-sum, SysV fold-sum). Also the shared presentation
//! layer (Tagged/Untagged/Raw formatting, hex/base64 digest encoding) and the `-c`
//! check-file parser, ported from uutils 0.9.0's `uucore::checksum` (mod.rs/compute.rs/
//! validate.rs) -- see docs/analysis/uutils-applets.md "cksum + hash family". The
//! oracle (`reference/uutils-coreutils/target/release/coreutils`) is the byte-parity
//! target; GNU cksum is not.
//!
//! Scope note (parity-ledger): the exotic OpenSSL-style tagged-line sub-case (algo name
//! immediately touching the paren with no space, e.g. `BLAKE2b(44)= ...`) and
//! locale-aware shell-escaping of control/non-UTF8 bytes in filenames inside `-c`
//! reports are NOT implemented -- only the common POSIX-style tagged/untagged/
//! single-space line forms and plain filename escaping (`\\`, `\n`, `\r` -> backslash
//! prefix marker) are. These are the flows exercised by the corpus; anything requiring
//! them should get a ledger entry, not silent guessing.

const std = @import("std");
const sys = @import("../sys/root.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

// ============================================================================
// SM3 (GB/T 32905-2016) -- hand-written, no std support.
// ============================================================================

pub const Sm3 = struct {
    h: [8]u32,
    buf: [64]u8 = undefined,
    buf_len: u8 = 0,
    total_len: u64 = 0,

    const IV = [8]u32{
        0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
        0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e,
    };

    pub fn init() Sm3 {
        return .{ .h = IV };
    }

    fn rotl(x: u32, n: u5) u32 {
        if (n == 0) return x;
        return (x << n) | (x >> @intCast(32 - @as(u6, n)));
    }

    fn p0(x: u32) u32 {
        return x ^ rotl(x, 9) ^ rotl(x, 17);
    }

    fn p1(x: u32) u32 {
        return x ^ rotl(x, 15) ^ rotl(x, 23);
    }

    fn ffj(j: usize, x: u32, y: u32, z: u32) u32 {
        return if (j < 16) x ^ y ^ z else (x & y) | (x & z) | (y & z);
    }

    fn ggj(j: usize, x: u32, y: u32, z: u32) u32 {
        return if (j < 16) x ^ y ^ z else (x & y) | (~x & z);
    }

    fn tj(j: usize) u32 {
        return if (j < 16) @as(u32, 0x79cc4519) else @as(u32, 0x7a879d8a);
    }

    fn compress(self: *Sm3, block: []const u8) void {
        var w: [68]u32 = undefined;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            w[i] = std.mem.readInt(u32, block[i * 4 ..][0..4], .big);
        }
        i = 16;
        while (i < 68) : (i += 1) {
            w[i] = p1(w[i - 16] ^ w[i - 9] ^ rotl(w[i - 3], 15)) ^ rotl(w[i - 13], 7) ^ w[i - 6];
        }
        var wp: [64]u32 = undefined;
        i = 0;
        while (i < 64) : (i += 1) wp[i] = w[i] ^ w[i + 4];

        var a = self.h[0];
        var b = self.h[1];
        var c = self.h[2];
        var d = self.h[3];
        var e = self.h[4];
        var f = self.h[5];
        var g = self.h[6];
        var hh = self.h[7];

        var j: usize = 0;
        while (j < 64) : (j += 1) {
            const rot_amt: u5 = @intCast(j % 32);
            const ss1 = rotl(rotl(a, 12) +% e +% rotl(tj(j), rot_amt), 7);
            const ss2 = ss1 ^ rotl(a, 12);
            const tt1 = ffj(j, a, b, c) +% d +% ss2 +% wp[j];
            const tt2 = ggj(j, e, f, g) +% hh +% ss1 +% w[j];
            d = c;
            c = rotl(b, 9);
            b = a;
            a = tt1;
            hh = g;
            g = rotl(f, 19);
            f = e;
            e = p0(tt2);
        }

        self.h[0] ^= a;
        self.h[1] ^= b;
        self.h[2] ^= c;
        self.h[3] ^= d;
        self.h[4] ^= e;
        self.h[5] ^= f;
        self.h[6] ^= g;
        self.h[7] ^= hh;
    }

    pub fn update(self: *Sm3, data_in: []const u8) void {
        var data = data_in;
        self.total_len += data.len;
        if (self.buf_len > 0) {
            const need = 64 - self.buf_len;
            const take = @min(need, data.len);
            @memcpy(self.buf[self.buf_len..][0..take], data[0..take]);
            self.buf_len += @intCast(take);
            data = data[take..];
            if (self.buf_len == 64) {
                self.compress(&self.buf);
                self.buf_len = 0;
            }
        }
        while (data.len >= 64) {
            self.compress(data[0..64]);
            data = data[64..];
        }
        if (data.len > 0) {
            @memcpy(self.buf[0..data.len], data);
            self.buf_len = @intCast(data.len);
        }
    }

    pub fn final(self: *Sm3, out: *[32]u8) void {
        const bit_len = self.total_len * 8;
        var pad: [128]u8 = [_]u8{0} ** 128;
        pad[0] = 0x80;
        const used: usize = self.buf_len;
        // `pad_len` is the FULL length of the slice fed to `update` below (the 0x80
        // marker byte, zero fill, and the trailing 8-byte big-endian bit length),
        // chosen so `used + pad_len` lands on a 64-byte block boundary with at least
        // 9 bytes (marker + length) available in the final block.
        const pad_len: usize = if (used + 1 + 8 <= 64) 64 - used else 128 - used;
        std.mem.writeInt(u64, pad[pad_len - 8 ..][0..8], bit_len, .big);
        self.update(pad[0..pad_len]);
        // update() above will have consumed exactly full blocks (buf_len reset to 0
        // by construction of pad_len), so h is final now.
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            std.mem.writeInt(u32, out[i * 4 ..][0..4], self.h[i], .big);
        }
    }

    pub fn hash(data: []const u8, out: *[32]u8) void {
        var s = Sm3.init();
        s.update(data);
        s.final(out);
    }
};

// ============================================================================
// BLAKE2b (RFC 7693) -- hand-written for runtime-configurable output length
// (std's `Blake2b(comptime out_bits)` bakes the length into the IV personalization at
// compile time, which cannot serve b2sum/cksum `-l`'s runtime bit length).
// ============================================================================

pub const Blake2b = struct {
    h: [8]u64,
    t: [2]u64 = .{ 0, 0 },
    buf: [128]u8 = undefined,
    buf_len: u8 = 0,
    out_bytes: usize,

    const IV = [8]u64{
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    };

    const SIGMA = [10][16]u8{
        .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        .{ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
        .{ 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 },
        .{ 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 },
        .{ 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 },
        .{ 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 },
        .{ 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 },
        .{ 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 },
        .{ 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 },
        .{ 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 },
    };

    /// `out_bytes` in 1..=64 (b2sum/cksum validate this before calling in).
    pub fn init(out_bytes: usize) Blake2b {
        var h = IV;
        h[0] ^= 0x01010000 ^ @as(u64, out_bytes);
        return .{ .h = h, .out_bytes = out_bytes };
    }

    fn rotr(x: u64, n: u6) u64 {
        return (x >> n) | (x << @intCast(64 - @as(u7, n)));
    }

    fn g(v: *[16]u64, a: usize, b: usize, c: usize, d: usize, x: u64, y: u64) void {
        v[a] = v[a] +% v[b] +% x;
        v[d] = rotr(v[d] ^ v[a], 32);
        v[c] = v[c] +% v[d];
        v[b] = rotr(v[b] ^ v[c], 24);
        v[a] = v[a] +% v[b] +% y;
        v[d] = rotr(v[d] ^ v[a], 16);
        v[c] = v[c] +% v[d];
        v[b] = rotr(v[b] ^ v[c], 63);
    }

    fn compress(self: *Blake2b, block: []const u8, final_block: bool) void {
        var m: [16]u64 = undefined;
        var i: usize = 0;
        while (i < 16) : (i += 1) m[i] = std.mem.readInt(u64, block[i * 8 ..][0..8], .little);

        var v: [16]u64 = undefined;
        @memcpy(v[0..8], &self.h);
        @memcpy(v[8..16], &IV);
        v[12] ^= self.t[0];
        v[13] ^= self.t[1];
        if (final_block) v[14] = ~v[14];

        var round: usize = 0;
        while (round < 12) : (round += 1) {
            const s = SIGMA[round % 10];
            g(&v, 0, 4, 8, 12, m[s[0]], m[s[1]]);
            g(&v, 1, 5, 9, 13, m[s[2]], m[s[3]]);
            g(&v, 2, 6, 10, 14, m[s[4]], m[s[5]]);
            g(&v, 3, 7, 11, 15, m[s[6]], m[s[7]]);
            g(&v, 0, 5, 10, 15, m[s[8]], m[s[9]]);
            g(&v, 1, 6, 11, 12, m[s[10]], m[s[11]]);
            g(&v, 2, 7, 8, 13, m[s[12]], m[s[13]]);
            g(&v, 3, 4, 9, 14, m[s[14]], m[s[15]]);
        }
        i = 0;
        while (i < 8) : (i += 1) self.h[i] ^= v[i] ^ v[i + 8];
    }

    pub fn update(self: *Blake2b, data_in: []const u8) void {
        var data = data_in;
        while (data.len > 0) {
            if (self.buf_len == 128) {
                self.t[0] +%= 128;
                if (self.t[0] < 128) self.t[1] +%= 1;
                self.compress(&self.buf, false);
                self.buf_len = 0;
            }
            const take = @min(128 - @as(usize, self.buf_len), data.len);
            @memcpy(self.buf[self.buf_len..][0..take], data[0..take]);
            self.buf_len += @intCast(take);
            data = data[take..];
        }
    }

    pub fn final(self: *Blake2b, out: []u8) void {
        std.debug.assert(out.len == self.out_bytes);
        self.t[0] +%= self.buf_len;
        if (self.t[0] < self.buf_len) self.t[1] +%= 1;
        @memset(self.buf[self.buf_len..], 0);
        self.compress(&self.buf, true);
        var full: [64]u8 = undefined;
        var i: usize = 0;
        while (i < 8) : (i += 1) std.mem.writeInt(u64, full[i * 8 ..][0..8], self.h[i], .little);
        @memcpy(out, full[0..self.out_bytes]);
    }
};

/// Fills `buf` (must be at least `bytes.len*2` long) with lowercase hex and returns the
/// exact-length slice. Test-only helper.
fn hexInto(buf: []u8, bytes: []const u8) []const u8 {
    const table = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        buf[i * 2] = table[b >> 4];
        buf[i * 2 + 1] = table[b & 0xf];
    }
    return buf[0 .. bytes.len * 2];
}

// ============================================================================
// Hash-family dispatch (md5sum/sha*sum/b2sum + cksum's non-legacy algorithms).
// ============================================================================

pub const HashAlgo = enum {
    md5,
    sha1,
    sha224,
    sha256,
    sha384,
    sha512,
    sha3_224,
    sha3_256,
    sha3_384,
    sha3_512,
    shake128,
    shake256,
    blake2b,
    blake3,
    sm3,
};

pub const MAX_FIXED_OUT_BYTES = 64;

/// Default output length in BITS, per uutils DEFAULT_BIT_SIZE constants.
pub fn defaultOutBits(algo: HashAlgo) usize {
    return switch (algo) {
        .md5 => 128,
        .sha1 => 160,
        .sha224 => 224,
        .sha256 => 256,
        .sha384 => 384,
        .sha512 => 512,
        .sha3_224 => 224,
        .sha3_256 => 256,
        .sha3_384 => 384,
        .sha3_512 => 512,
        .shake128 => 256,
        .shake256 => 512,
        .blake2b => 512,
        .blake3 => 256,
        .sm3 => 256,
    };
}

const sha2 = std.crypto.hash.sha2;
const sha3ns = std.crypto.hash.sha3;

pub const Digest = struct {
    algo: HashAlgo,
    out_bytes: usize,
    impl: union(enum) {
        md5: std.crypto.hash.Md5,
        sha1: std.crypto.hash.Sha1,
        sha224: sha2.Sha224,
        sha256: sha2.Sha256,
        sha384: sha2.Sha384,
        sha512: sha2.Sha512,
        sha3_224: sha3ns.Sha3_224,
        sha3_256: sha3ns.Sha3_256,
        sha3_384: sha3ns.Sha3_384,
        sha3_512: sha3ns.Sha3_512,
        shake128: sha3ns.Shake128,
        shake256: sha3ns.Shake256,
        blake2b: Blake2b,
        blake3: std.crypto.hash.Blake3,
        sm3: Sm3,
    },

    /// `out_bytes` is meaningful only for blake2b/blake3/shake128/shake256; other
    /// algorithms have a fixed length and ignore it (callers pass `defaultOutBits(algo)/8`
    /// for uniformity, or their own resolved length for the variable ones).
    pub fn init(algo: HashAlgo, out_bytes: usize) Digest {
        return switch (algo) {
            .md5 => .{ .algo = algo, .out_bytes = 16, .impl = .{ .md5 = std.crypto.hash.Md5.init(.{}) } },
            .sha1 => .{ .algo = algo, .out_bytes = 20, .impl = .{ .sha1 = std.crypto.hash.Sha1.init(.{}) } },
            .sha224 => .{ .algo = algo, .out_bytes = 28, .impl = .{ .sha224 = sha2.Sha224.init(.{}) } },
            .sha256 => .{ .algo = algo, .out_bytes = 32, .impl = .{ .sha256 = sha2.Sha256.init(.{}) } },
            .sha384 => .{ .algo = algo, .out_bytes = 48, .impl = .{ .sha384 = sha2.Sha384.init(.{}) } },
            .sha512 => .{ .algo = algo, .out_bytes = 64, .impl = .{ .sha512 = sha2.Sha512.init(.{}) } },
            .sha3_224 => .{ .algo = algo, .out_bytes = 28, .impl = .{ .sha3_224 = sha3ns.Sha3_224.init(.{}) } },
            .sha3_256 => .{ .algo = algo, .out_bytes = 32, .impl = .{ .sha3_256 = sha3ns.Sha3_256.init(.{}) } },
            .sha3_384 => .{ .algo = algo, .out_bytes = 48, .impl = .{ .sha3_384 = sha3ns.Sha3_384.init(.{}) } },
            .sha3_512 => .{ .algo = algo, .out_bytes = 64, .impl = .{ .sha3_512 = sha3ns.Sha3_512.init(.{}) } },
            .shake128 => .{ .algo = algo, .out_bytes = out_bytes, .impl = .{ .shake128 = sha3ns.Shake128.init(.{}) } },
            .shake256 => .{ .algo = algo, .out_bytes = out_bytes, .impl = .{ .shake256 = sha3ns.Shake256.init(.{}) } },
            .blake2b => .{ .algo = algo, .out_bytes = out_bytes, .impl = .{ .blake2b = Blake2b.init(out_bytes) } },
            .blake3 => .{ .algo = algo, .out_bytes = out_bytes, .impl = .{ .blake3 = std.crypto.hash.Blake3.init(.{}) } },
            .sm3 => .{ .algo = algo, .out_bytes = 32, .impl = .{ .sm3 = Sm3.init() } },
        };
    }

    pub fn update(self: *Digest, bytes: []const u8) void {
        switch (self.impl) {
            inline else => |*s| s.update(bytes),
        }
    }

    /// `out.len` must equal `self.out_bytes`.
    pub fn finalize(self: *Digest, out: []u8) void {
        std.debug.assert(out.len == self.out_bytes);
        switch (self.impl) {
            .md5 => |*s| {
                var buf: [16]u8 = undefined;
                s.final(&buf);
                @memcpy(out, &buf);
            },
            .sha1 => |*s| {
                var buf: [20]u8 = undefined;
                s.final(&buf);
                @memcpy(out, &buf);
            },
            .sha224 => |*s| {
                var buf: [28]u8 = undefined;
                s.final(&buf);
                @memcpy(out, &buf);
            },
            .sha256 => |*s| {
                var buf: [32]u8 = undefined;
                s.final(&buf);
                @memcpy(out, &buf);
            },
            .sha384 => |*s| {
                var buf: [48]u8 = undefined;
                s.final(&buf);
                @memcpy(out, &buf);
            },
            .sha512 => |*s| {
                var buf: [64]u8 = undefined;
                s.final(&buf);
                @memcpy(out, &buf);
            },
            .sha3_224 => |*s| {
                var buf: [28]u8 = undefined;
                s.final(&buf);
                @memcpy(out, &buf);
            },
            .sha3_256 => |*s| {
                var buf: [32]u8 = undefined;
                s.final(&buf);
                @memcpy(out, &buf);
            },
            .sha3_384 => |*s| {
                var buf: [48]u8 = undefined;
                s.final(&buf);
                @memcpy(out, &buf);
            },
            .sha3_512 => |*s| {
                var buf: [64]u8 = undefined;
                s.final(&buf);
                @memcpy(out, &buf);
            },
            .shake128 => |*s| {
                s.final(out);
                maskExtraBits(out, self.out_bytes * 8);
            },
            .shake256 => |*s| {
                s.final(out);
                maskExtraBits(out, self.out_bytes * 8);
            },
            .blake2b => |*s| s.final(out),
            .blake3 => |*s| s.final(out),
            .sm3 => |*s| {
                var buf: [32]u8 = undefined;
                s.final(&buf);
                @memcpy(out, &buf);
            },
        }
    }
};

/// Shake output at a bit length not a multiple of 8: zero the extra high bits of the
/// last byte (uutils `impl_digest_shake!`: `out[last] &= (1 << extra) - 1`). `bits` is
/// the REQUESTED bit length (out.len == ceil(bits/8) already).
fn maskExtraBits(out: []u8, bits: usize) void {
    const extra = bits % 8;
    if (extra != 0 and out.len > 0) {
        out[out.len - 1] &= @as(u8, @intCast((@as(u16, 1) << @intCast(extra)) - 1));
    }
}

// ============================================================================
// Legacy sums: GNU cksum's default CRC (poly + length postfix), CRC32B, BSD sum,
// SysV sum. Table-driven CRC comes from Zig std (verified params match uutils'
// `Crc`/`CRC32B` exactly -- see docs/analysis notes).
// ============================================================================

const crc = std.hash.crc;

/// GNU `cksum` default algorithm (`-a crc`, equivalent to legacy `cksum`): CRC-32/CKSUM
/// (poly 0x04c11db7, init 0, not reflected, xorout 0xffffffff) with the total byte
/// length appended (base-256, least-significant byte first, stopping once the
/// remaining length is zero) before the final table walk.
pub const Crc = struct {
    state: crc.Crc32Cksum = crc.Crc32Cksum.init(),
    len: u64 = 0,

    pub fn update(self: *Crc, bytes: []const u8) void {
        self.state.update(bytes);
        self.len += bytes.len;
    }

    pub fn final(self: *Crc) u32 {
        var sz = self.len;
        while (sz > 0) {
            self.state.update(&[1]u8{@truncate(sz)});
            sz >>= 8;
        }
        return self.state.final();
    }
};

/// `cksum -a crc32b`: plain CRC-32/ISO-HDLC (the classic zlib/Ethernet CRC32), no
/// length postfix.
pub const Crc32B = struct {
    state: crc.Crc32IsoHdlc = crc.Crc32IsoHdlc.init(),

    pub fn update(self: *Crc32B, bytes: []const u8) void {
        self.state.update(bytes);
    }

    pub fn final(self: *Crc32B) u32 {
        return self.state.final();
    }
};

/// BSD `sum -r` / `cksum -a bsd`: u16 state, per byte `rotate_right(1).wrapping_add`.
/// Block count for display is bytes read, rounded up to 1024-byte blocks.
pub const BsdSum = struct {
    state: u16 = 0,

    pub fn update(self: *BsdSum, bytes: []const u8) void {
        for (bytes) |byte| {
            self.state = (self.state >> 1) +% ((self.state & 1) << 15);
            self.state = self.state +% byte;
        }
    }

    pub fn final(self: *BsdSum) u16 {
        return self.state;
    }

    pub fn blocks(total_bytes: u64) u64 {
        return (total_bytes + 1023) / 1024;
    }
};

/// SysV `sum -s` / `cksum -a sysv`: u32 running byte sum, folded twice into 16 bits at
/// the end. Block count rounds up to 512-byte blocks.
pub const SysvSum = struct {
    state: u32 = 0,

    pub fn update(self: *SysvSum, bytes: []const u8) void {
        for (bytes) |byte| self.state = self.state +% byte;
    }

    pub fn final(self: *SysvSum) u16 {
        var s = self.state;
        s = (s & 0xffff) + (s >> 16);
        s = (s & 0xffff) + (s >> 16);
        return @truncate(s);
    }

    pub fn blocks(total_bytes: u64) u64 {
        return (total_bytes + 511) / 512;
    }
};

// ============================================================================
// CLI algorithm selection (cksum `-a`, per-binary AlgoKind::from_bin_name) and the
// resolved/"sized" algorithm (after `-l` is applied), mirroring uutils'
// `checksum::{AlgoKind, SizedAlgoKind}`.
// ============================================================================

/// The 17 `cksum --algorithm` values, in the exact order GNU/uutils lists them in its
/// "possible values" error text.
pub const CliAlgo = enum {
    sysv,
    bsd,
    crc,
    crc32b,
    md5,
    sha1,
    sha2,
    sha3,
    blake2b,
    sm3,
    sha224,
    sha256,
    sha384,
    sha512,
    blake3,
    shake128,
    shake256,
};

pub const CLI_ALGO_NAMES = [_][]const u8{
    "sysv", "bsd", "crc", "crc32b", "md5", "sha1", "sha2", "sha3", "blake2b",
    "sm3",  "sha224", "sha256", "sha384", "sha512", "blake3", "shake128", "shake256",
};

pub fn cliAlgoFromString(s: []const u8) ?CliAlgo {
    inline for (@typeInfo(CliAlgo).@"enum".fields) |f| {
        if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

pub fn cliAlgoIsLegacy(a: CliAlgo) bool {
    return a == .sysv or a == .bsd or a == .crc or a == .crc32b;
}

pub const ShaLen = enum(usize) { l224 = 224, l256 = 256, l384 = 384, l512 = 512 };

pub fn shaLenFromBits(bits: usize) ?ShaLen {
    return switch (bits) {
        224 => .l224,
        256 => .l256,
        384 => .l384,
        512 => .l512,
        else => null,
    };
}

/// A fully-resolved algorithm (after any `-l`/`--length` is applied), mirroring
/// `SizedAlgoKind`.
pub const Sized = union(enum) {
    sysv,
    bsd,
    crc,
    crc32b,
    md5,
    sm3,
    sha1,
    sha2: ShaLen,
    sha3: ShaLen,
    blake2b: usize, // output length in BITS
    blake3: usize,
    shake128: usize,
    shake256: usize,

    pub fn isLegacy(self: Sized) bool {
        return switch (self) {
            .sysv, .bsd, .crc, .crc32b => true,
            else => false,
        };
    }

    pub fn bitLen(self: Sized) usize {
        return switch (self) {
            .sysv => 512,
            .bsd => 1024,
            .crc => 256,
            .crc32b => 32,
            .md5 => 128,
            .sm3 => 256,
            .sha1 => 160,
            .sha2 => |l| @intFromEnum(l),
            .sha3 => |l| @intFromEnum(l),
            .blake2b => |b| b,
            .blake3 => |b| b,
            .shake128 => |b| b,
            .shake256 => |b| b,
        };
    }

    /// Writes the tag name (`ALGO`/`ALGO-N`) into `buf`, returns the used slice.
    /// Matches `SizedAlgoKind::to_tag()` exactly, including BLAKE2b's special-case
    /// (no `-N` suffix at the default 512-bit length) and BLAKE3/SHAKE's
    /// always-suffixed form.
    pub fn tag(self: Sized, buf: []u8) []const u8 {
        return switch (self) {
            .md5 => "MD5",
            .sm3 => "SM3",
            .sha1 => "SHA1",
            .sha2 => |l| std.fmt.bufPrint(buf, "SHA{d}", .{@intFromEnum(l)}) catch unreachable,
            .sha3 => |l| std.fmt.bufPrint(buf, "SHA3-{d}", .{@intFromEnum(l)}) catch unreachable,
            .blake2b => |b| if (b == 512) "BLAKE2b" else std.fmt.bufPrint(buf, "BLAKE2b-{d}", .{b}) catch unreachable,
            .blake3 => |b| std.fmt.bufPrint(buf, "BLAKE3-{d}", .{b}) catch unreachable,
            .shake128 => |b| std.fmt.bufPrint(buf, "SHAKE128-{d}", .{b}) catch unreachable,
            .shake256 => |b| std.fmt.bufPrint(buf, "SHAKE256-{d}", .{b}) catch unreachable,
            .sysv, .bsd, .crc, .crc32b => unreachable, // legacy: never tagged
        };
    }

    /// Output byte length for the hash-family (legacy variants have no meaningful
    /// digest byte length -- callers must not call this on them).
    pub fn outBytes(self: Sized) usize {
        return (self.bitLen() + 7) / 8;
    }

    pub fn algo(self: Sized) HashAlgo {
        return switch (self) {
            .md5 => .md5,
            .sm3 => .sm3,
            .sha1 => .sha1,
            .sha2 => |l| switch (l) {
                .l224 => .sha224,
                .l256 => .sha256,
                .l384 => .sha384,
                .l512 => .sha512,
            },
            .sha3 => |l| switch (l) {
                .l224 => .sha3_224,
                .l256 => .sha3_256,
                .l384 => .sha3_384,
                .l512 => .sha3_512,
            },
            .blake2b => .blake2b,
            .blake3 => .blake3,
            .shake128 => .shake128,
            .shake256 => .shake256,
            .sysv, .bsd, .crc, .crc32b => unreachable,
        };
    }

    pub fn createDigest(self: Sized) Digest {
        return Digest.init(self.algo(), self.outBytes());
    }
};

pub const SizedError = error{
    LengthOnlyForBlake2bSha2Sha3,
    LengthRequiredForSha,
    InvalidLengthForSha,
    LengthNotMultipleOf8,
    LengthTooBigForBlake,
};

/// Mirrors `SizedAlgoKind::from_unsized`: `bit_length` is `null` when `-l`/`--length`
/// was not given. Blake2b/Blake3 accept ANY multiple-of-8 length (Blake3 has no GNU
/// upper bound documented; Blake2b's is 512). SHAKE accepts anything (its "-l 0" case
/// is handled by callers before this, matching `maybe_sanitize_length`'s `Ok(None)`
/// short-circuit for `0`).
pub fn resolveSized(cli: CliAlgo, bit_length: ?usize) SizedError!Sized {
    switch (cli) {
        .sysv => return .sysv,
        .bsd => return .bsd,
        .crc => return .crc,
        .crc32b => return .crc32b,
        .md5, .sm3, .sha1, .sha224, .sha256, .sha384, .sha512 => {
            if (bit_length != null) return SizedError.LengthOnlyForBlake2bSha2Sha3;
            return switch (cli) {
                .md5 => .md5,
                .sm3 => .sm3,
                .sha1 => .sha1,
                .sha224 => .{ .sha2 = .l224 },
                .sha256 => .{ .sha2 = .l256 },
                .sha384 => .{ .sha2 = .l384 },
                .sha512 => .{ .sha2 = .l512 },
                else => unreachable,
            };
        },
        .blake2b => return .{ .blake2b = bit_length orelse 512 },
        .blake3 => return .{ .blake3 = bit_length orelse 256 },
        .shake128 => return .{ .shake128 = bit_length orelse 256 },
        .shake256 => return .{ .shake256 = bit_length orelse 512 },
        .sha2, .sha3 => {
            const l = bit_length orelse return SizedError.LengthRequiredForSha;
            const sl = shaLenFromBits(l) orelse return SizedError.InvalidLengthForSha;
            return if (cli == .sha2) .{ .sha2 = sl } else .{ .sha3 = sl };
        },
    }
}

/// Outcome of validating a BLAKE2b/BLAKE3 `-l` bit-length string (`parse_blake_length`).
/// Distinguished from a plain error union because the CLI prints TWO lines for the
/// `.too_big`/`.not_multiple_of_8` cases (a generic `invalid length: 'X'` followed by
/// the specific reason -- verified against the oracle: `b2sum -l 10` prints both
/// `invalid length: '10'` and `length is not a multiple of 8`), but only ONE line
/// (`invalid length: 'X'`) when the string isn't an integer at all.
pub const LengthOutcome = union(enum) {
    ok: usize,
    invalid_number,
    not_multiple_of_8,
    too_big,
};

/// Mirrors `parse_blake_length`: `"0"` means "use the default" (512 bits for BLAKE2b,
/// 256 for BLAKE3); BLAKE2b additionally caps at 512.
pub fn parseBlakeLength(is_blake2b: bool, s: []const u8) LengthOutcome {
    const n = std.fmt.parseInt(usize, s, 10) catch return .invalid_number;
    if (n == 0) return .{ .ok = if (is_blake2b) @as(usize, 512) else @as(usize, 256) };
    if (is_blake2b and n > 512) return .too_big;
    if (n % 8 != 0) return .not_multiple_of_8;
    return .{ .ok = n };
}

// ============================================================================
// Hex / base64 digest text encoding (the presentation layer needs both; codec.zig is
// not depended on here to keep the engines decoupled -- these are tiny).
// ============================================================================

pub fn hexEncode(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const table = "0123456789abcdef";
    var out = try gpa.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = table[b >> 4];
        out[i * 2 + 1] = table[b & 0xf];
    }
    return out;
}

const B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn base64Encode(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out_len = ((bytes.len + 2) / 3) * 4;
    var out = try gpa.alloc(u8, out_len);
    var i: usize = 0;
    var o: usize = 0;
    while (i + 3 <= bytes.len) : (i += 3) {
        const n = (@as(u32, bytes[i]) << 16) | (@as(u32, bytes[i + 1]) << 8) | bytes[i + 2];
        out[o] = B64_ALPHABET[(n >> 18) & 0x3f];
        out[o + 1] = B64_ALPHABET[(n >> 12) & 0x3f];
        out[o + 2] = B64_ALPHABET[(n >> 6) & 0x3f];
        out[o + 3] = B64_ALPHABET[n & 0x3f];
        o += 4;
    }
    const rem = bytes.len - i;
    if (rem == 1) {
        const n = @as(u32, bytes[i]) << 16;
        out[o] = B64_ALPHABET[(n >> 18) & 0x3f];
        out[o + 1] = B64_ALPHABET[(n >> 12) & 0x3f];
        out[o + 2] = '=';
        out[o + 3] = '=';
        o += 4;
    } else if (rem == 2) {
        const n = (@as(u32, bytes[i]) << 16) | (@as(u32, bytes[i + 1]) << 8);
        out[o] = B64_ALPHABET[(n >> 18) & 0x3f];
        out[o + 1] = B64_ALPHABET[(n >> 12) & 0x3f];
        out[o + 2] = B64_ALPHABET[(n >> 6) & 0x3f];
        out[o + 3] = '=';
        o += 4;
    }
    std.debug.assert(o == out_len);
    return out;
}

// ============================================================================
// Filename escaping for checksum lines (uucore::checksum::{escape_filename,
// unescape_filename}): backslash, LF and CR get backslash-escaped and the WHOLE line
// gets a literal leading `\` marker when any escaping happened. `-z/--zero` mode
// disables escaping entirely (LineEnding::Nul path in compute.rs).
// ============================================================================

pub const EscapedName = struct { text: []const u8, escaped: bool };

/// Returns the escaped filename and whether a leading `\` marker is needed. Caller
/// owns the returned slice iff `did_escape` is true (a fresh allocation); otherwise the
/// input slice is returned verbatim (`filename` must outlive the result in that case).
pub fn escapeFilename(gpa: std.mem.Allocator, filename: []const u8) !EscapedName {
    var needs = false;
    for (filename) |c| {
        if (c == '\\' or c == '\n' or c == '\r') {
            needs = true;
            break;
        }
    }
    if (!needs) return .{ .text = filename, .escaped = false };
    var out = std.ArrayListUnmanaged(u8).empty;
    for (filename) |c| {
        switch (c) {
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            else => try out.append(gpa, c),
        }
    }
    return .{ .text = try out.toOwnedSlice(gpa), .escaped = true };
}

/// Reverses `escapeFilename` for `-c` line parsing (uucore's `unescape_filename`).
pub fn unescapeFilename(gpa: std.mem.Allocator, filename: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, filename, '\\') == null) return filename;
    var out = std.ArrayListUnmanaged(u8).empty;
    var i: usize = 0;
    while (i < filename.len) : (i += 1) {
        if (filename[i] == '\\' and i + 1 < filename.len) {
            switch (filename[i + 1]) {
                '\\' => {
                    try out.append(gpa, '\\');
                    i += 1;
                },
                'n' => {
                    try out.append(gpa, '\n');
                    i += 1;
                },
                'r' => {
                    try out.append(gpa, '\r');
                    i += 1;
                },
                else => try out.append(gpa, filename[i]),
            }
        } else {
            try out.append(gpa, filename[i]);
        }
    }
    return out.toOwnedSlice(gpa);
}

// ============================================================================
// Compute-mode orchestration (uucore::checksum::compute): shared by hashsum-family
// applets (md5sum/sha*sum/b2sum) and cksum. This is the one engine in nutils that
// touches `sys`/`Ctx` (DESIGN.md §3 explicitly allows engines -> sys; the check-file
// parser and the digest-computation loop are declared in-scope for `hash.zig` by
// DESIGN.md §7.3, and "nothing imports an applet" rules out sharing this any other
// way between the two applet files that need it).
// ============================================================================

const READ_BUFFER_SIZE = 32 * 1024;

/// Right-aligns `value`'s decimal digits to `width` in `buf`, padding with `0` or ` `
/// (`ctx.outPrint`'s minimal formatter -- core/fmt_min.zig -- supports only bare
/// `{s}`/`{d}`/`{c}`, no width/alignment, so padded fields are rendered by hand).
/// Values whose digit count already reaches or exceeds `width` are left unpadded
/// (matches Rust's `{:0width$}` / `{:width$}` behavior).
pub fn padDecimal(buf: []u8, value: u64, width: usize, zero_pad: bool) []const u8 {
    var tmp: [20]u8 = undefined;
    var i: usize = tmp.len;
    var v = value;
    if (v == 0) {
        i -= 1;
        tmp[i] = '0';
    }
    while (v != 0) {
        i -= 1;
        tmp[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    const digits = tmp[i..];
    if (digits.len >= width) {
        @memcpy(buf[0..digits.len], digits);
        return buf[0..digits.len];
    }
    const pad_len = width - digits.len;
    const pad_char: u8 = if (zero_pad) '0' else ' ';
    @memset(buf[0..pad_len], pad_char);
    @memcpy(buf[pad_len..][0..digits.len], digits);
    return buf[0..width];
}

pub const DigestFormat = enum { hex, base64 };

pub const OutputFormat = union(enum) {
    raw,
    legacy,
    tagged: DigestFormat,
    untagged: struct { fmt: DigestFormat, binary: bool },

    pub fn isRaw(self: OutputFormat) bool {
        return self == .raw;
    }
};

const ComputedValue = union(enum) { bytes: []u8, u16: u16, u32: u32 };

fn computeOne(gpa: std.mem.Allocator, sized: Sized, fd: sys.Fd) sys.Error!struct { value: ComputedValue, size: u64 } {
    var buf: [READ_BUFFER_SIZE]u8 = undefined;
    var size: u64 = 0;

    switch (sized) {
        .crc => {
            var d = Crc{};
            while (true) {
                const n = try sys.read(fd, &buf);
                if (n == 0) break;
                d.update(buf[0..n]);
                size += n;
            }
            return .{ .value = .{ .u32 = d.final() }, .size = size };
        },
        .crc32b => {
            var d = Crc32B{};
            while (true) {
                const n = try sys.read(fd, &buf);
                if (n == 0) break;
                d.update(buf[0..n]);
                size += n;
            }
            return .{ .value = .{ .u32 = d.final() }, .size = size };
        },
        .bsd => {
            var d = BsdSum{};
            while (true) {
                const n = try sys.read(fd, &buf);
                if (n == 0) break;
                d.update(buf[0..n]);
                size += n;
            }
            return .{ .value = .{ .u16 = d.final() }, .size = size };
        },
        .sysv => {
            var d = SysvSum{};
            while (true) {
                const n = try sys.read(fd, &buf);
                if (n == 0) break;
                d.update(buf[0..n]);
                size += n;
            }
            return .{ .value = .{ .u16 = d.final() }, .size = size };
        },
        else => {
            var d = sized.createDigest();
            while (true) {
                const n = try sys.read(fd, &buf);
                if (n == 0) break;
                d.update(buf[0..n]);
                size += n;
            }
            const out = gpa.alloc(u8, d.out_bytes) catch @panic("OOM");
            d.finalize(out);
            return .{ .value = .{ .bytes = out }, .size = size };
        },
    }
}

fn writeLine(ctx: *Ctx, prog: []const u8, sized: Sized, fmt: OutputFormat, zero: bool, filename: []const u8, value: ComputedValue, size: u64) !void {
    switch (fmt) {
        .raw => {
            switch (value) {
                .bytes => |b| try ctx.outWrite(b),
                .u32 => |n| {
                    var be: [4]u8 = undefined;
                    std.mem.writeInt(u32, &be, n, .big);
                    try ctx.outWrite(&be);
                },
                .u16 => |n| {
                    var be: [2]u8 = undefined;
                    std.mem.writeInt(u16, &be, n, .big);
                    try ctx.outWrite(&be);
                },
            }
            return;
        },
        .legacy => {
            const esc: EscapedName = if (zero) .{ .text = filename, .escaped = false } else try escapeFilename(ctx.gpa, filename);
            const prefix: []const u8 = if (esc.escaped) "\\" else "";
            switch (sized) {
                .sysv => ctx.outPrint("{s}{d} {d}", .{ prefix, value.u16, (size + 511) / 512 }),
                .bsd => {
                    var sumbuf: [16]u8 = undefined;
                    var blkbuf: [16]u8 = undefined;
                    const sum_text = padDecimal(&sumbuf, value.u16, 5, true);
                    const blk_text = padDecimal(&blkbuf, (size + 1023) / 1024, 5, false);
                    ctx.outPrint("{s}{s} {s}", .{ prefix, sum_text, blk_text });
                },
                .crc, .crc32b => ctx.outPrint("{s}{d} {d}", .{ prefix, value.u32, size }),
                else => unreachable,
            }
            if (!std.mem.eql(u8, esc.text, "-")) ctx.outPrint(" {s}", .{esc.text});
        },
        .tagged => |df| {
            const esc: EscapedName = if (zero) .{ .text = filename, .escaped = false } else try escapeFilename(ctx.gpa, filename);
            const prefix: []const u8 = if (esc.escaped) "\\" else "";
            var tagbuf: [32]u8 = undefined;
            const tag_name = sized.tag(&tagbuf);
            const sum_text = try encodeDigest(ctx.gpa, value.bytes, df);
            ctx.outPrint("{s}{s} ({s}) = {s}", .{ prefix, tag_name, esc.text, sum_text });
        },
        .untagged => |u| {
            const esc: EscapedName = if (zero) .{ .text = filename, .escaped = false } else try escapeFilename(ctx.gpa, filename);
            const prefix: []const u8 = if (esc.escaped) "\\" else "";
            const flag: u8 = if (u.binary) '*' else ' ';
            const sum_text = try encodeDigest(ctx.gpa, value.bytes, u.fmt);
            ctx.outPrint("{s}{s} {c}{s}", .{ prefix, sum_text, flag, esc.text });
        },
    }
    _ = prog;
    if (zero) {
        try ctx.outWrite(&[1]u8{0});
    } else {
        try ctx.outWrite("\n");
    }
}

fn encodeDigest(gpa: std.mem.Allocator, bytes: []const u8, fmt: DigestFormat) ![]u8 {
    return switch (fmt) {
        .hex => hexEncode(gpa, bytes),
        .base64 => base64Encode(gpa, bytes),
    };
}

/// Mirrors `perform_checksum_computation`: computes and prints one line per file.
/// `--raw` with more than one file is an error (`{prog}: the --raw option is not
/// supported with multiple files`), matching the oracle/`ChecksumError::RawMultipleFiles`.
pub fn computeAndPrint(ctx: *Ctx, prog: []const u8, sized: Sized, fmt: OutputFormat, zero: bool, files: []const []const u8) u8 {
    var rc: u8 = 0;
    for (files, 0..) |filename, i| {
        if (fmt.isRaw() and i + 1 < files.len) {
            ctx.errPrint("{s}: the --raw option is not supported with multiple files\n", .{prog});
            return 1;
        }
        const is_stdin = std.mem.eql(u8, filename, "-");
        if (!is_stdin) {
            const st = sys.stat(filename) catch |e| {
                ctx.errPrint("{s}: {s}: {s}\n", .{ prog, filename, sys.strerror(sys.toErrno(e)) });
                rc = 1;
                continue;
            };
            if (st.is_dir) {
                ctx.errPrint("{s}: {s}: Is a directory\n", .{ prog, filename });
                rc = 1;
                continue;
            }
        }
        const fd = if (is_stdin) ctx.stdin else sys.open(filename, .{ .read = true }) catch |e| {
            ctx.errPrint("{s}: {s}: {s}\n", .{ prog, filename, sys.strerror(sys.toErrno(e)) });
            rc = 1;
            continue;
        };
        defer if (!is_stdin) sys.close(fd);

        const computed = computeOne(ctx.gpa, sized, fd) catch |e| {
            ctx.errPrint("{s}: {s}: {s}\n", .{ prog, filename, sys.strerror(sys.toErrno(e)) });
            rc = 1;
            continue;
        };
        if (fmt.isRaw()) {
            writeLine(ctx, prog, sized, fmt, zero, filename, computed.value, computed.size) catch {};
            return rc;
        }
        writeLine(ctx, prog, sized, fmt, zero, filename, computed.value, computed.size) catch {};
    }
    return rc;
}

// ============================================================================
// Check-mode: line parsing (uucore's `LineFormat`/`LineInfo`, validate.rs).
// ============================================================================

pub const LineFormat = enum { algo_based, untagged, single_space };

pub const LineInfo = struct {
    algo_name: ?[]const u8 = null,
    algo_bit_len: ?usize = null,
    checksum: []const u8,
    filename: []const u8,
    format: LineFormat,
};

fn isBase64Shaped(s: []const u8) bool {
    if (s.len == 0) return false;
    var is_base64 = false;
    for (s, 0..) |c, i| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9' => {},
            '+', '/' => is_base64 = true,
            '=' => {
                is_base64 = true;
                // '=' only legal as 1-3 trailing padding chars.
                if (s.len - i > 3) return false;
                for (s[i..]) |cc| if (cc != '=') return false;
                break;
            },
            else => return false,
        }
    }
    if (is_base64 and s.len % 4 != 0) return false;
    return true;
}

fn parseAlgoBased(line: []const u8) ?LineInfo {
    var trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len > 0 and trimmed[0] == '\\') trimmed = trimmed[1..];
    const par_idx = std.mem.indexOfScalar(u8, trimmed, '(') orelse return null;
    if (par_idx == 0) return null;
    if (trimmed[par_idx - 1] != ' ') return null; // POSIX sub-case only (see module doc)
    const algo_substring = trimmed[0 .. par_idx - 1];
    var algo_name = algo_substring;
    var algo_bits: ?usize = null;
    if (std.mem.indexOfScalar(u8, algo_substring, '-')) |dash| {
        algo_name = algo_substring[0..dash];
        algo_bits = std.fmt.parseInt(usize, algo_substring[dash + 1 ..], 10) catch null;
    }
    for (algo_name) |c| {
        if (!std.ascii.isUpper(c) and !std.ascii.isDigit(c)) {
            if (!std.mem.eql(u8, algo_name, "BLAKE2b")) return null;
        }
    }
    const after_paren = trimmed[par_idx + 1 ..];
    const marker = ") = ";
    const rel = std.mem.lastIndexOf(u8, after_paren, marker) orelse return null;
    const filename = after_paren[0..rel];
    const checksum = after_paren[rel + marker.len ..];
    if (!isBase64Shaped(checksum)) return null;
    return .{ .algo_name = algo_name, .algo_bit_len = algo_bits, .checksum = checksum, .filename = filename, .format = .algo_based };
}

fn parseUntagged(line: []const u8) ?LineInfo {
    const space_idx = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const checksum = line[0..space_idx];
    if (!isBase64Shaped(checksum)) return null;
    const rest = line[space_idx..];
    var filename: []const u8 = undefined;
    if (std.mem.startsWith(u8, rest, "  ")) {
        filename = rest[2..];
    } else if (std.mem.startsWith(u8, rest, " *")) {
        filename = rest[2..];
    } else {
        return null;
    }
    return .{ .checksum = checksum, .filename = filename, .format = .untagged };
}

fn parseSingleSpace(line: []const u8) ?LineInfo {
    const space_idx = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const checksum = line[0..space_idx];
    if (checksum.len == 0) return null;
    for (checksum) |c| if (!std.ascii.isHex(c)) return null;
    if (space_idx + 1 > line.len) return null;
    const filename = line[space_idx + 1 ..];
    return .{ .checksum = checksum, .filename = filename, .format = .single_space };
}

/// Mirrors `LineInfo::parse`: tries the algo-based (tagged) parser first; for
/// non-algo-based lines, `cached_format` pins whichever of untagged/single-space
/// matched first so later lines in the same file use the same parser consistently.
pub fn parseCheckLine(line: []const u8, cached_format: *?LineFormat) ?LineInfo {
    if (parseAlgoBased(line)) |info| return info;
    if (cached_format.*) |cf| {
        return switch (cf) {
            .untagged => parseUntagged(line),
            .single_space => parseSingleSpace(line),
            .algo_based => unreachable,
        };
    }
    if (parseUntagged(line)) |info| {
        cached_format.* = .untagged;
        return info;
    }
    if (parseSingleSpace(line)) |info| {
        cached_format.* = .single_space;
        return info;
    }
    return null;
}

/// Decodes a checksum string as hex first, falling back to base64 (uucore's
/// `get_raw_expected_digest`). `len_hint_bytes`, when known, disambiguates and is
/// required to match.
pub fn decodeExpectedDigest(gpa: std.mem.Allocator, checksum: []const u8, len_hint_bytes: ?usize) ?[]u8 {
    if (checksum.len % 2 != 0) return null;
    if (len_hint_bytes == null or len_hint_bytes.? == checksum.len / 2) {
        if (hexDecode(gpa, checksum)) |bytes| return bytes;
    }
    if (checksum.len % 4 != 0) return null;
    if (base64DecodeLenient(gpa, checksum)) |bytes| {
        if (len_hint_bytes == null or len_hint_bytes.? == bytes.len) return bytes;
        gpa.free(bytes);
    }
    return null;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn hexDecode(gpa: std.mem.Allocator, s: []const u8) ?[]u8 {
    if (s.len % 2 != 0) return null;
    var out = gpa.alloc(u8, s.len / 2) catch return null;
    var i: usize = 0;
    while (i < s.len) : (i += 2) {
        const hi = hexVal(s[i]) orelse {
            gpa.free(out);
            return null;
        };
        const lo = hexVal(s[i + 1]) orelse {
            gpa.free(out);
            return null;
        };
        out[i / 2] = (hi << 4) | lo;
    }
    return out;
}

fn b64Val(c: u8) ?u8 {
    return switch (c) {
        'A'...'Z' => c - 'A',
        'a'...'z' => c - 'a' + 26,
        '0'...'9' => c - '0' + 52,
        '+' => 62,
        '/' => 63,
        else => null,
    };
}

/// Small forgiving base64 decoder for check-mode digests (tolerates missing/incorrect
/// padding, matching uutils' `base64_simd::forgiving_decode_to_vec` usage there).
fn base64DecodeLenient(gpa: std.mem.Allocator, s_in: []const u8) ?[]u8 {
    var s = s_in;
    while (s.len > 0 and s[s.len - 1] == '=') s = s[0 .. s.len - 1];
    if (s.len == 0) return gpa.alloc(u8, 0) catch null;
    const out_len = (s.len * 6) / 8;
    var out = gpa.alloc(u8, out_len) catch return null;
    var acc: u32 = 0;
    var acc_bits: u6 = 0;
    var o: usize = 0;
    for (s) |c| {
        const v = b64Val(c) orelse {
            gpa.free(out);
            return null;
        };
        acc = (acc << 6) | v;
        acc_bits += 6;
        if (acc_bits >= 8) {
            const shift: u5 = @intCast(acc_bits - 8);
            out[o] = @intCast((acc >> shift) & 0xff);
            o += 1;
            acc_bits -= 8;
        }
    }
    return out[0..o];
}

// ============================================================================
// Check-mode: file-driving orchestration (uucore::checksum::validate).
// ============================================================================

pub const CheckVerbose = enum(u8) { status = 0, quiet = 1, normal = 2, warning = 3 };

pub fn checkVerboseFromFlags(status: bool, quiet: bool, warn: bool) CheckVerbose {
    if (status) return .status;
    if (quiet) return .quiet;
    if (warn) return .warning;
    return .normal;
}

fn overStatus(v: CheckVerbose) bool {
    return @intFromEnum(v) > @intFromEnum(CheckVerbose.status);
}
fn overQuiet(v: CheckVerbose) bool {
    return @intFromEnum(v) > @intFromEnum(CheckVerbose.quiet);
}
fn atLeastWarning(v: CheckVerbose) bool {
    return @intFromEnum(v) >= @intFromEnum(CheckVerbose.warning);
}

pub const CheckOptions = struct {
    ignore_missing: bool = false,
    strict: bool = false,
    verbose: CheckVerbose = .normal,
};

const LineOutcome = enum { ok, mismatch, improperly_formatted, cant_open_file, file_not_found, file_is_directory, skipped };

const CheckStats = struct {
    total: u32 = 0,
    bad_format: u32 = 0,
    failed_cksum: u32 = 0,
    failed_open_file: u32 = 0,
    correct: u32 = 0,

    fn properlyFormatted(self: CheckStats) u32 {
        return self.total - self.bad_format;
    }
};

fn cliAlgoUppercaseName(a: CliAlgo) []const u8 {
    return switch (a) {
        .sysv => "SYSV",
        .bsd => "BSD",
        .crc => "CRC",
        .crc32b => "CRC32B",
        .md5 => "MD5",
        .sm3 => "SM3",
        .sha1 => "SHA1",
        .sha2 => "SHA2",
        .sha3 => "SHA3",
        .blake2b => "BLAKE2b",
        .sha224 => "SHA224",
        .sha256 => "SHA256",
        .sha384 => "SHA384",
        .sha512 => "SHA512",
        .blake3 => "BLAKE3",
        .shake128 => "SHAKE128",
        .shake256 => "SHAKE256",
    };
}

/// The digest byte length implied by a CLI-selected FIXED algorithm (md5/sha1/sm3/the
/// concrete sha2 sizes) -- used as the length hint when decoding a checksum from an
/// untagged/single-space line. Variable-length algorithms (blake2b/blake3/shake/the
/// sha2/sha3 umbrellas) return `null` here (their length comes from elsewhere).
fn expectedDigestBytes(a: CliAlgo) ?usize {
    return switch (a) {
        .md5 => 16,
        .sm3 => 32,
        .sha1 => 20,
        .sha224 => 28,
        .sha256 => 32,
        .sha384 => 48,
        .sha512 => 64,
        else => null,
    };
}

fn lowerInto(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..s.len];
}

fn checkOneFile(ctx: *Ctx, prog: []const u8, filename_raw: []const u8, expected: []const u8, sized: Sized, opts: CheckOptions) LineOutcome {
    const filename = unescapeFilename(ctx.gpa, filename_raw) catch filename_raw;
    const is_stdin = std.mem.eql(u8, filename, "-");

    var fd: sys.Fd = undefined;
    if (is_stdin) {
        fd = ctx.stdin;
    } else {
        const st = sys.stat(filename) catch |e| {
            if (!opts.ignore_missing) {
                ctx.errPrint("{s}: {s}: {s}\n", .{ prog, filename, sys.strerror(sys.toErrno(e)) });
                ctx.outPrint("{s}: FAILED open or read\n", .{filename});
            }
            return .file_not_found;
        };
        if (st.is_dir) {
            ctx.errPrint("{s}: {s}: Is a directory\n", .{ prog, filename });
            ctx.outPrint("{s}: FAILED open or read\n", .{filename});
            return .file_is_directory;
        }
        fd = sys.open(filename, .{ .read = true }) catch |e| {
            if (!opts.ignore_missing) {
                ctx.errPrint("{s}: {s}: {s}\n", .{ prog, filename, sys.strerror(sys.toErrno(e)) });
                ctx.outPrint("{s}: FAILED open or read\n", .{filename});
            }
            return .file_not_found;
        };
    }
    defer if (!is_stdin) sys.close(fd);

    var d = sized.createDigest();
    var buf: [READ_BUFFER_SIZE]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &buf) catch {
            ctx.outPrint("{s}: FAILED open or read\n", .{filename});
            return .cant_open_file;
        };
        if (n == 0) break;
        d.update(buf[0..n]);
    }
    const got = ctx.gpa.alloc(u8, d.out_bytes) catch @panic("OOM");
    d.finalize(got);
    const matched = std.mem.eql(u8, got, expected);
    if (matched) {
        if (overQuiet(opts.verbose)) ctx.outPrint("{s}: OK\n", .{filename});
    } else {
        if (overStatus(opts.verbose)) ctx.outPrint("{s}: FAILED\n", .{filename});
    }
    return if (matched) .ok else .mismatch;
}

fn processAlgoBasedLine(ctx: *Ctx, prog: []const u8, info: LineInfo, cli_algo: ?CliAlgo, opts: CheckOptions, last_algo: *?[]const u8) LineOutcome {
    var lowerbuf: [32]u8 = undefined;
    const lowered = lowerInto(&lowerbuf, info.algo_name.?) orelse return .improperly_formatted;
    const line_algo = cliAlgoFromString(lowered) orelse return .improperly_formatted;
    last_algo.* = info.algo_name;

    if (cli_algo) |ca| {
        const matches = (ca == line_algo) or
            (ca == .sha2 and (line_algo == .sha224 or line_algo == .sha256 or line_algo == .sha384 or line_algo == .sha512));
        if (!matches) return .improperly_formatted;
    }

    const sized = resolveSized(line_algo, info.algo_bit_len) catch return .improperly_formatted;
    const len_hint: ?usize = switch (line_algo) {
        .blake2b, .blake3, .shake128, .shake256 => sized.outBytes(),
        else => null,
    };
    const expected = decodeExpectedDigest(ctx.gpa, info.checksum, len_hint) orelse return .improperly_formatted;
    defer ctx.gpa.free(expected);
    return checkOneFile(ctx, prog, info.filename, expected, sized, opts);
}

fn processNonAlgoBasedLine(ctx: *Ctx, prog: []const u8, line_no: usize, info: LineInfo, cli_algo: CliAlgo, cli_length: ?usize, opts: CheckOptions) LineOutcome {
    var filename = info.filename;
    if (info.format == .single_space and line_no == 0 and filename.len > 0 and filename[0] == '*') filename = filename[1..];

    const hint = expectedDigestBytes(cli_algo);
    const expected = decodeExpectedDigest(ctx.gpa, info.checksum, hint) orelse return .improperly_formatted;
    defer ctx.gpa.free(expected);

    const length_bits: ?usize = switch (cli_algo) {
        .blake2b, .blake3 => expected.len * 8,
        else => cli_length,
    };
    const sized = resolveSized(cli_algo, length_bits) catch return .improperly_formatted;
    return checkOneFile(ctx, prog, filename, expected, sized, opts);
}

fn processOneLine(
    ctx: *Ctx,
    prog: []const u8,
    line: []const u8,
    line_no: usize,
    cli_algo: ?CliAlgo,
    cli_length: ?usize,
    opts: CheckOptions,
    cached_format: *?LineFormat,
    last_algo: *?[]const u8,
) LineOutcome {
    if (line.len == 0 or line[0] == '#') return .skipped;
    const info = parseCheckLine(line, cached_format) orelse return .improperly_formatted;
    if (info.format == .algo_based) {
        return processAlgoBasedLine(ctx, prog, info, cli_algo, opts, last_algo);
    }
    const cli = cli_algo orelse return .improperly_formatted;
    return processNonAlgoBasedLine(ctx, prog, line_no, info, cli, cli_length, opts);
}

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}
fn isAre(n: u32) []const u8 {
    return if (n == 1) "is" else "are";
}

/// Processes one `-c` checksum-list file/stdin operand. Returns `true` if this
/// operand's overall result counts as a failure (mirrors `FileCheckError::{Failed,
/// CantOpenChecksumFile}`).
fn checkFile(ctx: *Ctx, prog: []const u8, cli_algo: ?CliAlgo, cli_length: ?usize, opts: CheckOptions, filename_input: []const u8) bool {
    const is_stdin = std.mem.eql(u8, filename_input, "-");
    var fd: sys.Fd = undefined;
    if (is_stdin) {
        fd = ctx.stdin;
    } else {
        const st = sys.stat(filename_input) catch {
            ctx.errPrint("{s}: {s}: No such file or directory\n", .{ prog, filename_input });
            return true;
        };
        if (st.is_dir) {
            ctx.errPrint("{s}: {s}: Is a directory\n", .{ prog, filename_input });
            return true;
        }
        fd = sys.open(filename_input, .{ .read = true }) catch {
            ctx.errPrint("{s}: {s}: No such file or directory\n", .{ prog, filename_input });
            return true;
        };
    }
    defer if (!is_stdin) sys.close(fd);

    var stats = CheckStats{};
    var cached_format: ?LineFormat = null;
    var last_algo: ?[]const u8 = null;
    var lr = textio.LineReader.init(fd);
    var line_no: usize = 0;
    while (true) {
        const maybe_line = lr.next() catch break;
        const line = maybe_line orelse break;
        const outcome = processOneLine(ctx, prog, line, line_no, cli_algo, cli_length, opts, &cached_format, &last_algo);
        if (outcome != .skipped) stats.total += 1;
        switch (outcome) {
            .ok => stats.correct += 1,
            .mismatch => stats.failed_cksum += 1,
            .improperly_formatted => {
                stats.bad_format += 1;
                if (atLeastWarning(opts.verbose)) {
                    const algo = if (cli_algo) |ca| cliAlgoUppercaseName(ca) else (last_algo orelse "Unknown algorithm");
                    ctx.errPrint("{s}: {s}: {d}: improperly formatted {s} checksum line\n", .{ prog, filename_input, line_no + 1, algo });
                }
            },
            .cant_open_file, .file_is_directory => stats.failed_open_file += 1,
            .file_not_found => if (!opts.ignore_missing) {
                stats.failed_open_file += 1;
            },
            .skipped => {},
        }
        line_no += 1;
    }

    const display_name = if (is_stdin) "standard input" else filename_input;
    if (stats.properlyFormatted() == 0) {
        if (overStatus(opts.verbose)) ctx.errPrint("{s}: {s}: no properly formatted checksum lines found\n", .{ prog, display_name });
        return true;
    }
    if (overStatus(opts.verbose)) {
        if (stats.bad_format > 0) ctx.errPrint("{s}: WARNING: {d} line{s} {s} improperly formatted\n", .{ prog, stats.bad_format, plural(stats.bad_format), isAre(stats.bad_format) });
        if (stats.failed_cksum > 0) ctx.errPrint("{s}: WARNING: {d} computed checksum{s} did NOT match\n", .{ prog, stats.failed_cksum, plural(stats.failed_cksum) });
        if (stats.failed_open_file > 0) ctx.errPrint("{s}: WARNING: {d} listed file{s} could not be read\n", .{ prog, stats.failed_open_file, plural(stats.failed_open_file) });
    }
    if (opts.ignore_missing and stats.correct == 0) {
        if (overStatus(opts.verbose)) ctx.errPrint("{s}: {s}: no file was verified\n", .{ prog, display_name });
        return true;
    }
    if (opts.strict and stats.bad_format > 0) return true;
    if (stats.failed_open_file > 0 and !opts.ignore_missing) return true;
    if (stats.failed_cksum > 0) return true;
    return false;
}

/// Mirrors `perform_checksum_validation`: runs `-c` over every checksum-list operand,
/// returning the process exit code (0 if every operand fully verified, 1 otherwise).
pub fn checkFiles(ctx: *Ctx, prog: []const u8, cli_algo: ?CliAlgo, cli_length: ?usize, opts: CheckOptions, files: []const []const u8) u8 {
    var failed = false;
    for (files) |f| {
        if (checkFile(ctx, prog, cli_algo, cli_length, opts, f)) failed = true;
    }
    return if (failed) 1 else 0;
}
