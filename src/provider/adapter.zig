//! Provider adapter interface.
//!
//! Isolates ACP protocol semantics from model provider backends. A provider
//! turns prompt text blocks into streamed text chunks via `emit`, honoring
//! `is_cancelled` between chunks. The caller (the prompt worker) serializes
//! chunks as ACP `session/update` notifications.
//!
//! Push-based so real streaming providers (OpenAI SSE, F4) and the echo stub
//! share one shape, and so cancellation can interrupt mid-stream.

const std = @import("std");

const config_mod = @import("../config.zig");
const http_util = @import("../util/http.zig");

/// Streamed text chunk callback. Returning an error aborts generation.
pub const EmitFn = *const fn (chunk: []const u8, userdata: ?*anyopaque) anyerror!void;

/// Cancellation poll — called between chunks/events.
pub const IsCancelledFn = *const fn (userdata: ?*anyopaque) bool;

/// Token usage for the turn (ACP `usage_update` mapping: used/size).
pub const Usage = struct {
    prompt_tokens: u64,
    total_tokens: u64,
};

/// Generation result: ACP stop reason + optional usage.
pub const Result = struct {
    /// "end_turn", "cancelled", "max_tokens", …
    stop_reason: []const u8,
    usage: ?Usage,
};

/// Per-generation options.
pub const Options = struct {
    config: *const config_mod.Config,
    /// API key for the provider; may be empty — providers decide how to
    /// fail lazily.
    api_key: []const u8,
    http: *std.http.Client,
    emit: EmitFn,
    is_cancelled: IsCancelledFn,
    userdata: ?*anyopaque,
};

/// A model provider.
pub const Provider = struct {
    generate: *const fn (
        allocator: std.mem.Allocator,
        text_blocks: []const []const u8,
        options: Options,
    ) anyerror!Result,
};

/// Error union for provider generation, usable by implementations.
pub const GenerateError = error{
    GenerateFailed,
    Cancelled,
    MissingApiKey,
    /// Body serialization (allocating writer) failure.
    WriteFailed,
} || http_util.Error || std.mem.Allocator.Error;
