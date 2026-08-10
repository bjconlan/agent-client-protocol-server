//! Echo provider — stub implementation behind the adapter seam.
//!
//! Emits each prompt text block as a single chunk, then `end_turn`. Used by
//! F3 to prove the session/prompt streaming path before the OpenAI Responses
//! adapter lands (F4).

const std = @import("std");

const adapter = @import("adapter.zig");

pub const generate: *const fn (
    allocator: std.mem.Allocator,
    text_blocks: []const []const u8,
    chunks: *std.ArrayList([]const u8),
) anyerror![]const u8 = generateImpl;

fn generateImpl(
    allocator: std.mem.Allocator,
    text_blocks: []const []const u8,
    chunks: *std.ArrayList([]const u8),
) anyerror![]const u8 {
    for (text_blocks) |block| {
        if (block.len == 0) continue;
        try chunks.append(allocator, block);
    }
    return adapter.StopReason.end_turn.asString();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "echo: emits text blocks as chunks, end_turn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var chunks: std.ArrayList([]const u8) = .empty;
    const stop = try generateImpl(a, &.{ "hello", "", "world" }, &chunks);
    try testing.expectEqualSlices(u8, "end_turn", stop);
    try testing.expectEqual(@as(usize, 2), chunks.items.len);
    try testing.expectEqualStrings("hello", chunks.items[0]);
    try testing.expectEqualStrings("world", chunks.items[1]);
}
