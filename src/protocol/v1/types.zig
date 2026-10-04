//! ACP v1 protocol types — session core.
//!
//! Mirrors the v1 schema (`.ai/knowledge/references/acp-schema-v1.json`):
//! SessionId, NewSessionRequest/Response, PromptRequest/Response,
//! SessionNotification / SessionUpdate variants, content blocks.
//!
//! Sessions are persisted as one JSON snapshot per session in a directory
//! (`SessionStore.persist_dir`), so they survive server restarts. The store
//! owns session memory for the process lifetime.

const std = @import("std");
const Io = std.Io;

/// Role of a stored exchange.
pub const Role = enum { user, assistant };

/// A stored exchange for cross-prompt context (the ACP agent holds session
/// context; the client sends only the new prompt).
pub const HistoryMessage = struct {
    role: Role,
    text: []const u8,
};

/// An active session (schema `NewSessionResponse.sessionId` is a string id).
/// Lives for the process; stored in `SessionStore` (arena-backed).
pub const Session = struct {
    id: []const u8,
    cwd: []const u8,
    /// The provider serving this session (from the server config).
    provider_name: []const u8,
    /// Session configuration: configId → value (from
    /// `session/set_config_option`), forwarded to the provider request.
    /// Keys/values are owned by the store's allocator.
    config: std.StringHashMap([]const u8),
    /// Recent user prompts + assistant text (last ~20), appended by the
    /// prompt worker. Strings are owned by the store's allocator.
    history: std.ArrayList(HistoryMessage) = .empty,
    /// Epoch seconds of the last persisted activity (for `session/list`
    /// `updatedAt`).
    updated_at: i64 = 0,
};

