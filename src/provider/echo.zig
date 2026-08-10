//! Echo provider — stub implementation behind the adapter seam.
//!
//! Emits each prompt text block as a single chunk (honoring cancellation),
//! then `end_turn`. Used by tests to prove the session/prompt streaming path
//! without network I/O; the OpenAI Responses adapter is the real backend.

const std = @import("std");
const Io = std.Io;

const adapter = @import("adapter.zig");

pub const generate: *const fn (
    allocator: std.mem.Allocator,
    text_blocks: []const []const u8,
    options: adapter.Options,
) anyerror!adapter.Result = generateImpl;

fn generateImpl(
    allocator: std.mem.Allocator,
    text_blocks: []const []const u8,
    options: adapter.Options,
) anyerror!adapter.Result {
    _ = allocator;
    for (text_blocks) |block| {
        if (block.len == 0) continue;
        if (options.is_cancelled(options.userdata)) {
            return .{ .stop_reason = "cancelled", .usage = null };
        }
        try options.emit(block, options.userdata);
    }
    return .{ .stop_reason = "end_turn", .usage = null };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "echo: emits blocks, end_turn; honours cancellation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const chunks = try a.create(std.ArrayList([]const u8));
    chunks.* = .empty;
    var cancel = false;
    const cfg = @import("../config.zig").Config{
        .api_key = null,
        .base_url = "http://x",
        .model = "m",
        .effort = "high",
    };
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var http: std.http.Client = .{ .allocator = a, .io = threaded.io() };

    const result = try generateImpl(a, &.{ "hello", "world" }, .{
        .config = &cfg,
        .api_key = "",
        .http = &http,
        .emit = struct {
            fn e(chunk: []const u8, ud: ?*anyopaque) anyerror!void {
                const list: *std.ArrayList([]const u8) = @ptrCast(@alignCast(ud.?));
                try list.append(std.heap.page_allocator, chunk);
            }
        }.e,
        .is_cancelled = struct {
            fn c(ud: ?*anyopaque) bool {
                const flag: *bool = @ptrCast(@alignCast(ud.?));
                return flag.*;
            }
        }.c,
        .userdata = @ptrCast(chunks),
    });
    try testing.expectEqualStrings("end_turn", result.stop_reason);
    try testing.expectEqual(@as(usize, 2), chunks.items.len);

    cancel = true;
    const cancelled = try generateImpl(a, &.{"x"}, .{
        .config = &cfg,
        .api_key = "",
        .http = &http,
        .emit = struct {
            fn e(_: []const u8, _: ?*anyopaque) anyerror!void {}
        }.e,
        .is_cancelled = struct {
            fn c(ud: ?*anyopaque) bool {
                const flag: *bool = @ptrCast(@alignCast(ud.?));
                return flag.*;
            }
        }.c,
        .userdata = @ptrCast(&cancel),
    });
    try testing.expectEqualStrings("cancelled", cancelled.stop_reason);
}
