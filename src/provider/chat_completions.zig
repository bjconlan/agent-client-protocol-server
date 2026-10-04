//! OpenAI Chat Completions API provider adapter.
//!
//! Target: `POST {base}/chat/completions` with `stream: true` (SSE). Bearer
//! auth (the `http_util` default). Works with OpenAI-compatible providers
//! that predate the Responses API and expose the classic Chat Completions
//! surface (OpenAI, DeepSeek, many self-hosted gateways).
//!
//! Mapping vs the shared adapter surface:
//! - The worker's Responses-style input items (`{type:"message", role,
//!   content:[{type:"input_text"|"output_text", text}]}`) are flattened to
//!   Chat messages (`{role, content: "…"}`).
//! - Prior output items are Chat-shaped assistant messages (with
//!   `tool_calls`) produced by `parseStream`; tool results become
//!   `{role:"tool", tool_call_id, content}`.
//! - Streamed `choices[0].delta.content` → `emit`; `delta.tool_calls`
//!   fragments accumulate into `Result.tool_calls`.

const std = @import("std");
const Io = std.Io;

const http_util = @import("../util/http.zig");
const adapter = @import("adapter.zig");
const tools = @import("../tools/registry.zig");

const Options = adapter.Options;
const Result = adapter.Result;

pub const GenerateError = adapter.GenerateError;

/// Run one generation: POST /chat/completions, stream SSE, emit text chunks
/// via `options.emit`. Checks `options.is_cancelled` between SSE events.
pub fn generate(
    allocator: std.mem.Allocator,
    input: std.json.Value,
    prior_outputs: []const std.json.Value,
    tool_results: []const adapter.ToolResult,
    options: Options,
) GenerateError!Result {
    const body = try buildBody(allocator, options.config, input, prior_outputs, tool_results, options.tools);
    defer allocator.free(body);

    const url = try http_util.url(allocator, options.base_url, "/chat/completions");
    defer allocator.free(url);

    var response = try http_util.request(options.http, allocator, url, options.api_key, .{ .body = body });
    defer response.deinit();

    return parseStream(allocator, response.reader, options);
}

