//! sys.zig — Layer 1 of the Luau standard library: `sys`, the thin 1:1 surface over the kernel
//! syscalls (was loom/src/sys_bindings.cpp; C++ → Zig). From inside the container these ARE the
//! system calls, so unlike the C++ — which went through wasi-libc for the fs/io ops — this calls
//! `mc_sys_*` DIRECTLY (sys is the syscall layer; one fd namespace, no libc indirection, no variadic
//! open). House rule: every `sys.*` returns `value, err` — `err` is the errno NAME or nil.

const std = @import("std");
const lua = @import("lua.zig");
const mc = @import("mc");
const fs = @import("fs.zig");
const c = lua.c;
const State = lua.State;

const alloc = std.heap.c_allocator;

// mc open flags (contracts/constants.kdl).
const O_READ: i32 = 1;
const O_WRITE: i32 = 2;
const O_CREATE: i32 = 4;
const O_TRUNC: i32 = 8;
const O_APPEND: i32 = 16;

// errno values (contracts/constants.kdl — WASI-style, what the mc syscalls return).
const EIO: i32 = 29;
const EINVAL: i32 = 28;

fn errnoName(e: i32) [*:0]const u8 {
    return switch (e) {
        2 => "EACCES",   6 => "EAGAIN",    8 => "EBADF",     10 => "ECHILD",
        20 => "EEXIST",  27 => "EINTR",    28 => "EINVAL",   29 => "EIO",
        31 => "EISDIR",  32 => "ELOOP",    33 => "EMFILE",   44 => "ENOENT",
        52 => "ENOSYS",  54 => "ENOTDIR",  55 => "ENOTEMPTY", 63 => "EPERM",
        64 => "EPIPE",   71 => "ESRCH",    75 => "EXDEV",    else => "EIO",
    };
}

// The value/err idiom: fail → (nil, errname); ok1 → (<value already pushed>, nil); okTrue → (true, nil).
fn fail(L: ?*State, e: i32) c_int {
    c.lua_pushnil(L);
    _ = c.lua_pushstring(L, errnoName(e));
    return 2;
}
fn ok1(L: ?*State) c_int {
    c.lua_pushnil(L);
    return 2;
}
fn okTrue(L: ?*State) c_int {
    c.lua_pushboolean(L, 1);
    c.lua_pushnil(L);
    return 2;
}

const Reg = struct { name: [*:0]const u8, fn_: lua.CFn };
fn setFuncs(L: ?*State, regs: []const Reg) void {
    for (regs) |r| {
        lua.pushcfunction(L, r.fn_, r.name);
        c.lua_setfield(L, -2, r.name);
    }
}

// ── sys.fs — whole-file read/write, typed readdir/stat, the mutating ops. ─────────────────────────

fn lFsRead(L: ?*State) callconv(.c) c_int {
    const path = c.luaL_checklstring(L, 1, null); // Lua strings are NUL-terminated
    var e: i32 = 0;
    const bytes = fs.slurp(@ptrCast(path), &e) orelse return fail(L, e);
    defer alloc.free(bytes);
    _ = c.lua_pushlstring(L, bytes.ptr, bytes.len);
    return ok1(L);
}

fn lFsWrite(L: ?*State) callconv(.c) c_int {
    var plen: usize = 0;
    const path = c.luaL_checklstring(L, 1, &plen);
    var dlen: usize = 0;
    const data = c.luaL_checklstring(L, 2, &dlen);
    var flags: i32 = O_WRITE | O_CREATE;
    if (c.lua_type(L, 3) == c.LUA_TTABLE) {
        _ = c.lua_getfield(L, 3, "append");
        flags |= if (c.lua_toboolean(L, -1) != 0) O_APPEND else O_TRUNC;
        lua.pop(L, 1);
    } else {
        flags |= O_TRUNC;
    }
    var fd: u32 = 0;
    var e = mc.mc_sys_open(mc.addr(path), @intCast(plen), flags, mc.addr(&fd));
    if (e != 0) return fail(L, e);
    defer _ = mc.mc_sys_close(@intCast(fd));
    var off: usize = 0;
    while (off < dlen) {
        var n: u32 = 0;
        e = mc.mc_sys_write(@intCast(fd), mc.addr(data + off), @intCast(dlen - off), mc.addr(&n));
        if (e != 0) return fail(L, e);
        if (n == 0) return fail(L, EIO);
        off += n;
    }
    return okTrue(L);
}

