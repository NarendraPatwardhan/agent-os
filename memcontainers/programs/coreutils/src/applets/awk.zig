//! `awk` -- a POSIX-subset awk (docs/analysis/applets-a-f.md), matching the awk-rs 0.1.0
//! crate the memcontainers box wrapped. CLI: -F SEP (field separator; glued -FSEP ok),
//! -v VAR=VALUE (repeatable pre-run assignment), -f FILE (repeatable program file), then a
//! PROGRAM operand if no -f, then input FILEs (- = stdin). BEGIN/END run once around all
//! input. Exit 0 ok, 2 on lex/parse/runtime error (`awk: {msg}`).

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;
const textio = @import("../core/textio.zig");
const interp = @import("../engines/awklang/interp.zig");

const help_doc = cli.Help{
    .summary = "pattern scanning and text processing language",
    .synopsis = &.{"awk [-F SEP] [-v VAR=VALUE]... [-f PROGFILE | 'PROGRAM'] [FILE]..."},
    .description =
    \\Runs an AWK PROGRAM (or the concatenation of one or more -f PROGFILEs) over
    \\every input record. A program is a sequence of `pattern { action }` rules:
    \\BEGIN and END run once, before and after all input; every other pattern -- an
    \\expression, a /regex/, a pat1,pat2 range, or the implicit always-true
    \\pattern -- is tested against each record, and its action runs when the
    \\pattern matches. Records default to lines: RS must be a single character
    \\(the default is \n), otherwise the whole input becomes one record. Fields
    \\split on FS: whitespace-run splitting (leading/trailing blanks ignored) for
    \\the default single-space FS, a literal byte for any other single-character
    \\FS, or a regular expression for a multi-character FS.
    \\
    \\The language covers the full expression grammar; control flow (if, while,
    \\for, for-in, do-while, break, continue, next, exit, return); user-defined
    \\functions (scalars by value, arrays by reference); associative and
    \\multidimensional (SUBSEP-joined) arrays; print and printf; and the
    \\builtins length, substr, index, split, sub, gsub, match, sprintf, toupper,
    \\tolower, int, sqrt, sin, cos, exp, log, atan2, rand, and srand. NR, NF,
    \\FNR, FILENAME, SUBSEP, RSTART, and RLENGTH are all live. An `exit [N]`
    \\statement sets the process exit status to N.
    ,
    .options = &.{
        .{ .flags = "-F SEP", .desc = "set the field separator FS (a glued -FSEP form is also accepted)" },
        .{ .flags = "-v VAR=VALUE", .desc = "assign VAR=VALUE before BEGIN runs (repeatable)" },
        .{ .flags = "-f FILE", .desc = "read the program from FILE instead of the command line (repeatable; concatenated)" },
    },
    .operands = "PROGRAM is the AWK source, taken from the first non-option argument unless one or more -f FILEs were given. FILE...   input files, read in order by the main rules; \"-\" means standard input; with none, standard input is read.",
    .exit = &.{
        .{ .code = 0, .when = "success" },
        .{ .code = 2, .when = "a lex/parse error in the program, a runtime error in BEGIN or END, or a usage error (bad option, no program text, an input FILE that could not be opened)" },
    },
    .deviations_from = "awk (POSIX/awk-rs)",
    .deviations = &.{
        "getline in any form (bare, `getline var`, `getline < file`, `cmd | getline`) is accepted syntactically but is always a no-op returning 0 -- no additional input is ever read.",
        "print/printf output redirection (`> file`, `>> file`, `| cmd`) is not supported.",
        "system() and close() are accepted as builtins but always return 0 without effect -- no command runs and no stream closes.",
        "RS must be a single character; an empty RS (paragraph mode) or a multi-character RS makes the whole input one record instead of splitting it.",
        "CONVFMT and OFMT are ordinary variables you can read and set, but number-to-string conversion always uses a fixed rule (integers with |n|<1e15 print with no decimal point; otherwise a %.6f-equivalent with trailing zeros/point trimmed) -- their value is never consulted.",
        "A runtime error in a main (non-BEGIN/END) rule prints \"awk: runtime error\" and moves on to the next record without changing the exit status; only a parse error or a BEGIN/END runtime error sets exit 2.",
        "-F/-v recognize only the literal two-character escapes \\t and \\n; any other backslash sequence in a -F or -v argument passes through verbatim.",
        "length(array) is not supported (it is treated as a string-length call, not an element count); no getline-driven or gawk-specific extensions.",
    },
    .examples = &.{
        .{ .cmd = "awk '{ print $1, $3 }' file.txt", .note = "print the 1st and 3rd whitespace-separated fields" },
        .{ .cmd = "awk -F: '{ print $1 }' /etc/passwd", .note = "colon-separated fields" },
        .{ .cmd = "awk 'BEGIN { for (i=1;i<=3;i++) print i }'", .note = "a program with no input" },
    },
    .see_also = "sed (line-oriented editing), grep (search only), cut (fixed field/byte selection).",
};

