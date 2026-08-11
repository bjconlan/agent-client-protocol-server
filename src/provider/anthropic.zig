//! Anthropic Messages API provider adapter.
//!
//! Target: `POST {base}/v1/messages` with `stream: true` (SSE). Auth via
//! `x-api-key` + `anthropic-version` headers. Works with Anthropic-native
//! endpoints and Anthropic-compatible ones (e.g. DeepSeek at
//! `https://api.deepseek.com/anthropic`).
//!
//! Maps the shared Options/Result surface: the worker's input items
//! (Responses-style messages) are translated to Anthropic messages;
//! `tool_use` content blocks become `Result.tool_calls`; the assistant's
//! content blocks (thinking + tool_use) are echoed via `output_items` for
//! tool-result continuation (assistant message + `tool_result` user message).

const std = @import("std");
const Io = std.Io;

const http_util = @import("../util/http.zig");
const adapter = @import("adapter.zig");
const tools = @import("../tools/registry.zig");

const Options = adapter.Options;
const Result = adapter.Result;

pub const GenerateError = adapter.GenerateError;

const anthropic_version = "2023-06-01";

/// Default max output tokens (the API requires `max_tokens`).
const default_max_tokens = 1024;

/// Run one generation: POST /v1/messages, stream SSE, emit text chunks via
/// `options.emit`, collect `tool_use` calls.
pub fn generate(
    allocator: std.mem.Allocator,
    input: std.json.Value,
    prior_outputs: []const std.json.Value,
    tool_results: []const adapter.ToolResult,
    options: Options,
) GenerateError!Result {
    const body = try buildBody(allocator, options.config, input, prior_outputs, tool_results, options.tools);
    defer allocator.free(body);

    const url = try http_util.url(allocator, options.base_url, "/v1/messages");
    defer allocator.free(url);

    var response = try http_util.request(options.http, allocator, url, options.api_key, .{
        .auth = .x_api_key,
        .extra_headers = &.{.{ .name = "anthropic-version", .value = anthropic_version }},
        .body = body,
    });
    defer response.deinit();

    return parseStream(allocator, response.reader, options);
}

