//! ACP v1 method registry and handlers.
//!
//! Version-namespaced per the F2 decision: each protocol version owns a
//! registry of `Handler` functions; v2 (later) may reuse v1 handlers via
//! `@import`. The shared JSON-RPC wire format lives in `protocol/json_rpc.zig`.
//!
//! Handlers receive a `Context` (session store + stdout writer) so they can
//! stream `session/update` notifications before the final response.

const std = @import("std");
const Io = std.Io;

const json_rpc = @import("../json_rpc.zig");
const types = @import("types.zig");
const adapter = @import("../../provider/adapter.zig");
const echo = @import("../../provider/echo.zig");

/// Version of this registry's protocol.
pub const protocol_version: u16 = 1;

pub const agent_name = "agent-client-protocol";
pub const agent_version = "0.1.0";

/// Server context threaded through handlers: session store, stdout writer
/// (for streaming notifications), and the active provider.
pub const Context = struct {
    sessions: *types.SessionStore,
    writer: *Io.Writer,
    provider: adapter.Provider,
    /// Set by `session/cancel`. F3 has no preemptive cancellation (the read
    /// loop is synchronous), so a cancel arriving before the next prompt
    /// answers it with `stopReason: cancelled`; mid-prompt preemption lands
    /// in F4 (event loop / worker thread).
    cancel_requested: bool = false,
};

/// Errors a handler may return, mapped to JSON-RPC codes by the dispatcher:
/// `error.InvalidParams` → -32602, `error.InvalidRequest` → -32600,
/// anything else → -32603.
pub const Handler = *const fn (
    ctx: *Context,
    allocator: std.mem.Allocator,
    params: std.json.Value,
) anyerror!std.json.Value;

/// Notification handlers return void (no response is sent).
pub const NotificationHandler = *const fn (
    ctx: *Context,
    allocator: std.mem.Allocator,
    params: std.json.Value,
) anyerror!void;

pub const Method = struct {
    name: []const u8,
    handler: Handler,
};

pub const Notification = struct {
    name: []const u8,
    handler: NotificationHandler,
};

/// v1 request method table. Lookup is linear (small table).
const v1_methods = [_]Method{
    .{ .name = "initialize", .handler = initialize },
    .{ .name = "session/new", .handler = sessionNew },
    .{ .name = "session/prompt", .handler = sessionPrompt },
};

/// v1 notification table (no response).
const v1_notifications = [_]Notification{
    .{ .name = "session/cancel", .handler = sessionCancel },
};

/// Look up a request method handler by name, or null if unknown.
pub fn lookup(name: []const u8) ?Handler {
    for (v1_methods) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.handler;
    }
    return null;
}

