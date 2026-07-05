//! `od` -- docs/analysis/uutils-applets.md: typed multi-format octal/decimal/hex/float/
//! char dumper. Custom argv scanner (mirrors uutils od's parse_formats.rs) since the
//! declarative `core/cli.zig` parser can't express `-fvoxw16` clustering with mixed
//! flag/value semantics and clap's "optional value" args (`-w[N]`, `-S[N]`). One
//! left-to-right scan of `ctx.args` handles both (1) format specs (`-t TYPE[SIZE][z]`,
//! repeatable + single-letter legacy flags `a b c d D o O u x X h H i I l L s e f F`)
//! and (2) the "other" options (`-A radix`, `-j skip`, `-N limit`, `-S[n]`, `-v`,
//! `-w[n]`, `--endian`) + FILE operands. Default (no `-t`/legacy flag) is `-t o2`
//! (2-byte octal), octal addressing, width 16.
//!
//! Byte-parity notes (oracle: uutils-coreutils 0.9.0 via `reference/uutils-coreutils`):
//! - `-w`/`-S` are clap "optional value" args: an attached value (`-w16`) or an
//!   unattached FOLLOWING token that doesn't start with `-` is consumed as the value
//!   (even if it fails to parse as a number -- that's an error, not a fallback to
//!   treating it as a FILE operand); otherwise the default (32 / 3) applies.
//! - `-A`/`-j`/`-N`/`-t` always consume a value: attached, else the very next token
//!   unconditionally (even if it looks like a flag).
//! - float formatters: `-t f`/`fD`/`-e`/`-F` = f64 (25-wide); `-t fF`/`-f` = f32
//!   (16-wide); `-t fH`/`f2` = binary16, `-t fB` = bfloat16 (both TRIMMED reprs, unlike
//!   f32/f64 -- trailing fraction zeros and the point itself are stripped, then
//!   re-padded); `-t fL`/`f16` = a 16-byte blob read as a binary128-like bit layout (1
//!   sign + 15 exp + 112 mantissa) narrowed to f64, formatted with RAW Rust `{:.21e}`
//!   (bare exponent: no `+`, no zero-pad) -- confirmed empirically, not derivable from
//!   the CLI docs alone.
//! - the running address starts at `skip_bytes` even when the skip itself fails (EOF
//!   before the skip completes): the final-offset line still prints the REQUESTED
//!   skip value, not how far the read actually got.
//! - duplicate-line elision (`*`) only ever compares FULL (width-sized) lines; a
//!   final short line is never elided and never updates the "previous line" baseline.
//!
//! Deliberately out of scope (documented ledger gaps, not silently faked):
//! - `--traditional` and the bare `FILE [+][0x]OFFSET[.][b]` positional-offset
//!   convenience (both are accepted-but-inert here: operands are always FILEs).
//! - true IEEE subnormal f32/f64 inputs render via a precision-8/17 scientific
//!   fallback rather than Rust's shortest-round-trip `{:e}` (the reference's OWN
//!   subnormal path for f32/f64 -- unlike f16/bf16, which use an explicit precision).

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const fmtnum = @import("../core/fmtnum.zig");
const Ctx = @import("../ctx.zig").Ctx;

const PROG = "od";

const help_doc = cli.Help{
    .summary = "dump files in octal, decimal, hex, float, or character format",
    .synopsis = &.{"od [OPTION]... [FILE]..."},
    .description =
    \\Dumps the contents of FILE (or standard input, with no FILE or FILE `-`;
    \\multiple FILEs are concatenated into one logical stream) in one or more
    \\parallel typed columns, each row prefixed by its byte offset. The type/format
    \\grammar (`-t TYPE[SIZE][z]`, repeatable, or the single-letter legacy flags `a b
    \\c d D o O u x X h H i I l L s e f F`) selects octal/decimal/unsigned/hex
    \\integers (SIZE one of `1 2 4 8` or `C S I L`), an ASCII-name (`a`) or C-escape
    \\(`c`) character dump, or floats (`f`, SIZE `4 8 16` or `F D L`, plus the 2-byte
    \\`H`/`B` = binary16/bfloat16 variants); several `-t`/legacy-flag groups may be
    \\given to print multiple formats per row, columns aligned to the widest one. A
    \\`z` suffix on a format group appends a trailing ASCII gutter to that row.
    \\
    \\`-A radix` selects the offset radix (`o`/`d`/`x`/`n`, default `o`);
    \\`-j skip`/`-N limit` skip/limit the bytes read; `-w N` sets the row width in bytes
    \\(default 16, must be a multiple of the widest requested type).
    \\`-S`/`--strings[=N]` switches to extracting and printing NUL-terminated runs of printable
    \\ASCII at least N bytes long (default 3), ignoring `-t` entirely. Consecutive
    \\duplicate full-width rows are collapsed to a single `*` line unless
    \\`-v`/`--output-duplicates` is given.
    ,
    .options_note = "od's option grammar (short-flag clustering with mixed value/legacy-format semantics, e.g. -fvoxw16) cannot be expressed by the declarative flag table this section would otherwise auto-render from; see DESCRIPTION for the -t/-A/-j/-N/-S/-w/-v/--endian grammar.",
    .operands = "FILE... (default -, meaning standard input); FILEs are concatenated into a single logical byte stream before any dump/skip/read/strings processing.",
    .exit = &.{
        .{ .code = 0, .when = "success" },
        .{ .code = 1, .when = "a FILE could not be opened or read, an option's argument was malformed or out of range, the requested skip ran past the end of input, or an unrecognized option/format letter was given" },
    },
    .deviations_from = "uutils coreutils 0.9.0 od",
    .deviations = &.{
        "--traditional and the classic bare FILE [+][0x]OFFSET[.][b] positional-offset syntax are accepted but functionally inert; operands are always parsed as FILE names, never as an offset.",
        "Subnormal f32/f64 values render via a fixed-precision (8/17 significant digit) scientific fallback rather than the reference's shortest-round-trip formatting; f16/bfloat16 subnormals are unaffected (they already use an explicit precision).",
    },
    .examples = &.{
        .{ .cmd = "printf hi | od -c", .note = "0000000   h   i\\n0000002" },
        .{ .cmd = "od -A x -t x1z FILE", .note = "hex offsets, one hex byte per column, trailing ASCII gutter" },
        .{ .cmd = "od -j 512 -N 16 FILE", .note = "dump 16 bytes starting at offset 512" },
    },
    .see_also = "file (type identification without a byte dump), xxd-style hex dumps via -A x -t x1z.",
};

// ============================================================================ formats

const Radix = enum { octal, decimal, hex, none };

const FmtId = enum {
    oct8, oct16, oct32, oct64,
    hex8, hex16, hex32, hex64,
    decu8, decu16, decu32, decu64,
    decs8, decs16, decs32, decs64,
    a_fmt, c_fmt,
    f16_fmt, bf16_fmt, f32_fmt, f64_fmt, ld_fmt,
};

fn byteSizeOf(id: FmtId) usize {
    return switch (id) {
        .oct8, .hex8, .decu8, .decs8, .a_fmt, .c_fmt => 1,
        .oct16, .hex16, .decu16, .decs16, .f16_fmt, .bf16_fmt => 2,
        .oct32, .hex32, .decu32, .decs32, .f32_fmt => 4,
        .oct64, .hex64, .decu64, .decs64, .f64_fmt => 8,
        .ld_fmt => 16,
    };
}

