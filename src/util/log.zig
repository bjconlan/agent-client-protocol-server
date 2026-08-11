//! Runtime-configurable logging for the binary.
//!
//! Zig's `std.log` filters by level at compile time (`std.options.log_level`);
//! the binary sets that to `.debug` and installs `logFn` (below) so the
//! effective level is chosen at RUNTIME via the `ACP_LOG_LEVEL` env var
//! (`err` | `warn` | `info` | `debug`, default `info`).
//!
//! Scopes used at the system edges:
//! - `.transport` — stdio lines in/out (the client session boundary)
//! - `.http` — provider HTTP requests (method/url/status) + bodies
//! - `.provider` — provider SSE lines (the response edge)
//! - `.config` — config loading/validation
//!
//! Tests do not install this logFn (they keep Zig's default logging).

const std = @import("std");

/// The effective runtime level; set once at startup from `ACP_LOG_LEVEL`
/// before any worker threads spawn.
var runtime_level: std.log.Level = .info;

pub fn initFromEnv(map: *const std.process.Environ.Map) void {
    const value = map.get("ACP_LOG_LEVEL") orelse return;
    if (std.mem.eql(u8, value, "debug")) {
        runtime_level = .debug;
    } else if (std.mem.eql(u8, value, "warn")) {
        runtime_level = .warn;
    } else if (std.mem.eql(u8, value, "err")) {
        runtime_level = .err;
    }
    // "info" (and anything unrecognized) → default .info
}

/// Installed as `std.options.logFn` by the binary root. Filters by the
/// runtime level (comptime level already passed the compile-time gate) and
/// formats as `[scope] level: message`.
pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) > @intFromEnum(runtime_level)) return;
    const prefix = "[{s}] {s}: ";
    std.debug.print(prefix ++ format ++ "\n", .{
        @tagName(scope),
        @tagName(message_level),
    } ++ args);
}
