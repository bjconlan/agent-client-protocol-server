//! MCP client module root — modelcontextprotocol.io client over stdio.
//!
//! A generic, protocol-agnostic MCP **client** (the protocol has client and
//! server roles; this module implements the client). Shared JSON-RPC 2.0
//! framing comes from `protocol/json_rpc.zig`. Exposed as the `mcp_client`
//! Zig module so it is consumable standalone and extractable to its own
//! package later.

const std = @import("std");

pub const client = @import("client.zig");
pub const types = @import("types.zig");
pub const transport = @import("transport.zig");
/// Test-only scripted transport (mirrors `util/mock_http.zig`).
pub const mock = @import("mock.zig");

pub const Client = client.Client;
pub const Transport = transport.Transport;
pub const StdioTransport = transport.StdioTransport;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(client);
    std.testing.refAllDecls(types);
    std.testing.refAllDecls(transport);
}