/// Build the /chat/completions request body from the session config KVs +
/// input. `model` is required; `temperature`, `top_p`, `max_tokens` /
/// `max_output_tokens`, and `system` / `instructions` are applied.
fn buildBody(
    allocator: std.mem.Allocator,
    config: []const adapter.ConfigKV,
    input_value: std.json.Value,
    prior_outputs: []const std.json.Value,
    tool_results: []const adapter.ToolResult,
    tools_defs: []const tools.Tool,
) ![]u8 {
    // Config first: `system` may need to be prepended to the message list.
    var model: ?[]const u8 = null;
    var system: ?[]const u8 = null;
    var temperature: ?f64 = null;
    var max_tokens: ?i64 = null;
    var top_p: ?f64 = null;
    for (config) |kv| {
        if (std.mem.eql(u8, kv.key, "model")) {
            model = kv.value;
        } else if (std.mem.eql(u8, kv.key, "temperature")) {
            temperature = std.fmt.parseFloat(f64, kv.value) catch continue;
        } else if (std.mem.eql(u8, kv.key, "max_output_tokens") or std.mem.eql(u8, kv.key, "max_tokens")) {
            max_tokens = std.fmt.parseInt(i64, kv.value, 10) catch continue;
        } else if (std.mem.eql(u8, kv.key, "top_p")) {
            top_p = std.fmt.parseFloat(f64, kv.value) catch continue;
        } else if (std.mem.eql(u8, kv.key, "system") or std.mem.eql(u8, kv.key, "instructions")) {
            system = kv.value;
        } else {
            std.log.warn("chat_completions: unknown session config '{s}' — skipped", .{kv.key});
        }
    }
    if (model == null) return error.MissingApiKey;

    var messages: std.json.Array = std.json.Array.init(allocator);
    defer messages.deinit();

    if (system) |s| {
        var sys: std.json.ObjectMap = .empty;
        try sys.put(allocator, "role", .{ .string = "system" });
        try sys.put(allocator, "content", .{ .string = s });
        try messages.append(.{ .object = sys });
    }

    // Translate the worker's Responses-style input items → chat messages.
    if (input_value == .array) {
        for (input_value.array.items) |item| {
            if (item != .object) continue;
            const role = item.object.get("role") orelse continue;
            if (role != .string) continue;
            var text: ?[]const u8 = null;
            if (item.object.get("content")) |content| {
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
            }
            if (text) |t| try appendChatMessage(allocator, &messages, role.string, t);
        }
    }

    // Prior output items are already Chat-shaped assistant messages.
    for (prior_outputs) |o| try messages.append(o);

    // Tool results → role:"tool" messages.
    for (tool_results) |tr| {
        var m: std.json.ObjectMap = .empty;
        try m.put(allocator, "role", .{ .string = "tool" });
        try m.put(allocator, "tool_call_id", .{ .string = tr.call_id });
        try m.put(allocator, "content", .{ .string = tr.output });
        try messages.append(.{ .object = m });
    }

    var root: std.json.ObjectMap = .empty;
    errdefer root.deinit(allocator);
    try root.put(allocator, "model", .{ .string = model.? });
    try root.put(allocator, "messages", .{ .array = messages });
    try root.put(allocator, "stream", .{ .bool = true });

    var stream_options: std.json.ObjectMap = .empty;
    try stream_options.put(allocator, "include_usage", .{ .bool = true });
    try root.put(allocator, "stream_options", .{ .object = stream_options });

    if (temperature) |t| try root.put(allocator, "temperature", .{ .float = t });
    if (top_p) |t| try root.put(allocator, "top_p", .{ .float = t });
    if (max_tokens) |t| try root.put(allocator, "max_tokens", .{ .integer = t });

    // tools: standard nested `function` shape. Omitted entirely when empty.
    // Declared at function scope so its deinit runs after stringify (a defer
    // inside the `if` would free the backing before the body is serialized).
    var tools_arr: std.json.Array = std.json.Array.init(allocator);
    defer tools_arr.deinit();
    if (tools_defs.len > 0) {
        for (tools_defs) |tool| {
            var scanner = std.json.Scanner.initCompleteInput(allocator, tool.parameters);
            const params = std.json.Value.jsonParse(allocator, &scanner, .{
                .allocate = .alloc_always,
                .max_value_len = tool.parameters.len,
            }) catch continue;
            var fn_obj: std.json.ObjectMap = .empty;
            try fn_obj.put(allocator, "name", .{ .string = tool.name });
            try fn_obj.put(allocator, "description", .{ .string = tool.description });
            try fn_obj.put(allocator, "parameters", params);
            var tool_obj: std.json.ObjectMap = .empty;
            try tool_obj.put(allocator, "type", .{ .string = "function" });
            try tool_obj.put(allocator, "function", .{ .object = fn_obj });
            try tools_arr.append(.{ .object = tool_obj });
        }
        try root.put(allocator, "tools", .{ .array = tools_arr });
        try root.put(allocator, "tool_choice", .{ .string = "auto" });
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(std.json.Value{ .object = root }, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn appendChatMessage(
    allocator: std.mem.Allocator,
    messages: *std.json.Array,
    role: []const u8,
    text: []const u8,
) !void {
    var m: std.json.ObjectMap = .empty;
    try m.put(allocator, "role", .{ .string = role });
    try m.put(allocator, "content", .{ .string = text });
    try messages.append(.{ .object = m });
}

/// Accumulator for one streamed tool call (fragments arrive keyed by index).
const ToolAcc = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    args: std.ArrayList(u8) = .empty,
};

/// Parse the SSE stream from `reader`, emitting text chunks.
fn parseStream(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    options: Options,
) GenerateError!Result {
    var usage: ?adapter.Usage = null;
    var text: std.ArrayList(u8) = .empty;
    var accs: std.ArrayList(ToolAcc) = .empty;
    var finish_reason: []const u8 = "";

    while (true) {
        if (options.is_cancelled(options.userdata)) {
            return .{ .stop_reason = "cancelled", .usage = usage, .tool_calls = &.{}, .output_items = &.{} };
        }

        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.GenerateFailed,
            error.ReadFailed => return error.Network,
        } orelse break; // EOF

        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == ':') continue; // SSE comment/keepalive

        const payload = std.mem.trimStart(u8, trimmed, " ");
        std.log.scoped(.provider).debug("sse: {s}", .{trimmed});
        const data = if (std.mem.startsWith(u8, payload, "data:"))
            std.mem.trimStart(u8, payload["data:".len..], " ")
        else
            continue;
        if (data.len == 0) continue;
        if (std.mem.eql(u8, data, "[DONE]")) break;

        var scanner = std.json.Scanner.initCompleteInput(allocator, data);
        const event = std.json.Value.jsonParse(allocator, &scanner, .{
            .allocate = .alloc_always,
            .max_value_len = data.len,
        }) catch continue;

        const obj = switch (event) {
            .object => |o| o,
            else => continue,
        };

        if (obj.get("usage")) |u| {
            if (u == .object) usage = extractUsage(u);
        }

        const choices = switch (obj.get("choices") orelse continue) {
            .array => |a| a,
            else => continue,
        };
        if (choices.items.len == 0) continue;
        const choice = switch (choices.items[0]) {
            .object => |o| o,
            else => continue,
        };

        if (choice.get("delta")) |d| {
            if (d == .object) {
                const delta = d.object;
                if (delta.get("content")) |c| {
                    if (c == .string) {
                        try text.appendSlice(allocator, c.string);
                        options.emit(c.string, options.userdata) catch return error.GenerateFailed;
                    }
                }
                if (delta.get("tool_calls")) |tcs| {
                    if (tcs == .array) {
                        for (tcs.array.items) |entry| {
                            if (entry != .object) continue;
                            const idx = switch (entry.object.get("index") orelse std.json.Value{ .integer = 0 }) {
                                .integer => |i| @as(usize, @intCast(@max(i, 0))),
                                else => 0,
                            };
                            if (idx > 64) continue; // sanity cap
                            while (accs.items.len <= idx) try accs.append(allocator, .{});
                            const acc = &accs.items[idx];
                            if (entry.object.get("id")) |idv| {
                                if (idv == .string) try acc.id.appendSlice(allocator, idv.string);
                            }
                            if (entry.object.get("function")) |fv| {
                                if (fv == .object) {
                                    if (fv.object.get("name")) |nv| {
                                        if (nv == .string) try acc.name.appendSlice(allocator, nv.string);
                                    }
                                    if (fv.object.get("arguments")) |av| {
                                        if (av == .string) try acc.args.appendSlice(allocator, av.string);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if (choice.get("finish_reason")) |fr| {
            if (fr == .string) finish_reason = fr.string;
        }
    }

    // Materialize tool calls (skip empty accumulators).
    var tool_calls: std.ArrayList(adapter.ToolCall) = .empty;
    for (accs.items) |acc| {
        if (acc.name.items.len == 0) continue;
        try tool_calls.append(allocator, .{
            .id = try allocator.dupe(u8, acc.id.items),
            .name = try allocator.dupe(u8, acc.name.items),
            .arguments = try allocator.dupe(u8, acc.args.items),
        });
    }

    // Echo an assistant message (with tool_calls) so the worker can continue
    // the tool flow on the next call.
    var output_items: std.ArrayList(std.json.Value) = .empty;
    if (tool_calls.items.len > 0) {
        var msg: std.json.ObjectMap = .empty;
        try msg.put(allocator, "role", .{ .string = "assistant" });
        if (text.items.len > 0) {
            try msg.put(allocator, "content", .{ .string = text.items });
        } else {
            try msg.put(allocator, "content", std.json.Value{ .null = {} });
        }
        var tcs: std.json.Array = std.json.Array.init(allocator);
        for (tool_calls.items) |tc| {
            var fn_obj: std.json.ObjectMap = .empty;
            try fn_obj.put(allocator, "name", .{ .string = tc.name });
            try fn_obj.put(allocator, "arguments", .{ .string = tc.arguments });
            var tc_obj: std.json.ObjectMap = .empty;
            try tc_obj.put(allocator, "id", .{ .string = tc.id });
            try tc_obj.put(allocator, "type", .{ .string = "function" });
            try tc_obj.put(allocator, "function", .{ .object = fn_obj });
            try tcs.append(.{ .object = tc_obj });
        }
        try msg.put(allocator, "tool_calls", .{ .array = tcs });
        try output_items.append(allocator, .{ .object = msg });
    }

    const stop_reason: []const u8 = if (tool_calls.items.len > 0)
        "end_turn"
    else if (std.mem.eql(u8, finish_reason, "length"))
        "max_tokens"
    else
        "end_turn";

    return .{
        .stop_reason = stop_reason,
        .usage = usage,
        .tool_calls = tool_calls.items,
        .output_items = output_items.items,
    };
}

/// Extract usage from a chunk's `usage` object.
fn extractUsage(u: std.json.Value) ?adapter.Usage {
    const obj = switch (u) {
        .object => |o| o,
        else => return null,
    };
    const prompt = switch (obj.get("prompt_tokens") orelse return null) {
        .integer => |i| @as(u64, @intCast(i)),
        else => return null,
    };
    const total = switch (obj.get("total_tokens") orelse return null) {
        .integer => |i| @as(u64, @intCast(i)),
        else => return null,
    };
    return .{ .prompt_tokens = prompt, .total_tokens = total };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const emit_collect = struct {
    fn collect(chunk: []const u8, userdata: ?*anyopaque) anyerror!void {
        const list: *std.ArrayList([]const u8) = @ptrCast(@alignCast(userdata.?));
        try list.append(std.heap.page_allocator, chunk);
    }
};

fn neverCancelled(_: ?*anyopaque) bool {
    return false;
}

fn noopExecute(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: []const u8) anyerror![]const u8 {
    return "";
}

test "parseStream: content deltas emit chunks, usage extracted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stream =
        \\data: {"choices":[{"delta":{"content":"Hi "},"finish_reason":null}]}
        \\data: {"choices":[{"delta":{"content":"there"},"finish_reason":null}]}
        \\data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}
        \\data: [DONE]
        \\
    ;
    var fixed = std.Io.Reader.fixed(stream);
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var http: std.http.Client = .{ .allocator = a, .io = threaded.io() };

    const chunks = try a.create(std.ArrayList([]const u8));
    chunks.* = .empty;

    const result = try parseStream(a, &fixed, .{
        .base_url = "http://x",
        .http = &http,
        .tools = &.{},
        .api_key = "k",
        .config = &.{},
        .emit = emit_collect.collect,
        .is_cancelled = neverCancelled,
        .userdata = @ptrCast(chunks),
    });
    try testing.expectEqualStrings("end_turn", result.stop_reason);
    try testing.expectEqual(@as(usize, 2), chunks.items.len);
    try testing.expectEqualStrings("Hi ", chunks.items[0]);
    try testing.expectEqualStrings("there", chunks.items[1]);
    try testing.expectEqual(@as(u64, 5), result.usage.?.prompt_tokens);
    try testing.expectEqual(@as(u64, 7), result.usage.?.total_tokens);
    try testing.expectEqual(@as(usize, 0), result.tool_calls.len);
}

test "parseStream: streamed tool_call fragments accumulate by index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stream =
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_9","type":"function","function":{"name":"echo","arguments":"{\"x\":"}}]},"finish_reason":null}]}
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"1}"}}]},"finish_reason":null}]}
        \\data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}
        \\data: [DONE]
        \\
    ;
    var fixed = std.Io.Reader.fixed(stream);
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var http: std.http.Client = .{ .allocator = a, .io = threaded.io() };

    const result = try parseStream(a, &fixed, .{
        .base_url = "http://x",
        .http = &http,
        .tools = &.{},
        .api_key = "k",
        .config = &.{},
        .emit = emit_collect.collect,
        .is_cancelled = neverCancelled,
        .userdata = null,
    });
    try testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try testing.expectEqualStrings("call_9", result.tool_calls[0].id);
    try testing.expectEqualStrings("echo", result.tool_calls[0].name);
    try testing.expectEqualStrings("{\"x\":1}", result.tool_calls[0].arguments);
    // the assistant message is echoed for tool-result continuation
    try testing.expectEqual(@as(usize, 1), result.output_items.len);
    try testing.expectEqualStrings("assistant", result.output_items[0].object.get("role").?.string);
}