const Out = struct {
    ctx: *Ctx,
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn write(ctx_ptr: *anyopaque, bytes: []const u8) void {
        const self: *Out = @ptrCast(@alignCast(ctx_ptr));
        self.buf.appendSlice(self.ctx.gpa, bytes) catch {};
        if (self.buf.items.len >= 1 << 15) self.flush();
    }
    fn flush(self: *Out) void {
        if (self.buf.items.len != 0) {
            sys.writeAll(self.ctx.stdout, self.buf.items) catch {};
            self.buf.clearRetainingCapacity();
        }
    }
};

pub fn run(ctx: *Ctx) u8 {
    var fs_sep: ?[]const u8 = null;
    var assigns: std.ArrayListUnmanaged([]const u8) = .empty;
    var prog_files: std.ArrayListUnmanaged([]const u8) = .empty;
    var operands: std.ArrayListUnmanaged([]const u8) = .empty;

    var i: usize = 1;
    while (i < ctx.args.len) : (i += 1) {
        const a = ctx.args[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        } else if (std.mem.eql(u8, a, "--help")) {
            cli.renderHelp(ctx, "awk", help_doc);
            return 0;
        } else if (std.mem.eql(u8, a, "-F")) {
            i += 1;
            if (i >= ctx.args.len) return err(ctx, "option requires an argument -- 'F'");
            fs_sep = a_unescape(ctx, ctx.args[i]);
        } else if (a.len > 2 and std.mem.startsWith(u8, a, "-F")) {
            fs_sep = a_unescape(ctx, a[2..]);
        } else if (std.mem.eql(u8, a, "-v")) {
            i += 1;
            if (i >= ctx.args.len) return err(ctx, "option requires an argument -- 'v'");
            assigns.append(ctx.gpa, ctx.args[i]) catch return 2;
        } else if (a.len > 2 and std.mem.startsWith(u8, a, "-v")) {
            assigns.append(ctx.gpa, a[2..]) catch return 2;
        } else if (std.mem.eql(u8, a, "-f")) {
            i += 1;
            if (i >= ctx.args.len) return err(ctx, "option requires an argument -- 'f'");
            prog_files.append(ctx.gpa, ctx.args[i]) catch return 2;
        } else if (a.len > 2 and std.mem.startsWith(u8, a, "-f")) {
            prog_files.append(ctx.gpa, a[2..]) catch return 2;
        } else if (a.len > 1 and a[0] == '-' and !std.mem.eql(u8, a, "-")) {
            return err(ctx, "unrecognized option");
        } else {
            break;
        }
    }

    // Assemble the program source.
    var src: []const u8 = "";
    if (prog_files.items.len != 0) {
        var joined: std.ArrayListUnmanaged(u8) = .empty;
        for (prog_files.items) |pf| {
            const fd = sys.open(pf, .{ .read = true }) catch return err(ctx, "can't open program file");
            const data = textio.readAll(ctx.gpa, fd) catch return 2;
            sys.close(fd);
            joined.appendSlice(ctx.gpa, data) catch return 2;
            joined.append(ctx.gpa, '\n') catch return 2;
        }
        src = joined.items;
    } else {
        if (i >= ctx.args.len) return err(ctx, "no program text");
        src = ctx.args[i];
        i += 1;
    }
    // Remaining args are input files.
    while (i < ctx.args.len) : (i += 1) operands.append(ctx.gpa, ctx.args[i]) catch return 2;

    const program = interp.parse(ctx.gpa, src) catch return err(ctx, "syntax error in program");

    var out = Out{ .ctx = ctx };
    var vm = interp.Interp.init(ctx.gpa, program, &out, Out.write) catch return 2;
    if (fs_sep) |f| vm.fs = f;

    // -v assignments (before BEGIN).
    for (assigns.items) |asg| applyAssign(&vm, asg);

    vm.runBegin() catch return runtimeErr(ctx, &out);
    if (vm.signal_is_exit()) {
        vm.runEnd() catch return runtimeErr(ctx, &out);
        out.flush();
        return vm.exit_code;
    }

    if (vm.hasMainOrEnd()) {
        var rc: u8 = 0;
        if (operands.items.len == 0) {
            rc = streamFd(ctx, &vm, sys.STDIN, "");
        } else {
            for (operands.items) |op| {
                if (vm.signal_is_exit()) break;
                if (std.mem.eql(u8, op, "-")) {
                    vm.filename = "";
                    vm.fnr = 0;
                    if (streamFd(ctx, &vm, sys.STDIN, "") != 0) rc = 1;
                } else {
                    const fd = sys.open(op, .{ .read = true }) catch {
                        ctx.errPrint("awk: can't open file {s}\n", .{op});
                        rc = 2;
                        continue;
                    };
                    vm.filename = op;
                    vm.fnr = 0;
                    if (streamFd(ctx, &vm, fd, op) != 0) rc = 1;
                    sys.close(fd);
                }
            }
        }
    }

    vm.runEnd() catch return runtimeErr(ctx, &out);
    out.flush();
    return vm.exit_code;
}

