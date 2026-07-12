//! `file`'s detection engine (DESIGN.md §7.6): the ~35-entry byte-signature table
//! ported from the vendored `infer` crate (`reference/crates/infer-0.16.0/src/matchers/`)
//! plus the port's shebang/JSON/XML/HTML/text heuristics
//! (the `file` entry). A flat table + a handful of prefix probes; no libmagic.
//!
//! No `sys`/`std.fs`/`std.Io` dependency here -- this module is pure bytes-in,
//! `Result`-out (DESIGN.md §11: size rules). The applet (`src/applets/file.zig`) does
//! all the I/O and calls `identify()`.
//!
//! Order of checks (matrix, `file` entry): magic-byte table first, then shebang, then
//! is_json/is_xml/is_html, then is_text, then the "data" fallthrough.
//!
//! MIME strings are copied verbatim from `reference/crates/infer-0.16.0/src/map.rs`
//! (the crate's own `mime_type()` table) wherever a signature is ported from infer;
//! they are normative even though the English descriptions are ours to choose
//! (source: spec, per the task ledger). Descriptions use the exact strings pre-approved
//! in the porting brief where given (JSON/XML/HTML/text/data + the ~35 signature list).

const std = @import("std");

pub const Result = struct {
    desc: []const u8,
    mime: []const u8,
};

// ---------------------------------------------------------------------- helpers

/// True iff `bytes` is at least `offset + pattern.len` long and matches `pattern`
/// starting at `offset`.
fn hasAt(bytes: []const u8, offset: usize, pattern: []const u8) bool {
    if (bytes.len < offset + pattern.len) return false;
    return std.mem.eql(u8, bytes[offset..][0..pattern.len], pattern);
}

// ---------------------------------------------------------------------- signature table

const Sig = struct {
    offset: usize = 0,
    pattern: []const u8,
    /// Overrides the default `offset + pattern.len` length gate. Needed only where
    /// infer's guard (`buf.len() > N`) requires more bytes than the pattern itself
    /// spans (ELF's `buf.len() > 52` against a 4-byte pattern; TIFF's `buf.len() > 9`
    /// against a 4-byte pattern, dropping infer's CR2-differentiation bytes 8/9 which
    /// we don't replicate -- see ledger).
    minlen: ?usize = null,
    desc: []const u8,
    mime: []const u8,
};

fn sigMatches(bytes: []const u8, s: Sig) bool {
    const need = s.minlen orelse (s.offset + s.pattern.len);
    if (bytes.len < need) return false;
    return hasAt(bytes, s.offset, s.pattern);
}

