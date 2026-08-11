//! Configuration: provider registry.
//!
//! Two sources, in priority order:
//! 1. A JSON config file — `$ACP_CONFIG` or
//!    `$XDG_CONFIG_HOME/acps/config.json` (default
//!    `~/.config/acps/config.json`):
//!    ```json
//!    { "default_provider": "deepseek",
//!      "providers": { "deepseek": { "api": "openai",
//!          "url": "https://api.deepseek.com/v1",
//!          "api_key_env": "DEEPSEEK_API_KEY",
//!          "model": "deepseek-v4-flash" } } }
//!    ```
//!    `api` selects the adapter dialect (`openai` | `anthropic`);
//!    `api_key` or `api_key_env` supplies the key (env resolved at load);
//!    `model` is the FALLBACK model — the session may override it (or any
//!    other API-request knob) via `session/set_config_option`.
//! 2. Environment fallback (no file): a single "default" provider from
//!    `OPENAI_API_KEY` / `OPENAI_URL` / `OPENAI_MODEL`.

const std = @import("std");
const Io = std.Io;

/// Adapter dialect a provider speaks.
pub const ApiKind = enum {
    openai,
    anthropic,

    pub fn parse(text: []const u8) ?ApiKind {
        if (std.mem.eql(u8, text, "openai")) return .openai;
        if (std.mem.eql(u8, text, "anthropic")) return .anthropic;
        return null;
    }
};

/// A configured provider. All strings are arena-owned.
pub const ProviderConfig = struct {
    name: []const u8,
    api: ApiKind,
    url: []const u8,
    /// Resolved API key (from `api_key_env` or inline `api_key`); null when
    /// absent — prompts fail lazily with a clear error.
    api_key: ?[]const u8,
    /// Fallback model — used when the session hasn't set one.
    model: []const u8,
};

