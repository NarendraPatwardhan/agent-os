//! console.zig — cooked terminal line discipline.
//!
//! Owns: the line editor, escape-sequence state machine, console backlog flushing,
//!   and committed-line queuing for pid-1 stdin.
//! Invariants: terminal edits are echoed here, while only committed lines enter the
//!   console pipe; all mutable editor state remains rooted in `Kernel`.
//! Consumes: the host stdout bridge, scheduler wakeups, rescue-shell line handoff,
//!   and process-signal delivery.
//! Not here: kernel lifecycle, guest stepping, pipe ownership, or shell startup.

const std = @import("std");
const bridge = @import("bridge.zig");
const rescue = @import("rescue.zig");
const state = @import("state.zig");
const constants = @import("constants_zig");

const HISTORY_CAP: usize = 200;

const EscState = enum {
    normal,
    esc,
    csi,
};

fn termEmit(bytes: []const u8) void {
    if (bytes.len != 0) bridge.mc_stdout_write(bytes.ptr, bytes.len);
}

fn termBs(n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) termEmit("\x08");
}

fn termErase(n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) termEmit("\x08 \x08");
}

pub const LineEditor = struct {
    line: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    history: std.ArrayList([]u8) = .empty,
    hist_nav: ?usize = null,
    stash: std.ArrayList(u8) = .empty,
    esc: EscState = .normal,
    param: u16 = 0,

    fn insert(self: *LineEditor, gpa: std.mem.Allocator, b: u8) void {
        const old_len = self.line.items.len;
        self.line.append(gpa, b) catch @panic("OOM");
        if (self.cursor < old_len) {
            std.mem.copyBackwards(
                u8,
                self.line.items[self.cursor + 1 .. old_len + 1],
                self.line.items[self.cursor..old_len],
            );
        }
        self.line.items[self.cursor] = b;
        termEmit(self.line.items[self.cursor..]);
        termBs(self.line.items.len - self.cursor - 1);
        self.cursor += 1;
    }

    fn removeAt(self: *LineEditor, idx: usize) void {
        const old_len = self.line.items.len;
        if (idx + 1 < old_len) {
            std.mem.copyForwards(u8, self.line.items[idx .. old_len - 1], self.line.items[idx + 1 .. old_len]);
        }
        self.line.items.len = old_len - 1;
    }

    fn backspace(self: *LineEditor) void {
        if (self.cursor == 0) return;
        self.cursor -= 1;
        self.removeAt(self.cursor);
        termBs(1);
        termEmit(self.line.items[self.cursor..]);
        termEmit(" ");
        termBs(self.line.items.len - self.cursor + 1);
    }

    fn deleteFwd(self: *LineEditor) void {
        if (self.cursor >= self.line.items.len) return;
        self.removeAt(self.cursor);
        termEmit(self.line.items[self.cursor..]);
        termEmit(" ");
        termBs(self.line.items.len - self.cursor + 1);
    }

    fn left(self: *LineEditor) void {
        if (self.cursor == 0) return;
        self.cursor -= 1;
        termBs(1);
    }

    fn right(self: *LineEditor) void {
        if (self.cursor >= self.line.items.len) return;
        termEmit(self.line.items[self.cursor .. self.cursor + 1]);
        self.cursor += 1;
    }

    fn home(self: *LineEditor) void {
        termBs(self.cursor);
        self.cursor = 0;
    }

    fn end(self: *LineEditor) void {
        termEmit(self.line.items[self.cursor..]);
        self.cursor = self.line.items.len;
    }

    fn replaceLine(self: *LineEditor, gpa: std.mem.Allocator, next: []const u8) void {
        termEmit(self.line.items[self.cursor..]);
        termErase(self.line.items.len);
        self.line.clearRetainingCapacity();
        self.line.appendSlice(gpa, next) catch @panic("OOM");
        termEmit(self.line.items);
        self.cursor = self.line.items.len;
    }

    fn historyPrev(self: *LineEditor, gpa: std.mem.Allocator) void {
        if (self.history.items.len == 0) return;
        const j = self.hist_nav orelse blk: {
            self.stash.clearRetainingCapacity();
            self.stash.appendSlice(gpa, self.line.items) catch @panic("OOM");
            break :blk self.history.items.len;
        };
        if (j == 0) return;
        self.hist_nav = j - 1;
        self.replaceLine(gpa, self.history.items[j - 1]);
    }

    fn historyNext(self: *LineEditor, gpa: std.mem.Allocator) void {
        const j = self.hist_nav orelse return;
        const n = self.history.items.len;
        if (j >= n) return;
        if (j + 1 == n) {
            self.hist_nav = null;
            self.replaceLine(gpa, self.stash.items);
            self.stash.clearRetainingCapacity();
        } else {
            self.hist_nav = j + 1;
            self.replaceLine(gpa, self.history.items[j + 1]);
        }
    }

    fn resetLine(self: *LineEditor) void {
        self.line.clearRetainingCapacity();
        self.cursor = 0;
        self.hist_nav = null;
        self.stash.clearRetainingCapacity();
        self.esc = .normal;
        self.param = 0;
    }

    fn commit(self: *LineEditor, gpa: std.mem.Allocator) void {
        if (self.line.items.len != 0) {
            const duplicate = if (self.history.items.len == 0)
                false
            else
                std.mem.eql(u8, self.history.items[self.history.items.len - 1], self.line.items);
            if (!duplicate) {
                const owned = gpa.dupe(u8, self.line.items) catch @panic("OOM");
                self.history.append(gpa, owned) catch @panic("OOM");
                if (self.history.items.len > HISTORY_CAP) {
                    const old = self.history.orderedRemove(0);
                    gpa.free(old);
                }
            }
        }
        self.resetLine();
    }
};

