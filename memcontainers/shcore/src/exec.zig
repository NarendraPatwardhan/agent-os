//! Blocking tree-walking shell executor.

const std = @import("std");
const arith = @import("arith.zig");
const ast = @import("ast.zig");
const builtins = @import("builtins.zig");
const echo = @import("echo.zig");
const expand = @import("expand.zig");
const glob = @import("glob.zig");
const os = @import("os.zig");
const parser = @import("parser.zig");
const printf = @import("printf.zig");
const testexpr = @import("testexpr.zig");
const token = @import("token.zig");
const word = @import("word.zig");

const CAPTURE_FD_BASE: os.Fd = -1000;

pub const Options = struct {
    errexit: bool = false,
    nounset: bool = false,
    xtrace: bool = false,
    pipefail: bool = false,
};

pub const Flow = union(enum) {
    normal,
    break_loop: u32,
    continue_loop: u32,
    return_status: i32,
    exit: i32,
};

const VarVal = struct {
    value: []const u8,
    exported: bool = false,
};

const LocalRestore = struct {
    name: []const u8,
    prev: ?VarVal,
};

const Frame = struct {
    saved_positional: []const []const u8,
    saved_positional_owned: bool,
    saved_arg0: []const u8,
    saved_arg0_owned: bool,
    locals: std.ArrayList(LocalRestore) = .empty,
};

const Job = struct {
    id: u32,
    pids: []const os.Pid,
    cmd: []const u8,
    running: bool = true,
    stopped: bool = false,
};

const FgWait = union(enum) {
    exited: i32,
    stopped,
};

const EnvRestore = struct {
    name: []const u8,
    prev: ?VarVal,
};

const Triple = struct {
    fds: [3]os.Fd,
    owned: []const os.Fd = &.{},
};

const Started = union(enum) {
    pid: struct { pid: os.Pid, restore: []const EnvRestore },
    done: i32,
    control: Flow,
};

const StageOutput = struct {
    fd: os.Fd,
    temp: ?[]const u8,
};

const Snapshot = struct {
    vars: std.StringHashMap(VarVal),
    positional: []const []const u8,
    arg0: []const u8,
    opts: Options,
    last_status: i32,
    cwd: []const u8,
    exported: std.StringHashMap([]const u8),
};

