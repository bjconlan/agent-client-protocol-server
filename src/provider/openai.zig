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

const Options = adapter.Options;
const Result = adapter.Result;

pub const GenerateError = adapter.GenerateError;

/// Run one generation: POST /responses, stream SSE, emit text chunks via
/// `options.emit`. Checks `options.is_cancelled` between SSE events.
pub fn generate(
    allocator: std.mem.Allocator,
    text_blocks: []const []const u8,
    options: Options,
) GenerateError!Result {
    const body = try buildBody(allocator, options.config, text_blocks);
    defer allocator.free(body);

    const url = try http_util.url(allocator, options.config.base_url, "/responses");
    defer allocator.free(url);

    var response = try http_util.request(options.http, allocator, url, options.api_key, body);
    defer response.deinit();

    return parseStream(allocator, response.reader, options);
}

/// Build the /responses request body.
fn buildBody(
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    text_blocks: []const []const u8,
) ![]u8 {
    var input: std.json.Array = std.json.Array.init(allocator);
    defer input.deinit();

    var content: std.json.Array = std.json.Array.init(allocator);
    defer content.deinit();
    for (text_blocks) |text| {
        var item: std.json.ObjectMap = .empty;
        try item.put(allocator, "type", .{ .string = "input_text" });
        try item.put(allocator, "text", .{ .string = text });
        try content.append(.{ .object = item });
    }

    var message: std.json.ObjectMap = .empty;
    try message.put(allocator, "type", .{ .string = "message" });
    try message.put(allocator, "role", .{ .string = "user" });
    try message.put(allocator, "content", .{ .array = content });
    try input.append(.{ .object = message });

    var reasoning: std.json.ObjectMap = .empty;
    try reasoning.put(allocator, "effort", .{ .string = config.effort });

    var stream_options: std.json.ObjectMap = .empty;
    try stream_options.put(allocator, "include_usage", .{ .bool = true });

    var root: std.json.ObjectMap = .empty;
    errdefer root.deinit(allocator);
    try root.put(allocator, "model", .{ .string = config.model });
    try root.put(allocator, "input", .{ .array = input });
    try root.put(allocator, "reasoning", .{ .object = reasoning });
    try root.put(allocator, "stream", .{ .bool = true });
    try root.put(allocator, "stream_options", .{ .object = stream_options });

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

    while (true) {
        if (options.is_cancelled(options.userdata)) return .{ .stop_reason = "cancelled", .usage = usage };

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
        } else if (std.mem.eql(u8, event_type, "response.completed")) {
            if (obj.get("response")) |resp| {
                usage = extractUsage(resp);
            }
            return .{ .stop_reason = if (saw_text) "end_turn" else "end_turn", .usage = usage };
        } else if (std.mem.eql(u8, event_type, "response.incomplete")) {
            return .{ .stop_reason = "max_tokens", .usage = usage };
        } else if (std.mem.eql(u8, event_type, "response.failed")) {
            return error.GenerateFailed;
        }
        // other events (created, in_progress, output_item.*, ...) ignored
    }

    return .{ .stop_reason = "end_turn", .usage = usage };
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
    var cfg = config_mod.Config{ .api_key = null, .base_url = "http://x", .model = "m", .effort = "high" };
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var http: std.http.Client = .{ .allocator = a, .io = threaded.io() };

    const result = try parseStream(a, &fixed, .{
        .config = &cfg,
        .http = &http,
        .api_key = "k",
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

    const cfg = config_mod.Config{ .api_key = null, .base_url = "http://x", .model = "m", .effort = "high" };
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var http: std.http.Client = .{ .allocator = a, .io = threaded.io() };
    var cancel = true;

    const result = try parseStream(a, &fixed, .{
        .config = &cfg,
        .http = &http,
        .api_key = "k",
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
    var cfg = config_mod.Config{ .api_key = null, .base_url = "http://x", .model = "m", .effort = "high" };
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var http: std.http.Client = .{ .allocator = a, .io = threaded.io() };
    const result = try parseStream(a, &fixed1, .{
        .config = &cfg,
        .http = &http,
        .api_key = "k",
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
        .config = &cfg,
        .http = &http,
        .api_key = "k",
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

    var cfg = config_mod.Config{ .api_key = null, .base_url = "http://x", .model = "deepseek-v4-flash", .effort = "high" };
    const body = try buildBody(a, &cfg, &.{"hi"});
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
    const input = obj.get("input").?.array;
    try testing.expectEqual(@as(usize, 1), input.items.len);
    const content = input.items[0].object.get("content").?.array;
    try testing.expectEqualStrings("hi", content.items[0].object.get("text").?.string);
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

    var cfg = config_mod.Config{ .api_key = "sk-test", .base_url = base, .model = "deepseek-v4-flash", .effort = "high" };

    const chunks = try a.create(std.ArrayList([]const u8));
    chunks.* = .empty;

    const result = try generate(a, &.{"hello"}, .{
        .config = &cfg,
        .api_key = "sk-test",
        .http = &http,
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
