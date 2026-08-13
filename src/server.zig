//! ACP server transport loop.
//!
//! Reads newline-delimited JSON-RPC 2.0 messages from `reader`, dispatches
//! them, and writes responses/notifications to `writer`. stdin EOF (the
//! client closing the pipes) terminates the loop cleanly with no further
//! writes — writing to a closed pipe pollutes stderr and breaks exec-based
//! callers.
//!
//! Written against the `std.Io.Reader`/`std.Io.Writer` interfaces so the
//! loop is testable in-process (fixed readers / allocating writers) and the
//! binary only wires real stdio files.

const std = @import("std");
const Io = std.Io;

const json_rpc = @import("json_rpc");
const methods_v1 = @import("protocol/v1/methods.zig");
const types_v1 = @import("protocol/v1/types.zig");
const echo = @import("provider/echo.zig");
const config_mod = @import("config.zig");
const mcp_bridge = @import("mcp_bridge.zig");

/// Protocol messages only on stdout; all logging goes to stderr (callers
/// wire the file handles).
const line_buffer_size = 1024 * 1024;

/// Run the transport loop until EOF. `gpa` backs a per-message arena that is
/// reset each iteration; the session store, HTTP client, and prompt workers
/// use `gpa` directly (process lifetime).
pub fn run(
    io: Io,
    reader: *Io.Reader,
    writer: *Io.Writer,
    gpa: std.mem.Allocator,
    config: config_mod.Config,
    adapters: [2]?@import("provider/adapter.zig").Provider,
    mcp_connections: []mcp_bridge.Connection,
) !void {
    var msg_arena = std.heap.ArenaAllocator.init(gpa);
    defer msg_arena.deinit();

    // Merged tool surface: static registry + MCP tools (process lifetime).
    const tool_surface = try mcp_bridge.buildToolSurface(gpa, mcp_connections);

    // Process-lifetime session store (outlives per-message arenas).
    var session_store = types_v1.SessionStore.init(gpa);
    defer session_store.deinit();

    var writer_lock: std.atomic.Mutex = .unlocked;
    var cancel_requested = std.atomic.Value(bool).init(false);
    var worker_done = std.atomic.Value(bool).init(false);
    var permission = methods_v1.PendingPermission{};
    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var ctx = methods_v1.Context{
        .io = io,
        .sessions = &session_store,
        .writer = writer,
        .writer_lock = &writer_lock,
        .adapters = adapters,
        .cancel_requested = &cancel_requested,
        .worker_done = &worker_done,
        .http = &http_client,
        .config = config,
        .tools = tool_surface,
        .process_allocator = gpa,
        .permission = &permission,
    };
    _ = echo;

    while (true) {
        _ = msg_arena.reset(.retain_capacity);
        const msg_alloc = msg_arena.allocator();

        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                // Line exceeds the reader buffer: discard it and answer with a
                // parse error, then keep the connection alive.
                _ = reader.discardDelimiterInclusive('\n') catch {};
                respondErrorLocked(&ctx, msg_alloc, .null, json_rpc.ErrorCode.parse_error, "Parse error") catch break;
                continue;
            },
            else => {
                std.log.err("stdio read failed: {s}", .{@errorName(err)});
                break;
            },
        } orelse break; // EOF

        std.log.scoped(.transport).debug("[in] {s}", .{line});
        if (line.len == 0) continue; // transport-level keepalive line

        const parsed = json_rpc.parse(msg_alloc, line) catch |err| switch (err) {
            error.ParseError => {
                respondErrorLocked(&ctx, msg_alloc, .null, json_rpc.ErrorCode.parse_error, "Parse error") catch break;
                continue;
            },
            error.InvalidRequest => {
                respondErrorLocked(&ctx, msg_alloc, .null, json_rpc.ErrorCode.invalid_request, "Invalid Request") catch break;
                continue;
            },
        };

        dispatch(&ctx, msg_alloc, parsed.message) catch break;
    }

    // EOF: cancel a still-running prompt worker and join it, then exit
    // cleanly with no further writes. A finished worker is joined as-is so a
    // fast turn isn't spuriously reported as cancelled.
    if (ctx.active_worker) |worker_thread| {
        if (!ctx.worker_done.load(.monotonic)) cancel_requested.store(true, .monotonic);
        worker_thread.join();
    }
}