pub const Shell = struct {
    allocator: std.mem.Allocator,
    os: *os.ShellOs,
    vars: std.StringHashMap(VarVal),
    funcs: std.StringHashMap(*ast.Command),
    positional: []const []const u8 = &.{},
    positional_owned: bool = false,
    arg0: []const u8 = "sh",
    arg0_owned: bool = false,
    frames: std.ArrayList(Frame) = .empty,
    opts: Options = .{},
    last_status: i32 = 0,
    last_bg: ?os.Pid = null,
    shell_pid: os.Pid = 0,
    cur_fds: [3]os.Fd = .{ os.STDIN, os.STDOUT, os.STDERR },
    jobs: std.ArrayList(Job) = .empty,
    next_job: u32 = 1,
    tmp_seq: u32 = 0,
    captures: std.ArrayList(std.ArrayList(u8)) = .empty,
    subshell_depth: u32 = 0,
    errexit_eligible: bool = false,

    pub fn init(allocator: std.mem.Allocator, shell_os: *os.ShellOs) Shell {
        var sh = Shell{
            .allocator = allocator,
            .os = shell_os,
            .vars = std.StringHashMap(VarVal).init(allocator),
            .funcs = std.StringHashMap(*ast.Command).init(allocator),
            .shell_pid = shell_os.getpid(),
        };
        sh.seedEnvironment() catch {};
        sh.setVarRaw("IFS", " \t\n") catch {};
        _ = shell_os.mkdir("/tmp") catch {};
        return sh;
    }

    pub fn deinit(self: *Shell) void {
        self.freeVarMap(&self.vars);
        self.freeFuncMap(&self.funcs);
        if (self.positional_owned) self.freeStringList(self.positional);
        if (self.arg0_owned) self.allocator.free(self.arg0);
        for (self.frames.items) |*frame| self.freeFrame(frame);
        self.frames.deinit(self.allocator);
        for (self.jobs.items) |*job| self.freeJob(job);
        self.jobs.deinit(self.allocator);
        for (self.captures.items) |*cap| cap.deinit(self.allocator);
        self.captures.deinit(self.allocator);
    }

    pub fn setArg0(self: *Shell, name: []const u8) !void {
        const owned = try self.allocator.dupe(u8, name);
        if (self.arg0_owned) self.allocator.free(self.arg0);
        self.arg0 = owned;
        self.arg0_owned = true;
    }

    pub fn setPositional(self: *Shell, args: []const []const u8) !void {
        const out = try self.cloneStringList(args);
        if (self.positional_owned) self.freeStringList(self.positional);
        self.positional = out;
        self.positional_owned = true;
    }

    pub fn lastStatus(self: *const Shell) i32 {
        return self.last_status;
    }

    pub fn run(self: *Shell, source: []const u8) !Flow {
        if (std.mem.trim(u8, source, " \t\r\n").len == 0) {
            self.last_status = 0;
            return .normal;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const script = parser.parse(arena.allocator(), source) catch |err| {
            switch (err) {
                error.Incomplete => self.eprintln("sh: syntax error: incomplete input"),
                error.Syntax => self.eprintln("sh: syntax error"),
                else => self.eprintln("sh: syntax error"),
            }
            self.last_status = 2;
            return .normal;
        };
        return self.execList(&script.list);
    }

    fn seedEnvironment(self: *Shell) !void {
        const names = self.os.environ(self.allocator) catch return;
        defer self.freeStringList(names);
        for (names) |name| {
            if (self.os.getenv(self.allocator, name) catch null) |value| {
                defer self.allocator.free(value);
                try self.putVarCopy(name, value, true);
            }
        }
    }

    fn getVar(self: *Shell, name: []const u8) ?[]const u8 {
        return if (self.vars.get(name)) |v| v.value else null;
    }

    fn setVarRaw(self: *Shell, name: []const u8, value: []const u8) !void {
        const exported = if (self.vars.get(name)) |v| v.exported else false;
        try self.putVarCopy(name, value, exported);
        if (exported) {
            const stored = self.getVar(name) orelse "";
            self.os.setenv(name, stored) catch {};
        }
    }

    fn exportVar(self: *Shell, name: []const u8, maybe_value: ?[]const u8) !void {
        const value = maybe_value orelse self.getVar(name) orelse "";
        try self.putVarCopy(name, value, true);
        const stored = self.getVar(name) orelse "";
        self.os.setenv(name, stored) catch {};
    }

    fn unsetVar(self: *Shell, name: []const u8) void {
        self.removeVarOnly(name, true);
        if (self.funcs.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            ast.destroyCommand(self.allocator, old.value);
        }
    }

    fn removeVarOnly(self: *Shell, name: []const u8, update_env: bool) void {
        if (self.vars.fetchRemove(name)) |old| {
            if (update_env and old.value.exported) self.os.unsetenv(name) catch {};
            self.freeVarEntry(old.key, old.value);
        }
    }

    fn putVarCopy(self: *Shell, name: []const u8, value: []const u8, exported: bool) !void {
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        const val = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(val);
        if (self.vars.fetchRemove(name)) |old| self.freeVarEntry(old.key, old.value);
        try self.vars.put(key, .{ .value = val, .exported = exported });
    }

    fn cloneVar(self: *Shell, value: VarVal) !VarVal {
        return .{ .value = try self.allocator.dupe(u8, value.value), .exported = value.exported };
    }

    fn freeVarEntry(self: *Shell, key: []const u8, value: VarVal) void {
        self.allocator.free(key);
        self.allocator.free(value.value);
    }

    fn freeVarMap(self: *Shell, map: *std.StringHashMap(VarVal)) void {
        var it = map.iterator();
        while (it.next()) |entry| self.freeVarEntry(entry.key_ptr.*, entry.value_ptr.*);
        map.deinit();
    }

    fn putFunction(self: *Shell, name: []const u8, body: *ast.Command) !void {
        errdefer ast.destroyCommand(self.allocator, body);
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        if (self.funcs.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            ast.destroyCommand(self.allocator, old.value);
        }
        try self.funcs.put(key, body);
    }

    fn freeFuncMap(self: *Shell, map: *std.StringHashMap(*ast.Command)) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            ast.destroyCommand(self.allocator, entry.value_ptr.*);
        }
        map.deinit();
    }

    fn cloneStringList(self: *Shell, items: []const []const u8) ![]const []const u8 {
        if (items.len == 0) return &.{};
        const out = try self.allocator.alloc([]const u8, items.len);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |item| self.allocator.free(item);
            self.allocator.free(out);
        }
        for (items, 0..) |item, i| {
            out[i] = try self.allocator.dupe(u8, item);
            initialized += 1;
        }
        return out;
    }

    fn freeStringList(self: *Shell, items: []const []const u8) void {
        for (items) |item| self.allocator.free(item);
        if (items.len != 0) self.allocator.free(items);
    }

    fn freeLocalRestore(self: *Shell, local: LocalRestore) void {
        self.allocator.free(local.name);
        if (local.prev) |prev| self.allocator.free(prev.value);
    }

    fn freeFrame(self: *Shell, frame: *Frame) void {
        var idx = frame.locals.items.len;
        while (idx > 0) {
            idx -= 1;
            self.freeLocalRestore(frame.locals.items[idx]);
        }
        frame.locals.deinit(self.allocator);
        if (frame.saved_positional_owned) self.freeStringList(frame.saved_positional);
        if (frame.saved_arg0_owned) self.allocator.free(frame.saved_arg0);
    }

    fn freeEnvRestores(self: *Shell, restores: []const EnvRestore) void {
        for (restores) |entry_restore| {
            self.allocator.free(entry_restore.name);
            if (entry_restore.prev) |prev| self.allocator.free(prev.value);
        }
        if (restores.len != 0) self.allocator.free(restores);
    }

    fn freeJob(self: *Shell, job: *Job) void {
        if (job.pids.len != 0) self.allocator.free(job.pids);
        self.allocator.free(job.cmd);
    }

    fn emit(self: *Shell, fd: os.Fd, bytes: []const u8) void {
        if (self.captureIndex(fd)) |idx| {
            if (idx < self.captures.items.len) {
                self.captures.items[idx].appendSlice(self.allocator, bytes) catch {};
            }
            return;
        }
        self.os.writeAll(fd, bytes) catch {};
    }

    fn writeFd(self: *Shell, fd: os.Fd, bytes: []const u8) void {
        self.emit(fd, bytes);
    }

    fn eprintln(self: *Shell, msg: []const u8) void {
        self.emit(self.cur_fds[2], msg);
        self.emit(self.cur_fds[2], "\n");
    }

    fn captureIndex(_: *Shell, fd: os.Fd) ?usize {
        if (fd <= CAPTURE_FD_BASE) return @intCast(CAPTURE_FD_BASE - fd);
        return null;
    }

    fn captureFd(idx: usize) os.Fd {
        return CAPTURE_FD_BASE - @as(os.Fd, @intCast(idx));
    }

    fn drainCaptureFile(self: *Shell, path: []const u8, idx: usize) void {
        const rfd = self.os.open(path, os.O_READ) catch {
            _ = self.os.unlink(path) catch {};
            return;
        };
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = self.os.read(rfd, &buf) catch break;
            if (n == 0) break;
            if (idx < self.captures.items.len) {
                self.captures.items[idx].appendSlice(self.allocator, buf[0..n]) catch {};
            }
        }
        self.os.close(rfd);
        _ = self.os.unlink(path) catch {};
    }

    fn execList(self: *Shell, list: *const ast.List) anyerror!Flow {
        var flow: Flow = .normal;
        for (list.items) |item| {
            switch (item.sep) {
                .async => self.execAndOrAsync(&item.and_or),
                .seq => {
                    flow = try self.execAndOr(&item.and_or);
                    if (!flowIsNormal(flow)) return flow;
                    if (self.opts.errexit and self.errexit_eligible) return .{ .exit = self.last_status };
                },
            }
        }
        return flow;
    }

    fn execAndOr(self: *Shell, ao: *const ast.AndOr) anyerror!Flow {
        var executed_last = ao.rest.len == 0;
        var flow = try self.execPipeline(&ao.first);
        if (!flowIsNormal(flow)) return flow;

        for (ao.rest, 0..) |rest, idx| {
            const should_run = switch (rest.op) {
                .and_if => self.last_status == 0,
                .or_if => self.last_status != 0,
            };
            if (should_run) {
                flow = try self.execPipeline(&rest.pipeline);
                if (!flowIsNormal(flow)) return flow;
                executed_last = idx == ao.rest.len - 1;
            } else {
                executed_last = false;
            }
        }

        self.errexit_eligible = executed_last and self.last_status != 0;
        return .normal;
    }

    fn execAndOrAsync(self: *Shell, ao: *const ast.AndOr) void {
        const pids = self.startPipelineBackground(&ao.first) catch &.{};
        if (pids.len == 0) return;
        defer self.allocator.free(pids);
        if (self.jobControl()) {
            const group = pids[0];
            for (pids) |pid| self.os.setpgid(pid, group) catch {};
        }
        const id = self.next_job;
        self.next_job += 1;
        self.last_bg = pids[pids.len - 1];
        const job_pids = self.allocator.dupe(os.Pid, pids) catch return;
        const job_cmd = self.allocator.dupe(u8, "background") catch {
            self.allocator.free(job_pids);
            return;
        };
        self.jobs.append(self.allocator, .{
            .id = id,
            .pids = job_pids,
            .cmd = job_cmd,
        }) catch {
            self.allocator.free(job_pids);
            self.allocator.free(job_cmd);
            return;
        };
        const marker = std.fmt.allocPrint(self.allocator, "[{d}] {d}\n", .{ id, pids[pids.len - 1] }) catch return;
        defer self.allocator.free(marker);
        self.writeFd(self.cur_fds[1], marker);
        self.last_status = 0;
    }

    fn execPipeline(self: *Shell, pl: *const ast.Pipeline) anyerror!Flow {
        const flow = if (pl.cmds.len == 1)
            try self.execCommand(&pl.cmds[0], self.cur_fds)
        else
            try self.execMultiPipeline(pl);
        if (pl.bang) self.last_status = if (self.last_status == 0) 1 else 0;
        return flow;
    }

    fn execMultiPipeline(self: *Shell, pl: *const ast.Pipeline) anyerror!Flow {
        const n = pl.cmds.len;
        var statuses = try self.allocator.alloc(i32, n);
        defer self.allocator.free(statuses);
        @memset(statuses, 0);
        var pids = try self.allocator.alloc(?os.Pid, n);
        defer self.allocator.free(pids);
        @memset(pids, null);
        var temps = std.ArrayList([]const u8).empty;
        defer {
            for (temps.items) |path| self.allocator.free(path);
            temps.deinit(self.allocator);
        }

        const base = self.cur_fds;
        var cur_in = base[0];
        var cur_in_owned = false;

        for (pl.cmds, 0..) |cmd, i| {
            const is_last = i + 1 == n;
            const plan = try self.planCommand(&cmd);
            defer self.freePlan(plan);
            const is_inline = switch (plan) {
                .inline_cmd, .failed => true,
                .simple => |simple| self.expandedRunsInline(simple.argv),
            };

            if (is_inline) {
                const out: StageOutput = if (is_last) .{ .fd = base[1], .temp = null } else blk: {
                    const path = try self.tmpPath("pipe");
                    const fd = self.os.open(path, os.O_WRITE | os.O_CREATE | os.O_TRUNC) catch blk2: {
                        self.allocator.free(path);
                        break :blk2 base[1];
                    };
                    if (fd == base[1]) self.allocator.free(path);
                    break :blk .{ .fd = fd, .temp = if (fd == base[1]) null else path };
                };
                statuses[i] = switch (plan) {
                    .inline_cmd => try self.runInlineStage(&cmd, .{ cur_in, out.fd, base[2] }),
                    .simple => |simple| try self.runInlineSimple(simple.argv, simple.assigns, simple.redirs, .{ cur_in, out.fd, base[2] }),
                    .failed => |status| status,
                };
                if (cur_in_owned) self.os.close(cur_in);
                if (out.temp) |path| {
                    self.os.close(out.fd);
                    cur_in = self.os.open(path, os.O_READ) catch base[0];
                    cur_in_owned = cur_in != base[0];
                    try temps.append(self.allocator, path);
                } else {
                    cur_in = base[0];
                    cur_in_owned = false;
                }
                continue;
            }

            const simple = switch (plan) {
                .simple => |s| s,
                else => unreachable,
            };
            const pipe_pair = if (is_last) null else self.os.pipe() catch {
                self.eprintln("sh: cannot create pipe");
                if (cur_in_owned) self.os.close(cur_in);
                self.last_status = 1;
                return .normal;
            };
            const out_fd = if (pipe_pair) |pair| pair[1] else base[1];
            const next_in = if (pipe_pair) |pair| pair[0] else null;

            const snap = try self.snapshot();
            const started = try self.dispatchSimple(simple.argv, simple.assigns, simple.redirs, .{ cur_in, out_fd, base[2] });
            const control_status = self.last_status;
            try self.restore(snap);
            switch (started) {
                .pid => |p| {
                    pids[i] = p.pid;
                    self.freeEnvRestores(p.restore);
                },
                .done => |status| statuses[i] = status,
                .control => statuses[i] = control_status,
            }
            if (cur_in_owned) self.os.close(cur_in);
            if (!is_last) self.os.close(out_fd);
            cur_in = next_in orelse base[0];
            cur_in_owned = next_in != null;
        }
        if (cur_in_owned) self.os.close(cur_in);

        var live = std.ArrayList(os.Pid).empty;
        defer live.deinit(self.allocator);
        for (pids) |maybe| if (maybe) |pid| try live.append(self.allocator, pid);
        self.enterForeground(live.items);
        var stopped = false;
        for (pids, 0..) |maybe, i| {
            if (maybe) |pid| {
                switch (self.waitOne(pid)) {
                    .exited => |status| statuses[i] = status,
                    .stopped => {
                        stopped = true;
                        break;
                    },
                }
            }
        }
        self.leaveForeground();

        for (temps.items) |path| _ = self.os.unlink(path) catch {};
        if (stopped) {
            _ = self.recordStopped(live.items, "pipeline") catch {};
            self.last_status = 128 + @intFromEnum(os.Signal.tstp);
            return .normal;
        }
        self.last_status = if (self.opts.pipefail) blk: {
            var idx = statuses.len;
            while (idx > 0) {
                idx -= 1;
                if (statuses[idx] != 0) break :blk statuses[idx];
            }
            break :blk 0;
        } else statuses[n - 1];
        return .normal;
    }

    const Plan = union(enum) {
        inline_cmd,
        simple: struct { argv: []const []const u8, assigns: []const AssignValue, redirs: []const ast.Redirect },
        failed: i32,
    };

    const AssignValue = struct {
        name: []const u8,
        value: []const u8,
    };

    fn planCommand(self: *Shell, cmd: *const ast.Command) !Plan {
        return switch (cmd.*) {
            .simple => |sc| blk: {
                const expanded = self.expandSimple(&sc) catch break :blk .{ .failed = 1 };
                break :blk .{ .simple = .{
                    .argv = expanded.argv,
                    .assigns = expanded.assigns,
                    .redirs = sc.redirs,
                } };
            },
            else => .inline_cmd,
        };
    }

    fn startPipelineBackground(self: *Shell, pl: *const ast.Pipeline) anyerror![]const os.Pid {
        if (pl.cmds.len == 1 and pl.cmds[0] == .simple) {
            switch (try self.startCommand(&pl.cmds[0], self.cur_fds)) {
                .pid => |p| {
                    try self.applyEnvRestore(p.restore);
                    const out = try self.allocator.alloc(os.Pid, 1);
                    out[0] = p.pid;
                    return out;
                },
                .done => |status| {
                    self.last_status = status;
                    return &.{};
                },
                .control => return &.{},
            }
        }
        _ = try self.execPipeline(pl);
        return &.{};
    }

    fn execCommand(self: *Shell, cmd: *const ast.Command, base: [3]os.Fd) anyerror!Flow {
        switch (try self.startCommand(cmd, base)) {
            .done => |status| {
                self.last_status = status;
                return .normal;
            },
            .control => |flow| return flow,
            .pid => |started| {
                self.enterForeground(&.{started.pid});
                const outcome = self.waitOne(started.pid);
                self.leaveForeground();
                try self.applyEnvRestore(started.restore);
                switch (outcome) {
                    .exited => |status| self.last_status = status,
                    .stopped => {
                        if (self.commandLabel(cmd)) |label| {
                            defer self.allocator.free(label);
                            _ = self.recordStopped(&.{started.pid}, label) catch {};
                        } else |_| {
                            _ = self.recordStopped(&.{started.pid}, "job") catch {};
                        }
                        self.last_status = 128 + @intFromEnum(os.Signal.tstp);
                    },
                }
                return .normal;
            },
        }
    }

    fn startCommand(self: *Shell, cmd: *const ast.Command, base: [3]os.Fd) anyerror!Started {
        return switch (cmd.*) {
            .function_def => |f| blk: {
                const body = try ast.cloneCommand(self.allocator, f.body);
                try self.putFunction(f.name, body);
                break :blk .{ .done = 0 };
            },
            .compound => |compound| blk: {
                const triple = self.resolveRedirs(compound.redirs, base) catch |err| {
                    const msg = try redirMessage(self.allocator, err);
                    defer self.allocator.free(msg);
                    self.eprintln(msg);
                    break :blk .{ .done = 1 };
                };
                const saved = self.cur_fds;
                self.cur_fds = triple.fds;
                defer {
                    self.cur_fds = saved;
                    self.closeOwned(triple.owned);
                }
                const flow = try self.execCompound(&compound.kind);
                break :blk switch (flow) {
                    .normal => .{ .done = self.last_status },
                    else => .{ .control = flow },
                };
            },
            .simple => |sc| self.startSimple(&sc, base),
        };
    }

    fn startSimple(self: *Shell, sc: *const ast.SimpleCommand, base: [3]os.Fd) anyerror!Started {
        const expanded = self.expandSimple(sc) catch return .{ .done = 1 };
        defer self.freeExpandedSimple(expanded);
        return self.dispatchSimple(expanded.argv, expanded.assigns, sc.redirs, base);
    }

    const ExpandedSimple = struct {
        argv: []const []const u8,
        assigns: []const AssignValue,
    };

    fn freeExpandedSimple(self: *Shell, expanded: ExpandedSimple) void {
        self.freeStringList(expanded.argv);
        for (expanded.assigns) |assignment| self.allocator.free(assignment.value);
        if (expanded.assigns.len != 0) self.allocator.free(expanded.assigns);
    }

    fn freePlan(self: *Shell, plan: Plan) void {
        switch (plan) {
            .simple => |simple| self.freeExpandedSimple(.{ .argv = simple.argv, .assigns = simple.assigns }),
            else => {},
        }
    }

    fn expandSimple(self: *Shell, sc: *const ast.SimpleCommand) !ExpandedSimple {
        var ctx = self.expandContext();
        var argv = std.ArrayList([]const u8).empty;
        errdefer {
            for (argv.items) |arg| self.allocator.free(arg);
            argv.deinit(self.allocator);
        }
        for (sc.words) |w| {
            const fields = expand.expandToFields(self.allocator, w, &ctx) catch {
                self.eprintln("sh: expansion failed");
                return error.Expansion;
            };
            argv.appendSlice(self.allocator, fields) catch |err| {
                self.freeStringList(fields);
                return err;
            };
            if (fields.len != 0) self.allocator.free(fields);
        }

        var assigns = std.ArrayList(AssignValue).empty;
        errdefer {
            for (assigns.items) |assignment| self.allocator.free(assignment.value);
            assigns.deinit(self.allocator);
        }
        for (sc.assigns) |assignment| {
            const value = expand.expandToString(self.allocator, assignment.value, &ctx) catch {
                self.eprintln("sh: expansion failed");
                return error.Expansion;
            };
            assigns.append(self.allocator, .{ .name = assignment.name, .value = value }) catch |err| {
                self.allocator.free(value);
                return err;
            };
        }
        return .{ .argv = try argv.toOwnedSlice(self.allocator), .assigns = try assigns.toOwnedSlice(self.allocator) };
    }

    fn expandedRunsInline(self: *Shell, argv: []const []const u8) bool {
        if (argv.len == 0) return true;
        return builtins.lookup(argv[0]) != null or self.funcs.contains(argv[0]);
    }

    fn dispatchSimple(self: *Shell, argv: []const []const u8, assigns: []const AssignValue, redirs: []const ast.Redirect, base: [3]os.Fd) anyerror!Started {
        if (argv.len == 0) {
            for (assigns) |assignment| try self.setVarRaw(assignment.name, assignment.value);
            const triple = self.resolveRedirs(redirs, base) catch |err| {
                const msg = try redirMessage(self.allocator, err);
                defer self.allocator.free(msg);
                self.eprintln(msg);
                return .{ .done = 1 };
            };
            self.closeOwned(triple.owned);
            return .{ .done = 0 };
        }

        const name = argv[0];
        const triple = self.resolveRedirs(redirs, base) catch |err| {
            const msg = try redirMessage(self.allocator, err);
            defer self.allocator.free(msg);
            self.eprintln(msg);
            return .{ .done = 1 };
        };

        if (self.funcs.get(name)) |body| {
            const env_restore = self.applyTempAssigns(assigns) catch |err| {
                self.closeOwned(triple.owned);
                return err;
            };
            const saved = self.cur_fds;
            self.cur_fds = triple.fds;
            defer {
                self.cur_fds = saved;
                self.closeOwned(triple.owned);
            }
            const flow = try self.callFunction(body, argv);
            try self.applyEnvRestore(env_restore);
            return switch (flow) {
                .return_status => |code| blk: {
                    self.last_status = code;
                    break :blk .{ .done = code };
                },
                .normal => .{ .done = self.last_status },
                else => .{ .control = flow },
            };
        }

        if (builtins.lookup(name)) |_| {
            const env_restore = self.applyTempAssigns(assigns) catch |err| {
                self.closeOwned(triple.owned);
                return err;
            };
            const saved = self.cur_fds;
            self.cur_fds = triple.fds;
            defer {
                self.cur_fds = saved;
                self.closeOwned(triple.owned);
            }
            const result = try self.dispatchBuiltin(name, argv[1..]);
            try self.applyEnvRestore(env_restore);
            return if (result.flow) |flow| .{ .control = flow } else .{ .done = result.status };
        }

        const env_restore = self.applyTempAssigns(assigns) catch |err| {
            self.closeOwned(triple.owned);
            return err;
        };
        const path = self.resolvePath(name) catch null orelse {
            const msg = try std.fmt.allocPrint(self.allocator, "sh: {s}: command not found", .{name});
            defer self.allocator.free(msg);
            self.eprintln(msg);
            self.closeOwned(triple.owned);
            try self.applyEnvRestore(env_restore);
            return .{ .done = 127 };
        };
        defer self.allocator.free(path);
        var spawn_argv = try self.allocator.alloc([]const u8, argv.len);
        defer self.allocator.free(spawn_argv);
        @memcpy(spawn_argv, argv);
        spawn_argv[0] = path;

        const capture_idx = self.captureIndex(triple.fds[1]) orelse self.captureIndex(triple.fds[2]);
        if (capture_idx) |idx| {
            const tmp = try self.tmpPath("cap");
            defer self.allocator.free(tmp);
            const status = if (self.os.open(tmp, os.O_WRITE | os.O_CREATE | os.O_TRUNC)) |wfd| blk: {
                const out_fd = if (self.captureIndex(triple.fds[1]) != null) wfd else triple.fds[1];
                const err_fd = if (self.captureIndex(triple.fds[2]) != null) wfd else triple.fds[2];
                const pid = self.os.spawn(spawn_argv, triple.fds[0], out_fd, err_fd, os.TIER_INHERIT) catch |err| {
                    self.os.close(wfd);
                    self.closeOwned(triple.owned);
                    const msg = try std.fmt.allocPrint(self.allocator, "sh: {s}: {s}", .{ name, shellErrorText(err) });
                    defer self.allocator.free(msg);
                    self.eprintln(msg);
                    break :blk 126;
                };
                self.os.close(wfd);
                self.closeOwned(triple.owned);
                break :blk self.os.waitpid(pid) catch 1;
            } else |_| blk: {
                self.closeOwned(triple.owned);
                break :blk 1;
            };
            self.drainCaptureFile(tmp, idx);
            try self.applyEnvRestore(env_restore);
            return .{ .done = status };
        }

        const pid = self.os.spawn(spawn_argv, triple.fds[0], triple.fds[1], triple.fds[2], os.TIER_INHERIT);
        self.closeOwned(triple.owned);
        return if (pid) |p|
            .{ .pid = .{ .pid = p, .restore = env_restore } }
        else |err| blk: {
            const msg = try std.fmt.allocPrint(self.allocator, "sh: {s}: {s}", .{ name, shellErrorText(err) });
            defer self.allocator.free(msg);
            self.eprintln(msg);
            try self.applyEnvRestore(env_restore);
            break :blk .{ .done = 126 };
        };
    }

    fn runInlineStage(self: *Shell, cmd: *const ast.Command, fds: [3]os.Fd) anyerror!i32 {
        const snap = try self.snapshot();
        self.subshell_depth += 1;
        const status = switch (try self.startCommand(cmd, fds)) {
            .done => |s| s,
            .control => |flow| switch (flow) {
                .exit, .return_status => |code| code,
                else => self.last_status,
            },
            .pid => |p| blk: {
                const st = self.os.waitpid(p.pid) catch 1;
                try self.applyEnvRestore(p.restore);
                break :blk st;
            },
        };
        self.subshell_depth -= 1;
        try self.restore(snap);
        return status;
    }

    fn runInlineSimple(self: *Shell, argv: []const []const u8, assigns: []const AssignValue, redirs: []const ast.Redirect, fds: [3]os.Fd) anyerror!i32 {
        const snap = try self.snapshot();
        self.subshell_depth += 1;
        const status = switch (try self.dispatchSimple(argv, assigns, redirs, fds)) {
            .done => |s| s,
            .control => |flow| switch (flow) {
                .exit, .return_status => |code| code,
                else => self.last_status,
            },
            .pid => |p| blk: {
                const st = self.os.waitpid(p.pid) catch 1;
                try self.applyEnvRestore(p.restore);
                break :blk st;
            },
        };
        self.subshell_depth -= 1;
        try self.restore(snap);
        return status;
    }

    fn execCompound(self: *Shell, compound: *const ast.Compound) anyerror!Flow {
        return switch (compound.*) {
            .brace_group => |list| self.execList(&list),
            .subshell => |list| self.execSubshell(&list),
            .if_clause => |if_clause| self.execIf(&if_clause),
            .for_clause => |for_clause| self.execFor(&for_clause),
            .while_clause => |while_clause| self.execWhile(&while_clause.cond, &while_clause.body, false),
            .until_clause => |until_clause| self.execWhile(&until_clause.cond, &until_clause.body, true),
            .case_clause => |case_clause| self.execCase(&case_clause),
        };
    }

    fn execIf(self: *Shell, if_clause: *const ast.IfClause) anyerror!Flow {
        for (if_clause.arms) |arm| {
            const flow = try self.execListCond(&arm.condition);
            if (!flowIsNormal(flow)) return flow;
            if (self.last_status == 0) return self.execList(&arm.body);
        }
        if (if_clause.else_body) |body| return self.execList(&body);
        self.last_status = 0;
        return .normal;
    }

    fn execFor(self: *Shell, for_clause: *const ast.ForClause) anyerror!Flow {
        var items = std.ArrayList([]const u8).empty;
        var owns_items = false;
        defer {
            if (owns_items) {
                for (items.items) |item| self.allocator.free(item);
            }
            items.deinit(self.allocator);
        }
        if (for_clause.words) |words| {
            owns_items = true;
            var ctx = self.expandContext();
            for (words) |w| {
                const fields = try expand.expandToFields(self.allocator, w, &ctx);
                items.appendSlice(self.allocator, fields) catch |err| {
                    self.freeStringList(fields);
                    return err;
                };
                if (fields.len != 0) self.allocator.free(fields);
            }
        } else {
            try items.appendSlice(self.allocator, self.positional);
        }
        for (items.items) |item| {
            try self.setVarRaw(for_clause.var_name, item);
            const flow = try self.execList(&for_clause.body);
            switch (flow) {
                .break_loop => |n| if (n == 1) break else return .{ .break_loop = n - 1 },
                .continue_loop => |n| if (n == 1) continue else return .{ .continue_loop = n - 1 },
                .normal => {},
                else => return flow,
            }
        }
        return .normal;
    }

    fn execWhile(self: *Shell, cond: *const ast.List, body: *const ast.List, until: bool) anyerror!Flow {
        var ran_body = false;
        var last_body_status: i32 = 0;
        while (true) {
            const flow = try self.execListCond(cond);
            if (!flowIsNormal(flow)) return flow;
            const go = if (until) self.last_status != 0 else self.last_status == 0;
            if (!go) break;
            ran_body = true;
            const body_flow = try self.execList(body);
            switch (body_flow) {
                .break_loop => |n| {
                    last_body_status = self.last_status;
                    if (n == 1) break else return .{ .break_loop = n - 1 };
                },
                .continue_loop => |n| {
                    last_body_status = self.last_status;
                    if (n == 1) continue else return .{ .continue_loop = n - 1 };
                },
                .normal => last_body_status = self.last_status,
                else => return body_flow,
            }
        }
        self.last_status = if (ran_body) last_body_status else 0;
        return .normal;
    }

    fn execCase(self: *Shell, case_clause: *const ast.CaseClause) anyerror!Flow {
        var ctx = self.expandContext();
        const subject = expand.expandToString(self.allocator, case_clause.subject, &ctx) catch {
            self.eprintln("sh: expansion failed");
            self.last_status = 1;
            return .normal;
        };
        defer self.allocator.free(subject);
        for (case_clause.items) |item| {
            for (item.patterns) |pat| {
                const p = expand.expandToString(self.allocator, pat, &ctx) catch {
                    self.eprintln("sh: expansion failed");
                    self.last_status = 1;
                    return .normal;
                };
                defer self.allocator.free(p);
                if (glob.globFull(p, subject)) return self.execList(&item.body);
            }
        }
        self.last_status = 0;
        return .normal;
    }

    fn execListCond(self: *Shell, list: *const ast.List) anyerror!Flow {
        const saved = self.opts.errexit;
        self.opts.errexit = false;
        const flow = try self.execList(list);
        self.opts.errexit = saved;
        return flow;
    }

    fn execSubshell(self: *Shell, list: *const ast.List) anyerror!Flow {
        const snap = try self.snapshot();
        self.subshell_depth += 1;
        const flow = try self.execList(list);
        self.subshell_depth -= 1;
        const status = self.last_status;
        try self.restore(snap);
        self.last_status = status;
        return switch (flow) {
            .exit => .normal,
            else => flow,
        };
    }

    fn commandSubstRun(self: *Shell, allocator: std.mem.Allocator, raw: []const u8) []const u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const script = parser.parse(arena.allocator(), raw) catch return "";
        const idx = self.captures.items.len;
        self.captures.append(self.allocator, .empty) catch return "";
        const cap = captureFd(idx);
        const snap = self.snapshot() catch {
            if (self.captures.pop()) |cap_value| {
                var cap_buf = cap_value;
                cap_buf.deinit(self.allocator);
            }
            return "";
        };
        const saved = self.cur_fds;
        self.cur_fds = .{ saved[0], cap, saved[2] };
        self.subshell_depth += 1;
        _ = self.execList(&script.list) catch {};
        self.subshell_depth -= 1;
        self.cur_fds = saved;
        self.restore(snap) catch {};
        var cap_buf = self.captures.pop() orelse return "";
        defer cap_buf.deinit(self.allocator);
        var cleaned = std.ArrayList(u8).empty;
        defer cleaned.deinit(self.allocator);
        for (cap_buf.items) |b| {
            if (b != '\r') cleaned.append(self.allocator, b) catch {};
        }
        var end = cleaned.items.len;
        while (end > 0 and cleaned.items[end - 1] == '\n') end -= 1;
        return allocator.dupe(u8, cleaned.items[0..end]) catch "";
    }

    fn callFunction(self: *Shell, body: *const ast.Command, argv: []const []const u8) anyerror!Flow {
        if (self.frames.items.len > 128) {
            self.eprintln("sh: function recursion too deep");
            self.last_status = 1;
            return .normal;
        }
        const saved_positional = try self.cloneStringList(self.positional);
        errdefer self.freeStringList(saved_positional);
        const saved_arg0 = try self.allocator.dupe(u8, self.arg0);
        errdefer self.allocator.free(saved_arg0);
        try self.frames.append(self.allocator, .{
            .saved_positional = saved_positional,
            .saved_positional_owned = true,
            .saved_arg0 = saved_arg0,
            .saved_arg0_owned = true,
        });
        if (self.positional_owned) self.freeStringList(self.positional);
        self.positional = argv[1..];
        self.positional_owned = false;
        var frame_restored = false;
        errdefer {
            if (!frame_restored) self.popFunctionFrame() catch {};
        }
        const flow = switch (try self.startCommand(body, self.cur_fds)) {
            .done => |status| blk: {
                self.last_status = status;
                break :blk .normal;
            },
            .control => |f| f,
            .pid => |p| blk: {
                const st = self.os.waitpid(p.pid) catch 1;
                try self.applyEnvRestore(p.restore);
                self.last_status = st;
                break :blk .normal;
            },
        };
        try self.popFunctionFrame();
        frame_restored = true;
        return switch (flow) {
            .return_status => |code| blk: {
                self.last_status = code;
                break :blk .normal;
            },
            else => flow,
        };
    }

    fn popFunctionFrame(self: *Shell) !void {
        if (self.frames.pop()) |frame_value| {
            var frame = frame_value;
            var idx = frame.locals.items.len;
            while (idx > 0) {
                idx -= 1;
                const local = frame.locals.items[idx];
                if (local.prev) |prev| {
                    try self.putVarCopy(local.name, prev.value, prev.exported);
                } else {
                    self.removeVarOnly(local.name, false);
                }
                self.freeLocalRestore(local);
            }
            frame.locals.deinit(self.allocator);
            if (self.positional_owned) self.freeStringList(self.positional);
            if (self.arg0_owned) self.allocator.free(self.arg0);
            self.positional = frame.saved_positional;
            self.positional_owned = frame.saved_positional_owned;
            self.arg0 = frame.saved_arg0;
            self.arg0_owned = frame.saved_arg0_owned;
        }
    }

    fn resolveRedirs(self: *Shell, redirs: []const ast.Redirect, base: [3]os.Fd) !Triple {
        var fds = base;
        var owned = std.ArrayList(os.Fd).empty;
        errdefer {
            for (owned.items) |fd| self.os.close(fd);
            owned.deinit(self.allocator);
        }
        for (redirs) |r| {
            const slot: usize = @intCast(r.io_number orelse defaultIo(r.op));
            if (slot > 2) return error.UnsupportedFd;
            switch (r.op) {
                .read => {
                    const path = try self.expandRedirectWord(&r);
                    defer self.allocator.free(path);
                    const fd = try self.os.open(path, os.O_READ);
                    fds[slot] = fd;
                    try owned.append(self.allocator, fd);
                },
                .write, .clobber => {
                    const path = try self.expandRedirectWord(&r);
                    defer self.allocator.free(path);
                    const fd = try self.os.open(path, os.O_WRITE | os.O_CREATE | os.O_TRUNC);
                    fds[slot] = fd;
                    try owned.append(self.allocator, fd);
                },
                .append => {
                    const path = try self.expandRedirectWord(&r);
                    defer self.allocator.free(path);
                    const fd = try self.os.open(path, os.O_WRITE | os.O_CREATE | os.O_APPEND);
                    fds[slot] = fd;
                    try owned.append(self.allocator, fd);
                },
                .read_write => {
                    const path = try self.expandRedirectWord(&r);
                    defer self.allocator.free(path);
                    const fd = try self.os.open(path, os.O_READ | os.O_WRITE | os.O_CREATE);
                    fds[slot] = fd;
                    try owned.append(self.allocator, fd);
                },
                .dup_in, .dup_out => switch (r.target) {
                    .dup => |dup| switch (dup) {
                        .number => |n| fds[slot] = if (n <= 2) fds[@intCast(n)] else -1,
                        .close => fds[slot] = -1,
                    },
                    else => return error.BadDup,
                },
                .heredoc => switch (r.target) {
                    .here => |here| {
                        const text = if (here.expand) try self.expandHeredoc(here.body) else try self.allocator.dupe(u8, here.body);
                        defer self.allocator.free(text);
                        const path = try self.tmpPath("hd");
                        defer self.allocator.free(path);
                        const wfd = try self.os.open(path, os.O_WRITE | os.O_CREATE | os.O_TRUNC);
                        self.os.writeAll(wfd, text) catch {};
                        self.os.close(wfd);
                        const rfd = try self.os.open(path, os.O_READ);
                        _ = self.os.unlink(path) catch {};
                        fds[slot] = rfd;
                        try owned.append(self.allocator, rfd);
                    },
                    else => return error.MalformedHeredoc,
                },
            }
        }
        return .{ .fds = fds, .owned = try owned.toOwnedSlice(self.allocator) };
    }

    fn expandRedirectWord(self: *Shell, r: *const ast.Redirect) ![]const u8 {
        const w = switch (r.target) {
            .word_value => |target| target,
            else => return error.ExpectedFilename,
        };
        var ctx = self.expandContext();
        return expand.expandRedirectTarget(self.allocator, w, &ctx);
    }

    fn expandHeredoc(self: *Shell, body: []const u8) ![]const u8 {
        const escaped = try escapeForDquote(self.allocator, body);
        defer self.allocator.free(escaped);
        const quoted = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
        defer self.allocator.free(quoted);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const toks = token.tokenize(arena.allocator(), quoted) catch return self.allocator.dupe(u8, body);
        if (toks.len != 0 and toks[0] == .word) {
            var ctx = self.expandContext();
            return expand.expandToString(self.allocator, toks[0].word, &ctx) catch self.allocator.dupe(u8, body);
        }
        return self.allocator.dupe(u8, body);
    }

    fn closeOwned(self: *Shell, owned: []const os.Fd) void {
        for (owned) |fd| self.os.close(fd);
        if (owned.len != 0) self.allocator.free(owned);
    }

    fn applyTempAssigns(self: *Shell, assigns: []const AssignValue) ![]const EnvRestore {
        var restores = std.ArrayList(EnvRestore).empty;
        errdefer {
            for (restores.items) |entry_restore| {
                self.allocator.free(entry_restore.name);
                if (entry_restore.prev) |prev| self.allocator.free(prev.value);
            }
            restores.deinit(self.allocator);
        }
        for (assigns) |assignment| {
            const prev = if (self.vars.get(assignment.name)) |value| try self.cloneVar(value) else null;
            const name = try self.allocator.dupe(u8, assignment.name);
            restores.append(self.allocator, .{
                .name = name,
                .prev = prev,
            }) catch |err| {
                self.allocator.free(name);
                if (prev) |p| self.allocator.free(p.value);
                return err;
            };
            try self.putVarCopy(assignment.name, assignment.value, true);
            self.os.setenv(assignment.name, assignment.value) catch {};
        }
        return restores.toOwnedSlice(self.allocator);
    }

    fn applyEnvRestore(self: *Shell, restores: []const EnvRestore) !void {
        defer self.freeEnvRestores(restores);
        var idx = restores.len;
        while (idx > 0) {
            idx -= 1;
            const r = restores[idx];
            if (r.prev) |prev| {
                try self.putVarCopy(r.name, prev.value, prev.exported);
                if (prev.exported) self.os.setenv(r.name, prev.value) catch {} else self.os.unsetenv(r.name) catch {};
            } else {
                self.removeVarOnly(r.name, false);
                self.os.unsetenv(r.name) catch {};
            }
        }
    }

    fn resolvePath(self: *Shell, name: []const u8) !?[]const u8 {
        if (std.mem.indexOfScalar(u8, name, '/') != null) return try self.allocator.dupe(u8, name);
        const path = self.getVar("PATH") orelse "/bin:/usr/bin";
        var it = std.mem.splitScalar(u8, path, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const full = if (dir[dir.len - 1] == '/')
                try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ dir, name })
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, name });
            if (self.os.stat(full)) |st| {
                if (!st.is_dir) return full;
            } else |_| {}
            self.allocator.free(full);
        }
        return null;
    }

    fn snapshot(self: *Shell) !Snapshot {
        var vars = try self.cloneVars();
        errdefer self.freeVarMap(&vars);
        const positional = try self.cloneStringList(self.positional);
        errdefer self.freeStringList(positional);
        const arg0 = try self.allocator.dupe(u8, self.arg0);
        errdefer self.allocator.free(arg0);
        const cwd = self.os.getcwd(self.allocator) catch try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(cwd);
        var exported = try self.exportedMap();
        errdefer self.freeStringMap(&exported);
        return .{
            .vars = vars,
            .positional = positional,
            .arg0 = arg0,
            .opts = self.opts,
            .last_status = self.last_status,
            .cwd = cwd,
            .exported = exported,
        };
    }

    fn restore(self: *Shell, snap: Snapshot) !void {
        var owned_snap = snap;
        errdefer self.freeSnapshot(&owned_snap);
        var now = try self.exportedMap();
        defer self.freeStringMap(&now);
        var it_now = now.iterator();
        while (it_now.next()) |entry| {
            if (!owned_snap.exported.contains(entry.key_ptr.*)) self.os.unsetenv(entry.key_ptr.*) catch {};
        }
        var it_snap = owned_snap.exported.iterator();
        while (it_snap.next()) |entry| {
            const cur = now.get(entry.key_ptr.*);
            if (cur == null or !std.mem.eql(u8, cur.?, entry.value_ptr.*)) {
                self.os.setenv(entry.key_ptr.*, entry.value_ptr.*) catch {};
            }
        }
        self.freeVarMap(&self.vars);
        if (self.positional_owned) self.freeStringList(self.positional);
        if (self.arg0_owned) self.allocator.free(self.arg0);
        self.vars = owned_snap.vars;
        self.positional = owned_snap.positional;
        self.positional_owned = true;
        self.arg0 = owned_snap.arg0;
        self.arg0_owned = true;
        self.opts = owned_snap.opts;
        self.last_status = owned_snap.last_status;
        self.os.chdir(owned_snap.cwd) catch {};
        self.allocator.free(owned_snap.cwd);
        self.freeStringMap(&owned_snap.exported);
    }

    fn cloneVars(self: *Shell) !std.StringHashMap(VarVal) {
        var out = std.StringHashMap(VarVal).init(self.allocator);
        errdefer self.freeVarMap(&out);
        var it = self.vars.iterator();
        while (it.next()) |entry| {
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            const value = try self.cloneVar(entry.value_ptr.*);
            out.put(key, value) catch |err| {
                self.allocator.free(key);
                self.allocator.free(value.value);
                return err;
            };
        }
        return out;
    }

    fn exportedMap(self: *Shell) !std.StringHashMap([]const u8) {
        var out = std.StringHashMap([]const u8).init(self.allocator);
        errdefer self.freeStringMap(&out);
        var it = self.vars.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.exported) {
                const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                const value = try self.allocator.dupe(u8, entry.value_ptr.value);
                out.put(key, value) catch |err| {
                    self.allocator.free(key);
                    self.allocator.free(value);
                    return err;
                };
            }
        }
        return out;
    }

    fn freeStringMap(self: *Shell, map: *std.StringHashMap([]const u8)) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        map.deinit();
    }

    fn freeSnapshot(self: *Shell, snap: *Snapshot) void {
        self.freeVarMap(&snap.vars);
        self.freeStringList(snap.positional);
        self.allocator.free(snap.arg0);
        self.allocator.free(snap.cwd);
        self.freeStringMap(&snap.exported);
    }

    const BuiltinResult = struct {
        status: i32,
        flow: ?Flow = null,
    };

    fn dispatchBuiltin(self: *Shell, name: []const u8, args: []const []const u8) !BuiltinResult {
        if (args.len != 0 and (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h"))) {
            if (builtinHelp(name)) |help| {
                self.writeFd(self.cur_fds[1], help);
                return .{ .status = 0 };
            }
        }
        return switch (builtins.lookup(name).?) {
            .colon, .true_cmd => .{ .status = 0 },
            .false_cmd => .{ .status = 1 },
            .echo => .{ .status = try self.biEcho(args) },
            .pwd => .{ .status = try self.biPwd() },
            .printf => .{ .status = try self.biPrintf(args) },
            .cd => .{ .status = try self.biCd(args) },
            .@"export" => .{ .status = try self.biExport(args) },
            .unset => .{ .status = self.biUnset(args) },
            .shift => .{ .status = try self.biShift(args) },
            .set => .{ .status = try self.biSet(args) },
            .read => .{ .status = try self.biRead(args) },
            .@"test" => .{ .status = self.biTest(name, args) },
            .umount => .{ .status = self.biUmount(args) },
            .bind => .{ .status = self.biBind(args) },
            .exit => blk: {
                const code = if (args.len != 0) std.fmt.parseInt(i32, args[0], 10) catch self.last_status else self.last_status;
                break :blk .{ .status = code, .flow = .{ .exit = code } };
            },
            .@"return" => blk: {
                const code = if (args.len != 0) std.fmt.parseInt(i32, args[0], 10) catch self.last_status else self.last_status;
                break :blk .{ .status = code, .flow = .{ .return_status = code } };
            },
            .break_cmd => .{ .status = 0, .flow = .{ .break_loop = loopCount(args) } },
            .continue_cmd => .{ .status = 0, .flow = .{ .continue_loop = loopCount(args) } },
            .source => .{ .status = try self.biSource(args) },
            .eval => .{ .status = try self.biEval(args) },
            .local => .{ .status = try self.biLocal(args) },
            .command => .{ .status = try self.biCommand(args) },
            .jobs => .{ .status = self.biJobs() },
            .fg => .{ .status = self.biFg(args) },
            .bg => .{ .status = self.biBg(args) },
            .wait => .{ .status = self.biWait(args) },
            .kill => .{ .status = self.biKill(args) },
        };
    }

    fn biEcho(self: *Shell, args: []const []const u8) !i32 {
        const bytes = try echo.render(self.allocator, args);
        defer self.allocator.free(bytes);
        self.writeFd(self.cur_fds[1], bytes);
        return 0;
    }

    fn biPwd(self: *Shell) !i32 {
        const cwd_owned = self.os.getcwd(self.allocator) catch null;
        defer {
            if (cwd_owned) |cwd| self.allocator.free(cwd);
        }
        const cwd = cwd_owned orelse "/";
        self.writeFd(self.cur_fds[1], cwd);
        self.writeFd(self.cur_fds[1], "\n");
        return 0;
    }

    fn biPrintf(self: *Shell, args: []const []const u8) !i32 {
        if (args.len == 0) {
            self.eprintln("printf: usage: printf FORMAT [ARG...]");
            return 1;
        }
        const rendered = try printf.render(self.allocator, args[0], args[1..]);
        defer self.allocator.free(rendered.bytes);
        self.writeFd(self.cur_fds[1], rendered.bytes);
        return if (rendered.had_error) 1 else 0;
    }

    fn biCd(self: *Shell, args: []const []const u8) !i32 {
        const prev_owned = self.os.getcwd(self.allocator) catch null;
        defer {
            if (prev_owned) |prev| self.allocator.free(prev);
        }
        const prev = prev_owned orelse "";
        var print_dir = false;
        const target = if (args.len != 0 and std.mem.eql(u8, args[0], "-")) blk: {
            print_dir = true;
            break :blk self.getVar("OLDPWD") orelse {
                self.eprintln("cd: OLDPWD not set");
                return 1;
            };
        } else if (args.len != 0) args[0] else self.getVar("HOME") orelse "/";
        self.os.chdir(target) catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "cd: {s}: {s}", .{ target, shellErrorText(err) });
            defer self.allocator.free(msg);
            self.eprintln(msg);
            return 1;
        };
        try self.setVarRaw("OLDPWD", prev);
        const cwd_owned = self.os.getcwd(self.allocator) catch null;
        defer {
            if (cwd_owned) |cwd| self.allocator.free(cwd);
        }
        const cwd = cwd_owned orelse target;
        try self.setVarRaw("PWD", cwd);
        if (print_dir) {
            self.writeFd(self.cur_fds[1], cwd);
            self.writeFd(self.cur_fds[1], "\n");
        }
        return 0;
    }

    fn biExport(self: *Shell, args: []const []const u8) !i32 {
        if (args.len == 0) {
            var it = self.vars.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.exported) {
                    const line = try std.fmt.allocPrint(self.allocator, "export {s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.value });
                    defer self.allocator.free(line);
                    self.writeFd(self.cur_fds[1], line);
                }
            }
            return 0;
        }
        for (args) |arg| {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                try self.exportVar(arg[0..eq], arg[eq + 1 ..]);
            } else {
                try self.exportVar(arg, null);
            }
        }
        return 0;
    }

    fn biUnset(self: *Shell, args: []const []const u8) i32 {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "-v")) continue;
            self.unsetVar(arg);
        }
        return 0;
    }

    fn biShift(self: *Shell, args: []const []const u8) !i32 {
        const n = if (args.len != 0) std.fmt.parseInt(usize, args[0], 10) catch 1 else 1;
        if (n > self.positional.len) return 1;
        try self.setPositional(self.positional[n..]);
        return 0;
    }

    fn biSet(self: *Shell, args: []const []const u8) !i32 {
        var i: usize = 0;
        var saw_dashdash = false;
        while (i < args.len) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--")) {
                saw_dashdash = true;
                i += 1;
                break;
            }
            if (a.len > 1 and a[0] == '-') {
                if (std.mem.eql(u8, a, "-o") and i + 1 < args.len) {
                    self.setNamedOption(args[i + 1], true);
                    i += 2;
                    continue;
                }
                for (a[1..]) |ch| self.setShortOption(ch, true);
                i += 1;
                continue;
            }
            if (a.len > 1 and a[0] == '+') {
                if (std.mem.eql(u8, a, "+o") and i + 1 < args.len) {
                    self.setNamedOption(args[i + 1], false);
                    i += 2;
                    continue;
                }
                for (a[1..]) |ch| self.setShortOption(ch, false);
                i += 1;
                continue;
            }
            break;
        }
        if (saw_dashdash or i < args.len) try self.setPositional(args[i..]);
        return 0;
    }

    fn setShortOption(self: *Shell, ch: u8, on: bool) void {
        switch (ch) {
            'e' => self.opts.errexit = on,
            'u' => self.opts.nounset = on,
            'x' => self.opts.xtrace = on,
            else => {},
        }
    }

    fn setNamedOption(self: *Shell, name: []const u8, on: bool) void {
        if (std.mem.eql(u8, name, "errexit")) self.opts.errexit = on;
        if (std.mem.eql(u8, name, "nounset")) self.opts.nounset = on;
        if (std.mem.eql(u8, name, "xtrace")) self.opts.xtrace = on;
        if (std.mem.eql(u8, name, "pipefail")) self.opts.pipefail = on;
    }

    fn biRead(self: *Shell, args: []const []const u8) !i32 {
        var line = std.ArrayList(u8).empty;
        defer line.deinit(self.allocator);
        var byte: [1]u8 = undefined;
        while (true) {
            const n = self.os.read(self.cur_fds[0], &byte) catch return 1;
            if (n == 0) {
                if (line.items.len == 0) return 1;
                break;
            }
            if (byte[0] == '\n') break;
            if (byte[0] != '\r') try line.append(self.allocator, byte[0]);
        }
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(self.allocator);
        for (args) |arg| if (arg.len == 0 or arg[0] != '-') try names.append(self.allocator, arg);
        if (names.items.len == 0) {
            try self.setVarRaw("REPLY", line.items);
            return 0;
        }
        const ifs = self.getVar("IFS") orelse " \t\n";
        var fields = std.ArrayList([]const u8).empty;
        defer fields.deinit(self.allocator);
        var it = std.mem.tokenizeAny(u8, line.items, ifs);
        while (it.next()) |field| try fields.append(self.allocator, field);
        for (names.items, 0..) |name, idx| {
            if (idx + 1 == names.items.len) {
                var rest = std.ArrayList(u8).empty;
                defer rest.deinit(self.allocator);
                for (fields.items[idx..], 0..) |field, j| {
                    if (j != 0) try rest.append(self.allocator, ' ');
                    try rest.appendSlice(self.allocator, field);
                }
                try self.setVarRaw(name, rest.items);
            } else {
                try self.setVarRaw(name, if (idx < fields.items.len) fields.items[idx] else "");
            }
        }
        return 0;
    }

    fn biTest(self: *Shell, name: []const u8, args: []const []const u8) i32 {
        const result = testexpr.eval(name, args, @ptrCast(self), statAdapter);
        return switch (result) {
            .ok => |v| if (v) 0 else 1,
            .err => 2,
        };
    }

    fn biSource(self: *Shell, args: []const []const u8) !i32 {
        if (args.len == 0) {
            self.eprintln("source: filename argument required");
            return 1;
        }
        const resolved = self.resolvePath(args[0]) catch null;
        defer {
            if (resolved) |full| self.allocator.free(full);
        }
        const full = resolved orelse args[0];
        const fd = self.os.open(full, os.O_READ) catch {
            const msg = try std.fmt.allocPrint(self.allocator, "source: {s}: cannot open", .{args[0]});
            defer self.allocator.free(msg);
            self.eprintln(msg);
            return 1;
        };
        defer self.os.close(fd);
        var content = std.ArrayList(u8).empty;
        defer content.deinit(self.allocator);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = self.os.read(fd, &buf) catch break;
            if (n == 0) break;
            try content.appendSlice(self.allocator, buf[0..n]);
        }
        const flow = try self.run(content.items);
        return switch (flow) {
            .normal => self.last_status,
            .exit => |code| code,
            .return_status => |code| code,
            else => self.last_status,
        };
    }

    fn biEval(self: *Shell, args: []const []const u8) !i32 {
        const joined = try joinArgs(self.allocator, args, " ");
        defer self.allocator.free(joined);
        const flow = try self.run(joined);
        return switch (flow) {
            .normal => self.last_status,
            .exit => |code| code,
            else => self.last_status,
        };
    }

    fn biLocal(self: *Shell, args: []const []const u8) !i32 {
        if (self.frames.items.len == 0) {
            self.eprintln("local: can only be used in a function");
            return 1;
        }
        var frame = &self.frames.items[self.frames.items.len - 1];
        for (args) |arg| {
            const eq = std.mem.indexOfScalar(u8, arg, '=');
            const name = if (eq) |i| arg[0..i] else arg;
            const prev = if (self.vars.get(name)) |value| try self.cloneVar(value) else null;
            const owned_name = try self.allocator.dupe(u8, name);
            frame.locals.append(self.allocator, .{
                .name = owned_name,
                .prev = prev,
            }) catch |err| {
                self.allocator.free(owned_name);
                if (prev) |p| self.allocator.free(p.value);
                return err;
            };
            try self.setVarRaw(name, if (eq) |i| arg[i + 1 ..] else "");
        }
        return 0;
    }

    fn biCommand(self: *Shell, args: []const []const u8) !i32 {
        if (args.len == 0) return 0;
        const joined = try joinArgs(self.allocator, args, " ");
        defer self.allocator.free(joined);
        const flow = try self.run(joined);
        return switch (flow) {
            .normal => self.last_status,
            .exit => |code| code,
            else => self.last_status,
        };
    }

    fn biUmount(self: *Shell, args: []const []const u8) i32 {
        if (args.len == 0) {
            self.eprintln("umount: missing operand");
            return 1;
        }
        self.os.unmount(args[0]) catch |err| {
            if (std.fmt.allocPrint(self.allocator, "umount: {s}: {s}", .{ args[0], shellErrorText(err) })) |msg| {
                defer self.allocator.free(msg);
                self.eprintln(msg);
            } else |_| self.eprintln("umount failed");
            return 1;
        };
        return 0;
    }

    fn biBind(self: *Shell, args: []const []const u8) i32 {
        if (args.len < 2) {
            self.eprintln("bind: usage: bind OLD NEW");
            return 1;
        }
        self.os.bind(args[0], args[1]) catch |err| {
            if (std.fmt.allocPrint(self.allocator, "bind: {s}: {s}", .{ args[1], shellErrorText(err) })) |msg| {
                defer self.allocator.free(msg);
                self.eprintln(msg);
            } else |_| self.eprintln("bind failed");
            return 1;
        };
        return 0;
    }

    fn jobControl(self: *Shell) bool {
        return self.os.isatty(os.STDIN);
    }

    fn enterForeground(self: *Shell, pids: []const os.Pid) void {
        if (!self.jobControl() or pids.len == 0) return;
        const group = pids[0];
        for (pids) |pid| self.os.setpgid(pid, group) catch {};
        self.os.setForegroundPgid(group) catch {};
    }

    fn leaveForeground(self: *Shell) void {
        if (!self.jobControl()) return;
        self.os.setForegroundPgid(self.shell_pid) catch {};
    }

    fn waitOne(self: *Shell, pid: os.Pid) FgWait {
        const status = self.os.waitpid(pid) catch return .{ .exited = 1 };
        if (status >= os.STOPPED_STATUS) return .stopped;
        return .{ .exited = status };
    }

    fn recordStopped(self: *Shell, pids: []const os.Pid, label: []const u8) !u32 {
        const id = self.next_job;
        self.next_job += 1;
        if (pids.len != 0) self.last_bg = pids[pids.len - 1];
        const owned_pids = try self.allocator.dupe(os.Pid, pids);
        const owned_label = self.allocator.dupe(u8, label) catch |err| {
            self.allocator.free(owned_pids);
            return err;
        };
        self.jobs.append(self.allocator, .{
            .id = id,
            .pids = owned_pids,
            .cmd = owned_label,
            .stopped = true,
        }) catch |err| {
            self.allocator.free(owned_pids);
            self.allocator.free(owned_label);
            return err;
        };
        const msg = try std.fmt.allocPrint(self.allocator, "\n[{d}]+  Stopped  {s}\n", .{ id, label });
        defer self.allocator.free(msg);
        self.writeFd(self.cur_fds[1], msg);
        return id;
    }

    fn reapJobs(self: *Shell) void {
        while (self.os.tryWaitAny() catch null) |status| {
            for (self.jobs.items) |*job| {
                var out = std.ArrayList(os.Pid).empty;
                for (job.pids) |pid| if (pid != status.pid) out.append(self.allocator, pid) catch {};
                const old_pids = job.pids;
                job.pids = out.toOwnedSlice(self.allocator) catch blk: {
                    out.deinit(self.allocator);
                    break :blk &.{};
                };
                if (old_pids.len != 0) self.allocator.free(old_pids);
                if (job.pids.len == 0) job.running = false;
            }
        }
        var i: usize = 0;
        while (i < self.jobs.items.len) {
            if (!self.jobs.items[i].running) {
                var removed = self.jobs.orderedRemove(i);
                self.freeJob(&removed);
            } else i += 1;
        }
    }

    fn biJobs(self: *Shell) i32 {
        self.reapJobs();
        for (self.jobs.items) |job| {
            if (std.fmt.allocPrint(self.allocator, "[{d}]  {s}  {s}\n", .{
                job.id,
                if (job.stopped) "Stopped" else "Running",
                job.cmd,
            })) |msg| {
                defer self.allocator.free(msg);
                self.writeFd(self.cur_fds[1], msg);
            } else |_| {}
        }
        return 0;
    }

    fn jobIndex(self: *Shell, spec: ?[]const u8) ?usize {
        const s = spec orelse return if (self.jobs.items.len == 0) null else self.jobs.items.len - 1;
        if (std.mem.eql(u8, s, "%%") or std.mem.eql(u8, s, "%+") or std.mem.eql(u8, s, "+") or
            std.mem.eql(u8, s, "%-") or std.mem.eql(u8, s, "-"))
        {
            return if (self.jobs.items.len == 0) null else self.jobs.items.len - 1;
        }
        const trimmed = if (s.len != 0 and s[0] == '%') s[1..] else s;
        const id = std.fmt.parseInt(u32, trimmed, 10) catch return null;
        for (self.jobs.items, 0..) |job, idx| if (job.id == id) return idx;
        return null;
    }

    fn biFg(self: *Shell, args: []const []const u8) i32 {
        const idx = self.jobIndex(if (args.len != 0) args[0] else null) orelse {
            self.eprintln("fg: no current job");
            return 1;
        };
        const job = &self.jobs.items[idx];
        if (std.fmt.allocPrint(self.allocator, "{s}\n", .{job.cmd})) |msg| {
            defer self.allocator.free(msg);
            self.writeFd(self.cur_fds[1], msg);
        } else |_| {}
        for (job.pids) |pid| self.os.kill(@intCast(pid), .cont) catch {};
        job.stopped = false;
        self.enterForeground(job.pids);
        var status: i32 = 0;
        var stopped = false;
        for (job.pids) |pid| switch (self.waitOne(pid)) {
            .exited => |st| status = st,
            .stopped => {
                stopped = true;
                break;
            },
        };
        self.leaveForeground();
        if (stopped) {
            job.stopped = true;
            if (std.fmt.allocPrint(self.allocator, "\n[{d}]+  Stopped  {s}\n", .{ job.id, job.cmd })) |msg| {
                defer self.allocator.free(msg);
                self.writeFd(self.cur_fds[1], msg);
            } else |_| {}
            return 128 + @intFromEnum(os.Signal.tstp);
        }
        var removed = self.jobs.orderedRemove(idx);
        self.freeJob(&removed);
        self.reapJobs();
        return status;
    }

    fn biBg(self: *Shell, args: []const []const u8) i32 {
        const idx = self.jobIndex(if (args.len != 0) args[0] else null) orelse {
            self.eprintln("bg: no current job");
            return 1;
        };
        const job = &self.jobs.items[idx];
        for (job.pids) |pid| self.os.kill(@intCast(pid), .cont) catch {};
        job.stopped = false;
        if (std.fmt.allocPrint(self.allocator, "[{d}]+ {s} &\n", .{ job.id, job.cmd })) |msg| {
            defer self.allocator.free(msg);
            self.writeFd(self.cur_fds[1], msg);
        } else |_| {}
        return 0;
    }

    fn biWait(self: *Shell, _: []const []const u8) i32 {
        var status: i32 = 0;
        for (self.jobs.items) |job| {
            for (job.pids) |pid| status = self.os.waitpid(pid) catch status;
        }
        for (self.jobs.items) |*job| self.freeJob(job);
        self.jobs.clearRetainingCapacity();
        return status;
    }

    fn biKill(self: *Shell, args: []const []const u8) i32 {
        var sig: os.Signal = .term;
        var i: usize = 0;
        if (args.len != 0 and args[0].len > 1 and args[0][0] == '-') {
            sig = parseSignal(args[0][1..]) orelse {
                self.eprintln("kill: invalid signal");
                return 1;
            };
            i = 1;
        }
        if (args.len <= i) {
            self.eprintln("kill: usage: kill [-SIG] pid | %job ...");
            return 1;
        }
        var rc: i32 = 0;
        for (args[i..]) |target| {
            if (target.len != 0 and target[0] == '%') {
                if (self.jobIndex(target)) |idx| {
                    const job = self.jobs.items[idx];
                    if (job.pids.len != 0) {
                        self.os.kill(-@as(i32, @intCast(job.pids[0])), sig) catch {
                            rc = 1;
                        };
                    }
                } else rc = 1;
            } else {
                const pid = std.fmt.parseInt(i32, target, 10) catch {
                    rc = 1;
                    continue;
                };
                self.os.kill(pid, sig) catch {
                    rc = 1;
                };
            }
        }
        return rc;
    }

    fn commandLabel(self: *Shell, cmd: *const ast.Command) ![]const u8 {
        if (cmd.* == .simple) {
            var parts = std.ArrayList([]const u8).empty;
            defer {
                for (parts.items) |part| self.allocator.free(part);
                parts.deinit(self.allocator);
            }
            for (cmd.simple.words) |w| {
                var text = std.ArrayList(u8).empty;
                errdefer text.deinit(self.allocator);
                for (w) |part| switch (part) {
                    .lit => |lit| try text.appendSlice(self.allocator, lit.text),
                    else => {},
                };
                if (text.items.len != 0) {
                    const owned = try text.toOwnedSlice(self.allocator);
                    parts.append(self.allocator, owned) catch |err| {
                        self.allocator.free(owned);
                        return err;
                    };
                } else {
                    text.deinit(self.allocator);
                }
            }
            if (parts.items.len != 0) return joinArgs(self.allocator, parts.items, " ");
        }
        const label: []const u8 = switch (cmd.*) {
            .compound => "compound",
            .function_def => "function",
            else => "job",
        };
        return self.allocator.dupe(u8, label);
    }

    fn tmpPath(self: *Shell, tag: []const u8) ![]const u8 {
        self.tmp_seq += 1;
        return std.fmt.allocPrint(self.allocator, "/tmp/.mcsh-{d}-{s}-{d}", .{ self.shell_pid, tag, self.tmp_seq });
    }

    fn expandContext(self: *Shell) expand.ExpandContext {
        return .{ .ptr = @ptrCast(self), .vtable = &expand_vtable };
    }

    fn optsString(self: *Shell, allocator: std.mem.Allocator) ![]const u8 {
        var out = std.ArrayList(u8).empty;
        if (self.opts.errexit) try out.append(allocator, 'e');
        if (self.opts.nounset) try out.append(allocator, 'u');
        if (self.opts.xtrace) try out.append(allocator, 'x');
        return out.toOwnedSlice(allocator);
    }

    fn expandArithOperands(self: *Shell, allocator: std.mem.Allocator, expr: []const u8) ![]const u8 {
        const escaped = try escapeForDquote(allocator, expr);
        const quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
        const toks = token.tokenize(allocator, quoted) catch return expr;
        if (toks.len != 0 and toks[0] == .word) {
            var ctx = self.expandContext();
            return expand.expandToString(allocator, toks[0].word, &ctx) catch expr;
        }
        return expr;
    }
};

