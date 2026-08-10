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
const config_mod = @import("../../config.zig");

/// Version of this registry's protocol.
pub const protocol_version: u16 = 1;

pub const agent_name = "agent-client-protocol";
pub const agent_version = "0.1.0";

/// Signal that a handler started async work that owns the turn's output
/// (e.g. a worker thread streaming a prompt); the dispatcher must not write a
/// response.
pub const DeferredResponse = error{DeferredResponse};

/// Server context threaded through handlers: session store, stdout writer
/// (for streaming notifications), provider, and shared async state.
pub const Context = struct {
    sessions: *types.SessionStore,
    writer: *Io.Writer,
    writer_lock: *std.atomic.Mutex,
    provider: adapter.Provider,
    /// Set by `session/cancel` (main loop); polled by the prompt worker
    /// between chunks (preemptive cancellation).
    cancel_requested: *std.atomic.Value(bool),
    http: *std.http.Client,
    config: config_mod.Config,
    /// Process-lifetime allocator (worker arenas must outlive per-message
    /// arena resets).
    process_allocator: std.mem.Allocator,
    /// Set by the prompt worker when it finishes; the EOF path only cancels a
    /// still-running worker.
    worker_done: *std.atomic.Value(bool),
    /// The active prompt worker thread, joined at EOF.
    active_worker: ?std.Thread = null,
};

/// Errors a handler may return, mapped to JSON-RPC codes by the dispatcher:
/// `error.InvalidParams` → -32602, `error.InvalidRequest` → -32600,
/// anything else → -32603.
pub const Handler = *const fn (
    ctx: *Context,
    allocator: std.mem.Allocator,
    id: json_rpc.RequestId,
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
    id: json_rpc.RequestId,
    params: std.json.Value,
) anyerror!std.json.Value {
    _ = ctx;
    _ = id;
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
    id: json_rpc.RequestId,
    params: std.json.Value,
) anyerror!std.json.Value {
    _ = id;
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

/// `session/prompt` — start a prompt turn.
///
/// Validation happens synchronously (including a pending-cancel check); the
/// actual generation runs on a worker thread so the main loop keeps reading
/// stdin (making `session/cancel` preemptive). Returns `DeferredResponse`
/// after spawning — the worker owns the turn's output.
fn sessionPrompt(
    ctx: *Context,
    allocator: std.mem.Allocator,
    id: json_rpc.RequestId,
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

    // A cancel that arrived before this prompt answers it with `cancelled`.
    if (ctx.cancel_requested.load(.monotonic)) {
        ctx.cancel_requested.store(false, .monotonic);
        return stopReasonResult(allocator, "cancelled");
    }
    ctx.cancel_requested.store(false, .monotonic);

    const prompt = switch (p.get("prompt") orelse return error.InvalidParams) {
        .array => |arr| arr,
        else => return error.InvalidParams,
    };

    // Extract text blocks; non-text blocks are skipped. The worker needs its
    // own copies (the per-message arena resets while it runs).
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

    // Spawn the worker with its own arena + deep copies. Ownership of the
    // arena transfers to the worker on successful spawn; on any failure
    // before spawn, free it here. NOTE: returning error.DeferredResponse is
    // still an error return — errdefers must NOT own the arena (they would
    // fire and free it while the worker runs).
    const worker_arena = try ctx.process_allocator.create(std.heap.ArenaAllocator);
    worker_arena.* = std.heap.ArenaAllocator.init(ctx.process_allocator);
    const wa = worker_arena.allocator();

    const worker = wa.create(PromptWorker) catch {
        worker_arena.deinit();
        ctx.process_allocator.destroy(worker_arena);
        return error.InternalError;
    };
    worker.* = .{
        .ctx = ctx,
        .arena = worker_arena,
        .text_blocks = dupStrings(wa, text_blocks.items) catch {
            worker_arena.deinit();
            ctx.process_allocator.destroy(worker_arena);
            return error.InternalError;
        },
        .session_id = wa.dupe(u8, session_id) catch {
            worker_arena.deinit();
            ctx.process_allocator.destroy(worker_arena);
            return error.InternalError;
        },
        .id = copyRequestId(wa, id) catch {
            worker_arena.deinit();
            ctx.process_allocator.destroy(worker_arena);
            return error.InternalError;
        },
    };

    const thread = std.Thread.spawn(.{}, PromptWorker.run, .{worker}) catch |err| {
        std.log.err("session/prompt: failed to spawn worker: {s}", .{@errorName(err)});
        worker_arena.deinit();
        ctx.process_allocator.destroy(worker_arena);
        return error.InternalError;
    };
    ctx.active_worker = thread;
    return error.DeferredResponse;
}

/// `session/cancel` (notification) — set the cancellation flag. The prompt
/// worker polls it between chunks and answers `stopReason: cancelled`.
fn sessionCancel(
    ctx: *Context,
    allocator: std.mem.Allocator,
    params: std.json.Value,
) anyerror!void {
    _ = allocator;
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
    ctx.cancel_requested.store(true, .monotonic);
}

// ---------------------------------------------------------------------------
// Prompt worker (F4: preemptive cancellation via worker thread)
// ---------------------------------------------------------------------------

/// Userdata for the provider's emit/cancel callbacks.
const EmitUd = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    session_id: []const u8,
    /// True once the first chunk has been emitted. Cancels that land before
    /// streaming starts (e.g. the loop's EOF shutdown racing thread spawn)
    /// are ignored — pre-start cancels are handled synchronously in
    /// `sessionPrompt`; mid-stream cancels are honored.
    streaming: bool = false,
};