/// Build the /v1/messages request body from the session config KVs + input.
fn buildBody(
    allocator: std.mem.Allocator,
    config: []const adapter.ConfigKV,
    input_value: std.json.Value,
    prior_outputs: []const std.json.Value,
    tool_results: []const adapter.ToolResult,
    tools_defs: []const tools.Tool,
) ![]u8 {
    var messages: std.json.Array = std.json.Array.init(allocator);
    defer messages.deinit();

    // Translate the worker's Responses-style input items → Anthropic messages
    // ({type: "message", role, content: [{type: input_text|output_text, text}]}).
    if (input_value == .array) {
        for (input_value.array.items) |item| {
            if (item != .object) continue;
            const role = item.object.get("role") orelse continue;
            if (role != .string) continue;
            const content = item.object.get("content") orelse continue;
            var text: ?[]const u8 = null;
            if (content == .array) {
                for (content.array.items) |block| {
                    if (block != .object) continue;
                    const t = block.object.get("text") orelse continue;
                    if (t == .string) {
                        text = t.string;
                        break;
                    }
                }
            }
            if (text) |t| try appendMessage(allocator, &messages, role.string, .{ .string = t });
        }
    }

    // Prior assistant content blocks (thinking + tool_use) echoed as one
    // assistant message, then tool results as a tool_result user message.
    if (prior_outputs.len > 0) {
        try messages.append(.{ .object = blk: {
            var m: std.json.ObjectMap = .empty;
            try m.put(allocator, "role", .{ .string = "assistant" });
            var blocks: std.json.Array = std.json.Array.init(allocator);
            for (prior_outputs) |b| try blocks.append(b);
            try m.put(allocator, "content", .{ .array = blocks });
            break :blk m;
        } });
    }
    if (tool_results.len > 0) {
        var content: std.json.Array = std.json.Array.init(allocator);
        for (tool_results) |tr| {
            var block: std.json.ObjectMap = .empty;
            try block.put(allocator, "type", .{ .string = "tool_result" });
            try block.put(allocator, "tool_use_id", .{ .string = tr.call_id });
            try block.put(allocator, "content", .{ .string = tr.output });
            try content.append(.{ .object = block });
        }
        var user_msg: std.json.ObjectMap = .empty;
        try user_msg.put(allocator, "role", .{ .string = "user" });
        try user_msg.put(allocator, "content", .{ .array = content });
        try messages.append(.{ .object = user_msg });
    }

    // model / max_tokens / system from the session config KVs.
    var model: []const u8 = "deepseek-v4-flash";
    var max_tokens: i64 = default_max_tokens;
    var system: ?[]const u8 = null;
    for (config) |kv| {
        if (std.mem.eql(u8, kv.key, "model")) {
            model = kv.value;
        } else if (std.mem.eql(u8, kv.key, "max_tokens")) {
            max_tokens = std.fmt.parseInt(i64, kv.value, 10) catch continue;
        } else if (std.mem.eql(u8, kv.key, "system")) {
            system = kv.value;
        } else {
            std.log.warn("anthropic: unknown session config '{s}' — skipped", .{kv.key});
        }
    }

    // tools: flat {name, description, input_schema}.
    var tools_arr: std.json.Array = std.json.Array.init(allocator);
    defer tools_arr.deinit();
    for (tools_defs) |tool| {
        var scanner = std.json.Scanner.initCompleteInput(allocator, tool.parameters);
        const input_schema = std.json.Value.jsonParse(allocator, &scanner, .{
            .allocate = .alloc_always,
            .max_value_len = tool.parameters.len,
        }) catch continue;
        var t: std.json.ObjectMap = .empty;
        try t.put(allocator, "name", .{ .string = tool.name });
        try t.put(allocator, "description", .{ .string = tool.description });
        try t.put(allocator, "input_schema", input_schema);
        try tools_arr.append(.{ .object = t });
    }

    var root: std.json.ObjectMap = .empty;
    errdefer root.deinit(allocator);
    try root.put(allocator, "model", .{ .string = model });
    try root.put(allocator, "max_tokens", .{ .integer = max_tokens });
    if (system) |s| try root.put(allocator, "system", .{ .string = s });
    try root.put(allocator, "messages", .{ .array = messages });
    try root.put(allocator, "tools", .{ .array = tools_arr });
    try root.put(allocator, "stream", .{ .bool = true });

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(std.json.Value{ .object = root }, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn appendMessage(
    allocator: std.mem.Allocator,
    messages: *std.json.Array,
    role: []const u8,
    content: std.json.Value,
) !void {
    var m: std.json.ObjectMap = .empty;
    try m.put(allocator, "role", .{ .string = role });
    try m.put(allocator, "content", content);
    try messages.append(.{ .object = m });
}

/// Parse the SSE stream, emitting text chunks and collecting tool calls.
fn parseStream(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    options: Options,
) GenerateError!Result {
    var usage: ?adapter.Usage = null;
    var tool_calls: std.ArrayList(adapter.ToolCall) = .empty;
    var output_items: std.ArrayList(std.json.Value) = .empty;
    var stop: []const u8 = "end_turn";

    // current content block state
    var cur_args: std.ArrayList(u8) = .empty;
    var cur_is_tool = false;
    var cur_tool_id: []const u8 = "";
    var cur_tool_name: []const u8 = "";
    // The current content block (echoed into output_items for continuation).
    var cur_block: ?std.json.Value = null;

    while (true) {
        if (options.is_cancelled(options.userdata)) return .{ .stop_reason = "cancelled", .usage = usage, .tool_calls = tool_calls.items, .output_items = output_items.items };

        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.GenerateFailed,
            error.ReadFailed => return error.Network,
        } orelse break;

        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == ':') continue; // comment

        const payload = std.mem.trimStart(u8, trimmed, " ");
        std.log.scoped(.provider).debug("sse: {s}", .{trimmed});
        const data = if (std.mem.startsWith(u8, payload, "data:"))
            std.mem.trimStart(u8, payload["data:".len..], " ")
        else
            continue;
        if (data.len == 0) continue;

        var scanner = std.json.Scanner.initCompleteInput(allocator, data);
        const event = std.json.Value.jsonParse(allocator, &scanner, .{
            .allocate = .alloc_always,
            .max_value_len = data.len,
        }) catch continue;

        const obj = switch (event) {
            .object => |o| o,
            else => continue,
        };
        const event_type = switch (obj.get("type") orelse continue) {
            .string => |s| s,
            else => continue,
        };

        if (std.mem.eql(u8, event_type, "message_start")) {
            if (obj.get("message")) |m| {
                usage = extractUsage(m);
            }
        } else if (std.mem.eql(u8, event_type, "content_block_start")) {
            const block = obj.get("content_block") orelse continue;
            cur_args.clearRetainingCapacity();
            cur_is_tool = false;
            cur_block = block;
            if (block == .object) {
                const bt = block.object.get("type") orelse continue;
                if (bt == .string and std.mem.eql(u8, bt.string, "tool_use")) {
                    cur_is_tool = true;
                    if (block.object.get("id")) |id| switch (id) {
                        .string => |s| cur_tool_id = s,
                        else => {},
                    };
                    if (block.object.get("name")) |n| switch (n) {
                        .string => |s| cur_tool_name = s,
                        else => {},
                    };
                }
            }
        } else if (std.mem.eql(u8, event_type, "content_block_delta")) {
            const delta = obj.get("delta") orelse continue;
            if (delta != .object) continue;
            const dt = delta.object.get("type") orelse continue;
            if (dt != .string) continue;
            if (std.mem.eql(u8, dt.string, "text_delta")) {
                if (delta.object.get("text")) |t| switch (t) {
                    .string => |s| options.emit(s, options.userdata) catch return error.GenerateFailed,
                    else => {},
                };
            } else if (std.mem.eql(u8, dt.string, "input_json_delta")) {
                if (cur_is_tool) {
                    if (delta.object.get("partial_json")) |pj| switch (pj) {
                        .string => |s| try cur_args.appendSlice(allocator, s),
                        else => {},
                    };
                }
            }
            // thinking_delta and others are echoed via the content block.
        } else if (std.mem.eql(u8, event_type, "content_block_stop")) {
            // Echo the completed content block (thinking/text/tool_use) so a
            // tool continuation can rebuild the assistant message.
            if (cur_block) |b| try output_items.append(allocator, b);
            cur_block = null;
            if (cur_is_tool) {
                const call = adapter.ToolCall{
                    .id = try allocator.dupe(u8, cur_tool_id),
                    .name = try allocator.dupe(u8, cur_tool_name),
                    .arguments = try cur_args.toOwnedSlice(allocator),
                };
                try tool_calls.append(allocator, call);
                cur_is_tool = false;
            }
        } else if (std.mem.eql(u8, event_type, "message_delta")) {
            if (obj.get("delta")) |d| {
                if (d == .object) {
                    if (d.object.get("stop_reason")) |sr| {
                        if (sr == .string and std.mem.eql(u8, sr.string, "max_tokens")) {
                            stop = "max_tokens";
                        }
                    }
                }
            }
            // message_delta carries only output_tokens — merge into the
            // running usage.
            if (obj.get("usage")) |u| {
                if (u == .object) {
                    if (u.object.get("output_tokens")) |ot| {
                        if (ot == .integer and ot.integer > 0) {
                            const out: u64 = @intCast(ot.integer);
                            const prompt = if (usage) |prev| prev.prompt_tokens else 0;
                            usage = .{ .prompt_tokens = prompt, .total_tokens = prompt + out };
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, event_type, "message_stop")) {
            break;
        } else if (std.mem.eql(u8, event_type, "error")) {
            return error.GenerateFailed;
        }
        // ping and others are ignored.
    }

    return .{ .stop_reason = stop, .usage = usage, .tool_calls = tool_calls.items, .output_items = output_items.items };
}

/// Extract usage. Accepts a container with a `usage` field (message_start's
/// message) or the usage object itself (message_delta's top-level `usage`).
fn extractUsage(value: std.json.Value) ?adapter.Usage {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    var u = obj;
    if (obj.get("usage")) |usage| {
        u = switch (usage) {
            .object => |o| o,
            else => return null,
        };
    } else if (obj.get("input_tokens") == null) {
        return null;
    }
    const input = if (u.get("input_tokens")) |v| switch (v) {
        .integer => |i| @as(u64, @intCast(@max(i, 0))),
        else => 0,
    } else 0;
    const output = if (u.get("output_tokens")) |v| switch (v) {
        .integer => |i| @as(u64, @intCast(@max(i, 0))),
        else => 0,
    } else 0;
    return .{ .prompt_tokens = input, .total_tokens = input + output };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "buildBody: translates messages, flat tools, max_tokens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Responses-style input: one user message
    var input: std.json.Array = std.json.Array.init(a);
    var content: std.json.Array = std.json.Array.init(a);
    var text_item: std.json.ObjectMap = .empty;
    try text_item.put(a, "type", .{ .string = "input_text" });
    try text_item.put(a, "text", .{ .string = "hi" });
    try content.append(.{ .object = text_item });
    var msg: std.json.ObjectMap = .empty;
    try msg.put(a, "type", .{ .string = "message" });
    try msg.put(a, "role", .{ .string = "user" });
    try msg.put(a, "content", .{ .array = content });
    try input.append(.{ .object = msg });

    const tools_registry = @import("../tools/registry.zig");
    const body = try buildBody(a, &.{ .{ .key = "model", .value = "deepseek-v4-flash" }, .{ .key = "max_tokens", .value = "512" } }, .{ .array = input }, &.{}, &.{}, &tools_registry.registry);
    defer a.free(body);

    var scanner = std.json.Scanner.initCompleteInput(a, body);
    const value = std.json.Value.jsonParse(a, &scanner, .{ .allocate = .alloc_always, .max_value_len = body.len }) catch return error.TestUnexpectedResult;
    const obj = switch (value) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("deepseek-v4-flash", obj.get("model").?.string);
    try testing.expectEqual(@as(i64, 512), obj.get("max_tokens").?.integer);
    try testing.expectEqual(true, obj.get("stream").?.bool);
    const messages = obj.get("messages").?.array;
    try testing.expectEqual(@as(usize, 1), messages.items.len);
    try testing.expectEqualStrings("user", messages.items[0].object.get("role").?.string);
    const tools_arr = obj.get("tools").?.array;
    try testing.expect(tools_arr.items.len >= 2);
    try testing.expectEqualStrings("get_current_time", tools_arr.items[0].object.get("name").?.string);
    try testing.expect(tools_arr.items[0].object.get("input_schema") != null);
}

test "buildBody: tool_results become a tool_result user message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try buildBody(a, &.{}, .{ .array = std.json.Array.init(a) }, &.{}, &.{
        .{ .call_id = "call_1", .output = "the result" },
    }, &.{});
    defer a.free(body);

    var scanner = std.json.Scanner.initCompleteInput(a, body);
    const value = std.json.Value.jsonParse(a, &scanner, .{ .allocate = .alloc_always, .max_value_len = body.len }) catch return error.TestUnexpectedResult;
    const messages = switch (value) {
        .object => |o| o.get("messages").?.array,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 1), messages.items.len);
    const user = messages.items[0].object;
    try testing.expectEqualStrings("user", user.get("role").?.string);
    const block = user.get("content").?.array.items[0].object;
    try testing.expectEqualStrings("tool_result", block.get("type").?.string);
    try testing.expectEqualStrings("call_1", block.get("tool_use_id").?.string);
    try testing.expectEqualStrings("the result", block.get("content").?.string);
}

