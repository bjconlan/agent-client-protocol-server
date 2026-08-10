//! ACP v1 method registry and handlers.
//!
//! Version-namespaced per the F2 decision: each protocol version owns a
//! registry of `Handler` functions; v2 (later) may reuse v1 handlers via
//! `@import`. The shared JSON-RPC wire format lives in `protocol/json_rpc.zig`.
//!
//! Handlers are stateless for now (`fn(allocator, params) !Value`); session
//! state and a context struct arrive with F3.

const std = @import("std");

const json_rpc = @import("../json_rpc.zig");

/// Version of this registry's protocol.
pub const protocol_version: u16 = 1;

pub const agent_name = "agent-client-protocol";
pub const agent_version = "0.1.0";

/// Errors a handler may return, mapped to JSON-RPC codes by the dispatcher:
/// `error.InvalidParams` → -32602, `error.InvalidRequest` → -32600,
/// anything else → -32603.
pub const Handler = *const fn (
    allocator: std.mem.Allocator,
    params: std.json.Value,
) anyerror!std.json.Value;

pub const Method = struct {
    name: []const u8,
    handler: Handler,
};

/// v1 method table. Order does not matter; lookup is linear (small table).
const v1_methods = [_]Method{
    .{ .name = "initialize", .handler = initialize },
};

/// Look up a method handler by name, or null if unknown.
pub fn lookup(name: []const u8) ?Handler {
    for (v1_methods) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.handler;
    }
    return null;
}

/// `initialize` — negotiate protocol version and capabilities.
///
/// Accepts any integer `protocolVersion >= 1` and responds with our version
/// (1); missing, non-integer, or < 1 is `error.InvalidParams`.
/// `clientCapabilities` / `clientInfo` are accepted and ignored (logged by
/// the dispatcher if needed).
///
/// Response (schema `InitializeResponse`):
///   protocolVersion: 1
///   agentCapabilities: { sessionCapabilities: {}, promptCapabilities: {} }  // MVP surface
///   authMethods: []
///   agentInfo: { name: "agent-client-protocol", version: "0.1.0" }
fn initialize(
    allocator: std.mem.Allocator,
    params: std.json.Value,
) anyerror!std.json.Value {
    const p = switch (params) {
        .object => |o| o,
        else => return error.InvalidParams,
    };

    const version = switch (p.get("protocolVersion") orelse return error.InvalidParams) {
        .integer => |i| i,
        else => return error.InvalidParams,
    };
    if (version < 1) return error.InvalidParams;

    var caps: std.json.ObjectMap = .empty;
    errdefer caps.deinit(allocator);
    try caps.put(allocator, "sessionCapabilities", .{ .object = .empty });
    try caps.put(allocator, "promptCapabilities", .{ .object = .empty });

    var info: std.json.ObjectMap = .empty;
    errdefer info.deinit(allocator);
    try info.put(allocator, "name", .{ .string = agent_name });
    try info.put(allocator, "version", .{ .string = agent_version });

    var result: std.json.ObjectMap = .empty;
    errdefer result.deinit(allocator);
    try result.put(allocator, "protocolVersion", .{ .integer = 1 });
    try result.put(allocator, "agentCapabilities", .{ .object = caps });
    try result.put(allocator, "authMethods", .{ .array = std.json.Array.init(allocator) });
    try result.put(allocator, "agentInfo", .{ .object = info });

    return .{ .object = result };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "lookup finds initialize, misses unknown" {
    try testing.expect(lookup("initialize") != null);
    try testing.expect(lookup("session/new") == null);
    try testing.expect(lookup("") == null);
}

test "initialize: valid request returns v1 response shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var params: std.json.ObjectMap = .empty;
    defer params.deinit(a);
    try params.put(a, "protocolVersion", .{ .integer = 1 });
    try params.put(a, "clientCapabilities", .{ .object = .empty });

    const result = try initialize(a, .{ .object = params });
    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(i64, 1), obj.get("protocolVersion").?.integer);

    const caps = switch (obj.get("agentCapabilities").?) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(caps.get("sessionCapabilities") != null);
    try testing.expect(caps.get("promptCapabilities") != null);

    const auth = switch (obj.get("authMethods").?) {
        .array => |arr| arr,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 0), auth.items.len);

    const info = switch (obj.get("agentInfo").?) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings(agent_name, info.get("name").?.string);
    try testing.expectEqualStrings(agent_version, info.get("version").?.string);
}

test "initialize: protocolVersion >= 1 accepted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try initialize(a, .{ .object = blk: {
        var m: std.json.ObjectMap = .empty;
        try m.put(a, "protocolVersion", .{ .integer = 2 });
        break :blk m;
    } });
}

test "initialize: missing or invalid protocolVersion rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // missing
    try testing.expectError(error.InvalidParams, initialize(a, .{ .object = .empty }));
    // non-object params
    try testing.expectError(error.InvalidParams, initialize(a, .null));
    // non-integer version
    try testing.expectError(error.InvalidParams, initialize(a, .{ .object = blk: {
        var m: std.json.ObjectMap = .empty;
        try m.put(a, "protocolVersion", .{ .string = "1" });
        break :blk m;
    } }));
    // version below 1
    try testing.expectError(error.InvalidParams, initialize(a, .{ .object = blk: {
        var m: std.json.ObjectMap = .empty;
        try m.put(a, "protocolVersion", .{ .integer = 0 });
        break :blk m;
    } }));
}