/// Straight single-pattern-at-offset signatures, in infer's own map.rs grouping order
/// (app, image, video/font/audio, archive) so that overlapping prefixes resolve the
/// same way infer's `iter().find()` would. Multi-part / conditional signatures (java
/// class vs Mach-O FAT sharing 0xCAFEBABE, WAV/AVI's two-part RIFF check, MKV vs WEBM's
/// shared EBML prefix, MP4's brand list) are NOT in this table -- see the dedicated
/// `is*` functions below, consulted first by `magicMatch`.
const signatures = [_]Sig{
    // -- app --
    .{ .pattern = &[_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 }, .desc = "WebAssembly binary module", .mime = "application/wasm" },
    .{ .pattern = &[_]u8{ 0x7F, 0x45, 0x4C, 0x46 }, .minlen = 53, .desc = "ELF executable", .mime = "application/x-executable" },
    .{ .pattern = "MZ", .desc = "PE32 executable (MS-DOS/Windows executable)", .mime = "application/vnd.microsoft.portable-executable" },
    // -- image --
    .{ .pattern = &[_]u8{ 0xFF, 0xD8, 0xFF }, .desc = "JPEG image", .mime = "image/jpeg" },
    .{ .pattern = &[_]u8{ 0x89, 0x50, 0x4E, 0x47 }, .desc = "PNG image", .mime = "image/png" },
    .{ .pattern = "GIF", .desc = "GIF image", .mime = "image/gif" },
    .{ .offset = 8, .pattern = "WEBP", .desc = "WebP image", .mime = "image/webp" },
    .{ .pattern = &[_]u8{ 0x49, 0x49, 0x2A, 0x00 }, .minlen = 10, .desc = "TIFF image", .mime = "image/tiff" },
    .{ .pattern = &[_]u8{ 0x4D, 0x4D, 0x00, 0x2A }, .minlen = 10, .desc = "TIFF image", .mime = "image/tiff" },
    .{ .pattern = "BM", .desc = "BMP image", .mime = "image/bmp" },
    .{ .pattern = &[_]u8{ 0x00, 0x00, 0x01, 0x00 }, .desc = "ICO image", .mime = "image/vnd.microsoft.icon" },
    // -- video --
    .{ .pattern = &[_]u8{ 0x1A, 0x45, 0xDF, 0xA3 }, .desc = "WebM video", .mime = "video/webm" },
    // -- font --
    .{ .pattern = &[_]u8{ 0x77, 0x4F, 0x46, 0x46, 0x00, 0x01, 0x00, 0x00 }, .desc = "Web Open Font Format (WOFF)", .mime = "application/font-woff" },
    .{ .pattern = &[_]u8{ 0x77, 0x4F, 0x46, 0x32, 0x00, 0x01, 0x00, 0x00 }, .desc = "Web Open Font Format 2 (WOFF2)", .mime = "application/font-woff" },
    .{ .pattern = &[_]u8{ 0x00, 0x01, 0x00, 0x00, 0x00 }, .desc = "TrueType font", .mime = "application/font-sfnt" },
    .{ .pattern = &[_]u8{ 0x4F, 0x54, 0x54, 0x4F, 0x00 }, .desc = "OpenType font", .mime = "application/font-sfnt" },
    // -- audio --
    .{ .pattern = "ID3", .desc = "MP3 audio", .mime = "audio/mpeg" },
    .{ .pattern = &[_]u8{ 0xFF, 0xFB }, .minlen = 3, .desc = "MP3 audio", .mime = "audio/mpeg" },
    .{ .pattern = "OggS", .desc = "Ogg data", .mime = "audio/ogg" },
    .{ .pattern = &[_]u8{ 0x66, 0x4C, 0x61, 0x43 }, .desc = "FLAC audio", .mime = "audio/x-flac" },
    // -- archive --
    .{ .pattern = &[_]u8{ 0x50, 0x4B, 0x03, 0x04 }, .desc = "Zip archive", .mime = "application/zip" },
    .{ .pattern = &[_]u8{ 0x50, 0x4B, 0x05, 0x06 }, .desc = "Zip archive", .mime = "application/zip" },
    .{ .pattern = &[_]u8{ 0x50, 0x4B, 0x07, 0x08 }, .desc = "Zip archive", .mime = "application/zip" },
    .{ .pattern = &[_]u8{ 0x50, 0x4B, 0x30, 0x30, 0x50, 0x4B, 0x03, 0x04 }, .desc = "Zip archive", .mime = "application/zip" }, // winzip
    .{ .offset = 257, .pattern = "ustar", .desc = "POSIX tar archive", .mime = "application/x-tar" },
    .{ .pattern = &[_]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00 }, .desc = "RAR archive", .mime = "application/vnd.rar" },
    .{ .pattern = &[_]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01 }, .desc = "RAR archive", .mime = "application/vnd.rar" },
    .{ .pattern = &[_]u8{ 0x1F, 0x8B, 0x08 }, .desc = "gzip compressed data", .mime = "application/gzip" },
    .{ .pattern = &[_]u8{ 0x42, 0x5A, 0x68 }, .desc = "bzip2 compressed data", .mime = "application/x-bzip2" },
    .{ .pattern = &[_]u8{ 0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C }, .desc = "7-Zip archive", .mime = "application/x-7z-compressed" },
    .{ .pattern = &[_]u8{ 0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00 }, .desc = "XZ compressed data", .mime = "application/x-xz" },
    .{ .pattern = &[_]u8{ 0x25, 0x50, 0x44, 0x46 }, .desc = "PDF document", .mime = "application/pdf" },
    .{ .pattern = &[_]u8{ 0x53, 0x51, 0x4C, 0x69 }, .desc = "SQLite 3.x database", .mime = "application/vnd.sqlite3" },
    .{ .pattern = &[_]u8{ 0x28, 0xB5, 0x2F, 0xFD }, .desc = "Zstandard compressed data", .mime = "application/zstd" }, // skippable-frame form not ported (see ledger)
};

// ---------------------------------------------------------------------- special-cased signatures

/// Java class file (0xCAFEBABE) vs Mach-O FAT binary (same magic) share a prefix;
/// distinguished by the (bogus for Mach-O) "major version" field, exactly like
/// `infer::app::is_java`.
fn isJavaClass(b: []const u8) bool {
    if (!hasAt(b, 0, &[_]u8{ 0xCA, 0xFE, 0xBA, 0xBE })) return false;
    if (b.len < 8) return false;
    const major: u16 = (@as(u16, b[6]) << 8) | b[7];
    return major >= 45;
}