fn printWidthOf(id: FmtId) usize {
    return switch (id) {
        .oct8 => 4,
        .oct16 => 7,
        .oct32 => 12,
        .oct64 => 23,
        .hex8 => 3,
        .hex16 => 5,
        .hex32 => 9,
        .hex64 => 17,
        .decu8 => 4,
        .decu16 => 6,
        .decu32 => 11,
        .decu64 => 21,
        .decs8 => 5,
        .decs16 => 7,
        .decs32 => 12,
        .decs64 => 21,
        .a_fmt, .c_fmt => 4,
        .f16_fmt, .bf16_fmt, .f32_fmt => 16,
        .f64_fmt => 25,
        .ld_fmt => 40,
    };
}

const ParsedFormat = struct { id: FmtId, add_ascii_dump: bool = false };

/// Single-letter legacy flags (`-a -b -c -d -D -o -O -u... -x -X -h -H -i -I -l -L -s
/// -e -f -F`), mirroring `od_argument_traditional_format`. NOT `-v` (a plain flag) or
/// `-t`/`-A`/`-j`/`-N`/`-S`/`-w` (value-taking, handled separately).
fn traditionalFormat(c: u8) ?FmtId {
    return switch (c) {
        'a' => .a_fmt,
        'B' => .oct16,
        'b' => .oct8,
        'c' => .c_fmt,
        'D' => .decu32,
        'd' => .decu16,
        'e' => .f64_fmt,
        'F' => .f64_fmt,
        'f' => .f32_fmt,
        'H' => .hex32,
        'h' => .hex16,
        'i' => .decs32,
        'I' => .decs64,
        'L' => .decs64,
        'l' => .decs64,
        'O' => .oct32,
        'o' => .oct16,
        's' => .decs16,
        'X' => .hex32,
        'x' => .hex16,
        else => null,
    };
}

/// `-A`/`-j`/`-N`/`-S`/`-w`: all consume a value (attached or next-token), so a format
/// cluster scan must stop here rather than treating trailing chars as format flags.
fn takesValue(c: u8) bool {
    return switch (c) {
        'A', 'j', 'N', 'S', 'w' => true,
        else => false,
    };
}

const FType = enum { ascii, char, decimal_int, octal_int, unsigned_int, hex_int, float };

fn formatTypeOf(c: u8) ?FType {
    return switch (c) {
        'a' => .ascii,
        'c' => .char,
        'd' => .decimal_int,
        'o' => .octal_int,
        'u' => .unsigned_int,
        'x' => .hex_int,
        'f' => .float,
        else => null,
    };
}

const FCat = enum { char_cat, integer_cat, float_cat };

fn categoryOf(t: FType) FCat {
    return switch (t) {
        .ascii, .char => .char_cat,
        .decimal_int, .octal_int, .unsigned_int, .hex_int => .integer_cat,
        .float => .float_cat,
    };
}

fn odFormatType(t: FType, byte_size: u8) ?FmtId {
    return switch (t) {
        .ascii => .a_fmt,
        .char => .c_fmt,
        .decimal_int => switch (byte_size) {
            1 => .decs8,
            2 => .decs16,
            0, 4 => .decs32,
            8 => .decs64,
            else => null,
        },
        .octal_int => switch (byte_size) {
            1 => .oct8,
            2 => .oct16,
            0, 4 => .oct32,
            8 => .oct64,
            else => null,
        },
        .unsigned_int => switch (byte_size) {
            1 => .decu8,
            2 => .decu16,
            0, 4 => .decu32,
            8 => .decu64,
            else => null,
        },
        .hex_int => switch (byte_size) {
            1 => .hex8,
            2 => .hex16,
            0, 4 => .hex32,
            8 => .hex64,
            else => null,
        },
        .float => switch (byte_size) {
            2 => .f16_fmt,
            4 => .f32_fmt,
            0, 8 => .f64_fmt,
            16 => .ld_fmt,
            else => null,
        },
    };
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

const TypeStringError = error{ UnexpectedChar, InvalidNumber, InvalidSize };

/// Ports `parse_type_string`: a single spec string is a back-to-back SEQUENCE of
/// `TYPE[SIZE][z]` groups with no separator, e.g. `"acdx1"` = a, c, d, x1 (four
/// entries). Returns the offending char/size via `bad_char`/`bad_num` (out
/// parameters) since Zig error unions can't carry payload without a wrapper struct.
fn parseTypeString(
    gpa: std.mem.Allocator,
    spec: []const u8,
    out: *std.ArrayListUnmanaged(ParsedFormat),
    bad_char: *u8,
    bad_num: *[]const u8,
) TypeStringError!void {
    var i: usize = 0;
    while (i < spec.len) {
        const type_char = spec[i];
        const ft = formatTypeOf(type_char) orelse {
            bad_char.* = type_char;
            return error.UnexpectedChar;
        };
        const cat = categoryOf(ft);
        i += 1;

        var byte_size: u8 = 0;
        var float_variant: ?u8 = null;

        if (cat == .float_cat) {
            const c: ?u8 = if (i < spec.len) spec[i] else null;
            if (c == @as(u8, 'B') or c == @as(u8, 'H')) {
                byte_size = 2;
                float_variant = c.?;
                i += 1;
            } else if (c == @as(u8, 'F')) {
                byte_size = 4;
                i += 1;
            } else if (c == @as(u8, 'D')) {
                byte_size = 8;
                i += 1;
            } else if (c == @as(u8, 'L')) {
                byte_size = 16;
                i += 1;
            } else {
                const start = i;
                while (i < spec.len and isDigit(spec[i])) : (i += 1) {}
                if (i > start) {
                    byte_size = std.fmt.parseInt(u8, spec[start..i], 10) catch {
                        bad_num.* = spec[start..i];
                        return error.InvalidNumber;
                    };
                }
            }
        } else if (cat == .integer_cat) {
            const c: ?u8 = if (i < spec.len) spec[i] else null;
            const sc: ?u8 = switch (c orelse 0) {
                'C' => 1,
                'S' => 2,
                'I' => 4,
                'L' => 8,
                else => null,
            };
            if (sc) |bs| {
                byte_size = bs;
                i += 1;
            } else {
                const start = i;
                while (i < spec.len and isDigit(spec[i])) : (i += 1) {}
                if (i > start) {
                    byte_size = std.fmt.parseInt(u8, spec[start..i], 10) catch {
                        bad_num.* = spec[start..i];
                        return error.InvalidNumber;
                    };
                }
            }
        }
        // char_cat: no size portion at all (byte_size stays 0, unused by odFormatType).

        var show_ascii_dump = false;
        if (i < spec.len and spec[i] == 'z') {
            show_ascii_dump = true;
            i += 1;
        }

        const id: FmtId = if (float_variant) |v|
            (if (v == 'B') FmtId.bf16_fmt else FmtId.f16_fmt)
        else
            odFormatType(ft, byte_size) orelse {
                bad_num.* = spec; // caller renders the byte_size itself via a second field
                return error.InvalidSize;
            };
        out.append(gpa, .{ .id = id, .add_ascii_dump = show_ascii_dump }) catch @panic("OOM");
    }
}

// ============================================================================ size parsing

const SizeErr = error{ InvalidSuffix, ParseFailure, TooBig };

fn checkedMul(a: u64, b: u64) SizeErr!u64 {
    return std.math.mul(u64, a, b) catch error.TooBig;
}

fn parseDigitsRadix(s: []const u8, radix: u8) SizeErr!u64 {
    if (s.len == 0) return error.ParseFailure;
    return std.fmt.parseUnsigned(u64, s, radix) catch |e| switch (e) {
        error.Overflow => error.TooBig,
        else => error.ParseFailure,
    };
}

/// The generic K/Ki/KiB/M/... suffix table (uucore's `parse_size_u64`, decimal
/// number-system only -- od's caller already special-cases any leading `0`/`0x`
/// before delegating here, so this never needs octal/hex/binary sniffing itself).
fn parseSizeGeneric(s: []const u8) SizeErr!u64 {
    if (s.len == 0) return error.ParseFailure;
    var np: usize = 0;
    while (np < s.len and isDigit(s[np])) : (np += 1) {}
    const digits = s[0..np];
    const unit = s[np..];

    const letters = "KMGTPEZYRQ";
    var base: u64 = 1;
    var exp: u32 = 0;
    if (unit.len == 0) {
        base = 1;
        exp = 0;
    } else if (unit.len == 1 and unit[0] == 'b') {
        base = 512;
        exp = 1;
    } else blk: {
        const first = std.ascii.toUpper(unit[0]);
        const idx = std.mem.indexOfScalar(u8, letters, first) orelse {
            return if (digits.len == 0) error.ParseFailure else error.InvalidSuffix;
        };
        exp = @intCast(idx + 1);
        if (unit.len == 1) {
            base = 1024;
            break :blk;
        }
        if (unit.len == 2 and unit[1] == 'i') {
            base = 1024;
            break :blk;
        }
        if (unit.len == 3 and unit[1] == 'i' and unit[2] == 'B') {
            base = 1024;
            break :blk;
        }
        if (unit.len == 2 and (unit[1] == 'B' or unit[1] == 'D')) {
            base = 1000;
            break :blk;
        }
        return if (digits.len == 0) error.ParseFailure else error.InvalidSuffix;
    }

    const number: u64 = if (digits.len == 0) 1 else try parseDigitsRadix(digits, 10);
    var factor: u64 = 1;
    var k: u32 = 0;
    while (k < exp) : (k += 1) factor = checkedMul(factor, base) catch return error.TooBig;
    return checkedMul(number, factor);
}

/// Ports `parse_nrofbytes.rs`: `0x`/`0X` -> hex (b/E/B-suffix forms excluded, since `b`
/// is itself a valid hex digit and `E`/`B` are gated the same way upstream);
/// leading-`0` -> octal (all suffixes allowed); otherwise decimal, delegated to the
/// generic K/Ki/KiB table (which is never itself asked to sniff octal/hex/binary,
/// since a leading `0` is already routed above).
fn parseNumberOfBytes(s: []const u8) SizeErr!u64 {
    if (s.len == 0) return error.ParseFailure;
    var start: usize = 0;
    var len: usize = s.len;
    var radix: u8 = 16;

    if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) {
        start = 2;
    } else if (s[0] == '0') {
        radix = 8;
    } else {
        return parseSizeGeneric(s);
    }

    var multiply: u64 = 1;
    const last = s[len - 1];
    if (last == 'b' and radix != 16) {
        multiply = 512;
        len -= 1;
    } else if (last == 'k' or last == 'K') {
        multiply = 1024;
        len -= 1;
    } else if (last == 'm' or last == 'M') {
        multiply = 1024 * 1024;
        len -= 1;
    } else if (last == 'G') {
        multiply = 1024 * 1024 * 1024;
        len -= 1;
    } else if (last == 'T') {
        multiply = 1024 * 1024 * 1024 * 1024;
        len -= 1;
    } else if (last == 'P') {
        multiply = 1024 * 1024 * 1024 * 1024 * 1024;
        len -= 1;
    } else if (last == 'E' and radix != 16) {
        multiply = 1024 * 1024 * 1024 * 1024 * 1024 * 1024;
        len -= 1;
    } else if (last == 'B' and radix != 16) {
        if (len < start + 2) return error.ParseFailure;
        len -= 2;
        const c2 = s[len];
        multiply = switch (c2) {
            'k', 'K' => 1000,
            'm', 'M' => 1_000_000,
            'G' => 1_000_000_000,
            'T' => 1_000_000_000_000,
            'P' => 1_000_000_000_000_000,
            'E' => 1_000_000_000_000_000_000,
            else => return error.ParseFailure,
        };
    }

    if (start > len) return error.ParseFailure;
    const factor = try parseDigitsRadix(s[start..len], radix);
    return checkedMul(factor, multiply);
}