test "buildBody: model, messages, tools, stream flags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

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

    const tool_defs = [_]tools.Tool{.{
        .name = "get_current_time",
        .description = "Return the current time",
        .kind = "execute",
        .parameters = "{\"type\":\"object\",\"properties\":{}}",
        .execute = noopExecute,
    }};

    const body = try buildBody(a, &.{
        .{ .key = "model", .value = "gpt-4o" },
        .{ .key = "system", .value = "be nice" },
        .{ .key = "temperature", .value = "0.5" },
    }, .{ .array = input }, &.{}, &.{}, &tool_defs);
    defer a.free(body);

    var scanner = std.json.Scanner.initCompleteInput(a, body);
    const value = std.json.Value.jsonParse(a, &scanner, .{
        .allocate = .alloc_always,
        .max_value_len = body.len,
    }) catch return error.TestUnexpectedResult;
    const obj = switch (value) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("gpt-4o", obj.get("model").?.string);
    try testing.expectEqual(true, obj.get("stream").?.bool);
    try testing.expectEqual(true, obj.get("stream_options").?.object.get("include_usage").?.bool);
    try testing.expectEqualStrings("auto", obj.get("tool_choice").?.string);
    const messages = obj.get("messages").?.array;
    try testing.expectEqual(@as(usize, 2), messages.items.len);
    try testing.expectEqualStrings("system", messages.items[0].object.get("role").?.string);
    try testing.expectEqualStrings("be nice", messages.items[0].object.get("content").?.string);
    try testing.expectEqualStrings("user", messages.items[1].object.get("role").?.string);
    try testing.expectEqualStrings("hi", messages.items[1].object.get("content").?.string);
    const t = obj.get("tools").?.array.items[0].object;
    try testing.expectEqualStrings("get_current_time", t.get("function").?.object.get("name").?.string);
}

