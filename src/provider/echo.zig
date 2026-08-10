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
    input: std.json.Value,
    prior_outputs: []const std.json.Value,
    tool_results: []const adapter.ToolResult,
    options: adapter.Options,
) anyerror!adapter.Result = generateImpl;

fn generateImpl(
    allocator: std.mem.Allocator,
    input: std.json.Value,
    prior_outputs: []const std.json.Value,
    tool_results: []const adapter.ToolResult,
    options: adapter.Options,
) anyerror!adapter.Result {
    _ = allocator;
    _ = prior_outputs;
    _ = tool_results;
    // Echo the user text blocks from the input items.
    const arr = switch (input) {
        .array => |a| a,
        else => return .{ .stop_reason = "end_turn", .usage = null, .tool_calls = &.{}, .output_items = &.{} },
    };
    for (arr.items) |item| {
        if (item != .object) continue;
        const role = item.object.get("role") orelse continue;
        if (role != .string or !std.mem.eql(u8, role.string, "user")) continue;
        const content = item.object.get("content") orelse continue;
        const blocks = switch (content) {
            .array => |a| a,
            else => continue,
        };
        for (blocks.items) |block| {
            if (block != .object) continue;
            const text = block.object.get("text") orelse continue;
            if (text != .string) continue;
            if (text.string.len == 0) continue;
            if (options.is_cancelled(options.userdata)) {
                return .{ .stop_reason = "cancelled", .usage = null, .tool_calls = &.{}, .output_items = &.{} };
            }
            try options.emit(text.string, options.userdata);
        }
    }
    return .{ .stop_reason = "end_turn", .usage = null, .tool_calls = &.{}, .output_items = &.{} };
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

    var input: std.json.Array = std.json.Array.init(a);
    var content: std.json.Array = std.json.Array.init(a);
    var text_item: std.json.ObjectMap = .empty;
    try text_item.put(a, "type", .{ .string = "input_text" });
    try text_item.put(a, "text", .{ .string = "hello" });
    try content.append(.{ .object = text_item });
    var text_item2: std.json.ObjectMap = .empty;
    try text_item2.put(a, "type", .{ .string = "input_text" });
    try text_item2.put(a, "text", .{ .string = "world" });
    try content.append(.{ .object = text_item2 });
    var msg: std.json.ObjectMap = .empty;
    try msg.put(a, "type", .{ .string = "message" });
    try msg.put(a, "role", .{ .string = "user" });
    try msg.put(a, "content", .{ .array = content });
    try input.append(.{ .object = msg });

    const result = try generateImpl(a, .{ .array = input }, &.{}, &.{}, .{
        .config = &cfg,
        .api_key = "",
        .http = &http,
        .tools = &.{},
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
    const cancelled = try generateImpl(a, .{ .array = input }, &.{}, &.{}, .{
        .config = &cfg,
        .api_key = "",
        .http = &http,
        .tools = &.{},
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