/// Dispatch a request or notification through the v1 registry. Requests are
/// answered by the handler (result or mapped error); `DeferredResponse`
/// means a worker owns the turn's output. Notifications are handled and
/// receive no response; unexpected inbound responses are ignored.
fn dispatch(
    ctx: *methods_v1.Context,
    allocator: std.mem.Allocator,
    message: json_rpc.Message,
) !void {
    switch (message) {
        .request => |r| {
            if (methods_v1.lookup(r.method)) |handler| {
                std.log.scoped(.transport).debug("[out] response for id {any} method {s}", .{ r.id, r.method });
                const result = handler(ctx, allocator, r.id, r.params) catch |err| switch (err) {
                    error.DeferredResponse => return, // worker writes the output
                    else => {
                        try respondErrorLocked(ctx, allocator, r.id, errorCode(err), "Method failed");
                        return;
                    },
                };
                methods_v1.lockSpin(ctx.writer_lock);
                defer ctx.writer_lock.unlock();
                try json_rpc.serializeResponse(allocator, ctx.writer, r.id, result);
                try ctx.writer.writeAll("\n");
                try ctx.writer.flush();
            } else {
                try respondErrorLocked(ctx, allocator, r.id, json_rpc.ErrorCode.method_not_found, "Method not found");
            }
        },
        .notification => |n| {
            if (methods_v1.lookupNotification(n.method)) |handler| {
                handler(ctx, allocator, n.params) catch |err| {
                    std.log.err("notification '{s}' failed: {s}", .{ n.method, @errorName(err) });
                };
            }
        },
        .response => |resp| {
            // Route the client's response to the pending permission request
            // (the prompt worker waits on the slot).
            if (!ctx.permission.done and ctx.permission.request_id != 0 and
                idMatches(resp.id, ctx.permission.request_id))
            {
                methods_v1.lockSpin(&ctx.permission.mutex);
                ctx.permission.granted = parsePermissionGranted(resp.result);
                ctx.permission.done = true;
                ctx.permission.mutex.unlock();
            }
        },
        .error_response => |resp| {
            if (!ctx.permission.done and ctx.permission.request_id != 0 and
                idMatches(resp.id, ctx.permission.request_id))
            {
                methods_v1.lockSpin(&ctx.permission.mutex);
                ctx.permission.granted = false;
                ctx.permission.done = true;
                ctx.permission.mutex.unlock();
            }
        },
    }
}

/// Does a JSON-RPC id equal a plain string id? (The worker uses string ids
/// like "p1"; the client echoes them verbatim.)
fn idMatches(id: json_rpc.RequestId, expected: i64) bool {
    return switch (id) {
        .int => |i| i == expected,
        else => false,
    };
}

/// Parse a permission response result: fossil client `{granted: bool}` or
/// schema `{outcome: ...}`.
fn parsePermissionGranted(result: std.json.Value) bool {
    const obj = switch (result) {
        .object => |o| o,
        else => return false,
    };
    if (obj.get("granted")) |g| switch (g) {
        .bool => |b| return b,
        else => {},
    };
    if (obj.get("outcome")) |o| switch (o) {
        .object => |oo| {
            const out = oo.get("outcome") orelse return false;
            if (out != .string) return false;
            if (std.mem.eql(u8, out.string, "cancelled")) return false;
            // "selected" → granted (option id would tell allow vs reject;
            // MVP treats selection as allow — see decisions.md)
            return true;
        },
        else => {},
    };
    return false;
}

/// Map handler errors to JSON-RPC codes: InvalidParams → -32602,
/// InvalidRequest → -32600, anything else (incl. OOM) → -32603.
fn errorCode(err: anyerror) i32 {
    return switch (err) {
        error.InvalidParams => json_rpc.ErrorCode.invalid_params,
        error.InvalidRequest => json_rpc.ErrorCode.invalid_request,
        else => json_rpc.ErrorCode.internal_error,
    };
}