/// Mach-O: two thin-binary magic variants (32/64-bit, either endianness) plus the FAT
/// variant that shares 0xCAFEBABE with Java class files (`infer::app::is_mach`).
fn isMachO(b: []const u8) bool {
    if (b.len < 4) return false;
    if ((b[0] == 0xCF or b[0] == 0xCE) and b[1] == 0xFA and b[2] == 0xED and b[3] == 0xFE) return true;
    if (b[0] == 0xFE and b[1] == 0xED and b[2] == 0xFA and (b[3] == 0xCF or b[3] == 0xCE)) return true;
    if (b.len >= 8 and hasAt(b, 0, &[_]u8{ 0xCA, 0xFE, 0xBA, 0xBE })) {
        const val: u32 = (@as(u32, b[4]) << 24) | (@as(u32, b[5]) << 16) | (@as(u32, b[6]) << 8) | b[7];
        return val < 45;
    }
    return false;
}

/// Matroska: EBML header (4 bytes) immediately followed by ascii "matroska" (the
/// 16-byte prefix), OR "matroska" appearing again at offset 31 (`infer::video::is_mkv`
/// -- two variants because different muxers place the DocType element at different
/// spots in practice). Checked before WEBM's plain 4-byte EBML-only signature so a
/// Matroska file (which also matches WEBM's shorter prefix) is reported as Matroska.
fn isMkv(b: []const u8) bool {
    if (hasAt(b, 0, &[_]u8{ 0x1A, 0x45, 0xDF, 0xA3, 0x93, 0x42, 0x82, 0x88, 'm', 'a', 't', 'r', 'o', 's', 'k', 'a' })) return true;
    return hasAt(b, 31, "matroska");
}

/// RIFF....WAVE (`infer::audio::is_wav`).
fn isWav(b: []const u8) bool {
    return hasAt(b, 0, "RIFF") and hasAt(b, 8, "WAVE");
}

/// RIFF....AVI (infer checks only 3 bytes "AVI", not "AVI ", at offset 8 --
/// `infer::video::is_avi`).
fn isAvi(b: []const u8) bool {
    return hasAt(b, 0, "RIFF") and hasAt(b, 8, "AVI");
}

/// A representative subset of `infer::video::is_mp4`'s ~25-brand allowlist at offset 8
/// (immediately after "ftyp" at offset 4) -- isom/iso2/mp41/mp42/avc1/dash cover the
/// overwhelming majority of real MP4 files; the long tail (NDSC/F4V/MSNV/... brands) is
/// not ported (source: spec simplification, see ledger).
const mp4_brands = [_][]const u8{ "isom", "iso2", "mp41", "mp42", "avc1", "dash" };
fn isMp4(b: []const u8) bool {
    if (!hasAt(b, 4, "ftyp")) return false;
    for (mp4_brands) |brand| {
        if (hasAt(b, 8, brand)) return true;
    }
    return false;
}

fn magicMatch(bytes: []const u8) ?Result {
    if (isJavaClass(bytes)) return .{ .desc = "Java class file (compiled)", .mime = "application/java" };
    if (isMachO(bytes)) return .{ .desc = "Mach-O executable", .mime = "application/x-mach-binary" };
    if (isMkv(bytes)) return .{ .desc = "Matroska video", .mime = "video/x-matroska" };
    if (isMp4(bytes)) return .{ .desc = "MP4 video", .mime = "video/mp4" };
    if (isWav(bytes)) return .{ .desc = "WAVE audio", .mime = "audio/x-wav" };
    if (isAvi(bytes)) return .{ .desc = "AVI video", .mime = "video/x-msvideo" };
    for (signatures) |s| {
        if (sigMatches(bytes, s)) return .{ .desc = s.desc, .mime = s.mime };
    }
    return null;
}

// ---------------------------------------------------------------------- shebang

fn isWs(b: u8) bool {
    return b == ' ' or b == '\t';
}

/// `#!/interpreter/path [args...]` -> basename of the interpreter path, with the `env`
/// special case (`#!/usr/bin/env python3` -> `python3`, taking the *next* whitespace
/// token verbatim instead of `env`'s own basename). Formats
/// "{prog} script, ASCII text executable" into a small static per-call buffer: this
/// module takes no allocator (pure bytes-in/Result-out, no `sys`/gpa dependency --
/// DESIGN.md §11), and `file` is single-threaded/one-shot-per-process, so a static
/// buffer reused across calls within one process is safe here.
var shebang_desc_buf: [256]u8 = undefined;

