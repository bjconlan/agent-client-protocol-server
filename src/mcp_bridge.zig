//! MCP ↔ ACP bridge: connects configured MCP servers (stdio) and merges
//! their tools into the ACP tool surface.
//!
//! The model sees MCP tools as ordinary tools named `"<server>:<tool>"`
//! (collision-free across servers); execution is routed back to the owning
//! MCP server via `tools/call`, riding the existing ACP flow (agent-side
//! execution, client permission grants).

const std = @import("std");
const Io = std.Io;

const config_mod = @import("config.zig");
const tools_registry = @import("tools/registry.zig");
const mcp_client = @import("mcp_client");

/// MCP protocol version we negotiate (client capability).
const protocol_version = "2025-06-18";

/// One connected MCP server.
pub const Connection = struct {
    name: []const u8,
    client: mcp_client.Client,
};

/// Per-tool dispatch context: which connection and which tool to call.
pub const Dispatch = struct {
    conn: *Connection,
    tool_name: []const u8,
};

/// Spawn + initialize every configured MCP server. Per-server failures are
/// warned about and skipped — the server still runs, those tools are just
/// absent. Returns arena-owned connections.
pub fn connectAll(
    allocator: std.mem.Allocator,
    io: Io,
    config: *const config_mod.Config,
    parent_env: *const std.process.Environ.Map,
) ![]Connection {
    var list: std.ArrayList(Connection) = .empty;
    for (config.mcp_servers) |server| {
        // argv = command + args (arena-owned; the client spawns immediately)
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(allocator, server.command);
        for (server.args) |arg| try argv.append(allocator, arg);
        const argv_slice = try argv.toOwnedSlice(allocator);

        // child env = parent clone + overrides (PATH etc. preserved)
        var child_env = try parent_env.clone(allocator);
        errdefer child_env.deinit();
        for (server.env) |kv| try child_env.put(kv.key, kv.value);

        const transport = mcp_client.transport.StdioTransport.spawn(io, argv_slice, &child_env) catch |err| {
            std.log.warn("mcp: server '{s}': spawn failed: {s}", .{ server.name, @errorName(err) });
            continue;
        };
        var client = mcp_client.Client.init(allocator, io, transport.transport());
        client.initialize(allocator, protocol_version, .{ .name = "acps", .version = "0.1.0" }) catch |err| {
            std.log.warn("mcp: server '{s}': initialize failed: {s}", .{ server.name, @errorName(err) });
            client.deinit();
            continue;
        };
        try list.append(allocator, .{
            .name = try allocator.dupe(u8, server.name),
            .client = client,
        });
    }
    return list.toOwnedSlice(allocator);
}

/// Build the merged tool surface: static registry tools + one entry per MCP
/// tool, named `"<server>:<tool>"`, with `parameters` = the MCP inputSchema
/// (JSON text, same shape as the static entries). Caller owns the result.
pub fn buildToolSurface(
    allocator: std.mem.Allocator,
    connections: []Connection,
) ![]tools_registry.Tool {
    var list: std.ArrayList(tools_registry.Tool) = .empty;
    try list.appendSlice(allocator, &tools_registry.registry);

    // Per-tool dispatch contexts, arena-owned, indexed by list order.
    var dispatches: std.ArrayList(Dispatch) = .empty;
    for (connections) |*conn| {
        const tools = conn.client.listTools(allocator) catch |err| {
            std.log.warn("mcp: server '{s}': tools/list failed: {s}", .{ conn.name, @errorName(err) });
            continue;
        };
        for (tools) |tool| {
            const full_name = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ conn.name, tool.name });
            try dispatches.append(allocator, .{
                .conn = conn,
                .tool_name = try allocator.dupe(u8, tool.name),
            });
            try list.append(allocator, .{
                .name = full_name,
                .description = tool.description,
                .kind = "execute",
                .parameters = tool.input_schema,
                .ctx = @ptrCast(&dispatches.items[dispatches.items.len - 1]),
                .execute = mcpExecute,
            });
        }
    }
    return list.toOwnedSlice(allocator);
}

/// Execute an MCP tool: parse the args JSON, call the owning server, join the
/// text content blocks into the result text contract.
fn mcpExecute(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: Io,
    args_json: []const u8,
) anyerror![]const u8 {
    _ = io;
    const d: *Dispatch = @ptrCast(@alignCast(ctx.?));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var scanner = std.json.Scanner.initCompleteInput(a, args_json);
    const args = std.json.Value.jsonParse(a, &scanner, .{
        .allocate = .alloc_always,
        .max_value_len = args_json.len,
    }) catch return error.InvalidToolArguments;

    const arguments: ?std.json.Value = switch (args) {
        .object => args,
        else => null,
    };
    const result = try d.conn.client.callTool(a, d.tool_name, arguments);

    var out: std.ArrayList(u8) = .empty;
    for (result.content) |block| switch (block) {
        .text => |t| {
            if (out.items.len > 0) try out.append(allocator, ' ');
            try out.appendSlice(allocator, t.text);
        },
    };
    return try out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const MockTransport = mcp_client.mock.MockTransport;

test "buildToolSurface merges static + MCP tools and dispatches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock = MockTransport.init(a, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"read_file\",\"description\":\"Read a file\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}}]}}",
    });
    var client = mcp_client.Client.init(a, testing.io, mock.transport());
    defer client.deinit();
    try client.initialize(a, protocol_version, .{ .name = "acps", .version = "0.1.0" });

    var conns: [1]Connection = .{.{ .name = "fs", .client = client }};
    const surface = try buildToolSurface(a, &conns);
    // static registry (2) + 1 MCP tool
    try testing.expectEqual(@as(usize, 3), surface.len);

    const mcp_tool = tools_registry.lookupIn(surface, "fs:read_file").?;
    try testing.expectEqualStrings("Read a file", mcp_tool.description);
    try testing.expect(std.mem.indexOf(u8, mcp_tool.parameters, "\"path\"") != null);
    try testing.expect(tools_registry.lookupIn(surface, "get_current_time") != null);
    try testing.expect(tools_registry.lookupIn(surface, "fs:nope") == null);

    // Script the tools/call response, then dispatch through the tool's ctx.
    try mock.appendResponse(a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"file contents\"}]}}");
    const result = try mcp_tool.execute(mcp_tool.ctx, a, testing.io, "{\"path\":\"/tmp/x\"}");
    try testing.expectEqualStrings("file contents", result);
}
