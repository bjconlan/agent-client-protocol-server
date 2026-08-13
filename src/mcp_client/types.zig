//! MCP (Model Context Protocol) data types — modelcontextprotocol.io.
//!
//! The client module is protocol-agnostic: MCP is an independent JSON-RPC 2.0
//! protocol (stdio transport here) with its own tool/resource/prompt surfaces.
//! The ACP integration (config, tool-surface merging) lives in the ACP layers.

const std = @import("std");

/// Client identity sent in the `initialize` request.
pub const ClientInfo = struct {
    name: []const u8,
    version: []const u8,
};

/// Server identity from the `initialize` result.
pub const ServerInfo = struct {
    name: []const u8,
    version: []const u8,
};

/// Server capability flags (subset of the MCP capabilities object).
pub const Capabilities = struct {
    tools: bool = false,
    resources: bool = false,
    prompts: bool = false,
    logging: bool = false,
};

/// A tool exposed by an MCP server. `input_schema` is the JSON Schema as
/// serialized JSON text — the same shape the ACP tool surface carries in its
/// `parameters` field, so the mapping is direct.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

/// A resource exposed by an MCP server.
pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    description: []const u8,
    mime_type: []const u8,
};

/// Resource contents from `resources/read` (text contents only in this cut;
/// `blob`/binary contents are unsupported for now).
pub const ResourceContent = struct {
    uri: []const u8,
    mime_type: []const u8,
    text: []const u8,
};

/// A prompt template exposed by an MCP server. `arguments` is the schema
/// array as serialized JSON text (empty string when absent).
pub const Prompt = struct {
    name: []const u8,
    description: []const u8,
    arguments: []const u8,
};

/// A prompt message from `prompts/get`. `content` is the content block as
/// serialized JSON text.
pub const PromptMessage = struct {
    role: []const u8,
    content: []const u8,
};

/// A content block in a `tools/call` result. Text is supported in this cut;
/// image/audio/resource blocks are skipped (logged-free) until needed.
pub const ContentBlock = union(enum) {
    text: struct {
        text: []const u8,
    },
};

/// The result of a `tools/call`.
pub const ToolResult = struct {
    content: []ContentBlock,
    is_error: bool,
};

/// A JSON-RPC error object returned by an MCP server (copied, caller-owned).
pub const McpError = struct {
    code: i32,
    message: []const u8,
};
