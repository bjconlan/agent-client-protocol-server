//! Environment configuration.
//!
//! MVP is env-only (no config file):
//! - `OPENAI_API_KEY` — provider API key. Missing → lazy failure at first
//!   prompt; when present, validated by a startup health check.
//! - `OPENAI_URL` — base URL, default `https://api.openai.com/v1`. Set to an
//!   OpenAI-compatible endpoint (e.g. `https://api.deepseek.com/v1`) to use
//!   another provider.
//! - `OPENAI_MODEL` — model id, default `deepseek-v4-flash`.
//! - `OPENAI_EFFORT` — `reasoning.effort` for the Responses API
//!   (none|minimal|low|medium|high|xhigh|max), default `high`.

const std = @import("std");
const Io = std.Io;

pub const Config = struct {
    api_key: ?[]const u8,
    base_url: []const u8,
    model: []const u8,
    effort: []const u8,

    pub const default_base_url = "https://api.openai.com/v1";
    pub const default_model = "deepseek-v4-flash";
    pub const default_effort = "high";

    /// Parse configuration from an environment map. Values are copied into
    /// `allocator` (typically the process arena).
    pub fn load(map: *std.process.Environ.Map, allocator: std.mem.Allocator) !Config {
        const key = map.get("OPENAI_API_KEY");
        const base = map.get("OPENAI_URL");
        const model = map.get("OPENAI_MODEL");
        const effort = map.get("OPENAI_EFFORT");

        return .{
            .api_key = if (key) |k| try allocator.dupe(u8, k) else null,
            .base_url = try allocator.dupe(u8, base orelse default_base_url),
            .model = try allocator.dupe(u8, model orelse default_model),
            .effort = try allocator.dupe(u8, effort orelse default_effort),
        };
    }
};

const config_mod = @import("config.zig");
const http_util = @import("util/http.zig");

/// Startup provider validation: `GET {base}/models` with the configured key.
/// Skipped when no key is set (lazy failure at first prompt instead).
pub fn healthCheck(
    config: Config,
    http: *std.http.Client,
    allocator: std.mem.Allocator,
) !void {
    const key = config.api_key orelse return;
    const url = try http_util.url(allocator, config.base_url, "/models");
    defer allocator.free(url);

    var response = try http_util.request(http, allocator, url, key, null);
    defer response.deinit();
    // `http_util.request` already classified the status; reaching here means 2xx.
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testMap(a: std.mem.Allocator) !std.process.Environ.Map {
    const map = try std.process.Environ.createMap(std.process.Environ.empty, a);
    return map;
}

test "config: defaults apply when env is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var map = try testMap(a);
    defer map.deinit();

    const c = try Config.load(&map, a);
    try testing.expect(c.api_key == null);
    try testing.expectEqualStrings(Config.default_base_url, c.base_url);
    try testing.expectEqualStrings(Config.default_model, c.model);
    try testing.expectEqualStrings(Config.default_effort, c.effort);
}

test "config: env overrides are read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var map = try testMap(a);
    defer map.deinit();
    try map.put("OPENAI_API_KEY", "sk-test");
    try map.put("OPENAI_URL", "https://api.deepseek.com/v1");
    try map.put("OPENAI_MODEL", "deepseek-chat");
    try map.put("OPENAI_EFFORT", "medium");

    const c = try Config.load(&map, a);
    try testing.expectEqualStrings("sk-test", c.api_key.?);
    try testing.expectEqualStrings("https://api.deepseek.com/v1", c.base_url);
    try testing.expectEqualStrings("deepseek-chat", c.model);
    try testing.expectEqualStrings("medium", c.effort);
}

test "healthCheck: 2xx passes, 401 fails, missing key skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var http: std.http.Client = .{ .allocator = a, .io = io };
    defer http.deinit();

    const Mock = @import("util/mock_http.zig").Mock;

    // 200 → pass
    var ok_mock = try Mock.start(io, a, "HTTP/1.1 200 OK", "{}");
    defer ok_mock.deinit();
    const ok_base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{ok_mock.port()});
    defer a.free(ok_base);
    const ok_cfg = Config{ .api_key = "sk-test", .base_url = ok_base, .model = "m", .effort = "high" };
    try healthCheck(ok_cfg, &http, a);

    // 401 → BadApiKey
    var bad_mock = try Mock.start(io, a, "HTTP/1.1 401 Unauthorized", "{}");
    defer bad_mock.deinit();
    const bad_base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{bad_mock.port()});
    defer a.free(bad_base);
    const bad_cfg = Config{ .api_key = "sk-bad", .base_url = bad_base, .model = "m", .effort = "high" };
    try testing.expectError(error.BadApiKey, healthCheck(bad_cfg, &http, a));

    // missing key → skipped (no request made)
    const no_key = Config{ .api_key = null, .base_url = bad_base, .model = "m", .effort = "high" };
    try healthCheck(no_key, &http, a);
}
