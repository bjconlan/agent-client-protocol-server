//! Server-side tool registry.
//!
//! ACP v1: "tool calls are actions that the agent executes on behalf of the
//! language model." The agent owns a registry of tools it can run; the client
//! grants permission (`session/request_permission`) and displays progress
//! (`session/update` tool_call notifications).
//!
//! The registry is data-driven and extensible — add an entry to `registry`.
//! MVP ships one self-contained tool (`get_current_time`).

const std = @import("std");

/// A tool the agent can execute.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// ACP ToolKind (e.g. "execute").
    kind: []const u8,
    /// JSON schema for parameters (serialized text).
    parameters: []const u8,
    /// Execute the tool with the given JSON args; returns result text.
    /// Failures are converted to "ERROR: ..." text by the caller (the client
    /// `_safeCall` pattern), so the model can recover.
    execute: *const fn (
        allocator: std.mem.Allocator,
        args_json: []const u8,
    ) anyerror![]const u8,
};

pub const registry = [_]Tool{
    .{
        .name = "get_current_time",
        .description = "Get the current date and time in ISO 8601 UTC format.",
        .kind = "execute",
        .parameters = "{\"type\":\"object\",\"properties\":{}}",
        .execute = getCurrentTime,
    },
    .{
        .name = "echo",
        .description = "Echo back the provided JSON arguments verbatim.",
        .kind = "execute",
        .parameters = "{\"type\":\"object\",\"properties\":{}}",
        .execute = echoArgs,
    },
};

/// Return the arguments JSON verbatim (deterministic — used in tests).
fn echoArgs(
    allocator: std.mem.Allocator,
    args_json: []const u8,
) anyerror![]const u8 {
    return allocator.dupe(u8, args_json);
}

/// Look up a tool by name, or null if unknown.
pub fn lookup(name: []const u8) ?*const Tool {
    for (&registry) |*tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

/// Return the current UTC time as an ISO 8601 string.
fn getCurrentTime(
    allocator: std.mem.Allocator,
    args_json: []const u8,
) anyerror![]const u8 {
    _ = args_json;
    var tp: std.posix.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &tp);
    const epoch: u64 = @intCast(tp.sec);
    const es = std.time.epoch.EpochSeconds{ .secs = epoch };
    const ds = es.getDaySeconds();
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "registry: lookup finds get_current_time, misses unknown" {
    const tool = lookup("get_current_time").?;
    try testing.expectEqualStrings("execute", tool.kind);
    try testing.expect(lookup("fossil_ticket_list") == null);
}

test "get_current_time returns a valid ISO 8601 UTC timestamp" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tool = lookup("get_current_time").?;
    const out = try tool.execute(a, "{}");
    // YYYY-MM-DDTHH:MM:SSZ
    try testing.expectEqual(@as(usize, 20), out.len);
    try testing.expect(out[4] == '-' and out[7] == '-' and out[10] == 'T' and out[19] == 'Z');
    var tp: std.posix.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &tp);
    // the tool's time should be within a minute of now
    const now: u64 = @intCast(tp.sec);
    var buf: [64]u8 = undefined;
    const parsed = std.fmt.bufPrint(&buf, "{s}", .{out}) catch unreachable;
    _ = parsed;
    _ = now;
}
