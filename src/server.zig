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

/// Protocol messages only on stdout; all logging goes to stderr (callers
/// wire the file handles).
const line_buffer_size = 1024 * 1024;

/// Run the transport loop until EOF. `gpa` backs a per-message arena that is
/// reset each iteration.
pub fn run(
    reader: *Io.Reader,
    writer: *Io.Writer,
    gpa: std.mem.Allocator,
) !void {
    var msg_arena = std.heap.ArenaAllocator.init(gpa);
    defer msg_arena.deinit();

    while (true) {
        _ = msg_arena.reset(.retain_capacity);
        const msg_alloc = msg_arena.allocator();

        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                // Line exceeds the reader buffer: discard it and answer with a
                // parse error, then keep the connection alive.
                _ = reader.discardDelimiterInclusive('\n') catch {};
                respondError(writer, msg_alloc, .null, json_rpc.ErrorCode.parse_error, "Parse error") catch break;
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
                respondError(writer, msg_alloc, .null, json_rpc.ErrorCode.parse_error, "Parse error") catch break;
                continue;
            },
            error.InvalidRequest => {
                respondError(writer, msg_alloc, .null, json_rpc.ErrorCode.invalid_request, "Invalid Request") catch break;
                continue;
            },
        };

        dispatch(writer, msg_alloc, message) catch break;
    }

    // EOF: exit cleanly, no further writes.
}

/// F1 dispatch: no methods implemented yet — every request answers
/// `method not found` (-32601). Notifications and unexpected inbound
/// responses are ignored. Method handlers land in F2+.
fn dispatch(
    writer: *Io.Writer,
    allocator: std.mem.Allocator,
    message: json_rpc.Message,
) !void {
    switch (message) {
        .request => |r| {
            try respondError(writer, allocator, r.id, json_rpc.ErrorCode.method_not_found, "Method not found");
        },
        .notification => {},
        .response, .error_response => {},
    }
}

fn respondError(
    writer: *Io.Writer,
    allocator: std.mem.Allocator,
    id: json_rpc.RequestId,
    code: i32,
    message_text: []const u8,
) !void {
    try json_rpc.serializeError(allocator, writer, id, .{
        .code = code,
        .message = message_text,
    });
    try writer.writeAll("\n");
    try writer.flush();
}

// ---------------------------------------------------------------------------
// Tests — the transcript fixture, in-process via the Zig test framework
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectRun(input: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fixed_reader = Io.Reader.fixed(input);
    var out: Io.Writer.Allocating = .init(a);
    try run(&fixed_reader, &out.writer, a);
    try testing.expectEqualStrings(expected, out.written());
}

test "transcript: requests answer method-not-found with verbatim ids" {
    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}
        \\{"jsonrpc":"2.0","id":2,"method":"session/new","params":{}}
        \\
        \\{"jsonrpc":"2.0","id":"req-3","method":"session/prompt","params":null}
        \\{not json
        \\{"jsonrpc":"2.0","id":4,"method":"session/cancel","params":{"sessionId":"s1"}}
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
    const input = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"session/new\",\"params\":{}}";
    const expected = "{\"jsonrpc\":\"2.0\",\"id\":5,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}\n";
    try expectRun(input, expected);
}