test "generate: full round-trip against a mock /chat/completions endpoint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var http: std.http.Client = .{ .allocator = a, .io = io };
    defer http.deinit();

    const sse =
        \\data: {"choices":[{"delta":{"content":"Hi "},"finish_reason":null}]}
        \\data: {"choices":[{"delta":{"content":"there"},"finish_reason":null}]}
        \\data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}
        \\data: [DONE]
        \\
    ;
    var mock = try @import("../util/mock_http.zig").Mock.start(io, a, "HTTP/1.1 200 OK", sse);
    defer mock.deinit();

    const base = try a.print("http://127.0.0.1:{d}", .{mock.port()});
    defer a.free(base);

    const chunks = try a.create(std.ArrayList([]const u8));
    chunks.* = .empty;

    const result = try generate(a, .{ .array = std.json.Array.init(a) }, &.{}, &.{}, .{
        .base_url = base,
        .api_key = "sk-test",
        .config = &.{.{ .key = "model", .value = "gpt-4o" }},
        .http = &http,
        .tools = &.{},
        .emit = emit_collect.collect,
        .is_cancelled = neverCancelled,
        .userdata = @ptrCast(chunks),
    });

    try testing.expectEqualStrings("end_turn", result.stop_reason);
    try testing.expectEqual(@as(usize, 2), chunks.items.len);
    try testing.expectEqualStrings("Hi ", chunks.items[0]);
    try testing.expectEqualStrings("there", chunks.items[1]);
    try testing.expectEqual(@as(u64, 5), result.usage.?.prompt_tokens);
    try testing.expectEqual(@as(u64, 7), result.usage.?.total_tokens);
    try testing.expect(std.mem.startsWith(u8, mock.request.items, "POST /chat/completions"));
}
