const std = @import("std");
const Io = std.Io;

const agent_client_protocol = @import("agent_client_protocol");
const config_mod = agent_client_protocol.config;

/// ACP server entry point.
///
/// Loads environment configuration, validates the provider at startup (when
/// a key is configured), then runs the transport loop: newline-delimited
/// JSON-RPC 2.0 messages on stdin, responses/notifications on stdout.
/// Protocol messages only on stdout; logging goes to stderr.
pub fn main(init: std.process.Init) !void {
    // Process-lifetime allocations.
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var env_map = try std.process.Environ.createMap(init.minimal.environ, arena);
    defer env_map.deinit();
    const config = try config_mod.Config.load(io, &env_map, arena);

    var http_client: std.http.Client = .{ .allocator = arena, .io = io };
    defer http_client.deinit();

    if (config.default()) |provider| {
        config_mod.healthCheck(provider.*, &http_client, arena) catch |err| {
            std.log.err("provider health check failed: {s} (check the provider config)", .{@errorName(err)});
            std.process.exit(1);
        };
    }

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);

    var stdin_buffer: [1024 * 1024]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);

    try agent_client_protocol.server.run(
        io,
        &stdin_file_reader.interface,
        &stdout_file_writer.interface,
        arena,
        config,
        .{
            .{ .generate = agent_client_protocol.provider.openai.generate },
            .{ .generate = agent_client_protocol.provider.anthropic.generate },
        },
    );
}