pub const Config = struct {
    default_provider: []const u8,
    providers: []ProviderConfig,

    pub const default_model = "deepseek-v4-flash";
    pub const config_dir = "acps/config.json";

    /// Load configuration from `ACP_CONFIG` or the default XDG path.
    ///
    /// `ACP_CONFIG` dispatches on its first character: a leading `{` is taken
    /// as the config JSON inline; anything else is a file path. The config
    /// is REQUIRED — all provider settings (keys, URLs, models) live there;
    /// the server's own env surface is only `ACP_CONFIG` and `ACP_LOG_LEVEL`.
    pub fn load(io: Io, map: *std.process.Environ.Map, allocator: std.mem.Allocator) !Config {
        if (map.get("ACP_CONFIG")) |value| {
            if (value.len > 0 and value[0] == '{') {
                return parseConfig(allocator, map, value, "ACP_CONFIG");
            }
            return loadFile(io, allocator, map, value);
        }
        if (defaultPath(map, allocator)) |path| {
            if (Io.Dir.accessAbsolute(io, path, .{})) |_| {
                return loadFile(io, allocator, map, path);
            } else |_| {}
        }
        std.log.err("no config found — set ACP_CONFIG (a file path or inline JSON starting with '{{') or create ~/.config/acps/config.json (see examples/config.example.json)", .{});
        return error.InvalidConfig;
    }

    /// Resolve a provider by name.
    pub fn resolve(self: *const Config, name: []const u8) ?*const ProviderConfig {
        for (self.providers) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    /// The default provider.
    pub fn default(self: *const Config) ?*const ProviderConfig {
        return self.resolve(self.default_provider);
    }
};

/// Default config file path (`$XDG_CONFIG_HOME` or `$HOME/.config`).
fn defaultPath(map: *const std.process.Environ.Map, allocator: std.mem.Allocator) ?[]const u8 {
    if (map.get("XDG_CONFIG_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, Config.config_dir }) catch null;
    }
    const home = map.get("HOME") orelse return null;
    return std.fs.path.join(allocator, &.{ home, ".config", Config.config_dir }) catch null;
}

/// Parse the JSON config file at `path` (absolute, resolved from the cwd).
pub fn loadFile(
    io: Io,
    allocator: std.mem.Allocator,
    map: *std.process.Environ.Map,
    path: []const u8,
) !Config {
    return loadFileAt(io, allocator, map, Io.Dir.cwd(), path);
}

/// Parse the JSON config file at `sub_path` within `dir`.
pub fn loadFileAt(
    io: Io,
    allocator: std.mem.Allocator,
    map: *std.process.Environ.Map,
    dir: Io.Dir,
    sub_path: []const u8,
) !Config {
    const raw = dir.readFileAlloc(io, sub_path, allocator, .unlimited) catch |err| {
        std.log.warn("config: cannot read '{s}': {s}", .{ sub_path, @errorName(err) });
        return error.InvalidConfig;
    };
    return parseConfig(allocator, map, raw, sub_path);
}

/// Parse + validate the config JSON document (`raw`), regardless of whether
/// it came from a file or inline.
fn parseConfig(
    allocator: std.mem.Allocator,
    map: *std.process.Environ.Map,
    raw: []const u8,
    label: []const u8,
) !Config {
    var scanner = std.json.Scanner.initCompleteInput(allocator, raw);
    const value = std.json.Value.jsonParse(allocator, &scanner, .{
        .allocate = .alloc_always,
        .max_value_len = raw.len,
    }) catch {
        std.log.warn("config: '{s}' is not valid JSON", .{label});
        return error.InvalidConfig;
    };
    const root = switch (value) {
        .object => |o| o,
        else => {
            std.log.warn("config: '{s}' must be a JSON object", .{label});
            return error.InvalidConfig;
        },
    };

    // `default_provider` is optional — when absent, the first listed
    // provider is the default.
    var default_name: []const u8 = undefined;
    if (root.get("default_provider")) |dv| switch (dv) {
        .string => |s| default_name = s,
        else => return error.InvalidConfig,
    } else default_name = "";

    const providers_obj = switch (root.get("providers") orelse return error.InvalidConfig) {
        .object => |o| o,
        else => return error.InvalidConfig,
    };

    var providers: std.ArrayList(ProviderConfig) = .empty;
    var it = providers_obj.iterator();
    while (it.next()) |entry| {
        const pc = try parseProvider(allocator, map, entry.key_ptr.*, entry.value_ptr.*);
        try providers.append(allocator, pc);
    }
    if (providers.items.len == 0) {
        std.log.warn("config: no providers defined", .{});
        return error.InvalidConfig;
    }

    if (default_name.len == 0) default_name = providers.items[0].name;
    return .{
        .default_provider = try allocator.dupe(u8, default_name),
        .providers = try providers.toOwnedSlice(allocator),
    };
}

fn parseProvider(
    allocator: std.mem.Allocator,
    map: *const std.process.Environ.Map,
    name: []const u8,
    value: std.json.Value,
) !ProviderConfig {
    const obj = switch (value) {
        .object => |o| o,
        else => {
            std.log.warn("config: provider '{s}' must be an object", .{name});
            return error.InvalidConfig;
        },
    };

    const api_text = switch (obj.get("api") orelse return error.InvalidConfig) {
        .string => |s| s,
        else => return error.InvalidConfig,
    };
    const api = ApiKind.parse(api_text) orelse {
        std.log.warn("config: provider '{s}': unknown api '{s}' (openai|anthropic)", .{ name, api_text });
        return error.InvalidConfig;
    };

    const url = switch (obj.get("url") orelse return error.InvalidConfig) {
        .string => |s| s,
        else => return error.InvalidConfig,
    };

    var api_key: ?[]const u8 = null;
    if (obj.get("api_key_env")) |env_name_v| {
        const env_name = switch (env_name_v) {
            .string => |s| s,
            else => return error.InvalidConfig,
        };
        if (map.get(env_name)) |v| api_key = try allocator.dupe(u8, v);
    }
    if (obj.get("api_key")) |kv| switch (kv) {
        .string => |s| api_key = try allocator.dupe(u8, s),
        else => {},
    };

    var model: []const u8 = Config.default_model;
    if (obj.get("model")) |mv| switch (mv) {
        .string => |s| model = s,
        else => {},
    };

    return .{
        .name = try allocator.dupe(u8, name),
        .api = api,
        .url = try allocator.dupe(u8, url),
        .api_key = api_key,
        .model = try allocator.dupe(u8, model),
    };
}

/// Startup validation of one provider: `GET {base}/models` with its key.
/// Skipped when no key is configured (lazy failure at first prompt) or for
/// anthropic providers (the Anthropic Messages API has no models endpoint —
/// validated lazily on first use).
pub fn healthCheck(
    provider: ProviderConfig,
    http: *std.http.Client,
    allocator: std.mem.Allocator,
) !void {
    if (provider.api == .anthropic) return;
    const key = provider.api_key orelse return;
    const url = try @import("util/http.zig").url(allocator, provider.url, "/models");
    defer allocator.free(url);

    var response = try @import("util/http.zig").request(http, allocator, url, key, .{});
    defer response.deinit();
    // Consume (and, at ACP_LOG=debug, trace) the body.
    _ = try @import("util/http.zig").readAll(response, allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testEnv(a: std.mem.Allocator) !std.process.Environ.Map {
    return std.process.Environ.createMap(std.process.Environ.empty, a);
}

test "loadFileAt: parses and validates a provider config" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var map = try testEnv(a);
    defer map.deinit();
    try map.put("DEEPSEEK_API_KEY", "sk-ds");

    const json =
        \\{"default_provider":"deepseek","providers":{
        \\ "deepseek":{"api":"openai","url":"https://api.deepseek.com/v1","api_key_env":"DEEPSEEK_API_KEY","model":"deepseek-v4-flash"},
        \\ "anthropic":{"api":"anthropic","url":"https://api.anthropic.com/v1","api_key":"sk-inline"}
        \\}}
    ;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data = json });

    const cfg = try loadFileAt(testing.io, a, &map, dir.dir, "config.json");
    try testing.expectEqualStrings("deepseek", cfg.default_provider);
    try testing.expectEqual(@as(usize, 2), cfg.providers.len);
    const ds = cfg.resolve("deepseek").?;
    try testing.expectEqual(ApiKind.openai, ds.api);
    try testing.expectEqualStrings("sk-ds", ds.api_key.?);
    try testing.expectEqualStrings("deepseek-v4-flash", ds.model);
    const an = cfg.resolve("anthropic").?;
    try testing.expectEqual(ApiKind.anthropic, an.api);
    try testing.expectEqualStrings("sk-inline", an.api_key.?);
    try testing.expectEqualStrings(Config.default_model, an.model); // model defaults
}

test "loadFileAt: default provider falls back to the first listed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var map = try testEnv(a);
    defer map.deinit();

    const json =
        \\{"providers":{
        \\ "second":{"api":"openai","url":"http://second"},
        \\ "first":{"api":"openai","url":"http://first"}
        \\}}
    ;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(testing.io, .{ .sub_path = "c.json", .data = json });

    const cfg = try loadFileAt(testing.io, a, &map, dir.dir, "c.json");
    try testing.expectEqualStrings("second", cfg.default_provider);
}