pub fn flushConsole(k: *state.Kernel) bool {
    const cpipe = k.console_pipe orelse return false;
    if (cpipe.isWriteClosed()) return false;
    var wrote = false;
    while (k.console_pending.items.len != 0) {
        const n = cpipe.write(k.console_pending.items);
        if (n == 0) break;
        wrote = true;
        const remaining = k.console_pending.items.len - n;
        if (remaining != 0) {
            std.mem.copyForwards(u8, k.console_pending.items[0..remaining], k.console_pending.items[n..]);
        }
        k.console_pending.items.len = remaining;
    }
    if (wrote) k.sched.checkUnblocked();
    return wrote;
}

pub fn queueConsoleLine(k: *state.Kernel, line: []const u8) void {
    k.console_pending.appendSlice(k.gpa, line) catch @panic("OOM");
    k.console_pending.append(k.gpa, '\n') catch @panic("OOM");
    _ = flushConsole(k);
}

pub fn feedConsoleByte(k: *state.Kernel, byte: u8) void {
    const ed = &k.line_editor;

    switch (ed.esc) {
        .esc => {
            ed.esc = if (byte == '[' or byte == 'O') blk: {
                ed.param = 0;
                break :blk .csi;
            } else .normal;
            return;
        },
        .csi => {
            if (byte >= '0' and byte <= '9') {
                ed.param = (ed.param *| 10) +| @as(u16, @intCast(byte - '0'));
                return;
            }
            ed.esc = .normal;
            switch (byte) {
                'A' => ed.historyPrev(k.gpa),
                'B' => ed.historyNext(k.gpa),
                'C' => ed.right(),
                'D' => ed.left(),
                'H' => ed.home(),
                'F' => ed.end(),
                '~' => switch (ed.param) {
                    1, 7 => ed.home(),
                    4, 8 => ed.end(),
                    3 => ed.deleteFwd(),
                    else => {},
                },
                else => {},
            }
            return;
        },
        .normal => {},
    }

    if (byte == 0x1b) {
        ed.esc = .esc;
    } else if (byte == 0x7f or byte == 0x08) {
        ed.backspace();
    } else if (byte == 0x01) {
        ed.home();
    } else if (byte == 0x05) {
        ed.end();
    } else if (byte == 0x04) {
        if (k.rescue_active) {
            return;
        } else if (ed.line.items.len == 0) {
            if (k.console_pipe) |cpipe| cpipe.closeWrite();
            k.sched.checkUnblocked();
        }
    } else if (byte == 0x03) {
        termEmit("^C\r\n");
        ed.resetLine();
        if (k.rescue_active) {
            rescue.prompt();
        } else {
            k.sched.signalGroup(k.sched.foreground_pgid, constants.SIGINT);
        }
    } else if (byte == 0x1a) {
        termEmit("^Z\r\n");
        ed.resetLine();
        if (k.rescue_active) {
            rescue.prompt();
        } else {
            k.sched.signalGroup(k.sched.foreground_pgid, constants.SIGTSTP);
        }
    } else if (byte == '\n' or byte == '\r') {
        termEmit("\r\n");
        if (k.rescue_active) {
            rescue.submitLine(k, ed.line.items);
        } else {
            queueConsoleLine(k, ed.line.items);
        }
        ed.commit(k.gpa);
    } else if ((byte >= '!' and byte <= '~') or byte == ' ') {
        ed.insert(k.gpa, byte);
    }
}