fn flowIsNormal(flow: Flow) bool {
    return switch (flow) {
        .normal => true,
        else => false,
    };
}

fn defaultIo(op: ast.RedirOp) u32 {
    return switch (op) {
        .read, .read_write, .dup_in, .heredoc => 0,
        .write, .append, .clobber, .dup_out => 1,
    };
}

fn shellErrorText(err: os.ShellError) []const u8 {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.BadFileDescriptor => "Bad file descriptor",
        error.InvalidArgument => "Invalid argument",
        error.Io => "I/O error",
        error.NotDir => "Not a directory",
        error.NotFound => "No such file or directory",
        error.NotImplemented => "Function not implemented",
        error.TooManyFiles => "Too many open files",
        error.Unsupported => "Unsupported",
    };
}

fn redirMessage(allocator: std.mem.Allocator, err: anyerror) ![]const u8 {
    return switch (err) {
        error.AmbiguousRedirectEmpty => allocator.dupe(u8, "sh: ambiguous redirect: empty"),
        error.AmbiguousRedirectMultiple => allocator.dupe(u8, "sh: ambiguous redirect: multiple files"),
        error.UnsupportedFd => allocator.dupe(u8, "sh: redirections to fds >2 are unsupported"),
        error.BadDup => allocator.dupe(u8, "sh: bad fd duplication"),
        error.MalformedHeredoc => allocator.dupe(u8, "sh: malformed heredoc"),
        error.ExpectedFilename => allocator.dupe(u8, "sh: expected a filename"),
        error.NotFound => allocator.dupe(u8, "sh: redirection target not found"),
        else => std.fmt.allocPrint(allocator, "sh: redirection failed: {s}", .{@errorName(err)}),
    };
}

