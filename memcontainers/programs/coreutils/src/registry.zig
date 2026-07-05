//! The one applet list (DESIGN.md §5.1), the Zig analogue of the Rust `mcbox!` macro.
//! Pairs `registry_data.zig`'s pure name/tier/min_set data with `run` function pointers.
//! The whole 88-name roster is ported: every name in `registry_data` MUST have a real
//! `run` through `wiredRun`. Imports are selected only after
//! the Bazel build options filter the roster, so lower-tier boxes do not link higher-tier
//! syscalls.

const std = @import("std");
const build_options = @import("build_options");
const data = @import("registry_data.zig");
const Ctx = @import("ctx.zig").Ctx;

pub const Tier = data.Tier;

pub const Applet = struct {
    name: []const u8,
    tier: Tier,
    min_set: bool = false,
    run: *const fn (*Ctx) u8,
};

fn wiredRun(comptime name: []const u8) *const fn (*Ctx) u8 {
    if (comptime std.mem.eql(u8, name, "true")) return @import("applets/true.zig").run;
    if (comptime std.mem.eql(u8, name, "false")) return @import("applets/false.zig").run;
    if (comptime std.mem.eql(u8, name, "echo")) return @import("applets/echo.zig").run;
    if (comptime std.mem.eql(u8, name, "yes")) return @import("applets/yes.zig").run;
    if (comptime std.mem.eql(u8, name, "clear")) return @import("applets/clear.zig").run;
    if (comptime std.mem.eql(u8, name, "basename")) return @import("applets/basename.zig").run;
    if (comptime std.mem.eql(u8, name, "dirname")) return @import("applets/dirname.zig").run;
    if (comptime std.mem.eql(u8, name, "cat")) return @import("applets/cat.zig").run;
    if (comptime std.mem.eql(u8, name, "printenv")) return @import("applets/printenv.zig").run;
    if (comptime std.mem.eql(u8, name, "pwd")) return @import("applets/pwd.zig").run;
    if (comptime std.mem.eql(u8, name, "readlink")) return @import("applets/readlink.zig").run;
    if (comptime std.mem.eql(u8, name, "realpath")) return @import("applets/realpath.zig").run;
    if (comptime std.mem.eql(u8, name, "sleep")) return @import("applets/sleep.zig").run;
    if (comptime std.mem.eql(u8, name, "stat")) return @import("applets/stat.zig").run;
    if (comptime std.mem.eql(u8, name, "test")) return @import("applets/test.zig").run;
    if (comptime std.mem.eql(u8, name, "[")) return @import("applets/test.zig").run;
    if (comptime std.mem.eql(u8, name, "tree")) return @import("applets/tree.zig").run;
    if (comptime std.mem.eql(u8, name, "which")) return @import("applets/which.zig").run;
    if (comptime std.mem.eql(u8, name, "rev")) return @import("applets/rev.zig").run;
    if (comptime std.mem.eql(u8, name, "head")) return @import("applets/head.zig").run;
    if (comptime std.mem.eql(u8, name, "wc")) return @import("applets/wc.zig").run;
    if (comptime std.mem.eql(u8, name, "nl")) return @import("applets/nl.zig").run;
    if (comptime std.mem.eql(u8, name, "fold")) return @import("applets/fold.zig").run;
    if (comptime std.mem.eql(u8, name, "cut")) return @import("applets/cut.zig").run;
    if (comptime std.mem.eql(u8, name, "tac")) return @import("applets/tac.zig").run;
    if (comptime std.mem.eql(u8, name, "tail")) return @import("applets/tail.zig").run;
    if (comptime std.mem.eql(u8, name, "uniq")) return @import("applets/uniq.zig").run;
    if (comptime std.mem.eql(u8, name, "chmod")) return @import("applets/chmod.zig").run;
    if (comptime std.mem.eql(u8, name, "cp")) return @import("applets/cp.zig").run;
    if (comptime std.mem.eql(u8, name, "ln")) return @import("applets/ln.zig").run;
    if (comptime std.mem.eql(u8, name, "mkdir")) return @import("applets/mkdir.zig").run;
    if (comptime std.mem.eql(u8, name, "mv")) return @import("applets/mv.zig").run;
    if (comptime std.mem.eql(u8, name, "rm")) return @import("applets/rm.zig").run;
    if (comptime std.mem.eql(u8, name, "rmdir")) return @import("applets/rmdir.zig").run;
    if (comptime std.mem.eql(u8, name, "tee")) return @import("applets/tee.zig").run;
    if (comptime std.mem.eql(u8, name, "touch")) return @import("applets/touch.zig").run;
    if (comptime std.mem.eql(u8, name, "truncate")) return @import("applets/truncate.zig").run;
    if (comptime std.mem.eql(u8, name, "kill")) return @import("applets/kill.zig").run;
    if (comptime std.mem.eql(u8, name, "printf")) return @import("applets/printf.zig").run;
    if (comptime std.mem.eql(u8, name, "seq")) return @import("applets/seq.zig").run;
    if (comptime std.mem.eql(u8, name, "tr")) return @import("applets/tr.zig").run;
    if (comptime std.mem.eql(u8, name, "ls")) return @import("applets/ls.zig").run;
    if (comptime std.mem.eql(u8, name, "env")) return @import("applets/env.zig").run;
    if (comptime std.mem.eql(u8, name, "nice")) return @import("applets/nice.zig").run;
    if (comptime std.mem.eql(u8, name, "nohup")) return @import("applets/nohup.zig").run;
    if (comptime std.mem.eql(u8, name, "time")) return @import("applets/time.zig").run;
    if (comptime std.mem.eql(u8, name, "timeout")) return @import("applets/timeout.zig").run;
    if (comptime std.mem.eql(u8, name, "xargs")) return @import("applets/xargs.zig").run;
    if (comptime std.mem.eql(u8, name, "grep")) return @import("applets/grep.zig").run;
    if (comptime std.mem.eql(u8, name, "find")) return @import("applets/find.zig").run;
    if (comptime std.mem.eql(u8, name, "sort")) return @import("applets/sort.zig").run;
    if (comptime std.mem.eql(u8, name, "diff")) return @import("applets/diff.zig").run;
    if (comptime std.mem.eql(u8, name, "file")) return @import("applets/file.zig").run;
    if (comptime std.mem.eql(u8, name, "gzip")) return @import("applets/gzip.zig").run;
    if (comptime std.mem.eql(u8, name, "tar")) return @import("applets/tar.zig").run;
    if (comptime std.mem.eql(u8, name, "zip")) return @import("applets/zip.zig").run;
    if (comptime std.mem.eql(u8, name, "unzip")) return @import("applets/unzip.zig").run;
    if (comptime std.mem.eql(u8, name, "comm")) return @import("applets/comm.zig").run;
    if (comptime std.mem.eql(u8, name, "tsort")) return @import("applets/tsort.zig").run;
    if (comptime std.mem.eql(u8, name, "pathchk")) return @import("applets/pathchk.zig").run;
    if (comptime std.mem.eql(u8, name, "paste")) return @import("applets/paste.zig").run;
    if (comptime std.mem.eql(u8, name, "expand")) return @import("applets/expand.zig").run;
    if (comptime std.mem.eql(u8, name, "unexpand")) return @import("applets/unexpand.zig").run;
    if (comptime std.mem.eql(u8, name, "join")) return @import("applets/join.zig").run;
    if (comptime std.mem.eql(u8, name, "od")) return @import("applets/od.zig").run;
    if (comptime std.mem.eql(u8, name, "numfmt")) return @import("applets/numfmt.zig").run;
    if (comptime std.mem.eql(u8, name, "fmt")) return @import("applets/fmt.zig").run;
    if (comptime std.mem.eql(u8, name, "md5sum")) return @import("applets/hashsum.zig").runMd5;
    if (comptime std.mem.eql(u8, name, "sha1sum")) return @import("applets/hashsum.zig").runSha1;
    if (comptime std.mem.eql(u8, name, "sha256sum")) return @import("applets/hashsum.zig").runSha256;
    if (comptime std.mem.eql(u8, name, "sha512sum")) return @import("applets/hashsum.zig").runSha512;
    if (comptime std.mem.eql(u8, name, "b2sum")) return @import("applets/hashsum.zig").runB2sum;
    if (comptime std.mem.eql(u8, name, "cksum")) return @import("applets/cksum.zig").run;
    if (comptime std.mem.eql(u8, name, "sum")) return @import("applets/sum.zig").run;
    if (comptime std.mem.eql(u8, name, "base32")) return @import("applets/base32.zig").run;
    if (comptime std.mem.eql(u8, name, "base64")) return @import("applets/base64.zig").run;
    if (comptime std.mem.eql(u8, name, "basenc")) return @import("applets/basenc.zig").run;
    if (comptime std.mem.eql(u8, name, "factor")) return @import("applets/factor.zig").run;
    if (comptime std.mem.eql(u8, name, "shuf")) return @import("applets/shuf.zig").run;
    if (comptime std.mem.eql(u8, name, "split")) return @import("applets/split.zig").run;
    if (comptime std.mem.eql(u8, name, "csplit")) return @import("applets/csplit.zig").run;
    if (comptime std.mem.eql(u8, name, "jq")) return @import("applets/jq.zig").run;
    if (comptime std.mem.eql(u8, name, "sed")) return @import("applets/sed.zig").run;
    if (comptime std.mem.eql(u8, name, "awk")) return @import("applets/awk.zig").run;
    if (comptime std.mem.eql(u8, name, "date")) return @import("applets/date.zig").run;
    if (comptime std.mem.eql(u8, name, "fetch")) return @import("applets/fetch.zig").run;
    if (comptime std.mem.eql(u8, name, "wget")) return @import("applets/wget.zig").run;
    if (comptime std.mem.eql(u8, name, "wscat")) return @import("applets/wscat.zig").run;

    // Invariant: every roster name in registry_data has a real `run` in `wired`. If this
    // fires, an applet was added to registry_data but never wired here.
    @compileError("registry_data applet '" ++ name ++ "' has no wired run in registry.zig");
}