fn shebangResult(bytes: []const u8) ?Result {
    if (bytes.len < 2 or bytes[0] != '#' or bytes[1] != '!') return null;
    const nl = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
    var line = bytes[2..nl];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    var i: usize = 0;
    while (i < line.len and isWs(line[i])) : (i += 1) {}
    line = line[i..];

    var tok_end: usize = 0;
    while (tok_end < line.len and !isWs(line[tok_end])) : (tok_end += 1) {}
    const interp = line[0..tok_end];
    var rest = line[tok_end..];
    i = 0;
    while (i < rest.len and isWs(rest[i])) : (i += 1) {}
    rest = rest[i..];

    var prog = interp;
    if (std.mem.lastIndexOfScalar(u8, interp, '/')) |slash| prog = interp[slash + 1 ..];

    if (std.mem.eql(u8, prog, "env")) {
        var tok2_end: usize = 0;
        while (tok2_end < rest.len and !isWs(rest[tok2_end])) : (tok2_end += 1) {}
        prog = if (tok2_end > 0) rest[0..tok2_end] else "env";
    }

    const suffix = " script, ASCII text executable";
    const total = @min(prog.len, shebang_desc_buf.len - suffix.len);
    @memcpy(shebang_desc_buf[0..total], prog[0..total]);
    @memcpy(shebang_desc_buf[total..][0..suffix.len], suffix);
    return .{ .desc = shebang_desc_buf[0 .. total + suffix.len], .mime = "text/x-script" };
}

// ---------------------------------------------------------------------- text-family heuristics

fn skipLeadingWs(bytes: []const u8) []const u8 {
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        switch (bytes[i]) {
            ' ', '\t', '\n', '\r', 0x0C => continue,
            else => break,
        }
    }
    return bytes[i..];
}

fn isJson(bytes: []const u8) bool {
    const b = skipLeadingWs(bytes);
    if (b.len == 0) return false;
    return b[0] == '{' or b[0] == '[';
}

fn startsWithCi(bytes: []const u8, needle: []const u8) bool {
    if (bytes.len < needle.len) return false;
    for (needle, 0..) |c, idx| {
        if (std.ascii.toLower(bytes[idx]) != std.ascii.toLower(c)) return false;
    }
    return true;
}

/// `<?xml` or `<!DOCTYPE`, case-insensitive, after skipping leading whitespace
/// (documented choice: the matrix allows either case-sensitivity; we chose
/// case-insensitive to match infer's own `is_xml` whitespace-trimming behavior more
/// closely -- source: spec judgment call, see ledger).
fn isXml(bytes: []const u8) bool {
    const b = skipLeadingWs(bytes);
    return startsWithCi(b, "<?xml") or startsWithCi(b, "<!DOCTYPE");
}

/// Lowercased content starts with `<!doctype html` or `<html` (matrix's exact wording
/// for `file`'s `is_html`, simpler than infer's own multi-tag whitelist -- we follow
/// the matrix, not infer, here since the matrix is the pre-approved spec for this
/// heuristic).
fn isHtml(bytes: []const u8) bool {
    const b = skipLeadingWs(bytes);
    return startsWithCi(b, "<!doctype html") or startsWithCi(b, "<html");
}

/// No NUL byte anywhere, and every byte is TAB/LF/CR/FF/BS/ESC or >= 0x20 (admits
/// 8-bit bytes -- not ASCII-only, per the matrix).
fn isText(bytes: []const u8) bool {
    for (bytes) |b| {
        switch (b) {
            0x00 => return false,
            0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x1B => continue,
            else => if (b < 0x20) return false,
        }
    }
    return true;
}

// ---------------------------------------------------------------------- public API

/// Identifies `bytes` (the first up-to-8192 bytes of a file, or a whole small buffer
/// for stdin/`-`). Empty input -> "empty"/`inode/x-empty` (the applet also handles the
/// zero-size case itself via `stat.size == 0` before ever opening a regular file, so
/// this path is mainly exercised by an empty stdin read -- see file.zig).
pub fn identify(bytes: []const u8) Result {
    if (bytes.len == 0) return .{ .desc = "empty", .mime = "inode/x-empty" };
    if (magicMatch(bytes)) |r| return r;
    if (shebangResult(bytes)) |r| return r;
    if (isJson(bytes)) return .{ .desc = "JSON data", .mime = "application/json" };
    // NOTE: is_html is checked before is_xml here, even though the matrix lists
    // "is_json/is_xml/is_html" in that textual order. is_xml's `<!DOCTYPE` branch is a
    // byte-for-byte (case-insensitive) prefix of is_html's `<!doctype html` branch, so
    // an ordinary HTML5 document (`<!doctype html>...`) would otherwise be reported as
    // XML -- clearly not the intent of a `file`-clone. json is unaffected (JSON starts
    // with `{`/`[`, disjoint from both). Source: spec judgment call, see ledger.
    if (isHtml(bytes)) return .{ .desc = "HTML document", .mime = "text/html" };
    if (isXml(bytes)) return .{ .desc = "XML 1.0 document", .mime = "text/xml" };
    if (isText(bytes)) return .{ .desc = "ASCII text", .mime = "text/plain" };
    return .{ .desc = "data", .mime = "application/octet-stream" };
}
