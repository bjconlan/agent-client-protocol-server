//! ACP v1 protocol types — session core.
//!
//! Mirrors the v1 schema (`.ai/knowledge/references/acp-schema-v1.json`):
//! SessionId, NewSessionRequest/Response, PromptRequest/Response,
//! SessionNotification / SessionUpdate variants, content blocks.

const std = @import("std");

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
    /// Recent user prompts + assistant text (last ~20), appended by the
    /// prompt worker. Strings are owned by the store's allocator.
    history: std.ArrayList(HistoryMessage) = .empty,
};

/// In-memory session store keyed by session id. Keys/values are owned by the
/// arena the store was created with — they must outlive per-message arenas.
pub const SessionStore = struct {
    map: std.StringHashMap(Session),
    /// Backing allocator for session keys/values — must outlive per-message
    /// arenas (typically the process arena).
    allocator: std.mem.Allocator,
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) SessionStore {
        return .{
            .map = std.StringHashMap(Session).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionStore) void {
        self.map.deinit();
    }

    /// Create a session, assigning the next monotonic id ("1", "2", …).
    /// Keys/values are allocated from the store's own allocator so they
    /// survive per-message arena resets.
    pub fn create(self: *SessionStore, cwd: []const u8) !*Session {
        const id = try std.fmt.allocPrint(self.allocator, "{d}", .{self.next_id});
        self.next_id += 1;
        const session = try self.allocator.create(Session);
        session.* = .{
            .id = id,
            .cwd = try self.allocator.dupe(u8, cwd),
        };
        try self.map.put(id, session.*);
        return session;
    }

    pub fn get(self: *const SessionStore, id: []const u8) ?Session {
        return self.map.get(id);
    }

    /// Mutable session lookup — the worker appends history through this.
    pub fn getPtr(self: *SessionStore, id: []const u8) ?*Session {
        return self.map.getPtr(id);
    }
};

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

    const s1 = try store.create("/tmp");
    const s2 = try store.create("/home");
    try testing.expectEqualStrings("1", s1.id);
    try testing.expectEqualStrings("2", s2.id);
    try testing.expectEqualStrings("/tmp", s1.cwd);

    const got = store.get("1").?;
    try testing.expectEqualStrings("/tmp", got.cwd);
    try testing.expect(store.get("999") == null);
}
