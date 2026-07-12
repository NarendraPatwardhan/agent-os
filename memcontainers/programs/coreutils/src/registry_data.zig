//! Single source of truth for the applet roster: name + tier + min_set flag.
//! Pure data, no function pointers, so it is importable both by `src/registry.zig`
//! (which pairs each entry with a `run` fn) and by Bazel tooling (which derives the
//! `mc_applets` custom-section payloads from it). See DESIGN.md §5.1.
//!
//! The roster is 88 names / 87 implementations (`test` and `[` share one), all wired to
//! real code in registry.zig (enforced there at comptime). An early draft of
//! the subset inventory miscounted this as "68/67"; the code below is authoritative.

pub const Tier = enum {
    isolated,
    readonly,
    readwrite,
    full,

    /// The exact string the `mc_tier` custom section carries for a box built at this tier.
    pub fn sectionName(t: Tier) []const u8 {
        return switch (t) {
            .isolated => "isolated",
            .readonly => "read-only",
            .readwrite => "read-write",
            .full => "full",
        };
    }
};

pub const AppletData = struct {
    name: []const u8,
    tier: Tier,
    min_set: bool = false,
};

pub const all = [_]AppletData{
    // --- isolated: hand-written, pure compute ---
    .{ .name = "basename", .tier = .isolated },
    .{ .name = "dirname", .tier = .isolated },
    .{ .name = "echo", .tier = .isolated, .min_set = true },
    .{ .name = "false", .tier = .isolated, .min_set = true },
    .{ .name = "printf", .tier = .isolated, .min_set = true },
    .{ .name = "seq", .tier = .isolated },
    .{ .name = "tr", .tier = .isolated },
    .{ .name = "true", .tier = .isolated, .min_set = true },
    .{ .name = "clear", .tier = .isolated },
    .{ .name = "yes", .tier = .isolated },

    // --- readonly: hand-written ---
    .{ .name = "cat", .tier = .readonly, .min_set = true },
    .{ .name = "cut", .tier = .readonly },
    .{ .name = "fold", .tier = .readonly },
    .{ .name = "head", .tier = .readonly },
    .{ .name = "ls", .tier = .readonly, .min_set = true },
    .{ .name = "nl", .tier = .readonly },
    .{ .name = "printenv", .tier = .readonly },
    .{ .name = "pwd", .tier = .readonly, .min_set = true },
    .{ .name = "readlink", .tier = .readonly },
    .{ .name = "realpath", .tier = .readonly },
    .{ .name = "rev", .tier = .readonly },
    .{ .name = "sleep", .tier = .readonly },
    .{ .name = "stat", .tier = .readonly },
    .{ .name = "tac", .tier = .readonly },
    .{ .name = "tail", .tier = .readonly },
    .{ .name = "test", .tier = .readonly, .min_set = true },
    .{ .name = "[", .tier = .readonly, .min_set = true },
    .{ .name = "tree", .tier = .readonly },
    .{ .name = "wc", .tier = .readonly },
    .{ .name = "which", .tier = .readonly },

    // --- readwrite: hand-written ---
    .{ .name = "chmod", .tier = .readwrite },
    .{ .name = "cp", .tier = .readwrite, .min_set = true },
    .{ .name = "ln", .tier = .readwrite, .min_set = true },
    .{ .name = "mkdir", .tier = .readwrite, .min_set = true },
    .{ .name = "mv", .tier = .readwrite, .min_set = true },
    .{ .name = "rm", .tier = .readwrite, .min_set = true },
    .{ .name = "rmdir", .tier = .readwrite },
    .{ .name = "sort", .tier = .readwrite },
    .{ .name = "tee", .tier = .readwrite },
    .{ .name = "touch", .tier = .readwrite },
    .{ .name = "truncate", .tier = .readwrite },
    .{ .name = "uniq", .tier = .readwrite },

    // --- full: hand-written ---
    .{ .name = "env", .tier = .full },
    .{ .name = "fetch", .tier = .full },
    .{ .name = "find", .tier = .full },
    .{ .name = "kill", .tier = .full, .min_set = true },
    .{ .name = "nice", .tier = .full },
    .{ .name = "nohup", .tier = .full },
    .{ .name = "time", .tier = .full },
    .{ .name = "timeout", .tier = .full },
    .{ .name = "wget", .tier = .full },
    .{ .name = "wscat", .tier = .full },
    .{ .name = "xargs", .tier = .full },

    // --- readonly: external-crate wrappers ---
    .{ .name = "grep", .tier = .readonly },
    .{ .name = "diff", .tier = .readonly },
    .{ .name = "file", .tier = .readonly },
    .{ .name = "jq", .tier = .readonly },

    // --- readwrite: external-crate wrappers ---
    .{ .name = "awk", .tier = .readwrite },
    .{ .name = "gzip", .tier = .readwrite },
    .{ .name = "tar", .tier = .readwrite },
    .{ .name = "zip", .tier = .readwrite },
    .{ .name = "unzip", .tier = .readwrite },

    // --- readonly: uutils crates as-is ---
    .{ .name = "base64", .tier = .readonly },
    .{ .name = "base32", .tier = .readonly },
    .{ .name = "basenc", .tier = .readonly },
    .{ .name = "sha256sum", .tier = .readonly },
    .{ .name = "sha1sum", .tier = .readonly },
    .{ .name = "sha512sum", .tier = .readonly },
    .{ .name = "md5sum", .tier = .readonly },
    .{ .name = "b2sum", .tier = .readonly },
    .{ .name = "cksum", .tier = .readonly },
    .{ .name = "sum", .tier = .readonly },
    .{ .name = "comm", .tier = .readonly },
    .{ .name = "join", .tier = .readonly },
    .{ .name = "paste", .tier = .readonly },
    .{ .name = "fmt", .tier = .readonly },
    .{ .name = "expand", .tier = .readonly },
    .{ .name = "unexpand", .tier = .readonly },
    .{ .name = "od", .tier = .readonly },
    .{ .name = "factor", .tier = .readonly },
    .{ .name = "numfmt", .tier = .readonly },
    .{ .name = "tsort", .tier = .readonly },
    .{ .name = "date", .tier = .readonly },
    .{ .name = "shuf", .tier = .readonly },
    .{ .name = "pathchk", .tier = .readonly },

    // --- full: uutils crates as-is ---
    // `split --filter=CMD` spawns a shell command per chunk, so the implemented applet
    // needs CAP_SPAWN even though its default path only writes files.
    .{ .name = "split", .tier = .full },

    // --- readwrite: uutils crates as-is ---
    .{ .name = "csplit", .tier = .readwrite },
    .{ .name = "sed", .tier = .readwrite },
};
