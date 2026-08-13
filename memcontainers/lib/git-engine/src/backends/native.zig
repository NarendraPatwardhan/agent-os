const std = @import("std");
const contract = @import("git_zig");
const fs = @import("fs");
const filesystem = @import("filesystem");
const memory = @import("memory");
const plumbing = @import("plumbing");
const repo = @import("repo");
const remote = @import("remote");
const remote_fs = @import("remote_pack_import_filesystem");

const Repository = repo.RepositoryFor(filesystem.StorageOs, fs.Os);
const PackImport = remote_fs.FilesystemPackImportSessionFor(fs.Os);
const remote_transaction = "agentos-remote-transaction";
const remote_transaction_tmp = "agentos-remote-transaction.tmp";

pub const Native = struct {
    io: std.Io,

    pub const Session = struct {
        filesystem: *fs.Os,
        dot_git_fs: *fs.Os,
        storage: *filesystem.StorageOs,
        repository: ?Repository = null,
        read_only: bool,
        mutation_generation: u32 = 1,
        pack_import: ?PackImport = null,
        submodule_import: ?SubmoduleImport = null,
        sparse_paths: []const []const u8 = &.{},
        remote_apply_pending: bool = false,
    };

    const SubmoduleImport = struct {
        path: []u8,
        storage: *filesystem.StorageOs,
        worktree: *fs.Os,
        importer: PackImport,
    };

    pub fn kind(_: *Native) u16 {
        return @intCast(contract.BACKEND_NATIVE);
    }
    pub fn capabilities(_: *Native) u32 {
        return @intCast(contract.CAPABILITY_CORE);
    }

    pub fn sessionInit(self: *Native, allocator: std.mem.Allocator, config: contract.SessionConfig) !Session {
        if (config.backend != @as(u16, @intCast(contract.BACKEND_NATIVE)) or config.root.len == 0 or config.root.len > contract.MAX_PATH_BYTES or config.restore != null) return error.BadConfig;

        const worktree_fs = try allocator.create(fs.Os);
        errdefer allocator.destroy(worktree_fs);
        worktree_fs.* = try fs.Os.initWithOptions(allocator, self.io, config.root, .{ .secure_beneath = true });
        errdefer worktree_fs.deinit();

        try worktree_fs.mkdirAll(".git", fs.Mode.dir);
        const dot_git_fs = try allocator.create(fs.Os);
        errdefer allocator.destroy(dot_git_fs);
        dot_git_fs.* = try worktree_fs.chroot(".git");
        errdefer dot_git_fs.deinit();

        const storage = try filesystem.newStorageOsWithOptions(allocator, dot_git_fs, null, .{
            .clock = memory.Clock.fixedClock(memory.Time.unix(0, 0)),
        });
        errdefer {
            storage.deinit();
            allocator.destroy(storage);
        }

        try recoverRemoteApply(allocator, worktree_fs, dot_git_fs, storage);

        return .{
            .filesystem = worktree_fs,
            .dot_git_fs = dot_git_fs,
            .storage = storage,
            .read_only = config.read_only,
        };
    }

    pub fn sessionDeinit(_: *Native, allocator: std.mem.Allocator, session: *Session) void {
        if (session.pack_import) |*import| import.deinit();
        clearSubmoduleImport(allocator, session);
        freeSparsePaths(allocator, session.sparse_paths);
        session.storage.deinit();
        allocator.destroy(session.storage);
        session.dot_git_fs.deinit();
        allocator.destroy(session.dot_git_fs);
        session.filesystem.deinit();
        allocator.destroy(session.filesystem);
        session.* = undefined;
    }

    pub fn isReadOnly(_: *Native, session: *const Session) bool {
        return session.read_only;
    }
    pub fn generation(_: *Native, session: *const Session) u32 {
        return session.mutation_generation;
    }
    pub fn sparsePaths(_: *Native, session: *const Session) []const []const u8 {
        return session.sparse_paths;
    }
    pub fn setSparsePaths(_: *Native, allocator: std.mem.Allocator, session: *Session, paths: []const []const u8) !void {
        const replacement = try cloneSparsePaths(allocator, paths);
        freeSparsePaths(allocator, session.sparse_paths);
        session.sparse_paths = replacement;
    }

    pub fn repositoryInit(_: *Native, session: *Session) !void {
        if (session.repository != null) return error.RepositoryAlreadyExists;
        try session.storage.initLayout();
        const head = plumbing.Reference.newSymbolicReference(plumbing.HEAD, plumbing.master);
        try session.storage.applyReferenceUpdatesDurable(&.{.{ .name = plumbing.HEAD, .new_reference = head }});
        session.repository = repo.newRepositoryFor(filesystem.StorageOs, fs.Os, session.storage, session.filesystem);
        session.mutation_generation +%= 1;
        if (session.mutation_generation == 0) session.mutation_generation = 1;
    }

    pub fn repositoryOpen(_: *Native, session: *Session) !void {
        if (session.repository != null) return error.RepositoryAlreadyOpen;
        const head = try session.storage.reference(plumbing.HEAD);
        defer session.storage.freeReference(head);
        const cfg = try session.storage.config();
        try repo.verifyExtensions(cfg);
        session.repository = repo.newRepositoryFor(filesystem.StorageOs, fs.Os, session.storage, session.filesystem);
    }

    pub fn checkpoint(_: *Native, allocator: std.mem.Allocator, session: *Session) ![]u8 {
        if (session.pack_import != null or session.submodule_import != null) return error.MutationInProgress;
        try session.storage.recoverReferenceTransactions();
        try session.filesystem.syncTree();
        return allocator.alloc(u8, 0);
    }

    pub fn restore(_: *Native, _: std.mem.Allocator, _: *Session, _: []const u8) !void {
        return error.NativeRepositoryIsDurable;
    }

    pub fn packImportBegin(_: *Native, allocator: std.mem.Allocator, session: *Session) !void {
        if (session.pack_import) |*old| old.deinit();
        session.pack_import = PackImport.init(allocator, session.storage, .{ .max_pack_bytes = contract.MAX_PACK_BYTES, .max_objects = contract.MAX_PACK_OBJECTS });
    }
    pub fn packImportWrite(_: *Native, session: *Session, bytes: []const u8) !void {
        const import = if (session.pack_import) |*value| value else return error.ImportNotStarted;
        try import.write(bytes);
    }
    pub fn packImportFinish(_: *Native, session: *Session, updates: []const memory.ReferenceUpdate) !struct { object_count: usize, reference_count: usize } {
        const import = if (session.pack_import) |*value| value else return error.ImportNotStarted;
        const result = try import.finish(updates);
        return .{ .object_count = result.object_count, .reference_count = result.reference_count };
    }
    pub fn packImportAbort(_: *Native, session: *Session) void {
        if (session.pack_import) |*value| value.abort();
    }
    pub fn packBuild(_: *Native, allocator: std.mem.Allocator, session: *Session, wants: []const plumbing.Hash, haves: []const plumbing.Hash) !struct { bytes: []u8, object_count: usize } {
        const built = try remote.buildPack(allocator, session.storage, wants, haves, .{});
        return .{ .bytes = built.bytes, .object_count = built.object_count };
    }

    /// Filesystem shallow() returns storage-owned data; duplicate it to match
    /// Browser.shallowGet and keep callers independent of subsequent writes.
    pub fn shallowGet(_: *Native, allocator: std.mem.Allocator, session: *Session) ![]plumbing.Hash {
        const commits = try session.storage.shallow();
        return allocator.dupe(plumbing.Hash, commits);
    }

    pub fn shallowSet(_: *Native, session: *Session, commits: []const plumbing.Hash) !void {
        try session.storage.setShallow(commits);
    }

    /// Filesystem storage validates expected-old values, journals old/new
    /// states, and recovers a process death before the next open returns.
    pub fn applyReferenceUpdates(_: *Native, session: *Session, updates: []const memory.ReferenceUpdate) !void {
        try session.storage.applyReferenceUpdatesDurable(updates);
    }

    pub fn remoteApplyBegin(_: *Native, allocator: std.mem.Allocator, session: *Session, transaction_kind: u8, branch: []const u8, source: []const u8, remote_name: []const u8, url: []const u8, target: plumbing.Hash) !void {
        try writeRemoteApply(allocator, session.dot_git_fs, transaction_kind, branch, source, remote_name, url, target);
        session.remote_apply_pending = true;
    }

    pub fn remoteApplyFinish(_: *Native, session: *Session) !void {
        try session.filesystem.syncTree();
        session.dot_git_fs.remove(remote_transaction) catch |err| switch (err) {
            error.NotExist => {},
            else => return err,
        };
        try session.dot_git_fs.syncRoot();
        session.remote_apply_pending = false;
    }

    pub fn hasPendingRemoteApply(_: *Native, session: *const Session) bool {
        return session.remote_apply_pending;
    }

    /// Stage an exact commit gitlink and persist the index atomically through
    /// the filesystem index writer. setIndexOwned preserves a cached pointer.
    pub fn stageGitlink(_: *Native, session: *Session, path: []const u8, hash: plumbing.Hash) !void {
        const index = try session.storage.index();
        const entry = index.entry(path) catch |err| switch (err) {
            error.EntryNotFound => try index.add(path),
            else => return err,
        };
        entry.hash = hash;
        entry.mode = 0o160000;
        entry.stage = 0;
        try session.storage.setIndexOwned(index);
    }

    pub fn gitlink(_: *Native, session: *Session, path: []const u8) !?plumbing.Hash {
        const index = try session.storage.index();
        const entry = index.entry(path) catch |err| switch (err) {
            error.EntryNotFound => return null,
            else => return err,
        };
        return if (entry.mode == 0o160000) entry.hash else null;
    }

    /// Filesystem storage owns and caches the encoded object. Copy its bytes
    /// into the engine response lifetime; storage teardown releases the object.
    pub fn objectRead(_: *Native, allocator: std.mem.Allocator, session: *Session, requested_kind: plumbing.ObjectType, hash: plumbing.Hash) !struct { kind: plumbing.ObjectType, data: []u8 } {
        const encoded = try session.storage.encodedObject(requested_kind, hash);
        return .{ .kind = encoded.object_type, .data = try allocator.dupe(u8, encoded.readerBytes()) };
    }

    pub fn submoduleImportBegin(_: *Native, allocator: std.mem.Allocator, session: *Session, path: []const u8) !void {
        try validateSubmodulePath(path);
        if (session.submodule_import != null) return error.SubmoduleImportInProgress;
        try session.filesystem.mkdirAll(path, fs.Mode.dir);
        const view = try allocator.create(fs.Os);
        errdefer allocator.destroy(view);
        view.* = try session.filesystem.chroot(path);
        errdefer view.deinit();
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const storage = try session.storage.module(path);
        try storage.initLayout();
        session.submodule_import = .{ .path = owned_path, .storage = storage, .worktree = view, .importer = PackImport.init(allocator, storage, .{ .max_pack_bytes = contract.MAX_PACK_BYTES, .max_objects = contract.MAX_PACK_OBJECTS }) };
    }

    pub fn submoduleImportWrite(_: *Native, session: *Session, path: []const u8, bytes: []const u8) !void {
        try validateSubmodulePath(path);
        const state = if (session.submodule_import) |*value| value else return error.SubmoduleImportNotStarted;
        if (!std.mem.eql(u8, state.path, path)) return error.SubmoduleImportPathMismatch;
        try state.importer.write(bytes);
    }

    pub fn submoduleImportAbort(_: *Native, allocator: std.mem.Allocator, session: *Session, path: []const u8) void {
        const state = if (session.submodule_import) |*value| value else return;
        if (!std.mem.eql(u8, state.path, path)) return;
        clearSubmoduleImport(allocator, session);
    }

    pub fn submoduleImportFinish(_: *Native, session: *Session, path: []const u8, target_hash: plumbing.Hash) !void {
        try validateSubmodulePath(path);
        const state = if (session.submodule_import) |*value| value else return error.SubmoduleImportNotStarted;
        if (!std.mem.eql(u8, state.path, path)) return error.SubmoduleImportPathMismatch;
        const allocator = state.importer.allocator;
        defer clearSubmoduleImport(allocator, session);
        _ = try state.importer.finish(&.{});
        if (!hasHead(state.storage)) try state.storage.setReference(plumbing.Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));
        var repository = repo.newRepositoryFor(filesystem.StorageOs, fs.Os, state.storage, state.worktree);
        var worktree = try repository.worktree();
        try worktree.checkout(.{ .hash = target_hash, .force = true });
        try state.storage.setReference(plumbing.Reference.newHashReference(plumbing.HEAD, target_hash));
        try writeGitDirLink(allocator, state.worktree, path);
    }

    pub fn submoduleHead(_: *Native, session: *Session, path: []const u8) !?plumbing.Hash {
        try validateSubmodulePath(path);
        return resolveHead(try session.storage.module(path));
    }
};

