//! OpenAI Responses API provider implementation.
//!
//! Target: `POST {base}/responses` with `stream: true` (SSE). Maps OpenAI
//! streamed output to text chunks and a stop reason; usage is extracted from
//! the final event. OpenAI-compatible endpoints (e.g. DeepSeek at
//! `https://api.deepseek.com/v1`) work via `OPENAI_URL`.
//!
//! Cancellation is cooperative: `is_cancelled` is polled between SSE events;
//! when it fires, generation stops and reports `cancelled`.

const std = @import("std");
const Io = std.Io;

const http_util = @import("../util/http.zig");
const config_mod = @import("../config.zig");
const adapter = @import("adapter.zig");
const tools = @import("../tools/registry.zig");

const Options = adapter.Options;
const Result = adapter.Result;

pub const GenerateError = adapter.GenerateError;

/// Run one generation: POST /responses, stream SSE, emit text chunks via
/// `options.emit`. Checks `options.is_cancelled` between SSE events and
/// collects `function_call` tool calls from the stream.
pub fn generate(
    allocator: std.mem.Allocator,
    input: std.json.Value,
    prior_outputs: []const std.json.Value,
    tool_results: []const adapter.ToolResult,
    options: Options,
) GenerateError!Result {
    const flat_tools = std.mem.indexOf(u8, options.base_url, "deepseek.com") != null;
    const body = try buildBody(allocator, options.config, flat_tools, input, prior_outputs, tool_results, options.tools);
    defer allocator.free(body);

    const url = try http_util.url(allocator, options.base_url, "/responses");
    defer allocator.free(url);

    var response = try http_util.request(options.http, allocator, url, options.api_key, .{ .body = body });
    defer response.deinit();

    return parseStream(allocator, response.reader, options);
}

/// Build the /responses request body from the session config KVs.
fn buildBody(
    allocator: std.mem.Allocator,
    config: []const adapter.ConfigKV,
    flat_tools: bool,
    input_value: std.json.Value,
    prior_outputs: []const std.json.Value,
    tool_results: []const adapter.ToolResult,
    tools_defs: []const tools.Tool,
) ![]u8 {
    // input = passed items (history + current prompt) + previous output
    // items (reasoning/function_call echo) + function_call_output items.
    var input = switch (input_value) {
        .array => |arr| arr,
        else => std.json.Array.init(allocator),
    };
    defer input.deinit();
    for (prior_outputs) |item| try input.append(item);
    for (tool_results) |tr| {
        var item: std.json.ObjectMap = .empty;
        try item.put(allocator, "type", .{ .string = "function_call_output" });
        try item.put(allocator, "call_id", .{ .string = tr.call_id });
        try item.put(allocator, "output", .{ .string = tr.output });
        try input.append(.{ .object = item });
    }

    // tools param from the registry definitions. OpenAI nests the function
    // under a `function` object; DeepSeek's Responses API uses the flat
    // shape (name at the top level).
    var tools_arr: std.json.Array = std.json.Array.init(allocator);
    defer tools_arr.deinit();
    for (tools_defs) |tool| {
        var scanner = std.json.Scanner.initCompleteInput(allocator, tool.parameters);
        const params = std.json.Value.jsonParse(allocator, &scanner, .{
            .allocate = .alloc_always,
            .max_value_len = tool.parameters.len,
        }) catch continue;
        var tool_obj: std.json.ObjectMap = .empty;
        try tool_obj.put(allocator, "type", .{ .string = "function" });
        if (flat_tools) {
            try tool_obj.put(allocator, "name", .{ .string = tool.name });
            try tool_obj.put(allocator, "description", .{ .string = tool.description });
            try tool_obj.put(allocator, "parameters", params);
        } else {
            var fn_obj: std.json.ObjectMap = .empty;
            try fn_obj.put(allocator, "name", .{ .string = tool.name });
            try fn_obj.put(allocator, "description", .{ .string = tool.description });
            try fn_obj.put(allocator, "parameters", params);
            try tool_obj.put(allocator, "function", .{ .object = fn_obj });
        }
        try tools_arr.append(.{ .object = tool_obj });
    }

    var stream_options: std.json.ObjectMap = .empty;
    try stream_options.put(allocator, "include_usage", .{ .bool = true });

    var root: std.json.ObjectMap = .empty;
    errdefer root.deinit(allocator);
    try root.put(allocator, "input", .{ .array = input });
    try root.put(allocator, "tools", .{ .array = tools_arr });
    try root.put(allocator, "stream", .{ .bool = true });
    try root.put(allocator, "stream_options", .{ .object = stream_options });

    // Session config KVs → request fields. `model` is required; known knobs
    // (reasoning.effort, temperature, max_output_tokens, top_p, instructions)
    // are applied; unknown keys are logged and skipped.
    var saw_model = false;
    for (config) |kv| {
        if (std.mem.eql(u8, kv.key, "model")) {
            try root.put(allocator, "model", .{ .string = kv.value });
            saw_model = true;
        } else if (std.mem.eql(u8, kv.key, "reasoning.effort")) {
            var reasoning: std.json.ObjectMap = .empty;
            try reasoning.put(allocator, "effort", .{ .string = kv.value });
            try root.put(allocator, "reasoning", .{ .object = reasoning });
        } else if (std.mem.eql(u8, kv.key, "temperature")) {
            root.put(allocator, "temperature", .{ .float = std.fmt.parseFloat(f64, kv.value) catch continue }) catch {};
        } else if (std.mem.eql(u8, kv.key, "max_output_tokens")) {
            root.put(allocator, "max_output_tokens", .{ .integer = std.fmt.parseInt(i64, kv.value, 10) catch continue }) catch {};
        } else if (std.mem.eql(u8, kv.key, "top_p")) {
            root.put(allocator, "top_p", .{ .float = std.fmt.parseFloat(f64, kv.value) catch continue }) catch {};
        } else if (std.mem.eql(u8, kv.key, "instructions")) {
            try root.put(allocator, "instructions", .{ .string = kv.value });
        } else {
            std.log.warn("openai: unknown session config '{s}' — skipped", .{kv.key});
        }
    }
    if (!saw_model) return error.MissingApiKey;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(std.json.Value{ .object = root }, .{}, &out.writer);
    return out.toOwnedSlice();
}

