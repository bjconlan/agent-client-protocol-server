//! Line-based transports for MCP stdio connections.
//!
//! MCP over stdio is newline-delimited JSON-RPC 2.0 — the same framing the ACP
//! server itself uses (`protocol/json_rpc.zig`). The `Transport` vtable keeps
//! the client testable in-process (scripted `MockTransport`) while the real
//! `StdioTransport` talks to a spawned child process over pipes.

const std = @import("std");
const Io = std.Io;

/// A line-based transport for an MCP stdio connection.
///
/// `readLine` returns a slice borrowed from the transport's internal buffer —
/// valid only until the next `readLine` call (the client parses immediately,
/// copying what it needs into its own memory). Returns `null` on clean EOF.
pub const Transport = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Write one complete line (no trailing newline included in `line`;
        /// the transport adds it). Callers serialize access via the client's
        /// write mutex.
        writeLine: *const fn (ctx: *anyopaque, io: Io, line: []const u8) anyerror!void,
        /// Read one line, borrowing from the transport's buffer.
        readLine: *const fn (ctx: *anyopaque, io: Io) anyerror!?[]const u8,
        /// Tear down the transport (close pipes / kill child, free memory).
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn writeLine(self: Transport, io: Io, line: []const u8) anyerror!void {
        return self.vtable.writeLine(self.ctx, io, line);
    }

    pub fn readLine(self: Transport, io: Io) anyerror!?[]const u8 {
        return self.vtable.readLine(self.ctx, io);
    }

    pub fn deinit(self: Transport) void {
        self.vtable.deinit(self.ctx);
    }
};

/// Stdio transport: spawns an MCP server as a child process and speaks
/// newline-delimited JSON-RPC over its stdin/stdout pipes.
pub const StdioTransport = struct {
    child: std.process.Child,
    io: Io,
    read_buf: [256 * 1024]u8,
    write_buf: [64 * 1024]u8,
    reader: ?Io.File.Reader = null,
    writer: ?Io.File.Writer = null,

    /// Spawn `argv` (resolved via PATH) with piped stdin/stdout; stderr is
    /// ignored. `environ_map` optionally replaces the child environment.
    pub fn spawn(
        io: Io,
        argv: []const []const u8,
        environ_map: ?*const std.process.Environ.Map,
    ) !StdioTransport {
        var self: StdioTransport = .{
            .child = try std.process.spawn(io, .{
                .argv = argv,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .ignore,
                .environ_map = environ_map,
            }),
            .io = io,
            .read_buf = undefined,
            .write_buf = undefined,
        };
        errdefer self.child.kill(io);
        self.reader = Io.File.Reader.init(self.child.stdout.?, io, &self.read_buf);
        self.writer = Io.File.Writer.init(self.child.stdin.?, io, &self.write_buf);
        return self;
    }

    pub fn transport(self: *StdioTransport) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn writeLineFn(ctx: *anyopaque, io: Io, line: []const u8) anyerror!void {
        _ = io;
        const self: *StdioTransport = @ptrCast(@alignCast(ctx));
        try self.writer.?.interface.writeAll(line);
        try self.writer.?.interface.writeAll("\n");
        // The writer is buffered — flush so the child actually receives the
        // line (request/response is synchronous; nothing else will flush).
        try self.writer.?.interface.flush();
    }

    fn readLineFn(ctx: *anyopaque, io: Io) anyerror!?[]const u8 {
        _ = io;
        const self: *StdioTransport = @ptrCast(@alignCast(ctx));
        return self.reader.?.interface.takeDelimiter('\n');
    }

    fn deinitFn(ctx: *anyopaque) void {
        const self: *StdioTransport = @ptrCast(@alignCast(ctx));
        // Closing stdin would let a well-behaved server exit cleanly; kill is
        // the reliable path for a first cut (covers servers that ignore EOF).
        // `kill` blocks until the child terminates and reaps it (id → null).
        self.child.kill(self.io);
        self.* = undefined;
    }

    const vtable = Transport.VTable{
        .writeLine = writeLineFn,
        .readLine = readLineFn,
        .deinit = deinitFn,
    };
};

test "stdio transport: line framing round-trip over real pipes" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    // `cat` echoes stdin to stdout — enough to verify pipe plumbing and
    // line framing without a real MCP server.
    var transport = try StdioTransport.spawn(std.testing.io, &.{ "sh", "-c", "cat" }, null);
    defer transport.transport().deinit();
    const t = transport.transport();

    try t.writeLine(std.testing.io, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":{}}");
    const line = (try t.readLine(std.testing.io)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":{}}", line);

    try t.writeLine(std.testing.io, "line two");
    const line2 = (try t.readLine(std.testing.io)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("line two", line2);
}