const RemoteApply = struct {
    kind: u8,
    branch: []const u8,
    source: []const u8,
    remote_name: []const u8,
    url: []const u8,
    target: plumbing.Hash,
};

fn writeRemoteApply(allocator: std.mem.Allocator, git_fs: *fs.Os, transaction_kind: u8, branch: []const u8, source: []const u8, remote_name: []const u8, url: []const u8, target: plumbing.Hash) !void {
    if (std.mem.indexOfScalar(u8, branch, '\n') != null or std.mem.indexOfScalar(u8, source, '\n') != null or std.mem.indexOfScalar(u8, remote_name, '\n') != null or std.mem.indexOfScalar(u8, url, '\n') != null) return error.InvalidRemoteTransaction;
    var hex_buf: [plumbing.MaxHexSize]u8 = undefined;
    const hex = target.formatHex(&hex_buf);
    const body = try std.fmt.allocPrint(allocator, "AORT1\n{d}\n{s}\n{s}\n{s}\n{s}\n{s}\n", .{ transaction_kind, hex, branch, source, remote_name, url });
    defer allocator.free(body);
    var file = try git_fs.create(remote_transaction_tmp);
    defer file.close() catch {};
    _ = try file.write(body);
    try file.sync();
    try git_fs.rename(remote_transaction_tmp, remote_transaction);
    try git_fs.syncRoot();
}