// ============================================================================ argv scan

const RawOpts = struct {
    radix_val: ?[]const u8 = null,
    skip_val: ?[]const u8 = null,
    skip_form: []const u8 = "-j",
    read_val: ?[]const u8 = null,
    read_form: []const u8 = "-N",
    endian_val: ?[]const u8 = null,
    strings_given: bool = false,
    strings_val: ?[]const u8 = null,
    strings_form: []const u8 = "-S",
    width_given: bool = false,
    width_val: ?[]const u8 = null,
    width_form: []const u8 = "-w",
    verbose: bool = false,
    files: std.ArrayListUnmanaged([]const u8) = .empty,
};

const Options = struct {
    formats: []ParsedFormat,
    radix: Radix,
    skip_bytes: u64,
    read_bytes: ?u64,
    endian_big: bool,
    strings_min: ?usize,
    verbose: bool,
    width: usize,
    files: []const []const u8,
};

const ParseResult = union(enum) { ok: Options, exit: u8 };

fn nextTokenMandatory(argv: []const [:0]const u8, i: *usize) ?[]const u8 {
    if (i.* + 1 >= argv.len) return null;
    i.* += 1;
    return argv[i.*];
}

fn takeOptionalNext(argv: []const [:0]const u8, i: *usize) ?[]const u8 {
    if (i.* + 1 >= argv.len) return null;
    const nxt = argv[i.* + 1];
    if (nxt.len > 0 and nxt[0] == '-') return null;
    i.* += 1;
    return nxt;
}

fn sizeErrMsg(ctx: *Ctx, form: []const u8, val: []const u8, err: SizeErr) void {
    switch (err) {
        error.InvalidSuffix => ctx.errPrint("{s}: invalid suffix in {s} argument '{s}'\n", .{ PROG, form, val }),
        error.ParseFailure => ctx.errPrint("{s}: invalid {s} argument '{s}'\n", .{ PROG, form, val }),
        error.TooBig => ctx.errPrint("{s}: {s} argument '{s}' too large\n", .{ PROG, form, val }),
    }
}

fn typeStringErr(ctx: *Ctx, e: TypeStringError, spec: []const u8, bad_char: u8, bad_num: []const u8) ParseResult {
    switch (e) {
        error.UnexpectedChar => ctx.errPrint("{s}: unexpected char '{c}' in format specification '{s}'\n", .{ PROG, bad_char, spec }),
        error.InvalidNumber => ctx.errPrint("{s}: invalid number '{s}' in format specification '{s}'\n", .{ PROG, bad_num, spec }),
        error.InvalidSize => ctx.errPrint("{s}: invalid size in format specification '{s}'\n", .{ PROG, spec }),
    }
    return .{ .exit = 1 };
}

fn missingFormatSpec(ctx: *Ctx) ParseResult {
    ctx.errPrint("{s}: missing format specification after '--format' / '-t'\n", .{PROG});
    return .{ .exit = 1 };
}