/// Parse the SSE stream from `reader`, emitting text chunks.
fn parseStream(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    options: Options,
) GenerateError!Result {
    var usage: ?adapter.Usage = null;
    var saw_text: bool = false;
    var tool_calls: std.ArrayList(adapter.ToolCall) = .empty;
    var output_items: std.ArrayList(std.json.Value) = .empty;
    var current_args: std.ArrayList(u8) = .empty;
    var in_tool_call = false;

    while (true) {
        if (options.is_cancelled(options.userdata)) return .{ .stop_reason = "cancelled", .usage = usage, .tool_calls = tool_calls.items, .output_items = output_items.items };

        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.GenerateFailed,
            error.ReadFailed => return error.Network,
        } orelse return error.GenerateFailed; // EOF mid-stream

        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == ':') continue; // SSE comment/keepalive

        const payload = std.mem.trimStart(u8, trimmed, " ");
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
        const event_type = switch (obj.get("type") orelse continue) {
            .string => |s| s,
            else => continue,
        };

        if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
            if (obj.get("delta")) |d| switch (d) {
                .string => |text| {
                    saw_text = true;
                    options.emit(text, options.userdata) catch return error.GenerateFailed;
                },
                else => {},
            };
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
            if (obj.get("delta")) |d| switch (d) {
                .string => |text| {
                    in_tool_call = true;
                    try current_args.appendSlice(allocator, text);
                },
                else => {},
            };
        } else if (std.mem.eql(u8, event_type, "response.output_item.done")) {
            const item = obj.get("item") orelse continue;
            const io = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const item_type = switch (io.get("type") orelse continue) {
                .string => |str| str,
                else => continue,
            };
            try output_items.append(allocator, item);
            if (!std.mem.eql(u8, item_type, "function_call")) continue;
            const call_id = switch (io.get("call_id") orelse continue) {
                .string => |str| str,
                else => continue,
            };
            const name = switch (io.get("name") orelse continue) {
                .string => |str| str,
                else => continue,
            };
            const arguments = if (in_tool_call)
                try current_args.toOwnedSlice(allocator)
            else switch (io.get("arguments") orelse std.json.Value{ .string = "" }) {
                .string => |str| try allocator.dupe(u8, str),
                else => "",
            };
            in_tool_call = false;
            try tool_calls.append(allocator, .{
                .id = try allocator.dupe(u8, call_id),
                .name = try allocator.dupe(u8, name),
                .arguments = arguments,
            });
        } else if (std.mem.eql(u8, event_type, "response.completed")) {
            if (obj.get("response")) |resp| {
                usage = extractUsage(resp);
            }
            // Drain the remainder of the body so the HTTP connection can be
            // reused cleanly (otherwise the next request on the pooled
            // connection fails).
            while (reader.takeDelimiter('\n') catch null) |_| {}
            return .{ .stop_reason = "end_turn", .usage = usage, .tool_calls = tool_calls.items, .output_items = output_items.items };
        } else if (std.mem.eql(u8, event_type, "response.incomplete")) {
            return .{ .stop_reason = "max_tokens", .usage = usage, .tool_calls = tool_calls.items, .output_items = output_items.items };
        } else if (std.mem.eql(u8, event_type, "response.failed")) {
            return error.GenerateFailed;
        }
        // other events (created, in_progress, output_item.*, ...) ignored
    }

    return .{ .stop_reason = "end_turn", .usage = usage, .tool_calls = tool_calls.items, .output_items = output_items.items };
}