fn escapeForDquote(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (input) |ch| {
        if (ch == '"' or ch == '\\') try out.append(allocator, '\\');
        try out.append(allocator, ch);
    }
    return out.toOwnedSlice(allocator);
}

fn joinArgs(allocator: std.mem.Allocator, args: []const []const u8, sep: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (args, 0..) |arg, idx| {
        if (idx != 0) try out.appendSlice(allocator, sep);
        try out.appendSlice(allocator, arg);
    }
    return out.toOwnedSlice(allocator);
}

fn loopCount(args: []const []const u8) u32 {
    if (args.len == 0) return 1;
    return @max(1, std.fmt.parseInt(u32, args[0], 10) catch 1);
}

fn statAdapter(ptr: *anyopaque, path: []const u8) ?os.FileStat {
    const shell: *Shell = @ptrCast(@alignCast(ptr));
    return shell.os.stat(path) catch null;
}

fn parseSignal(name: []const u8) ?os.Signal {
    if (std.mem.eql(u8, name, "1") or std.ascii.eqlIgnoreCase(name, "HUP") or std.ascii.eqlIgnoreCase(name, "SIGHUP")) return .hup;
    if (std.mem.eql(u8, name, "2") or std.ascii.eqlIgnoreCase(name, "INT") or std.ascii.eqlIgnoreCase(name, "SIGINT")) return .int;
    if (std.mem.eql(u8, name, "9") or std.ascii.eqlIgnoreCase(name, "KILL") or std.ascii.eqlIgnoreCase(name, "SIGKILL")) return .kill;
    if (std.mem.eql(u8, name, "15") or std.ascii.eqlIgnoreCase(name, "TERM") or std.ascii.eqlIgnoreCase(name, "SIGTERM")) return .term;
    if (std.mem.eql(u8, name, "18") or std.ascii.eqlIgnoreCase(name, "CONT") or std.ascii.eqlIgnoreCase(name, "SIGCONT")) return .cont;
    if (std.mem.eql(u8, name, "19") or std.ascii.eqlIgnoreCase(name, "STOP") or std.ascii.eqlIgnoreCase(name, "SIGSTOP")) return .tstp;
    if (std.mem.eql(u8, name, "20") or std.ascii.eqlIgnoreCase(name, "TSTP") or std.ascii.eqlIgnoreCase(name, "SIGTSTP")) return .tstp;
    return null;
}