/// Write an error response holding the writer lock (used by the main loop).
fn respondErrorLocked(
    ctx: *methods_v1.Context,
    allocator: std.mem.Allocator,
    id: json_rpc.RequestId,
    code: i32,
    message_text: []const u8,
) !void {
    methods_v1.lockSpin(ctx.writer_lock);
    defer ctx.writer_lock.unlock();
    try json_rpc.serializeError(allocator, ctx.writer, id, .{
        .code = code,
        .message = message_text,
    });
    try ctx.writer.writeAll("\n");
    try ctx.writer.flush();
}

// ---------------------------------------------------------------------------
// Tests — the transcript fixture, in-process via the Zig test framework
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectRun(input: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fixed_reader = Io.Reader.fixed(input);
    var out: Io.Writer.Allocating = .init(a);
    const cfg = testConfig(a);
    try run(io, &fixed_reader, &out.writer, a, cfg, .{ .{ .generate = echo.generate }, null }, &.{});
    try testing.expectEqualStrings(expected, out.written());
}

/// Test config: one "default" openai provider.
fn testConfig(a: std.mem.Allocator) @import("config.zig").Config {
    const providers = a.alloc(@import("config.zig").ProviderConfig, 1) catch unreachable;
    providers[0] = .{
        .name = "default",
        .api = .openai,
        .url = "http://127.0.0.1:1",
        .api_key = "test-key",
        .model = "test-model",
    };
    return .{ .default_provider = "default", .providers = providers };
}

test "transcript: requests answer method-not-found with verbatim ids" {
    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"test/unknown","params":{}}
        \\{"jsonrpc":"2.0","id":2,"method":"test/unknown2","params":{}}
        \\
        \\{"jsonrpc":"2.0","id":"req-3","method":"test/unknown3","params":null}
        \\{not json
        \\{"jsonrpc":"2.0","id":4,"method":"test/unknown4","params":null}
    ;
    const expected =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}
        \\{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}
        \\{"jsonrpc":"2.0","id":"req-3","error":{"code":-32601,"message":"Method not found"}}
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}
        \\{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"Method not found"}}
    ;
    // Zig multiline literals omit the final newline; the loop emits one per line.
    try expectRun(input, expected ++ "\n");
}

test "EOF-only input: clean return, no output" {
    try expectRun("", "");
}

test "keepalive and empty lines are skipped" {
    const input = "\n\n" ++
        \\{"jsonrpc":"2.0","id":9,"method":"x","params":{}}
    ;
    const expected = "{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}\n";
    try expectRun(input, expected);
}

test "notifications get no response" {
    const input =
        \\{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s1"}}
    ;
    try expectRun(input, "");
}

test "inbound response from client is ignored" {
    const input =
        \\{"jsonrpc":"2.0","id":7,"result":{"ok":true}}
    ;
    try expectRun(input, "");
}

test "line without trailing newline at EOF is processed" {
    const input = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"test/unknown\",\"params\":{}}";
    const expected = "{\"jsonrpc\":\"2.0\",\"id\":5,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}\n";
    try expectRun(input, expected);
}

test "initialize handshake: full response, verbatim id" {
    const input = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1,\"clientCapabilities\":{},\"clientInfo\":{\"name\":\"fossil-agent\",\"version\":\"1.0\"}}}\n";
    const expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1,\"agentCapabilities\":{\"sessionCapabilities\":{},\"promptCapabilities\":{}},\"authMethods\":[],\"agentInfo\":{\"name\":\"acps\",\"version\":\"0.1.0\"}}}\n";
    try expectRun(input, expected);
}

test "initialize: invalid protocolVersion answers -32602" {
    const input = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{\"protocolVersion\":0}}\n";
    const expected = "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32602,\"message\":\"Method failed\"}}\n";
    try expectRun(input, expected);
}

test "fossil client flow: initialize → session/new → session/prompt (streamed)" {
    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}
        \\{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}
        \\{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"1","prompt":[{"type":"text","text":"hello"}]}}
    ;
    const expected =
        \\{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{},"promptCapabilities":{}},"authMethods":[],"agentInfo":{"name":"acps","version":"0.1.0"}}}
        \\{"jsonrpc":"2.0","id":2,"result":{"sessionId":"1","configOptions":[{"id":"model","name":"Model","category":"model","value":{"type":"select","currentValue":"test-model","options":["test-model"]}}]}}
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}}}
        \\{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}
    ;
    // Zig multiline literals omit the final newline; the loop emits one per line.
    try expectRun(input, expected ++ "\n");
}