fn lFsReaddir(L: ?*State) callconv(.c) c_int {
    var plen: usize = 0;
    const path = c.luaL_checklstring(L, 1, &plen);
    var names: [32768]u8 = undefined;
    var used: u32 = 0;
    const e = mc.mc_sys_readdir(mc.addr(path), @intCast(plen), mc.addr(&names), names.len, mc.addr(&used));
    if (e != 0) return fail(L, e);
    lua.newtable(L);
    var i: c_int = 0;
    var it = std.mem.splitScalar(u8, names[0..used], 0);
    while (it.next()) |name| {
        if (name.len == 0) continue;
        lua.newtable(L);
        _ = c.lua_pushlstring(L, name.ptr, name.len);
        c.lua_setfield(L, -2, "name");
        // kind: lstat the entry (mc_sys_readdir yields names only).
        var full: [4096]u8 = undefined;
        const fl = joinPath(&full, path[0..plen], name);
        var st: [44]u8 = undefined;
        var kind: [*:0]const u8 = "file";
        if (fl) |n| {
            if (mc.mc_sys_lstat(mc.addr(&full), @intCast(n), mc.addr(&st)) == 0)
                kind = statKind(&st);
        }
        _ = c.lua_pushstring(L, kind);
        c.lua_setfield(L, -2, "kind");
        i += 1;
        c.lua_rawseti(L, -2, i);
    }
    return ok1(L);
}

fn joinPath(out: *[4096]u8, dir: []const u8, name: []const u8) ?usize {
    if (dir.len + 1 + name.len > out.len) return null;
    @memcpy(out[0..dir.len], dir);
    var n = dir.len;
    if (n == 0 or out[n - 1] != '/') {
        out[n] = '/';
        n += 1;
    }
    @memcpy(out[n .. n + name.len], name);
    return n + name.len;
}

fn statKind(buf: *const [44]u8) [*:0]const u8 {
    return switch (std.mem.readInt(u32, buf[8..12], .little)) {
        1 => "dir",
        2 => "symlink",
        else => "file",
    };
}

fn statTable(L: ?*State, buf: *const [44]u8) c_int {
    lua.newtable(L);
    c.lua_pushinteger(L, @intCast(@as(i64, @bitCast(std.mem.readInt(u64, buf[0..8], .little)))));
    c.lua_setfield(L, -2, "size");
    _ = c.lua_pushstring(L, statKind(buf));
    c.lua_setfield(L, -2, "kind");
    c.lua_pushinteger(L, @intCast(std.mem.readInt(u32, buf[16..20], .little) & 0o777));
    c.lua_setfield(L, -2, "mode");
    c.lua_pushnumber(L, @floatFromInt(std.mem.readInt(i64, buf[20..28], .little)));
    c.lua_setfield(L, -2, "mtime");
    return ok1(L);
}

