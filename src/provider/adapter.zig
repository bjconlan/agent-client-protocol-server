//! Provider adapter interface.
//!
//! Isolates ACP protocol semantics from model provider backends. A provider
//! turns prebuilt input items (session history + current prompt) plus prior
//! tool results into streamed text chunks (via `emit`), honoring
//! `is_cancelled` between chunks, and returns any `function_call` tool calls
//! the model requested. The caller (the prompt worker) executes tools
//! agent-side and feeds results back on the next call.

const std = @import("std");

const config_mod = @import("../config.zig");
const http_util = @import("../util/http.zig");
const tools = @import("../tools/registry.zig");

/// Streamed text chunk callback. Returning an error aborts generation.
pub const EmitFn = *const fn (chunk: []const u8, userdata: ?*anyopaque) anyerror!void;

/// Cancellation poll — called between chunks/events.
pub const IsCancelledFn = *const fn (userdata: ?*anyopaque) bool;

/// Token usage for the turn (ACP `usage_update` mapping: used/size).
pub const Usage = struct {
    prompt_tokens: u64,
    total_tokens: u64,
};

/// A tool call the model requested (OpenAI `function_call` output item).
pub const ToolCall = struct {
    /// Provider call id (echoed back in `ToolResult.call_id`).
    id: []const u8,
    name: []const u8,
    /// JSON arguments string.
    arguments: []const u8,
};

/// The result of executing a tool call, fed back to the provider.
pub const ToolResult = struct {
    call_id: []const u8,
    output: []const u8,
};

/// Generation result: stop reason + usage + requested tool calls.
pub const Result = struct {
    /// "end_turn", "cancelled", "max_tokens", …
    stop_reason: []const u8,
    usage: ?Usage,
    /// Tool calls the model requested (empty → the turn is done).
    tool_calls: []ToolCall,
};

/// Per-generation options.
pub const Options = struct {
    config: *const config_mod.Config,
    /// API key for the provider; may be empty — providers decide how to
    /// fail lazily.
    api_key: []const u8,
    http: *std.http.Client,
    /// Tool definitions to advertise (provider `tools` param).
    tools: []const tools.Tool,
    emit: EmitFn,
    is_cancelled: IsCancelledFn,
    userdata: ?*anyopaque,
};

/// A model provider.
pub const Provider = struct {
    generate: *const fn (
        allocator: std.mem.Allocator,
        /// Prebuilt input items (session history + current prompt), a
        /// `std.json.Array` Value.
        input: std.json.Value,
        /// Prior tool results, appended as `function_call_output` items.
        tool_results: []const ToolResult,
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
