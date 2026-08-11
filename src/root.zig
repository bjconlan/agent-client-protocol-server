//! By convention, root.zig is the root source file when making a package.
//! Re-exports the public API surface of the library.
const std = @import("std");

pub const config = @import("config.zig");

pub const tools = struct {
    pub const registry = @import("tools/registry.zig");
};

pub const server = @import("server.zig");

pub const protocol = struct {
    pub const json_rpc = @import("protocol/json_rpc.zig");
    pub const v1 = struct {
        pub const methods = @import("protocol/v1/methods.zig");
        pub const types = @import("protocol/v1/types.zig");
    };
    pub const v2 = struct {
        pub const methods = @import("protocol/v2/methods.zig");
    };
};

pub const provider = struct {
    pub const adapter = @import("provider/adapter.zig");
    pub const echo = @import("provider/echo.zig");
    pub const openai = @import("provider/openai.zig");
    pub const anthropic = @import("provider/anthropic.zig");
};

pub const util = struct {
    pub const json = @import("util/json.zig");
    pub const http = @import("util/http.zig");
    /// Test-only mock HTTP server (compiled in all builds; only used by tests).
    pub const mock_http = @import("util/mock_http.zig");
};

test {
    // Submodule tests (protocol/, provider/, util/) are compiled and run as
    // part of this module's test target. Explicitly reference each module so
    // lazy analysis pulls their test blocks into the test build.
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(protocol.json_rpc);
    std.testing.refAllDecls(protocol.v1.methods);
    std.testing.refAllDecls(protocol.v1.types);
    std.testing.refAllDecls(protocol.v2.methods);
    std.testing.refAllDecls(provider.adapter);
    std.testing.refAllDecls(provider.echo);
    std.testing.refAllDecls(provider.openai);
    std.testing.refAllDecls(provider.anthropic);
    std.testing.refAllDecls(util.json);
    std.testing.refAllDecls(util.http);
    std.testing.refAllDecls(util.mock_http);
    std.testing.refAllDecls(config);
    std.testing.refAllDecls(tools.registry);
}