fn parseArgs(ctx: *Ctx) ParseResult {
    const argv = ctx.args;
    var formats: std.ArrayListUnmanaged(ParsedFormat) = .empty;
    var opt = RawOpts{};
    var no_more_flags = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a: []const u8 = argv[i];
        if (no_more_flags) {
            opt.files.append(ctx.gpa, a) catch @panic("OOM");
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            no_more_flags = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--help")) {
            cli.renderHelp(ctx, PROG, help_doc);
            return .{ .exit = 0 };
        }
        if (std.mem.eql(u8, a, "--version")) {
            ctx.outPrint("{s} (nutils) 0.1.0\n", .{PROG});
            return .{ .exit = 0 };
        }
        if (a.len >= 2 and a[0] == '-' and a[1] == '-') {
            const body = a[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const attached: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;

            if (std.mem.eql(u8, name, "format")) {
                const v = attached orelse (nextTokenMandatory(argv, &i) orelse return missingFormatSpec(ctx));
                var bc: u8 = 0;
                var bn: []const u8 = "";
                parseTypeString(ctx.gpa, v, &formats, &bc, &bn) catch |e| return typeStringErr(ctx, e, v, bc, bn);
            } else if (std.mem.eql(u8, name, "address-radix")) {
                opt.radix_val = attached orelse (nextTokenMandatory(argv, &i) orelse {
                    ctx.errPrint("{s}: option '--address-radix' requires a value\n", .{PROG});
                    return .{ .exit = 1 };
                });
            } else if (std.mem.eql(u8, name, "skip-bytes")) {
                opt.skip_val = attached orelse (nextTokenMandatory(argv, &i) orelse {
                    ctx.errPrint("{s}: option '--skip-bytes' requires a value\n", .{PROG});
                    return .{ .exit = 1 };
                });
                opt.skip_form = "--skip-bytes";
            } else if (std.mem.eql(u8, name, "read-bytes")) {
                opt.read_val = attached orelse (nextTokenMandatory(argv, &i) orelse {
                    ctx.errPrint("{s}: option '--read-bytes' requires a value\n", .{PROG});
                    return .{ .exit = 1 };
                });
                opt.read_form = "--read-bytes";
            } else if (std.mem.eql(u8, name, "endian")) {
                opt.endian_val = attached orelse (nextTokenMandatory(argv, &i) orelse {
                    ctx.errPrint("{s}: option '--endian' requires a value\n", .{PROG});
                    return .{ .exit = 1 };
                });
            } else if (std.mem.eql(u8, name, "strings")) {
                opt.strings_given = true;
                opt.strings_form = "--strings";
                opt.strings_val = attached orelse takeOptionalNext(argv, &i);
            } else if (std.mem.eql(u8, name, "output-duplicates")) {
                opt.verbose = true;
            } else if (std.mem.eql(u8, name, "width")) {
                opt.width_given = true;
                opt.width_form = "--width";
                opt.width_val = attached orelse takeOptionalNext(argv, &i);
            } else if (std.mem.eql(u8, name, "traditional")) {
                // accepted, functionally inert (see module doc: ledgered gap).
            } else {
                ctx.errPrint("{s}: unrecognized option '--{s}'\n", .{ PROG, name });
                return .{ .exit = 1 };
            }
            continue;
        }
        if (a.len >= 2 and a[0] == '-') {
            var ci: usize = 1;
            while (ci < a.len) {
                const c = a[ci];
                if (c == 't') {
                    const v = if (ci + 1 < a.len) blk: {
                        const vv = a[ci + 1 ..];
                        ci = a.len;
                        break :blk vv;
                    } else (nextTokenMandatory(argv, &i) orelse return missingFormatSpec(ctx));
                    var bc: u8 = 0;
                    var bn: []const u8 = "";
                    parseTypeString(ctx.gpa, v, &formats, &bc, &bn) catch |e| return typeStringErr(ctx, e, v, bc, bn);
                    break;
                } else if (c == 'A') {
                    opt.radix_val = if (ci + 1 < a.len) a[ci + 1 ..] else (nextTokenMandatory(argv, &i) orelse {
                        ctx.errPrint("{s}: option '-A' requires a value\n", .{PROG});
                        return .{ .exit = 1 };
                    });
                    ci = a.len;
                    break;
                } else if (c == 'j') {
                    opt.skip_val = if (ci + 1 < a.len) a[ci + 1 ..] else (nextTokenMandatory(argv, &i) orelse {
                        ctx.errPrint("{s}: option '-j' requires a value\n", .{PROG});
                        return .{ .exit = 1 };
                    });
                    opt.skip_form = "-j";
                    ci = a.len;
                    break;
                } else if (c == 'N') {
                    opt.read_val = if (ci + 1 < a.len) a[ci + 1 ..] else (nextTokenMandatory(argv, &i) orelse {
                        ctx.errPrint("{s}: option '-N' requires a value\n", .{PROG});
                        return .{ .exit = 1 };
                    });
                    opt.read_form = "-N";
                    ci = a.len;
                    break;
                } else if (c == 'S') {
                    opt.strings_given = true;
                    opt.strings_form = "-S";
                    if (ci + 1 < a.len) {
                        opt.strings_val = a[ci + 1 ..];
                        ci = a.len;
                    } else {
                        opt.strings_val = takeOptionalNext(argv, &i);
                    }
                    break;
                } else if (c == 'w') {
                    opt.width_given = true;
                    opt.width_form = "-w";
                    if (ci + 1 < a.len) {
                        opt.width_val = a[ci + 1 ..];
                        ci = a.len;
                    } else {
                        opt.width_val = takeOptionalNext(argv, &i);
                    }
                    break;
                } else if (c == 'v') {
                    opt.verbose = true;
                    ci += 1;
                } else if (traditionalFormat(c)) |fid| {
                    formats.append(ctx.gpa, .{ .id = fid }) catch @panic("OOM");
                    ci += 1;
                } else {
                    ctx.errPrint("{s}: unrecognized option '-{c}'\n", .{ PROG, c });
                    return .{ .exit = 1 };
                }
            }
            continue;
        }
        opt.files.append(ctx.gpa, a) catch @panic("OOM");
    }

    if (formats.items.len == 0) formats.append(ctx.gpa, .{ .id = .oct16 }) catch @panic("OOM");

    var radix: Radix = .octal;
    if (opt.radix_val) |v| {
        if (v.len == 0) {
            ctx.errPrint("{s}: Radix cannot be empty, and must be one of [o, d, x, n]\n", .{PROG});
            return .{ .exit = 1 };
        }
        radix = switch (v[0]) {
            'o' => .octal,
            'd' => .decimal,
            'x' => .hex,
            'n' => .none,
            else => {
                ctx.errPrint("{s}: Radix must be one of [o, d, x, n], got: {s}\n", .{ PROG, v });
                return .{ .exit = 1 };
            },
        };
    }

    var skip_bytes: u64 = 0;
    if (opt.skip_val) |v| {
        skip_bytes = parseNumberOfBytes(v) catch |e| {
            sizeErrMsg(ctx, opt.skip_form, v, e);
            return .{ .exit = 1 };
        };
    }

    var read_bytes: ?u64 = null;
    if (opt.read_val) |v| {
        read_bytes = parseNumberOfBytes(v) catch |e| {
            sizeErrMsg(ctx, opt.read_form, v, e);
            return .{ .exit = 1 };
        };
    }

    var endian_big = false; // native == little on every host this port targets
    if (opt.endian_val) |v| {
        if (std.mem.eql(u8, v, "big")) {
            endian_big = true;
        } else if (std.mem.eql(u8, v, "little")) {
            endian_big = false;
        } else {
            ctx.errPrint("{s}: Invalid argument --endian={s}\n", .{ PROG, v });
            return .{ .exit = 1 };
        }
    }

    var strings_min: ?usize = null;
    if (opt.strings_given) {
        const v = opt.strings_val orelse "3";
        const n = parseNumberOfBytes(v) catch |e| {
            sizeErrMsg(ctx, opt.strings_form, v, e);
            return .{ .exit = 1 };
        };
        strings_min = std.math.cast(usize, n) orelse {
            ctx.errPrint("{s}: {s} argument '{d}' too large\n", .{ PROG, opt.strings_form, n });
            return .{ .exit = 1 };
        };
    }

    var min_bytes: usize = 1;
    for (formats.items) |f| min_bytes = @max(min_bytes, byteSizeOf(f.id));

    var width: usize = 16;
    if (opt.width_given) {
        const v = opt.width_val orelse "32";
        const n = parseNumberOfBytes(v) catch |e| {
            sizeErrMsg(ctx, opt.width_form, v, e);
            return .{ .exit = 1 };
        };
        if (n == 0) {
            ctx.errPrint("{s}: invalid {s} argument '0'\n", .{ PROG, opt.width_form });
            return .{ .exit = 1 };
        }
        width = std.math.cast(usize, n) orelse {
            ctx.errPrint("{s}: {s} argument '{s}' too large\n", .{ PROG, opt.width_form, v });
            return .{ .exit = 1 };
        };
    }
    if (width % min_bytes != 0) {
        ctx.errPrint("{s}: warning: invalid width {d}; using {d} instead\n", .{ PROG, width, min_bytes });
        width = min_bytes;
    }

    if (opt.files.items.len == 0) opt.files.append(ctx.gpa, "-") catch @panic("OOM");

    return .{ .ok = .{
        .formats = formats.toOwnedSlice(ctx.gpa) catch @panic("OOM"),
        .radix = radix,
        .skip_bytes = skip_bytes,
        .read_bytes = read_bytes,
        .endian_big = endian_big,
        .strings_min = strings_min,
        .verbose = opt.verbose,
        .width = width,
        .files = opt.files.toOwnedSlice(ctx.gpa) catch @panic("OOM"),
    } };
}