fn tierMatches(t: Tier) bool {
    return build_options.all_tiers or std.mem.eql(u8, @tagName(t), build_options.tier);
}

/// Whether applet `a` belongs in this box: tier and set are generated by Bazel, and
/// `exclude` remains available for size/profiling builds.
fn inBox(a: data.AppletData) bool {
    if (!tierMatches(a.tier)) return false;
    if (build_options.set != .full and !a.min_set) return false;
    if (build_options.exclude.len != 0 and std.mem.eql(u8, a.name, build_options.exclude)) return false;
    return true;
}

fn countBox() usize {
    @setEvalBranchQuota(50_000);
    var n: usize = 0;
    for (data.all) |a| {
        if (inBox(a)) n += 1;
    }
    return n;
}

/// The comptime-filtered dispatch table for this box (see `inBox`). Because it is
/// comptime, Zig's lazy analysis never even touches applets excluded from this box -- the
/// dead-code story needs zero tricks (DESIGN.md §5.1).
pub const box: [countBox()]Applet = blk: {
    @setEvalBranchQuota(50_000);
    var arr: [countBox()]Applet = undefined;
    var i: usize = 0;
    for (data.all) |a| {
        if (inBox(a)) {
            arr[i] = .{ .name = a.name, .tier = a.tier, .min_set = a.min_set, .run = wiredRun(a.name) };
            i += 1;
        }
    }
    break :blk arr;
};

pub fn find(name: []const u8) ?Applet {
    for (box) |a| {
        if (std.mem.eql(u8, a.name, name)) return a;
    }
    return null;
}