fn recoverRemoteApply(allocator: std.mem.Allocator, worktree_fs: *fs.Os, git_fs: *fs.Os, storage: *filesystem.StorageOs) !void {
    const info = git_fs.stat(remote_transaction) catch |err| switch (err) {
        error.NotExist => return,
        else => return err,
    };
    if (info.size > contract.MAX_FIELD_BYTES) return error.InvalidRemoteTransaction;
    const body = try allocator.alloc(u8, @intCast(info.size));
    defer allocator.free(body);
    var file = try git_fs.open(remote_transaction);
    defer file.close() catch {};
    var read: usize = 0;
    while (read < body.len) {
        const count = try file.read(body[read..]);
        if (count == 0) return error.InvalidRemoteTransaction;
        read += count;
    }
    const pending = try parseRemoteApply(body);
    const current = storage.reference(plumbing.ReferenceName.init(pending.branch)) catch |err| switch (err) {
        error.ReferenceNotFound => {
            try git_fs.remove(remote_transaction);
            try git_fs.syncRoot();
            return;
        },
        else => return err,
    };
    defer storage.freeReference(current);
    if (current.type != .hash or !current.hash.eql(pending.target)) {
        try git_fs.remove(remote_transaction);
        try git_fs.syncRoot();
        return;
    }

    var repository = repo.newRepositoryFor(filesystem.StorageOs, fs.Os, storage, worktree_fs);
    if (pending.kind == 1) {
        const cfg = try storage.config();
        var fetch_buf: [contract.MAX_REF_BYTES + 64]u8 = undefined;
        const fetch_spec = try std.fmt.bufPrint(&fetch_buf, "+refs/heads/*:refs/remotes/{s}/*", .{pending.remote_name});
        try cfg.putRemoteFull(pending.remote_name, &.{pending.url}, &.{fetch_spec}, false);
        try cfg.putBranch(plumbing.ReferenceName.init(pending.branch).short(), pending.remote_name, pending.source);
        try storage.setConfig(cfg);
    }
    var wt = try repository.worktree();
    try wt.checkout(.{ .branch = plumbing.ReferenceName.init(pending.branch), .force = true });
    try worktree_fs.syncTree();
    try git_fs.remove(remote_transaction);
    try git_fs.syncRoot();
}

