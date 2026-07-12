//! `fetch` -- a minimal HTTP client (DESIGN.md §1). Builds a request blob
//! `METHOD URL\n<header lines>\n[Content-Length: N\n]\n<body>` and hands it to
//! `sys.httpRequest`, which returns a readable body fd (the kernel/host owns the
//! connection + TLS; on the native backend an in-process HTTP client does the exchange).
//! Streams the body to stdout in 4 KiB chunks. Exit 0 if the status < 400, 1 if >= 400
//! (curl-like: the body is still streamed), 1 on a transport error, 2 on usage.
//!
//! No curl niceties: no -o, -L, -s, -i/-I, -u, -A.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "perform a single HTTP request and print the response body",
    .synopsis = &.{"fetch [-X METHOD] [-H 'Header: value']... [-d BODY] URL"},
    .description =
    \\Builds one HTTP request from METHOD, URL, request headers, and an optional
    \\body, sends it, and streams the response body to standard output. The method
    \\defaults to GET, or to POST when -d is given without an explicit -X. -H may be
    \\repeated to add request headers; -d supplies a request body and adds a
    \\Content-Length header sized to it.
    \\
    \\The connection itself (including TLS for https:// URLs) is performed by the
    \\host/kernel, not by fetch -- fetch only assembles the request blob and relays
    \\the response body byte-for-byte.
    ,
    .options = &.{
        .{ .flags = "-X METHOD", .desc = "HTTP method (default GET, or POST if -d is given)" },
        .{ .flags = "-H 'K: V'", .desc = "add a request header (repeatable)" },
        .{ .flags = "-d BODY", .desc = "request body; implies POST unless -X is also given" },
    },
    .operands = "URL   the address to request.",
    .exit = &.{
        .{ .code = 0, .when = "the response status was < 400 (the body is still streamed either way)" },
        .{ .code = 1, .when = "the response status was >= 400, or the request could not be sent (network unavailable or a transport error)" },
        .{ .code = 2, .when = "usage error: missing URL, an unrecognized option, or an option missing its argument" },
    },
    .deviations_from = "curl",
    .deviations = &.{
        "Only -X/-H/-d and the URL are supported -- no -o (write to file), -L (follow redirects), -s (silent), -i/-I (show/only response headers), -u (basic auth), or -A (user agent).",
        "The response body is streamed to stdout even on a >=400 status (curl-like); only the exit status reflects the failure.",
    },
    .examples = &.{
        .{ .cmd = "fetch https://example.com/", .note = "GET, body to stdout" },
        .{ .cmd = "fetch -X POST -d '{\"a\":1}' -H 'Content-Type: application/json' https://api.example.com/items", .note = "POST with a body and header" },
    },
    .see_also = "wget (save a URL to a file), wscat (WebSocket client).",
};

pub fn run(ctx: *Ctx) u8 {
    var method: ?[]const u8 = null;
    var body: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var headers: std.ArrayListUnmanaged([]const u8) = .empty;

    var i: usize = 1;
    while (i < ctx.args.len) : (i += 1) {
        const a = ctx.args[i];
        if (std.mem.eql(u8, a, "--help")) {
            cli.renderHelp(ctx, "fetch", help_doc);
            return 0;
        } else if (std.mem.eql(u8, a, "-X")) {
            i += 1;
            if (i >= ctx.args.len) return usage(ctx, "option requires an argument -- 'X'");
            method = ctx.args[i];
        } else if (std.mem.eql(u8, a, "-H")) {
            i += 1;
            if (i >= ctx.args.len) return usage(ctx, "option requires an argument -- 'H'");
            headers.append(ctx.gpa, ctx.args[i]) catch return 1;
        } else if (std.mem.eql(u8, a, "-d")) {
            i += 1;
            if (i >= ctx.args.len) return usage(ctx, "option requires an argument -- 'd'");
            body = ctx.args[i];
        } else if (a.len > 0 and a[0] == '-' and !std.mem.eql(u8, a, "-")) {
            return usage(ctx, "unrecognized option");
        } else if (url == null) {
            url = a;
        } else {
            return usage(ctx, "too many operands");
        }
    }

    const u = url orelse return usage(ctx, "missing URL");
    // POST is implied by -d unless -X was given.
    const m = method orelse (if (body != null) "POST" else "GET");

    // Assemble the request blob.
    var blob: std.ArrayListUnmanaged(u8) = .empty;
    blob.appendSlice(ctx.gpa, m) catch return 1;
    blob.append(ctx.gpa, ' ') catch return 1;
    blob.appendSlice(ctx.gpa, u) catch return 1;
    blob.append(ctx.gpa, '\n') catch return 1;
    for (headers.items) |h| {
        blob.appendSlice(ctx.gpa, h) catch return 1;
        blob.append(ctx.gpa, '\n') catch return 1;
    }
    if (body) |b| {
        blob.appendSlice(ctx.gpa, "Content-Length: ") catch return 1;
        appendUint(ctx.gpa, &blob, b.len) catch return 1;
        blob.append(ctx.gpa, '\n') catch return 1;
    }
    blob.append(ctx.gpa, '\n') catch return 1; // blank line separates headers from body
    if (body) |b| blob.appendSlice(ctx.gpa, b) catch return 1;

    const fd = sys.httpRequest(blob.items) catch |e| return transportErr(ctx, e);
    defer sys.close(fd);

    const status = sys.httpStatus(fd) catch |e| return transportErr(ctx, e);

    // Stream the body regardless of status.
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &buf) catch return 1;
        if (n == 0) break;
        ctx.outWrite(buf[0..n]) catch return 1;
    }
    return if (status < 400) 0 else 1;
}

fn transportErr(ctx: *Ctx, e: sys.Error) u8 {
    if (e == error.EPERM) {
        ctx.errPrint("fetch: network unavailable\n", .{});
    } else {
        ctx.errPrint("fetch: request failed\n", .{});
    }
    return 1;
}

fn usage(ctx: *Ctx, msg: []const u8) u8 {
    ctx.errPrint("fetch: {s}\n", .{msg});
    return 2;
}

fn appendUint(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), v: usize) !void {
    var digits: [20]u8 = undefined;
    var n: usize = 0;
    var x = v;
    if (x == 0) {
        try list.append(gpa, '0');
        return;
    }
    while (x != 0) : (x /= 10) {
        digits[n] = '0' + @as(u8, @intCast(x % 10));
        n += 1;
    }
    while (n != 0) {
        n -= 1;
        try list.append(gpa, digits[n]);
    }
}
