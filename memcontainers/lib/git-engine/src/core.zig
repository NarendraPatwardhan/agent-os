const std = @import("std");
const contract = @import("git_zig");
const object = @import("object");
const plumbing = @import("plumbing");
const worktree_pkg = @import("worktree");
const memory = @import("memory");
const packp = @import("packp");
const gitignore = @import("gitignore");
const gitconfig = @import("gitconfig");
const errors = @import("errors.zig");
const mount_ops = @import("mount.zig");
const paths_mod = @import("paths.zig");
const protocol = @import("protocol.zig");
const remote = @import("remote.zig");
const repository_ops = @import("repository_ops.zig");

const validRemoteUrl = remote.validRemoteUrl;
const validRemoteName = remote.validRemoteName;
const validFullRef = remote.validFullRef;
const remoteTrackingDestination = remote.remoteTrackingDestination;
const defaultRemoteDestination = remote.defaultRemoteDestination;
const infoRefsUrl = remote.infoRefsUrl;
const serviceUrl = remote.serviceUrl;
const resolveSubmoduleHttpUrl = remote.resolveSubmoduleHttpUrl;

const pathWithinAny = repository_ops.pathWithinAny;
const joinU64 = repository_ops.joinU64;
const lowU32 = repository_ops.lowU32;
const highU32 = repository_ops.highU32;
const pairsToPaths = repository_ops.pairsToPaths;
const decisiveIgnorePattern = repository_ops.decisiveIgnorePattern;
const formatIgnorePattern = repository_ops.formatIgnorePattern;
const hashFromObjectId = repository_ops.hashFromObjectId;
const objectIdsToHashes = repository_ops.objectIdsToHashes;
const objectKind = repository_ops.objectKind;
const referenceValue = repository_ops.referenceValue;
const encodeReference = repository_ops.encodeReference;
const removeStoredReference = repository_ops.removeStoredReference;
const bumpGeneration = repository_ops.bumpGeneration;
const signature = repository_ops.signature;
const objectId = repository_ops.objectId;
const readBoundedFile = repository_ops.readBoundedFile;
const statusEntryLess = repository_ops.statusEntryLess;
const submoduleEntryLess = repository_ops.submoduleEntryLess;

pub const gitz_commit = "fdf9124c2aab83b6c3297be4bae8045ada7661f8";
pub const slot_count: usize = 64;

const HandleKind = enum(u3) { result = 1, session = 2, stream = 3, remote = 4, transaction = 5 };

fn makeHandle(kind: HandleKind, index: usize, generation: u16) u32 {
    return (@as(u32, @intFromEnum(kind)) << 29) |
        (@as(u32, generation & 0x1fff) << 16) |
        @as(u32, @intCast(index + 1));
}

fn splitHandle(handle: u32, expected: HandleKind) ?struct { index: usize, generation: u16 } {
    if (@as(u3, @truncate(handle >> 29)) != @intFromEnum(expected)) return null;
    const low = handle & 0xffff;
    if (low == 0 or low > slot_count) return null;
    const generation: u16 = @intCast((handle >> 16) & 0x1fff);
    if (generation == 0) return null;
    return .{ .index = @intCast(low - 1), .generation = generation };
}

fn nextGeneration(generation: u16) u16 {
    const next = (generation +% 1) & 0x1fff;
    return if (next == 0) 1 else next;
}

