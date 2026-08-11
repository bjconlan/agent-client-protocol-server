//! Wrapper around `std.http.Client` for provider API calls (HTTPS).
//!
//! Provides a streaming JSON request helper: send the request, classify the
//! status, and hand back a body `Reader` for incremental reads (SSE). The
//! client is owned by the caller and reused across requests.

const std = @import("std");
const Io = std.Io;

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
/// when done. Heap-allocated (via `request`) so the reader's borrowed
/// transfer buffer and the request pointers are stable — returning this by
/// value would dangle them.
pub const Response = struct {
    req: std.http.Client.Request,
    response: std.http.Client.Response,
    transfer_buffer: [64 * 1024]u8,
    reader: *std.Io.Reader,
    /// Exchange info for the one-line trace ("GET"/"POST", url, status).
    method: []const u8,
    url: []const u8,
    status: std.http.Status,

    pub fn deinit(self: *Response) void {
        self.req.deinit();
    }
};

/// How the API key is presented.
pub const Auth = enum {
    /// `Authorization: Bearer <key>` (OpenAI-compatible).
    bearer,
    /// `x-api-key: <key>` (Anthropic Messages API).
    x_api_key,
};

pub const RequestOptions = struct {
    auth: Auth = .bearer,
    /// Additional headers (e.g. `anthropic-version`).
    extra_headers: []const std.http.Header = &.{},
    /// Body; null → GET.
    body: ?[]const u8 = null,
};

/// Send a JSON request. Returns a heap-allocated streaming response
/// (allocate from an arena or free the struct yourself); the caller checks
/// `status` and reads the body.
pub fn request(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    url_text: []const u8,
    api_key: []const u8,
    options: RequestOptions,
) Error!*Response {
    const uri = std.Uri.parse(url_text) catch return error.Network;
    const body = options.body;
    const method = if (body == null) "GET" else "POST";

    // Auth header: `Authorization: Bearer <key>` or `x-api-key: <key>`, plus
    // any extra headers, assembled into a single extra_headers slice (the
    // `Headers` struct has no x-api-key field).
    var headers_buf: [16]std.http.Header = undefined;
    var header_count: usize = 0;
    var bearer_text: []u8 = undefined;
    switch (options.auth) {
        .bearer => {
            // Set via Request.Headers.authorization below (single header).
            // NOTE: not freed here — the std client reads the header value
            // lazily (head flush can happen after this returns); callers pass
            // arenas, which reclaim it.
            bearer_text = std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key}) catch return error.Network;
        },
        .x_api_key => {
            headers_buf[header_count] = .{ .name = "x-api-key", .value = api_key };
            header_count += 1;
        },
    }
    for (options.extra_headers) |h| {
        if (header_count < headers_buf.len) {
            headers_buf[header_count] = h;
            header_count += 1;
        }
    }

    const self = allocator.create(Response) catch return error.Network;
    errdefer allocator.destroy(self);

    std.log.scoped(.http).debug("{s} {s}{s}", .{
        url_text,
        method,
        if (body) |b| std.fmt.allocPrint(allocator, " body={s}", .{b}) catch "" else "",
    });

    // Build the request directly into self.req so the response body reader
    // (which points into self.req + self.transfer_buffer) is stable at its
    // final heap location — a local req would dangle after this returns.
    self.req = client.request(
        if (body == null) .GET else .POST,
        uri,
        .{
            .headers = .{
                .authorization = if (options.auth == .bearer) .{ .override = bearer_text } else .default,
                .content_type = if (body != null) .{ .override = "application/json" } else .default,
            },
            .extra_headers = if (header_count > 0) headers_buf[0..header_count] else &.{},
        },
    ) catch return error.Network;
    errdefer self.req.deinit();

    if (body) |b| {
        // `sendBodyComplete` requires a mutable buffer; the body is not
        // modified, so a copy suffices.
        const owned = allocator.dupe(u8, b) catch return error.Network;
        defer allocator.free(owned);
        self.req.sendBodyComplete(owned) catch return error.Network;
    } else {
        self.req.sendBodiless() catch return error.Network;
    }

    var redirect_buffer: [64]u8 = undefined;
    self.response = self.req.receiveHead(&redirect_buffer) catch return error.Network;
    const status = self.response.head.status;
    self.method = method;
    self.url = url_text;
    self.status = status;

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

/// Read the remainder of a response body, logging the full exchange on one
/// line: `{method} {url} {status} body={body}`.
pub fn readAll(response: *Response, allocator: std.mem.Allocator) ![]u8 {
    const body = try response.reader.allocRemaining(allocator, .unlimited);
    std.log.scoped(.http).debug("{s} {d} body={s}", .{
        response.url,
        @intFromEnum(response.status),
        body,
    });
    return body;
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

test "bearer auth sends a single Authorization header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var http: std.http.Client = .{ .allocator = a, .io = io };
    defer http.deinit();

    var mock = try @import("mock_http.zig").Mock.start(io, a, "HTTP/1.1 200 OK", "ok");
    defer mock.deinit();

    const url_text = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/models", .{mock.port()});
    defer a.free(url_text);

    var resp = try request(&http, a, url_text, "sk-test", .{});
    defer resp.deinit();
    const body = try readAll(resp, a);
    try testing.expectEqualStrings("ok", body);

    try testing.expect(std.mem.indexOf(u8, mock.request.items, "authorization: Bearer sk-test") != null);
}
