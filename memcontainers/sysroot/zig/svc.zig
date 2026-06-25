//! svc.zig — resident-service serve-loop scaffolding for the Zig lane. Wraps the svc_serve/recv/
//! respond syscalls and the kernel's `[session:u32][req_id:u32][blob_len:u32][blob]` request envelope,
//! so a service binary writes only its DISPATCH: `serve` once, then loop `recv` → handle warm state →
//! `respond`. The client side (connect/call) is each tool's own (a Lua binding for luau, a CLI for a
//! service). Shared by the Zig services (sqlite today); a one-binary/two-modes service's `_start`
//! selects the serve loop vs the CLI by argv. SYSTEMS.md
const std = @import("std");
const mc = @import("mc");
const constants = @import("constants_zig"); // the projected contract constants (constants.kdl)

/// The SERVICE-mode argv[1] marker — the projected contract constant (one source: constants.kdl),
/// re-exported so a service's `_start` selects serve-vs-CLI without copying the literal (codex #5).
pub const SERVICE_MARKER = constants.SERVICE_MARKER;

/// `EIO`, re-exported for a service that needs a TRANSPORT-level failure status on `respond` — e.g. a
/// streamed result that errors mid-flight, after partial chunks are already sent and can't be retracted.
pub const EIO = constants.EIO;

/// `EAGAIN`, re-exported: `respond` returns it when the kernel buffer is at the high-water and the client
/// hasn't drained — the server YIELDS the chunk and resumes on the `.drain_ready` event `recv` delivers.
pub const EAGAIN = constants.EAGAIN;

/// Max fds a single call may delegate (mirrors the kernel's `MAX_DELEGATED_HANDLES`).
pub const MAX_HANDLES = 8;

/// What `recv` decoded: a call to answer, or a session-closed tombstone (free that session's own warm
/// state — SYSTEMS.md is silent; the kernel adds the signal, codex #1).
pub const Kind = enum(u8) { call = 0, session_closed = 1, drain_ready = 2, _ };

/// One decoded service inbound. `blob`/`handles` borrow the server's buffers — valid until the next
/// `recv`. A `.session_closed` tombstone carries only `session` (no `req_id`/`blob`/`handles`, no answer).
pub const Request = struct {
    kind: Kind,
    session: u32,
    req_id: u32,
    blob: []const u8,
    handles: []const u32,
};

/// A registered service's serve side: the control fd plus the recv scratch buffer (the caller sizes
/// `buf` for the largest request envelope it will accept).
pub const Server = struct {
    fd: i32,
    buf: []u8,
    /// Scratch for delegated fd numbers, filled by `recv` (mirrors the kernel's `hbuf`). Borrowed by
    /// `Request.handles` until the next `recv`.
    hbuf: [MAX_HANDLES]u32 = undefined,

    /// Register as the server for `name`. The kernel authorizes this ONLY for the task it activated
    /// to serve `name` (the activation grant), so this needs no capability. `error.ServeFailed` if a
    /// live server already holds the name or the caller is not the grant holder.
    pub fn serve(name: []const u8, buf: []u8) !Server {
        var fd: u32 = 0;
        if (mc.mc_sys_svc_serve(mc.addr(name.ptr), @intCast(name.len), mc.addr(&fd)) != 0) {
            return error.ServeFailed;
        }
        return .{ .fd = @intCast(fd), .buf = buf };
    }

    /// Block for the next inbound and decode its envelope
    /// (`[kind][nhandles][session][req_id][blob_len][blob]`). `null` when the channel is closed (no
    /// client will call again) — the serve loop should then exit. A short or self-inconsistent envelope
    /// is skipped rather than mis-decoded. Delegated fd numbers land in `self.hbuf`, borrowed by
    /// `Request.handles`.
    pub fn recv(self: *Server) ?Request {
        while (true) {
            var n: u32 = 0;
            if (mc.mc_sys_svc_recv(self.fd, mc.addr(self.buf.ptr), @intCast(self.buf.len), mc.addr(&self.hbuf), @intCast(self.hbuf.len * 4), mc.addr(&n)) != 0) {
                return null; // channel closed
            }
            if (n < 14) continue;
            const env = self.buf[0..n];
            const nh = env[1];
            const blob_len = std.mem.readInt(u32, env[10..14], .little);
            if (14 + @as(usize, blob_len) > n) continue;
            return .{
                .kind = @enumFromInt(env[0]),
                .session = std.mem.readInt(u32, env[2..6], .little),
                .req_id = std.mem.readInt(u32, env[6..10], .little),
                .blob = env[14 .. 14 + blob_len],
                .handles = self.hbuf[0..nh],
            };
        }
    }

    /// Append a body chunk to call `(session, req_id)`'s answer. `status` 0 = ok (`data` is the body the
    /// client drains); nonzero = a transport errno surfaced to the client's `read`. `last=true` is the
    /// final chunk (the call completes). Returns the raw mc errno: 0 on success; `EAGAIN` when the kernel
    /// buffer is at the high-water (the client hasn't drained — YIELD this chunk and resume on the
    /// `.drain_ready` event `recv` delivers); or another transport errno.
    pub fn respond(self: *Server, session: u32, req_id: u32, status: i32, data: []const u8, last: bool) i32 {
        return mc.mc_sys_svc_respond(self.fd, session, req_id, status, mc.addr(data.ptr), @intCast(data.len), @intFromBool(last));
    }
};