/// Runs one prompt turn on a worker thread: streams provider chunks as
/// `session/update` notifications (writer lock held per write), then writes
/// the final response. Owns its arena.
const PromptWorker = struct {
    ctx: *Context,
    arena: *std.heap.ArenaAllocator,
    text_blocks: []const []const u8,
    session_id: []const u8,
    id: json_rpc.RequestId,

    fn run(self: *PromptWorker) void {
        defer self.ctx.worker_done.store(true, .monotonic);
        defer {
            self.arena.deinit();
            self.ctx.process_allocator.destroy(self.arena);
        }
        const allocator = self.arena.allocator();

        var emit_ud = EmitUd{
            .ctx = self.ctx,
            .allocator = allocator,
            .session_id = self.session_id,
        };

        const api_key = self.ctx.config.api_key orelse {
            self.writeError(json_rpc.ErrorCode.internal_error, "Missing OPENAI_API_KEY");
            return;
        };

        const result = self.ctx.provider.generate(allocator, self.text_blocks, .{
            .config = &self.ctx.config,
            .api_key = api_key,
            .http = self.ctx.http,
            .emit = emitChunk,
            .is_cancelled = isCancelled,
            .userdata = &emit_ud,
        });

        if (result) |r| {
            if (r.usage) |u| self.writeUsage(u);
            self.writeResponse(stopReasonResult(allocator, r.stop_reason) catch {
                self.writeError(json_rpc.ErrorCode.internal_error, "Internal error");
                return;
            });
        } else |err| {
            switch (err) {
                error.Cancelled => self.writeResponse(stopReasonResult(allocator, "cancelled") catch return),
                error.MissingApiKey => self.writeError(json_rpc.ErrorCode.internal_error, "Missing OPENAI_API_KEY"),
                error.BadApiKey => self.writeError(json_rpc.ErrorCode.internal_error, "Provider authentication failed"),
                error.RateLimited => self.writeError(json_rpc.ErrorCode.internal_error, "Provider rate limited"),
                else => self.writeError(json_rpc.ErrorCode.internal_error, "Provider request failed"),
            }
        }
    }

    /// Emit a `usage_update` notification (schema: used/size).
    fn writeUsage(self: *PromptWorker, usage: adapter.Usage) void {
        var params: std.json.ObjectMap = .empty;
        defer params.deinit(self.arena.allocator());
        params.put(self.arena.allocator(), "sessionId", .{ .string = self.session_id }) catch return;

        var update: std.json.ObjectMap = .empty;
        defer update.deinit(self.arena.allocator());
        update.put(self.arena.allocator(), "sessionUpdate", .{ .string = "usage_update" }) catch return;
        update.put(self.arena.allocator(), "used", .{ .integer = @intCast(usage.prompt_tokens) }) catch return;
        update.put(self.arena.allocator(), "size", .{ .integer = @intCast(usage.total_tokens) }) catch return;
        params.put(self.arena.allocator(), "update", .{ .object = update }) catch return;

        self.writeLocked(json_rpc.serializeNotification(self.arena.allocator(), self.ctx.writer, "session/update", .{ .object = params }));
    }

    /// Write the final response (with lock).
    fn writeResponse(self: *PromptWorker, result: std.json.Value) void {
        self.writeLocked(json_rpc.serializeResponse(self.arena.allocator(), self.ctx.writer, self.id, result));
    }

    /// Write an error response (with lock).
    fn writeError(self: *PromptWorker, code: i32, message: []const u8) void {
        self.writeLocked(json_rpc.serializeError(self.arena.allocator(), self.ctx.writer, self.id, .{
            .code = code,
            .message = message,
        }));
    }

    /// Write a line + flush, holding the writer lock. Best-effort: write
    /// failures (client closed the pipe) just end the turn quietly.
    fn writeLocked(self: *PromptWorker, write_result: anyerror!void) void {
        lockSpin(self.ctx.writer_lock);
        defer self.ctx.writer_lock.unlock();
        write_result catch return;
        self.ctx.writer.writeAll("\n") catch return;
        self.ctx.writer.flush() catch return;
    }
};

fn emitChunk(chunk: []const u8, userdata: ?*anyopaque) anyerror!void {
    const ud: *EmitUd = @ptrCast(@alignCast(userdata.?));
    ud.streaming = true;
    lockSpin(ud.ctx.writer_lock);
    defer ud.ctx.writer_lock.unlock();
    try emitMessageChunk(ud.ctx, ud.allocator, ud.session_id, chunk);
}

