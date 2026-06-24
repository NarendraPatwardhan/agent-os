//! entry.zig — the `/bin/luau` command (was loom/src/luau_cli.cpp; the C/C++ → Zig rewrite). A
//! script/eval/REPL runner modelled on /bin/sh: `luau SCRIPT [args]`, `luau -e CODE`, `luau`
//! (REPL), `luau -` (stdin), `--version`/`--help`. Errors are pcall-trapped (printed `luau: <msg>`
//! + a traceback). Uses the Lua C API directly via @cImport — the underlying functions, since the
//! lua_* convenience MACROS are not exposed through translate-c. See third_party/luau/SYSTEM.md.

const std = @import("std");
const mc = @import("mc"); // mc_sys_spawn / waitpid — `luau --check` runs /bin/luau-analyze
const fs = @import("fs.zig"); // the shared mc_sys_*-backed file reader
const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
});

// luau_compile lives in luacode.h, which transitively pulls C++ (<vector> via TimeTrace.h) that
// Zig's translate-c (@cImport) can't handle. Declare the single C-ABI entry point we use by hand
// (it is `extern "C"` in luacode.h); the C++ TUs that DEFINE it compile fine via zig c++.
extern fn luau_compile(source: [*]const u8, size: usize, options: ?*anyopaque, outsize: *usize) [*c]u8;

// Installed by the Zig bindings (sys.zig / stdlib.zig) — opened after the standard libs. (Wired in
// once those land; the core interpreter runs without them.)
extern fn mc_open_sys(L: ?*c.lua_State) void;
extern fn mc_open_stdlib(L: ?*c.lua_State) void;

// Force the glue modules' export fns into the binary: mc_protected_call / mc_raise / __mc_pcall_run
// (linked by the patched ldo.cpp), mc_open_sys / mc_open_stdlib (the externs above). rules_zig
// zig_library deps are Zig MODULES (for @import), not linked archives — so the glue is compiled as
// the binary's own srcs and referenced here, rather than linked as a separate library.
comptime {
    _ = @import("trap.zig");
    _ = @import("sys.zig");
    _ = @import("stdlib.zig");
    _ = @import("json.zig"); // mc_open_json (the require'd native module)
    _ = @import("hash.zig"); // mc_open_hash
    _ = @import("encoding.zig"); // mc_open_encoding (base64/hex)
    _ = @import("deflate.zig"); // mc_open_deflate (raw deflate — zip/OOXML)
    _ = @import("re.zig"); // mc_open_re (Pike-VM regex)
    _ = @import("wasi_shim.zig"); // residual wasi import forwarders (fd_close)
}

const kVersion = "luau (agent-os) — Luau 0.725";

// Exit codes (§8.4): 0 ok · 1 runtime error · 2 syntax/usage error.
const EXIT_OK: c_int = 0;
const EXIT_RUNTIME: c_int = 1;
const EXIT_USAGE: c_int = 2;

fn newState() ?*c.lua_State {
    const L = c.luaL_newstate();
    c.luaL_openlibs(L);
    mc_open_sys(L);
    mc_open_stdlib(L);
    return L;
}

// The glue's own diagnostics go straight to the mc write syscall (fs.writeAll). Luau's own `print`
// stays on libc fwrite (the C++ core); both land on the same kernel stdio (fd 0/1/2), so there is no
// namespace fork — see fs.zig.
fn writeFd(fd: c_int, bytes: []const u8) void {
    fs.writeAll(@intCast(fd), bytes);
}

fn eprint(s: []const u8) void {
    writeFd(2, s);
}

// Compile `src` and load it as chunk `chunkname`, leaving the chunk on the stack on success. A
// syntax error becomes a load error (message on the stack). Returns 0 / nonzero.
fn loadChunk(L: ?*c.lua_State, chunkname: [*:0]const u8, src: [*]const u8, len: usize) c_int {
    var bclen: usize = 0;
    const bc = luau_compile(src, len, null, &bclen);
    const rc = c.luau_load(L, chunkname, bc, bclen, 0);
    std.c.free(bc);
    return rc;
}

// pcall message handler: append a Luau traceback to the error message.
fn tracebackHandler(L: ?*c.lua_State) callconv(.c) c_int {
    const msg = c.lua_tolstring(L, 1, null);
    const m: [*c]const u8 = if (msg != null) msg else "(non-string error)";
    c.luaL_traceback(L, L, m, 1);
    return 1;
}

// Call the function on top of the stack (with `nargs` beneath it) under the traceback handler.
fn callProtected(L: ?*c.lua_State, nargs: c_int, nresults: c_int) c_int {
    const base = c.lua_gettop(L) - nargs; // the function's index
    c.lua_pushcclosurek(L, &tracebackHandler, "traceback", 0, null);
    c.lua_insert(L, base); // move the handler below the function + args
    const rc = c.lua_pcall(L, nargs, nresults, base);
    c.lua_remove(L, base); // drop the handler
    return rc;
}

// Report a Lua error (message on top) as `luau: <msg>` and pop it.
fn reportError(L: ?*c.lua_State) void {
    const msg = c.lua_tolstring(L, -1, null);
    eprint("luau: ");
    if (msg != null) eprint(std.mem.span(msg)) else eprint("(unknown error)");
    eprint("\n");
    c.lua_settop(L, -2); // pop
}

// Set global `arg`: arg[0] = arg0, arg[1..] = operands; also push them as varargs.
fn setArgTable(L: ?*c.lua_State, arg0: [*:0]const u8, operands: [][*:0]u8) void {
    c.lua_createtable(L, @intCast(operands.len), 0);
    _ = c.lua_pushstring(L, arg0);
    c.lua_rawseti(L, -2, 0);
    for (operands, 0..) |op, i| {
        _ = c.lua_pushstring(L, op);
        c.lua_rawseti(L, -2, @intCast(i + 1));
    }
    c.lua_setfield(L, c.LUA_GLOBALSINDEX, "arg");
}