test "loadFileAt: invalid configs rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var map = try testEnv(a);
    defer map.deinit();

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    // unknown api
    try dir.dir.writeFile(testing.io, .{ .sub_path = "c1.json", .data = "{\"default_provider\":\"x\",\"providers\":{\"x\":{\"api\":\"bogus\",\"url\":\"http://x\"}}}" });
    try testing.expectError(error.InvalidConfig, loadFileAt(testing.io, a, &map, dir.dir, "c1.json"));

    // empty providers
    try dir.dir.writeFile(testing.io, .{ .sub_path = "c2.json", .data = "{\"default_provider\":\"x\",\"providers\":{}}" });
    try testing.expectError(error.InvalidConfig, loadFileAt(testing.io, a, &map, dir.dir, "c2.json"));

    // missing url
    try dir.dir.writeFile(testing.io, .{ .sub_path = "c3.json", .data = "{\"default_provider\":\"x\",\"providers\":{\"x\":{\"api\":\"openai\"}}}" });
    try testing.expectError(error.InvalidConfig, loadFileAt(testing.io, a, &map, dir.dir, "c3.json"));
}

test "load: ACP_CONFIG inline JSON dispatches on the first character" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var map = try testEnv(a);
    defer map.deinit();
    try map.put("ACP_CONFIG", "{\"default_provider\":\"ds\",\"providers\":{\"ds\":{\"api\":\"openai\",\"url\":\"http://x\",\"api_key\":\"sk-inline\",\"model\":\"m\"}}}");

    const cfg = try Config.load(testing.io, &map, a);
    try testing.expectEqualStrings("ds", cfg.default_provider);
    const p = cfg.default().?;
    try testing.expectEqualStrings("sk-inline", p.api_key.?);
    try testing.expectEqualStrings("m", p.model);
}
