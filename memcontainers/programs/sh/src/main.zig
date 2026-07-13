//! /bin/sh — Zig guest shell over shcore and sysroot/zig.

const std = @import("std");
const shcore = @import("shcore");
const shell_wire = @import("shell_zig");
const sys = @import("sys");

const shos = shcore.os;

const AUTOCOMPLETE_MAX_REQUEST: usize = @intCast(sys.constants.AUTOCOMPLETE_MAX_FRAME_BYTES);
const AUTOCOMPLETE_MAX_CANDIDATES: usize = @intCast(sys.constants.AUTOCOMPLETE_MAX_ITEMS);
var autocomplete_buffer: std.ArrayList(u8) = .empty;
var live_shell: ?*shcore.Shell = null;
var live_repl_source: []const u8 = "";
var live_repl_continuation = false;

fn candidateLess(_: void, a: shcore.completion.Candidate, b: shcore.completion.Candidate) bool {
    const order = std.mem.order(u8, a.value, b.value);
    return order == .lt or (order == .eq and std.mem.lessThan(u8, a.kind, b.kind));
}

fn wireContext(context: shcore.completion.Context) []const u8 {
    return switch (context) {
        .command => shell_wire.CONTEXT_COMMAND,
        .path => shell_wire.CONTEXT_PATH,
        .directory => shell_wire.CONTEXT_DIRECTORY,
        .variable => shell_wire.CONTEXT_VARIABLE,
    };
}

fn wireQuote(quote: shcore.completion.Quote) []const u8 {
    return switch (quote) {
        .bare => shell_wire.QUOTE_BARE,
        .single => shell_wire.QUOTE_SINGLE,
        .double => shell_wire.QUOTE_DOUBLE,
    };
}

fn parseWireQuote(value: []const u8) ?shcore.completion.Quote {
    if (std.mem.eql(u8, value, shell_wire.QUOTE_BARE)) return .bare;
    if (std.mem.eql(u8, value, shell_wire.QUOTE_SINGLE)) return .single;
    if (std.mem.eql(u8, value, shell_wire.QUOTE_DOUBLE)) return .double;
    return null;
}

fn replaceAutocompleteBuffer(bytes: []const u8) !i32 {
    if (bytes.len > AUTOCOMPLETE_MAX_REQUEST) return -sys.EMSGSIZE;
    autocomplete_buffer.clearRetainingCapacity();
    try autocomplete_buffer.appendSlice(sys.wasm_allocator, bytes);
    return @intCast(bytes.len);
}

fn shBuffer(len: u32) callconv(.c) u32 {
    if (len != 0) {
        if (len > AUTOCOMPLETE_MAX_REQUEST) return 0;
        autocomplete_buffer.resize(sys.wasm_allocator, len) catch return 0;
    }
    return if (autocomplete_buffer.items.len == 0) 0 else @intCast(@intFromPtr(autocomplete_buffer.items.ptr));
}