fn pushVarargs(L: ?*c.lua_State, operands: [][*:0]u8) c_int {
    for (operands) |op| _ = c.lua_pushstring(L, op);
    return @intCast(operands.len);
}

fn runSource(L: ?*c.lua_State, chunkname: [*:0]const u8, src: [*]const u8, len: usize, operands: [][*:0]u8) c_int {
    if (loadChunk(L, chunkname, src, len) != 0) {
        reportError(L);
        return EXIT_USAGE;
    }
    const nargs = pushVarargs(L, operands);
    if (callProtected(L, nargs, 0) != 0) {
        reportError(L);
        return EXIT_RUNTIME;
    }
    return EXIT_OK;
}

// Line-buffer stdout so Luau's print() (fwrite, no flush) reaches the capture pipe per line, not only
// at exit — and so output survives if the script later traps (cf. luau_cli.cpp).
extern var stdout: ?*anyopaque;
extern fn setvbuf(stream: ?*anyopaque, buf: ?[*]u8, mode: c_int, size: usize) c_int;

// wasi-libc's _start calls __main_argc_argv; its argv comes from wasi-libc's own __imported_wasi_
// args_get (→ the adapter → mc), so our code needs no direct wasi args import. (std.os.argv was
// removed in 0.16 and std.process.Args needs the Io-threaded global.)
// `luau --check FILE…` runs the type checker — it spawns /bin/luau-analyze with the operands and
// forwards its exit (the engine is a separate binary; this is the ergonomic front door, like tsc).
fn runAnalyze(operands: [][*:0]u8) c_int {
    var blob: [8192]u8 = undefined;
    var off: usize = 0;
    const prog = "luau-analyze";
    @memcpy(blob[0..prog.len], prog);
    off = prog.len;
    blob[off] = 0;
    off += 1;
    for (operands) |op| {
        const s = std.mem.span(op);
        if (off + s.len + 1 > blob.len) return EXIT_USAGE;
        @memcpy(blob[off .. off + s.len], s);
        off += s.len;
        blob[off] = 0;
        off += 1;
    }
    var pid: u32 = 0;
    if (mc.mc_sys_spawn(mc.addr(&blob), @intCast(off), 0, 1, 2, 0, mc.addr(&pid)) != 0) {
        eprint("luau: cannot run luau-analyze\n");
        return EXIT_RUNTIME;
    }
    var status: u32 = 0;
    var got: u32 = 0;
    _ = mc.mc_sys_waitpid(@intCast(pid), 0, mc.addr(&status), mc.addr(&got));
    return @intCast(@as(i32, @bitCast(status)) & 0xff);
}

export fn __main_argc_argv(argc: c_int, c_argv: [*][*:0]u8) c_int {
    const argv = c_argv[0..@intCast(argc)];
    _ = setvbuf(stdout, null, 1, 4096); // _IOLBF

    if (argv.len >= 2 and std.mem.eql(u8, std.mem.span(argv[1]), "--version")) {
        writeFd(1, kVersion ++ "\n");
        return EXIT_OK;
    }
    if (argv.len >= 2 and std.mem.eql(u8, std.mem.span(argv[1]), "--check")) {
        return runAnalyze(argv[2..]);
    }

    const L = newState();
    defer c.lua_close(L);

    if (argv.len >= 3 and std.mem.eql(u8, std.mem.span(argv[1]), "-e")) {
        const code = std.mem.span(argv[2]);
        setArgTable(L, "-e", argv[3..]);
        return runSource(L, "=(command line)", code.ptr, code.len, argv[3..]);
    } else if (argv.len >= 2 and !std.mem.eql(u8, std.mem.span(argv[1]), "-")) {
        // Script file: read it, skip a shebang, run it.
        const src = fs.slurp(argv[1], null) orelse {
            eprint("luau: cannot open ");
            eprint(std.mem.span(argv[1]));
            eprint("\n");
            return EXIT_USAGE;
        };
        var off: usize = 0;
        if (src.len >= 2 and src[0] == '#' and src[1] == '!') {
            off = std.mem.indexOfScalar(u8, src, '\n') orelse src.len;
        }
        setArgTable(L, argv[1], argv[2..]);
        return runSource(L, "=script", src.ptr + off, src.len - off, argv[2..]);
    }

    // Bare `luau` or `luau -`: read the whole of stdin and run it as one chunk (a non-interactive
    // REPL — the testable, pipe-friendly shape; a line-by-line TTY loop can layer on later).
    const code = readStdin() orelse return EXIT_OK; // empty stdin → nothing to do
    defer std.heap.c_allocator.free(code);
    const operands = if (argv.len >= 2) argv[2..] else argv[1..1];
    setArgTable(L, "luau", operands);
    return runSource(L, "=stdin", code.ptr, code.len, operands);
}

// Read all of stdin (fd 0) via the mc syscall. Returns null on empty (or read error).
fn readStdin() ?[]u8 {
    var list: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        var n: u32 = 0;
        if (mc.mc_sys_read(0, mc.addr(&buf), buf.len, mc.addr(&n)) != 0) break;
        if (n == 0) break;
        list.appendSlice(std.heap.c_allocator, buf[0..n]) catch return null;
    }
    if (list.items.len == 0) {
        list.deinit(std.heap.c_allocator);
        return null;
    }
    return list.toOwnedSlice(std.heap.c_allocator) catch null;
}