fn parseRemoteApply(body: []const u8) !RemoteApply {
    var lines = std.mem.splitScalar(u8, body, '\n');
    if (!std.mem.eql(u8, lines.next() orelse return error.InvalidRemoteTransaction, "AORT1")) return error.InvalidRemoteTransaction;
    const kind = std.fmt.parseInt(u8, lines.next() orelse return error.InvalidRemoteTransaction, 10) catch return error.InvalidRemoteTransaction;
    if (kind != 1 and kind != 2) return error.InvalidRemoteTransaction;
    const target = plumbing.parseHash(lines.next() orelse return error.InvalidRemoteTransaction) catch return error.InvalidRemoteTransaction;
    const branch = lines.next() orelse return error.InvalidRemoteTransaction;
    const source = lines.next() orelse return error.InvalidRemoteTransaction;
    const remote_name = lines.next() orelse return error.InvalidRemoteTransaction;
    const url = lines.next() orelse return error.InvalidRemoteTransaction;
    if ((lines.next() orelse return error.InvalidRemoteTransaction).len != 0 or lines.next() != null or branch.len == 0) return error.InvalidRemoteTransaction;
    return .{ .kind = kind, .branch = branch, .source = source, .remote_name = remote_name, .url = url, .target = target };
}

fn cloneSparsePaths(allocator: std.mem.Allocator, paths: []const []const u8) ![]const []const u8 {
    const copy = try allocator.alloc([]const u8, paths.len);
    errdefer allocator.free(copy);
    var count: usize = 0;
    errdefer for (copy[0..count]) |path| allocator.free(path);
    for (paths, 0..) |path, index| {
        copy[index] = try allocator.dupe(u8, path);
        count += 1;
    }
    return copy;
}
fn freeSparsePaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    if (paths.len > 0) allocator.free(paths);
}

