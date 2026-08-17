//! Shell builtin registry.
//!
//! Only commands that must run in the shell process live here: special
//! POSIX builtins, job control, and AgentOS-specific `umount`/`bind`.
//! Utility twins (`echo`, `printf`, `pwd`, `true`, `false`, `test`, `[`)
//! ship as `/bin` applets in both the minimal and posix images and are
//! spawned like any other program.

pub const Builtin = enum {
    cd,
    @"export",
    unset,
    exit,
    @"return",
    read,
    set,
    shift,
    colon,
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

/// Canonical spellings exposed by the shell. Keep aliases here as well: this
/// table is both the completion vocabulary and the registry's public surface.
pub const names = [_][]const u8{
    "cd",       "export", "unset", "exit",     "return", "read", "set",
    "shift",    ":",      ".",     "source",   "eval",   "local", "break",
    "continue", "jobs",   "fg",    "bg",       "kill",   "wait", "command",
    "umount",   "bind",
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
    if (eq(name, ":")) return .colon;
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