fn lFsStat(L: ?*State) callconv(.c) c_int {
    var plen: usize = 0;
    const path = c.luaL_checklstring(L, 1, &plen);
    var st: [44]u8 = undefined;
    const e = mc.mc_sys_stat(mc.addr(path), @intCast(plen), mc.addr(&st));
    return if (e != 0) fail(L, e) else statTable(L, &st);
}
fn lFsLstat(L: ?*State) callconv(.c) c_int {
    var plen: usize = 0;
    const path = c.luaL_checklstring(L, 1, &plen);
    var st: [44]u8 = undefined;
    const e = mc.mc_sys_lstat(mc.addr(path), @intCast(plen), mc.addr(&st));
    return if (e != 0) fail(L, e) else statTable(L, &st);
}
fn lFsExists(L: ?*State) callconv(.c) c_int {
    var plen: usize = 0;
    const path = c.luaL_checklstring(L, 1, &plen);
    var st: [44]u8 = undefined;
    c.lua_pushboolean(L, @intFromBool(mc.mc_sys_lstat(mc.addr(path), @intCast(plen), mc.addr(&st)) == 0));
    return 1;
}
fn lFsMkdir(L: ?*State) callconv(.c) c_int {
    var plen: usize = 0;
    const path = c.luaL_checklstring(L, 1, &plen);
    const e = mc.mc_sys_mkdir(mc.addr(path), @intCast(plen));
    return if (e != 0) fail(L, e) else okTrue(L);
}
fn lFsRemove(L: ?*State) callconv(.c) c_int {
    var plen: usize = 0;
    const path = c.luaL_checklstring(L, 1, &plen);
    const e = mc.mc_sys_unlink(mc.addr(path), @intCast(plen));
    return if (e != 0) fail(L, e) else okTrue(L);
}
fn lFsRename(L: ?*State) callconv(.c) c_int {
    var fl: usize = 0;
    const from = c.luaL_checklstring(L, 1, &fl);
    var tl: usize = 0;
    const to = c.luaL_checklstring(L, 2, &tl);
    const e = mc.mc_sys_rename(mc.addr(from), @intCast(fl), mc.addr(to), @intCast(tl));
    return if (e != 0) fail(L, e) else okTrue(L);
}
fn lFsSymlink(L: ?*State) callconv(.c) c_int {
    var tl: usize = 0;
    const target = c.luaL_checklstring(L, 1, &tl);
    var ll: usize = 0;
    const link = c.luaL_checklstring(L, 2, &ll);
    const e = mc.mc_sys_symlink(mc.addr(target), @intCast(tl), mc.addr(link), @intCast(ll));
    return if (e != 0) fail(L, e) else okTrue(L);
}
fn lFsReadlink(L: ?*State) callconv(.c) c_int {
    var plen: usize = 0;
    const path = c.luaL_checklstring(L, 1, &plen);
    var buf: [4096]u8 = undefined;
    var used: u32 = 0;
    const e = mc.mc_sys_readlink(mc.addr(path), @intCast(plen), mc.addr(&buf), buf.len, mc.addr(&used));
    if (e != 0) return fail(L, e);
    _ = c.lua_pushlstring(L, &buf, used);
    return ok1(L);
}
fn lFsChmod(L: ?*State) callconv(.c) c_int {
    var plen: usize = 0;
    const path = c.luaL_checklstring(L, 1, &plen);
    const mode = c.luaL_checkinteger(L, 2);
    const e = mc.mc_sys_chmod(mc.addr(path), @intCast(plen), @intCast(mode));
    return if (e != 0) fail(L, e) else okTrue(L);
}
fn lFsCwd(L: ?*State) callconv(.c) c_int {
    var buf: [4096]u8 = undefined;
    var used: u32 = 0;
    const e = mc.mc_sys_getcwd(mc.addr(&buf), buf.len, mc.addr(&used));
    if (e != 0) return fail(L, e);
    _ = c.lua_pushlstring(L, &buf, used);
    return ok1(L);
}
fn lFsChdir(L: ?*State) callconv(.c) c_int {
    var plen: usize = 0;
    const path = c.luaL_checklstring(L, 1, &plen);
    const e = mc.mc_sys_chdir(mc.addr(path), @intCast(plen));
    return if (e != 0) fail(L, e) else okTrue(L);
}

const fs_funcs = [_]Reg{
    .{ .name = "read", .fn_ = &lFsRead },         .{ .name = "write", .fn_ = &lFsWrite },
    .{ .name = "readdir", .fn_ = &lFsReaddir },   .{ .name = "stat", .fn_ = &lFsStat },
    .{ .name = "lstat", .fn_ = &lFsLstat },       .{ .name = "exists", .fn_ = &lFsExists },
    .{ .name = "mkdir", .fn_ = &lFsMkdir },       .{ .name = "remove", .fn_ = &lFsRemove },
    .{ .name = "rename", .fn_ = &lFsRename },      .{ .name = "symlink", .fn_ = &lFsSymlink },
    .{ .name = "readlink", .fn_ = &lFsReadlink },  .{ .name = "chmod", .fn_ = &lFsChmod },
    .{ .name = "cwd", .fn_ = &lFsCwd },            .{ .name = "chdir", .fn_ = &lFsChdir },
};

// ── sys.io — std streams + raw fd I/O. ────────────────────────────────────────────────────────────

fn lIoWrite(L: ?*State) callconv(.c) c_int {
    var argbase: c_int = 1;
    var fd: i32 = 1; // stdout
    if (c.lua_type(L, 1) == c.LUA_TNUMBER) {
        fd = @intCast(c.luaL_checkinteger(L, 1));
        argbase = 2;
    }
    var len: usize = 0;
    const data = c.luaL_checklstring(L, argbase, &len);
    var off: usize = 0;
    while (off < len) {
        var n: u32 = 0;
        const e = mc.mc_sys_write(fd, mc.addr(data + off), @intCast(len - off), mc.addr(&n));
        if (e != 0) return fail(L, e);
        if (n == 0) return fail(L, EIO);
        off += n;
    }
    return okTrue(L);
}

