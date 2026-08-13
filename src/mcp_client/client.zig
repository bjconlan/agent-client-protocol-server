//! MCP client: connect to an MCP server over stdio and call its tools
//! (plus resources and prompts) — modelcontextprotocol.io.
//!
//! Protocol-agnostic: MCP is an independent JSON-RPC 2.0 protocol; the client
//! only knows the MCP wire contract. The ACP integration (config surface,
//! tool-surface merging) lives in the ACP layers (`src/tools/`,
//! `src/config.zig`, `src/server.zig`).
//!
//! Ownership model: methods copy their results into the caller's `allocator`;
//! the client's own arena holds negotiated state (protocol version, server
//! info, capabilities, last error) for the client's lifetime.

const std = @import("std");
const Io = std.Io;

const json_rpc = @import("json_rpc");
const transport_mod = @import("transport.zig");
const types = @import("types.zig");

pub const Transport = transport_mod.Transport;
pub const types_mod = types;

/// MCP client over a line-based transport.
pub const Client = struct {
    io: Io,
    transport: Transport,
    /// Long-lived state (negotiated protocol version, server info,
    /// capabilities, last error) — owned by the client.
    arena: std.heap.ArenaAllocator,
    next_id: u64 = 1,
    write_mutex: Io.Mutex = Io.Mutex.init,
    /// Negotiated MCP protocol version (e.g. "2025-06-18").
    protocol_version: ?[]const u8 = null,
    server_info: ?types.ServerInfo = null,
    capabilities: types.Capabilities = .{},
    /// Set after a failed request; cleared at the start of each request.
    last_error: ?types.McpError = null,

    pub fn init(allocator: std.mem.Allocator, io: Io, transport: Transport) Client {
        return .{
            .io = io,
            .transport = transport,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Client) void {
        self.transport.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// MCP `initialize` handshake: negotiates `protocol_version`, records the
    /// server's capabilities/info, then sends `notifications/initialized`
    /// (required by the spec). `allocator` must outlive the client (it owns
    /// the negotiated state).
    pub fn initialize(
        self: *Client,
        allocator: std.mem.Allocator,
        protocol_version: []const u8,
        client_info: types.ClientInfo,
    ) !void {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const a = scratch.allocator();

        var info_obj: std.json.ObjectMap = .empty;
        try info_obj.put(a, "name", .{ .string = client_info.name });
        try info_obj.put(a, "version", .{ .string = client_info.version });
        var params_obj: std.json.ObjectMap = .empty;
        try params_obj.put(a, "protocolVersion", .{ .string = protocol_version });
        try params_obj.put(a, "capabilities", .{ .object = .empty });
        try params_obj.put(a, "clientInfo", .{ .object = info_obj });

        const result = try self.exchange(a, "initialize", .{ .object = params_obj });

        const ca = self.arena.allocator();
        self.protocol_version = if (objString(result, "protocolVersion")) |pv|
            try ca.dupe(u8, pv)
        else
            null;
        if (objValue(result, "serverInfo")) |si| {
            self.server_info = .{
                .name = try ca.dupe(u8, objString(si, "name") orelse ""),
                .version = try ca.dupe(u8, objString(si, "version") orelse ""),
            };
        }
        if (objValue(result, "capabilities")) |cap_v| {
            self.capabilities = .{
                .tools = hasKey(cap_v, "tools"),
                .resources = hasKey(cap_v, "resources"),
                .prompts = hasKey(cap_v, "prompts"),
                .logging = hasKey(cap_v, "logging"),
            };
        }

        // The client MUST send `notifications/initialized` after initialize.
        var nout: Io.Writer.Allocating = .init(a);
        try json_rpc.serializeNotification(a, &nout.writer, "notifications/initialized", .{ .object = .empty });
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        try self.transport.writeLine(self.io, nout.written());
    }

    /// MCP `ping` — round-trips an empty request.
    pub fn ping(self: *Client, allocator: std.mem.Allocator) !void {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        _ = try self.exchange(scratch.allocator(), "ping", .{ .object = .empty });
    }

    /// MCP `tools/list` — the server's tool definitions.
    pub fn listTools(self: *Client, allocator: std.mem.Allocator) ![]types.Tool {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const a = scratch.allocator();

        const result = try self.exchange(a, "tools/list", .{ .object = .empty });
        const arr = switch (objValue(result, "tools") orelse return error.McpInvalidResponse) {
            .array => |arr| arr,
            else => return error.McpInvalidResponse,
        };

        var list: std.ArrayList(types.Tool) = .empty;
        for (arr.items) |tv| {
            const name = objString(tv, "name") orelse continue;
            const schema = objValue(tv, "inputSchema") orelse std.json.Value{ .object = .empty };
            var w: Io.Writer.Allocating = .init(a);
            try std.json.Stringify.value(schema, .{}, &w.writer);
            try list.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .description = try allocator.dupe(u8, objString(tv, "description") orelse ""),
                .input_schema = try allocator.dupe(u8, w.written()),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    /// MCP `tools/call` — execute a tool on the server.
    pub fn callTool(
        self: *Client,
        allocator: std.mem.Allocator,
        name: []const u8,
        arguments: ?std.json.Value,
    ) !types.ToolResult {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const a = scratch.allocator();

        var params_obj: std.json.ObjectMap = .empty;
        try params_obj.put(a, "name", .{ .string = name });
        if (arguments) |args| try params_obj.put(a, "arguments", args);

        const result = try self.exchange(a, "tools/call", .{ .object = params_obj });

        const is_error = switch (objValue(result, "isError") orelse std.json.Value{ .bool = false }) {
            .bool => |b| b,
            else => false,
        };
        var content: std.ArrayList(types.ContentBlock) = .empty;
        if (objValue(result, "content")) |content_v| {
            const arr = switch (content_v) {
                .array => |arr| arr,
                else => return error.McpInvalidResponse,
            };
            for (arr.items) |block| {
                const btype = objString(block, "type") orelse continue;
                if (std.mem.eql(u8, btype, "text")) {
                    const text = objString(block, "text") orelse continue;
                    try content.append(allocator, .{ .text = .{ .text = try allocator.dupe(u8, text) } });
                }
                // image/audio/resource blocks: skipped in this cut
            }
        }
        return .{ .content = try content.toOwnedSlice(allocator), .is_error = is_error };
    }

    /// MCP `resources/list`.
    pub fn listResources(self: *Client, allocator: std.mem.Allocator) ![]types.Resource {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const a = scratch.allocator();

        const result = try self.exchange(a, "resources/list", .{ .object = .empty });
        const arr = switch (objValue(result, "resources") orelse return error.McpInvalidResponse) {
            .array => |arr| arr,
            else => return error.McpInvalidResponse,
        };

        var list: std.ArrayList(types.Resource) = .empty;
        for (arr.items) |rv| {
            const uri = objString(rv, "uri") orelse continue;
            try list.append(allocator, .{
                .uri = try allocator.dupe(u8, uri),
                .name = try allocator.dupe(u8, objString(rv, "name") orelse ""),
                .description = try allocator.dupe(u8, objString(rv, "description") orelse ""),
                .mime_type = try allocator.dupe(u8, objString(rv, "mimeType") orelse ""),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    /// MCP `resources/read` — reads the first content block (text only).
    pub fn readResource(self: *Client, allocator: std.mem.Allocator, uri: []const u8) !types.ResourceContent {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const a = scratch.allocator();

        var params_obj: std.json.ObjectMap = .empty;
        try params_obj.put(a, "uri", .{ .string = uri });

        const result = try self.exchange(a, "resources/read", .{ .object = params_obj });
        const arr = switch (objValue(result, "contents") orelse return error.McpInvalidResponse) {
            .array => |arr| arr,
            else => return error.McpInvalidResponse,
        };
        if (arr.items.len == 0) return error.McpInvalidResponse;
        const first = arr.items[0];
        return .{
            .uri = try allocator.dupe(u8, objString(first, "uri") orelse uri),
            .mime_type = try allocator.dupe(u8, objString(first, "mimeType") orelse ""),
            .text = try allocator.dupe(u8, objString(first, "text") orelse ""),
        };
    }

    /// MCP `prompts/list`.
    pub fn listPrompts(self: *Client, allocator: std.mem.Allocator) ![]types.Prompt {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const a = scratch.allocator();

        const result = try self.exchange(a, "prompts/list", .{ .object = .empty });
        const arr = switch (objValue(result, "prompts") orelse return error.McpInvalidResponse) {
            .array => |arr| arr,
            else => return error.McpInvalidResponse,
        };

        var list: std.ArrayList(types.Prompt) = .empty;
        for (arr.items) |pv| {
            const name = objString(pv, "name") orelse continue;
            const args_v = objValue(pv, "arguments") orelse std.json.Value{ .array = std.json.Array.init(a) };
            var w: Io.Writer.Allocating = .init(a);
            try std.json.Stringify.value(args_v, .{}, &w.writer);
            try list.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .description = try allocator.dupe(u8, objString(pv, "description") orelse ""),
                .arguments = try allocator.dupe(u8, w.written()),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    /// MCP `prompts/get` — resolves a prompt template into messages.
    pub fn getPrompt(
        self: *Client,
        allocator: std.mem.Allocator,
        name: []const u8,
        arguments: ?std.json.Value,
    ) ![]types.PromptMessage {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const a = scratch.allocator();

        var params_obj: std.json.ObjectMap = .empty;
        try params_obj.put(a, "name", .{ .string = name });
        if (arguments) |args| try params_obj.put(a, "arguments", args);

        const result = try self.exchange(a, "prompts/get", .{ .object = params_obj });
        const arr = switch (objValue(result, "messages") orelse return error.McpInvalidResponse) {
            .array => |arr| arr,
            else => return error.McpInvalidResponse,
        };

        var list: std.ArrayList(types.PromptMessage) = .empty;
        for (arr.items) |mv| {
            const role = objString(mv, "role") orelse continue;
            const content_v = objValue(mv, "content") orelse std.json.Value{ .object = .empty };
            var w: Io.Writer.Allocating = .init(a);
            try std.json.Stringify.value(content_v, .{}, &w.writer);
            try list.append(allocator, .{
                .role = try allocator.dupe(u8, role),
                .content = try allocator.dupe(u8, w.written()),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    // ------------------------------------------------------------------
    // Request/response plumbing
    // ------------------------------------------------------------------

    /// Send a request and return the response's `result` (a `std.json.Value`
    /// owned by `arena` — the caller's scratch arena, valid until it resets).
    /// Reads lines until the response matching this request's id arrives,
    /// skipping server-initiated notifications/requests. On error the client
    /// records the server's error object in `last_error`.
    fn exchange(self: *Client, arena: std.mem.Allocator, method: []const u8, params: std.json.Value) !std.json.Value {
        self.last_error = null;
        const request_id: i64 = @intCast(self.next_id);
        self.next_id += 1;

        var out: Io.Writer.Allocating = .init(arena);
        try json_rpc.serializeRequest(arena, &out.writer, .{ .int = request_id }, method, params);

        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        try self.transport.writeLine(self.io, out.written());

        while (true) {
            const line = (try self.transport.readLine(self.io)) orelse {
                self.setLastError(-32000, "MCP connection closed before a response arrived");
                return error.McpConnectionClosed;
            };
            const parsed = try json_rpc.parse(arena, line);
            switch (parsed.message) {
                .response => |r| switch (r.id) {
                    .int => |rid| if (rid == request_id) return r.result,
                    else => {},
                },
                .error_response => |e| switch (e.id) {
                    .int => |rid| if (rid == request_id) {
                        self.setLastError(e.error_object.code, e.error_object.message);
                        return error.McpRequestFailed;
                    },
                    else => {},
                },
                // Server-initiated notification or request: skip and keep reading.
                else => {},
            }
        }
    }

    fn setLastError(self: *Client, code: i32, message: []const u8) void {
        self.last_error = .{
            .code = code,
            .message = self.arena.allocator().dupe(u8, message) catch "",
        };
    }
};

// ---------------------------------------------------------------------------
// JSON access helpers
// ---------------------------------------------------------------------------

fn objValue(v: std.json.Value, key: []const u8) ?std.json.Value {
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    return o.get(key);
}

fn objString(v: std.json.Value, key: []const u8) ?[]const u8 {
    const fv = objValue(v, key) orelse return null;
    return switch (fv) {
        .string => |s| s,
        else => null,
    };
}

fn hasKey(v: std.json.Value, key: []const u8) bool {
    return objValue(v, key) != null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const MockTransport = @import("mock.zig").MockTransport;

test "initialize handshake: request shape + negotiated state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock = MockTransport.init(a, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{},\"prompts\":{}},\"serverInfo\":{\"name\":\"mock-mcp\",\"version\":\"1.0\"}}}",
    });
    var client = Client.init(a, testing.io, mock.transport());
    defer client.deinit();

    try client.initialize(a, "2025-06-18", .{ .name = "acps", .version = "0.1.0" });

    try testing.expectEqualStrings("2025-06-18", client.protocol_version.?);
    try testing.expectEqualStrings("mock-mcp", client.server_info.?.name);
    try testing.expect(client.capabilities.tools);
    try testing.expect(client.capabilities.prompts);
    try testing.expect(!client.capabilities.resources);

    try testing.expectEqual(@as(usize, 2), mock.writes.items.len);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"acps\",\"version\":\"0.1.0\"}}}",
        mock.writes.items[0],
    );
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}",
        mock.writes.items[1],
    );
}

test "tools/list + tools/call transcript" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock = MockTransport.init(a, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"get_time\",\"description\":\"Get the time\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"12:00 UTC\"}],\"isError\":false}}",
    });
    var client = Client.init(a, testing.io, mock.transport());
    defer client.deinit();

    const tools = try client.listTools(a);
    try testing.expectEqual(@as(usize, 1), tools.len);
    try testing.expectEqualStrings("get_time", tools[0].name);
    try testing.expectEqualStrings("Get the time", tools[0].description);
    try testing.expectEqualStrings("{\"type\":\"object\",\"properties\":{}}", tools[0].input_schema);

    const result = try client.callTool(a, "get_time", null);
    try testing.expect(!result.is_error);
    try testing.expectEqual(@as(usize, 1), result.content.len);
    try testing.expectEqualStrings("12:00 UTC", result.content[0].text.text);

    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"get_time\"}}",
        mock.writes.items[1],
    );
}

test "tools/call with arguments forwards them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock = MockTransport.init(a, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}",
    });
    var client = Client.init(a, testing.io, mock.transport());
    defer client.deinit();

    var args_obj: std.json.ObjectMap = .empty;
    try args_obj.put(a, "query", .{ .string = "zig" });
    _ = try client.callTool(a, "search", .{ .object = args_obj });

    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"search\",\"arguments\":{\"query\":\"zig\"}}}",
        mock.writes.items[0],
    );
}

test "error response sets last_error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock = MockTransport.init(a, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"unknown tool: nope\"}}",
    });
    var client = Client.init(a, testing.io, mock.transport());
    defer client.deinit();

    try testing.expectError(error.McpRequestFailed, client.callTool(a, "nope", null));
    try testing.expectEqual(@as(i32, -32602), client.last_error.?.code);
    try testing.expectEqualStrings("unknown tool: nope", client.last_error.?.message);
}