test "parseStream: text deltas emit, tool_use collected, stop reasons" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stream =
        \\data: {"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":0}}}
        \\data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}
        \\data: {"type":"content_block_stop","index":0}
        \\data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}
        \\data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hel"}}
        \\data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"lo"}}
        \\data: {"type":"content_block_stop","index":1}
        \\data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"get_current_time","input":{}}}
        \\data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{x:"}}
        \\data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"1}"}}
        \\data: {"type":"content_block_stop","index":2}
        \\data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":22}}
        \\data: {"type":"message_stop"}
        \\
    ;
    var fixed = std.Io.Reader.fixed(stream);

    var chunks: std.ArrayList([]const u8) = .empty;
    const result = try parseStream(a, &fixed, .{
        .base_url = "http://x",
        .api_key = "k",
        .config = &.{},
        .http = undefined,
        .tools = &.{},
        .emit = struct {
            fn e(chunk: []const u8, ud: ?*anyopaque) anyerror!void {
                const list: *std.ArrayList([]const u8) = @ptrCast(@alignCast(ud.?));
                try list.append(std.heap.page_allocator, chunk);
            }
        }.e,
        .is_cancelled = struct {
            fn c(_: ?*anyopaque) bool {
                return false;
            }
        }.c,
        .userdata = @ptrCast(&chunks),
    });

    try testing.expectEqual(@as(usize, 2), chunks.items.len);
    try testing.expectEqualStrings("Hel", chunks.items[0]);
    try testing.expectEqualStrings("lo", chunks.items[1]);
    try testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try testing.expectEqualStrings("toolu_1", result.tool_calls[0].id);
    try testing.expectEqualStrings("get_current_time", result.tool_calls[0].name);
    try testing.expectEqualStrings("{x:1}", result.tool_calls[0].arguments);
    try testing.expectEqualStrings("end_turn", result.stop_reason);
    try testing.expectEqual(@as(u64, 10), result.usage.?.prompt_tokens);
    try testing.expectEqual(@as(u64, 32), result.usage.?.total_tokens);
    // output_items echo the completed content blocks (thinking, text, tool_use)
    try testing.expectEqual(@as(usize, 3), result.output_items.len);
    const first_block = result.output_items[0].object;
    try testing.expectEqualStrings("thinking", first_block.get("type").?.string);
    const tool_block = result.output_items[2].object;
    try testing.expectEqualStrings("tool_use", tool_block.get("type").?.string);
}

