//! `wscat` -- a line-oriented WebSocket client (DESIGN.md §1). Opens the
//! connection with `sys.wsOpen(url) -> fd` (the kernel owns the connection + framing + TLS
//! for wss) and shuttles bytes both ways with `sys.poll`: ws->stdout, stdin->ws. After
//! stdin EOF it waits one idle window (250 ms) for any final server messages, then exits.
//!
//! Off-kernel (wasi/native backends) `wsOpen` is ENOSYS, so wscat reports
//! `wscat: network unavailable` and exits 1; the full pump below runs only on the kernel.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;

const IDLE_MS: i32 = 250;

const help_doc = cli.Help{
    .summary = "connect to a WebSocket server and shuttle lines both ways",
    .synopsis = &.{"wscat URL"},
    .description =
    \\Opens a WebSocket connection to URL (ws:// or wss://) and pumps bytes in both
    \\directions at once: server -> standard output, and standard input -> server.
    \\After standard input reaches EOF, wscat waits up to 250ms for any final
    \\server messages before exiting.
    \\
    \\The connection, WebSocket framing, and TLS (for wss://) are handled by the
    \\host/kernel; wscat itself is a line-oriented pump over that connection.
    ,
    .operands = "URL   the WebSocket endpoint; must start with ws:// or wss://.",
    .exit = &.{
        .{ .code = 0, .when = "the server closed the connection after at least one message was received" },
        .{ .code = 1, .when = "the connection failed, network access is unavailable, or the server closed before any message arrived" },
        .{ .code = 2, .when = "usage error: missing/malformed URL, an unrecognized option, or too many operands" },
    },
    .deviations_from = "websocat/wscat (Node)",
    .deviations = &.{
        "No subprotocol negotiation, custom headers, ping/pong control, binary-frame distinction, or reconnect logic -- it is a raw byte pump over one connection.",
        "On a backend without a kernel-provided WebSocket transport (e.g. plain native/WASI), every connection fails immediately with \"network unavailable\".",
    },
    .examples = &.{
        .{ .cmd = "wscat wss://echo.example.com/", .note = "interactive: stdin lines are sent, replies print to stdout" },
        .{ .cmd = "echo hello | wscat ws://localhost:8080/", .note = "send one line, then wait out the idle window for replies" },
    },
    .see_also = "fetch, wget (plain HTTP).",
};

pub fn run(ctx: *Ctx) u8 {
    var url: ?[]const u8 = null;
    var i: usize = 1;
    while (i < ctx.args.len) : (i += 1) {
        const a = ctx.args[i];
        if (std.mem.eql(u8, a, "--help")) {
            cli.renderHelp(ctx, "wscat", help_doc);
            return 0;
        } else if (a.len > 0 and a[0] == '-' and !std.mem.eql(u8, a, "-")) {
            ctx.errPrint("wscat: unrecognized option\n", .{});
            return 2;
        } else if (url == null) {
            url = a;
        } else {
            ctx.errPrint("wscat: too many operands\n", .{});
            return 2;
        }
    }

    const u = url orelse {
        ctx.errPrint("wscat: missing URL\n", .{});
        return 2;
    };
    if (!std.mem.startsWith(u8, u, "ws://") and !std.mem.startsWith(u8, u, "wss://")) {
        ctx.errPrint("wscat: URL must be ws:// or wss://\n", .{});
        return 2;
    }

    const ws = sys.wsOpen(u) catch |e| {
        if (e == error.EPERM or e == error.ENOSYS) {
            ctx.errPrint("wscat: network unavailable\n", .{});
        } else {
            ctx.errPrint("wscat: connection failed\n", .{});
        }
        return 1;
    };
    defer sys.close(ws);

    var got_message = false;
    var stdin_open = true;
    var buf: [8192]u8 = undefined;

    while (true) {
        // Poll set: ws always; stdin until its EOF.
        var fds: [2]sys.PollFd = undefined;
        var nfds: usize = 1;
        fds[0] = .{ .fd = ws, .want_read = true, .want_write = false };
        if (stdin_open) {
            fds[1] = .{ .fd = ctx.stdin, .want_read = true, .want_write = false };
            nfds = 2;
        }
        // Block indefinitely while stdin is open; after EOF only wait the idle window.
        const timeout: i32 = if (stdin_open) -1 else IDLE_MS;
        const ready = sys.poll(fds[0..nfds], timeout) catch return 1;
        if (ready == 0) {
            // Timed out: only reached after stdin EOF -> idle window elapsed, done.
            break;
        }

        if (fds[0].readable) {
            const n = sys.read(ws, &buf) catch return 1;
            if (n == 0) {
                // Server closed. Success iff we saw at least one message.
                return if (got_message) 0 else 1;
            }
            got_message = true;
            ctx.outWrite(buf[0..n]) catch return 1;
        }
        if (stdin_open and nfds == 2 and fds[1].readable) {
            const n = sys.read(ctx.stdin, &buf) catch return 1;
            if (n == 0) {
                stdin_open = false; // drop stdin from the set; enter idle window
            } else {
                sys.writeAll(ws, buf[0..n]) catch return 1;
            }
        }
    }

    return if (got_message) 0 else 1;
}
