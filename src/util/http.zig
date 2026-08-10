//! Wrapper around `std.http.Client` for provider API calls (HTTPS).
//!
//! Provides a streaming JSON request helper: send the request, classify the
//! status, and hand back a body `Reader` for incremental reads (SSE). The
//! client is owned by the caller and reused across requests.

const std = @import("std");

/// Provider API errors, classified from HTTP status / transport failures.
pub const Error = error{
    /// 401/403 — bad or missing API key.
    BadApiKey,
    /// 404 — endpoint not found (wrong base URL?).
    NotFound,
    /// 429 — rate limited.
    RateLimited,
    /// 4xx other.
    ClientError,
    /// 5xx.
    ServerError,
    /// Transport failure (connect/TLS/read).
    Network,
};

/// An in-flight streaming response. `reader` yields the body; call `deinit`
/// when done. The struct must not be moved after construction (the reader
/// points into its transfer buffer).
pub const Response = struct {
    req: std.http.Client.Request,
    response: std.http.Client.Response,
    transfer_buffer: [64 * 1024]u8,
    reader: *std.Io.Reader,

    pub fn deinit(self: *Response) void {
        self.req.deinit();
    }
};

/// Send a JSON request. `body` null → GET, else POST with the given body.
/// Returns the streaming response; the caller checks `status` and reads the
/// body.
pub fn request(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    url_text: []const u8,
    api_key: []const u8,
    body: ?[]const u8,
) Error!Response {
    const uri = std.Uri.parse(url_text) catch return error.Network;

    var req = client.request(
        if (body == null) .GET else .POST,
        uri,
        .{
            .headers = .{
                .authorization = .{ .override = api_key },
                .content_type = if (body != null) .{ .override = "application/json" } else .default,
            },
        },
    ) catch return error.Network;
    errdefer req.deinit();

    if (body) |b| {
        // `sendBodyComplete` requires a mutable buffer; the body is not
        // modified, so a copy suffices.
        const owned = allocator.dupe(u8, b) catch return error.Network;
        defer allocator.free(owned);
        req.sendBodyComplete(owned) catch return error.Network;
    } else {
        req.sendBodiless() catch return error.Network;
    }

    var self: Response = undefined;
    self.req = req;
    var redirect_buffer: [64]u8 = undefined;
    self.response = req.receiveHead(&redirect_buffer) catch return error.Network;
    const status = self.response.head.status;

    if (status.class() != .success) {
        switch (status) {
            .unauthorized, .forbidden => return error.BadApiKey,
            .not_found => return error.NotFound,
            .too_many_requests => return error.RateLimited,
            else => {},
        }
        if (status.class() == .server_error) return error.ServerError;
        return error.ClientError;
    }

    self.reader = self.response.reader(&self.transfer_buffer);
    return self;
}

/// Read the remainder of a streaming response body into `allocator`.
pub fn readAll(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) ![]u8 {
    return reader.allocRemaining(allocator, .unlimited);
}

/// Build a URL from a base URL (no trailing slash) + path suffix.
pub fn url(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    path: []const u8,
) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed, path });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "url: joins base and path without double slashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        "https://api.openai.com/v1/responses",
        try url(a, "https://api.openai.com/v1", "/responses"),
    );
    try testing.expectEqualStrings(
        "https://api.deepseek.com/responses",
        try url(a, "https://api.deepseek.com/", "/responses"),
    );
    try testing.expectEqualStrings(
        "https://api.deepseek.com/v1/models",
        try url(a, "https://api.deepseek.com/v1", "/models"),
    );
}