/// Test provider: returns one tool call on the first generate, then text.
/// The called tool name is read from `fake_call_name` (a plain fn — no self).
var fake_call_name: []const u8 = "get_current_time";

fn fakeToolGenerate(
    allocator: std.mem.Allocator,
    input: std.json.Value,
    prior_outputs: []const std.json.Value,
    tool_results: []const @import("provider/adapter.zig").ToolResult,
    options: @import("provider/adapter.zig").Options,
) anyerror!@import("provider/adapter.zig").Result {
    _ = input;
    _ = prior_outputs;
    if (tool_results.len == 0) {
        const calls = try allocator.alloc(@import("provider/adapter.zig").ToolCall, 1);
        calls[0] = .{ .id = "call_1", .name = fake_call_name, .arguments = "{\"x\":1}" };
        return .{ .stop_reason = "end_turn", .usage = null, .tool_calls = calls, .output_items = &.{} };
    }
    try options.emit("it is now done", options.userdata);
    return .{ .stop_reason = "end_turn", .usage = null, .tool_calls = &.{}, .output_items = &.{} };
}

test "MCP tool round-trip: model calls an MCP tool through the full ACP flow" {
    const mcp_client = @import("mcp_client");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    fake_call_name = "fs:read_file";
    defer fake_call_name = "get_current_time";

    // Scripted MCP server: initialize → tools/list → tools/call.
    var mock = mcp_client.mock.MockTransport.init(a, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"fs\",\"version\":\"1\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"read_file\",\"description\":\"Read a file\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"file contents\"}]}}",
    });
    var client = mcp_client.Client.init(a, testing.io, mock.transport());
    defer client.deinit();
    try client.initialize(a, "2025-06-18", .{ .name = "acps", .version = "0.1.0" });

    var conns: [1]mcp_bridge.Connection = .{.{ .name = "fs", .client = client }};

    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}
        \\{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}
        \\{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"1","prompt":[{"type":"text","text":"hello"}]}}
        \\{"jsonrpc":"2.0","id":1001,"result":{"granted":true}}
    ;
    var fixed_reader = Io.Reader.fixed(input);
    var out: Io.Writer.Allocating = .init(a);
    const cfg = testConfig(a);

    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    try run(threaded.io(), &fixed_reader, &out.writer, a, cfg, .{ .{ .generate = fakeToolGenerate }, null }, &conns);
    const actual = out.written();

    // MCP tool surfaces in the tool_call notification, permission flow runs,
    // the MCP server's result is fed back, then the model answers.
    try testing.expect(std.mem.indexOf(u8, actual, "\"sessionUpdate\":\"tool_call\"") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "\"method\":\"session/request_permission\"") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "file contents") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "\"status\":\"completed\"") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "\"text\":\"it is now done\"") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "\"stopReason\":\"end_turn\"") != null);
    // The ACP client saw the merged tool name, not the raw MCP name.
    try testing.expect(std.mem.indexOf(u8, actual, "fs:read_file") != null);
}

test "tool-call round-trip: echo tool, permission granted, result fed back" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    fake_call_name = "echo";
    defer fake_call_name = "get_current_time";

    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}
        \\{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}
        \\{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"1","prompt":[{"type":"text","text":"hello"}]}}
        \\{"jsonrpc":"2.0","id":1001,"result":{"granted":true}}
    ;
    var fixed_reader = Io.Reader.fixed(input);
    var out: Io.Writer.Allocating = .init(a);
    const cfg = testConfig(a);

    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    try run(threaded.io(), &fixed_reader, &out.writer, a, cfg, .{ .{ .generate = fakeToolGenerate }, null }, &.{});
    const actual = out.written();

    // tool_call (pending) notification
    try testing.expect(std.mem.indexOf(u8, actual, "\"sessionUpdate\":\"tool_call\"") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "\"rawInput\":\"{\\\"x\\\":1}\"") != null);
    // request_permission sent with id p1
    try testing.expect(std.mem.indexOf(u8, actual, "\"method\":\"session/request_permission\"") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "\"id\":1001") != null);
    // echo result fed back, completed update (deterministic)
    try testing.expect(std.mem.indexOf(u8, actual, "\"status\":\"completed\"") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "\"rawOutput\":\"{\\\"x\\\":1}\"") != null);
    // final answer + response
    try testing.expect(std.mem.indexOf(u8, actual, "\"text\":\"it is now done\"") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "\"stopReason\":\"end_turn\"") != null);
}

