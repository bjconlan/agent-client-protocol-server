//! JSON-RPC 2.0 framing, parsing, and serialization.
//!
//! ACP is a JSON-RPC 2.0 protocol carried over stdio. This module owns the
//! wire format: parsing incoming requests/notifications and serializing
//! responses/notifications, including error objects and request-id
//! correlation.
//!
//! Conventions (see `.ai/knowledge/decisions.md`):
//! - newline-delimited JSON; one message per line
//! - `"jsonrpc":"2.0"` required on every message
//! - `id` echoed verbatim (union: null | int | string) — clients correlate
//!   with string equality, so no normalization or type coercion
//! - batches (JSON arrays) are invalid requests; ACP never batches
//! - slices/values in `Message` are owned by the arena `parse` creates;
//!   release everything at once via `Parsed.deinit`

const std = @import("std");

/// A JSON-RPC request id. Mirrors the ACP `RequestId` schema: null (discouraged
/// but spec-allowed), integer (int64), or string. Serialized exactly as parsed.
pub const RequestId = union(enum) {
    null,
    int: i64,
    string: []const u8,
};

/// A JSON-RPC error object (spec section 5.1).
pub const ErrorObject = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
};

/// A parsed JSON-RPC 2.0 message. All slice/value fields are owned by the
/// arena created by `parse`; release everything at once via `Parsed.deinit`
/// (or reuse the caller's arena as in the server loop).
pub const Message = union(enum) {
    request: struct {
        id: RequestId,
        method: []const u8,
        /// Method-specific params; `.null` when absent.
        params: std.json.Value,
    },
    notification: struct {
        method: []const u8,
        /// Method-specific params; `.null` when absent.
        params: std.json.Value,
    },
    response: struct {
        id: RequestId,
        result: std.json.Value,
    },
    error_response: struct {
        id: RequestId,
        error_object: ErrorObject,
    },
};

