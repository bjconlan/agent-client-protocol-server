# Verify: MCP client module (feature/mcp-client-module)

Validates the implementation against the plan's verification strategy
(`.ai/feature/mcp-client-module.md`). Append-only — superseded criteria are
struck through with an HTML comment.

## Protocol / transcript (unit, via `MockTransport`)

| Criterion | Result |
|-----------|--------|
| `initialize` handshake: request shape, negotiated version/capabilities/serverInfo, `notifications/initialized` sent | ✅ `test "initialize handshake: request shape + negotiated state"` — asserts the exact written JSON lines (initialize request + initialized notification), negotiated state, capability flags |
| `tools/list` shape (name/description/inputSchema as JSON text) | ✅ `test "tools/list + tools/call transcript"` — inputSchema round-trips as `{"type":"object","properties":{}}` |
| `tools/call` (text content, `isError`) | ✅ same test — content block text, `is_error` false |
| `tools/call` forwards `arguments` | ✅ `test "tools/call with arguments forwards them"` — exact request JSON |
| Error response → `last_error` (code/message) | ✅ `test "error response sets last_error"` — -32602 + message |
| Interleaved server notification skipped, matching response wins | ✅ `test "interleaved server notification is skipped..."` — ping succeeds past a `notifications/message` line |
| EOF mid-response → `McpConnectionClosed` | ✅ `test "EOF before a response raises McpConnectionClosed"` — last_error -32000 |
| `resources/list` + `resources/read` | ✅ `test "resources + prompts transcript"` |
| `prompts/list` + `prompts/get` | ✅ same test — arguments schema text, message role/content |
| Invalid result shape → `McpInvalidResponse` | ✅ `test "invalid response shape raises McpInvalidResponse"` |
| Integer ids increment per request | ✅ implied by id assertions in transcripts (id 1, 2, 3…) |

## Stdio transport (integration)

| Criterion | Result |
|-----------|--------|
| Real child process line framing round-trip | ✅ `test "stdio transport: line framing round-trip over real pipes"` — spawns `sh -c cat`, writes/reads two lines (skipped on Windows) |
| Flush-after-write so the child receives short lines | ✅ implemented in `StdioTransport.writeLineFn` (required — the buffered writer otherwise never delivers the line; the round-trip test would hang) |
| Kill-on-deinit reaps the child | ✅ `Child.kill` (blocks + reaps; `wait` must NOT follow — caught as an ABRT during development) |

## Whole repo

| Criterion | Result |
|-----------|--------|
| `zig build test` all suites green | ✅ 69/69 (58 existing + 11 new) |
| `zig fmt --check` clean | ✅ |
| `zig build` produces the binary | ✅ `zig-out/bin/acps` |

## Out of scope (later epic tasks)

- `mcpServers` config section, ACP tool-surface integration, streamable-HTTP,
  MCP server role, library extraction — tracked in `.ai/backlog/3.md`.
- Live smoke against a real MCP server (e.g. the reference filesystem server)
  is planned for the ACP-integration task, which has a real provider key
  available.