fn builtinHelp(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, ":")) return ": - null command\n";
    if (std.mem.eql(u8, name, "true")) return "true - return success\n";
    if (std.mem.eql(u8, name, "false")) return "false - return failure\n";
    if (std.mem.eql(u8, name, "echo")) return "echo [-neE] [ARG]...\n";
    if (std.mem.eql(u8, name, "pwd")) return "pwd\n";
    if (std.mem.eql(u8, name, "printf")) return "printf FORMAT [ARG...]\n";
    if (std.mem.eql(u8, name, "test") or std.mem.eql(u8, name, "[")) return "test EXPR\n";
    if (std.mem.eql(u8, name, "cd")) return "cd [DIR]\n";
    if (std.mem.eql(u8, name, "export")) return "export NAME[=VALUE]...\n";
    if (std.mem.eql(u8, name, "unset")) return "unset NAME...\n";
    if (std.mem.eql(u8, name, "set")) return "set [-eux] [-o OPTION] [--] [ARG]...\n";
    if (std.mem.eql(u8, name, "shift")) return "shift [N]\n";
    if (std.mem.eql(u8, name, "read")) return "read NAME...\n";
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "source")) return ". FILE\n";
    if (std.mem.eql(u8, name, "eval")) return "eval [ARG]...\n";
    if (std.mem.eql(u8, name, "local")) return "local NAME[=VALUE]...\n";
    if (std.mem.eql(u8, name, "command")) return "command COMMAND [ARG]...\n";
    if (std.mem.eql(u8, name, "exit")) return "exit [N]\n";
    if (std.mem.eql(u8, name, "return")) return "return [N]\n";
    if (std.mem.eql(u8, name, "break")) return "break [N]\n";
    if (std.mem.eql(u8, name, "continue")) return "continue [N]\n";
    if (std.mem.eql(u8, name, "jobs")) return "jobs\n";
    if (std.mem.eql(u8, name, "fg")) return "fg [%JOB]\n";
    if (std.mem.eql(u8, name, "bg")) return "bg [%JOB]\n";
    if (std.mem.eql(u8, name, "wait")) return "wait [%JOB | PID]...\n";
    if (std.mem.eql(u8, name, "kill")) return "kill [-SIG] pid | %job ...\n";
    if (std.mem.eql(u8, name, "umount")) return "umount MOUNTPOINT\n";
    if (std.mem.eql(u8, name, "bind")) return "bind OLD NEW\n";
    return null;
}