// ============================================================================ multi-file reader

/// Concatenates FILE operands (and `-` = stdin) into one logical byte stream, mirroring
/// `MultifileReader`: a per-operand open failure prints `od: {name}: {strerror}`, sets
/// the sticky error flag, and moves on to the next operand (never fatal by itself).
const MultiReader = struct {
    ctx: *Ctx,
    files: []const []const u8,
    idx: usize = 0,
    cur_fd: ?sys.Fd = null,
    cur_is_stdin: bool = false,
    any_err: bool = false,

    fn openNext(self: *MultiReader) void {
        while (self.idx < self.files.len) {
            const name = self.files[self.idx];
            self.idx += 1;
            if (std.mem.eql(u8, name, "-")) {
                self.cur_fd = self.ctx.stdin;
                self.cur_is_stdin = true;
                return;
            }
            const fd = sys.open(name, .{ .read = true }) catch |e| {
                self.ctx.errPrint("{s}: {s}: {s}\n", .{ PROG, name, sys.strerror(sys.toErrno(e)) });
                self.any_err = true;
                continue;
            };
            self.cur_fd = fd;
            self.cur_is_stdin = false;
            return;
        }
        self.cur_fd = null;
    }

    /// Fills `out` completely by walking across operands, unless everything is
    /// exhausted first (returns the short count then, 0 at true EOF).
    fn read(self: *MultiReader, out: []u8) usize {
        var got: usize = 0;
        while (got < out.len) {
            if (self.cur_fd == null) self.openNext();
            const fd = self.cur_fd orelse break;
            const n = sys.read(fd, out[got..]) catch 0;
            if (n == 0) {
                if (!self.cur_is_stdin) sys.close(fd);
                self.cur_fd = null;
                continue;
            }
            got += n;
        }
        return got;
    }
};

/// Discards `n` bytes from the front of the combined stream; `false` if EOF hits first
/// (mirrors `PartialReader`'s "tried to skip past end of input").
fn skipBytes(mr: *MultiReader, n: u64) bool {
    var remaining = n;
    var buf: [16384]u8 = undefined;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, buf.len));
        const got = mr.read(buf[0..want]);
        remaining -= got;
        if (got < want) return remaining == 0;
    }
    return true;
}

// ============================================================================ address offsets

fn formatOffset(buf: []u8, radix: Radix, value: u64) []const u8 {
    var sink = fmtnum.FixedSink{ .buf = buf };
    switch (radix) {
        .none => {},
        .octal => fmtnum.emitUint(&sink, .{ .conv = 'o', .width = 7, .flags = .{ .zero = true } }, value) catch {},
        .decimal => fmtnum.emitUint(&sink, .{ .conv = 'u', .width = 7, .flags = .{ .zero = true } }, value) catch {},
        .hex => fmtnum.emitUint(&sink, .{ .conv = 'x', .width = 6, .flags = .{ .zero = true } }, value) catch {},
    }
    return sink.slice();
}

// ============================================================================ column alignment

const MAX_BLOCK = 16;

/// Ports `OutputInfo::calculate_alignment`: spreads any slack between a format's own
/// natural width and the widest format's width across that format's item positions
/// within a block, halving the item count (doubling the stride) each pass so wider
/// formats absorb more of the remainder -- keeps every format's columns lined up when
/// several `-t` types are requested together. `missing` is `usize`; the algorithm
/// relies on it never being asked to underflow (true by construction: `print_width *
/// items_in_block <= print_width_block`, the max over all formats).
fn calcAlignment(byte_size: usize, print_width: usize, block_byte_size: usize, block_print_width: usize) [MAX_BLOCK]usize {
    var spacing = [_]usize{0} ** MAX_BLOCK;
    var bsz = byte_size;
    var items = block_byte_size / bsz;
    const thisblock_width = print_width * items;
    var missing = block_print_width - thisblock_width;
    while (items > 0) {
        const avg = missing / items;
        var k: usize = 0;
        while (k < items) : (k += 1) {
            spacing[k * bsz] += avg;
            missing -= avg;
        }
        items /= 2;
        bsz *= 2;
    }
    return spacing;
}

const RowInfo = struct {
    fmt: ParsedFormat,
    spacing: [MAX_BLOCK]usize,
};

fn buildRows(gpa: std.mem.Allocator, formats: []const ParsedFormat, block_byte_size: usize, block_print_width: usize) []RowInfo {
    const rows = gpa.alloc(RowInfo, formats.len) catch @panic("OOM");
    for (formats, 0..) |f, idx| {
        rows[idx] = .{
            .fmt = f,
            .spacing = calcAlignment(byteSizeOf(f.id), printWidthOf(f.id), block_byte_size, block_print_width),
        };
    }
    return rows;
}

// ============================================================================ byte decoding

fn readUintAt(data: []const u8, at: usize, size: usize, big_endian: bool) u64 {
    var v: u64 = 0;
    if (big_endian) {
        for (data[at .. at + size]) |b| v = (v << 8) | b;
    } else {
        var k: usize = size;
        while (k > 0) {
            k -= 1;
            v = (v << 8) | data[at + k];
        }
    }
    return v;
}

fn readU128At(data: []const u8, at: usize, big_endian: bool) u128 {
    var v: u128 = 0;
    if (big_endian) {
        for (data[at .. at + 16]) |b| v = (v << 8) | b;
    } else {
        var k: usize = 16;
        while (k > 0) {
            k -= 1;
            v = (v << 8) | data[at + k];
        }
    }
    return v;
}

fn signExtend(raw: u64, byte_size: usize) i64 {
    const shift: u6 = @intCast(64 - byte_size * 8);
    const wide: i64 = @bitCast(raw << shift);
    return wide >> shift;
}

/// 16-byte binary128-like blob (1 sign + 15 exponent + 112 mantissa) -> f64, narrowing
/// (never widening) precision. Mirrors `u128_to_f64` exactly, including its flush-
/// subnormal-to-zero and overflow-to-infinity behavior.
fn u128ToF64(u: u128) f64 {
    const sign: u64 = @intCast(u >> 127);
    const exp: u64 = @intCast((u >> 112) & 0x7FFF);
    const mant: u128 = u & ((@as(u128, 1) << 112) - 1);

    if (exp == 0x7FFF) {
        if (mant == 0) return if (sign == 0) std.math.inf(f64) else -std.math.inf(f64);
        return std.math.nan(f64);
    }
    if (exp == 0) {
        return if (sign == 0) 0.0 else -0.0;
    }
    const new_exp: i64 = @as(i64, @intCast(exp)) - 16383 + 1023;
    if (new_exp >= 2047) return if (sign == 0) std.math.inf(f64) else -std.math.inf(f64);
    if (new_exp <= 0) return if (sign == 0) 0.0 else -0.0;
    const new_mant: u64 = @intCast(mant >> (112 - 52));
    const bits: u64 = (sign << 63) | (@as(u64, @intCast(new_exp)) << 52) | new_mant;
    return @bitCast(bits);
}