/// Look up a notification handler by name, or null if unknown.
pub fn lookupNotification(name: []const u8) ?NotificationHandler {
    for (v1_notifications) |n| {
        if (std.mem.eql(u8, n.name, name)) return n.handler;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// `initialize` — negotiate protocol version and capabilities.
fn initialize(
    ctx: *Context,
    allocator: std.mem.Allocator,
    params: std.json.Value,
) anyerror!std.json.Value {
    _ = ctx;
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

/// `session/new` — create a session and return its id.
/// `cwd` (string) is required; `mcpServers` is accepted but ignored (MCP is
/// Epic 2 scope).
fn sessionNew(
    ctx: *Context,
    allocator: std.mem.Allocator,
    params: std.json.Value,
) anyerror!std.json.Value {
    const p = switch (params) {
        .object => |o| o,
        else => return error.InvalidParams,
    };
    const cwd = switch (p.get("cwd") orelse return error.InvalidParams) {
        .string => |s| s,
        else => return error.InvalidParams,
    };

    const session = try ctx.sessions.create(cwd);

    var result: std.json.ObjectMap = .empty;
    errdefer result.deinit(allocator);
    try result.put(allocator, "sessionId", .{ .string = session.id });
    return .{ .object = result };
}

/// `session/prompt` — stream the provider's chunks as `session/update`
/// notifications, then return `PromptResponse {stopReason}`.
fn sessionPrompt(
    ctx: *Context,
    allocator: std.mem.Allocator,
    params: std.json.Value,
) anyerror!std.json.Value {
    const p = switch (params) {
        .object => |o| o,
        else => return error.InvalidParams,
    };
    const session_id = switch (p.get("sessionId") orelse return error.InvalidParams) {
        .string => |s| s,
        else => return error.InvalidParams,
    };
    if (ctx.sessions.get(session_id) == null) return error.InvalidParams;

    // F3 cooperative cancellation: a cancel that arrived before this prompt
    // answers it with `cancelled`.
    if (ctx.cancel_requested) {
        ctx.cancel_requested = false;
        return stopReasonResult(allocator, "cancelled");
    }
    ctx.cancel_requested = false;

    const prompt = switch (p.get("prompt") orelse return error.InvalidParams) {
        .array => |arr| arr,
        else => return error.InvalidParams,
    };

    // Extract text blocks; non-text blocks are skipped.
    var text_blocks: std.ArrayList([]const u8) = .empty;
    for (prompt.items) |block| {
        if (block != .object) continue;
        const b = block.object;
        const block_type = b.get("type") orelse continue;
        if (block_type != .string or !std.mem.eql(u8, block_type.string, "text")) continue;
        const text = b.get("text") orelse continue;
        if (text != .string) continue;
        try text_blocks.append(allocator, text.string);
    }

    var chunks: std.ArrayList([]const u8) = .empty;
    const stop = try ctx.provider.generate(allocator, text_blocks.items, &chunks);

    for (chunks.items) |chunk| {
        try emitMessageChunk(ctx, allocator, session_id, chunk);
    }
    return stopReasonResult(allocator, stop);
}

/// `session/cancel` (notification) — set the pending-cancel flag.
/// See the cancellation note in `Context`.
fn sessionCancel(
    ctx: *Context,
    allocator: std.mem.Allocator,
    params: std.json.Value,
) anyerror!void {
    const p = switch (params) {
        .object => |o| o,
        else => return, // malformed cancel: ignore
    };
    const session_id = switch (p.get("sessionId") orelse return) {
        .string => |s| s,
        else => return,
    };
    if (ctx.sessions.get(session_id) == null) {
        std.log.warn("session/cancel: unknown session '{s}'", .{session_id});
        return;
    }
    _ = allocator;
    ctx.cancel_requested = true;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Emit one `session/update` notification with an `agent_message_chunk`.
fn emitMessageChunk(
    ctx: *Context,
    allocator: std.mem.Allocator,
    session_id: []const u8,
    text: []const u8,
) !void {
    var content: std.json.ObjectMap = .empty;
    defer content.deinit(allocator);
    try content.put(allocator, "type", .{ .string = "text" });
    try content.put(allocator, "text", .{ .string = text });

    var update: std.json.ObjectMap = .empty;
    defer update.deinit(allocator);
    try update.put(allocator, "sessionUpdate", .{ .string = "agent_message_chunk" });
    try update.put(allocator, "content", .{ .object = content });

    var params: std.json.ObjectMap = .empty;
    defer params.deinit(allocator);
    try params.put(allocator, "sessionId", .{ .string = session_id });
    try params.put(allocator, "update", .{ .object = update });

    try json_rpc.serializeNotification(allocator, ctx.writer, "session/update", .{ .object = params });
    try ctx.writer.writeAll("\n");
    try ctx.writer.flush();
}

fn stopReasonResult(allocator: std.mem.Allocator, stop: []const u8) !std.json.Value {
    // The returned Value escapes this frame — errdefer only (callers own the
    // value; typically arena-backed).
    var result: std.json.ObjectMap = .empty;
    errdefer result.deinit(allocator);
    try result.put(allocator, "stopReason", .{ .string = stop });
    return .{ .object = result };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testContext(a: std.mem.Allocator, writer: *Io.Writer) !*Context {
    const store = try a.create(types.SessionStore);
    store.* = types.SessionStore.init(a);
    const ctx = try a.create(Context);
    ctx.* = .{
        .sessions = store,
        .writer = writer,
        .provider = .{ .generate = echo.generate },
    };
    return ctx;
}

test "lookup finds known methods and notifications, misses unknown" {
    try testing.expect(lookup("initialize") != null);
    try testing.expect(lookup("session/new") != null);
    try testing.expect(lookup("session/prompt") != null);
    try testing.expect(lookup("session/cancel") == null); // notification, not request
    try testing.expect(lookup("") == null);
    try testing.expect(lookupNotification("session/cancel") != null);
    try testing.expect(lookupNotification("initialize") == null);
}

test "initialize: valid request returns v1 response shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var out: Io.Writer.Allocating = .init(a);
    const ctx = try testContext(a, &out.writer);

    var params: std.json.ObjectMap = .empty;
    defer params.deinit(a);
    try params.put(a, "protocolVersion", .{ .integer = 1 });

    const result = try initialize(ctx, a, .{ .object = params });
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
}

test "initialize: invalid protocolVersion rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    const ctx = try testContext(a, &out.writer);

    try testing.expectError(error.InvalidParams, initialize(ctx, a, .null));
    try testing.expectError(error.InvalidParams, initialize(ctx, a, .{ .object = .empty }));
    try testing.expectError(error.InvalidParams, initialize(ctx, a, .{ .object = blk: {
        var m: std.json.ObjectMap = .empty;
        try m.put(a, "protocolVersion", .{ .integer = 0 });
        break :blk m;
    } }));
}

test "session/new: creates session, validates cwd" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    const ctx = try testContext(a, &out.writer);

    const result = try sessionNew(ctx, a, .{ .object = blk: {
        var m: std.json.ObjectMap = .empty;
        try m.put(a, "cwd", .{ .string = "/tmp" });
        break :blk m;
    } });
    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("1", obj.get("sessionId").?.string);

    try testing.expectError(error.InvalidParams, sessionNew(ctx, a, .{ .object = .empty }));
    try testing.expectError(error.InvalidParams, sessionNew(ctx, a, .{ .object = blk: {
        var m: std.json.ObjectMap = .empty;
        try m.put(a, "cwd", .{ .integer = 42 });
        break :blk m;
    } }));
}

test "session/prompt: streams chunks then end_turn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    const ctx = try testContext(a, &out.writer);

    _ = try sessionNew(ctx, a, .{ .object = blk: {
        var m: std.json.ObjectMap = .empty;
        try m.put(a, "cwd", .{ .string = "/tmp" });
        break :blk m;
    } });

    var prompt: std.json.Array = .init(a);
    defer prompt.deinit();
    var block: std.json.ObjectMap = .empty;
    try block.put(a, "type", .{ .string = "text" });
    try block.put(a, "text", .{ .string = "hello world" });
    try prompt.append(.{ .object = block });

    var params: std.json.ObjectMap = .empty;
    try params.put(a, "sessionId", .{ .string = "1" });
    try params.put(a, "prompt", .{ .array = prompt });

    const result = try sessionPrompt(ctx, a, .{ .object = params });
    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("end_turn", obj.get("stopReason").?.string);

    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"hello world\"}}}}\n",
        out.written(),
    );
}