fn shAutocomplete(request_len: u32) callconv(.c) i32 {
    const sh = live_shell orelse return -sys.EAGAIN;
    if (request_len > AUTOCOMPLETE_MAX_REQUEST or request_len != autocomplete_buffer.items.len)
        return -sys.EINVAL;
    if (request_len < 3) return -sys.EINVAL;

    var arena_state = std.heap.ArenaAllocator.init(sys.wasm_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const request = arena.dupe(u8, autocomplete_buffer.items) catch return -sys.EMSGSIZE;
    const message_id = @as(u16, request[0]) | (@as(u16, request[1]) << 8);

    if (message_id == shell_wire.PROBE_REQUEST_MSG_ID) {
        const decoded = shell_wire.ProbeRequest.decode(arena, request) catch return -sys.EINVAL;
        const result = if (decoded.interactive and live_repl_source.len != 0) blk: {
            const combined = std.mem.concat(arena, u8, &.{ live_repl_source, decoded.source }) catch return -sys.EMSGSIZE;
            var full = shcore.completion.probe(arena, combined, live_repl_source.len + decoded.cursor) catch return -sys.EINVAL;
            if (full.replace_start < live_repl_source.len) {
                // Submitted lines are immutable; splice only the live fragment.
                const local = shcore.completion.probe(arena, decoded.source, decoded.cursor) catch return -sys.EINVAL;
                full.replace_start = local.replace_start;
                full.replace_end = local.replace_end;
                full.prefix = local.prefix;
            } else {
                full.replace_start -= live_repl_source.len;
                full.replace_end -= live_repl_source.len;
            }
            break :blk full;
        } else shcore.completion.probe(arena, decoded.source, decoded.cursor) catch return -sys.EINVAL;
        var candidates: std.ArrayList(shcore.completion.Candidate) = .empty;
        const truncated = sh.appendCompletionCandidates(
            arena,
            result.context,
            result.prefix,
            &candidates,
            AUTOCOMPLETE_MAX_CANDIDATES,
            @intCast(sys.constants.AUTOCOMPLETE_MAX_SCAN_ENTRIES),
        ) catch return -sys.EMSGSIZE;
        std.mem.sort(shcore.completion.Candidate, candidates.items, {}, candidateLess);
        var wire_candidates = arena.alloc(shell_wire.Candidate, candidates.items.len) catch return -sys.EMSGSIZE;
        for (candidates.items, 0..) |candidate, i| wire_candidates[i] = .{
            .value = candidate.value,
            .kind = candidate.kind,
        };
        const response = shell_wire.ProbeResponse{
            .replace_start = @intCast(result.replace_start),
            .replace_end = @intCast(result.replace_end),
            .prefix = result.prefix,
            .context = wireContext(result.context),
            .quote = wireQuote(result.quote),
            .shell_candidates = wire_candidates,
            .truncated = truncated,
            .continuation = decoded.interactive and live_repl_continuation,
        };
        const encoded = response.encode(arena) catch return -sys.EMSGSIZE;
        return replaceAutocompleteBuffer(encoded) catch -sys.EMSGSIZE;
    }

    if (message_id == shell_wire.RENDER_REQUEST_MSG_ID) {
        const decoded = shell_wire.RenderRequest.decode(arena, request) catch return -sys.EINVAL;
        const quote = parseWireQuote(decoded.quote) orelse return -sys.EINVAL;
        if (decoded.candidates.len > AUTOCOMPLETE_MAX_CANDIDATES) return -sys.EMSGSIZE;
        var raw_values = arena.alloc([]const u8, decoded.candidates.len) catch return -sys.EMSGSIZE;
        var items = arena.alloc(shell_wire.Item, decoded.candidates.len) catch return -sys.EMSGSIZE;
        for (decoded.candidates, 0..) |candidate, i| {
            raw_values[i] = candidate.value;
            items[i] = .{
                .label = candidate.value,
                .value = shcore.completion.renderValue(arena, candidate.value, quote) catch return -sys.EMSGSIZE,
                .kind = candidate.kind,
            };
        }
        const raw_prefix = shcore.completion.commonPrefix(raw_values);
        const rendered_prefix = shcore.completion.renderValue(arena, raw_prefix, quote) catch return -sys.EMSGSIZE;
        const response = shell_wire.CompletionResult{
            .replace_start = decoded.replace_start,
            .replace_end = decoded.replace_end,
            .common_prefix = rendered_prefix,
            .items = items,
            .truncated = decoded.truncated,
        };
        const encoded = response.encode(arena) catch return -sys.EMSGSIZE;
        return replaceAutocompleteBuffer(encoded) catch -sys.EMSGSIZE;
    }

    return -sys.EINVAL;
}

fn shellExportName(comptime variant: []const u8) []const u8 {
    inline for (shell_wire.EXPORTS) |desc| {
        if (std.mem.eql(u8, desc.variant, variant)) return desc.name;
    }
    @compileError("shell contract is missing export variant " ++ variant);
}

comptime {
    @export(&shBuffer, .{ .name = shellExportName("ShBuf") });
    @export(&shAutocomplete, .{ .name = shellExportName("ShAutocomplete") });
}

pub const panic = std.debug.FullPanic(struct {
    pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        _ = msg;
        _ = first_trace_addr;
        sys.eprint("sh: panic\n");
        sys.exit(134);
    }
}.panic);