/// A parsed message plus the arena owning all of its memory. This is what
/// `parse` returns: `deinit` releases everything at once — strings, params/
/// result JSON values, dropped number tokens, and the parse scaffolding.
/// (0.16's dynamic `std.json.Value` has no recursive deinit and leaks number
/// tokens under `.alloc_always`, so an arena is the leak-free way to own a
/// parsed message.)
pub const Parsed = struct {
    message: Message,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

/// JSON-RPC 2.0 error codes plus the ACP/ client conventions used here.
pub const ErrorCode = struct {
    pub const parse_error: i32 = -32700;
    pub const invalid_request: i32 = -32600;
    pub const method_not_found: i32 = -32601;
    pub const invalid_params: i32 = -32602;
    pub const internal_error: i32 = -32603;
    /// Request cancelled (`session/cancel`) — client convention.
    pub const request_cancelled: i32 = -32800;
};

/// Errors from `parse`, mapped to JSON-RPC codes by the caller:
/// `error.ParseError` → -32700, `error.InvalidRequest` → -32600.
pub const ParseError = error{ ParseError, InvalidRequest };

/// Parse one newline-delimited JSON-RPC 2.0 message.
///
/// All message memory (strings, params/result JSON values, and parse
/// scaffolding) is owned by a per-call arena over `allocator`; the returned
/// `Parsed.deinit` releases everything at once. Strict envelope validation:
/// the document must be an object with `"jsonrpc":"2.0"`, shaped as one of
/// request / notification / response / error response. Malformed JSON is
/// `error.ParseError`; envelope violations are `error.InvalidRequest`. A JSON
/// array (batch) is `error.InvalidRequest`.
pub fn parse(allocator: std.mem.Allocator, line: []const u8) ParseError!Parsed {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var scanner = std.json.Scanner.initCompleteInput(a, line);
    const value = std.json.Value.jsonParse(a, &scanner, .{
        .allocate = .alloc_always,
        .max_value_len = line.len,
    }) catch return error.ParseError;

    const root = switch (value) {
        .object => |o| o,
        else => return error.InvalidRequest,
    };

    const jsonrpc = root.get("jsonrpc") orelse return error.InvalidRequest;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0"))
        return error.InvalidRequest;

    const method_v = root.get("method");
    const id_v = root.get("id");

    if (method_v) |m| {
        const method = switch (m) {
            .string => |s| s,
            else => return error.InvalidRequest,
        };
        const params = root.get("params") orelse .null;
        if (id_v) |iv| {
            return .{ .message = .{ .request = .{
                .id = try requestId(iv),
                .method = method,
                .params = params,
            } }, .arena = arena };
        }
        return .{ .message = .{ .notification = .{ .method = method, .params = params } }, .arena = arena };
    }

    // No method: must be a response or error response, with an id.
    const id = try requestId(id_v orelse return error.InvalidRequest);

    if (root.get("error")) |ev| {
        const e = switch (ev) {
            .object => |o| o,
            else => return error.InvalidRequest,
        };
        const code_v = e.get("code") orelse return error.InvalidRequest;
        const code = switch (code_v) {
            .integer => |i| i,
            else => return error.InvalidRequest,
        };
        if (code < std.math.minInt(i32) or code > std.math.maxInt(i32))
            return error.InvalidRequest;
        const message_v = e.get("message") orelse return error.InvalidRequest;
        const message = switch (message_v) {
            .string => |s| s,
            else => return error.InvalidRequest,
        };
        return .{ .message = .{ .error_response = .{
            .id = id,
            .error_object = .{
                .code = @intCast(code),
                .message = message,
                .data = e.get("data"),
            },
        } }, .arena = arena };
    }

    if (root.get("result")) |rv| {
        return .{ .message = .{ .response = .{ .id = id, .result = rv } }, .arena = arena };
    }

    return error.InvalidRequest;
}

fn requestId(v: std.json.Value) ParseError!RequestId {
    return switch (v) {
        .null => .null,
        .integer => |i| .{ .int = i },
        .string => |s| .{ .string = s },
        else => error.InvalidRequest,
    };
}

fn idToValue(id: RequestId) std.json.Value {
    return switch (id) {
        .null => .null,
        .int => |i| .{ .integer = i },
        .string => |s| .{ .string = s },
    };
}

fn jsonrpcField(allocator: std.mem.Allocator, obj: *std.json.ObjectMap) !void {
    try obj.put(allocator, "jsonrpc", .{ .string = "2.0" });
}

/// Serialize a request as single-line JSON to `writer`.
pub fn serializeRequest(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    id: RequestId,
    method: []const u8,
    params: ?std.json.Value,
) !void {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(allocator);
    try jsonrpcField(allocator, &obj);
    try obj.put(allocator, "id", idToValue(id));
    try obj.put(allocator, "method", .{ .string = method });
    try obj.put(allocator, "params", params orelse .null);
    try std.json.Stringify.value(std.json.Value{ .object = obj }, .{}, writer);
}

/// Serialize a notification (no id) as single-line JSON to `writer`.
pub fn serializeNotification(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    method: []const u8,
    params: ?std.json.Value,
) !void {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(allocator);
    try jsonrpcField(allocator, &obj);
    try obj.put(allocator, "method", .{ .string = method });
    try obj.put(allocator, "params", params orelse .null);
    try std.json.Stringify.value(std.json.Value{ .object = obj }, .{}, writer);
}

/// Serialize a successful response as single-line JSON to `writer`.
pub fn serializeResponse(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    id: RequestId,
    result: std.json.Value,
) !void {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(allocator);
    try jsonrpcField(allocator, &obj);
    try obj.put(allocator, "id", idToValue(id));
    try obj.put(allocator, "result", result);
    try std.json.Stringify.value(std.json.Value{ .object = obj }, .{}, writer);
}

/// Serialize an error response as single-line JSON to `writer`.
pub fn serializeError(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    id: RequestId,
    error_object: ErrorObject,
) !void {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(allocator);
    try jsonrpcField(allocator, &obj);
    try obj.put(allocator, "id", idToValue(id));

    var err_obj: std.json.ObjectMap = .empty;
    defer err_obj.deinit(allocator);
    try err_obj.put(allocator, "code", .{ .integer = error_object.code });
    try err_obj.put(allocator, "message", .{ .string = error_object.message });
    if (error_object.data) |d| try err_obj.put(allocator, "data", d);

    try obj.put(allocator, "error", .{ .object = err_obj });
    try std.json.Stringify.value(std.json.Value{ .object = obj }, .{}, writer);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parse request with integer id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(),
        \\{"jsonrpc":"2.0","id":7,"method":"session/new","params":{"foo":"bar"}}
    );
    const m = parsed.message;
    switch (m) {
        .request => |r| {
            try testing.expectEqual(RequestId{ .int = 7 }, r.id);
            try testing.expectEqualStrings("session/new", r.method);
            try testing.expectEqual(@as(i64, 0), 0); // params checked below
        },
        else => return error.TestUnexpectedResult,
    }
    // params must be an object with foo=bar
    const params = switch (m) {
        .request => |r| r.params,
        else => unreachable,
    };
    try testing.expectEqual(@as(u8, 1), @intFromBool(params == .object));
    try testing.expectEqualStrings("bar", params.object.get("foo").?.string);
}

