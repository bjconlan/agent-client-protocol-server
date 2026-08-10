//! By convention, root.zig is the root source file when making a package.
//! Re-exports the public API surface of the library.
const std = @import("std");
const Io = std.Io;

pub const config = @import("config.zig");

pub const protocol = struct {
    pub const json_rpc = @import("protocol/json_rpc.zig");
    pub const types = @import("protocol/types.zig");
    pub const methods = @import("protocol/methods.zig");
};

pub const provider = struct {
    pub const adapter = @import("provider/adapter.zig");
    pub const openai = @import("provider/openai.zig");
};

pub const util = struct {
    pub const json = @import("util/json.zig");
    pub const http = @import("util/http.zig");
};

/// Placeholder banner shown by the CLI entry point until the transport loop
/// lands.
pub fn printBanner(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("agent-client-protocol: ACP server (stdio JSON-RPC 2.0)\n", .{});
}

test {
    // Submodule tests (protocol/, provider/, util/) are compiled and run as
    // part of this module's test target.
    std.testing.refAllDecls(@This());
}
