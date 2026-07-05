//! The one formatter (DESIGN.md §11 rule 3): `{s}` (bytes), `{d}` (signed/unsigned
//! integer decimal), `{c}` (byte) only -- covers every M0 diagnostic. No `std.fmt`
//! anywhere in this file; that machinery (float formatting, error-name introspection)
//! is exactly the classic wasm bloat source the design calls out.

const std = @import("std");

/// Fixed-capacity byte sink. Overflow silently truncates -- diagnostics are one line
/// by construction, so callers size the buffer generously and never hit this in
/// practice; a unit test below pins the truncation behavior itself.
pub const Sink = struct {
    buf: []u8,
    len: usize = 0,

    pub fn writeBytes(self: *Sink, bytes: []const u8) void {
        const room = self.buf.len - self.len;
        const n = @min(room, bytes.len);
        @memcpy(self.buf[self.len..][0..n], bytes[0..n]);
        self.len += n;
    }

    pub fn writeByte(self: *Sink, b: u8) void {
        self.writeBytes(&[1]u8{b});
    }

    pub fn slice(self: *const Sink) []const u8 {
        return self.buf[0..self.len];
    }
};

fn writeUint(sink: *Sink, value: anytype) void {
    var buf: [39]u8 = undefined; // u128 max is 39 decimal digits
    var v = value;
    var i: usize = buf.len;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
    } else {
        while (v != 0) {
            i -= 1;
            buf[i] = '0' + @as(u8, @intCast(v % 10));
            v /= 10;
        }
    }
    sink.writeBytes(buf[i..]);
}

fn writeInt(sink: *Sink, value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => {
            const v128: i128 = value;
            if (v128 < 0) {
                sink.writeByte('-');
                writeUint(sink, @as(u128, @intCast(-v128)));
            } else {
                writeUint(sink, @as(u128, @intCast(v128)));
            }
        },
        else => @compileError("fmt_min: {d} requires an integer"),
    }
}

/// Renders `fmt` (a comptime string with `{s}`/`{d}`/`{c}` placeholders) into `sink`,
/// consuming one field of the `args` tuple per placeholder, left to right.
pub fn render(sink: *Sink, comptime fmt: []const u8, args: anytype) void {
    const fields_len = @typeInfo(@TypeOf(args)).@"struct".fields.len;
    comptime var ai: usize = 0;
    comptime var i: usize = 0;
    inline while (i < fmt.len) {
        if (fmt[i] == '{') {
            comptime var j = i + 1;
            inline while (fmt[j] != '}') : (j += 1) {}
            const spec = fmt[i + 1 .. j];
            if (comptime std.mem.eql(u8, spec, "s")) {
                sink.writeBytes(args[ai]);
            } else if (comptime std.mem.eql(u8, spec, "d")) {
                writeInt(sink, args[ai]);
            } else if (comptime std.mem.eql(u8, spec, "c")) {
                sink.writeByte(args[ai]);
            } else {
                @compileError("fmt_min: unsupported format spec {" ++ spec ++ "}");
            }
            ai += 1;
            i = j + 1;
        } else {
            comptime var k = i;
            inline while (k < fmt.len and fmt[k] != '{') : (k += 1) {}
            sink.writeBytes(fmt[i..k]);
            i = k;
        }
    }
    if (comptime ai != fields_len) @compileError("fmt_min: argument count mismatch");
}

/// Convenience one-shot: render into `buf`, return the written slice.
pub fn formatBuf(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var sink = Sink{ .buf = buf };
    render(&sink, fmt, args);
    return sink.slice();
}