fn expandGet(ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const shell: *Shell = @ptrCast(@alignCast(ptr));
    if (shell.getVar(name)) |v| return v;
    return shell.os.getenv(allocator, name) catch null;
}

fn expandSet(ptr: *anyopaque, name: []const u8, value: []const u8) void {
    const shell: *Shell = @ptrCast(@alignCast(ptr));
    shell.setVarRaw(name, value) catch {};
}

fn expandSpecial(ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const shell: *Shell = @ptrCast(@alignCast(ptr));
    if (std.mem.eql(u8, name, "?")) return std.fmt.allocPrint(allocator, "{d}", .{shell.last_status}) catch "";
    if (std.mem.eql(u8, name, "$")) return std.fmt.allocPrint(allocator, "{d}", .{shell.shell_pid}) catch "";
    if (std.mem.eql(u8, name, "!")) return if (shell.last_bg) |pid| std.fmt.allocPrint(allocator, "{d}", .{pid}) catch "" else "";
    if (std.mem.eql(u8, name, "#")) return std.fmt.allocPrint(allocator, "{d}", .{shell.positional.len}) catch "";
    if (std.mem.eql(u8, name, "-")) return shell.optsString(allocator) catch "";
    if (std.mem.eql(u8, name, "0")) return shell.arg0;
    const n = std.fmt.parseInt(usize, name, 10) catch return null;
    if (n >= 1 and n <= shell.positional.len) return shell.positional[n - 1];
    return null;
}

