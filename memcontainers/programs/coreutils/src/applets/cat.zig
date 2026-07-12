//! `cat` -- DESIGN.md §1: two paths. No display flags -> verbatim
//! 4096-byte-chunk streaming (bytes/CRLF preserved exactly). Any display flag ->
//! byte-exact transform: 8192-byte reads, one line of carry across operands
//! (unterminated final line joins the next file's first line), lineno/squeeze state
//! also carries across operands. `-n`/`-b`/`-s`/`-E`/`-T`/`-v` plus the composites
//! `-A`=`-vET`, `-e`=`-vE`, `-t`=`-vT`. Missing FILE can't open -> `cat: NAME: reason`
//! to stderr, rc=1, continue; stops quietly (no error) if stdout closes.

const std = @import("std");
const sys = @import("../sys/root.zig");
const textio = @import("../core/textio.zig");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "concatenate files and print on the standard output",
    .synopsis = &.{"cat [OPTION]... [FILE]..."},
    .description =
    \\Writes each FILE to standard output, in the order given; with no FILE (or
    \\FILE is "-"), reads standard input. With no display option, bytes are
    \\streamed through verbatim in fixed-size chunks -- no line-based logic, no
    \\decoding; output is byte-for-byte identical to the concatenated inputs.
    \\
    \\Giving any display option (-n/-b/-s/-E/-T/-v or a composite) switches to a
    \\line-transform path: an input's final unterminated line is joined with
    \\the next FILE's first line, and line-number/blank-run state carries
    \\across FILE operands, so numbering and squeezing behave as if all FILEs
    \\were one stream.
    ,
    .options = &.{
        .{ .flags = "-A, --show-all", .desc = "equivalent to -vET" },
        .{ .flags = "-b, --number-nonblank", .desc = "number nonempty output lines, overrides -n" },
        .{ .flags = "-e", .desc = "equivalent to -vE" },
        .{ .flags = "-E, --show-ends", .desc = "display $ at the end of each line" },
        .{ .flags = "-n, --number", .desc = "number all output lines" },
        .{ .flags = "-s, --squeeze-blank", .desc = "suppress repeated empty output lines" },
        .{ .flags = "-t", .desc = "equivalent to -vT" },
        .{ .flags = "-T, --show-tabs", .desc = "display TAB characters as ^I" },
        .{ .flags = "-v, --show-nonprinting", .desc = "use ^ and M- notation, except for LFD and TAB" },
    },
    .operands = "FILE...   files to concatenate; \"-\" means standard input; with no FILE, reads standard input.",
    .exit = &.{
        .{ .code = 0, .when = "success" },
        .{ .code = 1, .when = "a FILE could not be opened (a diagnostic is printed; remaining files are still processed)" },
        .{ .code = 2, .when = "usage error: an unrecognized option" },
    },
    .deviations = &.{
        "-u is not accepted as a flag (it is a usage error); GNU treats it as a silent no-op kept only for POSIX compatibility.",
        "More than 512 FILE operands: operands beyond the 512th are silently dropped, with no error or diagnostic.",
    },
    .examples = &.{
        .{ .cmd = "cat file1.txt file2.txt > combined.txt", .note = "concatenate two files" },
        .{ .cmd = "cat -n file.txt", .note = "prefix every output line with its line number" },
        .{ .cmd = "printf 'a\\tb\\n' | cat -A", .note = "prints: a^Ib$" },
    },
    .see_also = "tac (reverse line order), tee (duplicate to files), head, wc.",
};

const Flags = struct {
    number: bool = false,
    number_nonblank: bool = false,
    squeeze: bool = false,
    show_ends: bool = false,
    show_tabs: bool = false,
    show_nonprinting: bool = false,

    fn any(f: Flags) bool {
        return f.number or f.number_nonblank or f.squeeze or f.show_ends or f.show_tabs or f.show_nonprinting;
    }
};

pub fn run(ctx: *Ctx) u8 {
    var f = Flags{};
    var file_buf: [512][]const u8 = undefined;
    var file_count: usize = 0;
    var parsing_flags = true;

    var i: usize = 1;
    while (i < ctx.args.len) : (i += 1) {
        const a = ctx.args[i];
        if (parsing_flags and a.len >= 2 and a[0] == '-') {
            if (std.mem.eql(u8, a, "--")) {
                parsing_flags = false;
                continue;
            }
            if (std.mem.eql(u8, a, "--help")) {
                cli.renderHelp(ctx, "cat", help_doc);
                return 0;
            }
            if (std.mem.eql(u8, a, "--version")) {
                ctx.print(ctx.stdout, "cat 0.1.0\n", .{});
                return 0;
            }
            if (a.len >= 2 and a[1] == '-') {
                const name = a[2..];
                if (std.mem.eql(u8, name, "number")) {
                    f.number = true;
                } else if (std.mem.eql(u8, name, "number-nonblank")) {
                    f.number_nonblank = true;
                } else if (std.mem.eql(u8, name, "squeeze-blank")) {
                    f.squeeze = true;
                } else if (std.mem.eql(u8, name, "show-ends")) {
                    f.show_ends = true;
                } else if (std.mem.eql(u8, name, "show-tabs")) {
                    f.show_tabs = true;
                } else if (std.mem.eql(u8, name, "show-nonprinting")) {
                    f.show_nonprinting = true;
                } else if (std.mem.eql(u8, name, "show-all")) {
                    f.show_nonprinting = true;
                    f.show_ends = true;
                    f.show_tabs = true;
                } else {
                    ctx.errPrint("cat: unrecognized option '{s}'\n", .{a});
                    return 2;
                }
                continue;
            }
            for (a[1..]) |c| {
                switch (c) {
                    'n' => f.number = true,
                    'b' => f.number_nonblank = true,
                    's' => f.squeeze = true,
                    'E' => f.show_ends = true,
                    'T' => f.show_tabs = true,
                    'v' => f.show_nonprinting = true,
                    'A' => {
                        f.show_nonprinting = true;
                        f.show_ends = true;
                        f.show_tabs = true;
                    },
                    'e' => {
                        f.show_nonprinting = true;
                        f.show_ends = true;
                    },
                    't' => {
                        f.show_nonprinting = true;
                        f.show_tabs = true;
                    },
                    else => {
                        ctx.errPrint("cat: invalid option -- '{c}'\n", .{c});
                        return 2;
                    },
                }
            }
            continue;
        }
        if (file_count < file_buf.len) {
            file_buf[file_count] = a;
            file_count += 1;
        }
    }
    const files = file_buf[0..file_count];

    if (!f.any()) return catVerbatim(ctx, files);
    return catTransform(ctx, files, f);
}