fn clearSubmoduleImport(allocator: std.mem.Allocator, session: *Native.Session) void {
    if (session.submodule_import) |*state| {
        state.importer.deinit();
        state.worktree.deinit();
        allocator.destroy(state.worktree);
        allocator.free(state.path);
        session.submodule_import = null;
    }
}

fn hasHead(storage: anytype) bool {
    const head = storage.reference(plumbing.HEAD) catch return false;
    storage.freeReference(head);
    return true;
}

fn resolveHead(storage: anytype) !?plumbing.Hash {
    const reference = storage.reference(plumbing.HEAD) catch |err| switch (err) {
        error.ReferenceNotFound => return null,
        else => return err,
    };
    defer storage.freeReference(reference);
    return if (reference.type == .hash) reference.hash else null;
}

fn writeGitDirLink(allocator: std.mem.Allocator, worktree: *fs.Os, path: []const u8) !void {
    var contents: std.Io.Writer.Allocating = .init(allocator);
    defer contents.deinit();
    try contents.writer.writeAll("gitdir: ");
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next() != null) try contents.writer.writeAll("../");
    try contents.writer.writeAll(".git/modules/");
    try contents.writer.writeAll(path);
    try contents.writer.writeByte('\n');

    var file = try worktree.create(".git");
    defer file.close() catch {};
    var written: usize = 0;
    while (written < contents.written().len) written += try file.writeAt(contents.written()[written..], @intCast(written));
}

fn validateSubmodulePath(path: []const u8) !void {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfAny(u8, path, "\\\x00") != null) return error.InvalidSubmodulePath;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..") or std.mem.eql(u8, component, ".git")) return error.InvalidSubmodulePath;
}

test "native remote apply recovers a killed checkout after atomic refs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var backend = Native{ .io = io };
    var session = try backend.sessionInit(allocator, .{ .backend = contract.BACKEND_NATIVE, .read_only = false, .root = root });
    try backend.repositoryInit(&session);
    var repository = &session.repository.?;
    var wt = try repository.worktree();
    const signature = .{ .name = "AgentOS", .email = "agentos@example.invalid", .when = 1 };

    try writeTestFile(session.filesystem, "tracked.txt", "first\n");
    _ = try wt.add("tracked.txt");
    const first = try wt.commit("first", .{ .author = signature, .committer = signature });
    try writeTestFile(session.filesystem, "tracked.txt", "second\n");
    _ = try wt.add("tracked.txt");
    const second = try wt.commit("second", .{ .author = signature, .committer = signature });

    try wt.checkout(.{ .hash = first, .force = true });
    const branch = plumbing.master;
    try backend.remoteApplyBegin(allocator, &session, 2, branch.raw, "", "", "", second);
    try session.storage.applyReferenceUpdatesDurable(&.{
        .{ .name = branch, .new_reference = plumbing.Reference.newHashReference(branch, second) },
        .{ .name = plumbing.HEAD, .new_reference = plumbing.Reference.newSymbolicReference(plumbing.HEAD, branch) },
    });
    backend.sessionDeinit(allocator, &session);

    var recovered = try backend.sessionInit(allocator, .{ .backend = contract.BACKEND_NATIVE, .read_only = false, .root = root });
    defer backend.sessionDeinit(allocator, &recovered);
    const bytes = try readTestFile(allocator, recovered.filesystem, "tracked.txt");
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("second\n", bytes);
    try std.testing.expectError(error.NotExist, recovered.dot_git_fs.stat(remote_transaction));
}

fn writeTestFile(filesystem_value: *fs.Os, path: []const u8, bytes: []const u8) !void {
    var file = try filesystem_value.create(path);
    defer file.close() catch {};
    _ = try file.write(bytes);
}

fn readTestFile(allocator: std.mem.Allocator, filesystem_value: *fs.Os, path: []const u8) ![]u8 {
    const info = try filesystem_value.stat(path);
    const bytes = try allocator.alloc(u8, @intCast(info.size));
    errdefer allocator.free(bytes);
    var file = try filesystem_value.open(path);
    defer file.close() catch {};
    var read: usize = 0;
    while (read < bytes.len) read += try file.read(bytes[read..]);
    return bytes;
}
