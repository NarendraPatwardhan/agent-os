//! /bin/sh — Zig guest shell over shcore and sysroot/zig.

const std = @import("std");
const shcore = @import("shcore");
const sys = @import("sys");

const shos = shcore.os;

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
    sys.print("$ ");
    while (true) {
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

    const mode: Mode = if (argv.len >= 2 and std.mem.eql(u8, argv[1], "-c"))
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
    defer sh.deinit();

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
            repl(allocator, &sh);
            break :blk sh.lastStatus();
        },
    };
}

pub export fn _start() void {
    const code = runShell(sys.wasm_allocator) catch {
        sys.eprint("sh: internal error\n");
        sys.exit(1);
    };
    sys.exit(code);
}