test "session/prompt: unknown session and bad params rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    const ctx = try testContext(a, &out.writer);

    try testing.expectError(error.InvalidParams, sessionPrompt(ctx, a, .{ .object = blk: {
        var m: std.json.ObjectMap = .empty;
        try m.put(a, "sessionId", .{ .string = "nope" });
        try m.put(a, "prompt", .{ .array = std.json.Array.init(a) });
        break :blk m;
    } }));
    try testing.expectError(error.InvalidParams, sessionPrompt(ctx, a, .null));
    try testing.expectError(error.InvalidParams, sessionPrompt(ctx, a, .{ .object = .empty }));
}

test "session/cancel before prompt answers cancelled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    const ctx = try testContext(a, &out.writer);

    _ = try sessionNew(ctx, a, .{ .object = blk: {
        var m: std.json.ObjectMap = .empty;
        try m.put(a, "cwd", .{ .string = "/tmp" });
        break :blk m;
    } });

    try sessionCancel(ctx, a, .{ .object = blk: {
        var m: std.json.ObjectMap = .empty;
        try m.put(a, "sessionId", .{ .string = "1" });
        break :blk m;
    } });
    try testing.expect(ctx.cancel_requested);

    const result = try sessionPrompt(ctx, a, .{ .object = blk: {
        var m: std.json.ObjectMap = .empty;
        try m.put(a, "sessionId", .{ .string = "1" });
        try m.put(a, "prompt", .{ .array = std.json.Array.init(a) });
        break :blk m;
    } });
    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("cancelled", obj.get("stopReason").?.string);
    try testing.expect(!ctx.cancel_requested);
}
