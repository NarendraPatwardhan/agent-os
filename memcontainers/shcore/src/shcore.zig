//! Zig shcore public surface.
//!
//! Zig-native universal shell core.
//!
//! The public boundary is ShellOs: callers pass a blocking OS vtable and drive
//! a Shell state object directly. Rescue-shell and guest-shell adapters share
//! this runtime instead of carrying separate shell semantics.

const std = @import("std");

pub const arith = @import("arith.zig");
pub const ast = @import("ast.zig");
pub const builtins = @import("builtins.zig");
pub const echo = @import("echo.zig");
pub const exec = @import("exec.zig");
pub const expand = @import("expand.zig");
pub const glob = @import("glob.zig");
pub const os = @import("os.zig");
pub const parser = @import("parser.zig");
pub const printf = @import("printf.zig");
pub const testexpr = @import("testexpr.zig");
pub const token = @import("token.zig");
pub const word = @import("word.zig");

pub const Shell = exec.Shell;
pub const Flow = exec.Flow;
pub const ShellOs = os.ShellOs;
pub const ParseError = parser.ParseError;

pub fn init(allocator: std.mem.Allocator, shell_os: *ShellOs) Shell {
    return Shell.init(allocator, shell_os);
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!ast.Script {
    return parser.parse(allocator, source);
}