const HELP =
    \\sh - the Zig memcontainers shell
    \\
    \\Usage: sh                     start an interactive shell
    \\       sh -l|--login          start a login shell and source /etc/profile
    \\       sh -c COMMAND [ARG]...  run COMMAND, then exit
    \\       sh FILE [ARG]...        run FILE as a shell script
    \\
;

const SysrootOs = struct {
    allocator: std.mem.Allocator,
    interactive: bool,

    fn shellOs(self: *SysrootOs) shos.ShellOs {
        return .{
            .ptr = @ptrCast(self),
            .allocator = self.allocator,
            .vtable = &vtable,
        };
    }
};

fn ctx(ptr: *anyopaque) *SysrootOs {
    return @ptrCast(@alignCast(ptr));
}

fn shellErr(errno: sys.Errno) shos.ShellError {
    return switch (errno) {
        sys.EACCES => error.AccessDenied,
        sys.EBADF => error.BadFileDescriptor,
        sys.EINVAL => error.InvalidArgument,
        sys.ENOTDIR => error.NotDir,
        sys.ENOENT => error.NotFound,
        sys.ENOSYS => error.NotImplemented,
        sys.EPERM => error.PermissionDenied,
        sys.EMFILE => error.TooManyFiles,
        else => error.Io,
    };
}

fn statusToShell(st: sys.Status) shos.ShellError!void {
    return switch (st) {
        .ok => {},
        .err => |errno| shellErr(errno),
    };
}

fn vSpawn(ptr: *anyopaque, argv: []const []const u8, in_fd: shos.Fd, out_fd: shos.Fd, err_fd: shos.Fd, tier: i32) shos.ShellError!shos.Pid {
    const c = ctx(ptr);
    var blob = std.ArrayList(u8).empty;
    defer blob.deinit(c.allocator);
    for (argv) |arg| {
        blob.appendSlice(c.allocator, arg) catch return error.Io;
        blob.append(c.allocator, 0) catch return error.Io;
    }
    return switch (sys.spawnTiered(blob.items, in_fd, out_fd, err_fd, tier)) {
        .ok => |pid| pid,
        .err => |errno| shellErr(errno),
    };
}

fn vWaitpid(_: *anyopaque, pid: shos.Pid) shos.ShellError!i32 {
    return switch (sys.waitpid(@intCast(pid))) {
        .ok => |status| status,
        .err => |errno| shellErr(errno),
    };
}

fn vTryWaitAny(_: *anyopaque) shos.ShellError!?shos.WaitStatus {
    return switch (sys.waitpidNoHang(-1)) {
        .ok => |maybe| if (maybe) |ws| .{ .pid = ws.pid, .status = ws.status } else null,
        .err => |errno| shellErr(errno),
    };
}

fn vGetpid(_: *anyopaque) shos.Pid {
    return sys.getpid();
}

fn vPipe(_: *anyopaque) shos.ShellError!struct { shos.Fd, shos.Fd } {
    return switch (sys.pipe()) {
        .ok => |fds| fds,
        .err => |errno| shellErr(errno),
    };
}

fn vDup(_: *anyopaque, fd: shos.Fd) shos.ShellError!shos.Fd {
    return switch (sys.dup(fd)) {
        .ok => |new_fd| new_fd,
        .err => |errno| shellErr(errno),
    };
}