// ============================================================================ int/char/ascii renderers

fn rjustInto(sink: *fmtnum.FixedSink, s: []const u8, width: usize) void {
    const pad = if (width > s.len) width - s.len else 0;
    var k: usize = 0;
    while (k < pad) : (k += 1) sink.push(' ') catch {};
    sink.extend(s) catch {};
}

const A_CHARS = [_][]const u8{
    "nul", "soh", "stx", "etx", "eot", "enq", "ack", "bel", "bs", "ht", "nl", "vt", "ff", "cr",
    "so", "si", "dle", "dc1", "dc2", "dc3", "dc4", "nak", "syn", "etb", "can", "em", "sub", "esc",
    "fs", "gs", "rs", "us", "sp", "!", "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "-",
    ".", "/", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ":", ";", "<", "=", ">", "?", "@",
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S",
    "T", "U", "V", "W", "X", "Y", "Z", "[", "\\", "]", "^", "_", "`", "a", "b", "c", "d", "e", "f",
    "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y",
    "z", "{", "|", "}", "~", "del",
};

const C_CHARS = [_][]const u8{
    "\\0", "001", "002", "003", "004", "005", "006", "\\a", "\\b", "\\t", "\\n", "\\v", "\\f",
    "\\r", "016", "017", "020", "021", "022", "023", "024", "025", "026", "027", "030", "031",
    "032", "033", "034", "035", "036", "037", " ", "!", "\"", "#", "$", "%", "&", "'", "(", ")",
    "*", "+", ",", "-", ".", "/", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ":", ";", "<",
    "=", ">", "?", "@", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O",
    "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "[", "\\", "]", "^", "_", "`", "a", "b",
    "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u",
    "v", "w", "x", "y", "z", "{", "|", "}", "~", "177",
};

fn renderA(sink: *fmtnum.FixedSink, byte: u8) void {
    const idx = byte & 0x7f;
    rjustInto(sink, A_CHARS[idx], 4);
}

fn renderC(sink: *fmtnum.FixedSink, byte: u8) void {
    if (byte & 0x80 == 0) {
        rjustInto(sink, C_CHARS[byte], 4);
    } else {
        sink.push(' ') catch {};
        fmtnum.emitUint(sink, .{ .conv = 'o', .width = 3, .flags = .{ .zero = true } }, byte) catch {};
    }
}

pub fn formatAsciiDump(buf: []u8, bytes: []const u8) []const u8 {
    var sink = fmtnum.FixedSink{ .buf = buf };
    sink.push('>') catch {};
    for (bytes) |b| {
        if (b >= 0x20 and b <= 0x7e) {
            sink.extend(C_CHARS[b]) catch {};
        } else {
            sink.push('.') catch {};
        }
    }
    sink.push('<') catch {};
    return sink.slice();
}

fn renderInt(sink: *fmtnum.FixedSink, id: FmtId, raw: u64) void {
    const w = printWidthOf(id) - 1;
    sink.push(' ') catch {};
    switch (id) {
        .oct8, .oct16, .oct32, .oct64 => fmtnum.emitUint(sink, .{ .conv = 'o', .width = w, .flags = .{ .zero = true } }, raw) catch {},
        .hex8, .hex16, .hex32, .hex64 => fmtnum.emitUint(sink, .{ .conv = 'x', .width = w, .flags = .{ .zero = true } }, raw) catch {},
        .decu8, .decu16, .decu32, .decu64 => fmtnum.emitUint(sink, .{ .conv = 'u', .width = w }, raw) catch {},
        .decs8, .decs16, .decs32, .decs64 => {
            const bs = byteSizeOf(id);
            fmtnum.emitInt(sink, .{ .conv = 'd', .width = w }, signExtend(raw, bs)) catch {};
        },
        else => unreachable,
    }
}

// ============================================================================ float renderers
//
// Ports `prn_float.rs`'s `format_float`/`format_f64_exp_precision` family. The FIXED
// branch is byte-identical to fmtnum's own `%f` (both round the exact binary value to
// N decimal places, ties-to-even, space-padded to a width -- see fmtnum's module doc);
// reused directly rather than re-deriving digit extraction. The SCI branch needs a
// bespoke emitter: Rust's raw `{:e}` exponent has NO zero-padding and (for od's f32/
// f64/f16/bf16 paths only, NOT long double) a manually-inserted `+` for non-negative
// exponents -- both details fmtnum's own `%e` (C-style, always >=2 exponent digits)
// gets wrong for this purpose.

fn floorLog10(x: f64) i32 {
    return @intFromFloat(@floor(@log10(x)));
}

/// Builds `[sign]d[.ddd]e[+]NN` (bare exponent digits, `plus_for_nonneg` selects
/// whether a non-negative exponent gets a literal `+`) then right-pads with spaces to
/// `width`, matching `format_f64_exp_precision`/`format_long_double`'s two-step
/// "format at width-1 then splice in a sign char" as a single direct render.
fn renderSci(out: *fmtnum.FixedSink, width: usize, mant_frac: usize, value: f64, plus_for_nonneg: bool) void {
    var tmp: [80]u8 = undefined;
    var s = fmtnum.FixedSink{ .buf = &tmp };
    const neg = std.math.signbit(value);
    if (neg) s.push('-') catch {};
    var d = fmtnum.decompose(@abs(value));
    fmtnum.roundAt(&d, mant_frac + 1);
    if (d.n == 0) d = fmtnum.decompose(0);
    s.push(fmtnum.sigDigit(&d, 0)) catch {};
    if (mant_frac > 0) {
        s.push('.') catch {};
        var j: usize = 1;
        while (j <= mant_frac) : (j += 1) s.push(fmtnum.sigDigit(&d, @intCast(j))) catch {};
    }
    s.push('e') catch {};
    const exp: i32 = d.exp10 - 1;
    if (exp < 0) {
        s.push('-') catch {};
    } else if (plus_for_nonneg) {
        s.push('+') catch {};
    }
    var digbuf: [16]u8 = undefined;
    var v: u32 = @abs(exp);
    var di: usize = digbuf.len;
    if (v == 0) {
        di -= 1;
        digbuf[di] = '0';
    } else {
        while (v != 0) : (v /= 10) {
            di -= 1;
            digbuf[di] = '0' + @as(u8, @intCast(v % 10));
        }
    }
    s.extend(digbuf[di..]) catch {};
    rjustInto(out, s.slice(), width);
}

/// Non-finite / exactly-zero special cases, shared by all float widths (each caller
/// passes its own field width).
fn renderFloatSpecial(out: *fmtnum.FixedSink, width: usize, value: f64) bool {
    if (value == 0.0 and std.math.signbit(value)) {
        rjustInto(out, "-0", width);
        return true;
    }
    if (value == 0.0) {
        rjustInto(out, "0", width);
        return true;
    }
    if (std.math.isNan(value)) {
        rjustInto(out, "NaN", width);
        return true;
    }
    if (std.math.isInf(value)) {
        rjustInto(out, if (value < 0) "-inf" else "inf", width);
        return true;
    }
    return false;
}

/// The shared fixed-vs-scientific decision from `format_float` (used, with different
/// (width, precision) pairs, by f32/f64 and -- via `format_binary16_like`'s non-
/// subnormal path -- f16/bf16 too). Assumes `value` is finite and nonzero.
fn formatFloatCore(out: *fmtnum.FixedSink, width: usize, precision: usize, value: f64) void {
    var l = floorLog10(@abs(value));
    const r = std.math.pow(f64, 10.0, @floatFromInt(l));
    if ((value > 0.0 and r > value) or (value < 0.0 and -r < value)) l -= 1;

    const prec_i: i32 = @intCast(precision);
    if (l >= 0 and l <= prec_i - 1) {
        const dec: usize = @intCast(prec_i - 1 - l);
        fmtnum.emitFloat(out, .{ .conv = 'f', .width = width, .precision = dec }, value) catch {};
    } else if (l == -1) {
        fmtnum.emitFloat(out, .{ .conv = 'f', .width = width, .precision = precision }, value) catch {};
    } else {
        renderSci(out, width, precision - 1, value, true);
    }
}

fn renderF32(sink: *fmtnum.FixedSink, bits: u32) void {
    const value: f32 = @bitCast(bits);
    const width = 15;
    sink.push(' ') catch {};
    if (renderFloatSpecial(sink, width, value)) return;
    const is_subnormal = (bits & 0x7F80_0000) == 0 and (bits & 0x007F_FFFF) != 0;
    if (is_subnormal) {
        // Ledgered gap (module doc): the reference uses Rust's shortest-round-trip
        // `{:e}` here; approximated with a fixed 8-digit mantissa instead.
        renderSci(sink, width, 7, value, true);
        return;
    }
    formatFloatCore(sink, width, 8, value);
}

fn renderF64(sink: *fmtnum.FixedSink, bits: u64) void {
    const value: f64 = @bitCast(bits);
    const width = 24;
    sink.push(' ') catch {};
    if (renderFloatSpecial(sink, width, value)) return;
    const exp11: u64 = (bits >> 52) & 0x7FF;
    const is_subnormal = exp11 == 0 and value != 0.0;
    if (is_subnormal) {
        renderSci(sink, width, 16, value, true); // ledgered gap, see renderF32
        return;
    }
    formatFloatCore(sink, width, 17, value);
}

/// Strips trailing fraction zeros (and the point itself if that empties it), keeping
/// the exponent suffix untouched -- `trim_float_repr`. `raw` has already been
/// space-padded by the caller; this trims from the first non-space character.
fn trimFloatRepr(buf: []u8, raw: []const u8) []const u8 {
    var s = std.mem.trimStart(u8, raw, " ");
    if (std.mem.eql(u8, s, "NaN") or std.mem.eql(u8, s, "inf") or std.mem.eql(u8, s, "-inf")) return s;
    var exp_at: usize = s.len;
    if (std.mem.indexOfScalar(u8, s, 'e')) |p| exp_at = p;
    var mant = s[0..exp_at];
    const exp_part = s[exp_at..];
    if (std.mem.indexOfScalar(u8, mant, '.') != null) {
        while (mant.len > 0 and mant[mant.len - 1] == '0') mant = mant[0 .. mant.len - 1];
        if (mant.len > 0 and mant[mant.len - 1] == '.') mant = mant[0 .. mant.len - 1];
    }
    if (mant.len == 0 or std.mem.eql(u8, mant, "-") or std.mem.eql(u8, mant, "+")) mant = "0";
    return std.fmt.bufPrint(buf, "{s}{s}", .{ mant, exp_part }) catch raw;
}

/// f16/bfloat16 share this pipeline (unlike f32/f64): render at width 15 (matching
/// f32's width, precision 8), TRIM trailing fraction zeros, then re-pad to 15 and
/// prepend the one mandatory leading space -- `format_item_f16`/`format_item_bf16`.
fn renderNarrowFloat(sink: *fmtnum.FixedSink, value: f64, is_subnormal: bool) void {
    var raw_buf: [80]u8 = undefined;
    var raw_sink = fmtnum.FixedSink{ .buf = &raw_buf };
    if (!renderFloatSpecial(&raw_sink, 15, value)) {
        if (is_subnormal) {
            renderSci(&raw_sink, 15, 7, value, true);
        } else {
            formatFloatCore(&raw_sink, 15, 8, value);
        }
    }
    var trim_buf: [80]u8 = undefined;
    const trimmed = trimFloatRepr(&trim_buf, raw_sink.slice());
    sink.push(' ') catch {};
    rjustInto(sink, trimmed, 15);
}

fn renderF16(sink: *fmtnum.FixedSink, bits: u16) void {
    const value16: f16 = @bitCast(bits);
    const value: f64 = @floatCast(value16);
    const is_subnormal = (bits & 0x7C00) == 0 and (bits & 0x03FF) != 0;
    renderNarrowFloat(sink, value, is_subnormal);
}

fn renderBf16(sink: *fmtnum.FixedSink, bits: u16) void {
    // bf16 is exactly an f32's top 16 bits (same exponent range, truncated mantissa).
    const f32_bits: u32 = @as(u32, bits) << 16;
    const value32: f32 = @bitCast(f32_bits);
    const value: f64 = value32;
    const is_subnormal = (bits & 0x7F80) == 0 and (bits & 0x007F) != 0;
    renderNarrowFloat(sink, value, is_subnormal);
}

fn renderLongDouble(sink: *fmtnum.FixedSink, raw16: u128) void {
    const value = u128ToF64(raw16);
    const width = 39;
    sink.push(' ') catch {};
    if (renderFloatSpecial(sink, width, value)) return;
    renderSci(sink, width, 21, value, false);
}

fn renderItem(sink: *fmtnum.FixedSink, id: FmtId, data: []const u8, at: usize, big_endian: bool) void {
    switch (id) {
        .oct8, .oct16, .oct32, .oct64, .hex8, .hex16, .hex32, .hex64, .decu8, .decu16, .decu32, .decu64, .decs8, .decs16, .decs32, .decs64 => {
            renderInt(sink, id, readUintAt(data, at, byteSizeOf(id), big_endian));
        },
        .a_fmt => renderA(sink, data[at]),
        .c_fmt => renderC(sink, data[at]),
        .f16_fmt => renderF16(sink, @intCast(readUintAt(data, at, 2, big_endian))),
        .bf16_fmt => renderBf16(sink, @intCast(readUintAt(data, at, 2, big_endian))),
        .f32_fmt => renderF32(sink, @intCast(readUintAt(data, at, 4, big_endian))),
        .f64_fmt => renderF64(sink, readUintAt(data, at, 8, big_endian)),
        .ld_fmt => renderLongDouble(sink, readU128At(data, at, big_endian)),
    }
}

// ============================================================================ main dump loop

/// Whole line (all requested `-t` rows), the offset column, and the trailing `z`
/// ASCII gutter. `full_line` is `width`-long and zero-padded past `got` (so a trailing
/// partial multi-byte unit still decodes with its missing high/low bytes as zero,
/// matching `MemoryDecoder::zero_out_buffer`); `got` bounds how many items actually
/// get emitted per row (the padding is read-only filler, never its own item).
fn writeDumpLine(
    out: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    rows: []const RowInfo,
    block_byte_size: usize,
    print_width_line: usize,
    full_line: []const u8,
    got: usize,
    offset_str: []const u8,
    big_endian: bool,
) void {
    var row_buf: [8192]u8 = undefined;
    for (rows, 0..) |row, ridx| {
        var sink = fmtnum.FixedSink{ .buf = &row_buf };
        var b: usize = 0;
        const bsz = byteSizeOf(row.fmt.id);
        while (b < got) {
            const sp = row.spacing[b % block_byte_size];
            var k: usize = 0;
            while (k < sp) : (k += 1) sink.push(' ') catch {};
            renderItem(&sink, row.fmt.id, full_line, b, big_endian);
            b += bsz;
        }
        if (row.fmt.add_ascii_dump) {
            const emitted = sink.slice().len;
            const pad = if (print_width_line > emitted) print_width_line - emitted else 0;
            var k: usize = 0;
            while (k < pad) : (k += 1) sink.push(' ') catch {};
            sink.extend("  ") catch {};
            var dump_buf: [8192]u8 = undefined;
            sink.extend(formatAsciiDump(&dump_buf, full_line[0..got])) catch {};
        }
        if (ridx == 0) {
            out.appendSlice(gpa, offset_str) catch @panic("OOM");
        } else {
            out.appendNTimes(gpa, ' ', offset_str.len) catch @panic("OOM");
        }
        out.appendSlice(gpa, sink.slice()) catch @panic("OOM");
        out.append(gpa, '\n') catch @panic("OOM");
    }
}

fn runDump(ctx: *Ctx, mr: *MultiReader, opt: Options) u8 {
    var block_byte_size: usize = 1;
    var block_print_width: usize = 1;
    for (opt.formats) |f| block_byte_size = @max(block_byte_size, byteSizeOf(f.id));
    for (opt.formats) |f| {
        const items = block_byte_size / byteSizeOf(f.id);
        block_print_width = @max(block_print_width, printWidthOf(f.id) * items);
    }
    const print_width_line = block_print_width * (opt.width / block_byte_size);
    const rows = buildRows(ctx.gpa, opt.formats, block_byte_size, block_print_width);

    var out: std.ArrayListUnmanaged(u8) = .empty;

    var offset: u64 = opt.skip_bytes;
    if (!skipBytes(mr, opt.skip_bytes)) {
        ctx.errPrint("{s}: tried to skip past end of input\n", .{PROG});
        var obuf: [32]u8 = undefined;
        out.appendSlice(ctx.gpa, formatOffset(&obuf, opt.radix, offset)) catch @panic("OOM");
        if (opt.radix != .none) out.append(ctx.gpa, '\n') catch @panic("OOM");
        ctx.outWrite(out.items) catch {};
        return 1;
    }

    var read_remaining: ?u64 = opt.read_bytes;
    const line = ctx.gpa.alloc(u8, opt.width) catch @panic("OOM");
    const prev = ctx.gpa.alloc(u8, opt.width) catch @panic("OOM");
    var have_prev = false;
    var dup_active = false;

    while (true) {
        const want: usize = if (read_remaining) |r| @intCast(@min(@as(u64, opt.width), r)) else opt.width;
        if (want == 0) break;
        @memset(line, 0);
        const got = mr.read(line[0..want]);
        if (read_remaining) |*r| r.* -= got;
        if (got == 0) break;

        const is_full = got == opt.width;
        const is_dup = !opt.verbose and is_full and have_prev and std.mem.eql(u8, line, prev);
        if (is_dup) {
            if (!dup_active) {
                dup_active = true;
                out.appendSlice(ctx.gpa, "*\n") catch @panic("OOM");
            }
        } else {
            dup_active = false;
            if (is_full) {
                @memcpy(prev, line);
                have_prev = true;
            }
            var obuf: [32]u8 = undefined;
            const offset_str = formatOffset(&obuf, opt.radix, offset);
            writeDumpLine(&out, ctx.gpa, rows, block_byte_size, print_width_line, line, got, offset_str, opt.endian_big);
        }
        offset += got;
    }

    // The final offset line is skipped entirely if any operand ever failed to open
    // (`!input_decoder.has_error()` in the reference) -- e.g. `od /no/such/file`
    // prints NOTHING on stdout, only the stderr diagnostic.
    if (!mr.any_err) {
        var obuf: [32]u8 = undefined;
        out.appendSlice(ctx.gpa, formatOffset(&obuf, opt.radix, offset)) catch @panic("OOM");
        if (opt.radix != .none) out.append(ctx.gpa, '\n') catch @panic("OOM");
    }

    ctx.outWrite(out.items) catch {};
    return if (mr.any_err) 1 else 0;
}

// ============================================================================ strings mode (-S)

/// `-S`/`--strings`: byte-at-a-time scan for NUL-terminated runs of printable ASCII
/// (0x20..=0x7e) at least `min_len` long -- ports `extract_strings_from_input`. Unlike
/// the main dump path, an unterminated trailing run at EOF is discarded, not printed.
fn runStrings(ctx: *Ctx, mr: *MultiReader, opt: Options) u8 {
    // Strings mode's own skip loop is silent on EOF (`Ok(0) => break`, no error) --
    // deliberately NOT `skipBytes` (the main dump path's `PartialReader`-alike, which
    // DOES fail loudly). Confirmed against `extract_strings_from_input`.
    var remaining = opt.skip_bytes;
    var skip_buf: [8192]u8 = undefined;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, skip_buf.len));
        const got = mr.read(skip_buf[0..want]);
        if (got == 0) break;
        remaining -= got;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    const min_len = opt.strings_min.?;
    var cur: std.ArrayListUnmanaged(u8) = .empty;
    var cur_start: u64 = 0;
    var offset: u64 = opt.skip_bytes;
    var bytes_read: u64 = 0;

    while (true) {
        if (opt.read_bytes) |limit| {
            if (bytes_read >= limit) {
                if (cur.items.len >= min_len) emitString(ctx, &out, opt.radix, cur_start, cur.items);
                break;
            }
        }
        var one: [1]u8 = undefined;
        const n = mr.read(&one);
        if (n == 0) break;
        bytes_read += 1;
        const byte = one[0];
        if (byte >= 0x20 and byte <= 0x7e) {
            if (cur.items.len == 0) cur_start = offset;
            cur.append(ctx.gpa, byte) catch @panic("OOM");
        } else {
            if (byte == 0 and cur.items.len >= min_len) emitString(ctx, &out, opt.radix, cur_start, cur.items);
            cur.clearRetainingCapacity();
        }
        offset += 1;
    }

    ctx.outWrite(out.items) catch {};
    return if (mr.any_err) 1 else 0;
}

fn emitString(ctx: *Ctx, out: *std.ArrayListUnmanaged(u8), radix: Radix, offset: u64, s: []const u8) void {
    var obuf: [32]u8 = undefined;
    switch (radix) {
        .none => {},
        else => {
            out.appendSlice(ctx.gpa, formatOffsetPlain(&obuf, radix, offset)) catch @panic("OOM");
            out.append(ctx.gpa, ' ') catch @panic("OOM");
        },
    }
    out.appendSlice(ctx.gpa, s) catch @panic("OOM");
    out.append(ctx.gpa, '\n') catch @panic("OOM");
}

/// `-S` mode's own offset rendering: plain (no leading space baked in, unlike the
/// per-item dump formatters) 7-digit-minimum, uses whatever WIDTH the value naturally
/// needs beyond 7 digits (Rust's `{:07}` grows past the zero-padded floor, never
/// truncates) -- kept separate from `formatOffset` (the main dump path's version,
/// which never needs a decimal radix leading space or a variable width).
fn formatOffsetPlain(buf: []u8, radix: Radix, value: u64) []const u8 {
    var sink = fmtnum.FixedSink{ .buf = buf };
    switch (radix) {
        .none => {},
        .octal => fmtnum.emitUint(&sink, .{ .conv = 'o', .width = 7, .flags = .{ .zero = true } }, value) catch {},
        .decimal => fmtnum.emitUint(&sink, .{ .conv = 'u', .width = 7, .flags = .{ .zero = true } }, value) catch {},
        .hex => fmtnum.emitUint(&sink, .{ .conv = 'x', .width = 7, .flags = .{ .zero = true } }, value) catch {},
    }
    return sink.slice();
}

// ============================================================================ entry point

pub fn run(ctx: *Ctx) u8 {
    const res = parseArgs(ctx);
    const opt = switch (res) {
        .exit => |c| return c,
        .ok => |o| o,
    };

    var mr = MultiReader{ .ctx = ctx, .files = opt.files };
    if (opt.strings_min != null) return runStrings(ctx, &mr, opt);
    return runDump(ctx, &mr, opt);
}