/// Records the model + config KVs it receives (for session-config assertions).
var fake_seen_model: []const u8 = "";
var fake_seen_kvs: std.ArrayList([]const u8) = .empty;

fn configRecordingGenerate(
    allocator: std.mem.Allocator,
    input: std.json.Value,
    prior_outputs: []const std.json.Value,
    tool_results: []const @import("provider/adapter.zig").ToolResult,
    options: @import("provider/adapter.zig").Options,
) anyerror!@import("provider/adapter.zig").Result {
    _ = allocator;
    _ = input;
    _ = prior_outputs;
    _ = tool_results;
    for (options.config) |kv| {
        if (std.mem.eql(u8, kv.key, "model")) {
            fake_seen_model = kv.value;
        } else {
            fake_seen_kvs.append(std.heap.page_allocator, kv.value) catch {};
        }
    }
    try options.emit("ok", options.userdata);
    return .{ .stop_reason = "end_turn", .usage = null, .tool_calls = &.{}, .output_items = &.{} };
}

test "session config: set_config_option updates model, prompt uses it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    fake_seen_model = "";
    fake_seen_kvs = .empty;
    defer fake_seen_kvs.deinit(std.heap.page_allocator);

    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}
        \\{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}
        \\{"jsonrpc":"2.0","id":3,"method":"session/set_config_option","params":{"sessionId":"1","configId":"model","value":{"value":"new-model"}}}
        \\{"jsonrpc":"2.0","id":4,"method":"session/set_config_option","params":{"sessionId":"1","configId":"temperature","value":{"value":"0.7"}}}
        \\{"jsonrpc":"2.0","id":5,"method":"session/prompt","params":{"sessionId":"1","prompt":[{"type":"text","text":"hello"}]}}
    ;
    var fixed_reader = Io.Reader.fixed(input);
    var out: Io.Writer.Allocating = .init(a);
    const cfg = testConfig(a);

    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    try run(threaded.io(), &fixed_reader, &out.writer, a, cfg, .{ .{ .generate = configRecordingGenerate }, null }, &.{});
    const actual = out.written();

    // set_config_option responses reflect the updated currentValue
    try testing.expect(std.mem.indexOf(u8, actual, "\"currentValue\":\"new-model\"") != null);
    // the prompt used the session model + forwarded the arbitrary knob
    try testing.expectEqualStrings("new-model", fake_seen_model);
    try testing.expect(std.mem.indexOf(u8, fake_seen_kvs.items[0], "0.7") != null);
    // session/new advertised the fallback model
    try testing.expect(std.mem.indexOf(u8, actual, "\"currentValue\":\"test-model\"") != null);
}

/// Fake anthropic adapter: one tool call, then text (like fakeToolGenerate).
fn fakeAnthropicGenerate(
    allocator: std.mem.Allocator,
    input: std.json.Value,
    prior_outputs: []const std.json.Value,
    tool_results: []const @import("provider/adapter.zig").ToolResult,
    options: @import("provider/adapter.zig").Options,
) anyerror!@import("provider/adapter.zig").Result {
    _ = input;
    _ = prior_outputs;
    if (tool_results.len == 0) {
        const calls = try allocator.alloc(@import("provider/adapter.zig").ToolCall, 1);
        calls[0] = .{ .id = "toolu_1", .name = "echo", .arguments = "{}" };
        return .{ .stop_reason = "tool_use", .usage = null, .tool_calls = calls, .output_items = &.{} };
    }
    try options.emit("anthropic answered", options.userdata);
    return .{ .stop_reason = "end_turn", .usage = null, .tool_calls = &.{}, .output_items = &.{} };
}