fn lIoRead(L: ?*State) callconv(.c) c_int {
    const fd: i32 = if (c.lua_type(L, 1) == c.LUA_TNUMBER and c.lua_type(L, 2) == c.LUA_TNUMBER)
        @intCast(c.luaL_checkinteger(L, 1))
    else
        0; // stdin
    const argbase: c_int = if (c.lua_type(L, 1) == c.LUA_TNUMBER and c.lua_type(L, 2) == c.LUA_TNUMBER) 2 else 1;
    var want: i64 = c.luaL_optinteger(L, argbase, 4096);
    if (want < 0) want = 0;
    const buf = alloc.alloc(u8, @intCast(want)) catch return fail(L, EIO);
    defer alloc.free(buf);
    var n: u32 = 0;
    const e = mc.mc_sys_read(fd, mc.addr(buf.ptr), @intCast(buf.len), mc.addr(&n));
    if (e != 0) return fail(L, e);
    _ = c.lua_pushlstring(L, buf.ptr, n);
    return ok1(L);
}

fn lIoIsatty(L: ?*State) callconv(.c) c_int {
    const fd: i32 = @intCast(c.luaL_optinteger(L, 1, 1));
    var r: u32 = 0;
    _ = mc.mc_sys_isatty(fd, mc.addr(&r));
    c.lua_pushboolean(L, @intFromBool(r != 0));
    return 1;
}

const io_funcs = [_]Reg{
    .{ .name = "write", .fn_ = &lIoWrite },
    .{ .name = "read", .fn_ = &lIoRead },
    .{ .name = "isatty", .fn_ = &lIoIsatty },
};

// ── sys.proc — process control. ───────────────────────────────────────────────────────────────────

// Build a NUL-separated argv blob from a Lua array of strings at `idx` (caller frees).
fn buildArgv(L: ?*State, idx: c_int) ?[]u8 {
    const n: c_int = @intCast(c.lua_objlen(L, idx));
    var blob: std.ArrayList(u8) = .empty;
    var i: c_int = 1;
    while (i <= n) : (i += 1) {
        _ = c.lua_rawgeti(L, idx, i);
        var len: usize = 0;
        const s = c.lua_tolstring(L, -1, &len);
        if (s == null) {
            lua.pop(L, 1);
            blob.deinit(alloc);
            return null;
        }
        blob.appendSlice(alloc, s[0..len]) catch {
            blob.deinit(alloc);
            return null;
        };
        blob.append(alloc, 0) catch {
            blob.deinit(alloc);
            return null;
        };
        lua.pop(L, 1);
    }
    return blob.toOwnedSlice(alloc) catch null;
}

fn tierFrom(L: ?*State, idx: c_int) i32 {
    if (c.lua_type(L, idx) == c.LUA_TNUMBER) return @intCast(c.luaL_checkinteger(L, idx));
    if (c.lua_type(L, idx) == c.LUA_TSTRING) {
        const s = std.mem.span(c.lua_tolstring(L, idx, null));
        if (std.mem.eql(u8, s, "full")) return 1;
        if (std.mem.eql(u8, s, "read-write")) return 2;
        if (std.mem.eql(u8, s, "read-only")) return 3;
        if (std.mem.eql(u8, s, "isolated")) return 4;
    }
    return 0;
}

