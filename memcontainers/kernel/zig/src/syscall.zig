//! syscall.zig - thin dispatcher for generated guest syscalls.
//!
//! Owns: the public syscall facade, the exhaustive Pending dispatcher, and the
//!   compatibility re-exports other kernel modules import through `syscall.<name>`.
//! Invariants: every generated Pending variant has an explicit arm, and each arm
//!   delegates to exactly one domain module without changing syscall behavior.
//! Consumes: generated syscall descriptors, shared primitives, and domain
//!   fulfillment modules.
//! Not here: guest-memory codecs, fd ownership, or domain syscall policy.

const constants = @import("constants_zig");
const mc = @import("mc_zig");
const mem = @import("syscall/mem.zig");
const fd = @import("syscall/fd.zig");
const fsops = @import("syscall/fsops.zig");
const proc = @import("syscall/proc.zig");
const ambient = @import("syscall/ambient.zig");
const net = @import("syscall/net.zig");
const ns = @import("syscall/ns.zig");
const svc = @import("syscall/svc.zig");

pub const Guest = mem.Guest;
pub const GuestMemory = mem.GuestMemory;
pub const Fulfillment = mem.Fulfillment;
pub const SpawnResult = proc.SpawnResult;
pub const ChildFactory = proc.ChildFactory;
pub const errnoFromFs = mem.errnoFromFs;
pub const neg = mem.neg;
pub const termWrite = fsops.termWrite;
pub const openFlags = fsops.openFlags;
pub const wrapFileHandle = fd.wrapFileHandle;
pub const releaseFdValue = fd.releaseFdValue;
pub const cloneFd = fd.cloneFd;
pub const spawnNative = proc.spawnNative;

const finish = mem.finish;

pub fn fulfillOutcome(memory: GuestMemory, guest: *const Guest, pending: mc.Pending) Fulfillment {
    return switch (pending) {
        .Args => |args| finish(proc.fulfillArgs(guest, memory, args)),
        .Write => |args| fsops.fulfillWrite(guest, memory, args),
        .Read => |args| fsops.fulfillRead(guest, memory, args),
        .Open => |args| fsops.fulfillOpen(guest, memory, args),
        .Close => |args| finish(fsops.fulfillClose(guest, args)),
        .Stat => |args| finish(fsops.fulfillStatLike(guest, memory, args.path_ptr, args.path_len, args.ret_stat, true)),
        .Readdir => |args| fsops.fulfillReaddir(guest, memory, args),
        .Mkdir => |args| finish(fsops.fulfillMkdir(guest, memory, args)),
        .Unlink => |args| finish(fsops.fulfillUnlink(guest, memory, args)),
        // TODO(Phase 6): namespace mutation and richer metadata operations.
        .Rename => |args| finish(fsops.fulfillRename(guest, memory, args)),
        .Symlink => |args| finish(fsops.fulfillSymlink(guest, memory, args)),
        .Link => |args| finish(fsops.fulfillLink(guest, memory, args)),
        .Readlink => |args| finish(fsops.fulfillReadlink(guest, memory, args)),
        .Lstat => |args| finish(fsops.fulfillStatLike(guest, memory, args.path_ptr, args.path_len, args.ret_stat, false)),
        .Chmod => |args| finish(fsops.fulfillChmod(guest, memory, args)),
        .Utimes => |args| finish(fsops.fulfillUtimes(guest, memory, args)),
        .Getcwd => |args| finish(fsops.fulfillGetcwd(guest, memory, args)),
        .Chdir => |args| finish(fsops.fulfillChdir(guest, memory, args)),
        .Lseek => |args| finish(fsops.fulfillLseek(guest, memory, args)),
        .Ftruncate => |args| finish(fsops.fulfillFtruncate(guest, args)),
        .Poll => |args| fsops.fulfillPoll(guest, memory, args),
        .Bind => |args| finish(ns.fulfillBind(guest, memory, args)),
        .Unmount => |args| finish(ns.fulfillUnmount(guest, memory, args)),
        .Serve => |args| finish(ns.fulfillServe(guest, memory, args)),
        .ServeRecv => |args| ns.fulfillServeRecv(guest, memory, args),
        .ServeRespond => |args| finish(ns.fulfillServeRespond(guest, memory, args)),
        .SvcServe => |args| finish(svc.fulfillSvcServe(guest, memory, args)),
        .SvcRecv => |args| svc.fulfillSvcRecv(guest, memory, args),
        .SvcRespond => |args| finish(svc.fulfillSvcRespond(guest, memory, args)),
        .SvcConnect => |args| svc.fulfillSvcConnect(guest, memory, args),
        .SvcCall => |args| finish(svc.fulfillSvcCall(guest, memory, args)),
        .Pipe => |args| finish(fsops.fulfillPipe(guest, memory, args)),
        .Dup => |args| finish(fsops.fulfillDup(guest, memory, args)),
        .Dup2 => |args| finish(fsops.fulfillDup2(guest, args)),
        .Isatty => |args| finish(fsops.fulfillIsatty(guest, memory, args)),
        .Getpid => |args| finish(proc.fulfillGetpid(guest, memory, args)),
        .Getppid => |args| finish(proc.fulfillGetppid(guest, memory, args)),
        .Spawn => |args| proc.fulfillSpawn(guest, memory, args),
        .Waitpid => |args| proc.fulfillWaitpid(guest, memory, args),
        .Nice => |args| proc.fulfillNice(guest, memory, args),
        .Kill => |args| proc.fulfillKill(guest, args),
        .Sigdisp => |args| proc.fulfillSigdisp(guest, args),
        .Setpgid => |args| proc.fulfillSetpgid(guest, args),
        .Tcsetpgrp => |args| proc.fulfillTcsetpgrp(guest, args),
        .HttpGet => |args| finish(net.fulfillHttpGet(guest, memory, args)),
        .HttpRequest => |args| finish(net.fulfillHttpRequest(guest, memory, args)),
        .HttpStatus => |args| net.fulfillHttpStatus(guest, memory, args),
        .WsOpen => |args| finish(net.fulfillWsOpen(guest, memory, args)),
        .HostCall => |args| finish(net.fulfillHostCall(guest, memory, args)),
        .TimeMonotonic => |args| finish(ambient.fulfillTimeMonotonic(guest, memory, args)),
        .TimeRealtime => |args| finish(ambient.fulfillTimeRealtime(guest, memory, args)),
        .SleepMs => |args| proc.fulfillSleepMs(guest, args),
        .Random => |args| finish(ambient.fulfillRandom(guest, memory, args)),
        .AbiVersion => |args| finish(ambient.fulfillAbiVersion(memory, args)),
        .Exit => |args| .{ .Exit = args.code },
        // Pcall/SetThrow are intercepted in the WAMR native bridge (guest.zig rawPcall/rawSetThrow),
        // which runs the nested call and records the throw before a Pending is ever built — so these
        // arms are unreachable in practice. They remain for switch exhaustiveness (mc.Pending has no
        // `else`), failing closed with ENOSYS should the interception ever be bypassed.
        .Pcall, .SetThrow => finish(neg(constants.ENOSYS)),
    };
}

pub fn fulfill(memory: GuestMemory, guest: *const Guest, pending: mc.Pending) i32 {
    return switch (fulfillOutcome(memory, guest, pending)) {
        .Resume => |code| code,
        .Exit => |code| code,
        .Block, .Pending => neg(constants.EAGAIN),
    };
}