fn vDup2(_: *anyopaque, old_fd: shos.Fd, new_fd: shos.Fd) shos.ShellError!void {
    return statusToShell(sys.dup2(old_fd, new_fd));
}

fn vClose(_: *anyopaque, fd: shos.Fd) void {
    sys.close(fd);
}

fn vOpen(_: *anyopaque, path: []const u8, flags: i32) shos.ShellError!shos.Fd {
    return switch (sys.open(path, flags)) {
        .ok => |fd| fd,
        .err => |errno| shellErr(errno),
    };
}

fn vRead(_: *anyopaque, fd: shos.Fd, buf: []u8) shos.ShellError!usize {
    return switch (sys.read(fd, buf)) {
        .ok => |n| n,
        .err => |errno| shellErr(errno),
    };
}

fn vWriteAll(_: *anyopaque, fd: shos.Fd, bytes: []const u8) shos.ShellError!void {
    return statusToShell(sys.writeAll(fd, bytes));
}

fn vReaddir(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) shos.ShellError![]const []const u8 {
    return switch (sys.readdirAlloc(allocator, path)) {
        .ok => |entries| entries,
        .err => |errno| shellErr(errno),
    };
}

fn vStat(_: *anyopaque, path: []const u8) shos.ShellError!shos.FileStat {
    return switch (sys.stat(path)) {
        .ok => |st| .{
            .is_dir = st.is_dir,
            .size = st.size,
            .mode = st.mode,
            .mtime = st.mtime,
        },
        .err => |errno| shellErr(errno),
    };
}

fn vMkdir(_: *anyopaque, path: []const u8) shos.ShellError!void {
    return statusToShell(sys.mkdir(path));
}

fn vUnlink(_: *anyopaque, path: []const u8) shos.ShellError!void {
    return statusToShell(sys.unlink(path));
}

fn vGetcwd(_: *anyopaque, allocator: std.mem.Allocator) shos.ShellError![]const u8 {
    return switch (sys.getcwdAlloc(allocator)) {
        .ok => |cwd| cwd,
        .err => |errno| shellErr(errno),
    };
}

fn vChdir(_: *anyopaque, path: []const u8) shos.ShellError!void {
    return statusToShell(sys.chdir(path));
}

fn vBind(_: *anyopaque, old: []const u8, new: []const u8) shos.ShellError!void {
    return statusToShell(sys.bind(old, new));
}

fn vUnmount(_: *anyopaque, path: []const u8) shos.ShellError!void {
    return statusToShell(sys.unmount(path));
}

fn vGetenv(ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) shos.ShellError!?[]const u8 {
    _ = ctx(ptr);
    return switch (sys.getenv(allocator, name)) {
        .ok => |value| value,
        .err => |errno| shellErr(errno),
    };
}

fn vSetenv(ptr: *anyopaque, name: []const u8, value: []const u8) shos.ShellError!void {
    const c = ctx(ptr);
    return statusToShell(sys.setenv(c.allocator, name, value));
}

fn vUnsetenv(ptr: *anyopaque, name: []const u8) shos.ShellError!void {
    const c = ctx(ptr);
    return statusToShell(sys.unsetenv(c.allocator, name));
}

fn vEnviron(_: *anyopaque, allocator: std.mem.Allocator) shos.ShellError![]const []const u8 {
    return switch (sys.environ(allocator)) {
        .ok => |names| names,
        .err => |errno| shellErr(errno),
    };
}

fn vKill(_: *anyopaque, pid: i32, sig: shos.Signal) shos.ShellError!void {
    return statusToShell(sys.kill(pid, @intFromEnum(sig)));
}

fn vSetSigdisp(_: *anyopaque, sig: shos.Signal, disp: shos.SigDisp) void {
    _ = sys.sigdisp(@intFromEnum(sig), @intFromEnum(disp));
}

