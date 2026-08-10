//! Provider adapter interface.
//!
//! Isolates ACP protocol semantics from model provider backends. A provider
//! turns the text blocks of a user prompt into streamed text chunks; the
//! caller (the `session/prompt` handler) serializes chunks as ACP
//! `session/update` notifications.
//!
//! F3: minimal pull-based interface — `generate` appends chunks to a list,
//! the handler emits them. F4 refines this for SSE streaming and
//! cancellation when the OpenAI Responses adapter lands.

const std = @import("std");

/// A model provider.
pub const Provider = struct {
    /// Produce text chunks for the given prompt text blocks. Chunks are
    /// appended to `chunks` (allocator-owned); empty blocks are skipped.
    /// Returns the stop reason for the turn.
    generate: *const fn (
        allocator: std.mem.Allocator,
        text_blocks: []const []const u8,
        chunks: *std.ArrayList([]const u8),
    ) anyerror![]const u8,
};

/// Stop reasons a provider can produce (ACP `StopReason` subset for F3).
pub const StopReason = enum {
    end_turn,
    cancelled,

    pub fn asString(self: StopReason) []const u8 {
        return switch (self) {
            .end_turn => "end_turn",
            .cancelled => "cancelled",
        };
    }
};