fn streamFd(ctx: *Ctx, vm: *interp.Interp, fd: sys.Fd, name: []const u8) u8 {
    _ = name;
    const data = textio.readAll(ctx.gpa, fd) catch return 1;
    // Split into records by RS (single char; default '\n').
    const rs = vm.rs;
    if (rs.len == 1) {
        var it = std.mem.splitScalar(u8, data, rs[0]);
        var pending: ?[]const u8 = null;
        while (it.next()) |rec| {
            if (pending) |p| {
                runRec(ctx, vm, p);
                if (vm.signal_is_exit()) return 0;
            }
            pending = rec;
        }
        // A trailing separator yields a final empty piece; drop it (GNU: no empty last record).
        if (pending) |p| {
            if (p.len != 0) runRec(ctx, vm, p);
        }
    } else {
        // Paragraph/other RS deferred: treat whole input as one record.
        runRec(ctx, vm, data);
    }
    return 0;
}

fn runRec(ctx: *Ctx, vm: *interp.Interp, rec: []const u8) void {
    vm.runRecord(rec) catch {
        ctx.errPrint("awk: runtime error\n", .{});
    };
}

fn applyAssign(vm: *interp.Interp, asg: []const u8) void {
    const eq = std.mem.indexOfScalar(u8, asg, '=') orelse return;
    const name = asg[0..eq];
    const val = asg[eq + 1 ..];
    const value = @import("../engines/awklang/value.zig");
    vm.setVarPublic(name, value.Value.fromStr(val));
}

fn a_unescape(ctx: *Ctx, s: []const u8) []const u8 {
    // -F '\t' etc.: interpret a leading backslash-escape.
    if (std.mem.eql(u8, s, "\\t")) return "\t";
    if (std.mem.eql(u8, s, "\\n")) return "\n";
    _ = ctx;
    return s;
}

fn err(ctx: *Ctx, msg: []const u8) u8 {
    ctx.errPrint("awk: {s}\n", .{msg});
    return 2;
}

fn runtimeErr(ctx: *Ctx, out: *Out) u8 {
    out.flush();
    ctx.errPrint("awk: runtime error\n", .{});
    return 2;
}
