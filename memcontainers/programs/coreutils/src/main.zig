//! /bin mcbox — Zig coreutils multicall over the mc sysroot.

const std = @import("std");
const agent_sys = @import("sys");
const sys = @import("sys/root.zig");
const Ctx = @import("ctx.zig").Ctx;
const registry = @import("registry.zig");

pub const panic = std.debug.FullPanic(struct {
    pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        _ = first_trace_addr;
        sys.writeAll(sys.STDERR, "mcbox: panic: ") catch {};
        sys.writeAll(sys.STDERR, msg) catch {};
        sys.writeAll(sys.STDERR, "\n") catch {};
        sys.exit(127);
    }
}.panic);

fn basenameOf(path: []const u8) []const u8 {
    var idx: usize = 0;
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/' or path[i] == '\\') {
            idx = i + 1;
            break;
        }
    }
    return path[idx..];
}

const applet_names_joined: []const u8 = blk: {
    var buf: []const u8 = "";
    for (registry.box, 0..) |a, i| {
        if (i != 0) buf = buf ++ ", ";
        buf = buf ++ a.name;
    }
    break :blk buf;
};

var arena_state: std.heap.ArenaAllocator = undefined;

fn dispatch() noreturn {
    sys.init();
    arena_state = std.heap.ArenaAllocator.init(agent_sys.wasm_allocator);
    const gpa = arena_state.allocator();
    const argv = sys.argsAlloc(gpa) catch &.{};

    var ctx = Ctx{
        .args = argv,
        .gpa = gpa,
        .stdin = sys.STDIN,
        .stdout = sys.STDOUT,
        .stderr = sys.STDERR,
    };

    if (argv.len == 0) sys.exit(2);

    const bundle_name = basenameOf(argv[0]);
    if (registry.find(bundle_name)) |applet| {
        sys.exit(applet.run(&ctx));
    }

    if (argv.len >= 2) {
        const name = basenameOf(argv[1]);
        if (registry.find(name)) |applet| {
            ctx.args = argv[1..];
            sys.exit(applet.run(&ctx));
        }
        ctx.errPrint("{s}: applet not in this box\n", .{name});
        sys.exit(127);
    }

    ctx.errPrint("mcbox: usage: <applet> [args...]  (applets: {s})\n", .{applet_names_joined});
    sys.exit(2);
}

pub export fn _start() void {
    dispatch();
}
