//! Shell builtin registry.

pub const Builtin = enum {
    cd,
    @"export",
    unset,
    exit,
    @"return",
    read,
    set,
    shift,
    @"test",
    colon,
    true_cmd,
    false_cmd,
    echo,
    pwd,
    printf,
    source,
    eval,
    local,
    break_cmd,
    continue_cmd,
    jobs,
    fg,
    bg,
    kill,
    wait,
    command,
    umount,
    bind,
};

pub fn lookup(name: []const u8) ?Builtin {
    if (eq(name, "cd")) return .cd;
    if (eq(name, "export")) return .@"export";
    if (eq(name, "unset")) return .unset;
    if (eq(name, "exit")) return .exit;
    if (eq(name, "return")) return .@"return";
    if (eq(name, "read")) return .read;
    if (eq(name, "set")) return .set;
    if (eq(name, "shift")) return .shift;
    if (eq(name, "test")) return .@"test";
    if (eq(name, "[")) return .@"test";
    if (eq(name, ":")) return .colon;
    if (eq(name, "true")) return .true_cmd;
    if (eq(name, "false")) return .false_cmd;
    if (eq(name, "echo")) return .echo;
    if (eq(name, "pwd")) return .pwd;
    if (eq(name, "printf")) return .printf;
    if (eq(name, ".")) return .source;
    if (eq(name, "source")) return .source;
    if (eq(name, "eval")) return .eval;
    if (eq(name, "local")) return .local;
    if (eq(name, "break")) return .break_cmd;
    if (eq(name, "continue")) return .continue_cmd;
    if (eq(name, "jobs")) return .jobs;
    if (eq(name, "fg")) return .fg;
    if (eq(name, "bg")) return .bg;
    if (eq(name, "kill")) return .kill;
    if (eq(name, "wait")) return .wait;
    if (eq(name, "command")) return .command;
    if (eq(name, "umount")) return .umount;
    if (eq(name, "bind")) return .bind;
    return null;
}

fn eq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}
