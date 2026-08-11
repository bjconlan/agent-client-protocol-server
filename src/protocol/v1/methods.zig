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
const tools_registry = @import("../../tools/registry.zig");

/// Max provider→tool iterations per prompt turn.
const tool_iteration_cap = 8;

/// Version of this registry's protocol.
pub const protocol_version: u16 = 1;

pub const agent_name = "agent-client-protocol";
pub const agent_version = "0.1.0";

/// Signal that a handler started async work that owns the turn's output
/// (e.g. a worker thread streaming a prompt); the dispatcher must not write a
/// response.
pub const DeferredResponse = error{DeferredResponse};

/// A pending `session/request_permission` slot. Single-slot: at most one
/// prompt (and thus one permission request) runs at a time. The worker sets
/// the request and spins on `done`; the main loop routes the client's
/// response into the slot. Permission persistence is client-side (the client
/// owns session/workspace policy) — the server stays stateless on grants.
pub const PendingPermission = struct {
    mutex: std.atomic.Mutex = .unlocked,
    /// Request id of the in-flight `session/request_permission` (worker
    /// arena-owned, alive while the worker waits).
    request_id: []const u8 = "",
    done: bool = false,
    granted: bool = false,
    /// Next request id counter.
    next_id: u64 = 1,
};

/// Server context threaded through handlers: session store, stdout writer
/// (for streaming notifications), provider, and shared async state.
pub const Context = struct {
    io: Io,
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
    /// Single-slot pending permission request (worker ↔ main loop).
    permission: *PendingPermission,
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
    // Arm the permission slot synchronously (main thread) BEFORE spawning, so
    // the loop can route the client's response no matter how fast it arrives.
    // The id is duped into the worker arena (outlives per-message resets).
    const permission_id = std.fmt.allocPrint(wa, "p{d}", .{ctx.permission.next_id}) catch {
        worker_arena.deinit();
        ctx.process_allocator.destroy(worker_arena);
        return error.InternalError;
    };
    ctx.permission.next_id += 1;
    lockSpin(&ctx.permission.mutex);
    ctx.permission.request_id = permission_id;
    ctx.permission.done = false;
    ctx.permission.granted = false;
    ctx.permission.mutex.unlock();

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
        .permission_id = permission_id,
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

/// Runs one prompt turn on a worker thread: iterates the provider tool-call
/// loop (streaming text chunks via `session/update`, reporting tool calls,
/// requesting permission, executing agent-side), then writes the final
/// response. Owns its arena.
const PromptWorker = struct {
    ctx: *Context,
    arena: *std.heap.ArenaAllocator,
    text_blocks: []const []const u8,
    session_id: []const u8,
    id: json_rpc.RequestId,
    /// Reserved permission request id — the pending slot is armed before any
    /// provider call so the main loop can route an early response.
    permission_id: []const u8,

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

        var tool_results: std.ArrayList(adapter.ToolResult) = .empty;
        var prior_outputs: std.ArrayList(std.json.Value) = .empty;
        var final_stop: []const u8 = "end_turn";
        var final_usage: ?adapter.Usage = null;

        for (0..tool_iteration_cap) |_| {
            const input = self.buildInput(allocator) catch {
                self.writeError(json_rpc.ErrorCode.internal_error, "Internal error");
                return;
            };

            const result = self.ctx.provider.generate(allocator, input, prior_outputs.items, tool_results.items, .{
                .config = &self.ctx.config,
                .api_key = api_key,
                .http = self.ctx.http,
                .tools = &tools_registry.registry,
                .emit = emitChunk,
                .is_cancelled = isCancelled,
                .userdata = &emit_ud,
            });

            const r = result catch |err| switch (err) {
                error.Cancelled => {
                    self.writeResponse(stopReasonResult(allocator, "cancelled") catch return);
                    return;
                },
                error.MissingApiKey => {
                    self.writeError(json_rpc.ErrorCode.internal_error, "Missing OPENAI_API_KEY");
                    return;
                },
                error.BadApiKey => {
                    self.writeError(json_rpc.ErrorCode.internal_error, "Provider authentication failed");
                    return;
                },
                error.RateLimited => {
                    self.writeError(json_rpc.ErrorCode.internal_error, "Provider rate limited");
                    return;
                },
                else => {
                    self.writeError(json_rpc.ErrorCode.internal_error, "Provider request failed");
                    return;
                },
            };

            if (r.usage) |u| final_usage = u;
            // Echo the model's output items (reasoning/function_call) into
            // the next call; some providers require this to continue.
            prior_outputs.clearRetainingCapacity();
            prior_outputs.appendSlice(allocator, r.output_items) catch {
                self.writeError(json_rpc.ErrorCode.internal_error, "Internal error");
                return;
            };
            if (r.tool_calls.len == 0) {
                final_stop = r.stop_reason;
                break;
            }

            // Execute each requested tool call (report, permission, run),
            // then loop again with the results fed back.
            for (r.tool_calls) |call| {
                const output = self.runToolCall(allocator, call) catch {
                    self.writeError(json_rpc.ErrorCode.internal_error, "Tool execution failed");
                    return;
                };
                tool_results.append(allocator, .{ .call_id = call.id, .output = output }) catch {
                    self.writeError(json_rpc.ErrorCode.internal_error, "Internal error");
                    return;
                };
            }
        }

        self.appendHistory(allocator) catch {};

        if (final_usage) |u| self.writeUsage(u);
        self.writeResponse(stopReasonResult(allocator, final_stop) catch {
            self.writeError(json_rpc.ErrorCode.internal_error, "Internal error");
            return;
        });
    }

    /// Build the provider input items: session history (user/assistant
    /// messages) + this prompt's text blocks as a user message.
    fn buildInput(self: *PromptWorker, allocator: std.mem.Allocator) !std.json.Value {
        // The returned Value escapes this frame — no deinit (worker arena
        // owns the array; the provider consumes it).
        var input: std.json.Array = std.json.Array.init(allocator);

        if (self.ctx.sessions.getPtr(self.session_id)) |session| {
            for (session.history.items) |h| {
                try appendMessage(allocator, &input, h.role, h.text);
            }
        }
        for (self.text_blocks) |text| {
            try appendMessage(allocator, &input, .user, text);
        }
        return .{ .array = input };
    }

    /// Execute one tool call: report pending, request permission, run
    /// agent-side (ACP v1), report completion, return the result text.
    fn runToolCall(self: *PromptWorker, allocator: std.mem.Allocator, call: adapter.ToolCall) ![]const u8 {
        const tool = tools_registry.lookup(call.name) orelse
            return allocator.dupe(u8, "ERROR: unknown tool");

        self.reportToolCall(allocator, call, tool, "pending");

        const granted = self.requestPermission(allocator, call, tool) catch false;
        if (!granted) {
            self.reportToolCall(allocator, call, tool, "failed");
            return allocator.dupe(u8, "ERROR: permission denied");
        }

        self.reportToolCall(allocator, call, tool, "in_progress");
        const result = tool.execute(allocator, self.ctx.io, call.arguments) catch |err| blk: {
            const msg = std.fmt.allocPrint(allocator, "ERROR: {s}", .{@errorName(err)}) catch break :blk "ERROR";
            break :blk msg;
        };
        self.reportToolResult(allocator, call, result);
        return result;
    }

    /// Send `session/request_permission` and wait for the client's response
    /// (routed into the single-slot `PendingPermission` by the main loop).
    /// Timeout (~10s) or cancellation → denied.
    fn requestPermission(
        self: *PromptWorker,
        allocator: std.mem.Allocator,
        call: adapter.ToolCall,
        tool: *const tools_registry.Tool,
    ) !bool {
        const req_id = self.permission_id;

        // params: {sessionId, toolCall, options: []}
        var tool_call: std.json.ObjectMap = .empty;
        try tool_call.put(allocator, "toolCallId", .{ .string = call.id });
        try tool_call.put(allocator, "title", .{ .string = tool.name });
        try tool_call.put(allocator, "kind", .{ .string = tool.kind });
        try tool_call.put(allocator, "status", .{ .string = "pending" });
        try tool_call.put(allocator, "rawInput", .{ .string = call.arguments });

        var params: std.json.ObjectMap = .empty;
        try params.put(allocator, "sessionId", .{ .string = self.session_id });
        try params.put(allocator, "toolCall", .{ .object = tool_call });
        try params.put(allocator, "options", .{ .array = std.json.Array.init(allocator) });

        self.writeLocked(json_rpc.serializeRequest(allocator, self.ctx.writer, .{ .string = req_id }, "session/request_permission", .{ .object = params }));

        var waited: u32 = 0;
        while (true) {
            lockSpin(&self.ctx.permission.mutex);
            const done = self.ctx.permission.done;
            const granted = self.ctx.permission.granted;
            self.ctx.permission.mutex.unlock();
            if (done) return granted;
            if (self.ctx.cancel_requested.load(.monotonic)) return false;
            // Portable-ish wait: yield ~1ms (no cross-platform nanosleep).
            for (0..100) |_| _ = std.Thread.yield() catch {};
            waited += 1;
            if (waited > 10_000) {
                std.log.warn("session/request_permission: timeout waiting for response", .{});
                return false;
            }
        }
    }

    /// Emit a `tool_call` / `tool_call_update` session/update notification.
    fn reportToolCall(
        self: *PromptWorker,
        allocator: std.mem.Allocator,
        call: adapter.ToolCall,
        tool: *const tools_registry.Tool,
        status: []const u8,
    ) void {
        var update: std.json.ObjectMap = .empty;
        defer update.deinit(allocator);
        update.put(allocator, "sessionUpdate", .{ .string = if (std.mem.eql(u8, status, "pending")) "tool_call" else "tool_call_update" }) catch return;
        update.put(allocator, "toolCallId", .{ .string = call.id }) catch return;
        update.put(allocator, "title", .{ .string = tool.name }) catch return;
        update.put(allocator, "kind", .{ .string = tool.kind }) catch return;
        update.put(allocator, "status", .{ .string = status }) catch return;
        update.put(allocator, "rawInput", .{ .string = call.arguments }) catch return;

        var params: std.json.ObjectMap = .empty;
        defer params.deinit(allocator);
        params.put(allocator, "sessionId", .{ .string = self.session_id }) catch return;
        params.put(allocator, "update", .{ .object = update }) catch return;

        self.writeLocked(json_rpc.serializeNotification(allocator, self.ctx.writer, "session/update", .{ .object = params }));
    }

    /// Emit a `tool_call_update` with the completed status + raw output.
    fn reportToolResult(
        self: *PromptWorker,
        allocator: std.mem.Allocator,
        call: adapter.ToolCall,
        result: []const u8,
    ) void {
        var update: std.json.ObjectMap = .empty;
        defer update.deinit(allocator);
        update.put(allocator, "sessionUpdate", .{ .string = "tool_call_update" }) catch return;
        update.put(allocator, "toolCallId", .{ .string = call.id }) catch return;
        update.put(allocator, "status", .{ .string = "completed" }) catch return;
        update.put(allocator, "rawOutput", .{ .string = result }) catch return;

        var params: std.json.ObjectMap = .empty;
        defer params.deinit(allocator);
        params.put(allocator, "sessionId", .{ .string = self.session_id }) catch return;
        params.put(allocator, "update", .{ .object = update }) catch return;

        self.writeLocked(json_rpc.serializeNotification(allocator, self.ctx.writer, "session/update", .{ .object = params }));
    }

    /// Append this turn to the session history (user prompt + assistant
    /// text; tool exchanges live within the turn). Keeps the last ~20.
    fn appendHistory(self: *PromptWorker, allocator: std.mem.Allocator) !void {
        const session = self.ctx.sessions.getPtr(self.session_id) orelse return;
        for (self.text_blocks) |text| {
            try session.history.append(self.ctx.process_allocator, .{ .role = .user, .text = try self.ctx.process_allocator.dupe(u8, text) });
        }
        // Assistant text is not tracked separately yet (the provider streams
        // it); the history holds user prompts for MVP context.
        _ = allocator;
        if (session.history.items.len > 40) {
            session.history.replaceRange(self.ctx.process_allocator, 0, session.history.items.len - 20, &.{}) catch {};
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

/// Append a message item (user/assistant) to the provider input array.
fn appendMessage(
    allocator: std.mem.Allocator,
    input: *std.json.Array,
    role: types.Role,
    text: []const u8,
) !void {
    // content escapes into the message Value — no deinit (arena-owned).
    var content: std.json.Array = std.json.Array.init(allocator);
    var text_item: std.json.ObjectMap = .empty;
    try text_item.put(allocator, "type", .{ .string = if (role == .user) "input_text" else "output_text" });
    try text_item.put(allocator, "text", .{ .string = text });
    try content.append(.{ .object = text_item });

    var msg: std.json.ObjectMap = .empty;
    try msg.put(allocator, "type", .{ .string = "message" });
    try msg.put(allocator, "role", .{ .string = if (role == .user) "user" else "assistant" });
    try msg.put(allocator, "content", .{ .array = content });
    try input.append(.{ .object = msg });
}

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
    const permission = try a.create(PendingPermission);
    permission.* = .{};
    const http = try a.create(std.http.Client);
    http.* = undefined;
    const ctx = try a.create(Context);
    const threaded = try a.create(std.Io.Threaded);
    threaded.* = std.Io.Threaded.init(a, .{});
    ctx.* = .{
        .io = threaded.io(),
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
        .permission = permission,
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

test "session history: buildInput includes history + current prompt" {
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

    // simulate a completed turn: history has the first user prompt
    const session = ctx.sessions.getPtr("1").?;
    try session.history.append(ctx.process_allocator, .{ .role = .user, .text = try ctx.process_allocator.dupe(u8, "first question") });

    // worker for a second prompt
    var worker_arena = std.heap.ArenaAllocator.init(a);
    defer worker_arena.deinit();
    const wa = worker_arena.allocator();
    const worker = try wa.create(PromptWorker);
    worker.* = .{
        .ctx = ctx,
        .arena = &worker_arena,
        .text_blocks = try dupStrings(wa, &.{"second question"}),
        .session_id = try wa.dupe(u8, "1"),
        .id = .{ .int = 2 },
        .permission_id = "",
    };

    const input = try worker.buildInput(wa);
    const arr = switch (input) {
        .array => |arr_| arr_,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 2), arr.items.len);
    // item 0 = history (user, "first question"); item 1 = current prompt
    const text0 = arr.items[0].object.get("content").?.array.items[0].object.get("text").?.string;
    const text1 = arr.items[1].object.get("content").?.array.items[0].object.get("text").?.string;
    try testing.expectEqualStrings("first question", text0);
    try testing.expectEqualStrings("second question", text1);
}
