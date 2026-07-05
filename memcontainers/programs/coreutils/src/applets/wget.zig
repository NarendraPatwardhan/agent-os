//! `wget` -- fetch a URL body to a file or stdout (docs/analysis/applets-s-z.md). A thin
//! pump over `sys.httpGet(url) -> fd` (the kernel/host performs the request + TLS; the
//! native backend does it in-process). Body only -- no status line, no redirects. Output
//! goes to `-O FILE` (`-` = stdout) or stdout by default.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "download a URL's body to a file or standard output",
    .synopsis = &.{"wget [-O FILE] URL"},
    .description =
    \\Requests URL and writes its response body to FILE (truncating or creating
    \\it), or to standard output with -O - or when -O is omitted. This is a thin
    \\pump over a host/kernel-performed request: wget streams whatever body comes
    \\back, with no status line and no redirect handling of its own.
    ,
    .options = &.{
        .{ .flags = "-O, --output-document=FILE", .desc = "write the body to FILE instead of standard output (\"-\" means stdout)" },
    },
    .operands = "URL   the address to request.",
    .exit = &.{
        .{ .code = 0, .when = "the body was fetched and written" },
        .{ .code = 1, .when = "the request failed (network unavailable or a transport error), or FILE could not be opened for writing" },
        .{ .code = 2, .when = "usage error: missing URL, an unrecognized option, or too many operands" },
    },
    .deviations_from = "GNU wget",
    .deviations = &.{
        "Body only: no status line is checked, no redirects are followed, and no retries/timeouts/progress meter are implemented.",
        "Only -O/--output-document is supported -- no -q, -v, -N, -c, -b, --no-check-certificate, or any recursive/mirroring options.",
    },
    .examples = &.{
        .{ .cmd = "wget -O out.json https://example.com/data.json", .note = "save the body to out.json" },
        .{ .cmd = "wget https://example.com/", .note = "body to stdout (no -O)" },
    },
    .see_also = "fetch (set method/headers/body), wscat (WebSocket client).",
};

pub fn run(ctx: *Ctx) u8 {
    var output: ?[]const u8 = null;
    var url: ?[]const u8 = null;

    var i: usize = 1;
    while (i < ctx.args.len) : (i += 1) {
        const a = ctx.args[i];
        if (std.mem.eql(u8, a, "--help")) {
            cli.renderHelp(ctx, "wget", help_doc);
            return 0;
        } else if (std.mem.eql(u8, a, "-O") or std.mem.eql(u8, a, "--output-document")) {
            i += 1;
            if (i >= ctx.args.len) return usage(ctx, "option requires an argument -- 'O'");
            output = ctx.args[i];
        } else if (std.mem.startsWith(u8, a, "--output-document=")) {
            output = a["--output-document=".len..];
        } else if (a.len > 0 and a[0] == '-' and !std.mem.eql(u8, a, "-")) {
            return usage(ctx, "unrecognized option");
        } else if (url == null) {
            url = a;
        } else {
            return usage(ctx, "too many operands");
        }
    }

    const u = url orelse return usage(ctx, "missing URL");

    const fd = sys.httpGet(u) catch |e| return transportErr(ctx, e);
    defer sys.close(fd);

    // Resolve the output fd: stdout for none or "-", else an opened/truncated file.
    var out_fd: sys.Fd = ctx.stdout;
    var close_out = false;
    if (output) |o| {
        if (!std.mem.eql(u8, o, "-")) {
            out_fd = sys.open(o, .{ .write = true, .create = true, .trunc = true }) catch |e| {
                ctx.errPrint("wget: {s}: {s}\n", .{ o, sys.strerror(sys.toErrno(e)) });
                return 1;
            };
            close_out = true;
        }
    }
    defer if (close_out) sys.close(out_fd);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &buf) catch return 1;
        if (n == 0) break;
        sys.writeAll(out_fd, buf[0..n]) catch return 1;
    }
    return 0;
}

fn transportErr(ctx: *Ctx, e: sys.Error) u8 {
    if (e == error.EPERM) {
        ctx.errPrint("wget: network unavailable\n", .{});
    } else {
        ctx.errPrint("wget: request failed\n", .{});
    }
    return 1;
}

fn usage(ctx: *Ctx, msg: []const u8) u8 {
    ctx.errPrint("wget: {s}\n", .{msg});
    return 2;
}