fn lProcSpawn(L: ?*State) callconv(.c) c_int {
    c.luaL_checktype(L, 1, c.LUA_TTABLE);
    _ = c.lua_getfield(L, 1, "argv");
    if (c.lua_type(L, -1) != c.LUA_TTABLE) {
        _ = c.luaL_errorL(L, "sys.proc.spawn: missing argv array");
        return 0;
    }
    const blob = buildArgv(L, c.lua_gettop(L)) orelse return fail(L, EINVAL);
    defer alloc.free(blob);
    lua.pop(L, 1);
    _ = c.lua_getfield(L, 1, "stdin");
    const in_fd: i32 = @intCast(c.luaL_optinteger(L, -1, 0));
    _ = c.lua_getfield(L, 1, "stdout");
    const out_fd: i32 = @intCast(c.luaL_optinteger(L, -1, 1));
    _ = c.lua_getfield(L, 1, "stderr");
    const err_fd: i32 = @intCast(c.luaL_optinteger(L, -1, 2));
    lua.pop(L, 3);
    _ = c.lua_getfield(L, 1, "tier");
    const tier = tierFrom(L, -1);
    lua.pop(L, 1);
    var pid: u32 = 0;
    const e = mc.mc_sys_spawn(mc.addr(blob.ptr), @intCast(blob.len), in_fd, out_fd, err_fd, tier, mc.addr(&pid));
    if (e != 0) return fail(L, e);
    c.lua_pushinteger(L, @intCast(pid));
    return ok1(L);
}

fn lProcWait(L: ?*State) callconv(.c) c_int {
    const pid: i32 = @intCast(c.luaL_checkinteger(L, 1));
    var opts: i32 = 0;
    if (c.lua_type(L, 2) == c.LUA_TTABLE) {
        _ = c.lua_getfield(L, 2, "nohang");
        if (c.lua_toboolean(L, -1) != 0) opts |= 1;
        lua.pop(L, 1);
    }
    var status: u32 = 0;
    var got: u32 = 0;
    const e = mc.mc_sys_waitpid(pid, opts, mc.addr(&status), mc.addr(&got));
    if (e != 0) return fail(L, e);
    c.lua_pushinteger(L, @intCast(@as(i32, @bitCast(status))));
    return ok1(L);
}