fn expandPositionals(ptr: *anyopaque, _: std.mem.Allocator) []const []const u8 {
    const shell: *Shell = @ptrCast(@alignCast(ptr));
    return shell.positional;
}

fn expandCommandSubst(ptr: *anyopaque, allocator: std.mem.Allocator, raw: []const u8) []const u8 {
    const shell: *Shell = @ptrCast(@alignCast(ptr));
    return shell.commandSubstRun(allocator, raw);
}

const ArithShellEnv = struct {
    shell: *Shell,
};

fn arithGet(ptr: *anyopaque, name: []const u8) i64 {
    const env: *ArithShellEnv = @ptrCast(@alignCast(ptr));
    const value = env.shell.getVar(name) orelse return 0;
    return std.fmt.parseInt(i64, std.mem.trim(u8, value, " \t\r\n"), 10) catch 0;
}

fn arithSet(ptr: *anyopaque, name: []const u8, value: i64) void {
    const env: *ArithShellEnv = @ptrCast(@alignCast(ptr));
    const text = std.fmt.allocPrint(env.shell.allocator, "{d}", .{value}) catch return;
    defer env.shell.allocator.free(text);
    env.shell.setVarRaw(name, text) catch {};
}

const arith_vtable = arith.ArithEnv.VTable{ .get = arithGet, .set = arithSet };