test "interleaved server notification is skipped, matching response wins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock = MockTransport.init(a, &.{
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"info\",\"data\":\"hello from server\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
    });
    var client = Client.init(a, testing.io, mock.transport());
    defer client.deinit();

    try client.ping(a);
}

test "EOF before a response raises McpConnectionClosed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock = MockTransport.init(a, &.{});
    var client = Client.init(a, testing.io, mock.transport());
    defer client.deinit();

    try testing.expectError(error.McpConnectionClosed, client.ping(a));
    try testing.expectEqual(@as(i32, -32000), client.last_error.?.code);
}

test "resources + prompts transcript" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock = MockTransport.init(a, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resources\":[{\"uri\":\"file:///tmp/x.txt\",\"name\":\"x\",\"description\":\"a file\",\"mimeType\":\"text/plain\"}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"contents\":[{\"uri\":\"file:///tmp/x.txt\",\"mimeType\":\"text/plain\",\"text\":\"hello\"}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"prompts\":[{\"name\":\"greet\",\"description\":\"say hi\",\"arguments\":[{\"name\":\"who\"}]}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"Hello there\"}}]}}",
    });
    var client = Client.init(a, testing.io, mock.transport());
    defer client.deinit();

    const resources = try client.listResources(a);
    try testing.expectEqual(@as(usize, 1), resources.len);
    try testing.expectEqualStrings("file:///tmp/x.txt", resources[0].uri);
    try testing.expectEqualStrings("text/plain", resources[0].mime_type);

    const rc = try client.readResource(a, "file:///tmp/x.txt");
    try testing.expectEqualStrings("hello", rc.text);

    const prompts = try client.listPrompts(a);
    try testing.expectEqual(@as(usize, 1), prompts.len);
    try testing.expectEqualStrings("greet", prompts[0].name);
    try testing.expect(std.mem.indexOf(u8, prompts[0].arguments, "\"who\"") != null);

    const msgs = try client.getPrompt(a, "greet", null);
    try testing.expectEqual(@as(usize, 1), msgs.len);
    try testing.expectEqualStrings("user", msgs[0].role);
    try testing.expect(std.mem.indexOf(u8, msgs[0].content, "Hello there") != null);
}

test "invalid response shape raises McpInvalidResponse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock = MockTransport.init(a, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"not_tools\":[]}}",
    });
    var client = Client.init(a, testing.io, mock.transport());
    defer client.deinit();

    try testing.expectError(error.McpInvalidResponse, client.listTools(a));
}
