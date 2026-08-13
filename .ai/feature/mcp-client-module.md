# Plan: MCP client module (mcp_client)

## Scope

A generic **MCP client** module (`src/mcp_client/`, Zig module `mcp_client`) that
connects to MCP servers over **stdio** (child subprocess) and performs tool
calls on behalf of the ACP server — plus `resources` and `prompts` list/read
methods (same request/response pattern, trivial once the client core exists).

Out of scope (later epic tasks): `mcpServers` config section, ACP tool-surface
integration, streamable-HTTP transport, MCP server role, library extraction
to a separate repository. The module is protocol-agnostic — MCP is independent
of ACP except for shared JSON-RPC 2.0 framing (reuses `protocol/json_rpc.zig`).

## Architecture

### Data layer (`types.zig`)
- `ClientInfo { name, version }` — client identity for `initialize`
- `ServerInfo { name, version }` — from `initialize` result
- `Capabilities` — server capability flags (tools / resources / prompts / logging)
- `Tool { name, description, input_schema }` — `input_schema` is serialized
  JSON-Schema text (matches the existing ACP `Tool.parameters` shape)
- `Resource { uri, name, description, mime_type }`
- `Prompt { name, description, arguments }`
- `ContentBlock` — `text` first cut (`image`/`audio`/`resource` later)
- `ToolResult { content: []ContentBlock, is_error: bool }`
- `McpError { code: i32, message: []const u8 }` — mapped from JSON-RPC error objects

### Function layer (`client.zig`)
Pure, composable, testable against a scripted transport:
- `initialize(allocator, protocol_version, client_info) !InitializeResult` — handshake + `notifications/initialized`
- `listTools(allocator) ![]Tool`
- `callTool(allocator, name, arguments) !ToolResult`
- `listResources(allocator) ![]Resource`, `readResource(allocator, uri) !ResourceContent`
- `listPrompts(allocator) ![]Prompt`, `getPrompt(allocator, name, arguments) !PromptResult`
- `ping() !void`
- `request(allocator, method, params) !std.json.Value` — shared: serialize →
  write line (mutex) → read lines until the matching response id (skip
  notifications) → return `result` or throw with `last_error` set

### Context layer (`client.zig`, `transport.zig`)
- `Client { io, transport, arena, next_id, write_mutex, protocol_version, server_info, last_error }`
  — one `Client` per MCP server; caller-owned lifetime (connect at startup,
  deinit at shutdown); `write_mutex` serializes writers; a per-call parse arena
  is reset after each `request` (results are copied into the caller allocator).
- `Transport` vtable (`writeLine` / `readLine` / `deinit`) — `readLine` returns
  a slice borrowed until the next call (parse copies immediately).
  - `StdioTransport`: `std.process.spawn(io, .{ .argv, .stdin = .pipe,
    .stdout = .pipe, .stderr = .ignore })`; wraps `Child.stdin`/`Child.stdout`
    in `Io.File.Writer` / `Io.File.Reader` (line-delimited via
    `takeDelimiter('\n')`); `deinit` kills + waits the child.
  - `InMemoryTransport` (test-only): scripted request → response lines for
    transcript tests without spawning processes.

### API / Contract
- Module root `mcp_client.zig` re-exports `Client`, `types`, `transport`.
- `b.addModule("mcp_client", .{ .root_source_file = b.path("src/mcp_client/mcp_client.zig") })`
  — consumable standalone now, extractable later.
- Methods return caller-owned data (allocator param); failures throw
  `error.McpRequestFailed` / `error.McpError` with `client.last_error` set.

## Units of Work

1. **`types.zig`** — data types. Checkpoint: compiles; unit test for
   `ToolResult`/`ContentBlock` construction and `McpError` mapping.
2. **`transport.zig`** — `Transport` vtable + `InMemoryTransport` (scripted).
   Checkpoint: in-memory round-trip test (write line → scripted response line).
3. **`client.zig` core** — `request()` (serialize/write/read-match), `initialize`,
   `listTools`, `callTool`, `ping`. Checkpoint: transcript tests against
   `InMemoryTransport` — initialize → initialized → tools/list → tools/call →
   result, plus error response → `last_error`.
