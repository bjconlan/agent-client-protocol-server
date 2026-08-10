const std = @import("std");
const Io = std.Io;

const agent_client_protocol = @import("agent_client_protocol");

/// ACP server entry point.
///
/// Wires real stdio file handles into the transport loop (`server.run`):
/// newline-delimited JSON-RPC 2.0 messages on stdin, responses/notifications
/// on stdout. Protocol messages only on stdout; logging goes to stderr.
pub fn main(init: std.process.Init) !void {
    // Process-lifetime allocations.
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);

    var stdin_buffer: [1024 * 1024]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);

    try agent_client_protocol.server.run(&stdin_file_reader.interface, &stdout_file_writer.interface, arena);
}
