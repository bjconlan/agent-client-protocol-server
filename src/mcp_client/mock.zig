//! Scripted in-memory transport for MCP client tests.
//!
//! Mirrors the project's `util/mock_http.zig` pattern: compiled in all builds,
//! used only by tests. `responses` is the server script — each client
//! `writeLine` makes the next scripted line available to `readLine`; every
//! line the client wrote is recorded in the mock's arena for assertions.

const std = @import("std");
const Io = std.Io;

const transport_mod = @import("transport.zig");

pub const MockTransport = struct {
    /// Scripted server lines, returned in order (one per client write).
    responses: []const []const u8,
    /// Every line the client wrote (arena-owned copies).
    writes: std.ArrayListUnmanaged([]const u8) = .empty,
    arena: std.heap.ArenaAllocator,
    next_response: usize = 0,

    pub fn init(allocator: std.mem.Allocator, responses: []const []const u8) MockTransport {
        return .{
            .responses = responses,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn transport(self: *MockTransport) transport_mod.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn writeLineFn(ctx: *anyopaque, io: Io, line: []const u8) anyerror!void {
        _ = io;
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        try self.writes.append(self.arena.allocator(), try self.arena.allocator().dupe(u8, line));
    }

    fn readLineFn(ctx: *anyopaque, io: Io) anyerror!?[]const u8 {
        _ = io;
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        if (self.next_response >= self.responses.len) return null;
        defer self.next_response += 1;
        return self.responses[self.next_response];
    }

    fn deinitFn(ctx: *anyopaque) void {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        self.arena.deinit();
        self.* = undefined;
    }

    const vtable = transport_mod.Transport.VTable{
        .writeLine = writeLineFn,
        .readLine = readLineFn,
        .deinit = deinitFn,
    };
};
