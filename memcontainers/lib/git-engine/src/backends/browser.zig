const std = @import("std");
const contract = @import("git_zig");
const fs = @import("fs");
const memory = @import("memory");
const persistence = @import("persistence");
const plumbing = @import("plumbing");
const remote = @import("remote");
const repo = @import("repo");

pub const Browser = struct {
    pub const Session = struct {
        store: *memory.Storage,
        filesystem: *fs.Mem,
        repository: ?repo.Repository = null,
        read_only: bool,
        mutation_generation: u32 = 1,
        pack_import: ?remote.PackImportSession = null,
        submodule_import: ?SubmoduleImport = null,
        sparse_paths: []const []const u8 = &.{},
    };

    const SubmoduleImport = struct {
        path: []u8,
        storage: *memory.Storage,
        worktree: *fs.Mem,
        importer: remote.PackImportSession,
    };

    pub fn kind(_: *Browser) u16 {
        return @intCast(contract.BACKEND_BROWSER);
    }
    pub fn capabilities(_: *Browser) u32 {
        return @intCast(contract.CAPABILITY_CORE);
    }

    pub fn sessionInit(_: *Browser, allocator: std.mem.Allocator, config: contract.SessionConfig) !Session {
        if (config.backend != @as(u16, @intCast(contract.BACKEND_BROWSER)) or config.root.len > contract.MAX_PATH_BYTES) return error.BadConfig;
        const clock = memory.Clock.fixedClock(memory.Time.unix(0, 0));
        if (config.restore) |image| {
            var restored = try persistence.restoreImage(allocator, clock, image);
            errdefer restored.deinit(allocator);
            const filesystem = try allocator.create(fs.Mem);
            filesystem.* = restored.filesystem;
            const store = restored.store;
            restored = undefined;
            return .{ .store = store, .filesystem = filesystem, .read_only = config.read_only };
        }
        const store = try memory.newStorageWithClock(allocator, clock);
        errdefer {
            store.deinit();
            allocator.destroy(store);
        }
        const filesystem = try allocator.create(fs.Mem);
        errdefer allocator.destroy(filesystem);
        filesystem.* = try fs.Mem.init(allocator);
        errdefer filesystem.deinit();
        return .{ .store = store, .filesystem = filesystem, .read_only = config.read_only };
    }

    pub fn sessionDeinit(_: *Browser, allocator: std.mem.Allocator, session: *Session) void {
        if (session.pack_import) |*import| import.deinit();
        clearSubmoduleImport(allocator, session);
        freeSparsePaths(allocator, session.sparse_paths);
        session.filesystem.deinit();
        allocator.destroy(session.filesystem);
        session.store.deinit();
        allocator.destroy(session.store);
        session.* = undefined;
    }

    pub fn isReadOnly(_: *Browser, session: *const Session) bool {
        return session.read_only;
    }
    pub fn generation(_: *Browser, session: *const Session) u32 {
        return session.mutation_generation;
    }
    pub fn sparsePaths(_: *Browser, session: *const Session) []const []const u8 {
        return session.sparse_paths;
    }
    pub fn setSparsePaths(_: *Browser, allocator: std.mem.Allocator, session: *Session, paths: []const []const u8) !void {
        const replacement = try cloneSparsePaths(allocator, paths);
        freeSparsePaths(allocator, session.sparse_paths);
        session.sparse_paths = replacement;
    }

    pub fn repositoryInit(_: *Browser, session: *Session) !void {
        if (session.repository != null) return error.RepositoryAlreadyExists;
        session.repository = try repo.init(session.store, session.filesystem);
        session.mutation_generation +%= 1;
        if (session.mutation_generation == 0) session.mutation_generation = 1;
    }

    pub fn repositoryOpen(_: *Browser, session: *Session) !void {
        if (session.repository != null) return error.RepositoryAlreadyOpen;
        session.repository = try repo.open(session.store, session.filesystem);
    }

    pub fn checkpoint(_: *Browser, allocator: std.mem.Allocator, session: *Session) ![]u8 {
        _ = session.repository orelse return error.RepositoryNotOpen;
        return persistence.exportImage(allocator, session.store, session.filesystem);
    }

    pub fn restore(_: *Browser, allocator: std.mem.Allocator, session: *Session, image: []const u8) !void {
        var restored = try persistence.restoreImage(allocator, memory.Clock.fixedClock(memory.Time.unix(0, 0)), image);
        errdefer restored.deinit(allocator);
        const repository = try repo.open(restored.store, &restored.filesystem);
        session.filesystem.deinit();
        session.store.deinit();
        allocator.destroy(session.store);
        session.filesystem.* = restored.filesystem;
        session.store = restored.store;
        session.repository = repository;
        session.repository.?.wt = session.filesystem;
        restored = undefined;
    }

    pub fn packImportBegin(_: *Browser, allocator: std.mem.Allocator, session: *Session) !void {
        if (session.pack_import) |*old| old.deinit();
        session.pack_import = remote.PackImportSession.init(allocator, session.store, .{ .max_pack_bytes = contract.MAX_PACK_BYTES, .max_objects = contract.MAX_PACK_OBJECTS });
    }
    pub fn packImportWrite(_: *Browser, session: *Session, bytes: []const u8) !void {
        const import = if (session.pack_import) |*value| value else return error.ImportNotStarted;
        try import.write(bytes);
    }
    pub fn packImportFinish(_: *Browser, session: *Session, updates: []const memory.ReferenceUpdate) !struct { object_count: usize, reference_count: usize } {
        const import = if (session.pack_import) |*value| value else return error.ImportNotStarted;
        const result = try import.finish(updates);
        return .{ .object_count = result.object_count, .reference_count = result.reference_count };
    }
    pub fn packImportAbort(_: *Browser, session: *Session) void {
        if (session.pack_import) |*value| value.abort();
    }
    pub fn packBuild(_: *Browser, allocator: std.mem.Allocator, session: *Session, wants: []const plumbing.Hash, haves: []const plumbing.Hash) !struct { bytes: []u8, object_count: usize } {
        const built = try remote.buildPack(allocator, session.store, wants, haves, .{});
        return .{ .bytes = built.bytes, .object_count = built.object_count };
    }

    /// Return an allocator-owned snapshot so callers see one lifetime contract
    /// for memory and filesystem storage.
    pub fn shallowGet(_: *Browser, allocator: std.mem.Allocator, session: *Session) ![]plumbing.Hash {
        return allocator.dupe(plumbing.Hash, session.store.shallow());
    }

    pub fn shallowSet(_: *Browser, session: *Session, commits: []const plumbing.Hash) !void {
        try session.store.setShallow(commits);
    }

    /// Validate every expected-old constraint before publishing any update.
    pub fn applyReferenceUpdates(_: *Browser, session: *Session, updates: []const memory.ReferenceUpdate) !void {
        // Use the two-phase primitive directly. The pinned convenience wrapper
        // narrows its error set incorrectly; prepareUpdates also guarantees no
        // visible mutation until commitPrepared performs the map swap.
        var prepared = try session.store.reference_storage.prepareUpdates(updates);
        session.store.reference_storage.commitPrepared(&prepared);
    }

    /// Stage an exact commit gitlink without touching the nested worktree.
    pub fn stageGitlink(_: *Browser, session: *Session, path: []const u8, hash: plumbing.Hash) !void {
        const index = try session.store.index();
        const entry = index.entry(path) catch |err| switch (err) {
            error.EntryNotFound => try index.add(path),
            else => return err,
        };
        entry.hash = hash;
        entry.mode = 0o160000;
        entry.stage = 0;
        session.store.setIndex(index);
    }

    pub fn gitlink(_: *Browser, session: *Session, path: []const u8) !?plumbing.Hash {
        const index = try session.store.index();
        const entry = index.entry(path) catch |err| switch (err) {
            error.EntryNotFound => return null,
            else => return err,
        };
        return if (entry.mode == 0o160000) entry.hash else null;
    }

    /// Memory storage returns a borrowed encoded object; expose an owned copy.
    pub fn objectRead(_: *Browser, allocator: std.mem.Allocator, session: *Session, requested_kind: plumbing.ObjectType, hash: plumbing.Hash) !struct { kind: plumbing.ObjectType, data: []u8 } {
        const encoded = try session.store.encodedObject(requested_kind, hash);
        return .{ .kind = encoded.object_type, .data = try allocator.dupe(u8, encoded.readerBytes()) };
    }

    pub fn submoduleImportBegin(_: *Browser, allocator: std.mem.Allocator, session: *Session, path: []const u8) !void {
        try validateSubmodulePath(path);
        if (session.submodule_import != null) return error.SubmoduleImportInProgress;
        try session.filesystem.mkdirAll(path, fs.Mode.dir);
        const view = try allocator.create(fs.Mem);
        errdefer allocator.destroy(view);
        view.* = try session.filesystem.chroot(path);
        errdefer view.deinit();
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const storage = try session.store.module(path);
        session.submodule_import = .{ .path = owned_path, .storage = storage, .worktree = view, .importer = remote.PackImportSession.init(allocator, storage, .{ .max_pack_bytes = contract.MAX_PACK_BYTES, .max_objects = contract.MAX_PACK_OBJECTS }) };
    }

    pub fn submoduleImportWrite(_: *Browser, session: *Session, path: []const u8, bytes: []const u8) !void {
        try validateSubmodulePath(path);
        const state = if (session.submodule_import) |*value| value else return error.SubmoduleImportNotStarted;
        if (!std.mem.eql(u8, state.path, path)) return error.SubmoduleImportPathMismatch;
        try state.importer.write(bytes);
    }

    pub fn submoduleImportAbort(_: *Browser, allocator: std.mem.Allocator, session: *Session, path: []const u8) void {
        const state = if (session.submodule_import) |*value| value else return;
        if (!std.mem.eql(u8, state.path, path)) return;
        clearSubmoduleImport(allocator, session);
    }

    pub fn submoduleImportFinish(_: *Browser, session: *Session, path: []const u8, target_hash: plumbing.Hash) !void {
        try validateSubmodulePath(path);
        const state = if (session.submodule_import) |*value| value else return error.SubmoduleImportNotStarted;
        if (!std.mem.eql(u8, state.path, path)) return error.SubmoduleImportPathMismatch;
        const allocator = state.importer.allocator;
        defer clearSubmoduleImport(allocator, session);
        _ = try state.importer.finish(&.{});
        var repository = if (hasHead(state.storage)) try repo.open(state.storage, state.worktree) else try repo.init(state.storage, state.worktree);
        var worktree = try repository.worktree();
        try worktree.checkout(.{ .hash = target_hash, .force = true });
        try state.storage.setReference(plumbing.Reference.newHashReference(plumbing.HEAD, target_hash));
    }

    pub fn submoduleHead(_: *Browser, session: *Session, path: []const u8) !?plumbing.Hash {
        try validateSubmodulePath(path);
        return resolveHead(try session.store.module(path));
    }
};

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

fn clearSubmoduleImport(allocator: std.mem.Allocator, session: *Browser.Session) void {
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

fn validateSubmodulePath(path: []const u8) !void {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfAny(u8, path, "\\\x00") != null) return error.InvalidSubmodulePath;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..") or std.mem.eql(u8, component, ".git")) return error.InvalidSubmodulePath;
}