// ---------------------------------------------------------------- verbatim path

fn catVerbatim(ctx: *Ctx, files: []const []const u8) u8 {
    var rc: u8 = 0;
    var buf: [4096]u8 = undefined;
    if (files.len == 0) {
        _ = copyLoop(ctx, ctx.stdin, &buf);
        return rc;
    }
    for (files) |file| {
        const op = textio.openOperand(ctx, "cat", file) orelse {
            rc = 1;
            continue;
        };
        defer op.deinit();
        if (copyLoop(ctx, op.fd, &buf)) return rc;
    }
    return rc;
}

fn copyLoop(ctx: *Ctx, fd: sys.Fd, buf: []u8) bool {
    while (true) {
        const n = sys.read(fd, buf) catch return true;
        if (n == 0) return false;
        ctx.outWrite(buf[0..n]) catch return true;
    }
}

// ---------------------------------------------------------------- transform path

const State = struct {
    lineno: u32 = 1,
    at_bol: bool = true,
    prev_line_blank: bool = false,
};

fn visLow(out: *textio.BufOut, b: u8) sys.Error!void {
    if (b == 127) {
        try out.extend("^?");
    } else if (b < 32) {
        try out.push('^');
        try out.push(b + 64);
    } else {
        try out.push(b);
    }
}

fn emitContentByte(out: *textio.BufOut, f: Flags, b: u8) sys.Error!void {
    if (f.show_tabs and b == '\t') {
        try out.extend("^I");
        return;
    }
    if (!f.show_nonprinting) {
        try out.push(b);
        return;
    }
    if (b == '\t') {
        try out.push(b);
        return;
    }
    if (b >= 128) {
        try out.push('M');
        try out.push('-');
        try visLow(out, b - 128);
    } else {
        try visLow(out, b);
    }
}

fn emitLineNo(out: *textio.BufOut, n: u32) sys.Error!void {
    var digits: [10]u8 = undefined;
    var len: usize = 0;
    var v = n;
    if (v == 0) {
        digits[0] = '0';
        len = 1;
    } else {
        while (v != 0) {
            digits[len] = '0' + @as(u8, @intCast(v % 10));
            v /= 10;
            len += 1;
        }
    }
    var buf: [10]u8 = undefined;
    for (0..len) |k| buf[k] = digits[len - 1 - k];
    var pad: usize = if (len < 6) 6 - len else 0;
    while (pad > 0) : (pad -= 1) try out.push(' ');
    try out.extend(buf[0..len]);
    try out.push('\t');
}

fn onByte(out: *textio.BufOut, f: Flags, st: *State, b: u8) sys.Error!void {
    if (st.at_bol) {
        if (b == '\n') {
            const skip = f.squeeze and st.prev_line_blank;
            if (!skip) {
                if (f.number and !f.number_nonblank) {
                    try emitLineNo(out, st.lineno);
                    st.lineno += 1;
                }
                if (f.show_ends) try out.push('$');
                try out.push('\n');
            }
            st.prev_line_blank = true;
            return;
        }
        if (f.number or f.number_nonblank) {
            try emitLineNo(out, st.lineno);
            st.lineno += 1;
        }
        st.at_bol = false;
        st.prev_line_blank = false;
        try emitContentByte(out, f, b);
        return;
    }
    if (b == '\n') {
        if (f.show_ends) try out.push('$');
        try out.push('\n');
        st.at_bol = true;
        return;
    }
    try emitContentByte(out, f, b);
}

fn feedFd(out: *textio.BufOut, f: Flags, st: *State, fd: sys.Fd, buf: []u8) bool {
    while (true) {
        const n = sys.read(fd, buf) catch return true;
        if (n == 0) return false;
        for (buf[0..n]) |b| {
            onByte(out, f, st, b) catch return true;
        }
    }
}

fn catTransform(ctx: *Ctx, files: []const []const u8, f: Flags) u8 {
    var out = textio.BufOut.init(ctx.stdout);
    var st = State{};
    var rc: u8 = 0;
    var buf: [8192]u8 = undefined;

    if (files.len == 0) {
        _ = feedFd(&out, f, &st, ctx.stdin, &buf);
    } else {
        for (files) |file| {
            const op = textio.openOperand(ctx, "cat", file) orelse {
                rc = 1;
                continue;
            };
            defer op.deinit();
            if (feedFd(&out, f, &st, op.fd, &buf)) break;
        }
    }
    out.finish() catch {};
    return rc;
}