fn vSetpgid(_: *anyopaque, pid: shos.Pid, pgid: shos.Pid) shos.ShellError!void {
    return statusToShell(sys.setpgid(@intCast(pid), @intCast(pgid)));
}

fn vSetForegroundPgid(_: *anyopaque, pgid: shos.Pid) shos.ShellError!void {
    return statusToShell(sys.tcsetpgrp(@intCast(pgid)));
}

fn vIsatty(ptr: *anyopaque, fd: shos.Fd) bool {
    return ctx(ptr).interactive and sys.isatty(fd);
}

const vtable = shos.ShellOs.VTable{
    .spawn = vSpawn,
    .waitpid = vWaitpid,
    .try_wait_any = vTryWaitAny,
    .getpid = vGetpid,
    .pipe = vPipe,
    .dup = vDup,
    .dup2 = vDup2,
    .close = vClose,
    .open = vOpen,
    .read = vRead,
    .write_all = vWriteAll,
    .readdir = vReaddir,
    .stat = vStat,
    .mkdir = vMkdir,
    .unlink = vUnlink,
    .getcwd = vGetcwd,
    .chdir = vChdir,
    .bind = vBind,
    .unmount = vUnmount,
    .getenv = vGetenv,
    .setenv = vSetenv,
    .unsetenv = vUnsetenv,
    .environ = vEnviron,
    .kill = vKill,
    .set_sigdisp = vSetSigdisp,
    .setpgid = vSetpgid,
    .set_foreground_pgid = vSetForegroundPgid,
    .isatty = vIsatty,
};

const Mode = union(enum) {
    command: struct { source: []const u8, args: []const []const u8 },
    script: struct { path: []const u8, args: []const []const u8 },
    interactive,
};

const LineRead = union(enum) {
    line: []const u8,
    eof,
    interrupted,
};

fn readLine(allocator: std.mem.Allocator) LineRead {
    var out = std.ArrayList(u8).empty;
    var b: [1]u8 = undefined;
    while (true) {
        switch (sys.read(sys.STDIN, &b)) {
            .ok => |n| {
                if (n == 0) {
                    if (out.items.len == 0) return .eof;
                    return .{ .line = out.toOwnedSlice(allocator) catch {
                        out.deinit(allocator);
                        return .eof;
                    } };
                }
                if (b[0] == '\n') return .{ .line = out.toOwnedSlice(allocator) catch {
                    out.deinit(allocator);
                    return .eof;
                } };
                if (b[0] != '\r') out.append(allocator, b[0]) catch {
                    out.deinit(allocator);
                    return .eof;
                };
            },
            .err => |errno| {
                out.deinit(allocator);
                if (errno == sys.EINTR) return .interrupted;
                return .eof;
            },
        }
    }
}

fn exitCode(flow: shcore.Flow, status: i32) i32 {
    return switch (flow) {
        .exit => |code| code,
        else => status,
    };
}

fn repl(allocator: std.mem.Allocator, sh: *shcore.Shell) void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    defer {
        live_repl_source = "";
        live_repl_continuation = false;
    }
    sys.print("$ ");
    while (true) {
        // Stable while the cooperative shell is suspended in readLine.
        live_repl_source = buf.items;
        live_repl_continuation = buf.items.len != 0;
        switch (readLine(allocator)) {
            .eof => {
                if (std.mem.trim(u8, buf.items, " \t\r\n").len == 0) sys.print("\n");
                if (buf.items.len != 0) {
                    const flow = sh.run(buf.items) catch {
                        sys.eprint("sh: execution error\n");
                        break;
                    };
                    _ = exitCode(flow, sh.lastStatus());
                }
                break;
            },
            .interrupted => {
                buf.clearRetainingCapacity();
                sys.print("$ ");
                continue;
            },
            .line => |line| {
                defer allocator.free(line);
                buf.appendSlice(allocator, line) catch break;
                buf.append(allocator, '\n') catch break;
            },
        }

        var parse_arena = std.heap.ArenaAllocator.init(allocator);
        defer parse_arena.deinit();
        _ = shcore.parse(parse_arena.allocator(), buf.items) catch |err| switch (err) {
            error.Incomplete => {
                sys.print("> ");
                continue;
            },
            else => {},
        };

        const flow = sh.run(buf.items) catch {
            sys.eprint("sh: execution error\n");
            break;
        };
        buf.clearRetainingCapacity();
        switch (flow) {
            .exit => break,
            else => sys.print("$ "),
        }
    }
}