test "worker dispatch: anthropic api provider uses the anthropic adapter slot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const providers = a.alloc(@import("config.zig").ProviderConfig, 1) catch unreachable;
    providers[0] = .{
        .name = "default",
        .api = .anthropic,
        .url = "http://127.0.0.1:1",
        .api_key = "sk-ant",
        .model = "deepseek-v4-flash",
    };
    const cfg = @import("config.zig").Config{ .default_provider = "default", .providers = providers };

    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}
        \\{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}
        \\{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"1","prompt":[{"type":"text","text":"hello"}]}}
        \\{"jsonrpc":"2.0","id":1001,"result":{"granted":true}}
    ;
    var fixed_reader = Io.Reader.fixed(input);
    var out: Io.Writer.Allocating = .init(a);

    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    try run(threaded.io(), &fixed_reader, &out.writer, a, cfg, .{ null, .{ .generate = fakeAnthropicGenerate } }, &.{});
    const actual = out.written();

    // tool call reported + permission + executed via the anthropic slot
    try testing.expect(std.mem.indexOf(u8, actual, "\"sessionUpdate\":\"tool_call\"") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "\"rawOutput\":\"{}\"") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "\"text\":\"anthropic answered\"") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "\"stopReason\":\"end_turn\"") != null);
}

/// Slow provider: emits one chunk, waits, then emits another — lets the
/// test's EOF/cancel land mid-stream deterministically.
fn slowGenerate(
    allocator: std.mem.Allocator,
    input: std.json.Value,
    prior_outputs: []const std.json.Value,
    tool_results: []const @import("provider/adapter.zig").ToolResult,
    options: @import("provider/adapter.zig").Options,
) anyerror!@import("provider/adapter.zig").Result {
    _ = allocator;
    _ = input;
    _ = prior_outputs;
    _ = tool_results;
    try options.emit("first", options.userdata);
    for (0..100_000) |_| _ = std.Thread.yield() catch {};
    if (options.is_cancelled(options.userdata)) {
        return .{ .stop_reason = "cancelled", .usage = null, .tool_calls = &.{}, .output_items = &.{} };
    }
    try options.emit("second", options.userdata);
    return .{ .stop_reason = "end_turn", .usage = null, .tool_calls = &.{}, .output_items = &.{} };
}

test "EOF mid-prompt cancels the turn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // prompt is immediately followed by EOF — the loop cancels the in-flight
    // worker; it has already emitted its first chunk, so the cancel is honored.
    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}
        \\{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}
        \\{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"1","prompt":[{"type":"text","text":"hello"}]}}
    ;
    var fixed_reader = Io.Reader.fixed(input);
    var out: Io.Writer.Allocating = .init(a);
    const cfg = testConfig(a);

    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    try run(threaded.io(), &fixed_reader, &out.writer, a, cfg, .{ .{ .generate = slowGenerate }, null }, &.{});
    const actual = out.written();

    // the first chunk streamed, then the EOF cancel answered cancelled
    try testing.expect(std.mem.indexOf(u8, actual, "\"text\":\"first\"") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "\"stopReason\":\"cancelled\"") != null);
}

test "prompt after a consumed cancel is not spuriously cancelled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // cancel before prompt 3 → prompt 3 answers cancelled (sync, flag
    // consumed). Prompt 4 must NOT answer cancelled at the start — it spawns
    // a worker and streams (the stale-flag regression would answer
    // immediately with no chunk).
    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}
        \\{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}
        \\{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"1"}}
        \\{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"1","prompt":[{"type":"text","text":"one"}]}}
        \\{"jsonrpc":"2.0","id":4,"method":"session/prompt","params":{"sessionId":"1","prompt":[{"type":"text","text":"two"}]}}
    ;
    var fixed_reader = Io.Reader.fixed(input);
    var out: Io.Writer.Allocating = .init(a);
    const cfg = testConfig(a);

    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    try run(threaded.io(), &fixed_reader, &out.writer, a, cfg, .{ .{ .generate = slowGenerate }, null }, &.{});
    const actual = out.written();

    // prompt 3: cancelled synchronously
    try testing.expect(std.mem.indexOf(u8, actual, "\"id\":3,\"result\":{\"stopReason\":\"cancelled\"}") != null);
    // prompt 4: NOT cancelled at the start — its worker ran and streamed a
    // chunk (the stale-flag bug would answer cancelled with no chunk).
    try testing.expect(std.mem.indexOf(u8, actual, "\"text\":\"first\"") != null);
}