pub fn Engine(comptime Backend: type) type {
    return struct {
        const Self = @This();
        const ResultSlot = struct {
            generation: u16 = 1,
            owner: u32 = 0,
            bytes: ?[]u8 = null,
        };
        const SessionSlot = struct {
            generation: u16 = 1,
            value: ?Backend.Session = null,
        };
        const StreamSlot = struct { generation: u16 = 1, owner: u32 = 0, bytes: ?[]u8 = null };
        const TransactionSlot = struct { generation: u16 = 1, owner: u32 = 0, request: ?[]u8 = null };
        const SubmoduleTarget = struct { name: []u8, path: []u8, url: []u8, gitlink: plumbing.Hash };
        fn submoduleTargetLess(_: void, left: SubmoduleTarget, right: SubmoduleTarget) bool {
            return std.mem.lessThan(u8, left.path, right.path);
        }
        const RemoteSlot = struct {
            generation: u16 = 1,
            owner: u32 = 0,
            opcode: u16 = 0,
            request_id: u32 = 0,
            phase: enum { empty, advertise, upload, receive } = .empty,
            http_state: enum { awaiting_begin, receiving } = .awaiting_begin,
            url: ?[]u8 = null,
            response: std.ArrayListUnmanaged(u8) = .empty,
            upload: ?packp.UploadPackRequest = null,
            target: plumbing.Hash = plumbing.ZeroHash,
            base: plumbing.Hash = plumbing.ZeroHash,
            remote_name: ?[]u8 = null,
            source_ref: ?[]u8 = null,
            target_ref: ?[]u8 = null,
            push_source: ?[]u8 = null,
            push_dest: ?[]u8 = null,
            depth: u32 = 0,
            submodules: []SubmoduleTarget = &.{},
            submodule_index: usize = 0,
        };

        allocator: std.mem.Allocator,
        backend: Backend,
        results: [slot_count]ResultSlot = [_]ResultSlot{.{}} ** slot_count,
        sessions: [slot_count]SessionSlot = [_]SessionSlot{.{}} ** slot_count,
        streams: [slot_count]StreamSlot = [_]StreamSlot{.{}} ** slot_count,
        remotes: [slot_count]RemoteSlot = [_]RemoteSlot{.{}} ** slot_count,
        transactions: [slot_count]TransactionSlot = [_]TransactionSlot{.{}} ** slot_count,

        pub fn init(allocator: std.mem.Allocator, backend: Backend) Self {
            return .{ .allocator = allocator, .backend = backend };
        }

        pub fn deinit(self: *Self) void {
            for (&self.results) |*slot| if (slot.bytes) |bytes| self.allocator.free(bytes);
            for (&self.sessions) |*slot| if (slot.value) |*session| self.backend.sessionDeinit(self.allocator, session);
            for (&self.streams) |*slot| if (slot.bytes) |bytes| self.allocator.free(bytes);
            for (&self.remotes) |*slot| if (slot.phase != .empty) self.freeRemoteSlot(slot);
            for (&self.transactions) |*slot| if (slot.request) |request| self.allocator.free(request);
            self.* = undefined;
        }

        fn putResult(self: *Self, owner: u32, bytes: []u8) u32 {
            for (&self.results, 0..) |*slot, index| {
                if (slot.bytes == null) {
                    slot.owner = owner;
                    slot.bytes = bytes;
                    return makeHandle(.result, index, slot.generation);
                }
            }
            self.allocator.free(bytes);
            return 0;
        }

        fn errorResponse(self: *Self, owner: u32, opcode: u16, request_id: u32, domain: u16, code: u16) u32 {
            const body = (contract.EngineError{
                .domain = domain,
                .code = code,
                .operation = opcode,
                .retry = @intCast(contract.RETRY_NEVER),
            }).encode(self.allocator) catch return 0;
            defer self.allocator.free(body);
            const bytes = contract.encodeResponseEnvelope(self.allocator, opcode, @intCast(contract.STATUS_ERROR), request_id, body) catch return 0;
            return self.putResult(owner, bytes);
        }

        fn classifiedErrorResponse(self: *Self, owner: u32, opcode: u16, request_id: u32, err: anyerror) u32 {
            const classified = errors.classify(err, opcode);
            const body = (contract.EngineError{
                .domain = classified.domain,
                .code = classified.code,
                .operation = opcode,
                .retry = classified.retry,
            }).encode(self.allocator) catch return 0;
            defer self.allocator.free(body);
            const bytes = contract.encodeResponseEnvelope(self.allocator, opcode, @intCast(contract.STATUS_ERROR), request_id, body) catch return 0;
            return self.putResult(owner, bytes);
        }

        pub fn sessionOpen(self: *Self, config_bytes: []const u8, request_id: u32) u32 {
            if (config_bytes.len > contract.MAX_FRAME_BYTES) return self.errorResponse(0, @intCast(contract.OP_SESSION_OPEN), request_id, @intCast(contract.ERROR_LIMIT), 1);
            const session_config = contract.SessionConfig.decode(self.allocator, config_bytes) catch return self.errorResponse(0, @intCast(contract.OP_SESSION_OPEN), request_id, @intCast(contract.ERROR_PROTOCOL), 1);
            for (&self.sessions, 0..) |*slot, index| {
                if (slot.value == null) {
                    slot.value = self.backend.sessionInit(self.allocator, session_config) catch |err| return self.classifiedErrorResponse(0, @intCast(contract.OP_SESSION_OPEN), request_id, err);
                    const session_handle = makeHandle(.session, index, slot.generation);
                    const body = (contract.Result{ .kind = 1, .generation = 1, .handle = session_handle }).encode(self.allocator) catch return 0;
                    defer self.allocator.free(body);
                    const bytes = contract.encodeResponseEnvelope(self.allocator, @intCast(contract.OP_SESSION_OPEN), @intCast(contract.STATUS_OK), request_id, body) catch return 0;
                    return self.putResult(session_handle, bytes);
                }
            }
            return self.errorResponse(0, @intCast(contract.OP_SESSION_OPEN), request_id, @intCast(contract.ERROR_LIMIT), 1);
        }

        pub fn sessionClose(self: *Self, handle: u32) u32 {
            const decoded = splitHandle(handle, .session) orelse return 1;
            const slot = &self.sessions[decoded.index];
            if (slot.generation != decoded.generation or slot.value == null) return 1;
            for (&self.results) |*result| {
                if (result.owner == handle and result.bytes != null) {
                    self.allocator.free(result.bytes.?);
                    result.bytes = null;
                    result.owner = 0;
                    result.generation = nextGeneration(result.generation);
                }
            }
            for (&self.streams) |*stream_slot| if (stream_slot.owner == handle and stream_slot.bytes != null) self.freeStreamSlot(stream_slot);
            for (&self.remotes) |*remote_slot| if (remote_slot.owner == handle and remote_slot.phase != .empty) self.freeRemoteSlot(remote_slot);
            for (&self.transactions) |*transaction_slot| if (transaction_slot.owner == handle and transaction_slot.request != null) self.freeTransactionSlot(transaction_slot);
            self.backend.sessionDeinit(self.allocator, &slot.value.?);
            slot.value = null;
            slot.generation = nextGeneration(slot.generation);
            return 0;
        }

        pub fn execute(self: *Self, session_handle: u32, request_bytes: []const u8) u32 {
            const envelope = contract.decodeRequestEnvelope(request_bytes) catch return self.errorResponse(0, 0, 0, @intCast(contract.ERROR_PROTOCOL), 1);
            if (envelope.flags != 0) return self.errorResponse(0, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_PROTOCOL), 2);
            const decoded = splitHandle(session_handle, .session) orelse return self.errorResponse(0, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 1);
            const slot = &self.sessions[decoded.index];
            if (slot.generation != decoded.generation or slot.value == null) return self.errorResponse(0, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 2);

            if (envelope.opcode == contract.OP_ENGINE_DESCRIBE) {
                if (envelope.payload.len != 0) return self.errorResponse(session_handle, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_PROTOCOL), 3);
                const body = (contract.EngineDescription{
                    .abi_major = @intCast(contract.PROTOCOL_VERSION),
                    .abi_minor = @intCast(contract.PROTOCOL_MINOR),
                    .build_id = "agentos-gitz-v1",
                    .gitz_commit = gitz_commit,
                    .backend = self.backend.kind(),
                    .capabilities_low = self.backend.capabilities(),
                    .capabilities_high = 0,
                    .max_frame_bytes = contract.MAX_FRAME_BYTES,
                    .max_pack_bytes = contract.MAX_PACK_BYTES,
                    .max_handles = @intCast(slot_count),
                }).encode(self.allocator) catch return 0;
                defer self.allocator.free(body);
                const bytes = contract.encodeResponseEnvelope(self.allocator, envelope.opcode, @intCast(contract.STATUS_OK), envelope.request_id, body) catch return 0;
                return self.putResult(session_handle, bytes);
            }

            if (envelope.opcode == contract.OP_REPOSITORY_INIT) {
                if (envelope.payload.len != 0) return self.errorResponse(session_handle, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_PROTOCOL), 3);
                if (self.backend.isReadOnly(&slot.value.?)) return self.errorResponse(session_handle, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 3);
                self.backend.repositoryInit(&slot.value.?) catch |err| return self.classifiedErrorResponse(session_handle, envelope.opcode, envelope.request_id, err);
                const generation = self.backend.generation(&slot.value.?);
                const body = (contract.Result{ .kind = 2, .generation = generation }).encode(self.allocator) catch return 0;
                defer self.allocator.free(body);
                const bytes = contract.encodeResponseEnvelope(self.allocator, envelope.opcode, @intCast(contract.STATUS_OK), envelope.request_id, body) catch return 0;
                return self.putResult(session_handle, bytes);
            }

            if (envelope.opcode == contract.OP_REPOSITORY_OPEN) {
                if (envelope.payload.len != 0) return self.errorResponse(session_handle, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_PROTOCOL), 3);
                self.backend.repositoryOpen(&slot.value.?) catch |err| return self.classifiedErrorResponse(session_handle, envelope.opcode, envelope.request_id, err);
                const body = (contract.Result{ .kind = 2, .generation = self.backend.generation(&slot.value.?) }).encode(self.allocator) catch return 0;
                defer self.allocator.free(body);
                const bytes = contract.encodeResponseEnvelope(self.allocator, envelope.opcode, @intCast(contract.STATUS_OK), envelope.request_id, body) catch return 0;
                return self.putResult(session_handle, bytes);
            }

            const session = &slot.value.?;
            if (self.backend.hasPendingRemoteApply(session))
                return self.errorResponse(session_handle, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_REPOSITORY), @intCast(contract.ERROR_CODE_CONFLICT));
            if (envelope.opcode == contract.OP_CLONE or envelope.opcode == contract.OP_FETCH or envelope.opcode == contract.OP_PULL or envelope.opcode == contract.OP_PUSH) return self.remoteStart(session_handle, session, envelope);
            if (envelope.opcode == contract.OP_HTTP_EFFECT) return self.remoteContinue(session_handle, session, envelope);
            if (envelope.opcode == contract.OP_REMOTE_CANCEL) return self.remoteCancel(session_handle, envelope);
            if (envelope.opcode == contract.OP_REF_TRANSACTION) return self.refTransaction(session_handle, session, envelope);
            if (envelope.opcode == contract.OP_SUBMODULE) {
                const submodule_request = contract.SubmoduleRequest.decode(self.allocator, envelope.payload) catch
                    return self.errorResponse(session_handle, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_PROTOCOL), 40);
                if (submodule_request.action == contract.ACTION_UPDATE) return self.submoduleStart(session_handle, session, envelope, submodule_request);
            }
            const body = switch (envelope.opcode) {
                contract.OP_FILE_WRITE => self.fileWrite(session, envelope.payload),
                contract.OP_FILE_STAT => self.fileStat(session, envelope.payload),
                contract.OP_FILE_READ => self.fileRead(session, envelope.payload),
                contract.OP_FILE_REMOVE => self.fileRemove(session, envelope.payload),
                contract.OP_FILE_RENAME => self.fileRename(session, envelope.payload),
                contract.OP_FILE_READDIR => self.fileReadDir(session, envelope.payload),
                contract.OP_STATUS => self.status(session, envelope.payload),
                contract.OP_ADD => self.add(session, envelope.payload),
                contract.OP_REMOVE => self.remove(session, envelope.payload),
                contract.OP_COMMIT => self.commit(session, envelope.payload),
                contract.OP_LOG => self.log(session, envelope.payload),
                contract.OP_RESOLVE_REVISION => self.resolveRevision(session, envelope.payload),
                contract.OP_DIFF => self.diff(session, envelope.payload),
                contract.OP_SHOW => self.show(session, envelope.payload),
                contract.OP_CHECKOUT => self.checkout(session, envelope.payload),
                contract.OP_SPARSE => self.sparse(session, envelope.payload),
                contract.OP_IGNORE_QUERY => self.ignoreQuery(session, envelope.payload),
                contract.OP_SHALLOW => self.shallow(session, envelope.payload),
                contract.OP_SUBMODULE => self.submoduleLocal(session, envelope.payload),
                contract.OP_RESET => self.reset(session, envelope.payload),
                contract.OP_BRANCH => self.branch(session, envelope.payload),
                contract.OP_TAG => self.tag(session, envelope.payload),
                contract.OP_CONFIG => self.config(session, envelope.payload),
                contract.OP_REMOTE_METADATA => self.remoteMetadata(session, envelope.payload),
                contract.OP_REF => self.reference(session, envelope.payload),
                contract.OP_OBJECT => self.objectOperation(session, envelope.payload),
                contract.OP_PACK_IMPORT => self.packImport(session, envelope.payload),
                contract.OP_PACK_BUILD => self.packBuild(session_handle, session, envelope.payload),
                contract.OP_MOUNT => self.mount(session, envelope.payload),
                contract.OP_STREAM => self.stream(session_handle, envelope.payload),
                contract.OP_CHECKPOINT => self.checkpoint(session, envelope.payload),
                contract.OP_RESTORE => self.restore(session, envelope.payload),
                else => return self.errorResponse(session_handle, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 4),
            } catch |err| return self.classifiedErrorResponse(session_handle, envelope.opcode, envelope.request_id, err);
            defer self.allocator.free(body);
            const response = contract.encodeResponseEnvelope(self.allocator, envelope.opcode, @intCast(contract.STATUS_OK), envelope.request_id, body) catch return 0;
            return self.putResult(session_handle, response);
        }

        fn fileWrite(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            if (self.backend.isReadOnly(session)) return error.ReadOnly;
            const request = try contract.FileRequest.decode(self.allocator, payload);
            try validatePath(request.path);
            const data = request.data orelse return error.MissingData;
            if (data.len > contract.MAX_FIELD_BYTES) return error.DataTooLarge;
            if (std.fs.path.dirname(request.path)) |parent| try session.filesystem.mkdirAll(parent, 0o040755);
            var file = try session.filesystem.create(request.path);
            defer file.close() catch {};
            var written: usize = 0;
            while (written < data.len) written += try file.write(data[written..]);
            if (request.mode) |mode| try session.filesystem.chmod(request.path, mode);
            bumpGeneration(session);
            const info = try session.filesystem.lstat(request.path);
            return (contract.FileResult{
                .path = request.path,
                .mode = info.mode,
                .size_low = @truncate(@as(u64, @intCast(info.size))),
                .size_high = @truncate(@as(u64, @intCast(info.size)) >> 32),
            }).encode(self.allocator);
        }

        fn fileStat(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            const request = try contract.FileRequest.decode(self.allocator, payload);
            try validatePath(request.path);
            const info = try session.filesystem.lstat(request.path);
            return (contract.FileResult{
                .path = request.path,
                .mode = info.mode,
                .size_low = @truncate(@as(u64, @intCast(info.size))),
                .size_high = @truncate(@as(u64, @intCast(info.size)) >> 32),
            }).encode(self.allocator);
        }

        fn fileRead(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            const request = try contract.FileRequest.decode(self.allocator, payload);
            try validatePath(request.path);
            const info = try session.filesystem.lstat(request.path);
            const offset = joinU64(request.offset_low orelse 0, request.offset_high orelse 0);
            if (offset > @as(u64, @intCast(info.size))) return error.InvalidOffset;
            const available: usize = @intCast(@as(u64, @intCast(info.size)) - offset);
            const count = @min(available, @as(usize, contract.MAX_FIELD_BYTES));
            const data = try self.allocator.alloc(u8, count);
            defer self.allocator.free(data);
            var file = try session.filesystem.open(request.path);
            defer file.close() catch {};
            var read: usize = 0;
            while (read < data.len) {
                const n = try file.readAt(data[read..], @intCast(offset + read));
                if (n == 0) break;
                read += n;
            }
            return (contract.FileResult{ .path = request.path, .mode = info.mode, .size_low = lowU32(info.size), .size_high = highU32(info.size), .data = data[0..read] }).encode(self.allocator);
        }

        fn fileRemove(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            if (self.backend.isReadOnly(session)) return error.ReadOnly;
            const request = try contract.FileRequest.decode(self.allocator, payload);
            try validatePath(request.path);
            try session.filesystem.remove(request.path);
            bumpGeneration(session);
            return (contract.Result{ .kind = 3, .generation = session.mutation_generation, .count = 1 }).encode(self.allocator);
        }

        fn fileRename(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            if (self.backend.isReadOnly(session)) return error.ReadOnly;
            const request = try contract.FileRequest.decode(self.allocator, payload);
            const target = request.other_path orelse return error.MissingTarget;
            try validatePath(request.path);
            try validatePath(target);
            try session.filesystem.rename(request.path, target);
            bumpGeneration(session);
            const info = try session.filesystem.lstat(target);
            return (contract.FileResult{ .path = target, .mode = info.mode, .size_low = lowU32(info.size), .size_high = highU32(info.size) }).encode(self.allocator);
        }

        fn fileReadDir(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            const request = try contract.FileRequest.decode(self.allocator, payload);
            try validateDirectoryPath(request.path);
            const infos = try session.filesystem.readDir(request.path);
            defer session.filesystem.freeReadDir(infos);
            const entries = try self.allocator.alloc(contract.DirectoryEntry, infos.len);
            defer self.allocator.free(entries);
            for (infos, 0..) |info, i| entries[i] = .{ .name = info.name, .mode = info.mode, .size_low = lowU32(info.size), .size_high = highU32(info.size) };
            return (contract.DirectoryResult{ .entries = entries }).encode(self.allocator);
        }

        fn status(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            if (payload.len != 0) return error.UnexpectedPayload;
            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            var worktree = try repository.worktree();
            var state = try worktree.status();
            defer state.deinit();
            const submodule_paths = try self.configuredSubmodulePaths(session);
            defer self.freeOwnedPaths(submodule_paths);
            var entries = try self.allocator.alloc(contract.StatusEntry, state.map.count());
            defer self.allocator.free(entries);
            var iterator = state.map.iterator();
            var index: usize = 0;
            while (iterator.next()) |entry| {
                const staging = entry.value_ptr.staging.char();
                const worktree_state = entry.value_ptr.worktree.char();
                if ((staging == ' ' and worktree_state == ' ') or pathWithinAny(entry.key_ptr.*, submodule_paths)) continue;
                entries[index] = .{
                    .path = entry.key_ptr.*,
                    .index = staging,
                    .worktree = worktree_state,
                };
                index += 1;
            }
            std.mem.sort(contract.StatusEntry, entries[0..index], {}, statusEntryLess);
            return (contract.StatusResult{
                .generation = session.mutation_generation,
                .entries = entries[0..index],
            }).encode(self.allocator);
        }

        fn configuredSubmodulePaths(self: *Self, session: *Backend.Session) ![][]u8 {
            const bytes = readBoundedFile(self.allocator, session.filesystem, ".gitmodules", contract.MAX_FIELD_BYTES) catch |err| switch (err) {
                error.NotExist => return self.allocator.alloc([]u8, 0),
                else => |value| return value,
            };
            defer self.allocator.free(bytes);
            var modules = try gitconfig.Modules.create(self.allocator);
            defer modules.deinit();
            try modules.unmarshal(bytes);
            const paths = try self.allocator.alloc([]u8, modules.submodules.count());
            errdefer self.allocator.free(paths);
            var count: usize = 0;
            errdefer for (paths[0..count]) |path| self.allocator.free(path);
            var iterator = modules.submodules.iterator();
            while (iterator.next()) |item| {
                const module = item.value_ptr.*;
                try validatePath(module.path);
                paths[count] = try self.allocator.dupe(u8, module.path);
                count += 1;
            }
            return paths;
        }

        fn freeOwnedPaths(self: *Self, paths: [][]u8) void {
            for (paths) |path| self.allocator.free(path);
            self.allocator.free(paths);
        }

        fn parentWorktreeClean(self: *Self, session: *Backend.Session) !bool {
            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            var worktree = try repository.worktree();
            var state = try worktree.status();
            defer state.deinit();
            const submodule_paths = try self.configuredSubmodulePaths(session);
            defer self.freeOwnedPaths(submodule_paths);
            var iterator = state.map.iterator();
            while (iterator.next()) |entry| {
                if (pathWithinAny(entry.key_ptr.*, submodule_paths)) continue;
                if (entry.value_ptr.staging.char() != ' ' or entry.value_ptr.worktree.char() != ' ') return false;
            }
            return true;
        }

        fn add(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            if (self.backend.isReadOnly(session)) return error.ReadOnly;
            const request = try contract.PorcelainRequest.decode(self.allocator, payload);
            defer self.allocator.free(request.paths);
            if (request.action != contract.ACTION_UPDATE) return error.InvalidAction;
            if (request.paths.len == 0) return error.EmptyPaths;
            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            var worktree = try repository.worktree();
            for (request.paths) |path| {
                try validatePath(path.key);
                try worktree.addWithOptions(.{ .path = path.key, .skip_status = true });
            }
            bumpGeneration(session);
            return (contract.Result{ .kind = 3, .generation = session.mutation_generation, .count = @intCast(request.paths.len) }).encode(self.allocator);
        }

        fn remove(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            if (self.backend.isReadOnly(session)) return error.ReadOnly;
            const request = try contract.PorcelainRequest.decode(self.allocator, payload);
            defer self.allocator.free(request.paths);
            if (request.action != contract.ACTION_UPDATE) return error.InvalidAction;
            if (request.paths.len == 0) return error.EmptyPaths;
            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            var worktree = try repository.worktree();
            for (request.paths) |path| {
                try validatePath(path.key);
                _ = try worktree.remove(path.key);
            }
            bumpGeneration(session);
            return (contract.Result{ .kind = 3, .generation = session.mutation_generation, .count = @intCast(request.paths.len) }).encode(self.allocator);
        }

        fn commit(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            if (self.backend.isReadOnly(session)) return error.ReadOnly;
            const request = try contract.PorcelainRequest.decode(self.allocator, payload);
            defer self.allocator.free(request.paths);
            if (request.action != contract.ACTION_CREATE) return error.InvalidAction;
            const message = request.message orelse return error.MissingMessage;
            const author = request.author orelse return error.MissingAuthor;
            const committer = request.committer orelse return error.MissingCommitter;
            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            var worktree = try repository.worktree();
            const hash = try worktree.commit(message, .{
                .author = signature(author),
                .committer = signature(committer),
            });
            bumpGeneration(session);
            return (contract.CommitResult{
                .generation = session.mutation_generation,
                .object_id = objectId(&hash),
            }).encode(self.allocator);
        }

        fn resolveRevision(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            const request = try contract.PorcelainRequest.decode(self.allocator, payload);
            defer self.allocator.free(request.paths);
            if (request.action != contract.ACTION_GET) return error.InvalidAction;
            const revision = request.revision orelse return error.MissingRevision;
            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            const hash = try repository.resolveRevision(revision);
            return (contract.ResolveResult{ .object_id = objectId(&hash) }).encode(self.allocator);
        }

        fn log(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            const request = try contract.PorcelainRequest.decode(self.allocator, payload);
            defer self.allocator.free(request.paths);
            if (request.action != contract.ACTION_LIST or request.flags != 0 or request.paths.len != 0) return error.InvalidAction;
            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            const from = if (request.revision) |revision| try repository.resolveRevision(revision) else plumbing.ZeroHash;
            var history = try repository.log(.{ .from = from });
            defer history.deinit();
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(self.allocator);
            const limit: usize = @intCast(@min(request.limit orelse 32, 4096));
            var count: usize = 0;
            while (count < limit) : (count += 1) {
                const entry = history.next() catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return err,
                };
                defer {
                    entry.deinit();
                    self.allocator.destroy(entry);
                }
                var hex: [plumbing.MaxHexSize]u8 = undefined;
                try output.appendSlice(self.allocator, entry.hash.string(&hex));
                try output.append(self.allocator, ' ');
                const subject_end = std.mem.indexOfScalar(u8, entry.message, '\n') orelse entry.message.len;
                try output.appendSlice(self.allocator, entry.message[0..subject_end]);
                try output.append(self.allocator, '\n');
                if (output.items.len > contract.MAX_RESULT_BYTES - contract.ENVELOPE_HEADER_BYTES) return error.ResultTooLarge;
            }
            return (contract.Result{ .kind = 7, .generation = session.mutation_generation, .count = @intCast(count), .data = output.items }).encode(self.allocator);
        }

        fn diff(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            const request = try contract.PorcelainRequest.decode(self.allocator, payload);
            defer self.allocator.free(request.paths);
            if (request.action != contract.ACTION_GET or request.flags != 1 or request.paths.len != 0) return error.InvalidAction;
            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            var wt = try repository.worktree();
            const revision = request.revision orelse "HEAD";
            const hash = try repository.resolveRevision(revision);
            var changes = try wt.diffCommitWithStaging(hash, false);
            defer worktree_pkg.deinitMaterializedChanges(self.allocator, &changes);
            var summary: std.ArrayList(u8) = .empty;
            defer summary.deinit(self.allocator);
            for (changes.items.items) |*change| {
                const line = try change.string(self.allocator);
                defer self.allocator.free(line);
                if (summary.items.len + line.len + 1 > contract.MAX_RESULT_BYTES - contract.ENVELOPE_HEADER_BYTES) return error.ResultTooLarge;
                try summary.appendSlice(self.allocator, line);
                try summary.append(self.allocator, '\n');
            }
            return (contract.Result{ .kind = 8, .generation = session.mutation_generation, .count = @intCast(changes.items.items.len), .data = summary.items }).encode(self.allocator);
        }

        fn show(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            const request = try contract.PorcelainRequest.decode(self.allocator, payload);
            defer self.allocator.free(request.paths);
            if (request.action != contract.ACTION_GET or request.flags != 0 or request.paths.len != 0) return error.InvalidAction;
            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            const hash = try repository.resolveRevision(request.revision orelse "HEAD");
            const commit_object = try repository.commitObject(hash);
            defer {
                commit_object.deinit();
                self.allocator.destroy(commit_object);
            }
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(self.allocator);
            var hex: [plumbing.MaxHexSize]u8 = undefined;
            try output.appendSlice(self.allocator, "commit ");
            try output.appendSlice(self.allocator, hash.string(&hex));
            try output.append(self.allocator, '\n');
            try output.appendSlice(self.allocator, "Author: ");
            try output.appendSlice(self.allocator, commit_object.author.name);
            try output.appendSlice(self.allocator, " <");
            try output.appendSlice(self.allocator, commit_object.author.email);
            try output.appendSlice(self.allocator, ">\n\n    ");
            try output.appendSlice(self.allocator, commit_object.message);
            if (!std.mem.endsWith(u8, commit_object.message, "\n")) try output.append(self.allocator, '\n');
            return (contract.Result{ .kind = 9, .generation = session.mutation_generation, .count = 1, .data = output.items }).encode(self.allocator);
        }

        fn checkout(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            if (self.backend.isReadOnly(session)) return error.ReadOnly;
            const request = try contract.PorcelainRequest.decode(self.allocator, payload);
            defer self.allocator.free(request.paths);
            if (request.action != contract.ACTION_UPDATE) return error.InvalidAction;
            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            var wt = try repository.worktree();
            var options = worktree_pkg.CheckoutOptions{ .force = request.flags & 1 != 0, .keep = request.flags & 2 != 0, .create = request.flags & 4 != 0 };
            if (request.revision) |revision| options.hash = try repository.resolveRevision(revision);
            if (request.target) |target| options.branch = plumbing.ReferenceName.init(target);
            options.sparse_checkout_directories = self.backend.sparsePaths(session);
            try wt.checkout(options);
            bumpGeneration(session);
            return self.mutationResult(session, 1);
        }

        fn sparse(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            if (self.backend.isReadOnly(session)) return error.ReadOnly;
            const request = try contract.PorcelainRequest.decode(self.allocator, payload);
            defer self.allocator.free(request.paths);
            if (request.action != contract.ACTION_LIST or request.flags != 0) return error.InvalidAction;
            const paths = try pairsToPaths(self.allocator, request.paths);
            defer self.allocator.free(paths);
            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            var wt = try repository.worktree();
            const head = try repository.resolveRevision("HEAD");
            try wt.checkout(.{ .hash = head, .sparse_checkout_directories = paths });
            try self.backend.setSparsePaths(self.allocator, session, paths);
            bumpGeneration(session);
            return self.mutationResult(session, @intCast(paths.len));
        }

        fn ignoreQuery(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            _ = session.repository orelse return error.RepositoryNotOpen;
            const request = try contract.PathQuery.decode(self.allocator, payload);
            defer self.allocator.free(request.paths);
            if (request.paths.len == 0) return error.EmptyPaths;

            const patterns = try gitignore.readPatterns(self.allocator, session.filesystem, &.{});
            defer gitignore.freePatterns(self.allocator, patterns);
            const matcher = gitignore.newMatcher(patterns);
            const matched = try self.allocator.alloc(contract.StringPair, request.paths.len);
            defer self.allocator.free(matched);
            const matched_patterns = try self.allocator.alloc([]u8, request.paths.len);
            defer self.allocator.free(matched_patterns);
            var count: usize = 0;
            defer for (matched_patterns[0..count]) |pattern| self.allocator.free(pattern);
            for (request.paths) |path| {
                if (path.value.len != 0) return error.InvalidQueryValue;
                try validatePath(path.key);
                const segment_count = std.mem.countScalar(u8, path.key, '/') + 1;
                const segments = try self.allocator.alloc([]const u8, segment_count);
                defer self.allocator.free(segments);
                var iterator = std.mem.splitScalar(u8, path.key, '/');
                var index: usize = 0;
                while (iterator.next()) |segment| : (index += 1) segments[index] = segment;
                const info = session.filesystem.lstat(path.key) catch null;
                const is_dir = if (info) |value| value.isDir() else false;
                if (matcher.match(segments, is_dir)) {
                    const pattern = decisiveIgnorePattern(patterns, segments, is_dir) orelse return error.InvalidIgnoreMatch;
                    matched_patterns[count] = try formatIgnorePattern(self.allocator, pattern);
                    matched[count] = .{ .key = path.key, .value = matched_patterns[count] };
                    count += 1;
                }
            }
            return (contract.IgnoreResult{ .paths = matched[0..count] }).encode(self.allocator);
        }

        fn shallow(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            _ = session.repository orelse return error.RepositoryNotOpen;
            const request = try contract.ShallowRequest.decode(self.allocator, payload);
            defer self.allocator.free(request.commits);
            if (request.action == contract.ACTION_GET) {
                if (request.commits.len != 0) return error.InvalidAction;
                const hashes = try self.backend.shallowGet(self.allocator, session);
                defer self.allocator.free(hashes);
                const ids = try self.allocator.alloc(contract.ObjectId, hashes.len);
                defer self.allocator.free(ids);
                for (hashes, 0..) |*hash, index| ids[index] = objectId(hash);
                return (contract.ShallowResult{ .commits = ids }).encode(self.allocator);
            }
            if (request.action != contract.ACTION_UPDATE or self.backend.isReadOnly(session)) return error.InvalidAction;
            const hashes = try objectIdsToHashes(self.allocator, request.commits);
            defer self.allocator.free(hashes);
            for (hashes) |hash| {
                var repository = &(session.repository orelse return error.RepositoryNotOpen);
                const commit_object = try repository.commitObject(hash);
                commit_object.deinit();
                self.allocator.destroy(commit_object);
            }
            try self.backend.shallowSet(session, hashes);
            bumpGeneration(session);
            return (contract.ShallowResult{ .commits = request.commits }).encode(self.allocator);
        }

        fn submoduleLocal(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            _ = session.repository orelse return error.RepositoryNotOpen;
            const request = try contract.SubmoduleRequest.decode(self.allocator, payload);
            if (request.action == contract.ACTION_CREATE) {
                if (self.backend.isReadOnly(session)) return error.ReadOnly;
                const path = request.path orelse return error.MissingPath;
                try validatePath(path);
                const hash = try hashFromObjectId(request.object_id orelse return error.MissingObjectId);
                var repository = &(session.repository orelse return error.RepositoryNotOpen);
                const commit_object = try repository.commitObject(hash);
                commit_object.deinit();
                self.allocator.destroy(commit_object);
                try self.backend.stageGitlink(session, path, hash);
                bumpGeneration(session);
                const id = objectId(&hash);
                const entry = contract.SubmoduleEntry{ .name = path, .path = path, .url = "", .gitlink = id, .state = 0 };
                return (contract.SubmoduleResult{ .generation = session.mutation_generation, .entries = &.{entry} }).encode(self.allocator);
            }
            if (request.action != contract.ACTION_LIST and request.action != contract.ACTION_GET) return error.InvalidAction;
            if (request.object_id != null) return error.InvalidAction;
            if (request.path) |path| try validatePath(path);

            const modules_bytes = readBoundedFile(self.allocator, session.filesystem, ".gitmodules", contract.MAX_FIELD_BYTES) catch |err| switch (err) {
                error.NotExist => return (contract.SubmoduleResult{ .generation = session.mutation_generation, .entries = &.{} }).encode(self.allocator),
                else => |value| return value,
            };
            defer self.allocator.free(modules_bytes);
            const info = try session.filesystem.lstat(".gitmodules");
            if (info.isSymlink()) return error.GitModulesSymlink;
            var modules = try gitconfig.Modules.create(self.allocator);
            defer modules.deinit();
            try modules.unmarshal(modules_bytes);

            const capacity = if (request.path == null) modules.submodules.count() else @min(modules.submodules.count(), 1);
            const entries = try self.allocator.alloc(contract.SubmoduleEntry, capacity);
            defer self.allocator.free(entries);
            const hashes = try self.allocator.alloc(plumbing.Hash, capacity);
            defer self.allocator.free(hashes);
            const heads = try self.allocator.alloc(plumbing.Hash, capacity);
            defer self.allocator.free(heads);
            const urls = try self.allocator.alloc([]u8, capacity);
            var url_count: usize = 0;
            defer {
                for (urls[0..url_count]) |url| self.allocator.free(url);
                self.allocator.free(urls);
            }
            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            const origin = repository.remote("origin") catch null;
            const parent_url: ?[]const u8 = if (origin) |remote_value| if (remote_value.config.urls.len > 0) remote_value.config.urls[0] else null else null;
            var count: usize = 0;
            var iterator = modules.submodules.iterator();
            while (iterator.next()) |item| {
                const module = item.value_ptr.*;
                try module.validate();
                try validatePath(module.path);
                if (request.path) |wanted| if (!std.mem.eql(u8, wanted, module.path)) continue;
                const link = try self.backend.gitlink(session, module.path);
                var link_id: ?contract.ObjectId = null;
                var head_id: ?contract.ObjectId = null;
                var state: u16 = 0;
                if (link) |hash| {
                    hashes[count] = hash;
                    link_id = objectId(&hashes[count]);
                    if (try self.backend.submoduleHead(session, module.path)) |head| {
                        heads[count] = head;
                        head_id = objectId(&heads[count]);
                        state = if (head.eql(hash)) 1 else 2;
                    }
                }
                urls[count] = try resolveSubmoduleHttpUrl(self.allocator, parent_url, module.url);
                url_count += 1;
                entries[count] = .{ .name = module.name, .path = module.path, .url = urls[count], .gitlink = link_id, .head = head_id, .state = state };
                count += 1;
            }
            std.mem.sort(contract.SubmoduleEntry, entries[0..count], {}, submoduleEntryLess);
            if (request.action == contract.ACTION_GET and count == 0) return error.SubmoduleNotFound;
            return (contract.SubmoduleResult{ .generation = session.mutation_generation, .entries = entries[0..count] }).encode(self.allocator);
        }

        fn syncConfiguredGitlinks(self: *Self, session: *Backend.Session) !void {
            const modules_bytes = readBoundedFile(self.allocator, session.filesystem, ".gitmodules", contract.MAX_FIELD_BYTES) catch |err| switch (err) {
                error.NotExist => return,
                else => |value| return value,
            };
            defer self.allocator.free(modules_bytes);
            const info = try session.filesystem.lstat(".gitmodules");
            if (info.isSymlink()) return error.GitModulesSymlink;
            var modules = try gitconfig.Modules.create(self.allocator);
            defer modules.deinit();
            try modules.unmarshal(modules_bytes);

            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            const head = try repository.resolveRevision("HEAD");
            const commit_object = try repository.commitObject(head);
            defer {
                commit_object.deinit();
                self.allocator.destroy(commit_object);
            }
            const tree = try commit_object.tree();
            defer object.freeTree(self.allocator, tree);

            var iterator = modules.submodules.iterator();
            while (iterator.next()) |item| {
                const module = item.value_ptr.*;
                try module.validate();
                try validatePath(module.path);
                const entry = try tree.findEntry(module.path);
                if (entry.mode != 0o160000) return error.InvalidGitlink;
                try self.backend.stageGitlink(session, module.path, entry.hash);
            }
        }

        fn reset(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            if (self.backend.isReadOnly(session)) return error.ReadOnly;
            const request = try contract.PorcelainRequest.decode(self.allocator, payload);
            defer self.allocator.free(request.paths);
            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            var wt = try repository.worktree();
            const mode: worktree_pkg.ResetMode = switch (request.action) {
                contract.RESET_SOFT => .soft,
                contract.RESET_MIXED => .mixed,
                contract.RESET_HARD => .hard,
                contract.RESET_MERGE => .merge,
                else => return error.InvalidAction,
            };
            const hash = if (request.revision) |revision| try repository.resolveRevision(revision) else plumbing.ZeroHash;
            const paths = try pairsToPaths(self.allocator, request.paths);
            defer self.allocator.free(paths);
            try wt.reset(.{ .commit = hash, .mode = mode, .files = paths });
            bumpGeneration(session);
            return self.mutationResult(session, @intCast(paths.len));
        }

        fn branch(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            const request = try contract.PorcelainRequest.decode(self.allocator, payload);
            defer self.allocator.free(request.paths);
            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            const name = request.target orelse return error.MissingTarget;
            if (request.action == contract.ACTION_DELETE) {
                if (self.backend.isReadOnly(session)) return error.ReadOnly;
                try repository.deleteBranch(name);
                bumpGeneration(session);
                return self.mutationResult(session, 1);
            }
            if (request.action != contract.ACTION_CREATE) return error.InvalidAction;
            if (self.backend.isReadOnly(session)) return error.ReadOnly;
            const remote_name = request.revision orelse "";
            const merge = request.message orelse "";
            try repository.createBranch(name, remote_name, merge);
            bumpGeneration(session);
            return self.mutationResult(session, 1);
        }

        fn tag(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            const request = try contract.PorcelainRequest.decode(self.allocator, payload);
            defer self.allocator.free(request.paths);
            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            const name = request.target orelse return error.MissingTarget;
            if (request.action == contract.ACTION_DELETE) {
                if (self.backend.isReadOnly(session)) return error.ReadOnly;
                var ref_name_buf: [contract.MAX_REF_BYTES]u8 = undefined;
                const ref_name = try plumbing.newTagReferenceName(name, &ref_name_buf);
                _ = try repository.reference(ref_name, false);
                try removeStoredReference(repository.storer, ref_name);
                bumpGeneration(session);
                return self.mutationResult(session, 1);
            }
            if (request.action == contract.ACTION_GET) {
                const ref = try repository.tag(name);
                defer repository.freeReference(ref);
                return encodeReference(self.allocator, &ref);
            }
            if (request.action != contract.ACTION_CREATE or self.backend.isReadOnly(session)) return error.InvalidAction;
            const revision = request.revision orelse "HEAD";
            const hash = try repository.resolveRevision(revision);
            const ref = try repository.createTag(name, hash, null);
            defer repository.freeReference(ref);
            bumpGeneration(session);
            return encodeReference(self.allocator, &ref);
        }

        fn reference(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            const request = try contract.PorcelainRequest.decode(self.allocator, payload);
            defer self.allocator.free(request.paths);
            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            if (request.action == contract.ACTION_LIST) {
                var iter = try repository.references();
                defer iter.deinit();
                var stored_refs: std.ArrayList(plumbing.Reference) = .empty;
                defer stored_refs.deinit(self.allocator);
                while (true) {
                    const ref = iter.next() catch |err| switch (err) {
                        error.EndOfStream => break,
                    };
                    try stored_refs.append(self.allocator, ref);
                }
                const results = try self.allocator.alloc(contract.ReferenceResult, stored_refs.items.len);
                defer self.allocator.free(results);
                for (stored_refs.items, 0..) |*ref, index| results[index] = referenceValue(ref);
                return (contract.ReferenceList{ .references = results }).encode(self.allocator);
            }
            const name = plumbing.ReferenceName.init(request.target orelse return error.MissingTarget);
            if (request.action == contract.ACTION_GET) {
                const ref = try repository.reference(name, request.flags & 1 != 0);
                defer repository.freeReference(ref);
                return encodeReference(self.allocator, &ref);
            }
            if (self.backend.isReadOnly(session)) return error.ReadOnly;
            if (request.action == contract.ACTION_DELETE) {
                try removeStoredReference(repository.storer, name);
                bumpGeneration(session);
                return self.mutationResult(session, 1);
            }
            if (request.action != contract.ACTION_UPDATE) return error.InvalidAction;
            const hash = try repository.resolveRevision(request.revision orelse return error.MissingRevision);
            try repository.storer.setReference(plumbing.Reference.newHashReference(name, hash));
            bumpGeneration(session);
            return self.mutationResult(session, 1);
        }

        fn remoteMetadata(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            const request = try contract.PorcelainRequest.decode(self.allocator, payload);
            defer self.allocator.free(request.paths);
            if (request.flags != 0 or request.paths.len != 0) return error.InvalidAction;
            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            if (request.action == contract.ACTION_LIST) {
                const remotes = try repository.remotes(self.allocator);
                defer self.allocator.free(remotes);
                var output: std.ArrayList(u8) = .empty;
                defer output.deinit(self.allocator);
                for (remotes) |remote_value| {
                    try output.appendSlice(self.allocator, remote_value.config.name);
                    if (remote_value.config.urls.len > 0) {
                        try output.append(self.allocator, '\t');
                        try output.appendSlice(self.allocator, remote_value.config.urls[0]);
                    }
                    try output.append(self.allocator, '\n');
                }
                return (contract.Result{ .kind = 10, .generation = session.mutation_generation, .count = @intCast(remotes.len), .data = output.items }).encode(self.allocator);
            }
            const name = request.target orelse return error.MissingTarget;
            if (!validRemoteName(name)) return error.InvalidRemoteName;
            if (request.action == contract.ACTION_GET) {
                const remote_value = try repository.remote(name);
                const url = if (remote_value.config.urls.len > 0) remote_value.config.urls[0] else "";
                return (contract.Result{ .kind = 10, .generation = session.mutation_generation, .count = 1, .data = url }).encode(self.allocator);
            }
            if (self.backend.isReadOnly(session)) return error.ReadOnly;
            if (request.action == contract.ACTION_DELETE) {
                try repository.deleteRemote(name);
            } else if (request.action == contract.ACTION_CREATE) {
                const url = request.message orelse return error.MissingURL;
                if (!validRemoteUrl(url)) return error.InvalidRemoteURL;
                _ = try repository.createRemote(name, &.{url});
            } else if (request.action == contract.ACTION_UPDATE) {
                const url = request.message orelse return error.MissingURL;
                if (!validRemoteUrl(url)) return error.InvalidRemoteURL;
                try repository.deleteRemote(name);
                _ = try repository.createRemote(name, &.{url});
            } else return error.InvalidAction;
            bumpGeneration(session);
            return self.mutationResult(session, 1);
        }

        fn config(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            const request = try contract.PorcelainRequest.decode(self.allocator, payload);
            defer self.allocator.free(request.paths);
            if (request.flags != 0 or request.paths.len != 0) return error.InvalidAction;
            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            const cfg = try repository.config();
            if (request.action == contract.ACTION_LIST) {
                var output: std.ArrayList(u8) = .empty;
                defer output.deinit(self.allocator);
                var count: u32 = 0;
                if (cfg.user_name.len > 0) {
                    try output.appendSlice(self.allocator, "user.name=");
                    try output.appendSlice(self.allocator, cfg.user_name);
                    try output.append(self.allocator, '\n');
                    count += 1;
                }
                if (cfg.user_email.len > 0) {
                    try output.appendSlice(self.allocator, "user.email=");
                    try output.appendSlice(self.allocator, cfg.user_email);
                    try output.append(self.allocator, '\n');
                    count += 1;
                }
                return (contract.Result{ .kind = 11, .generation = session.mutation_generation, .count = count, .data = output.items }).encode(self.allocator);
            }
            const key = request.target orelse return error.MissingTarget;
            const current = if (std.mem.eql(u8, key, "user.name")) cfg.user_name else if (std.mem.eql(u8, key, "user.email")) cfg.user_email else return error.UnsupportedConfigKey;
            if (request.action == contract.ACTION_GET) return (contract.Result{ .kind = 11, .generation = session.mutation_generation, .count = 1, .data = current }).encode(self.allocator);
            if (self.backend.isReadOnly(session)) return error.ReadOnly;
            if (request.action != contract.ACTION_UPDATE and request.action != contract.ACTION_DELETE) return error.InvalidAction;
            const replacement = if (request.action == contract.ACTION_DELETE) "" else request.message orelse return error.MissingValue;
            const preserved_name = try self.allocator.dupe(u8, cfg.user_name);
            defer self.allocator.free(preserved_name);
            const preserved_email = try self.allocator.dupe(u8, cfg.user_email);
            defer self.allocator.free(preserved_email);
            if (std.mem.eql(u8, key, "user.name")) try cfg.setUser(replacement, preserved_email) else try cfg.setUser(preserved_name, replacement);
            try repository.setConfig(cfg);
            bumpGeneration(session);
            return self.mutationResult(session, 1);
        }

        fn objectOperation(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            const request = try contract.ObjectRequest.decode(self.allocator, payload);
            _ = session.repository orelse return error.RepositoryNotOpen;
            const oid = request.object_id orelse return error.MissingObject;
            const hash = try hashFromObjectId(oid);
            if (request.action != contract.ACTION_GET) return error.InvalidAction;
            const kind: plumbing.ObjectType = switch (request.kind) {
                1 => .commit,
                2 => .tree,
                3 => .blob,
                4 => .tag,
                else => .any,
            };
            const encoded = try self.backend.objectRead(self.allocator, session, kind, hash);
            defer self.allocator.free(encoded.data);
            return (contract.ObjectResult{ .kind = objectKind(encoded.kind), .object_id = objectId(&hash), .size_low = lowU32(encoded.data.len), .size_high = highU32(encoded.data.len), .data = encoded.data }).encode(self.allocator);
        }

        fn packImport(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            if (self.backend.isReadOnly(session)) return error.ReadOnly;
            const request = try contract.PackRequest.decode(self.allocator, payload);
            defer {
                self.allocator.free(request.wants);
                self.allocator.free(request.haves);
                self.allocator.free(request.updates);
            }
            switch (request.action) {
                contract.ACTION_BEGIN => {
                    try self.backend.packImportBegin(self.allocator, session);
                    return (contract.PackResult{ .handle = session.mutation_generation, .object_count = 0, .reference_count = 0 }).encode(self.allocator);
                },
                contract.ACTION_WRITE => {
                    try self.backend.packImportWrite(session, request.data orelse return error.MissingData);
                    return (contract.PackResult{ .handle = session.mutation_generation, .object_count = 0, .reference_count = 0 }).encode(self.allocator);
                },
                contract.ACTION_ABORT => {
                    self.backend.packImportAbort(session);
                    return (contract.PackResult{ .object_count = 0, .reference_count = 0 }).encode(self.allocator);
                },
                contract.ACTION_FINISH => {
                    const updates = try self.refUpdates(request.updates);
                    defer self.allocator.free(updates);
                    const imported = try self.backend.packImportFinish(session, updates);
                    bumpGeneration(session);
                    return (contract.PackResult{ .object_count = @intCast(imported.object_count), .reference_count = @intCast(imported.reference_count) }).encode(self.allocator);
                },
                else => return error.InvalidAction,
            }
        }

        fn packBuild(self: *Self, owner: u32, session: *Backend.Session, payload: []const u8) ![]u8 {
            const request = try contract.PackRequest.decode(self.allocator, payload);
            defer {
                self.allocator.free(request.wants);
                self.allocator.free(request.haves);
                self.allocator.free(request.updates);
            }
            if (request.action != contract.ACTION_CREATE) return error.InvalidAction;
            const wants = try objectIdsToHashes(self.allocator, request.wants);
            defer self.allocator.free(wants);
            const haves = try objectIdsToHashes(self.allocator, request.haves);
            defer self.allocator.free(haves);
            const built = try self.backend.packBuild(self.allocator, session, wants, haves);
            const handle = try self.putStream(owner, built.bytes);
            return (contract.PackResult{ .handle = handle, .object_count = @intCast(built.object_count), .reference_count = 0 }).encode(self.allocator);
        }

        fn refUpdates(self: *Self, requested: []const contract.RefUpdate) ![]memory.ReferenceUpdate {
            const updates = try self.allocator.alloc(memory.ReferenceUpdate, requested.len);
            errdefer self.allocator.free(updates);
            for (requested, 0..) |update, i| {
                const name = plumbing.ReferenceName.init(update.name);
                try name.validate();
                updates[i] = .{
                    .name = name,
                    .new_reference = if (update.new_value) |value| plumbing.Reference.newHashReference(name, try hashFromObjectId(value)) else null,
                    .expected = if (update.expected_value) |value| plumbing.Reference.newHashReference(name, try hashFromObjectId(value)) else null,
                    .require_absent = update.require_absent,
                };
            }
            return updates;
        }

        fn refTransaction(self: *Self, owner: u32, session: *Backend.Session, envelope: contract.RequestEnvelope) u32 {
            const request = contract.RefTransactionRequest.decode(self.allocator, envelope.payload) catch
                return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_PROTOCOL), 30);
            defer self.allocator.free(request.updates);

            if (request.action == contract.ACTION_BEGIN) {
                if (self.backend.isReadOnly(session) or request.handle != null or request.updates.len == 0)
                    return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 31);
                const validated = self.refUpdates(request.updates) catch
                    return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_REFERENCE), 31);
                self.allocator.free(validated);
                for (&self.transactions, 0..) |*transaction_slot, index| {
                    if (transaction_slot.request == null) {
                        transaction_slot.owner = owner;
                        transaction_slot.request = self.allocator.dupe(u8, envelope.payload) catch return 0;
                        const handle = makeHandle(.transaction, index, transaction_slot.generation);
                        const body = (contract.RefTransactionResult{ .handle = handle, .generation = self.backend.generation(session), .count = @intCast(request.updates.len) }).encode(self.allocator) catch return 0;
                        defer self.allocator.free(body);
                        const response = contract.encodeResponseEnvelope(self.allocator, envelope.opcode, @intCast(contract.STATUS_OK), envelope.request_id, body) catch return 0;
                        return self.putResult(owner, response);
                    }
                }
                return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_LIMIT), 31);
            }

            if (request.updates.len != 0 or request.handle == null)
                return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 32);
            const decoded = splitHandle(request.handle.?, .transaction) orelse
                return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 33);
            const transaction_slot = &self.transactions[decoded.index];
            if (transaction_slot.owner != owner or transaction_slot.generation != decoded.generation or transaction_slot.request == null)
                return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 34);

            if (request.action == contract.ACTION_ABORT) {
                const handle = request.handle.?;
                self.freeTransactionSlot(transaction_slot);
                const body = (contract.RefTransactionResult{ .handle = handle, .generation = self.backend.generation(session), .count = 0 }).encode(self.allocator) catch return 0;
                defer self.allocator.free(body);
                const response = contract.encodeResponseEnvelope(self.allocator, envelope.opcode, @intCast(contract.STATUS_OK), envelope.request_id, body) catch return 0;
                return self.putResult(owner, response);
            }
            if (request.action != contract.ACTION_FINISH or self.backend.isReadOnly(session))
                return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 35);

            const begun = contract.RefTransactionRequest.decode(self.allocator, transaction_slot.request.?) catch {
                self.freeTransactionSlot(transaction_slot);
                return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_PROTOCOL), 36);
            };
            defer self.allocator.free(begun.updates);
            const updates = self.refUpdates(begun.updates) catch {
                self.freeTransactionSlot(transaction_slot);
                return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_REFERENCE), 36);
            };
            defer self.allocator.free(updates);
            self.backend.applyReferenceUpdates(session, updates) catch |err| {
                self.freeTransactionSlot(transaction_slot);
                return self.classifiedErrorResponse(owner, envelope.opcode, envelope.request_id, err);
            };
            const count: u32 = @intCast(updates.len);
            self.freeTransactionSlot(transaction_slot);
            bumpGeneration(session);
            const body = (contract.RefTransactionResult{ .generation = self.backend.generation(session), .count = count }).encode(self.allocator) catch return 0;
            defer self.allocator.free(body);
            const response = contract.encodeResponseEnvelope(self.allocator, envelope.opcode, @intCast(contract.STATUS_OK), envelope.request_id, body) catch return 0;
            return self.putResult(owner, response);
        }

        fn freeTransactionSlot(self: *Self, slot: *TransactionSlot) void {
            self.allocator.free(slot.request.?);
            slot.request = null;
            slot.owner = 0;
            slot.generation = nextGeneration(slot.generation);
        }

        fn checkpoint(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            if (payload.len != 0) return error.UnexpectedPayload;
            const image = try self.backend.checkpoint(self.allocator, session);
            defer self.allocator.free(image);
            return (contract.SnapshotResult{ .generation = session.mutation_generation, .image = image }).encode(self.allocator);
        }

        fn mount(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            const request = try contract.MountRequest.decode(self.allocator, payload);
            switch (request.action) {
                contract.MOUNT_ATTACH, contract.MOUNT_DETACH => return (contract.Result{ .kind = 4, .generation = session.mutation_generation, .count = 1 }).encode(self.allocator),
                contract.MOUNT_STAT => return mount_ops.stat(self.allocator, session, request),
                contract.MOUNT_READ => return mount_ops.read(self.allocator, session, request),
                contract.MOUNT_WRITE => return mount_ops.write(self.allocator, &self.backend, session, request),
                contract.MOUNT_CREATE => return mount_ops.create(self.allocator, &self.backend, session, request),
                contract.MOUNT_REMOVE => return mount_ops.remove(self.allocator, &self.backend, session, request),
                contract.MOUNT_RENAME => return mount_ops.rename(self.allocator, &self.backend, session, request),
                contract.MOUNT_READDIR => return mount_ops.readDir(self.allocator, session, request),
                contract.MOUNT_CHMOD => return mount_ops.chmod(self.allocator, &self.backend, session, request),
                else => return error.InvalidAction,
            }
        }

        fn putStream(self: *Self, owner: u32, bytes: []u8) !u32 {
            for (&self.streams, 0..) |*slot, index| if (slot.bytes == null) {
                slot.owner = owner;
                slot.bytes = bytes;
                return makeHandle(.stream, index, slot.generation);
            };
            self.allocator.free(bytes);
            return error.TooManyStreams;
        }

        fn stream(self: *Self, owner: u32, payload: []const u8) ![]u8 {
            const request = try contract.StreamRequest.decode(self.allocator, payload);
            const handle = request.handle orelse return error.MissingHandle;
            const decoded = splitHandle(handle, .stream) orelse return error.InvalidHandle;
            const slot = &self.streams[decoded.index];
            if (slot.generation != decoded.generation or slot.owner != owner or slot.bytes == null) return error.InvalidHandle;
            if (request.action == contract.STREAM_CLOSE or request.action == contract.STREAM_ABORT) {
                self.freeStreamSlot(slot);
                return (contract.Result{ .kind = 5, .generation = 0, .handle = handle }).encode(self.allocator);
            }
            if (request.action != contract.STREAM_READ) return error.InvalidAction;
            const offset = joinU64(request.offset_low orelse 0, request.offset_high orelse 0);
            const bytes = slot.bytes.?;
            if (offset > bytes.len) return error.InvalidOffset;
            const count = @min(bytes.len - @as(usize, @intCast(offset)), @as(usize, contract.MAX_FIELD_BYTES));
            return (contract.StreamChunk{ .handle = handle, .offset_low = lowU32(offset), .offset_high = highU32(offset), .data = bytes[@intCast(offset)..][0..count], .done = offset + count == bytes.len }).encode(self.allocator);
        }

        fn freeStreamSlot(self: *Self, slot: *StreamSlot) void {
            self.allocator.free(slot.bytes.?);
            slot.bytes = null;
            slot.owner = 0;
            slot.generation = nextGeneration(slot.generation);
        }

        fn remoteStart(self: *Self, owner: u32, session: *Backend.Session, envelope: contract.RequestEnvelope) u32 {
            if (envelope.opcode == contract.OP_PUSH and self.backend.isReadOnly(session)) return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 6);
            const request = contract.RemoteRequest.decode(self.allocator, envelope.payload) catch return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_PROTOCOL), 6);
            defer self.allocator.free(request.refspecs);
            if (!validRemoteUrl(request.url)) return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_REMOTE), 1);
            if (request.flags != 0 or (envelope.opcode == contract.OP_PUSH and request.depth != null)) return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 14);
            const depth = request.depth orelse 0;
            if (depth > std.math.maxInt(i32)) return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 21);
            if (request.refspecs.len > 1) return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 15);
            const remote_name = request.remote orelse "origin";
            if (!validRemoteName(remote_name)) return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 16);
            if (envelope.opcode != contract.OP_CLONE and session.repository == null) return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_REPOSITORY), 7);
            if (envelope.opcode == contract.OP_CLONE and session.repository == null) self.backend.repositoryInit(session) catch |err| return self.classifiedErrorResponse(owner, envelope.opcode, envelope.request_id, err);
            for (&self.remotes, 0..) |*remote_slot, index| if (remote_slot.phase == .empty) {
                remote_slot.owner = owner;
                remote_slot.opcode = envelope.opcode;
                remote_slot.request_id = envelope.request_id;
                remote_slot.phase = .advertise;
                remote_slot.depth = depth;
                remote_slot.url = self.allocator.dupe(u8, request.url) catch return 0;
                remote_slot.remote_name = self.allocator.dupe(u8, remote_name) catch {
                    self.freeRemoteSlot(remote_slot);
                    return 0;
                };
                if (envelope.opcode == contract.OP_PULL) {
                    var repository = &session.repository.?;
                    const clean = self.parentWorktreeClean(session) catch {
                        self.freeRemoteSlot(remote_slot);
                        return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_REPOSITORY), 24);
                    };
                    if (!clean) {
                        self.freeRemoteSlot(remote_slot);
                        return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_REPOSITORY), 25);
                    }
                    remote_slot.base = repository.resolveRevision("HEAD") catch {
                        self.freeRemoteSlot(remote_slot);
                        return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_REFERENCE), 24);
                    };
                }
                if (envelope.opcode == contract.OP_PUSH) {
                    if (request.refspecs.len != 1) {
                        self.freeRemoteSlot(remote_slot);
                        return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 13);
                    }
                    if (!validFullRef(request.refspecs[0].key) or !validFullRef(request.refspecs[0].value)) {
                        self.freeRemoteSlot(remote_slot);
                        return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 17);
                    }
                    remote_slot.push_source = self.allocator.dupe(u8, request.refspecs[0].key) catch return 0;
                    remote_slot.push_dest = self.allocator.dupe(u8, request.refspecs[0].value) catch return 0;
                } else if (request.refspecs.len == 1) {
                    if (!validFullRef(request.refspecs[0].key) or !validFullRef(request.refspecs[0].value)) {
                        self.freeRemoteSlot(remote_slot);
                        return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 18);
                    }
                    if (envelope.opcode == contract.OP_CLONE and !std.mem.startsWith(u8, request.refspecs[0].value, "refs/heads/")) {
                        self.freeRemoteSlot(remote_slot);
                        return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 19);
                    }
                    if ((envelope.opcode == contract.OP_FETCH or envelope.opcode == contract.OP_PULL) and !remoteTrackingDestination(request.refspecs[0].value, remote_name)) {
                        self.freeRemoteSlot(remote_slot);
                        return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 20);
                    }
                    remote_slot.source_ref = self.allocator.dupe(u8, request.refspecs[0].key) catch {
                        self.freeRemoteSlot(remote_slot);
                        return 0;
                    };
                    remote_slot.target_ref = self.allocator.dupe(u8, request.refspecs[0].value) catch {
                        self.freeRemoteSlot(remote_slot);
                        return 0;
                    };
                }
                const exchange = makeHandle(.remote, index, remote_slot.generation);
                return self.emitHttpEffect(owner, remote_slot, exchange, "GET", infoRefsUrl(self.allocator, request.url, if (envelope.opcode == contract.OP_PUSH) "git-receive-pack" else "git-upload-pack") catch return 0, null);
            };
            return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_LIMIT), 7);
        }

        fn submoduleStart(self: *Self, owner: u32, session: *Backend.Session, envelope: contract.RequestEnvelope, request: contract.SubmoduleRequest) u32 {
            if (self.backend.isReadOnly(session) or request.object_id != null)
                return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 40);
            if (request.path) |path| validatePath(path) catch
                return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 41);
            const targets = self.loadSubmoduleTargets(session, request.path) catch
                return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_REPOSITORY), 40);
            if (targets.len == 0) {
                self.freeSubmoduleTargets(targets);
                return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_REFERENCE), 40);
            }
            for (&self.remotes, 0..) |*remote_slot, index| if (remote_slot.phase == .empty) {
                remote_slot.owner = owner;
                remote_slot.opcode = envelope.opcode;
                remote_slot.request_id = envelope.request_id;
                remote_slot.phase = .advertise;
                remote_slot.submodules = targets;
                remote_slot.url = self.allocator.dupe(u8, targets[0].url) catch {
                    self.freeRemoteSlot(remote_slot);
                    return 0;
                };
                const exchange = makeHandle(.remote, index, remote_slot.generation);
                return self.emitHttpEffect(owner, remote_slot, exchange, "GET", infoRefsUrl(self.allocator, targets[0].url, "git-upload-pack") catch return 0, null);
            };
            self.freeSubmoduleTargets(targets);
            return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_LIMIT), 40);
        }

        fn remoteContinue(self: *Self, owner: u32, session: *Backend.Session, envelope: contract.RequestEnvelope) u32 {
            const response = contract.HttpResponse.decode(self.allocator, envelope.payload) catch return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_PROTOCOL), 7);
            defer self.allocator.free(response.headers);
            const decoded = splitHandle(response.exchange, .remote) orelse return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 8);
            const remote_slot = &self.remotes[decoded.index];
            if (remote_slot.generation != decoded.generation or remote_slot.owner != owner or remote_slot.phase == .empty) return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 9);
            if (response.action == contract.HTTP_RESPONSE_ABORT) {
                const opcode = remote_slot.opcode;
                const request_id = remote_slot.request_id;
                self.freeRemoteSlot(remote_slot);
                return self.errorResponse(owner, opcode, request_id, @intCast(contract.ERROR_TRANSPORT_EFFECT), response.error_code orelse 1);
            }
            if (response.action == contract.HTTP_RESPONSE_BEGIN) {
                if (remote_slot.http_state != .awaiting_begin or response.status == null or response.data != null) return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_PROTOCOL), 13);
                const http_status = response.status.?;
                if (http_status < 200 or http_status >= 300) return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REMOTE), http_status);
                remote_slot.http_state = .receiving;
                return self.remoteAck(owner, remote_slot);
            }
            if (response.action == contract.HTTP_RESPONSE_CHUNK) {
                if (remote_slot.http_state != .receiving or response.status != null or response.headers.len != 0) return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_PROTOCOL), 14);
                const data = response.data orelse return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_PROTOCOL), 10);
                if (remote_slot.response.items.len + data.len > contract.MAX_PACK_BYTES) return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_LIMIT), 8);
                remote_slot.response.appendSlice(self.allocator, data) catch return 0;
                return self.remoteAck(owner, remote_slot);
            }
            if (response.action != contract.HTTP_RESPONSE_END or remote_slot.http_state != .receiving or response.status != null or response.headers.len != 0 or response.data != null) return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_PROTOCOL), 11);
            return switch (remote_slot.phase) {
                .advertise => self.remoteAdvertisement(owner, session, remote_slot, response.exchange),
                .upload => self.remoteUploadComplete(owner, session, remote_slot),
                .receive => self.remoteReceiveComplete(owner, session, remote_slot),
                .empty => unreachable,
            };
        }

        fn remoteAdvertisement(self: *Self, owner: u32, session: *Backend.Session, remote_slot: *RemoteSlot, exchange: u32) u32 {
            if (remote_slot.opcode == contract.OP_PUSH) return self.remotePushAdvertisement(owner, session, remote_slot, exchange);
            if (remote_slot.opcode == contract.OP_SUBMODULE) return self.submoduleAdvertisement(owner, session, remote_slot, exchange);
            const advertised = protocol.parseAdvertisedHead(self.allocator, remote_slot.response.items) catch {
                const opcode = remote_slot.opcode;
                const id = remote_slot.request_id;
                self.freeRemoteSlot(remote_slot);
                return self.errorResponse(owner, opcode, id, @intCast(contract.ERROR_REMOTE), 2);
            };
            defer if (advertised.target_ref) |name| self.allocator.free(name);
            const source_ref = remote_slot.source_ref orelse advertised.target_ref orelse {
                const opcode = remote_slot.opcode;
                const id = remote_slot.request_id;
                self.freeRemoteSlot(remote_slot);
                return self.errorResponse(owner, opcode, id, @intCast(contract.ERROR_REFERENCE), 2);
            };
            const target = protocol.findAdvertisedRef(remote_slot.response.items, source_ref) catch {
                const opcode = remote_slot.opcode;
                const id = remote_slot.request_id;
                self.freeRemoteSlot(remote_slot);
                return self.errorResponse(owner, opcode, id, @intCast(contract.ERROR_REFERENCE), 3);
            };
            if (remote_slot.depth != 0 and !protocol.advertisementSupportsCapability(remote_slot.response.items, "shallow")) {
                const opcode = remote_slot.opcode;
                const id = remote_slot.request_id;
                self.freeRemoteSlot(remote_slot);
                return self.errorResponse(owner, opcode, id, @intCast(contract.ERROR_REMOTE), 5);
            }
            if (remote_slot.source_ref == null) remote_slot.source_ref = self.allocator.dupe(u8, source_ref) catch return 0;
            if (remote_slot.target_ref == null) {
                remote_slot.target_ref = defaultRemoteDestination(self.allocator, remote_slot.opcode, remote_slot.remote_name.?, source_ref) catch {
                    const opcode = remote_slot.opcode;
                    const id = remote_slot.request_id;
                    self.freeRemoteSlot(remote_slot);
                    return self.errorResponse(owner, opcode, id, @intCast(contract.ERROR_REFERENCE), 4);
                };
            }
            var upload = packp.newUploadPackRequest(self.allocator);
            upload.upload_request.wants.append(self.allocator, target) catch {
                upload.deinit();
                return 0;
            };
            if (remote_slot.depth != 0) {
                upload.upload_request.capabilities.set("shallow", &.{}) catch {
                    upload.deinit();
                    return 0;
                };
                upload.upload_request.depth = .{ .commits = @intCast(remote_slot.depth) };
            }
            const current_shallows = self.backend.shallowGet(self.allocator, session) catch {
                upload.deinit();
                return 0;
            };
            defer self.allocator.free(current_shallows);
            if (current_shallows.len != 0 and !protocol.advertisementSupportsCapability(remote_slot.response.items, "shallow")) {
                upload.deinit();
                return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REMOTE), 6);
            }
            if (current_shallows.len != 0 and remote_slot.depth == 0) upload.upload_request.capabilities.set("shallow", &.{}) catch {
                upload.deinit();
                return 0;
            };
            upload.upload_request.shallows.appendSlice(self.allocator, current_shallows) catch {
                upload.deinit();
                return 0;
            };
            var repository = &(session.repository orelse return self.errorResponse(owner, remote_slot.opcode, remote_slot.request_id, @intCast(contract.ERROR_REPOSITORY), 9));
            var refs = repository.references() catch {
                upload.deinit();
                return 0;
            };
            defer refs.deinit();
            while (true) {
                const ref = refs.next() catch |err| switch (err) {
                    error.EndOfStream => break,
                };
                if (ref.type == .hash) upload.upload_haves.haves.append(self.allocator, ref.hash) catch {
                    upload.deinit();
                    return 0;
                };
            }
            const body = protocol.encodeUploadPackRequest(self.allocator, &upload) catch {
                upload.deinit();
                return 0;
            };
            const body_handle = self.putStream(owner, body) catch {
                upload.deinit();
                return 0;
            };
            remote_slot.response.clearRetainingCapacity();
            remote_slot.phase = .upload;
            remote_slot.http_state = .awaiting_begin;
            remote_slot.upload = upload;
            remote_slot.target = target;
            const url = serviceUrl(self.allocator, remote_slot.url.?, "git-upload-pack") catch return 0;
            return self.emitHttpEffect(owner, remote_slot, exchange, "POST", url, body_handle);
        }

        fn submoduleAdvertisement(self: *Self, owner: u32, session: *Backend.Session, remote_slot: *RemoteSlot, exchange: u32) u32 {
            _ = session.repository orelse return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REPOSITORY), 40);
            const target = &remote_slot.submodules[remote_slot.submodule_index];
            const advertised = protocol.parseAdvertisedHead(self.allocator, remote_slot.response.items) catch
                return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REMOTE), 40);
            if (advertised.target_ref) |name| self.allocator.free(name);
            var upload = packp.newUploadPackRequest(self.allocator);
            upload.upload_request.wants.append(self.allocator, target.gitlink) catch {
                upload.deinit();
                return 0;
            };
            if (self.backend.submoduleHead(session, target.path) catch null) |head|
                upload.upload_haves.haves.append(self.allocator, head) catch {
                    upload.deinit();
                    return 0;
                };
            const body = protocol.encodeUploadPackRequest(self.allocator, &upload) catch {
                upload.deinit();
                return 0;
            };
            const body_handle = self.putStream(owner, body) catch {
                upload.deinit();
                return 0;
            };
            remote_slot.response.clearRetainingCapacity();
            remote_slot.phase = .upload;
            remote_slot.http_state = .awaiting_begin;
            remote_slot.upload = upload;
            remote_slot.target = target.gitlink;
            const url = serviceUrl(self.allocator, target.url, "git-upload-pack") catch return 0;
            return self.emitHttpEffect(owner, remote_slot, exchange, "POST", url, body_handle);
        }

        fn remotePushAdvertisement(self: *Self, owner: u32, session: *Backend.Session, remote_slot: *RemoteSlot, exchange: u32) u32 {
            var repository = &(session.repository orelse return self.errorResponse(owner, remote_slot.opcode, remote_slot.request_id, @intCast(contract.ERROR_REPOSITORY), 10));
            const new_hash = repository.resolveRevision(remote_slot.push_source.?) catch {
                const id = remote_slot.request_id;
                self.freeRemoteSlot(remote_slot);
                return self.errorResponse(owner, contract.OP_PUSH, id, @intCast(contract.ERROR_REFERENCE), 1);
            };
            const old_hash = protocol.findAdvertisedRef(remote_slot.response.items, remote_slot.push_dest.?) catch plumbing.ZeroHash;
            const no_haves: []const plumbing.Hash = &.{};
            const one_have = [_]plumbing.Hash{old_hash};
            const haves: []const plumbing.Hash = if (old_hash.isZero()) no_haves else &one_have;
            const built = self.backend.packBuild(self.allocator, session, &.{new_hash}, haves) catch {
                const id = remote_slot.request_id;
                self.freeRemoteSlot(remote_slot);
                return self.errorResponse(owner, contract.OP_PUSH, id, @intCast(contract.ERROR_PACK), 4);
            };
            defer self.allocator.free(built.bytes);
            const body = protocol.encodeReceivePackRequest(self.allocator, old_hash, new_hash, remote_slot.push_dest.?, built.bytes) catch return 0;
            const body_handle = self.putStream(owner, body) catch return 0;
            remote_slot.response.clearRetainingCapacity();
            remote_slot.phase = .receive;
            remote_slot.http_state = .awaiting_begin;
            remote_slot.target = new_hash;
            const url = serviceUrl(self.allocator, remote_slot.url.?, "git-receive-pack") catch return 0;
            return self.emitHttpEffectWithType(owner, remote_slot, exchange, "POST", url, body_handle, "application/x-git-receive-pack-request");
        }

        fn remoteReceiveComplete(self: *Self, owner: u32, session: *Backend.Session, remote_slot: *RemoteSlot) u32 {
            const request_id = remote_slot.request_id;
            if (std.mem.indexOf(u8, remote_slot.response.items, "unpack ok") == null or std.mem.indexOf(u8, remote_slot.response.items, "ng ") != null) {
                self.freeRemoteSlot(remote_slot);
                return self.errorResponse(owner, contract.OP_PUSH, request_id, @intCast(contract.ERROR_REMOTE), 21);
            }
            const updated = contract.ReferenceResult{ .name = remote_slot.push_dest.?, .kind = 1, .object_id = objectId(&remote_slot.target) };
            const body = (contract.RemoteResult{ .handle = 0, .state = 2, .generation = session.mutation_generation, .updated = &.{updated} }).encode(self.allocator) catch return 0;
            defer self.allocator.free(body);
            self.freeRemoteSlot(remote_slot);
            const bytes = contract.encodeResponseEnvelope(self.allocator, @intCast(contract.OP_PUSH), @intCast(contract.STATUS_OK), request_id, body) catch return 0;
            return self.putResult(owner, bytes);
        }

        fn remoteUploadComplete(self: *Self, owner: u32, session: *Backend.Session, remote_slot: *RemoteSlot) u32 {
            const opcode = remote_slot.opcode;
            const request_id = remote_slot.request_id;
            const requested_shallows = remote_slot.upload.?.upload_request.shallows.items;
            const parsed = protocol.parseUploadResponse(self.allocator, remote_slot.response.items, requested_shallows, remote_slot.depth != 0 or requested_shallows.len != 0) catch {
                self.freeRemoteSlot(remote_slot);
                return self.errorResponse(owner, opcode, request_id, @intCast(contract.ERROR_REMOTE), 4);
            };
            defer self.allocator.free(parsed.shallows);
            const pack = remote_slot.response.items[parsed.pack_offset..];
            if (opcode == contract.OP_SUBMODULE) return self.submoduleUploadComplete(owner, session, remote_slot, parsed, pack);
            self.backend.packImportBegin(self.allocator, session) catch {
                self.freeRemoteSlot(remote_slot);
                return self.errorResponse(owner, opcode, request_id, @intCast(contract.ERROR_PACK), 1);
            };
            self.backend.packImportWrite(session, pack) catch {
                self.backend.packImportAbort(session);
                self.freeRemoteSlot(remote_slot);
                return self.errorResponse(owner, opcode, request_id, @intCast(contract.ERROR_PACK), 2);
            };
            const name = plumbing.ReferenceName.init(remote_slot.target_ref.?);
            const direct_update = [_]memory.ReferenceUpdate{.{ .name = name, .new_reference = plumbing.Reference.newHashReference(name, remote_slot.target) }};
            const import_updates: []const memory.ReferenceUpdate = if (opcode == contract.OP_CLONE or opcode == contract.OP_PULL) &.{} else &direct_update;
            const imported = self.backend.packImportFinish(session, import_updates) catch {
                self.backend.packImportAbort(session);
                self.freeRemoteSlot(remote_slot);
                return self.errorResponse(owner, opcode, request_id, @intCast(contract.ERROR_PACK), 3);
            };
            var repository = &session.repository.?;
            if (opcode == contract.OP_CLONE) {
                const source_name = plumbing.ReferenceName.init(remote_slot.source_ref.?);
                if (!source_name.isBranch() or !name.isBranch()) return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REFERENCE), 5);
                var tracking_buf: [contract.MAX_REF_BYTES]u8 = undefined;
                const tracking_name = plumbing.newRemoteReferenceName(remote_slot.remote_name.?, source_name.short(), &tracking_buf) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REFERENCE), 6);
                self.backend.remoteApplyBegin(self.allocator, session, 1, name.raw, source_name.raw, remote_slot.remote_name.?, remote_slot.url.?, remote_slot.target) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REPOSITORY), 21);
                const old_head = repository.storer.reference(plumbing.HEAD) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REFERENCE), 7);
                defer repository.storer.freeReference(old_head);
                const updates = [_]memory.ReferenceUpdate{
                    .{ .name = name, .new_reference = plumbing.Reference.newHashReference(name, remote_slot.target), .require_absent = true },
                    .{ .name = tracking_name, .new_reference = plumbing.Reference.newHashReference(tracking_name, remote_slot.target), .require_absent = true },
                    .{ .name = plumbing.HEAD, .new_reference = plumbing.Reference.newSymbolicReference(plumbing.HEAD, name), .expected = old_head },
                };
                self.backend.applyReferenceUpdates(session, &updates) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REFERENCE), 8);
                if (parsed.has_update) self.backend.shallowSet(session, parsed.shallows) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REPOSITORY), 18);
                const fetch_spec = std.fmt.allocPrint(self.allocator, "+refs/heads/*:refs/remotes/{s}/*", .{remote_slot.remote_name.?}) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_INTERNAL), 1);
                defer self.allocator.free(fetch_spec);
                _ = repository.createRemoteFull(remote_slot.remote_name.?, &.{remote_slot.url.?}, &.{fetch_spec}, false) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REPOSITORY), 11);
                repository.createBranch(name.short(), remote_slot.remote_name.?, remote_slot.source_ref.?) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REPOSITORY), 12);
                var wt = repository.worktree() catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REPOSITORY), 13);
                wt.checkout(.{ .branch = name, .force = true }) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REPOSITORY), 14);
                self.syncConfiguredGitlinks(session) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REPOSITORY), 19);
                self.backend.remoteApplyFinish(session) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REPOSITORY), 22);
            } else if (opcode == contract.OP_PULL) {
                const head = repository.storer.reference(plumbing.HEAD) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REFERENCE), 10);
                defer repository.storer.freeReference(head);
                if (head.type != .symbolic or !head.target.isBranch()) return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REFERENCE), 11);
                const head_target_raw = self.allocator.dupe(u8, head.target.raw) catch return 0;
                defer self.allocator.free(head_target_raw);
                const head_target = plumbing.ReferenceName.init(head_target_raw);
                const old_tip = remote_slot.base;
                const current_tip = repository.resolveRevision("HEAD") catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REFERENCE), 25);
                if (!current_tip.eql(old_tip)) return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REFERENCE), 26);
                const fast_forward = self.commitIsAncestor(session, old_tip, remote_slot.target) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REFERENCE), 15);
                if (!fast_forward) return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REFERENCE), 16);
                self.backend.remoteApplyBegin(self.allocator, session, 2, head_target.raw, "", "", "", remote_slot.target) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REPOSITORY), 21);
                const updates = [_]memory.ReferenceUpdate{
                    .{ .name = name, .new_reference = plumbing.Reference.newHashReference(name, remote_slot.target) },
                    .{ .name = head_target, .new_reference = plumbing.Reference.newHashReference(head_target, remote_slot.target), .expected = plumbing.Reference.newHashReference(head_target, old_tip) },
                };
                self.backend.applyReferenceUpdates(session, &updates) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REFERENCE), 17);
                if (parsed.has_update) self.backend.shallowSet(session, parsed.shallows) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REPOSITORY), 18);
                var wt = repository.worktree() catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REPOSITORY), 15);
                wt.checkout(.{ .branch = head_target, .force = true }) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REPOSITORY), 16);
                self.syncConfiguredGitlinks(session) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REPOSITORY), 20);
                self.backend.remoteApplyFinish(session) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REPOSITORY), 22);
            } else if (parsed.has_update) {
                self.backend.shallowSet(session, parsed.shallows) catch return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REPOSITORY), 18);
            }
            bumpGeneration(session);
            const updated_ref = plumbing.Reference.newHashReference(name, remote_slot.target);
            const updated = referenceValue(&updated_ref);
            const body = (contract.RemoteResult{ .handle = 0, .state = 2, .generation = session.mutation_generation, .updated = &.{updated} }).encode(self.allocator) catch return 0;
            defer self.allocator.free(body);
            self.freeRemoteSlot(remote_slot);
            const bytes = contract.encodeResponseEnvelope(self.allocator, opcode, @intCast(contract.STATUS_OK), request_id, body) catch return 0;
            _ = imported;
            return self.putResult(owner, bytes);
        }

        fn commitIsAncestor(self: *Self, session: *Backend.Session, ancestor: plumbing.Hash, descendant: plumbing.Hash) !bool {
            if (ancestor.eql(descendant)) return true;
            const repository = &(session.repository orelse return error.RepositoryNotOpen);
            const anc = try object.getCommit(self.allocator, repository.storer, ancestor);
            defer object.freeCommit(self.allocator, anc);
            const desc = try object.getCommit(self.allocator, repository.storer, descendant);
            defer object.freeCommit(self.allocator, desc);
            return try object.isAncestor(anc, desc);
        }

        fn submoduleUploadComplete(self: *Self, owner: u32, session: *Backend.Session, remote_slot: *RemoteSlot, parsed: protocol.ParsedUploadResponse, pack: []const u8) u32 {
            _ = parsed;
            const target = &remote_slot.submodules[remote_slot.submodule_index];
            self.backend.submoduleImportBegin(self.allocator, session, target.path) catch
                return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_REPOSITORY), 41);
            self.backend.submoduleImportWrite(session, target.path, pack) catch {
                self.backend.submoduleImportAbort(self.allocator, session, target.path);
                return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_PACK), 41);
            };
            self.backend.submoduleImportFinish(session, target.path, target.gitlink) catch
                return self.finishRemoteError(owner, remote_slot, @intCast(contract.ERROR_PACK), 42);

            remote_slot.submodule_index += 1;
            if (remote_slot.submodule_index < remote_slot.submodules.len) {
                const next = &remote_slot.submodules[remote_slot.submodule_index];
                self.allocator.free(remote_slot.url.?);
                remote_slot.url = self.allocator.dupe(u8, next.url) catch return 0;
                if (remote_slot.upload) |*upload| upload.deinit();
                remote_slot.upload = null;
                remote_slot.response.clearRetainingCapacity();
                remote_slot.phase = .advertise;
                remote_slot.http_state = .awaiting_begin;
                const remote_index = (@intFromPtr(remote_slot) - @intFromPtr(&self.remotes[0])) / @sizeOf(RemoteSlot);
                const exchange = makeHandle(.remote, remote_index, remote_slot.generation);
                return self.emitHttpEffect(owner, remote_slot, exchange, "GET", infoRefsUrl(self.allocator, next.url, "git-upload-pack") catch return 0, null);
            }

            bumpGeneration(session);
            const entries = self.allocator.alloc(contract.SubmoduleEntry, remote_slot.submodules.len) catch return 0;
            defer self.allocator.free(entries);
            for (remote_slot.submodules, 0..) |*completed, index| {
                entries[index] = .{
                    .name = completed.name,
                    .path = completed.path,
                    .url = completed.url,
                    .gitlink = objectId(&completed.gitlink),
                    .head = objectId(&completed.gitlink),
                    .state = 1,
                };
            }
            const body = (contract.SubmoduleResult{ .generation = session.mutation_generation, .entries = entries }).encode(self.allocator) catch return 0;
            defer self.allocator.free(body);
            const request_id = remote_slot.request_id;
            self.freeRemoteSlot(remote_slot);
            const response = contract.encodeResponseEnvelope(self.allocator, @intCast(contract.OP_SUBMODULE), @intCast(contract.STATUS_OK), request_id, body) catch return 0;
            return self.putResult(owner, response);
        }

        fn remoteCancel(self: *Self, owner: u32, envelope: contract.RequestEnvelope) u32 {
            const req = contract.StreamRequest.decode(self.allocator, envelope.payload) catch return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_PROTOCOL), 12);
            const handle = req.handle orelse return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 10);
            const decoded = splitHandle(handle, .remote) orelse return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 11);
            const slot = &self.remotes[decoded.index];
            if (slot.owner != owner or slot.generation != decoded.generation or slot.phase == .empty) return self.errorResponse(owner, envelope.opcode, envelope.request_id, @intCast(contract.ERROR_USAGE), 12);
            self.freeRemoteSlot(slot);
            const body = (contract.Result{ .kind = 6, .generation = 0, .handle = handle }).encode(self.allocator) catch return 0;
            defer self.allocator.free(body);
            const bytes = contract.encodeResponseEnvelope(self.allocator, envelope.opcode, @intCast(contract.STATUS_OK), envelope.request_id, body) catch return 0;
            return self.putResult(owner, bytes);
        }

        fn remoteAck(self: *Self, owner: u32, slot: *RemoteSlot) u32 {
            const body = (contract.Result{ .kind = 6, .generation = 0 }).encode(self.allocator) catch return 0;
            defer self.allocator.free(body);
            const bytes = contract.encodeResponseEnvelope(self.allocator, @intCast(contract.OP_HTTP_EFFECT), @intCast(contract.STATUS_OK), slot.request_id, body) catch return 0;
            return self.putResult(owner, bytes);
        }
        fn finishRemoteError(self: *Self, owner: u32, slot: *RemoteSlot, domain: u16, code: u16) u32 {
            const opcode = slot.opcode;
            const request_id = slot.request_id;
            self.freeRemoteSlot(slot);
            return self.errorResponse(owner, opcode, request_id, domain, code);
        }
        fn emitHttpEffect(self: *Self, owner: u32, slot: *RemoteSlot, exchange: u32, method: []const u8, owned_url: []u8, body_handle: ?u32) u32 {
            return self.emitHttpEffectWithType(owner, slot, exchange, method, owned_url, body_handle, "application/x-git-upload-pack-request");
        }
        fn emitHttpEffectWithType(self: *Self, owner: u32, slot: *RemoteSlot, exchange: u32, method: []const u8, owned_url: []u8, body_handle: ?u32, content_type: []const u8) u32 {
            defer self.allocator.free(owned_url);
            const headers: []const contract.StringPair = if (std.mem.eql(u8, method, "POST")) &[_]contract.StringPair{.{ .key = "content-type", .value = content_type }} else &.{};
            const body = (contract.HttpEffect{ .exchange = exchange, .method = method, .path = owned_url, .headers = headers, .body = body_handle }).encode(self.allocator) catch return 0;
            defer self.allocator.free(body);
            const bytes = contract.encodeResponseEnvelope(self.allocator, slot.opcode, @intCast(contract.STATUS_EFFECT), slot.request_id, body) catch return 0;
            return self.putResult(owner, bytes);
        }

        fn loadSubmoduleTargets(self: *Self, session: *Backend.Session, wanted_path: ?[]const u8) ![]SubmoduleTarget {
            const modules_bytes = try readBoundedFile(self.allocator, session.filesystem, ".gitmodules", contract.MAX_FIELD_BYTES);
            defer self.allocator.free(modules_bytes);
            const info = try session.filesystem.lstat(".gitmodules");
            if (info.isSymlink()) return error.GitModulesSymlink;
            var modules = try gitconfig.Modules.create(self.allocator);
            defer modules.deinit();
            try modules.unmarshal(modules_bytes);

            var repository = &(session.repository orelse return error.RepositoryNotOpen);
            const origin = repository.remote("origin") catch null;
            const parent_url: ?[]const u8 = if (origin) |remote_value| if (remote_value.config.urls.len > 0) remote_value.config.urls[0] else null else null;
            const capacity = if (wanted_path == null) modules.submodules.count() else @min(modules.submodules.count(), 1);
            if (capacity == 0) return &.{};
            const targets = try self.allocator.alloc(SubmoduleTarget, capacity);
            var count: usize = 0;
            errdefer {
                for (targets[0..count]) |target| {
                    self.allocator.free(target.name);
                    self.allocator.free(target.path);
                    self.allocator.free(target.url);
                }
                self.allocator.free(targets);
            }
            var iterator = modules.submodules.iterator();
            while (iterator.next()) |item| {
                const module = item.value_ptr.*;
                try module.validate();
                try validatePath(module.path);
                if (wanted_path) |path| if (!std.mem.eql(u8, path, module.path)) continue;
                const gitlink = try self.backend.gitlink(session, module.path) orelse return error.MissingGitlink;
                const url = try resolveSubmoduleHttpUrl(self.allocator, parent_url, module.url);
                errdefer self.allocator.free(url);
                const name = try self.allocator.dupe(u8, module.name);
                errdefer self.allocator.free(name);
                const path = try self.allocator.dupe(u8, module.path);
                errdefer self.allocator.free(path);
                targets[count] = .{ .name = name, .path = path, .url = url, .gitlink = gitlink };
                count += 1;
            }
            if (count == 0) {
                self.allocator.free(targets);
                return &.{};
            }
            if (count < targets.len) {
                const resized = try self.allocator.realloc(targets, count);
                std.mem.sort(SubmoduleTarget, resized, {}, submoduleTargetLess);
                return resized;
            }
            std.mem.sort(SubmoduleTarget, targets, {}, submoduleTargetLess);
            return targets;
        }

        fn freeSubmoduleTargets(self: *Self, targets: []SubmoduleTarget) void {
            for (targets) |target| {
                self.allocator.free(target.name);
                self.allocator.free(target.path);
                self.allocator.free(target.url);
            }
            if (targets.len > 0) self.allocator.free(targets);
        }

        fn freeRemoteSlot(self: *Self, slot: *RemoteSlot) void {
            if (slot.url) |url| self.allocator.free(url);
            if (slot.remote_name) |remote_name| self.allocator.free(remote_name);
            if (slot.source_ref) |name| self.allocator.free(name);
            if (slot.target_ref) |name| self.allocator.free(name);
            if (slot.push_source) |source| self.allocator.free(source);
            if (slot.push_dest) |dest| self.allocator.free(dest);
            if (slot.submodules.len > 0) self.freeSubmoduleTargets(slot.submodules);
            if (slot.upload) |*upload| upload.deinit();
            slot.response.deinit(self.allocator);
            const generation = nextGeneration(slot.generation);
            slot.* = .{ .generation = generation };
        }

        fn restore(self: *Self, session: *Backend.Session, payload: []const u8) ![]u8 {
            if (self.backend.isReadOnly(session)) return error.ReadOnly;
            const snapshot = try contract.SnapshotResult.decode(self.allocator, payload);
            try self.backend.restore(self.allocator, session, snapshot.image);
            bumpGeneration(session);
            return self.mutationResult(session, 1);
        }

        fn mutationResult(self: *Self, session: *Backend.Session, count: u32) ![]u8 {
            return (contract.Result{ .kind = 3, .generation = session.mutation_generation, .count = count }).encode(self.allocator);
        }

        pub fn resultLen(self: *Self, handle: u32) u32 {
            const decoded = splitHandle(handle, .result) orelse return 0;
            const slot = &self.results[decoded.index];
            if (slot.generation != decoded.generation) return 0;
            return @intCast((slot.bytes orelse return 0).len);
        }

        pub fn resultRead(self: *Self, handle: u32, offset: u32, out: []u8) u32 {
            const decoded = splitHandle(handle, .result) orelse return 0;
            const slot = &self.results[decoded.index];
            if (slot.generation != decoded.generation) return 0;
            const bytes = slot.bytes orelse return 0;
            const start: usize = offset;
            if (start >= bytes.len) return 0;
            const count = @min(out.len, bytes.len - start);
            @memcpy(out[0..count], bytes[start..][0..count]);
            return @intCast(count);
        }

        pub fn resultFree(self: *Self, handle: u32) u32 {
            const decoded = splitHandle(handle, .result) orelse return 1;
            const slot = &self.results[decoded.index];
            if (slot.generation != decoded.generation or slot.bytes == null) return 1;
            self.allocator.free(slot.bytes.?);
            slot.bytes = null;
            slot.owner = 0;
            slot.generation = nextGeneration(slot.generation);
            return 0;
        }
    };
}

const validatePath = paths_mod.validate;
const validateDirectoryPath = paths_mod.validateDirectory;