fn runShell(allocator: std.mem.Allocator) !i32 {
    const argv = switch (sys.argsAlloc(allocator)) {
        .ok => |args| args,
        .err => return 1,
    };
    defer sys.freeStringList(allocator, argv);

    if (argv.len >= 2 and (std.mem.eql(u8, argv[1], "--help") or std.mem.eql(u8, argv[1], "-h"))) {
        sys.print(HELP);
        return 0;
    }

    const login = argv.len >= 2 and
        (std.mem.eql(u8, argv[1], "-l") or std.mem.eql(u8, argv[1], "--login"));

    const mode: Mode = if (login)
        .interactive
    else if (argv.len >= 2 and std.mem.eql(u8, argv[1], "-c"))
        .{ .command = .{
            .source = if (argv.len >= 3) argv[2] else "",
            .args = if (argv.len >= 4) argv[3..] else &.{},
        } }
    else if (argv.len >= 2)
        .{ .script = .{ .path = argv[1], .args = argv[2..] } }
    else
        .interactive;

    const interactive = switch (mode) {
        .interactive => true,
        else => false,
    };

    var adapter = SysrootOs{ .allocator = allocator, .interactive = interactive };
    if (interactive) {
        _ = sys.sigdisp(sys.SIGINT, sys.SIG_IGN);
        _ = sys.sigdisp(sys.SIGTSTP, sys.SIG_IGN);
    }
    var shell_os = adapter.shellOs();
    var sh = shcore.init(allocator, &shell_os);
    live_shell = &sh;
    defer {
        live_shell = null;
        sh.deinit();
    }

    return switch (mode) {
        .command => |cmd| blk: {
            if (cmd.args.len != 0) {
                try sh.setArg0(cmd.args[0]);
                try sh.setPositional(cmd.args[1..]);
            }
            const flow = try sh.run(cmd.source);
            break :blk exitCode(flow, sh.lastStatus());
        },
        .script => |script| blk: {
            try sh.setArg0(script.path);
            try sh.setPositional(script.args);
            const source = switch (sys.readFileAlloc(allocator, script.path)) {
                .ok => |src| src,
                .err => |errno| {
                    if (std.fmt.allocPrint(allocator, "sh: cannot open {s}: {s}\n", .{ script.path, sys.strerror(errno) })) |msg| {
                        defer allocator.free(msg);
                        sys.eprint(msg);
                    } else |_| {
                        sys.eprint("sh: cannot open script\n");
                    }
                    break :blk 127;
                },
            };
            defer allocator.free(source);
            const flow = try sh.run(source);
            break :blk exitCode(flow, sh.lastStatus());
        },
        .interactive => blk: {
            if (login) {
                switch (sys.readFileAlloc(allocator, "/etc/profile")) {
                    .ok => |source| {
                        defer allocator.free(source);
                        const flow = try sh.run(source);
                        switch (flow) {
                            .exit => break :blk exitCode(flow, sh.lastStatus()),
                            else => {},
                        }
                    },
                    .err => {},
                }
            }
            repl(allocator, &sh);
            break :blk sh.lastStatus();
        },
    };
}

pub export fn _start() void {
    defer autocomplete_buffer.deinit(sys.wasm_allocator);
    const code = runShell(sys.wasm_allocator) catch {
        sys.eprint("sh: internal error\n");
        sys.exit(1);
    };
    sys.exit(code);
}