test "generate: full round-trip against a mock /v1/messages endpoint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var http: std.http.Client = .{ .allocator = a, .io = io };
    defer http.deinit();

    const sse =
        \\data: {"type":"message_start","message":{"usage":{"input_tokens":7,"output_tokens":0}}}
        \\data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}
        \\data: {"type":"content_block_stop","index":0}
        \\data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}
        \\data: {"type":"message_stop"}
        \\
    ;
    var mock = try @import("../util/mock_http.zig").Mock.start(io, a, "HTTP/1.1 200 OK", sse);
    defer mock.deinit();

    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{mock.port()});
    defer a.free(base);

    const chunks = try a.create(std.ArrayList([]const u8));
    chunks.* = .empty;

    const result = try generate(a, .{ .array = std.json.Array.init(a) }, &.{}, &.{}, .{
        .base_url = base,
        .api_key = "sk-ant",
        .config = &.{.{ .key = "model", .value = "deepseek-v4-flash" }},
        .http = &http,
        .tools = &.{},
        .emit = struct {
            fn e(chunk: []const u8, ud: ?*anyopaque) anyerror!void {
                const list: *std.ArrayList([]const u8) = @ptrCast(@alignCast(ud.?));
                try list.append(std.heap.page_allocator, chunk);
            }
        }.e,
        .is_cancelled = struct {
            fn c(_: ?*anyopaque) bool {
                return false;
            }
        }.c,
        .userdata = @ptrCast(chunks),
    });

    try testing.expectEqualStrings("end_turn", result.stop_reason);
    try testing.expectEqual(@as(usize, 1), chunks.items.len);
    try testing.expectEqualStrings("hello", chunks.items[0]);
    try testing.expectEqual(@as(u64, 7), result.usage.?.prompt_tokens);
    try testing.expectEqual(@as(u64, 10), result.usage.?.total_tokens);
    // the request hit /v1/messages with the anthropic auth header
    try testing.expect(std.mem.indexOf(u8, mock.request.items, "POST /v1/messages") != null);
    try testing.expect(std.mem.indexOf(u8, mock.request.items, "x-api-key: sk-ant") != null);
    try testing.expect(std.mem.indexOf(u8, mock.request.items, "anthropic-version: 2023-06-01") != null);
}