/// Session store keyed by session id. Keys/values are owned by the arena the
/// store was created with — they must outlive per-message arenas. Each map
/// value is a stable `*Session` so `session/close`/`delete` never invalidate
/// a worker's pointer.
pub const SessionStore = struct {
    map: std.StringHashMap(*Session),
    /// Backing allocator for session keys/values — must outlive per-message
    /// arenas (typically the process arena).
    allocator: std.mem.Allocator,
    next_id: u64 = 1,
    /// Directory for JSON snapshots; null disables persistence.
    persist_dir: ?Io.Dir = null,

    pub fn init(allocator: std.mem.Allocator) SessionStore {
        return .{
            .map = std.StringHashMap(*Session).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionStore) void {
        self.map.deinit();
    }

    /// Enable snapshot persistence into `dir` (must be writable; opened with
    /// iterate access for `loadAll`).
    pub fn setPersistDir(self: *SessionStore, dir: Io.Dir) void {
        self.persist_dir = dir;
    }

    /// Create a session, assigning the next monotonic id ("1", "2", …).
    /// Keys/values are allocated from the store's own allocator so they
    /// survive per-message arena resets.
    pub fn create(self: *SessionStore, cwd: []const u8, provider_name: []const u8) !*Session {
        const id = try self.allocator.print("{d}", .{self.next_id});
        self.next_id += 1;
        const session = try self.allocator.create(Session);
        session.* = .{
            .id = id,
            .cwd = try self.allocator.dupe(u8, cwd),
            .provider_name = try self.allocator.dupe(u8, provider_name),
            .config = std.StringHashMap([]const u8).init(self.allocator),
        };
        try self.map.put(session.id, session);
        return session;
    }

    pub fn get(self: *const SessionStore, id: []const u8) ?*Session {
        return self.map.get(id);
    }

    /// Mutable session lookup — the worker appends history through this.
    pub fn getPtr(self: *SessionStore, id: []const u8) ?*Session {
        return self.map.get(id);
    }

    /// Remove a session from memory and delete its snapshot (if any).
    pub fn remove(self: *SessionStore, io: Io, id: []const u8) void {
        _ = self.map.remove(id);
        const dir = self.persist_dir orelse return;
        const file_name = self.allocator.print("{s}.json", .{id}) catch return;
        dir.deleteFile(io, file_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => std.log.warn("session: delete '{s}' failed: {s}", .{ file_name, @errorName(err) }),
        };
    }

    /// Stamp `updated_at` and persist (best-effort).
    pub fn touch(self: *SessionStore, io: Io, session: *Session) void {
        session.updated_at = nowEpoch(io);
        self.save(io, session);
    }

    /// Write one session snapshot (best-effort; failures are logged, never
    /// propagated — persistence must not break a turn).
    pub fn save(self: *SessionStore, io: Io, session: *const Session) void {
        const dir = self.persist_dir orelse return;
        const a = self.allocator;

        var root: std.json.ObjectMap = .empty;
        defer root.deinit(a);
        root.put(a, "sessionId", .{ .string = session.id }) catch return;
        root.put(a, "cwd", .{ .string = session.cwd }) catch return;
        root.put(a, "provider", .{ .string = session.provider_name }) catch return;

        var cfg: std.json.ObjectMap = .empty;
        defer cfg.deinit(a);
        var cfg_it = session.config.iterator();
        while (cfg_it.next()) |e| cfg.put(a, e.key_ptr.*, .{ .string = e.value_ptr.* }) catch return;
        root.put(a, "config", .{ .object = cfg }) catch return;

        var hist: std.json.Array = std.json.Array.init(a);
        defer hist.deinit();
        for (session.history.items) |h| {
            var m: std.json.ObjectMap = .empty;
            m.put(a, "role", .{ .string = @tagName(h.role) }) catch return;
            m.put(a, "text", .{ .string = h.text }) catch return;
            hist.append(.{ .object = m }) catch return;
        }
        root.put(a, "history", .{ .array = hist }) catch return;
        root.put(a, "updatedAt", .{ .integer = session.updated_at }) catch return;

        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        std.json.Stringify.value(std.json.Value{ .object = root }, .{}, &out.writer) catch return;

        const file_name = a.print("{s}.json", .{session.id}) catch return;
        dir.writeFile(io, .{ .sub_path = file_name, .data = out.written() }) catch |err| {
            std.log.warn("session: save '{s}' failed: {s}", .{ file_name, @errorName(err) });
        };
    }

    /// Load every `*.json` snapshot from the persist dir (best-effort).
    pub fn loadAll(self: *SessionStore, io: Io) void {
        const dir = self.persist_dir orelse return;
        var it = dir.iterate();
        while (true) {
            const entry = it.next(io) catch break orelse break;
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            self.loadOne(io, dir, entry.name) catch |err| {
                std.log.warn("session: load '{s}' failed: {s}", .{ entry.name, @errorName(err) });
            };
        }
    }

    fn loadOne(self: *SessionStore, io: Io, dir: Io.Dir, name: []const u8) !void {
        const a = self.allocator;
        const raw = try dir.readFileAlloc(io, name, a, .unlimited);
        var scanner = std.json.Scanner.initCompleteInput(a, raw);
        const v = try std.json.Value.jsonParse(a, &scanner, .{
            .allocate = .alloc_always,
            .max_value_len = raw.len,
        });
        const obj = switch (v) {
            .object => |o| o,
            else => return error.InvalidSnapshot,
        };
        const id = objString(obj, "sessionId") orelse return error.InvalidSnapshot;
        const cwd = objString(obj, "cwd") orelse return error.InvalidSnapshot;

        const session = try a.create(Session);
        session.* = .{
            .id = id,
            .cwd = cwd,
            .provider_name = objString(obj, "provider") orelse "",
            .config = std.StringHashMap([]const u8).init(a),
        };
        if (obj.get("config")) |c| {
            if (c == .object) {
                var ci = c.object.iterator();
                while (ci.next()) |e| {
                    if (e.value_ptr.* == .string) try session.config.put(e.key_ptr.*, e.value_ptr.*.string);
                }
            }
        }
        if (obj.get("history")) |h| {
            if (h == .array) {
                for (h.array.items) |item| {
                    if (item != .object) continue;
                    const text = objString(item.object, "text") orelse continue;
                    const role_s = objString(item.object, "role") orelse continue;
                    const role = std.meta.stringToEnum(Role, role_s) orelse continue;
                    try session.history.append(a, .{ .role = role, .text = text });
                }
            }
        }
        if (obj.get("updatedAt")) |u| {
            if (u == .integer) session.updated_at = u.integer;
        }
        try self.map.put(session.id, session);
        const n = std.fmt.parseInt(u64, id, 10) catch 0;
        if (n >= self.next_id) self.next_id = n + 1;
    }
};

fn objString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn nowEpoch(io: Io) i64 {
    const ts = Io.Clock.now(.real, io);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "store: create assigns monotonic ids, get retrieves" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var store = SessionStore.init(a);
    defer store.deinit();

    const s1 = try store.create("/tmp", "default");
    const s2 = try store.create("/home", "default");
    try testing.expectEqualStrings("1", s1.id);
    try testing.expectEqualStrings("2", s2.id);
    try testing.expectEqualStrings("/tmp", s1.cwd);

    const got = store.get("1").?;
    try testing.expectEqualStrings("/tmp", got.cwd);
    try testing.expect(store.get("999") == null);
}

test "store: save/load round-trip persists config + history + next_id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store = SessionStore.init(a);
    defer store.deinit();
    store.setPersistDir(tmp.dir);
    const s = try store.create("/work", "prov");
    try s.config.put("model", "m1");
    try s.history.append(a, .{ .role = .user, .text = "hi" });
    store.touch(testing.io, s);

    var store2 = SessionStore.init(a);
    defer store2.deinit();
    store2.setPersistDir(tmp.dir);
    store2.loadAll(testing.io);

    const got = store2.get("1").?;
    try testing.expectEqualStrings("/work", got.cwd);
    try testing.expectEqualStrings("prov", got.provider_name);
    try testing.expectEqualStrings("m1", got.config.get("model").?);
    try testing.expectEqualStrings("hi", got.history.items[0].text);
    try testing.expect(got.updated_at > 0);

    // next_id is advanced past loaded ids.
    const s2 = try store2.create("/x", "prov");
    try testing.expectEqualStrings("2", s2.id);
}

test "store: remove deletes from memory and disk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store = SessionStore.init(a);
    defer store.deinit();
    store.setPersistDir(tmp.dir);
    const s = try store.create("/work", "prov");
    store.save(testing.io, s);
    try testing.expect(store.get("1") != null);

    store.remove(testing.io, "1");
    try testing.expect(store.get("1") == null);

    var store2 = SessionStore.init(a);
    defer store2.deinit();
    store2.setPersistDir(tmp.dir);
    store2.loadAll(testing.io);
    try testing.expect(store2.get("1") == null);
}