fn isCancelled(userdata: ?*anyopaque) bool {
    const ud: *EmitUd = @ptrCast(@alignCast(userdata.?));
    return ud.streaming and ud.ctx.cancel_requested.load(.monotonic);
}

/// Busy-wait on a short critical section (the writer). `yield()` can fail on
/// Windows (NtYieldExecution) — ignore that error and spin again.
pub fn lockSpin(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) _ = std.Thread.yield() catch {};
}

/// Deep-copy a list of strings into `allocator`.
fn dupStrings(allocator: std.mem.Allocator, strings: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, strings.len);
    for (strings, 0..) |s, i| out[i] = try allocator.dupe(u8, s);
    return out;
}

/// Copy a RequestId into `allocator` (string ids get duped — the original may
/// live in a per-message arena).
fn copyRequestId(allocator: std.mem.Allocator, id: json_rpc.RequestId) !json_rpc.RequestId {
    return switch (id) {
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        else => id,
    };
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
    const mutex = try a.create(std.atomic.Mutex);
    mutex.* = .unlocked;
    const cancel = try a.create(std.atomic.Value(bool));
    cancel.* = std.atomic.Value(bool).init(false);
    const worker_done = try a.create(std.atomic.Value(bool));
    worker_done.* = std.atomic.Value(bool).init(false);
    const http = try a.create(std.http.Client);
    http.* = undefined;
    const ctx = try a.create(Context);
    ctx.* = .{
        .sessions = store,
        .writer = writer,
        .writer_lock = mutex,
        .provider = .{ .generate = echo.generate },
        .cancel_requested = cancel,
        .worker_done = worker_done,
        .http = http,
        .config = .{
            .api_key = "test-key",
            .base_url = "http://127.0.0.1",
            .model = "test-model",
            .effort = "high",
        },
        .process_allocator = a,
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

    const result = try initialize(ctx, a, .{ .int = 1 }, .{ .object = params });
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

    try testing.expectError(error.InvalidParams, initialize(ctx, a, .{ .int = 1 }, .null));
    try testing.expectError(error.InvalidParams, initialize(ctx, a, .{ .int = 1 }, .{ .object = .empty }));
    try testing.expectError(error.InvalidParams, initialize(ctx, a, .{ .int = 1 }, .{ .object = blk: {
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

    const result = try sessionNew(ctx, a, .{ .int = 1 }, .{ .object = blk: {
        var m: std.json.ObjectMap = .empty;
        try m.put(a, "cwd", .{ .string = "/tmp" });
        break :blk m;
    } });
    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("1", obj.get("sessionId").?.string);

    try testing.expectError(error.InvalidParams, sessionNew(ctx, a, .{ .int = 1 }, .{ .object = .empty }));
    try testing.expectError(error.InvalidParams, sessionNew(ctx, a, .{ .int = 1 }, .{ .object = blk: {
        var m: std.json.ObjectMap = .empty;
        try m.put(a, "cwd", .{ .integer = 42 });
        break :blk m;
    } }));
}

test "session/prompt: unknown session and bad params rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    const ctx = try testContext(a, &out.writer);

    try testing.expectError(error.InvalidParams, sessionPrompt(ctx, a, .{ .int = 3 }, .{ .object = blk: {
        var m: std.json.ObjectMap = .empty;
        try m.put(a, "sessionId", .{ .string = "nope" });
        try m.put(a, "prompt", .{ .array = std.json.Array.init(a) });
        break :blk m;
    } }));
    try testing.expectError(error.InvalidParams, sessionPrompt(ctx, a, .{ .int = 3 }, .null));
    try testing.expectError(error.InvalidParams, sessionPrompt(ctx, a, .{ .int = 3 }, .{ .object = .empty }));
}

test "session/cancel before prompt answers cancelled synchronously" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    const ctx = try testContext(a, &out.writer);

    _ = try sessionNew(ctx, a, .{ .int = 1 }, .{ .object = blk: {
        var m: std.json.ObjectMap = .empty;
        try m.put(a, "cwd", .{ .string = "/tmp" });
        break :blk m;
    } });

    try sessionCancel(ctx, a, .{ .object = blk: {
        var m: std.json.ObjectMap = .empty;
        try m.put(a, "sessionId", .{ .string = "1" });
        break :blk m;
    } });
    try testing.expect(ctx.cancel_requested.load(.monotonic));

    const result = try sessionPrompt(ctx, a, .{ .int = 2 }, .{ .object = blk: {
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
    try testing.expect(!ctx.cancel_requested.load(.monotonic));
}

test "session/cancel: unknown session ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    const ctx = try testContext(a, &out.writer);

    try sessionCancel(ctx, a, .{ .object = blk: {
        var m: std.json.ObjectMap = .empty;
        try m.put(a, "sessionId", .{ .string = "nope" });
        break :blk m;
    } });
    try testing.expect(!ctx.cancel_requested.load(.monotonic));
}
