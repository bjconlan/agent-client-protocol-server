const std = @import("std");
const Io = std.Io;

const agent_client_protocol = @import("agent_client_protocol");

/// ACP server entry point.
///
/// Runs as a CLI process: JSON-RPC 2.0 requests arrive on stdin and responses
/// are written to stdout. The transport loop, method dispatch, and provider
/// wiring land in the first feature; for now this prints usage information.
pub fn main(init: std.process.Init) !void {
    // A long-lived process like a stdio server should use an arena for
    // process-lifetime allocations.
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    _ = args; // parsed into config in the first feature

    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try agent_client_protocol.printBanner(stdout_writer);
    try stdout_writer.flush();
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