fn expandArith(ptr: *anyopaque, allocator: std.mem.Allocator, raw: []const u8) i64 {
    const shell: *Shell = @ptrCast(@alignCast(ptr));
    const expr = shell.expandArithOperands(allocator, raw) catch raw;
    var env_state = ArithShellEnv{ .shell = shell };
    var env = arith.ArithEnv{ .ptr = @ptrCast(&env_state), .vtable = &arith_vtable };
    return arith.eval(allocator, expr, &env) catch 0;
}

fn expandListDir(ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ?[]const []const u8 {
    const shell: *Shell = @ptrCast(@alignCast(ptr));
    return shell.os.readdir(allocator, path) catch null;
}

fn expandCwd(ptr: *anyopaque, allocator: std.mem.Allocator) []const u8 {
    const shell: *Shell = @ptrCast(@alignCast(ptr));
    return shell.os.getcwd(allocator) catch "";
}

fn expandIfs(ptr: *anyopaque, _: std.mem.Allocator) []const u8 {
    const shell: *Shell = @ptrCast(@alignCast(ptr));
    return shell.getVar("IFS") orelse " \t\n";
}

fn expandHome(ptr: *anyopaque, _: std.mem.Allocator) ?[]const u8 {
    const shell: *Shell = @ptrCast(@alignCast(ptr));
    return shell.getVar("HOME");
}

const expand_vtable = expand.ExpandContext.VTable{
    .get = expandGet,
    .set = expandSet,
    .special = expandSpecial,
    .positionals = expandPositionals,
    .command_subst = expandCommandSubst,
    .arith = expandArith,
    .list_dir = expandListDir,
    .cwd = expandCwd,
    .ifs = expandIfs,
    .home = expandHome,
};
