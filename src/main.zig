const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const acps = @import("acps");
const config_mod = acps.config;
const logging = acps.util.log;

/// Enable all levels at compile time; `util/log.zig` filters at runtime via
/// the `ACP_LOG` env var.
pub const std_options = std.Options{
    .log_level = .debug,
    .logFn = logging.logFn,
};

/// ACP server entry point.
///
/// Loads environment configuration, validates the provider at startup (when
/// a key is configured), then runs the transport loop: newline-delimited
/// JSON-RPC 2.0 messages on stdin, responses/notifications on stdout.
/// Protocol messages only on stdout; logging goes to stderr.
/// Ignore SIGPIPE so a write to a closed pipe (the client exiting mid-turn)
/// returns EPIPE from the write instead of killing the process; the write
/// paths catch those errors and end the turn quietly.
fn ignoreSigpipe() void {
    if (comptime builtin.os.tag != .windows) {
        var act = std.posix.Sigaction{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.PIPE, &act, null);
    }
}

pub fn main(init: std.process.Init) !void {
    ignoreSigpipe();
    // Process-lifetime allocations.
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var env_map = try std.process.Environ.createMap(init.minimal.environ, arena);
    defer env_map.deinit();
    logging.initFromEnv(&env_map);
    const config = config_mod.Config.load(io, &env_map, arena) catch |err| {
        std.log.err("configuration load failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    var http_client: std.http.Client = .{ .allocator = arena, .io = io };
    defer http_client.deinit();

    if (config.default()) |provider| {
        if (provider.api_key == null) {
            std.log.warn("no API key configured for the default provider — prompts will fail until api_key or api_key_env is set in the config", .{});
        }
        config_mod.healthCheck(provider.*, &http_client, arena) catch |err| {
            std.log.err("provider health check failed: {s} (check the provider config)", .{@errorName(err)});
            std.process.exit(1);
        };
    }

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);

    var stdin_buffer: [1024 * 1024]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);

    try acps.server.run(
        io,
        &stdin_file_reader.interface,
        &stdout_file_writer.interface,
        arena,
        config,
        .{
            .{ .generate = acps.provider.openai.generate },
            .{ .generate = acps.provider.anthropic.generate },
        },
    );
}
