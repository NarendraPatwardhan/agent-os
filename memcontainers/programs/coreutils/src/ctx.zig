//! The applet calling convention (DESIGN.md §5.3). Applets take a `*Ctx` instead of
//! reading process-global stdio/argv, which is what makes them unit-testable
//! in-process: tests build a `Ctx` over pipes/temp fds and assert on captured bytes.

const std = @import("std");
const sys = @import("sys/root.zig");
const fmt_min = @import("core/fmt_min.zig");

pub const Ctx = struct {
    args: []const [:0]const u8, // argv, args[0] = applet name
    gpa: std.mem.Allocator, // arena; freed wholesale after run()
    stdin: sys.Fd,
    stdout: sys.Fd,
    stderr: sys.Fd,

    /// Renders `fmt`/`args` (see core/fmt_min.zig) into a stack buffer and writes it to
    /// `fd` in one `sys.writeAll` call. Best-effort: write failure is swallowed here --
    /// callers that must react to a closed pipe use `sys.writeAll`/`outWrite` directly.
    pub fn print(self: *const Ctx, fd: sys.Fd, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        var buf: [1024]u8 = undefined;
        var sink = fmt_min.Sink{ .buf = &buf };
        fmt_min.render(&sink, fmt, args);
        sys.writeAll(fd, sink.slice()) catch {};
    }

    pub fn errPrint(self: *const Ctx, comptime fmt: []const u8, args: anytype) void {
        self.print(self.stderr, fmt, args);
    }

    pub fn outPrint(self: *const Ctx, comptime fmt: []const u8, args: anytype) void {
        self.print(self.stdout, fmt, args);
    }

    /// Raw bytes to stdout; propagates the write error (downstream-closed) so
    /// streaming applets (yes, cat) can stop quietly instead of looping forever.
    pub fn outWrite(self: *const Ctx, bytes: []const u8) sys.Error!void {
        return sys.writeAll(self.stdout, bytes);
    }
};