4. **`resources` + `prompts`** — list/read/get methods (same pattern).
   Checkpoint: transcript tests for each.
5. **`StdioTransport`** — child-process spawn + pipe line IO. Checkpoint:
   integration test spawning a real helper (echo/`cat`-style) verifying
   line framing over actual pipes; `deinit` kills the child.
6. **`build.zig` wiring + root module** — `b.addModule("mcp_client", …)` and a
   test step for the module (mirrors `mod_tests`). Checkpoint:
   `zig build test` runs the mcp_client tests; `zig fmt --check` clean.

## Verification Strategy

- **Protocol/transcript (unit)**: scripted `InMemoryTransport` covering
  initialize handshake (version + capabilities negotiation), tools/list shape
  (name/description/inputSchema), tools/call (text content, `isError`),
  error responses (code/message → `last_error`), unknown-method errors,
  responses out of order / interleaved notifications, EOF mid-response.
- **Stdio transport (integration)**: real child process; line framing
  round-trip; child exit / EOF handling; kill-on-deinit.
- **Edge cases**: empty tool list, missing optional fields (description),
  non-object params, oversized lines (`StreamTooLong`), matching-id
  correlation, integer ids incrementing.
- **Whole repo**: `zig build test` (all suites green), `zig fmt --check`.

## References

- MCP spec (modelcontextprotocol.io): JSON-RPC 2.0 stdio transport,
  `initialize` / `notifications/initialized`, `tools/list` + `tools/call`
  (JSON-Schema `inputSchema`), `resources/list` + `resources/read`,
  `prompts/list` + `prompts/get`, `ping`. Protocol versions are date-stamped
  (e.g. `2025-06-18`); the client negotiates via the `initialize` result.
- Existing: `src/protocol/json_rpc.zig` (framing), `src/server.zig`
  (interface-based line IO pattern), `src/util/mock_http.zig` (mock pattern).

## Status

- **Stage:** 2 (Implementation complete — units 1–6 done)
- **Current unit:** —
- **Last checkpoint:** `zig build test` 69/69 pass (11 new MCP tests);
  `zig fmt --check` clean; binary builds; stdio transport verified against a
  real child process (`cat` line round-trip)
- **Next action:** Review (see `.ai/feature/mcp-client-module.verify.md`)

## Outcomes

### What was implemented
- `src/mcp_client/` — generic MCP client: `Client` (initialize, tools/list,
  tools/call, resources/list, resources/read, prompts/list, prompts/get,
  ping), `Transport` vtable + `StdioTransport` (spawned child over pipes) +
  test-only `MockTransport`, `types.zig`, module root.
- `build.zig` — `mcp_client` Zig module with a declared `json_rpc` module
  import (extraction seam) and its own test target.

### Changes from the original plan
- JSON-RPC framing is imported as a declared `json_rpc` module dependency
  rather than a relative path (module-path restriction; also cleaner for
  extraction).
- Flush-after-write added to the stdio transport (buffered writer would
  otherwise never deliver short lines) — discovered via a hanging test.
- `Child.kill` reaps (blocks + id → null), so `wait` must not follow —
  discovered via an ABRT in the stdio test.

### Use cases resolved
- acps can connect to an MCP server over stdio and call its tools (plus
  resources/prompts) — module-level, before any ACP wiring.
- Module is protocol-agnostic and consumable standalone (own Zig module,
  declared json_rpc dependency) — extraction-ready.

### Verification results
- All checkpoints passed: yes
- Full test suite: 69/69 passing (11 new)
- Benchmarks: n/a (no hot-path changes)

### Knowledge updates
- Glossary: MCP section (MCP, stdio transport, initialize handshake,
  tools/list + tools/call, resources/prompts, mcp_client module)
- Architecture: MCP client module section + gotchas (mutex extern init,
  cancelable lock, buffered writer flush, kill-reaps, ArrayList idiom)
- Decisions: MCP client as standalone module; arena ownership + transport vtable