/// Extract usage from the response object (final event with
/// `stream_options.include_usage`).
fn extractUsage(response: std.json.Value) ?adapter.Usage {
    const obj = switch (response) {
        .object => |o| o,
        else => return null,
    };
    const usage = obj.get("usage") orelse return null;
    const u = switch (usage) {
        .object => |o| o,
        else => return null,
    };
    const prompt = if (u.get("prompt_tokens")) |v| switch (v) {
        .integer => |i| @as(u64, @intCast(@max(i, 0))),
        else => 0,
    } else 0;
    const total = if (u.get("total_tokens")) |v| switch (v) {
        .integer => |i| @as(u64, @intCast(@max(i, 0))),
        else => 0,
    } else 0;
    return .{ .prompt_tokens = prompt, .total_tokens = total };
}

// ---------------------------------------------------------------------------
// Tests (SSE parsing against scripted streams)
// ---------------------------------------------------------------------------

const testing = std.testing;

const emit_collect = struct {
    fn collect(chunk: []const u8, userdata: ?*anyopaque) anyerror!void {
        const list: *std.ArrayList([]const u8) = @ptrCast(@alignCast(userdata.?));
        try list.append(std.heap.page_allocator, chunk);
    }
};

test "parseStream: delta events emit chunks, completed returns end_turn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stream =
        \\data: {"type":"response.created","response":{"id":"r1"}}
        \\
        \\data: {"type":"response.output_text.delta","delta":"Hel"}
        \\data: {"type":"response.output_text.delta","delta":"lo"}
        \\data: {"type":"response.completed","response":{"usage":{"prompt_tokens":12,"completion_tokens":3,"total_tokens":15}}}
        \\
    ;
    var fixed = std.Io.Reader.fixed(stream);

    const chunks = try a.create(std.ArrayList([]const u8));
    chunks.* = .empty;
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
        .is_cancelled = struct {
            fn c(_: ?*anyopaque) bool {
                return false;
            }
        }.c,
        .userdata = @ptrCast(chunks),
    });
    try testing.expectEqualStrings("end_turn", result.stop_reason);
    try testing.expectEqual(@as(usize, 2), chunks.items.len);
    try testing.expectEqualStrings("Hel", chunks.items[0]);
    try testing.expectEqualStrings("lo", chunks.items[1]);
    try testing.expectEqual(@as(u64, 12), result.usage.?.prompt_tokens);
    try testing.expectEqual(@as(u64, 15), result.usage.?.total_tokens);
}

test "parseStream: cancelled mid-stream returns cancelled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stream =
        \\data: {"type":"response.output_text.delta","delta":"partial"}
        \\data: {"type":"response.output_text.delta","delta":"more"}
        \\
    ;
    var fixed = std.Io.Reader.fixed(stream);

    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var http: std.http.Client = .{ .allocator = a, .io = threaded.io() };
    var cancel = true;

    const result = try parseStream(a, &fixed, .{
        .base_url = "http://x",
        .http = &http,
        .tools = &.{},
        .api_key = "k",
        .config = &.{},
        .emit = emit_collect.collect,
        .is_cancelled = struct {
            fn c(ud: ?*anyopaque) bool {
                const flag: *bool = @ptrCast(@alignCast(ud.?));
                return flag.*;
            }
        }.c,
        .userdata = @ptrCast(&cancel),
    });
    try testing.expectEqualStrings("cancelled", result.stop_reason);
}

