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

const json_rpc = @import("protocol/json_rpc.zig");
const methods_v1 = @import("protocol/v1/methods.zig");
const types_v1 = @import("protocol/v1/types.zig");
const echo = @import("provider/echo.zig");
const config_mod = @import("config.zig");

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
) !void {
    var msg_arena = std.heap.ArenaAllocator.init(gpa);
    defer msg_arena.deinit();

    // Process-lifetime session store (outlives per-message arenas).
    var session_store = types_v1.SessionStore.init(gpa);
    defer session_store.deinit();

    var writer_lock: std.atomic.Mutex = .unlocked;
    var cancel_requested = std.atomic.Value(bool).init(false);
    var worker_done = std.atomic.Value(bool).init(false);
    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var ctx = methods_v1.Context{
        .sessions = &session_store,
        .writer = writer,
        .writer_lock = &writer_lock,
        .provider = .{ .generate = echo.generate },
        .cancel_requested = &cancel_requested,
        .worker_done = &worker_done,
        .http = &http_client,
        .config = config,
        .process_allocator = gpa,
    };

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

        if (line.len == 0) continue; // transport-level keepalive line

        const message = json_rpc.parseLine(msg_alloc, line) catch |err| switch (err) {
            error.ParseError => {
                respondErrorLocked(&ctx, msg_alloc, .null, json_rpc.ErrorCode.parse_error, "Parse error") catch break;
                continue;
            },
            error.InvalidRequest => {
                respondErrorLocked(&ctx, msg_alloc, .null, json_rpc.ErrorCode.invalid_request, "Invalid Request") catch break;
                continue;
            },
        };

        dispatch(&ctx, msg_alloc, message) catch break;
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
        .response, .error_response => {},
    }
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
    const cfg = @import("config.zig").Config{
        .api_key = "test-key",
        .base_url = "http://127.0.0.1:1",
        .model = "test-model",
        .effort = "high",
    };
    try run(io, &fixed_reader, &out.writer, a, cfg);
    try testing.expectEqualStrings(expected, out.written());
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
    const expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1,\"agentCapabilities\":{\"sessionCapabilities\":{},\"promptCapabilities\":{}},\"authMethods\":[],\"agentInfo\":{\"name\":\"agent-client-protocol\",\"version\":\"0.1.0\"}}}\n";
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
        \\{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{},"promptCapabilities":{}},"authMethods":[],"agentInfo":{"name":"agent-client-protocol","version":"0.1.0"}}}
        \\{"jsonrpc":"2.0","id":2,"result":{"sessionId":"1"}}
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}}}
        \\{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}
    ;
    // Zig multiline literals omit the final newline; the loop emits one per line.
    try expectRun(input, expected ++ "\n");
}