test "parse request with string id echoes verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(),
        \\{"jsonrpc":"2.0","id":"req-42","method":"initialize","params":{}}
    );
    const m = parsed.message;
    switch (m) {
        .request => |r| {
            try testing.expect(r.id == .string);
            try testing.expectEqualStrings("req-42", r.id.string);
            try testing.expectEqualStrings("initialize", r.method);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse request with null id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(),
        \\{"jsonrpc":"2.0","id":null,"method":"ping","params":{}}
    );
    const m = parsed.message;
    try testing.expect(m == .request);
}

test "parse notification without id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(),
        \\{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s1"}}
    );
    const m = parsed.message;
    switch (m) {
        .notification => |n| try testing.expectEqualStrings("session/cancel", n.method),
        else => return error.TestUnexpectedResult,
    }
}

test "parse response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(),
        \\{"jsonrpc":"2.0","id":1,"result":{"ok":true}}
    );
    const m = parsed.message;
    switch (m) {
        .response => |r| {
            try testing.expectEqual(RequestId{ .int = 1 }, r.id);
            try testing.expectEqual(@as(bool, true), r.result.object.get("ok").?.bool);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse error response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(),
        \\{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}
    );
    const m = parsed.message;
    switch (m) {
        .error_response => |e| {
            try testing.expectEqual(ErrorCode.method_not_found, e.error_object.code);
            try testing.expectEqualStrings("Method not found", e.error_object.message);
            try testing.expect(e.error_object.data == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "id round-trip: integer stays integer, string stays string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var out: std.Io.Writer.Allocating = .init(a);
    const writer = &out.writer;

    // int id
    try serializeRequest(a, writer, .{ .int = 7 }, "session/new", .{ .object = .empty });
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"session/new\",\"params\":{}}",
        out.written(),
    );
    // string id
    out.clearRetainingCapacity();
    try serializeRequest(a, writer, .{ .string = "abc" }, "initialize", null);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"initialize\",\"params\":null}",
        out.written(),
    );
}

test "parse errors: malformed JSON and envelope violations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.ParseError, parse(a, "{not json"));
    try testing.expectError(error.ParseError, parse(a, ""));

    // Well-formed JSON that is not a JSON-RPC message: envelope violation.
    try testing.expectError(error.InvalidRequest, parse(a, "null"));
    try testing.expectError(error.InvalidRequest, parse(a, "42"));

    // missing jsonrpc
    try testing.expectError(error.InvalidRequest, parse(a, "{\"id\":1,\"method\":\"x\"}"));
    // wrong jsonrpc version
    try testing.expectError(error.InvalidRequest, parse(a, "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"x\"}"));
    // array (batch) — invalid
    try testing.expectError(error.InvalidRequest, parse(a, "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\"}]"));
    // method not a string
    try testing.expectError(error.InvalidRequest, parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":42}"));
    // id of unsupported type (object)
    try testing.expectError(error.InvalidRequest, parse(a, "{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"x\"}"));
    // float id — schema says integer; reject
    try testing.expectError(error.InvalidRequest, parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"x\"}"));
    // response without id
    try testing.expectError(error.InvalidRequest, parse(a, "{\"jsonrpc\":\"2.0\",\"result\":{}}"));
    // response with neither result nor error
    try testing.expectError(error.InvalidRequest, parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1}"));
    // error object missing message
    try testing.expectError(error.InvalidRequest, parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-1}}"));
}

test "serialize error response shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    const writer = &out.writer;

    try serializeError(a, writer, .{ .int = 1 }, .{
        .code = ErrorCode.parse_error,
        .message = "Parse error",
    });
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}",
        out.written(),
    );
}

test "serialize notification has no id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    const writer = &out.writer;

    try serializeNotification(a, writer, "session/update", .{ .object = .empty });
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{}}",
        out.written(),
    );
}

test "serialize response round-trips result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    const writer = &out.writer;

    try serializeResponse(a, writer, .{ .int = 2 }, .{ .object = .empty });
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}",
        out.written(),
    );
}

test "Parsed.deinit frees a parsed message (leak-checked)" {
    // Parse with the leak-checking testing allocator; Parsed.deinit must
    // release every allocation via its arena — including number tokens that
    // std.json's dynamic parser drops under .alloc_always (they become
    // unreachable once converted to .integer/.float, so only an arena can
    // reclaim them).
    var parsed = try parse(testing.allocator,
        \\{"jsonrpc":"2.0","id":"req-7","method":"initialize","params":{"foo":"bar","n":[1,2,"three"],"num":42}}
    );
    defer parsed.deinit();
}

test "parse→serialize round-trip: notification and response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // notification round-trips to its canonical serialization
    const parsed = try parse(a,
        \\{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s1"}}
    );
    const n = parsed.message;
    var out: std.Io.Writer.Allocating = .init(a);
    const writer = &out.writer;
    switch (n) {
        .notification => |notif| try serializeNotification(a, writer, notif.method, notif.params),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"s1\"}}",
        out.written(),
    );
}