fn lProcRun(L: ?*State) callconv(.c) c_int {
    if (c.lua_type(L, 1) == c.LUA_TSTRING) {
        const cmd = c.lua_tolstring(L, 1, null);
        lua.newtable(L);
        _ = c.lua_pushstring(L, "sh");
        c.lua_rawseti(L, -2, 1);
        _ = c.lua_pushstring(L, "-c");
        c.lua_rawseti(L, -2, 2);
        _ = c.lua_pushstring(L, cmd);
        c.lua_rawseti(L, -2, 3);
    } else {
        c.luaL_checktype(L, 1, c.LUA_TTABLE);
        c.lua_pushvalue(L, 1);
    }
    const blob = buildArgv(L, c.lua_gettop(L)) orelse return fail(L, EINVAL);
    defer alloc.free(blob);
    var rfd: u32 = 0;
    var wfd: u32 = 0;
    var e = mc.mc_sys_pipe(mc.addr(&rfd), mc.addr(&wfd));
    if (e != 0) return fail(L, e);
    var pid: u32 = 0;
    e = mc.mc_sys_spawn(mc.addr(blob.ptr), @intCast(blob.len), 0, @intCast(wfd), 2, 0, mc.addr(&pid));
    _ = mc.mc_sys_close(@intCast(wfd));
    if (e != 0) {
        _ = mc.mc_sys_close(@intCast(rfd));
        return fail(L, e);
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var read_err: i32 = 0;
    var buf: [8192]u8 = undefined;
    while (true) {
        var n: u32 = 0;
        const re = mc.mc_sys_read(@intCast(rfd), mc.addr(&buf), buf.len, mc.addr(&n));
        if (re != 0) {
            read_err = re;
            break;
        }
        if (n == 0) break;
        out.appendSlice(alloc, buf[0..n]) catch {
            read_err = EIO;
            break;
        };
    }
    _ = mc.mc_sys_close(@intCast(rfd));
    var status: u32 = 0;
    var got: u32 = 0;
    const wait_err = mc.mc_sys_waitpid(@intCast(pid), 0, mc.addr(&status), mc.addr(&got));
    if (read_err != 0 or wait_err != 0) return fail(L, if (read_err != 0) read_err else wait_err);
    lua.newtable(L);
    _ = c.lua_pushlstring(L, out.items.ptr, out.items.len);
    c.lua_setfield(L, -2, "out");
    c.lua_pushinteger(L, @intCast(@as(i32, @bitCast(status))));
    c.lua_setfield(L, -2, "code");
    c.lua_pushnil(L);
    return 2;
}

fn lProcPid(L: ?*State) callconv(.c) c_int {
    var pid: u32 = 0;
    _ = mc.mc_sys_getpid(mc.addr(&pid));
    c.lua_pushinteger(L, @intCast(pid));
    return 1;
}
fn lProcPpid(L: ?*State) callconv(.c) c_int {
    var pid: u32 = 0;
    _ = mc.mc_sys_getppid(mc.addr(&pid));
    c.lua_pushinteger(L, @intCast(pid));
    return 1;
}
fn lProcExit(L: ?*State) callconv(.c) c_int {
    _ = mc.mc_sys_exit(@intCast(c.luaL_optinteger(L, 1, 0)));
    return 0; // unreachable — exit terminates the guest
}

const proc_funcs = [_]Reg{
    .{ .name = "spawn", .fn_ = &lProcSpawn }, .{ .name = "wait", .fn_ = &lProcWait },
    .{ .name = "run", .fn_ = &lProcRun },     .{ .name = "pid", .fn_ = &lProcPid },
    .{ .name = "ppid", .fn_ = &lProcPpid },   .{ .name = "exit", .fn_ = &lProcExit },
};

// ── sys.net / sys.host — capability egress + host-tool invocation. ─────────────────────────────────

fn drainFd(fd: i32, out: *std.ArrayList(u8)) i32 {
    var buf: [8192]u8 = undefined;
    while (true) {
        var n: u32 = 0;
        const e = mc.mc_sys_read(fd, mc.addr(&buf), buf.len, mc.addr(&n));
        if (e != 0) return e;
        if (n == 0) return 0;
        out.appendSlice(alloc, buf[0..n]) catch return EIO;
    }
}

fn lNetGet(L: ?*State) callconv(.c) c_int {
    var len: usize = 0;
    const url = c.luaL_checklstring(L, 1, &len);
    var fd: u32 = 0;
    const e = mc.mc_sys_http_get(mc.addr(url), @intCast(len), mc.addr(&fd));
    if (e != 0) return fail(L, e);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const re = drainFd(@intCast(fd), &out);
    _ = mc.mc_sys_close(@intCast(fd));
    if (re != 0) return fail(L, re);
    _ = c.lua_pushlstring(L, out.items.ptr, out.items.len);
    return ok1(L);
}

fn lNetFetch(L: ?*State) callconv(.c) c_int {
    var ulen: usize = 0;
    const url = c.luaL_checklstring(L, 1, &ulen);
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(alloc);
    var method: []const u8 = "GET";
    var headers: std.ArrayList(u8) = .empty;
    defer headers.deinit(alloc);
    var body: []const u8 = "";
    if (c.lua_type(L, 2) == c.LUA_TTABLE) {
        _ = c.lua_getfield(L, 2, "method");
        if (c.lua_type(L, -1) == c.LUA_TSTRING) method = std.mem.span(c.lua_tolstring(L, -1, null));
        lua.pop(L, 1);
        _ = c.lua_getfield(L, 2, "body");
        if (c.lua_type(L, -1) == c.LUA_TSTRING) {
            var bl: usize = 0;
            const b = c.lua_tolstring(L, -1, &bl);
            body = b[0..bl];
        }
        lua.pop(L, 1);
        _ = c.lua_getfield(L, 2, "headers");
        if (c.lua_type(L, -1) == c.LUA_TTABLE) {
            c.lua_pushnil(L);
            while (c.lua_next(L, -2) != 0) {
                if (c.lua_type(L, -2) == c.LUA_TSTRING and c.lua_type(L, -1) == c.LUA_TSTRING) {
                    headers.appendSlice(alloc, std.mem.span(c.lua_tolstring(L, -2, null))) catch return fail(L, EIO);
                    headers.appendSlice(alloc, ": ") catch return fail(L, EIO);
                    headers.appendSlice(alloc, std.mem.span(c.lua_tolstring(L, -1, null))) catch return fail(L, EIO);
                    headers.append(alloc, '\n') catch return fail(L, EIO);
                }
                lua.pop(L, 1);
            }
        }
        lua.pop(L, 1);
    }
    req.appendSlice(alloc, method) catch return fail(L, EIO);
    req.append(alloc, ' ') catch return fail(L, EIO);
    req.appendSlice(alloc, url[0..ulen]) catch return fail(L, EIO);
    req.append(alloc, '\n') catch return fail(L, EIO);
    req.appendSlice(alloc, headers.items) catch return fail(L, EIO);
    req.append(alloc, '\n') catch return fail(L, EIO);
    req.appendSlice(alloc, body) catch return fail(L, EIO);
    var fd: u32 = 0;
    var e = mc.mc_sys_http_request(mc.addr(req.items.ptr), @intCast(req.items.len), mc.addr(&fd));
    if (e != 0) return fail(L, e);
    var status: u32 = 0;
    e = mc.mc_sys_http_status(@intCast(fd), mc.addr(&status));
    if (e != 0) {
        _ = mc.mc_sys_close(@intCast(fd));
        return fail(L, e);
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const re = drainFd(@intCast(fd), &out);
    _ = mc.mc_sys_close(@intCast(fd));
    if (re != 0) return fail(L, re);
    lua.newtable(L);
    c.lua_pushinteger(L, @intCast(status));
    c.lua_setfield(L, -2, "status");
    _ = c.lua_pushlstring(L, out.items.ptr, out.items.len);
    c.lua_setfield(L, -2, "body");
    return ok1(L);
}

const net_funcs = [_]Reg{
    .{ .name = "get", .fn_ = &lNetGet },
    .{ .name = "fetch", .fn_ = &lNetFetch },
};

fn lHostCall(L: ?*State) callconv(.c) c_int {
    var nlen: usize = 0;
    const name = c.luaL_checklstring(L, 1, &nlen);
    var alen: usize = 0;
    const args = c.luaL_optlstring(L, 2, "", &alen);
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(alloc);
    req.appendSlice(alloc, name[0..nlen]) catch return fail(L, EIO);
    req.append(alloc, 0) catch return fail(L, EIO);
    req.appendSlice(alloc, args[0..alen]) catch return fail(L, EIO);
    var fd: u32 = 0;
    const e = mc.mc_sys_host_call(mc.addr(req.items.ptr), @intCast(req.items.len), mc.addr(&fd));
    if (e != 0) return fail(L, e);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const re = drainFd(@intCast(fd), &out);
    _ = mc.mc_sys_close(@intCast(fd));
    if (re != 0) return fail(L, re);
    _ = c.lua_pushlstring(L, out.items.ptr, out.items.len);
    return ok1(L);
}

const host_funcs = [_]Reg{
    .{ .name = "call", .fn_ = &lHostCall },
};

// ── sys.svc — resident-service CLIENT (connect + call). ─────────────────────────────────────────────
// The low-level face of a resident service: `connect(name)` opens a session (returns a connection fd),
// `call(fd, req)` sends a request blob and returns the response bytes (draining the readable result
// fd, exactly like host.call). Domain libraries (sqlite.luau, …) wrap these into ergonomic objects.

fn lSvcConnect(L: ?*State) callconv(.c) c_int {
    var nlen: usize = 0;
    const name = c.luaL_checklstring(L, 1, &nlen);
    var fd: u32 = 0;
    const e = mc.mc_sys_svc_connect(mc.addr(name), @intCast(nlen), mc.addr(&fd));
    if (e != 0) return fail(L, e);
    c.lua_pushinteger(L, @intCast(fd));
    return ok1(L);
}

fn lSvcCall(L: ?*State) callconv(.c) c_int {
    const fd: i32 = @intCast(c.luaL_checkinteger(L, 1));
    var rlen: usize = 0;
    const req = c.luaL_checklstring(L, 2, &rlen);
    var rfd: u32 = 0;
    const e = mc.mc_sys_svc_call(fd, mc.addr(req), @intCast(rlen), 0, 0, mc.addr(&rfd));
    if (e != 0) return fail(L, e);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const re = drainFd(@intCast(rfd), &out);
    _ = mc.mc_sys_close(@intCast(rfd));
    if (re != 0) return fail(L, re);
    _ = c.lua_pushlstring(L, out.items.ptr, out.items.len);
    return ok1(L);
}

fn lSvcClose(L: ?*State) callconv(.c) c_int {
    const fd: i32 = @intCast(c.luaL_checkinteger(L, 1));
    const e = mc.mc_sys_close(fd);
    if (e != 0) return fail(L, e);
    return okTrue(L);
}

const svc_funcs = [_]Reg{
    .{ .name = "connect", .fn_ = &lSvcConnect },
    .{ .name = "call", .fn_ = &lSvcCall },
    .{ .name = "close", .fn_ = &lSvcClose },
};

// ── sys.time / sys.rand. ──────────────────────────────────────────────────────────────────────────

fn lTimeNow(L: ?*State) callconv(.c) c_int {
    var ms: i64 = 0;
    const e = mc.mc_sys_time_realtime(mc.addr(&ms));
    if (e != 0) return fail(L, e);
    c.lua_pushnumber(L, @floatFromInt(ms));
    return ok1(L);
}
fn lTimeMono(L: ?*State) callconv(.c) c_int {
    var ms: i64 = 0;
    const e = mc.mc_sys_time_monotonic(mc.addr(&ms));
    if (e != 0) return fail(L, e);
    c.lua_pushnumber(L, @floatFromInt(ms));
    return ok1(L);
}
fn lTimeSleep(L: ?*State) callconv(.c) c_int {
    const e = mc.mc_sys_sleep_ms(@intCast(c.luaL_checkinteger(L, 1)));
    return if (e != 0) fail(L, e) else okTrue(L);
}
const time_funcs = [_]Reg{
    .{ .name = "now", .fn_ = &lTimeNow },
    .{ .name = "mono", .fn_ = &lTimeMono },
    .{ .name = "sleep", .fn_ = &lTimeSleep },
};

fn lRandBytes(L: ?*State) callconv(.c) c_int {
    var n: i64 = c.luaL_checkinteger(L, 1);
    if (n < 0) n = 0;
    const buf = alloc.alloc(u8, @intCast(n)) catch return fail(L, EIO);
    defer alloc.free(buf);
    const e = mc.mc_sys_random(mc.addr(buf.ptr), @intCast(buf.len));
    if (e != 0) return fail(L, e);
    _ = c.lua_pushlstring(L, buf.ptr, buf.len);
    return ok1(L);
}
const rand_funcs = [_]Reg{
    .{ .name = "bytes", .fn_ = &lRandBytes },
};

// ── sys.args() / sys.abi(). ───────────────────────────────────────────────────────────────────────

fn lArgs(L: ?*State) callconv(.c) c_int {
    var buf: [16384]u8 = undefined;
    var total: u32 = 0;
    _ = mc.mc_sys_args(mc.addr(&buf), buf.len, mc.addr(&total));
    const n = @min(total, buf.len);
    lua.newtable(L);
    var i: c_int = 0;
    var it = std.mem.splitScalar(u8, buf[0..n], 0);
    while (it.next()) |arg| {
        if (arg.len == 0) continue;
        _ = c.lua_pushlstring(L, arg.ptr, arg.len);
        i += 1;
        c.lua_rawseti(L, -2, i);
    }
    return 1;
}

fn lAbi(L: ?*State) callconv(.c) c_int {
    var v: u32 = 0;
    _ = mc.mc_sys_abi_version(mc.addr(&v));
    c.lua_pushinteger(L, @intCast(v));
    return 1;
}

// ── install the `sys` global. ─────────────────────────────────────────────────────────────────────

fn sub(L: ?*State, name: [*:0]const u8, regs: []const Reg) void {
    lua.newtable(L);
    setFuncs(L, regs);
    c.lua_setfield(L, -2, name);
}

pub export fn mc_open_sys(L: ?*State) void {
    lua.newtable(L); // sys
    sub(L, "fs", &fs_funcs);
    sub(L, "io", &io_funcs);
    sub(L, "proc", &proc_funcs);
    sub(L, "net", &net_funcs);
    sub(L, "host", &host_funcs);
    sub(L, "svc", &svc_funcs);
    sub(L, "time", &time_funcs);
    sub(L, "rand", &rand_funcs);
    lua.pushcfunction(L, &lArgs, "args");
    c.lua_setfield(L, -2, "args");
    lua.pushcfunction(L, &lAbi, "abi");
    c.lua_setfield(L, -2, "abi");
    c.lua_pushinteger(L, 0);
    c.lua_setfield(L, -2, "TIER_INHERIT");
    c.lua_pushinteger(L, 1);
    c.lua_setfield(L, -2, "TIER_FULL");
    c.lua_pushinteger(L, 2);
    c.lua_setfield(L, -2, "TIER_READ_WRITE");
    c.lua_pushinteger(L, 3);
    c.lua_setfield(L, -2, "TIER_READ_ONLY");
    c.lua_pushinteger(L, 4);
    c.lua_setfield(L, -2, "TIER_ISOLATED");
    lua.setglobal(L, "sys");
}