test "parseStream: incomplete returns max_tokens, failed returns error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stream1 = "data: {\"type\":\"response.incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}\n\n";
    var fixed1 = std.Io.Reader.fixed(stream1);
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var http: std.http.Client = .{ .allocator = a, .io = threaded.io() };
    const result = try parseStream(a, &fixed1, .{
        .base_url = "http://x",
        .http = &http,
        .tools = &.{},
        .api_key = "k",
        .config = &.{},
        .emit = emit_collect.collect,
        .is_cancelled = struct {
            fn c(_: ?*anyopaque) bool {
                return false;
            }
        }.c,
        .userdata = null,
    });
    try testing.expectEqualStrings("max_tokens", result.stop_reason);

    const stream2 = "data: {\"type\":\"response.failed\",\"error\":{\"message\":\"boom\"}}\n\n";
    var fixed2 = std.Io.Reader.fixed(stream2);
    try testing.expectError(error.GenerateFailed, parseStream(a, &fixed2, .{
        .base_url = "http://x",
        .http = &http,
        .tools = &.{},
        .api_key = "k",
        .config = &.{},
        .emit = emit_collect.collect,
        .is_cancelled = struct {
            fn c(_: ?*anyopaque) bool {
                return false;
            }
        }.c,
        .userdata = null,
    }));
}

test "buildBody: contains model, reasoning.effort, stream flags" {
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

    const body = try buildBody(a, &.{ .{ .key = "model", .value = "deepseek-v4-flash" }, .{ .key = "reasoning.effort", .value = "high" } }, false, .{ .array = input }, &.{}, &.{}, &.{});
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
    try testing.expectEqualStrings("deepseek-v4-flash", obj.get("model").?.string);
    try testing.expectEqualStrings("high", obj.get("reasoning").?.object.get("effort").?.string);
    try testing.expectEqual(true, obj.get("stream").?.bool);
    try testing.expectEqual(true, obj.get("stream_options").?.object.get("include_usage").?.bool);
    const input_items = obj.get("input").?.array;
    try testing.expectEqual(@as(usize, 1), input_items.items.len);
    const blocks = input_items.items[0].object.get("content").?.array;
    try testing.expectEqualStrings("hi", blocks.items[0].object.get("text").?.string);
}

test "generate: full round-trip against a mock /responses endpoint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var http: std.http.Client = .{ .allocator = a, .io = io };
    defer http.deinit();

    const sse =
        \\data: {"type":"response.output_text.delta","delta":"Hi "}
        \\data: {"type":"response.output_text.delta","delta":"there"}
        \\data: {"type":"response.completed","response":{"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}}
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
        .api_key = "sk-test",
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
    try testing.expectEqual(@as(usize, 2), chunks.items.len);
    try testing.expectEqualStrings("Hi ", chunks.items[0]);
    try testing.expectEqualStrings("there", chunks.items[1]);
    try testing.expectEqual(@as(u64, 5), result.usage.?.prompt_tokens);
    try testing.expectEqual(@as(u64, 7), result.usage.?.total_tokens);
    // the request reached the mock as a POST to /responses
    try testing.expect(std.mem.startsWith(u8, mock.request.items, "POST /responses"));
}

test "parseStream: function_call args deltas collect a ToolCall" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stream =
        \\data: {"type":"response.function_call_arguments.delta","delta":"{\"x\":"}
        \\data: {"type":"response.function_call_arguments.delta","delta":"1}"}
        \\data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_9","name":"echo","arguments":""}}
        \\data: {"type":"response.completed","response":{"id":"r1"}}
        \\
    ;
    var fixed = Io.Reader.fixed(stream);

    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var http: std.http.Client = .{ .allocator = a, .io = threaded.io() };

    const result = try parseStream(a, &fixed, .{
        .base_url = "http://x",
        .http = &http,
        .tools = &.{},
        .api_key = "k",
        .config = &.{},
        .emit = struct {
            fn e(_: []const u8, _: ?*anyopaque) anyerror!void {}
        }.e,
        .is_cancelled = struct {
            fn c(_: ?*anyopaque) bool {
                return false;
            }
        }.c,
        .userdata = null,
    });
    try testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try testing.expectEqualStrings("call_9", result.tool_calls[0].id);
    try testing.expectEqualStrings("echo", result.tool_calls[0].name);
    try testing.expectEqualStrings("{\"x\":1}", result.tool_calls[0].arguments);
}

test "buildBody: tools array includes registry definitions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tools_registry = @import("../tools/registry.zig");

    const body = try buildBody(a, &.{.{ .key = "model", .value = "m" }}, false, .{ .array = std.json.Array.init(a) }, &.{}, &.{}, &tools_registry.registry);
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
    const tools_arr = obj.get("tools").?.array;
    try testing.expect(tools_arr.items.len >= 2);
    const first = tools_arr.items[0].object;
    try testing.expectEqualStrings("function", first.get("type").?.string);
    const fn_obj = first.get("function").?.object;
    try testing.expectEqualStrings("get_current_time", fn_obj.get("name").?.string);
    try testing.expect(fn_obj.get("parameters") != null);
}
