//! Test-only mock HTTP server.
//!
//! Serves a single canned response over TCP (127.0.0.1, ephemeral port) and
//! records the request it received. Used by provider/health-check tests to
//! exercise the real `std.http.Client` path without network access.
//!
//! Only referenced from test blocks — not part of the production module tree.

const std = @import("std");
const Io = std.Io;

pub const Mock = struct {
    io: Io,
    allocator: std.mem.Allocator,
    server: std.Io.net.Server,
    thread: ?std.Thread = null,
    /// HTTP status line, e.g. "HTTP/1.1 200 OK".
    status_line: []const u8,
    /// Raw response body.
    body: []const u8,
    /// Captured request (head + body) — for assertions.
    request: std.ArrayList(u8) = .empty,

    pub fn start(
        io: Io,
        allocator: std.mem.Allocator,
        status_line: []const u8,
        body: []const u8,
    ) !*Mock {
        const self = try allocator.create(Mock);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .server = undefined,
            .status_line = status_line,
            .body = body,
        };

        var addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.server = try std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true });

        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    pub fn deinit(self: *Mock) void {
        if (self.thread) |t| t.join();
        self.request.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn port(self: *const Mock) u16 {
        return self.server.socket.address.getPort();
    }

    /// Serve one connection, then return.
    fn serve(self: *Mock) void {
        var conn = self.server.accept(self.io) catch return;
        defer conn.close(self.io);

        var read_buf: [8192]u8 = undefined;
        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(self.allocator);

        var stream_reader = conn.reader(self.io, &read_buf);
        const reader = &stream_reader.interface;
        // Read the request head (terminated by an empty line).
        while (true) {
            const line = (reader.takeDelimiter('\n') catch break) orelse break;
            head.appendSlice(self.allocator, line) catch break;
            head.append(self.allocator, '\n') catch break;
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (trimmed.len == 0) break;
        }
        // Read the body (content-length) if present.
        if (findContentLength(head.items)) |len| {
            _ = reader.readAlloc(self.allocator, len) catch {};
        }

        self.request.appendSlice(self.allocator, head.items) catch {};
        self.request.appendSlice(self.allocator, "\n") catch {};

        var write_buf: [8192]u8 = undefined;
        var stream_writer = conn.writer(self.io, &write_buf);
        const writer = &stream_writer.interface;
        writer.print("{s}\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{
            self.status_line, self.body.len,
        }) catch return;
        writer.writeAll(self.body) catch return;
        writer.flush() catch return;
    }
};

fn findContentLength(head: []const u8) ?usize {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    while (it.next()) |line| {
        var parts = std.mem.splitSequence(u8, line, ":");
        const name = std.mem.trim(u8, parts.next() orelse continue, " ");
        if (!std.mem.eql(u8, name, "Content-Length")) continue;
        const value = std.mem.trim(u8, parts.next() orelse continue, " ");
        return std.fmt.parseInt(usize, value, 10) catch null;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "mock: serves a canned response and records the request" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mock = try Mock.start(io, a, "HTTP/1.1 200 OK", "hello");
    defer mock.deinit();

    var http: std.http.Client = .{ .allocator = a, .io = io };
    defer http.deinit();

    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/models", .{mock.port()});
    defer a.free(url);

    var resp = try @import("../util/http.zig").request(&http, a, url, "sk-test", .{});
    defer resp.deinit();
    const body = try @import("../util/http.zig").readAll(resp, a);
    try testing.expectEqualStrings("hello", body);
    try testing.expect(std.mem.startsWith(u8, mock.request.items, "GET /models"));
}
